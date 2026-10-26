# 失敗条件: 移行dry-runの変更、旧record bytes/ID喪失、typed不正layoutの無視、通常容量走査での本文再読、
# 復元前/深い監査の破損見逃し、終端後の上書き、cleanup途中の証拠消失、再開不能、
# 中断した参考用結果の孤立pending化・0バイト結果による終端整理停止・空stage増殖を検出する。
# 正式移行intent付きlayout公開中断の再開不能、予約prefix以外の採用、元metadata差替えの見逃し、
# 全不在deleteの永久active化、候補hintによるauthority捏造、入力件数/statusの変更も検出する。
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ExecutablePath,
 [Parameter(Mandatory)][string]$BaselineExecutablePath,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [Parameter(Mandatory)][string]$ReportPath,
 [ValidateRange(100,65536)][int]$FileCount=32769
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach($path in @($ExecutablePath,$BaselineExecutablePath,$OutputDirectory,$ReportPath)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
Assert-VerificationDestination $OutputDirectory @([IO.Path]::GetFullPath((Split-Path $PSScriptRoot)),(Join-Path $env:USERPROFILE '.codex'))
if(Test-Path -LiteralPath $OutputDirectory){throw 'Unused output directory required'}
if(!(Test-Path -LiteralPath (Split-Path $ReportPath))){throw 'Report parent must exist'}
if([Diagnostics.FileVersionInfo]::GetVersionInfo($BaselineExecutablePath).ProductVersion-notmatch'^1\.0\.15(?:[.+-]|$)'){throw 'Genuine pre-migration 1.0.15 baseline required'}
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$env:TEMP=Join-Path $OutputDirectory 'temp';$env:TMP=$env:TEMP;$null=[IO.Directory]::CreateDirectory($env:TEMP)
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=Join-Path $OutputDirectory 'runtime-cache'
$results=[Collections.Generic.List[object]]::new()
$utf8=[Text.UTF8Encoding]::new($false)
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;
public static class LifecycleE2ENative {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int field,byte[] bytes,uint length);
 [StructLayout(LayoutKind.Sequential)] struct BasicInfo {public uint Attributes,CreationLow,CreationHigh,AccessLow,AccessHigh,WriteLow,WriteHigh,VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;}
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out BasicInfo information);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetKernelObjectSecurity(SafeFileHandle file,uint information,byte[] bytes,uint length,out uint needed);
 [DllImport("ntdll.dll")] static extern int NtSetSecurityObject(SafeFileHandle file,uint information,byte[] bytes);
 public static string Identity(string path){using var h=CreateFileW(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h.IsInvalid)throw new System.ComponentModel.Win32Exception();var b=new byte[24];if(!GetFileInformationByHandleEx(h,18,b,24))throw new System.ComponentModel.Win32Exception();return Convert.ToHexString(b);}
 public static string LifecycleIdentity(string path){using var h=CreateFileW(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h.IsInvalid||!GetFileInformationByHandle(h,out var info))throw new System.ComponentModel.Win32Exception();return $"{info.VolumeSerial:x8}:{info.IndexHigh:x8}{info.IndexLow:x8}";}
 public static string ChangeToken(string path){using var h=CreateFileW(path,0x80,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h.IsInvalid)throw new System.ComponentModel.Win32Exception();var b=new byte[40];if(!GetFileInformationByHandleEx(h,0,b,40))throw new System.ComponentModel.Win32Exception();return Convert.ToHexString(b.AsSpan(16,20));}
 public static SafeFileHandle HoldDirectory(string path){var h=CreateFileW(path,0x80000000,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h.IsInvalid)throw new System.ComponentModel.Win32Exception();return h;}
 public static string Security(string path){using var h=CreateFileW(path,0x20000,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h.IsInvalid)throw new System.ComponentModel.Win32Exception();GetKernelObjectSecurity(h,7,null,0,out uint n);var b=new byte[n];if(!GetKernelObjectSecurity(h,7,b,n,out n))throw new System.ComponentModel.Win32Exception();return Convert.ToBase64String(b);}
 public static void FixtureDacl(string path,string security){var d=new System.Security.AccessControl.RawSecurityDescriptor(Convert.FromBase64String(security),0);if((d.ControlFlags&System.Security.AccessControl.ControlFlags.DiscretionaryAclAutoInherited)!=0)d.SetFlags(d.ControlFlags|System.Security.AccessControl.ControlFlags.DiscretionaryAclAutoInheritRequired);var b=new byte[d.BinaryLength];d.GetBinaryForm(b,0);using var h=CreateFileW(path,0x60000,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(h.IsInvalid)throw new System.ComponentModel.Win32Exception();int status=NtSetSecurityObject(h,4,b);if(status<0)throw new IOException("Fixture DACL NTSTATUS "+status);}
 public static void CreateTree(string root,int count){Directory.CreateDirectory(root);for(int i=0;i<count;i++)File.WriteAllText(Path.Combine(root,$"file-{i:D6}.txt"),$"lifecycle-{i}");}
}
// FSW callbackから今回のCMDが起動した同一exeの子だけを停止する。製品へtest hookを追加しない。
public sealed class LifecycleBoundaryGate:IDisposable {
 [DllImport("ntdll.dll")] static extern int NtSuspendProcess(SafeProcessHandle process);
 [DllImport("ntdll.dll")] static extern int NtResumeProcess(SafeProcessHandle process);
 [DllImport("kernel32.dll",SetLastError=true)] static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags,uint pid);
 [DllImport("kernel32.dll",EntryPoint="Process32FirstW",ExactSpelling=true,CharSet=CharSet.Unicode)] static extern bool Process32FirstW(SafeFileHandle snapshot,ref Entry entry);
 [DllImport("kernel32.dll",EntryPoint="Process32NextW",ExactSpelling=true,CharSet=CharSet.Unicode)] static extern bool Process32NextW(SafeFileHandle snapshot,ref Entry entry);
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Entry {public uint Size,Usage,Pid;public UIntPtr Heap;public uint Module,Threads,Parent;public int Priority;public uint Flags;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)]public string Exe;}
 readonly FileSystemWatcher watcher;readonly string directory,mode,key,executable;
 readonly ManualResetEventSlim bound=new(false),reached=new(false);readonly object sync=new();bool closed;Process launcher,owned;int matched;
 public int SuspendCount{get;private set;}public int ResumeCount{get;private set;}public int KillCount{get;private set;}public bool Suspended{get;private set;}public string Error{get;private set;}public string ObservedPath{get;private set;}public int OwnedProcessId{get;private set;}public int SuspendStatus{get;private set;}=int.MinValue;
 public LifecycleBoundaryGate(string watchRoot,string expectedDirectory,string mode,string key,string executable){this.directory=expectedDirectory;this.mode=mode;this.key=key;this.executable=executable;watcher=new FileSystemWatcher(watchRoot){IncludeSubdirectories=true,NotifyFilter=NotifyFilters.FileName};watcher.Created+=(s,e)=>Observe(e.FullPath);watcher.Renamed+=(s,e)=>Observe(e.FullPath);watcher.Error+=(s,e)=>{Error=e.GetException().Message;reached.Set();};watcher.EnableRaisingEvents=true;}
 Process FindOwned(){using var snapshot=CreateToolhelp32Snapshot(2,0);if(snapshot.IsInvalid)throw new IOException("Cannot enumerate owned CLI process.");var entry=new Entry{Size=(uint)Marshal.SizeOf<Entry>()};if(Process32FirstW(snapshot,ref entry)){do{if(entry.Parent!=(uint)launcher.Id||!string.Equals(entry.Exe,Path.GetFileName(executable),StringComparison.OrdinalIgnoreCase))continue;var process=Process.GetProcessById((int)entry.Pid);if(string.Equals(process.MainModule.FileName,executable,StringComparison.OrdinalIgnoreCase))return process;process.Dispose();}while(Process32NextW(snapshot,ref entry));}throw new IOException("Owned CMD has no matching CLI child.");}
 void Observe(string path){lock(sync){if(closed)return;bool target=mode=="recycle-complete"?string.Equals(Path.GetDirectoryName(Path.GetDirectoryName(path)),directory,StringComparison.OrdinalIgnoreCase)&&Regex.IsMatch(Path.GetFileName(path),@"^recycle-[0-9]{4,}-complete[.]json$"):mode=="exact-pending"?string.Equals(Path.GetDirectoryName(path),directory,StringComparison.OrdinalIgnoreCase)&&Regex.IsMatch(Path.GetFileName(path),"^"+Regex.Escape(key)+@"[.]pending-[0-9a-f]{32}$"):mode=="exact"?string.Equals(path,Path.Combine(directory,key),StringComparison.OrdinalIgnoreCase):mode=="layout"?string.Equals(Path.GetDirectoryName(path),directory,StringComparison.OrdinalIgnoreCase)&&Regex.IsMatch(Path.GetFileName(path),@"^record-layout[.]json[.]pending-[0-9a-f]{32}$"):Path.GetFileName(path)=="ready.json"&&string.Equals(Path.GetDirectoryName(Path.GetDirectoryName(path)),directory,StringComparison.OrdinalIgnoreCase)&&Regex.IsMatch(Path.GetFileName(Path.GetDirectoryName(path)),@"^\.publication-[0-9a-f]{32}-"+Regex.Escape(key)+"$");if(!target||Interlocked.CompareExchange(ref matched,1,0)!=0)return;try{if(!bound.Wait(10000)||owned==null)throw new IOException("CLI launcher was not bound.");SuspendStatus=NtSuspendProcess(owned.SafeHandle);if(SuspendStatus<0)throw new IOException("Suspend NTSTATUS "+SuspendStatus);SuspendCount++;Suspended=true;ObservedPath=path;}catch(Exception e){Error=e.Message;}finally{reached.Set();}}}
 public void Bind(Process process){launcher=process;try{var watch=Stopwatch.StartNew();while(watch.ElapsedMilliseconds<10000&&!launcher.HasExited){try{owned=FindOwned();OwnedProcessId=owned.Id;var handle=owned.SafeHandle;break;}catch(Exception){Thread.Sleep(2);}}if(owned==null){Error="Owned CLI was unavailable before process binding completed.";reached.Set();}}finally{bound.Set();}}public bool Wait(int milliseconds)=>reached.Wait(milliseconds);
 public void Resume(){lock(sync){if(!Suspended)return;if(!owned.HasExited){if(NtResumeProcess(owned.SafeHandle)<0)throw new IOException("Cannot resume owned CLI.");ResumeCount++;}Suspended=false;}}
 public void KillOwned(){lock(sync){if(owned!=null&&!owned.HasExited){owned.Kill();owned.WaitForExit();KillCount++;}Suspended=false;}}
 public void Dispose(){lock(sync){if(closed)return;closed=true;watcher.Dispose();try{Resume();}finally{owned?.Dispose();bound.Dispose();reached.Dispose();}}}
}
'@
function Assert-Lifecycle([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function Read-LifecyclePublishedJson([string]$Path){
 # rename直後のpublisherがまだWRITE/DELETE handleを保持していても、読取りだけで境界を観測する。
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
 try{Assert-Lifecycle ($stream.Length-le16MB) 'Published control exceeds bounded E2E read';$reader=[IO.StreamReader]::new($stream,$utf8);try{return $reader.ReadToEnd()|ConvertFrom-Json -AsHashtable -Depth 100}finally{$reader.Dispose()}}finally{$stream.Dispose()}
}
function Invoke-LifecycleCli([string]$Exe,[string]$Config,[string[]]$Arguments){
 $info=[Diagnostics.ProcessStartInfo]::new('cmd.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true
 $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8
 # 制御パスは外部のASCII絶対パスに限定し、実対象はUTF-8 JSON一覧だけで渡す。
 foreach($p in @($Exe,$Config)){if($p-cnotmatch'^[A-Za-z]:\\[A-Za-z0-9_.\\-]+$'){throw 'Safe ASCII control paths required'}}
 $args=@('--config',$Config)+$Arguments
 if(@($args|Where-Object {$_-match'[\s"&|<>^%!()]'}).Count){throw 'Unsafe CMD control argument'}
 $info.Arguments='/d /c '+$Exe+' '+($args-join' ')
 $p=[Diagnostics.Process]::Start($info);$clock=[Diagnostics.Stopwatch]::StartNew()
 try{$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();if(!$p.WaitForExit(240000)){$p.Kill($true);throw 'Lifecycle CLI timeout'};$text=$o.GetAwaiter().GetResult();$json=$null;try{$json=$text|ConvertFrom-Json -AsHashtable -Depth 100}catch{};return @{exitCode=$p.ExitCode;json=$json;stdout=$text;stderr=$e.GetAwaiter().GetResult();milliseconds=$clock.Elapsed.TotalMilliseconds;launcherCpuMilliseconds=$p.TotalProcessorTime.TotalMilliseconds}}finally{$p.Dispose()}
}
function New-LifecycleScope([string]$Name){
 $dir=Join-Path $OutputDirectory $Name;$null=[IO.Directory]::CreateDirectory($dir)
 $s=@{root=$dir;metadata=(Join-Path $dir 'metadata');config=(Join-Path $dir 'config.json');files=(Join-Path $dir 'files')}
 $null=[IO.Directory]::CreateDirectory($s.files)
 $null=[IO.Directory]::CreateDirectory($s.metadata)
 $r=Invoke-LifecycleCli $BaselineExecutablePath $s.config @('init','--backup-directory',$s.metadata)
 Assert-Lifecycle ($r.exitCode-eq0) ('Baseline init failed: '+$r.stderr+$r.stdout)
 $c=[IO.File]::ReadAllText($s.config)|ConvertFrom-Json -AsHashtable
 $c.volumeRecoveryDirectories=@{'D:/'=(Join-Path $dir 'volume-store')};[IO.File]::WriteAllText($s.config,($c|ConvertTo-Json -Depth 30),$utf8)
 return $s
}
function Invoke-LifecycleDelete($Scope,[string[]]$Paths){
 $file=Join-Path $Scope.root ('paths-'+[guid]::NewGuid().ToString('N')+'.json')
 [IO.File]::WriteAllText($file,(ConvertTo-Json -InputObject $Paths),$utf8)
 $r=Invoke-LifecycleCli $BaselineExecutablePath $Scope.config @('delete','--recursive','--paths-file',$file)
 Assert-Lifecycle ($r.exitCode-eq0-and$r.json.operationId) ('Baseline recycle failed: '+$r.stderr+$r.stdout)
 return $r.json.operationId
}
function Get-LifecycleMetadataHashes([string]$Directory,[switch]$ExcludeNewRecordLayout){
 return @((Get-ChildItem -LiteralPath $Directory -File -Recurse|Where-Object {!$ExcludeNewRecordLayout-or$_.Name-cne'record-layout.json'}|Sort-Object FullName)|ForEach-Object {$_.FullName.Substring($Directory.Length)+'='+((Get-FileHash -LiteralPath $_.FullName).Hash)})-join"`n"
}
function Get-LifecycleNamespace([string]$Directory){
 return @((Get-ChildItem -LiteralPath $Directory -Force -Recurse|Sort-Object FullName)|ForEach-Object {$_.FullName.Substring($Directory.Length)+'='+$(if($_.PSIsContainer){'directory'}else{'file'})})-join"`n"
}
function Test-LifecycleCase([string]$Name,[scriptblock]$Body){
 $script:LifecycleEvidence=@{};$clock=[Diagnostics.Stopwatch]::StartNew();try{&$Body;$results.Add(@{name=$Name;passed=$true;milliseconds=$clock.Elapsed.TotalMilliseconds;observed=$script:LifecycleEvidence})}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;location=$_.InvocationInfo.PositionMessage;milliseconds=$clock.Elapsed.TotalMilliseconds;observed=$script:LifecycleEvidence})}
}
function Initialize-LifecycleSparseNative {
 if('PrunletSparseE2E'-as[type]){return}
 # 別runnerは実行せず、検証済みnative helperの型定義だけを共有する。
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Verify-RecycleBin.ps1'),[ref]$tokens,[ref]$errors)
 Assert-Lifecycle ($errors.Count-eq0) 'Sparse helper source has parse errors'
 $definitions=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.StringConstantExpressionAst]-and$node.Value.Contains('public static class PrunletSparseE2E')},$true))
 Assert-Lifecycle ($definitions.Count-eq1-and$definitions[0].Value.Contains('RestoreTiny(')) 'Unique safe sparse finalizer definition required'
 Add-Type -TypeDefinition $definitions[0].Value
}
function Get-LifecycleOriginalEvidence([string]$Path,[int]$PrefixLength=0){
 $e=@{identity=[LifecycleE2ENative]::Identity($Path);security=[LifecycleE2ENative]::Security($Path);attributes=[int][IO.File]::GetAttributes($Path)}
 if([IO.File]::Exists($Path)){
  $e.length=[IO.FileInfo]::new($Path).Length
  if($PrefixLength){$stream=[IO.File]::OpenRead($Path);try{$bytes=[byte[]]::new($PrefixLength);Assert-Lifecycle ($stream.Read($bytes,0,$bytes.Length)-eq$bytes.Length) 'Sparse prefix short read';$e.prefix=[Convert]::ToBase64String($bytes)}finally{$stream.Dispose()}}
  else{$e.sha256=(Get-FileHash -LiteralPath $Path).Hash}
 }
 return $e
}
function Assert-LifecycleOriginalEvidence([string]$Path,$Expected,[int]$PrefixLength=0){
 $actual=Get-LifecycleOriginalEvidence $Path $PrefixLength
 foreach($key in $Expected.Keys){Assert-Lifecycle ($actual[$key]-ceq$Expected[$key]) ('Original source evidence changed: '+$key+' '+$Path)}
}
function Move-LifecycleOriginalEvidence([string]$Source,[string]$Destination,[string]$ScopeRoot){
 if(![IO.Directory]::Exists($Source)){Move-LifecycleOwnEvidence $Source $Destination $ScopeRoot;return}
 $sourcePath=[IO.Path]::GetFullPath($Source);$destinationPath=[IO.Path]::GetFullPath($Destination);$prefix=[IO.Path]::GetFullPath($ScopeRoot).TrimEnd([char]92)+'\'
 foreach($path in @($sourcePath,$destinationPath)){Assert-Lifecycle ($path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) 'Original evidence move escaped fixture';Assert-VerificationDestination $path @()}
 Assert-Lifecycle (!(Test-Path -LiteralPath $destinationPath)) 'Original evidence move destination already exists'
 $before=Get-LifecycleOriginalEvidence $sourcePath;[IO.Directory]::Move($sourcePath,$destinationPath);Assert-LifecycleOriginalEvidence $destinationPath $before
}
function Complete-LifecycleOriginalFixture($Fixture){
 if(!$Fixture){return}
 $result=[PrunletSparseE2E]::RestoreTiny($Fixture.sparse,$Fixture.sparseEvidence.identity,$Fixture.sparseEvidence.security,$Fixture.sparseEvidence.attributes,$Fixture.sparseEvidence.length,$Fixture.prefix,1MB)
 $script:LifecycleEvidence.sparseFinalizer=$result;$script:LifecycleEvidence.sparseFinalizationSucceeded=$result.Success;$script:LifecycleEvidence.sparseFixturePath=$Fixture.sparse
 Assert-Lifecycle $result.Success ('Sparse fixture finalizer failed: '+$result.Error)
}
function New-LifecycleOriginalFixture([string]$Name){
 $script:LifecycleEvidence.bodyAssertionsPassed=$false
 Initialize-LifecycleSparseNative
 $scope=New-LifecycleScope $Name;$tree=Join-Path $scope.files 'original-tree';$null=[IO.Directory]::CreateDirectory($tree)
 $child=Join-Path $tree 'small.txt';[IO.File]::WriteAllText($child,'original-present-child',$utf8)
 $sparse=Join-Path $tree 'oversized.bin';$prefix=[Text.Encoding]::UTF8.GetBytes('Prunlet original-present refusal fixture prefix')
 $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($sparse));Assert-Lifecycle ($drive.IsReady-and$drive.TotalSize-lt([long]::MaxValue-4096)) 'Sparse fixture drive size unavailable'
 [IO.File]::WriteAllBytes($sparse,$prefix);$stream=[IO.File]::Open($sparse,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
 try{[PrunletSparseE2E]::MakeSparse($stream.SafeFileHandle)}finally{$stream.Dispose()}
 $fixture=@{scope=$scope;tree=$tree;child=$child;sparse=$sparse;prefix=$prefix;sparseEvidence=(Get-LifecycleOriginalEvidence $sparse $prefix.Length);treeEvidence=(Get-LifecycleOriginalEvidence $tree);childEvidence=(Get-LifecycleOriginalEvidence $child)}
 try{
  $fixture.sparseEvidence.length=$drive.TotalSize+4096
  $stream=[IO.File]::Open($sparse,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
  try{$stream.SetLength($fixture.sparseEvidence.length);$stream.Flush($true)}finally{$stream.Dispose()}
  Assert-Lifecycle ([PrunletSparseE2E]::Allocation($sparse)-le1MB) 'Sparse fixture allocation exceeds bound'
  $paths=Join-Path $scope.root 'original-paths.json';[IO.File]::WriteAllText($paths,(ConvertTo-Json -InputObject @($tree)),$utf8)
  $r=Invoke-LifecycleCli $BaselineExecutablePath $scope.config @('delete','--recursive','--paths-file',$paths)
  Assert-Lifecycle ($r.exitCode-ne0-and$r.json.operationId) ('Genuine old15 Shell refusal required: '+$r.stdout+$r.stderr)
  $fixture.id=$r.json.operationId;$fixture.record=Join-Path $scope.metadata $fixture.id
  Assert-Lifecycle (Test-Path -LiteralPath (Join-Path $fixture.record 'recycle-manifest.json')) 'Old15 refusal did not publish its real manifest'
  Assert-Lifecycle (@(Get-ChildItem -LiteralPath $fixture.record -Recurse -File|Where-Object Name -Match '(recycle|restore).*complete').Count-eq0) 'Refusal fixture already has positive completion authority'
  Assert-LifecycleOriginalEvidence $tree $fixture.treeEvidence;Assert-LifecycleOriginalEvidence $child $fixture.childEvidence;Assert-LifecycleOriginalEvidence $sparse $fixture.sparseEvidence $prefix.Length
  $script:LifecycleEvidence.old15Refusal=$r;$script:LifecycleEvidence.original=@{tree=$fixture.treeEvidence;child=$fixture.childEvidence;sparse=$fixture.sparseEvidence}
  return $fixture
 }catch{Complete-LifecycleOriginalFixture $fixture;throw}
}
function Get-LifecycleOriginalRecord($Fixture){
 $typed=Join-Path (Join-Path $Fixture.scope.metadata '.recycle-records-v1') $Fixture.id
 if(Test-Path -LiteralPath $typed){return $typed};return $Fixture.record
}
function New-LifecycleOriginalSuccessorFixture([string]$Name){
 $attempts=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.successorAttempts=$attempts
 foreach($attempt in 1..3){
  $fixture=$null;$gate=$null;$session=$null;$held=$null;$captured=$false
  try{
   $fixture=New-LifecycleOriginalFixture ($Name+'-'+$attempt)
   $fixture.childMoved=Join-Path $fixture.scope.files 'retained-child.txt';Move-LifecycleOwnEvidence $fixture.child $fixture.childMoved $fixture.scope.root
   $closed=Join-Path $fixture.scope.metadata '.closed-records-v1';$fixture.request=Join-Path $closed ($fixture.id+'.request.json')
   # candidate publisherのWRITE/DELETE handleが閉じた後のmigration layoutを停止点にする。
   $typedRecord=Join-Path (Join-Path $fixture.scope.metadata '.recycle-records-v1') $fixture.id
   $gate=[LifecycleBoundaryGate]::new($fixture.scope.metadata,$typedRecord,'layout','',$ExecutablePath)
   $session=Start-LifecycleProcess $fixture.scope @('maintain','--apply');$gate.Bind($session.process)
   $observed=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $fixture.request)
   if($observed){
    $candidate=[IO.File]::ReadAllText($fixture.request)|ConvertFrom-Json -AsHashtable -Depth 100
    $observed=$candidate.kind-ceq'retire-original-request'
    if($observed){
     $fixture.predecessor=Get-LifecycleFileEvidence $fixture.request
     $fixture.predecessorLifecycleIdentity=[LifecycleE2ENative]::LifecycleIdentity($fixture.request)
     # 完成した旧candidateを保持し、successor flush後の旧final削除だけを拒否する。
     $held=[IO.File]::Open($fixture.request,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    }
   }
   $gate.Resume();$response=Finish-LifecycleProcess $session
   if($held){$held.Dispose();$held=$null}
   $pending=@(Get-ChildItem -LiteralPath $closed -File -Filter ($fixture.id+'.request.json.pending-*') -ErrorAction SilentlyContinue)
   if($observed-and$pending.Count-eq1){
    $body=$null;try{$body=[IO.File]::ReadAllText($pending[0].FullName)|ConvertFrom-Json -AsHashtable -Depth 100}catch{}
    $captured=$body-and$body.kind-ceq'original-reconcile-needed'-and$body.operationId-ceq$fixture.id-and$body.previousRequestIdentity-ceq$fixture.predecessorLifecycleIdentity-and$body.previousRequestLength-eq$fixture.predecessor.length-and$body.previousRequestSha256-ceq$fixture.predecessor.sha256.ToLowerInvariant()
    if($captured){$fixture.pending=$pending[0].FullName;$fixture.successor=$body;Assert-LifecycleFileEvidence $fixture.request $fixture.predecessor}
   }
   $attempts.Add(@{attempt=$attempt;scope=$fixture.scope.root;candidateObserved=$observed;successorCaptured=[bool]$captured;ownedProcessId=$gate.OwnedProcessId;gateError=$gate.Error;response=$response})
   if($captured){return $fixture}
  }finally{
   if($session){if(!$session.process.HasExited){if($gate){$gate.KillOwned()};$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()};if($gate){$gate.Dispose()};if($held){$held.Dispose()}
   if($fixture-and!$captured){if([IO.File]::Exists($fixture.childMoved)){Move-LifecycleOwnEvidence $fixture.childMoved $fixture.child $fixture.scope.root};Complete-LifecycleOriginalFixture $fixture}
  }
 }
 throw 'A genuine flushed candidate-to-negative successor was not captured in three fresh attempts; no interruption success is claimed'
}
function New-LifecycleUnpublishedOriginalFixture([string]$Name){
 $attempts=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.unpublishedAttempts=$attempts
 foreach($attempt in 1..3){
  $scope=New-LifecycleScope ($Name+'-'+$attempt);$tree=Join-Path $scope.files 'source-tree';$null=[IO.Directory]::CreateDirectory($tree)
  $child=Join-Path $tree 'small.txt';[IO.File]::WriteAllText($child,'unpublished-original-snapshot',$utf8)
  $fixture=@{scope=$scope;tree=$tree;child=$child;treeEvidence=(Get-LifecycleOriginalEvidence $tree);childEvidence=(Get-LifecycleFileEvidence $child)}
  $paths=Join-Path $scope.root 'paths.json';[IO.File]::WriteAllText($paths,(ConvertTo-Json -InputObject @($tree)),$utf8)
  $typedRoot=Join-Path $scope.metadata '.recycle-records-v1';$key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('recycle-manifest.json'))).ToLowerInvariant().Substring(0,32)
  $gate=[LifecycleBoundaryGate]::new($scope.metadata,$typedRoot,'manifest',$key,$ExecutablePath);$session=$null;$observed=$false
  try{
   $session=Start-LifecycleProcess $scope @('delete','--recursive','--paths-file',$paths);$gate.Bind($session.process)
   $observed=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $gate.ObservedPath)
   if($observed){
    $control=Split-Path $gate.ObservedPath;$match=[regex]::Match((Split-Path $control -Leaf),'^[.]publication-([a-f0-9]{32})-');Assert-Lifecycle $match.Success 'Unpublished manifest has no generated operation identity'
    $fixture.id=$match.Groups[1].Value;$fixture.control=$control;$fixture.record=Join-Path $typedRoot $fixture.id;$fixture.manifest=Join-Path $fixture.record 'recycle-manifest.json';$fixture.body=Join-Path $control 'body.json';$fixture.owner=Join-Path $control 'owner.json'
    $observed=!(Test-Path -LiteralPath $fixture.manifest)-and(Test-Path -LiteralPath $fixture.body)-and[IO.Directory]::Exists($tree)
    if($observed){$gate.KillOwned()}
   }
   if(!$observed){$gate.Resume()};$response=Finish-LifecycleProcess $session
   $attempts.Add(@{attempt=$attempt;scope=$scope.root;boundaryObserved=$observed;ownedProcessId=$gate.OwnedProcessId;gateError=$gate.Error;response=$response})
   if(!$observed){if($response.json.operationId){$restored=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$response.json.operationId);Assert-Lifecycle ($restored.exitCode-eq0) 'Missed unpublished boundary could not restore its fixture'};continue}
   $fixture.ownerBody=[IO.File]::ReadAllText($fixture.owner)|ConvertFrom-Json -AsHashtable -Depth 100
   $fixture.bodyBytes=[IO.File]::ReadAllBytes($fixture.body);$fixture.bodyEvidence=Get-LifecycleFileEvidence $fixture.body;$fixture.ownerEvidence=Get-LifecycleFileEvidence $fixture.owner
   $body=[Text.Encoding]::UTF8.GetString($fixture.bodyBytes)|ConvertFrom-Json -AsHashtable -Depth 100
   Assert-Lifecycle ($fixture.ownerBody.documentType-ceq'manifest'-and$fixture.ownerBody.operationId-ceq$fixture.id-and$fixture.ownerBody.finalName-ceq'recycle-manifest.json'-and$fixture.ownerBody.bodyLength-eq$fixture.bodyBytes.Length-and$fixture.ownerBody.bodySha256-ceq$fixture.bodyEvidence.sha256.ToLowerInvariant()-and@($body.entries).Count-eq1-and$body.entries[0].path-ceq$tree-and$body.entries[0].state-cne'already_absent'-and$body.entries[0].security) 'Unpublished fixture is not a genuine complete generated source snapshot'
   Assert-LifecycleOriginalEvidence $tree $fixture.treeEvidence;Assert-LifecycleFileEvidence $child $fixture.childEvidence
   $script:LifecycleEvidence.unpublishedOwner=$fixture.ownerBody;$script:LifecycleEvidence.original=@{tree=$fixture.treeEvidence;child=$fixture.childEvidence;body=$fixture.bodyEvidence;owner=$fixture.ownerEvidence}
   return $fixture
  }finally{if($session){if(!$session.process.HasExited){$gate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()};$gate.Dispose()}
 }
 throw 'A genuine unpublished original manifest was not caught in three fresh attempts; no interruption success is claimed'
}
function New-LifecycleDeferredUnpublishedFixture([string]$Name){
 $fixture=New-LifecycleUnpublishedOriginalFixture $Name
 try{
  [IO.File]::SetAttributes($fixture.child,([IO.FileAttributes]$fixture.childEvidence.attributes-bor[IO.FileAttributes]::Hidden))
  $fixture.faultChildEvidence=Get-LifecycleFileEvidence $fixture.child
  Assert-Lifecycle ($fixture.faultChildEvidence.attributes-ne$fixture.childEvidence.attributes) 'Unpublished source fault did not change attributes'
  $first=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.firstStrongEvaluation=$first
  $fixture.request=Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.request.json')
  Assert-Lifecycle (Test-Path -LiteralPath $fixture.request) 'Unpublished source mismatch lost its candidate'
  $marker=[IO.File]::ReadAllText($fixture.request)|ConvertFrom-Json -AsHashtable -Depth 100
  Assert-Lifecycle ($marker.kind-ceq'original-reconcile-needed'-and$marker.operationId-ceq$fixture.id-and$marker.unpublishedControlName-ceq(Split-Path $fixture.control -Leaf)-and$marker.unpublishedControlIdentity-ceq[LifecycleE2ENative]::LifecycleIdentity($fixture.control)-and$marker.unpublishedOwnerIdentity-ceq[LifecycleE2ENative]::LifecycleIdentity($fixture.owner)-and$marker.unpublishedOwnerLength-eq$fixture.ownerEvidence.length-and$marker.unpublishedOwnerSha256-ceq$fixture.ownerEvidence.sha256.ToLowerInvariant()-and$marker.originalManifestIdentity-ceq[LifecycleE2ENative]::LifecycleIdentity($fixture.body)-and$marker.observedManifestLength-eq$fixture.bodyEvidence.length-and$marker.originalManifestSha256-ceq$fixture.ownerBody.bodySha256-and$marker.originalManifestLength-eq$fixture.ownerBody.bodyLength) 'Deferred unpublished marker lost its exact namespace/owner/body binding or expected publisher bytes'
  Assert-Lifecycle (!(Test-Path -LiteralPath $fixture.manifest)) 'Unpublished source mismatch promoted manifest authority'
  Assert-LifecycleOriginalEvidence $fixture.tree $fixture.treeEvidence;Assert-LifecycleFileEvidence $fixture.child $fixture.faultChildEvidence;Assert-LifecycleFileEvidence $fixture.body $fixture.bodyEvidence;Assert-LifecycleFileEvidence $fixture.owner $fixture.ownerEvidence
  $fixture.negativeMarker=$marker;$script:LifecycleEvidence.unpublishedNegativeMarker=$marker
  return $fixture
 }catch{if([IO.File]::Exists($fixture.child)){[IO.File]::SetAttributes($fixture.child,[IO.FileAttributes]$fixture.childEvidence.attributes)};throw}
}
function Assert-LifecycleOriginalClosed($Fixture){
 $closed=Join-Path $Fixture.scope.metadata '.closed-records-v1';$summary=Join-Path $closed ($Fixture.id+'.json');$done=Join-Path $closed ($Fixture.id+'.done.json')
 Assert-Lifecycle ((Test-Path -LiteralPath $summary)-and(Test-Path -LiteralPath $done)-and!(Test-Path -LiteralPath (Get-LifecycleOriginalRecord $Fixture))) 'Original-present operation did not finish metadata retirement'
 $document=[IO.File]::ReadAllText($summary)|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-Lifecycle ($document.terminalReason-ceq'original_present'-and(Get-Item -LiteralPath $summary).Length-lt65536) 'Original-present summary has wrong reason or retains large body'
 Assert-LifecycleOriginalEvidence $Fixture.tree $Fixture.treeEvidence;Assert-LifecycleOriginalEvidence $Fixture.child $Fixture.childEvidence;Assert-LifecycleOriginalEvidence $Fixture.sparse $Fixture.sparseEvidence $Fixture.prefix.Length
 $script:LifecycleEvidence.summary=$document
}
function Start-LifecycleProcess($Scope,[string[]]$Arguments){
 $values=@('--config',$Scope.config)+$Arguments
 foreach($value in @($ExecutablePath)+$values){if($value-match'[\s"&|<>^%!()]'){throw 'Unsafe CMD control argument'}}
 $info=[Diagnostics.ProcessStartInfo]::new('cmd.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8
 $info.Arguments='/d /c '+$ExecutablePath+' '+($values-join' ')
 $process=[Diagnostics.Process]::Start($info)
 return @{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync()}
}
function Finish-LifecycleProcess($Session){
 $process=$Session.process
 if(!$process.WaitForExit(240000)){$process.Kill($true);$process.WaitForExit();throw 'Boundary CLI timeout'}
 $text=$Session.stdout.GetAwaiter().GetResult();$json=$null;try{$json=$text|ConvertFrom-Json -AsHashtable -Depth 100}catch{}
 return @{exitCode=$process.ExitCode;json=$json;stdout=$text;stderr=$Session.stderr.GetAwaiter().GetResult()}
}
function Get-LifecycleFileEvidence([string]$Path){
 Assert-Lifecycle ([IO.File]::Exists($Path)) ('File evidence is missing: '+$Path)
 return @{identity=[LifecycleE2ENative]::Identity($Path);security=[LifecycleE2ENative]::Security($Path);attributes=[int][IO.File]::GetAttributes($Path);length=[IO.FileInfo]::new($Path).Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}
}
function Assert-LifecycleFileEvidence([string]$Path,$Expected){
 $actual=Get-LifecycleFileEvidence $Path
 foreach($field in @('identity','security','attributes','length','sha256')){Assert-Lifecycle ($actual[$field]-ceq$Expected[$field]) ('Native file evidence changed: '+$field+' '+$Path)}
}
function Move-LifecycleOwnEvidence([string]$Source,[string]$Destination,[string]$ScopeRoot){
 $sourcePath=[IO.Path]::GetFullPath($Source);$destinationPath=[IO.Path]::GetFullPath($Destination);$prefix=[IO.Path]::GetFullPath($ScopeRoot).TrimEnd([char]92)+'\'
 foreach($path in @($sourcePath,$destinationPath)){Assert-Lifecycle ($path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) 'Evidence move escaped its fixture';Assert-VerificationDestination $path @()}
 Assert-Lifecycle ([IO.File]::Exists($sourcePath)-and!(Test-Path -LiteralPath $destinationPath)) 'Evidence move requires a file and unused destination'
 $before=Get-LifecycleFileEvidence $sourcePath;[IO.File]::Move($sourcePath,$destinationPath,$false);Assert-LifecycleFileEvidence $destinationPath $before
}
function New-LifecycleMigrationPending([string]$Name){
 $attempts=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.boundaryAttempts=$attempts
 foreach($attempt in 1..3){
  $scope=New-LifecycleScope ($Name+'-'+$attempt);$file=Join-Path $scope.files 'a.bin';[IO.File]::WriteAllText($file,'migration-layout-original',$utf8);$original=Get-LifecycleFileEvidence $file
  $id=Invoke-LifecycleDelete $scope @($file);$legacy=Join-Path $scope.metadata $id;$typedRoot=Join-Path $scope.metadata '.recycle-records-v1';$record=Join-Path $typedRoot $id;$intent=Join-Path $typedRoot ($id+'.intent.json');$formal=Join-Path $record 'record-layout.json'
  $recordIdentity=[LifecycleE2ENative]::Identity($legacy);$originalHashes=Get-LifecycleMetadataHashes $legacy;$originalFiles=@{}
  foreach($member in Get-ChildItem -LiteralPath $legacy -File){$originalFiles[$member.Name]=Get-LifecycleFileEvidence $member.FullName}
  $receipt=[IO.File]::ReadAllText((Join-Path $legacy 'recycle-0000-complete.json'))|ConvertFrom-Json -AsHashtable -Depth 100;$payload=$receipt.physicalPath;$payloadEvidence=Get-LifecycleFileEvidence $payload
  $held=[LifecycleE2ENative]::HoldDirectory($legacy)
  try{$prepared=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply')}finally{$held.Dispose()}
  Assert-Lifecycle ((Test-Path -LiteralPath $intent)-and(Test-Path -LiteralPath $legacy)-and!(Test-Path -LiteralPath $record)) 'Failed to retain a real pre-move migration intent'
  $plan=[IO.File]::ReadAllText($intent)|ConvertFrom-Json -AsHashtable -Depth 100
  Assert-Lifecycle ($plan.action-ceq'migrate'-and$plan.operationId-ceq$id-and$plan.recordLayoutName-ceq'record-layout.json'-and$plan.recordLayoutPendingName-cmatch'^record-layout[.]json[.]pending-[0-9a-f]{32}$'-and$plan.recordLayoutLength-gt0-and$plan.recordLayoutSha256-cmatch'^[a-f0-9]{64}$') 'Migration intent lacks its exact durable layout publication plan'
  $gate=[LifecycleBoundaryGate]::new($scope.metadata,$record,'layout','',$ExecutablePath);$session=$null;$observed=$false;$response=$null
  try{
   $session=Start-LifecycleProcess $scope @('maintain','--apply');$gate.Bind($session.process)
   $observed=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $gate.ObservedPath)-and!(Test-Path -LiteralPath $formal)
   if($observed){
    Assert-Lifecycle (!(Test-Path -LiteralPath $legacy)-and[LifecycleE2ENative]::Identity($record)-ceq$recordIdentity-and[IO.Path]::GetFileName($gate.ObservedPath)-ceq$plan.recordLayoutPendingName) 'Observed layout boundary did not use the real migration intent and moved directory'
    [IO.File]::WriteAllBytes($formal,[byte[]]@());$blocker=Get-LifecycleFileEvidence $formal
   }
   $gate.Resume();$response=Finish-LifecycleProcess $session
   $attempts.Add(@{attempt=$attempt;scope=$scope.root;boundaryObserved=$observed;ownedProcessId=$gate.OwnedProcessId;suspendStatus=$gate.SuspendStatus;gateError=$gate.Error;response=$response})
  }finally{
   if($session){if(!$session.process.HasExited){$gate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()};$gate.Dispose()
  }
  if(!$observed){
   $restore=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$id);Assert-Lifecycle ($restore.exitCode-eq0) 'Missed boundary fixture could not restore its isolated payload';Assert-LifecycleFileEvidence $file $original
   continue
  }
  $pending=Join-Path $record $plan.recordLayoutPendingName
  Assert-Lifecycle ((Test-Path -LiteralPath $intent)-and(Test-Path -LiteralPath $pending)-and(Test-Path -LiteralPath $formal)) 'Real interrupted layout publication did not retain intent, pending and conflict evidence'
  Assert-LifecycleFileEvidence $formal $blocker
  Assert-Lifecycle ((Get-Item -LiteralPath $pending).Length-eq$plan.recordLayoutLength-and(Get-FileHash -LiteralPath $pending).Hash.ToLowerInvariant()-ceq$plan.recordLayoutSha256) 'Observed pending was not a fully flushed product-generated planned layout'
  $layout=[IO.File]::ReadAllText($pending)|ConvertFrom-Json -AsHashtable -Depth 100
  Assert-Lifecycle ($layout.kind-ceq'recycle'-and$layout.operationId-ceq$id) 'Product pending layout did not bind this operation'
  Move-LifecycleOwnEvidence $formal (Join-Path $scope.root 'held-formal.bin') $scope.root
  Assert-Lifecycle (!(Test-Path -LiteralPath $formal)-and!(Test-Path -LiteralPath $file)) 'Formal conflict fixture did not leave the real pre-publication migration boundary'
  Assert-LifecycleFileEvidence $payload $payloadEvidence
  $script:LifecycleEvidence.fixture=@{scope=$scope.root;configPath=$scope.config;operationId=$id;record=$record;intent=$intent;pending=$pending;payload=$payload}
  return @{scope=$scope;id=$id;file=$file;original=$original;payload=$payload;payloadEvidence=$payloadEvidence;record=$record;recordIdentity=$recordIdentity;originalHashes=$originalHashes;originalFiles=$originalFiles;intent=$intent;plan=$plan;pending=$pending;formal=$formal;falseFormal=(Join-Path $scope.root 'held-formal.bin')}
 }
 throw 'The actual layout publication boundary was not observed in three fresh fixtures; no crash-boundary success is claimed.'
}
function Assert-LifecycleMigrationResumed($Fixture){
 $pendingId=[LifecycleE2ENative]::Identity($Fixture.pending)
 $r=Invoke-LifecycleCli $ExecutablePath $Fixture.scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0-and(Test-Path -LiteralPath $Fixture.formal)-and!(Test-Path -LiteralPath $Fixture.pending)-and!(Test-Path -LiteralPath $Fixture.intent)) ('Real layout pending could not resume: '+$r.stdout+$r.stderr)
 Assert-Lifecycle ([LifecycleE2ENative]::Identity($Fixture.formal)-ceq$pendingId-and[LifecycleE2ENative]::Identity($Fixture.record)-ceq$Fixture.recordIdentity-and(Get-FileHash -LiteralPath $Fixture.formal).Hash.ToLowerInvariant()-ceq$Fixture.plan.recordLayoutSha256) 'Layout repair replaced its opened pending object or changed the planned bytes'
 foreach($name in $Fixture.originalFiles.Keys){Assert-LifecycleFileEvidence (Join-Path $Fixture.record $name) $Fixture.originalFiles[$name]}
 $restore=Invoke-LifecycleCli $ExecutablePath $Fixture.scope.config @('restore',$Fixture.id)
 Assert-Lifecycle ($restore.exitCode-eq0-and$restore.json.items.Count-eq1-and$restore.json.items[0].status-eq'restored') 'Repaired migration did not reach normal CLI restoration'
 Assert-LifecycleFileEvidence $Fixture.file $Fixture.original
 Assert-Lifecycle (!(Test-Path -LiteralPath $Fixture.payload)-and!(Test-Path -LiteralPath $Fixture.record)) 'Repaired migration retained a consumed bin payload or active terminal record'
}
function Invoke-LifecycleMcpAbsent($Scope,[string[]]$Paths){
 $values=@('--config',$Scope.config,'mcp');foreach($value in @($ExecutablePath)+$values){if($value-match'[\s"&|<>^%!()]'){throw 'Unsafe MCP CMD control argument'}}
 $info=[Diagnostics.ProcessStartInfo]::new('cmd.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=$utf8;$info.StandardErrorEncoding=$utf8;$info.Arguments='/d /c '+$ExecutablePath+' '+($values-join' ')
 $process=[Diagnostics.Process]::Start($info);$errors=$process.StandardError.ReadToEndAsync();$transcript=[Collections.Generic.List[object]]::new()
 try{
  foreach($request in @(@{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2025-11-25';capabilities=@{};clientInfo=@{name='absent-lifecycle-e2e';version='1'}}},@{jsonrpc='2.0';id=2;method='tools/call';params=@{name='delete_files';arguments=@{paths=$Paths}}})){
   if($request.id-eq2){$process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')}
   $process.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 20 -Compress));$process.StandardInput.Flush();$matched=$null
   foreach($lineIndex in 1..64){$read=$process.StandardOutput.ReadLineAsync();if(!$read.Wait(30000)){throw 'Absent MCP response timeout'};$line=$read.GetAwaiter().GetResult();if(!$line){throw 'Absent MCP closed stdout'};$reply=$line|ConvertFrom-Json -AsHashtable -Depth 100;$transcript.Add($reply);if($reply.id-eq$request.id){$matched=$reply;break}}
   Assert-Lifecycle ($null-ne$matched-and!$matched.error) 'Absent MCP did not return its matching RPC response'
   if($request.id-eq1){Assert-Lifecycle ($matched.result.protocolVersion-ceq'2025-11-25') 'Absent MCP initialization changed protocol'}
   else{Assert-Lifecycle (!$matched.result.isError-and$matched.result.structuredContent) 'Absent MCP delete failed';$result=$matched.result.structuredContent}
  }
  $process.StandardInput.Close();if(!$process.WaitForExit(30000)){$process.Kill($true);$process.WaitForExit();throw 'Absent MCP did not complete after EOF'}
  Assert-Lifecycle ($process.ExitCode-eq0) ('Absent MCP process failed: '+$errors.GetAwaiter().GetResult())
  $script:LifecycleEvidence.mcpTranscript=@($transcript);return $result
 }finally{if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
}
function Assert-LifecycleAbsentHint($Scope,[string]$Id){
 $root=Join-Path $Scope.metadata '.closed-records-v1';$path=Join-Path $root ($Id+'.request.json')
 Assert-Lifecycle (Test-Path -LiteralPath $path) 'All-absent delete did not persist its bounded retirement candidate'
 $hint=[IO.File]::ReadAllText($path)|ConvertFrom-Json -AsHashtable -Depth 100;$layout=[IO.File]::ReadAllText((Join-Path $root 'layout.json'))|ConvertFrom-Json -AsHashtable -Depth 100
 Assert-Lifecycle ($hint.kind-ceq'retire-absent-request'-and$hint.operationId-ceq$Id-and$hint.requiredFinalReceiptName-ceq'recycle-manifest.json'-and$hint.metadataRootIdentity-ceq$layout.metadataRootIdentity-and$hint.nonce-ceq$layout.nonce-and$hint.machineName-ceq$layout.machineName-and$hint.ownerSid-ceq$layout.ownerSid) 'All-absent retirement candidate lost its kind, final-manifest requirement or root binding'
 return $path
}
function Assert-LifecycleAbsentResult($Result,[string[]]$Paths){
 Assert-Lifecycle ($Result.operationId-cmatch'^[a-f0-9]{32}$'-and@($Result.items).Count-eq$Paths.Count) 'All-absent response changed operation identity or input count'
 for($index=0;$index-lt$Paths.Count;$index++){Assert-Lifecycle ($Result.items[$index].path-ceq$Paths[$index]-and$Result.items[$index].status-ceq'already_absent'-and!(Test-Path -LiteralPath $Paths[$index])) 'All-absent response changed input order/status or created an original'}
}
function Expire-LifecycleAbsentSummary($Scope,[string]$Id){
 $root=Join-Path $Scope.metadata '.closed-records-v1';$summaryPath=Join-Path $root ($Id+'.json');$donePath=Join-Path $root ($Id+'.done.json')
 $config=[IO.File]::ReadAllText($Scope.config)|ConvertFrom-Json -AsHashtable;$past=[Text.Json.JsonSerializer]::Serialize[DateTimeOffset]([DateTimeOffset]::UtcNow.AddDays(-([int]$config.retentionDays+1)))
 $summary=[IO.File]::ReadAllText($summaryPath);$summary=[regex]::Replace($summary,'("closedUtc"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+$past});[IO.File]::WriteAllText($summaryPath,$summary,$utf8)
 $digest=(Get-FileHash -LiteralPath $summaryPath).Hash.ToLowerInvariant();$done=[IO.File]::ReadAllText($donePath);$done=[regex]::Replace($done,'("summarySha256"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+'"'+$digest+'"'});[IO.File]::WriteAllText($donePath,$done,$utf8)
}
function New-LifecyclePendingCleanup([string]$Name){
 $scope=New-LifecycleScope $Name;$file=Join-Path $scope.files 'source.txt';[IO.File]::WriteAllText($file,'original-retirement-payload',$utf8)
 $id=Invoke-LifecycleDelete $scope @($file)
 $migrate=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-Lifecycle ($migrate.exitCode-eq0) 'Pending-case migration failed'
 $record=Join-Path (Join-Path $scope.metadata '.recycle-records-v1') $id
 $held=[IO.File]::Open((Join-Path $record 'recycle-manifest.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{
  $restored=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$id)
  [IO.File]::WriteAllText((Join-Path $scope.root 'blocked-cleanup-restore-response.json'),($restored.json|ConvertTo-Json -Depth 100),$utf8)
  Assert-Lifecycle ($restored.exitCode-eq0-and$restored.json.items.Count-eq1-and$restored.json.items[0].status-eq'restored') 'Cleanup sharing failure changed successful restoration into failure'
 }finally{$held.Dispose()}
 $closed=Join-Path $scope.metadata '.closed-records-v1';$summary=Join-Path $closed ($id+'.json');$done=Join-Path $closed ($id+'.done.json')
 Assert-Lifecycle ((Test-Path -LiteralPath $summary)-and!(Test-Path -LiteralPath $done)-and(Test-Path -LiteralPath $record)) 'Sharing fault did not preserve a committed pending cleanup'
 Assert-Lifecycle ([IO.File]::ReadAllText($file)-ceq'original-retirement-payload') 'Sharing fault lost original restored data'
 return @{scope=$scope;id=$id;file=$file;record=$record;summary=$summary;done=$done;closed=$closed}
}
function New-LifecycleProvisionFixture([string]$Name){
 $scope=New-LifecycleScope $Name;$file=Join-Path $scope.files 'source.txt';[IO.File]::WriteAllText($file,'root-provision-payload',$utf8)
 $id=Invoke-LifecycleDelete $scope @($file)
 $migrate=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-Lifecycle ($migrate.exitCode-eq0) 'Provision fixture migration failed'
 $restore=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$id);Assert-Lifecycle ($restore.exitCode-eq0) 'Provision fixture restoration failed'
 $kind='.recycle-records-v1';$root=Join-Path $scope.metadata $kind;$markerPath=Join-Path $root 'layout.json'
 Assert-Lifecycle (@([IO.Directory]::EnumerateFileSystemEntries($root)).Count-eq1) 'Provision fixture requires an empty completed typed root'
 $marker=[IO.File]::ReadAllText($markerPath)|ConvertFrom-Json -AsHashtable;$markerAcl=Get-Acl -LiteralPath $markerPath
 $stageName=$kind+'.stage-'+$marker.nonce;$stage=Join-Path $scope.metadata $stageName;$identity=[LifecycleE2ENative]::Identity($root)
 [IO.Directory]::Move($root,$stage)
 $intentPath=Join-Path $scope.metadata ($kind+'.create.json')
 $intent=[ordered]@{schema=1;rootKind=$kind;stageName=$stageName;nonce=$marker.nonce;metadataRootIdentity=$marker.metadataRootIdentity;machineName=$marker.machineName;ownerSid=$marker.ownerSid}
 [IO.File]::WriteAllText($intentPath,($intent|ConvertTo-Json -Depth 10),$utf8);Set-Acl -LiteralPath $intentPath -AclObject $markerAcl
 return @{scope=$scope;root=$root;stage=$stage;intent=$intentPath;identity=$identity;file=$file}
}
$large=New-LifecycleScope 'large-active-recycle'
$tree=Join-Path $large.files 'tree';[LifecycleE2ENative]::CreateTree($tree,$FileCount)
$identity=[LifecycleE2ENative]::Identity($tree);$acl=(Get-Acl -LiteralPath $tree).Sddl
$operation=Invoke-LifecycleDelete $large @($tree)
$oldRecord=Join-Path $large.metadata $operation;$typedRecord=Join-Path (Join-Path $large.metadata '.recycle-records-v1') $operation
$originalHashes=Get-LifecycleMetadataHashes $oldRecord
$recordIdentity=[LifecycleE2ENative]::Identity($oldRecord)
Test-LifecycleCase 'legacy-recycle-dry-run-does-not-migrate' {
 $r=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--dry-run')
 Assert-Lifecycle ($r.exitCode-eq0) ('Dry-run failed: '+$r.stderr+$r.stdout)
 Assert-Lifecycle ((Test-Path -LiteralPath $oldRecord)-and!(Test-Path -LiteralPath $typedRecord)) 'Dry-run moved the operation'
 Assert-Lifecycle ((Get-LifecycleMetadataHashes $oldRecord)-ceq$originalHashes) 'Dry-run changed record bytes'
}
Test-LifecycleCase 'legacy-recycle-migrates-with-identical-bytes' {
 $r=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0) ('Migration failed: '+$r.stderr+$r.stdout)
 Assert-Lifecycle (!(Test-Path -LiteralPath $oldRecord)-and(Test-Path -LiteralPath $typedRecord)) 'Typed migration did not finish'
 Assert-Lifecycle ([LifecycleE2ENative]::Identity($typedRecord)-ceq$recordIdentity) 'Migration replaced the operation directory instead of moving it'
 Assert-Lifecycle ((Get-LifecycleMetadataHashes $typedRecord -ExcludeNewRecordLayout)-ceq$originalHashes) 'Migration changed original metadata bytes'
 Assert-Lifecycle (!(Test-Path -LiteralPath $tree)) 'Migration restored a Windows-managed payload'
}
Test-LifecycleCase 'typed-migration-is-idempotent-and-remains-listed' {
 $before=Get-LifecycleMetadataHashes $typedRecord
 $r=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0) 'Second maintenance failed'
 Assert-Lifecycle ((Get-LifecycleMetadataHashes $typedRecord)-ceq$before) 'Second maintenance rewrote active metadata'
 $list=Invoke-LifecycleCli $ExecutablePath $large.config @('operations')
 Assert-Lifecycle (@($list.json.operations|Where-Object {$_.operationId-ceq$operation}).Count-eq1) 'Migrated operation is missing or duplicated in CLI list'
}
Test-LifecycleCase 'light-budget-scan-and-full-body-audit-are-distinct' {
 $manifest=Join-Path $typedRecord 'recycle-manifest.json';$original=[IO.File]::ReadAllBytes($manifest)
 try{
  $invalid=[byte[]]::new($original.Length);[Array]::Fill[byte]($invalid,32);$invalid[0]=123
  [IO.File]::WriteAllBytes($manifest,$invalid)
  $light=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--dry-run')
  Assert-Lifecycle ($light.exitCode-eq0-and$light.json.capacityKnown) 'Light budget scan parsed a schema 6 body'
   $lightApply=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--apply')
   Assert-Lifecycle ($lightApply.exitCode-eq0-and$lightApply.json.capacityKnown-eq$true-and$lightApply.json.recordAuditRequested-eq$false) 'Ordinary apply maintenance reread an active schema 6 body without a retirement candidate'
  $deep=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--dry-run','--audit-records')
  Assert-Lifecycle ($deep.json.recordAuditRequested-eq$true-and$deep.json.recordAuditScope-ceq'recycle-record-body-and-layout'-and$deep.json.recordAuditComplete-eq$false-and$deep.json.warnings.Count-gt0) 'Explicit full audit did not report the corrupted body through its audit result'
  $restore=Invoke-LifecycleCli $ExecutablePath $large.config @('restore',$operation)
  Assert-Lifecycle ($restore.exitCode-ne0-and!(Test-Path -LiteralPath $tree)) 'Restore did not reject invalid metadata before touching the source'
 }finally{[IO.File]::WriteAllBytes($manifest,$original)}
}
Test-LifecycleCase 'typed-layout-unknown-payload-is-not-excluded' {
 $unknown=Join-Path $typedRecord 'unknown-payload.bin';[IO.File]::WriteAllText($unknown,'retained-unknown')
 $r=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--dry-run')
 Assert-Lifecycle ($r.exitCode-ne0-or!$r.json.capacityKnown) 'Unknown typed member was treated as safe zero capacity'
 Assert-Lifecycle ([IO.File]::ReadAllText($unknown)-ceq'retained-unknown') 'Unknown member was changed'
 # 自作の注入物を移動して証拠を残す。実データは削除しない。
 Move-Item -LiteralPath $unknown -Destination (Join-Path $large.root 'retained-unknown-payload.bin')
}
Test-LifecycleCase 'typed-record-marker-corruption-is-not-repaired-or-ignored' {
 $marker=Join-Path $typedRecord 'record-layout.json';$original=[IO.File]::ReadAllBytes($marker)
 try{
  $bad=[Text.Encoding]::UTF8.GetBytes('{"schema":999}');[IO.File]::WriteAllBytes($marker,$bad)
  $r=Invoke-LifecycleCli $ExecutablePath $large.config @('maintain','--apply')
  Assert-Lifecycle ($r.exitCode-ne0-or!$r.json.capacityKnown) 'Malformed record marker was accepted'
  Assert-Lifecycle ((Get-FileHash -LiteralPath $marker).Hash-ceq[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bad))) 'Malformed marker was overwritten'
  Assert-Lifecycle (!(Test-Path -LiteralPath $tree)) 'Malformed marker triggered payload mutation'
 }finally{[IO.File]::WriteAllBytes($marker,$original)}
}
Test-LifecycleCase 'migrated-record-restores-with-id-acl-content-preserved' {
 $r=Invoke-LifecycleCli $ExecutablePath $large.config @('restore',$operation)
 Assert-Lifecycle ($r.exitCode-eq0-and$r.json.items.Count-eq1-and$r.json.items[0].status-eq'restored') ('Restore failed: '+$r.stderr+$r.stdout)
 Assert-Lifecycle ([LifecycleE2ENative]::Identity($tree)-ceq$identity) 'Root file ID changed'
 Assert-Lifecycle ((Get-Acl -LiteralPath $tree).Sddl-ceq$acl) 'Root ACL changed'
 Assert-Lifecycle (@([IO.Directory]::EnumerateFiles($tree)).Count-eq$FileCount) 'Tree file count changed'
 foreach($index in @(0,[int]($FileCount/2),($FileCount-1))){Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $tree ('file-{0:D6}.txt'-f$index)))-ceq('lifecycle-'+$index)) 'Restored content changed'}
}
Test-LifecycleCase 'completed-recycle-has-finite-summary-and-no-large-original' {
 $summary=Join-Path (Join-Path $large.metadata '.closed-records-v1') ($operation+'.json')
 Assert-Lifecycle (Test-Path -LiteralPath $summary) 'Closed summary absent after successful restore'
 Assert-Lifecycle (!(Test-Path -LiteralPath $typedRecord)) 'Large completed record was left active'
 Assert-Lifecycle ((Get-Item -LiteralPath $summary).Length-lt65536) 'Closed summary retained the large security map'
 $before=Get-LifecycleMetadataHashes $tree;$closedIdentity=[LifecycleE2ENative]::Identity($tree);$closedAcl=(Get-Acl -LiteralPath $tree).Sddl
 $userFile=Join-Path $tree 'file-000000.txt';[IO.File]::SetAttributes($userFile,[IO.FileAttributes]::ReadOnly);$closedAttributes=[IO.File]::GetAttributes($userFile)
 $r=Invoke-LifecycleCli $ExecutablePath $large.config @('restore',$operation)
 Assert-Lifecycle ($r.exitCode-eq0-and$r.json.lifecycleState-eq'closed'-and$r.json.originalSchema-eq6-and$r.json.items.Count-eq1-and$r.json.items[0].status-eq'closed') 'Closed restore did not explicitly report the closed target'
 Assert-Lifecycle ((Get-LifecycleMetadataHashes $tree)-ceq$before) 'Closed restore changed existing files'
 Assert-Lifecycle ([LifecycleE2ENative]::Identity($tree)-ceq$closedIdentity-and(Get-Acl -LiteralPath $tree).Sddl-ceq$closedAcl-and[IO.File]::GetAttributes($userFile)-eq$closedAttributes) 'Closed restore changed existing identity, ACL or user-modified attributes'
}
Test-LifecycleCase 'cleanup-sharing-interruption-resumes-without-rewriting-commit' {
 $pending=New-LifecyclePendingCleanup 'sharing-resume';$commit=(Get-FileHash -LiteralPath $pending.summary).Hash
 $r=Invoke-LifecycleCli $ExecutablePath $pending.scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0-and(Test-Path -LiteralPath $pending.done)-and!(Test-Path -LiteralPath $pending.record)) ('Pending cleanup did not resume: '+$r.stderr+$r.stdout)
 Assert-Lifecycle ((Get-FileHash -LiteralPath $pending.summary).Hash-ceq$commit) 'Resumed cleanup rewrote its committed summary'
 Assert-Lifecycle ([IO.File]::ReadAllText($pending.file)-ceq'original-retirement-payload') 'Resumed cleanup changed restored data'
}
Test-LifecycleCase 'pending-cleanup-changed-member-prevents-all-deletion' {
 $pending=New-LifecyclePendingCleanup 'changed-pending-member'
 $intent=[IO.File]::ReadAllText((Join-Path $pending.closed ($pending.id+'.intent.json')))|ConvertFrom-Json -AsHashtable -Depth 100
 $members=@($intent.files|Where-Object name -ne 'operation.lock');Assert-Lifecycle ($members.Count-ge3) 'All-preflight fixture requires earlier valid members'
 $target=Join-Path $pending.record $members[-1].name;$original=[IO.File]::ReadAllBytes($target)
 try{
  [IO.File]::WriteAllText($target,'changed-after-retirement-commit',$utf8)
  $before=Get-LifecycleMetadataHashes $pending.record
  $r=Invoke-LifecycleCli $ExecutablePath $pending.scope.config @('maintain','--apply')
  Assert-Lifecycle ($r.exitCode-ne0-or$r.json.warnings.Count-gt0) 'Changed pending member was accepted'
  Assert-Lifecycle (!(Test-Path -LiteralPath $pending.done)) 'Changed member cleanup was marked complete'
  Assert-Lifecycle ((Get-LifecycleMetadataHashes $pending.record)-ceq$before) 'Cleanup deleted other members before detecting the changed member'
 }finally{[IO.File]::WriteAllBytes($target,$original)}
 $r=Invoke-LifecycleCli $ExecutablePath $pending.scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0-and(Test-Path -LiteralPath $pending.done)-and!(Test-Path -LiteralPath $pending.record)) 'Restored pending evidence could not be reconciled'
 Assert-Lifecycle ([IO.File]::ReadAllText($pending.file)-ceq'original-retirement-payload') 'Pending evidence reconciliation changed source data'
}
Test-LifecycleCase 'only-cleaned-closed-summary-expires-automatically' {
 $pending=New-LifecyclePendingCleanup 'closed-expiry'
 # 同じexeが生成した隔離済み完了記録だけを過去時刻のfixtureにする。実機の時計は変更しない。
 $summaryText=[IO.File]::ReadAllText($pending.summary)
 $config=[IO.File]::ReadAllText($pending.scope.config)|ConvertFrom-Json -AsHashtable
 $pastJson=[Text.Json.JsonSerializer]::Serialize[DateTimeOffset]([DateTimeOffset]::UtcNow.AddDays(-([int]$config.retentionDays+1)))
 $intentPath=Join-Path $pending.closed ($pending.id+'.intent.json')
 if(Test-Path -LiteralPath $intentPath){
  $intentText=[IO.File]::ReadAllText($intentPath)
  $intentText=[regex]::Replace($intentText,'("closedUtc"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+$pastJson})
  [IO.File]::WriteAllText($intentPath,$intentText,$utf8)
  $digest=(Get-FileHash -LiteralPath $intentPath).Hash.ToLowerInvariant()
  $summaryText=[regex]::Replace($summaryText,'("intentSha256"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+'"'+$digest+'"'})
 }
 $summaryText=[regex]::Replace($summaryText,'("closedUtc"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+$pastJson})
 [IO.File]::WriteAllText($pending.summary,$summaryText,$utf8)
 $held=[IO.File]::Open((Join-Path $pending.record 'recycle-manifest.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{
  $blocked=Invoke-LifecycleCli $ExecutablePath $pending.scope.config @('maintain','--apply')
  Assert-Lifecycle ((Test-Path -LiteralPath $pending.summary)-and(Test-Path -LiteralPath $intentPath)-and(Test-Path -LiteralPath $pending.record)-and!(Test-Path -LiteralPath $pending.done)) 'Retention expiry removed the only evidence for unfinished cleanup'
 }finally{$held.Dispose()}
 $r=Invoke-LifecycleCli $ExecutablePath $pending.scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0) ('Closed expiry failed: '+$r.stderr+$r.stdout)
 Assert-Lifecycle (!(Test-Path -LiteralPath $pending.summary)-and!(Test-Path -LiteralPath $pending.done)) 'Expired closed summary was retained indefinitely'
 Assert-Lifecycle (@(Get-ChildItem -LiteralPath $pending.closed -Filter ($pending.id+'*')).Count-eq0) 'Expiry left orphan lifecycle control records'
 $restore=Invoke-LifecycleCli $ExecutablePath $pending.scope.config @('restore',$pending.id)
 Assert-Lifecycle ($restore.exitCode-ne0-and[IO.File]::ReadAllText($pending.file)-ceq'original-retirement-payload') 'Expired operation changed original data or guessed a legacy record'
}
Test-LifecycleCase 'unknown-layout-root-is-preserved' {
 $scope=New-LifecycleScope 'unknown-layout-root';$root=Join-Path $scope.metadata '.recycle-records-v1'
 $null=[IO.Directory]::CreateDirectory($root);$unknown=Join-Path $root 'unknown-evidence.bin';[IO.File]::WriteAllText($unknown,'retain-unknown-evidence',$utf8)
 $before=Get-LifecycleMetadataHashes $root
 $r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-ne0-or$r.json.warnings.Count-gt0) 'Unknown layout root was silently accepted'
 Assert-Lifecycle ((Get-LifecycleMetadataHashes $root)-ceq$before) 'Unknown layout was overwritten or removed'
}
Test-LifecycleCase 'interrupted-advisory-outcomes-do-not-block-safe-restoration-or-retirement' {
 $scope=New-LifecycleScope 'interrupted-advisory-outcomes';$file=Join-Path $scope.files 'source.txt';[IO.File]::WriteAllText($file,'advisory-original-data',$utf8)
 $id=Invoke-LifecycleDelete $scope @($file);$migrated=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-Lifecycle ($migrated.exitCode-eq0) 'Advisory fixture migration failed'
 $record=Join-Path (Join-Path $scope.metadata '.recycle-records-v1') $id
 [IO.File]::WriteAllBytes((Join-Path $record 'delete-result.json'),[byte[]]::new(0))
 [IO.File]::WriteAllText((Join-Path $record ('restore-result-'+[guid]::NewGuid().ToString('N')+'.json')),'{',$utf8)
 $light=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--dry-run')
 Assert-Lifecycle ($light.exitCode-eq0-and$light.json.capacityKnown) 'Interrupted advisory outcome made recovery capacity unknown'
 $restored=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$id)
 Assert-Lifecycle ($restored.exitCode-eq0-and$restored.json.items[0].status-eq'restored'-and[IO.File]::ReadAllText($file)-ceq'advisory-original-data') 'Advisory outcome replaced authoritative receipts or blocked restoration'
 Assert-Lifecycle (!(Test-Path -LiteralPath $record)-and(Test-Path -LiteralPath (Join-Path (Join-Path $scope.metadata '.closed-records-v1') ($id+'.done.json')))) 'Interrupted advisory outcome could not be collected after receipt-proven completion'
 Assert-Lifecycle (@(Get-ChildItem -LiteralPath $scope.metadata -Filter 'recycle-pending-*').Count-eq0) 'Outcome publisher left an unowned flat pending record'
}
Test-LifecycleCase 'migration-directory-sharing-interruption-resumes' {
 $scope=New-LifecycleScope 'migration-sharing';$file=Join-Path $scope.files 'source.txt';[IO.File]::WriteAllText($file,'migration-sharing-data',$utf8)
 $id=Invoke-LifecycleDelete $scope @($file);$legacy=Join-Path $scope.metadata $id;$typed=Join-Path (Join-Path $scope.metadata '.recycle-records-v1') $id
 $before=Get-LifecycleMetadataHashes $legacy;$directoryId=[LifecycleE2ENative]::Identity($legacy)
 $held=[LifecycleE2ENative]::HoldDirectory($legacy)
 try{
  $r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply')
  Assert-Lifecycle ((Test-Path -LiteralPath $legacy)-and!(Test-Path -LiteralPath $typed)) 'Migration ignored a directory sharing conflict'
  Assert-Lifecycle ((Get-LifecycleMetadataHashes $legacy -ExcludeNewRecordLayout)-ceq$before) 'Interrupted migration changed original evidence'
 }finally{$held.Dispose()}
 $r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0-and!(Test-Path -LiteralPath $legacy)-and(Test-Path -LiteralPath $typed)) 'Interrupted migration could not resume'
 Assert-Lifecycle ([LifecycleE2ENative]::Identity($typed)-ceq$directoryId-and(Get-LifecycleMetadataHashes $typed -ExcludeNewRecordLayout)-ceq$before) 'Resumed migration changed record identity or original bytes'
 $r=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$id)
 Assert-Lifecycle ($r.exitCode-eq0-and[IO.File]::ReadAllText($file)-ceq'migration-sharing-data') 'Resumed migration lost restoration'
}
Test-LifecycleCase 'completed-root-stage-publication-resumes' {
 $fixture=New-LifecycleProvisionFixture 'root-complete-stage'
 $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0-and(Test-Path -LiteralPath $fixture.root)-and!(Test-Path -LiteralPath $fixture.stage)-and!(Test-Path -LiteralPath $fixture.intent)) 'Completed root stage did not resume publication'
 Assert-Lifecycle ([LifecycleE2ENative]::Identity($fixture.root)-ceq$fixture.identity-and[IO.File]::ReadAllText($fixture.file)-ceq'root-provision-payload') 'Root publication replaced identity or changed restored data'
}
Test-LifecycleCase 'reserved-empty-root-stage-recovers' {
 $fixture=New-LifecycleProvisionFixture 'root-empty-stage'
 [IO.File]::Move((Join-Path $fixture.stage 'layout.json'),(Join-Path $fixture.scope.root 'saved-layout-evidence.json'))
 $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply')
 Assert-Lifecycle ($r.exitCode-eq0-and(Test-Path -LiteralPath (Join-Path $fixture.root 'layout.json'))-and!(Test-Path -LiteralPath $fixture.stage)-and!(Test-Path -LiteralPath $fixture.intent)) 'Reserved empty root stage could not recover'
 Assert-Lifecycle ([IO.File]::ReadAllText($fixture.file)-ceq'root-provision-payload') 'Empty stage recovery changed original data'
}
Test-LifecycleCase 'unknown-child-in-reserved-root-stage-is-preserved-without-proliferation' {
 $fixture=New-LifecycleProvisionFixture 'root-unknown-stage';$unknown=Join-Path $fixture.stage 'unknown-evidence.bin';[IO.File]::WriteAllText($unknown,'retain-stage-evidence',$utf8)
 $before=Get-LifecycleMetadataHashes $fixture.scope.metadata;$namespaceBefore=Get-LifecycleNamespace $fixture.scope.metadata
 foreach($iteration in 1..2){
  $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply')
  Assert-Lifecycle ($r.exitCode-ne0-or$r.json.warnings.Count-gt0) 'Unknown stage contents were silently accepted'
  Assert-Lifecycle (!(Test-Path -LiteralPath $fixture.root)-and(Test-Path -LiteralPath $fixture.intent)-and(Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before) 'Unknown stage contents were removed, changed or multiplied'
  Assert-Lifecycle ((Get-LifecycleNamespace $fixture.scope.metadata)-ceq$namespaceBefore) 'Unknown stage contents caused empty directory proliferation'
 }
}
Test-LifecycleCase 'uncommitted-first-root-intent-is-preserved-without-proliferation' {
 $scope=New-LifecycleScope 'root-first-pending'
 $ready=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-Lifecycle ($ready.exitCode-eq0) 'Initial pending fixture initialization failed'
 $typedRoot=Join-Path $scope.metadata '.recycle-records-v1'
 Assert-Lifecycle (@([IO.Directory]::EnumerateFileSystemEntries($typedRoot)).Count-eq1) 'Initial pending fixture requires an empty completed typed root'
 [IO.Directory]::Move($typedRoot,(Join-Path $scope.root 'saved-root-evidence'))
 $pendingPath=Join-Path $scope.metadata ('.recycle-records-v1.create.json.pending-'+[guid]::NewGuid().ToString('N'))
 [IO.File]::WriteAllText($pendingPath,'{"incomplete":',$utf8);$before=Get-LifecycleMetadataHashes $scope.metadata;$namespaceBefore=Get-LifecycleNamespace $scope.metadata
 foreach($iteration in 1..2){
  $r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply')
  Assert-Lifecycle ($r.exitCode-ne0-or$r.json.warnings.Count-gt0) 'Unknown initial pending evidence was silently accepted'
  Assert-Lifecycle ((Get-LifecycleMetadataHashes $scope.metadata)-ceq$before-and!(Test-Path -LiteralPath (Join-Path $scope.metadata '.recycle-records-v1'))) 'Unknown initial pending evidence was deleted or new stages proliferated'
  Assert-Lifecycle ((Get-LifecycleNamespace $scope.metadata)-ceq$namespaceBefore) 'Unknown initial pending evidence caused empty directory proliferation'
 }
}
Test-LifecycleCase 'unpublished-empty-operation-stage-is-collected-but-unknown-child-is-retained' {
 $fixture=New-LifecycleProvisionFixture 'unpublished-operation-stage'
 $ready=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');Assert-Lifecycle ($ready.exitCode-eq0) 'Operation stage fixture root did not resume'
 $rootAcl=Get-Acl -LiteralPath $fixture.root
 $empty=Join-Path $fixture.root ('.operation-stage-'+[guid]::NewGuid().ToString('N')+'-'+[guid]::NewGuid().ToString('N'))
 $unknown=Join-Path $fixture.root ('.operation-stage-'+[guid]::NewGuid().ToString('N')+'-'+[guid]::NewGuid().ToString('N'))
 foreach($directory in @($empty,$unknown)){$null=[IO.Directory]::CreateDirectory($directory);Set-Acl -LiteralPath $directory -AclObject $rootAcl}
 $evidence=Join-Path $unknown 'unknown-evidence.bin';[IO.File]::WriteAllText($evidence,'retain-unpublished-evidence',$utf8)
 $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply')
 Assert-Lifecycle (!(Test-Path -LiteralPath $empty)-and(Test-Path -LiteralPath $unknown)-and[IO.File]::ReadAllText($evidence)-ceq'retain-unpublished-evidence') 'Operation stage recovery retained empty garbage or deleted unknown contents'
 Assert-Lifecycle ($r.exitCode-ne0-or$r.json.warnings.Count-gt0) 'Unknown operation stage did not report retained evidence'
 Assert-Lifecycle ([IO.File]::ReadAllText($fixture.file)-ceq'root-provision-payload') 'Operation stage recovery changed original data'
}
$migrationCases=@('complete','zero','prefix','nonprefix','unknown-name','directory-binding','original-file-id','formal-conflict')
foreach($boundary in $migrationCases){
 Test-LifecycleCase ('reserved-migration-layout-'+$boundary){
  $fixture=New-LifecycleMigrationPending ('mp'+[Array]::IndexOf($migrationCases,$boundary))
  if($boundary-in@('complete','zero','prefix')){
   $bytes=[IO.File]::ReadAllBytes($fixture.pending)
   if($boundary-eq'zero'){[IO.File]::WriteAllBytes($fixture.pending,[byte[]]@())}
   elseif($boundary-eq'prefix'){$part=[byte[]]::new([Math]::Min(64,[int]($bytes.Length/2)));[Array]::Copy($bytes,$part,$part.Length);[IO.File]::WriteAllBytes($fixture.pending,$part)}
   Assert-LifecycleMigrationResumed $fixture
  }else{
   switch($boundary){
    'nonprefix'{[IO.File]::WriteAllText($fixture.pending,'!not-a-prefix-of-the-reserved-marker',$utf8)}
    'unknown-name'{Move-LifecycleOwnEvidence $fixture.pending (Join-Path $fixture.record ('record-layout.json.pending-'+[guid]::NewGuid().ToString('N'))) $fixture.scope.root}
    'directory-binding'{
     $text=[IO.File]::ReadAllText($fixture.pending);$value=$text|ConvertFrom-Json -AsHashtable -Depth 100;$old=$value.directoryIdentity;$replacement=$(if($old.StartsWith('0')){'1'}else{'0'})+$old.Substring(1)
     $text=[regex]::Replace($text,'("directoryIdentity"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+'"'+$replacement+'"'});[IO.File]::WriteAllText($fixture.pending,$text,$utf8)
    }
    'original-file-id'{
     $manifest=Join-Path $fixture.record 'recycle-manifest.json';$saved=Join-Path $fixture.scope.root 'held-manifest.json';$expected=$fixture.originalFiles['recycle-manifest.json']
     Move-LifecycleOwnEvidence $manifest $saved $fixture.scope.root;[IO.File]::Copy($saved,$manifest,$false);[LifecycleE2ENative]::FixtureDacl($manifest,$expected.security)
     $copy=Get-LifecycleFileEvidence $manifest;Assert-Lifecycle ($copy.identity-cne$expected.identity) 'Metadata replacement fixture did not create a different file ID'
     foreach($field in @('security','attributes','length','sha256')){Assert-Lifecycle ($copy[$field]-ceq$expected[$field]) 'Different-ID fixture also changed nonidentity metadata evidence'}
    }
    'formal-conflict'{Move-LifecycleOwnEvidence $fixture.falseFormal $fixture.formal $fixture.scope.root}
   }
   $before=Get-LifecycleMetadataHashes $fixture.record;$names=Get-LifecycleNamespace $fixture.record;$intentBefore=Get-LifecycleFileEvidence $fixture.intent;$files=@{}
   foreach($member in Get-ChildItem -LiteralPath $fixture.record -File){$files[$member.Name]=Get-LifecycleFileEvidence $member.FullName}
   foreach($iteration in 1..2){
    $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply')
    Assert-Lifecycle ($r.exitCode-ne0-or$r.json.warnings.Count-gt0) 'Untrusted migration evidence was silently adopted'
    Assert-Lifecycle ((Get-LifecycleMetadataHashes $fixture.record)-ceq$before-and(Get-LifecycleNamespace $fixture.record)-ceq$names-and[LifecycleE2ENative]::Identity($fixture.record)-ceq$fixture.recordIdentity) 'Rejected migration changed or multiplied evidence'
    Assert-LifecycleFileEvidence $fixture.intent $intentBefore
    foreach($name in $files.Keys){Assert-LifecycleFileEvidence (Join-Path $fixture.record $name) $files[$name]}
    Assert-Lifecycle (!(Test-Path -LiteralPath $fixture.file)) 'Rejected migration restored its original'
    Assert-LifecycleFileEvidence $fixture.payload $fixture.payloadEvidence
   }
   $restore=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id)
   Assert-Lifecycle ($restore.exitCode-ne0-and!(Test-Path -LiteralPath $fixture.file)) 'Direct restore bypassed invalid migration evidence'
   Assert-LifecycleFileEvidence $fixture.payload $fixture.payloadEvidence
   $script:LifecycleEvidence.retainedReason='Invalid migration evidence and its Windows-managed fixture payload are retained for inspection.'
  }
 }
}
foreach($transport in @('cli-single','cli-many','mcp-many')){
 Test-LifecycleCase ('all-absent-'+$transport+'-has-finite-lifecycle'){
  $scope=New-LifecycleScope ('na-'+$transport);$witness=Join-Path $scope.files 'witness.bin';[IO.File]::WriteAllText($witness,'untouched-noop-witness',$utf8);$witnessEvidence=Get-LifecycleFileEvidence $witness;$ids=[Collections.Generic.List[string]]::new()
  foreach($round in 1..3){
   $count=if($transport-eq'cli-single'){1}else{3};$paths=@(1..$count|ForEach-Object{Join-Path $scope.files ('absent-'+$round+'-'+$_+'.bin')})
   if($transport-eq'mcp-many'){$deleted=Invoke-LifecycleMcpAbsent $scope $paths}
   else{$pathsFile=Join-Path $scope.root ('p'+$round+'.json');[IO.File]::WriteAllText($pathsFile,(ConvertTo-Json -InputObject $paths),$utf8);$call=Invoke-LifecycleCli $ExecutablePath $scope.config @('delete','--paths-file',$pathsFile);Assert-Lifecycle ($call.exitCode-eq0) ('All-absent CLI failed: '+$call.stdout+$call.stderr);$deleted=$call.json}
   Assert-LifecycleAbsentResult $deleted $paths;$id=$deleted.operationId;$ids.Add($id);$hintPath=Assert-LifecycleAbsentHint $scope $id
   $typedRoot=Join-Path $scope.metadata '.recycle-records-v1';$record=Join-Path $typedRoot $id;$manifestPath=Join-Path $record 'recycle-manifest.json';$original=[IO.File]::ReadAllBytes($manifestPath)
   $manifest=[Text.Encoding]::UTF8.GetString($original)|ConvertFrom-Json -AsHashtable -Depth 100
   Assert-Lifecycle (@($manifest.entries).Count-eq$count-and@($manifest.entries|Where-Object state -ne 'already_absent').Count-eq0-and@(Get-ChildItem -LiteralPath $record -Filter 'recycle-*-complete.json').Count-eq0) 'All-absent operation fabricated movement receipts or changed manifest inputs'
   try{
    $invalid=[byte[]]::new($original.Length);[Array]::Fill[byte]($invalid,32);$invalid[0]=123;[IO.File]::WriteAllBytes($manifestPath,$invalid);$before=Get-LifecycleMetadataHashes $scope.metadata
    $lightScans=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.lightScans=$lightScans
    foreach($iteration in 1..2){
     $light=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--dry-run');$unchanged=(Get-LifecycleMetadataHashes $scope.metadata)-ceq$before
     $lightScans.Add(@{round=$round;iteration=$iteration;response=$light;metadataUnchanged=$unchanged})
     $expectedWarnings=@(('Closed record '+$id+'.request.json could not be fully reconciled and was retained: A terminal retirement request is pending.'),'Recovery capacity is unknown because some data is busy or cannot be safely inspected.')
     Assert-Lifecycle ($light.exitCode-eq1-and$light.json.capacityKnown-eq$false-and$light.json.complete-eq$false-and$light.json.recordAuditRequested-eq$false-and@($light.json.warnings).Count-eq2-and@(Compare-Object $expectedWarnings @($light.json.warnings)).Count-eq0-and$unchanged) 'Ordinary all-absent capacity scan read body JSON, emitted an unrelated error, or changed metadata'
    }
   }finally{[IO.File]::WriteAllBytes($manifestPath,$original)}
   $maintained=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-Lifecycle ($maintained.exitCode-eq0) 'All-absent retirement failed'
   Assert-VerificationClosedRecord $scope.metadata $id 6
   $summary=[IO.File]::ReadAllText((Join-Path (Join-Path $scope.metadata '.closed-records-v1') ($id+'.json')))|ConvertFrom-Json -AsHashtable -Depth 100
   Assert-Lifecycle (@($summary.entries).Count-eq$count-and!(Test-Path -LiteralPath $hintPath)-and@(Get-ChildItem -LiteralPath $typedRoot -Directory|Where-Object Name -Match '^[a-f0-9]{32}$').Count-eq0-and@(Get-ChildItem -LiteralPath $typedRoot -Directory -Filter '.publication-*').Count-eq0) 'Consecutive no-op deletion left permanent active records or candidates'
   for($index=0;$index-lt$count;$index++){Assert-Lifecycle ($summary.entries[$index].path-ceq$paths[$index]-and!(Test-Path -LiteralPath $paths[$index])) 'No-op terminal history changed inputs or created originals'}
   Assert-LifecycleFileEvidence $witness $witnessEvidence
  }
  Assert-Lifecycle (@($ids|Sort-Object -Unique).Count-eq3) 'Consecutive no-op deletion unexpectedly reused an operation ID'
  $before=Get-LifecycleMetadataHashes $scope.metadata;foreach($iteration in 1..2){$r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-Lifecycle ($r.exitCode-eq0-and(Get-LifecycleMetadataHashes $scope.metadata)-ceq$before) 'Repeated no-op maintenance changed completed evidence'}
  foreach($id in $ids){Expire-LifecycleAbsentSummary $scope $id}
  $expired=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-Lifecycle ($expired.exitCode-eq0) 'Finite no-op terminal history could not expire'
  foreach($id in $ids){Assert-Lifecycle (@(Get-ChildItem -LiteralPath (Join-Path $scope.metadata '.closed-records-v1') -Filter ($id+'*')).Count-eq0) 'No-op history retained dangling control data after expiry'}
  Assert-LifecycleFileEvidence $witness $witnessEvidence;$script:LifecycleEvidence.operationIds=@($ids)
 }
}
Test-LifecycleCase 'interrupted-all-absent-hint-does-not-authorize-a-manifest' {
 $attempts=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.boundaryAttempts=$attempts;$observed=$false
 foreach($attempt in 1..3){
  $scope=New-LifecycleScope ('ni-'+$attempt);$witness=Join-Path $scope.files 'w.bin';[IO.File]::WriteAllText($witness,'unpublished-noop-witness',$utf8);$witnessEvidence=Get-LifecycleFileEvidence $witness
  $paths=@((Join-Path $scope.files 'missing-a.bin'),(Join-Path $scope.files 'missing-b.bin'));$pathsFile=Join-Path $scope.root 'p.json';[IO.File]::WriteAllText($pathsFile,(ConvertTo-Json -InputObject $paths),$utf8)
  $typedRoot=Join-Path $scope.metadata '.recycle-records-v1';$key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes('recycle-manifest.json'))).ToLowerInvariant().Substring(0,32)
  $gate=[LifecycleBoundaryGate]::new($scope.metadata,$typedRoot,'manifest',$key,$ExecutablePath);$session=$null
  try{
   $session=Start-LifecycleProcess $scope @('delete','--paths-file',$pathsFile);$gate.Bind($session.process)
   $observed=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $gate.ObservedPath)
   if($observed){
    $control=Split-Path $gate.ObservedPath;$match=[regex]::Match((Split-Path $control -Leaf),'^[.]publication-([a-f0-9]{32})-');Assert-Lifecycle $match.Success 'Manifest boundary has no owned operation ID';$id=$match.Groups[1].Value;$record=Join-Path $typedRoot $id;$manifestPath=Join-Path $record 'recycle-manifest.json'
    Assert-Lifecycle (!(Test-Path -LiteralPath $manifestPath)-and(Test-Path -LiteralPath (Join-Path $control 'body.json'))) 'All-absent interruption missed the pre-manifest publication boundary'
    $hintPath=Assert-LifecycleAbsentHint $scope $id;$gate.KillOwned()
   }else{$gate.Resume()}
   $response=Finish-LifecycleProcess $session;$attempts.Add(@{attempt=$attempt;scope=$scope.root;boundaryObserved=$observed;ownedProcessId=$gate.OwnedProcessId;gateError=$gate.Error;response=$response})
  }finally{if($session){if(!$session.process.HasExited){$gate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()};$gate.Dispose()}
  if(!$observed){$r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');Assert-LifecycleFileEvidence $witness $witnessEvidence;continue}
  Assert-Lifecycle (!(Test-Path -LiteralPath $manifestPath)) 'Interrupted candidate had already published an authoritative manifest'
  $owner=[IO.File]::ReadAllText((Join-Path $control 'owner.json'))|ConvertFrom-Json -AsHashtable -Depth 100;$bodyPath=Join-Path $control 'body.json';$body=[IO.File]::ReadAllText($bodyPath)|ConvertFrom-Json -AsHashtable -Depth 100
  Assert-Lifecycle ($owner.documentType-ceq'manifest'-and$owner.operationId-ceq$id-and$owner.finalName-ceq'recycle-manifest.json'-and$owner.bodyLength-eq(Get-Item -LiteralPath $bodyPath).Length-and$owner.bodySha256-ceq(Get-FileHash -LiteralPath $bodyPath).Hash.ToLowerInvariant()-and@($body.entries).Count-eq$paths.Count-and@($body.entries|Where-Object state -ne 'already_absent').Count-eq0) 'Interrupted candidate does not have a complete real pre-execution no-op body proof'
  foreach($iteration in 1..2){
   $r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply')
   Assert-Lifecycle ($r.exitCode-eq0-and!(Test-Path -LiteralPath $record)-and!(Test-Path -LiteralPath $control)-and!(Test-Path -LiteralPath $hintPath)-and!(Test-Path -LiteralPath (Join-Path (Join-Path $scope.metadata '.closed-records-v1') ($id+'.json')))) 'An unpublished all-absent hint fabricated terminal authority or retained dangling candidate data'
   Assert-Lifecycle (@(Get-ChildItem -LiteralPath $typedRoot -Force -Directory -Filter ('.publication-'+$id+'-*')).Count-eq0-and@(Get-ChildItem -LiteralPath $scope.metadata -Force -Recurse|Where-Object Name -Like ('*'+$id+'*')).Count-eq0) 'Pre-execution cleanup retained a publication namespace, request pending, request control copy or owned operation artifact'
   if($iteration-eq1){$settledHashes=Get-LifecycleMetadataHashes $scope.metadata;$settledNames=Get-LifecycleNamespace $scope.metadata}else{Assert-Lifecycle ((Get-LifecycleMetadataHashes $scope.metadata)-ceq$settledHashes-and(Get-LifecycleNamespace $scope.metadata)-ceq$settledNames) 'Pre-execution candidate cleanup was not idempotent'}
   foreach($path in $paths){Assert-Lifecycle (!(Test-Path -LiteralPath $path)) 'Interrupted absent candidate created an original'};Assert-LifecycleFileEvidence $witness $witnessEvidence
  }
  break
 }
 Assert-Lifecycle $observed 'All-absent pre-publication boundary was not observed in three fresh fixtures; no interruption success is claimed'
}
foreach($entryPoint in @('maintain','restore')){
 Test-LifecycleCase ('old15-original-present-'+$entryPoint+'-closes-without-source-writes') {
  $fixture=$null
  try{
   $fixture=New-LifecycleOriginalFixture ('original-'+$entryPoint)
   $arguments=if($entryPoint-ceq'maintain'){@('maintain','--apply')}else{@('restore',$fixture.id)}
   $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config $arguments;$script:LifecycleEvidence.response=$r
   Assert-Lifecycle ($r.exitCode-eq0) ('Original-present reconciliation failed: '+$r.stdout+$r.stderr)
   Assert-LifecycleOriginalClosed $fixture
   $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id)
   Assert-Lifecycle ($r.exitCode-eq0-and$r.json.lifecycleState-ceq'closed'-and$r.json.terminalReason-ceq'original_present'-and@($r.json.items|Where-Object status -ne 'closed').Count-eq0) 'Repeated original-present restore did not report closed status'
   Assert-LifecycleOriginalClosed $fixture
   $script:LifecycleEvidence.bodyAssertionsPassed=$true
  }finally{Complete-LifecycleOriginalFixture $fixture}
 }
}
foreach($fault in @('child-missing','child-other-id','acl-change','attributes-change','unknown-record-member')){
 Test-LifecycleCase ('old15-original-present-'+$fault+'-is-retained') {
  $fixture=$null;$moved=$null;$replacement=$null;$unknown=$null
  try{
   $fixture=New-LifecycleOriginalFixture ('original-negative-'+$fault)
   switch($fault){
    'child-missing' {$moved=Join-Path $fixture.scope.files 'retained-child.txt';Move-LifecycleOwnEvidence $fixture.child $moved $fixture.scope.root}
    'child-other-id' {$moved=Join-Path $fixture.scope.files 'retained-child.txt';Move-LifecycleOwnEvidence $fixture.child $moved $fixture.scope.root;[IO.File]::WriteAllText($fixture.child,'original-present-child',$utf8);$replacement=Join-Path $fixture.scope.files 'retained-replacement.txt';Assert-Lifecycle ([LifecycleE2ENative]::Identity($fixture.child)-cne$fixture.childEvidence.identity) 'Replacement child did not change native identity'}
    'acl-change' {$acl=Get-Acl -LiteralPath $fixture.child;$rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::ReadAttributes,[Security.AccessControl.AccessControlType]::Allow);$acl.AddAccessRule($rule);Set-Acl -LiteralPath $fixture.child -AclObject $acl;Assert-Lifecycle ([LifecycleE2ENative]::Security($fixture.child)-cne$fixture.childEvidence.security) 'ACL fault did not change security bytes'}
    'attributes-change' {[IO.File]::SetAttributes($fixture.child,([IO.FileAttributes]$fixture.childEvidence.attributes-bor[IO.FileAttributes]::Hidden))}
    'unknown-record-member' {$unknown=Join-Path $fixture.record 'unknown-original-authority.bin';[IO.File]::WriteAllText($unknown,'must-be-retained',$utf8)}
   }
   $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.response=$r
   $record=Get-LifecycleOriginalRecord $fixture
   Assert-Lifecycle ((Test-Path -LiteralPath $record)-and!(Test-Path -LiteralPath (Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.json')))) 'Negative original proof fabricated terminal authority'
   $before=Get-LifecycleMetadataHashes $record;$names=Get-LifecycleNamespace $record
   $again=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.repeatedResponse=$again
   Assert-Lifecycle ((Get-LifecycleMetadataHashes $record)-ceq$before-and(Get-LifecycleNamespace $record)-ceq$names) 'Repeated negative maintenance rewrote metadata or accumulated successor files'
   if($unknown){Assert-Lifecycle ([IO.File]::ReadAllText($unknown)-ceq'must-be-retained') 'Unknown authority member was changed'}
   Assert-LifecycleOriginalEvidence $fixture.sparse $fixture.sparseEvidence $fixture.prefix.Length
   $script:LifecycleEvidence.bodyAssertionsPassed=$true
  }finally{
   if($fixture){
    if($fault-ceq'acl-change'){[LifecycleE2ENative]::FixtureDacl($fixture.child,$fixture.childEvidence.security)}
    if($fault-ceq'attributes-change'){[IO.File]::SetAttributes($fixture.child,[IO.FileAttributes]$fixture.childEvidence.attributes)}
    if($replacement-and[IO.File]::Exists($fixture.child)){Move-LifecycleOwnEvidence $fixture.child $replacement $fixture.scope.root}
    if($moved-and[IO.File]::Exists($moved)){Move-LifecycleOwnEvidence $moved $fixture.child $fixture.scope.root}
    if($unknown){$current=Join-Path (Get-LifecycleOriginalRecord $fixture) (Split-Path $unknown -Leaf);if(Test-Path -LiteralPath $current){Move-LifecycleOwnEvidence $current (Join-Path $fixture.scope.files 'retained-unknown-authority.bin') $fixture.scope.root}}
   }
   Complete-LifecycleOriginalFixture $fixture
  }
 }
}
foreach($boundary in @('before-commit','after-commit')){
 Test-LifecycleCase ('old15-original-present-'+$boundary+'-rechecks-authority') {
  $observed=$false;$attempts=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.attempts=$attempts
  foreach($attempt in 1..3){
   $fixture=$null;$gate=$null;$summaryStageGate=$null;$session=$null;$held=$null;$moved=$null;$summaryStageObserved=$null;$summaryStagePath=$null
   try{
    $fixture=New-LifecycleOriginalFixture ('original-'+$boundary+'-'+$attempt)
    $closed=Join-Path $fixture.scope.metadata '.closed-records-v1';$summary=Join-Path $closed ($fixture.id+'.json')
    $name=if($boundary-ceq'before-commit'){$fixture.id+'.intent.json'}else{$fixture.id+'.json'}
    if($boundary-ceq'after-commit'){
     # 旧flatのmanifestを先に保持するとmigration renameを阻止する。
     # Source proof後、summary作成が始まった実境界でだけtyped metadataを保持する。
     $summaryStageGate=[LifecycleBoundaryGate]::new($fixture.scope.metadata,$closed,'exact-pending',$name,$ExecutablePath)
    }
    $gate=[LifecycleBoundaryGate]::new($fixture.scope.metadata,$closed,'exact',$name,$ExecutablePath)
    $session=Start-LifecycleProcess $fixture.scope @('restore',$fixture.id);$gate.Bind($session.process)
    if($summaryStageGate){
     $summaryStageGate.Bind($session.process)
     $summaryStageObserved=$summaryStageGate.Wait(30000)-and$summaryStageGate.Suspended-and!$summaryStageGate.Error-and(Test-Path -LiteralPath $summaryStageGate.ObservedPath)-and!(Test-Path -LiteralPath $summary)
     $summaryStagePath=$summaryStageGate.ObservedPath
     if($summaryStageObserved){
      $record=Get-LifecycleOriginalRecord $fixture
      Assert-Lifecycle ($record-cne$fixture.record-and(Test-Path -LiteralPath (Join-Path $record 'record-layout.json'))) 'Summary stage was reached before a completed typed migration'
      $held=[IO.File]::Open((Join-Path $record 'recycle-manifest.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
     }
     $summaryStageGate.Resume()
    }
    $observed=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $gate.ObservedPath)
    if($boundary-ceq'before-commit'){$observed=$observed-and!(Test-Path -LiteralPath $summary)}else{
     $observed=$observed-and$summaryStageObserved-and(Test-Path -LiteralPath $summary)-and(Test-Path -LiteralPath (Get-LifecycleOriginalRecord $fixture))-and!(Test-Path -LiteralPath (Join-Path $closed ($fixture.id+'.done.json')))
    }
    if($observed){
     if($boundary-ceq'after-commit'){
      $committed=Read-LifecyclePublishedJson $summary
      Assert-Lifecycle ($committed.operationId-ceq$fixture.id-and$committed.terminalReason-ceq'original_present'-and$committed.intentSha256-cmatch'^[a-f0-9]{64}$') 'Observed summary does not prove the original-present durable commit'
      $script:LifecycleEvidence.observedCommit=$committed
     }
     if($boundary-ceq'before-commit'){
      $intent=Read-LifecyclePublishedJson (Join-Path $closed $name)
      Assert-Lifecycle ($intent.terminalReason-ceq'original_present'-and@($intent.files|Where-Object name -Match '(recycle|restore).*complete').Count-eq0) 'Original-present retirement fabricated positive recycle/restore receipts'
      $liveMoves=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.livePinnedSourceMoves=$liveMoves
      foreach($source in @($fixture.tree,$fixture.child)){
       $destination=Join-Path $fixture.scope.files ('live-move-'+[guid]::NewGuid().ToString('N'));$succeeded=$false;$errorText=$null
       try{Move-LifecycleOriginalEvidence $source $destination $fixture.scope.root;$succeeded=$true}catch{$errorText=$_.Exception.Message}
       if($succeeded){Move-LifecycleOriginalEvidence $destination $source $fixture.scope.root}
       $liveMoves.Add(@{source=$source;destination=$destination;moveSucceeded=$succeeded;error=$errorText})
      }
      Assert-LifecycleOriginalEvidence $fixture.tree $fixture.treeEvidence;Assert-LifecycleOriginalEvidence $fixture.child $fixture.childEvidence;Assert-LifecycleOriginalEvidence $fixture.sparse $fixture.sparseEvidence $fixture.prefix.Length
      Assert-Lifecycle (@($liveMoves|Where-Object moveSucceeded).Count-eq0) 'Live precommit source root/child was movable despite required pinned handles; owned source was returned before stopping'
     }
     $gate.KillOwned()
    }else{$gate.Resume()}
    $response=Finish-LifecycleProcess $session;$attempts.Add(@{attempt=$attempt;scope=$fixture.scope.root;boundaryObserved=$observed;ownedProcessId=$gate.OwnedProcessId;gateError=$gate.Error;summaryStageObserved=$summaryStageObserved;summaryStagePath=$summaryStagePath;gateSuspendCount=$gate.SuspendCount;gateResumeCount=$gate.ResumeCount;gateKillCount=$gate.KillCount;summaryStageOwnedProcessId=$(if($summaryStageGate){$summaryStageGate.OwnedProcessId}else{$null});summaryStageSuspendCount=$(if($summaryStageGate){$summaryStageGate.SuspendCount}else{$null});summaryStageResumeCount=$(if($summaryStageGate){$summaryStageGate.ResumeCount}else{$null});summaryStageError=$(if($summaryStageGate){$summaryStageGate.Error}else{$null});response=$response})
    if($held){$held.Dispose();$held=$null}
    if(!$observed){continue}
    if($boundary-ceq'before-commit'){
     $moved=Join-Path $fixture.scope.files 'retained-before-commit.txt';Move-LifecycleOwnEvidence $fixture.child $moved $fixture.scope.root
     $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.resume=$r
     Assert-Lifecycle (!(Test-Path -LiteralPath $summary)-and(Test-Path -LiteralPath (Get-LifecycleOriginalRecord $fixture))-and!(Test-Path -LiteralPath $fixture.child)) 'Precommit restart accepted stale original-source proof or recreated a missing child'
     Assert-LifecycleOriginalEvidence $moved $fixture.childEvidence
    }else{
     $commit=(Get-FileHash -LiteralPath $summary).Hash
     [IO.File]::SetAttributes($fixture.child,([IO.FileAttributes]$fixture.childEvidence.attributes-bor[IO.FileAttributes]::Hidden));$changed=Get-LifecycleOriginalEvidence $fixture.child
     $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.resume=$r
     Assert-Lifecycle ($r.exitCode-eq0-and(Get-FileHash -LiteralPath $summary).Hash-ceq$commit-and(Test-Path -LiteralPath (Join-Path $closed ($fixture.id+'.done.json')))-and!(Test-Path -LiteralPath (Get-LifecycleOriginalRecord $fixture))) 'Committed cleanup did not finish solely from terminal metadata'
     Assert-LifecycleOriginalEvidence $fixture.child $changed
    }
    Assert-LifecycleOriginalEvidence $fixture.sparse $fixture.sparseEvidence $fixture.prefix.Length
    $script:LifecycleEvidence.bodyAssertionsPassed=$true
   }finally{
    if($session){if(!$session.process.HasExited){if($gate){$gate.KillOwned()};$session.process.Kill($true);$session.process.WaitForExit()};$session.process.Dispose()}
    if($gate){$gate.Dispose()};if($summaryStageGate){$summaryStageGate.Dispose()};if($held){$held.Dispose()}
    if($fixture){if($moved-and[IO.File]::Exists($moved)){Move-LifecycleOwnEvidence $moved $fixture.child $fixture.scope.root};if([IO.File]::Exists($fixture.child)){[IO.File]::SetAttributes($fixture.child,[IO.FileAttributes]$fixture.childEvidence.attributes)}}
    Complete-LifecycleOriginalFixture $fixture
   }
   if($observed){break}
  }
  Assert-Lifecycle $observed ('Original-present '+$boundary+' boundary was not caught in three fresh attempts; no interruption success is claimed')
 }
}
Test-LifecycleCase 'old15-original-negative-marker-skips-body-until-explicit-restore' {
 $fixture=$null;$moved=$null;$manifest=$null;$originalBytes=$null
 try{
  $fixture=New-LifecycleOriginalFixture 'original-negative-no-body-reread'
  $moved=Join-Path $fixture.scope.files 'retained-child.txt';Move-LifecycleOwnEvidence $fixture.child $moved $fixture.scope.root
  $first=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.firstResponse=$first
  $markers=@(Get-ChildItem -LiteralPath $fixture.scope.metadata -File -Recurse|Where-Object Length -LT 65536|ForEach-Object {try{$body=[IO.File]::ReadAllText($_.FullName)|ConvertFrom-Json -AsHashtable -Depth 100;if($body.kind-ceq'original-reconcile-needed'-and$body.operationId-ceq$fixture.id){@{path=$_.FullName;body=$body}}}catch{}})
  Assert-Lifecycle ($markers.Count-eq1) 'Negative proof did not persist exactly one bounded original-reconcile-needed marker'
  $script:LifecycleEvidence.negativeMarker=$markers[0]
  $record=Get-LifecycleOriginalRecord $fixture;$manifest=Join-Path $record 'recycle-manifest.json';$originalBytes=[IO.File]::ReadAllBytes($manifest);$manifestId=[LifecycleE2ENative]::Identity($manifest)
  $poison=[byte[]]$originalBytes.Clone();$poison[0]=[byte][char]'?';[IO.File]::WriteAllBytes($manifest,$poison)
  Assert-Lifecycle ([LifecycleE2ENative]::Identity($manifest)-ceq$manifestId-and[IO.FileInfo]::new($manifest).Length-eq$originalBytes.Length) 'Body poison changed manifest identity or length'
  $before=Get-LifecycleMetadataHashes $fixture.scope.metadata;$names=Get-LifecycleNamespace $fixture.scope.metadata
  foreach($iteration in 1..2){
   $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence['poisonMaintenance'+$iteration]=$r
   Assert-Lifecycle (($r.stdout+$r.stderr).Contains('Original reconciliation required for '+$fixture.id+':')) 'Maintenance lost the exact negative-marker diagnosis'
   Assert-Lifecycle ((Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names) 'Negative-marker maintenance read/repaired the poisoned body or changed metadata'
  }
  $restore=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:LifecycleEvidence.poisonRestore=$restore
  Assert-Lifecycle ($restore.exitCode-ne0-and(Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names) 'Explicit restore skipped its full validator or changed rejected evidence'
  [IO.File]::WriteAllBytes($manifest,$originalBytes);$originalBytes=$null
  Move-LifecycleOwnEvidence $moved $fixture.child $fixture.scope.root;$moved=$null
  $repaired=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:LifecycleEvidence.repairedResponse=$repaired
  Assert-Lifecycle ($repaired.exitCode-eq0) 'Explicit restore could not retry the repaired original proof'
  Assert-LifecycleOriginalClosed $fixture
  Assert-Lifecycle (!(Test-Path -LiteralPath $markers[0].path)) 'Successful explicit reconciliation left its negative marker'
  $script:LifecycleEvidence.bodyAssertionsPassed=$true
 }finally{
  if($originalBytes-and$manifest-and(Test-Path -LiteralPath $manifest)){[IO.File]::WriteAllBytes($manifest,$originalBytes)}
  if($moved-and[IO.File]::Exists($moved)){Move-LifecycleOwnEvidence $moved $fixture.child $fixture.scope.root}
  Complete-LifecycleOriginalFixture $fixture
 }
}
Test-LifecycleCase 'successful-recycle-wrapper-stop-keeps-bound-external-candidate-without-body-read' {
 $observed=$false;$attempts=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.attempts=$attempts
 foreach($attempt in 1..3){
  $scope=New-LifecycleScope ('original-success-gate-'+$attempt);$file=Join-Path $scope.files 'success.txt';[IO.File]::WriteAllText($file,'positive-recycle-negative-gate',$utf8);$source=Get-LifecycleFileEvidence $file
  $paths=Join-Path $scope.root 'success-paths.json';[IO.File]::WriteAllText($paths,(ConvertTo-Json -InputObject @($file)),$utf8)
  $typed=Join-Path $scope.metadata '.recycle-records-v1';$gate=[LifecycleBoundaryGate]::new($scope.metadata,$typed,'recycle-complete','',$ExecutablePath);$session=$null;$originalBytes=$null;$manifest=$null;$id=$null
  $attemptEvidence=@{attempt=$attempt;scope=$scope.root;observed=$false};$attempts.Add($attemptEvidence)
  try{
   $session=Start-LifecycleProcess $scope @('delete','--paths-file',$paths);$gate.Bind($session.process)
   $observed=$gate.Wait(30000)-and$gate.Suspended-and!$gate.Error-and(Test-Path -LiteralPath $gate.ObservedPath)
   if($observed){
    $record=Split-Path $gate.ObservedPath;$id=Split-Path $record -Leaf;$request=Join-Path (Join-Path $scope.metadata '.closed-records-v1') ($id+'.request.json')
    $observed=$id-cmatch'^[a-f0-9]{32}$'-and(Test-Path -LiteralPath $request)-and![IO.File]::Exists($file)
    if($observed){
     $body=Read-LifecyclePublishedJson $request;$attemptEvidence.observed=$true;$attemptEvidence.externalRequest=$body;$manifest=Join-Path $record 'recycle-manifest.json';$manifestEvidence=Get-LifecycleFileEvidence $manifest
     $closedLayout=Read-LifecyclePublishedJson (Join-Path (Split-Path $request) 'layout.json')
     $manifestReservation=@($body.externalUnavailable.metadata|Where-Object name -CEQ 'recycle-manifest.json')
     $finalReservation=@($body.externalUnavailable.metadata|Where-Object name -CEQ 'recycle-0000-complete.json')
     $final=[IO.File]::Open($gate.ObservedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
     try{$finalLength=$final.Length;$finalSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($final)).ToLowerInvariant()}finally{$final.Dispose()}
     Assert-Lifecycle ($body.kind-ceq'external-unavailable-request'-and$body.operationId-ceq$id-and$body.directoryIdentity-ceq[LifecycleE2ENative]::LifecycleIdentity($record)-and$body.metadataRootIdentity-ceq[LifecycleE2ENative]::LifecycleIdentity($scope.metadata)-and$body.machineName-ceq[Environment]::MachineName-and$body.ownerSid-ceq[Security.Principal.WindowsIdentity]::GetCurrent().User.Value-and$body.nonce-ceq$closedLayout.nonce-and$body.requiredFinalReceiptName-ceq'recycle-0000-complete.json') 'Positive-recycle stop lost its exact external request/root/operation binding'
     Assert-Lifecycle ($body.externalUnavailable.originalSchema-eq6-and$body.externalUnavailable.manifestName-ceq'recycle-manifest.json'-and$body.externalUnavailable.manifestSha256-ceq$manifestEvidence.sha256.ToLowerInvariant()-and$manifestReservation.Count-eq1-and$manifestReservation[0].identity-ceq[LifecycleE2ENative]::LifecycleIdentity($manifest)-and$manifestReservation[0].length-eq$manifestEvidence.length-and$manifestReservation[0].sha256-ceq$manifestEvidence.sha256.ToLowerInvariant()-and$finalReservation.Count-eq1-and$finalReservation[0].identity-ceq''-and$finalReservation[0].length-eq$finalLength-and$finalReservation[0].sha256-ceq$finalSha-and@($body.externalUnavailable.metadata).Count-eq2-and@($body.externalUnavailable.locators).Count-eq1-and$body.externalUnavailable.locators[0].path-ceq$file-and$body.externalUnavailable.locators[0].index-eq0) 'Positive-recycle stop lost the exact manifest or required-final byte reservation'
     Assert-Lifecycle (@(Get-ChildItem -LiteralPath (Split-Path $request) -File -Filter ($id+'.request.json.pending-*')).Count-eq0-and!$body.ContainsKey('originalManifestSha256')-and!$body.ContainsKey('deferredAssessment')) 'A superseded original-only or partial successor survived the completed publication boundary'
     $attemptEvidence.externalRequest=$body;$attemptEvidence.finalReceipt=@{path=$gate.ObservedPath;length=$finalLength;sha256=$finalSha};$gate.KillOwned()
    }
   }
   if(!$observed){$gate.Resume()}
   $response=Finish-LifecycleProcess $session;$attemptEvidence.observed=$observed;$attemptEvidence.response=$response
   if(!$observed){
    if($response.json.operationId){$restore=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$response.json.operationId);Assert-Lifecycle ($restore.exitCode-eq0) 'Missed success boundary left its fixture un-restorable';Assert-LifecycleFileEvidence $file $source}
    continue
   }
   $settle=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');$attemptEvidence.settlePublication=$settle
   Assert-Lifecycle ($settle.exitCode-eq0-and$settle.json.capacityKnown-and!(Test-Path -LiteralPath $file)) 'Published receipt control could not reconcile while its payload remained live'
   $requestEvidence=Get-LifecycleFileEvidence $request
   $manifest=Join-Path $record 'recycle-manifest.json';$originalBytes=[IO.File]::ReadAllBytes($manifest);$manifestId=[LifecycleE2ENative]::Identity($manifest);$bad=[byte[]]$originalBytes.Clone();$bad[0]=[byte][char]'?';[IO.File]::WriteAllBytes($manifest,$bad)
   $beforeHashes=Get-LifecycleMetadataHashes $scope.metadata;$beforeNamespace=Get-LifecycleNamespace $scope.metadata;$poisonResponses=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.poisonMaintenance=$poisonResponses
   foreach($iteration in 1..2){
    $r=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');$poisonResponses.Add($r)
    Assert-Lifecycle ($r.exitCode-eq0-and$r.json.capacityKnown-and!$r.json.recordAuditRequested-and!$r.json.recordAuditComplete-and!(Test-Path -LiteralPath $file)-and[LifecycleE2ENative]::Identity($manifest)-ceq$manifestId-and[IO.FileInfo]::new($manifest).Length-eq$originalBytes.Length-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($manifest))-ceq[Convert]::ToBase64String($bad)-and(Get-LifecycleMetadataHashes $scope.metadata)-ceq$beforeHashes-and(Get-LifecycleNamespace $scope.metadata)-ceq$beforeNamespace) 'Normal maintenance read/changed the poisoned live record or audited its body'
    Assert-LifecycleFileEvidence $request $requestEvidence
   }
   [IO.File]::WriteAllBytes($manifest,$originalBytes);$originalBytes=$null
   $restore=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$id);Assert-Lifecycle ($restore.exitCode-eq0) 'Receipt-negative-gate fixture could not restore after body rollback';Assert-LifecycleFileEvidence $file $source
  }finally{
   if($session){if(!$session.process.HasExited){$gate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};if(!$attemptEvidence.ContainsKey('response')){try{$attemptEvidence.response=Finish-LifecycleProcess $session}catch{$attemptEvidence.finishError=$_.Exception.Message}};$session.process.Dispose()};$attemptEvidence.processId=$gate.OwnedProcessId;$attemptEvidence.gateError=$gate.Error;$attemptEvidence.suspendCount=$gate.SuspendCount;$attemptEvidence.resumeCount=$gate.ResumeCount;$attemptEvidence.killCount=$gate.KillCount;$gate.Dispose()
   if($originalBytes-and$manifest-and(Test-Path -LiteralPath $manifest)){[IO.File]::WriteAllBytes($manifest,$originalBytes)}
  }
  if($observed){break}
 }
 Assert-Lifecycle $observed 'Successful recycle wrapper-stop boundary was not caught in three fresh attempts; no negative-gate success is claimed'
}
Test-LifecycleCase 'partial-multi-recycle-name-defers-original-candidate-without-body-read' {
 $captured=$false;$attempts=[Collections.Generic.List[object]]::new();$script:LifecycleEvidence.attempts=$attempts
 foreach($attempt in 1..3){
  $scope=New-LifecycleScope ('partial-recycle-negative-'+$attempt);$first=Join-Path $scope.files 'first.txt';$second=Join-Path $scope.files 'second.txt'
  [IO.File]::WriteAllText($first,'partial-first-root',$utf8);[IO.File]::WriteAllText($second,'partial-unmoved-second-root',$utf8)
  $firstEvidence=Get-LifecycleFileEvidence $first;$secondEvidence=Get-LifecycleFileEvidence $second
  $paths=Join-Path $scope.root 'paths.json';[IO.File]::WriteAllText($paths,(ConvertTo-Json -InputObject @($first,$second)),$utf8)
  $typed=Join-Path $scope.metadata '.recycle-records-v1';$key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('recycle-manifest.json'))).ToLowerInvariant().Substring(0,32)
  $manifestGate=[LifecycleBoundaryGate]::new($scope.metadata,$typed,'manifest',$key,$ExecutablePath)
  $receiptGate=[LifecycleBoundaryGate]::new($scope.metadata,$typed,'recycle-complete','',$ExecutablePath)
  $session=$null;$heldSecond=$null;$id=$null;$manifest=$null;$originalBytes=$null;$observed=$false;$receiptGateDisposed=$false
  $attemptEvidence=@{attempt=$attempt;scope=$scope.root;captured=$false};$attempts.Add($attemptEvidence)
  try{
   $session=Start-LifecycleProcess $scope @('delete','--paths-file',$paths);$manifestGate.Bind($session.process);$receiptGate.Bind($session.process)
   $manifestObserved=$manifestGate.Wait(30000)-and$manifestGate.Suspended-and!$manifestGate.Error-and(Test-Path -LiteralPath $manifestGate.ObservedPath)
   if($manifestObserved){
    $match=[regex]::Match((Split-Path (Split-Path $manifestGate.ObservedPath) -Leaf),'^[.]publication-([a-f0-9]{32})-');Assert-Lifecycle $match.Success 'Manifest boundary has no owned operation identity'
    $id=$match.Groups[1].Value;$record=Join-Path $typed $id;$manifest=Join-Path $record 'recycle-manifest.json';$request=Join-Path (Join-Path $scope.metadata '.closed-records-v1') ($id+'.request.json')
    $manifestObserved=!(Test-Path -LiteralPath $manifest)-and(Test-Path -LiteralPath $request)-and[IO.File]::Exists($first)-and[IO.File]::Exists($second)
    if($manifestObserved){
     $initial=Read-LifecyclePublishedJson $request;Assert-Lifecycle ($initial.kind-ceq'retire-original-request') 'Current multi-input caller did not generate its own initial original candidate'
     # 全preflight後に2個目のShell renameだけを拒否する。候補・receiptを後付けしない。
     $heldSecond=[IO.File]::Open($second,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    }
   }
   $attemptEvidence.manifestObserved=$manifestObserved
   if(!$manifestObserved){$receiptGate.Dispose();$receiptGateDisposed=$true}
   $manifestGate.Resume()
   if($manifestObserved){
    $observed=$receiptGate.Wait(30000)-and$receiptGate.Suspended-and!$receiptGate.Error-and(Test-Path -LiteralPath $receiptGate.ObservedPath)
    if($observed){
     $current=Read-LifecyclePublishedJson $request;$attemptEvidence.boundaryRequest=$current;$attemptEvidence.observedReceipt=$receiptGate.ObservedPath
     $observed=$current.kind-ceq'retire-original-request'-and(Split-Path $receiptGate.ObservedPath -Leaf)-ceq'recycle-0000-complete.json'-and!(Test-Path -LiteralPath (Join-Path $record 'recycle-0001-complete.json'))-and@(Get-ChildItem -LiteralPath (Split-Path $request) -File -Filter ($id+'.request.json.pending-*')).Count-eq0-and![IO.File]::Exists($first)-and[IO.File]::Exists($second)
     if($observed){$attemptEvidence.originalCandidate=$current;$receiptGate.KillOwned()}
    }
   }
   if(!$observed-and!$receiptGateDisposed){$receiptGate.Resume()}
   $response=Finish-LifecycleProcess $session;$attemptEvidence.response=$response
   if($heldSecond){$heldSecond.Dispose();$heldSecond=$null}
   if(!$observed){
    $restoreId=if($id){$id}else{$response.json.operationId}
    if($restoreId){$attemptEvidence.missedBoundaryRestore=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$restoreId)}
    Assert-LifecycleFileEvidence $first $firstEvidence;Assert-LifecycleFileEvidence $second $secondEvidence
    continue
   }
   $captured=$true;$attemptEvidence.captured=$true;$originalBytes=[IO.File]::ReadAllBytes($manifest);$manifestIdentity=[LifecycleE2ENative]::LifecycleIdentity($manifest);$originalSha=(Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()
   Assert-Lifecycle ($current.originalManifestSha256-ceq$originalSha-and$current.originalManifestLength-eq$originalBytes.Length) 'Initial current caller did not bind the real manifest bytes'
   $bad=[byte[]]$originalBytes.Clone();$bad[0]=[byte][char]'?';[IO.File]::WriteAllBytes($manifest,$bad);$recordHashes=Get-LifecycleMetadataHashes $record
   $attemptEvidence.poisonRecordHashes=$recordHashes;$attemptEvidence.poisonRecordNamespace=Get-LifecycleNamespace $record;$attemptEvidence.poisonManifest=@{identity=$manifestIdentity;length=$bad.Length;sha256=(Get-FileHash -LiteralPath $manifest).Hash}
   $maintenance=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');$attemptEvidence.firstMaintenance=$maintenance
   $attemptEvidence.afterFirstRecordHashes=Get-LifecycleMetadataHashes $record;$attemptEvidence.afterFirstRecordNamespace=Get-LifecycleNamespace $record
   Assert-Lifecycle ($maintenance.exitCode-eq1-and$maintenance.json.capacityKnown-and$maintenance.json.budgetSatisfied-and!$maintenance.json.complete-and!$maintenance.json.recordAuditRequested-and!$maintenance.json.recordAuditComplete-and@($maintenance.json.warnings).Count-eq1-and($maintenance.json.warnings[0]-match('Current partial operation '+[regex]::Escape($id)+'.*Operation bodies were not inspected'))-and$attemptEvidence.afterFirstRecordHashes-ceq$recordHashes-and$attemptEvidence.afterFirstRecordNamespace-ceq$attemptEvidence.poisonRecordNamespace-and![IO.File]::Exists($first)) 'Formal-name negative gate read or rewrote its poisoned partial operation, or lost the explicit pending exit/diagnostic contract'
   $deferred=Read-LifecyclePublishedJson $request;$facts=$deferred.deferredAssessment;$closedLayout=Read-LifecyclePublishedJson (Join-Path (Split-Path $request) 'layout.json')
   Assert-Lifecycle ($deferred.kind-ceq'external-deferred-assessment'-and$deferred.operationId-ceq$id-and$deferred.directoryIdentity-ceq[LifecycleE2ENative]::LifecycleIdentity($record)-and$deferred.metadataRootIdentity-ceq[LifecycleE2ENative]::LifecycleIdentity($scope.metadata)-and$deferred.nonce-ceq$closedLayout.nonce-and$deferred.machineName-ceq[Environment]::MachineName-and$deferred.ownerSid-ceq[Security.Principal.WindowsIdentity]::GetCurrent().User.Value-and$deferred.requiredFinalReceiptName-ceq'recycle-manifest.json'-and!$deferred.ContainsKey('externalUnavailable')-and!$deferred.ContainsKey('originalManifestSha256')) 'Formal-name negative gate retained original-only eligibility or forged a terminal candidate'
   Assert-Lifecycle ($facts.inheritedExpectedManifestSha256-ceq$originalSha-and$facts.inheritedExpectedManifestLength-eq$originalBytes.Length-and$facts.inheritedExpectedManifestSha256-cne(Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()-and$facts.manifestObservation.name-ceq'recycle-manifest.json'-and$facts.manifestObservation.identity-ceq$manifestIdentity-and$facts.manifestObservation.length-eq$originalBytes.Length-and$facts.manifestObservation.changeToken-ceq[LifecycleE2ENative]::ChangeToken($manifest)) 'Deferred assessment confused inherited expected bytes with current observation facts'
   $names=@(Get-ChildItem -LiteralPath $record -File|Where-Object Name -CNE 'operation.lock'|ForEach-Object Name|Sort-Object)
   Assert-Lifecycle (($names-join'|')-ceq(@($facts.metadataObservations|ForEach-Object name|Sort-Object)-join'|')) 'Deferred observation omitted or fabricated metadata filenames'
   foreach($fact in $facts.metadataObservations){$path=Join-Path $record $fact.name;Assert-Lifecycle ($fact.identity-ceq[LifecycleE2ENative]::LifecycleIdentity($path)-and$fact.length-eq[IO.FileInfo]::new($path).Length-and$fact.changeToken-ceq[LifecycleE2ENative]::ChangeToken($path)-and!$fact.ContainsKey('sha256')) 'Deferred metadata fact is not the observed ID/length/change token'}
   $deferredEvidence=Get-LifecycleFileEvidence $request;$stableHashes=Get-LifecycleMetadataHashes $scope.metadata;$stableNamespace=Get-LifecycleNamespace $scope.metadata
   $again=Invoke-LifecycleCli $ExecutablePath $scope.config @('maintain','--apply');$attemptEvidence.secondMaintenance=$again;$attemptEvidence.deferred=$deferred
   Assert-Lifecycle ($again.exitCode-eq1-and$again.json.capacityKnown-and$again.json.budgetSatisfied-and!$again.json.complete-and!$again.json.recordAuditRequested-and!$again.json.recordAuditComplete-and@($again.json.warnings).Count-eq1-and(Get-LifecycleMetadataHashes $scope.metadata)-ceq$stableHashes-and(Get-LifecycleNamespace $scope.metadata)-ceq$stableNamespace-and(($again.json.warnings-join' ')-match('Current partial operation '+[regex]::Escape($id)+'.*Operation bodies were not inspected'))) 'Stable deferred partial operation was re-read, rewritten or silently lost its pending diagnostic/exit contract'
   Assert-LifecycleFileEvidence $request $deferredEvidence;Assert-LifecycleFileEvidence $second $secondEvidence
   [IO.File]::WriteAllBytes($manifest,$originalBytes);$originalBytes=$null
   $restore=Invoke-LifecycleCli $ExecutablePath $scope.config @('restore',$id);$attemptEvidence.partialRestore=$restore
   Assert-Lifecycle ($restore.exitCode-eq1-and$restore.json.items.Count-eq2-and$restore.json.items[0].path-ceq$first-and$restore.json.items[0].status-ceq'restored'-and$restore.json.items[1].path-ceq$second-and$restore.json.items[1].status-ceq'failed'-and$restore.json.items[1].error-match'Recycle completion receipt is missing') 'Genuine partial operation was misreported as a complete restoration'
   Assert-LifecycleFileEvidence $first $firstEvidence;Assert-LifecycleFileEvidence $second $secondEvidence
   $attemptEvidence.retainedPartialOperation=$id
  }finally{
   if($session){if(!$session.process.HasExited){if(!$receiptGateDisposed){$receiptGate.KillOwned()};$manifestGate.KillOwned();$session.process.Kill($true);$session.process.WaitForExit()};if(!$attemptEvidence.ContainsKey('response')){try{$attemptEvidence.response=Finish-LifecycleProcess $session}catch{$attemptEvidence.finishError=$_.Exception.Message}};$session.process.Dispose()}
   if($heldSecond){$heldSecond.Dispose()}
   $attemptEvidence.operationId=$id;$attemptEvidence.manifestGate=@{pid=$manifestGate.OwnedProcessId;error=$manifestGate.Error;suspend=$manifestGate.SuspendCount;resume=$manifestGate.ResumeCount;kill=$manifestGate.KillCount};$attemptEvidence.receiptGate=@{pid=$receiptGate.OwnedProcessId;error=$receiptGate.Error;suspend=$receiptGate.SuspendCount;resume=$receiptGate.ResumeCount;kill=$receiptGate.KillCount}
   $manifestGate.Dispose();if(!$receiptGateDisposed){$receiptGate.Dispose()}
   if($originalBytes-and$manifest-and(Test-Path -LiteralPath $manifest)){[IO.File]::WriteAllBytes($manifest,$originalBytes)}
  }
  if($captured){break}
 }
 Assert-Lifecycle $captured 'No genuine non-final multi-input receipt boundary was captured in three fresh attempts'
}
foreach($successorState in @('predecessor-present','predecessor-absent','unknown-root-binding')){
 Test-LifecycleCase ('original-negative-successor-'+$successorState+'-resumes-or-preserves') {
  $fixture=$null;$manifest=$null;$manifestBytes=$null;$pendingBytes=$null
  try{
   $fixture=New-LifecycleOriginalSuccessorFixture ('original-successor-'+$successorState)
   $script:LifecycleEvidence.successor=$fixture.successor;$script:LifecycleEvidence.pendingPath=$fixture.pending
   if($successorState-ceq'predecessor-absent'){
    # 同IDの旧finalをfixture内へ退避し、削除後rename前の状態だけを作る。
    $saved=Join-Path $fixture.scope.files 'retained-predecessor-request.json';Move-LifecycleOwnEvidence $fixture.request $saved $fixture.scope.root
    Assert-LifecycleFileEvidence $saved $fixture.predecessor
   }
   if($successorState-ceq'unknown-root-binding'){
    $pendingBytes=[IO.File]::ReadAllBytes($fixture.pending);$text=[Text.Encoding]::UTF8.GetString($pendingBytes);$binding=$fixture.successor.metadataRootIdentity
    Assert-Lifecycle (![string]::IsNullOrEmpty($binding)) 'Genuine successor lacks metadata root binding'
    $replacement=$(if($binding.StartsWith('0')){'1'}else{'0'})+$binding.Substring(1)
    $changed=[regex]::Replace($text,'("metadataRootIdentity"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+'"'+$replacement+'"'})
    Assert-Lifecycle ($changed-cne$text) 'Unknown successor fault did not change root binding'
    [IO.File]::WriteAllText($fixture.pending,$changed,$utf8)
   }
   $record=Get-LifecycleOriginalRecord $fixture;$manifest=Join-Path $record 'recycle-manifest.json';$manifestBytes=[IO.File]::ReadAllBytes($manifest);$manifestId=[LifecycleE2ENative]::Identity($manifest)
   $poison=[byte[]]$manifestBytes.Clone();$poison[0]=[byte][char]'?';[IO.File]::WriteAllBytes($manifest,$poison)
   $before=Get-LifecycleMetadataHashes $fixture.scope.metadata;$names=Get-LifecycleNamespace $fixture.scope.metadata
   $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.interruptedResume=$r
   if($successorState-ceq'unknown-root-binding'){
    Assert-Lifecycle ((Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names-and(Test-Path -LiteralPath $fixture.request)-and(Test-Path -LiteralPath $fixture.pending)) 'Unknown successor was adopted, removed, repaired or allowed body processing'
    Assert-Lifecycle ($r.exitCode-ne0-or$r.json.warnings.Count-gt0) 'Unknown successor had no preservation diagnosis'
    [IO.File]::WriteAllBytes($fixture.pending,$pendingBytes);$pendingBytes=$null
    $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.repairedSuccessorResume=$r
   }
   Assert-Lifecycle (!(Test-Path -LiteralPath $fixture.pending)-and(Test-Path -LiteralPath $fixture.request)) 'Genuine negative successor did not publish after interruption'
   $marker=[IO.File]::ReadAllText($fixture.request)|ConvertFrom-Json -AsHashtable -Depth 100
   Assert-Lifecycle ($marker.kind-ceq'original-reconcile-needed'-and$marker.operationId-ceq$fixture.id-and($r.stdout+$r.stderr).Contains('Original reconciliation required for '+$fixture.id+':')) 'Successor resume lost its bounded negative marker or exact diagnosis'
   Assert-Lifecycle ([LifecycleE2ENative]::Identity($manifest)-ceq$manifestId-and[IO.FileInfo]::new($manifest).Length-eq$manifestBytes.Length-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($manifest))-ceq[Convert]::ToBase64String($poison)) 'Successor gate read or rewrote the poisoned formal manifest'
   Assert-LifecycleOriginalEvidence $fixture.childMoved $fixture.childEvidence;Assert-LifecycleOriginalEvidence $fixture.sparse $fixture.sparseEvidence $fixture.prefix.Length
   [IO.File]::WriteAllBytes($manifest,$manifestBytes);$manifestBytes=$null
   Move-LifecycleOwnEvidence $fixture.childMoved $fixture.child $fixture.scope.root
   $restore=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:LifecycleEvidence.finalRestore=$restore
   Assert-Lifecycle ($restore.exitCode-eq0) 'Resumed successor could not explicitly re-evaluate repaired source proof'
   Assert-LifecycleOriginalClosed $fixture;$script:LifecycleEvidence.bodyAssertionsPassed=$true
  }finally{
   if($pendingBytes-and$fixture-and(Test-Path -LiteralPath $fixture.pending)){[IO.File]::WriteAllBytes($fixture.pending,$pendingBytes)}
   if($manifestBytes-and$manifest-and(Test-Path -LiteralPath $manifest)){[IO.File]::WriteAllBytes($manifest,$manifestBytes)}
   if($fixture-and[IO.File]::Exists($fixture.childMoved)){Move-LifecycleOwnEvidence $fixture.childMoved $fixture.child $fixture.scope.root}
   Complete-LifecycleOriginalFixture $fixture
  }
 }
}
Test-LifecycleCase 'unpublished-original-negative-skips-body-and-explicitly-reevaluates-source' {
 $fixture=$null;$poisoned=$false
 try{
  $fixture=New-LifecycleDeferredUnpublishedFixture 'unpublished-negative-no-body-reread'
  $bad=[byte[]]$fixture.bodyBytes.Clone();$bad[0]=[byte][char]'?';[IO.File]::WriteAllBytes($fixture.body,$bad);$poisoned=$true
  Assert-Lifecycle ([LifecycleE2ENative]::Identity($fixture.body)-ceq$fixture.bodyEvidence.identity-and[IO.FileInfo]::new($fixture.body).Length-eq$fixture.bodyEvidence.length) 'Unpublished body poison changed native identity or length'
  $before=Get-LifecycleMetadataHashes $fixture.scope.metadata;$names=Get-LifecycleNamespace $fixture.scope.metadata
  foreach($iteration in 1..2){
   $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence['unpublishedPoisonMaintenance'+$iteration]=$r
   Assert-Lifecycle (($r.stdout+$r.stderr).Contains('Original reconciliation required for '+$fixture.id+':')-and(Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names) 'Deferred unpublished maintenance parsed/repaired body or changed retained metadata'
   Assert-LifecycleOriginalEvidence $fixture.tree $fixture.treeEvidence;Assert-LifecycleFileEvidence $fixture.child $fixture.faultChildEvidence
  }
  $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:LifecycleEvidence.poisonExplicitRestore=$r
  Assert-Lifecycle ($r.exitCode-ne0-and(Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names) 'Explicit unpublished restore skipped strong body validation or changed rejected evidence'
  [IO.File]::WriteAllBytes($fixture.body,$fixture.bodyBytes);$poisoned=$false
  $before=Get-LifecycleMetadataHashes $fixture.scope.metadata;$names=Get-LifecycleNamespace $fixture.scope.metadata
  $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:LifecycleEvidence.sourceFaultExplicitRestore=$r
  Assert-Lifecycle ($r.exitCode-ne0-and(Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names) 'Explicit unpublished restore bypassed the remaining source attribute mismatch'
  Assert-LifecycleFileEvidence $fixture.child $fixture.faultChildEvidence
  [IO.File]::SetAttributes($fixture.child,[IO.FileAttributes]$fixture.childEvidence.attributes)
  $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:LifecycleEvidence.repairedExplicitRestore=$r
  Assert-Lifecycle ($r.exitCode-ne0-and!(Test-Path -LiteralPath $fixture.manifest)-and!(Test-Path -LiteralPath $fixture.control)-and!(Test-Path -LiteralPath (Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.json')))) 'Valid unpublished retry promoted authority instead of preexecution cleanup without a closed restore result'
  Assert-LifecycleOriginalEvidence $fixture.tree $fixture.treeEvidence;Assert-LifecycleFileEvidence $fixture.child $fixture.childEvidence
  $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence.finalCleanup=$r
  Assert-Lifecycle ($r.exitCode-eq0-and!(Test-Path -LiteralPath $fixture.record)-and!(Test-Path -LiteralPath $fixture.request)-and!(Test-Path -LiteralPath $fixture.control)-and!(Test-Path -LiteralPath $fixture.manifest)-and!(Test-Path -LiteralPath (Join-Path (Join-Path $fixture.scope.metadata '.closed-records-v1') ($fixture.id+'.json')))) 'Validated unpublished cleanup retained its empty candidate or fabricated terminal authority'
  Assert-LifecycleOriginalEvidence $fixture.tree $fixture.treeEvidence;Assert-LifecycleFileEvidence $fixture.child $fixture.childEvidence
 }finally{
  if($fixture){if($poisoned-and[IO.File]::Exists($fixture.body)){[IO.File]::WriteAllBytes($fixture.body,$fixture.bodyBytes)};if([IO.File]::Exists($fixture.child)){[IO.File]::SetAttributes($fixture.child,[IO.FileAttributes]$fixture.childEvidence.attributes)}}
 }
}
foreach($bindingFault in @('owner-bytes','namespace','body-id','body-length')){
 Test-LifecycleCase ('unpublished-negative-'+$bindingFault+'-change-is-not-authorized') {
  $fixture=$null;$savedBody=$null;$replacementBody=$null;$movedControl=$null;$ownerBytes=$null;$bodyLengthChanged=$false
  try{
   $fixture=New-LifecycleDeferredUnpublishedFixture ('unpublished-invalid-'+$bindingFault)
   switch($bindingFault){
    'owner-bytes' {
     $ownerBytes=[IO.File]::ReadAllBytes($fixture.owner);$text=[Text.Encoding]::UTF8.GetString($ownerBytes);$old=$fixture.ownerBody.operationId;$new=$(if($old.StartsWith('0')){'1'}else{'0'})+$old.Substring(1)
     $changed=[regex]::Replace($text,'("operationId"\s*:\s*)"[^"]*"',{param($m)$m.Groups[1].Value+'"'+$new+'"'});Assert-Lifecycle ($changed-cne$text) 'Unknown-owner fault did not change binding';[IO.File]::WriteAllText($fixture.owner,$changed,$utf8)
    }
    'namespace' {$movedControl=Join-Path (Split-Path $fixture.control) ((Split-Path $fixture.control -Leaf)+'-unknown');Move-LifecycleOriginalEvidence $fixture.control $movedControl $fixture.scope.root}
    'body-id' {
     $savedBody=Join-Path $fixture.scope.files 'retained-original-body.json';$replacementBody=Join-Path $fixture.scope.files 'retained-replacement-body.json'
     Move-LifecycleOwnEvidence $fixture.body $savedBody $fixture.scope.root;[IO.File]::Copy($savedBody,$fixture.body,$false);[LifecycleE2ENative]::FixtureDacl($fixture.body,$fixture.bodyEvidence.security);[IO.File]::SetAttributes($fixture.body,[IO.FileAttributes]$fixture.bodyEvidence.attributes)
     $copy=Get-LifecycleFileEvidence $fixture.body;Assert-Lifecycle ($copy.identity-cne$fixture.bodyEvidence.identity) 'Unpublished replacement body reused native identity'
     foreach($field in @('security','attributes','length','sha256')){Assert-Lifecycle ($copy[$field]-ceq$fixture.bodyEvidence[$field]) 'Unpublished body-ID fault also changed another binding'}
    }
    'body-length' {$longer=[byte[]]::new($fixture.bodyBytes.Length+1);[Array]::Copy($fixture.bodyBytes,$longer,$fixture.bodyBytes.Length);$longer[-1]=32;[IO.File]::WriteAllBytes($fixture.body,$longer);$bodyLengthChanged=$true}
   }
   $before=Get-LifecycleMetadataHashes $fixture.scope.metadata;$names=Get-LifecycleNamespace $fixture.scope.metadata
   foreach($iteration in 1..2){
    $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('maintain','--apply');$script:LifecycleEvidence['invalidBindingMaintenance'+$iteration]=$r
    Assert-Lifecycle (($r.exitCode-ne0-or$r.json.warnings.Count-gt0)-and(Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names) 'Unknown unpublished binding was authorized, repaired or collected'
    Assert-LifecycleOriginalEvidence $fixture.tree $fixture.treeEvidence;Assert-LifecycleFileEvidence $fixture.child $fixture.faultChildEvidence
   }
   $r=Invoke-LifecycleCli $ExecutablePath $fixture.scope.config @('restore',$fixture.id);$script:LifecycleEvidence.invalidBindingExplicitRestore=$r
   Assert-Lifecycle ($r.exitCode-ne0-and(Get-LifecycleMetadataHashes $fixture.scope.metadata)-ceq$before-and(Get-LifecycleNamespace $fixture.scope.metadata)-ceq$names-and!(Test-Path -LiteralPath $fixture.manifest)) 'Explicit restore accepted unknown unpublished binding or promoted authority'
   Assert-LifecycleOriginalEvidence $fixture.tree $fixture.treeEvidence;Assert-LifecycleFileEvidence $fixture.child $fixture.faultChildEvidence
  }finally{
   if($fixture){
    if($movedControl-and[IO.Directory]::Exists($movedControl)){Move-LifecycleOriginalEvidence $movedControl $fixture.control $fixture.scope.root}
    if($ownerBytes-and[IO.File]::Exists($fixture.owner)){[IO.File]::WriteAllBytes($fixture.owner,$ownerBytes)}
    if($bodyLengthChanged-and[IO.File]::Exists($fixture.body)){[IO.File]::WriteAllBytes($fixture.body,$fixture.bodyBytes)}
    if($savedBody-and[IO.File]::Exists($savedBody)){if([IO.File]::Exists($fixture.body)){Move-LifecycleOwnEvidence $fixture.body $replacementBody $fixture.scope.root};Move-LifecycleOwnEvidence $savedBody $fixture.body $fixture.scope.root}
    if([IO.File]::Exists($fixture.child)){[IO.File]::SetAttributes($fixture.child,[IO.FileAttributes]$fixture.childEvidence.attributes)}
   }
  }
 }
}
if($results.Count-ne51){$results.Add(@{name='default-coverage-count';passed=$false;error='Expected all 51 lifecycle cases.'})}
$report=@{sourceSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;expectedCases=51;executablePath=$ExecutablePath;executableSha256=(Get-FileHash -LiteralPath $ExecutablePath).Hash;baselineExecutablePath=$BaselineExecutablePath;fileCount=$FileCount;results=@($results);passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object {!$_.passed}).Count;scope='isolated CLI lifecycle E2E; Windows bin limited to this fixture';retainedDirectory=$OutputDirectory}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 30),$utf8)
$report|Select-Object passed,failed,fileCount|ConvertTo-Json
if($report.failed){exit 1}
