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
    internal static SafeFileHandle OpenInspect(string path) => Open(path, 0x80, 3, 3, OpenReparse);
    internal static SafeFileHandle OpenAny(string path) => Open(path, 0x80, 3, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenSpecial(string path, bool deleting = false) => Open(path, Read | (deleting ? Delete : 0u), 1, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenDirectorySource(string path) => Open(path, 0x80 | Delete, 3, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenSource(string path) => Open(path, Read | Delete, 1, 3, OpenReparse);
    internal static SafeFileHandle OpenBackup(string path) => Open(path, Read, 1, 3, OpenReparse);
    internal static SafeFileHandle OpenPurgeTarget(string path) => Open(path, Read | Delete, 1, 3, OpenReparse);
    internal static SafeFileHandle CreateDestination(string path) => Open(path, Read | Write | Delete, 1, 1, OpenReparse);
    internal static SafeFileHandle OpenLock(string path) => Open(path, Read | Write, 0, 3, OpenReparse);

    internal static void CreateDirectory(string path)
    {
        if (!CreateDirectoryW(Win32Path(path), IntPtr.Zero)) ThrowLastError("Cannot exclusively create operation directory");
    }

    // FILE_CREATE は既存名を拒否し、作成したディレクトリそのもののハンドルを返す。
    internal static SafeFileHandle CreateDirectoryDestination(string path)
    {
        var name = @"\??\" + PathPolicy.Absolute(path);
        if (name.Length > 32766) throw new ArgumentException("Directory path is too long.");
        var text = Marshal.StringToHGlobalUni(name);
        var unicodeBuffer = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
        try
        {
            Marshal.StructureToPtr(new UnicodeString { Length = (ushort)(name.Length * 2), MaximumLength = (ushort)((name.Length + 1) * 2), Buffer = text }, unicodeBuffer, false);
            var attributes = new ObjectAttributes { Length = Marshal.SizeOf<ObjectAttributes>(), ObjectName = unicodeBuffer };
            var status = NtCreateFile(out var handle, Read | Write | Delete | 0x00100000, ref attributes, out _, IntPtr.Zero,
                (uint)FileAttributes.Normal, 1, 2, 0x00204021, IntPtr.Zero, 0);
            if (status >= 0) return handle;
            handle.Dispose();
            throw new IOException($"Cannot exclusively create directory: {new Win32Exception((int)RtlNtStatusToDosError(status)).Message}");
        }
        finally { Marshal.FreeHGlobal(unicodeBuffer); Marshal.FreeHGlobal(text); }
    }

    internal static void RejectNamedStreams(string path)
    {
        var search = FindFirstStreamW(Win32Path(path), 0, out var data, 0);
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
        var handle = CreateFileW(Win32Path(path), access, share, IntPtr.Zero, disposition, flags, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        if (error == 2) throw new FileNotFoundException("File does not exist.", path);
        if (error == 3) throw new DirectoryNotFoundException("A parent directory does not exist.");
        throw new IOException($"Cannot open {path}: {new Win32Exception(error).Message}", new Win32Exception(error));
    }

    // 入力の許可条件を保ち、Win32 呼び出しの直前だけ長いパス形式へ変換する。
    private static string Win32Path(string path) => @"\\?\" + PathPolicy.Absolute(path);

    internal static void Verify(SafeFileHandle handle, string expected, bool directory = false)
    {
        var actual = ResolveVerified(handle, directory);
        if (!actual.TrimEnd('\\').Equals(expected.TrimEnd('\\'), StringComparison.Ordinal))
            throw new IOException("Resolved handle path differs from the validated canonical path.");
    }

    // 表記の一致と、通常ファイル/ディレクトリであることの検査を分離する。
    internal static string ResolveVerified(SafeFileHandle handle, bool directory = false)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect file handle");
        if ((info.Attributes & (uint)FileAttributes.ReparsePoint) != 0
            || ((info.Attributes & (uint)FileAttributes.Directory) != 0) != directory)
            throw new IOException("Handle does not refer to an ordinary file/directory.");
        if (directory) _ = IsCaseSensitive(handle);
        return FinalPath(handle);
    }

    internal static string FinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(32768);
        var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
        if (length == 0 || length >= buffer.Capacity) ThrowLastError("Cannot resolve file handle path");
        var actual = buffer.ToString();
        return PathPolicy.Absolute(actual);
    }

    internal static bool IsReparse(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect handle type");
        return (info.Attributes & (uint)FileAttributes.ReparsePoint) != 0;
    }

    internal static uint LinkCount(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect link count");
        return info.Links;
    }

    internal static bool IsCaseSensitive(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleEx(handle, FileCaseSensitiveInfo, out var info, (uint)Marshal.SizeOf<CaseSensitiveInformation>()))
            ThrowLastError("Cannot inspect directory case sensitivity");
        return (info.Flags & CaseSensitiveDirectory) != 0;
    }

    internal static void SetCaseSensitive(SafeFileHandle handle, bool enabled)
    {
        var info = new CaseSensitiveInformation { Flags = enabled ? CaseSensitiveDirectory : 0u };
        if (!SetFileInformationByHandle(handle, FileCaseSensitiveInfo, ref info, (uint)Marshal.SizeOf<CaseSensitiveInformation>()))
            ThrowLastError("Cannot restore directory case sensitivity");
    }

    internal static void RejectCaseSensitive(SafeFileHandle handle)
    {
        if (IsCaseSensitive(handle)) throw new IOException("Recovery storage cannot use case-sensitive directories.");
    }

    internal static List<string> NamedStreams(string path)
    {
        using var handle = OpenAny(path);
        return NamedStreams(handle);
    }

    internal static List<string> NamedStreams(SafeFileHandle handle)
    {
        var names = new List<string>();
        var size = 65536;
        while (true)
        {
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetFileInformationByHandleEx(handle, 7, buffer, (uint)size))
                {
                    var error = Marshal.GetLastWin32Error();
                    if ((error is 234 or 122) && size < 8 * 1024 * 1024) { size *= 2; continue; }
                    if (error == 38) return names;
                    ThrowLastError("Cannot inspect alternate streams by object handle");
                }
                var offset = 0;
                while (true)
                {
                    if (offset > size - 24) throw new IOException("Invalid stream information buffer.");
                    var next = Marshal.ReadInt32(buffer, offset); var nameBytes = Marshal.ReadInt32(buffer, offset + 4);
                    if (nameBytes < 0 || nameBytes % 2 != 0 || nameBytes > size - offset - 24)
                        throw new IOException("Invalid stream name buffer.");
                    var wireName = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 24), nameBytes / 2)!;
                    if (wireName != "::$DATA")
                    {
                        if (!wireName.StartsWith(':') || !wireName.EndsWith(":$DATA", StringComparison.Ordinal))
                            throw new IOException("Unsupported stream type.");
                        var name = wireName[1..^6]; ValidateStreamName(name); names.Add(name);
                    }
                    if (next == 0) break;
                    if (next < 24 || next > size - offset) throw new IOException("Invalid stream information offset.");
                    offset += next;
                }
                return names.Order(StringComparer.Ordinal).ToList();
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    internal static void ValidateStreamName(string name)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 255 || name.IndexOfAny([':', '\\', '/', '*', '?', '"', '<', '>', '|']) >= 0
            || name.Any(char.IsControl))
            throw new InvalidDataException("Invalid alternate stream name.");
    }

    internal static SafeFileHandle OpenStream(string path, string name, bool create = false)
    {
        ValidateStreamName(name);
        // ストリーム名の末尾空白・ピリオドも保持し、型を明示して同名の別ストリームを取り違えない。
        var handle = CreateFileW(Win32Path(path) + ":" + name + ":$DATA", create ? Read | Write : Read, 5,
            IntPtr.Zero, create ? 1u : 3u, OpenReparse | BackupSemantics, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); ThrowLastError("Cannot open alternate stream"); }
        return handle;
    }

    internal static byte[] ReadReparse(SafeFileHandle handle)
    {
        var bytes = new byte[16384];
        if (!DeviceIoControl(handle, 0x000900A8, null, 0, bytes, bytes.Length, out var count, IntPtr.Zero))
            ThrowLastError("Cannot read reparse point");
        Array.Resize(ref bytes, count);
        ValidateReparse(bytes);
        return bytes;
    }

    internal static uint ValidateReparse(byte[] bytes)
    {
        if (bytes.Length < 16 || bytes.Length > 16384 || BitConverter.ToUInt16(bytes, 4) != bytes.Length - 8 || BitConverter.ToUInt16(bytes, 6) != 0)
            throw new InvalidDataException("Invalid reparse buffer size.");
        var tag = BitConverter.ToUInt32(bytes, 0);
        var prefix = tag switch { 0xa0000003 => 16, 0xa000000c => 20, _ => throw new InvalidDataException("Unsupported reparse tag; only junctions and symbolic links are supported.") };
        if (bytes.Length < prefix || (tag == 0xa000000c && BitConverter.ToUInt32(bytes, 16) > 1))
            throw new InvalidDataException("Invalid reparse flags.");
        for (var i = 8; i < 16; i += 4)
        {
            var offset = BitConverter.ToUInt16(bytes, i); var size = BitConverter.ToUInt16(bytes, i + 2);
            if (offset % 2 != 0 || size % 2 != 0 || prefix + offset + size > bytes.Length)
                throw new InvalidDataException("Invalid reparse name offsets.");
        }
        if (BitConverter.ToUInt16(bytes, 10) == 0) throw new InvalidDataException("Empty reparse target.");
        return tag;
    }

    internal static void WriteReparse(SafeFileHandle handle, byte[] bytes)
    {
        ValidateReparse(bytes);
        if (!DeviceIoControl(handle, 0x000900A4, bytes, bytes.Length, null, 0, out _, IntPtr.Zero))
            ThrowLastError("Cannot restore reparse point");
        if (!ReadReparse(handle).SequenceEqual(bytes)) throw new IOException("Restored reparse buffer differs.");
    }

    internal static string SymbolicTarget(byte[] bytes)
    {
        if (ValidateReparse(bytes) != 0xa000000c) throw new InvalidDataException("Expected a symbolic link.");
        var target = new UnicodeEncoding(false, false, true).GetString(bytes, 20 + BitConverter.ToUInt16(bytes, 8), BitConverter.ToUInt16(bytes, 10));
        if (target.IndexOf('\0') >= 0) throw new InvalidDataException("Embedded NUL in symbolic link target.");
        if (BitConverter.ToUInt32(bytes, 16) == 1) return target;
        if (!target.StartsWith(@"\??\", StringComparison.Ordinal)) throw new InvalidDataException("Unsupported absolute symbolic link target namespace.");
        target = target[4..];
        return target.StartsWith(@"UNC\", StringComparison.OrdinalIgnoreCase) ? @"\\" + target[4..] : @"\\?\" + target;
    }

    internal static void CreateSymbolicDestination(string path, byte[] bytes, bool directory)
    {
        var target = SymbolicTarget(bytes);
        // Developer Modeを利用できるOSの公開APIを使い、ホストの権限設定は変更しない。
        if (!CreateSymbolicLinkW(Win32Path(path), target, (directory ? 1u : 0u) | 2u)) ThrowLastError("Cannot exclusively restore symbolic link");
        using var handle = OpenAny(path);
        var restored = ReadReparse(handle);
        if (!IsReparse(handle) || IsDirectory(handle) != directory || SymbolicTarget(restored) != target
            || BitConverter.ToUInt32(restored, 16) != BitConverter.ToUInt32(bytes, 16))
            throw new IOException("Restored symbolic link target or type differs; the created link was retained for inspection.");
    }

    internal static void VerifySingleLink(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect recovery file handle");
        if (info.Links != 1)
            throw new IOException("Recovery files with multiple hard links cannot be purged.");
    }

    internal static bool IsDirectory(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect handle type");
        return (info.Attributes & (uint)FileAttributes.Directory) != 0;
    }

    internal static string Identity(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect handle identity");
        return $"{info.VolumeSerial:x8}:{info.FileIndexHigh:x8}{info.FileIndexLow:x8}";
    }

    internal static void DeleteHandle(SafeFileHandle handle)
        => SetDeletePending(handle, true);

    internal static void SetDeletePending(SafeFileHandle handle, bool pending)
    {
        var disposition = new FileDisposition { DeleteFile = pending };
        if (!SetFileInformationByHandle(handle, 4, ref disposition, (uint)Marshal.SizeOf<FileDisposition>()))
            ThrowLastError(pending ? "Cannot mark file for deletion" : "Cannot cancel pending deletion");
    }

    internal static void RenameHandle(SafeFileHandle handle, string destination)
    {
        var name = Encoding.Unicode.GetBytes(Win32Path(destination));
        // FILE_RENAME_INFO の HANDLE は自然境界へ整列する。FileNameLength は UTF-16 のバイト数。
        var rootOffset = IntPtr.Size == 8 ? 8 : 4;
        var lengthOffset = rootOffset + IntPtr.Size;
        var nameOffset = lengthOffset + sizeof(uint);
        var size = checked(nameOffset + name.Length + sizeof(char));
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            // ReplaceIfExists=false、RootDirectory=NULL。既存の公開済み記録は置換しない。
            Marshal.Copy(new byte[size], 0, buffer, size);
            Marshal.WriteInt32(buffer, lengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
            if (!SetFileInformationByHandle(handle, 3, buffer, (uint)size))
                ThrowLastError("Cannot atomically publish file without replacing an existing destination");
        }
        finally { Marshal.FreeHGlobal(buffer); }
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

    [StructLayout(LayoutKind.Sequential)]
    private struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ObjectAttributes { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }

    [DllImport("ntdll.dll")]
    private static extern int NtCreateFile(out SafeFileHandle handle, uint access, ref ObjectAttributes attributes, out IoStatusBlock status,
        IntPtr allocationSize, uint fileAttributes, uint share, uint disposition, uint options, IntPtr eaBuffer, uint eaLength);
    [DllImport("ntdll.dll")]
    private static extern uint RtlNtStatusToDosError(int status);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    private static extern bool CreateSymbolicLinkW(string path, string target, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref CaseSensitiveInformation information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, IntPtr information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[]? input, int inputSize, byte[]? output, int outputSize, out int returned, IntPtr overlapped);

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
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, IntPtr info, uint size);
}
