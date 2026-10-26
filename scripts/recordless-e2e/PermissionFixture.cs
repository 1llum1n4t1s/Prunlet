using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Diagnostics;
using Microsoft.Win32.SafeHandles;
namespace Prunlet.RecordlessE2E;
public static class PermissionFixture {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint access,uint share,IntPtr s,uint mode,uint flags,IntPtr t);
 [DllImport("ntdll.dll")]static extern int NtSetSecurityObject(SafeFileHandle h,uint information,byte[] sd);
 [DllImport("ntdll.dll")]static extern int NtQueryObject(SafeFileHandle h,int cls,byte[] data,int size,out int needed);
 [DllImport("advapi32.dll",SetLastError=true)]static extern bool GetKernelObjectSecurity(SafeFileHandle h,uint information,byte[] bytes,uint length,out uint needed);
 [DllImport("kernel32.dll",SetLastError=true)]static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags,uint pid);
 [DllImport("kernel32.dll",EntryPoint="Process32FirstW",ExactSpelling=true,CharSet=CharSet.Unicode)]static extern bool First(SafeFileHandle snapshot,ref Entry entry);
 [DllImport("kernel32.dll",EntryPoint="Process32NextW",ExactSpelling=true,CharSet=CharSet.Unicode)]static extern bool Next(SafeFileHandle snapshot,ref Entry entry);
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct Entry{public uint Size,Usage,Pid;public UIntPtr Heap;public uint Module,Threads,Parent;public int Priority;public uint Flags;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)]public string Exe;}
 public static Process FindChild(int parent,string executable){using(var snapshot=CreateToolhelp32Snapshot(2,0)){if(snapshot.IsInvalid)throw new Win32Exception();var entry=new Entry{Size=(uint)Marshal.SizeOf<Entry>()};if(First(snapshot,ref entry)){do{if(entry.Parent!=(uint)parent)continue;Process child=null;try{child=Process.GetProcessById((int)entry.Pid);if(child.MainModule?.FileName?.Equals(executable,StringComparison.OrdinalIgnoreCase)==true){_=child.SafeHandle;return child;}}catch(InvalidOperationException){}catch(ArgumentException){}catch(Win32Exception){}child?.Dispose();}while(Next(snapshot,ref entry));}return null;}}
 public static byte[] Security(string path){using(var h=CreateFileW(path,0x20080,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)){if(h.IsInvalid)throw new Win32Exception();bool result=GetKernelObjectSecurity(h,7,null,0,out uint needed);if(result||Marshal.GetLastWin32Error()!=122||needed<20||needed>1048576)throw new IOException("Invalid O/G/D length");var bytes=new byte[needed];if(!GetKernelObjectSecurity(h,7,bytes,needed,out needed))throw new Win32Exception();return bytes;}}
 public static uint GrantedAccess(SafeFileHandle handle){var bytes=new byte[56];int status=NtQueryObject(handle,0,bytes,56,out int needed);if(status<0||needed!=56)throw new IOException("PUBLIC_OBJECT_BASIC_INFORMATION query failed "+status+"/"+needed);return BitConverter.ToUInt32(bytes,4);}
 public static int ReadDataError(string path){using(var h=CreateFileW(path,0x80000000,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)){return h.IsInvalid?Marshal.GetLastWin32Error():0;}}
 public static void SetDacl(string path,byte[] sd){var descriptor=new RawSecurityDescriptor(sd,0);if((descriptor.ControlFlags&ControlFlags.DiscretionaryAclAutoInherited)!=0)descriptor.SetFlags(descriptor.ControlFlags|ControlFlags.DiscretionaryAclAutoInheritRequired);var input=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(input,0);using(var h=CreateFileW(path,0x60000,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)){if(h.IsInvalid)throw new Win32Exception();int status=NtSetSecurityObject(h,4,input);if(status<0)throw new IOException("Fixture DACL failed "+status);}}
 public static void DenyDataRead(string path,byte[] original){var descriptor=new RawSecurityDescriptor(original,0);var acl=descriptor.DiscretionaryAcl;if(acl==null)throw new IOException("Explicit DACL required");acl.InsertAce(0,new CommonAce(AceFlags.None,AceQualifier.AccessDenied,1,WindowsIdentity.GetCurrent().User,false,null));var bytes=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(bytes,0);SetDacl(path,bytes);}
}
