param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string[]]$TargetPaths)
$ErrorActionPreference='Stop'
foreach($path in @($AssemblyPath,$ConfigPath)+$TargetPaths){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
if($TargetPaths.Count-ne2-or$TargetPaths[0]-ieq$TargetPaths[1]){throw 'Two distinct targets required'}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Candidate assembly changed'}
if(!('OversizeParallelIndependenceHost'-as[type])){
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
public static class OversizeParallelIndependenceHost {
 private sealed class StripeProof {public string path,fileId;public ulong volume;public int stripe;}
 private static StripeProof InspectStripe(Assembly assembly,Type serviceType,string path) {
  const BindingFlags flags=BindingFlags.Static|BindingFlags.Public|BindingFlags.NonPublic;
  var native=assembly.GetType("Prunlet.Core.NativeFiles",true);
  var open=native.GetMethod("OpenRecordlessPreflight",flags) ?? throw new MissingMethodException("OpenRecordlessPreflight missing");
  var identityMethod=native.GetMethod("MoveIdentity",flags) ?? throw new MissingMethodException("MoveIdentity missing");
  using var handle=(IDisposable)open.Invoke(null,new object[]{path});
  var identity=identityMethod.Invoke(null,new object[]{handle});var type=identity.GetType();
  var volume=(ulong)type.GetProperty("VolumeSerialNumber").GetValue(identity);
  var fileId=(string)type.GetProperty("FileId").GetValue(identity);
  if((bool)type.GetProperty("IsDirectory").GetValue(identity) || (uint)type.GetProperty("ReparseTag").GetValue(identity)!=0)throw new IOException("Ordinary file required for stripe proof");
  var stateType=serviceType.GetNestedType("OversizedHardlinkState",BindingFlags.NonPublic) ?? throw new MissingMemberException("OversizedHardlinkState missing");
  using var state=(IDisposable)Activator.CreateInstance(stateType,true);
  var stripes=(object[])stateType.GetField("stripes",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(state);
  var hold=stateType.GetMethod("Hold",BindingFlags.Instance|BindingFlags.NonPublic) ?? throw new MissingMethodException("Stripe Hold missing");
  using var lease=(IDisposable)hold.Invoke(state,new object[]{(volume,fileId)});
  var index=Array.FindIndex(stripes,Monitor.IsEntered);
  if(index<0)throw new IOException("Could not identify acquired stripe");
  return new StripeProof{path=path,volume=volume,fileId=fileId,stripe=index};
 }
 public static object Run(string assemblyPath,string configPath,string[] targets) {
  var assembly=Assembly.LoadFrom(assemblyPath);
  var configType=assembly.GetType("Prunlet.Core.PrunletConfig",true);
  var serviceType=assembly.GetType("Prunlet.Core.DeletionService",true);
  var config=configType.GetMethod("Load").Invoke(null,new object[]{configPath});
  var service=Activator.CreateInstance(serviceType,new object[]{config});
  var first=InspectStripe(assembly,serviceType,Path.Combine(targets[0],"small.txt"));
  var secondSmall=InspectStripe(assembly,serviceType,Path.Combine(targets[1],"small.txt"));
  var secondSparse=InspectStripe(assembly,serviceType,Path.Combine(targets[1],"huge-sparse"));
  var stripeProof=new[]{first,secondSmall,secondSparse};
  // root1のどちらが先に列挙されても同期点に到達できる場合だけ実削除する。
  if(first.stripe==secondSmall.stripe || first.stripe==secondSparse.stripe)
   return new {checkpointCount=0,events=new object[0],blockedPath=(string)null,secondPath=(string)null,secondPinned=false,firstReleased=false,failure="Stripe collision; fixture retained before Shell",stripeProof,result=(object)null,reportedError=true};
  var firstPath=first.path;var desiredSecond=secondSmall.path;
  var checkpoint=serviceType.GetEvent("OversizedDeleteCheckpoint",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMemberException("Oversize checkpoint missing");
  var gate=new object();var arrived=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var events=new List<object>();
  var clock=Stopwatch.StartNew();string failure=null;bool secondPinned=false,firstReleased=false;string blockedPath=null,secondPath=null;
  Action<string,string> handler=(phase,path)=>{
   lock(gate) {
    if(phase=="oversize-reported") {
     if(!Array.Exists(targets,p=>string.Equals(p,path,StringComparison.OrdinalIgnoreCase)) || !arrived.Add(path)) {failure="Unexpected or repeated Shell size notification";Monitor.PulseAll(gate);throw new IOException(failure);}
     events.Add(new {phase,path,elapsedMs=clock.ElapsedMilliseconds});
     var wait=Stopwatch.StartNew();
     while(arrived.Count<2 && failure==null) {var left=20000-(int)wait.ElapsedMilliseconds;if(left<=0 || !Monitor.Wait(gate,left)) {failure="Shell notification rendezvous timed out";Monitor.PulseAll(gate);break;}}
     Monitor.PulseAll(gate);if(failure!=null) throw new IOException(failure);return;
    }
    if(phase!="child-pinned") return;
    if(string.Equals(path,firstPath,StringComparison.OrdinalIgnoreCase) && blockedPath==null) {
     blockedPath=path;events.Add(new {phase="first-child-blocked",path,elapsedMs=clock.ElapsedMilliseconds});
     Monitor.PulseAll(gate);
     var wait=Stopwatch.StartNew();
     while(!secondPinned && failure==null) {var left=10000-(int)wait.ElapsedMilliseconds;if(left<=0 || !Monitor.Wait(gate,left)) {failure="Other root did not pin while the first was blocked";Monitor.PulseAll(gate);break;}}
     firstReleased=true;events.Add(new {phase="first-child-released",path,elapsedMs=clock.ElapsedMilliseconds});return;
    }
    if(string.Equals(path,desiredSecond,StringComparison.OrdinalIgnoreCase)) {
     var wait=Stopwatch.StartNew();
     while(blockedPath==null && failure==null) {var left=10000-(int)wait.ElapsedMilliseconds;if(left<=0 || !Monitor.Wait(gate,left)) {failure="First root did not reach its pin checkpoint";Monitor.PulseAll(gate);break;}}
     events.Add(new {phase="second-child-pinned",path,elapsedMs=clock.ElapsedMilliseconds});
     if(blockedPath!=null && !firstReleased) {secondPinned=true;secondPath=path;Monitor.PulseAll(gate);}
    }
   }
  };
  checkpoint.GetAddMethod(true).Invoke(null,new object[]{handler});
  object result;
  try {result=serviceType.GetMethod("Delete",new[]{typeof(string[]),typeof(bool),typeof(bool)}).Invoke(service,new object[]{targets,false,true});}
  finally {checkpoint.GetRemoveMethod(true).Invoke(null,new object[]{handler});}
  var program=assembly.GetType("Prunlet.Program",true);
  var hasErrors=program.GetMethod("HasErrors",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMethodException("Program.HasErrors missing");
  return new {checkpointCount=arrived.Count,events,blockedPath,secondPath,secondPinned,firstReleased,failure,stripeProof,result,reportedError=(bool)hasErrors.Invoke(null,new[]{result})};
 }
}
'@
}
[OversizeParallelIndependenceHost]::Run($AssemblyPath,$ConfigPath,$TargetPaths)
