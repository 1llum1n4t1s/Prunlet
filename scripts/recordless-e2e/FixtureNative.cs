#nullable enable
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.RecordlessE2E;

public sealed class StreamProof {
    public string Name { get; set; } = "";
    public long Length { get; set; }
    public string Sha256 { get; set; } = "";
}
public sealed class NodeProof {
    public string Relative { get; set; } = "";
    public string Id { get; set; } = "";
    public ulong VolumeSerialNumber { get; set; }
    public string FileId { get; set; } = "";
    public string SecurityBase64 { get; set; } = "";
    public int Attributes { get; set; }
    public bool Directory { get; set; }
    public uint NumberOfLinks { get; set; }
    public uint ReparseTag { get; set; }
    public string ReparseBase64 { get; set; } = "";
    public StreamProof[] Streams { get; set; } = [];
}
public sealed class LookupProof { public bool Found {get;set;} public int Error {get;set;} public string? ActualId {get;set;} }

public static class FixtureNative {
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool DeviceIoControl(SafeFileHandle handle,uint code,IntPtr input,uint inputLength,byte[] output,uint outputLength,out uint returned,IntPtr overlapped);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int field,byte[] bytes,uint length);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle,out BasicInfo info);
    [StructLayout(LayoutKind.Sequential)] struct BasicInfo {public uint Attributes,CreationLow,CreationHigh,AccessLow,AccessHigh,WriteLow,WriteHigh,VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;}
    [DllImport("advapi32.dll",SetLastError=true)]
    static extern bool GetKernelObjectSecurity(SafeFileHandle handle,uint information,byte[]? bytes,uint length,out uint needed);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    struct StreamData {public long Size;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=296)]public string Name;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr FindFirstStreamW(string path,int level,out StreamData data,uint flags);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool FindNextStreamW(IntPtr search,out StreamData data);
    [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr search);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateHardLinkW(string link,string target,IntPtr security);
    [StructLayout(LayoutKind.Explicit,Size=24)] struct IdDescriptor {[FieldOffset(0)]public uint Size;[FieldOffset(4)]public uint Type;[FieldOffset(8)]public ulong Low;[FieldOffset(16)]public ulong High;}
    [DllImport("kernel32.dll",SetLastError=true)] static extern SafeFileHandle OpenFileById(SafeFileHandle hint,ref IdDescriptor id,uint access,uint share,IntPtr security,uint flags);
    public static LookupProof Lookup(string hintPath,NodeProof expected) {
        using var hint=Open(hintPath,0x80,7);var bytes=Convert.FromHexString(expected.FileId);var id=new IdDescriptor{Size=24,Type=2,Low=BitConverter.ToUInt64(bytes,0),High=BitConverter.ToUInt64(bytes,8)};
        using var found=OpenFileById(hint,ref id,0x80,7,IntPtr.Zero,0x02200000);
        if(found.IsInvalid)return new LookupProof{Found=false,Error=Marshal.GetLastWin32Error()};
        var actual=new byte[24];if(!GetFileInformationByHandleEx(found,18,actual,24))throw new Win32Exception();string actualId=Convert.ToHexString(actual);
        if(actualId!=expected.Id)throw new IOException("Fixture ID lookup returned another object.");return new LookupProof{Found=true,Error=0,ActualId=actualId};
    }

    internal static string Absolute(string path) {
        if (!Path.IsPathFullyQualified(path)) throw new IOException("Absolute fixture paths required.");
        return Path.GetFullPath(path);
    }
    static string Extended(string path) => path.StartsWith(@"\\?\",StringComparison.Ordinal) ? path : @"\\?\"+Absolute(path);
    static SafeFileHandle Open(string path,uint access,uint share) {
        var handle=CreateFileW(Extended(path),access,share,IntPtr.Zero,3,0x03200000,IntPtr.Zero);
        if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error,"Cannot open fixture: "+path);}
        return handle;
    }
    public static void WriteCaseSensitiveFile(string path, byte[] bytes) {
        using var handle=CreateFileW(Extended(path),0x40000000,0,IntPtr.Zero,1,0x01200000,IntPtr.Zero);
        if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot create exact-case fixture");
        using var stream=new FileStream(handle,FileAccess.Write);stream.Write(bytes);stream.Flush(true);
    }
    public static bool IsCaseSensitive(string path) {
        using var handle=Open(path,0x80,7);var info=new byte[4];
        if(!GetFileInformationByHandleEx(handle,23,info,4))throw new Win32Exception(Marshal.GetLastWin32Error());
        return (BitConverter.ToUInt32(info,0)&1)!=0;
    }
    static NodeProof ReadNode(SafeFileHandle handle) {
        var bytes=new byte[24];
        if(!GetFileInformationByHandleEx(handle,18,bytes,24)||!GetFileInformationByHandle(handle,out var info)) throw new Win32Exception();
        uint reparseTag=0;string reparse="";
        if((info.Attributes&(uint)FileAttributes.ReparsePoint)!=0){var data=new byte[16384];if(!DeviceIoControl(handle,0x900A8,IntPtr.Zero,0,data,(uint)data.Length,out uint returned,IntPtr.Zero))throw new Win32Exception();if(returned<8||returned>data.Length||BitConverter.ToUInt16(data,4)+8!=returned)throw new IOException("Malformed fixture reparse data");reparseTag=BitConverter.ToUInt32(data,0);if(reparseTag!=0xA0000003&&reparseTag!=0xA000000C)throw new IOException("Unknown fixture reparse tag");Array.Resize(ref data,(int)returned);reparse=Convert.ToBase64String(data);}
        bool measured=GetKernelObjectSecurity(handle,7,null,0,out uint needed);int error=Marshal.GetLastWin32Error();
        if(!measured&&error!=122)throw new Win32Exception(error);
        if(needed<20||needed>1024*1024)throw new IOException("Unbounded fixture security descriptor.");
        var descriptor=new byte[needed];if(!GetKernelObjectSecurity(handle,7,descriptor,needed,out needed))throw new Win32Exception();
        Array.Resize(ref descriptor,(int)needed);
        return new NodeProof {Id=Convert.ToHexString(bytes),VolumeSerialNumber=BitConverter.ToUInt64(bytes,0),FileId=Convert.ToHexString(bytes,8,16),SecurityBase64=Convert.ToBase64String(descriptor),Attributes=(int)info.Attributes,Directory=(info.Attributes&16)!=0,NumberOfLinks=info.Links,ReparseTag=reparseTag,ReparseBase64=reparse};
    }
    public static string Identity(string path){using var handle=Open(path,0x20080,7);return ReadNode(handle).Id;}
    public static string LegacyIdentity(string path){using var handle=Open(path,0x80,7);if(!GetFileInformationByHandle(handle,out var info))throw new Win32Exception();return $"{info.VolumeSerial:x8}:{info.IndexHigh:x8}{info.IndexLow:x8}";}
    public static SafeFileHandle HoldNoDelete(string path){var handle=Open(path,0x80020080,1);try{_=ReadNode(handle);return handle;}catch{handle.Dispose();throw;}}
    public static SafeFileHandle HoldParent(string path){var handle=Open(path,0x80020080,3);try{var proof=ReadNode(handle);if(!proof.Directory||proof.ReparseTag!=0)throw new IOException("Ordinary parent required.");return handle;}catch{handle.Dispose();throw;}}
    public static void CreateHardlink(string link,string target){if(!CreateHardLinkW(Extended(link),Extended(target),IntPtr.Zero))throw new Win32Exception();}
    static StreamProof[] ReadStreams(string path,bool directory) {
        var result=new List<StreamProof>();var search=FindFirstStreamW(Extended(path),0,out var data,0);
        if(search==new IntPtr(-1)){
            int error=Marshal.GetLastWin32Error();if(error==38&&directory)return [];
            if(error==38){using var emptyHandle=Open(path,0x80000000,1);using var empty=new FileStream(emptyHandle,FileAccess.Read);if(empty.Length==0)return [new StreamProof{Name="::$DATA",Length=0,Sha256=Convert.ToHexString(SHA256.HashData(empty))}];}
            throw new Win32Exception(error,"Cannot enumerate fixture streams.");
        }
        try{
            do{
                if(directory&&data.Name=="::$DATA")continue;
                if(data.Size<0||!data.Name.StartsWith(':')||!data.Name.EndsWith(":$DATA",StringComparison.Ordinal))throw new IOException("Unknown fixture stream.");
                string streamPath=path+(data.Name=="::$DATA"?"":data.Name);
                using var handle=Open(streamPath,0x80000000,1);using var stream=new FileStream(handle,FileAccess.Read);
                if(stream.Length!=data.Size)throw new IOException("Fixture stream size changed.");
                result.Add(new StreamProof{Name=data.Name,Length=data.Size,Sha256=Convert.ToHexString(SHA256.HashData(stream))});
            }while(FindNextStreamW(search,out data));
            if(Marshal.GetLastWin32Error()!=38)throw new Win32Exception();
        }finally{FindClose(search);}
        if(!directory&&!result.Any(s=>s.Name=="::$DATA"))throw new IOException("Default fixture stream absent.");
        return result.OrderBy(s=>s.Name,StringComparer.Ordinal).ToArray();
    }
    // 木全体を読取りpinし、全streamをhashした後にID/OGD/属性/直接member集合を再照合する。
    public static NodeProof[] SnapshotTree(string root) {
        root=Absolute(root);var handles=new List<(string Path,SafeFileHandle Handle,NodeProof Proof)>();
        var memberships=new Dictionary<string,string[]>(StringComparer.Ordinal);
        try{
            var pending=new Stack<string>();pending.Push(root);
            while(pending.Count!=0){
                string path=pending.Pop();var handle=HoldNoDelete(path);var proof=ReadNode(handle);proof.Relative=path.Substring(root.Length);handles.Add((path,handle,proof));
                if(handles.Count>65536)throw new IOException("Fixture node bound exceeded.");
                if(proof.Directory&&proof.ReparseTag==0){var children=Directory.EnumerateFileSystemEntries(path).OrderBy(s=>s,StringComparer.Ordinal).ToArray();memberships[path]=children;foreach(string child in children.Reverse())pending.Push(child);}
                proof.Streams=proof.ReparseTag==0?ReadStreams(path,proof.Directory):[];
            }
            foreach(var node in handles){var now=ReadNode(node.Handle);if(now.Id!=node.Proof.Id||now.SecurityBase64!=node.Proof.SecurityBase64||now.Attributes!=node.Proof.Attributes||now.NumberOfLinks!=node.Proof.NumberOfLinks||now.ReparseBase64!=node.Proof.ReparseBase64)throw new IOException("Fixture changed during snapshot.");}
            foreach(var pair in memberships)if(!Directory.EnumerateFileSystemEntries(pair.Key).OrderBy(s=>s,StringComparer.Ordinal).SequenceEqual(pair.Value,StringComparer.Ordinal))throw new IOException("Fixture membership changed during snapshot.");
            return handles.Select(node=>node.Proof).OrderBy(node=>node.Relative,StringComparer.Ordinal).ToArray();
        }finally{for(int i=handles.Count-1;i>=0;i--)handles[i].Handle.Dispose();}
    }
    static void RequireOwned(string path,string scope) {
        path=Absolute(path);scope=Absolute(scope).TrimEnd('\\')+"\\";
        if(!path.StartsWith(scope,StringComparison.OrdinalIgnoreCase))throw new IOException("Fixture path escaped its owned scope.");
        string? current=Path.GetDirectoryName(path);
        while(current is not null){using var handle=Open(current,0x20080,7);var proof=ReadNode(handle);if(!proof.Directory||proof.ReparseTag!=0)throw new IOException("Fixture parent is not an ordinary directory.");current=Path.GetDirectoryName(current);}
    }
    public static string? FindTracked(string pidl)=>NativeRecycleBin.Find(pidl)?.PhysicalPath;
    public static string RestoreOwned(string pidl,string physical,string expectedId,string original,string scope) {
        RequireOwned(original,scope);string parent=Path.GetDirectoryName(original)!;
        if(File.Exists(original)||Directory.Exists(original))throw new IOException("External restore destination exists.");
        var item=NativeRecycleBin.Find(pidl)??throw new IOException("Created fixture PIDL is not currently in the Bin.");
        if(item.PhysicalPath!=physical||Identity(physical)!=expectedId)throw new IOException("Created fixture Bin identity differs from its receipt.");
        using var pin=HoldParent(parent);
        string result=NativeRecycleBin.RestoreNoReplace(item,parent,Path.GetFileName(original),source=>{if(source!=physical||Identity(source)!=expectedId)throw new IOException("External restore source changed.");});
        if(result!=original||Identity(result)!=expectedId||NativeRecycleBin.Find(pidl) is not null||File.Exists(physical)||Directory.Exists(physical))throw new IOException("External restore did not consume exactly its tracked item.");
        return result;
    }
    public static void MoveOwned(string source,string destination,string expectedId,string scope) {
        RequireOwned(source,scope);RequireOwned(destination,scope);
        if(File.Exists(destination)||Directory.Exists(destination)||Identity(source)!=expectedId)throw new IOException("Nonoverwrite fixture move precondition failed.");
        var sourceProof=SnapshotTree(source);using var parentInfo=Open(Path.GetDirectoryName(destination)!,0x20080,7);var destinationParent=ReadNode(parentInfo);
        if(sourceProof[0].VolumeSerialNumber!=destinationParent.VolumeSerialNumber)throw new IOException("Fixture move must remain on its original volume.");
        using var pin=HoldParent(Path.GetDirectoryName(destination)!);
        if(sourceProof[0].Directory)Directory.Move(source,destination);else File.Move(source,destination,false);
        if(Identity(destination)!=expectedId||File.Exists(source)||Directory.Exists(source))throw new IOException("Fixture move identity changed.");
    }
}

// 今回のCMD直下の指定exeだけを停止する。製品へのtest hookは追加しない。
public sealed class OwnedBoundaryGate:IDisposable {
    [DllImport("ntdll.dll")]static extern int NtSuspendProcess(SafeProcessHandle process);
    [DllImport("ntdll.dll")]static extern int NtResumeProcess(SafeProcessHandle process);
    [DllImport("kernel32.dll",SetLastError=true)]static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags,uint pid);
    [DllImport("kernel32.dll",EntryPoint="Process32FirstW",ExactSpelling=true,CharSet=CharSet.Unicode)]static extern bool First(SafeFileHandle snapshot,ref Entry entry);
    [DllImport("kernel32.dll",EntryPoint="Process32NextW",ExactSpelling=true,CharSet=CharSet.Unicode)]static extern bool Next(SafeFileHandle snapshot,ref Entry entry);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct Entry{public uint Size,Usage,Pid;public UIntPtr Heap;public uint Module,Threads,Parent;public int Priority;public uint Flags;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)]public string Exe;}
    readonly FileSystemWatcher watcher;readonly string expected,executable,mode;readonly ManualResetEventSlim bound=new(false),reached=new(false);Process? owned;int matched;
    public bool Suspended{get;private set;}public string? Error{get;private set;}public string? ObservedPath{get;private set;}public int OwnedProcessId{get;private set;}public int SuspendCount{get;private set;}public int ResumeCount{get;private set;}
    public OwnedBoundaryGate(string watchRoot,string expectedPath,string executable,string mode="exact"){
        expected=expectedPath;this.executable=executable;this.mode=mode;watcher=new FileSystemWatcher(watchRoot){IncludeSubdirectories=true,NotifyFilter=NotifyFilters.FileName|NotifyFilters.DirectoryName};
        watcher.Created+=(s,e)=>Observe(e.FullPath,false);watcher.Renamed+=(s,e)=>Observe(e.FullPath,false);watcher.Deleted+=(s,e)=>Observe(e.FullPath,true);watcher.Error+=(s,e)=>{Error=e.GetException().Message;reached.Set();};watcher.EnableRaisingEvents=true;
    }
    void Observe(string path,bool deleted){if((mode=="deleted")!=deleted||!path.Equals(expected,StringComparison.OrdinalIgnoreCase)||Interlocked.CompareExchange(ref matched,1,0)!=0)return;try{if(!bound.Wait(10000)||owned==null)throw new IOException("Owned CLI was not bound.");int status=NtSuspendProcess(owned.SafeHandle);if(status<0)throw new IOException("Suspend NTSTATUS "+status);SuspendCount++;Suspended=true;ObservedPath=path;}catch(Exception ex){Error=ex.ToString();}finally{reached.Set();}}
    public void Bind(Process launcher){try{var clock=Stopwatch.StartNew();while(clock.ElapsedMilliseconds<10000&&!launcher.HasExited){using var snapshot=CreateToolhelp32Snapshot(2,0);if(snapshot.IsInvalid)throw new Win32Exception();var entry=new Entry{Size=(uint)Marshal.SizeOf<Entry>()};if(First(snapshot,ref entry)){do{if(entry.Parent!=(uint)launcher.Id||!entry.Exe.Equals(Path.GetFileName(executable),StringComparison.OrdinalIgnoreCase))continue;var child=Process.GetProcessById((int)entry.Pid);if(child.MainModule?.FileName?.Equals(executable,StringComparison.OrdinalIgnoreCase)==true){owned=child;OwnedProcessId=child.Id;_=child.SafeHandle;return;}child.Dispose();}while(Next(snapshot,ref entry));}Thread.Sleep(2);}Error="Owned CLI binding expired.";reached.Set();}finally{bound.Set();}}
    public bool Wait(int milliseconds)=>reached.Wait(milliseconds);
    public void Resume(){if(!Suspended)return;if(owned!=null&&!owned.HasExited){if(NtResumeProcess(owned.SafeHandle)<0)throw new IOException("Cannot resume owned CLI.");ResumeCount++;}Suspended=false;}
    public void KillOwned(){if(owned!=null&&!owned.HasExited){owned.Kill();owned.WaitForExit();}Suspended=false;}
    public void Dispose(){watcher.Dispose();try{Resume();}finally{owned?.Dispose();bound.Dispose();reached.Dispose();}}
}
