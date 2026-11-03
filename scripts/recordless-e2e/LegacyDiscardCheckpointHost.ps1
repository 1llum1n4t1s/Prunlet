param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][string]$ExpectedAssemblySha256,[Parameter(Mandatory)][string]$ConfigPath,[ValidateSet('CreateTypedRoots','CreateRestoreRoot')][string]$Action='CreateTypedRoots')
$ErrorActionPreference='Stop'
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256){throw 'Synthetic ownership-marker helper assembly changed'}
# この.NET補助はsynthetic所有marker生成専用。移行・中断・差替えは同buildのRust probeで行い、真正旧schema producerとも区別する。
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Threading;
public static class LegacyDiscardCheckpointHost {
 public static void Run(string assemblyPath,string configPath,string action) {
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
  throw new ArgumentException("Only synthetic ownership-marker preparation is supported; Rust probes own migration checkpoints.");
 }
}
'@
[LegacyDiscardCheckpointHost]::Run($AssemblyPath,$ConfigPath,$Action)
