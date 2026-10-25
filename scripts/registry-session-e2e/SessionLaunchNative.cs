using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class SessionLaunchNative {
 [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder path,ref uint length);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out long creation,out long exit,out long kernel,out long user);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out SafeAccessTokenHandle token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(SafeAccessTokenHandle token,int field,byte[] bytes,uint length,out uint required);
 [DllImport("advapi32.dll",EntryPoint="GetTokenInformation",SetLastError=true)] static extern bool TokenBuffer(SafeAccessTokenHandle token,int field,IntPtr bytes,uint length,out uint required);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern int GetPackageFullName(IntPtr process,ref uint length,StringBuilder name);
 static byte[] Field(SafeAccessTokenHandle token,int field){GetTokenInformation(token,field,null,0,out uint length);if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error());var bytes=new byte[length];if(!GetTokenInformation(token,field,bytes,length,out _))throw new Win32Exception(Marshal.GetLastWin32Error());return bytes;}
 static string Owner(SafeAccessTokenHandle token){TokenBuffer(token,1,IntPtr.Zero,0,out uint length);var buffer=Marshal.AllocHGlobal((int)length);try{if(!TokenBuffer(token,1,buffer,length,out _))throw new Win32Exception(Marshal.GetLastWin32Error());return new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value;}finally{Marshal.FreeHGlobal(buffer);}}
 public static Dictionary<string,object> ProcessInfo(int pid){
  var process=OpenProcess(0x1000,false,pid);if(process==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
  try{
   if(!OpenProcessToken(process,8,out var token))throw new Win32Exception(Marshal.GetLastWin32Error());
   using(token){var statistics=Field(token,10);uint length=32768;var path=new StringBuilder((int)length);
    if(!QueryFullProcessImageName(process,0,path,ref length)||!GetProcessTimes(process,out long creation,out _,out _,out _))throw new Win32Exception(Marshal.GetLastWin32Error());uint packageLength=0;
    return new Dictionary<string,object>{{"ownerSid",Owner(token)},{"authenticationId",$"{BitConverter.ToUInt32(statistics,12):X8}:{BitConverter.ToUInt32(statistics,8):X8}"},{"windowsSessionId",BitConverter.ToUInt32(Field(token,12),0)},{"isAdministrator",BitConverter.ToUInt32(Field(token,20),0)!=0},{"isAppContainer",BitConverter.ToUInt32(Field(token,29),0)!=0},{"packaged",GetPackageFullName(process,ref packageLength,null)!=15700},{"path",path.ToString()},{"creationFileTime",creation},{"creationTicks",DateTime.FromFileTimeUtc(creation).Ticks},{"pid",pid}};
   }
  }finally{CloseHandle(process);}
 }
 public static Dictionary<string,object> DesktopInfo(){var window=GetShellWindow();if(window==IntPtr.Zero)throw new InvalidOperationException("Desktop shell missing.");GetWindowThreadProcessId(window,out uint pid);var result=ProcessInfo((int)pid);result["hwnd"]=window.ToInt64();return result;}
}
