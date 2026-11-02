[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Alias('BaselineMoveExecutablePath')][string]$MoveExecutablePath,
    [string]$AssemblyPath,
    [string]$LegacyRegistryExecutablePath,
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
foreach ($path in @($ExecutablePath, $MoveExecutablePath, $AssemblyPath, $LegacyRegistryExecutablePath, $OutputDirectory, $ReportPath) | Where-Object { $_ }) {
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
    Assert-VerificationDestination $path @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Local registry verification requires D: output.' }
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
    $config = Read-Json $script:Config; $config.volumeRecoveryDirectories = @{ 'D:\' = (Join-Path $script:CaseRoot 'volume-store') }; Save-Json $script:Config $config
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
$nativeSource = @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
public static class PrunletRegistryE2E {
 static RegistryHive Hive;
 static IntPtr Root;
 static string FixturePrefix;
 static string LinkPrefix;
 static string ClassesPrefix;
 public static void Configure(bool machine,string fixturePrefix) {
  string allowed=machine?"SYSTEM\\PrunletE2E\\":"Software\\PrunletE2E\\";
  string suffix=fixturePrefix.StartsWith(allowed,StringComparison.OrdinalIgnoreCase)?fixturePrefix.Substring(allowed.Length):"";
  if(suffix.Length!=32||!Guid.TryParseExact(suffix,"N",out _))throw new ArgumentException("Unsafe fixture namespace.");
  Hive=machine?RegistryHive.LocalMachine:RegistryHive.CurrentUser;
  Root=new IntPtr(machine?unchecked((int)0x80000002):unchecked((int)0x80000001)); FixturePrefix=fixturePrefix;
  LinkPrefix=fixturePrefix+"-link-probes";
  ClassesPrefix="Software\\Classes\\PrunletE2E_"+suffix;
 }
 static void CheckFixture(string relative) {
  bool main=FixturePrefix!=null&&(relative.Equals(FixturePrefix,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(FixturePrefix+"\\",StringComparison.OrdinalIgnoreCase));
  bool links=LinkPrefix!=null&&(relative.Equals(LinkPrefix,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(LinkPrefix+"\\",StringComparison.OrdinalIgnoreCase));
  if(!main&&!links&&!IsClasses(relative))throw new ArgumentException("Registry fixture escaped its unique run root.");
 }
 static bool IsClasses(string relative) => ClassesPrefix!=null&&(relative.Equals(ClassesPrefix,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(ClassesPrefix+"\\",StringComparison.OrdinalIgnoreCase));
 static void CheckPermissionFixture(string relative) {
  CheckFixture(relative);
  bool link=relative.StartsWith(LinkPrefix+"\\",StringComparison.OrdinalIgnoreCase);
  bool protectedCase=relative.StartsWith(FixturePrefix+"\\backup-restore-protected-cli-mcp-key-value-roundtrip\\",StringComparison.OrdinalIgnoreCase);
  if(!link&&!protectedCase)throw new ArgumentException("Permission probe escaped its dedicated GUID subtree.");
 }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegSetValueExW(SafeRegistryHandle k,string n,int r,uint t,byte[] b,int l);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryValueExW(SafeRegistryHandle k,string n,IntPtr r,out uint t,byte[] b,ref uint l);
 [DllImport("advapi32.dll")] static extern int RegGetKeySecurity(SafeRegistryHandle k,uint i,byte[] b,ref uint l);
 [DllImport("advapi32.dll")] static extern int RegSetKeySecurity(SafeRegistryHandle k,uint information,byte[] descriptor);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr root,string path,uint options,uint access,out SafeRegistryHandle key);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegCreateKeyExW(IntPtr root,string path,int reserved,string keyClass,uint options,uint access,IntPtr security,out SafeRegistryHandle key,out uint disposition);
 [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length,MaximumLength; public IntPtr Buffer; }
 [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes { public int Length; public IntPtr RootDirectory,ObjectName; public uint Attributes; public IntPtr SecurityDescriptor,SecurityQualityOfService; }
 [DllImport("ntdll.dll")] static extern int NtOpenKeyEx(out SafeRegistryHandle key,uint access,ref ObjectAttributes attributes,uint options);
 [DllImport("ntdll.dll")] static extern uint RtlNtStatusToDosError(int status);
 [DllImport("ntdll.dll")] static extern int NtQueryKey(SafeRegistryHandle key,int information,byte[] buffer,uint length,out uint resultLength);
 [DllImport("ntdll.dll")] static extern int NtRenameKey(SafeRegistryHandle key,ref UnicodeString name);
 public static int RenameVolatileLink(string relative,RegistryKey key,string newName) {
  CheckFixture(relative);if(!relative.StartsWith(LinkPrefix+"\\",StringComparison.OrdinalIgnoreCase)||newName.Length==0||newName.Length>255||newName.IndexOfAny(new[]{'\\','/','\0'})>=0)throw new ArgumentException("Rename probe escaped volatile run root.");
  IntPtr text=Marshal.StringToHGlobalUni(newName);
  try {var name=new UnicodeString{Length=checked((ushort)(newName.Length*2)),MaximumLength=checked((ushort)((newName.Length+1)*2)),Buffer=text};int status=NtRenameKey(key.Handle,ref name);return status<0?(int)RtlNtStatusToDosError(status):0;}
  finally {Marshal.FreeHGlobal(text);}
 }
 public static string ClassesAliasState() {
  string source="\\Registry\\User\\"+System.Security.Principal.WindowsIdentity.GetCurrent().User.Value+"\\Software\\Classes";
  IntPtr text=Marshal.StringToHGlobalUni(source),unicode=Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
  try {
   Marshal.StructureToPtr(new UnicodeString{Length=checked((ushort)(source.Length*2)),MaximumLength=checked((ushort)((source.Length+1)*2)),Buffer=text},unicode,false);
   var attributes=new ObjectAttributes{Length=Marshal.SizeOf<ObjectAttributes>(),ObjectName=unicode,Attributes=0x140};
   SafeRegistryHandle handle;int status=NtOpenKeyEx(out handle,0x01020119,ref attributes,8);
   if(status<0){handle.Dispose();throw new Win32Exception((int)RtlNtStatusToDosError(status));}
   using(var alias=RegistryKey.FromHandle(handle,RegistryView.Registry64)) {
    uint size=0;int error=RegGetKeySecurity(alias.Handle,0x10000,null,ref size);if(error!=122&&error!=0)throw new Win32Exception(error);
    byte[] acl=new byte[size];error=RegGetKeySecurity(alias.Handle,0x10000,acl,ref size);if(error!=0)throw new Win32Exception(error);
    byte[] basic=new byte[4096];uint length;status=NtQueryKey(alias.Handle,0,basic,(uint)basic.Length,out length);if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));
    return Value(alias,"SymbolicLinkValue")+"|security:"+Convert.ToBase64String(acl)+"|lastwrite:"+BitConverter.ToInt64(basic,0);
   }
  } finally { Marshal.FreeHGlobal(unicode);Marshal.FreeHGlobal(text); }
 }
 [DllImport("KtmW32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateTransaction(IntPtr security,IntPtr unitOfWork,uint options,uint isolationLevel,uint isolationFlags,uint timeout,string description);
 [DllImport("KtmW32.dll",SetLastError=true)] static extern bool RollbackTransaction(SafeFileHandle transaction);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyTransactedW(IntPtr root,string path,uint options,uint access,out SafeRegistryHandle key,SafeFileHandle transaction,IntPtr extendedParameter);
 public sealed class KtmPreflightResult {
  public int View;
  public string Parent;
  public string Stage;
  public int NativeError;
  public int RollbackError;
  public bool Available { get { return NativeError==0&&RollbackError==0&&Stage=="complete"; } }
 }
 public static KtmPreflightResult PreflightKtm(int view) {
  if(FixturePrefix==null)throw new InvalidOperationException("Configure the fixture hive before preflight.");
  var result=new KtmPreflightResult { View=view,Parent=Hive==RegistryHive.LocalMachine?"SYSTEM":"Software",Stage="CreateTransaction" };
  using(var transaction=CreateTransaction(IntPtr.Zero,IntPtr.Zero,0,0,0,30000,"Prunlet E2E read-only KTM preflight")) {
   if(transaction.IsInvalid) { result.NativeError=Marshal.GetLastWin32Error();return result; }
   try {
    result.Stage="RegOpenKeyTransactedW(KEY_READ)";
    SafeRegistryHandle key;
    result.NativeError=RegOpenKeyTransactedW(Root,result.Parent,0,(uint)(0x20019|(view==32?0x200:0x100)),out key,transaction,IntPtr.Zero);
    if(key!=null)key.Dispose();
   } finally {
    if(!RollbackTransaction(transaction))result.RollbackError=Marshal.GetLastWin32Error();
   }
  }
  if(result.NativeError==0)result.Stage=result.RollbackError==0?"complete":"RollbackTransaction";
  return result;
 }
 [DllImport("advapi32.dll",EntryPoint="RegOpenKeyExW",CharSet=CharSet.Unicode)] static extern int ReopenSecurity(SafeRegistryHandle root,string path,uint options,uint access,out SafeRegistryHandle key);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint a,out IntPtr t);
 [StructLayout(LayoutKind.Sequential)] struct Luid { public uint LowPart; public int HighPart; }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string s,string n,out Luid l);
 [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
 [StructLayout(LayoutKind.Sequential)] struct PrivilegeSet { public uint Count; public uint Control; public Luid Luid; public uint Attributes; }
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr t,bool d,ref Privileges p,uint l,IntPtr b,IntPtr r);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool PrivilegeCheck(IntPtr token,ref PrivilegeSet privileges,out bool enabled);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static bool EnableSecurity() {
  IntPtr token; if(!OpenProcessToken(GetCurrentProcess(),0x28,out token)) return false;
  try { Luid id; if(!LookupPrivilegeValue(null,"SeSecurityPrivilege",out id))return false;
   var p=new Privileges{Count=1,Luid=id,Attributes=2};
   if(!AdjustTokenPrivileges(token,false,ref p,0,IntPtr.Zero,IntPtr.Zero)||Marshal.GetLastWin32Error()!=0)return false;
   var required=new PrivilegeSet{Count=1,Control=1,Luid=id,Attributes=2};
   bool enabled;return PrivilegeCheck(token,ref required,out enabled)&&enabled;
  } finally { CloseHandle(token); }
 }
 public static RegistryKey Open(string relative,int view,bool security=false) {
  CheckFixture(relative);
  SafeRegistryHandle h; int e=RegOpenKeyExW(IsClasses(relative)?new IntPtr(unchecked((int)0x80000001)):Root,relative,0,(uint)(0x20019|(view==32?0x200:0x100)|(security?0x1000000:0)),out h);
  if(e==2)return null; if(e!=0)throw new Win32Exception(e); return RegistryKey.FromHandle(h,view==32?RegistryView.Registry32:RegistryView.Registry64);
 }
 public static RegistryKey Create(string relative,int view) {
  CheckFixture(relative);
  using(var root=RegistryKey.OpenBaseKey(IsClasses(relative)?RegistryHive.CurrentUser:Hive,view==32?RegistryView.Registry32:RegistryView.Registry64)) return root.CreateSubKey(relative,true);
 }
 public static RegistryKey CreateVolatile(string relative,bool link=false,string keyClass=null) {
  CheckFixture(relative);
  if(!(relative.Equals(LinkPrefix,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(LinkPrefix+"\\",StringComparison.OrdinalIgnoreCase)))throw new ArgumentException("Volatile probes require their dedicated run root.");
  SafeRegistryHandle handle;uint disposition;
  int e=RegCreateKeyExW(Root,relative,0,keyClass,link?3u:1u,0xF013F,IntPtr.Zero,out handle,out disposition);
  if(e!=0)throw new Win32Exception(e);
  if(disposition!=1){handle.Dispose();throw new Exception("Volatile probe already existed.");}
  return RegistryKey.FromHandle(handle,RegistryView.Registry64);
 }
 public static RegistryKey CreateWithClass(string relative,string keyClass) {
  CheckPermissionFixture(relative);
  if(!relative.StartsWith(FixturePrefix+"\\backup-restore-protected-cli-mcp-key-value-roundtrip\\",StringComparison.OrdinalIgnoreCase))throw new ArgumentException("Class fixture escaped the protected nonvolatile GUID subtree.");
  SafeRegistryHandle handle;uint disposition;
  int error=RegCreateKeyExW(Root,relative,0,keyClass,0,0xF013F,IntPtr.Zero,out handle,out disposition);
  if(error!=0){handle.Dispose();throw new Win32Exception(error);}
  if(disposition!=1){handle.Dispose();throw new InvalidOperationException("Class fixture already exists.");}
  return RegistryKey.FromHandle(handle,RegistryView.Registry64);
 }
 public static void CreateLink(string relative,string target) {
  CheckFixture(target);
  if(!target.StartsWith(LinkPrefix+"\\",StringComparison.OrdinalIgnoreCase))throw new ArgumentException("Link target escaped volatile probe root.");
  string native=Hive==RegistryHive.LocalMachine?"\\Registry\\Machine\\":"\\Registry\\User\\"+System.Security.Principal.WindowsIdentity.GetCurrent().User.Value+"\\";
  using(var key=CreateVolatile(relative,true))Set(key,"SymbolicLinkValue",6,System.Text.Encoding.Unicode.GetBytes(native+target));
 }
 public static void Set(RegistryKey k,string name,uint type,byte[] data) { int e=RegSetValueExW(k.Handle,name,0,type,data,data.Length);if(e!=0)throw new Win32Exception(e); }
 public static int TrySet(RegistryKey k,string name,uint type,byte[] data) => RegSetValueExW(k.Handle,name,0,type,data,data.Length);
 public static long KeyLastWrite(RegistryKey key) {
  byte[] basic=new byte[4096];uint length;int status=NtQueryKey(key.Handle,0,basic,(uint)basic.Length,out length);
  if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));return BitConverter.ToInt64(basic,0);
 }
 public static void DenyFixtureSetValue(string relative,RegistryKey key) {
  CheckPermissionFixture(relative);
  string sid=System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
  var descriptor=new System.Security.AccessControl.RawSecurityDescriptor("D:P(D;;0x2;;;"+sid+")(A;;KA;;;"+sid+")(A;;KA;;;SY)");
  byte[] bytes=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(bytes,0);
  int error=RegSetKeySecurity(key.Handle,4,bytes);if(error!=0)throw new Win32Exception(error);
 }
 public static byte[] FixtureDacl(string relative,RegistryKey key) {
  CheckPermissionFixture(relative);uint size=0;int error=RegGetKeySecurity(key.Handle,4,null,ref size);if(error!=122&&error!=0)throw new Win32Exception(error);
  byte[] bytes=new byte[size];error=RegGetKeySecurity(key.Handle,4,bytes,ref size);if(error!=0)throw new Win32Exception(error);return bytes;
 }
 public static void RestoreFixtureDacl(string relative,RegistryKey key,byte[] bytes) {
  CheckPermissionFixture(relative);
  var descriptor=new System.Security.AccessControl.RawSecurityDescriptor(bytes,0);
  uint information=4u|((descriptor.ControlFlags&System.Security.AccessControl.ControlFlags.DiscretionaryAclProtected)!=0?0x80000000u:0x20000000u);
  int error=RegSetKeySecurity(key.Handle,information,bytes);if(error!=0)throw new Win32Exception(error);
 }
 public static string[] ClassesBackingSnapshot(string relative,int view) {
  CheckFixture(relative);if(!IsClasses(relative))throw new ArgumentException("Not a Classes fixture.");
  var rows=new List<string>();WalkBacking(relative,"",view,rows);rows.Sort(StringComparer.Ordinal);return rows.ToArray();
 }
 static void WalkBacking(string relative,string label,int view,List<string> rows) {
  CheckFixture(relative);
  string path=System.Security.Principal.WindowsIdentity.GetCurrent().User.Value+"_Classes\\"+relative.Substring("Software\\Classes\\".Length);
  SafeRegistryHandle handle;int error=RegOpenKeyExW(new IntPtr(unchecked((int)0x80000003)),path,0,(uint)(0x01020019|(view==32?0x200:0x100)),out handle);
  if(error!=0)throw new Win32Exception(error);
  using(var key=RegistryKey.FromHandle(handle,view==32?RegistryView.Registry32:RegistryView.Registry64)) {
   rows.Add("K:"+label+":"+Security(key));foreach(var name in key.GetValueNames())rows.Add("V:"+label+":"+Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(name))+":"+Value(key,name));
   foreach(var child in key.GetSubKeyNames())WalkBacking(relative+"\\"+child,label+"\\"+child,view,rows);
  }
 }
 public static void SetLowIntegrityFixture(string relative,int view) {
  CheckFixture(relative);
  var descriptor=new System.Security.AccessControl.RawSecurityDescriptor("S:(ML;;NW;;;LW)");
  var bytes=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(bytes,0);
  SafeRegistryHandle handle;
  int e=RegOpenKeyExW(Root,relative,0,(uint)(0x80000|(view==32?0x200:0x100)),out handle);
  if(e!=0)throw new Win32Exception(e);
  using(handle) { e=RegSetKeySecurity(handle,0x10,bytes);if(e!=0)throw new Win32Exception(e); }
 }
 public static string Value(RegistryKey k,string name) {
  uint t,l=0;int e=RegQueryValueExW(k.Handle,name,IntPtr.Zero,out t,null,ref l);if(e==2)return null;if(e!=0)throw new Win32Exception(e);
  byte[] b=new byte[l];e=RegQueryValueExW(k.Handle,name,IntPtr.Zero,out t,b,ref l);if(e!=0)throw new Win32Exception(e);return t+":"+Convert.ToBase64String(b);
 }
 public static string Security(RegistryKey k) {
  SafeRegistryHandle securityHandle;
  int e=ReopenSecurity(k.Handle,"",0,0x01020000,out securityHandle);if(e!=0)throw new Win32Exception(e);
  using(securityHandle) {
   uint l=0;e=RegGetKeySecurity(securityHandle,0x10000,null,ref l);if(e!=122&&e!=0)throw new Win32Exception(e);
   byte[] b=new byte[l];e=RegGetKeySecurity(securityHandle,0x10000,b,ref l);if(e!=0)throw new Win32Exception(e);return Convert.ToBase64String(b);
  }
 }
 public static string[] Snapshot(string relative,int view) {
  var rows=new List<string>(); Walk(relative,"",view,rows); rows.Sort(StringComparer.Ordinal);return rows.ToArray();
 }
 static void Walk(string relative,string label,int view,List<string> rows) {
  using(var k=Open(relative,view,true)) { if(k==null)throw new Exception("Snapshot key missing: "+relative);
   rows.Add("K:"+label+":"+Security(k)); foreach(var name in k.GetValueNames())rows.Add("V:"+label+":"+Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(name))+":"+Value(k,name));
   foreach(var child in k.GetSubKeyNames())Walk(relative+"\\"+child,label+"\\"+child,view,rows);
  }
 }
}
'@
$compilerTemp = Join-Path $OutputDirectory 'compiler-temp'; $null = [IO.Directory]::CreateDirectory($compilerTemp)
$previousTemp = $env:TEMP; $previousTmp = $env:TMP
try { $env:TEMP = $compilerTemp; $env:TMP = $compilerTemp; Add-Type -TypeDefinition $nativeSource }
finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
$securityPrivilege = [PrunletRegistryE2E]::EnableSecurity()
[PrunletRegistryE2E]::Configure($machineFixture,$runRelative)
$preflight = @()
foreach ($view in @(64,32)) {
    try { $preflight += [PrunletRegistryE2E]::PreflightKtm($view) }
    catch { $preflight += @{ View=$view; Available=$false; Stage='native preflight exception'; error=$_.Exception.Message; hresult=$_.Exception.HResult } }
}
if (@($preflight | Where-Object { !$_.Available }).Count) {
    # 読み取り専用の既存親接続に失敗した環境では、fixtureキーを一つも作らない。
    $presence = @(); $remaining = $null
    foreach ($view in @(64,32)) {
        try {
            $existing = [PrunletRegistryE2E]::Open($runRelative,$view)
            $exists = $null -ne $existing
            if ($existing) { $existing.Dispose(); $remaining = $runPath }
            $presence += @{ view=$view; exists=$exists; observed=$true }
        } catch { $presence += @{ view=$view; exists=$null; observed=$false; error=$_.Exception.Message }; $remaining=$runPath }
    }
    $reason = 'Read-only KTM preflight unavailable; no registry fixture creation was attempted. Registry behavior remains unverified in this process context.'
    Save-Json $ReportPath @{
        schema=1; timestampUtc=[DateTimeOffset]::UtcNow.ToString('O'); executablePath=$ExecutablePath; moveExecutablePath=$MoveExecutablePath
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
    $existing = [PrunletRegistryE2E]::Open($runRelative,$view)
    if ($existing) { $existing.Dispose(); throw 'Unique registry fixture already exists.' }
}
$fixture = [PrunletRegistryE2E]::Create($runRelative,64); $fixture.Dispose(); $createdFixture = $true
function Exists([string]$Relative = $script:Relative, [int]$View = 64) { $k = [PrunletRegistryE2E]::Open($Relative,$View); if ($k) { $k.Dispose(); return $true }; return $false }
function Fixture([switch]$Tree, [int]$View = 64) {
    Assert-True (!(Exists $script:Relative $View)) 'Case fixture already exists.'
    $k = [PrunletRegistryE2E]::Create($script:Relative,$View)
    try {
        foreach ($entry in @(
            @('',1,[Text.Encoding]::Unicode.GetBytes("default`0")), @('日本語😀',1,[Text.Encoding]::Unicode.GetBytes("文字`0")),
            @('none',0,[byte[]]@(0,255,1)), @('expand',2,[Text.Encoding]::Unicode.GetBytes("%TEMP%`0")),
            @('binary',3,[byte[]]@(0,1,128,255)), @('dword',4,[byte[]]@(0x78,0x56,0x34,0x12)),
            @('multi',7,[Text.Encoding]::Unicode.GetBytes("one`0日本語`0`0")), @('qword',11,[BitConverter]::GetBytes([uint64]0x123456789abcdef)),
            @('empty-binary',3,[byte[]]@()), @('empty-string',1,[byte[]]@())
        )) { [PrunletRegistryE2E]::Set($k,[string]$entry[0],[uint32]$entry[1],[byte[]]$entry[2]) }
        foreach ($name in $pathValueNames) { [PrunletRegistryE2E]::Set($k,$name,1,[Text.Encoding]::Unicode.GetBytes("fixture:$name`0")) }
    } finally { $k.Dispose() }
    if ($Tree) { $child = [PrunletRegistryE2E]::Create($script:Relative+'\子\empty',$View); $child.Dispose() }
}
function Snapshot([int]$View = 64) { [PrunletRegistryE2E]::Snapshot($script:Relative,$View) -join "`n" }
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
        [PrunletRegistryE2E]::SetLowIntegrityFixture($relative,64)
        $key = [PrunletRegistryE2E]::Open($relative,64,$true)
        try {
            $raw = [Convert]::FromBase64String([PrunletRegistryE2E]::Security($key))
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
    $conflict = [PrunletRegistryE2E]::Create($script:Relative,64); $conflict.Dispose(); $before = Snapshot
    Assert-Rejected @('restore',$op.Id)
    Assert-True ((Snapshot) -ceq $before -and (Digest $op.Payload) -ceq $hash) 'Conflicting key or backup changed.'
}
foreach ($name in @('binary','日本語😀','') + $pathValueNames) {
    $valueName = $name
    $label = if (!$name) { 'default' } elseif ($name -eq 'binary') { 'named' } elseif ($name -eq '日本語😀') { 'unicode' } else { 'path-' + [array]::IndexOf($pathValueNames,$name) }
    Case "value-$label-roundtrip-preserves-parent-siblings-security" {
        Fixture; $before = Snapshot
        $op = Delete-Registry @('--value-name',$valueName)
        $k = [PrunletRegistryE2E]::Open($script:Relative,64,$true)
        try { Assert-True ($null -eq [PrunletRegistryE2E]::Value($k,$valueName)) 'Selected value remains.' } finally { $k.Dispose() }
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
    $k = [PrunletRegistryE2E]::Create($script:Relative,64)
    try { [PrunletRegistryE2E]::Set($k,'',3,[byte[]]@(99)) } finally { $k.Dispose() }
    $before = Snapshot; Assert-Rejected @('restore',$op.Id)
    Assert-True ((Snapshot) -ceq $before -and (Digest $op.Payload) -ceq $hash) 'Value conflict changed source or snapshot.'
}
Case 'identical-existing-value-still-refuses-restore' {
    Fixture; $name = $pathValueNames[0]; $op = Delete-Registry @('--value-name',$name); $hash = Digest $op.Payload
    $k = [PrunletRegistryE2E]::Create($script:Relative,64)
    try { [PrunletRegistryE2E]::Set($k,$name,1,[Text.Encoding]::Unicode.GetBytes("fixture:$name`0")) } finally { $k.Dispose() }
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
    $parent = [PrunletRegistryE2E]::Create($parentRelative,64); $parent.Dispose()
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
    $aliasBefore = [PrunletRegistryE2E]::ClassesAliasState()
    foreach ($view in @(32,64)) {
        $script:Relative = $classesRelative+'\cli'+$view; $script:Path = 'HKEY_CURRENT_USER\'+$script:Relative
        Fixture -Tree -View $view; $before = Snapshot $view
        Assert-True (([PrunletRegistryE2E]::ClassesBackingSnapshot($script:Relative,$view) -join "`n") -ceq $before) 'Classes alias and direct SID_Classes backing disagree.'
        $sourceBefore = [PrunletRegistryE2E]::ClassesAliasState(); $recordsBefore = Recovery-State
        $r = Invoke-RegistryCli @('registry-delete','--view',"$view",'--value-name',$pathValueNames[0],'--dry-run','--',$script:Path)
        Assert-True ($r.ExitCode -eq 0 -and (Snapshot $view) -ceq $before -and [PrunletRegistryE2E]::ClassesAliasState() -ceq $sourceBefore -and (Recovery-State) -ceq $recordsBefore) 'Classes dry-run changed alias bytes, complete ACL, last-write time, fixture, or metadata.'
        foreach ($name in $pathValueNames) {
            $op = Delete-Registry @('--value-name',$name) $view
            $prefix = 'V::'+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($name))+':'
            $expected = (($before -split "`n" | Where-Object { !$_.StartsWith($prefix,[StringComparison]::Ordinal) }) -join "`n")
            Assert-True ((Snapshot $view) -ceq $expected) 'Classes value delete changed sibling values, child keys, or complete parent ACL.'
            $null = Restore $op
            Assert-True ((Snapshot $view) -ceq $before -and ([PrunletRegistryE2E]::ClassesBackingSnapshot($script:Relative,$view) -join "`n") -ceq $before) 'Classes value restore changed literal names, types, raw bytes, siblings, or security.'
        }
        $name = $pathValueNames[0]; $op = Delete-Registry @('--value-name',$name) $view; $hash = Digest $op.Payload
        $k = [PrunletRegistryE2E]::Create($script:Relative,$view)
        try { [PrunletRegistryE2E]::Set($k,$name,1,[Text.Encoding]::Unicode.GetBytes("fixture:$name`0")) } finally { $k.Dispose() }
        Assert-Rejected @('restore',$op.Id)
        Assert-True ((Snapshot $view) -ceq $before -and (Digest $op.Payload) -ceq $hash) 'Classes value restore conflict changed source or snapshot.'
    }
    foreach ($view in @(32,64)) {
        $script:Relative = $classesRelative; $script:Path = 'HKEY_CURRENT_USER\'+$classesRelative; $before = Snapshot $view
        $op = Delete-Registry @('--recursive') $view
        Assert-True (!(Exists $script:Relative $view)) 'Direct Classes child key remains after CLI delete.'
        $null = Restore $op
        Assert-True ((Snapshot $view) -ceq $before -and ([PrunletRegistryE2E]::ClassesBackingSnapshot($script:Relative,$view) -join "`n") -ceq $before) 'Direct Classes child restore changed raw tree or complete security.'
    }
    Assert-True ((Alias-Content ([PrunletRegistryE2E]::ClassesAliasState())) -ceq (Alias-Content $aliasBefore)) 'Classes operation changed real ancestor link bytes or complete ACL.'
}
Case 'volatile-registry-links-and-link-like-value-refused' {
    # リンク拒否後は削除APIを付け替えない。専用volatile rootだけをログオフ/再起動まで保持する。
    Assert-True (!(Exists $linkRelative)) 'Unique volatile link probe already exists.'
    $root = [PrunletRegistryE2E]::CreateVolatile($linkRelative); $root.Dispose(); $script:createdLinkFixture = $true
    $targetRelative = $linkRelative + '\target'
    $target = [PrunletRegistryE2E]::CreateVolatile($targetRelative)
    try { [PrunletRegistryE2E]::Set($target,'sentinel',3,[byte[]]@(42,0,255)) } finally { $target.Dispose() }
    $child = [PrunletRegistryE2E]::CreateVolatile($targetRelative+'\child'); $child.Dispose()
    $before = [PrunletRegistryE2E]::Snapshot($targetRelative,64) -join "`n"
    [PrunletRegistryE2E]::CreateLink($linkRelative+'\link',$targetRelative)
    Assert-True (([PrunletRegistryE2E]::Snapshot($linkRelative+'\link',64) -join "`n") -ceq $before) 'Probe link does not resolve to its fixture target.'
    foreach ($suffix in @('\link','\link\child')) {
        $r = Invoke-RegistryCli @('registry-delete','--view','64','--recursive','--dry-run','--',($fixtureHive+'\'+$linkRelative+$suffix))
        Assert-True ($r.ExitCode -ne 0 -and ($r.Stdout+$r.Stderr) -match 'Registry link or link-like key') 'Actual link was not rejected by the link guard.'
        Assert-True (([PrunletRegistryE2E]::Snapshot($targetRelative,64) -join "`n") -ceq $before) 'Rejected link probe changed target.'
    }
    $ordinaryRelative = $linkRelative+'\ordinary'
    $ordinary = [PrunletRegistryE2E]::CreateVolatile($ordinaryRelative)
    $nativePrefix = if ($machineFixture) { '\Registry\Machine\' } else { '\Registry\User\'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'\' }
    try {
        [PrunletRegistryE2E]::Set($ordinary,'SymbolicLinkValue',6,[Text.Encoding]::Unicode.GetBytes($nativePrefix+$targetRelative))
        [PrunletRegistryE2E]::Set($ordinary,'ordinary-sentinel',3,[byte[]]@(17,18))
    } finally { $ordinary.Dispose() }
    $ordinaryBefore = [PrunletRegistryE2E]::Snapshot($ordinaryRelative,64) -join "`n"
    $r = Invoke-RegistryCli @('registry-delete','--view','64','--recursive','--dry-run','--',($fixtureHive+'\'+$ordinaryRelative))
    Assert-True ($r.ExitCode -ne 0 -and ($r.Stdout+$r.Stderr) -match 'Registry link or link-like key') 'Ordinary REG_LINK value was not rejected by the link guard.'
    Assert-True (([PrunletRegistryE2E]::Snapshot($ordinaryRelative,64) -join "`n") -ceq $ordinaryBefore) 'Rejected REG_LINK value probe changed ordinary key.'
}
if ($AssemblyPath) {
    Case 'core-classes-alias-proof-permission-and-staged-commit-conflict' {
        Assert-True ([IO.File]::Exists($AssemblyPath)) 'Candidate AssemblyPath missing.'
        if (!(Exists $linkRelative)) { $root = [PrunletRegistryE2E]::CreateVolatile($linkRelative); $root.Dispose(); $script:createdLinkFixture = $true }
        $assembly = [Reflection.Assembly]::LoadFrom($AssemblyPath)
        $native = $assembly.GetType('Prunlet.Core.NativeRegistry',$true); $transactionType = $assembly.GetType('Prunlet.Core.NativeRegistry+Transaction',$true)
        $static = [Reflection.BindingFlags]'Static,NonPublic'; $instance = [Reflection.BindingFlags]'Instance,NonPublic'
        function Core-Target([string]$Path,[string]$Name) {
            $request = [Activator]::CreateInstance($assembly.GetType('Prunlet.Core.RegistryDeleteRequest',$true)); $request.Path=$Path; $request.View='64'; $request.ValueName=$Name
            $native.GetMethod('Target',$static).Invoke($null,[object[]]@($request))
        }
        $targetRelatives = @(($linkRelative+'\guard-target-a'),($linkRelative+'\guard-target-b')); $targets = @(); $targetSnapshots = @()
        foreach ($relative in $targetRelatives) {
            $targetKey = [PrunletRegistryE2E]::CreateVolatile($relative)
            [PrunletRegistryE2E]::Set($targetKey,'sentinel',3,[byte[]]@(42,0,255)); $targets += $targetKey
            $targetSnapshots += [PrunletRegistryE2E]::Snapshot($relative,64) -join "`n"
        }
        $nativePrefix = if ($machineFixture) { '\Registry\Machine\' } else { '\Registry\User\'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'\' }
        $destination = $nativePrefix+$targetRelatives[0]; $original = [Text.Encoding]::Unicode.GetBytes($destination); $changed = [Text.Encoding]::Unicode.GetBytes($nativePrefix+$targetRelatives[1])
        $aliasRelative=$linkRelative+'\guard-real'; $alias=[PrunletRegistryE2E]::CreateVolatile($aliasRelative,$true)
        $plain=[PrunletRegistryE2E]::CreateVolatile($linkRelative+'\guard-plain'); $aliasRaw=$null; $denied=$null; $deniedRaw=$null; $savedDacl=$null; $parent=$null; $transaction=$null
        try {
            [PrunletRegistryE2E]::Set($alias,'SymbolicLinkValue',6,$original); [PrunletRegistryE2E]::Set($plain,'SymbolicLinkValue',6,$original)
            $parent=[PrunletRegistryE2E]::Open($linkRelative,64); $proof=$native.GetMethod('VerifyClassesAlias',$static)
            $aliasRaw=$native.GetMethod('OpenNative',$static).Invoke($null,[object[]]@($null,$parent.Handle,'guard-real',[uint32]0x20119,'Cannot open isolated readonly alias probe',$false))
            $rejected=$false
            try { $null=$proof.Invoke($null,[object[]]@($plain.Handle,$parent.Handle,'guard-plain',$destination,[uint32]0x20119,$original)) }
            catch { $rejected=$_.Exception.ToString() -match 'differs from the explicitly resolved native path' }
            Assert-True $rejected 'Ordinary matching REG_LINK metadata was accepted as a real alias.'
            $null=$proof.Invoke($null,[object[]]@($aliasRaw,$parent.Handle,'guard-real',$destination,[uint32]0x20119,$original))
            $aliasTarget=Core-Target ($fixtureHive+'\'+$aliasRelative) $null
            $value=$native.GetMethod('ReadValue',$static).Invoke($null,[object[]]@($aliasRaw,'SymbolicLinkValue'))
            $guard=$native.GetMethod('GuardClassesAlias',$static)
            $before=[PrunletRegistryE2E]::Value($alias,'SymbolicLinkValue')+'|'+[PrunletRegistryE2E]::KeyLastWrite($alias)
            $transaction=[Activator]::CreateInstance($transactionType,$true)
            $null=$guard.Invoke($null,[object[]]@($transaction,$aliasTarget,$aliasRaw,$value,$false)); $transaction.Dispose(); $transaction=$null
            Assert-True (([PrunletRegistryE2E]::Value($alias,'SymbolicLinkValue')+'|'+[PrunletRegistryE2E]::KeyLastWrite($alias)) -ceq $before) 'Permission-only alias guard wrote bytes or changed last-write time.'
            $deniedRelative=$linkRelative+'\guard-denied'; $denied=[PrunletRegistryE2E]::CreateVolatile($deniedRelative,$true)
            [PrunletRegistryE2E]::Set($denied,'SymbolicLinkValue',6,$original)
            $deniedRaw=$native.GetMethod('OpenNative',$static).Invoke($null,[object[]]@($null,$parent.Handle,'guard-denied',[uint32]0x20119,'Cannot open isolated readonly permission probe',$false))
            $savedDacl=[PrunletRegistryE2E]::FixtureDacl($deniedRelative,$denied); [PrunletRegistryE2E]::DenyFixtureSetValue($deniedRelative,$denied)
            $deniedBefore=[PrunletRegistryE2E]::Value($denied,'SymbolicLinkValue')+'|'+[PrunletRegistryE2E]::KeyLastWrite($denied)
            $transaction=[Activator]::CreateInstance($transactionType,$true); $deniedTarget=Core-Target ($fixtureHive+'\'+$deniedRelative) $null; $deniedError=0
            try { $null=$guard.Invoke($null,[object[]]@($transaction,$deniedTarget,$deniedRaw,$value,$true)) }
            catch { $cause=$_.Exception; while ($cause.InnerException) { $cause=$cause.InnerException }; if ($cause -is [ComponentModel.Win32Exception]) { $deniedError=$cause.NativeErrorCode } }
            $transaction.Dispose(); $transaction=$null
            Assert-True ($deniedError -eq 5 -and ([PrunletRegistryE2E]::Value($denied,'SymbolicLinkValue')+'|'+[PrunletRegistryE2E]::KeyLastWrite($denied)) -ceq $deniedBefore) 'Denied SetValue permission was not rejected before alias staging.'
            [PrunletRegistryE2E]::RestoreFixtureDacl($deniedRelative,$denied,$savedDacl); $savedDacl=$null
            $transaction=[Activator]::CreateInstance($transactionType,$true)
            $null=$guard.Invoke($null,[object[]]@($transaction,$aliasTarget,$aliasRaw,$value,$true))
            $target=Core-Target ($fixtureHive+'\'+$targetRelatives[0]) 'sentinel'
            $bound=$native.GetMethod('BindTransaction',$static).Invoke($null,[object[]]@($transaction,$target,$targets[0].Handle,[uint32]2))
            $staged=[Activator]::CreateInstance($assembly.GetType('Prunlet.Core.RegistryValueSnapshot',$true),$true); $staged.Name='sentinel'; $staged.Type=[uint32]3; $staged.Data=[byte[]]@(99,88,77)
            $null=$native.GetMethod('SetRaw',$static).Invoke($null,[object[]]@($bound,$staged))
            $stagedRead=$native.GetMethod('ReadValue',$static).Invoke($null,[object[]]@($bound,'sentinel'))
            Assert-True ([Convert]::ToBase64String($stagedRead.Data) -ceq [Convert]::ToBase64String($staged.Data)) 'Target sentinel mutation was not actually staged.'
            $null=$transactionType.GetMethod('VerifyPinnedNames',$instance).Invoke($transaction,@())
            # 本番の最終確認後の窓を検証するため、外部writer後は再確認を挟まず同じKTM commitを呼ぶ。
            $writeError=[PrunletRegistryE2E]::TrySet($alias,'SymbolicLinkValue',6,$changed)
            $handle=$transactionType.GetProperty('Handle',$instance).GetValue($transaction)
            $committed=$native.GetMethod('CommitTransaction',$static).Invoke($null,[object[]]@($handle)); $commitError=if($committed){0}else{[Runtime.InteropServices.Marshal]::GetLastWin32Error()}
            $transaction.Dispose(); $transaction=$null
            $writerPreserved=[PrunletRegistryE2E]::Value($alias,'SymbolicLinkValue') -ceq ('6:'+[Convert]::ToBase64String($changed)); $targetsPreserved=$true
            for($i=0;$i -lt $targetRelatives.Count;$i++){ $targetsPreserved=$targetsPreserved -and (([PrunletRegistryE2E]::Snapshot($targetRelatives[$i],64) -join "`n") -ceq $targetSnapshots[$i]) }
            Save-Json (Join-Path $script:CaseRoot 'classes-guard-evidence.json') @{ assemblyPath=$AssemblyPath; assemblySha256=(Digest $AssemblyPath); ordinaryMatchingBytesRejected=$rejected; deniedSetValueError=$deniedError; externalWriteError=$writeError; committed=$committed; commitError=$commitError; writerBytesPreserved=$writerPreserved; targetMutationRolledBack=$targetsPreserved; scope='Production helper and actual KTM; dedicated volatile real link only; staged target write; external link update after final Verify; raw commit without second check' }
            Assert-True ($writeError -eq 0 -and !$committed -and $writerPreserved -and $targetsPreserved) 'Staged alias guard did not roll back target mutation and preserve the accepted external writer after the final check.'
            $renameRelative=$linkRelative+'\guard-rename'; $renameAlias=[PrunletRegistryE2E]::CreateVolatile($renameRelative,$true); $renameRaw=$null; $replacement=$null
            try {
                [PrunletRegistryE2E]::Set($renameAlias,'SymbolicLinkValue',6,$original)
                $renameRaw=$native.GetMethod('OpenNative',$static).Invoke($null,[object[]]@($null,$parent.Handle,'guard-rename',[uint32]0x20119,'Cannot open isolated rename probe',$false))
                $renameTarget=Core-Target ($fixtureHive+'\'+$renameRelative) $null
                $transaction=[Activator]::CreateInstance($transactionType,$true)
                $null=$guard.Invoke($null,[object[]]@($transaction,$renameTarget,$renameRaw,$value,$true))
                $bound=$native.GetMethod('BindTransaction',$static).Invoke($null,[object[]]@($transaction,$target,$targets[0].Handle,[uint32]2))
                $null=$native.GetMethod('SetRaw',$static).Invoke($null,[object[]]@($bound,$staged))
                $null=$transactionType.GetMethod('VerifyPinnedNames',$instance).Invoke($transaction,@())
                $renameError=[PrunletRegistryE2E]::RenameVolatileLink($renameRelative,$renameAlias,'guard-renamed')
                $renameCommitted=$false; $renameCommitError=$null; $replacementPreserved=$true
                if($renameError -eq 0){
                    $replacement=[PrunletRegistryE2E]::CreateVolatile($renameRelative,$true)
                    [PrunletRegistryE2E]::Set($replacement,'SymbolicLinkValue',6,$changed)
                    $handle=$transactionType.GetProperty('Handle',$instance).GetValue($transaction)
                    $renameCommitted=$native.GetMethod('CommitTransaction',$static).Invoke($null,[object[]]@($handle)); $renameCommitError=if($renameCommitted){0}else{[Runtime.InteropServices.Marshal]::GetLastWin32Error()}
                }
                $transaction.Dispose(); $transaction=$null
                if($replacement){$replacementPreserved=[PrunletRegistryE2E]::Value($replacement,'SymbolicLinkValue') -ceq ('6:'+[Convert]::ToBase64String($changed))}
                $renamedSourcePreserved=[PrunletRegistryE2E]::Value($renameAlias,'SymbolicLinkValue') -ceq ('6:'+[Convert]::ToBase64String($original)); $renameTargetsPreserved=$true
                for($i=0;$i -lt $targetRelatives.Count;$i++){$renameTargetsPreserved=$renameTargetsPreserved -and (([PrunletRegistryE2E]::Snapshot($targetRelatives[$i],64) -join "`n") -ceq $targetSnapshots[$i])}
                Save-Json (Join-Path $script:CaseRoot 'classes-rename-evidence.json') @{ assemblyPath=$AssemblyPath; assemblySha256=(Digest $AssemblyPath); renameError=$renameError; replacementCreated=($null -ne $replacement); committed=$renameCommitted; commitError=$renameCommitError; renamedSourceBytesPreserved=$renamedSourcePreserved; replacementBytesPreserved=$replacementPreserved; targetMutationRolledBack=$renameTargetsPreserved; scope='Production guard + staged target; NtRenameKey after final check; real replacement when accepted; raw KTM commit without second check; isolated volatile fixture only' }
                Assert-True ((($renameError -eq 6800) -or ($renameError -eq 0 -and !$renameCommitted)) -and $renamedSourcePreserved -and $replacementPreserved -and $renameTargetsPreserved) 'Alias rename/replacement was not blocked or rolled back after the final check.'
            } finally {if($transaction){$transaction.Dispose();$transaction=$null};if($replacement){$replacement.Dispose()};if($renameRaw){$renameRaw.Dispose()};$renameAlias.Dispose()}
        } finally {
            if($transaction){$transaction.Dispose()}; if($denied -and $savedDacl){[PrunletRegistryE2E]::RestoreFixtureDacl($deniedRelative,$denied,$savedDacl)}; if($deniedRaw){$deniedRaw.Dispose()}; if($aliasRaw){$aliasRaw.Dispose()}; if($parent){$parent.Dispose()}; if($denied){$denied.Dispose()}; $plain.Dispose(); $alias.Dispose(); foreach($key in $targets){$key.Dispose()}
        }
    }
    Case 'core-incomplete-links-cannot-be-used-as-ordinary-keys' {
        if (!(Exists $linkRelative)) {
            $root = [PrunletRegistryE2E]::CreateVolatile($linkRelative); $root.Dispose(); $script:createdLinkFixture = $true
        }
        $assembly = [Reflection.Assembly]::LoadFrom($AssemblyPath)
        $native = $assembly.GetType('Prunlet.Core.NativeRegistry',$true)
        $flags = [Reflection.BindingFlags]'Static,NonPublic'
        $ordinaryOpen = $native.GetMethod('OpenOrdinaryKey',$flags)
        $rawOpen = $native.GetMethod('OpenNative',$flags)
        $keyName = $native.GetMethod('NtKeyName',$flags)
        $parent = [PrunletRegistryE2E]::Open($linkRelative,64)
        $targetRelative = $linkRelative+'\incomplete-target'
        $target = [PrunletRegistryE2E]::CreateVolatile($targetRelative)
        $child = [PrunletRegistryE2E]::CreateVolatile($targetRelative+'\child')
        $plain = [PrunletRegistryE2E]::CreateVolatile($linkRelative+'\incomplete-ordinary')
        $link = [PrunletRegistryE2E]::CreateVolatile($linkRelative+'\incomplete-source',$true)
        try {
            [PrunletRegistryE2E]::Set($target,'sentinel',3,[byte[]]@(42,0,255))
            [PrunletRegistryE2E]::Set($child,'sentinel',3,[byte[]]@(17,18,19))
            [PrunletRegistryE2E]::Set($plain,'SymbolicLinkValue',1,[Text.Encoding]::Unicode.GetBytes("ordinary text`0"))
            $before = [PrunletRegistryE2E]::Snapshot($targetRelative,64) -join "`n"
            $plainBefore = [PrunletRegistryE2E]::Snapshot($linkRelative+'\incomplete-ordinary',64) -join "`n"
            $secure = $ordinaryOpen.Invoke($null,[object[]]@($null,$plain.Handle,$parent.Handle,'incomplete-ordinary',[uint32]0x20119))
            try { Assert-True ($keyName.Invoke($null,[object[]]@($secure)) -ceq $keyName.Invoke($null,[object[]]@($plain.Handle))) 'Ordinary key proof returned another key.' }
            finally { $secure.Dispose() }
            $states = @()
            foreach ($state in @('missing','restored')) {
                if ($state -eq 'missing') {
                    $refused = Invoke-RegistryCli @('registry-delete','--view','64','--value-name','sentinel','--dry-run','--',($fixtureHive+'\'+$linkRelative+'\incomplete-source'))
                    Assert-True ($refused.ExitCode -ne 0 -and $refused.Json.items[0].status -ceq 'failed') 'An incomplete actual link was reported as an absent target.'
                }
                if ($state -eq 'restored') {
                    $destination = $keyName.Invoke($null,[object[]]@($target.Handle))
                    [PrunletRegistryE2E]::Set($link,'SymbolicLinkValue',6,[Text.Encoding]::Unicode.GetBytes($destination))
                }
                $failure = $null
                try {
                    $unexpected = $ordinaryOpen.Invoke($null,[object[]]@($null,$link.Handle,$parent.Handle,'incomplete-source',[uint32]0x20119))
                    $unexpected.Dispose()
                } catch { $failure = $_.Exception.ToString() }
                Assert-True ($null -ne $failure) "Actual link with $state metadata passed ordinary-key validation."
                $states += @{state=$state;refused=$true;error=$failure}
            }
            # 分類後にREG_LINK値が復活しても、保持したraw linkを親にした再解析を許さない。
            $childFailure = $null; $childNativeError = $null
            try {
                $unexpected = $rawOpen.Invoke($null,[object[]]@($null,$link.Handle,'child',[uint32]0x20119,'Incomplete-link regression probe',$false))
                $unexpected.Dispose()
            } catch {
                $childFailure = $_.Exception.ToString(); $cause = $_.Exception
                while ($cause) { if ($cause -is [ComponentModel.Win32Exception]) { $childNativeError = $cause.NativeErrorCode; break }; $cause = $cause.InnerException }
            }
            Assert-True ($null -ne $childFailure -and $childNativeError -eq 4395) 'A held raw link was not rejected as a reparse point.'
            Assert-True (([PrunletRegistryE2E]::Snapshot($targetRelative,64) -join "`n") -ceq $before -and ([PrunletRegistryE2E]::Snapshot($linkRelative+'\incomplete-ordinary',64) -join "`n") -ceq $plainBefore) 'Ordinary-key validation changed fixture values or full security.'
            Save-Json (Join-Path $script:CaseRoot 'incomplete-link-evidence.json') @{assemblyPath=$AssemblyPath;assemblySha256=(Digest $AssemblyPath);ordinaryKeyAccepted=$true;states=$states;incompleteCliStatus=$refused.Json.items[0].status;restoredRawParentChildRefused=$true;childNativeError=$childNativeError;childError=$childFailure;targetAndOrdinaryPreserved=$true;scope='Production secure ordinary-open and raw-parent no-reparse checks; isolated volatile link; no real Classes metadata removal'}
        } finally { $link.Dispose(); $plain.Dispose(); $child.Dispose(); $target.Dispose(); $parent.Dispose() }
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
    if (!('Prunlet.RecordlessE2E.FixtureNative' -as [type])) {
        Add-Type -Path @('NativeShellFixture.cs','FixtureNative.cs','OwnedBinLocator.cs' | ForEach-Object { Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_ }) -CompilerOptions '/unsafe'
    }
    $fileScope = $script:CaseRoot
    if ($FixtureRoot) {
        $script:fileFixtureRun = New-VerificationFixtureRun -FixtureRoot $FixtureRoot -ForbiddenRoots @($repoRoot,$codexRoot) -NamePrefix 'registry-files'
        $fileScope = $script:fileFixtureRun.directory
    }
    $file = Join-Path $fileScope 'mixed-file.bin'; [IO.File]::WriteAllBytes($file,[byte[]](0..255)*16)
    $fileBefore = [Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($file)
    $priorPidls = [string[]]@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($fileBefore[0].Id) | ForEach-Object Pidl)
    Fixture; $registryBefore = Snapshot
    $deleted = Invoke-RegistryCli @('delete','--',$file)
    Assert-True ($deleted.ExitCode -eq 0 -and !$deleted.Json.PSObject.Properties['operationId'] -and $deleted.Json.items[0].status -ceq 'recycled' -and ![IO.File]::Exists($file)) 'Current file deletion must recycle without an operation record.'
    $bin = [Prunlet.RecordlessE2E.OwnedBinLocator]::FindNew($fileBefore[0].Id,$priorPidls)
    $binBefore = [Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($bin.PhysicalPath)
    $registryOp = Delete-Registry; $registryHash = Digest $registryOp.Payload; $registryBytes = [IO.FileInfo]::new($registryOp.Payload).Length
    foreach ($mode in @('--dry-run','--apply')) {
        $config = Read-Json $script:Config; $config.maxRecoveryBytes = $registryBytes; Save-Json $script:Config $config
        $inspection = Invoke-RegistryCli @('maintain',$mode)
        Assert-True ($inspection.ExitCode -eq 0 -and $inspection.Json.capacityKnown -and $inspection.Json.retainedBytesBefore -eq $registryBytes -and $inspection.Json.retainedBytesAfter -eq $registryBytes) 'Registry capacity included Windows-managed file bytes.'
        Assert-True ((Digest $registryOp.Payload) -ceq $registryHash -and ![IO.File]::Exists($file)) 'Registry-only retention changed either source or snapshot.'
        $binAfter = [Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($bin.PhysicalPath)
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
    $compilerTemp = Join-Path $script:CaseRoot 'temp'; $oldTemp=$env:TEMP; $oldTmp=$env:TMP
    try { $env:TEMP=$compilerTemp; $env:TMP=$compilerTemp; Add-Type -Path (Join-Path $PSScriptRoot 'ProtectedRegistryAccess.Native.cs') }
    finally { $env:TEMP=$oldTemp; $env:TMP=$oldTmp }
    $privileges = [ProtectedRegistryAccessProbe+PrivilegeLease]::new()
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
            $parentRelative=$script:Relative+'\'+$protocol; $parent=[PrunletRegistryE2E]::Create($parentRelative,64)
            $relative=$parentRelative+'\restricted'; $path=$fixtureHive+'\'+$relative
            $target=[PrunletRegistryE2E]::CreateWithClass($relative,('protected '+$protocol+' 日本語 class'))
            $child=[PrunletRegistryE2E]::CreateWithClass($relative+'\child','protected child class')
            $backup=$null; $originalDacl=$null
            try {
                [PrunletRegistryE2E]::Set($parent,'sentinel',3,[byte[]]@(99,0,254))
                [PrunletRegistryE2E]::Set($target,'sentinel',3,[byte[]]@(0,1,128,255))
                [PrunletRegistryE2E]::Set($target,'',3,[byte[]]@(7,0,255))
                [PrunletRegistryE2E]::Set($child,'sentinel',11,[BitConverter]::GetBytes([uint64]0x123456789abcdef))
                $originalDacl=[PrunletRegistryE2E]::FixtureDacl($relative,$target)
                $childSecurity=[Convert]::ToBase64String([ProtectedRegistryAccessProbe]::Security(($childSecurityOpen=[ProtectedRegistryAccessProbe]::Open($null,$target.Handle,'child',4,$false,[uint32]0x010F013F)).Handle))
                $childSecurityOpen.Dispose()
                $childValue=[PrunletRegistryE2E]::Value($child,'sentinel'); $child.Dispose(); $child=$null
                [ProtectedRegistryAccessProbe]::Restrict($target.Handle)
                $backup=[ProtectedRegistryAccessProbe]::Open($null,$parent.Handle,'restricted',4,$false,[uint32]0x010F013F)
                Assert-True ($backup.Error -eq 0) 'Protected observation open failed.'
                $security=[Convert]::ToBase64String([ProtectedRegistryAccessProbe]::Security($backup.Handle))
                $value=[ProtectedRegistryAccessProbe]::Value($backup.Handle,''); $class=[ProtectedRegistryAccessProbe]::Class($backup.Handle)
                if ($protocol -eq 'mcp') {
                    $privileges.Dispose(); Assert-True $privileges.Restored 'Observer privileges were not restored before MCP launch.'
                    $p=Start-Child @('mcp'); $stderrTask=$p.StandardError.ReadToEndAsync(); $script:protectedRpcId=100
                    $processBefore=[ProtectedRegistryAccessProbe]::ProcessPrivileges([uint32]$p.Id)
                    $privileges=[ProtectedRegistryAccessProbe+PrivilegeLease]::new()
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
                $records=Recovery-State; $lastWrite=[PrunletRegistryE2E]::KeyLastWrite($target)
                $normalKey=Protected-Call 'delete_registry' @{path=$path;view='64';recursive=$true;dryRun=$true;accessMode='normal'}
                Assert-True (!$normalKey.ok -and (Recovery-State) -ceq $records -and [PrunletRegistryE2E]::KeyLastWrite($target) -eq $lastWrite -and [Convert]::ToBase64String([ProtectedRegistryAccessProbe]::Security($backup.Handle)) -ceq $security) 'Normal key access bypassed the deny ACL or changed the source.'
                $dry=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';dryRun=$true;accessMode='backupRestore'}
                Assert-True ($dry.ok -and $dry.data.items[0].status -eq 'would_delete' -and (Recovery-State) -ceq $records -and [PrunletRegistryE2E]::KeyLastWrite($target) -eq $lastWrite) 'Protected dry-run failed or changed data/records/timestamp.'
                $deleted=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';accessMode='backupRestore'}
                Assert-True ($deleted.ok -and $deleted.data.operationId) 'Protected value deletion failed.'
                $id=$deleted.data.operationId; $payload=Join-Path (Join-Path (Join-Path $script:Recovery '.registry-records-v1') $id) 'registry-snapshot.json'; $hash=Digest $payload
                $normal=Protected-Call 'restore_registry' @{operationId=$id;accessMode='normal'}
                Assert-True (!$normal.ok -and (Digest $payload) -ceq $hash) 'Restore silently remembered the deletion access mode.'
                [PrunletRegistryE2E]::Set($target,'',3,[byte[]]@())
                $conflict=Protected-Call 'restore_registry' @{operationId=$id;accessMode='backupRestore'}
                Assert-True (!$conflict.ok -and (Digest $payload) -ceq $hash -and [ProtectedRegistryAccessProbe]::Value($backup.Handle,'') -ceq '3:') 'Protected restore overwrote an existing empty default value.'
                $null=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';accessMode='backupRestore'}
                $restored=Protected-Call 'restore_registry' @{operationId=$id;accessMode='backupRestore'}
                Assert-True ($restored.ok -and [ProtectedRegistryAccessProbe]::Value($backup.Handle,'') -ceq $value -and [Convert]::ToBase64String([ProtectedRegistryAccessProbe]::Security($backup.Handle)) -ceq $security) 'Protected value roundtrip changed raw bytes or parent ACL.'
                $normal=Protected-Call 'delete_registry' @{path=$path;view='64';valueName='';dryRun=$true;accessMode='normal'}
                Assert-True (!$normal.ok) 'A later normal MCP request inherited backup/restore access.'
                $backup.Dispose();$backup=$null;$target.Dispose();$target=$null
                $deleted=Protected-Call 'delete_registry' @{path=$path;view='64';recursive=$true;accessMode='backupRestore'}
                Assert-True ($deleted.ok -and $deleted.data.operationId) 'Protected key deletion failed.'
                $keyPayload=Read-Json (Join-Path (Join-Path (Join-Path $script:Recovery '.registry-records-v1') $deleted.data.operationId) 'registry-snapshot.json')
                Assert-True ($keyPayload.schema -eq 5 -and $keyPayload.keys[0].class -ceq $class -and !$keyPayload.ContainsKey('accessMode')) 'Protected snapshot schema/class contract changed.'
                $restored=Protected-Call 'restore_registry' @{operationId=$deleted.data.operationId;accessMode='backupRestore'}
                Assert-True $restored.ok 'Protected key restoration failed.'
                $backup=[ProtectedRegistryAccessProbe]::Open($null,$parent.Handle,'restricted',4,$false,[uint32]0x010F013F)
                Assert-True ($backup.Error -eq 0 -and [ProtectedRegistryAccessProbe]::Class($backup.Handle) -ceq $class -and [ProtectedRegistryAccessProbe]::Value($backup.Handle,'') -ceq $value -and [Convert]::ToBase64String([ProtectedRegistryAccessProbe]::Security($backup.Handle)) -ceq $security) 'Protected key class/raw/full ACL roundtrip failed.'
                $childOpen=[ProtectedRegistryAccessProbe]::Open($null,$backup.Handle,'child',4,$false,[uint32]0x010F013F)
                try { Assert-True ($childOpen.Error -eq 0 -and [ProtectedRegistryAccessProbe]::Value($childOpen.Handle,'sentinel') -ceq $childValue -and [Convert]::ToBase64String([ProtectedRegistryAccessProbe]::Security($childOpen.Handle)) -ceq $childSecurity -and [PrunletRegistryE2E]::Value($parent,'sentinel') -ceq '3:YwD+') 'Child/sibling raw or complete security changed.' }
                finally { $childOpen.Dispose() }
                if ($protocol -eq 'mcp') {
                    $processAfter=[ProtectedRegistryAccessProbe]::ProcessPrivileges([uint32]$p.Id)
                    foreach ($name in $processBefore.Keys) { Assert-True ($processBefore[$name] -ceq $processAfter[$name]) "MCP process-token privilege changed: $name" }
                    Save-Json (Join-Path $script:CaseRoot 'protected-mcp-token-attributes.json') @{before=$processBefore;after=$processAfter}
                }
            } finally {
                if ($p) { $p.StandardInput.Close(); if (!$p.WaitForExit(15000)) {$p.Kill($true)}; $p.Dispose(); $p=$null }
                if ($backup) {
                    $restoredKey=[Microsoft.Win32.RegistryKey]::FromHandle($backup.Handle)
                    try { if ($originalDacl) {[PrunletRegistryE2E]::RestoreFixtureDacl($relative,$restoredKey,$originalDacl)} } finally {$restoredKey.Dispose();$backup.Dispose()}
                } elseif ($target -and $originalDacl) { [PrunletRegistryE2E]::RestoreFixtureDacl($relative,$target,$originalDacl) }
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
        $k = [PrunletRegistryE2E]::Create($script:Relative,64)
        try { [PrunletRegistryE2E]::Set($k,$name,1,[Text.Encoding]::Unicode.GetBytes("fixture:$name`0")) } finally { $k.Dispose() }
        $conflictBefore = Snapshot
        $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$valueId } } }
        Assert-True ($reply.result.isError -and (Snapshot) -ceq $conflictBefore -and (Digest $payload) -ceq $hash) 'MCP value conflict changed source or snapshot.'
        $aliasBefore = [PrunletRegistryE2E]::ClassesAliasState()
        foreach ($view in @(32,64)) {
            $script:Relative = $classesRelative+'\mcp'+$view; $script:Path = 'HKEY_CURRENT_USER\'+$script:Relative
            Fixture -Tree -View $view; $before = Snapshot $view
            $sourceBefore = [PrunletRegistryE2E]::ClassesAliasState(); $recordsBefore = Recovery-State
            $dry = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; valueName=$pathValueNames[0]; dryRun=$true } } }
            Assert-True (!$dry.result.isError -and (Snapshot $view) -ceq $before -and [PrunletRegistryE2E]::ClassesAliasState() -ceq $sourceBefore -and (Recovery-State) -ceq $recordsBefore) 'MCP Classes dry-run changed ancestor timestamp, raw bytes, full ACL, target, or metadata.'
            foreach ($name in $pathValueNames) {
                $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; valueName=$name } } }
                Assert-True (!$deleted.result.isError -and $deleted.result.structuredContent.items[0].kind -ceq 'registry-value') 'MCP Classes value delete failed.'
                $valueId = $deleted.result.structuredContent.operationId
                $prefix = 'V::'+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($name))+':'
                $expected = (($before -split "`n" | Where-Object { !$_.StartsWith($prefix,[StringComparison]::Ordinal) }) -join "`n")
                Assert-True ((Snapshot $view) -ceq $expected) 'MCP Classes value delete changed siblings or full security.'
                $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$valueId } } }
                Assert-True (!$reply.result.isError -and (Snapshot $view) -ceq $before -and ([PrunletRegistryE2E]::ClassesBackingSnapshot($script:Relative,$view) -join "`n") -ceq $before) 'MCP Classes restore changed path-shaped names, raw bytes, siblings, or full ACL.'
            }
            $name = $pathValueNames[0]
            $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; valueName=$name } } }
            Assert-True (!$deleted.result.isError) 'MCP Classes conflict setup failed.'
            $valueId = $deleted.result.structuredContent.operationId
            $payload = Join-Path (Join-Path (Join-Path $script:Recovery '.registry-records-v1') $valueId) 'registry-snapshot.json'; $hash = Digest $payload
            $k = [PrunletRegistryE2E]::Create($script:Relative,$view)
            try { [PrunletRegistryE2E]::Set($k,$name,1,[Text.Encoding]::Unicode.GetBytes("fixture:$name`0")) } finally { $k.Dispose() }
            $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$valueId } } }
            Assert-True ($reply.result.isError -and (Snapshot $view) -ceq $before -and (Digest $payload) -ceq $hash) 'MCP Classes conflict changed original or snapshot.'
            $script:Relative = $classesRelative; $script:Path = 'HKEY_CURRENT_USER\'+$classesRelative; $beforeRoot = Snapshot $view
            $deleted = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='delete_registry'; arguments=@{ path=$script:Path; view="$view"; recursive=$true } } }
            Assert-True (!$deleted.result.isError -and !(Exists $script:Relative $view)) 'MCP direct Classes child delete failed.'
            $reply = Rpc @{ jsonrpc='2.0'; id=$rpcId++; method='tools/call'; params=@{ name='restore_registry'; arguments=@{ operationId=$deleted.result.structuredContent.operationId } } }
            Assert-True (!$reply.result.isError -and (Snapshot $view) -ceq $beforeRoot) 'MCP direct Classes child key restore changed tree or full ACL.'
        }
        Assert-True ((Alias-Content ([PrunletRegistryE2E]::ClassesAliasState())) -ceq (Alias-Content $aliasBefore)) 'MCP Classes operations changed ancestor raw link bytes or full ACL.'
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
# 清掃も今回exeを一度だけ利用する。拒否は別APIへ付け替えず残存パスを報告する。
$cleanup = @{ attempted = $false; remainingRegistryPath = $runPath; remainingClassesPath = 'HKEY_CURRENT_USER\'+$classesRelative; retainedVolatileLinkPath = $(if ($createdLinkFixture) { $fixtureHive+'\'+$linkRelative } else { $null }); operations = @() }
if ($createdFixture) {
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
$passed = @($results | Where-Object passed).Count; $skipped = @($results | Where-Object skipped).Count; $failed = $results.Count - $passed - $skipped
$unverified = @('Actual OS Classes alias destination swaps are not performed; the production guard/commit race and source rename/replacement are probed only on dedicated volatile links. Exact privilege-deficient token behavior requires separate native probes.','KTM crash timing requires separate integration probes.','Distinct WOW64 view isolation requires separate views; shared views do not verify isolation. See view-observation.json.')
if (!@($results | Where-Object { $_.name -eq 'volatile-registry-links-and-link-like-value-refused' -and $_.passed }).Count) { $unverified += 'Actual target/ancestor registry link and ordinary REG_LINK value rejection was not verified because its case was excluded or failed.' }
if (!@($results | Where-Object { $_.name -eq 'core-classes-alias-proof-permission-and-staged-commit-conflict' -and $_.passed }).Count) { $unverified += 'Production Classes alias guard, SetValue denial, dry-run no-write, and staged-target rollback after the final check were not verified; supply AssemblyPath and include its case.' }
if (!@($results | Where-Object { $_.name -eq 'classes-alias-cli-values-and-direct-child-keys-both-views' -and $_.passed }).Count -or !@($results | Where-Object { $_.name -eq 'mcp-schema-errors-roundtrip-and-iserror' -and $_.passed }).Count) { $unverified += 'Classes descendant CLI/MCP values and direct-child keys in both views were not fully verified.' }
if (!@($results | Where-Object { $_.name -eq 'recordless-files-excluded-from-registry-capacity-and-restore-type-guards' -and $_.passed }).Count) { $unverified += 'Windows-managed file exclusion from registry retention was not verified because its case was excluded, skipped, or failed.' }
if ($machineFixture) { $unverified += 'Normal HKCU roundtrip was not verified by this HKLM SYSTEM run; HKCU ERROR_RM_NOT_ACTIVE preservation requires a separate probe.' }
Save-Json $ReportPath @{ schema=1; fileFixtureRun=$script:fileFixtureRun; timestampUtc=[DateTimeOffset]::UtcNow.ToString('O'); executablePath=$ExecutablePath; moveExecutablePath=$MoveExecutablePath; passed=$passed; failed=$failed; skipped=$skipped; excludedCount=$excluded; results=@($results); preflight=$preflight; createdFixture=$createdFixture; securityPrivilegeEnabled=$securityPrivilege; registryFixtureRoot=$RegistryFixtureRoot; registryFixture=$runPath; cleanup=$cleanup; retainedDirectory=$OutputDirectory; unverified=$unverified }
[ordered]@{ passed=$passed; failed=$failed; skipped=$skipped; excludedCount=$excluded; reportPath=$ReportPath; remainingRegistryPath=$cleanup.remainingRegistryPath; remainingClassesPath=$cleanup.remainingClassesPath; retainedVolatileLinkPath=$cleanup.retainedVolatileLinkPath } | ConvertTo-Json
if ($failed) { exit 1 }; exit 0
