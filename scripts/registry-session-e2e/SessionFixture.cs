using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Text.Json;
using System.Security.Cryptography;
using System.Security.Principal;
public static class SessionE2ENative {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern int GetCurrentPackageFullName(ref uint length,StringBuilder name);
 public static bool Packaged(){uint n=0;return GetCurrentPackageFullName(ref n,null)!=15700;}
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(SafeAccessTokenHandle token,int information,byte[] bytes,uint length,out uint required);
 static byte[] TokenField(SafeAccessTokenHandle token,int information){
  GetTokenInformation(token,information,null,0,out uint length);if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error());
  var bytes=new byte[length];if(!GetTokenInformation(token,information,bytes,length,out _))throw new Win32Exception(Marshal.GetLastWin32Error());return bytes;
 }
 public static Dictionary<string,object> TokenInfo(){
  using var identity=WindowsIdentity.GetCurrent();var statistics=TokenField(identity.AccessToken,10);
  string authenticationId=$"{BitConverter.ToUInt32(statistics,12):X8}:{BitConverter.ToUInt32(statistics,8):X8}";
  return new Dictionary<string,object>{{"authenticationId",authenticationId},{"ownerSid",identity.User.Value},{"windowsSessionId",BitConverter.ToUInt32(TokenField(identity.AccessToken,12),0)},{"isAdministrator",new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)},{"isAppContainer",BitConverter.ToUInt32(TokenField(identity.AccessToken,29),0)!=0},{"packaged",Packaged()},{"processId",Environment.ProcessId}};
 }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryValueExW(SafeRegistryHandle key,string name,IntPtr reserved,out uint type,byte[] bytes,ref uint length);
 // 実在する既存値をquery-onlyで照合する。内容自体は検証ログへ出さない。
 public static string CurrentSoftwareValueDigest(){
  using var key=Registry.CurrentUser.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer",false);
  if(key==null)throw new InvalidOperationException("Existing Software probe key missing; do not create a replacement fixture.");
  uint length=0,type;int error=RegQueryValueExW(key.Handle,"ShellState",IntPtr.Zero,out type,null,ref length);
  if(error!=0)throw new Win32Exception(error);if(length>1024*1024)throw new InvalidOperationException("Probe value unexpectedly large.");
  var bytes=new byte[length];error=RegQueryValueExW(key.Handle,"ShellState",IntPtr.Zero,out type,bytes,ref length);if(error!=0)throw new Win32Exception(error);
  return type+":"+length+":"+Convert.ToHexStringLower(SHA256.HashData(bytes));
 }
 public static string Fingerprint(string json){
  using var d=JsonDocument.Parse(json);var r=d.RootElement;
  string Abs(string p){p=p.Replace('/','\\').TrimEnd('\\');if(p.Length==2)p+="\\";return Path.GetFullPath(p);}
  var roots=r.TryGetProperty("allowedRoots",out var ar)&&ar.ValueKind!=JsonValueKind.Null?ar.EnumerateArray().Select(x=>x.GetString()).ToArray():Array.Empty<string>();
  var volumes=r.GetProperty("volumeRecoveryDirectories").EnumerateObject().Select(x=>new KeyValuePair<string,string>(Abs(x.Name),Abs(x.Value.GetString()))).OrderBy(x=>x.Key,StringComparer.OrdinalIgnoreCase).ToArray();
  var b=JsonSerializer.SerializeToUtf8Bytes(new{Schema=r.GetProperty("schema").GetInt32(),AllowedRoots=roots,BackupDirectory=Abs(r.GetProperty("backupDirectory").GetString()),RetentionDays=r.GetProperty("retentionDays").GetInt32(),MaxRecoveryBytes=r.GetProperty("maxRecoveryBytes").GetInt64(),RegistryScope=r.GetProperty("registryScope").GetString(),RegistrySessionFile=r.GetProperty("registrySessionFile").GetString(),volumes},new JsonSerializerOptions(JsonSerializerDefaults.Web){WriteIndented=true});
  return Convert.ToHexStringLower(SHA256.HashData(b));
 }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegCreateKeyExW(IntPtr root,string path,int reserved,string cls,uint options,uint access,IntPtr security,out SafeRegistryHandle key,out uint disposition);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryInfoKeyW(SafeRegistryHandle key,StringBuilder cls,ref uint length,IntPtr reserved,IntPtr subkeys,IntPtr maxSubkey,IntPtr maxClass,IntPtr values,IntPtr maxValueName,IntPtr maxValueData,IntPtr security,IntPtr written);
 [DllImport("ntdll.dll")] static extern int NtQueryKey(SafeRegistryHandle key,int information,byte[] data,int length,out int required);
 public static void CreateClass(string path,string cls) {
  if(!path.StartsWith("Software\\PrunletE2E\\",StringComparison.Ordinal)||path.Split('\\').Length<4)throw new ArgumentException("fixture scope");
  SafeRegistryHandle k;uint d;int e=RegCreateKeyExW(new IntPtr(unchecked((int)0x80000001)),path,0,cls,0,0xF013F,IntPtr.Zero,out k,out d);if(e!=0)throw new Win32Exception(e);using(k){if(d!=1)throw new Exception("Fixture collision");}
 }
 public static void CreateRunRoot(string path){
  const string prefix="Software\\PrunletE2E\\";
  if(!path.StartsWith(prefix,StringComparison.Ordinal)||!Guid.TryParseExact(path.Substring(prefix.Length),"N",out _))throw new ArgumentException("Unsafe fixture run root.");
  SafeRegistryHandle key;uint disposition;int error=RegCreateKeyExW(new IntPtr(unchecked((int)0x80000001)),path,0,"Prunlet E2E owned run",0,0xF013F,IntPtr.Zero,out key,out disposition);
  if(error!=0)throw new Win32Exception(error);using(key){if(disposition!=1)throw new InvalidOperationException("Run root already exists; no fixture mutation allowed.");}
 }
 public static string Class(RegistryKey key){uint l=4096;var b=new StringBuilder((int)l);int e=RegQueryInfoKeyW(key.Handle,b,ref l,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);if(e!=0)throw new Win32Exception(e);return b.ToString();}
 public static string Name(RegistryKey key){int n;NtQueryKey(key.Handle,3,null,0,out n);var b=new byte[n];int e=NtQueryKey(key.Handle,3,b,b.Length,out n);if(e!=0)throw new Exception("NtQueryKey:"+e);return Encoding.Unicode.GetString(b,4,BitConverter.ToInt32(b,0));}
}
