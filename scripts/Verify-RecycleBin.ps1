[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LegacyExecutablePath,
    [string]$MoveExecutablePath,
    [string]$RecycleLegacyExecutablePath,
    [string]$BaselineExecutablePath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBaselineSha256,
    [switch]$RetainPublicationFailureFixture,
    [switch]$Large,
    [ValidateRange(32769, 1000000)][int]$LargeFileCount = 32769,
    [ValidateNotNullOrEmpty()][string[]]$CaseFilter = @('*'),
    [ValidateRange(1, 3600)][int]$ProcessTimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
# 想定する失敗: ごみ箱以外へのコピー、ID/内容/ACL/ADSの欠落、衝突先の上書き、
# dry-run/拒否の副作用、リンク先の変更、改竄記録の信頼、整理によるごみ箱項目の消失、
# CLI/MCPの方式不一致、使用中の子ディレクトリの削除や不明瞭な診断、schema 1〜4互換性の喪失。
# protected/inherited/Denyのnative O/G/D bytesの変化、外部alias経由のBin ACL改変の上書き、
# ACL snapshotのない旧schema 6の互換復元・警告の欠落も失敗とする。
# stage未readyの中断後のACL再適用、ready後競合の破壊、公開後の利用者ACL変更の上書きも拒否する。
# 実ごみ箱全体の空化は行わない。
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $LegacyExecutablePath, $MoveExecutablePath, $RecycleLegacyExecutablePath, $BaselineExecutablePath) | Where-Object { $_ }) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'All executable and verification paths must be absolute.' }
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$fixtureDrive = [IO.Path]::GetPathRoot($outputRoot)
foreach ($path in @($outputRoot, $ReportPath)) {
    Assert-VerificationDestination $path @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if ($env:GITHUB_ACTIONS -cne 'true' -and ![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Local verification requires external D: output.' }
    if (Test-Path -LiteralPath $path) { throw 'OutputDirectory and ReportPath must be new.' }
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Create external output/report parents first.' }
}
foreach ($path in @($ExecutablePath, $LegacyExecutablePath, $MoveExecutablePath, $RecycleLegacyExecutablePath, $BaselineExecutablePath) | Where-Object { $_ }) {
    if (![IO.File]::Exists($path)) { throw "Executable missing: $path" }
}
if ($BaselineExecutablePath -and @($CaseFilter | Where-Object { 'retention-and-budget-exclude-windows-bin' -like $_ }).Count) {
    $baselineVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($BaselineExecutablePath).ProductVersion
    if (($baselineVersion -split '\+')[0] -notin @('1.0.15','1.0.15.0')) { throw 'BaselineExecutablePath must be the genuine pre-locator 1.0.15 fixture producer.' }
    $baselineHash = (Get-FileHash -LiteralPath $BaselineExecutablePath).Hash
    if ($baselineHash -ceq (Get-FileHash -LiteralPath $ExecutablePath).Hash) { throw 'The aging producer must differ from the current executable.' }
    if ($ExpectedBaselineSha256 -and $baselineHash -ine $ExpectedBaselineSha256) { throw 'BaselineExecutablePath SHA differs from ExpectedBaselineSha256.' }
}
$null = [IO.Directory]::CreateDirectory($outputRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()
$script:ExcludedCount = 0
function Assert-True([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Save-Json([string]$Path, [object]$Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 80), $utf8) }
function Read-Json([string]$Path) { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 80 }
function Digest([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function New-Directory([string]$Path) { $null = [IO.Directory]::CreateDirectory($Path); return $Path }
function Start-Child([string]$Exe, [string[]]$Arguments, [Text.Encoding]$OutputEncoding = $utf8) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8; $info.StandardOutputEncoding = $OutputEncoding; $info.StandardErrorEncoding = $OutputEncoding
    $info.WorkingDirectory = $script:CaseRoot
    $info.Environment['TEMP'] = Join-Path $script:CaseRoot 'temp'
    $info.Environment['TMP'] = Join-Path $script:CaseRoot 'temp'
    $info.Environment['DOTNET_BUNDLE_EXTRACT_BASE_DIR'] = Join-Path $script:CaseRoot 'runtime-cache'
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start(); return $process
}
function Invoke-Child([string]$Exe, [string[]]$Arguments, [string]$InputText = '', [switch]$Raw, [switch]$NativeConsoleEncoding) {
    $encoding = if ($NativeConsoleEncoding) { [Text.Encoding]::GetEncoding((Get-WinSystemLocale).TextInfo.OEMCodePage) } else { $utf8 }
    $process = Start-Child $Exe $Arguments $encoding
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.Write($InputText) }; $process.StandardInput.Close()
        if (!$process.WaitForExit($ProcessTimeoutSeconds * 1000)) { $process.Kill($true); $process.WaitForExit(); throw 'Subprocess timeout.' }
        $stdout = $outTask.GetAwaiter().GetResult(); $stderr = $errTask.GetAwaiter().GetResult()
        $script:InvocationIndex++
        $prefix = Join-Path $script:CaseRoot ('process-{0:D3}' -f $script:InvocationIndex)
        [IO.File]::WriteAllText($prefix + '.stdout.txt', $stdout, $utf8)
        [IO.File]::WriteAllText($prefix + '.stderr.txt', $stderr, $utf8)
        Save-Json ($prefix + '.process.json') @{ executable = $Exe; arguments = $Arguments; exitCode = $process.ExitCode }
        $json = if (!$Raw -and $stdout.Trim()) { $stdout | ConvertFrom-Json -Depth 80 } else { $null }
        return @{ ExitCode = $process.ExitCode; Json = $json; Stdout = $stdout; Stderr = $stderr }
    } finally { $process.Dispose() }
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
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using Microsoft.Win32.SafeHandles;
public static class PrunletVolumeMoveVerificationIdentity {
    [DllImport("ntdll.dll")] static extern int NtSetSecurityObject(SafeFileHandle h, uint information, byte[] descriptor);
    // 検証専用。既知のDACL改変・復帰だけに用い、読取り証拠とは分離する。
    public static void FixtureDacl(string path, byte[] bytes) {
        var descriptor = new System.Security.AccessControl.RawSecurityDescriptor(bytes, 0);
        if ((descriptor.ControlFlags & System.Security.AccessControl.ControlFlags.DiscretionaryAclAutoInherited) != 0)
            descriptor.SetFlags(descriptor.ControlFlags | System.Security.AccessControl.ControlFlags.DiscretionaryAclAutoInheritRequired);
        byte[] input = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(input, 0);
        using (var handle = CreateFileW(ExtendedPath(path), 0x60000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            int status = NtSetSecurityObject(handle, 4, input);
            if (status < 0) throw new IOException("Fixture DACL mutation NTSTATUS " + status);
        }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int kind, byte[] data, uint size);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetKernelObjectSecurity(SafeFileHandle file, uint information, byte[] data, uint size, out uint needed);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle file, uint code, IntPtr input, uint inputSize, byte[] output, uint outputSize, out uint done, IntPtr overlapped);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StreamData { public long Size; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)] public string Name; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstStreamW(string path, int level, out StreamData data, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool FindNextStreamW(IntPtr search, out StreamData data);
    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr search);
    [StructLayout(LayoutKind.Sequential)]
    struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }
    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationFile(SafeFileHandle file, out IoStatusBlock status, out uint information, uint length, int informationClass);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLinkW(string link, string target, IntPtr security);
    static string ExtendedPath(string path) {
        string prefix = new string((char)92, 2) + "?" + (char)92;
        return path.StartsWith(prefix, StringComparison.Ordinal) ? path : prefix + path;
    }
    public static void CreateHardLink(string link, string target) {
        if (!CreateHardLinkW(ExtendedPath(link), ExtendedPath(target), IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static string Read(string path) {
        using (var handle = CreateFileW(ExtendedPath(path), 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] data = new byte[24];
            if (!GetFileInformationByHandleEx(handle, 18, data, 24)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return BitConverter.ToString(data).Replace("-", "");
        }
    }
    public static bool IsCaseSensitive(string path) {
        using (var handle = CreateFileW(ExtendedPath(path), 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            int result = NtQueryInformationFile(handle, out IoStatusBlock status, out uint flags, 4, 71);
            if (result < 0) throw new System.IO.IOException("NtQueryInformationFile(FileCaseSensitiveInformation=71) failed with NTSTATUS 0x" + unchecked((uint)result).ToString("X8") + "; IO_STATUS 0x" + status.Status.ToInt64().ToString("X"));
            return (flags & 1) != 0;
        }
    }
    public static SafeFileHandle HoldDirectoryWithoutDeleteShare(string path) {
        // FILE_LIST_DIRECTORYで共有検査へ参加する。情報照会だけのaccess=0では削除共有を拒否できない。
        var handle = CreateFileW(ExtendedPath(path), 1, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
        return handle;
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
    public static byte[] ReadSecurity(string path) {
        using (var handle = CreateFileW(ExtendedPath(path), 0x20080, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint needed; bool measured = GetKernelObjectSecurity(handle, 7, null, 0, out needed);
            int error = Marshal.GetLastWin32Error();
            if (!measured && error != 122) throw new Win32Exception(error);
            if (needed < 20 || needed > 1024 * 1024) throw new IOException("Unsupported native O/G/D descriptor length.");
            byte[] data = new byte[needed];
            if (!GetKernelObjectSecurity(handle, 7, data, needed, out needed)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Array.Resize(ref data, checked((int)needed)); return data;
        }
    }
    public static string ReadReparse(string path) {
        using (var handle = CreateFileW(ExtendedPath(path), 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] data = new byte[16384]; uint done;
            if (!DeviceIoControl(handle, 0x900A8, IntPtr.Zero, 0, data, (uint)data.Length, out done, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Array.Resize(ref data, checked((int)done)); return Convert.ToBase64String(data);
        }
    }
    public static object[] ReadStreams(string path, bool directory) {
        var streams = new System.Collections.Generic.List<object>(); StreamData data;
        IntPtr search = FindFirstStreamW(ExtendedPath(path), 0, out data, 0);
        if (search == new IntPtr(-1)) { int error = Marshal.GetLastWin32Error(); if (error != 38) throw new Win32Exception(error); return streams.ToArray(); }
        try {
            do {
                if (directory && data.Name == "::$DATA") continue;
                string streamPath = path + (data.Name == "::$DATA" ? "" : data.Name);
                using (var handle = CreateFileW(ExtendedPath(streamPath), 0x80000000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                    if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                    using (var stream = new FileStream(handle, FileAccess.Read)) {
                        streams.Add(new { name = data.Name, length = data.Size, sha256 = Convert.ToHexString(SHA256.HashData(stream)) });
                    }
                }
            } while (FindNextStreamW(search, out data));
            int error = Marshal.GetLastWin32Error(); if (error != 38) throw new Win32Exception(error);
        } finally { FindClose(search); }
        return streams.ToArray();
    }
}
public sealed class PrunletRestoreBoundaryGate : IDisposable {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(SafeProcessHandle process);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(SafeProcessHandle process);
    readonly FileSystemWatcher watcher;
    readonly string expectedPath;
    readonly string stagePrefix;
    readonly ManualResetEventSlim bound = new ManualResetEventSlim(false);
    readonly ManualResetEventSlim reached = new ManualResetEventSlim(false);
    Process process;
    int matched;
    public bool Suspended { get; private set; }
    public string Error { get; private set; }
    public string ObservedPath { get; private set; }
    public int SuspendStatus { get; private set; } = int.MinValue;
    public PrunletRestoreBoundaryGate(string watchRoot, string expectedPath, string stagePrefix) {
        this.expectedPath = expectedPath; this.stagePrefix = stagePrefix.TrimEnd('\\') + "\\";
        watcher = new FileSystemWatcher(watchRoot) { IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName };
        watcher.Created += (sender, args) => Observe(args.FullPath);
        watcher.Renamed += (sender, args) => Observe(args.FullPath);
        watcher.Error += (sender, args) => { Error = args.GetException().Message; reached.Set(); };
        watcher.EnableRaisingEvents = true;
    }
    void Observe(string path) {
        bool target = expectedPath.Length != 0 ? string.Equals(path, expectedPath, StringComparison.OrdinalIgnoreCase)
            : path.StartsWith(stagePrefix, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(path) == "0000.entry";
        if (!target || Interlocked.CompareExchange(ref matched, 1, 0) != 0) return;
        try {
            if (!bound.Wait(10000)) throw new IOException("Restore process was not bound to its boundary watcher.");
            SuspendStatus = NtSuspendProcess(process.SafeHandle);
            if (SuspendStatus < 0) throw new IOException("Cannot suspend the owned restore process: NTSTATUS 0x" + unchecked((uint)SuspendStatus).ToString("X8"));
            Suspended = true; ObservedPath = path;
        } catch (Exception error) { Error = error.Message; }
        finally { reached.Set(); }
    }
    public void Bind(Process ownedProcess) { process = ownedProcess; bound.Set(); }
    public bool Wait(int milliseconds) { return reached.Wait(milliseconds); }
    public void Resume() {
        if (!Suspended) return;
        if (!process.HasExited) {
            int status = NtResumeProcess(process.SafeHandle);
            if (status < 0) throw new IOException("Cannot resume the owned restore process: NTSTATUS 0x" + unchecked((uint)status).ToString("X8"));
        }
        Suspended = false;
    }
    public void Dispose() {
        watcher.Dispose();
        try { Resume(); } finally { bound.Dispose(); reached.Dispose(); }
    }
}
'@
        } finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
    }
    return [PrunletVolumeMoveVerificationIdentity]::Read($Path)
}

function Normalize-RecycleRestoredAclBinary([string]$BinaryBase64) {
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new([Convert]::FromBase64String($BinaryBase64), 0)
    # Get-Aclの補助比較用。合否の正本はnative O/G/D bytesの完全一致で、AIの差分も許容しない。
    $flags = [Security.AccessControl.ControlFlags]([int]$descriptor.ControlFlags -band (-bnot [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited))
    $descriptor.SetFlags($flags)
    $bytes = [byte[]]::new($descriptor.BinaryLength); $descriptor.GetBinaryForm($bytes, 0)
    return @{ binaryBase64 = [Convert]::ToBase64String($bytes); controlFlags = [int]$descriptor.ControlFlags }
}
function Snapshot-Tree([string]$Path) {
    $root = Get-Item -LiteralPath $Path -Force
    $snapshotRoot = $root.FullName
    $entries = @($root); if ($root.PSIsContainer) { $entries += @(Get-ChildItem -LiteralPath $snapshotRoot -Force -Recurse) }
    # 単一ファイルでもHashtableへ展開せず、snapshot全体を一つの配列として返す。
    return ,@($entries | ForEach-Object {
        Assert-True (!(($_.Attributes -band [IO.FileAttributes]::ReparsePoint))) 'Use ordinary trees for full snapshots.'
        $acl = Get-Acl -LiteralPath $_.FullName
        $securityBytes = $acl.GetSecurityDescriptorBinaryForm()
        $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($securityBytes, 0)
        $id = File-Id $_.FullName
        $nativeBytes = [PrunletVolumeMoveVerificationIdentity]::ReadSecurity($_.FullName)
        @{ relative = $_.FullName.Substring($snapshotRoot.Length); id = $id; attributes = [int]$_.Attributes; isDirectory = [bool]$_.PSIsContainer
           sddl = $acl.Sddl; securityDescriptorBase64 = [Convert]::ToBase64String($securityBytes); controlFlags = [int]$descriptor.ControlFlags
           nativeSecurityDescriptorBase64 = [Convert]::ToBase64String($nativeBytes)
           hash = $(if (!$_.PSIsContainer) { Digest $_.FullName } else { $null }) }
    })
}
function Assert-Tree([string]$Path, [object[]]$Snapshot, [switch]$MovedRoot, [switch]$RestoredRecycle) {
    Assert-True ($Snapshot.Count -gt 0) 'Expected a nonempty snapshot array.'
    $count = 1; if ([IO.Directory]::Exists($Path)) { $count += @(Get-ChildItem -LiteralPath $Path -Force -Recurse).Count }
    Assert-True ($count -eq $Snapshot.Count) 'Tree entry count changed.'
    foreach ($entry in $Snapshot) {
        Assert-True ($entry -is [Collections.IDictionary] -and $entry.Contains('relative') -and $entry.Contains('attributes') -and $entry.Contains('isDirectory') -and $entry.Contains('controlFlags') -and $entry.id -cmatch '^[0-9A-F]{48}$' -and ![string]::IsNullOrEmpty($entry.sddl) -and ![string]::IsNullOrEmpty($entry.securityDescriptorBase64)) 'Snapshot entry lacks identity, attributes, type or binary ACL evidence.'
        $actual = $Path + $entry.relative
        Assert-True ((File-Id $actual) -ceq $entry.id) "FileID changed: $actual"
        Assert-True ([IO.Directory]::Exists($actual) -eq $entry.isDirectory) "Object type changed: $actual"
        Assert-True ([int][IO.File]::GetAttributes($actual) -eq $entry.attributes) "Attributes changed: $actual"
        $actualAcl = Get-Acl -LiteralPath $actual
        $actualSecurityBytes = $actualAcl.GetSecurityDescriptorBinaryForm()
        $actualSecurityBase64 = [Convert]::ToBase64String($actualSecurityBytes)
        $actualDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($actualSecurityBytes, 0)
        $actualControlFlags = [int]$actualDescriptor.ControlFlags
        $aclContext = "expectedSddl=$($entry.sddl); actualSddl=$($actualAcl.Sddl); expectedBinary=$($entry.securityDescriptorBase64); actualBinary=$actualSecurityBase64; expectedControlFlags=$($entry.controlFlags); actualControlFlags=$actualControlFlags"
        if (!$entry.relative -or $actualAcl.Sddl -cne $entry.sddl -or $actualSecurityBase64 -cne $entry.securityDescriptorBase64) {
            $script:AclEvidence.Add(@{ path = $actual; mode = $(if ($MovedRoot) { 'windows-bin-owner-group' } elseif ($RestoredRecycle) { 'restored-binary-exact' } else { 'exact-sddl' }); expectedSddl = $entry.sddl; actualSddl = $actualAcl.Sddl; expectedBinaryBase64 = $entry.securityDescriptorBase64; actualBinaryBase64 = $actualSecurityBase64; expectedControlFlags = $entry.controlFlags; actualControlFlags = $actualControlFlags })
        }
        if ($MovedRoot) {
            # ごみ箱滞在中のDACLはWindowsの管理対象。所有者とgroupは引き続き照合する。
            $expectedDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new([Convert]::FromBase64String($entry.securityDescriptorBase64), 0)
            Assert-True ($actualDescriptor.Owner.Value -ceq $expectedDescriptor.Owner.Value -and $actualDescriptor.Group.Value -ceq $expectedDescriptor.Group.Value) "Bin owner/group changed: $actual; $aclContext"
        } elseif ($RestoredRecycle) {
            Assert-True ($actualControlFlags -eq $entry.controlFlags -and $actualSecurityBase64 -ceq $entry.securityDescriptorBase64) "Restored Get-Acl bytes or control flags changed: $actual; $aclContext"
            $actualNative = [Convert]::ToBase64String([PrunletVolumeMoveVerificationIdentity]::ReadSecurity($actual))
            Assert-True ($actualNative -ceq $entry.nativeSecurityDescriptorBase64) "Restored native O/G/D bytes changed: $actual"
        } else {
            Assert-True ($actualAcl.Sddl -ceq $entry.sddl) "ACL changed: $actual; $aclContext"
        }
        if (!$entry.isDirectory) {
            Assert-True ($entry.hash -cmatch '^[0-9A-F]{64}$') "Snapshot content hash missing: $actual"
            Assert-True ((Digest $actual) -ceq $entry.hash) "Content changed: $actual"
        }
    }
}
function Snapshot-NativeTree([string]$Path) {
    $null = File-Id $Path
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($root)
    $snapshot = [Collections.Generic.List[object]]::new()
    while ($pending.Count) {
        $current = $pending.Pop(); $attributes = [IO.File]::GetAttributes($current)
        $link = [bool]($attributes -band [IO.FileAttributes]::ReparsePoint)
        $directory = [bool]($attributes -band [IO.FileAttributes]::Directory)
        $bytes = [PrunletVolumeMoveVerificationIdentity]::ReadSecurity($current)
        $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($bytes, 0)
        $entry = @{ relative = $current.Substring($root.Length); id = File-Id $current; attributes = [int]$attributes; isDirectory = $directory; isLink = $link
            nativeSecurityBase64 = [Convert]::ToBase64String($bytes); nativeControlFlags = [int]$descriptor.ControlFlags; nativeSddl = $descriptor.GetSddlForm([Security.AccessControl.AccessControlSections]::All)
            owner = $descriptor.Owner.Value; group = $descriptor.Group.Value; streams = @(); reparseBase64 = $null }
        if ($link) {
            # junction自身だけを採取し、リンク先の列挙・hash・File ID取得は行わない。
            $entry.reparseBase64 = [PrunletVolumeMoveVerificationIdentity]::ReadReparse($current)
        } else {
            $entry.streams = @([PrunletVolumeMoveVerificationIdentity]::ReadStreams($current, $directory))
            # Get-Aclの表現も別途残す。完全一致の正本は独立したnative bytesとする。
            $acl = Get-Acl -LiteralPath $current
            $entry.getAclSddl = $acl.Sddl
            $entry.getAclSecurityBase64 = [Convert]::ToBase64String($acl.GetSecurityDescriptorBinaryForm())
            $entry.getAclNormalized = (Normalize-RecycleRestoredAclBinary $entry.getAclSecurityBase64).binaryBase64
            if ($directory) {
                foreach ($child in [IO.Directory]::GetFileSystemEntries($current)) { $pending.Push($child) }
            }
        }
        $snapshot.Add($entry)
    }
    return ,@($snapshot | Sort-Object relative)
}
function Assert-NativeTree([string]$Path, [object[]]$Snapshot, [switch]$WindowsOwnedSecurity, [switch]$AllowIntermediateAttributes) {
    $actual = Snapshot-NativeTree $Path
    Assert-True ($actual.Count -eq $Snapshot.Count) 'Native snapshot inventory count changed.'
    $lookup = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $actual) { $lookup.Add($entry.relative, $entry) }
    foreach ($entry in $Snapshot) {
        Assert-True ($lookup.ContainsKey($entry.relative)) "Native snapshot entry missing: $($entry.relative)"
        $current = $lookup[$entry.relative]
        foreach ($field in @('id', 'attributes', 'isDirectory', 'isLink', 'reparseBase64', 'owner', 'group')) {
            if ($AllowIntermediateAttributes -and $field -eq 'attributes') { continue }
            Assert-True ($current[$field] -ceq $entry[$field]) "Native snapshot $field changed: $($entry.relative)"
        }
        $expectedStreams = @($entry.streams | Sort-Object name | ForEach-Object { "$($_.name)|$($_.length)|$($_.sha256)" }) -join "`n"
        $actualStreams = @($current.streams | Sort-Object name | ForEach-Object { "$($_.name)|$($_.length)|$($_.sha256)" }) -join "`n"
        Assert-True ($actualStreams -ceq $expectedStreams) "Native snapshot stream bytes changed: $($entry.relative)"
        if (!$WindowsOwnedSecurity) {
            $nativeExact = $current.nativeControlFlags -eq $entry.nativeControlFlags -and $current.nativeSecurityBase64 -ceq $entry.nativeSecurityBase64
            $projectionDiffers = !$entry.isLink -and $current.getAclNormalized -cne $entry.getAclNormalized
            if (!$nativeExact -or $projectionDiffers) {
                # Get-Aclは親が異なるstageで同じnative bytesを別の継承表現へ投影する場合がある。
                # 差異を隠さず記録し、AIも含むnative bytesの完全一致だけをACLの合否に使う。
                $script:AclEvidence.Add(@{ path = $Path + $entry.relative; mode = 'native-exact-with-getacl-projection-evidence'; nativeExact = $nativeExact; getAclProjectionDiffers = $projectionDiffers
                    expectedNative = $entry.nativeSecurityBase64; actualNative = $current.nativeSecurityBase64; expectedNativeFlags = $entry.nativeControlFlags; actualNativeFlags = $current.nativeControlFlags
                    expectedGetAcl = $entry.getAclSecurityBase64; actualGetAcl = $current.getAclSecurityBase64; expectedGetAclNormalized = $entry.getAclNormalized; actualGetAclNormalized = $current.getAclNormalized
                    expectedGetAclSddl = $entry.getAclSddl; actualGetAclSddl = $current.getAclSddl })
            }
            # AIを含むcontrol bitsと全native O/G/D bytesの完全一致を要求する。
            Assert-True $nativeExact "Native O/G/D bytes changed: $($entry.relative); expected=$($entry.nativeSddl); actual=$($current.nativeSddl)"
        }
    }
    return ,$actual
}
function Invoke-RecycleCli([string[]]$Arguments, [string]$Exe = $ExecutablePath, [string]$ConfigPath = $script:Config) {
    return Invoke-Child $Exe (@('--config', $ConfigPath) + $Arguments)
}
function Read-SharedJson([string]$Path) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { $reader = [IO.StreamReader]::new($stream, $utf8); try { return $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -Depth 80 } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}
function Get-SharedRecordDigest([string]$Path) {
    # immutable記録のflush直後で停止したwriterと共存する。対象CLIはGateで停止済み。
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
}
function Start-BoundaryRestore($Operation, [switch]$Ready, [string]$PublicationName) {
    $expected = if ($PublicationName) {
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($PublicationName))).ToLowerInvariant().Substring(0, 32)
        Join-Path (Join-Path (Join-Path $script:Recovery '.recycle-records-v1') ('.publication-' + $Operation.Id + '-' + $key)) 'ready.json'
    } elseif ($Ready) { Join-Path $Operation.Root 'recycle-stage-0000-ready.json' } else { '' }
    # 実ファイル通知で今回起動したCLIだけを停止する。製品へのhookや記録のhash改変は行わない。
    # 検証configのvolumeRecoveryDirectoriesは旧storeを指し、復元専用stageはその.restore側を使う。
    $gate = [PrunletRestoreBoundaryGate]::new($script:CaseRoot, $expected, $script:Store + '.restore')
    $process = $null
    try {
        $process = Start-Child $ExecutablePath @('--config', $script:Config, 'restore', $Operation.Id)
        $gate.Bind($process)
        return @{ Process = $process; Gate = $gate; Stdout = $process.StandardOutput.ReadToEndAsync(); Stderr = $process.StandardError.ReadToEndAsync() }
    } catch { try { if ($process -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() } } finally { try { $gate.Dispose() } finally { if ($process) { $process.Dispose() } } }; throw }
}
function Close-BoundaryRestore($Session, [string]$Name) {
    $process = $Session.Process
    try { if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() } }
    finally {
        try {
            $Session.Gate.Dispose()
            [IO.File]::WriteAllText((Join-Path $script:CaseRoot "$Name.stdout.txt"), $Session.Stdout.GetAwaiter().GetResult(), $utf8)
            [IO.File]::WriteAllText((Join-Path $script:CaseRoot "$Name.stderr.txt"), $Session.Stderr.GetAwaiter().GetResult(), $utf8)
            Save-Json (Join-Path $script:CaseRoot "$Name.process.json") @{ executable = $ExecutablePath; processId = $process.Id; exitCode = $process.ExitCode; observedPath = $Session.Gate.ObservedPath; suspensionObserved = [bool]$Session.Gate.ObservedPath; suspendStatus = $Session.Gate.SuspendStatus; gateError = $Session.Gate.Error }
        } finally { $process.Dispose() }
    }
}
function New-Case([string]$Name) {
    $script:AclEvidence = [Collections.Generic.List[object]]::new()
    $script:InvocationIndex = 0
    $script:CaseRoot = New-Directory (Join-Path $outputRoot $Name)
    $script:Scope = New-Directory (Join-Path $script:CaseRoot 'scope')
    $script:Recovery = New-Directory (Join-Path $script:CaseRoot 'metadata')
    $null = New-Directory (Join-Path $script:CaseRoot 'temp')
    $null = New-Directory (Join-Path $script:CaseRoot 'runtime-cache')
    $script:Store = Join-Path $script:CaseRoot 'volume-store'
    $script:Config = Join-Path $script:CaseRoot 'config.json'
    $init = Invoke-RecycleCli @('init', '--backup-directory', $script:Recovery)
    Assert-True ($init.ExitCode -eq 0) "Init failed: $($init.Stderr)"
    $config = Read-Json $script:Config
    $config.volumeRecoveryDirectories = @{ $fixtureDrive = $script:Store }
    Save-Json $script:Config $config
}
function Test-Case([string]$Name, [scriptblock]$Body, [string]$RequiredExe) {
    if (!@($CaseFilter | Where-Object { $Name -like $_ }).Count) { $script:ExcludedCount++; return }
    if ($RequiredExe -and !((Get-Variable -Name $RequiredExe -ValueOnly))) {
        $note = if ($RequiredExe -eq 'BaselineExecutablePath') { 'RequiresBaseline: genuine pre-locator 1.0.15 not supplied; aged retention compatibility unverified.' } else { "$RequiredExe not supplied; compatibility unverified." }
        $results.Add(@{ name = $Name; passed = $null; skipped = $true; note = $note }); return
    }
    $timer = [Diagnostics.Stopwatch]::StartNew(); $script:CaseNote = $null; $script:CaseObserved = $null; $script:CaseSkipped = $false
    try {
        New-Case $Name; & $Body
        $results.Add(@{ name = $Name; passed = $(if ($script:CaseSkipped) { $null } else { $true }); skipped = $script:CaseSkipped; note = $script:CaseNote; observed = $script:CaseObserved; aclEvidence = @($script:AclEvidence); milliseconds = $timer.Elapsed.TotalMilliseconds })
    } catch {
        $results.Add(@{ name = $Name; passed = $false; skipped = $false; error = $_.Exception.Message; scriptStackTrace = $_.ScriptStackTrace; invocation = $_.InvocationInfo.PositionMessage; observed = $script:CaseObserved; aclEvidence = @($script:AclEvidence); milliseconds = $timer.Elapsed.TotalMilliseconds })
        Write-Warning "$Name : $($_.Exception.Message)"
    }
}
function Assert-Bin([string]$Id, [string]$Source) {
    $root = Resolve-VerificationOperationDirectory $script:Recovery $Id
    $manifestPath = Join-Path $root 'recycle-manifest.json'
    $manifest = Read-Json $manifestPath
    Assert-True ($manifest.schema -eq 6 -and $manifest.entries.Count -eq 1 -and $manifest.entries[0].path -ceq $Source) 'Expected one schema 6 original-path entry.'
    $receiptPath = Join-Path $root 'recycle-0000-complete.json'
    $receipt = Read-Json $receiptPath
    Assert-True ($receipt.schema -eq 6 -and $receipt.operationId -ceq $Id -and $receipt.manifestSha256 -ieq (Digest $manifestPath)) 'Receipt manifest binding invalid.'
    Assert-True ($receipt.pidl -and $receipt.physicalPath -and $receipt.identity.fileId) 'Bin PIDL, physicalPath or identity missing.'
    Assert-True ([IO.Path]::IsPathFullyQualified($receipt.physicalPath) -and ($receipt.physicalPath.Split([char]92) -icontains '$Recycle.Bin')) 'Payload is not in Windows Recycle Bin.'
    Assert-True (Test-Path -LiteralPath $receipt.physicalPath) 'Recorded bin item missing.'
    $actualId = File-Id $receipt.physicalPath
    Assert-True ($actualId.Substring(16) -ieq $receipt.identity.fileId -and $receipt.identity.fileId -ieq $manifest.entries[0].identity.fileId) 'Bin File ID differs from receipt or original manifest.'
    Assert-True (!(Test-Path -LiteralPath $script:Store)) 'New delete created a dedicated recovery payload store.'
    Assert-True (!(Test-Path -LiteralPath (Join-Path $root 'manifest.json')) -and !(Test-Path -LiteralPath (Join-Path $root 'move-manifest.json'))) 'New delete generated legacy payload metadata.'
    return @{ Id = $Id; Root = $root; ManifestPath = $manifestPath; Manifest = $manifest; ReceiptPath = $receiptPath; Receipt = $receipt; Payload = $receipt.physicalPath }
}
function Delete-Entry([string]$Path, [switch]$Recursive) {
    $list = Join-Path $script:CaseRoot ('paths-' + [guid]::NewGuid().ToString('N') + '.json')
    Save-Json $list @($Path)
    $arguments = @('delete'); if ($Recursive) { $arguments += '--recursive' }; $arguments += @('--paths-file', $list)
    $deleted = Invoke-RecycleCli $arguments
    Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $Path)) "Delete failed: $($deleted.Stdout) $($deleted.Stderr)"
    Assert-True ($deleted.Json.items[0].status -eq 'deleted') 'Delete wire status changed.'
    return Assert-Bin $deleted.Json.operationId $Path
}
function Restore-Entry($Operation, [string]$Path) {
    $restored = Invoke-RecycleCli @('restore', $Operation.Id)
    Assert-True ($restored.ExitCode -eq 0 -and $restored.Json.items[0].status -eq 'restored' -and (Test-Path -LiteralPath $Path) -and !(Test-Path -LiteralPath $Operation.Payload)) "Restore failed: $($restored.Stdout) $($restored.Stderr)"
}
function Set-RecycleFixtureAge($Operation, [int]$Days) {
    $manifest = Read-Json $Operation.ManifestPath
    Assert-True ($manifest.schema -eq 6) 'Only schema 6 fixture metadata may be rebound.'
    $manifest.createdUtc = [DateTimeOffset]::UtcNow.AddDays(-$Days).ToString('O')
    Save-Json $Operation.ManifestPath $manifest
    $manifestHash = (Digest $Operation.ManifestPath).ToLowerInvariant()
    $records = @(Get-ChildItem -LiteralPath $Operation.Root -File -Filter '*.json' | Where-Object Name -Match '^(recycle|restore)-[0-9]{4}-(intent|complete)[.]json$')
    foreach ($record in $records) {
        $receipt = Read-Json $record.FullName; $receipt.manifestSha256 = $manifestHash
        Save-Json $record.FullName $receipt
    }
    $recycleHashes = @{}
    foreach ($record in $records | Where-Object Name -Match '^recycle-[0-9]{4}-complete[.]json$') {
        $receipt = Read-Json $record.FullName
        $recycleHashes[[int]$receipt.index] = (Digest $record.FullName).ToLowerInvariant()
    }
    foreach ($record in $records | Where-Object Name -Match '^restore-[0-9]{4}-(intent|complete)[.]json$') {
        $receipt = Read-Json $record.FullName
        Assert-True ($recycleHashes.ContainsKey([int]$receipt.index)) 'Restore fixture receipt has no bound recycle completion.'
        $receipt.recycleSha256 = $recycleHashes[[int]$receipt.index]
        Save-Json $record.FullName $receipt
    }
}
Test-Case 'unrecyclable-oversized-sparse-preserves-source' {
    if (!('PrunletSparseE2E' -as [type])) {
        $oldTemp = $env:TEMP; $oldTmp = $env:TMP
        try {
            $env:TEMP = Join-Path $script:CaseRoot 'temp'; $env:TMP = $env:TEMP
            Add-Type -Path (Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs')
        } finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp }
    }
    $sparseTargets = [Collections.Generic.List[object]]::new()
    function New-SparseTarget([string]$Path, [byte[]]$Prefix, [long]$Length) {
        [IO.File]::WriteAllBytes($Path, $Prefix)
        $registered = @{ path = [IO.Path]::GetFullPath($Path); expectedLogicalLength = $Length; prefixBase64 = [Convert]::ToBase64String($Prefix); proofEstablished = $false }
        $sparseTargets.Add($registered)
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            [PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle)
            $stream.SetLength($Length); $stream.Flush($true)
        } finally { $stream.Dispose() }
        $proof = [PrunletSparseE2E]::CaptureProof($Path)
        $registered.id = $proof.Id; $registered.nativeSecurityBase64 = $proof.SecurityBase64; $registered.attributes = $proof.Attributes
        $registered.creationProof = $proof; $registered.proofEstablished = $true
        $allocation = [PrunletSparseE2E]::Allocation($Path)
        Assert-True ($allocation -le 1MB) 'Sparse fixture allocated more than 1 MiB; delete verification was not started.'
        $attributes = [IO.File]::GetAttributes($Path)
        Assert-True (($attributes -band [IO.FileAttributes]::SparseFile) -ne 0 -and [IO.FileInfo]::new($Path).Length -eq $Length) 'Sparse fixture shape invalid.'
        $registered.allocation = $allocation
        Assert-True ($proof.Id -ceq (File-Id $Path) -and $proof.Length -eq $Length -and $proof.Attributes -eq [int]$attributes -and $proof.NumberOfLinks -eq 1) 'Sparse creation proof changed before test entry.'
        return $registered
    }
    $sparseBodyFailure = $null
    try {
    $prefix = [Text.Encoding]::UTF8.GetBytes('Prunlet sparse refusal fixture: small prefix only')
    Assert-True ($prefix.Length -eq 49) 'Sparse fixture prefix must be 49 bytes.'
    $drive = [IO.DriveInfo]::new($fixtureDrive)
    Assert-True ($drive.IsReady -and $drive.TotalSize -lt ([long]::MaxValue - 4096)) 'Volume total size unavailable or cannot safely add sparse margin.'
    $logicalLength = [long]($drive.TotalSize + 4096)
    $file = Join-Path $script:Scope 'oversized-cli-sparse.bin'
    $cliFixture = New-SparseTarget $file $prefix $logicalLength
    $allocation = $cliFixture.allocation; $originalId = $cliFixture.id; $attributes = $cliFixture.attributes
    # 長大な論理領域はhash/走査せず、先頭prefixと永続IDだけを観測する。
    $cliBinBefore = [PrunletSparseE2E]::BinTotals($fixtureDrive)
    $result = Invoke-RecycleCli @('delete', '--', $file)
    $cliBinAfter = [PrunletSparseE2E]::BinTotals($fixtureDrive)
    Assert-True ($cliBinAfter[0] -eq $cliBinBefore[0] -and $cliBinAfter[1] -eq $cliBinBefore[1]) 'CLI refusal changed D: Recycle Bin item count or total bytes.'
    $publicFailures = @($result.Json.items | Where-Object { $_.status -in @('failed', 'ambiguous', 'error') })
    Assert-True ($result.ExitCode -ne 0 -and ($result.Json.error -or $publicFailures.Count -gt 0) -and @($result.Json.items | Where-Object status -EQ 'deleted').Count -eq 0) "Unrecyclable target did not report a public failure: $($result.Stdout) $($result.Stderr)"
    Assert-True ([IO.File]::Exists($file) -and (File-Id $file) -ceq $originalId -and [IO.FileInfo]::new($file).Length -eq $logicalLength -and [IO.File]::GetAttributes($file) -eq $attributes) 'Unrecyclable source identity, length or attributes changed.'
    $actualPrefix = [byte[]]::new($prefix.Length)
    $stream = [IO.File]::OpenRead($file)
    try { $stream.ReadExactly($actualPrefix) } finally { $stream.Dispose() }
    Assert-True ([Convert]::ToBase64String($actualPrefix) -ceq [Convert]::ToBase64String($prefix) -and [PrunletSparseE2E]::Allocation($file) -le 1MB) 'Sparse prefix or physical allocation changed.'
    Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Recurse -File -Filter 'recycle-*-complete.json').Count -eq 0) 'Unrecyclable target has a recycle completion receipt.'
    $observed = [ordered]@{ logicalLength = $logicalLength; prefixBytes = $prefix.Length; cliAllocatedBytes = $allocation; cliExitCode = $result.ExitCode; cliItems = @($result.Json.items); cliError = $result.Json.error
        cliBinBefore = @{ itemCount = $cliBinBefore[0]; totalBytes = $cliBinBefore[1] }; cliBinAfter = @{ itemCount = $cliBinAfter[0]; totalBytes = $cliBinAfter[1] } }
    $script:CaseObserved = $observed
    $mcpFile = Join-Path $script:Scope 'oversized-mcp-sparse.bin'
    $mcpFixture = New-SparseTarget $mcpFile $prefix $logicalLength
    Assert-True ($mcpFixture.id -cne $originalId) 'MCP sparse fixture reused the CLI object.'
    $observed.mcpAllocatedBytes = $mcpFixture.allocation
    $process = Start-Child $ExecutablePath @('--config', $script:Config, 'mcp')
    $transcript = [Collections.Generic.List[object]]::new()
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        function Rpc-Sparse([object]$Request) {
            $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $Request -Depth 16 -Compress)); $process.StandardInput.Flush()
            for ($index = 0; $index -lt 64; $index++) {
                $read = $process.StandardOutput.ReadLineAsync(); if (!$read.Wait(30000)) { throw 'MCP sparse response timeout.' }
                $line = $read.GetAwaiter().GetResult(); if (!$line) { throw 'MCP sparse output closed.' }
                $reply = $line | ConvertFrom-Json -Depth 80; $transcript.Add($reply)
                if ($reply.id -eq $Request.id) { return $reply }
            }
            throw 'Too many MCP sparse notifications.'
        }
        $init = Rpc-Sparse @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'recycle-sparse-e2e'; version = '1' } } }
        Assert-True ($null -ne $init.result) 'MCP sparse initialize failed.'
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $process.StandardInput.Flush()
        $mcpBinBefore = [PrunletSparseE2E]::BinTotals($fixtureDrive)
        $deleted = Rpc-Sparse @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = 'delete_files'; arguments = @{ paths = @($mcpFile) } } }
        $mcpBinAfter = [PrunletSparseE2E]::BinTotals($fixtureDrive)
        $observed.mcpBinBefore = @{ itemCount = $mcpBinBefore[0]; totalBytes = $mcpBinBefore[1] }; $observed.mcpBinAfter = @{ itemCount = $mcpBinAfter[0]; totalBytes = $mcpBinAfter[1] }
        Assert-True ($mcpBinAfter[0] -eq $mcpBinBefore[0] -and $mcpBinAfter[1] -eq $mcpBinBefore[1]) 'MCP refusal changed D: Recycle Bin item count or total bytes.'
        $mcpItems = @($deleted.result.structuredContent.items)
        $observed.mcpIsError = $deleted.result.isError; $observed.mcpItems = $mcpItems; $observed.mcpContent = @($deleted.result.content)
        Assert-True ($deleted.result.isError -eq $true -and $null -ne $deleted.result.structuredContent -and @($mcpItems | Where-Object { $_.status -in @('failed', 'ambiguous', 'error') }).Count -gt 0 -and @($mcpItems | Where-Object status -EQ 'deleted').Count -eq 0) 'MCP oversized deletion was not a structured failure.'
        Assert-True ([IO.File]::Exists($mcpFile) -and (File-Id $mcpFile) -ceq $mcpFixture.id -and [IO.FileInfo]::new($mcpFile).Length -eq $logicalLength -and [IO.File]::GetAttributes($mcpFile) -eq $mcpFixture.attributes -and [PrunletSparseE2E]::Allocation($mcpFile) -le 1MB) 'MCP oversized deletion changed source or allocated data.'
        $actualPrefix = [byte[]]::new($prefix.Length); $stream = [IO.File]::OpenRead($mcpFile)
        try { $stream.ReadExactly($actualPrefix) } finally { $stream.Dispose() }
        Assert-True ([Convert]::ToBase64String($actualPrefix) -ceq [Convert]::ToBase64String($prefix)) 'MCP oversized deletion changed sparse prefix.'
        Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Recurse -File -Filter 'recycle-*-complete.json').Count -eq 0 -and !(Test-Path -LiteralPath $script:Store)) 'MCP oversized deletion created a completion receipt or native-delete fallback store.'
        $process.StandardInput.Close(); Assert-True ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'MCP sparse process did not exit cleanly.'
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'mcp.stderr.txt'), $stderrTask.GetAwaiter().GetResult(), $utf8)
    } finally {
        Save-Json (Join-Path $script:CaseRoot 'mcp-transcript.json') @($transcript)
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose()
    }
    $folder = New-Directory (Join-Path $script:Scope 'oversized-sparse-folder')
    $child = Join-Path $folder 'oversized-sparse.bin'
    $folderFixture = New-SparseTarget $child $prefix $logicalLength
    Assert-True ($folderFixture.id -cne $originalId -and $folderFixture.id -cne $mcpFixture.id) 'Recursive folder sparse fixture reused a refused object.'
    $originalId = $folderFixture.id; $attributes = $folderFixture.attributes
    $observed.folderAllocatedBytes = $folderFixture.allocation
    $folderId = File-Id $folder; $folderAttributes = [IO.File]::GetAttributes($folder)
    $folderAcl = [Convert]::ToBase64String((Get-Acl -LiteralPath $folder).GetSecurityDescriptorBinaryForm())
    $childAcl = [Convert]::ToBase64String((Get-Acl -LiteralPath $child).GetSecurityDescriptorBinaryForm())
    $folderNativeAcl = [Convert]::ToBase64String([PrunletVolumeMoveVerificationIdentity]::ReadSecurity($folder))
    $childNativeAcl = [Convert]::ToBase64String([PrunletVolumeMoveVerificationIdentity]::ReadSecurity($child))
    Assert-True ((File-Id $child) -ceq $originalId -and [PrunletSparseE2E]::Allocation($child) -le 1MB) 'Moving sparse fixture into folder changed identity or allocation.'
    $pathsFile = Join-Path $script:CaseRoot 'oversized-folder-paths.json'
    Save-Json $pathsFile @($folder)
    $folderBinBefore = [PrunletSparseE2E]::BinTotals($fixtureDrive)
    $folderResult = Invoke-RecycleCli @('delete', '--recursive', '--paths-file', $pathsFile)
    $folderBinAfter = [PrunletSparseE2E]::BinTotals($fixtureDrive)
    $observed.folderBinBefore = @{ itemCount = $folderBinBefore[0]; totalBytes = $folderBinBefore[1] }; $observed.folderBinAfter = @{ itemCount = $folderBinAfter[0]; totalBytes = $folderBinAfter[1] }
    $observed.folderExitCode = $folderResult.ExitCode; $observed.folderItems = @($folderResult.Json.items); $observed.folderError = $folderResult.Json.error
    if ($folderResult.ExitCode -eq 0 -and $folderResult.Json.items[0].status -eq 'deleted') {
        $observed.folderOutcome = 'recycled'
        Assert-True (!(Test-Path -LiteralPath $folder)) 'Oversized folder claimed deletion but source remains.'
        $op = Assert-Bin $folderResult.Json.operationId $folder
        Assert-True ((File-Id $op.Payload) -ceq $folderId) 'Recycled folder File ID changed.'
        $binChild = Join-Path $op.Payload 'oversized-sparse.bin'
        Assert-True ((File-Id $binChild) -ceq $originalId -and [IO.FileInfo]::new($binChild).Length -eq $logicalLength -and [IO.File]::GetAttributes($binChild) -eq $attributes -and [PrunletSparseE2E]::Allocation($binChild) -le 1MB) 'Recycled sparse child identity, stream length, attributes or allocation changed.'
        $actualPrefix = [byte[]]::new($prefix.Length); $stream = [IO.File]::OpenRead($binChild)
        try { $stream.ReadExactly($actualPrefix) } finally { $stream.Dispose() }
        Assert-True ([Convert]::ToBase64String($actualPrefix) -ceq [Convert]::ToBase64String($prefix)) 'Recycled sparse child stream prefix changed.'
        foreach ($pair in @(@($folderAcl, $op.Payload), @($childAcl, $binChild))) {
            $expectedAcl = [Security.AccessControl.RawSecurityDescriptor]::new([Convert]::FromBase64String($pair[0]), 0)
            $actualAcl = [Security.AccessControl.RawSecurityDescriptor]::new((Get-Acl -LiteralPath $pair[1]).GetSecurityDescriptorBinaryForm(), 0)
            Assert-True ($actualAcl.Owner.Value -ceq $expectedAcl.Owner.Value -and $actualAcl.Group.Value -ceq $expectedAcl.Group.Value) "Recycled folder owner/group changed: $($pair[1])"
        }
        $conflict = New-Directory $folder
        [IO.File]::WriteAllText((Join-Path $conflict 'current.txt'), 'retain-current', $utf8)
        $collision = Invoke-RecycleCli @('restore', $op.Id)
        Assert-True ($collision.Json.items[0].status -eq 'conflict' -and (File-Id $op.Payload) -ceq $folderId -and [IO.File]::ReadAllText((Join-Path $conflict 'current.txt')) -ceq 'retain-current') 'Oversized folder restore overwrote collision or consumed bin item.'
        [IO.Directory]::Move($folder, (Join-Path $script:Scope 'retained-folder-conflict'))
        Restore-Entry $op $folder
        Assert-True ((File-Id $folder) -ceq $folderId -and [IO.File]::GetAttributes($folder) -eq $folderAttributes -and (File-Id $child) -ceq $originalId -and [IO.FileInfo]::new($child).Length -eq $logicalLength -and [IO.File]::GetAttributes($child) -eq $attributes -and [PrunletSparseE2E]::Allocation($child) -le 1MB) 'Oversized folder restore changed object identity or sparse stream.'
        $actualPrefix = [byte[]]::new($prefix.Length); $stream = [IO.File]::OpenRead($child)
        try { $stream.ReadExactly($actualPrefix) } finally { $stream.Dispose() }
        Assert-True ([Convert]::ToBase64String($actualPrefix) -ceq [Convert]::ToBase64String($prefix)) 'Restored sparse stream prefix changed.'
        foreach ($pair in @(@($folderAcl, $folder, $folderNativeAcl), @($childAcl, $child, $childNativeAcl))) {
            $actualAcl = [Convert]::ToBase64String((Get-Acl -LiteralPath $pair[1]).GetSecurityDescriptorBinaryForm())
            $actualNativeAcl = [Convert]::ToBase64String([PrunletVolumeMoveVerificationIdentity]::ReadSecurity($pair[1]))
            Assert-True ($actualAcl -ceq $pair[0] -and $actualNativeAcl -ceq $pair[2]) "Restored oversized folder ACL bytes changed: $($pair[1])"
        }
    } else {
        $observed.folderOutcome = 'refused'
        Assert-True ($folderBinAfter[0] -eq $folderBinBefore[0] -and $folderBinAfter[1] -eq $folderBinBefore[1]) 'Recursive folder refusal changed D: Recycle Bin item count or total bytes.'
        $folderFailures = @($folderResult.Json.items | Where-Object { $_.status -in @('failed', 'ambiguous', 'error') })
        Assert-True ($folderResult.ExitCode -ne 0 -and ($folderResult.Json.error -or $folderFailures.Count -gt 0) -and @($folderResult.Json.items | Where-Object status -EQ 'deleted').Count -eq 0) 'Oversized folder neither recycled nor reported a public failure.'
        Assert-True ((File-Id $folder) -ceq $folderId -and [IO.File]::GetAttributes($folder) -eq $folderAttributes -and (File-Id $child) -ceq $originalId -and [IO.FileInfo]::new($child).Length -eq $logicalLength -and [IO.File]::GetAttributes($child) -eq $attributes -and [PrunletSparseE2E]::Allocation($child) -le 1MB) 'Refused oversized folder changed source or allocation.'
        Assert-True ([Convert]::ToBase64String((Get-Acl -LiteralPath $folder).GetSecurityDescriptorBinaryForm()) -ceq $folderAcl -and [Convert]::ToBase64String((Get-Acl -LiteralPath $child).GetSecurityDescriptorBinaryForm()) -ceq $childAcl) 'Refused oversized folder changed ACL bytes.'
        $actualPrefix = [byte[]]::new($prefix.Length); $stream = [IO.File]::OpenRead($child)
        try { $stream.ReadExactly($actualPrefix) } finally { $stream.Dispose() }
        Assert-True ([Convert]::ToBase64String($actualPrefix) -ceq [Convert]::ToBase64String($prefix)) 'Refused oversized folder changed sparse stream prefix.'
        Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Recurse -File -Filter 'recycle-*-complete.json').Count -eq 0 -and !(Test-Path -LiteralPath $script:Store)) 'Refused oversized folder created a completion receipt or fallback store.'
    }
    $script:CaseNote = "CLI and MCP file refusal, plus recursive folder outcome ($($observed.folderOutcome)) verified at logical length=$logicalLength; allocated bytes=$allocation; prefix bytes=$($prefix.Length)."
    } catch {
        $sparseBodyFailure = $_
        throw
    } finally {
        $finalizers = [Collections.Generic.List[object]]::new()
        foreach ($target in $sparseTargets) {
            try {
                if (!$target.proofEstablished) { throw 'Sparse creation did not establish complete original evidence; the fixture was preserved.' }
                Assert-VerificationDestination $target.path @()
                $finalized = [PrunletSparseE2E]::RestoreTiny($target.path, $target.id, $target.nativeSecurityBase64, [int]$target.attributes, [long]$target.expectedLogicalLength, [Convert]::FromBase64String($target.prefixBase64), [ulong]1MB)
                $finalizers.Add($finalized)
            } catch {
                $finalizers.Add(@{ Success = $false; Path = $target.path; Error = $_.Exception.Message; MutationStarted = $false; ExpectedLogicalLength = $target.expectedLogicalLength })
            }
        }
        if ($null -eq $script:CaseObserved) { $script:CaseObserved = [ordered]@{} }
        $script:CaseObserved.sparseFixtures = @($sparseTargets)
        $script:CaseObserved.sparseFinalizers = @($finalizers)
        $script:CaseObserved.sparseBodyAssertionsCompleted = ($null -eq $sparseBodyFailure)
        $script:CaseObserved.sparseBodyFailure = $(if ($sparseBodyFailure) { $sparseBodyFailure.Exception.Message } else { $null })
        $failedFinalizers = @($finalizers | Where-Object { !$_.Success })
        $script:CaseObserved.sparseFinalizerFailed = ($failedFinalizers.Count -ne 0)
        if ($failedFinalizers.Count) {
            $script:CaseObserved.sparseFinalizerErrors = @($failedFinalizers | ForEach-Object { @{ path = $_.Path; error = $_.Error } })
            if (!$sparseBodyFailure) { throw ('Sparse finalizer failed; unknown fixture state was retained: ' + (($failedFinalizers | ForEach-Object Path) -join ', ')) }
            # 本体例外を上書きせず、独立したfinalizer失敗はobservedへ残す。
            Write-Warning 'Sparse body failed and one or more sparse finalizers also failed; both failures are retained in the case evidence.'
        } elseif ($sparseTargets.Count) {
            $script:CaseNote += ' Afterwards, the finally block verified exact native identity/O/G/D/attributes, a single unnamed stream and bounded zero allocated tails, then restored each owned fixture to its tiny prefix length. No 1 TB stream read was performed.'
        }
    }
}
Test-Case 'default-recovery-budget-cli-and-mcp' {
    $oneGiB = [long]1073741824
    $explicitBytes = [long]34359738368
    $config = Read-Json $script:Config
    Assert-True ([long]$config.maxRecoveryBytes -eq $oneGiB) 'Fresh init did not write the 1 GiB default.'
    Assert-True ($config.capacityDefaultMigrationVersion -eq 1) 'Fresh init was not marked migrated.'
    $initial = Invoke-RecycleCli @('maintain', '--dry-run')
    Assert-True ($initial.ExitCode -eq 0 -and [long]$initial.Json.maxRecoveryBytes -eq $oneGiB) 'Fresh config maintenance did not use the 1 GiB default.'
    $null = $config.Remove('maxRecoveryBytes'); Save-Json $script:Config $config
    $omitted = Invoke-RecycleCli @('maintain', '--dry-run')
    Assert-True ($omitted.ExitCode -eq 0 -and [long]$omitted.Json.maxRecoveryBytes -eq $oneGiB -and !(Read-Json $script:Config).Contains('maxRecoveryBytes')) 'Omitted property did not load the 1 GiB default or was rewritten.'
    $config = Read-Json $script:Config; $config.maxRecoveryBytes = $explicitBytes
    $null = $config.Remove('capacityDefaultMigrationVersion'); Save-Json $script:Config $config
    $legacyConfigHash = Digest $script:Config
    $explicit = Invoke-RecycleCli @('maintain', '--dry-run')
    Assert-True ($explicit.ExitCode -eq 0 -and [long]$explicit.Json.maxRecoveryBytes -eq $explicitBytes -and [long](Read-Json $script:Config).maxRecoveryBytes -eq $explicitBytes) 'Explicit 32 GiB budget was not preserved.'
    Assert-True ((Digest $script:Config) -ceq $legacyConfigHash) 'Reading a legacy config unexpectedly migrated it.'
    $help = Invoke-Child $ExecutablePath @('--help') -Raw
    Assert-True ($help.ExitCode -eq 0 -and $help.Stdout -match '(?i)1\s*GiB') 'CLI help does not describe the 1 GiB default.'
    $process = Start-Child $ExecutablePath @('--config', $script:Config, 'mcp')
    $transcript = [Collections.Generic.List[object]]::new()
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $request = @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'recovery-default-e2e'; version = '1' } } }
        $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $request -Depth 16 -Compress)); $process.StandardInput.Flush()
        $read = $process.StandardOutput.ReadLineAsync(); if (!$read.Wait(30000)) { throw 'MCP default initialize timed out.' }
        $line = $read.GetAwaiter().GetResult(); if (!$line) { throw 'MCP default initialize closed output.' }
        $reply = $line | ConvertFrom-Json -Depth 80; $transcript.Add($reply)
        Assert-True ($reply.id -eq 1 -and $reply.result.instructions -match '(?i)1\s*GiB') 'MCP initialize instructions do not describe the 1 GiB default.'
        $process.StandardInput.Close(); Assert-True ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'MCP default process did not exit cleanly.'
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'mcp.stderr.txt'), $stderrTask.GetAwaiter().GetResult(), $utf8)
    } finally {
        Save-Json (Join-Path $script:CaseRoot 'mcp-transcript.json') @($transcript)
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose()
    }
    $script:CaseObserved = @{ initBytes = $oneGiB; freshMaintainBytes = $initial.Json.maxRecoveryBytes; omittedMaintainBytes = $omitted.Json.maxRecoveryBytes; explicitMaintainBytes = $explicit.Json.maxRecoveryBytes; explicitConfigBytes = (Read-Json $script:Config).maxRecoveryBytes }
}
Test-Case 'file-and-folder-exact-roundtrip' {
    foreach ($folder in @($false, $true)) {
        $file = New-File ($(if ($folder) { 'tree\child.bin' } else { 'single.bin' }))
        $path = if ($folder) { Split-Path -Parent $file } else { $file }
        $snapshot = Snapshot-Tree $path
        $op = Delete-Entry $path -Recursive:$folder
        Assert-True ((File-Id $op.Payload) -ceq $snapshot[0].id) 'Bin object identity changed.'
        Assert-Tree $op.Payload $snapshot -MovedRoot
        Restore-Entry $op $path; Assert-Tree $path $snapshot -RestoredRecycle
        $again = Invoke-RecycleCli @('restore', $op.Id)
        Assert-VerificationRepeatedRestore $again $op.Id 1; Assert-Tree $path $snapshot -RestoredRecycle
    }
}
Test-Case 'interrupted-unready-stage-refuses-alias-acl-change' {
    $file = New-File 'unready-tree\group\0000.bin' 31
    for ($index = 1; $index -lt 256; $index++) { $null = New-File ('unready-tree\group\{0:D4}.bin' -f $index) 17 }
    $tree = Join-Path $script:Scope 'unready-tree'
    $alias = Join-Path $script:Scope 'external-unready-alias.bin'
    $null = File-Id $file; [PrunletVolumeMoveVerificationIdentity]::CreateHardLink($alias, $file)
    $before = Snapshot-NativeTree $tree
    Save-Json (Join-Path $script:CaseRoot 'native-original.json') $before
    $op = Delete-Entry $tree -Recursive
    $session = Start-BoundaryRestore $op
    $intentPath = Join-Path $op.Root 'recycle-stage-0000-intent.json'
    $readyPath = Join-Path $op.Root 'recycle-stage-0000-ready.json'
    try {
        Assert-True ($session.Gate.Wait(60000) -and $session.Gate.Suspended -and !$session.Gate.Error) "Did not suspend the owned CLI at stage arrival: $($session.Gate.Error)"
        $intent = Read-SharedJson $intentPath
        $stage = Join-Path $intent.stageOperationPath '0000.entry'
        Assert-True ($session.Gate.ObservedPath -ceq $stage -and !(Test-Path -LiteralPath $readyPath)) 'Stage-arrival interruption missed the unready boundary.'
        Assert-True (!(Test-Path -LiteralPath $tree) -and (Test-Path -LiteralPath $stage) -and !(Test-Path -LiteralPath $op.Payload) -and (File-Id $stage) -ceq @($before | Where-Object relative -EQ '')[0].id) 'Interrupted restore did not retain exactly the same object in stage.'
        # 実際に到着したstageと実intentを残して、今回のCLIだけを強制終了する。
        $session.Process.Kill(); Assert-True ($session.Process.WaitForExit(15000)) 'Interrupted restore process did not exit.'
    } finally { Close-BoundaryRestore $session 'interrupted-stage-arrival' }
    $intentHash = Digest $intentPath
    # 中断時点ではclose時Archive等の途中属性を許容し、以後の拒否前後は採取した実属性と完全一致させる。
    $null = Assert-NativeTree $stage $before -WindowsOwnedSecurity -AllowIntermediateAttributes
    $acl = Get-Acl -LiteralPath $alias; $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::ExecuteFile, [Security.AccessControl.AccessControlType]::Deny))
    Set-Acl -LiteralPath $alias -AclObject $acl
    $changed = Snapshot-NativeTree $stage; $aliasChanged = Snapshot-NativeTree $alias
    Save-Json (Join-Path $script:CaseRoot 'native-interrupted-stage-after-alias-change.json') $changed
    $retry = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($retry.ExitCode -ne 0 -and @($retry.Json.items | Where-Object status -In @('failed', 'ambiguous', 'error')).Count -gt 0 -and !(Test-Path -LiteralPath $tree)) 'Restore accepted an interrupted unready stage after external ACL modification.'
    $null = Assert-NativeTree $stage $changed; $null = Assert-NativeTree $alias $aliasChanged
    Assert-True (!(Test-Path -LiteralPath $readyPath) -and !(Test-Path -LiteralPath $op.Payload) -and (Digest $intentPath) -ceq $intentHash) 'Unready stage refusal wrote readiness, recreated Bin data, or altered its intent.'
    $script:CaseNote = 'Actual CLI was killed after Shell stage arrival and before ready; intentionally changed stage, alias and immutable journals are retained.'
    $script:CaseObserved = @{ operationId = $op.Id; realProcessInterruption = $true; stage = $stage; rootFileId = (File-Id $stage); stageReadyAbsent = $true; refusalItems = @($retry.Json.items); aclAndDataRetained = $true }
}
Test-Case 'stage-ready-conflict-resume-and-published-acl-guard' {
    $file = New-File 'ready-tree\group\0000.bin' 31
    for ($index = 1; $index -lt 256; $index++) { $null = New-File ('ready-tree\group\{0:D4}.bin' -f $index) 17 }
    $tree = Join-Path $script:Scope 'ready-tree'
    $before = Snapshot-NativeTree $tree
    Save-Json (Join-Path $script:CaseRoot 'native-original.json') $before
    $op = Delete-Entry $tree -Recursive
    $session = Start-BoundaryRestore $op -Ready
    $intentPath = Join-Path $op.Root 'recycle-stage-0000-intent.json'
    $readyPath = Join-Path $op.Root 'recycle-stage-0000-ready.json'
    try {
        Assert-True ($session.Gate.Wait(60000) -and $session.Gate.Suspended -and !$session.Gate.Error) "Did not suspend the owned CLI at immutable stage-ready publication: $($session.Gate.Error)"
        $intent = Read-SharedJson $intentPath; $ready = Read-SharedJson $readyPath
        $stage = Join-Path $intent.stageOperationPath '0000.entry'
        Assert-True ($session.Gate.ObservedPath -ceq $readyPath -and $ready.phase -eq 'ready' -and !(Test-Path -LiteralPath $tree) -and !(Test-Path -LiteralPath $op.Payload)) 'Stage-ready interruption missed the prepublication boundary.'
        $null = Assert-NativeTree $stage $before
        $null = New-File 'ready-tree\retain-current.bin' 43
        $conflictBefore = Snapshot-NativeTree $tree
        $session.Gate.Resume()
        Assert-True ($session.Process.WaitForExit($ProcessTimeoutSeconds * 1000)) 'Stage-ready conflict restore process timed out.'
        $reply = $session.Stdout.GetAwaiter().GetResult() | ConvertFrom-Json -Depth 80
        Assert-True ($reply.items[0].status -eq 'conflict') 'A destination created after stage-ready did not produce a preserved conflict.'
    } finally { Close-BoundaryRestore $session 'stage-ready-conflict' }
    $readyHash = Digest $readyPath; $intentHash = Digest $intentPath
    $null = Assert-NativeTree $tree $conflictBefore; $null = Assert-NativeTree $stage $before
    [IO.Directory]::Move($tree, (Join-Path $script:Scope 'retained-ready-tree-conflict'))
    $resumed = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($resumed.ExitCode -eq 0 -and $resumed.Json.items[0].status -eq 'restored' -and !(Test-Path -LiteralPath $stage)) 'Verified stage-ready payload did not resume and publish.'
    $after = Assert-NativeTree $tree $before
    Save-Json (Join-Path $script:CaseRoot 'native-resumed-restored.json') $after
    Assert-VerificationClosedRecord $script:Recovery $op.Id 6
    # 完了後の記録改変を避け、別の実プロセスで公開後・complete永続化前の失敗を作る。
    $op = Delete-Entry $tree -Recursive
    $session = Start-BoundaryRestore $op -PublicationName 'restore-0000-complete.json'
    $intentPath = Join-Path $op.Root 'recycle-stage-0000-intent.json'
    $readyPath = Join-Path $op.Root 'recycle-stage-0000-ready.json'
    $completePath = Join-Path $op.Root 'restore-0000-complete.json'
    $priorMetadataAcl = $null
    try {
        Assert-True ($session.Gate.Wait(60000) -and $session.Gate.Suspended -and !$session.Gate.Error) 'Receipt failure fixture missed completion-publication ready boundary.'
        $intent = Read-SharedJson $intentPath; $stage = Join-Path $intent.stageOperationPath '0000.entry'
        Assert-True ((Test-Path -LiteralPath $tree) -and !(Test-Path -LiteralPath $stage) -and !(Test-Path -LiteralPath $op.Payload) -and !(Test-Path -LiteralPath $completePath)) 'Completion publication fixture did not reach the already-published source boundary.'
        $readyHash = Get-SharedRecordDigest $readyPath; $intentHash = Get-SharedRecordDigest $intentPath
        $priorMetadataAcl = [PrunletVolumeMoveVerificationIdentity]::ReadSecurity($op.Root)
        $metadataAcl = Get-Acl -LiteralPath $op.Root; $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $metadataAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::WriteData, [Security.AccessControl.AccessControlType]::Deny))
        [PrunletVolumeMoveVerificationIdentity]::FixtureDacl($op.Root, $metadataAcl.GetSecurityDescriptorBinaryForm())
        $session.Gate.Resume()
        Assert-True ($session.Process.WaitForExit($ProcessTimeoutSeconds * 1000)) 'Completion failure fixture timed out.'
        $failed = $session.Stdout.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -Depth 80
        Assert-True ($session.Process.ExitCode -ne 0 -and (Test-Path -LiteralPath $tree) -and !(Test-Path -LiteralPath $completePath) -and $failed.items[0].status -notin @('restored', 'already_restored')) 'Fixture did not fail receipt persistence after source publication.'
    } finally {
        Close-BoundaryRestore $session 'published-completion-failure'
        if ($priorMetadataAcl) {
            [PrunletVolumeMoveVerificationIdentity]::FixtureDacl($op.Root, $priorMetadataAcl)
            Assert-True ([Convert]::ToBase64String([PrunletVolumeMoveVerificationIdentity]::ReadSecurity($op.Root)) -ceq [Convert]::ToBase64String($priorMetadataAcl)) 'Metadata ACL fixture rollback changed native bytes.'
        }
    }
    $null = Assert-NativeTree $tree $before
    $acl = Get-Acl -LiteralPath $file; $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::ExecuteFile, [Security.AccessControl.AccessControlType]::Deny))
    Set-Acl -LiteralPath $file -AclObject $acl
    $publishedChanged = Snapshot-NativeTree $tree
    Save-Json (Join-Path $script:CaseRoot 'native-published-with-user-acl-change.json') $publishedChanged
    $refused = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($refused.ExitCode -ne 0 -and @($refused.Json.items | Where-Object status -In @('failed', 'ambiguous', 'error')).Count -gt 0) 'Missing-complete recovery accepted changed published ACLs.'
    $null = Assert-NativeTree $tree $publishedChanged
    Assert-True (!(Test-Path -LiteralPath $completePath) -and !(Test-Path -LiteralPath $stage) -and !(Test-Path -LiteralPath $op.Payload) -and (Digest $readyPath) -ceq $readyHash -and (Digest $intentPath) -ceq $intentHash) 'Published ACL refusal reapplied ACLs, recreated payloads, completed, or changed journals.'
    if ($RetainPublicationFailureFixture) {
        $script:CaseNote = 'Fixture generation only: receipt publication failed after source publication; changed source ACL was refused. Normal recovery is intentionally left for the publication lifecycle verifier.'
        $script:CaseObserved = @{ fixtureGenerationOnly = $true; operationId = $op.Id; configPath = $script:Config; recovery = $script:Recovery; operationDirectory = $op.Root; tree = $tree; changedFile = $file; originalSnapshot = (Join-Path $script:CaseRoot 'native-original.json'); readyPath = $readyPath; intentPath = $intentPath; completionPath = $completePath; completionWriteFailure = $failed; publishedAclRetained = $true }
        return
    }
    # 拒否確認後、今回のfixtureで加えたDACLだけを元のnative bytesへ戻し、通常経路の再開と回収まで確認する。
    $originalLeaf = @($before | Where-Object { $_.relative.TrimStart('\') -ceq 'group\0000.bin' })
    Assert-True ($originalLeaf.Count -eq 1) 'Published ACL recovery fixture lacks its original native descriptor.'
    [PrunletVolumeMoveVerificationIdentity]::FixtureDacl($file, [Convert]::FromBase64String($originalLeaf[0].nativeSecurityBase64))
    $null = Assert-NativeTree $tree $before
    $finished = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($finished.ExitCode -eq 0 -and $finished.Json.items[0].status -in @('restored', 'already_restored')) 'Valid published source could not resume after the fixture ACL was restored.'
    $null = Assert-NativeTree $tree $before
    Assert-VerificationClosedRecord $script:Recovery $op.Id 6
    Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -File -Filter 'recycle-pending-*').Count -eq 0) 'Authority publication left an unowned flat pending after normal recovery.'
    $publicationRoot = Join-Path $script:Recovery '.recycle-records-v1'
    Assert-True (@(Get-ChildItem -LiteralPath $publicationRoot -Directory -Filter ('.publication-' + $op.Id + '-*')).Count -eq 0) 'Completed recovery retained its publication control attempts.'
    $script:CaseNote = 'Ready conflict and missing completion used suspended CLI processes. Modified published ACLs were refused; restoring only the fixture ACL allowed normal recovery and terminal control collection.'
    $script:CaseObserved = @{ operationId = $op.Id; readyConflictRealProcess = $true; resumedNativeExact = $true; missingCompleteFixture = $true; completionWriteFailure = $failed; publishedAclRetained = $true; refusalItems = @($refused.Json.items); recoveredAfterFixtureAclReset = $true; publicationControlsCollected = $true }
}
Test-Case 'protected-descendant-native-security-roundtrip' {
    $tree = New-Directory (Join-Path $script:Scope 'protected-tree')
    $protected = New-Directory (Join-Path $tree 'protected')
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $inheritance = [Security.AccessControl.InheritanceFlags]('ContainerInherit, ObjectInherit')
    $acl = Get-Acl -LiteralPath $protected
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($identity in @($sid, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $protected -AclObject $acl
    $file = New-File 'protected-tree\protected\inherited\payload.bin' 4096
    $null = New-File 'protected-tree\ordinary.bin' 73
    [IO.File]::WriteAllText("${file}:proof", 'protected ADS bytes', $utf8)
    $fileAcl = Get-Acl -LiteralPath $file
    # ExecuteFileだけを拒否し、snapshotの読取りと復元用metadata権限を妨げない。
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::ExecuteFile, [Security.AccessControl.AccessControlType]::Deny))
    Set-Acl -LiteralPath $file -AclObject $fileAcl
    $alias = Join-Path $script:Scope 'external-protected-alias.bin'
    $null = File-Id $file; [PrunletVolumeMoveVerificationIdentity]::CreateHardLink($alias, $file)
    $targetFile = New-File 'external-junction-target\preserved.bin' 257
    $target = Split-Path -Parent $targetFile
    $link = Join-Path $protected 'external-link'
    $null = New-Item -ItemType Junction -Path $link -Target $target
    $before = Snapshot-NativeTree $tree; $aliasBefore = Snapshot-NativeTree $alias; $targetBefore = Snapshot-NativeTree $target
    Assert-True (@($before | Where-Object { $_.relative -ceq '\protected' -and ($_.nativeControlFlags -band 0x1000) -ne 0 }).Count -eq 1) 'Protected descendant fixture lost DACL protection.'
    Assert-True (@($before | Where-Object { $_.relative -ceq '\protected\inherited\payload.bin' -and $_.nativeSddl -match '\(D;' }).Count -eq 1) 'Protected descendant fixture lost explicit Deny.'
    Save-Json (Join-Path $script:CaseRoot 'native-before.json') $before
    Save-Json (Join-Path $script:CaseRoot 'external-alias-before.json') $aliasBefore
    Save-Json (Join-Path $script:CaseRoot 'external-target-before.json') $targetBefore
    $op = Delete-Entry $tree -Recursive
    Assert-True ($null -ne $op.Manifest.entries[0].security -and $null -ne $op.Receipt.security) 'New recycle record lacks original or bin security snapshot.'
    $bin = Assert-NativeTree $op.Payload $before -WindowsOwnedSecurity
    Save-Json (Join-Path $script:CaseRoot 'native-in-bin.json') $bin
    $null = Assert-NativeTree $target $targetBefore
    $null = Assert-NativeTree $alias $aliasBefore -WindowsOwnedSecurity
    $null = New-File 'protected-tree\preserve-conflict.bin' 41
    $current = Snapshot-NativeTree $tree
    $conflict = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($conflict.Json.items[0].status -eq 'conflict') 'Protected tree restore accepted an occupied destination.'
    $null = Assert-NativeTree $tree $current; $null = Assert-NativeTree $op.Payload $bin
    [IO.Directory]::Move($tree, (Join-Path $script:Scope 'retained-protected-tree-conflict'))
    Restore-Entry $op $tree
    $after = Assert-NativeTree $tree $before
    $null = Assert-NativeTree $alias $aliasBefore; $null = Assert-NativeTree $target $targetBefore
    Save-Json (Join-Path $script:CaseRoot 'native-restored.json') $after
    $script:CaseObserved = @{ operationId = $op.Id; nativeEntries = $before.Count; rawOgdExact = $true; controlFlagsExact = $true; conflictVerified = $true; externalAliasFinalExact = $true; externalTargetExact = $true; saclNotRequested = $true }
}
Test-Case 'bin-acl-alias-tamper-refuses-restore' {
    $file = New-File 'bin-acl-original.bin' 257
    [IO.File]::WriteAllText("${file}:proof", 'retained ACL tamper ADS', $utf8)
    $alias = Join-Path $script:Scope 'external-bin-acl-alias.bin'
    $null = File-Id $file; [PrunletVolumeMoveVerificationIdentity]::CreateHardLink($alias, $file)
    $before = Snapshot-NativeTree $file
    $op = Delete-Entry $file
    $bin = Assert-NativeTree $op.Payload $before -WindowsOwnedSecurity
    $receiptHash = Digest $op.ReceiptPath
    $acl = Get-Acl -LiteralPath $alias
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::ExecuteFile, [Security.AccessControl.AccessControlType]::Deny))
    Set-Acl -LiteralPath $alias -AclObject $acl
    $tampered = Snapshot-NativeTree $op.Payload; $aliasTampered = Snapshot-NativeTree $alias
    Assert-True ($tampered[0].nativeSecurityBase64 -cne $bin[0].nativeSecurityBase64) 'External hardlink alias did not change the bin object ACL.'
    $null = Assert-NativeTree $op.Payload $before -WindowsOwnedSecurity
    Save-Json (Join-Path $script:CaseRoot 'native-bin-before-tamper.json') $bin
    Save-Json (Join-Path $script:CaseRoot 'native-bin-after-alias-tamper.json') $tampered
    $restore = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($restore.ExitCode -ne 0 -and @($restore.Json.items | Where-Object status -In @('failed', 'ambiguous')).Count -gt 0 -and !(Test-Path -LiteralPath $file)) 'Restore accepted or published an externally changed bin ACL.'
    $null = Assert-NativeTree $op.Payload $tampered; $null = Assert-NativeTree $alias $aliasTampered
    Assert-True ((Digest $op.ReceiptPath) -ceq $receiptHash -and @(Get-ChildItem -LiteralPath $op.Root -Filter 'restore-*-complete.json' -File).Count -eq 0) 'Refused ACL tamper changed the recycle receipt or completed restoration.'
    $script:CaseNote = 'Intentionally changed small fixture remains in the Windows bin with its alias and metadata; original ACL is not reapplied.'
    $script:CaseObserved = @{ operationId = $op.Id; restoreExitCode = $restore.ExitCode; items = @($restore.Json.items); binPayload = $op.Payload; retainedAlias = $alias; nativeAclRetained = $true; dataAndIdPreserved = $true }
}
Test-Case 'schema6-without-security-snapshot-compatibility' {
    $file = New-File 'legacy-recycle-original.bin' 513
    [IO.File]::WriteAllText("${file}:proof", 'legacy schema6 ADS', $utf8)
    $before = Snapshot-NativeTree $file
    $config = Read-Json $script:Config; $null = $config.Remove('capacityDefaultMigrationVersion')
    $legacyConfig = Join-Path $script:CaseRoot 'legacy-config.json'; Save-Json $legacyConfig $config
    $deleted = Invoke-RecycleCli @('delete', '--', $file) -Exe $RecycleLegacyExecutablePath -ConfigPath $legacyConfig
    Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $file)) 'Pre-security schema 6 executable did not recycle the fixture.'
    $op = Assert-Bin $deleted.Json.operationId $file
    Assert-True (!$op.Manifest.entries[0].ContainsKey('security') -and !$op.Receipt.ContainsKey('security')) 'Compatibility fixture unexpectedly has a security snapshot.'
    $bin = Assert-NativeTree $op.Payload $before -WindowsOwnedSecurity
    $null = New-File 'legacy-recycle-original.bin' 19
    $current = Snapshot-NativeTree $file
    $conflict = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($conflict.Json.items[0].status -eq 'conflict') 'Legacy schema 6 restore overwrote an occupied path.'
    $null = Assert-NativeTree $file $current; $null = Assert-NativeTree $op.Payload $bin
    [IO.File]::Move($file, (Join-Path $script:Scope 'retained-legacy-recycle-conflict.bin'), $false)
    $restored = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($restored.ExitCode -eq 0 -and $restored.Json.items[0].status -eq 'restored' -and !(Test-Path -LiteralPath $op.Payload)) 'Legacy schema 6 fixture was not restored.'
    Assert-True ((@($restored.Json.warnings) -join ' ') -match '(?i)no ACL snapshot' -and (@($restored.Json.warnings) -join ' ') -match '(?i)cannot guarantee the original ACL') 'Legacy schema 6 restoration omitted the missing original ACL warning.'
    $after = Assert-NativeTree $file $before -WindowsOwnedSecurity
    Save-Json (Join-Path $script:CaseRoot 'legacy-schema6-original.json') $before
    Save-Json (Join-Path $script:CaseRoot 'legacy-schema6-restored.json') $after
    $script:CaseNote = 'Pre-security schema 6 record restored with explicit ACL limitation warning; original ACL equality is unsupported for this legacy format.'
    $script:CaseObserved = @{ operationId = $op.Id; fixtureExecutable = $RecycleLegacyExecutablePath; warnings = @($restored.Json.warnings); dataAndIdPreserved = $true; originalAclRecorded = $false; conflictVerified = $true }
} 'RecycleLegacyExecutablePath'
Test-Case 'locked-child-directory-cli-mcp-and-roundtrip' {
    $file = New-File 'locked-tree\child\nested.bin' 4096
    $child = Split-Path -Parent $file; $tree = Split-Path -Parent $child
    $null = New-File 'locked-tree\sibling.bin' 128
    $before = Snapshot-Tree $tree
    Save-Json (Join-Path $script:CaseRoot 'source-before.json') $before
    $observed = [ordered]@{}; $script:CaseObserved = $observed
    # 子ディレクトリだけを削除共有なしで保持し、root自身の使用中とは区別する。
    $held = [PrunletVolumeMoveVerificationIdentity]::HoldDirectoryWithoutDeleteShare($child)
    try {
        Assert-True (![PrunletVolumeMoveVerificationIdentity]::CanOpenForDelete($child)) 'Child directory delete-share fixture was not locked.'
        Assert-True ([PrunletVolumeMoveVerificationIdentity]::CanOpenForDelete($tree)) 'Fixture locked the root instead of only its child.'
        $cli = Invoke-RecycleCli @('delete', '--recursive', '--', $tree)
        $observed.cliExitCode = $cli.ExitCode; $observed.cliItems = @($cli.Json.items)
        Assert-True ($cli.ExitCode -ne 0 -and @($cli.Json.items | Where-Object status -In @('failed', 'ambiguous', 'error')).Count -gt 0 -and @($cli.Json.items | Where-Object status -EQ 'deleted').Count -eq 0) 'CLI accepted a tree with a locked child directory.'
        $cliError = @($cli.Json.items | ForEach-Object error) -join ' '
        Assert-True ($cliError -match '(?i)HRESULT 0x(8027002[78]|8007002[01])' -and $cliError -match 'in use by another process' -and $cliError -match 'original path' -and $cliError -match 'Recycle Bin' -and $cliError -match 'retrying manually') "CLI sharing error lost its HRESULT or recovery guidance: $cliError"
        Assert-Tree $tree $before
        $process = Start-Child $ExecutablePath @('--config', $script:Config, 'mcp')
        $transcript = [Collections.Generic.List[object]]::new()
        try {
            $stderrTask = $process.StandardError.ReadToEndAsync()
            function Rpc-LockedChild([object]$Request) {
                $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $Request -Depth 16 -Compress)); $process.StandardInput.Flush()
                for ($index = 0; $index -lt 64; $index++) {
                    $read = $process.StandardOutput.ReadLineAsync(); if (!$read.Wait(30000)) { throw 'MCP locked-child response timeout.' }
                    $line = $read.GetAwaiter().GetResult(); if (!$line) { throw 'MCP locked-child output closed.' }
                    $reply = $line | ConvertFrom-Json -Depth 80; $transcript.Add($reply)
                    if ($reply.id -eq $Request.id) { return $reply }
                }
                throw 'Too many MCP locked-child notifications.'
            }
            $init = Rpc-LockedChild @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'recycle-locked-child-e2e'; version = '1' } } }
            Assert-True ($null -ne $init.result) 'MCP locked-child initialize failed.'
            $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $process.StandardInput.Flush()
            $deleted = Rpc-LockedChild @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = 'delete_files'; arguments = @{ paths = @($tree); recursive = $true } } }
            $mcpItems = @($deleted.result.structuredContent.items)
            $observed.mcpIsError = $deleted.result.isError; $observed.mcpItems = $mcpItems
            Assert-True ($deleted.result.isError -eq $true -and @($mcpItems | Where-Object status -In @('failed', 'ambiguous', 'error')).Count -gt 0 -and @($mcpItems | Where-Object status -EQ 'deleted').Count -eq 0) 'MCP accepted a tree with a locked child directory.'
            $mcpError = @($mcpItems | ForEach-Object error) -join ' '
            Assert-True ($mcpError -match '(?i)HRESULT 0x(8027002[78]|8007002[01])' -and $mcpError -match 'in use by another process' -and $mcpError -match 'original path' -and $mcpError -match 'Recycle Bin' -and $mcpError -match 'retrying manually') "MCP sharing error lost its HRESULT or recovery guidance: $mcpError"
            Assert-Tree $tree $before
            $process.StandardInput.Close(); Assert-True ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'MCP locked-child process did not exit cleanly.'
            [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'mcp.stderr.txt'), $stderrTask.GetAwaiter().GetResult(), $utf8)
        } finally {
            Save-Json (Join-Path $script:CaseRoot 'mcp-transcript.json') @($transcript)
            if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose()
        }
        Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Recurse -File -Filter 'recycle-*-complete.json').Count -eq 0) 'Locked child refusal produced a recycle completion receipt.'
    } finally { $held.Dispose() }
    # 解放後の明示操作で同じ実体を往復し、復元先の衝突も上書きしない。
    $op = Delete-Entry $tree -Recursive
    $observed.releasedOperationId = $op.Id
    Assert-Tree $op.Payload $before -MovedRoot
    $null = New-File 'locked-tree\conflict.bin' 31
    $conflictBefore = Snapshot-Tree $tree
    $collision = Invoke-RecycleCli @('restore', $op.Id)
    Assert-True ($collision.Json.items[0].status -eq 'conflict') 'Restore accepted an occupied directory destination.'
    Assert-Tree $tree $conflictBefore; Assert-Tree $op.Payload $before -MovedRoot
    [IO.Directory]::Move($tree, (Join-Path $script:Scope 'retained-locked-tree-conflict'))
    Restore-Entry $op $tree; Assert-Tree $tree $before -RestoredRecycle
}
Test-Case 'dry-run-and-rejected-inputs-preserve-source' {
    $file = New-File 'dry file 日本語.bin'; $before = Snapshot-Tree $file
    $metadataBefore = @(Get-ChildItem -LiteralPath $script:Recovery -Force -Recurse).FullName -join '|'
    $dry = Invoke-RecycleCli @('delete', '--dry-run', '--', $file)
    Assert-True ($dry.ExitCode -eq 0 -and $dry.Json.items[0].status -eq 'would_delete') 'Dry-run result changed.'
    Assert-Tree $file $before
    Assert-True ((@(Get-ChildItem -LiteralPath $script:Recovery -Force -Recurse).FullName -join '|') -ceq $metadataBefore) 'Dry-run created metadata.'
    $treeFile = New-File 'nonrecursive\child'; $tree = Split-Path -Parent $treeFile
    $treeBefore = Snapshot-Tree $tree
    $reject = Invoke-RecycleCli @('delete', '--', $tree)
    Assert-True ($reject.ExitCode -ne 0) 'Nonrecursive nonempty directory was accepted.'; Assert-Tree $tree $treeBefore
    foreach ($target in @($script:Recovery, $script:CaseRoot)) {
        $result = Invoke-RecycleCli @('delete', '--recursive', '--', $target)
        Assert-True ($result.ExitCode -ne 0 -and (Test-Path -LiteralPath $target)) 'Protected metadata or its parent was accepted.'
    }
    $missing = Join-Path $script:Scope 'absent'
    $null = Invoke-RecycleCli @('delete', '--', $missing)
    Assert-True (!(Test-Path -LiteralPath $missing)) 'Missing input appeared.'
    $invalid = Join-Path $script:CaseRoot 'invalid-paths.json'; Save-Json $invalid @{ paths = @($file) }
    Assert-True ((Invoke-RecycleCli @('delete', '--paths-file', $invalid)).ExitCode -ne 0) 'Invalid paths JSON accepted.'
    Assert-Tree $file $before
    Assert-True (!(Test-Path -LiteralPath $script:Store)) 'Rejected/dry-run input created payload store.'
}
foreach ($directory in @($false, $true)) {
    Test-Case "restore-collision-directory-$directory" {
        $file = New-File 'original\child'; $path = if ($directory) { Split-Path -Parent $file } else { $file }
        $original = Snapshot-Tree $path; $op = Delete-Entry $path -Recursive:$directory
        if ($directory) { $null = New-Directory $path; [IO.File]::WriteAllText((Join-Path $path 'current'), 'current', $utf8) }
        else { [IO.File]::WriteAllText($path, 'current', $utf8) }
        $current = Snapshot-Tree $path; $binId = File-Id $op.Payload
        $result = Invoke-RecycleCli @('restore', $op.Id)
        Assert-True ($result.Json.items[0].status -eq 'conflict') 'Restore did not report conflict.'
        Assert-Tree $path $current; Assert-True ((File-Id $op.Payload) -ceq $binId) 'Collision consumed bin item.'
        $retained = Join-Path $script:Scope ('retained-' + [guid]::NewGuid().ToString('N'))
        if ($directory) { [IO.Directory]::Move($path, $retained) } else { [IO.File]::Move($path, $retained, $false) }
        Restore-Entry $op $path; Assert-Tree $path $original -RestoredRecycle
    }
}
Test-Case 'attributes-ads-hardlink-unicode-spaces' {
    $file = New-File '日本語 space 😀\data.bin'
    Assert-True ($file.Length -lt 260) 'Normal attribute/ADS/hardlink fixture requires a path below the Windows Recycle Bin long-path limit.'
    [IO.File]::WriteAllText("${file}:stream", 'alternate-stream', $utf8)
    $alias = Join-Path $script:Scope 'alias.bin'; $null = File-Id $file
    [PrunletVolumeMoveVerificationIdentity]::CreateHardLink($alias, $file)
    $acl = Get-Acl -LiteralPath $file
    $acl.SetAccessRuleProtection($true, $true)
    $world = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::WorldSid, $null)
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($world, [Security.AccessControl.FileSystemRights]::ExecuteFile, [Security.AccessControl.AccessControlType]::Deny))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($currentSid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $file -AclObject $acl
    $fixtureAcl = Get-Acl -LiteralPath $file
    Assert-True ($fixtureAcl.AreAccessRulesProtected -and @($fixtureAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny -and $_.IdentityReference.Value -ceq $world.Value }).Count -gt 0 -and @($fixtureAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.IdentityReference.Value -ceq $currentSid.Value }).Count -gt 0) 'Protected ACL with explicit deny/allow fixture was not created.'
    [IO.File]::SetAttributes($file, [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive)
    $before = Snapshot-Tree $file; $aliasId = File-Id $alias; $aliasHash = Digest $alias
    $op = Delete-Entry $file
    Assert-True ((File-Id $alias) -ceq $aliasId -and (Digest $alias) -ceq $aliasHash -and (File-Id $op.Payload) -ceq $aliasId) 'Hardlink sharing changed.'
    Assert-True ([IO.File]::ReadAllText("$($op.Payload):stream") -ceq 'alternate-stream') 'Bin ADS missing.'
    Restore-Entry $op $file; Assert-Tree $file $before -RestoredRecycle
    Assert-True ([IO.File]::ReadAllText("${file}:stream") -ceq 'alternate-stream' -and (File-Id $file) -ceq $aliasId) 'Restored ADS or hardlink missing.'
}
Test-Case 'hardlink-external-writes-while-recycled-remain-shared' {
    $file = New-File 'shared\original.bin'
    $originalId = File-Id $file
    $alias = Join-Path $script:Scope 'external-alias.bin'
    [PrunletVolumeMoveVerificationIdentity]::CreateHardLink($alias, $file)
    $before = Snapshot-Tree $file
    $originalLength = [IO.FileInfo]::new($file).Length
    Assert-True ((File-Id $alias) -ceq $originalId) 'Writable external hardlink fixture does not share the original identity.'
    $op = Delete-Entry $file
    Assert-True ((File-Id $op.Payload) -ceq $originalId -and (File-Id $alias) -ceq $originalId) 'Recycle detached the external hardlink.'
    Assert-Tree $op.Payload $before -MovedRoot
    $updatedContent = 'Updated through the surviving external alias: ' + ('different-length-content-' * 17)
    [IO.File]::WriteAllText($alias, $updatedContent, $utf8)
    $updatedHash = Digest $alias
    Assert-True ([IO.FileInfo]::new($alias).Length -ne $originalLength -and [IO.File]::ReadAllText($op.Payload) -ceq $updatedContent -and (Digest $op.Payload) -ceq $updatedHash -and (File-Id $op.Payload) -ceq $originalId -and (File-Id $alias) -ceq $originalId) 'Writes through the surviving alias did not remain visible in the same bin object.'
    # 内容だけが利用者の書込みで変わる。元ID/属性/Owner/Group/binary ACLの期待値は保持する。
    $before[0].hash = $updatedHash
    Assert-Tree $op.Payload $before -MovedRoot
    Restore-Entry $op $file
    Assert-Tree $file $before -RestoredRecycle
    Assert-Tree $alias $before -RestoredRecycle
    Assert-True ((File-Id $file) -ceq $originalId -and (File-Id $alias) -ceq $originalId -and [IO.File]::ReadAllText($file) -ceq $updatedContent -and [IO.File]::ReadAllText($alias) -ceq $updatedContent) 'Restored entry lost identity, external sharing or updated alias content.'
    $script:CaseObserved = @{ behavior='external-hardlink-write-remained-shared'; originalLength=$originalLength; updatedLength=[IO.FileInfo]::new($file).Length; originalFileId=$originalId; restoredFileId=(File-Id $file); aliasFileId=(File-Id $alias) }
}
Test-Case 'long-path-windows-limit-preserves-source' {
    $file = New-File ('日本語 space 😀\' + ('long-' * 36) + '\data.bin')
    Assert-True ($file.Length -gt 260) 'Long-path fixture must exceed 260 characters.'
    [IO.File]::WriteAllText("${file}:stream", 'long-path alternate-stream', $utf8)
    $before = Snapshot-Tree $file; $originalId = $before[0].id
    $list = Join-Path $script:CaseRoot 'long-paths.json'; Save-Json $list @($file)
    $result = Invoke-RecycleCli @('delete', '--paths-file', $list)
    if ($result.ExitCode -eq 0) {
        Assert-True ($result.Json.items[0].status -eq 'deleted' -and ![IO.File]::Exists($file)) 'Successful long-path delete did not recycle the source.'
        $op = Assert-Bin $result.Json.operationId $file; Assert-Tree $op.Payload $before -MovedRoot
        Assert-True ([IO.File]::ReadAllText("$($op.Payload):stream") -ceq 'long-path alternate-stream') 'Recycled long-path ADS changed.'
        [IO.File]::WriteAllText($file, 'preserve current long-path file', $utf8); $current = Snapshot-Tree $file
        $conflict = Invoke-RecycleCli @('restore', $op.Id)
        Assert-True ($conflict.Json.items[0].status -eq 'conflict' -and (File-Id $op.Payload) -ceq $originalId) 'Long-path restore collision consumed or replaced the bin item.'
        Assert-Tree $file $current
        [IO.File]::Move($file, (Join-Path $script:Scope 'retained-long-path-current'), $false)
        Restore-Entry $op $file; Assert-Tree $file $before -RestoredRecycle
        Assert-True ([IO.File]::ReadAllText("${file}:stream") -ceq 'long-path alternate-stream') 'Restored long-path ADS changed.'
        $script:CaseObserved = @{ behavior='recycled-and-restored'; pathLength=$file.Length; roundtripVerified=$true; collisionVerified=$true }
        return
    }
    Assert-True (($result.Stdout + $result.Stderr) -match '(?i)0x80270038' -and @($result.Json.items | Where-Object { $_.status -in @('failed','ambiguous') }).Count -gt 0 -and @($result.Json.items | Where-Object status -EQ 'deleted').Count -eq 0) "Unexpected long-path failure; not treated as a Windows limit: $($result.Stdout) $($result.Stderr)"
    Assert-Tree $file $before
    Assert-True ([IO.File]::ReadAllText("${file}:stream") -ceq 'long-path alternate-stream') 'Rejected long-path ADS changed.'
    Assert-True (@(Get-ChildItem -LiteralPath $script:Recovery -Recurse -File -Filter 'recycle-*-complete.json').Count -eq 0) 'Rejected long-path target has a recycle completion receipt.'
    $shell = New-Object -ComObject Shell.Application
    try {
        $bin = $shell.NameSpace(10)
        Assert-True ($null -ne $bin) 'Cannot inspect Windows Recycle Bin for unexpected long-path item.'
        foreach ($item in $bin.Items()) {
            if ($item.IsFolder) { continue }
            $physical = [string]$item.Path
            Assert-True ([IO.Path]::IsPathFullyQualified($physical)) 'Cannot inspect a Recycle Bin file identity.'
            Assert-True ((File-Id $physical) -cne $originalId) 'Rejected long-path file unexpectedly appeared in Recycle Bin.'
        }
    } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    $script:CaseObserved = @{ behavior='rejected-windows-recycle-max-path'; hresult='0x80270038'; pathLength=$file.Length; sourcePreserved=$true; binItemAbsent=$true; roundtripVerified=$false }
    $script:CaseNote = 'Windows Recycle Bin path limit refusal verified; this is preservation evidence, not a successful long-path roundtrip.'
}
Test-Case 'directory-link-preserves-target' {
    $targetFile = New-File 'target\child'; $target = Split-Path -Parent $targetFile
    $before = Snapshot-Tree $target; $link = Join-Path $script:Scope 'junction'
    $null = New-Item -ItemType Junction -Path $link -Target $target
    $linkId = File-Id $link
    $result = Invoke-RecycleCli @('delete', '--recursive', '--', $link)
    Assert-Tree $target $before
    if ($result.ExitCode -ne 0) { Assert-True ((File-Id $link) -ceq $linkId) 'Rejected link changed.'; $script:CaseNote = 'Link unsupported; verified rejection preserved link and target.'; return }
    $op = Assert-Bin $result.Json.operationId $link
    Restore-Entry $op $link
    Assert-True ((File-Id $link) -ceq $linkId) 'Link identity changed.'; Assert-Tree $target $before
}
Test-Case 'retention-and-budget-exclude-windows-bin' {
    $file = New-File 'old-bin' 4096; $before = Snapshot-NativeTree $file
    # bound hint生成前の真正旧版で作り、日時fixtureを初回新版評価より前に完成させる。
    $legacyConfigValue = Read-Json $script:Config; $null = $legacyConfigValue.Remove('capacityDefaultMigrationVersion')
    $legacyConfig = Join-Path $script:CaseRoot 'pre-locator-config.json'; Save-Json $legacyConfig $legacyConfigValue
    $paths = Join-Path $script:CaseRoot 'pre-locator-paths.json'; Save-Json $paths @($file)
    $deleted = Invoke-RecycleCli @('delete', '--paths-file', $paths) -Exe $BaselineExecutablePath -ConfigPath $legacyConfig
    $script:CaseObserved = @{ fixtureExecutable = $BaselineExecutablePath; fixtureExecutableSha256 = (Digest $BaselineExecutablePath); fixtureVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($BaselineExecutablePath).ProductVersion; producer = 'genuine pre-locator 1.0.15'; deleteExitCode = $deleted.ExitCode; operationId = $deleted.Json.operationId; originalNative = $before }
    Assert-True ($deleted.ExitCode -eq 0 -and $deleted.Json.items[0].status -ceq 'deleted' -and !(Test-Path -LiteralPath $file)) 'Pre-locator producer did not recycle the aging fixture.'
    $op = Assert-Bin $deleted.Json.operationId $file; $id = File-Id $op.Payload
    $bin = Assert-NativeTree $op.Payload $before -WindowsOwnedSecurity
    $request = Join-Path (Join-Path $script:Recovery '.closed-records-v1') ($op.Id + '.request.json')
    $script:CaseObserved.hintAbsentBeforeAging = !(Test-Path -LiteralPath $request); $script:CaseObserved.binNative = $bin
    Assert-True (!(Test-Path -LiteralPath $request)) 'Aging fixture already has a bound retirement hint.'
    # 有効な期限fixtureとして、全receiptのmanifest hashとrestore→recycle hash連結も更新する。
    Set-RecycleFixtureAge $op 30
    $null = Assert-NativeTree $op.Payload $bin
    $script:CaseObserved.agedCreatedUtc = (Read-Json $op.ManifestPath).createdUtc
    $config = Read-Json $script:Config; $config.maxRecoveryBytes = 1; $config.retentionDays = 1; Save-Json $script:Config $config
    foreach ($argsList in @(@('maintain', '--dry-run'), @('maintain', '--apply'), @('purge', $op.Id, '--apply'))) {
        $result = Invoke-RecycleCli $argsList
        $op = Assert-Bin $op.Id $file
        $null = Assert-NativeTree $op.Payload $bin
        Assert-True ($result.ExitCode -eq 0 -and (File-Id $op.Payload) -ceq $id -and [IO.File]::Exists($op.ManifestPath)) "Retention/purge touched bin item: $($result.Stdout) $($result.Stderr)"
        if ($argsList[0] -eq 'purge') { Assert-True ($result.Json.items[0].status -eq 'retained') 'Purge did not explicitly retain bin item.' }
    }
    $other = New-File 'next-bin' 8192; $next = Delete-Entry $other
    $null = Assert-NativeTree $op.Payload $bin
    Assert-True ((File-Id $op.Payload) -ceq $id) 'Budget reclaimed previous bin item.'
    Restore-Entry $next $other; Restore-Entry $op $file
    $null = Assert-NativeTree $file $before
    $script:CaseObserved.restoredNative = Snapshot-NativeTree $file
    $script:CaseObserved.nativeIdentityBytesAclPreserved = $true
} 'BaselineExecutablePath'
Test-Case 'current-retention-budget-and-purge-exclude-windows-bin' {
    $file = New-File 'current-bin' 4096; $before = Snapshot-NativeTree $file
    $op = Delete-Entry $file; $bin = Assert-NativeTree $op.Payload $before -WindowsOwnedSecurity
    $script:CaseObserved = @{ producer = 'current executable, unchanged current timestamps'; operationId = $op.Id; originalNative = $before; binNative = $bin; operations = [Collections.Generic.List[object]]::new() }
    $config = Read-Json $script:Config; $config.maxRecoveryBytes = 1; $config.retentionDays = 1; Save-Json $script:Config $config
    foreach ($arguments in @(@('maintain','--dry-run'),@('maintain','--apply'),@('purge',$op.Id,'--apply'))) {
        $r = Invoke-RecycleCli $arguments; $script:CaseObserved.operations.Add(@{ arguments = $arguments; exitCode = $r.ExitCode; json = $r.Json; stderr = $r.Stderr })
        $op = Assert-Bin $op.Id $file; $null = Assert-NativeTree $op.Payload $bin
        Assert-True ($r.ExitCode -eq 0) "Current valid bin exclusion failed: $($r.Stdout) $($r.Stderr)"
        if ($arguments[0] -eq 'purge') { Assert-True ($r.Json.items[0].status -ceq 'retained') 'Current bin purge was not explicitly retained.' }
    }
    $other = New-File 'current-next-bin' 8192; $otherBefore = Snapshot-NativeTree $other; $next = Delete-Entry $other
    $null = Assert-NativeTree $op.Payload $bin
    $null = New-File 'current-bin' 17; $collision = Snapshot-NativeTree $file
    $conflict = Invoke-RecycleCli @('restore',$op.Id); $script:CaseObserved.conflict = @{ exitCode = $conflict.ExitCode; json = $conflict.Json; stderr = $conflict.Stderr }
    Assert-True ($conflict.Json.items[0].status -ceq 'conflict') 'Current exclusion fixture did not refuse overwriting an existing original.'
    $null = Assert-NativeTree $file $collision; $null = Assert-NativeTree $op.Payload $bin
    [IO.File]::Move($file,(Join-Path $script:Scope 'retained-current-collision'))
    Restore-Entry $next $other; Restore-Entry $op $file
    $null = Assert-NativeTree $other $otherBefore; $null = Assert-NativeTree $file $before
    $script:CaseObserved.restoredNative = Snapshot-NativeTree $file
    $script:CaseObserved.nativeIdentityBytesAclPreserved = $true
}
foreach ($tamper in @('owner', 'identity', 'pidl', 'physicalPath', 'unknownMember')) {
    Test-Case "tampered-record-$tamper-fails-closed" {
        $file = New-File 'original'; $hash = Digest $file; $op = Delete-Entry $file; $binId = File-Id $op.Payload
        $originalManifest = [IO.File]::ReadAllText($op.ManifestPath); $originalReceipt = [IO.File]::ReadAllText($op.ReceiptPath)
        try {
            $manifest = Read-Json $op.ManifestPath; $receipt = Read-Json $op.ReceiptPath
            switch ($tamper) {
                'owner' { $manifest.ownerSid = 'S-1-5-18' }
                'identity' { $receipt.identity.fileId = '00000000000000000000000000000000' }
                'pidl' { $receipt.pidl = '////' }
                'physicalPath' { $receipt.physicalPath = Join-Path $script:Scope 'unrelated' }
                'unknownMember' { $manifest.unknownMember = $true }
            }
            Save-Json $op.ManifestPath $manifest; $receipt.manifestSha256 = (Digest $op.ManifestPath).ToLowerInvariant(); Save-Json $op.ReceiptPath $receipt
            $result = Invoke-RecycleCli @('restore', $op.Id)
            Assert-True ($result.ExitCode -ne 0 -and !(Test-Path -LiteralPath $file) -and (File-Id $op.Payload) -ceq $binId -and (Digest $op.Payload) -ceq $hash) 'Tampered record changed source/bin item or was accepted.'
        } finally { [IO.File]::WriteAllText($op.ManifestPath, $originalManifest, $utf8); [IO.File]::WriteAllText($op.ReceiptPath, $originalReceipt, $utf8) }
        Restore-Entry $op $file
    }
}
Test-Case 'case-sensitive-directory-when-supported' {
    $tree = New-Directory (Join-Path $script:Scope 'case-sensitive')
    $enabled = Invoke-Child (Join-Path $env:SystemRoot 'System32\fsutil.exe') @('file', 'SetCaseSensitiveInfo', $tree, 'enable') -Raw -NativeConsoleEncoding
    if ($enabled.ExitCode -ne 0 -or ($enabled.Stdout + $enabled.Stderr) -match '(?i)0x00000005') {
        Assert-True ($enabled.Stderr -match '(?i)access|denied|support|privilege|拒否|サポート|権限' -or $enabled.Stdout -match '(?i)access|denied|support|privilege|拒否|サポート|権限') 'Unexpected fsutil failure; not treated as unavailable.'
        $script:CaseSkipped = $true; $script:CaseNote = 'Case-sensitive fixture unavailable: fsutil reports filesystem/privilege limitation; see process logs.'; return
    }
    $null = File-Id $tree
    Assert-True ([PrunletVolumeMoveVerificationIdentity]::IsCaseSensitive($tree)) 'fsutil succeeded but case-sensitive flag remains disabled.'
    [IO.File]::WriteAllText((Join-Path $tree 'a'), 'lower', $utf8); [IO.File]::WriteAllText((Join-Path $tree 'A'), 'UPPER', $utf8)
    Assert-True ([IO.File]::ReadAllText((Join-Path $tree 'a')) -ceq 'lower') 'Case-sensitive fixture did not retain distinct names.'
    $before = Snapshot-Tree $tree
    $result = Invoke-RecycleCli @('delete', '--recursive', '--', $tree)
    if ($result.ExitCode -ne 0) { Assert-Tree $tree $before; $script:CaseNote = 'Case-sensitive target unsupported; verified preservation on rejection.'; return }
    $op = Assert-Bin $result.Json.operationId $tree; Restore-Entry $op $tree; Assert-Tree $tree $before -RestoredRecycle
    Assert-True ([PrunletVolumeMoveVerificationIdentity]::IsCaseSensitive($tree)) 'Case-sensitive flag lost.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $tree 'a')) -ceq 'lower' -and [IO.File]::ReadAllText((Join-Path $tree 'A')) -ceq 'UPPER') 'Case-sensitive children collapsed.'
}
Test-Case 'reserved-device-child-names-preserved-or-rejected' {
    $tree = New-Directory (Join-Path $script:Scope 'reserved-children')
    $extended = [string]::Concat([char]92, [char]92, '?', [char]92); $first = $extended + (Join-Path $tree 'CON'); $second = $extended + (Join-Path $tree 'NUL.txt')
    [IO.File]::WriteAllText($first, 'reserved CON fixture', $utf8); [IO.File]::WriteAllText($second, 'reserved NUL fixture', $utf8)
    $firstId = File-Id $first; $secondId = File-Id $second
    $result = Invoke-RecycleCli @('delete', '--recursive', '--', $tree)
    if ($result.ExitCode -ne 0) {
        Assert-True ((File-Id $first) -ceq $firstId -and (File-Id $second) -ceq $secondId -and [IO.File]::ReadAllText($first) -ceq 'reserved CON fixture' -and [IO.File]::ReadAllText($second) -ceq 'reserved NUL fixture') 'Rejected device-child fixture changed.'
        $script:CaseNote = 'Reserved device child names unsupported; verified preservation on rejection.'; return
    }
    $op = Assert-Bin $result.Json.operationId $tree; Restore-Entry $op $tree
    Assert-True ((File-Id $first) -ceq $firstId -and (File-Id $second) -ceq $secondId -and [IO.File]::ReadAllText($first) -ceq 'reserved CON fixture' -and [IO.File]::ReadAllText($second) -ceq 'reserved NUL fixture') 'Device-child names or contents changed.'
}
Test-Case 'missing-recycle-receipt-preserves-bin-item' {
    $file = New-File 'incomplete'; $op = Delete-Entry $file; $binId = File-Id $op.Payload; $hash = Digest $op.Payload
    $retainedReceipt = Join-Path $script:CaseRoot 'retained-recycle-complete.json'
    [IO.File]::Move($op.ReceiptPath, $retainedReceipt, $false)
    try {
        $result = Invoke-RecycleCli @('restore', $op.Id)
        Assert-True ($result.ExitCode -ne 0 -and !(Test-Path -LiteralPath $file) -and (File-Id $op.Payload) -ceq $binId -and (Digest $op.Payload) -ceq $hash) 'Incomplete record consumed or modified bin item.'
    } finally { [IO.File]::Move($retainedReceipt, $op.ReceiptPath, $false) }
    Restore-Entry $op $file
}
Test-Case 'mcp-delete-conflict-restore-and-hook-guidance' {
    $file = New-File 'mcp target 日本語'; $before = Snapshot-Tree $file
    $event = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = "Remove-Item -LiteralPath '$file'"; cwd = $script:Scope } }
    $hook = Invoke-Child $ExecutablePath @('--config', $script:Config, 'hook') ($event | ConvertTo-Json -Depth 8 -Compress)
    Assert-True ($hook.ExitCode -eq 0 -and $hook.Json.hookSpecificOutput.permissionDecision -ceq 'deny' -and $hook.Stdout -match '(?i)prunlet' -and !$hook.Json.hookSpecificOutput.updatedInput) 'Hook did not refuse with CLI guidance.'
    Assert-Tree $file $before
    $process = Start-Child $ExecutablePath @('--config', $script:Config, 'mcp')
    $transcript = [Collections.Generic.List[object]]::new()
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        function Rpc([object]$Request) {
            $process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 16 -Compress)); $process.StandardInput.Flush()
            for ($index = 0; $index -lt 64; $index++) {
                $read = $process.StandardOutput.ReadLineAsync(); if (!$read.Wait(30000)) { throw 'MCP response timeout.' }
                $line = $read.GetAwaiter().GetResult(); if (!$line) { throw 'MCP closed output.' }
                $reply = $line | ConvertFrom-Json -Depth 80; $transcript.Add($reply)
                if ($reply.id -eq $Request.id) { return $reply }
            }
            throw 'Too many MCP notifications.'
        }
        $init = Rpc @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'recycle-e2e'; version = '1' } } }
        Assert-True ($null -ne $init.result) 'MCP initialize failed.'
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $process.StandardInput.Flush()
        $list = Rpc @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
        Assert-True (@($list.result.tools.name) -contains 'delete_files' -and @($list.result.tools.name) -contains 'restore_files') 'MCP delete/restore tool missing.'
        $deleted = Rpc @{ jsonrpc = '2.0'; id = 3; method = 'tools/call'; params = @{ name = 'delete_files'; arguments = @{ paths = @($file) } } }
        Assert-True (!$deleted.result.isError -and ![IO.File]::Exists($file)) 'MCP delete failed.'
        $op = Assert-Bin $deleted.result.structuredContent.operationId $file
        [IO.File]::WriteAllText($file, 'current', $utf8); $current = Snapshot-Tree $file; $binId = File-Id $op.Payload
        $conflict = Rpc @{ jsonrpc = '2.0'; id = 4; method = 'tools/call'; params = @{ name = 'restore_files'; arguments = @{ operationId = $op.Id } } }
        Assert-True ($conflict.result.structuredContent.items[0].status -eq 'conflict' -and (File-Id $op.Payload) -ceq $binId) 'MCP collision consumed bin item.'
        Assert-Tree $file $current
        [IO.File]::Move($file, (Join-Path $script:Scope 'retained-current'), $false)
        $restored = Rpc @{ jsonrpc = '2.0'; id = 5; method = 'tools/call'; params = @{ name = 'restore_files'; arguments = @{ operationId = $op.Id } } }
        Assert-True (!$restored.result.isError -and !(Test-Path -LiteralPath $op.Payload)) 'MCP restore failed.'
        Assert-Tree $file $before -RestoredRecycle
        $process.StandardInput.Close(); Assert-True ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'MCP process did not exit cleanly.'
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'mcp.stderr.txt'), $stderrTask.GetAwaiter().GetResult(), $utf8)
    } finally {
        Save-Json (Join-Path $script:CaseRoot 'mcp-transcript.json') @($transcript)
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose()
    }
}
foreach ($schema in @(1, 2, 3, 4)) {
    foreach ($action in @('restore', 'purge', 'maintain', 'conflict')) {
        $required = if ($schema -eq 4) { 'MoveExecutablePath' } else { 'LegacyExecutablePath' }
        Test-Case "legacy-schema-$schema-$action" {
            $file = New-File 'legacy\data.bin' 97; $hash = Digest $file
            $path = if ($schema -eq 1) { $file } else { Split-Path -Parent $file }
            if ($schema -eq 3) { [IO.File]::WriteAllText("${file}:legacy-stream", 'legacy ADS', $utf8) }
            $generator = if ($schema -eq 4) { $MoveExecutablePath } else { $LegacyExecutablePath }
            $configPath = Join-Path $script:CaseRoot 'legacy-config.json'; $config = Read-Json $script:Config
            $null = $config.Remove('capacityDefaultMigrationVersion')
            if ($schema -ne 4) { $null = $config.Remove('volumeRecoveryDirectories') }
            Save-Json $configPath $config
            $argsList = @('delete'); if ($schema -ne 1) { $argsList += '--recursive' }; $argsList += @('--', $path)
            $deleted = Invoke-RecycleCli $argsList $generator $configPath
            Assert-True ($deleted.ExitCode -eq 0 -and !(Test-Path -LiteralPath $path)) 'Legacy fixture generation failed.'
            $root = Join-Path $script:Recovery $deleted.Json.operationId
            $manifestPath = Join-Path $root ($(if ($schema -eq 4) { 'move-manifest.json' } else { 'manifest.json' }))
            $manifest = Read-Json $manifestPath
            Assert-True ($manifest.schema -eq $schema) 'Legacy generator did not produce requested schema.'
            $payload = if ($schema -eq 4) { Join-Path (Join-Path $manifest.entries[0].storeRoot $manifest.operationId) $manifest.entries[0].payloadName } else { $null }
            switch ($action) {
                'conflict' {
                    if ($schema -eq 1) { [IO.File]::WriteAllText($path, 'current', $utf8) }
                    else { $null = New-Directory $path; [IO.File]::WriteAllText((Join-Path $path 'data.bin'), 'current', $utf8) }
                    $current = Snapshot-Tree $path; $result = Invoke-RecycleCli @('restore', $deleted.Json.operationId)
                    Assert-True (@($result.Json.items | Where-Object status -EQ 'conflict').Count -gt 0) 'Legacy conflict not reported.'
                    Assert-Tree $path $current
                    if ($schema -eq 1) { [IO.File]::Move($path, (Join-Path $script:Scope 'retained-current'), $false) }
                    else { [IO.Directory]::Move($path, (Join-Path $script:Scope 'retained-current')) }
                    $result = Invoke-RecycleCli @('restore', $deleted.Json.operationId)
                    Assert-True ($result.ExitCode -eq 0 -and (Digest $file) -ceq $hash) 'Legacy recovery after conflict failed.'
                }
                'restore' {
                    $result = Invoke-RecycleCli @('restore', $deleted.Json.operationId)
                    Assert-True ($result.ExitCode -eq 0 -and (Digest $file) -ceq $hash) 'Legacy restore failed.'
                    if ($schema -eq 3) { Assert-True ([IO.File]::ReadAllText("${file}:legacy-stream") -ceq 'legacy ADS') 'Legacy ADS missing.' }
                }
                default {
                    if ($action -eq 'maintain') {
                        $manifest.createdUtc = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('O'); Save-Json $manifestPath $manifest
                        if ($schema -eq 4) {
                            foreach ($record in Get-ChildItem -LiteralPath $root -File -Filter '*.json') {
                                if ($record.Name -match '^(move|restore|purge)-[0-9]{4}-(intent|complete)[.]json$') {
                                    $receipt = Read-Json $record.FullName; $receipt.manifestSha256 = Digest $manifestPath; Save-Json $record.FullName $receipt
                                }
                            }
                        }
                        $result = Invoke-RecycleCli @('maintain', '--apply')
                    } else { $result = Invoke-RecycleCli @('purge', $deleted.Json.operationId, '--apply') }
                    Assert-True ($result.ExitCode -eq 0) "Legacy $action failed."
                    if ($schema -eq 4) { Assert-True (!(Test-Path -LiteralPath $payload)) "Legacy schema 4 $action retained payload." }
                    else { Assert-True (![IO.Directory]::Exists($root) -or @(Get-ChildItem -LiteralPath $root -File -Filter '*.bak').Count -eq 0) "Legacy $action retained copies." }
                    Assert-VerificationClosedRecord $script:Recovery $deleted.Json.operationId $schema
                }
            }
        } $required
    }
}
if ($Large) {
    Test-Case 'large-recursive-tree-collision-and-consumptive-roundtrip' {
        $tree = New-Directory (Join-Path $script:Scope 'large-tree')
        for ($index = 0; $index -lt $LargeFileCount; $index++) {
            $group = New-Directory (Join-Path $tree ('group-{0:D4}' -f [int][Math]::Floor($index / 256)))
            [IO.File]::WriteAllText((Join-Path $group ('{0:D7}.txt' -f $index)), "entry:$index", $utf8)
        }
        $snapshot = Snapshot-Tree $tree
        Assert-True (@($snapshot | Where-Object { !$_.isDirectory }).Count -eq $LargeFileCount) 'Large fixture file count differs.'
        $op = Delete-Entry $tree -Recursive
        Assert-True ($op.Manifest.entries.Count -eq 1 -and (File-Id $op.Payload) -ceq $snapshot[0].id) 'Large delete expanded entries or changed root identity.'
        Assert-Tree $op.Payload $snapshot -MovedRoot
        $null = New-Directory $tree; [IO.File]::WriteAllText((Join-Path $tree 'current.txt'), 'preserve current', $utf8)
        $current = Snapshot-Tree $tree
        $conflict = Invoke-RecycleCli @('restore', $op.Id)
        Assert-True ($conflict.Json.items[0].status -eq 'conflict') 'Large restore did not report destination conflict.'
        Assert-Tree $tree $current; Assert-Tree $op.Payload $snapshot -MovedRoot
        [IO.Directory]::Move($tree, (Join-Path $script:Scope 'retained-large-current'))
        Restore-Entry $op $tree; Assert-Tree $tree $snapshot -RestoredRecycle
        $again = Invoke-RecycleCli @('restore', $op.Id)
        Assert-VerificationRepeatedRestore $again $op.Id 1; Assert-Tree $tree $snapshot -RestoredRecycle
    }
}
if (!$results.Count) { $results.Add(@{ name = 'case-filter-matched-no-cases'; passed = $false; skipped = $false; error = 'CaseFilter matched no cases (large cases require -Large).' }) }
$passed = @($results | Where-Object { $_.passed -eq $true }).Count
$skipped = @($results | Where-Object skipped).Count
$failed = $results.Count - $passed - $skipped
Save-Json $ReportPath @{
    sparseHelper = @{ path = (Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs'); sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'recordless-e2e/SparseFixture.cs')).Hash }
    schema = 1; timestampUtc = [DateTimeOffset]::UtcNow.ToString('O'); executablePath = $ExecutablePath
    legacyExecutablePath = $LegacyExecutablePath; moveExecutablePath = $MoveExecutablePath; recycleLegacyExecutablePath = $RecycleLegacyExecutablePath; baselineExecutablePath = $BaselineExecutablePath
    large = [bool]$Large; largeFileCount = $LargeFileCount
    passed = $passed; failed = $failed; skipped = $skipped; excludedCount = $script:ExcludedCount
    results = @($results); retainedDirectory = $outputRoot
    unverified = @('External Explorer restore and bin-empty lifecycle: no global bin-empty or direct bin payload deletion is performed.', 'Native recycling interruptions and other transfer/crash boundaries beyond the stage-arrival/ready cases require separate process-boundary verification.')
}
[ordered]@{ passed = $passed; failed = $failed; skipped = $skipped; excludedCount = $script:ExcludedCount; reportPath = $ReportPath } | ConvertTo-Json
if ($failed) { exit 1 }
exit 0
