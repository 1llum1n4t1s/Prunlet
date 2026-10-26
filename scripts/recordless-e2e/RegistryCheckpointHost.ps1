param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][ValidateSet('RegistryControlCheckpoint','RegistryPublicationCheckpoint')][string]$EventName,[Parameter(Mandatory)][string]$Checkpoint,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][ValidateSet('Migrate','MigrateMaintain','Restore')][string]$Action,[Parameter(Mandatory)][string]$SignalPath)
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Prepared candidate assembly changed'}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Threading;
public static class RegistryCheckpointHost {
 public static void Run(string assemblyPath,string configPath,string eventName,string checkpoint,string operationId,string action,string signalPath) {
  var assembly=Assembly.LoadFrom(assemblyPath);var configType=assembly.GetType("Prunlet.Core.PrunletConfig",true);var serviceType=assembly.GetType("Prunlet.Core.DeletionService",true);
  var signal=serviceType.GetEvent(eventName,BindingFlags.NonPublic|BindingFlags.Static);if(signal==null)throw new MissingMemberException("Actual candidate checkpoint event missing");
  Action<string,string> handler=(phase,id)=>{if(phase!=checkpoint||id!=operationId)return;using(var stream=new FileStream(signalPath+".writing",FileMode.CreateNew,FileAccess.Write,FileShare.None)){var bytes=System.Text.Encoding.UTF8.GetBytes(phase+"\n"+id+"\n"+Environment.ProcessId);stream.Write(bytes);stream.Flush(true);}File.Move(signalPath+".writing",signalPath);Thread.Sleep(Timeout.Infinite);};
  signal.GetAddMethod(true).Invoke(null,new object[]{handler});
  try {var config=configType.GetMethod("Load").Invoke(null,new object[]{configPath});var service=Activator.CreateInstance(serviceType,new object[]{config});if(action=="Restore")serviceType.GetMethod("RestoreRegistry").Invoke(service,new object[]{operationId});else {serviceType.GetMethod("MigrateRecoveryStorage",new[]{typeof(bool),typeof(bool),typeof(bool)}).Invoke(service,new object[]{true,false,false});if(action=="MigrateMaintain")serviceType.GetMethod("MaintainRecovery").Invoke(service,new object[]{true,false});}throw new InvalidOperationException("Public operation ended without selected checkpoint");}
  finally {signal.GetRemoveMethod(true).Invoke(null,new object[]{handler});}
 }
}
'@
[RegistryCheckpointHost]::Run($AssemblyPath,$ConfigPath,$EventName,$Checkpoint,$OperationId,$Action,$SignalPath)
