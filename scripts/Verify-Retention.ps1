[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All paths must be absolute.' }
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$report = [IO.Path]::GetFullPath($ReportPath)
foreach ($destination in @($outputRoot, $report)) {
    foreach ($forbidden in @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))) {
        if ($destination.Equals($forbidden, [StringComparison]::OrdinalIgnoreCase) -or $destination.StartsWith($forbidden.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Verification output must be external.' }
    }
    $ancestor = $destination
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Verification output must not traverse links.' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
}
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable not found.' }
if ((Test-Path -LiteralPath $outputRoot) -or (Test-Path -LiteralPath $report)) { throw 'OutputDirectory and ReportPath must be new.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($report))) { throw 'Create the report parent first.' }
$null = [IO.Directory]::CreateDirectory($outputRoot)
$results = [Collections.Generic.List[object]]::new()
$commands = [Collections.Generic.List[object]]::new()
$script:CaseRoot = $null; $script:Config = $null; $script:Recovery = $null

# 想定する失敗: 旧設定の既定値欠落、期限の誤判定、容量整理の順序違反、dry-runの変更、
# 大きすぎる入力の部分削除、破損・稼働中コピーの削除、ADSの過少計上、未知項目の追跡、
# 整理後の復元成功、繰り返し実行時の記録増殖。各ケースを独立した復元先で検証する。
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Digest([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}
function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false)) }
function Invoke-Cli([string[]]$Arguments) {
    $values = @('--config', $script:Config) + $Arguments
    foreach ($value in @($ExecutablePath) + $values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD argument.' } }
    $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + (($values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $outputRoot 'runtime-cache'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(60000)) { $process.Kill($true); $process.WaitForExit(); throw 'CLI timed out.' }
        $raw = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
        $json = if ($raw.Trim()) { $raw | ConvertFrom-Json -Depth 50 } else { $null }
        $commands.Add(@{ case = [IO.Path]::GetFileName($script:CaseRoot); arguments = $Arguments; exitCode = $process.ExitCode; response = $json; stderr = $errorText })
        return @{ ExitCode = $process.ExitCode; Json = $json }
    } finally { $process.Dispose() }
}
function New-Case([string]$Name) {
    $script:CaseRoot = Join-Path $outputRoot $Name
    $script:Recovery = Join-Path $script:CaseRoot 'recovery'
    $script:Config = Join-Path $script:CaseRoot 'config.json'
    $null = [IO.Directory]::CreateDirectory($script:Recovery)
    $init = Invoke-Cli @('init', '--backup-directory', $script:Recovery)
    Assert-True ($init.ExitCode -eq 0) 'Initialization failed.'
}
function Set-Policy([long]$Budget = 10737418240, [int]$Days = 7) {
    $config = [IO.File]::ReadAllText($script:Config) | ConvertFrom-Json -AsHashtable
    $config.retentionDays = $Days; $config.maxRecoveryBytes = $Budget
    Save-Json $script:Config $config
}
function New-Source([string]$Name, [int]$Bytes = 64) {
    $path = Join-Path $script:CaseRoot $Name
    [IO.File]::WriteAllBytes($path, [byte[]](1..$Bytes | ForEach-Object { $_ % 251 }))
    return $path
}
function Delete-Source([string]$Path, [switch]$Recursive) {
    $arguments = @('delete'); if ($Recursive) { $arguments += '--recursive' }; $arguments += @('--', $Path)
    $result = Invoke-Cli $arguments
    Assert-True ($result.ExitCode -eq 0 -and !(Test-Path -LiteralPath $Path)) 'Fixture delete failed.'
    return (Join-Path $script:Recovery $result.Json.operationId)
}
function Set-Age([string]$Root, [double]$Days) {
    $path = Join-Path $Root 'manifest.json'; $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $manifest.createdUtc = [DateTimeOffset]::UtcNow.AddDays(-$Days).ToString('O'); Save-Json $path $manifest
}
function Backups([string]$Root) { return ,@([IO.Directory]::EnumerateFiles($Root, '*.bak')) }
function Snapshot([string]$Root) {
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Digest $_.FullName) }) -join '|')
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { New-Case $Name; & $Body; $results.Add(@{ name = $Name; passed = $true }) }
    catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message }); Write-Warning "$Name : $($_.Exception.Message)" }
}

Test-Case 'old-config-defaults-expiry-and-repeat' {
    $config = [IO.File]::ReadAllText($script:Config) | ConvertFrom-Json -AsHashtable
    Assert-True ($config.retentionDays -eq 7 -and $config.maxRecoveryBytes -eq 10737418240) 'Init did not persist the 7 day / 10 GiB defaults.'
    $null = $config.Remove('retentionDays'); $null = $config.Remove('maxRecoveryBytes'); Save-Json $script:Config $config
    $old = Delete-Source (New-Source 'old.txt'); $fresh = Delete-Source (New-Source 'fresh.txt')
    Set-Age $old 8; Set-Age $fresh 6
    $snapshot = Snapshot $script:Recovery
    $dry = Invoke-Cli @('maintain', '--dry-run')
    Assert-True ($dry.ExitCode -eq 0 -and (Snapshot $script:Recovery) -ceq $snapshot) 'Maintenance dry-run changed recovery data.'
    Assert-True ($dry.Json.retentionDays -eq 7 -and $dry.Json.maxRecoveryBytes -eq 10737418240 -and $dry.Json.retainedBytesBefore -eq 128 -and $dry.Json.retainedBytesAfter -eq 64 -and $dry.Json.plannedPurgeBytes -eq 64 -and $dry.Json.purgedBytes -eq 0) 'Legacy defaults or dry-run byte accounting were incorrect.'
    $apply = Invoke-Cli @('maintain', '--apply')
    Assert-True ($apply.ExitCode -eq 0 -and (Backups $old).Count -eq 0 -and (Backups $fresh).Count -eq 1) 'Old-config expiry did not preserve fresh recovery.'
    foreach ($name in @('manifest.json', 'operation.lock', 'delete-result.json')) { Assert-True ([IO.File]::Exists((Join-Path $old $name))) 'Maintenance removed audit metadata.' }
    $restore = Invoke-Cli @('restore', [IO.Path]::GetFileName($old))
    Assert-True ($restore.ExitCode -ne 0 -and ![IO.File]::Exists((Join-Path $script:CaseRoot 'old.txt'))) 'Purged recovery was restored.'
    $snapshot = Snapshot $script:Recovery
    foreach ($index in 1..3) { $again = Invoke-Cli @('maintain', '--apply'); Assert-True ($again.ExitCode -eq 0) 'Repeat maintain failed.' }
    Assert-True ((Snapshot $script:Recovery) -ceq $snapshot) 'Repeated maintenance changed or accumulated metadata.'
}
Test-Case 'capacity-oldest-first-within-retention' {
    $old = Delete-Source (New-Source 'older.txt'); $fresh = Delete-Source (New-Source 'newer.txt')
    Set-Age $old 2; Set-Age $fresh 1; Set-Policy 64
    $apply = Invoke-Cli @('maintain', '--apply')
    Assert-True ($apply.ExitCode -eq 0 -and (Backups $old).Count -eq 0 -and (Backups $fresh).Count -eq 1) 'Capacity did not remove oldest recovery first.'
}
Test-Case 'automatic-expiry-before-delete' {
    $old = Delete-Source (New-Source 'expired.txt'); Set-Age $old 8
    $fresh = Delete-Source (New-Source 'incoming.txt')
    Assert-True ((Backups $old).Count -eq 0 -and (Backups $fresh).Count -eq 1) 'Real delete did not apply expiry.'
}
foreach ($emptySchema in @(1, 3)) {
Test-Case "zero-byte-schema-$emptySchema-recovery-expires-and-repeat-is-idempotent" {
    $source = Join-Path $script:CaseRoot 'empty.txt'; [IO.File]::WriteAllBytes($source, [byte[]]@())
    if ($emptySchema -eq 3) { [IO.File]::WriteAllBytes($source + ':empty', [byte[]]@()) }
    $old = Delete-Source $source; $backup = (Backups $old)[0]
    $manifest = [IO.File]::ReadAllText((Join-Path $old 'manifest.json')) | ConvertFrom-Json
    Assert-True ($manifest.schema -eq $emptySchema) 'Expected zero-byte recovery schema was not exercised.'
    Assert-True ([IO.File]::Exists($backup) -and (Get-Item -LiteralPath $backup).Length -eq 0) 'Fixture did not persist an empty recovery copy.'
    Set-Age $old 8
    $apply = Invoke-Cli @('maintain', '--apply')
    Assert-True ($apply.ExitCode -eq 0 -and (Backups $old).Count -eq 0) 'Expired zero-byte recovery copy was retained.'
    $restore = Invoke-Cli @('restore', [IO.Path]::GetFileName($old))
    Assert-True ($restore.ExitCode -ne 0 -and ![IO.File]::Exists($source)) 'Expired empty recovery was restored.'
    $snapshot = Snapshot $script:Recovery
    $again = Invoke-Cli @('maintain', '--apply')
    Assert-True ($again.ExitCode -eq 0 -and (Snapshot $script:Recovery) -ceq $snapshot) 'Repeated empty-copy maintenance accumulated metadata.'
}
}
Test-Case 'automatic-capacity-before-delete' {
    $old = Delete-Source (New-Source 'older.txt'); Set-Age $old 1; Set-Policy 64
    $fresh = Delete-Source (New-Source 'incoming.txt')
    Assert-True ((Backups $old).Count -eq 0 -and (Backups $fresh).Count -eq 1) 'Real delete exceeded the recovery budget.'
}
Test-Case 'oversized-input-preserves-source-and-existing-recovery' {
    $old = Delete-Source (New-Source 'retained.txt' 32); Set-Age $old 8; Set-Policy 64
    $source = New-Source 'oversized.txt' 65; $hash = Digest $source; $snapshot = Snapshot $script:Recovery
    $result = Invoke-Cli @('delete', '--', $source)
    Assert-True ($result.ExitCode -ne 0 -and [IO.File]::Exists($source) -and (Digest $source) -ceq $hash) 'Oversized source was changed.'
    Assert-True ((Snapshot $script:Recovery) -ceq $snapshot) 'Impossible incoming request discarded old recovery.'
}
Test-Case 'delete-dry-run-preserves-expired-recovery' {
    $old = Delete-Source (New-Source 'expired.txt'); Set-Age $old 8; Set-Policy 64
    $source = New-Source 'incoming.txt'; $snapshot = Snapshot $script:Recovery
    $dry = Invoke-Cli @('delete', '--dry-run', '--', $source)
    Assert-True ($dry.ExitCode -eq 0 -and [IO.File]::Exists($source) -and (Snapshot $script:Recovery) -ceq $snapshot) 'Delete dry-run mutated recovery or input.'
}
Test-Case 'corrupt-recovery-retained-and-budget-blocks-delete' {
    $old = Delete-Source (New-Source 'corrupt.txt'); Set-Age $old 8
    $backup = (Backups $old)[0]; [IO.File]::WriteAllBytes($backup, [byte[]](2..65)); $hash = Digest $backup
    Set-Policy 64
    $apply = Invoke-Cli @('maintain', '--apply')
    Assert-True ([IO.File]::Exists($backup) -and (Digest $backup) -ceq $hash) 'Corrupt recovery was discarded.'
    Assert-True (@($apply.Json.warnings).Count -gt 0 -or $apply.ExitCode -ne 0) 'Corrupt recovery produced no warning.'
    $source = New-Source 'incoming.txt'; $result = Invoke-Cli @('delete', '--', $source)
    Assert-True ($result.ExitCode -ne 0 -and [IO.File]::Exists($source) -and (Digest $backup) -ceq $hash) 'Uncollectable recovery allowed budget overflow.'
}
Test-Case 'active-operation-lock-retained' {
    $old = Delete-Source (New-Source 'locked.txt'); Set-Age $old 8
    $backup = (Backups $old)[0]; $hash = Digest $backup
    $lock = [IO.File]::Open((Join-Path $old 'operation.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $result = Invoke-Cli @('maintain', '--apply')
        Assert-True ([IO.File]::Exists($backup) -and (Digest $backup) -ceq $hash) 'Active operation was purged.'
        Assert-True (@($result.Json.warnings).Count -gt 0 -or $result.ExitCode -ne 0) 'Active operation produced no warning.'
        Set-Policy 64; $source = New-Source 'incoming.txt'; $delete = Invoke-Cli @('delete', '--', $source)
        Assert-True ($delete.ExitCode -ne 0 -and [IO.File]::Exists($source)) 'Active operation permitted budget overflow.'
    } finally { $lock.Dispose() }
    $retry = Invoke-Cli @('maintain', '--apply')
    Assert-True ($retry.ExitCode -eq 0 -and (Backups $old).Count -eq 0) 'Released operation could not be maintained.'
}
Test-Case 'failed-unverified-copy-is-retained' {
    $old = Delete-Source (New-Source 'failed.txt'); Set-Age $old 8
    $path = Join-Path $old 'manifest.json'; $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $manifest.items[0].state = 'failed'; $manifest.items[0].sha256 = $null; Save-Json $path $manifest
    $backup = (Backups $old)[0]; $hash = Digest $backup
    $result = Invoke-Cli @('maintain', '--apply')
    Assert-True ([IO.File]::Exists($backup) -and (Digest $backup) -ceq $hash) 'Unverified incomplete recovery was discarded automatically.'
    Assert-True (@($result.Json.warnings).Count -gt 0 -or $result.ExitCode -ne 0) 'Incomplete recovery produced no warning.'
}
foreach ($schema in @(2, 3)) {
    Test-Case "schema-$schema-tree-expiry-and-ads-accounting" {
        $tree = Join-Path $script:CaseRoot 'tree'; $null = [IO.Directory]::CreateDirectory($tree)
        $source = Join-Path $tree 'payload.txt'; [IO.File]::WriteAllBytes($source, [byte[]](1..64))
        if ($schema -eq 3) { [IO.File]::WriteAllBytes($source + ':custom', [byte[]](1..64)) }
        $root = Delete-Source $tree -Recursive
        $manifest = [IO.File]::ReadAllText((Join-Path $root 'manifest.json')) | ConvertFrom-Json
        Assert-True ($manifest.schema -eq $schema) 'Expected schema was not exercised.'
        Set-Policy 100
        $result = Invoke-Cli @('maintain', '--apply')
        Assert-True ($result.ExitCode -eq 0) 'Schema maintenance failed.'
        Assert-True ((Backups $root).Count -eq $(if ($schema -eq 3) { 0 } else { 1 })) 'ADS payload bytes were not counted correctly.'
        if ($schema -eq 2) { Set-Age $root 8; $result = Invoke-Cli @('maintain', '--apply'); Assert-True ($result.ExitCode -eq 0 -and (Backups $root).Count -eq 0) 'Schema 2 expiry failed.' }
    }
}
Test-Case 'unknown-root-entry-is-retained-and-counted' {
    $unknown = Join-Path $script:Recovery 'unrecognized'; $null = [IO.Directory]::CreateDirectory($unknown)
    $payload = Join-Path $unknown 'payload'; [IO.File]::WriteAllBytes($payload, [byte[]](1..64)); $hash = Digest $payload
    Set-Policy 64; $result = Invoke-Cli @('maintain', '--apply')
    Assert-True ([IO.File]::Exists($payload) -and (Digest $payload) -ceq $hash) 'Unknown recovery member was removed.'
    Assert-True (@($result.Json.warnings).Count -gt 0 -or $result.ExitCode -ne 0) 'Unknown member produced no warning.'
    $source = New-Source 'incoming.txt'; $delete = Invoke-Cli @('delete', '--', $source)
    Assert-True ($delete.ExitCode -ne 0 -and [IO.File]::Exists($source)) 'Unknown recovery bytes were omitted from the budget.'
}
foreach ($metadataKind in @('directory', 'ads')) {
    Test-Case "metadata-name-$metadataKind-cannot-bypass-capacity" {
        $root = Delete-Source (New-Source 'retained.txt'); Set-Age $root 8
        $backup = (Backups $root)[0]; $backupHash = Digest $backup
        if ($metadataKind -eq 'directory') {
            $fake = Join-Path $root ('restore-result-' + [guid]::NewGuid().ToString('N') + '.json')
            $null = [IO.Directory]::CreateDirectory($fake)
            $hiddenPayload = Join-Path $fake 'payload.bin'
        } else { $hiddenPayload = (Join-Path $root 'manifest.json') + ':payload' }
        [IO.File]::WriteAllBytes($hiddenPayload, [byte[]](1..64)); $payloadHash = Digest $hiddenPayload
        Set-Policy 64
        $maintain = Invoke-Cli @('maintain', '--apply')
        Assert-True ($maintain.ExitCode -ne 0 -and !$maintain.Json.capacityKnown -and @($maintain.Json.warnings).Count -gt 0) 'Non-ordinary metadata was excluded from capacity without warning.'
        Assert-True ([IO.File]::Exists($backup) -and (Digest $backup) -ceq $backupHash -and (Digest $hiddenPayload) -ceq $payloadHash) 'Unsafe metadata inspection modified recovery payload.'
        $source = New-Source 'incoming.txt'; $hash = Digest $source
        $delete = Invoke-Cli @('delete', '--', $source)
        Assert-True ($delete.ExitCode -ne 0 -and [IO.File]::Exists($source) -and (Digest $source) -ceq $hash) 'Disguised metadata permitted a new recovery copy.'
        Assert-True ((Digest $hiddenPayload) -ceq $payloadHash -and (Digest $backup) -ceq $backupHash) 'Rejected delete changed disguised metadata or its recovery copy.'
    }
}
Test-Case 'empty-default-maintain-is-read-only' {
    $snapshot = Snapshot $script:Recovery
    $result = Invoke-Cli @('maintain')
    Assert-True ($result.ExitCode -eq 0 -and $result.Json.dryRun -and (Snapshot $script:Recovery) -ceq $snapshot) 'Default maintain created a lock or changed empty recovery.'
}
Test-Case 'recovery-root-ads-counts-against-budget' {
    $payload = $script:Recovery + ':payload'; [IO.File]::WriteAllBytes($payload, [byte[]](1..64)); $hash = Digest $payload
    Set-Policy 32
    $maintain = Invoke-Cli @('maintain', '--apply')
    Assert-True ($maintain.ExitCode -ne 0 -and $maintain.Json.retainedBytesBefore -ge 64 -and !$maintain.Json.budgetSatisfied) 'Recovery-root ADS bytes were omitted from the budget.'
    Assert-True ((Digest $payload) -ceq $hash) 'Maintenance changed the root ADS.'
    $source = New-Source 'incoming.txt' 16; $sourceHash = Digest $source
    $delete = Invoke-Cli @('delete', '--', $source)
    Assert-True ($delete.ExitCode -ne 0 -and [IO.File]::Exists($source) -and (Digest $source) -ceq $sourceHash -and (Digest $payload) -ceq $hash) 'Root ADS permitted a new copy or was removed.'
}
Test-Case 'reparse-root-does-not-follow-target' {
    $outside = Join-Path $script:CaseRoot 'outside'; $null = [IO.Directory]::CreateDirectory($outside)
    $payload = Join-Path $outside 'payload'; [IO.File]::WriteAllBytes($payload, [byte[]](1..64)); $hash = Digest $payload
    $junction = Join-Path $script:Recovery ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Junction -Path $junction -Target $outside
    $result = Invoke-Cli @('maintain', '--apply')
    Assert-True ([IO.Directory]::Exists($junction) -and [IO.File]::Exists($payload) -and (Digest $payload) -ceq $hash) 'Maintenance followed or removed a recovery reparse point.'
    Assert-True (!$result.Json.capacityKnown -and @($result.Json.warnings).Count -gt 0) 'Reparse recovery root was silently trusted.'
}
Test-Case 'resume-partially-applied-purge-intent' {
    $first = New-Source 'first.txt'; $second = New-Source 'second.txt'
    $deleted = Invoke-Cli @('delete', '--', $first, $second)
    Assert-True ($deleted.ExitCode -eq 0) 'Fixture delete failed.'
    $root = Join-Path $script:Recovery $deleted.Json.operationId; Set-Age $root 8
    $manifestPath = Join-Path $root 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $targets = @(foreach ($index in 0..1) { @{ index = $index; size = $manifest.items[$index].size; sha256 = $manifest.items[$index].sha256 } })
    $intentPath = Join-Path $root 'purge-intent.json'
    Save-Json $intentPath @{ schema = 1; operationId = $deleted.Json.operationId; manifestSha256 = Digest $manifestPath; createdUtc = [DateTimeOffset]::UtcNow.ToString('O'); targets = $targets }
    $intentHash = Digest $intentPath
    # 別の隔離設定でCoreに先頭コピーを削除させ、intent永続化後の途中終了状態を再現する。
    $originalConfig = $script:Config
    $scratch = Join-Path $script:CaseRoot 'crash-fixture-recovery'; $null = [IO.Directory]::CreateDirectory($scratch)
    try {
        $script:Config = Join-Path $script:CaseRoot 'crash-fixture-config.json'
        $init = Invoke-Cli @('init', '--backup-directory', $scratch); Assert-True ($init.ExitCode -eq 0) 'Crash fixture init failed.'
        $remove = Invoke-Cli @('delete', '--', (Join-Path $root '0000.bak'))
        Assert-True ($remove.ExitCode -eq 0 -and ![IO.File]::Exists((Join-Path $root '0000.bak'))) 'Crash fixture could not remove the first published target.'
    } finally { $script:Config = $originalConfig }
    $result = Invoke-Cli @('maintain', '--apply')
    Assert-True ($result.ExitCode -eq 0 -and (Backups $root).Count -eq 0 -and (Digest $intentPath) -ceq $intentHash) 'Partial purge did not resume from its persisted intent.'
}
Test-Case 'concurrent-deletes-share-one-capacity-budget' {
    Set-Policy 1048576
    foreach ($round in 1..3) {
        $processes = @(); $data = [byte[]]::new(1048576); [Random]::new($round).NextBytes($data)
        try {
            foreach ($index in 1..2) {
                $source = Join-Path $script:CaseRoot "parallel-$round-$index.bin"; [IO.File]::WriteAllBytes($source, $data); $hash = Digest $source
                $values = @('--config', $script:Config, 'delete', '--', $source)
                foreach ($value in @($ExecutablePath) + $values) { if ($value -match '["%&|<>^!\r\n]') { throw 'Unsafe CMD argument.' } }
                $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe'); $info.UseShellExecute = $false; $info.CreateNoWindow = $true
                $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
                $info.Arguments = '/d /s /c ""' + $ExecutablePath + '" ' + (($values | ForEach-Object { '"' + $_ + '"' }) -join ' ') + '"'
                $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $outputRoot 'runtime-cache'
                $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; $null = $process.Start()
                $processes += @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync(); source = $source; hash = $hash }
            }
            $successes = 0
            foreach ($entry in $processes) {
                $process = $entry.process
                if (!$process.WaitForExit(60000)) { $process.Kill($true); $process.WaitForExit(); throw 'Concurrent delete timed out.' }
                $json = $entry.stdout.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 50
                $commands.Add(@{ case = 'concurrent-deletes-share-one-capacity-budget'; arguments = @('delete', $entry.source); exitCode = $process.ExitCode; response = $json; stderr = $entry.stderr.GetAwaiter().GetResult() })
                if ($process.ExitCode -eq 0) { $successes++; Assert-True (![IO.File]::Exists($entry.source)) 'Successful concurrent delete retained its source.' }
                else { Assert-True ([IO.File]::Exists($entry.source) -and (Digest $entry.source) -ceq $entry.hash) 'Rejected concurrent delete changed its source.' }
            }
            $bytes = (Get-ChildItem -LiteralPath $script:Recovery -Recurse -Filter '*.bak' -File | Measure-Object Length -Sum).Sum
            Assert-True ($successes -ge 1 -and $bytes -le 1048576) 'Concurrent deletes exceeded the shared recovery budget or both failed.'
        } finally { foreach ($entry in $processes) { if (!$entry.process.HasExited) { $entry.process.Kill($true); $entry.process.WaitForExit() }; $entry.process.Dispose() } }
    }
}

$passed = @($results | Where-Object passed).Count; $failed = $results.Count - $passed
Save-Json $report @{ executable = $ExecutablePath; outputDirectory = $outputRoot; passed = $passed; failed = $failed; cases = @($results); commands = @($commands) }
Write-Output ($report)
Write-Output "passed=$passed failed=$failed"
if ($failed) { exit 1 }
