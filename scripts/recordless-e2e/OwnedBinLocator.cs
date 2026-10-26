#nullable enable
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace Prunlet.RecordlessE2E;
public sealed class OwnedBinItem { public string Pidl {get;set;}="";public string PhysicalPath {get;set;}="";public string NativeId {get;set;}=""; }
public static class OwnedBinLocator {
 public static OwnedBinItem[] FindIdentity(string expectedId) => NativeRecycleBin.FindIdentity(expectedId);
 public static OwnedBinItem FindNew(string expectedId,string[] priorPidls){var previous=new HashSet<string>(priorPidls,StringComparer.Ordinal);var found=FindIdentity(expectedId).Where(item=>!previous.Contains(item.Pidl)).ToArray();if(found.Length!=1)throw new IOException("Exactly one newly recycled owned native identity required; found "+found.Length);return found[0];}
}
internal static partial class NativeRecycleBin {
 internal static OwnedBinItem[] FindIdentity(string expectedId)=>InSta(()=>{
  if(expectedId.Length!=48||!expectedId.All(Uri.IsHexDigit))throw new ArgumentException("Exact native ID required");
  var result=new List<OwnedBinItem>();var bin=OpenBin();
  try{_ = FindCurrentBinItem(bin,(item,pidl)=>{
    string path;try{path=PhysicalPath(item);}catch(IOException){return false;}
    string id;try{id=FixtureNative.Identity(path);}catch(System.ComponentModel.Win32Exception){return false;}catch(IOException){return false;}
    if(id.Equals(expectedId,StringComparison.Ordinal)){IStream? stream=null;try{RequireOk(CreateStreamOnHGlobal(IntPtr.Zero,true,out stream),"Cannot serialize owned PIDL");RequireOk(ILSaveToStream(stream,pidl),"Cannot save owned PIDL");stream.Stat(out var stat,1);if(stat.cbSize<=0||stat.cbSize>MaximumSerializedPidlBytes)throw new IOException("Owned PIDL length invalid");var bytes=new byte[(int)stat.cbSize];stream.Seek(0,0,IntPtr.Zero);ReadExactly(stream,bytes);result.Add(new OwnedBinItem{Pidl=Convert.ToBase64String(bytes),PhysicalPath=path,NativeId=id});}finally{Release(stream);}}
    return false;
  });return result.ToArray();}finally{Release(bin);}
 });
}
