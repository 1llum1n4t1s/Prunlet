param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$TargetPath,[Parameter(Mandatory)][string]$MovedPath,[Parameter(Mandatory)][string]$EvidencePath)
$ErrorActionPreference='Stop'
foreach($p in @($AssemblyPath,$ConfigPath,$TargetPath,$MovedPath,$EvidencePath)){if(![IO.Path]::IsPathFullyQualified($p)){throw 'Absolute paths required'}}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash -cne $ExpectedAssemblySha256){throw 'Prepared candidate assembly changed'}
if(!('BeforeRecycleCheckpointHost' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Linq;
using System.Text.Json;
public static class BeforeRecycleCheckpointHost {
 public static object Run(string assemblyPath,string configPath,string target,string moved,string evidencePath) {
  var assembly=Assembly.LoadFrom(assemblyPath);
  var configType=assembly.GetType("Prunlet.Core.PrunletConfig",true);
  var serviceType=assembly.GetType("Prunlet.Core.DeletionService",true);
  var native=assembly.GetType("Prunlet.Core.NativeRecycleBin",true);
  var checkpoint=native.GetEvent("BeforeRecycleCheckpoint",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMemberException("BeforeRecycleCheckpoint missing");
  var createdCheckpoint=native.GetEvent("RecycleCreatedCheckpoint",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMemberException("RecycleCreatedCheckpoint missing");
  var fixture=AppDomain.CurrentDomain.GetAssemblies().Select(a=>a.GetType("Prunlet.RecordlessE2E.FixtureNative",false)).First(t=>t!=null);
  var config=configType.GetMethod("Load").Invoke(null,new object[]{configPath});var service=Activator.CreateInstance(serviceType,new object[]{config});
  int count=0,createdCount=0; object replacement=null; string createdSource=null,createdPath=null,createdId=null,createdError=null;
  Action<string,string> handler=(phase,path)=>{
   if(phase!="before-recycle" || !string.Equals(path,target,StringComparison.OrdinalIgnoreCase) || ++count!=1) throw new InvalidOperationException("Unexpected or repeated checkpoint");
   File.Move(target,moved,false);
   using(var f=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {var bytes=System.Text.Encoding.UTF8.GetBytes("before-recycle replacement fixture");f.Write(bytes);f.Flush(true);}
   replacement=fixture.GetMethod("SnapshotTree").Invoke(null,new object[]{target});
   var evidence=JsonSerializer.SerializeToUtf8Bytes(new {phase,path,moved,replacement});
   using(var f=new FileStream(evidencePath,FileMode.CreateNew,FileAccess.Write,FileShare.None)){f.Write(evidence);f.Flush(true);}
  };
  Action<string,string> createdHandler=(source,path)=>{
   createdCount++;createdSource=source;createdPath=path;createdId=null;createdError=null;
   try {createdId=(string)fixture.GetMethod("Identity").Invoke(null,new object[]{path});}
   catch(Exception ex){createdError=ex.GetBaseException().ToString();}
  };
  checkpoint.GetAddMethod(true).Invoke(null,new object[]{handler});
  try {
   createdCheckpoint.GetAddMethod(true).Invoke(null,new object[]{createdHandler});
   try {
   var result=serviceType.GetMethod("Delete",new[]{typeof(string[]),typeof(bool),typeof(bool)}).Invoke(service,new object[]{new[]{target},false,false});
   var hasErrors=assembly.GetType("Prunlet.Program",true).GetMethod("HasErrors",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMethodException("Program.HasErrors missing");
   return new {checkpointCount=count,phase=count==1?"before-recycle":null,path=target,moved,replacement,result,reportedError=(bool)hasErrors.Invoke(null,new[]{result}),createdCheckpointCount=createdCount,createdSource,createdPath,createdId,createdError};
   } finally {createdCheckpoint.GetRemoveMethod(true).Invoke(null,new object[]{createdHandler});}
  } finally {checkpoint.GetRemoveMethod(true).Invoke(null,new object[]{handler});}
 }
}
'@
}
[BeforeRecycleCheckpointHost]::Run($AssemblyPath,$ConfigPath,$TargetPath,$MovedPath,$EvidencePath)
