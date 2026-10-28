using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static partial class NativeFiles
{
    // 名前の差し替えを防ぐDELETE非共有pinに、directory列挙権限を加える。
    internal static SafeFileHandle OpenPermanentDirectory(string path)
        => Open(path, Delete | 0x80 | 0x01, 1, 3, OpenReparse | BackupSemantics);

    // Shell自身の共有handleと共存し、返却された同じdirectoryから一時的に列挙する。
    internal static SafeFileHandle OpenRecycledDirectory(string path)
        => Open(path, 0x80 | 0x01, 7, 3, OpenReparse | BackupSemantics);

    // 旧領域の所有確認中はdirectory名の差し替えを禁止し、同じhandleから列挙する。
    internal static SafeFileHandle OpenLegacyDirectoryInspection(string path)
        => Open(path, 0x80 | 0x01, 3, 3, OpenReparse | BackupSemantics);

    // 旧領域の分類には名前だけが必要であり、子のIDや時刻を保存・要求しない。
    internal static bool AnyPinnedDirectoryName(SafeFileHandle directory, Func<string, bool> match)
    {
        const int header = 68;
        const int noMoreFiles = 18;
        var buffer = new byte[64 * 1024];
        var first = true;
        while (true)
        {
            Array.Clear(buffer);
            if (!GetPinnedDirectoryInformation(directory, first ? 15 : 14, buffer, (uint)buffer.Length))
            {
                var error = Marshal.GetLastWin32Error();
                if (error == noMoreFiles) return false;
                throw new IOException("Cannot enumerate the pinned directory names.", new Win32Exception(error));
            }
            first = false;
            var offset = 0;
            while (true)
            {
                if (offset < 0 || offset > buffer.Length - header) throw new IOException("Invalid directory enumeration offset.");
                var next = BitConverter.ToUInt32(buffer, offset);
                var length = BitConverter.ToUInt32(buffer, offset + 60);
                if (length == 0 || (length & 1) != 0 || length > buffer.Length - offset - header)
                    throw new IOException("Invalid directory entry name.");
                var name = new UnicodeEncoding(false, false, true).GetString(buffer, offset + header, (int)length);
                if (name is not ("." or ".."))
                {
                    if (name.IndexOfAny(['\\', '/', ':', '\0']) >= 0) throw new IOException("Invalid directory entry component.");
                    if (match(name)) return true;
                }
                if (next == 0) break;
                if (next < header + length || (next & 7) != 0 || next > buffer.Length - offset)
                    throw new IOException("Invalid directory enumeration record.");
                offset += checked((int)next);
            }
        }
    }

    // 固定したdirectory自身から名前とFILE_ID_128を同時に取得する。
    // 保存用の記録は作らず、未対応・不正な情報は安全側に停止する。
    internal static IReadOnlyList<PinnedDirectoryEntry> ReadPinnedDirectory(SafeFileHandle directory)
    {
        const int header = 88;
        const int noMoreFiles = 18;
        var buffer = new byte[64 * 1024];
        var result = new List<PinnedDirectoryEntry>();
        var first = true;
        while (true)
        {
            Array.Clear(buffer);
            if (!GetPinnedDirectoryInformation(directory, first ? 20 : 19, buffer, (uint)buffer.Length))
            {
                var error = Marshal.GetLastWin32Error();
                if (error == noMoreFiles) return result;
                throw new IOException("Cannot enumerate the pinned directory by file identity.", new Win32Exception(error));
            }
            first = false;
            var offset = 0;
            while (true)
            {
                if (offset < 0 || offset > buffer.Length - header) throw new IOException("Invalid directory enumeration offset.");
                var next = BitConverter.ToUInt32(buffer, offset);
                var attributes = BitConverter.ToUInt32(buffer, offset + 56);
                var nameLength = BitConverter.ToUInt32(buffer, offset + 60);
                var tag = (attributes & (uint)FileAttributes.ReparsePoint) != 0
                    ? BitConverter.ToUInt32(buffer, offset + 68) : 0;
                var created = BitConverter.ToInt64(buffer, offset + 8);
                var changed = BitConverter.ToInt64(buffer, offset + 32);
                if (nameLength == 0 || (nameLength & 1) != 0 || nameLength > buffer.Length - offset - header)
                    throw new IOException("Invalid directory entry name.");
                var name = new UnicodeEncoding(false, false, true).GetString(buffer, offset + header, (int)nameLength);
                if (name is not ("." or ".."))
                {
                    if (name.IndexOfAny(['\\', '/', ':', '\0']) >= 0) throw new IOException("Invalid directory entry component.");
                    var fileId = Convert.ToHexString(buffer.AsSpan(offset + 72, 16));
                    if (fileId.All(c => c == '0') || fileId.All(c => c == 'F'))
                        throw new IOException("Directory entry has no usable file identity.");
                    if (created == 0 || changed == 0) throw new IOException("Directory entry has no usable creation or change time.");
                    result.Add(new(name, fileId, attributes, tag, created, changed));
                }
                if (next == 0) break;
                if (next < header + nameLength || (next & 7) != 0 || next > buffer.Length - offset)
                    throw new IOException("Invalid directory enumeration record.");
                offset += checked((int)next);
            }
        }
    }

    internal static (long ChangeTime, long LastWriteTime) VerifyPinnedEntryTimes(SafeFileHandle handle, PinnedDirectoryEntry entry, long? ownLinkChangeTime)
    {
        if (!GetPinnedBasicInformation(handle, 0, out var info, (uint)Marshal.SizeOf<BasicInformation>()))
            ThrowLastError("Cannot inspect the pinned directory entry times");
        if (info.CreationTime != entry.CreationTime || info.ChangeTime != (ownLinkChangeTime ?? entry.ChangeTime))
            throw new IOException("Directory entry changed after enumeration.");
        return (info.ChangeTime, info.LastWriteTime);
    }

    internal static long PinnedChangeTime(SafeFileHandle handle)
    {
        if (!GetPinnedBasicInformation(handle, 0, out var info, (uint)Marshal.SizeOf<BasicInformation>()))
            ThrowLastError("Cannot inspect the retained hardlink change time");
        if (info.ChangeTime == 0) throw new IOException("Hardlink change time is unavailable.");
        return info.ChangeTime;
    }

    internal static long PinnedLastWriteTime(SafeFileHandle handle)
    {
        if (!GetPinnedBasicInformation(handle, 0, out var info, (uint)Marshal.SizeOf<BasicInformation>()))
            ThrowLastError("Cannot inspect the retained hardlink write time");
        return info.LastWriteTime;
    }

    internal static void SetPermanentDeletePending(SafeFileHandle handle, bool posix)
    {
        if (!posix) { SetOriginalDeletePending(handle, true); return; }
        // 生存するhardlinkやinspection handleに影響せず、対象名をclose時に外す。
        var flags = 0x03u; // DELETE | POSIX_SEMANTICS
        if ((RestorableAttributes(handle) & (uint)FileAttributes.ReadOnly) != 0) flags |= 0x10u;
        var info = new FileDispositionEx { Flags = flags };
        if (!SetFileInformationByHandle(handle, 21, ref info, (uint)Marshal.SizeOf<FileDispositionEx>()))
            ThrowLastError("Cannot mark the fixed hardlink name for deletion");
    }

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPinnedDirectoryInformation(SafeFileHandle handle, int informationClass, [Out] byte[] information, uint size);

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPinnedBasicInformation(SafeFileHandle handle, int informationClass, out BasicInformation information, uint size);
}

internal readonly record struct PinnedDirectoryEntry(string Name, string FileId, uint Attributes, uint ReparseTag, long CreationTime, long ChangeTime);
