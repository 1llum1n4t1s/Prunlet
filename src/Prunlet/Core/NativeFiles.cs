using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static class NativeFiles
{
    private const uint Read = 0x80000000, Write = 0x40000000, Delete = 0x00010000;
    private const uint OpenReparse = 0x00200000, BackupSemantics = 0x02000000;
    private const int FileCaseSensitiveInfo = 23;
    private const uint CaseSensitiveDirectory = 0x00000001;

    internal static SafeFileHandle OpenDirectory(string path) => Open(path, 0x80, 3, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenSource(string path) => Open(path, Read | Delete, 1, 3, OpenReparse);
    internal static SafeFileHandle OpenBackup(string path) => Open(path, Read, 1, 3, OpenReparse);
    internal static SafeFileHandle CreateDestination(string path) => Open(path, Read | Write | Delete, 1, 1, OpenReparse);
    internal static SafeFileHandle OpenLock(string path) => Open(path, Read | Write, 0, 3, OpenReparse);

    internal static void CreateDirectory(string path)
    {
        if (!CreateDirectoryW(path, IntPtr.Zero)) ThrowLastError("Cannot exclusively create operation directory");
    }

    internal static void RejectNamedStreams(string path)
    {
        var search = FindFirstStreamW(path, 0, out var data, 0);
        if (search == new IntPtr(-1))
        {
            if (Marshal.GetLastWin32Error() == 38) return;
            ThrowLastError("Cannot inspect alternate data streams");
        }
        try
        {
            do
            {
                if (data.Name != "::$DATA") throw new IOException("Files with alternate data streams cannot be deleted because the backup stores only the unnamed stream.");
            } while (FindNextStreamW(search, out data));
            if (Marshal.GetLastWin32Error() != 38) ThrowLastError("Cannot finish alternate data stream inspection");
        }
        finally { FindClose(search); }
    }

    private static SafeFileHandle Open(string path, uint access, uint share, uint disposition, uint flags)
    {
        var handle = CreateFileW(path, access, share, IntPtr.Zero, disposition, flags, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        if (error == 2) throw new FileNotFoundException("File does not exist.", path);
        if (error == 3) throw new DirectoryNotFoundException("A parent directory does not exist.");
        throw new IOException($"Cannot open {path}: {new Win32Exception(error).Message}", new Win32Exception(error));
    }

    internal static void Verify(SafeFileHandle handle, string expected, bool directory = false)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect file handle");
        if ((info.Attributes & (uint)FileAttributes.ReparsePoint) != 0
            || ((info.Attributes & (uint)FileAttributes.Directory) != 0) != directory)
            throw new IOException("Handle does not refer to an ordinary file/directory.");
        if (directory)
        {
            // 大文字小文字を無視する境界比較は、全祖先が通常のWindowsディレクトリの場合に限る。
            // 未対応OS/ファイルシステムなど、判定不能の場合も許可しない。
            if (!GetFileInformationByHandleEx(handle, FileCaseSensitiveInfo, out var caseInfo, (uint)Marshal.SizeOf<CaseSensitiveInformation>()))
                ThrowLastError("Cannot verify directory case sensitivity; this OS/filesystem is unsupported");
            if ((caseInfo.Flags & CaseSensitiveDirectory) != 0)
                throw new IOException($"Case-sensitive directories are not supported: {expected}");
        }
        var buffer = new StringBuilder(32768);
        var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
        if (length == 0 || length >= buffer.Capacity) ThrowLastError("Cannot resolve file handle path");
        var actual = buffer.ToString();
        if (actual.StartsWith("\\\\?\\", StringComparison.Ordinal)) actual = actual[4..];
        if (!actual.TrimEnd('\\').Equals(expected.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            throw new IOException("Resolved handle path differs from the validated path (aliases are not supported).");
    }

    internal static void DeleteHandle(SafeFileHandle handle)
    {
        var disposition = new FileDisposition { DeleteFile = true };
        if (!SetFileInformationByHandle(handle, 4, ref disposition, (uint)Marshal.SizeOf<FileDisposition>()))
            ThrowLastError("Cannot mark file for deletion");
    }

    private static void ThrowLastError(string message) => throw new IOException($"{message}: {new Win32Exception(Marshal.GetLastWin32Error()).Message}");

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerial, FileSizeHigh, FileSizeLow, Links, FileIndexHigh, FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileDisposition { [MarshalAs(UnmanagedType.U1)] public bool DeleteFile; }

    [StructLayout(LayoutKind.Sequential)]
    private struct CaseSensitiveInformation { public uint Flags; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StreamInformation
    {
        public long Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)] public string Name;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(string path, IntPtr security);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstStreamW(string path, int infoLevel, out StreamInformation data, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindNextStreamW(IntPtr search, out StreamInformation data);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindClose(IntPtr search);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, out CaseSensitiveInformation info, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, ref FileDisposition info, uint size);
}
