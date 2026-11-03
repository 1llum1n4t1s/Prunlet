[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$RustProbePath,
    [Parameter(Mandatory)][string]$BuildManifestPath,
    [Parameter(Mandatory)][string]$ExpectedBuildManifestSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$Large,
    [string]$FixtureRoot
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'Verification-Fixture.ps1')
if (!$IsWindows -or [Environment]::Version.Major -ne 10) { throw 'Native Windows and .NET 10 PowerShell required' }
foreach ($path in @($ExecutablePath,$RustProbePath,$BuildManifestPath,$OutputDirectory,$ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute paths required' }
}
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-VerificationDestination $path @($repo, (Join-Path $env:USERPROFILE '.codex'))
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'External D output required' }
    if (Test-Path -LiteralPath $path) { throw 'Unused output/report required' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Output parent must exist' }
}
. (Join-Path $PSScriptRoot 'recordless-e2e/RustFileProbe.Common.ps1')
$buildBinding=Assert-RustFileProbeBinding
$script:fixtureRun = $null
if ($FixtureRoot) { $script:fixtureRun = New-VerificationFixtureRun -FixtureRoot $FixtureRoot -ForbiddenRoots @($repo, (Join-Path $env:USERPROFILE '.codex')) -NamePrefix 'hardlink-times' }
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$script:temp = Join-Path $OutputDirectory 'temp'
$null = [IO.Directory]::CreateDirectory($script:temp)
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
$env:TEMP = $script:temp; $env:TMP = $script:temp
$common = Join-Path $PSScriptRoot 'recordless-e2e/Common.ps1'
. $common
$script:commands = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
$helpers = @('NativeShellFixture.cs', 'FixtureNative.cs', 'OwnedBinLocator.cs', 'SparseFixture.cs') | ForEach-Object { Join-Path $PSScriptRoot "recordless-e2e/$_" }
$sourceHashes = @(@($PSCommandPath, $common, (Join-Path $PSScriptRoot 'Verification-Fixture.ps1')) + $helpers | ForEach-Object { @{ path = $_; sha256 = (Get-FileHash -LiteralPath $_).Hash } })
$sourceHashes+=@(Get-RustFileProbeSourceHashes)
try {
    Add-Type -Path $helpers -CompilerOptions '/unsafe'
    # 公開CLI/MCPに検証専用APIを増やさず、同じCoreの既存内部checkpointだけで競合を同期する。
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class HardlinkEntryTimesProbe {
    [StructLayout(LayoutKind.Sequential)] public struct Times { public long CreationTime, LastAccessTime, LastWriteTime, ChangeTime; public uint Attributes; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int kind,out Times times,uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle handle,int kind,ref Times times,uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int kind,byte[] data,uint size);
    static SafeFileHandle Open(string path,uint access) {
        var h=CreateFileW(path,access,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
        if(h.IsInvalid) {h.Dispose();throw new Win32Exception();} return h;
    }
    public static Times Read(string path) {
        using var h=Open(path,0x80);
        if(!GetFileInformationByHandleEx(h,0,out Times t,(uint)Marshal.SizeOf<Times>())) throw new Win32Exception();
        return t;
    }
    public static void Change(string path) {
        using var h=Open(path,0x180);
        if(!GetFileInformationByHandleEx(h,0,out Times t,(uint)Marshal.SizeOf<Times>())) throw new Win32Exception();
        t.ChangeTime+=100000000;
        if(!SetFileInformationByHandle(h,0,ref t,(uint)Marshal.SizeOf<Times>())) throw new Win32Exception();
    }
    public static long ListedChangeTime(string directory,string name) {
        using var h=Open(directory,0x81);var data=new byte[65536];bool first=true;
        for(;;) {
            if(!GetFileInformationByHandleEx(h,first?20:19,data,(uint)data.Length)) {
                if(Marshal.GetLastWin32Error()==18) throw new IOException("Fixture directory member missing");
                throw new Win32Exception();
            }
            first=false;int offset=0;
            for(;;) {
                int length=BitConverter.ToInt32(data,offset+60);
                var entry=System.Text.Encoding.Unicode.GetString(data,offset+88,length);
                if(entry==name) return BitConverter.ToInt64(data,offset+32);
                int next=BitConverter.ToInt32(data,offset);if(next==0)break;offset+=next;
            }
        }
    }
}
'@
    function New-SparseH([string]$Path) {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { [PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle); $stream.WriteByte(97); $stream.SetLength([long]1099511627776); $stream.Flush($true) }
        finally { $stream.Dispose() }
        $proof = [PrunletSparseE2E]::CaptureProof($Path)
        Assert-R ($proof.AllocationSize -le 1MB -and $proof.CompressedSize -le 1MB) 'Sparse allocation unexpectedly large'
        return $proof
    }
    function Case-H([string]$Name, [scriptblock]$Body) {
        $script:observed = @{}; $clock = [Diagnostics.Stopwatch]::StartNew()
        try { & $Body; $results.Add(@{ name = $Name; passed = $true; observed = $script:observed; elapsedMs = $clock.ElapsedMilliseconds }) }
        catch { $results.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message; stack = $_.ScriptStackTrace; observed = $script:observed; elapsedMs = $clock.ElapsedMilliseconds }) }
    }
    foreach ($transport in @('cli', 'mcp')) {
        Case-H "many-root-hardlinks-$transport" {
            $s = New-ScopeR "many-root-hardlinks-$transport"
            $outside = Join-Path $s.files 'outside'; $null = [IO.Directory]::CreateDirectory($outside)
            $keepers = @((Join-Path $outside 'empty'), (Join-Path $outside 'small'))
            [IO.File]::WriteAllBytes($keepers[0], [byte[]]::new(0)); [IO.File]::WriteAllText($keepers[1], 'export {};')
            foreach ($keeper in $keepers) { [IO.File]::WriteAllText(($keeper + ':proof'), 'external stream') }
            $external = @(foreach ($kind in 0..1) { foreach ($index in 0..699) {
                $alias = Join-Path $outside ("alias-$kind-$index")
                [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($alias, $keepers[$kind]); @{ path = $alias; kind = $kind }
            } })
            # 予約名の通常ファイルにより、ボリューム設定に依存せず同じroot固定削除経路を通す。
            $paths = @(foreach ($index in 0..127) { foreach ($kind in 0..1) {
                $parent = Join-Path (Join-Path $s.files 'targets') ("$index-$kind"); $null = [IO.Directory]::CreateDirectory($parent)
                $path = Join-Path $parent 'NUL'; [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink(('\\?\' + $path), $keepers[$kind]); $path
            } })
            $before = @($keepers | ForEach-Object { ,(Snapshot-R $_) })
            Assert-R ($before[0][0].NumberOfLinks -eq 829 -and $before[1][0].NumberOfLinks -eq 829) 'Many-root hardlink fixture count wrong'
            if ($transport -eq 'cli') {
                $response = Delete-R $s $paths; $script:observed.response = $response; Assert-R ($response.exitCode -eq 0) 'Many-root CLI deletion failed'
            } else {
                $session = Open-McpR $s
                try { Init-McpR $session; $response = Call-McpR $session 2 'delete_files' @{ paths = $paths }; $script:observed.response = $response; Assert-R (!$response.failed) 'Many-root MCP deletion failed' }
                finally { Close-McpR $session }
            }
            $script:observed.response = $response
            Assert-WireR $response $paths @($paths | ForEach-Object { 'permanently_deleted' })
            foreach ($path in $paths) { Assert-R (![IO.File]::Exists(('\\?\' + $path))) 'A deleted root name remains' }
            $after = @($keepers | ForEach-Object { ,(Snapshot-R $_) })
            foreach ($kind in 0..1) {
                foreach ($field in @('Id', 'SecurityBase64', 'Attributes')) { Assert-R ($before[$kind][0].$field -ceq $after[$kind][0].$field) "External alias $field changed" }
                Assert-R (($before[$kind][0].Streams | ConvertTo-Json -Depth 10 -Compress) -ceq ($after[$kind][0].Streams | ConvertTo-Json -Depth 10 -Compress)) 'External alias streams changed'
                Assert-R ($after[$kind][0].NumberOfLinks -eq 701) 'External alias link count wrong'
            }
            foreach ($alias in $external) { Assert-R ([Prunlet.RecordlessE2E.FixtureNative]::Identity($alias.path) -ceq $after[$alias.kind][0].Id) 'An external alias changed identity or disappeared' }
            $script:observed.aliasBefore = $before; $script:observed.aliasAfter = $after; $script:observed.externalAliasCount = $external.Count
            No-FileRecordsR $s
        }
        Case-H "stale-hardlink-$transport" {
            $s = New-ScopeR "stale-hardlink-$transport"
            $root = Join-Path $s.files 'node_modules'; $store = Join-Path $s.files 'store'
            $null = [IO.Directory]::CreateDirectory((Join-Path $root '.pnpm/package-a/node_modules/package-a'))
            $null = [IO.Directory]::CreateDirectory((Join-Path $root '.pnpm/package-b/node_modules/package-a'))
            $null = [IO.Directory]::CreateDirectory($store)
            $first = Join-Path $root '.pnpm/package-a/node_modules/package-a/index.js'
            $second = Join-Path $root '.pnpm/package-b/node_modules/package-a/index.js'
            [IO.File]::WriteAllText($first, 'initial package content')
            $alias = Join-Path $store 'package-content'
            [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($second, $first)
            [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($alias, $first)
            [IO.File]::WriteAllText($alias, 'updated shared package content')
            [HardlinkEntryTimesProbe]::Change($alias)
            $listed = [HardlinkEntryTimesProbe]::ListedChangeTime([IO.Path]::GetDirectoryName($first), 'index.js')
            $native = [HardlinkEntryTimesProbe]::Read($first).ChangeTime
            $script:observed.times = @{ listed = $listed; native = $native; stale = ($listed -ne $native) }
            Assert-R ($listed -ne $native) 'Fixture did not produce stale directory ChangeTime'
            $before = Snapshot-R $alias
            $null = New-SparseH (Join-Path $root 'oversized-sparse')
            if ($transport -eq 'cli') {
                $response = Delete-R $s @($root) -Recursive
                $script:observed.response = $response
                Assert-WireR $response @($root) @('permanently_deleted')
                Assert-R ($response.exitCode -eq 0) 'CLI deletion failed'
            } else {
                $session = Open-McpR $s
                try {
                    Init-McpR $session
                    $response = Call-McpR $session 2 'delete_files' @{ paths = @($root); recursive = $true }
                    $script:observed.response = $response
                    Assert-R (!$response.failed -and $response.json.items[0].status -ceq 'permanently_deleted') 'MCP deletion failed'
                } finally { Close-McpR $session }
            }
            Assert-R (![IO.Directory]::Exists($root)) 'Deleted tree remains'
            $after = Snapshot-R $alias
            foreach ($field in @('Id', 'SecurityBase64', 'Attributes')) { Assert-R ($before[0].$field -ceq $after[0].$field) "External alias $field changed" }
            Assert-R (($before[0].Streams | ConvertTo-Json -Depth 10 -Compress) -ceq ($after[0].Streams | ConvertTo-Json -Depth 10 -Compress)) 'External alias streams changed'
            Assert-R ($after[0].NumberOfLinks -eq 1) 'External alias link count wrong'
            $script:observed.aliasBefore = $before; $script:observed.aliasAfter = $after
            No-FileRecordsR $s
        }
    }
    Case-H 'baseline-race-time' {
        $s=New-ScopeR 'baseline-race-time'
        $script:observed.nativeHeldBaseline=Invoke-RustFileContract 'file-hardlink-entry-times' $s.files
        $script:observed.native=Invoke-RustFileContract 'file-oversize-child-baseline-race' $s.files
        No-FileRecordsR $s
    }
    Case-H 'baseline-race-replacement' {
        $s=New-ScopeR 'baseline-race-replacement'
        $script:observed.native=Invoke-RustFileContract 'file-parent-replacement' $s.files
        No-FileRecordsR $s
    }
    if ($Large) {
        Case-H 'large-sibling-baselines' {
            $s = New-ScopeR 'large-sibling-baselines'
            $root = Join-Path $s.files 'tree'; $null = [IO.Directory]::CreateDirectory($root)
            # sparseにより通常の固定削除経路を選び、ボリュームの即時削除設定へ依存しない。
            $first = Join-Path $root 'file-00000'
            [IO.File]::WriteAllText($first, 'shared content')
            $alias = Join-Path $s.files 'external-alias'
            [Prunlet.RecordlessE2E.FixtureNative]::CreateHardlink($alias, $first)
            for ($i = 1; $i -lt 32769; $i++) { [IO.File]::WriteAllBytes((Join-Path $root ('file-{0:D5}' -f $i)), [byte[]]::new(0)) }
            $null = New-SparseH (Join-Path $root 'z-oversized-sparse')
            $before = Snapshot-R $alias
            $response = Delete-R $s @($root) -Recursive
            $script:observed.response = $response; $script:observed.siblingFiles = 32769
            Assert-WireR $response @($root) @('permanently_deleted')
            Assert-R ($response.exitCode -eq 0 -and ![IO.Directory]::Exists($root)) 'Large sibling deletion failed'
            $after = Snapshot-R $alias
            foreach ($field in @('Id', 'SecurityBase64', 'Attributes')) { Assert-R ($before[0].$field -ceq $after[0].$field) "External alias $field changed" }
            Assert-R ([IO.File]::ReadAllText($alias) -ceq 'shared content' -and $after[0].NumberOfLinks -eq 1) 'Large sibling alias changed'
            $script:observed.aliasBefore = $before; $script:observed.aliasAfter = $after
            No-FileRecordsR $s
        }
    }
} finally {
    $report = @{ fixtureRun = $script:fixtureRun; executable = $ExecutablePath; executableSha256 = (Get-FileHash -LiteralPath $ExecutablePath).Hash; rustProbePath=$RustProbePath;sameSourceBuild=$buildBinding;sources = $sourceHashes;results = @($results);commands = @($script:commands);passed = @($results | Where-Object passed).Count;failed = @($results | Where-Object { !$_.passed }).Count;largeRequested=[bool]$Large;unverified=$(if(!$Large){@('Optional 32769-sibling stress case was not requested.')}else{@()});retainedFixtures = $OutputDirectory;note = 'Fresh fixtures only; failed/ambiguous deletes are never resent. Native boundaries use the same-source Rust libtest; shipping CLI/MCP paths remain separate actual-process cases.' }
    Save-R $ReportPath $report
    $env:TEMP = $oldTemp; $env:TMP = $oldTmp
}
$report | Select-Object passed, failed, retainedFixtures | ConvertTo-Json -Compress
if ($results.Count -ne $(if ($Large) { 7 } else { 6 }) -or $report.failed -ne 0) { exit 1 }
