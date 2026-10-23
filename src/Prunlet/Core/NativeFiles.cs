using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static partial class NativeFiles
{
    private const uint Read = 0x80000000, Write = 0x40000000, Delete = 0x00010000;
    private const uint OpenReparse = 0x00200000, BackupSemantics = 0x02000000;
    private const int FileCaseSensitiveInfo = 23;
    private const uint CaseSensitiveDirectory = 0x00000001;
    // FileBasicInfoで復元できる通常属性。構造・圧縮・暗号化属性は含めない。
    internal const uint RestorableAttributeMask = 0x31a7;

    internal static SafeFileHandle OpenDirectory(string path) => Open(path, 0x80, 3, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenInspect(string path) => Open(path, 0x80, 3, 3, OpenReparse);
    internal static SafeFileHandle OpenAny(string path) => Open(path, 0x80, 3, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenRestoreMetadata(string path) => Open(path, 0x180, 3, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenBackup(string path) => Open(path, Read, 1, 3, OpenReparse);
    internal static SafeFileHandle OpenHistoryCompression(string path) => Open(path, Read | Write, 1, 3, OpenReparse);
    internal static SafeFileHandle OpenPurgeTarget(string path) => Open(path, Read | Delete, 1, 3, OpenReparse);
    internal static SafeFileHandle CreateDestination(string path) => Open(path, Read | Write | Delete, 1, 1, OpenReparse);
    internal static SafeFileHandle OpenLock(string path) => Open(path, Read | Write, 0, 3, OpenReparse);
    internal static SafeFileHandle OpenOrCreateLock(string path) => Open(path, Read | Write, 0, 4, OpenReparse);

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

    // winioctl.h: FSCTL_GET_COMPRESSION (15), FSCTL_SET_COMPRESSION (16).
    // winbase.h: FileCompressionInfo / FILE_COMPRESSION_INFO。パスによる容量再解決をしない。
    internal static (ushort Format, long PhysicalBytes) HistoryCompressionInfo(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var attributes)) ThrowLastError("Cannot inspect history attributes");
        const uint allowed = (uint)(FileAttributes.Normal | FileAttributes.Archive | FileAttributes.Compressed | FileAttributes.NotContentIndexed);
        if ((attributes.Attributes & ~allowed) != 0)
            throw new IOException("History compression requires an ordinary writable file without sparse, encrypted, offline, or unknown attributes.");
        var fileSystem = new StringBuilder(64);
        if (!GetVolumeInformationByHandleW(handle, null, 0, out _, out _, out var flags, fileSystem, (uint)fileSystem.Capacity))
            ThrowLastError("Cannot inspect history filesystem");
        if (fileSystem.ToString() != "NTFS" || (flags & 0x10) == 0)
            throw new IOException("History compression requires NTFS file compression support.");
        var bytes = new byte[2];
        if (!DeviceIoControl(handle, 0x0009003C, null, 0, bytes, bytes.Length, out var count, IntPtr.Zero))
            ThrowLastError("Cannot inspect history compression format");
        if (count != 2) throw new IOException("Invalid history compression format response.");
        var format = (ushort)(bytes[0] | bytes[1] << 8);
        if (format is not (0 or 2)) throw new IOException("Unsupported history compression format.");
        if (!GetFileInformationByHandleEx(handle, 8, out CompressionInformation info, (uint)Marshal.SizeOf<CompressionInformation>()))
            ThrowLastError("Cannot measure history physical bytes");
        if (info.CompressionFormat != format || info.CompressedFileSize < 0)
            throw new IOException("Inconsistent history compression information.");
        // CompressedFileSizeは小さい非圧縮データではEOFを返すため、割当量と同一視しない。
        // FILE_STANDARD_INFOはresident領域も含む現在の割当量を同じハンドルから返す。
        if (!GetFileInformationByHandleEx(handle, 1, out StandardInformation allocation, (uint)Marshal.SizeOf<StandardInformation>()))
            ThrowLastError("Cannot measure history allocation bytes");
        if (allocation.AllocationSize < 0 || allocation.EndOfFile != RandomAccess.GetLength(handle)
            || allocation.Directory != 0 || allocation.DeletePending != 0)
            throw new IOException("Inconsistent history allocation information.");
        return (format, allocation.AllocationSize);
    }

    internal static void CompressHistory(SafeFileHandle handle)
    {
        // COMPRESSION_FORMAT_LZNT1。元の内容・名前・ID・ACLを保持したまま圧縮する。
        byte[] format = [2, 0];
        if (!DeviceIoControl(handle, 0x0009C040, format, format.Length, null, 0, out _, IntPtr.Zero))
            ThrowLastError("Cannot compress history metadata");
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
    private static string Win32Path(string path) => @"\\?\" + PathPolicy.FileSystemAbsolute(path);

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
        var buffer = new StringBuilder(512);
        var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
        if (length >= buffer.Capacity)
        {
            buffer = new StringBuilder(32768);
            length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
        }
        if (length == 0 || length >= buffer.Capacity) ThrowLastError("Cannot resolve file handle path");
        var actual = buffer.ToString();
        return PathPolicy.FileSystemAbsolute(actual);
    }

    internal static bool IsReparse(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect handle type");
        return (info.Attributes & (uint)FileAttributes.ReparsePoint) != 0;
    }

    internal static bool IsCaseSensitive(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleEx(handle, FileCaseSensitiveInfo, out CaseSensitiveInformation info, (uint)Marshal.SizeOf<CaseSensitiveInformation>()))
            ThrowLastError("Cannot inspect directory case sensitivity");
        return (info.Flags & CaseSensitiveDirectory) != 0;
    }

    internal static void SetCaseSensitive(SafeFileHandle handle, bool enabled)
    {
        // 同じ属性への再設定でもWindowsは変更権限を要求する。既定のままなら書き込まない。
        if (IsCaseSensitive(handle) == enabled) return;
        var info = new CaseSensitiveInformation { Flags = enabled ? CaseSensitiveDirectory : 0u };
        if (!SetFileInformationByHandle(handle, FileCaseSensitiveInfo, ref info, (uint)Marshal.SizeOf<CaseSensitiveInformation>()))
            ThrowLastError("Cannot restore directory case sensitivity");
        if (IsCaseSensitive(handle) != enabled) throw new IOException("Restored directory case sensitivity differs from the saved value.");
    }

    internal static void RejectCaseSensitive(SafeFileHandle handle)
    {
        if (IsCaseSensitive(handle)) throw new IOException("Recovery storage cannot use case-sensitive directories.");
    }

    internal static List<string> NamedStreams(SafeFileHandle handle) =>
        ReadStreams(handle).Select(stream => stream.Name).Order(StringComparer.Ordinal).ToList();

    internal static long NamedStreamBytes(SafeFileHandle handle)
    {
        long bytes = 0;
        foreach (var stream in ReadStreams(handle)) bytes = checked(bytes + stream.Size);
        return bytes;
    }

    private static List<(string Name, long Size)> ReadStreams(SafeFileHandle handle)
    {
        var streams = new List<(string Name, long Size)>();
        // 通常は無名ストリームだけなので、小さく始め、多数のADSでは従来と同じ上限まで拡張する。
        var size = 1024;
        while (true)
        {
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetFileInformationByHandleEx(handle, 7, buffer, (uint)size))
                {
                    var error = Marshal.GetLastWin32Error();
                    if ((error is 234 or 122) && size < 8 * 1024 * 1024) { size *= 2; continue; }
                    if (error == 38) return streams;
                    ThrowLastError("Cannot inspect alternate streams by object handle");
                }
                var offset = 0;
                while (true)
                {
                    if (offset > size - 24) throw new IOException("Invalid stream information buffer.");
                    var next = Marshal.ReadInt32(buffer, offset); var nameBytes = Marshal.ReadInt32(buffer, offset + 4);
                    if (nameBytes < 0 || nameBytes % 2 != 0 || nameBytes > size - offset - 24)
                        throw new IOException("Invalid stream name buffer.");
                    var streamSize = Marshal.ReadInt64(buffer, offset + 8);
                    if (streamSize < 0) throw new IOException("Invalid stream size.");
                    var wireName = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 24), nameBytes / 2)!;
                    if (wireName != "::$DATA")
                    {
                        if (!wireName.StartsWith(':') || !wireName.EndsWith(":$DATA", StringComparison.Ordinal))
                            throw new IOException("Unsupported stream type.");
                        var name = wireName[1..^6]; ValidateStreamName(name); streams.Add((name, streamSize));
                    }
                    if (next == 0) break;
                    if (next < 24 || next > size - offset) throw new IOException("Invalid stream information offset.");
                    offset += next;
                }
                return streams;
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

    internal static SafeFileHandle CreateSymbolicDestination(string path, byte[] bytes, bool directory)
    {
        var target = SymbolicTarget(bytes);
        // Developer Modeを利用できるOSの公開APIを使い、ホストの権限設定は変更しない。
        if (!CreateSymbolicLinkW(Win32Path(path), target, (directory ? 1u : 0u) | 2u)) ThrowLastError("Cannot exclusively restore symbolic link");
        var handle = Open(path, 0x180 | Delete, 3, 3, OpenReparse | BackupSemantics);
        try
        {
            var restored = ReadReparse(handle);
            if (!IsReparse(handle) || IsDirectory(handle) != directory || SymbolicTarget(restored) != target
                || BitConverter.ToUInt32(restored, 16) != BitConverter.ToUInt32(bytes, 16))
                throw new IOException("Restored symbolic link target or type differs; the created link was retained for inspection.");
            return handle;
        }
        catch { handle.Dispose(); throw; }
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

    internal static void DeleteHandle(SafeFileHandle handle) => DeleteHandleCore(handle, original: false);

    internal static void DeleteOriginalHandle(SafeFileHandle handle) => DeleteHandleCore(handle, original: true);

    private static void DeleteHandleCore(SafeFileHandle handle, bool original)
    {
        var timeout = TimeSpan.FromSeconds(10);
        var timer = Stopwatch.StartNew();
        while (true)
        {
            try { if (original) SetOriginalDeletePending(handle, true); else SetDeletePending(handle, true); return; }
            catch (IOException ex) when (IsTransientDeletionFailure(handle, ex, original))
            {
                // DLLのイメージ解放などを同じ検証済みハンドルで待つ。権限や削除方式は変えない。
                var remaining = timeout - timer.Elapsed;
                if (remaining <= TimeSpan.Zero)
                    throw new IOException("Windows still refused deletion after 10 seconds. Close applications using this item before retrying. " + ex.Message, ex);
                Thread.Sleep((int)Math.Min(100, Math.Ceiling(remaining.TotalMilliseconds)));
            }
        }
    }

    private static bool IsTransientDeletionFailure(SafeFileHandle handle, IOException error, bool original)
    {
        if (error.InnerException is not Win32Exception { NativeErrorCode: 5 or 32 or 33 }) return false;
        // 元対象だけは属性を書き換えず読み取り専用を無視する。コピー整理には広げない。
        var excluded = FileAttributes.Directory | FileAttributes.ReparsePoint | (original ? 0 : FileAttributes.ReadOnly);
        return GetFileInformationByHandle(handle, out var info) && (info.Attributes & (uint)excluded) == 0;
    }

    internal static void SetDeletePending(SafeFileHandle handle, bool pending)
    {
        var disposition = new FileDisposition { DeleteFile = pending };
        if (!SetFileInformationByHandle(handle, 4, ref disposition, (uint)Marshal.SizeOf<FileDisposition>()))
            ThrowLastError(pending ? "Cannot mark file for deletion" : "Cannot cancel pending deletion");
    }

    internal static void SetOriginalDeletePending(SafeFileHandle handle, bool pending)
    {
        if ((RestorableAttributes(handle) & (uint)FileAttributes.ReadOnly) == 0)
        { SetDeletePending(handle, pending); return; }
        // FILE_DISPOSITION_INFO_EX: DELETE | IGNORE_READONLY_ATTRIBUTE。
        // 属性そのものを変更しないため、別hardlink名・拒否時の元属性も保つ。
        var disposition = new FileDispositionEx { Flags = pending ? 0x11u : 0u };
        if (!SetFileInformationByHandle(handle, 21, ref disposition, (uint)Marshal.SizeOf<FileDispositionEx>()))
            ThrowLastError(pending ? "Cannot mark read-only original for deletion without changing its attributes" : "Cannot cancel pending deletion");
    }

    internal static uint RestorableAttributes(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) ThrowLastError("Cannot inspect original attributes");
        return info.Attributes & RestorableAttributeMask;
    }

    internal static void RestoreAttributes(SafeFileHandle handle, uint? attributes)
    {
        if (attributes is not uint value || EquivalentAttributes(RestorableAttributes(handle), value)) return;
        var info = new BasicInformation { Attributes = value == 0 ? (uint)FileAttributes.Normal : value };
        if (!SetFileInformationByHandle(handle, 0, ref info, (uint)Marshal.SizeOf<BasicInformation>()))
            ThrowLastError("Cannot restore original attributes");
        if (!EquivalentAttributes(RestorableAttributes(handle), value)) throw new IOException("Restored attributes differ from the manifest.");
    }

    // 通常属性なしは、圧縮などの構造属性の有無により0またはNormalで表現される。
    private static bool EquivalentAttributes(uint left, uint right) =>
        (left == (uint)FileAttributes.Normal ? 0u : left) == (right == (uint)FileAttributes.Normal ? 0u : right);

    internal static void RestoreLastWriteTime(SafeFileHandle handle, DateTime timestamp)
    {
        var info = new BasicInformation { LastWriteTime = timestamp.ToFileTimeUtc() };
        if (!SetFileInformationByHandle(handle, 0, ref info, (uint)Marshal.SizeOf<BasicInformation>()))
            ThrowLastError("Cannot restore original last-write time");
    }

    internal static unsafe void RenameHandle(SafeFileHandle handle, string destination)
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
            new Span<byte>((void*)buffer, size).Clear();
            Marshal.WriteInt32(buffer, lengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
            if (!SetFileInformationByHandle(handle, 3, buffer, (uint)size))
                ThrowLastError("Cannot atomically publish file without replacing an existing destination");
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static void ThrowLastError(string message)
    {
        var error = new Win32Exception(Marshal.GetLastWin32Error());
        throw new IOException($"{message}: {error.Message}", error);
    }

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
    private struct FileDispositionEx { public uint Flags; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicInformation
    {
        public long CreationTime, LastAccessTime, LastWriteTime, ChangeTime;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CaseSensitiveInformation { public uint Flags; }

    [StructLayout(LayoutKind.Sequential)]
    private struct CompressionInformation
    {
        public long CompressedFileSize;
        public ushort CompressionFormat;
        public byte CompressionUnitShift, ChunkShift, ClusterShift, Reserved1, Reserved2, Reserved3;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StandardInformation
    {
        public long AllocationSize, EndOfFile;
        public uint NumberOfLinks;
        public byte DeletePending, Directory;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ObjectAttributes { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }

    [LibraryImport("ntdll.dll", EntryPoint = "NtCreateFile")]
    private static partial int NtCreateFile(out SafeFileHandle handle, uint access, ref ObjectAttributes attributes, out IoStatusBlock status,
        IntPtr allocationSize, uint fileAttributes, uint share, uint disposition, uint options, IntPtr eaBuffer, uint eaLength);
    [LibraryImport("ntdll.dll", EntryPoint = "RtlNtStatusToDosError")]
    private static partial uint RtlNtStatusToDosError(int status);
    [LibraryImport("kernel32.dll", EntryPoint = "CreateSymbolicLinkW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    private static partial bool CreateSymbolicLinkW(string path, string target, uint flags);

    [LibraryImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref CaseSensitiveInformation information, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref FileDispositionEx information, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, ref BasicInformation information, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, IntPtr information, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeviceIoControl(SafeFileHandle handle, uint code,
        [In, MarshalUsing(CountElementName = nameof(inputSize))] byte[]? input, int inputSize,
        [Out, MarshalUsing(CountElementName = nameof(outputSize))] byte[]? output, int outputSize, out int returned, IntPtr overlapped);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StreamInformation
    {
        public long Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)] public string Name;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [LibraryImport("kernel32.dll", EntryPoint = "CreateDirectoryW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CreateDirectoryW(string path, IntPtr security);
    // ByValTStrを含む構造体はソース生成の対象外なので、既存のマーシャリングを維持する。
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstStreamW(string path, int infoLevel, out StreamInformation data, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindNextStreamW(IntPtr search, out StreamInformation data);
    [LibraryImport("kernel32.dll", EntryPoint = "FindClose", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool FindClose(IntPtr search);
    // 外部型FILETIMEを含む構造体は、ランタイムマーシャリングを有効のまま維持する。
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, out CaseSensitiveInformation info, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, out CompressionInformation info, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, out StandardInformation info, uint size);
    // StringBuilderはソース生成非対応のため、既存のバッファ契約を維持する。
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeInformationByHandleW(SafeFileHandle handle, StringBuilder? volumeName, uint volumeNameSize,
        out uint serial, out uint maximumComponentLength, out uint flags, StringBuilder fileSystem, uint fileSystemSize);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
    // boolフィールドのU1変換はソース生成非対応のため、構造体と既存の変換を維持する。
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, ref FileDisposition info, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, IntPtr info, uint size);
}
