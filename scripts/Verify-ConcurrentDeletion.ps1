[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$BaselineExecutablePath,
    [string]$LegacyHardlinkExecutablePath,
    [ValidateNotNullOrEmpty()][string[]]$CaseFilter = @('*'),
    [ValidateRange(1000, 100000)][int]$HeavyFileCount = 10000,
    [ValidateRange(90, 1800)][int]$ProcessTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
# コード作成前に列挙した失敗条件:
# 独立rootの直列化、同path/ancestor競合による別実体の削除、invalidを含むbatchの部分変更、
# 結果順/manifest hash/receiptの混線、MCP token混入・最終応答後通知・EOFでの未処理破棄、
# maintenanceの60秒timeout/共有中のexclusive侵入、復元時のID/内容/O/G/D/ADS欠落・上書き、
# 外部hardlinkの破損、旧版比較の試行不足を失敗とする。
# 単一batchのShell呼出しの重なりは速度から推測せず、別途観測が必要な未検証項目にする。
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $BaselineExecutablePath, $LegacyHardlinkExecutablePath) | Where-Object { $_ }) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Executable and output paths must be absolute.' }
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
foreach ($path in @($outputRoot, $ReportPath)) {
    Assert-VerificationDestination $path @($repoRoot, $codexRoot)
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Concurrency verification requires external D: output.' }
    if (Test-Path -LiteralPath $path) { throw 'Output and report must be new.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create output/report parents first.' }
}
if (![IO.File]::Exists($ExecutablePath)) { throw 'Executable not found.' }
$null = [IO.Directory]::CreateDirectory($outputRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()
$script:ExcludedCount = 0
function Assert-True([bool]$Value, [string]$Message) { if (!$Value) { throw $Message } }
function Save-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 80), $utf8) }
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 80 }
function New-Directory([string]$Path) { $null = [IO.Directory]::CreateDirectory($Path); return $Path }
function New-File([string]$Name) {
    $path = Join-Path $script:Scope $Name
    $null = New-Directory ([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, 'Prunlet concurrency fixture: ' + $Name, $utf8)
    return $path
}
function Start-Child([string[]]$Arguments, [string]$Exe = $ExecutablePath) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8; $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    $info.WorkingDirectory = $script:CaseRoot
    $info.Environment['TEMP'] = Join-Path $script:CaseRoot 'temp'
    $info.Environment['TMP'] = Join-Path $script:CaseRoot 'temp'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $script:CaseRoot 'runtime-cache'
    foreach ($argument in @('--config', $script:Config) + $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start()
    $session = @{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync(); Arguments = $Arguments; Exe = $Exe; Timer = [Diagnostics.Stopwatch]::StartNew() }
    $script:Sessions.Add($session)
    return $session
}
function Complete-Child($Session) {
    $process = $Session.Process
    $process.StandardInput.Close()
    if (!$process.WaitForExit($ProcessTimeoutSeconds * 1000)) { throw 'Owned child timed out.' }
    $stdout = $Session.Out.GetAwaiter().GetResult(); $stderr = $Session.Err.GetAwaiter().GetResult()
    $prefix = Join-Path $script:CaseRoot ('process-' + $process.Id)
    [IO.File]::WriteAllText($prefix + '.stdout.txt', $stdout, $utf8)
    [IO.File]::WriteAllText($prefix + '.stderr.txt', $stderr, $utf8)
    Save-Json ($prefix + '.json') @{ executable = $Session.Exe; arguments = $Session.Arguments; exitCode = $process.ExitCode; milliseconds = $Session.Timer.Elapsed.TotalMilliseconds }
    return @{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr; Json = $(if ($stdout.Trim()) { $stdout | ConvertFrom-Json -AsHashtable -Depth 80 } else { $null }); Milliseconds = $Session.Timer.Elapsed.TotalMilliseconds }
}
function Invoke-Cli([string[]]$Arguments, [string]$Exe = $ExecutablePath) { Complete-Child (Start-Child $Arguments $Exe) }
function Start-Delete([string[]]$Paths, [switch]$Recursive, [string]$Exe = $ExecutablePath) {
    $list = Join-Path $script:CaseRoot ('paths-' + [guid]::NewGuid().ToString('N') + '.json')
    Save-Json $list @($Paths)
    $arguments = @('delete'); if ($Recursive) { $arguments += '--recursive' }
    Start-Child ($arguments + @('--paths-file', $list)) $Exe
}
function Snapshot([string]$Path) {
    @{ path = $Path; id = [PrunletConcurrentNative]::Identity($Path); hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
       security = [Convert]::ToBase64String([PrunletConcurrentNative]::Security($Path)); ads = [IO.File]::ReadAllText($Path + ':concurrent')
       attributes = [int][IO.File]::GetAttributes($Path); links = [PrunletConcurrentNative]::Links($Path) }
}
function Assert-Snapshot($Snapshot) {
    $actual = Snapshot $Snapshot.path
    foreach ($key in @('id', 'hash', 'security', 'ads', 'attributes', 'links')) { Assert-True ($actual[$key] -ceq $Snapshot[$key]) "Restored $key differs: $($Snapshot.path)" }
}
function Assert-Deleted($Result, [string[]]$Paths) {
    Assert-True ($Result.ExitCode -eq 0) "Delete failed: $($Result.Stderr) $($Result.Stdout)"
    Assert-True ($Result.Json.items.Count -eq $Paths.Count) 'Result count differs.'
    $root = Join-Path $script:Recovery $Result.Json.operationId
    $manifestPath = Join-Path $root 'recycle-manifest.json'; $manifest = Read-Json $manifestPath
    $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    for ($i = 0; $i -lt $Paths.Count; $i++) {
        Assert-True (!(Test-Path -LiteralPath $Paths[$i]) -and $Result.Json.items[$i].status -eq 'deleted') 'Expected deleted original is present or result is not deleted.'
        Assert-True ($Result.Json.items[$i].path -ceq $Paths[$i]) 'Result input order changed.'
        Assert-True ($manifest.entries[$i].path -ieq $Paths[$i]) 'Manifest input order changed.'
        $receipt = Read-Json (Join-Path $root ('recycle-{0:D4}-complete.json' -f $i))
        Assert-True ($receipt.operationId -ceq $Result.Json.operationId -and $receipt.manifestSha256 -ieq $hash) 'Receipt is bound to a different operation or manifest.'
        Assert-True ($receipt.identity.fileId -ieq $manifest.entries[$i].identity.fileId -and (Test-Path -LiteralPath $receipt.physicalPath)) 'Receipt identity/payload missing.'
    }
}
function Restore-Result($Result) {
    $restore = Invoke-Cli @('restore', $Result.Json.operationId)
    Assert-True ($restore.ExitCode -eq 0 -and @($restore.Json.items | Where-Object status -ne 'restored').Count -eq 0) "Restore failed: $($restore.Stdout) $($restore.Stderr)"
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    if (!@($CaseFilter | Where-Object { $Name -like $_ }).Count) { $script:ExcludedCount++; return }
    $script:CaseRoot = New-Directory (Join-Path $outputRoot $Name)
    $script:Scope = New-Directory (Join-Path $script:CaseRoot 'scope')
    $script:Recovery = New-Directory (Join-Path $script:CaseRoot 'metadata')
    $script:Config = Join-Path $script:CaseRoot 'config.json'
    $null = New-Directory (Join-Path $script:CaseRoot 'temp'); $null = New-Directory (Join-Path $script:CaseRoot 'runtime-cache')
    $script:Sessions = [Collections.Generic.List[object]]::new(); $script:Evidence = @{}; $script:SkipReason = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Assert-True ((Invoke-Cli @('init', '--backup-directory', $script:Recovery)).ExitCode -eq 0) 'Init failed.'
        $fixtureConfig = Read-Json $script:Config
        $fixtureConfig.volumeRecoveryDirectories = @{ 'D:\' = (Join-Path $script:CaseRoot 'volume-store') }
        Save-Json $script:Config $fixtureConfig
        & $Body
        $results.Add(@{ name = $Name; passed = $(if ($script:SkipReason) { $null } else { $true }); skipped = [bool]$script:SkipReason; note = $script:SkipReason; observed = $script:Evidence; milliseconds = $clock.Elapsed.TotalMilliseconds })
    } catch {
        $results.Add(@{ name = $Name; passed = $false; skipped = $false; error = $_.Exception.Message; location = $_.InvocationInfo.PositionMessage; stack = $_.ScriptStackTrace; observed = $script:Evidence })
        Write-Warning "$Name : $($_.Exception.Message)"
    } finally {
        foreach ($session in $script:Sessions) {
            try { if (!$session.Process.HasExited) { $session.Process.Kill($true); $session.Process.WaitForExit() } } finally { $session.Process.Dispose() }
        }
    }
}
$compileTemp = New-Directory (Join-Path $outputRoot 'compile-temp')
$previousTemp = $env:TEMP; $previousTmp = $env:TMP
try {
    $env:TEMP = $compileTemp; $env:TMP = $compileTemp
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Threading;
using Microsoft.Win32.SafeHandles;
public static class PrunletConcurrentNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string p, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int c, byte[] b, uint n);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetKernelObjectSecurity(SafeFileHandle h, uint i, byte[] b, uint n, out uint needed);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateHardLinkW(string a, string b, IntPtr s);
    [DllImport("ntdll.dll")] static extern int NtSetSecurityObject(SafeFileHandle h, uint information, byte[] descriptor);
    public static void Link(string alias, string source) { if (!CreateHardLinkW(alias, source, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static string Identity(string p) { using(var h=CreateFileW(p,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) { byte[] b=new byte[24]; if(h.IsInvalid || !GetFileInformationByHandleEx(h,18,b,24)) throw new Win32Exception(Marshal.GetLastWin32Error()); return BitConverter.ToString(b); } }
    public static uint Links(string p) { using(var h=CreateFileW(p,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) { byte[] b=new byte[24]; if(h.IsInvalid || !GetFileInformationByHandleEx(h,1,b,24)) throw new Win32Exception(Marshal.GetLastWin32Error()); return BitConverter.ToUInt32(b,16); } }
    public static byte[] Security(string p) { using(var h=CreateFileW(p,0x20000,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) { if(h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error()); uint n; GetKernelObjectSecurity(h,7,null,0,out n); byte[] b=new byte[n]; if(!GetKernelObjectSecurity(h,7,b,n,out n)) throw new Win32Exception(Marshal.GetLastWin32Error()); return b; } }
    // fixtureのDACL改変と既知bytesへの復帰だけに使う。検証値は別のnative読取で比較する。
    public static void FixtureDacl(string p,byte[] bytes) { var descriptor=new RawSecurityDescriptor(bytes,0); if((descriptor.ControlFlags&ControlFlags.DiscretionaryAclAutoInherited)!=0)descriptor.SetFlags(descriptor.ControlFlags|ControlFlags.DiscretionaryAclAutoInheritRequired);byte[] input=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(input,0);using(var h=CreateFileW(p,0x60000,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)){if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());int status=NtSetSecurityObject(h,4,input);if(status<0)throw new IOException("Fixture DACL mutation NTSTATUS "+status);} }
}
public sealed class PrunletConcurrentGate : IDisposable {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(SafeProcessHandle p);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(SafeProcessHandle p);
    readonly FileSystemWatcher watcher;
    readonly ManualResetEventSlim bound=new ManualResetEventSlim(false), reached=new ManualResetEventSlim(false);
    Process process; int matched; public bool Suspended { get; private set; } public string Error { get; private set; } public string ObservedPath { get; private set; }
    public PrunletConcurrentGate(string root) : this(root,"recycle-manifest.json") { }
    public PrunletConcurrentGate(string root,string filter) { watcher=new FileSystemWatcher(root,filter){IncludeSubdirectories=true}; watcher.Created+=(s,e)=>Observe(e.FullPath); watcher.Renamed+=(s,e)=>Observe(e.FullPath); watcher.Error+=(s,e)=>{Error=e.GetException().Message;reached.Set();}; watcher.EnableRaisingEvents=true; }
    void Observe(string p) { if(Interlocked.CompareExchange(ref matched,1,0)!=0)return; try { if(!bound.Wait(10000))throw new IOException("Owned process not bound."); int status=NtSuspendProcess(process.SafeHandle); if(status<0)throw new IOException("Suspend NTSTATUS "+status); Suspended=true;ObservedPath=p; }catch(Exception e){Error=e.Message;}finally{reached.Set();} }
    public void Bind(Process p) {process=p;bound.Set();} public bool Wait(int ms){return reached.Wait(ms);}
    public void Resume(){if(!Suspended)return;if(!process.HasExited && NtResumeProcess(process.SafeHandle)<0)throw new IOException("Cannot resume owned process.");Suspended=false;}
    public void Dispose(){watcher.Dispose();try{Resume();}finally{bound.Dispose();reached.Dispose();}}
}
'@
} finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }

foreach ($relation in @('independent', 'same', 'parent-child', 'child-parent')) {
    Test-Case ('process-claims-' + $relation) {
        $child = New-File 'a\child.txt'; $parent = Split-Path -Parent $child
        $aPath = if ($relation -eq 'child-parent') { $child } else { $parent }
        $bPath = switch ($relation) { 'independent' { New-File 'b.txt' }; 'same' { $parent }; 'parent-child' { $child }; 'child-parent' { $parent } }
        $gate = [PrunletConcurrentGate]::new($script:Recovery)
        try {
            $a = Start-Delete @($aPath) -Recursive; $gate.Bind($a.Process)
            Assert-True ($gate.Wait(30000) -and $gate.Suspended -and !$gate.Error) "Cannot suspend A at manifest publication: $($gate.Error)"
            $script:Evidence.suspendedManifest = $gate.ObservedPath; $script:Evidence.aPid = $a.Process.Id
            $b = Start-Delete @($bPath) -Recursive
            if ($relation -eq 'independent') {
                Assert-True ($b.Process.WaitForExit(20000)) 'Independent B blocked behind suspended A.'
                $bResult = Complete-Child $b; Assert-Deleted $bResult @($bPath)
                Assert-True ($gate.Suspended -and (Test-Path -LiteralPath $aPath)) 'A did not remain suspended with its original.'
                $script:Evidence.independentCompletedWhileASuspended = $true
            } else {
                Assert-True (!$b.Process.WaitForExit(2000)) 'Conflicting B bypassed A claims.'
                Assert-True (Test-Path -LiteralPath $child) 'Blocked conflict changed original.'
                $script:Evidence.conflictWaitMilliseconds = 2000
            }
            $gate.Resume(); $aResult = Complete-Child $a; Assert-Deleted $aResult @($aPath)
            if ($relation -ne 'independent') {
                $bResult = Complete-Child $b
                Assert-True ($bResult.ExitCode -eq 0) "B did not safely finish after A: $($bResult.Stderr)"
                # 競合待機中に解決したpathを再利用せず、完了したAを復元できることも確認する。
                if ($relation -eq 'child-parent') { Assert-Deleted $bResult @($parent); Restore-Result $bResult }
            }
            Restore-Result $aResult
            Assert-True ([IO.File]::ReadAllText($child).StartsWith('Prunlet concurrency fixture:')) 'A original did not restore.'
            if ($relation -eq 'independent') { Restore-Result $bResult }
        } finally { $gate.Dispose() }
    }
}

Test-Case 'batch-preflight-all-unchanged' {
    $valid = New-File 'valid.txt'; $invalidChild = New-File 'nonempty\child.txt'; $invalid = Split-Path -Parent $invalidChild
    [IO.File]::WriteAllText($valid + ':concurrent', 'ADS unchanged', $utf8)
    $snapshot = Snapshot $valid
    $result = Complete-Child (Start-Delete @($valid, $invalid))
    Assert-True ($result.ExitCode -ne 0 -and (Test-Path -LiteralPath $invalidChild)) 'Invalid nonrecursive root did not reject batch.'
    Assert-Snapshot $snapshot
    Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Recurse -Filter 'recycle-manifest.json').Count -eq 0) 'Rejected batch published a manifest.'
}

Test-Case 'batch-order-receipts-hardlinks-restore' {
    $paths = @(0..7 | ForEach-Object { New-File ('root-{0:D2}\file.txt' -f $_) })
    foreach ($path in $paths) { [IO.File]::WriteAllText($path + ':concurrent', 'ADS ' + $path, $utf8) }
    $alias = Join-Path $script:Scope 'outside-alias.txt'; [PrunletConcurrentNative]::Link($alias, $paths[0])
    $snapshots = @($paths | ForEach-Object { Snapshot $_ }); $aliasId = [PrunletConcurrentNative]::Identity($alias)
    $result = Complete-Child (Start-Delete $paths); Assert-Deleted $result $paths
    Assert-True ([PrunletConcurrentNative]::Identity($alias) -ceq $aliasId) 'External hardlink identity changed.'
    [IO.File]::WriteAllText($paths[0], 'current destination', $utf8)
    $collisionId = [PrunletConcurrentNative]::Identity($paths[0])
    $conflict = Invoke-Cli @('restore', $result.Json.operationId)
    Assert-True ($conflict.Json.items[0].status -eq 'conflict' -and [IO.File]::ReadAllText($paths[0]) -ceq 'current destination' -and [PrunletConcurrentNative]::Identity($paths[0]) -ceq $collisionId) 'Restore overwrote collision.'
    # 衝突fixtureを保持し、元のpathを空ける。削除・ゴミ箱直接操作はしない。
    [IO.File]::Move($paths[0], (Join-Path $script:Scope 'retained-collision.txt'))
    $restore = Invoke-Cli @('restore', $result.Json.operationId)
    Assert-True ($restore.ExitCode -eq 0) 'Retry restore failed.'
    foreach ($snapshot in $snapshots) { Assert-Snapshot $snapshot }
    Assert-True ([PrunletConcurrentNative]::Identity($paths[0]) -ceq $aliasId) 'Restored hardlink no longer shares identity.'
}

# MCPは行単位で読み、終端までJSONの完全性と応答後通知抑止を照合する。
Test-Case 'hardlink-two-aliases-same-batch' {
    $first = New-File 'first\shared.txt'
    $second = Join-Path (New-Directory (Join-Path $script:Scope 'second')) 'shared.txt'
    $external = Join-Path $script:Scope 'external-shared.txt'
    [PrunletConcurrentNative]::Link($second, $first); [PrunletConcurrentNative]::Link($external, $first)
    [IO.File]::WriteAllText($first + ':concurrent', 'shared ADS fixture', $utf8)
    $snapshots = @(@($first, $second, $external) | ForEach-Object { Snapshot $_ })
    $script:Evidence.originalSnapshots = $snapshots
    $result = $null
    try {
        $result = Complete-Child (Start-Delete @($first, $second))
        $script:Evidence.deleteResult = $result.Json
        Assert-Deleted $result @($first, $second)
        Assert-True ([PrunletConcurrentNative]::Identity($external) -ceq $snapshots[2].id) 'Surviving external alias changed identity.'
    } finally {
        if ($result -and $result.Json.operationId) {
            $restored = Invoke-Cli @('restore', $result.Json.operationId)
            $script:Evidence.restoreResult = $restored.Json
            foreach ($snapshot in $snapshots) { Assert-Snapshot $snapshot }
            $script:Evidence.restoredOriginalsVerified = $true
            $script:Evidence.restoredSnapshots = @($snapshots | ForEach-Object { Snapshot $_.path })
            if ($result.ExitCode -eq 0) { Assert-True ($restored.ExitCode -eq 0) 'Hardlink fixture restore failed; operation metadata retained.' }
        }
    }
}

function Start-Mcp {
    $info = [Diagnostics.ProcessStartInfo]::new($ExecutablePath)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8; $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    $info.WorkingDirectory = $script:CaseRoot
    $info.Environment['TEMP'] = Join-Path $script:CaseRoot 'temp'; $info.Environment['TMP'] = Join-Path $script:CaseRoot 'temp'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $script:CaseRoot 'runtime-cache'
    foreach ($argument in @('--config', $script:Config, 'mcp')) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; $null = $process.Start()
    $session = @{ Process = $process; Err = $process.StandardError.ReadToEndAsync(); Pending = $process.StandardOutput.ReadLineAsync(); Lines = [Collections.Generic.List[object]]::new(); Timer = [Diagnostics.Stopwatch]::StartNew() }
    $script:Sessions.Add($session)
    Send-Mcp $session @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'concurrency-e2e'; version = '1' } } }
    Wait-Mcp $session { @($session.Lines | Where-Object { $_.message.id -eq 1 }).Count -gt 0 } 10000
    Send-Mcp $session @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
    return $session
}
function Send-Mcp($Session, $Message) { $Session.Process.StandardInput.WriteLine(($Message | ConvertTo-Json -Depth 20 -Compress)); $Session.Process.StandardInput.Flush() }
function Pump-Mcp($Session) {
    while ($null -ne $Session.Pending -and $Session.Pending.IsCompleted) {
        $line = $Session.Pending.GetAwaiter().GetResult()
        if ($null -eq $line) { $Session.Pending = $null; break }
        $Session.Lines.Add(@{ text = $line; milliseconds = $Session.Timer.Elapsed.TotalMilliseconds; message = ($line | ConvertFrom-Json -AsHashtable -Depth 80) })
        $Session.Pending = $Session.Process.StandardOutput.ReadLineAsync()
    }
}
function Wait-Mcp($Session, [scriptblock]$Condition, [int]$Timeout) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) { Pump-Mcp $Session; if (& $Condition) { return }; if ($clock.ElapsedMilliseconds -gt $Timeout) { throw 'MCP condition timed out.' }; Start-Sleep -Milliseconds 20 }
}
function Send-DeleteMcp($Session, [int]$Id, [string[]]$Paths, $Token = $null, [switch]$Recursive) {
    $parameters = @{ name = 'delete_files'; arguments = @{ paths = @($Paths); recursive = [bool]$Recursive } }
    if ($null -ne $Token) { $parameters._meta = @{ progressToken = $Token } }
    Send-Mcp $Session @{ jsonrpc = '2.0'; id = $Id; method = 'tools/call'; params = $parameters }
}
function Complete-Mcp($Session, [hashtable]$Tokens, [int[]]$ExpectedIds) {
    $Session.Process.StandardInput.Close()
    Wait-Mcp $Session { $null -eq $Session.Pending } ($ProcessTimeoutSeconds * 1000)
    Assert-True ($Session.Process.WaitForExit(10000) -and $Session.Process.ExitCode -eq 0) 'MCP EOF drain failed.'
    $stderr = $Session.Err.GetAwaiter().GetResult()
    Save-Json (Join-Path $script:CaseRoot ('mcp-{0}-lines.json' -f $Session.Process.Id)) @($Session.Lines)
    [IO.File]::WriteAllText((Join-Path $script:CaseRoot ('mcp-{0}.stderr.txt' -f $Session.Process.Id)), $stderr, $utf8)
    $closed = @{}; $progressCounts = @{}
    foreach ($entry in $Session.Lines) {
        $message = $entry.message
        if ($null -ne $message.id) {
            if ($message.id -ne 1) { Assert-True ($ExpectedIds -contains [int]$message.id -and !$closed.ContainsKey([int]$message.id)) 'Unexpected/duplicate MCP response.' }
            $closed[[int]$message.id] = $true
        } elseif ($message.method -eq 'notifications/progress') {
            $token = $message.params.progressToken
            $key = $token | ConvertTo-Json -Compress
            Assert-True ($Tokens.ContainsKey($key) -and !$closed.ContainsKey($Tokens[$key])) 'Unexpected token or progress after final response.'
            $progressCounts[$key] = 1 + [int]$progressCounts[$key]
        }
    }
    foreach ($id in $ExpectedIds) { Assert-True $closed.ContainsKey($id) "MCP dropped request $id at EOF." }
    $script:Evidence.mcpMessages = @($Session.Lines); $script:Evidence.progressCounts = $progressCounts
    return $stderr
}

function Invoke-HardlinkTool([string]$Transport, [string]$Name, [hashtable]$Arguments) {
    if ($Transport -eq 'cli') {
        if ($Name -eq 'delete_files') { return Complete-Child (Start-Delete $Arguments.paths -Recursive) }
        return Invoke-Cli @('restore', $Arguments.operationId)
    }
    $session = Start-Mcp
    Send-Mcp $session @{ jsonrpc = '2.0'; id = 60; method = 'tools/call'; params = @{ name = $Name; arguments = $Arguments } }
    $null = Complete-Mcp $session @{} @(60)
    $reply = @($session.Lines | Where-Object { $_.message.id -eq 60 })[0]
    return @{ ExitCode = $(if ($reply.message.error -or $reply.message.result.isError) { 1 } else { 0 }); Json = $reply.message.result.structuredContent; Stdout = $reply.text; Stderr = '' }
}
function New-HardlinkFixture([string]$Shape, [int]$Count = 2) {
    $files = [Collections.Generic.List[string]]::new(); $paths = [Collections.Generic.List[string]]::new()
    $external = [Collections.Generic.List[string]]::new()
    $first = New-File 'entry-0\shared.txt'; $files.Add($first)
    switch ($Shape) {
        'same-tree' {
            $paths.Add((Split-Path -Parent $first))
            for ($i = 1; $i -lt $Count; $i++) {
                $alias = Join-Path (Split-Path -Parent $first) "alias-$i.txt"
                [PrunletConcurrentNative]::Link($alias, $first); $files.Add($alias)
            }
        }
        'transitive' {
            $secondRoot = New-Directory (Join-Path $script:Scope 'entry-1')
            $thirdRoot = New-Directory (Join-Path $script:Scope 'entry-2')
            $alias = Join-Path $secondRoot 'x-alias.txt'; [PrunletConcurrentNative]::Link($alias, $first); $files.Add($alias)
            $secondId = New-File 'entry-1\y.txt'; $files.Add($secondId)
            $alias = Join-Path $thirdRoot 'y-alias.txt'; [PrunletConcurrentNative]::Link($alias, $secondId); $files.Add($alias)
            $outside = Join-Path $script:Scope 'external-y.txt'; [PrunletConcurrentNative]::Link($outside, $secondId); $external.Add($outside)
            $paths.Add((Split-Path -Parent $first)); $paths.Add($secondRoot); $paths.Add($thirdRoot)
        }
        default {
            for ($i = 1; $i -lt $Count; $i++) {
                $root = New-Directory (Join-Path $script:Scope "entry-$i")
                $alias = Join-Path $root 'shared.txt'; [PrunletConcurrentNative]::Link($alias, $first); $files.Add($alias)
            }
            for ($i = 0; $i -lt $Count; $i++) {
                $file = $files[$i]
                $paths.Add($(if ($Shape -eq 'cross-trees' -or ($Shape -eq 'root-child' -and $i -gt 0)) { Split-Path -Parent $file } else { $file }))
            }
        }
    }
    $outside = Join-Path $script:Scope 'external-x.txt'; [PrunletConcurrentNative]::Link($outside, $first); $external.Add($outside)
    foreach ($file in @($files) + @($external)) { [IO.File]::WriteAllText($file + ':concurrent', 'shared hardlink ADS', $utf8) }
    $snapshots = @(@($files) + @($external) | ForEach-Object { Snapshot $_ })
    $directories = @($paths | Where-Object { [IO.Directory]::Exists($_) } | ForEach-Object {
        @{ path = $_; id = [PrunletConcurrentNative]::Identity($_); security = [Convert]::ToBase64String([PrunletConcurrentNative]::Security($_)); attributes = [int][IO.File]::GetAttributes($_) }
    })
    $fixture = @{ Paths = @($paths); Files = @($files); External = @($external); Snapshots = $snapshots; Directories = $directories }
    $script:Evidence.fixture = $fixture
    return $fixture
}
function Assert-HardlinkFixture($Fixture) {
    foreach ($snapshot in $Fixture.Snapshots) { Assert-Snapshot $snapshot }
    foreach ($directory in $Fixture.Directories) {
        Assert-True ([PrunletConcurrentNative]::Identity($directory.path) -ceq $directory.id) 'Restored directory ID differs.'
        Assert-True ([Convert]::ToBase64String([PrunletConcurrentNative]::Security($directory.path)) -ceq $directory.security) 'Restored directory O/G/D bytes differ.'
        Assert-True ([int][IO.File]::GetAttributes($directory.path) -eq $directory.attributes) 'Restored directory attributes differ.'
    }
    $script:Evidence.restoredSnapshots = @($Fixture.Snapshots | ForEach-Object { Snapshot $_.path })
}
function Assert-ExternalFacts($Fixture) {
    foreach ($path in $Fixture.External) {
        $before = @($Fixture.Snapshots | Where-Object path -CEQ $path)[0]
        $now = Snapshot $path
        # Windowsのごみ箱移動中の共有ACLは変わり得る。ID・内容・属性・ADS・別名数をここで照合し、最終O/G/Dは復元後に完全照合する。
        foreach ($key in @('id', 'hash', 'attributes', 'ads', 'links')) { Assert-True ($now[$key] -ceq $before[$key]) "Surviving external alias $key differs." }
    }
}
function Add-FixtureDenyWrite([string]$Path, [switch]$DaclOnly) {
    $acl = Get-Acl -LiteralPath $Path
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::WriteData, [Security.AccessControl.AccessControlType]::Deny)
    $acl.AddAccessRule($rule)
    if ($DaclOnly) { [PrunletConcurrentNative]::FixtureDacl($Path, $acl.GetSecurityDescriptorBinaryForm()) }
    else { Set-Acl -LiteralPath $Path -AclObject $acl }
}
function Restore-FixtureAcl([string]$Path, [byte[]]$Bytes) {
    [PrunletConcurrentNative]::FixtureDacl($Path, $Bytes)
    Assert-True ([Convert]::ToBase64String([PrunletConcurrentNative]::Security($Path)) -ceq [Convert]::ToBase64String($Bytes)) 'Fixture O/G/D rollback did not reproduce exact native bytes.'
}
foreach ($transport in @('cli', 'mcp')) {
    foreach ($shape in @('files-2', 'files-3', 'cross-trees', 'root-child', 'same-tree', 'transitive')) {
        Test-Case ("hardlink-batch-roundtrip-$transport-$shape") {
            $fixture = New-HardlinkFixture $shape $(if ($shape -eq 'files-3') { 3 } else { 2 })
            $deleted = Invoke-HardlinkTool $transport 'delete_files' @{ paths = $fixture.Paths; recursive = $true }
            Assert-Deleted $deleted $fixture.Paths; Assert-ExternalFacts $fixture
            $manifest = Read-Json (Join-Path (Join-Path $script:Recovery $deleted.Json.operationId) 'recycle-manifest.json')
            Assert-True (($manifest.hardlinkProtocol -eq 1) -eq ($shape -ne 'same-tree')) 'Cross-entry shared-ID opt-in differs from fixture shape.'
            $restored = Invoke-HardlinkTool $transport 'restore_files' @{ operationId = $deleted.Json.operationId }
            Assert-True ($restored.ExitCode -eq 0 -and @($restored.Json.items | Where-Object status -ne 'restored').Count -eq 0) "Batch restore failed: $($restored.Stdout)"
            Assert-HardlinkFixture $fixture
            $again = Invoke-HardlinkTool $transport 'restore_files' @{ operationId = $deleted.Json.operationId }
            Assert-True ($again.ExitCode -eq 0 -and @($again.Json.items | Where-Object status -ne 'already_restored').Count -eq 0) 'Repeated restore was not idempotent.'
            Assert-HardlinkFixture $fixture
        }
    }
}
Test-Case 'hardlink-batch-initial-conflict-component-and-independent-progress' {
    $fixture = New-HardlinkFixture 'files-2'
    $independent = New-File 'independent.txt'; [IO.File]::WriteAllText($independent + ':concurrent', 'independent ADS', $utf8)
    $independentBefore = Snapshot $independent
    $paths = @($fixture.Paths) + @($independent)
    $deleted = Complete-Child (Start-Delete $paths); Assert-Deleted $deleted $paths
    [IO.File]::WriteAllText($fixture.Paths[0], 'current destination occupant', $utf8)
    [IO.File]::WriteAllText($fixture.Paths[0] + ':concurrent', 'current destination ADS', $utf8)
    $occupant = Snapshot $fixture.Paths[0]
    $conflict = Invoke-Cli @('restore', $deleted.Json.operationId)
    $script:Evidence.conflictResult = $conflict.Json
    Assert-True ($conflict.Json.items[0].status -eq 'conflict') 'Occupied group member did not report conflict.'
    Assert-Snapshot $occupant
    Assert-True (![IO.File]::Exists($fixture.Paths[1])) 'Initial group conflict partially restored a shared component.'
    Assert-Snapshot $independentBefore
    [IO.File]::Move($fixture.Paths[0], (Join-Path $script:Scope 'retained-occupant.txt'))
    $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Conflict retry did not restore component.'
    Assert-HardlinkFixture $fixture; Assert-Snapshot $independentBefore
    $again = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($again.ExitCode -eq 0 -and @($again.Json.items | Where-Object status -ne 'already_restored').Count -eq 0) 'Partial restore retry was not idempotent.'
}
Test-Case 'hardlink-batch-external-acl-tamper-rejected' {
    $fixture = New-HardlinkFixture 'files-2'
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $outside = $fixture.External[0]; $postDeleteAcl = [PrunletConcurrentNative]::Security($outside)
    Add-FixtureDenyWrite $outside
    $tampered = Snapshot $outside
    $result = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($result.ExitCode -ne 0 -and @($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'External ACL tamper was accepted or partially restored.'
    Assert-Snapshot $tampered
    $script:Evidence.tamperedSnapshot = $tampered; $script:Evidence.rejectionResult = $result.Json
    Restore-FixtureAcl $outside $postDeleteAcl
    $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Exact fixture ACL rollback did not allow restore.'
    Assert-HardlinkFixture $fixture
}
function Interrupt-OwnedRestore($Deleted, [string]$WatchRoot, [string]$Filter) {
    $gate = [PrunletConcurrentGate]::new($WatchRoot, $Filter)
    $session = $null
    try {
        $session = Start-Child @('restore', $Deleted.Json.operationId); $gate.Bind($session.Process)
        Assert-True ($gate.Wait(30000) -and $gate.Suspended -and !$gate.Error) "Restore boundary was not observed: $Filter $($gate.Error)"
        $observed = $gate.ObservedPath
        # 今回起動したProcessだけを終了する。停止中でもfinallyでresume可能な状態を保持し、他PIDを探索しない。
        $session.Process.Kill($true)
        Assert-True ($session.Process.WaitForExit(10000)) 'Owned interrupted restore did not terminate.'
        Save-Json (Join-Path $script:CaseRoot 'interrupted-restore.json') @{ processId = $session.Process.Id; observedPath = $observed; exitCode = $session.Process.ExitCode; stdout = $session.Out.GetAwaiter().GetResult(); stderr = $session.Err.GetAwaiter().GetResult() }
        $script:Evidence.boundary = @{ filter = $Filter; observedPath = $observed; processId = $session.Process.Id; terminated = $session.Process.HasExited }
        return $observed
    } finally { $gate.Dispose() }
}
Test-Case 'hardlink-batch-unready-stage-acl-not-reapplied' {
    $fixture = New-HardlinkFixture 'files-2'
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $stage = Interrupt-OwnedRestore $deleted $script:CaseRoot '0000.entry'
    $operationRoot = Join-Path $script:Recovery $deleted.Json.operationId
    Assert-True ([IO.File]::Exists($stage) -and ![IO.File]::Exists((Join-Path $operationRoot 'recycle-stage-0000-ready.json'))) 'Unready boundary already passed or stage missing.'
    Add-FixtureDenyWrite $stage
    $tampered = Snapshot $stage
    $retry = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($retry.ExitCode -ne 0) 'Unready existing stage was automatically corrected.'
    Assert-Snapshot $tampered
    Assert-True (![IO.File]::Exists((Join-Path $operationRoot 'recycle-stage-0000-ready.json'))) 'Retry created ready proof for unready tampered stage.'
    $script:Evidence.retainedReason = 'Negative fixture: interrupted unready stage and shared alias ACL must remain intact for inspection.'
    $script:Evidence.stageSnapshot = $tampered; $script:Evidence.retry = $retry.Json
}
Test-Case 'hardlink-batch-ready-restart-and-partial-publish' {
    $fixture = New-HardlinkFixture 'files-3' 3
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $published = Interrupt-OwnedRestore $deleted $script:Scope 'shared.txt'
    $remaining = @($fixture.Paths | Where-Object { ![IO.File]::Exists($_) })
    Assert-True ([IO.File]::Exists($published) -and $remaining.Count -gt 0) 'Partial publication boundary was not observed; no restart claim is made.'
    $publishedBefore = Snapshot $published
    $retry = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($retry.ExitCode -eq 0) 'Ready partial-publication restart failed.'
    Assert-Snapshot $publishedBefore; Assert-HardlinkFixture $fixture
    $again = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($again.ExitCode -eq 0 -and @($again.Json.items | Where-Object status -ne 'already_restored').Count -eq 0) 'Publication restart was not idempotent.'
}
function Existing-StageSnapshots([string]$OperationId) {
    $root = Join-Path $script:Recovery $OperationId
    return @(Get-ChildItem -LiteralPath $root -Filter 'recycle-stage-*-intent.json' | ForEach-Object {
        $intent = Read-Json $_.FullName
        $path = Join-Path $intent.stageOperationPath ('{0:D4}.entry' -f [int]$intent.index)
        if ([IO.File]::Exists($path)) { Snapshot $path }
    })
}
Test-Case 'hardlink-batch-incomplete-ready-component-not-corrected' {
    $fixture = New-HardlinkFixture 'files-3' 3
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    $null = Interrupt-OwnedRestore $deleted $root 'recycle-stage-0000-ready.json'
    $ready = @(Get-ChildItem -LiteralPath $root -Filter 'recycle-stage-*-ready.json')
    Assert-True ($ready.Count -gt 0 -and $ready.Count -lt 3) 'Partial-ready boundary was not observed.'
    $stages = Existing-StageSnapshots $deleted.Json.operationId
    Assert-True ($stages.Count -eq 3) 'Expected all three staged aliases before group ready completion.'
    $retry = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($retry.ExitCode -ne 0) 'Incomplete-ready group was silently corrected.'
    foreach ($snapshot in $stages) { Assert-Snapshot $snapshot }
    Assert-True (@(Get-ChildItem -LiteralPath $root -Filter 'recycle-stage-*-ready.json').Count -eq $ready.Count) 'Retry added ready proofs to an incomplete group.'
    $script:Evidence.retainedReason = 'Negative fixture: partially ready component must not have security reapplied.'
    $script:Evidence.stageSnapshots = $stages; $script:Evidence.retry = $retry.Json
}
Test-Case 'hardlink-batch-all-ready-publication-conflict-retry' {
    $fixture = New-HardlinkFixture 'files-3' 3
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    $null = Interrupt-OwnedRestore $deleted $root 'hardlink-0000-ready.json'
    Assert-True ([IO.File]::Exists((Join-Path $root 'hardlink-0000-ready.json')) -and @(Get-ChildItem -LiteralPath $root -Filter 'recycle-stage-*-ready.json').Count -eq 3 -and @($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'All-ready prepublication boundary was not observed.'
    [IO.File]::WriteAllText($fixture.Paths[0], 'occupant after ready', $utf8)
    [IO.File]::WriteAllText($fixture.Paths[0] + ':concurrent', 'occupant ADS', $utf8)
    $occupant = Snapshot $fixture.Paths[0]
    $retry = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($retry.ExitCode -ne 0 -and $retry.Json.items[0].status -eq 'conflict') 'Ready destination conflict was not rejected.'
    Assert-Snapshot $occupant
    [IO.File]::Move($fixture.Paths[0], (Join-Path $script:Scope 'retained-ready-occupant.txt'))
    $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Ready conflict retry failed.'
    Assert-HardlinkFixture $fixture
    $script:Evidence.occupantSnapshot = $occupant
}
foreach ($change in @('conflict', 'acl-tamper')) {
    Test-Case ("hardlink-batch-partially-published-$change-preserved") {
        $fixture = New-HardlinkFixture 'files-3' 3
        $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
        $published = Interrupt-OwnedRestore $deleted $script:Scope 'shared.txt'
        $missing = @($fixture.Paths | Where-Object { ![IO.File]::Exists($_) })
        Assert-True ([IO.File]::Exists($published) -and $missing.Count -gt 0) 'Partial-publication boundary was not observed.'
        $publishedBefore = Snapshot $published
        if ($change -eq 'conflict') {
            [IO.File]::WriteAllText($missing[0], 'occupant after partial publish', $utf8)
            [IO.File]::WriteAllText($missing[0] + ':concurrent', 'occupant ADS', $utf8)
            $occupant = Snapshot $missing[0]
        } else {
            $priorAcl = [PrunletConcurrentNative]::Security($published)
            Add-FixtureDenyWrite $published
            $publishedBefore = Snapshot $published
        }
        $rejected = Invoke-Cli @('restore', $deleted.Json.operationId)
        Assert-True ($rejected.ExitCode -ne 0) 'Partial-publication conflict or ACL tamper was accepted.'
        Assert-Snapshot $publishedBefore
        if ($change -eq 'conflict') {
            Assert-Snapshot $occupant
            [IO.File]::Move($missing[0], (Join-Path $script:Scope 'retained-partial-occupant.txt'))
        } else { Restore-FixtureAcl $published $priorAcl }
        $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0) 'Partial-publication retry after exact fixture rollback failed.'
        Assert-HardlinkFixture $fixture
        $script:Evidence.publishedSnapshot = $publishedBefore; $script:Evidence.rejected = $rejected.Json
    }
}
Test-Case 'hardlink-batch-unrelated-node-acl-tamper-rejected' {
    $fixture = New-HardlinkFixture 'cross-trees'
    $other = New-File 'entry-0\unrelated.txt'; [IO.File]::WriteAllText($other + ':concurrent', 'unrelated ADS', $utf8)
    $otherOriginal = Snapshot $other
    $deleted = Complete-Child (Start-Delete $fixture.Paths -Recursive); Assert-Deleted $deleted $fixture.Paths
    $receipt = Read-Json (Join-Path (Join-Path $script:Recovery $deleted.Json.operationId) 'recycle-0000-complete.json')
    $binOther = Join-Path $receipt.physicalPath 'unrelated.txt'
    $priorAcl = [PrunletConcurrentNative]::Security($binOther)
    Add-FixtureDenyWrite $binOther; $tampered = Snapshot $binOther
    $rejected = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($rejected.ExitCode -ne 0) 'Shared-ID journal authorized an unrelated node ACL change.'
    Assert-Snapshot $tampered
    Assert-True (@($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Unrelated node tamper partially restored a component.'
    Restore-FixtureAcl $binOther $priorAcl
    $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Exact unrelated-node fixture ACL rollback did not allow restore.'
    Assert-HardlinkFixture $fixture; Assert-Snapshot $otherOriginal
    $script:Evidence.tamperedSnapshot = $tampered; $script:Evidence.rejected = $rejected.Json
}
foreach ($damage in @('missing', 'truncated', 'modified')) {
    Test-Case ("hardlink-batch-ledger-$damage-rejected") {
        $fixture = New-HardlinkFixture 'files-2'
        $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
        $root = Join-Path $script:Recovery $deleted.Json.operationId
        $ledgers = @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '(?i)(shared|hardlink|ledger)' } | Sort-Object LastWriteTimeUtc, Name)
        Assert-True ($ledgers.Count -gt 0) 'New-format shared-ID ledger record was not found.'
        $ledger = $ledgers[-1].FullName; $bytes = [IO.File]::ReadAllBytes($ledger)
        $parked = Join-Path $script:CaseRoot ('retained-original-' + [IO.Path]::GetFileName($ledger))
        $outside = Snapshot $fixture.External[0]
        if ($damage -eq 'missing') { [IO.File]::Move($ledger, $parked) }
        elseif ($damage -eq 'truncated') { [IO.File]::WriteAllBytes($ledger, $bytes[0..([int]($bytes.Length / 2))]) }
        else { $data = Read-Json $ledger; $data.operationId = 'ffffffffffffffffffffffffffffffff'; Save-Json $ledger $data }
        try {
            $rejected = Invoke-Cli @('restore', $deleted.Json.operationId)
            Assert-True ($rejected.ExitCode -ne 0 -and @($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Damaged shared-ID journal was accepted or partially restored.'
            Assert-Snapshot $outside
            $script:Evidence.damagedRecord = $ledger; $script:Evidence.rejected = $rejected.Json
        } finally {
            if ($damage -eq 'missing') { [IO.File]::Move($parked, $ledger) } else { [IO.File]::WriteAllBytes($ledger, $bytes) }
        }
        $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0) 'Byte-identical fixture journal rollback did not permit restoration.'
        Assert-HardlinkFixture $fixture
    }
}
foreach ($removal in @('last-transition', 'all-transitions')) {
    Test-Case ("hardlink-batch-ledger-$removal-missing-rejected") {
        $fixture = New-HardlinkFixture 'files-2'
        $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
        $root = Join-Path $script:Recovery $deleted.Json.operationId
        $records = @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '^hardlink-0000-[0-9]{4}-(intent|proof|complete)\.json$' } | Sort-Object Name)
        Assert-True ($records.Count -eq 6) 'Expected two complete three-record delete transitions.'
        $lastIntent = Read-Json (Join-Path $root 'hardlink-0000-0001-intent.json')
        $lastProof = Read-Json (Join-Path $root 'hardlink-0000-0001-proof.json')
        foreach ($key in $lastIntent.security.Keys) { Assert-True ($lastIntent.security[$key].descriptor -ceq $lastProof.security[$key].descriptor) 'Fixture did not produce an unchanged-DACL final delete transition.' }
        $selected = if ($removal -eq 'last-transition') { @($records | Where-Object Name -like 'hardlink-0000-0001-*') } else { $records }
        $parked = New-Directory (Join-Path $script:CaseRoot 'retained-transition-records')
        $outside = Snapshot $fixture.External[0]
        foreach ($record in $selected) { [IO.File]::Move($record.FullName, (Join-Path $parked $record.Name)) }
        try {
            $rejected = Invoke-Cli @('restore', $deleted.Json.operationId)
            Assert-True ($rejected.ExitCode -ne 0 -and @($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'A whole missing transition was accepted because its DACL did not change.'
            Assert-Snapshot $outside
            $script:Evidence.removedRecords = @($selected.Name); $script:Evidence.rejected = $rejected.Json
        } finally { foreach ($record in $selected) { [IO.File]::Move((Join-Path $parked $record.Name), $record.FullName) } }
        $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
        Assert-True ($restored.ExitCode -eq 0) 'Exact transition rollback did not permit restoration.'
        Assert-HardlinkFixture $fixture
    }
}
Test-Case 'hardlink-batch-ready-missing-restore-intent-rejected' {
    $fixture = New-HardlinkFixture 'files-2'
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    $null = Interrupt-OwnedRestore $deleted $root 'hardlink-0000-ready.json'
    Assert-True (@($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Prepublication group-ready boundary was not observed.'
    $stages = Existing-StageSnapshots $deleted.Json.operationId
    Assert-True ($stages.Count -eq 2) 'Ready fixture stage set differs.'
    $intent = Join-Path $root 'restore-0000-intent.json'; $parked = Join-Path $script:CaseRoot 'retained-restore-0000-intent.json'
    [IO.File]::Move($intent, $parked)
    try {
        $rejected = Invoke-Cli @('restore', $deleted.Json.operationId)
        Assert-True ($rejected.ExitCode -ne 0 -and ![IO.File]::Exists((Join-Path $root 'restore-0000-complete.json')) -and @($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Ready stage without restore intent was published or gained a completion receipt.'
        foreach ($snapshot in $stages) { Assert-Snapshot $snapshot }
        $script:Evidence.stageSnapshots = $stages; $script:Evidence.rejected = $rejected.Json
    } finally { [IO.File]::Move($parked, $intent) }
    $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Exact restore-intent rollback did not permit restoration.'
    Assert-HardlinkFixture $fixture
}
Test-Case 'hardlink-batch-ready-unbound-stage-member-rejected' {
    $fixture = New-HardlinkFixture 'files-2'
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    $null = Interrupt-OwnedRestore $deleted $root 'hardlink-0000-ready.json'
    Assert-True (@($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Prepublication group-ready boundary was not observed.'
    $stages = Existing-StageSnapshots $deleted.Json.operationId
    Assert-True ($stages.Count -eq 2) 'Expected two ready stage aliases.'
    $extra = Join-Path ([IO.Path]::GetDirectoryName($stages[0].path)) '9999.entry'
    Assert-True (!(Test-Path -LiteralPath $extra)) 'Unbound stage fixture already exists.'
    [IO.File]::WriteAllText($extra, 'unbound stage object', $utf8); [IO.File]::WriteAllText($extra + ':concurrent', 'unbound ADS', $utf8)
    $extraSnapshot = Snapshot $extra
    $rejected = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($rejected.ExitCode -ne 0 -and @($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Unbound stage object was accepted and an original was published.'
    Assert-Snapshot $extraSnapshot; foreach ($snapshot in $stages) { Assert-Snapshot $snapshot }
    [IO.File]::Move($extra, (Join-Path $script:Scope 'retained-unbound-stage-object.txt'))
    $restored = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($restored.ExitCode -eq 0) 'Removing only the test-owned unbound member did not permit restoration.'
    Assert-HardlinkFixture $fixture
    $script:Evidence.unboundSnapshot = $extraSnapshot; $script:Evidence.rejected = $rejected.Json
}
Test-Case 'hardlink-batch-published-receipt-write-failure-not-success' {
    $fixture = New-HardlinkFixture 'files-2'
    $deleted = Complete-Child (Start-Delete $fixture.Paths); Assert-Deleted $deleted $fixture.Paths
    $root = Join-Path $script:Recovery $deleted.Json.operationId
    $gate = [PrunletConcurrentGate]::new($root, 'hardlink-0000-ready.json')
    $priorAcl = $null
    try {
        $session = Start-Child @('restore', $deleted.Json.operationId); $gate.Bind($session.Process)
        Assert-True ($gate.Wait(30000) -and $gate.Suspended -and !$gate.Error -and @($fixture.Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Ready prepublication boundary was not observed for receipt failure injection.'
        $priorAcl = [PrunletConcurrentNative]::Security($root)
        # 完了記録の最終rename先だけでCreateFilesを拒否する。中央pendingの作成と原本の公開は許可されたままにする。
        Add-FixtureDenyWrite $root -DaclOnly
        $gate.Resume()
        $failed = Complete-Child $session
        $published = @($fixture.Paths | Where-Object { [IO.File]::Exists($_) })
        Assert-True ($failed.ExitCode -ne 0 -and $published.Count -gt 0 -and ![IO.File]::Exists((Join-Path $root 'restore-0000-complete.json'))) 'Fixture did not fail completion persistence after publication.'
        Assert-True ($failed.Json.items[0].status -notin @('restored', 'already_restored')) 'Published object without a durable completion receipt was reported as restored.'
        $publishedBefore = Snapshot $fixture.Paths[0]
        $script:Evidence.failedResult = $failed.Json; $script:Evidence.publishedSnapshot = $publishedBefore
    } finally {
        try { $gate.Dispose() } finally { if ($priorAcl) { Restore-FixtureAcl $root $priorAcl } }
    }
    $repaired = Invoke-Cli @('restore', $deleted.Json.operationId)
    Assert-True ($repaired.ExitCode -eq 0) 'Re-read with valid group-ready/stage/intent evidence could not repair completion.'
    Assert-Snapshot $publishedBefore; Assert-HardlinkFixture $fixture
    $script:Evidence.repairResult = $repaired.Json
}

Test-Case 'hardlink-batch-legacy-schema6-and-partial-failure-preserved' {
    if (!$LegacyHardlinkExecutablePath -or ![IO.File]::Exists($LegacyHardlinkExecutablePath)) { $script:SkipReason = 'LegacyHardlinkExecutablePath is required to create genuine pre-feature schema 6 records.'; return }
    $fixture = New-HardlinkFixture 'files-2'
    $legacy = Complete-Child (Start-Delete $fixture.Paths -Exe $LegacyHardlinkExecutablePath)
    Assert-True ($legacy.ExitCode -ne 0 -and $legacy.Json.items[0].status -eq 'deleted' -and $legacy.Json.items[1].status -eq 'failed') 'Legacy creator did not produce the known partial schema 6 operation.'
    $restored = Invoke-Cli @('restore', $legacy.Json.operationId)
    Assert-True ($restored.Json.items[0].status -eq 'restored' -and $restored.Json.items[1].status -eq 'failed') 'Legacy partial record was guessed or rerouted as a new shared component.'
    Assert-HardlinkFixture $fixture
    $single = New-File 'legacy-single.txt'; [IO.File]::WriteAllText($single + ':concurrent', 'legacy single ADS', $utf8)
    $before = Snapshot $single
    $singleDelete = Complete-Child (Start-Delete @($single) -Exe $LegacyHardlinkExecutablePath); Assert-Deleted $singleDelete @($single)
    Restore-Result $singleDelete; Assert-Snapshot $before
    $script:Evidence.legacyCreator = $LegacyHardlinkExecutablePath; $script:Evidence.legacyPartialDelete = $legacy.Json; $script:Evidence.legacyPartialRestore = $restored.Json
}

Test-Case 'exclusive-maintenance-65seconds-cli-mcp-eof-drain' {
    $paths = @(0..3 | ForEach-Object { New-File ('wait-{0}.txt' -f $_) })
    $mcp = Start-Mcp
    $held = [IO.FileStream]::new((Join-Path $script:Recovery 'maintenance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $cli = Start-Delete @($paths[0])
        Send-DeleteMcp $mcp 10 @($paths[1]) 'first-token'; Send-DeleteMcp $mcp 11 @($paths[2]) 42; Send-DeleteMcp $mcp 12 @($paths[3])
        $mcp.Process.StandardInput.Close()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.ElapsedMilliseconds -lt 65000) {
            Pump-Mcp $mcp
            Assert-True (!$cli.Process.HasExited -and !$mcp.Process.HasExited) 'Request exited while exclusive maintenance remained held.'
            foreach ($path in $paths) { Assert-True ([IO.File]::Exists($path)) 'Maintenance wait changed an original.' }
            Assert-True (@($mcp.Lines | Where-Object { $_.message.id -in @(10, 11, 12) }).Count -eq 0) 'MCP responded before exclusive lock release.'
            Start-Sleep -Milliseconds 100
        }
        $script:Evidence.lockHeldMilliseconds = $timer.ElapsedMilliseconds
        Assert-True (@($mcp.Lines | Where-Object { $_.message.method -eq 'notifications/progress' -and $_.message.params.progressToken -ceq 'first-token' }).Count -ge 2) 'First token wait notifications missing.'
        Assert-True (@($mcp.Lines | Where-Object { $_.message.method -eq 'notifications/progress' -and $_.message.params.progressToken -is [long] -and $_.message.params.progressToken -eq 42 }).Count -ge 2) 'Numeric token wait notifications missing.'
    } finally { $held.Dispose() }
    $result = Complete-Child $cli; Assert-Deleted $result @($paths[0]); Assert-True ($result.Stderr.Trim().Length -gt 0) 'CLI wait diagnostics missing on stderr.'
    $null = Complete-Mcp $mcp @{ '"first-token"' = 10; '42' = 11 } @(10, 11, 12)
    foreach ($entry in @($mcp.Lines | Where-Object { $_.message.id -in @(10, 11, 12) })) { Assert-True (!$entry.message.result.isError -and $entry.message.result.structuredContent.operationId) 'MCP delete failed after release.' }
    Restore-Result $result
    foreach ($entry in @($mcp.Lines | Where-Object { $_.message.id -in @(10, 11, 12) })) { Restore-Result @{ Json = $entry.message.result.structuredContent } }
}

Test-Case 'mcp-independent-completes-before-heavy-request-and-exception-drain' {
    $heavy = New-Directory (Join-Path $script:Scope 'heavy')
    for ($i = 0; $i -lt $HeavyFileCount; $i++) { [IO.File]::WriteAllText((Join-Path $heavy ('{0:D6}.txt' -f $i)), 'heavy fixture ' + $i, $utf8) }
    $small = New-File 'small.txt'; $last = New-File 'last.txt'
    $mcp = Start-Mcp
    Send-DeleteMcp $mcp 20 @($heavy) 'heavy-token' -Recursive
    Wait-Mcp $mcp { @(Get-ChildItem -LiteralPath $script:Recovery -Recurse -Filter 'recycle-manifest.json').Count -gt 0 } 30000
    Send-DeleteMcp $mcp 21 @($small) 'small-token'
    # 保護対象でrequestが失敗しても枠が戻り、次の正常requestとEOFを処理できることを確かめる。
    Send-DeleteMcp $mcp 22 @($script:Recovery) 'invalid-token' -Recursive
    Send-DeleteMcp $mcp 23 @($last)
    $null = Complete-Mcp $mcp @{ '"heavy-token"' = 20; '"small-token"' = 21; '"invalid-token"' = 22 } @(20, 21, 22, 23)
    $responses = @($mcp.Lines | Where-Object { $_.message.id -in @(20, 21, 22, 23) })
    $script:Evidence.completionOrder = @($responses | ForEach-Object { $_.message.id })
    $heavyResponse = @($responses | Where-Object { $_.message.id -eq 20 })[0]
    $smallResponse = @($responses | Where-Object { $_.message.id -eq 21 })[0]
    Assert-True ($smallResponse.milliseconds -lt $heavyResponse.milliseconds) 'Small MCP request did not complete before heavy A; increase HeavyFileCount if A already completed before B submission.'
    foreach ($id in @(20, 21, 23)) {
        $entry = @($responses | Where-Object { $_.message.id -eq $id })[0]
        Assert-True (!$entry.message.result.isError -and $entry.message.result.structuredContent.operationId) "MCP request $id failed."
        Restore-Result @{ Json = $entry.message.result.structuredContent }
    }
    $rejected = @($responses | Where-Object { $_.message.id -eq 22 })[0].message
    Assert-True ($rejected.result.isError -or $rejected.error) 'Protected request did not report failure.'
}

Test-Case 'mcp-nondeletion-tool-waits-for-pending-delete' {
    $source = New-File 'before-list.txt'; $mcp = Start-Mcp
    $held = [IO.FileStream]::new((Join-Path $script:Recovery 'maintenance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Send-DeleteMcp $mcp 40 @($source) 'barrier-token'
        Wait-Mcp $mcp { @($mcp.Lines | Where-Object { $_.message.method -eq 'notifications/progress' }).Count -gt 0 } 15000
        Send-Mcp $mcp @{ jsonrpc = '2.0'; id = 41; method = 'tools/call'; params = @{ name = 'list_operations'; arguments = @{} } }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.ElapsedMilliseconds -lt 1500) { Pump-Mcp $mcp; Start-Sleep -Milliseconds 25 }
        Assert-True (@($mcp.Lines | Where-Object { $_.message.id -in @(40, 41) }).Count -eq 0) 'Nondeletion tool bypassed pending delete barrier.'
        Assert-True ([IO.File]::Exists($source)) 'Held delete changed original.'
    } finally { $held.Dispose() }
    $null = Complete-Mcp $mcp @{ '"barrier-token"' = 40 } @(40, 41)
    $responses = @($mcp.Lines | Where-Object { $_.message.id -in @(40, 41) })
    Assert-True ($responses.Count -eq 2 -and $responses[0].message.id -eq 40 -and $responses[1].message.id -eq 41) 'Barrier response order differs.'
    Assert-True (!$responses[0].message.result.isError -and !$responses[1].message.result.isError) 'Barrier tool failed after lock release.'
    $script:Evidence.responseOrder = @($responses | ForEach-Object { $_.message.id })
    Restore-Result @{ Json = $responses[0].message.result.structuredContent }
}

Test-Case 'mcp-request-constructor-errors-release-dispatch-capacity' {
    $source = New-File 'after-constructor-errors.txt'
    $mcp = Start-Mcp
    $parked = Join-Path $script:CaseRoot 'metadata-temporarily-parked'
    # active operationのない専用fixtureだけを一時退避する。復帰時も既存pathへ上書きしない。
    $expected = [IO.Path]::GetFullPath((Join-Path $script:CaseRoot 'metadata'))
    Assert-True ($script:Recovery -ceq $expected -and [IO.Directory]::Exists($expected) -and !(Test-Path -LiteralPath $parked)) 'Unexpected metadata move boundary.'
    Assert-VerificationDestination $expected @($repoRoot, $codexRoot)
    Assert-VerificationDestination $parked @($repoRoot, $codexRoot)
    $moved = $false
    try {
        [IO.Directory]::Move($expected, $parked); $moved = $true
        foreach ($id in @(30, 31, 32, 33)) { Send-DeleteMcp $mcp $id @($source) }
        Wait-Mcp $mcp { @($mcp.Lines | Where-Object { $_.message.id -in @(30, 31, 32, 33) }).Count -eq 4 } 15000
        foreach ($entry in @($mcp.Lines | Where-Object { $_.message.id -in @(30, 31, 32, 33) })) {
            Assert-True ([bool]$entry.message.error -or [bool]$entry.message.result.isError) 'Missing metadata did not reject request service construction.'
        }
        Assert-True ([IO.File]::Exists($source) -and ![IO.Directory]::Exists($expected)) 'Failed request mutated original or recreated missing metadata.'
    } finally {
        if ($moved) {
            if (Test-Path -LiteralPath $expected) { throw 'Metadata path unexpectedly recreated; parked original retained and not overwritten.' }
            [IO.Directory]::Move($parked, $expected)
        }
    }
    Send-DeleteMcp $mcp 34 @($source) 'after-error-token'
    $null = Complete-Mcp $mcp @{ '"after-error-token"' = 34 } @(30, 31, 32, 33, 34)
    $success = @($mcp.Lines | Where-Object { $_.message.id -eq 34 })[0].message
    Assert-True (!$success.result.isError -and $success.result.structuredContent.operationId) 'Fifth request did not finish after constructor errors.'
    Restore-Result @{ Json = $success.result.structuredContent }
}

foreach ($transport in @('cli', 'mcp')) {
    foreach ($nested in @($false, $true)) {
        $shape = if ($nested) { 'directory-child' } else { 'file-roots' }
        Test-Case ("hardlink-separate-requests-$transport-$shape") {
            $first = New-File 'first\shared.txt'
            $second = Join-Path (New-Directory (Join-Path $script:Scope 'second')) 'shared.txt'
            $external = Join-Path $script:Scope 'external-shared.txt'
            [PrunletConcurrentNative]::Link($second, $first); [PrunletConcurrentNative]::Link($external, $first)
            [IO.File]::WriteAllText($first + ':concurrent', 'hardlink request ADS', $utf8)
            $snapshots = @(@($first, $second, $external) | ForEach-Object { Snapshot $_ })
            $aPath = if ($nested) { Split-Path -Parent $first } else { $first }
            $operations = [Collections.Generic.List[object]]::new()
            try {
                if ($transport -eq 'cli') {
                    $gate = [PrunletConcurrentGate]::new($script:Recovery)
                    try {
                        $a = Start-Delete @($aPath) -Recursive; $gate.Bind($a.Process)
                        Assert-True ($gate.Wait(30000) -and $gate.Suspended -and !$gate.Error) 'Cannot suspend hardlink A.'
                        $b = Start-Delete @($second)
                        Assert-True (!$b.Process.WaitForExit(2000)) 'Hardlink B bypassed suspended A exclusive fallback.'
                        Assert-True ([IO.File]::Exists($second) -and [PrunletConcurrentNative]::Identity($external) -ceq $snapshots[2].id) 'Waiting hardlink B or external alias changed.'
                        $script:Evidence.bWaitedWhileASuspended = $true
                        $gate.Resume()
                        $aResult = Complete-Child $a; $operations.Add($aResult)
                        $bResult = Complete-Child $b; $operations.Add($bResult)
                        Assert-Deleted $aResult @($aPath); Assert-Deleted $bResult @($second)
                    } finally { $gate.Dispose() }
                } else {
                    $mcp = Start-Mcp
                    Send-DeleteMcp $mcp 50 @($aPath) 'hardlink-a' -Recursive
                    Send-DeleteMcp $mcp 51 @($second) 'hardlink-b'
                    $null = Complete-Mcp $mcp @{ '"hardlink-a"' = 50; '"hardlink-b"' = 51 } @(50, 51)
                    foreach ($entry in @($mcp.Lines | Where-Object { $_.message.id -in @(50, 51) })) {
                        $result = @{ ExitCode = 0; Json = $entry.message.result.structuredContent; Stderr = ''; Stdout = $entry.text }
                        $operations.Add($result)
                        Assert-True (!$entry.message.result.isError -and $result.Json.operationId) 'Concurrent hardlink MCP request failed.'
                        Assert-Deleted $result @($(if ($entry.message.id -eq 50) { $aPath } else { $second }))
                    }
                }
            } finally {
                # 共有ACLの履歴を巻き戻すため、後の実削除receiptから逆順に復元する。
                $ordered = @($operations | Where-Object { $_.Json.operationId } | Sort-Object { [IO.File]::GetLastWriteTimeUtc((Join-Path (Join-Path $script:Recovery $_.Json.operationId) 'recycle-0000-complete.json')).Ticks } -Descending)
                $script:Evidence.restoreOperationOrder = @($ordered | ForEach-Object { $_.Json.operationId })
                foreach ($operation in $ordered) { Restore-Result $operation }
                foreach ($snapshot in $snapshots) { Assert-Snapshot $snapshot }
            }
        }
    }
}

Test-Case 'shared-delete-blocks-maintain-until-finite-burst-completes' {
    $path = New-File 'shared.txt'; $gate = [PrunletConcurrentGate]::new($script:Recovery)
    try {
        $a = Start-Delete @($path); $gate.Bind($a.Process)
        Assert-True ($gate.Wait(30000) -and $gate.Suspended -and !$gate.Error) 'Cannot suspend shared deletion.'
        $maintain = Start-Child @('maintain')
        Assert-True (!$maintain.Process.WaitForExit(2000)) 'Maintain entered while shared deletion remained suspended.'
        $burst = @(0..3 | ForEach-Object { $p = New-File ('burst-{0}.txt' -f $_); @{ Path = $p; Session = (Start-Delete @($p)) } })
        foreach ($item in $burst) { $item.Result = Complete-Child $item.Session; Assert-Deleted $item.Result @($item.Path) }
        Assert-True (!$maintain.Process.HasExited) 'Maintain bypassed suspended shared deletion after independent burst.'
        $gate.Resume(); $result = Complete-Child $a; Assert-Deleted $result @($path)
        Assert-True ((Complete-Child $maintain).ExitCode -eq 0) 'Maintain failed after finite shared burst.'
        Restore-Result $result; foreach ($item in $burst) { Restore-Result $item.Result }
    } finally { $gate.Dispose() }
}

Test-Case 'baseline-three-trials-batch-throughput' {
    if (!$BaselineExecutablePath -or ![IO.File]::Exists($BaselineExecutablePath)) { $script:SkipReason = 'BaselineExecutablePath unavailable; performance comparison unverified.'; return }
    # 容量移行の導入前exeも読める共通fixture設定を使う。製品の利用者設定は変更しない。
    $benchmarkConfig = Read-Json $script:Config
    $null = $benchmarkConfig.Remove('capacityDefaultMigrationVersion')
    Save-Json $script:Config $benchmarkConfig
    $trials = [Collections.Generic.List[object]]::new()
    for ($trial = 0; $trial -lt 3; $trial++) {
        foreach ($mode in $(if ($trial % 2 -eq 0) { @('baseline', 'current') } else { @('current', 'baseline') })) {
            $exe = if ($mode -eq 'baseline') { $BaselineExecutablePath } else { $ExecutablePath }
            $roots = @(0..7 | ForEach-Object {
                $root = New-Directory (Join-Path $script:Scope ("trial-$trial-$mode-root-$_"))
                for ($i = 0; $i -lt 128; $i++) { [IO.File]::WriteAllText((Join-Path $root "$i.txt"), 'same benchmark payload', $utf8) }
                $root
            })
            $identities = @($roots | ForEach-Object { [PrunletConcurrentNative]::Identity($_) })
            $result = Complete-Child (Start-Delete $roots -Recursive -Exe $exe); Assert-Deleted $result $roots
            $trials.Add(@{ trial = $trial; mode = $mode; milliseconds = $result.Milliseconds; roots = $roots.Count; filesPerRoot = 128 })
            Restore-Result $result
            for ($i = 0; $i -lt $roots.Count; $i++) { Assert-True ([PrunletConcurrentNative]::Identity($roots[$i]) -ceq $identities[$i]) 'Benchmark restore changed root identity.' }
        }
    }
    $medians = @{}
    foreach ($mode in @('baseline', 'current')) { $sorted = @($trials | Where-Object mode -eq $mode | Sort-Object milliseconds); $medians[$mode] = $sorted[1].milliseconds }
    $script:Evidence.trials = @($trials); $script:Evidence.medianMilliseconds = $medians
}

Test-Case 'single-batch-shell-overlap-direct-observation' {
    $script:SkipReason = 'No external per-thread Shell invocation boundary observer is installed. Independent-process suspension and benchmark timing do not prove overlap inside a batch; inspect this separately.'
}
if (!$results.Count) { $results.Add(@{ name = 'empty-filter'; passed = $false; skipped = $false; error = 'No cases selected.' }) }
$passed = @($results | Where-Object passed -eq $true).Count
$skipped = @($results | Where-Object skipped -eq $true).Count
$failed = $results.Count - $passed - $skipped
Save-Json $ReportPath @{ schema = 1; executablePath = $ExecutablePath; baselineExecutablePath = $BaselineExecutablePath; timestampUtc = [DateTimeOffset]::UtcNow.ToString('O'); passed = $passed; failed = $failed; skipped = $skipped; excludedCount = $script:ExcludedCount; results = @($results); retainedDirectory = $outputRoot; unverified = @('Single-batch Shell call overlap requires direct per-thread external observation.', 'Fixtures and only their operation metadata remain for inspection. No global recycle-bin clearing or direct bin-payload cleanup is performed.') }
[ordered]@{ passed = $passed; failed = $failed; skipped = $skipped; excludedCount = $script:ExcludedCount; reportPath = $ReportPath } | ConvertTo-Json
if ($failed) { exit 1 }
exit 0
