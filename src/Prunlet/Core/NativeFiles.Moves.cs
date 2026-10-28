using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static partial class NativeFiles
{
    // 書込み・削除共有を許さず、同じストリームへの通常の書込みと名前の差し替えを防ぐ。
    // 既に書込み/削除権限を持つハンドルがあれば取得を拒否し、属性や内容は変更しない。
    // 別ストリーム・属性・ディレクトリ配下までの排他は保証しない。移動は木全体に行う。
    internal static SafeFileHandle OpenMoveEntry(string path) =>
        Open(path, Delete | 0x80, 1, 3, OpenReparse | BackupSemantics);

    // 容量確認中は通常の書込みを拒否し、保持した木をそのままrenameできるよう削除共有は許可する。
    internal static SafeFileHandle OpenMoveMeasurement(string path) =>
        Open(path, 0x80, 5, 3, OpenReparse | BackupSemantics);

    // Shellの完了callbackはShell自身のハンドルが開いている場合も照合する。
    // ここでは共有を制限せず、CoreはFile ID不一致を曖昧な状態として保全する。
    internal static SafeFileHandle OpenShellInspection(string path) =>
        Open(path, 0x80, 7, 3, OpenReparse | BackupSemantics);

    // 共有hardlinkを複数回固定削除するときだけ、通常ストリームへの書込みを抑止する。
    // 属性や別ストリームの変更まで排他するものではない。
    internal static SafeFileHandle OpenHardlinkReadGuard(string path) =>
        Open(path, 0x81, 5, 3, OpenReparse | BackupSemantics);

    internal static SafeFileHandle OpenHardlinkExecuteGuard(string path) =>
        Open(path, 0xa0, 5, 3, OpenReparse | BackupSemantics);

    internal static SafeFileHandle OpenHardlinkStreamGuard(string path, string name, bool execute)
    {
        ValidateStreamName(name);
        var handle = CreateFileW(Win32Path(path) + ":" + name + ":$DATA", execute ? 0xa0u : 0x81u, 5,
            IntPtr.Zero, 3, OpenReparse | BackupSemantics, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        handle.Dispose();
        ThrowLastError("Cannot retain an alternate hardlink stream");
        throw new InvalidOperationException();
    }

    // DELETEハンドルと共存し、renameのclose時に付くArchiveだけを元属性へ戻す。
    internal static SafeFileHandle OpenMoveAttributeGuard(string path) =>
        Open(path, 0x180, 5, 3, OpenReparse | BackupSemantics);

    // 子の整理中は親を固定し、DELETE権限を持つハンドルで列挙を妨げない。
    internal static SafeFileHandle OpenMovePurgePin(string path) =>
        Open(path, 0x80, 1, 3, OpenReparse | BackupSemantics);

    // 移動先は親ハンドルで固定する。削除共有を許さず、親自体の差し替えを防ぐ。
    // 復元時は対象種別に必要な追加権限だけを要求し、不要な権限不足で拒否しない。
    internal static SafeFileHandle OpenMoveParent(string path, bool? directoryEntry = null) =>
        Open(path, 0x80u | (directoryEntry switch { true => 0x4u, false => 0x2u, null => 0x6u }),
            3, 3, OpenReparse | BackupSemantics);

    internal static MoveEntryIdentity MoveIdentity(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleEx(handle, 18, out MoveFileIdInformation id, (uint)Marshal.SizeOf<MoveFileIdInformation>()))
            ThrowLastError("Cannot inspect persistent file identity");
        if (!GetFileInformationByHandleEx(handle, 9, out MoveAttributeTagInformation tag, (uint)Marshal.SizeOf<MoveAttributeTagInformation>()))
            ThrowLastError("Cannot inspect move entry type");
        // FILE_ID_128は不透明な16バイト列として保持し、数値の大小やendiannessへ依存しない。
        Span<byte> bytes = stackalloc byte[16];
        MemoryMarshal.Write(bytes[..8], in id.FileIdLow);
        MemoryMarshal.Write(bytes[8..], in id.FileIdHigh);
        return new MoveEntryIdentity(id.VolumeSerialNumber, Convert.ToHexString(bytes),
            (tag.Attributes & (uint)FileAttributes.Directory) != 0,
            (tag.Attributes & (uint)FileAttributes.ReparsePoint) != 0 ? tag.ReparseTag : 0, tag.Attributes);
    }

    internal static void MoveNoReplace(SafeFileHandle handle, SafeFileHandle parentHandle, string leafName)
    {
        ArgumentException.ThrowIfNullOrEmpty(leafName);
        if (leafName.IndexOfAny(['\\', '/', ':', '\0']) >= 0)
            throw new ArgumentException("Move destination must be a single ordinary path component.", nameof(leafName));
        _ = PathPolicy.Absolute("C:\\" + leafName);
        var source = MoveIdentity(handle);
        var parent = MoveIdentity(parentHandle);
        if (!parent.IsDirectory || parent.ReparseTag != 0 || (parent.Attributes & (uint)FileAttributes.ReparsePoint) != 0)
            throw new IOException("Move destination parent must be an ordinary directory.");
        if (source.VolumeSerialNumber != parent.VolumeSerialNumber)
            throw new IOException("Move source and destination must belong to the same volume.");
        var parentPath = FinalPath(parentHandle);
        using var pinned = PathPolicy.PinDirectories(parentPath);
        Verify(parentHandle, parentPath, directory: true);
        if (MoveIdentity(parentHandle) != parent)
            throw new IOException("Move destination parent identity changed while pinning its ancestors.");
        // 絶対パスの全祖先を削除共有なしで固定し、検査後の差し替えを防ぐ。
        // FILE_RENAME_INFO/ReplaceIfExists=falseを使う既存APIへ統一する。
        // 読取り専用の元対象が拒否されても、属性を書き換えて再試行しない。
        RenameHandle(handle, Path.Combine(parentPath, leafName));
    }

    internal static string VolumeMountRoot(string path)
    {
        var buffer = new StringBuilder(32768);
        if (!GetVolumePathNameW(Win32Path(path), buffer, (uint)buffer.Capacity))
            ThrowLastError("Cannot resolve volume mount root");
        return PathPolicy.Absolute(buffer.ToString());
    }

    internal static string VolumeName(string mountRoot)
    {
        var buffer = new StringBuilder(64);
        var root = Win32Path(mountRoot).TrimEnd('\\') + "\\";
        if (!GetVolumeNameForVolumeMountPointW(root, buffer, (uint)buffer.Capacity))
            ThrowLastError("Cannot resolve persistent volume name");
        return buffer.ToString();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MoveFileIdInformation
    {
        public ulong VolumeSerialNumber, FileIdLow, FileIdHigh;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MoveAttributeTagInformation { public uint Attributes, ReparseTag; }

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, out MoveFileIdInformation information, uint size);
    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, out MoveAttributeTagInformation information, uint size);
    // StringBuilderの出力マーシャリングを使うため、既存のFinalPathと同じDllImportを使う。
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumePathNameW(string path, StringBuilder volumePath, uint length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, StringBuilder volumeName, uint length);
}

internal sealed record MoveEntryIdentity(ulong VolumeSerialNumber, string FileId, bool IsDirectory, uint ReparseTag, uint Attributes);
