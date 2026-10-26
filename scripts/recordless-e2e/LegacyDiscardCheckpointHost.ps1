param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[ValidateSet('Checkpoint','CreateTypedRoots','CreateRestoreRoot')][string]$Action='Checkpoint',[string]$Checkpoint,[string]$TargetPath,[string]$SignalPath)
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Prepared candidate assembly changed'}
# 失敗モデルは公開移行APIのgate flush後/Shell帰還後の強制終了。typed fixtureは現候補Coreの所有境界モデルであり真正旧版互換の証拠にはしない。
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Threading;
public static class LegacyDiscardCheckpointHost {
 public static void Run(string assemblyPath,string configPath,string action,string phase,string target,string signalPath) {
  var assembly=Assembly.LoadFrom(assemblyPath);var configType=assembly.GetType("Prunlet.Core.PrunletConfig",true);var serviceType=assembly.GetType("Prunlet.Core.DeletionService",true);
  var config=configType.GetMethod("Load").Invoke(null,new object[]{configPath});var service=Activator.CreateInstance(serviceType,new object[]{config});
  if(action=="CreateTypedRoots"||action=="CreateRestoreRoot") {
   var coordination=serviceType.GetMethod("AcquireRecoveryCoordination",BindingFlags.NonPublic|BindingFlags.Instance);
   using(var lease=(IDisposable)coordination.Invoke(service,new object[]{true,null})) {
    var metadata=(string)configType.GetProperty("BackupDirectory").GetValue(config);
    if(action=="CreateRestoreRoot") {
     // 所有境界モデルだけを生成する。旧schemaのmanifest/payload/復元履歴は作らない。
     var store=assembly.GetType("Prunlet.Core.VolumeRecoveryStore",true);var native=assembly.GetType("Prunlet.Core.NativeFiles",true);
     var location=store.GetMethod("Location",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,new object[]{config,Path.GetPathRoot(metadata),false,true});var locationType=location.GetType();
     var parent=(string)locationType.GetProperty("PrivateBase").GetValue(location);var root=(string)locationType.GetProperty("Root").GetValue(location);
     var createDirectory=native.GetMethod("CreatePrivateRegistryDirectory",BindingFlags.NonPublic|BindingFlags.Static);
     using(var directory=(IDisposable)createDirectory.Invoke(null,new object[]{parent})){}
     using(var directory=(IDisposable)createDirectory.Invoke(null,new object[]{root})) {
      var identity=native.GetMethod("MoveIdentity",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,new object[]{directory});var identityType=identity.GetType();
      var body=new System.Collections.Generic.Dictionary<string,object>{{"schema",1},{"ownerSid",store.GetProperty("OwnerSid",BindingFlags.NonPublic|BindingFlags.Static).GetValue(null)},{"metadataRoot",locationType.GetProperty("MetadataRoot").GetValue(location)},{"storeKey",locationType.GetProperty("StoreKey").GetValue(location)},{"volumeName",locationType.GetProperty("VolumeName").GetValue(location)},{"volumeSerial",identityType.GetProperty("VolumeSerialNumber").GetValue(identity)},{"rootFileId",identityType.GetProperty("FileId").GetValue(identity)}};
      using(var handle=(Microsoft.Win32.SafeHandles.SafeFileHandle)native.GetMethod("CreatePrivateRegistryFile",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,new object[]{Path.Combine(root,"store.json")}))
      using(var stream=new FileStream(handle,FileAccess.ReadWrite)){JsonSerializer.Serialize(stream,body);stream.Flush(true);}
     }
     Console.WriteLine(JsonSerializer.Serialize(new[]{root}));return;
    }
    var create=serviceType.GetMethod("EnsureRecordRoot",BindingFlags.NonPublic|BindingFlags.Static);
    var roots=new[]{(string)create.Invoke(null,new object[]{metadata,".recycle-records-v1",true}),(string)create.Invoke(null,new object[]{metadata,".closed-records-v1",true})};
    Console.WriteLine(JsonSerializer.Serialize(roots));return;
   }
  }
  if(!Path.IsPathFullyQualified(target)||!Path.IsPathFullyQualified(signalPath)||(phase!="gate.flushed"&&phase!="shell.returned"))throw new ArgumentException("Fixed checkpoint input missing.");
  var checkpoint=serviceType.GetEvent("LegacyDiscardCheckpoint",BindingFlags.NonPublic|BindingFlags.Static);if(checkpoint==null)throw new MissingMemberException("Actual discard checkpoint event missing");
  Action<string,string> handler=(observed,path)=>{if(observed!=phase||!string.Equals(path,target,StringComparison.OrdinalIgnoreCase))return;using(var file=new FileStream(signalPath+".writing",FileMode.CreateNew,FileAccess.Write,FileShare.None)){var bytes=System.Text.Encoding.UTF8.GetBytes(observed+"\n"+path+"\n"+Environment.ProcessId);file.Write(bytes);file.Flush(true);}File.Move(signalPath+".writing",signalPath);Thread.Sleep(Timeout.Infinite);};
  checkpoint.GetAddMethod(true).Invoke(null,new object[]{handler});
  try {serviceType.GetMethod("MigrateRecoveryStorage",new[]{typeof(bool),typeof(bool),typeof(bool)}).Invoke(service,new object[]{true,false,false});throw new InvalidOperationException("Public migration ended without selected checkpoint");}
  finally {checkpoint.GetRemoveMethod(true).Invoke(null,new object[]{handler});}
 }
}
'@
[LegacyDiscardCheckpointHost]::Run($AssemblyPath,$ConfigPath,$Action,$Checkpoint,$TargetPath,$SignalPath)
