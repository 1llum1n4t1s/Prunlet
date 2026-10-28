param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$SmallPath,[Parameter(Mandatory)][string]$AliasPath,[Parameter(Mandatory)][string]$HugeRoot,[Parameter(Mandatory)][string]$ExpectedFileId,[Parameter(Mandatory)][ulong]$ExpectedVolume)
$ErrorActionPreference='Stop'
foreach($path in @($AssemblyPath,$ConfigPath,$SmallPath,$AliasPath,$HugeRoot)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Candidate assembly changed'}
if(!('OversizeRecycledHardlinkHost'-as[type])){
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
public static class OversizeRecycledHardlinkHost {
 public static object Run(string assemblyPath,string configPath,string small,string alias,string huge,string expectedId,ulong expectedVolume) {
  var assembly=Assembly.LoadFrom(assemblyPath);
  var configType=assembly.GetType("Prunlet.Core.PrunletConfig",true);
  var serviceType=assembly.GetType("Prunlet.Core.DeletionService",true);
  var native=assembly.GetType("Prunlet.Core.NativeFiles",true);
  const BindingFlags flags=BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Static;
  var open=native.GetMethod("OpenShellInspection",flags) ?? throw new MissingMethodException("Shell inspection missing");
  var identity=native.GetMethod("MoveIdentity",flags) ?? throw new MissingMethodException("Move identity missing");
  var checkpoint=serviceType.GetEvent("OversizedDeleteCheckpoint",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMemberException("Oversize checkpoint missing");
  var config=configType.GetMethod("Load").Invoke(null,new object[]{configPath});
  var service=Activator.CreateInstance(serviceType,new object[]{config});
  var clock=Stopwatch.StartNew();var events=new List<object>();bool sizeReported=false,attempted=false,allowed=false,sourceAbsent=false,identityMatched=false;string error=null;
  Action<string,string> handler=(phase,path)=>{
   if(phase=="oversize-reported" && string.Equals(path,huge,StringComparison.OrdinalIgnoreCase)) {sizeReported=true;events.Add(new {phase,path,elapsedMs=clock.ElapsedMilliseconds});return;}
   if(phase!="child-pinned" || attempted || !string.Equals(path,Path.Combine(huge,"small.txt"),StringComparison.OrdinalIgnoreCase))return;
   attempted=true;events.Add(new {phase="child-blocked",path,elapsedMs=clock.ElapsedMilliseconds});sourceAbsent=!File.Exists(small);
   using(var handle=(IDisposable)open.Invoke(null,new object[]{alias})) {
    var info=identity.Invoke(null,new object[]{handle});var type=info.GetType();
    identityMatched=(ulong)type.GetProperty("VolumeSerialNumber").GetValue(info)==expectedVolume && string.Equals((string)type.GetProperty("FileId").GetValue(info),expectedId,StringComparison.OrdinalIgnoreCase);
   }
   try {using var writer=new FileStream(alias,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete);allowed=true;}
   catch(IOException ex){error=ex.ToString();} catch(UnauthorizedAccessException ex){error=ex.ToString();}
   events.Add(new {phase="child-released",path,elapsedMs=clock.ElapsedMilliseconds});
  };
  checkpoint.GetAddMethod(true).Invoke(null,new object[]{handler});object result;
  try {result=serviceType.GetMethod("Delete",new[]{typeof(string[]),typeof(bool),typeof(bool)}).Invoke(service,new object[]{new[]{small,huge},false,true});}
  finally {checkpoint.GetRemoveMethod(true).Invoke(null,new object[]{handler});}
  var program=assembly.GetType("Prunlet.Program",true);
  var hasErrors=program.GetMethod("HasErrors",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMethodException("Program.HasErrors missing");
  return new {sizeReported,attempted,allowed,sourceAbsent,identityMatched,error,events,result,reportedError=(bool)hasErrors.Invoke(null,new[]{result})};
 }
}
'@
}
[OversizeRecycledHardlinkHost]::Run($AssemblyPath,$ConfigPath,$SmallPath,$AliasPath,$HugeRoot,$ExpectedFileId,$ExpectedVolume)
