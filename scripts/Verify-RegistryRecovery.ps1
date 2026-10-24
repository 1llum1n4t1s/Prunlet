[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Alias('BaselineMoveExecutablePath')][string]$MoveExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
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
foreach ($path in @($ExecutablePath, $MoveExecutablePath, $OutputDirectory, $ReportPath) | Where-Object { $_ }) {
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
 public static void Configure(bool machine,string fixturePrefix) {
  string allowed=machine?"SYSTEM\\PrunletE2E\\":"Software\\PrunletE2E\\";
  string suffix=fixturePrefix.StartsWith(allowed,StringComparison.OrdinalIgnoreCase)?fixturePrefix.Substring(allowed.Length):"";
  if(suffix.Length!=32||!Guid.TryParseExact(suffix,"N",out _))throw new ArgumentException("Unsafe fixture namespace.");
  Hive=machine?RegistryHive.LocalMachine:RegistryHive.CurrentUser;
  Root=new IntPtr(machine?unchecked((int)0x80000002):unchecked((int)0x80000001)); FixturePrefix=fixturePrefix;
 }
 static void CheckFixture(string relative) {
  if(FixturePrefix==null||!(relative.Equals(FixturePrefix,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(FixturePrefix+"\\",StringComparison.OrdinalIgnoreCase)))throw new ArgumentException("Registry fixture escaped its unique run root.");
 }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegSetValueExW(SafeRegistryHandle k,string n,int r,uint t,byte[] b,int l);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryValueExW(SafeRegistryHandle k,string n,IntPtr r,out uint t,byte[] b,ref uint l);
 [DllImport("advapi32.dll")] static extern int RegGetKeySecurity(SafeRegistryHandle k,uint i,byte[] b,ref uint l);
 [DllImport("advapi32.dll")] static extern int RegSetKeySecurity(SafeRegistryHandle k,uint information,byte[] descriptor);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr root,string path,uint options,uint access,out SafeRegistryHandle key);
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
  SafeRegistryHandle h; int e=RegOpenKeyExW(Root,relative,0,(uint)(0x20019|(view==32?0x200:0x100)|(security?0x1000000:0)),out h);
  if(e==2)return null; if(e!=0)throw new Win32Exception(e); return RegistryKey.FromHandle(h,view==32?RegistryView.Registry32:RegistryView.Registry64);
 }
 public static RegistryKey Create(string relative,int view) {
  CheckFixture(relative);
  using(var root=RegistryKey.OpenBaseKey(Hive,view==32?RegistryView.Registry32:RegistryView.Registry64)) return root.CreateSubKey(relative,true);
 }
 public static void Set(RegistryKey k,string name,uint type,byte[] data) { int e=RegSetValueExW(k.Handle,name,0,type,data,data.Length);if(e!=0)throw new Win32Exception(e); }
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
    } finally { $k.Dispose() }
    if ($Tree) { $child = [PrunletRegistryE2E]::Create($script:Relative+'\子\empty',$View); $child.Dispose() }
}
function Snapshot([int]$View = 64) { [PrunletRegistryE2E]::Snapshot($script:Relative,$View) -join "`n" }
function Delete-Registry([string[]]$Options = @('--recursive'), [int]$View = 64) {
    $r = Invoke-RegistryCli (@('registry-delete','--view',"$View")+$Options+@('--',$script:Path))
    Assert-True ($r.ExitCode -eq 0 -and $r.Json.operationId) "Registry delete failed: $($r.Stdout) $($r.Stderr)"
    $root = Join-Path $script:Recovery $r.Json.operationId
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
foreach ($name in @('binary','日本語😀','')) {
    $valueName = $name
    $label = if (!$name) { 'default' } elseif ($name -eq 'binary') { 'named' } else { 'unicode' }
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
    Fixture; $op = Delete-Registry @('--value-name','binary'); $hash = Digest $op.Payload
    $k = [PrunletRegistryE2E]::Create($script:Relative,64)
    try { [PrunletRegistryE2E]::Set($k,'binary',3,[byte[]]@(0,1,128,255)) } finally { $k.Dispose() }
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
Case 'mixed-file-registry-capacity-order-and-restore-type-guards' -RequiresMove {
    $file = Join-Path $script:CaseRoot 'mixed-file.bin'
    [IO.File]::WriteAllBytes($file,[byte[]](0..255)*16)
    $fileHash = Digest $file; $fileBytes = [IO.FileInfo]::new($file).Length
    Fixture; $registryBefore = Snapshot
    # 保持予算を持つ旧schema 4だけを変更前exeで作り、新版MCPで復元と型境界を検証する。
    $p = Start-Child @('mcp'); $mcpCompleted = $false
    try {
        $stderrTask = $p.StandardError.ReadToEndAsync()
        function Mixed-Rpc([object]$Request) {
            $p.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 30 -Compress)); $p.StandardInput.Flush()
            for ($i=0; $i -lt 64; $i++) {
                $read = $p.StandardOutput.ReadLineAsync(); if (!$read.Wait(15000)) { throw 'Mixed-retention MCP response timeout.' }
                $line = $read.GetAwaiter().GetResult(); if (!$line) { throw 'Mixed-retention MCP output closed.' }
                $reply = $line | ConvertFrom-Json -Depth 80
                if ($reply.id -eq $Request.id) { return $reply }
            }; throw 'Too many mixed-retention MCP notifications.'
        }
        $init = Mixed-Rpc @{ jsonrpc='2.0'; id=1; method='initialize'; params=@{ protocolVersion='2024-11-05'; capabilities=@{}; clientInfo=@{name='mixed-retention-e2e';version='1'} } }
        Assert-True ($null -ne $init.result) 'Mixed-retention MCP initialize failed.'
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $p.StandardInput.Flush()
        $first = Invoke-RegistryCli @('delete','--',$file) -LegacyMove
        Assert-True ($first.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'Mixed-retention legacy file deletion failed.'
        $firstId = $first.Json.operationId
        $wrongRegistry = Mixed-Rpc @{ jsonrpc='2.0'; id=3; method='tools/call'; params=@{name='restore_registry';arguments=@{operationId=$firstId}} }
        Assert-True ($wrongRegistry.result.isError -and ![IO.File]::Exists($file)) 'Registry restore accepted a file operation.'
        $restoredFile = Mixed-Rpc @{ jsonrpc='2.0'; id=4; method='tools/call'; params=@{name='restore_files';arguments=@{operationId=$firstId}} }
        Assert-True (!$restoredFile.result.isError -and [IO.File]::Exists($file) -and (Digest $file) -ceq $fileHash) 'File restore after type rejection changed content.'
        $deletedFile = Invoke-RegistryCli @('delete','--',$file) -LegacyMove
        Assert-True ($deletedFile.ExitCode -eq 0 -and ![IO.File]::Exists($file)) 'Mixed-retention second legacy file deletion failed.'
        $fileId = $deletedFile.Json.operationId
        $fileManifest = Read-Json (Join-Path (Join-Path $script:Recovery $fileId) 'move-manifest.json')
        Assert-True ($fileManifest.schema -eq 4 -and $fileManifest.entries.Count -eq 1) 'Mixed-retention file operation did not use schema 4 root rename.'
        $entry = $fileManifest.entries[0]
        $filePayload = Join-Path (Join-Path $entry.storeRoot $fileId) $entry.payloadName
        $config = Read-Json $script:Config
        Assert-True ($filePayload.StartsWith($config.volumeRecoveryDirectories['D:\']+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($filePayload) -and (Digest $filePayload) -ceq $fileHash) 'Mixed-retention file payload escaped the isolated D: store or changed content.'
        $registryOp = Delete-Registry; $registryHash = Digest $registryOp.Payload
        $registryBytes = [IO.FileInfo]::new($registryOp.Payload).Length
        $wrongFile = Mixed-Rpc @{ jsonrpc='2.0'; id=6; method='tools/call'; params=@{name='restore_files';arguments=@{operationId=$registryOp.Id}} }
        Assert-True ($wrongFile.result.isError -and !(Exists) -and (Digest $registryOp.Payload) -ceq $registryHash) 'File restore accepted a registry operation or changed its backup.'
        $totalBytes = $fileBytes + $registryBytes
        $inspection = Invoke-RegistryCli @('maintain','--dry-run')
        Assert-True ($inspection.ExitCode -eq 0 -and $inspection.Json.capacityKnown -and $inspection.Json.retainedBytesBefore -eq $totalBytes -and $inspection.Json.retainedBytesAfter -eq $totalBytes) 'Capacity inspection did not sum schema 4 file and schema 5 registry payloads.'
        Assert-True ([IO.File]::Exists($filePayload) -and (Digest $registryOp.Payload) -ceq $registryHash) 'Capacity dry run changed mixed recovery data.'
        $config.maxRecoveryBytes = $registryBytes; Save-Json $script:Config $config
        $maintenance = Invoke-RegistryCli @('maintain','--apply')
        Assert-True ($maintenance.ExitCode -eq 0 -and $maintenance.Json.capacityKnown -and $maintenance.Json.budgetSatisfied -and $maintenance.Json.retainedBytesBefore -eq $totalBytes -and $maintenance.Json.retainedBytesAfter -eq $registryBytes -and $maintenance.Json.purgedBytes -eq $fileBytes) 'Mixed-retention maintenance did not rescan the combined capacity after eviction.'
        Assert-True (![IO.File]::Exists($filePayload) -and ![IO.File]::Exists($file) -and !(Exists) -and (Digest $registryOp.Payload) -ceq $registryHash) 'Mixed retention failed to purge only the older file and preserve the newer registry snapshot.'
        $restoredRegistry = Mixed-Rpc @{ jsonrpc='2.0'; id=7; method='tools/call'; params=@{name='restore_registry';arguments=@{operationId=$registryOp.Id}} }
        Assert-True (!$restoredRegistry.result.isError -and (Snapshot) -ceq $registryBefore -and ![IO.File]::Exists($registryOp.Payload)) 'Registry restore after mixed eviction changed content or failed to consume its snapshot.'
        $empty = Invoke-RegistryCli @('maintain','--apply')
        Assert-True ($empty.ExitCode -eq 0 -and $empty.Json.capacityKnown -and $empty.Json.retainedBytesBefore -eq 0 -and $empty.Json.retainedBytesAfter -eq 0) 'Consumed mixed operations remained in retained capacity.'
        $mcpCompleted = $true
    } finally {
        $p.StandardInput.Close()
        if (!$p.WaitForExit(15000)) { $p.Kill($true); $p.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $script:CaseRoot 'mcp.stderr.txt'),$stderrTask.GetAwaiter().GetResult(),$utf8)
        $exitCode = $p.ExitCode; $p.Dispose()
        if ($mcpCompleted) { Assert-True ($exitCode -eq 0) "Mixed-retention MCP shutdown failed: $exitCode" }
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
        Assert-True ($names.Count -eq 6 -and $names -contains 'delete_files' -and $names -contains 'restore_files' -and $names -contains 'delete_registry' -and $names -contains 'restore_registry' -and $names -contains 'reconcile_registry' -and $names -contains 'list_operations' -and !($names -match 'purge')) 'MCP tool contract changed.'
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
        $operationDirectory = Join-Path $script:Recovery $id
        $metadataBefore = @(Get-ChildItem -LiteralPath $operationDirectory -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Digest $_.FullName) }) -join "`n"
        $reconciled = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'reconcile_registry'; arguments = @{ operationId = $id } } }
        $metadataAfter = @(Get-ChildItem -LiteralPath $operationDirectory -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Digest $_.FullName) }) -join "`n"
        Assert-True (!$reconciled.result.isError -and $reconciled.result.structuredContent.dryRun -and $reconciled.result.structuredContent.items[0].kind -ceq 'registry-key' -and !(Exists) -and $metadataBefore -ceq $metadataAfter) 'MCP reconciliation changed registry/metadata or lost its registry kind.'
        $restored = Rpc @{ jsonrpc = '2.0'; id = $rpcId++; method = 'tools/call'; params = @{ name = 'restore_registry'; arguments = @{ operationId = $id } } }
        Assert-True (!$restored.result.isError -and (Snapshot) -ceq $before) 'MCP roundtrip changed raw tree or ACL.'
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
if (!$results.Count) { $results.Add(@{ name='case-filter-matched-no-cases'; passed=$false; error='CaseFilter matched no cases.' }) }
# 清掃も今回exeを一度だけ利用する。拒否は別APIへ付け替えず残存パスを報告する。
$cleanup = @{ attempted = $false; remainingRegistryPath = $runPath; operations = @() }
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
    } catch { $cleanup.error = $_.Exception.Message }
}
$passed = @($results | Where-Object passed).Count; $skipped = @($results | Where-Object skipped).Count; $failed = $results.Count - $passed - $skipped
$unverified = @('Native registry link rejection and exact privilege-deficient token behavior require separate native probes.','KTM concurrency and crash timing require separate integration probes.','Distinct WOW64 view isolation requires separate views; SYSTEM shared views do not verify isolation. See view-observation.json.')
if (!@($results | Where-Object { $_.name -eq 'mixed-file-registry-capacity-order-and-restore-type-guards' -and $_.passed }).Count) { $unverified += 'Mixed file/registry retention was not verified because its case was excluded, skipped, or failed.' }
if ($machineFixture) { $unverified += 'Normal HKCU roundtrip was not verified by this HKLM SYSTEM run; HKCU ERROR_RM_NOT_ACTIVE preservation requires a separate probe.' }
Save-Json $ReportPath @{ schema=1; timestampUtc=[DateTimeOffset]::UtcNow.ToString('O'); executablePath=$ExecutablePath; moveExecutablePath=$MoveExecutablePath; passed=$passed; failed=$failed; skipped=$skipped; excludedCount=$excluded; results=@($results); preflight=$preflight; createdFixture=$createdFixture; securityPrivilegeEnabled=$securityPrivilege; registryFixtureRoot=$RegistryFixtureRoot; registryFixture=$runPath; cleanup=$cleanup; retainedDirectory=$OutputDirectory; unverified=$unverified }
[ordered]@{ passed=$passed; failed=$failed; skipped=$skipped; excludedCount=$excluded; reportPath=$ReportPath; remainingRegistryPath=$cleanup.remainingRegistryPath } | ConvertTo-Json
if ($failed) { exit 1 }; exit 0
