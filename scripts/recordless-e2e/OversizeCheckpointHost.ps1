param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$TargetPath,[Parameter(Mandatory)][string]$MovedPath,[ValidateSet('replace','lock')][string]$Mode)
$ErrorActionPreference='Stop'
foreach($p in @($AssemblyPath,$ConfigPath,$TargetPath,$MovedPath)){if(![IO.Path]::IsPathFullyQualified($p)){throw 'Absolute paths required'}}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash -cne $ExpectedAssemblySha256){throw 'Prepared candidate assembly changed'}
if(!('OversizeCheckpointHost' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Linq;
public static class OversizeCheckpointHost {
 public static object Run(string assemblyPath,string configPath,string target,string moved,string mode) {
  var assembly=Assembly.LoadFrom(assemblyPath);
  var configType=assembly.GetType("Prunlet.Core.PrunletConfig",true);
  var serviceType=assembly.GetType("Prunlet.Core.DeletionService",true);
  var config=configType.GetMethod("Load").Invoke(null,new object[]{configPath});
  var service=Activator.CreateInstance(serviceType,new object[]{config});
  var checkpoint=serviceType.GetEvent("OversizedDeleteCheckpoint",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMemberException("Oversized checkpoint missing");
  var fixture=AppDomain.CurrentDomain.GetAssemblies().Select(a=>a.GetType("Prunlet.RecordlessE2E.FixtureNative",false)).First(t=>t!=null);
  object replacement=null; FileStream held=null; int count=0;
  Action<string,string> handler=(phase,path)=>{
   if(phase!="oversize-reported" || !string.Equals(path,target,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unexpected checkpoint");
   if(++count!=1) throw new InvalidOperationException("Repeated checkpoint");
   if(mode=="replace") {
    File.Move(target,moved);
    using(var f=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { var bytes=System.Text.Encoding.UTF8.GetBytes("replacement fixture"); f.Write(bytes); f.Flush(true); }
    replacement=fixture.GetMethod("SnapshotTree").Invoke(null,new object[]{target});
   } else if(mode=="lock") held=new FileStream(target,FileMode.Open,FileAccess.Read,FileShare.ReadWrite);
   else throw new ArgumentException("Unknown mode");
  };
  checkpoint.GetAddMethod(true).Invoke(null,new object[]{handler});
  try {
   var result=serviceType.GetMethod("Delete",new[]{typeof(string[]),typeof(bool),typeof(bool)}).Invoke(service,new object[]{new[]{target},false,false});
   var program=assembly.GetType("Prunlet.Program",true);
   var hasErrors=program.GetMethod("HasErrors",BindingFlags.NonPublic|BindingFlags.Static) ?? throw new MissingMethodException("Program.HasErrors missing");
   var reportedError=(bool)hasErrors.Invoke(null,new[]{result});
   return new {checkpointCount=count,phase=count==1?"oversize-reported":null,path=target,mode,replacement,result,reportedError};
  } finally { held?.Dispose(); checkpoint.GetRemoveMethod(true).Invoke(null,new object[]{handler}); }
 }
}
'@
}
[OversizeCheckpointHost]::Run($AssemblyPath,$ConfigPath,$TargetPath,$MovedPath,$Mode)
