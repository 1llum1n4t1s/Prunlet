[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [string]$LegacyExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$Large,
    [string]$SecondaryVolumeDirectory,
    [ValidateNotNullOrEmpty()][string[]]$CaseFilter = @('*'),
    [ValidateRange(1, 3600)][int]$ProcessTimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
# 想定する失敗（実装前に列挙）:
# ・木を展開してコピーしID/ACL/ADS/属性を失う、子の容量を数えない、非再帰で非空の木を消す。
# ・dry-runで記録や領域を作る、リンク先や外部hardlink名へ変更を波及する。
# ・既存の復元先を上書きする、消費済みpayloadを再利用する、改竄されたID/JSONを信頼する。
# ・不正な領域/ACL/volumeを受理する、領域自身やその親を削除する。
# ・期限/容量順序/単一超過の一時予算を誤る、旧schema 1/2/3を復元/整理できない。
# ・並行した削除がそれぞれ同じ空き容量を予約し、合計で上限を超える。
# ・移動完了receipt不在や復元intent後の再開で同一オブジェクトを失う。
# ・整理途中の欠けた木を復元済みと誤認する、中央記録のない退避データを容量から落とす。
# ・CLI以外のMCP/フック経路が旧削除へ漏れる、大量の木で旧件数上限へ戻る。
# ・filterの誤記や旧exe未指定を合格と誤表示し、未実施ケースを見落とす。
# ・子のロックによる拒否後に未cancel記録が容量検査を阻害し、解放後の削除まで失敗する。
# ・Archiveなし属性のrenameで属性が変わる、外部hardlink別名へ属性変更が波及する。
# ・WriteAttributes拒否時に先に移動してしまい、元対象/属性/別名を失う。
# ・複数volumeを一方のstoreへ集約し、ID・属性・非上書き・消費型復元を壊す。
# ・schema 4の履歴を未対応の圧縮経路へ通し、manifestやpayloadを変更する。
# 中断fixtureは有効な記録と移動済みの位置を再現する。原子APIの時刻kill試験ではない。
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($ExecutablePath, $LegacyExecutablePath, $OutputDirectory, $ReportPath) | Where-Object { $_ }) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Executable/output/report paths must be absolute.' }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
if ($LegacyExecutablePath) { $LegacyExecutablePath = [IO.Path]::GetFullPath($LegacyExecutablePath) }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$fixtureDrive = [IO.Path]::GetPathRoot($outputRoot)
$isGitHubActions = $env:GITHUB_ACTIONS -ceq 'true'
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
foreach ($path in @($outputRoot, $ReportPath)) {
    Assert-VerificationDestination $path @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if (!$isGitHubActions -and ![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Local volume-move verification requires D: output.' }
    if (Test-Path -LiteralPath $path) { throw 'OutputDirectory and ReportPath must be new.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create each external output/report parent first.' }
}
foreach ($path in @($ExecutablePath, $LegacyExecutablePath) | Where-Object { $_ }) { if (![IO.File]::Exists($path)) { throw "Executable missing: $path" } }
if ($SecondaryVolumeDirectory) {
    if ($SecondaryVolumeDirectory -notmatch '^[A-Za-z]:\\' -or ![IO.Path]::IsPathFullyQualified($SecondaryVolumeDirectory)) { throw 'SecondaryVolumeDirectory must be an absolute local drive path.' }
    $SecondaryVolumeDirectory = [IO.Path]::GetFullPath($SecondaryVolumeDirectory)
    $secondaryDriveRoot = [IO.Path]::GetPathRoot($SecondaryVolumeDirectory)
    if ($secondaryDriveRoot.Equals($fixtureDrive, [StringComparison]::OrdinalIgnoreCase)) { throw 'SecondaryVolumeDirectory must use a volume different from OutputDirectory.' }
    $drive = [IO.DriveInfo]::new($secondaryDriveRoot)
    if (!$drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'SecondaryVolumeDirectory must use a ready local fixed drive.' }
    Assert-VerificationDestination $SecondaryVolumeDirectory @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if (Test-Path -LiteralPath $SecondaryVolumeDirectory) { throw 'SecondaryVolumeDirectory must be new; existing data must never be reused.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($SecondaryVolumeDirectory))) { throw 'SecondaryVolumeDirectory parent must exist.' }
}
$null = [IO.Directory]::CreateDirectory($outputRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()
$script:SelectedCount = 0; $script:ExcludedCount = 0
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 80), $utf8) }
function Read-Json([string]$Path) { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 80 }
function Digest([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function New-Directory([string]$Path) { $null = [IO.Directory]::CreateDirectory($Path); return $Path }
function Start-Child([string]$Exe, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8; $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    $info.WorkingDirectory = $script:CaseRoot
    $info.Environment['TEMP'] = Join-Path $script:CaseRoot 'temp'
    $info.Environment['TMP'] = Join-Path $script:CaseRoot 'temp'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $script:CaseRoot 'runtime-cache'
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start(); return $process
}
function Invoke-Child([string]$Exe, [string[]]$Arguments, [string]$InputText = '', [switch]$Raw) {
    $process = Start-Child $Exe $Arguments
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.Write($InputText) }; $process.StandardInput.Close()
        if (!$process.WaitForExit($ProcessTimeoutSeconds * 1000)) { $process.Kill($true); $process.WaitForExit(); throw 'Subprocess timeout.' }
        $stdout = $outTask.GetAwaiter().GetResult(); $stderr = $errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $script:InvocationIndex++
            $prefix = Join-Path $script:CaseRoot ('rejected-{0:D3}' -f $script:InvocationIndex)
            [IO.File]::WriteAllText($prefix + '.stdout.txt', $stdout, $utf8)
            [IO.File]::WriteAllText($prefix + '.stderr.txt', $stderr, $utf8)
            Save-Json ($prefix + '.process.json') @{ executable = $Exe; arguments = $Arguments; exitCode = $process.ExitCode }
        }
        $json = if (!$Raw -and $stdout.Trim()) { $stdout | ConvertFrom-Json -Depth 80 } else { $null }
        return @{ ExitCode = $process.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
    } finally { $process.Dispose() }
}
function Invoke-VolumeCli([string[]]$Arguments, [switch]$Legacy) {
    $exe = if ($Legacy) { $LegacyExecutablePath } else { $ExecutablePath }
    $config = if ($Legacy) { $script:LegacyConfig } else { $script:Config }
    return Invoke-Child $exe (@('--config', $config) + $Arguments)
}
function New-Case([string]$Name) {
    $script:InvocationIndex = 0
    $script:CaseRoot = New-Directory (Join-Path $outputRoot $Name)
    $script:Scope = New-Directory (Join-Path $script:CaseRoot 'scope')
    $script:Recovery = New-Directory (Join-Path $script:CaseRoot 'metadata')
    $null = New-Directory (Join-Path $script:CaseRoot 'temp')
    $null = New-Directory (Join-Path $script:CaseRoot 'runtime-cache')
    $script:Store = Join-Path $script:CaseRoot 'volume-store'
    $script:Config = Join-Path $script:CaseRoot 'config.json'
    $script:LegacyConfig = Join-Path $script:CaseRoot 'legacy-config.json'
    # initはmetadataだけを作る。map設定前にcandidateの削除を絶対に実行しない。
    $init = Invoke-VolumeCli @('init', '--backup-directory', $script:Recovery)
    Assert-True ($init.ExitCode -eq 0) "Init failed: $($init.Stderr)"
    $config = Read-Json $script:Config
    $config.volumeRecoveryDirectories = @{ $fixtureDrive = $script:Store }
    Save-Json $script:Config $config
    $legacy = @{} + $config; $null = $legacy.Remove('volumeRecoveryDirectories')
    Save-Json $script:LegacyConfig $legacy
}
function Test-Case([string]$Name, [scriptblock]$Body, [switch]$RequiresLegacy) {
    if (!@($CaseFilter | Where-Object { $Name -like $_ }).Count) { $script:ExcludedCount++; return }
    $script:SelectedCount++
    if ($RequiresLegacy -and !$LegacyExecutablePath) {
        $results.Add(@{ name = $Name; passed = $null; skipped = $true; note = 'LegacyExecutablePath not supplied; schema 1/2/3 compatibility was not verified.'; milliseconds = 0 })
        return
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $script:CaseNote = $null
    try { New-Case $Name; & $Body; $results.Add(@{ name = $Name; passed = $(if ($script:CaseNote) { $null } else { $true }); skipped = [bool]$script:CaseNote; note = $script:CaseNote; milliseconds = $timer.Elapsed.TotalMilliseconds }) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message; milliseconds = $timer.Elapsed.TotalMilliseconds }); Write-Warning "$Name : $($_.Exception.Message)" }
}
function New-File([string]$Name, [int]$Bytes = 64) {
    $path = Join-Path $script:Scope $Name
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $data = [byte[]]::new($Bytes); for ($i = 0; $i -lt $Bytes; $i++) { $data[$i] = $i % 251 }
    [IO.File]::WriteAllBytes($path, $data); return $path
}
function File-Id([string]$Path) {
    if (!('PrunletVolumeMoveVerificationIdentity' -as [type])) {
        $previousTemp = $env:TEMP; $previousTmp = $env:TMP
        try {
            $env:TEMP = Join-Path $script:CaseRoot 'temp'; $env:TMP = $env:TEMP
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PrunletVolumeMoveVerificationIdentity {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int kind, byte[] data, uint size);
    public static string Read(string path) {
        using (var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] data = new byte[24];
            if (!GetFileInformationByHandleEx(handle, 18, data, 24)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return BitConverter.ToString(data).Replace("-", "");
        }
    }
    public static bool IsCaseSensitive(string path) {
        using (var handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] data = new byte[4];
            if (!GetFileInformationByHandleEx(handle, 23, data, 4)) return false;
            return (BitConverter.ToUInt32(data, 0) & 1) != 0;
        }
    }
    public static bool CanOpenForDelete(string path) {
        using (var handle = CreateFileW(path, 0x10000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) return !handle.IsInvalid;
    }
    public static bool CanOpenForAttributeWrite(string path) {
        using (var handle = CreateFileW(path, 0x100, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) return !handle.IsInvalid;
    }
    public static SafeFileHandle OpenAttributeWriter(string path) {
        var handle = CreateFileW(path, 0x100, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
        return handle;
    }
    public static void WriteAttributes(SafeFileHandle handle, uint attributes) {
        byte[] basic = new byte[40];
        Array.Copy(BitConverter.GetBytes(attributes), 0, basic, 32, 4);
        if (!SetFileInformationByHandle(handle, 0, basic, 40)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
        } finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
    }
    return [PrunletVolumeMoveVerificationIdentity]::Read($Path)
}
function Acl-Permissions($Acl) {
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Acl.GetSecurityDescriptorBinaryForm(), 0)
    $identity = $descriptor.Owner.Value + '|' + $descriptor.Group.Value
    $dacl = $descriptor.DiscretionaryAcl
    if ($null -eq $dacl) { return $identity + '|null-dacl' }
    $allowOnly = !@($dacl | Where-Object { $_.AceType -ne [Security.AccessControl.AceType]::AccessAllowed }).Count
    foreach ($ace in $dacl) {
        $ace.AceFlags = [Security.AccessControl.AceFlags]([int]$ace.AceFlags -band (-bnot [int][Security.AccessControl.AceFlags]::Inherited))
    }
    if ($allowOnly) {
        # 継承ACEの明示化後と同じ標準APIで、分割・重複したAllowを統合する。
        # 主体・権利・継承範囲・伝播を保持し、Owner/Groupとnull DACLも区別する。
        $normalized = [Security.AccessControl.DiscretionaryAcl]::new($true, $false, $dacl)
        $rules = @($normalized | ForEach-Object {
            '{0}|{1}|{2}|{3}' -f $_.SecurityIdentifier.Value, $_.AccessMask, $_.InheritanceFlags, $_.PropagationFlags
        } | Sort-Object)
        return $identity + '|allow|' + ($rules -join ';')
    }
    # Denyや未知のACEは順序を維持し、継承元を示すflag以外の全bytesを照合する。
    $rules = @($dacl | ForEach-Object {
        $bytes = [byte[]]::new($_.BinaryLength); $_.GetBinaryForm($bytes, 0)
        [Convert]::ToBase64String($bytes)
    })
    return $identity + '|ordered|' + ($rules -join ';')
}
function Snapshot-Tree([string]$Path) {
    $root = Get-Item -LiteralPath $Path -Force
    $snapshotRoot = $root.FullName
    $entries = @($root); if ($root.PSIsContainer) { $entries += @(Get-ChildItem -LiteralPath $snapshotRoot -Force -Recurse) }
    return @($entries | ForEach-Object {
        Assert-True (!(($_.Attributes -band [IO.FileAttributes]::ReparsePoint))) 'Use ordinary trees for full snapshots.'
        $acl = Get-Acl -LiteralPath $_.FullName
        @{ relative = $_.FullName.Substring($snapshotRoot.Length); id = File-Id $_.FullName; attributes = [int]$_.Attributes
           sddl = $acl.Sddl; permissions = $(if ($_.FullName -ceq $snapshotRoot) { Acl-Permissions $acl } else { $null })
           hash = $(if (!$_.PSIsContainer) { Digest $_.FullName } else { $null }) }
    })
}
function Assert-Tree([string]$Path, [object[]]$Snapshot, [switch]$MovedRoot) {
    $count = 1; if ([IO.Directory]::Exists($Path)) { $count += @(Get-ChildItem -LiteralPath $Path -Force -Recurse).Count }
    Assert-True ($count -eq $Snapshot.Count) 'Tree entry count changed.'
    foreach ($entry in $Snapshot) {
        $actual = $Path + $entry.relative
        Assert-True ((File-Id $actual) -ceq $entry.id) "FileID changed: $actual"
        Assert-True ([int][IO.File]::GetAttributes($actual) -eq $entry.attributes) "Attributes changed: $actual"
        $actualAcl = Get-Acl -LiteralPath $actual
        if ($MovedRoot -and !$entry.relative) {
            # Windowsは移動した木のrootで継承ACEを明示化する。主体・権利・伝播は全て照合する。
            $actualPermissions = Acl-Permissions $actualAcl
            Assert-True ($actualPermissions -ceq $entry.permissions) "ACL permissions changed: $actual; expectedPermissions=$($entry.permissions); actualPermissions=$actualPermissions; expectedSddl=$($entry.sddl); actualSddl=$($actualAcl.Sddl)"
        } else {
            Assert-True ($actualAcl.Sddl -ceq $entry.sddl) "ACL changed: $actual; expected=$($entry.sddl); actual=$($actualAcl.Sddl)"
        }
        if ($entry.hash) { Assert-True ((Digest $actual) -ceq $entry.hash) "Content changed: $actual" }
    }
}
function Delete-Entry([string]$Path, [switch]$Recursive) {
    $arguments = @('delete'); if ($Recursive) { $arguments += '--recursive' }; $arguments += @('--', $Path)
    $deleted = Invoke-VolumeCli $arguments
    Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $Path)) "Delete failed: $($deleted.Stderr) $($deleted.Json | ConvertTo-Json -Depth 5 -Compress)"
    $id = $deleted.Json.operationId
    $root = Join-Path $script:Recovery $id
    $manifestPath = Join-Path $root 'move-manifest.json'
    $manifest = Read-Json $manifestPath
    Assert-True ($manifest.schema -eq 4 -and $manifest.entries.Count -eq 1) 'New delete must store one schema 4 input entry.'
    $entry = $manifest.entries[0]
    $payload = Join-Path (Join-Path $entry.storeRoot $id) $entry.payloadName
    Assert-True ($payload.StartsWith($script:Store + '\', [StringComparison]::OrdinalIgnoreCase)) 'Payload escaped configured volume store.'
    Assert-True ($entry.payloadName -ceq '0000.entry' -and (Test-Path -LiteralPath $payload)) 'Input payload missing.'
    Assert-True (!(Test-Path -LiteralPath (Join-Path $root 'manifest.json'))) 'New delete used legacy copy manifest.'
    return @{ Id = $id; Root = $root; ManifestPath = $manifestPath; Manifest = $manifest; Payload = $payload; Result = $deleted.Json }
}
function Restore-Entry([object]$Operation, [string]$Path) {
    $result = Invoke-VolumeCli @('restore', $Operation.Id)
    Assert-True ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $Path) -and !(Test-Path -LiteralPath $Operation.Payload)) "Restore failed: $($result.Stderr)"
}
function Set-Policy([long]$Bytes = 10737418240, [int]$Days = 7) {
    $config = Read-Json $script:Config; $config.maxRecoveryBytes = $Bytes; $config.retentionDays = $Days; Save-Json $script:Config $config
}
function Rebind-Receipts([object]$Operation) {
    foreach ($file in Get-ChildItem -LiteralPath $Operation.Root -File -Filter '*.json') {
        if ($file.Name -match '^(move|restore|purge)-\d{4}-(intent|complete)\.json$') {
            $receipt = Read-Json $file.FullName; $receipt.manifestSha256 = Digest $Operation.ManifestPath; Save-Json $file.FullName $receipt
        }
    }
}
function Set-Age([object]$Operation, [int]$Days) {
    $manifest = Read-Json $Operation.ManifestPath; $manifest.createdUtc = [DateTimeOffset]::UtcNow.AddDays(-$Days).ToString('O')
    Save-Json $Operation.ManifestPath $manifest; Rebind-Receipts $Operation
}
function Assert-RejectedRestore([object]$Operation) {
    $payloadId = File-Id $Operation.Payload
    $result = Invoke-VolumeCli @('restore', $Operation.Id)
    Assert-True ($result.ExitCode -ne 0 -and (File-Id $Operation.Payload) -ceq $payloadId) 'Unsafe restore consumed/changed payload.'
}

function Assert-FileFacts([string]$Path, [string]$Id, [int]$Attributes, [string]$Hash) {
    Assert-True ((File-Id $Path) -ceq $Id -and [int][IO.File]::GetAttributes($Path) -eq $Attributes -and (Digest $Path) -ceq $Hash) "File ID/attributes/content changed: $Path"
}
Test-Case 'locked-child-failure-cancelled-then-fresh-delete-and-maintain' {
    $file = New-File 'locked-tree\child.bin'; $tree = Split-Path -Parent $file; $snapshot = Snapshot-Tree $tree
    $held = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $failed = Invoke-VolumeCli @('delete', '--recursive', '--', $tree)
        Assert-True ($failed.ExitCode -ne 0 -and @($failed.Json.items | Where-Object status -eq 'failed').Count -gt 0) 'Locked tree deletion unexpectedly succeeded.'
        Assert-Tree $tree $snapshot
        if ($failed.Json.operationId) {
            $cancelled = Join-Path (Join-Path $script:Recovery $failed.Json.operationId) 'move-0000-cancelled.json'
            Assert-True ([IO.File]::Exists($cancelled)) 'Rejected move did not persist cancellation receipt.'
        } else { throw 'Locked move did not reach persisted intent/cancellation boundary.' }
    } finally { $held.Dispose() }
    $op = Delete-Entry $tree -Recursive; Assert-Tree $op.Payload $snapshot -MovedRoot
    $maintained = Invoke-VolumeCli @('maintain', '--apply')
    Assert-True ($maintained.ExitCode -eq 0 -and $maintained.Json.capacityKnown) 'Cancelled move poisoned maintenance capacity.'
    $freshFile = New-File 'fresh'; $fresh = Delete-Entry $freshFile; Restore-Entry $fresh $freshFile
    Restore-Entry $op $tree; Assert-Tree $tree $snapshot
}
foreach ($attributeValue in @(1, 128, 2)) {
    Test-Case "no-archive-attributes-$attributeValue-hardlink-roundtrip" {
        $file = New-File 'original'; $alias = Join-Path $script:Scope 'external-alias'
        $null = New-Item -ItemType HardLink -Path $alias -Target $file
        [IO.File]::SetAttributes($file, [IO.FileAttributes]$attributeValue)
        $id = File-Id $file; $hash = Digest $file
        Assert-FileFacts $alias $id $attributeValue $hash
        $op = Delete-Entry $file; Assert-FileFacts $op.Payload $id $attributeValue $hash; Assert-FileFacts $alias $id $attributeValue $hash
        Restore-Entry $op $file; Assert-FileFacts $file $id $attributeValue $hash; Assert-FileFacts $alias $id $attributeValue $hash
    }
}
Test-Case 'no-archive-deny-writeattributes-preserves-source-and-alias' {
    $file = New-File 'original'; $alias = Join-Path $script:Scope 'external-alias'
    $null = New-Item -ItemType HardLink -Path $alias -Target $file
    [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
    $id = File-Id $file; $hash = Digest $file
    $originalAcl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]$file, [Security.AccessControl.AccessControlSections]::Access)
    $restricted = [Security.AccessControl.FileSecurity]::new()
    $restricted.SetSecurityDescriptorSddlForm($originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access), [Security.AccessControl.AccessControlSections]::Access)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $restricted.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::WriteAttributes, [Security.AccessControl.AccessControlType]::Deny))
    # DACL更新もArchiveを立てるため、拒否前に得たハンドルでfixtureのNormalを戻す。
    $writer = [PrunletVolumeMoveVerificationIdentity]::OpenAttributeWriter($file)
    try {
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$file, $restricted)
        [PrunletVolumeMoveVerificationIdentity]::WriteAttributes($writer, 128)
    } finally { $writer.Dispose() }
    $primaryFailure = $null
    try {
        Assert-True ([PrunletVolumeMoveVerificationIdentity]::CanOpenForDelete($file)) 'Fixture does not independently permit DELETE.'
        Assert-True (![PrunletVolumeMoveVerificationIdentity]::CanOpenForAttributeWrite($file)) 'Fixture does not independently deny WRITE_ATTRIBUTES.'
        Assert-FileFacts $file $id 128 $hash; Assert-FileFacts $alias $id 128 $hash
        $result = Invoke-VolumeCli @('delete', '--', $file)
        Assert-True ($result.ExitCode -ne 0) 'Archive-free file moved without required attribute guard permission.'
        Assert-FileFacts $file $id 128 $hash; Assert-FileFacts $alias $id 128 $hash
    } catch { $primaryFailure = $_; throw
    } finally {
        try {
            $restorePath = if ([IO.File]::Exists($file)) { $file } else { $alias }
            Assert-True ((File-Id $restorePath) -ceq $id) 'DACL cleanup path no longer identifies the fixture.'
            $restoredAcl = [Security.AccessControl.FileSecurity]::new()
            $restoredAcl.SetSecurityDescriptorSddlForm($originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access), [Security.AccessControl.AccessControlSections]::Access)
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$restorePath, $restoredAcl)
        } catch {
            if ($primaryFailure) { Write-Warning ('Fixture DACL cleanup also failed: ' + $_.Exception.Message) } else { throw }
        }
    }
}
Test-Case 'file-roundtrip-and-consumption' {
    $file = New-File 'plain.bin'; $id = File-Id $file; $hash = Digest $file
    $op = Delete-Entry $file
    Assert-True ((File-Id $op.Payload) -ceq $id -and $op.Manifest.entries[0].size -eq 64) 'File was copied or size incorrect.'
    Restore-Entry $op $file
    Assert-True ((File-Id $file) -ceq $id -and (Digest $file) -ceq $hash) 'Roundtrip changed file.'
    $again = Invoke-VolumeCli @('restore', $op.Id)
    Assert-True ($again.ExitCode -eq 0 -and (File-Id $file) -ceq $id -and !(Test-Path -LiteralPath $op.Payload)) 'Repeated restore changed the consumed operation.'
}
Test-Case 'tree-one-entry-full-size-and-identities' {
    $null = New-File 'tree\a.bin' 113; $null = New-File 'tree\nested\b.bin' 257
    $tree = Join-Path $script:Scope 'tree'; $null = New-Directory (Join-Path $tree 'empty')
    $snapshot = Snapshot-Tree $tree; $op = Delete-Entry $tree -Recursive
    Assert-True ($op.Manifest.entries[0].size -eq 370) 'Directory size omitted descendants.'
    Assert-Tree $op.Payload $snapshot -MovedRoot; Restore-Entry $op $tree; Assert-Tree $tree $snapshot
}
foreach ($difference in @('rights', 'propagation', 'deny')) {
    Test-Case "moved-root-acl-$difference-change-is-detected" {
        $tree = New-Directory (Join-Path $script:Scope 'acl-tree')
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $containers = [Security.AccessControl.InheritanceFlags]::ContainerInherit
        $none = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $read = [Security.AccessControl.FileSystemRights]::ReadAndExecute
        $write = [Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData
        $acl = Get-Acl -LiteralPath $tree; $acl.SetAccessRuleProtection($true, $false)
        foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, $none, $allow))
        }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, $read, $inherit, $none, $allow))
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, $write, $containers, $none, $allow))
        Set-Acl -LiteralPath $tree -AclObject $acl
        $null = New-File 'acl-tree\child.bin'
        $originalAcl = Get-Acl -LiteralPath $tree; $snapshot = Snapshot-Tree $tree
        $op = Delete-Entry $tree -Recursive; Assert-Tree $op.Payload $snapshot -MovedRoot
        $changed = [Security.AccessControl.DirectorySecurity]::new()
        $changed.SetSecurityDescriptorSddlForm($originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access), [Security.AccessControl.AccessControlSections]::Access)
        $changed.PurgeAccessRules($users)
        $changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, $read, $inherit, $none, $allow))
        $changedRights = if ($difference -eq 'rights') { [Security.AccessControl.FileSystemRights]::AppendData } else { $write }
        $propagation = if ($difference -eq 'propagation') { [Security.AccessControl.PropagationFlags]::NoPropagateInherit } else { $none }
        $changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, $changedRights, $containers, $propagation, $allow))
        if ($difference -eq 'deny') {
            $changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, [Security.AccessControl.FileSystemRights]::WriteData, [Security.AccessControl.InheritanceFlags]::None, $none, [Security.AccessControl.AccessControlType]::Deny))
        }
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($op.Payload), $changed)
        $rejected = $false
        try { Assert-Tree $op.Payload $snapshot -MovedRoot } catch { $rejected = $_.Exception.Message -like 'ACL permissions changed:*' }
        Assert-True $rejected "ACL $difference change was hidden by comparison."
        $restoreAcl = [Security.AccessControl.DirectorySecurity]::new()
        $restoreAcl.SetSecurityDescriptorSddlForm($originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access), [Security.AccessControl.AccessControlSections]::Access)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($op.Payload), $restoreAcl)
        Assert-Tree $op.Payload $snapshot -MovedRoot
        Restore-Entry $op $tree; Assert-Tree $tree $snapshot
    }
}
Test-Case 'nonrecursive-rejects-nonempty-tree' {
    $null = New-File 'tree\a'; $tree = Join-Path $script:Scope 'tree'; $snapshot = Snapshot-Tree $tree
    $result = Invoke-VolumeCli @('delete', '--', $tree)
    Assert-True ($result.ExitCode -ne 0) 'Nonrecursive delete accepted nonempty tree.'; Assert-Tree $tree $snapshot
}
Test-Case 'dry-run-no-store-no-metadata-no-attribute-change' {
    $file = New-File 'tree\readonly.bin'; [IO.File]::SetAttributes($file, [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden)
    $tree = Join-Path $script:Scope 'tree'; $snapshot = Snapshot-Tree $tree
    $before = @(Get-ChildItem -LiteralPath $script:Recovery -Force -Recurse | ForEach-Object FullName) -join '|'
    $result = Invoke-VolumeCli @('delete', '--recursive', '--dry-run', '--', $tree)
    Assert-True ($result.ExitCode -eq 0 -and !(Test-Path -LiteralPath $script:Store)) 'Dry-run created volume store.'
    Assert-True ((@(Get-ChildItem -LiteralPath $script:Recovery -Force -Recurse | ForEach-Object FullName) -join '|') -ceq $before) 'Dry-run changed metadata.'
    Assert-Tree $tree $snapshot
}
Test-Case 'readonly-64-ads-and-acl-preserved' {
    $file = New-File 'streams.bin'; $hashes = @{}
    for ($i = 0; $i -lt 64; $i++) { $stream = "${file}:stream$i"; [IO.File]::WriteAllText($stream, "ADS$i 日本語", $utf8); $hashes[$i] = [IO.File]::ReadAllText($stream) }
    [IO.File]::SetAttributes($file, [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive)
    $snapshot = Snapshot-Tree $file; $op = Delete-Entry $file
    for ($i = 0; $i -lt 64; $i++) { Assert-True ([IO.File]::ReadAllText($op.Payload + ":stream$i") -ceq $hashes[$i]) 'ADS missing after delete.' }
    Restore-Entry $op $file; Assert-Tree $file $snapshot
    for ($i = 0; $i -lt 64; $i++) { Assert-True ([IO.File]::ReadAllText("${file}:stream$i") -ceq $hashes[$i]) 'ADS missing after restore.' }
}
Test-Case 'external-hardlink-name-unchanged' {
    $file = New-File 'source.bin'; $alias = Join-Path $script:Scope 'external-alias.bin'
    $null = New-Item -ItemType HardLink -Path $alias -Target $file
    $id = File-Id $alias; $hash = Digest $alias; $attrs = [IO.File]::GetAttributes($alias)
    $op = Delete-Entry $file
    Assert-True ((File-Id $alias) -ceq $id -and (Digest $alias) -ceq $hash -and [IO.File]::GetAttributes($alias) -eq $attrs) 'Delete changed external hardlink name/content/attributes.'
    Restore-Entry $op $file; Assert-True ((File-Id $file) -ceq $id) 'Hardlink identity changed.'
}
foreach ($linkKind in @('Junction', 'SymbolicLink')) {
    Test-Case "link-$linkKind-target-preserved" {
        $targetFile = New-File 'outside\target.bin'; $target = Split-Path -Parent $targetFile
        $link = Join-Path $script:Scope 'link'; $snapshot = Snapshot-Tree $target
        try { $null = New-Item -ItemType $linkKind -Path $link -Target $target }
        catch {
            if ($linkKind -eq 'SymbolicLink' -and $_.Exception.Message -match 'privilege|権限') {
                $script:CaseNote = 'SymbolicLink fixture unavailable: creation privilege absent.'; return
            }; throw
        }
        $op = Delete-Entry $link -Recursive; Assert-Tree $target $snapshot
        Assert-True (((Get-Item -LiteralPath $op.Payload -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Link became ordinary directory.'
        Restore-Entry $op $link; Assert-Tree $target $snapshot
        Assert-True ((Get-Item -LiteralPath $link -Force).Target -ceq $target) 'Link target changed.'
    }
}
Test-Case 'case-sensitive-directory-when-supported' {
    $tree = New-Directory (Join-Path $script:Scope 'case-sensitive')
    $enabled = Invoke-Child (Join-Path $env:SystemRoot 'System32\fsutil.exe') @('file', 'SetCaseSensitiveInfo', $tree, 'enable') -Raw
    if ($enabled.ExitCode -ne 0) { $script:CaseNote = 'Case-sensitive fixture unavailable: filesystem/privilege limitation.'; return }
    $null = File-Id $tree
    if (![PrunletVolumeMoveVerificationIdentity]::IsCaseSensitive($tree)) { $script:CaseNote = 'fsutil returned success but the case-sensitive flag remains disabled.'; return }
    [IO.File]::WriteAllText((Join-Path $tree 'a'), 'lower', $utf8); [IO.File]::WriteAllText((Join-Path $tree 'A'), 'UPPER', $utf8)
    Assert-True ([IO.File]::ReadAllText((Join-Path $tree 'a')) -ceq 'lower') 'Case-sensitive fixture flag was not enabled.'
    $snapshot = Snapshot-Tree $tree; $op = Delete-Entry $tree -Recursive; Restore-Entry $op $tree; Assert-Tree $tree $snapshot
    Assert-True ([PrunletVolumeMoveVerificationIdentity]::IsCaseSensitive($tree)) 'Case-sensitive attribute was lost.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $tree 'a')) -ceq 'lower' -and [IO.File]::ReadAllText((Join-Path $tree 'A')) -ceq 'UPPER') 'Case-sensitive names collapsed.'
}
foreach ($kind in @('file', 'directory')) {
    Test-Case "restore-conflict-$kind" {
        $file = New-File 'original'; $op = Delete-Entry $file
        if ($kind -eq 'file') { [IO.File]::WriteAllText($file, 'conflict', $utf8) } else { $null = New-Directory $file }
        $conflictId = File-Id $file; Assert-RejectedRestore $op
        Assert-True ((File-Id $file) -ceq $conflictId) 'Restore overwrote existing destination.'
    }
}
foreach ($mutation in @('source-id', 'store-id', 'unknown-member', 'truncated-json', 'payload-replaced')) {
    Test-Case "reject-$mutation" {
        $file = New-File 'original'; $op = Delete-Entry $file; $manifest = Read-Json $op.ManifestPath
        switch ($mutation) {
            'source-id' { $manifest.entries[0].identity.fileId = '00000000000000000000000000000000'; Save-Json $op.ManifestPath $manifest; Rebind-Receipts $op }
            'store-id' { $manifest.entries[0].storeIdentity.fileId = '00000000000000000000000000000000'; Save-Json $op.ManifestPath $manifest; Rebind-Receipts $op }
            'unknown-member' { $manifest.unrecognized = $true; Save-Json $op.ManifestPath $manifest }
            'truncated-json' { [IO.File]::WriteAllText($op.ManifestPath, '{"schema":4,', $utf8) }
            'payload-replaced' { Move-Item -LiteralPath $op.Payload -Destination ($op.Payload + '.retained'); [IO.File]::WriteAllText($op.Payload, 'replacement', $utf8) }
        }
        Assert-RejectedRestore $op; Assert-True (!(Test-Path -LiteralPath $file)) 'Unsafe restore recreated original.'
        $purge = Invoke-VolumeCli @('purge', $op.Id, '--apply'); Assert-True ($purge.ExitCode -ne 0 -and (Test-Path -LiteralPath $op.Payload)) 'Unsafe purge removed payload.'
    }
}
Test-Case 'reject-store-and-containing-directory' {
    $file = New-File 'seed'; $op = Delete-Entry $file
    foreach ($target in @($script:Store, $op.Manifest.entries[0].storeRoot, $script:CaseRoot)) {
        $result = Invoke-VolumeCli @('delete', '--recursive', '--', $target)
        Assert-True ($result.ExitCode -ne 0 -and (Test-Path -LiteralPath $op.Payload)) 'Delete accepted its recovery store or containing directory.'
    }
}
Test-Case 'reject-unrecognized-volume-key' {
    $file = New-File 'original'; $id = File-Id $file; $config = Read-Json $script:Config
    # 不正keyは設定読込で拒否し、未設定volumeの既定領域を試行しない。
    $config.volumeRecoveryDirectories['not-a-volume'] = $script:Store; Save-Json $script:Config $config
    $result = Invoke-VolumeCli @('delete', '--', $file)
    Assert-True ($result.ExitCode -ne 0 -and (File-Id $file) -ceq $id -and !(Test-Path -LiteralPath $script:Store)) 'Invalid volume configuration mutated source/store.'
}
Test-Case 'reject-recovery-location-inside-source' {
    $file = New-File 'tree\original'; $tree = Join-Path $script:Scope 'tree'; $config = Read-Json $script:Config
    $config.volumeRecoveryDirectories[$fixtureDrive] = Join-Path $tree 'volume-store'; Save-Json $script:Config $config
    $result = Invoke-VolumeCli @('delete', '--recursive', '--', $tree)
    Assert-True ($result.ExitCode -ne 0 -and [IO.File]::Exists($file)) 'Store nested in source was accepted.'
}
Test-Case 'reject-recorded-external-store-placement' {
    $op = Delete-Entry (New-File 'original'); $manifest = Read-Json $op.ManifestPath
    $manifest.entries[0].storeRoot = New-Directory (Join-Path $script:CaseRoot 'untrusted-placement')
    Save-Json $op.ManifestPath $manifest; Rebind-Receipts $op
    Assert-RejectedRestore $op
}
Test-Case 'reject-store-with-untrusted-acl' {
    $seed = Delete-Entry (New-File 'seed'); $storeRoot = $seed.Manifest.entries[0].storeRoot
    # DACLだけを編集し、監査ACL/所有者の再適用に必要なSeSecurityPrivilegeを要求しない。
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]$storeRoot, [Security.AccessControl.AccessControlSections]::Access)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), [Security.AccessControl.FileSystemRights]::ReadAndExecute, [Security.AccessControl.AccessControlType]::Allow)
    $null = $acl.AddAccessRule($rule); [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$storeRoot, $acl)
    $file = New-File 'original'; $id = File-Id $file; $payloadId = File-Id $seed.Payload
    $result = Invoke-VolumeCli @('delete', '--', $file)
    Assert-True ($result.ExitCode -ne 0 -and (File-Id $file) -ceq $id -and (File-Id $seed.Payload) -ceq $payloadId) 'Untrusted store ACL was accepted or data changed.'
}
Test-Case 'retention-expiry-and-capacity-order' {
    $old = Delete-Entry (New-File 'old' 64); $middle = Delete-Entry (New-File 'middle' 64); $fresh = Delete-Entry (New-File 'fresh' 64)
    Set-Age $old 8; Set-Age $middle 2; Set-Age $fresh 1; Set-Policy 64
    $before = File-Id $old.Payload; $dry = Invoke-VolumeCli @('maintain', '--dry-run')
    Assert-True ($dry.ExitCode -eq 0 -and (File-Id $old.Payload) -ceq $before -and (Test-Path -LiteralPath $middle.Payload)) 'Maintenance dry-run mutated payload.'
    $apply = Invoke-VolumeCli @('maintain', '--apply')
    Assert-True ($apply.ExitCode -eq 0 -and !(Test-Path -LiteralPath $old.Payload) -and !(Test-Path -LiteralPath $middle.Payload) -and (Test-Path -LiteralPath $fresh.Payload)) 'Maintenance expiry/capacity order incorrect.'
    Assert-True ((Test-Path -LiteralPath $old.ManifestPath) -and (Test-Path -LiteralPath $middle.ManifestPath)) 'Maintenance removed audit manifests.'
}
Test-Case 'oversized-single-operation-next-maintain-normal-budget' {
    Set-Policy 64; $old = Delete-Entry (New-File 'old' 64); $large = Delete-Entry (New-File 'large' 129)
    Assert-True (!(Test-Path -LiteralPath $old.Payload) -and (Test-Path -LiteralPath $large.Payload)) 'Incoming size did not define temporary budget.'
    $result = Invoke-VolumeCli @('maintain', '--apply')
    Assert-True ($result.ExitCode -eq 0 -and !(Test-Path -LiteralPath $large.Payload)) 'Next maintain did not reapply configured budget.'
}
Test-Case 'invalid-old-operation-blocks-capacity-preserving-source' {
    Set-Policy 64; $old = Delete-Entry (New-File 'old' 64)
    $manifest = Read-Json $old.ManifestPath; $manifest.entries[0].identity.fileId = '00000000000000000000000000000000'
    Save-Json $old.ManifestPath $manifest; Rebind-Receipts $old
    $file = New-File 'new' 65; $id = File-Id $file; $payloadId = File-Id $old.Payload
    $result = Invoke-VolumeCli @('delete', '--', $file)
    Assert-True ($result.ExitCode -ne 0 -and (File-Id $file) -ceq $id -and (File-Id $old.Payload) -ceq $payloadId) 'Unknown capacity did not preserve source and old payload.'
}
Test-Case 'mutable-hardlink-payload-is-measured-and-restored' {
    $file = New-File 'original'; $alias = Join-Path $script:Scope 'alias'
    $null = New-Item -ItemType HardLink -Path $alias -Target $file
    $op = Delete-Entry $file; [IO.File]::WriteAllText($alias, 'updated through existing hardlink', $utf8)
    $result = Invoke-VolumeCli @('maintain', '--dry-run')
    Assert-True ($result.ExitCode -eq 0 -and $result.Json.retainedBytesBefore -eq ([IO.FileInfo]$alias).Length) 'Maintenance trusted stale initial size.'
    Restore-Entry $op $file
    Assert-True ([IO.File]::ReadAllText($file) -ceq 'updated through existing hardlink') 'Mutable recovery payload was rejected or overwritten.'
}
Test-Case 'oversized-multiple-input-sum-and-next-delete' {
    Set-Policy 64; $one = New-File 'one' 65; $two = New-File 'two' 66
    $pathsFile = Join-Path $script:CaseRoot 'paths.json'; Save-Json $pathsFile @($one, $two)
    $result = Invoke-VolumeCli @('delete', '--paths-file', $pathsFile)
    Assert-True ($result.ExitCode -eq 0 -and ![IO.File]::Exists($one) -and ![IO.File]::Exists($two)) 'Multi-input oversized operation failed.'
    $manifestPath = Join-Path (Join-Path $script:Recovery $result.Json.operationId) 'move-manifest.json'; $manifest = Read-Json $manifestPath
    Assert-True ($manifest.entries.Count -eq 2 -and (($manifest.entries | Measure-Object size -Sum).Sum -eq 131)) 'Multi-input total size incorrect.'
    $null = Delete-Entry (New-File 'next' 32)
    foreach ($entry in $manifest.entries) { Assert-True (!(Test-Path -LiteralPath (Join-Path (Join-Path $entry.storeRoot $manifest.operationId) $entry.payloadName))) 'Next delete retained old over-budget operation.' }
}
Test-Case 'oversized-multiple-input-dryrun-and-restore' {
    Set-Policy 64; $one = New-File 'one' 65; $two = New-File 'tree\two' 66
    $tree = Split-Path -Parent $two; $oneId = File-Id $one; $treeSnapshot = Snapshot-Tree $tree
    $pathsFile = Join-Path $script:CaseRoot 'paths.json'; Save-Json $pathsFile @($one, $tree)
    $dry = Invoke-VolumeCli @('delete', '--recursive', '--dry-run', '--paths-file', $pathsFile)
    Assert-True ($dry.ExitCode -eq 0 -and (File-Id $one) -ceq $oneId -and !(Test-Path -LiteralPath $script:Store)) 'Oversized multi-input dry-run mutated source/store.'
    Assert-Tree $tree $treeSnapshot
    $deleted = Invoke-VolumeCli @('delete', '--recursive', '--paths-file', $pathsFile)
    Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $one) -and !(Test-Path -LiteralPath $tree)) 'Oversized multi-input delete failed.'
    $restored = Invoke-VolumeCli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0 -and (File-Id $one) -ceq $oneId) 'Oversized multi-input restore failed.'
    Assert-Tree $tree $treeSnapshot
}
foreach ($schema in @(1, 2, 3)) {
    foreach ($action in @('restore', 'purge', 'maintain')) {
        Test-Case "legacy-schema-$schema-$action" -RequiresLegacy {
            $file = New-File 'legacy\data.bin' 97; $path = if ($schema -eq 1) { $file } else { Split-Path -Parent $file }
            if ($schema -eq 3) { [IO.File]::WriteAllText("${file}:legacy-stream", 'legacy ADS', $utf8) }
            $hash = Digest $file; $argsList = @('delete'); if ($schema -ne 1) { $argsList += '--recursive' }; $argsList += @('--', $path)
            $deleted = Invoke-VolumeCli $argsList -Legacy
            Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $path)) 'Legacy fixture generation failed.'
            $root = Join-Path $script:Recovery $deleted.Json.operationId; $manifestPath = Join-Path $root 'manifest.json'; $manifest = Read-Json $manifestPath
            Assert-True ($manifest.schema -eq $schema) 'Legacy generator did not exercise requested schema.'
            switch ($action) {
                'restore' { $result = Invoke-VolumeCli @('restore', $deleted.Json.operationId); Assert-True ($result.ExitCode -eq 0 -and (Digest $file) -ceq $hash) 'Legacy restore failed.'; if ($schema -eq 3) { Assert-True ([IO.File]::ReadAllText("${file}:legacy-stream") -ceq 'legacy ADS') 'Legacy ADS missing.' } }
                'purge' { $result = Invoke-VolumeCli @('purge', $deleted.Json.operationId, '--apply'); Assert-True ($result.ExitCode -eq 0 -and @(Get-ChildItem -LiteralPath $root -File -Filter '*.bak').Count -eq 0) 'Legacy purge failed.' }
                'maintain' { $manifest.createdUtc = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O'); Save-Json $manifestPath $manifest; $result = Invoke-VolumeCli @('maintain', '--apply'); Assert-True ($result.ExitCode -eq 0 -and @(Get-ChildItem -LiteralPath $root -File -Filter '*.bak').Count -eq 0) 'Legacy maintenance failed.' }
            }
        }
    }
}
Test-Case 'move-complete-receipt-absent-recovery' {
    $file = New-File 'original'; $id = File-Id $file; $op = Delete-Entry $file
    $receipt = Join-Path $op.Root 'move-0000-complete.json'
    Assert-True ([IO.File]::Exists($receipt)) 'Move completion receipt missing from successful fixture.'
    # 削除せず同じfixture volume上の隔離先へ退避して、移動直後の記録境界を再現する。
    Move-Item -LiteralPath $receipt -Destination (Join-Path $script:CaseRoot 'retained-move-complete.json')
    Restore-Entry $op $file; Assert-True ((File-Id $file) -ceq $id) 'Receipt-free move recovery lost identity.'
}
Test-Case 'restore-intent-already-moved-recovery' {
    $file = New-File 'original'; $id = File-Id $file; $op = Delete-Entry $file
    $intent = @{ schema = 4; operationId = $op.Id; index = 0; manifestSha256 = Digest $op.ManifestPath; action = 'restore'; phase = 'intent'; attributes = [uint32]([int][IO.File]::GetAttributes($op.Payload) -band 0x31a7); createdUtc = [DateTimeOffset]::UtcNow.ToString('O') }
    Save-Json (Join-Path $op.Root 'restore-0000-intent.json') $intent
    Move-Item -LiteralPath $op.Payload -Destination $file
    $result = Invoke-VolumeCli @('restore', $op.Id)
    Assert-True ($result.ExitCode -eq 0 -and (File-Id $file) -ceq $id -and !(Test-Path -LiteralPath $op.Payload)) 'Restore intent recovery lost moved object.'
}
Test-Case 'move-intent-original-only-not-moved-recovery' {
    $file = New-File 'original'; $id = File-Id $file; $op = Delete-Entry $file
    Move-Item -LiteralPath (Join-Path $op.Root 'move-0000-complete.json') -Destination (Join-Path $script:CaseRoot 'retained-move-complete.json')
    Move-Item -LiteralPath $op.Payload -Destination $file
    $result = Invoke-VolumeCli @('restore', $op.Id)
    Assert-True ($result.ExitCode -eq 0 -and (File-Id $file) -ceq $id -and !(Test-Path -LiteralPath $op.Payload)) 'Unexecuted move intent changed original.'
}
Test-Case 'purge-intent-payload-already-absent-recovery' {
    $file = New-File 'original'; $op = Delete-Entry $file
    $intent = @{ schema = 4; operationId = $op.Id; index = 0; manifestSha256 = Digest $op.ManifestPath; action = 'purge'; phase = 'intent'; createdUtc = [DateTimeOffset]::UtcNow.ToString('O') }
    Save-Json (Join-Path $op.Root 'purge-0000-intent.json') $intent
    Move-Item -LiteralPath $op.Payload -Destination (Join-Path $script:CaseRoot 'retained-purged-payload')
    $result = Invoke-VolumeCli @('purge', $op.Id, '--apply')
    Assert-True ($result.ExitCode -eq 0 -and !(Test-Path -LiteralPath $file) -and !(Test-Path -LiteralPath $op.Payload)) 'Purge-intent recovery failed.'
    Assert-True ([IO.File]::Exists((Join-Path $op.Root 'purge-0000-complete.json'))) 'Purge recovery did not persist completion.'
}
Test-Case 'partial-purge-intent-refuses-directory-restore' {
    $null = New-File 'tree\first' 31; $null = New-File 'tree\remaining' 47
    $tree = Join-Path $script:Scope 'tree'; $op = Delete-Entry $tree -Recursive
    $intent = @{ schema = 4; operationId = $op.Id; index = 0; manifestSha256 = Digest $op.ManifestPath; action = 'purge'; phase = 'intent'; createdUtc = [DateTimeOffset]::UtcNow.ToString('O') }
    Save-Json (Join-Path $op.Root 'purge-0000-intent.json') $intent
    $removedChild = Join-Path $op.Payload 'first'; $retainedChild = Join-Path $script:CaseRoot 'retained-removed-child'
    Assert-True ([IO.Path]::IsPathFullyQualified($removedChild) -and !(Test-Path -LiteralPath $retainedChild)) 'Unsafe partial-purge fixture paths.'
    Move-Item -LiteralPath $removedChild -Destination $retainedChild
    $rootId = File-Id $op.Payload; $remainingHash = Digest (Join-Path $op.Payload 'remaining')
    $result = Invoke-VolumeCli @('restore', $op.Id)
    Assert-True ($result.ExitCode -ne 0 -and !(Test-Path -LiteralPath $tree) -and (File-Id $op.Payload) -ceq $rootId) 'Partial purge was treated as a complete restore.'
    Assert-True ((Digest (Join-Path $op.Payload 'remaining')) -ceq $remainingHash) 'Refused restore changed remaining data.'
}
Test-Case 'orphaned-operation-blocks-capacity-and-preserves-source' {
    $file = New-File 'original' 128; $op = Delete-Entry $file
    Move-Item -LiteralPath $op.Root -Destination (Join-Path $script:CaseRoot 'retained-orphan-metadata')
    $fresh = New-File 'fresh' 17; $id = File-Id $fresh; $hash = Digest $op.Payload
    $inspection = Invoke-VolumeCli @('maintain', '--dry-run')
    Assert-True ($inspection.Json.capacityKnown -eq $false -and $inspection.Json.budgetSatisfied -eq $false) 'Orphaned payload was omitted from capacity control.'
    $result = Invoke-VolumeCli @('delete', '--', $fresh)
    Assert-True ($result.ExitCode -ne 0 -and (File-Id $fresh) -ceq $id -and (Digest $op.Payload) -ceq $hash) 'Unknown capacity changed the source or orphaned payload.'
}
Test-Case 'unknown-store-member-blocks-capacity' {
    $file = New-File 'original' 32; $op = Delete-Entry $file
    $unknown = Join-Path $op.Manifest.entries[0].storeRoot 'unknown.bin'; [IO.File]::WriteAllText($unknown, 'untracked bytes', $utf8)
    $hash = Digest $unknown; $inspection = Invoke-VolumeCli @('maintain', '--dry-run')
    Assert-True ($inspection.Json.capacityKnown -eq $false -and $inspection.Json.budgetSatisfied -eq $false -and (Digest $unknown) -ceq $hash) 'Unknown store data was ignored or removed.'
}
Test-Case 'metadata-directory-ads-blocks-capacity-and-mutation' {
    $file = New-File 'original' 41; $op = Delete-Entry $file
    $stream = $op.Root + ':untracked'; [IO.File]::WriteAllText($stream, 'untracked metadata-directory stream', $utf8)
    $payloadHash = Digest $op.Payload; $streamHash = Digest $stream
    $inspection = Invoke-VolumeCli @('maintain', '--dry-run')
    Assert-True ($inspection.Json.capacityKnown -eq $false -and $inspection.Json.budgetSatisfied -eq $false) 'Metadata directory ADS was omitted from capacity control.'
    foreach ($arguments in @(@('restore', $op.Id), @('purge', $op.Id, '--apply'))) {
        $result = Invoke-VolumeCli $arguments
        Assert-True ($result.ExitCode -ne 0 -and !(Test-Path -LiteralPath $file) -and (Digest $op.Payload) -ceq $payloadHash -and (Digest $stream) -ceq $streamHash) 'Unrecognized metadata directory data allowed mutation.'
    }
}
Test-Case 'parallel-deletes-maintain-strict-capacity' {
    $config = Read-Json $script:Config; $config.maxRecoveryBytes = 100; Save-Json $script:Config $config
    $sources = @((New-File 'first' 60), (New-File 'second' 70))
    $workers = [Collections.Generic.List[object]]::new()
    try {
        foreach ($source in $sources) {
            $process = Start-Child $ExecutablePath @('--config', $script:Config, 'delete', '--', $source)
            $process.StandardInput.Close()
            $workers.Add(@{ process = $process; output = $process.StandardOutput.ReadToEndAsync(); error = $process.StandardError.ReadToEndAsync() })
        }
        foreach ($worker in $workers) {
            Assert-True ($worker.process.WaitForExit(30000)) 'Concurrent delete timed out.'
            $reply = $worker.output.GetAwaiter().GetResult() | ConvertFrom-Json
            $diagnostics = $worker.error.GetAwaiter().GetResult()
            Assert-True ($worker.process.ExitCode -eq 0 -and $reply.items[0].status -eq 'deleted') "Concurrent delete failed: $diagnostics"
        }
        Assert-True (@($sources | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Concurrent delete retained a source.'
        $inspection = Invoke-VolumeCli @('maintain', '--dry-run')
        Assert-True ($inspection.Json.capacityKnown -eq $true -and $inspection.Json.budgetSatisfied -eq $true -and $inspection.Json.retainedBytesAfter -le 100) 'Concurrent deletions exceeded the strict recovery budget.'
        $manifests = @(Get-ChildItem -LiteralPath $script:Recovery -Filter move-manifest.json -Recurse -File)
        $present = @($manifests | ForEach-Object {
            $manifest = Read-Json $_.FullName; $entry = $manifest.entries[0]
            Join-Path (Join-Path $entry.storeRoot $manifest.operationId) $entry.payloadName
        } | Where-Object { Test-Path -LiteralPath $_ })
        Assert-True ($manifests.Count -eq 2 -and $present.Count -eq 1) 'Concurrent capacity cleanup did not retain exactly one valid payload.'
    } finally {
        foreach ($worker in $workers) {
            if (!$worker.process.HasExited) { $worker.process.Kill($true); $worker.process.WaitForExit() }
            $worker.process.Dispose()
        }
    }
}
Test-Case 'multiple-folders-with-cross-hardlinks-move-and-restore' {
    $first = New-File 'first\data' 73; $secondRoot = New-Directory (Join-Path $script:Scope 'second')
    $second = Join-Path $secondRoot 'alias'; $null = New-Item -ItemType HardLink -Path $second -Target $first
    $firstRoot = Split-Path -Parent $first; $firstSnapshot = Snapshot-Tree $firstRoot; $secondSnapshot = Snapshot-Tree $secondRoot
    $pathList = Join-Path $script:CaseRoot 'cross-hardlinks.json'; Save-Json $pathList @($firstRoot, $secondRoot)
    $deleted = Invoke-VolumeCli @('delete', '--recursive', '--paths-file', $pathList)
    Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $firstRoot) -and !(Test-Path -LiteralPath $secondRoot)) 'Cross-linked folder inputs blocked each other during rename.'
    $manifest = Read-Json (Join-Path (Join-Path $script:Recovery $deleted.Json.operationId) 'move-manifest.json')
    Assert-True ($manifest.entries.Count -eq 2) 'Cross-linked folders expanded into file copies.'
    for ($index = 0; $index -lt 2; $index++) {
        $entry = $manifest.entries[$index]; $payload = Join-Path (Join-Path $entry.storeRoot $manifest.operationId) $entry.payloadName
        $snapshot = if ($index -eq 0) { $firstSnapshot } else { $secondSnapshot }
        Assert-Tree $payload $snapshot -MovedRoot
    }
    $restored = Invoke-VolumeCli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Cross-linked folders could not be restored.'
    Assert-Tree $firstRoot $firstSnapshot; Assert-Tree $secondRoot $secondSnapshot
    Assert-True ((File-Id $first) -ceq (File-Id $second)) 'Cross-folder hardlink identity changed.'
}
Test-Case 'hook-rejects-native-delete-with-cli-guidance' {
    $file = New-File 'hook-target'; $event = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = "Remove-Item -LiteralPath '$file'"; cwd = $script:Scope } }
    $result = Invoke-Child $ExecutablePath @('--config', $script:Config, 'hook') ($event | ConvertTo-Json -Depth 8 -Compress)
    Assert-True ($result.ExitCode -eq 0 -and $result.Stdout -match '(?i)deny' -and $result.Stdout -match '(?i)prunlet' -and [IO.File]::Exists($file)) 'Hook did not refuse and guide to Prunlet.'
}
Test-Case 'mcp-initialize-delete-restore' {
    $help = Invoke-Child $ExecutablePath @('--help') -Raw
    Assert-True ($help.ExitCode -eq 0 -and $help.Stdout -match 'same volume' -and $help.Stdout -match 'consumes moved items' -and $help.Stdout -match 'surviving aliases') 'CLI help omits the move-based recovery contract.'
    $file = New-File 'mcp-target'; $id = File-Id $file; $process = Start-Child $ExecutablePath @('--config', $script:Config, 'mcp')
    try {
        $stderr = $process.StandardError.ReadToEndAsync()
        function Rpc([object]$Request) {
            $process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 12 -Compress)); $process.StandardInput.Flush()
            for ($i = 0; $i -lt 64; $i++) {
                $read = $process.StandardOutput.ReadLineAsync(); if (!$read.Wait(15000)) { throw 'MCP response timeout.' }
                $line = $read.GetAwaiter().GetResult(); if (!$line) { throw 'MCP closed output.' }
                $reply = $line | ConvertFrom-Json -Depth 40
                if ($reply.id -eq $Request.id) { return $reply }
            }; throw 'Too many MCP notifications.'
        }
        $init = Rpc @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'volume-moves-e2e'; version = '1' } } }
        Assert-True ($null -ne $init.result) 'MCP initialize failed.'
        Assert-True ($init.result.instructions -match 'same volume' -and $init.result.instructions -match 'consumes moved items' -and $init.result.instructions -match 'alias writes') 'MCP instructions omit the move, consumption, or shared-hardlink contract.'
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $process.StandardInput.Flush()
        $list = Rpc @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
        Assert-True (@($list.result.tools.name) -contains 'delete_files') 'MCP delete tool missing.'
        $deleteTool = $list.result.tools | Where-Object name -EQ 'delete_files'
        $restoreTool = $list.result.tools | Where-Object name -EQ 'restore_files'
        Assert-True ($deleteTool.description -match 'same volume' -and $restoreTool.description -match 'consumes') 'MCP tool descriptions do not describe move-based recovery.'
        $deleted = Rpc @{ jsonrpc = '2.0'; id = 3; method = 'tools/call'; params = @{ name = 'delete_files'; arguments = @{ paths = @($file) } } }
        Assert-True (!$deleted.result.isError -and ![IO.File]::Exists($file)) 'MCP delete failed.'
        $manifest = Read-Json (Join-Path (Join-Path $script:Recovery $deleted.result.structuredContent.operationId) 'move-manifest.json')
        Assert-True ($manifest.schema -eq 4) 'MCP used copy path.'
        $restored = Rpc @{ jsonrpc = '2.0'; id = 4; method = 'tools/call'; params = @{ name = 'restore_files'; arguments = @{ operationId = $deleted.result.structuredContent.operationId } } }
        Assert-True (!$restored.result.isError -and (File-Id $file) -ceq $id) 'MCP restore changed identity.'
        $process.StandardInput.Close(); Assert-True ($process.WaitForExit(15000)) 'MCP did not exit after stdin closed.'
        $null = $stderr.GetAwaiter().GetResult()
    } finally { if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose() }
}
Test-Case 'schema4-compact-history-retains-manifest-and-payload' {
    $file = New-File 'original'; $original = Snapshot-Tree $file; $op = Delete-Entry $file
    $manifestHash = Digest $op.ManifestPath; $manifestId = File-Id $op.ManifestPath; $payload = Snapshot-Tree $op.Payload
    foreach ($mode in @('--dry-run', '--apply')) {
        $result = Invoke-VolumeCli @('compact-history', $mode)
        Assert-True ($result.ExitCode -eq 0 -and @($result.Json.operations).Count -eq 1 -and $result.Json.operations[0].operationId -ceq $op.Id -and $result.Json.operations[0].status -eq 'skipped') 'Schema 4 history was not retained.'
        Assert-True (@($result.Json.warnings | Where-Object { $_ -match '(?i)schema 4.*retained' }).Count -gt 0) 'Schema 4 retention reason was not reported.'
        Assert-True ((Digest $op.ManifestPath) -ceq $manifestHash -and (File-Id $op.ManifestPath) -ceq $manifestId) 'History compaction changed move manifest bytes or ID.'
        Assert-Tree $op.Payload $payload
    }
    Restore-Entry $op $file; Assert-Tree $file $original
}
Test-Case 'secondary-volume-mixed-input-roundtrip-conflict-and-consumption' {
    if (!$SecondaryVolumeDirectory) { $script:CaseNote = 'SecondaryVolumeDirectory not supplied; cross-volume input dispatch was not verified.'; return }
    # 別volumeへの書込みは、呼出元で対象の新規パスへの許可を得た場合だけ指定する。
    # metadata・paths-file・TEMP・bundle・ログはfixture volume（ローカルD:）に保持する。
    # 別volumeには小さなsource/storeだけ置く。
    Assert-True (!(Test-Path -LiteralPath $SecondaryVolumeDirectory)) 'Secondary fixture path already exists.'
    $secondarySource = New-Directory (Join-Path $SecondaryVolumeDirectory 'source')
    $secondaryStore = Join-Path $SecondaryVolumeDirectory 'volume-store'
    $otherFile = Join-Path $secondarySource 'other.bin'; [IO.File]::WriteAllText($otherFile, 'tiny secondary-volume fixture', $utf8)
    $null = New-File 'tree\child.bin' 19; $tree = Join-Path $script:Scope 'tree'
    $snapshots = @{}; $snapshots[$tree] = Snapshot-Tree $tree; $snapshots[$otherFile] = Snapshot-Tree $otherFile
    $config = Read-Json $script:Config; $config.volumeRecoveryDirectories[$secondaryDriveRoot] = $secondaryStore; Save-Json $script:Config $config
    $pathsFile = Join-Path $script:CaseRoot 'mixed-volume-paths.json'; Save-Json $pathsFile @($tree, $otherFile)
    $deleted = Invoke-VolumeCli @('delete', '--recursive', '--paths-file', $pathsFile)
    Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $tree) -and !(Test-Path -LiteralPath $otherFile)) 'Mixed-volume input delete failed.'
    $manifest = Read-Json (Join-Path (Join-Path $script:Recovery $deleted.Json.operationId) 'move-manifest.json')
    Assert-True ($manifest.schema -eq 4 -and $manifest.entries.Count -eq 2 -and @($manifest.entries.volumeName | Sort-Object -Unique).Count -eq 2) 'Inputs were not dispatched to distinct volumes.'
    $payloads = @{}
    foreach ($entry in $manifest.entries) {
        $expectedBase = if ($entry.path -ceq $tree) { $script:Store } elseif ($entry.path -ceq $otherFile) { $secondaryStore } else { throw 'Unexpected mixed-volume entry.' }
        Assert-True ($entry.storeRoot.StartsWith($expectedBase + '\', [StringComparison]::OrdinalIgnoreCase)) 'Mixed-volume payload escaped its configured store.'
        $payload = Join-Path (Join-Path $entry.storeRoot $manifest.operationId) $entry.payloadName; $payloads[$entry.path] = $payload
        Assert-Tree $payload $snapshots[$entry.path] -MovedRoot
    }
    [IO.File]::WriteAllText($otherFile, 'existing conflict must survive', $utf8)
    $conflictId = File-Id $otherFile; $conflictHash = Digest $otherFile; $conflictAttributes = [int][IO.File]::GetAttributes($otherFile)
    $conflicted = Invoke-VolumeCli @('restore', $manifest.operationId)
    Assert-True ($conflicted.ExitCode -ne 0) 'Mixed-volume restore overwrote conflict.'
    Assert-FileFacts $otherFile $conflictId $conflictAttributes $conflictHash
    Assert-Tree $payloads[$otherFile] $snapshots[$otherFile] -MovedRoot
    # 衝突fixtureは削除せず、同じsourceディレクトリ内の別名へ退避する。
    Move-Item -LiteralPath $otherFile -Destination (Join-Path $secondarySource 'retained-conflict.bin')
    $restored = Invoke-VolumeCli @('restore', $manifest.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Mixed-volume restore did not resume after conflict was removed.'
    Assert-Tree $tree $snapshots[$tree]; Assert-Tree $otherFile $snapshots[$otherFile]
    foreach ($payload in $payloads.Values) { Assert-True (!(Test-Path -LiteralPath $payload)) 'Mixed-volume restore did not consume payload.' }
    $again = Invoke-VolumeCli @('restore', $manifest.operationId)
    Assert-True ($again.ExitCode -eq 0) 'Consumed mixed-volume restore was not idempotent.'
    Assert-Tree $tree $snapshots[$tree]; Assert-Tree $otherFile $snapshots[$otherFile]
    $maintained = Invoke-VolumeCli @('maintain', '--apply')
    Assert-True ($maintained.ExitCode -eq 0 -and $maintained.Json.capacityKnown) 'Mixed-volume consumed operation left capacity unknown.'
}
if ($Large) {
    Test-Case 'large-32769-files-one-input' {
        $tree = New-Directory (Join-Path $script:Scope 'large')
        for ($i = 0; $i -lt 32769; $i++) { [IO.File]::WriteAllText((Join-Path $tree ('{0:D5}.txt' -f $i)), "entry:$i", $utf8) }
        $snapshot = Snapshot-Tree $tree; $op = Delete-Entry $tree -Recursive
        Assert-True ($op.Manifest.entries.Count -eq 1) 'Large tree expanded manifest.'
        Assert-Tree $op.Payload $snapshot -MovedRoot; Restore-Entry $op $tree; Assert-Tree $tree $snapshot
    }
}
if (!$script:SelectedCount) {
    $results.Add(@{ name = 'case-filter-matched-no-cases'; passed = $false; skipped = $false; error = 'CaseFilter matched no available cases. Check spelling and enable -Large for large cases.'; milliseconds = 0 })
}
$passed = @($results | Where-Object { $_.passed -eq $true }).Count
$skipped = @($results | Where-Object skipped).Count; $failed = $results.Count - $passed - $skipped
$legacySelected = @($results | Where-Object { $_.name -like 'legacy-schema-*' })
$legacyStatus = if (!$LegacyExecutablePath) { 'not-verified-missing-legacy-executable' } elseif (!$legacySelected.Count) { 'not-verified-excluded-by-filter' } elseif (@($legacySelected | Where-Object { $_.passed -ne $true }).Count) { 'failed-or-skipped' } elseif ($legacySelected.Count -lt 9) { 'partial-passed' } else { 'passed' }
Save-Json $ReportPath @{ schema = 1; timestampUtc = [DateTimeOffset]::UtcNow.ToString('O'); executablePath = $ExecutablePath; legacyExecutablePath = $LegacyExecutablePath; legacyCompatibility = @{ status = $legacyStatus; expectedCount = 9; selectedCount = $legacySelected.Count; excludedCount = 9 - $legacySelected.Count }; large = [bool]$Large; secondaryVolumeDirectory = $SecondaryVolumeDirectory; caseFilter = $CaseFilter; selectedCount = $script:SelectedCount; excludedCount = $script:ExcludedCount; passed = $passed; failed = $failed; skipped = $skipped; results = @($results); interruptionEvidence = 'Reconstructed valid metadata and object positions; no timing kill of native rename.'; retainedDirectory = $outputRoot }
[ordered]@{ passed = $passed; failed = $failed; skipped = $skipped; excludedCount = $script:ExcludedCount; legacyCompatibility = $legacyStatus; reportPath = $ReportPath } | ConvertTo-Json
if ($failed) { exit 1 }
exit 0
