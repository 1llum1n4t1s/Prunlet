param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string[]]$TargetPaths,[ValidateSet('rendezvous','child-race','locked-child','guard-probe','time-probe','external-change','external-attributes','external-masked-change')][string]$Mode='rendezvous')
$ErrorActionPreference='Stop'
foreach($path in @($AssemblyPath,$ConfigPath)+$TargetPaths){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
if($TargetPaths.Count-ne2-or$TargetPaths[0]-ieq$TargetPaths[1]){throw 'Two distinct targets required'}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Prepared candidate assembly changed'}
if(!('OversizeBatchRendezvousHost'-as[type])){
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Linq;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class OversizeBatchRendezvousHost {
 [StructLayout(LayoutKind.Sequential)] struct Basic { public long CreationTime,LastAccessTime,LastWriteTime,ChangeTime; public uint Attributes; }
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int kind,out Basic info,uint size);
 static long ChangeTime(string path) {using var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);if(!GetFileInformationByHandleEx(file.SafeFileHandle,0,out var info,(uint)Marshal.SizeOf<Basic>()))throw new IOException("Cannot read fixture change time");return info.ChangeTime;}
 public static object Run(string assemblyPath,string configPath,string[] targets,string mode) {
  var assembly=Assembly.LoadFrom(assemblyPath);
  var configType=assembly.GetType("Prunlet.Core.PrunletConfig",true);
  var serviceType=assembly.GetType("Prunlet.Core.DeletionService",true);
  var config=configType.GetMethod("Load").Invoke(null,new object[]{configPath});
  var service=Activator.CreateInstance(serviceType,new object[]{config});
  var checkpoint=serviceType.GetEvent("OversizedDeleteCheckpoint",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMemberException("Oversized checkpoint missing");
  var gate=new object();var arrived=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var clock=new Stopwatch();var events=new List<object>();var eventClock=Stopwatch.StartNew();bool released=false;string failure=null;IDisposable held=null;bool lockAcquired=false;string pinnedRoot=null;bool childConflict=false,childWaitTimedOut=false,writerAttempted=false,writerDenied=false,writerAllowedAfter=false,pendingWriterDenied=false,externalChangeInjected=false;int writerError=0;long pendingTime=0,unlinkedTime=0;
  Action<string,string> handler=(phase,path)=>{
   lock(gate) {
    if(failure!=null) throw new IOException(failure);
    if(phase=="hardlink-pending" && mode=="time-probe") events.Add(new {phase,path,time=ChangeTime(Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias"))});
    if(phase=="hardlink-pending" && (mode=="time-probe" || mode=="guard-probe") && pendingTime==0) {
     var survivor=Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias");pendingTime=ChangeTime(survivor);
     try {using var writer=new FileStream(survivor,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete);} catch(IOException ex) {pendingWriterDenied=ex.HResult==unchecked((int)0x80070020);}
     return;
    }
    if(phase=="hardlink-pending") return;
    if(phase=="hardlink-unlinked") {
     if(mode=="time-probe") events.Add(new {phase,path,time=ChangeTime(Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias"))});
     if(mode=="time-probe" && unlinkedTime==0) unlinkedTime=ChangeTime(Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias"));
     if(mode=="external-change" && !writerAttempted) {writerAttempted=true;var survivor=Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias");try {using(var file=new FileStream(survivor+":prunlet-external-probe",FileMode.Open,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete)){var first=file.ReadByte();if(first<0)throw new IOException("Empty shared fixture stream");file.Position=0;file.WriteByte((byte)(first^1));file.Flush(true);file.Position=0;file.WriteByte((byte)first);file.Flush(true);}externalChangeInjected=true;} catch(IOException ex) {writerError=ex.HResult;writerDenied=ex.HResult==unchecked((int)0x80070020);}}
     if(mode=="external-attributes" && !externalChangeInjected) {var survivor=Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias");File.SetAttributes(survivor,File.GetAttributes(survivor)^FileAttributes.Hidden);externalChangeInjected=true;}
     if(mode=="external-masked-change" && !writerAttempted) {writerAttempted=true;var survivor=Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias");var stamp=File.GetLastWriteTimeUtc(survivor);try {using(var file=new FileStream(survivor+":prunlet-external-probe",FileMode.Open,FileAccess.ReadWrite,FileShare.ReadWrite|FileShare.Delete)){var first=file.ReadByte();if(first<0)throw new IOException("Empty shared fixture stream");file.Position=0;file.WriteByte((byte)(first^1));file.Flush(true);}File.SetLastWriteTimeUtc(survivor,stamp);externalChangeInjected=true;} catch(IOException ex) {writerError=ex.HResult;writerDenied=ex.HResult==unchecked((int)0x80070020);}}
     if(mode=="guard-probe" && !writerAttempted) {writerAttempted=true;var survivor=Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias");try {using var writer=new FileStream(survivor,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete);} catch(IOException ex) {writerError=ex.HResult;writerDenied=ex.HResult==unchecked((int)0x80070020);}}
     return;
    }
    if(phase=="child-pinned" || phase=="child-open-failed") {
     if(mode=="locked-child" && string.Equals(path,Path.Combine(targets[0],"huge-sparse"),StringComparison.OrdinalIgnoreCase)) {events.Add(new {phase,path,root=targets[0],elapsedMs=eventClock.ElapsedMilliseconds});return;}
     if(mode!="child-race") return;
     var parent=Path.GetDirectoryName(path);var root=Array.Find(targets,p=>string.Equals(p,parent,StringComparison.OrdinalIgnoreCase));
     if(root==null || !Path.GetFileName(path).StartsWith("alias-",StringComparison.Ordinal)) return;
     events.Add(new {phase,path,root,elapsedMs=eventClock.ElapsedMilliseconds});
     if(phase=="child-open-failed" && pinnedRoot!=null && !string.Equals(root,pinnedRoot,StringComparison.OrdinalIgnoreCase)) {childConflict=true;Monitor.PulseAll(gate);return;}
     if(phase!="child-pinned" || pinnedRoot!=null) return;
     pinnedRoot=root;var wait=Stopwatch.StartNew();
     while(!childConflict) {var remaining=3000-(int)wait.ElapsedMilliseconds;if(remaining<=0 || (!Monitor.Wait(gate,remaining) && !childConflict)){childWaitTimedOut=true;break;}}
     events.Add(new {phase="child-wait-released",path,root,elapsedMs=eventClock.ElapsedMilliseconds});return;
    }
    if(phase!="oversize-reported" || !Array.Exists(targets,p=>string.Equals(p,path,StringComparison.OrdinalIgnoreCase)) || !arrived.Add(path)) {
     failure="Unexpected or repeated oversized checkpoint";Monitor.PulseAll(gate);throw new IOException(failure);
    }
    events.Add(new {phase,path,root=path,elapsedMs=eventClock.ElapsedMilliseconds});
    if(mode=="locked-child") {
     if(string.Equals(path,targets[0],StringComparison.OrdinalIgnoreCase)) {
      var fixture=AppDomain.CurrentDomain.GetAssemblies().Select(a=>a.GetType("Prunlet.RecordlessE2E.FixtureNative",false)).First(t=>t!=null);
      held=(IDisposable)fixture.GetMethod("HoldNoDelete").Invoke(null,new object[]{Path.Combine(path,"huge-sparse")});lockAcquired=true;
     }
     return;
    }
    if(!clock.IsRunning) clock.Start();
    if(clock.ElapsedMilliseconds>=20000) {clock.Stop();failure="Oversized rendezvous timed out";Monitor.PulseAll(gate);throw new IOException(failure);}
    if(arrived.Count==2) {clock.Stop();released=true;Monitor.PulseAll(gate);return;}
    while(!released && failure==null) {
     var remaining=20000-(int)clock.ElapsedMilliseconds;
     if(remaining<=0 || (!Monitor.Wait(gate,remaining) && !released)) {clock.Stop();failure="Oversized rendezvous timed out";Monitor.PulseAll(gate);break;}
    }
    if(failure!=null) throw new IOException(failure);
   }
  };
  checkpoint.GetAddMethod(true).Invoke(null,new object[]{handler});
  object result=null;bool reportedError=false;
  try {
   result=serviceType.GetMethod("Delete",new[]{typeof(string[]),typeof(bool),typeof(bool)}).Invoke(service,new object[]{targets,false,true});
   var program=assembly.GetType("Prunlet.Program",true);
   var hasErrors=program.GetMethod("HasErrors",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMethodException("Program.HasErrors missing");
   reportedError=(bool)hasErrors.Invoke(null,new[]{result});
  } finally {held?.Dispose();checkpoint.GetRemoveMethod(true).Invoke(null,new object[]{handler});}
  if(mode=="guard-probe") {var survivor=Path.Combine(Path.GetDirectoryName(targets[0]),"surviving-alias");try {using var writer=new FileStream(survivor,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete);writerAllowedAfter=true;} catch(IOException) {}}
  return new {mode,checkpointCount=arrived.Count,checkpointPaths=new List<string>(arrived).ToArray(),released,elapsedMs=clock.ElapsedMilliseconds,failure,events,pinnedRoot,childConflict,childWaitTimedOut,lockAcquired,lockReleased=lockAcquired,writerAttempted,writerDenied,writerError,writerAllowedAfter,pendingWriterDenied,externalChangeInjected,pendingTime,unlinkedTime,result,reportedError};
 }
}
'@
}
[OversizeBatchRendezvousHost]::Run($AssemblyPath,$ConfigPath,$TargetPaths,$Mode)
