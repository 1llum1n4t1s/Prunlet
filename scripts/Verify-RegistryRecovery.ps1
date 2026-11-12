[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Alias('BaselineMoveExecutablePath')][string]$MoveExecutablePath,
    [string]$RustProbePath,
    [string]$BuildManifestPath,
    [string]$ExpectedBuildManifestSha256,
    [string]$LegacyRegistryExecutablePath,
    [string]$LatestRegistryExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$FixtureRoot,
    [ValidateSet('HKCU\Software\PrunletE2E','HKEY_CURRENT_USER\Software\PrunletE2E','HKLM\SYSTEM\PrunletE2E','HKEY_LOCAL_MACHINE\SYSTEM\PrunletE2E')]
    [string]$RegistryFixtureRoot = 'HKCU\Software\PrunletE2E',
    [ValidateNotNullOrEmpty()][string[]]$CaseFilter = @('*')
)
$ErrorActionPreference = 'Stop'
# 想定する失敗: 元キー/値の誤削除、型/生bytes/完全ACLの欠落、viewの取り違え、
# 既存復元先の上書き、dry-runによる変更、改竄/中断記録の受理、保持予算の混同、
# MCPの入力検査漏れと失敗の成功表示。キー正常往復は権限不足でも合格にしない。
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'Verification-Fixture.ps1')
. (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')
. (Join-Path $PSScriptRoot 'RegistryFixtures.Common.ps1')
. (Join-Path $PSScriptRoot 'ProtectedRegistryFixtures.Common.ps1')
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$null = Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256 -SourceRoot $repoRoot
if ($RustProbePath) {
    if (!$BuildManifestPath -or !$ExpectedBuildManifestSha256) { throw 'Rust probe requires a fixed same-source build manifest and SHA-256.' }
    $repo = $repoRoot
    . (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
    $script:RegistryBuildBinding = Assert-RustFileProbeBinding
    # 同じ候補・manifest・入力を要求終了までread handleで固定する。
    $script:RegistryBuildPins = [Collections.Generic.List[object]]::new()
    try {
        foreach ($inputPath in @($ExecutablePath,$RustProbePath,$BuildManifestPath) + @(Get-PrunletRustInputNames $repo | ForEach-Object { Join-Path $repo $_ })) {
            $handle = [IO.File]::Open($inputPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $script:RegistryBuildPins.Add($handle)
        }
        if ((Get-RustFileSourceFingerprint $repo) -cne $script:RegistryBuildBinding.sourceFingerprint) { throw 'Rust source changed while fixing registry verification inputs.' }
    } catch { foreach ($handle in $script:RegistryBuildPins) { $handle.Dispose() }; throw }
} elseif ($BuildManifestPath -or $ExpectedBuildManifestSha256) { throw 'Build manifest is only accepted with RustProbePath.' }
foreach ($path in @($ExecutablePath, $MoveExecutablePath, $RustProbePath, $BuildManifestPath, $LegacyRegistryExecutablePath, $LatestRegistryExecutablePath, $OutputDirectory, $ReportPath) | Where-Object { $_ }) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Executable/output/report paths must be absolute.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
if ($MoveExecutablePath) {
    $MoveExecutablePath = [IO.Path]::GetFullPath($MoveExecutablePath)
    if (![IO.File]::Exists($MoveExecutablePath)) { throw 'MoveExecutablePath missing.' }
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-ExternalVerificationPath $path @($repoRoot, $codexRoot)
    if (Test-Path -LiteralPath $path) { throw 'Output/report must be new.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create external output/report parents first.' }
}
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable missing.' }
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()
$machineFixture = $RegistryFixtureRoot -match '^(HKLM|HKEY_LOCAL_MACHINE)\\'
$fixtureHive = if ($machineFixture) { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
$fixtureNamespace = if ($machineFixture) { 'SYSTEM\PrunletE2E' } else { 'Software\PrunletE2E' }
$RegistryFixtureRoot = $fixtureHive + '\' + $fixtureNamespace
$runRelative = $fixtureNamespace + '\' + [guid]::NewGuid().ToString('N')
$runPath = $fixtureHive + '\' + $runRelative
$classesRelative = 'Software\Classes\PrunletE2E_' + ($runRelative -split '\\')[-1]
$linkRelative = $runRelative + '-link-probes'
$createdLinkFixture = $false
$pathValueNames = @(
    'C:\Program Files\Prunlet Fixture\App.exe.FriendlyAppName',
    'C:\Program Files\Prunlet Fixture\App.exe.ApplicationCompany',
    'C:\Program Files (x86)\Prunlet Fixture\Tool.exe.FriendlyAppName',
    'C:\Program Files (x86)\Prunlet Fixture\Tool.exe.ApplicationCompany',
    'D:\日本語 fixture\試験.exe.FriendlyAppName',
    'D:\日本語 fixture\試験.exe.ApplicationCompany'
)
$createdFixture = $false
$excluded = 0
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 80), $utf8) }
function Read-Json([string]$Path) { [IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 80 -AsHashtable }
function Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Start-Child([string[]]$Arguments, [string]$Binary = $ExecutablePath, [string]$ConfigPath = $script:Config) {
    $info = [Diagnostics.ProcessStartInfo]::new($Binary)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8; $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    $info.WorkingDirectory = $script:CaseRoot
    $info.Environment['TEMP'] = Join-Path $script:CaseRoot 'temp'; $info.Environment['TMP'] = $info.Environment['TEMP']
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $script:CaseRoot 'runtime-cache'
    foreach ($arg in (@('--config', $ConfigPath) + $Arguments)) { $info.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::new(); $p.StartInfo = $info; $null = $p.Start(); return $p
}
function Invoke-RegistryCli([string[]]$Arguments, [switch]$LegacyMove) {
    $binary = if ($LegacyMove) { $MoveExecutablePath } else { $ExecutablePath }
    $configPath = $script:Config
    if ($LegacyMove) {
        $settings = Read-Json $script:Config; $null = $settings.Remove('capacityDefaultMigrationVersion')
        $configPath = Join-Path $script:CaseRoot 'legacy-config.json'; Save-Json $configPath $settings
    }
    $p = Start-Child $Arguments $binary $configPath
    try {
        $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync(); $p.StandardInput.Close()
        if (!$p.WaitForExit(180000)) { $p.Kill($true); $p.WaitForExit(); throw 'CLI timeout.' }
        $stdout = $out.GetAwaiter().GetResult(); $stderr = $err.GetAwaiter().GetResult()
        $script:Invocation++
        Save-Json (Join-Path $script:CaseRoot ('process-{0:D3}.json' -f $script:Invocation)) @{ executablePath = $binary; arguments = $Arguments; exitCode = $p.ExitCode; stdout = $stdout; stderr = $stderr }
        $json = if ($stdout.Trim()) { $stdout | ConvertFrom-Json -Depth 80 } else { $null }
        return @{ ExitCode = $p.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
    } finally { $p.Dispose() }
}
function New-Case([string]$Name) {
    $script:CaseRoot = Join-Path $OutputDirectory $Name; $null = [IO.Directory]::CreateDirectory($script:CaseRoot)
    foreach ($dir in @('temp','runtime-cache','metadata')) { $null = [IO.Directory]::CreateDirectory((Join-Path $script:CaseRoot $dir)) }
    $script:Config = Join-Path $script:CaseRoot 'config.json'; $script:Recovery = Join-Path $script:CaseRoot 'metadata'; $script:Invocation = 0
    $init = Invoke-RegistryCli @('init', '--backup-directory', $script:Recovery)
    Assert-True ($init.ExitCode -eq 0) "Init failed: $($init.Stderr)"
    $config = Read-Json $script:Config; $volumeStore = Join-Path $script:CaseRoot 'volume-store'; $config.volumeRecoveryDirectories = @{ (Get-VerificationVolumeRoot $volumeStore) = $volumeStore }; Save-Json $script:Config $config
    $migration = Invoke-RegistryCli @('migrate','--apply')
    Assert-True ($migration.ExitCode -eq 0 -and $migration.Json.registryReady -and $migration.Json.complete) 'Fresh registry namespace preparation failed.'
    $script:Relative = $runRelative + '\' + $Name; $script:Path = $fixtureHive + '\' + $script:Relative
}
function Case([string]$Name, [scriptblock]$Body, [switch]$RequiresMove) {
    if (!@($CaseFilter | Where-Object { $Name -like $_ }).Count) { $script:excluded++; return }
    if ($RequiresMove -and !$MoveExecutablePath) {
        $results.Add(@{ name = $Name; passed = $null; skipped = $true; note = 'MoveExecutablePath not supplied; mixed schema 4/5 retention was not verified.'; milliseconds = 0 }); return
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try { New-Case $Name; & $Body; $results.Add(@{ name = $Name; passed = $true; milliseconds = $timer.ElapsedMilliseconds }) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message; milliseconds = $timer.ElapsedMilliseconds }); Write-Warning "$Name : $($_.Exception.Message)" }
}
# 補助APIはfixture作成と観測に限る。拒否された削除を別APIで再試行しない。
$securityPrivilege = (Enable-RegistryFixtureSecurity)
Initialize-RegistryFixture $machineFixture $runRelative
$preflight = @()
foreach ($view in @(64,32)) {
    try { $preflight += (Test-RegistryFixtureKtm ($view)) }
    catch { $preflight += @{ View=$view; Available=$false; Stage='native preflight exception'; error=$_.Exception.Message; hresult=$_.Exception.HResult } }
}
if (@($preflight | Where-Object { !$_.Available }).Count) {
    # 読み取り専用の既存親接続に失敗した環境では、fixtureキーを一つも作らない。
    $presence = @(); $remaining = $null
    foreach ($view in @(64,32)) {
        try {
            $existing = (Open-RegistryFixtureKey ($runRelative) ($view))
            $exists = $null -ne $existing
            if ($existing) { $existing.Dispose(); $remaining = $runPath }
            $presence += @{ view=$view; exists=$exists; observed=$true }
        } catch { $presence += @{ view=$view; exists=$null; observed=$false; error=$_.Exception.Message }; $remaining=$runPath }
    }
    $reason = 'Read-only KTM preflight unavailable; no registry fixture creation was attempted. Registry behavior remains unverified in this process context.'
    Save-Json $ReportPath @{
        schema=1; timestampUtc=[DateTimeOffset]::UtcNow.ToString('O'); executablePath=$ExecutablePath; sameSourceBuild=$script:RegistryBuildBinding; rustProbePath=$RustProbePath; rustProbeSha256=$(if($RustProbePath){Digest $RustProbePath}else{$null}); moveExecutablePath=$MoveExecutablePath
        passed=0; failed=1; skipped=0; excludedCount=0; createdFixture=$false
        results=@(@{ name='read-only-ktm-preflight'; passed=$false; error=$reason; probes=$preflight })
        preflight=$preflight; securityPrivilegeEnabled=$securityPrivilege; registryFixtureRoot=$RegistryFixtureRoot
        registryFixture=$null; intendedRegistryFixture=$runPath; fixturePresence=$presence
        cleanup=@{ attempted=$false; remainingRegistryPath=$remaining; operations=@() }; retainedDirectory=$OutputDirectory
        unverified=@($reason)
    }
    [ordered]@{ passed=0; failed=1; skipped=0; createdFixture=$false; reportPath=$ReportPath; remainingRegistryPath=$remaining; error=$reason } | ConvertTo-Json
    exit 1
}
foreach ($view in @(32,64)) {
    $existing = (Open-RegistryFixtureKey ($runRelative) ($view))
    if ($existing) { $existing.Dispose(); throw 'Unique registry fixture already exists.' }
}
$fixture = (New-RegistryFixtureKey ($runRelative) (64)); $fixture.Dispose(); $createdFixture = $true
function Exists([string]$Relative = $script:Relative, [int]$View = 64) { $k = (Open-RegistryFixtureKey ($Relative) ($View)); if ($k) { $k.Dispose(); return $true }; return $false }
function Fixture([switch]$Tree, [int]$View = 64) {
    Assert-True (!(Exists $script:Relative $View)) 'Case fixture already exists.'
    $k = (New-RegistryFixtureKey ($script:Relative) ($View))
    try {
        foreach ($entry in @(
            @('',1,[Text.Encoding]::Unicode.GetBytes("default`0")), @('日本語😀',1,[Text.Encoding]::Unicode.GetBytes("文字`0")),
            @('none',0,[byte[]]@(0,255,1)), @('expand',2,[Text.Encoding]::Unicode.GetBytes("%TEMP%`0")),
            @('binary',3,[byte[]]@(0,1,128,255)), @('dword',4,[byte[]]@(0x78,0x56,0x34,0x12)),
            @('multi',7,[Text.Encoding]::Unicode.GetBytes("one`0日本語`0`0")), @('qword',11,[BitConverter]::GetBytes([uint64]0x123456789abcdef)),
            @('empty-binary',3,[byte[]]@()), @('empty-string',1,[byte[]]@())
        )) { (Set-RegistryFixtureValue ($k) ([string]$entry[0]) ([uint32]$entry[1]) ([byte[]]$entry[2])) }
        foreach ($name in $pathValueNames) { (Set-RegistryFixtureValue ($k) ($name) (1) ([Text.Encoding]::Unicode.GetBytes("fixture:$name`0"))) }
    } finally { $k.Dispose() }
    if ($Tree) { $child = (New-RegistryFixtureKey ($script:Relative+'\子\empty') ($View)); $child.Dispose() }
}
function Snapshot([int]$View = 64) { (Get-RegistryFixtureSnapshot ($script:Relative) ($View)) -join "`n" }
function Alias-Content([string]$State) { ($State -split '\|lastwrite:')[0] }
function Recovery-State { @(Get-ChildItem -LiteralPath $script:Recovery -Recurse -Force | Sort-Object FullName | ForEach-Object { if ($_.PSIsContainer) { $_.FullName+':directory' } else { $_.FullName+':'+(Digest $_.FullName) } }) -join "`n" }
function Delete-Registry([string[]]$Options = @('--recursive'), [int]$View = 64) {
    $r = Invoke-RegistryCli (@('registry-delete','--view',"$View")+$Options+@('--',$script:Path))
    Assert-True ($r.ExitCode -eq 0 -and $r.Json.operationId) "Registry delete failed: $($r.Stdout) $($r.Stderr)"
    $root = Join-Path (Join-Path $script:Recovery '.registry-records-v1') $r.Json.operationId
    return @{ Id = $r.Json.operationId; Root = $root; Manifest = (Join-Path $root 'registry-manifest.json'); Payload = (Join-Path $root 'registry-snapshot.json'); Result = $r.Json }
}
function Restore([object]$Op) { $r = Invoke-RegistryCli @('restore',$Op.Id); Assert-True ($r.ExitCode -eq 0) "Restore failed: $($r.Stdout) $($r.Stderr)"; return $r }
function Assert-Rejected([string[]]$Arguments) { $r = Invoke-RegistryCli $Arguments; Assert-True ($r.ExitCode -ne 0) "Unexpected accepted command: $Arguments" }
function Assert-PrivateRecoveryAcl([string]$Path, [switch]$Directory) {
    $acl = Get-Acl -LiteralPath $Path
    $sd = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $expected.Add($sid); $null = $expected.Add('S-1-5-18')
    $requiredFlags = [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent -bor [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected
    Assert-True ($sd.Owner.Value -ceq $sid -and ($sd.ControlFlags -band $requiredFlags) -eq $requiredFlags) "Recovery member owner or protected DACL incorrect: $Path"
    Assert-True ($null -ne $sd.DiscretionaryAcl -and $sd.DiscretionaryAcl.Count -eq $expected.Count) "Recovery member must grant only current user and SYSTEM: $Path"
    $aceFlags = if ($Directory) { [Security.AccessControl.AceFlags]::ObjectInherit -bor [Security.AccessControl.AceFlags]::ContainerInherit } else { [Security.AccessControl.AceFlags]::None }
    foreach ($ace in $sd.DiscretionaryAcl) {
        Assert-True ($ace -is [Security.AccessControl.CommonAce] -and !$ace.IsCallback -and $ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and $ace.AceFlags -eq $aceFlags -and $ace.AccessMask -eq [int][Security.AccessControl.FileSystemRights]::FullControl -and $expected.Remove($ace.SecurityIdentifier.Value)) "Recovery member contains an unexpected ACE: $Path"
    }
    Assert-True ($expected.Count -eq 0) "Recovery member omitted a private principal: $Path"
}
function Assert-RegistryOperationPrivateAcl([object]$Op, [switch]$Restored) {
    Assert-PrivateRecoveryAcl $Op.Root -Directory
    foreach ($name in @('registry-manifest.json','registry-delete-intent.json','registry-delete-complete.json','operation.lock')) {
        Assert-PrivateRecoveryAcl (Join-Path $Op.Root $name)
    }
    if ($Restored) {
        foreach ($name in @('registry-restore-intent.json','registry-restore-complete.json')) { Assert-PrivateRecoveryAcl (Join-Path $Op.Root $name) }
    } else { Assert-PrivateRecoveryAcl $Op.Payload }
}
Case 'key-recursive-raw-types-security-roundtrip' {
    Assert-True $securityPrivilege 'SeSecurityPrivilege unavailable; full key roundtrip was not verified.'
    Fixture -Tree; $before = Snapshot; $op = Delete-Registry
    Assert-True (!(Exists)) 'Deleted key remains.'
    Assert-True ($op.Result.items[0].kind -ceq 'registry-key') 'Wrong item kind.'
    Assert-RegistryOperationPrivateAcl $op
    $null = Restore $op; Assert-True ((Snapshot) -ceq $before) 'Raw registry tree or full security descriptor changed.'
    Assert-True (![IO.File]::Exists($op.Payload)) 'Restore did not consume snapshot.'
    Assert-RegistryOperationPrivateAcl $op -Restored
    $again = Restore $op; Assert-True (($again.Json | ConvertTo-Json -Depth 30) -match 'already_restored') 'Consumed restore not idempotent.'
}
Case 'key-mandatory-integrity-label-full-security-roundtrip' {
    Assert-True $securityPrivilege 'SeSecurityPrivilege unavailable; integrity-label roundtrip was not verified.'
    Fixture -Tree
    foreach ($relative in @($script:Relative,($script:Relative+'\子'),($script:Relative+'\子\empty'))) {
        # LABEL setterとWRITE_OWNERは、今回作成したsource fixtureの準備だけに使用する。
        (Set-RegistryFixtureLowIntegrity ($relative) (64))
        $key = (Open-RegistryFixtureKey ($relative) (64) ($true))
        try {
            $raw = [Convert]::FromBase64String((Get-RegistryFixtureSecurity ($key)))
            $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($raw,0)
            $labels = @($descriptor.SystemAcl | Where-Object { [int]$_.AceType -eq 17 })
            Assert-True ($labels.Count -eq 1) "Full registry security observation omitted the mandatory integrity label: $relative"
            # .NETはtype 17をCustomAceとして返すため、ACE header+mask後のSIDを直接読む。
            $labelBytes = [byte[]]::new($labels[0].BinaryLength); $labels[0].GetBinaryForm($labelBytes,0)
            $labelSid = [Security.Principal.SecurityIdentifier]::new($labelBytes,8)
            Assert-True ($labelSid.Value -ceq 'S-1-16-4096') "Fixture mandatory integrity label is not low integrity: $relative"
        } finally { $key.Dispose() }
    }
    $before = Snapshot; $op = Delete-Registry
    Assert-True (!(Exists)) 'Integrity-labeled registry source remains after delete.'
    Assert-RegistryOperationPrivateAcl $op
    $null = Restore $op
    Assert-True ((Snapshot) -ceq $before) 'Integrity label, full raw security, or raw values changed during registry roundtrip.'
    Assert-True (![IO.File]::Exists($op.Payload)) 'Integrity-label restore did not consume the snapshot.'
    Assert-RegistryOperationPrivateAcl $op -Restored
}
Case 'key-conflict-even-empty-refuses-and-retains-backup' {
    Fixture; $op = Delete-Registry; $hash = Digest $op.Payload
    $conflict = (New-RegistryFixtureKey ($script:Relative) (64)); $conflict.Dispose(); $before = Snapshot
    Assert-Rejected @('restore',$op.Id)
    Assert-True ((Snapshot) -ceq $before -and (Digest $op.Payload) -ceq $hash) 'Conflicting key or backup changed.'
}
foreach ($name in @('binary','日本語😀','') + $pathValueNames) {
    $valueName = $name
    $label = if (!$name) { 'default' } elseif ($name -eq 'binary') { 'named' } elseif ($name -eq '日本語😀') { 'unicode' } else { 'path-' + [array]::IndexOf($pathValueNames,$name) }
    Case "value-$label-roundtrip-preserves-parent-siblings-security" {
        Fixture; $before = Snapshot
        $op = Delete-Registry @('--value-name',$valueName)
        $k = (Open-RegistryFixtureKey ($script:Relative) (64) ($true))
        try { Assert-True ($null -eq (Get-RegistryFixtureValue ($k) ($valueName))) 'Selected value remains.' } finally { $k.Dispose() }
        $prefix = 'V::' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($valueName)) + ':'
        $expectedAfterDelete = (($before -split "`n" | Where-Object { !$_.StartsWith($prefix,[StringComparison]::Ordinal) }) -join "`n")
        Assert-True ((Snapshot) -ceq $expectedAfterDelete) 'Value delete changed siblings or parent security.'
        Assert-True ($op.Result.items[0].kind -ceq 'registry-value') 'Wrong value item kind.'
        $null = Restore $op; Assert-True ((Snapshot) -ceq $before) 'Value restore changed raw bytes, siblings, or parent ACL.'
        Assert-True (![IO.File]::Exists($op.Payload)) 'Value snapshot not consumed.'
    }
}
Case 'default-value-equals-form-and-existing-value-conflict' {
    Fixture; $op = Delete-Registry @('--value-name='); $hash = Digest $op.Payload
    $k = (New-RegistryFixtureKey ($script:Relative) (64))
    try { (Set-RegistryFixtureValue ($k) ('') (3) ([byte[]]@(99))) } finally { $k.Dispose() }
    $before = Snapshot; Assert-Rejected @('restore',$op.Id)
    Assert-True ((Snapshot) -ceq $before -and (Digest $op.Payload) -ceq $hash) 'Value conflict changed source or snapshot.'
}
Case 'identical-existing-value-still-refuses-restore' {
    Fixture; $name = $pathValueNames[0]; $op = Delete-Registry @('--value-name',$name); $hash = Digest $op.Payload
    $k = (New-RegistryFixtureKey ($script:Relative) (64))
    try { (Set-RegistryFixtureValue ($k) ($name) (1) ([Text.Encoding]::Unicode.GetBytes("fixture:$name`0"))) } finally { $k.Dispose() }
    $before = Snapshot; Assert-Rejected @('restore',$op.Id)
    Assert-True ((Snapshot) -ceq $before -and (Digest $op.Payload) -ceq $hash) 'Identical value conflict changed source or backup.'
}
Case 'value-parent-missing-refuses-and-backup-resumes' {
    Fixture; $before = Snapshot; $valueOp = Delete-Registry @('--value-name','binary')
    $keyOp = Delete-Registry; $hash = Digest $valueOp.Payload
    Assert-Rejected @('restore',$valueOp.Id)
    Assert-True (!(Exists) -and (Digest $valueOp.Payload) -ceq $hash) 'Missing-parent restore created parent or changed backup.'
    $null = Restore $keyOp; $null = Restore $valueOp
    Assert-True ((Snapshot) -ceq $before) 'Value restore failed after parent was restored.'
}
Case 'key-parent-missing-refuses-and-backup-resumes' {
    $parentRelative = $script:Relative; $parentPath = $script:Path
    $parent = (New-RegistryFixtureKey ($parentRelative) (64)); $parent.Dispose()
    $script:Relative += '\child'; $script:Path += '\child'; Fixture
    $before = Snapshot; $childOp = Delete-Registry; $hash = Digest $childOp.Payload
    $script:Relative = $parentRelative; $script:Path = $parentPath; $parentOp = Delete-Registry
    Assert-Rejected @('restore',$childOp.Id)
    Assert-True (!(Exists) -and (Digest $childOp.Payload) -ceq $hash) 'Missing-parent key restore changed source or backup.'
    $null = Restore $parentOp; $null = Restore $childOp
    $script:Relative += '\child'; $script:Path += '\child'
    Assert-True ((Snapshot) -ceq $before) 'Key restore failed after parent returned.'
}
Case 'dry-run-preserves-source-and-records' {
    Fixture -Tree; $before = Snapshot
    $recordBefore = @(Get-ChildItem -LiteralPath $script:Recovery -Recurse -File | ForEach-Object { $_.FullName+':'+(Digest $_.FullName) }) -join "`n"
    $r = Invoke-RegistryCli @('registry-delete','--view','64','--recursive','--dry-run','--',$script:Path)
    Assert-True ($r.ExitCode -eq 0 -and ($r.Stdout -match 'would_delete')) 'Dry run failed.'
    $recordAfter = @(Get-ChildItem -LiteralPath $script:Recovery -Recurse -File | ForEach-Object { $_.FullName+':'+(Digest $_.FullName) }) -join "`n"
    Assert-True ((Snapshot) -ceq $before -and $recordBefore -ceq $recordAfter) 'Dry run changed source or records.'
}
Case 'reject-invalid-root-relative-wildcard-options-and-nonrecursive' {
    Fixture -Tree; $before = Snapshot
    foreach ($path in @('HKCU','HKEY_CURRENT_USER','HKCR\Software\Probe','HKCC\Software\Probe','Software\Probe','Registry::Software\Probe','\\localhost\HKCU\Software\Probe',($script:Path+'\*'))) {
        Assert-Rejected @('registry-delete','--view','64','--recursive','--',$path)
    }
    Assert-Rejected @('registry-delete','--view','64','--',$script:Path)
    Assert-Rejected @('registry-delete','--recursive','--',$script:Path)
    Assert-Rejected @('registry-delete','--view','16','--',$script:Path)
    Assert-Rejected @('registry-delete','--view','64','--value-name','binary','--recursive','--',$script:Path)
    Assert-Rejected @('registry-delete','--view','64','--access-mode','unknown','--',$script:Path)
    Assert-Rejected @('registry-delete','--view','64','--access-mode','normal','--access-mode','backupRestore','--',$script:Path)
    Assert-Rejected @('registry-restore',('0'*32),'--access-mode','unknown')
    Assert-Rejected @('registry-restore',('0'*32),'--access-mode','normal','--access-mode','backupRestore')
    Assert-True ((Snapshot) -ceq $before) 'Rejected command changed fixture.'
}
Case 'provider-module-prefixes-accepted' {
    Fixture; $before = Snapshot
    foreach ($prefix in @('Registry::','Microsoft.PowerShell.Core\Registry::')) {
        $r = Invoke-RegistryCli @('registry-delete','--view','64','--dry-run','--',($prefix+$script:Path))
        Assert-True ($r.ExitCode -eq 0) "Provider prefix rejected: $prefix"
    }
    Assert-True ((Snapshot) -ceq $before) 'Provider dry run changed source.'
}
Case 'literal-colon-key-roundtrip' {
    $relative = $script:Relative; $path = $script:Path
    foreach ($name in @('C:#Program Files#Fixture.exe','C:%5CProgram Files%5CFixture.exe','C:#Program Files#Norton#Suite#NortonSvc.exe')) {
        $script:Relative = $relative + '\' + $name
        $script:Path = $path + '\' + $name
        Fixture; $before = Snapshot
        $op = Delete-Registry
        Assert-True (!(Exists)) 'Literal colon key was retained.'
        $null = Restore $op
        Assert-True ((Snapshot) -ceq $before) 'Literal colon key roundtrip changed source.'
    }
}
Case 'classes-alias-cli-values-and-direct-child-keys-both-views' {
    $aliasBefore = (Get-RegistryFixtureClassesAliasState)
    foreach ($view in @(32,64)) {
        $script:Relative = $classesRelative+'\cli'+$view; $script:Path = 'HKEY_CURRENT_USER\'+$script:Relative
        Fixture -Tree -View $view; $before = Snapshot $view
        Assert-True (((Get-RegistryFixtureClassesBackingSnapshot $script:Relative $view) -join "`n") -ceq $before) 'Classes alias and direct SID_Classes backing disagree.'
        $sourceBefore = (Get-RegistryFixtureClassesAliasState); $recordsBefore = Recovery-State
        $r = Invoke-RegistryCli @('registry-delete','--view',"$view",'--value-name',$pathValueNames[0],'--dry-run','--',$script:Path)
        Assert-True ($r.ExitCode -eq 0 -and (Snapshot $view) -ceq $before -and (Get-RegistryFixtureClassesAliasState) -ceq $sourceBefore -and (Recovery-State) -ceq $recordsBefore) 'Classes dry-run changed alias bytes, complete ACL, last-write time, fixture, or metadata.'
        foreach ($name in $pathValueNames) {
            $op = Delete-Registry @('--value-name',$name) $view
            $prefix = 'V::'+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($name))+':'
            $expected = (($before -split "`n" | Where-Object { !$_.StartsWith($prefix,[StringComparison]::Ordinal) }) -join "`n")
            Assert-True ((Snapshot $view) -ceq $expected) 'Classes value delete changed sibling values, child keys, or complete parent ACL.'
            $null = Restore $op
            Assert-True ((Snapshot $view) -ceq $before -and ((Get-RegistryFixtureClassesBackingSnapshot $script:Relative $view) -join "`n") -ceq $before) 'Classes value restore changed literal names, types, raw bytes, siblings, or security.'
        }
        $name = $pathValueNames[0]; $op = Delete-Registry @('--value-name',$name) $view; $hash = Digest $op.Payload
        $k = (New-RegistryFixtureKey ($script:Relative) ($view))
        try { (Set-RegistryFixtureValue ($k) ($name) (1) ([Text.Encoding]::Unicode.GetBytes("fixture:$name`0"))) } finally { $k.Dispose() }
        Assert-Rejected @('restore',$op.Id)
        Assert-True ((Snapshot $view) -ceq $before -and (Digest $op.Payload) -ceq $hash) 'Classes value restore conflict changed source or snapshot.'
    }
    foreach ($view in @(32,64)) {
        $script:Relative = $classesRelative; $script:Path = 'HKEY_CURRENT_USER\'+$classesRelative; $before = Snapshot $view
        $op = Delete-Registry @('--recursive') $view
        Assert-True (!(Exists $script:Relative $view)) 'Direct Classes child key remains after CLI delete.'
        $null = Restore $op
        Assert-True ((Snapshot $view) -ceq $before -and ((Get-RegistryFixtureClassesBackingSnapshot $script:Relative $view) -join "`n") -ceq $before) 'Direct Classes child restore changed raw tree or complete security.'
    }
    Assert-True ((Alias-Content ((Get-RegistryFixtureClassesAliasState))) -ceq (Alias-Content $aliasBefore)) 'Classes operation changed real ancestor link bytes or complete ACL.'
}
Case 'volatile-registry-links-and-link-like-value-refused' {
    # リンク拒否後は削除APIを付け替えない。専用volatile rootだけをログオフ/再起動まで保持する。
    Assert-True (!(Exists $linkRelative)) 'Unique volatile link probe already exists.'
    $root = (New-RegistryFixtureVolatile ($linkRelative)); $root.Dispose(); $script:createdLinkFixture = $true
    $targetRelative = $linkRelative + '\target'
    $target = (New-RegistryFixtureVolatile ($targetRelative))
    try { (Set-RegistryFixtureValue ($target) ('sentinel') (3) ([byte[]]@(42,0,255))) } finally { $target.Dispose() }
    $child = (New-RegistryFixtureVolatile ($targetRelative+'\child')); $child.Dispose()
    $before = (Get-RegistryFixtureSnapshot ($targetRelative) (64)) -join "`n"
    (New-RegistryFixtureLink ($linkRelative+'\link') ($targetRelative))
    Assert-True (((Get-RegistryFixtureSnapshot ($linkRelative+'\link') (64)) -join "`n") -ceq $before) 'Probe link does not resolve to its fixture target.'
    foreach ($suffix in @('\link','\link\child')) {
        $r = Invoke-RegistryCli @('registry-delete','--view','64','--recursive','--dry-run','--',($fixtureHive+'\'+$linkRelative+$suffix))
        Assert-True ($r.ExitCode -ne 0 -and ($r.Stdout+$r.Stderr) -match 'Registry link or link-like key') 'Actual link was not rejected by the link guard.'
        Assert-True (((Get-RegistryFixtureSnapshot ($targetRelative) (64)) -join "`n") -ceq $before) 'Rejected link probe changed target.'
    }
    $ordinaryRelative = $linkRelative+'\ordinary'
    $ordinary = (New-RegistryFixtureVolatile ($ordinaryRelative))
    $nativePrefix = if ($machineFixture) { '\Registry\Machine\' } else { '\Registry\User\'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'\' }
    try {
        (Set-RegistryFixtureValue ($ordinary) ('SymbolicLinkValue') (6) ([Text.Encoding]::Unicode.GetBytes($nativePrefix+$targetRelative)))
        (Set-RegistryFixtureValue ($ordinary) ('ordinary-sentinel') (3) ([byte[]]@(17,18)))
    } finally { $ordinary.Dispose() }
    $ordinaryBefore = (Get-RegistryFixtureSnapshot ($ordinaryRelative) (64)) -join "`n"
    $r = Invoke-RegistryCli @('registry-delete','--view','64','--recursive','--dry-run','--',($fixtureHive+'\'+$ordinaryRelative))
    Assert-True ($r.ExitCode -ne 0 -and ($r.Stdout+$r.Stderr) -match 'Registry link or link-like key') 'Ordinary REG_LINK value was not rejected by the link guard.'
    Assert-True (((Get-RegistryFixtureSnapshot ($ordinaryRelative) (64)) -join "`n") -ceq $ordinaryBefore) 'Rejected REG_LINK value probe changed ordinary key.'
}

if ($RustProbePath) {
    Case 'core-classes-alias-proof-permission-and-staged-commit-conflict' {
        $evidence=Invoke-RustNativeContract 'classes-alias-guard' $runPath
        Assert-True ($evidence.result.retainedVolatileLinkRoot -ceq ($fixtureHive+'\'+$linkRelative)) 'Rust probe volatile link root escaped the owned sibling'
        $script:createdLinkFixture=$true
        Save-Json (Join-Path $script:CaseRoot 'classes-guard-evidence.json') $evidence
    }
    Case 'core-incomplete-links-cannot-be-used-as-ordinary-keys' {
        $evidence=Invoke-RustNativeContract 'incomplete-links' $runPath
        Assert-True ($evidence.result.retainedVolatileLinkRoot -ceq ($fixtureHive+'\'+$linkRelative)) 'Rust probe volatile link root escaped the owned sibling'
        $script:createdLinkFixture=$true
        Save-Json (Join-Path $script:CaseRoot 'incomplete-link-evidence.json') $evidence
    }
    Case 'core-snapshot-publication-fault-rolls-back-staged-value' {
        $evidence=Invoke-RustNativeContract 'snapshot-publication-rollback' $runPath
        # このprobeはリンク領域ではなく、固定した通常fixture直下の新規GUID子だけを使う。
        Assert-True ($evidence.result.fixture -cmatch ('\A'+[regex]::Escape($runPath+'\rust-publication-fault-')+'[0-9a-f]{32}\z')) 'Rust publication probe escaped the owned fixture child'
        $metadataParent=Join-Path $script:CaseRoot 'temp'
        Assert-True ($evidence.result.metadataFixture -cmatch ('\A'+[regex]::Escape($metadataParent+'\registry-publication-fault-')+'[0-9a-f]{32}\\registry-snapshot\.json\z')) 'Rust publication metadata escaped the owned temporary child'
        $proof=$evidence.result.evidence
        Assert-True ($proof.realTransactionStaged -eq $true -and $proof.actualPersistedBytesCorrupted -eq $true -and $proof.nativeCommitCalled -eq $false -and $proof.originalRegistryRawBytesAndFullSecurityPreserved -eq $true -and $proof.privateAclFromCreation -eq $true -and $proof.expectedSha256 -cmatch '\A[0-9a-f]{64}\z' -and $proof.actualSha256 -cmatch '\A[0-9a-f]{64}\z' -and $proof.expectedSha256 -cne $proof.actualSha256) 'Rust publication rollback did not establish the native transaction and preservation proof'
        Save-Json (Join-Path $script:CaseRoot 'staged-publication-rollback-evidence.json') $evidence
    }
}
Case 'explicit-views-do-not-touch-distinct-other-view' {
    Fixture -View 64; $before64 = Snapshot 64
    # SYSTEMとHKCU\Softwareの共有viewでは、同名の別fixtureを作って上書きしない。
    $shared = Exists $script:Relative 32
    if (!$shared) { Fixture -View 32; $before32 = Snapshot 32 }
    $op = Delete-Registry @('--value-name','binary') 64
    if (!$shared) { Assert-True ((Snapshot 32) -ceq $before32) '64-bit delete changed distinct 32-bit view.' }
    $null = Restore $op; Assert-True ((Snapshot 64) -ceq $before64) 'View 64 roundtrip changed source.'
    $op32 = Delete-Registry @('--value-name','binary') 32; $null = Restore $op32
    Assert-True ((Snapshot 32) -ceq $(if ($shared) { $before64 } else { $before32 })) 'View 32 roundtrip changed source.'
    Save-Json (Join-Path $script:CaseRoot 'view-observation.json') @{ registryFixtureRoot = $RegistryFixtureRoot; sharedViewsObserved = $shared; distinctViewIsolationVerified = (!$shared -and !$machineFixture); isolationStatus = $(if ($machineFixture) { 'not-verified-SYSTEM-shared-view' } elseif ($shared) { 'not-verified-shared-view' } else { 'verified-distinct-views' }) }
}
foreach ($mode in @('snapshot-hash','unknown-metadata','snapshot-ads','snapshot-acl','receipt-schema-string','pending-delete','pending-restore')) {
    $tamper = $mode
    Case "reject-$mode-retain-backup" {
        Fixture; $op = Delete-Registry
        Assert-RegistryOperationPrivateAcl $op
        switch ($tamper) {
            'snapshot-hash' { [IO.File]::AppendAllText($op.Payload,' ', $utf8) }
            'unknown-metadata' { $m = Read-Json $op.Manifest; $m.unrecognized = $true; Save-Json $op.Manifest $m }
            'snapshot-ads' { [IO.File]::WriteAllText($op.Payload+':unexpected','tampered',$utf8) }
            'snapshot-acl' {
                Assert-PrivateRecoveryAcl $op.Payload
                $acl = Get-Acl -LiteralPath $op.Payload
                $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone,[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))
                Set-Acl -LiteralPath $op.Payload -AclObject $acl
                $rules = (Get-Acl -LiteralPath $op.Payload).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
                Assert-True (@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' -and $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow }).Count -gt 0) 'Snapshot ACL tamper fixture did not add Everyone Read.'
                $config = Read-Json $script:Config; $config.maxRecoveryBytes = 1; Save-Json $script:Config $config
            }
            'receipt-schema-string' {
                $complete = Join-Path $op.Root 'registry-delete-complete.json'
                $receipt = Read-Json $complete; $receipt.schema = '5'; Save-Json $complete $receipt
                Assert-True ((Read-Json $complete).schema -is [string]) 'Receipt fixture did not retain a JSON string schema.'
                # 整理対象になる予算を指定し、単に若い記録だから残る場合と区別する。
                $config = Read-Json $script:Config; $config.maxRecoveryBytes = 1; Save-Json $script:Config $config
            }
            'pending-delete' {
                $complete = Join-Path $op.Root 'registry-delete-complete.json'
                [IO.File]::Move($complete,(Join-Path $script:CaseRoot 'retained-delete-complete.json'))
            }
            'pending-restore' {
                $intentPath = Join-Path $op.Root 'registry-restore-intent.json'
                Save-Json $intentPath @{ schema = 5; operationId = $op.Id; manifestSha256 = (Digest $op.Manifest); action = 'restore'; phase = 'intent'; createdUtc = [DateTimeOffset]::UtcNow.ToString('O') }
                # 再構成fixtureも製品のprivate ACLへ揃え、ACL拒否が中断状態の検証を横取りしない。
                Set-Acl -LiteralPath $intentPath -AclObject (Get-Acl -LiteralPath $op.Manifest)
                Assert-PrivateRecoveryAcl $intentPath
            }
        }
        $hash = Digest $op.Payload
        $rejected = Invoke-RegistryCli @('restore',$op.Id)
        Assert-True ($rejected.ExitCode -ne 0) 'Unsafe recovery operation unexpectedly restored.'
        if ($tamper -like 'pending-*') { Assert-True (($rejected.Stdout + $rejected.Stderr) -match '(?i)ambiguous|unconfirmed') 'Pending fixture was refused for a reason other than ambiguous transaction state.' }
        Assert-True (!(Exists) -and [IO.File]::Exists($op.Payload) -and (Digest $op.Payload) -ceq $hash) 'Unsafe restore changed source or backup.'
        $maintenance = Invoke-RegistryCli @('maintain','--apply')
        Assert-True ([IO.File]::Exists($op.Payload) -and (Digest $op.Payload) -ceq $hash) 'Automatic maintenance discarded unsafe backup.'
        if ($tamper -in @('receipt-schema-string','snapshot-acl')) {
            Assert-True ($maintenance.ExitCode -ne 0 -and $maintenance.Json.capacityKnown -eq $false -and ($maintenance.Json.warnings -join "`n").Contains($op.Id)) 'Maintenance accepted unsafe recovery metadata or failed to identify the retained operation.'
            Assert-True (!(Exists)) 'Maintenance recreated a deleted registry key.'
        }
        if ($tamper -like 'pending-*' -or $tamper -in @('receipt-schema-string','snapshot-acl')) {
            Assert-Rejected @('purge',$op.Id,'--apply')
            Assert-True (!(Exists) -and [IO.File]::Exists($op.Payload) -and (Digest $op.Payload) -ceq $hash) 'Purge changed the source or unsafe backup.'
        }
    }
}
Case 'operations-explicit-purge-and-expiry' {
    Fixture; $op = Delete-Registry
    $operations = Invoke-RegistryCli @('operations')
    Assert-True ($operations.ExitCode -eq 0 -and $operations.Stdout.Contains($op.Id)) 'Registry operation omitted from operations.'
    $preview = Invoke-RegistryCli @('purge',$op.Id)
    Assert-True ([IO.File]::Exists($op.Payload)) 'Purge without apply consumed backup.'
    $purged = Invoke-RegistryCli @('purge',$op.Id,'--apply')
    Assert-True ($purged.ExitCode -eq 0 -and ![IO.File]::Exists($op.Payload)) 'Explicit purge failed.'
    Fixture; $old = Delete-Registry
    $m = Read-Json $old.Manifest; $m.createdUtc = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O'); Save-Json $old.Manifest $m
    foreach ($file in Get-ChildItem -LiteralPath $old.Root -Filter 'registry-*-*.json' -File) {
        $receipt = Read-Json $file.FullName
        if ($receipt.ContainsKey('manifestSha256')) { $receipt.manifestSha256 = Digest $old.Manifest; Save-Json $file.FullName $receipt }
    }
    $maintained = Invoke-RegistryCli @('maintain','--apply')
    Assert-True ($maintained.ExitCode -eq 0 -and ![IO.File]::Exists($old.Payload)) 'Expired registry backup not maintained.'
    Assert-True ([IO.File]::Exists($old.Manifest)) 'Expiry removed operation metadata.'
}
Case 'uncommitted-before-intent-is-known-capacity-and-purgeable' {
    # 正式intentの公開前に中断した記録を、実削除の記録からdelete receiptを退避して再現する。
    # 分類はreceiptの構成だけで決まり、現在のregistryキーの有無からcommitを推測しないことも確認する。
    Fixture; $op = Delete-Registry
    foreach ($phase in @('complete','intent')) {
        [IO.File]::Move((Join-Path $op.Root "registry-delete-$phase.json"), (Join-Path $script:CaseRoot "retained-delete-$phase.json"))
    }
    $hash = Digest $op.Payload
    $reconcile = Invoke-RegistryCli @('registry-reconcile',$op.Id)
    Assert-True ($reconcile.ExitCode -eq 0 -and $reconcile.Json.items[0].status -ceq 'not_committed') "Uncommitted record was not reconciled as not_committed: $($reconcile.Stdout) $($reconcile.Stderr)"
    $operations = Invoke-RegistryCli @('operations')
    Assert-True ($operations.ExitCode -eq 0 -and @($operations.Json.operations | Where-Object { $_.operationId -ceq $op.Id -and $_.lifecycleState -ceq 'not_committed' }).Count -eq 1) 'Uncommitted record was not listed as not_committed.'
    $rejected = Invoke-RegistryCli @('restore',$op.Id)
    Assert-True ($rejected.ExitCode -ne 0 -and ($rejected.Stdout + $rejected.Stderr) -match 'not committed') 'Uncommitted record was not refused for its not-committed state.'
    Assert-True (!(Exists) -and [IO.File]::Exists($op.Payload) -and (Digest $op.Payload) -ceq $hash) 'Uncommitted restore refusal changed the source or snapshot.'
    # 以前は容量不明として以後の全registry-deleteを拒否していた。未commit記録は既知容量として数える。
    Fixture; $second = Delete-Registry
    Assert-True ([IO.File]::Exists($op.Payload) -and (Digest $op.Payload) -ceq $hash) 'Delete capacity gate discarded the retained uncommitted snapshot.'
    $purged = Invoke-RegistryCli @('purge',$op.Id,'--apply')
    Assert-True ($purged.ExitCode -eq 0 -and $purged.Json.items[0].status -ceq 'purged' -and ![IO.Directory]::Exists($op.Root)) "Uncommitted record was not purged: $($purged.Stdout) $($purged.Stderr)"
    $maintained = Invoke-RegistryCli @('maintain','--apply')
    Assert-True ($maintained.ExitCode -eq 0 -and $maintained.Json.capacityKnown -and [IO.File]::Exists($second.Payload)) 'Maintenance after uncommitted purge was incomplete.'
    $null = Restore $second
}
Case 'capacity-single-oversized-then-normal-budget' {
    $config = Read-Json $script:Config; $config.maxRecoveryBytes = 1; Save-Json $script:Config $config
    Fixture; $first = Delete-Registry
    Assert-True ([IO.File]::Exists($first.Payload)) 'Single oversized registry operation was not retained.'
    Fixture; $second = Delete-Registry
    Assert-True (![IO.File]::Exists($first.Payload) -and [IO.File]::Exists($second.Payload)) 'Next operation did not resume retention budget.'
    $maintained = Invoke-RegistryCli @('maintain','--apply')
    Assert-True ($maintained.ExitCode -eq 0 -and ![IO.File]::Exists($second.Payload)) 'Maintenance retained previous oversized exception.'
}
Case 'recordless-files-excluded-from-registry-capacity-and-restore-type-guards' {
    . (Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1')
    $script:observed = @{}
    $fileScope = $script:CaseRoot
    if ($FixtureRoot) {
        $script:fileFixtureRun = New-VerificationFixtureRun -FixtureRoot $FixtureRoot -ForbiddenRoots @($repoRoot,$codexRoot) -NamePrefix 'registry-files'
        $fileScope = $script:fileFixtureRun.directory
    }
    $file = Join-Path $fileScope 'mixed-file.bin'; [IO.File]::WriteAllBytes($file,[byte[]](0..255)*16)
    $fileBefore = Get-FileFixtureSnapshot -Path $file
    $priorPidls = [string[]]@(Find-FileFixtureBinIdentity -ExpectedId $fileBefore[0].Id | ForEach-Object Pidl)
    Fixture; $registryBefore = Snapshot
    $deleted = Invoke-RegistryCli @('delete','--',$file)
    Assert-True ($deleted.ExitCode -eq 0 -and !$deleted.Json.PSObject.Properties['operationId'] -and $deleted.Json.items[0].status -ceq 'recycled' -and ![IO.File]::Exists($file)) 'Current file deletion must recycle without an operation record.'
    $bin = Find-FileFixtureBinNew -ExpectedId $fileBefore[0].Id -PriorPidls $priorPidls
    $binBefore = Get-FileFixtureSnapshot -Path $bin.PhysicalPath
    $registryOp = Delete-Registry; $registryHash = Digest $registryOp.Payload; $registryBytes = [IO.FileInfo]::new($registryOp.Payload).Length
    foreach ($mode in @('--dry-run','--apply')) {
        $config = Read-Json $script:Config; $config.maxRecoveryBytes = $registryBytes; Save-Json $script:Config $config
        $inspection = Invoke-RegistryCli @('maintain',$mode)
        Assert-True ($inspection.ExitCode -eq 0 -and $inspection.Json.capacityKnown -and $inspection.Json.retainedBytesBefore -eq $registryBytes -and $inspection.Json.retainedBytesAfter -eq $registryBytes) 'Registry capacity included Windows-managed file bytes.'
        Assert-True ((Digest $registryOp.Payload) -ceq $registryHash -and ![IO.File]::Exists($file)) 'Registry-only retention changed either source or snapshot.'
        $binAfter = Get-FileFixtureSnapshot -Path $bin.PhysicalPath
        Assert-True (($binAfter | ConvertTo-Json -Depth 20 -Compress) -ceq ($binBefore | ConvertTo-Json -Depth 20 -Compress)) 'Registry maintenance changed owned Bin native data/security.'
    }
    $p = Start-Child @('mcp'); $completed = $false
    try {
        $stderrTask = $p.StandardError.ReadToEndAsync()
        function Mixed-Rpc([object]$Request) {
            $p.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 30 -Compress)); $p.StandardInput.Flush()
            for ($i=0; $i -lt 64; $i++) { $read=$p.StandardOutput.ReadLineAsync(); if(!$read.Wait(15000)){throw 'Mixed MCP timeout'}; $line=$read.GetAwaiter().GetResult(); if(!$line){throw 'Mixed MCP EOF'}; $reply=$line|ConvertFrom-Json -Depth 80; if($reply.id-eq$Request.id){return $reply} }; throw 'Too many mixed MCP notifications.'
        }
        $init=Mixed-Rpc @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='registry-only-capacity';version='1'}}};Assert-True ($null-ne$init.result) 'Mixed MCP init failed'
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');$p.StandardInput.Flush()
        $removed=Mixed-Rpc @{jsonrpc='2.0';id=2;method='tools/call';params=@{name='restore_files';arguments=@{operationId=$registryOp.Id}}}
        Assert-True ($removed.error -or $removed.result.isError) 'Removed file restore tool is still callable.'
        Assert-True ((Digest $registryOp.Payload)-ceq$registryHash-and!(Exists)) 'Removed tool changed registry backup/source.'
        $restored=Mixed-Rpc @{jsonrpc='2.0';id=3;method='tools/call';params=@{name='restore_registry';arguments=@{operationId=$registryOp.Id}}}
        Assert-True (!$restored.result.isError-and(Snapshot)-ceq$registryBefore-and![IO.File]::Exists($registryOp.Payload)) 'Registry non-overwrite restore changed raw data/security.'
        $p.StandardInput.Close();Assert-True ($p.WaitForExit(30000)-and$p.ExitCode-eq0) 'Mixed MCP shutdown failed';$completed=$true
    } finally {if(!$p.HasExited){$p.Kill($true);$p.WaitForExit()};if($stderrTask){$null=$stderrTask.GetAwaiter().GetResult()};$p.Dispose()}
    $null = Restore-WindowsVerbR $bin $file $fileScope
    $after = Assert-SnapshotR $file $fileBefore -WindowsManagedRestore
    Save-Json (Join-Path $script:CaseRoot 'windows-file-restore.json') @{
        policy = 'Windows standard Restore verb; native identity, attributes and all stream bytes are compared; Windows-managed O/G/D is observed.'
        route = $script:observed.restoreRoute; before = $fileBefore; bin = $binBefore; restored = $after
    }
    $empty=Invoke-RegistryCli @('maintain','--dry-run');Assert-True ($empty.ExitCode-eq0-and$empty.Json.retainedBytesBefore-eq0) 'Consumed registry snapshot remains in capacity.'
}
Case 'backup-restore-protected-cli-mcp-key-value-roundtrip' {
    $privileges = Start-ProtectedFixturePrivileges
    $root = $null; $p = $null
    function Protected-Rpc([object]$Request, [string]$Raw) {
        $line = if ($Raw) { $Raw } else { $Request | ConvertTo-Json -Depth 30 -Compress }
        $p.StandardInput.WriteLine($line); $p.StandardInput.Flush()
        for ($index=0; $index -lt 64; $index++) {
            $read=$p.StandardOutput.ReadLineAsync(); if (!$read.Wait(15000)) { throw 'Protected MCP response timeout.' }
            $reply=$read.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 80
            if ($reply.id -eq $Request.id) {
                Save-Json (Join-Path $script:CaseRoot ('protected-rpc-'+$Request.id+'.json')) @{request=$line;response=$reply}
                return $reply
            }
        }
        throw 'Protected MCP response was not received.'
    }
    function Protected-Call([string]$Operation, [hashtable]$Arguments) {
        if ($protocol -eq 'cli') {
            if ($Operation -eq 'delete_registry') {
                $command=@('registry-delete','--view','64','--access-mode',$Arguments.accessMode)
                if ($Arguments.ContainsKey('valueName')) { $command+=@('--value-name='+$Arguments.valueName) }
                if ($Arguments.recursive) { $command+='--recursive' }; if ($Arguments.dryRun) { $command+='--dry-run' }
                $command+=@('--',$Arguments.path)
            } else { $command=@('registry-restore',$Arguments.operationId,'--access-mode',$Arguments.accessMode) }
            $response=Invoke-RegistryCli $command; return @{ ok=($response.ExitCode -eq 0); data=$response.Json }
        }
        $script:protectedRpcId++
        $reply=Protected-Rpc @{ jsonrpc='2.0'; id=$script:protectedRpcId; method='tools/call'; params=@{name=$Operation;arguments=$Arguments} }
        return @{ ok=(!$reply.error -and !$reply.result.isError); data=$reply.result.structuredContent }
    }
    try {
        foreach ($protocol in @('cli','mcp')) {
            $parentRelative=$script:Relative+'\'+$protocol; $parent=(New-RegistryFixtureKey ($parentRelative) (64))
            $relative=$parentRelative+'\restricted'; $path=$fixtureHive+'\'+$relative
            $target=(New-RegistryFixtureWithClass ($relative) (('protected '+$protocol+' 日本語 class')))
            $child=(New-RegistryFixtureWithClass ($relative+'\child') ('protected child class'))
            $backup=$null; $originalDacl=$null
            try {
                (Set-RegistryFixtureValue ($parent) ('sentinel') (3) ([byte[]]@(99,0,254)))
                (Set-RegistryFixtureValue ($target) ('sentinel') (3) ([byte[]]@(0,1,128,255)))
                (Set-RegistryFixtureValue ($target) ('') (3) ([byte[]]@(7,0,255)))
                (Set-RegistryFixtureValue ($child) ('sentinel') (11) ([BitConverter]::GetBytes([uint64]0x123456789abcdef)))
                $originalDacl=(Get-RegistryFixtureDacl ($relative) ($target))
                $childSecurityOpen=Open-ProtectedFixtureKey $null $target.Handle 'child' 4 $false ([uint32]0x010F013F)
                try { $childSecurity=[Convert]::ToBase64String((Get-ProtectedFixtureSecurity $childSecurityOpen.Handle)) }
                finally { $childSecurityOpen.Dispose() }
                $childValue=(Get-RegistryFixtureValue ($child) ('sentinel')); $child.Dispose(); $child=$null
                (Set-ProtectedFixtureRestriction ($target.Handle))
                $backup=(Open-ProtectedFixtureKey ($null) ($parent.Handle) ('restricted') (4) ($false) ([uint32]0x010F013F))
                Assert-True ($backup.Error -eq 0) 'Protected observation open failed.'
                $security=[Convert]::ToBase64String((Get-ProtectedFixtureSecurity ($backup.Handle)))
                $value=(Get-ProtectedFixtureValue ($backup.Handle) ('')); $class=(Get-ProtectedFixtureClass ($backup.Handle))
                if ($protocol -eq 'mcp') {
                    $privileges.Dispose(); Assert-True $privileges.Restored 'Observer privileges were not restored before MCP launch.'
                    $p=Start-Child @('mcp'); $stderrTask=$p.StandardError.ReadToEndAsync(); $script:protectedRpcId=100
                    $processBefore=(Get-ProtectedFixtureProcessPrivileges ([uint32]$p.Id))
                    $privileges=Start-ProtectedFixturePrivileges
                    $initialized=Protected-Rpc @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='protected-registry-e2e';version='1'}}}
                    Assert-True ($null -ne $initialized.result) 'Protected MCP initialization failed.'
                    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $p.StandardInput.Flush()
                    $invalid=Protected-Rpc @{jsonrpc='2.0';id=2;method='tools/call';params=@{name='delete_registry';arguments=@{path=$path;view='64';accessMode='unknown'}}}
                    Assert-True ($invalid.error.code -eq -32602) ('Unknown MCP mode did not return invalid-params: '+($invalid|ConvertTo-Json -Depth 10 -Compress))
                    $duplicate='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"restore_registry","arguments":{"operationId":"'+('0'*32)+'","accessMode":"normal","accessMode":"backupRestore"}}}'
                    $invalid=Protected-Rpc @{id=3} $duplicate
                    Assert-True ($invalid.error.code -eq -32602) ('Duplicate MCP mode did not return invalid-params: '+($invalid|ConvertTo-Json -Depth 10 -Compress))
                }
                $normal=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';dryRun=$true;accessMode='normal'}
                Assert-True (!$normal.ok) 'Normal access unexpectedly bypassed the deny ACL.'
                $records=Recovery-State; $lastWrite=(Get-RegistryFixtureLastWrite ($target))
                $normalKey=Protected-Call 'delete_registry' @{path=$path;view='64';recursive=$true;dryRun=$true;accessMode='normal'}
                Assert-True (!$normalKey.ok -and (Recovery-State) -ceq $records -and (Get-RegistryFixtureLastWrite ($target)) -eq $lastWrite -and [Convert]::ToBase64String((Get-ProtectedFixtureSecurity ($backup.Handle))) -ceq $security) 'Normal key access bypassed the deny ACL or changed the source.'
                $dry=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';dryRun=$true;accessMode='backupRestore'}
                Assert-True ($dry.ok -and $dry.data.items[0].status -eq 'would_delete' -and (Recovery-State) -ceq $records -and (Get-RegistryFixtureLastWrite ($target)) -eq $lastWrite) 'Protected dry-run failed or changed data/records/timestamp.'
                $deleted=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';accessMode='backupRestore'}
                Assert-True ($deleted.ok -and $deleted.data.operationId) 'Protected value deletion failed.'
                $id=$deleted.data.operationId; $payload=Join-Path (Join-Path (Join-Path $script:Recovery '.registry-records-v1') $id) 'registry-snapshot.json'; $hash=Digest $payload
                $normal=Protected-Call 'restore_registry' @{operationId=$id;accessMode='normal'}
                Assert-True (!$normal.ok -and (Digest $payload) -ceq $hash) 'Restore silently remembered the deletion access mode.'
                (Set-RegistryFixtureValue ($target) ('') (3) ([byte[]]@()))
                $conflict=Protected-Call 'restore_registry' @{operationId=$id;accessMode='backupRestore'}
                Assert-True (!$conflict.ok -and (Digest $payload) -ceq $hash -and (Get-ProtectedFixtureValue ($backup.Handle) ('')) -ceq '3:') 'Protected restore overwrote an existing empty default value.'
                $null=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';accessMode='backupRestore'}
                $restored=Protected-Call 'restore_registry' @{operationId=$id;accessMode='backupRestore'}
                Assert-True ($restored.ok -and (Get-ProtectedFixtureValue ($backup.Handle) ('')) -ceq $value -and [Convert]::ToBase64String((Get-ProtectedFixtureSecurity ($backup.Handle))) -ceq $security) 'Protected value roundtrip changed raw bytes or parent ACL.'
                $normal=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';dryRun=$true;accessMode='normal'}
                Assert-True (!$normal.ok) 'A later normal MCP request inherited backup/restore access.'
                $backup.Dispose();$backup=$null;$target.Dispose();$target=$null
                $deleted=Protected-Call 'delete_registry' @{path=$path;view='64';recursive=$true;accessMode='backupRestore'}
                Assert-True ($deleted.ok -and $deleted.data.operationId) 'Protected key deletion failed.'
                $keyPayload=Read-Json (Join-Path (Join-Path (Join-Path $script:Recovery '.registry-records-v1') $deleted.data.operationId) 'registry-snapshot.json')
                Assert-True ($keyPayload.schema -eq 5 -and $keyPayload.keys[0].class -ceq $class -and !$keyPayload.ContainsKey('accessMode')) 'Protected snapshot schema/class contract changed.'
                $restored=Protected-Call 'restore_registry' @{operationId=$deleted.data.operationId;accessMode='backupRestore'}
                Assert-True $restored.ok 'Protected key restoration failed.'
                $backup=(Open-ProtectedFixtureKey ($null) ($parent.Handle) ('restricted') (4) ($false) ([uint32]0x010F013F))
                Assert-True ($backup.Error -eq 0 -and (Get-ProtectedFixtureClass ($backup.Handle)) -ceq $class -and (Get-ProtectedFixtureValue ($backup.Handle) ('')) -ceq $value -and [Convert]::ToBase64String((Get-ProtectedFixtureSecurity ($backup.Handle))) -ceq $security) 'Protected key class/raw/full ACL roundtrip failed.'
                $childOpen=(Open-ProtectedFixtureKey ($null) ($backup.Handle) ('child') (4) ($false) ([uint32]0x010F013F))
                try { Assert-True ($childOpen.Error -eq 0 -and (Get-ProtectedFixtureValue ($childOpen.Handle) ('sentinel')) -ceq $childValue -and [Convert]::ToBase64String((Get-ProtectedFixtureSecurity ($childOpen.Handle))) -ceq $childSecurity -and (Get-RegistryFixtureValue ($parent) ('sentinel')) -ceq '3:YwD+') 'Child/sibling raw or complete security changed.' }
                finally { $childOpen.Dispose() }
                if ($protocol -eq 'mcp') {
                    $processAfter=(Get-ProtectedFixtureProcessPrivileges ([uint32]$p.Id))
                    foreach ($name in $processBefore.Keys) { Assert-True ($processBefore[$name] -ceq $processAfter[$name]) "MCP process-token privilege changed: $name" }
                    Save-Json (Join-Path $script:CaseRoot 'protected-mcp-token-attributes.json') @{before=$processBefore;after=$processAfter}
                }
            } finally {
                if ($p) { $p.StandardInput.Close(); if (!$p.WaitForExit(15000)) {$p.Kill($true)}; $p.Dispose(); $p=$null }
                if ($backup) {
                    try { if ($originalDacl) { Restore-ProtectedFixtureDacl -Lease $backup.Handle -Relative $relative -Security $originalDacl } } finally { $backup.Dispose() }
                } elseif ($target -and $originalDacl) { (Restore-RegistryFixtureDacl ($relative) ($target) ($originalDacl)) }
                if ($target) {$target.Dispose()}; if ($child) {$child.Dispose()}; $parent.Dispose()
            }
        }
    } finally {
        if ($root) {$root.Dispose()}; $privileges.Dispose()
        Assert-True $privileges.Restored 'Protected test host privilege attributes were not restored.'
    }
}
Case 'mcp-schema-errors-roundtrip-and-iserror' {
    Fixture; $before = Snapshot; $p = Start-Child @('mcp')
    try {
        $stderrTask = $p.StandardError.ReadToEndAsync()
        function Rpc([object]$Request) {
            $p.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 30 -Compress)); $p.StandardInput.Flush()
            for ($i=0; $i -lt 64; $i++) {
                $task = $p.StandardOutput.ReadLineAsync(); if (!$task.Wait(15000)) { throw 'MCP response timeout.' }
                $line = $task.GetAwaiter().GetResult(); if (!$line) { throw 'MCP output closed.' }
                $reply = $line | ConvertFrom-Json -Depth 80
                if ($reply.id -eq $Request.id) { return $reply }
            }; throw 'Too many MCP notifications.'
        }
        $init = Rpc @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'registry-recovery-e2e'; version = '1' } } }
        Assert-True ($null -ne $init.result) 'MCP initialize failed.'
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $p.StandardInput.Flush()
        $list = Rpc @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
        $names = @($list.result.tools.name)
        Assert-True ($names.Count -eq 5 -and $names -contains 'delete_files' -and $names -notcontains 'restore_files' -and $names -contains 'delete_registry' -and $names -contains 'restore_registry' -and $names -contains 'reconcile_registry' -and $names -contains 'list_operations' -and !($names -match 'purge')) 'MCP tool contract changed.'
        $reconcileTool = $list.result.tools | Where-Object name -EQ 'reconcile_registry'
        Assert-True ($reconcileTool.annotations.readOnlyHint -and $reconcileTool.annotations.idempotentHint -and !$reconcileTool.inputSchema.additionalProperties -and @($reconcileTool.inputSchema.required) -contains 'operationId') 'Registry reconciliation must advertise a strict read-only schema.'
        $tool = $list.result.tools | Where-Object name -EQ 'delete_registry'
        Assert-True (@($tool.inputSchema.required) -contains 'view' -and @($tool.inputSchema.properties.view.enum).Count -eq 2 -and @($tool.inputSchema.properties.view.enum) -contains '32' -and @($tool.inputSchema.properties.view.enum) -contains '64') 'Registry MCP view schema missing.'
        $rpcId = 3
        foreach ($arguments in @(@{path=$script:Path},@{path=$script:Path;view='16'},@{path=$script:Path;view=64},@{path=$script:Path;view='64';recursive='yes'},@{path=$script:Path;view='64';unknown=1})) {
            $reply = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'delete_registry'; arguments = $arguments } }
            Assert-True ($reply.error -or $reply.result.isError) 'Invalid MCP arguments accepted.'
            Assert-True ((Snapshot) -ceq $before) 'Invalid MCP changed fixture.'
        }
        $failed = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'delete_registry'; arguments = @{ path = 'HKEY_CURRENT_USER'; view = '64' } } }
        Assert-True ($failed.result.isError) 'MCP domain failure did not set isError.'
        $dry = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'delete_registry'; arguments = @{ path = $script:Path; view = '64'; recursive = $true; dryRun = $true } } }
        Assert-True (!$dry.result.isError -and (Snapshot) -ceq $before) 'MCP dry run changed source.'
        $deleted = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'delete_registry'; arguments = @{ path = $script:Path; view = '64'; recursive = $true } } }
        Assert-True (!$deleted.result.isError -and !(Exists)) 'MCP delete failed.'
        $id = $deleted.result.structuredContent.operationId
        $operationDirectory = Join-Path (Join-Path $script:Recovery '.registry-records-v1') $id
        $metadataBefore = @(Get-ChildItem -LiteralPath $operationDirectory -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Digest $_.FullName) }) -join "`n"
        $reconciled = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'reconcile_registry'; arguments = @{ operationId = $id } } }
        $metadataAfter = @(Get-ChildItem -LiteralPath $operationDirectory -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Digest $_.FullName) }) -join "`n"
        Assert-True (!$reconciled.result.isError -and $reconciled.result.structuredContent.dryRun -and $reconciled.result.structuredContent.items[0].kind -ceq 'registry-key' -and !(Exists) -and $metadataBefore -ceq $metadataAfter) 'MCP reconciliation changed registry/metadata or lost its registry kind.'
        $restored = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'restore_registry'; arguments = @{ operationId = $id } } }
        Assert-True (!$restored.result.isError -and (Snapshot) -ceq $before) 'MCP roundtrip changed raw tree or ACL.'
        foreach ($name in $pathValueNames) {
            $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view='64'; valueName=$name } } }
            Assert-True (!$deleted.result.isError -and $deleted.result.structuredContent.items[0].kind -ceq 'registry-value') 'MCP path-shaped value delete failed.'
            $valueId = $deleted.result.structuredContent.operationId
            $prefix = 'V::' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($name)) + ':'
            $expected = (($before -split "`n" | Where-Object { !$_.StartsWith($prefix,[StringComparison]::Ordinal) }) -join "`n")
            Assert-True ((Snapshot) -ceq $expected) 'MCP path-shaped value delete changed siblings or complete security.'
            $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$valueId } } }
            Assert-True (!$reply.result.isError -and (Snapshot) -ceq $before) 'MCP path-shaped value restore changed literal names, bytes, siblings, or security.'
        }
        # 同じ値が復元先へ再作成されても、MCPは上書きせずsnapshotを残す。
        $name = $pathValueNames[0]
        $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view='64'; valueName=$name } } }
        Assert-True (!$deleted.result.isError) 'MCP conflict setup delete failed.'
        $valueId = $deleted.result.structuredContent.operationId
        $payload = Join-Path (Join-Path (Join-Path $script:Recovery '.registry-records-v1') $valueId) 'registry-snapshot.json'; $hash = Digest $payload
        $k = (New-RegistryFixtureKey ($script:Relative) (64))
        try { (Set-RegistryFixtureValue ($k) ($name) (1) ([Text.Encoding]::Unicode.GetBytes("fixture:$name`0"))) } finally { $k.Dispose() }
        $conflictBefore = Snapshot
        $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$valueId } } }
        Assert-True ($reply.result.isError -and (Snapshot) -ceq $conflictBefore -and (Digest $payload) -ceq $hash) 'MCP value conflict changed source or snapshot.'
        $aliasBefore = (Get-RegistryFixtureClassesAliasState)
        foreach ($view in @(32,64)) {
            $script:Relative = $classesRelative+'\mcp'+$view; $script:Path = 'HKEY_CURRENT_USER\'+$script:Relative
            Fixture -Tree -View $view; $before = Snapshot $view
            $sourceBefore = (Get-RegistryFixtureClassesAliasState); $recordsBefore = Recovery-State
            $dry = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; valueName=$pathValueNames[0]; dryRun=$true } } }
            Assert-True (!$dry.result.isError -and (Snapshot $view) -ceq $before -and (Get-RegistryFixtureClassesAliasState) -ceq $sourceBefore -and (Recovery-State) -ceq $recordsBefore) 'MCP Classes dry-run changed ancestor timestamp, raw bytes, full ACL, target, or metadata.'
            foreach ($name in $pathValueNames) {
                $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; valueName=$name } } }
                Assert-True (!$deleted.result.isError -and $deleted.result.structuredContent.items[0].kind -ceq 'registry-value') 'MCP Classes value delete failed.'
                $valueId = $deleted.result.structuredContent.operationId
                $prefix = 'V::'+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($name))+':'
                $expected = (($before -split "`n" | Where-Object { !$_.StartsWith($prefix,[StringComparison]::Ordinal) }) -join "`n")
                Assert-True ((Snapshot $view) -ceq $expected) 'MCP Classes value delete changed siblings or full security.'
                $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$valueId } } }
                Assert-True (!$reply.result.isError -and (Snapshot $view) -ceq $before -and ((Get-RegistryFixtureClassesBackingSnapshot $script:Relative $view) -join "`n") -ceq $before) 'MCP Classes restore changed path-shaped names, raw bytes, siblings, or full ACL.'
            }
            $name = $pathValueNames[0]
            $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; valueName=$name } } }
            Assert-True (!$deleted.result.isError) 'MCP Classes conflict setup failed.'
            $valueId = $deleted.result.structuredContent.operationId
            $payload = Join-Path (Join-Path (Join-Path $script:Recovery '.registry-records-v1') $valueId) 'registry-snapshot.json'; $hash = Digest $payload
            $k = (New-RegistryFixtureKey ($script:Relative) ($view))
            try { (Set-RegistryFixtureValue ($k) ($name) (1) ([Text.Encoding]::Unicode.GetBytes("fixture:$name`0"))) } finally { $k.Dispose() }
            $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$valueId } } }
            Assert-True ($reply.result.isError -and (Snapshot $view) -ceq $before -and (Digest $payload) -ceq $hash) 'MCP Classes conflict changed original or snapshot.'
            $script:Relative = $classesRelative; $script:Path = 'HKEY_CURRENT_USER\'+$classesRelative; $beforeRoot = Snapshot $view
            $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; recursive=$true } } }
            Assert-True (!$deleted.result.isError -and !(Exists $script:Relative $view)) 'MCP direct Classes child delete failed.'
            $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$deleted.result.structuredContent.operationId } } }
            Assert-True (!$reply.result.isError -and (Snapshot $view) -ceq $beforeRoot) 'MCP direct Classes child key restore changed tree or full ACL.'
        }
        Assert-True ((Alias-Content ((Get-RegistryFixtureClassesAliasState))) -ceq (Alias-Content $aliasBefore)) 'MCP Classes operations changed ancestor raw link bytes or full ACL.'
        $mcpCompleted = $true
    } finally {
        $p.StandardInput.Close()
        if (!$p.WaitForExit(15000)) { $p.Kill($true); $p.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'mcp.stderr.txt'),$stderrTask.GetAwaiter().GetResult(),$utf8)
        $exitCode = $p.ExitCode
        $p.Dispose()
        if ($mcpCompleted) { Assert-True ($exitCode -eq 0) "MCP process failed at shutdown: $exitCode" }
    }
}
. (Join-Path $PSScriptRoot 'registry-session-e2e/RegistryControlCases.ps1')
if (!$results.Count) { $results.Add(@{ name='case-filter-matched-no-cases'; passed=$false; error='CaseFilter matched no cases.' }) }
# 固定sourceが変わった場合、候補の同一性を主張せずfixtureも保持する。
$bindingValid=$true
if($RustProbePath){try{Assert-RegistryRustBinding}catch{$bindingValid=$false;$results.Add(@{name='same-source-build-binding';passed=$false;error=$_.Exception.Message})}}
# 清掃も今回exeを一度だけ利用する。拒否は別APIへ付け替えず残存パスを報告する。
$cleanup = @{ attempted = $false; remainingRegistryPath = $runPath; remainingClassesPath = 'HKEY_CURRENT_USER\'+$classesRelative; retainedVolatileLinkPath = $(if ($createdLinkFixture) { $fixtureHive+'\'+$linkRelative } else { $null }); operations = @() }
if ($createdFixture -and $bindingValid) {
    try {
        New-Case 'fixture-cleanup'
        $cleanup.attempted = $true
        foreach ($view in @(64,32)) {
            if (!(Exists $runRelative $view)) { continue }
            $r = Invoke-RegistryCli @('registry-delete','--view',"$view",'--recursive','--',$runPath)
            $cleanup.operations += @{ view = $view; exitCode = $r.ExitCode; operationId = $r.Json.operationId }
            if ($r.ExitCode -ne 0) { $cleanup.error = 'Prunlet refused fixture cleanup; no alternative deletion attempted.'; break }
        }
        if (!(Exists $runRelative 64) -and !(Exists $runRelative 32)) { $cleanup.remainingRegistryPath = $null }
        foreach ($view in @(64,32)) {
            if (!(Exists $classesRelative $view)) { continue }
            $r = Invoke-RegistryCli @('registry-delete','--view',"$view",'--recursive','--',$cleanup.remainingClassesPath)
            $cleanup.operations += @{ path=$cleanup.remainingClassesPath; view=$view; exitCode=$r.ExitCode; operationId=$r.Json.operationId }
            if ($r.ExitCode -ne 0) { $cleanup.error='Prunlet refused Classes fixture cleanup; no alternative deletion attempted.'; break }
        }
        if (!(Exists $classesRelative 64) -and !(Exists $classesRelative 32)) { $cleanup.remainingClassesPath = $null }
    } catch { $cleanup.error = $_.Exception.Message }
}
if($RustProbePath -and $bindingValid){try{Assert-RegistryRustBinding}catch{$results.Add(@{name='same-source-build-binding-final';passed=$false;error=$_.Exception.Message})}}
$passed = @($results | Where-Object passed).Count; $skipped = @($results | Where-Object skipped).Count; $failed = $results.Count - $passed - $skipped
$unverified = @('Actual OS Classes alias destination swaps are not performed; the production guard/commit race and source rename/replacement are probed only on dedicated volatile links. Exact privilege-deficient token behavior requires separate native probes.','KTM crash timing requires separate integration probes.','Distinct WOW64 view isolation requires separate views; shared views do not verify isolation. See view-observation.json.')
if (!@($results | Where-Object { $_.name -eq 'volatile-registry-links-and-link-like-value-refused' -and $_.passed }).Count) { $unverified += 'Actual target/ancestor registry link and ordinary REG_LINK value rejection was not verified because its case was excluded or failed.' }
if (!@($results | Where-Object { $_.name -eq 'core-classes-alias-proof-permission-and-staged-commit-conflict' -and $_.passed }).Count) { $unverified += 'Production Classes alias guard, SetValue denial, dry-run no-write, and staged-target rollback after the final check were not verified; supply the actual candidate RustProbePath and include its case.' }
if (!@($results | Where-Object { $_.name -eq 'classes-alias-cli-values-and-direct-child-keys-both-views' -and $_.passed }).Count -or !@($results | Where-Object { $_.name -eq 'mcp-schema-errors-roundtrip-and-iserror' -and $_.passed }).Count) { $unverified += 'Classes descendant CLI/MCP values and direct-child keys in both views were not fully verified.' }
if (!@($results | Where-Object { $_.name -eq 'recordless-files-excluded-from-registry-capacity-and-restore-type-guards' -and $_.passed }).Count) { $unverified += 'Windows-managed file exclusion from registry retention was not verified because its case was excluded, skipped, or failed.' }
if ($machineFixture) { $unverified += 'Normal HKCU roundtrip was not verified by this HKLM SYSTEM run; HKCU ERROR_RM_NOT_ACTIVE preservation requires a separate probe.' }
Save-Json $ReportPath @{ schema=1; fileFixtureRun=$script:fileFixtureRun; timestampUtc=[DateTimeOffset]::UtcNow.ToString('O'); executablePath=$ExecutablePath; sameSourceBuild=$script:RegistryBuildBinding; rustProbePath=$RustProbePath; rustProbeSha256=$(if($RustProbePath){Digest $RustProbePath}else{$null}); moveExecutablePath=$MoveExecutablePath; passed=$passed; failed=$failed; skipped=$skipped; excludedCount=$excluded; results=@($results); preflight=$preflight; createdFixture=$createdFixture; securityPrivilegeEnabled=$securityPrivilege; registryFixtureRoot=$RegistryFixtureRoot; registryFixture=$runPath; cleanup=$cleanup; retainedDirectory=$OutputDirectory; unverified=$unverified }
[ordered]@{ passed=$passed; failed=$failed; skipped=$skipped; excludedCount=$excluded; reportPath=$ReportPath; remainingRegistryPath=$cleanup.remainingRegistryPath; remainingClassesPath=$cleanup.remainingClassesPath; retainedVolatileLinkPath=$cleanup.retainedVolatileLinkPath } | ConvertTo-Json
if ($failed) { exit 1 }; exit 0
