using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
public static class PrunletRegistryE2E {
 static RegistryHive Hive;
 static IntPtr Root;
 static string FixturePrefix;
 public static void Configure(bool machine,string fixturePrefix) {
  string allowed=machine?"SYSTEM\\PrunletE2E\\":"Software\\PrunletE2E\\";
  string suffix=fixturePrefix.StartsWith(allowed,StringComparison.OrdinalIgnoreCase)?fixturePrefix.Substring(allowed.Length):"";
  if(suffix.Length!=32||!Guid.TryParseExact(suffix,"N",out _))throw new ArgumentException("Unsafe fixture namespace.");
  Hive=machine?RegistryHive.LocalMachine:RegistryHive.CurrentUser;
  Root=new IntPtr(machine?unchecked((int)0x80000002):unchecked((int)0x80000001)); FixturePrefix=fixturePrefix;
 }
 static void CheckFixture(string relative) {
  if(FixturePrefix==null||!(relative.Equals(FixturePrefix,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(FixturePrefix+"\\",StringComparison.OrdinalIgnoreCase)))throw new ArgumentException("Registry fixture escaped its unique run root.");
 }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegSetValueExW(SafeRegistryHandle k,string n,int r,uint t,byte[] b,int l);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryValueExW(SafeRegistryHandle k,string n,IntPtr r,out uint t,byte[] b,ref uint l);
 [DllImport("advapi32.dll")] static extern int RegGetKeySecurity(SafeRegistryHandle k,uint i,byte[] b,ref uint l);
 [DllImport("advapi32.dll")] static extern int RegSetKeySecurity(SafeRegistryHandle k,uint information,byte[] descriptor);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr root,string path,uint options,uint access,out SafeRegistryHandle key);
 [DllImport("advapi32.dll",EntryPoint="RegOpenKeyExW",CharSet=CharSet.Unicode)] static extern int ReopenSecurity(SafeRegistryHandle root,string path,uint options,uint access,out SafeRegistryHandle key);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint a,out IntPtr t);
 [StructLayout(LayoutKind.Sequential)] struct Luid { public uint LowPart; public int HighPart; }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string s,string n,out Luid l);
 [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
 [StructLayout(LayoutKind.Sequential)] struct PrivilegeSet { public uint Count; public uint Control; public Luid Luid; public uint Attributes; }
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr t,bool d,ref Privileges p,uint l,IntPtr b,IntPtr r);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool PrivilegeCheck(IntPtr token,ref PrivilegeSet privileges,out bool enabled);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static bool EnableSecurity() {
  IntPtr token; if(!OpenProcessToken(GetCurrentProcess(),0x28,out token)) return false;
  try { Luid id; if(!LookupPrivilegeValue(null,"SeSecurityPrivilege",out id))return false;
   var p=new Privileges{Count=1,Luid=id,Attributes=2};
   if(!AdjustTokenPrivileges(token,false,ref p,0,IntPtr.Zero,IntPtr.Zero)||Marshal.GetLastWin32Error()!=0)return false;
   var required=new PrivilegeSet{Count=1,Control=1,Luid=id,Attributes=2};
   bool enabled;return PrivilegeCheck(token,ref required,out enabled)&&enabled;
  } finally { CloseHandle(token); }
 }
 public static RegistryKey Open(string relative,int view,bool security=false) {
  CheckFixture(relative);
  SafeRegistryHandle h; int e=RegOpenKeyExW(Root,relative,0,(uint)(0x20019|(view==32?0x200:0x100)|(security?0x1000000:0)),out h);
  if(e==2)return null; if(e!=0)throw new Win32Exception(e); return RegistryKey.FromHandle(h,view==32?RegistryView.Registry32:RegistryView.Registry64);
 }
 public static RegistryKey Create(string relative,int view) {
  CheckFixture(relative);
  using(var root=RegistryKey.OpenBaseKey(Hive,view==32?RegistryView.Registry32:RegistryView.Registry64)) return root.CreateSubKey(relative,true);
 }
 public static void Set(RegistryKey k,string name,uint type,byte[] data) { int e=RegSetValueExW(k.Handle,name,0,type,data,data.Length);if(e!=0)throw new Win32Exception(e); }
 public static void SetLowIntegrityFixture(string relative,int view) {
  CheckFixture(relative);
  var descriptor=new System.Security.AccessControl.RawSecurityDescriptor("S:(ML;;NW;;;LW)");
  var bytes=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(bytes,0);
  SafeRegistryHandle handle;
  int e=RegOpenKeyExW(Root,relative,0,(uint)(0x80000|(view==32?0x200:0x100)),out handle);
  if(e!=0)throw new Win32Exception(e);
  using(handle) { e=RegSetKeySecurity(handle,0x10,bytes);if(e!=0)throw new Win32Exception(e); }
 }
 public static string Value(RegistryKey k,string name) {
  uint t,l=0;int e=RegQueryValueExW(k.Handle,name,IntPtr.Zero,out t,null,ref l);if(e==2)return null;if(e!=0)throw new Win32Exception(e);
  byte[] b=new byte[l];e=RegQueryValueExW(k.Handle,name,IntPtr.Zero,out t,b,ref l);if(e!=0)throw new Win32Exception(e);return t+":"+Convert.ToBase64String(b);
 }
 public static string Security(RegistryKey k) {
  SafeRegistryHandle securityHandle;
  int e=ReopenSecurity(k.Handle,"",0,0x01020000,out securityHandle);if(e!=0)throw new Win32Exception(e);
  using(securityHandle) {
   uint l=0;e=RegGetKeySecurity(securityHandle,0x10000,null,ref l);if(e!=122&&e!=0)throw new Win32Exception(e);
   byte[] b=new byte[l];e=RegGetKeySecurity(securityHandle,0x10000,b,ref l);if(e!=0)throw new Win32Exception(e);return Convert.ToBase64String(b);
  }
 }
 public static string[] Snapshot(string relative,int view) {
  var rows=new List<string>(); Walk(relative,"",view,rows); rows.Sort(StringComparer.Ordinal);return rows.ToArray();
 }
 static void Walk(string relative,string label,int view,List<string> rows) {
  using(var k=Open(relative,view,true)) { if(k==null)throw new Exception("Snapshot key missing: "+relative);
   rows.Add("K:"+label+":"+Security(k)); foreach(var name in k.GetValueNames())rows.Add("V:"+label+":"+Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(name))+":"+Value(k,name));
   foreach(var child in k.GetSubKeyNames())Walk(relative+"\\"+child,label+"\\"+child,view,rows);
  }
 }
}