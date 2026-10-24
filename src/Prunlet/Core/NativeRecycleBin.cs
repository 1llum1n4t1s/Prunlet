using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Principal;

namespace Prunlet.Core;

internal sealed record BinItem(string Pidl, string PhysicalPath);

// ごみ箱の実体・付随情報の変更はShellだけに任せる。保存するPIDLは同じ端末・SIDでのみ再利用する。
internal static class NativeRecycleBin
{
    private const int Abort = unchecked((int)0x80004004);
    private const int AlreadyExists = unchecked((int)0x80070050);
    private const int DontProcessChildren = 0x00270008;
    private const uint FileSystemPath = 0x80058000;
    private const int MaximumSerializedPidlBytes = 1024 * 1024;
    private static readonly Guid RecycleFolder = new("B7534046-3ECB-4C18-BE4E-64CD4CB7D6AC");
    private static readonly Guid ShellItemId = new("43826D1E-E718-42EE-BC55-A1E261C37BFE");
    private static readonly Guid EnumItemsHandler = new("94F60519-2850-4924-AA5A-D15E84868039");
    private static readonly Guid EnumItemsId = new("70629033-E363-4A28-A567-0DB78006E6D7");
    private static readonly Guid TransferHandler = new("D5E346A1-F753-4932-B403-4574800E2498");
    private static readonly Guid TransferSourceId = new("00ADB003-BDE9-45C6-8E29-D09F9353E108");

    // beforeDeleteはShellが解決した対象の照合、recycledは移動後の照合と記録の永続化を同期して行う。
    // callback後の中断や失敗を元対象の不変更と解釈せず、Coreのintentを曖昧な記録として保持する。
    internal static BinItem Recycle(string sourcePath, Action<string> beforeDelete, Action<BinItem> recycled)
    {
        ArgumentNullException.ThrowIfNull(beforeDelete);
        ArgumentNullException.ThrowIfNull(recycled);
        sourcePath = PathPolicy.Absolute(sourcePath);
        return InSta(() =>
        {
            var source = ShellItem(sourcePath);
            IShellItem? parent = null;
            IShellItem? bin = null;
            IShellItem? created = null;
            ITransferSource? transfer = null;
            uint cookie = 0;
            var advised = false;
            var sink = new TransferSink();
            try
            {
                RequireOk(source.GetParent(out parent), "Cannot resolve the source Shell parent");
                if (parent is null) throw new IOException("Shell returned no parent for the recycle source.");
                bin = OpenBin();
                transfer = Bind<ITransferSource>(parent, TransferHandler, TransferSourceId);
                RequireOk(transfer.Advise(sink, out cookie), "Cannot observe Shell recycling");
                advised = true;
                beforeDelete(PhysicalPath(source));
                // RecycleItemだけを呼び、失敗を永久削除やcopy/deleteへ切り替える上位engineを使わない。
                // TSF_NORMAL=0。確認・再試行・昇格が必要な状態はTransferSinkがその場で拒否する。
                var result = transfer.RecycleItem(source, bin, 0, out created);
                RequireCompletedTransfer(result, "Shell recycling did not complete");
                if (created is null) throw new IOException("Shell returned no recycled item; the operation record was retained.");
                var item = SnapshotRecycled(created);
                recycled(item);
                return item;
            }
            finally
            {
                if (advised) _ = transfer!.Unadvise(cookie);
                Release(created);
                Release(transfer);
                Release(bin);
                Release(parent);
                Release(source);
                GC.KeepAlive(sink);
            }
        });
    }

    // 古いPIDLを直接bindせず、現在のごみ箱から列挙した項目との一致だけを採用する。
    // 不在はWindows側の復元・整理もあり得るため、削除済み/復元済みと推測しない。
    internal static BinItem? Find(string pidlBase64) => InSta(() =>
    {
        var bin = OpenBin();
        IShellItem? item = null;
        try
        {
            item = FindShellItem(bin, pidlBase64);
            return item is null ? null : new BinItem(pidlBase64, PhysicalPath(item));
        }
        finally { Release(item); Release(bin); }
    });

    internal static string RestoreNoReplace(BinItem item, string parentPath, string leafName,
        Action<string>? beforeMove = null, Action<string>? restored = null)
    {
        ArgumentNullException.ThrowIfNull(item);
        parentPath = PathPolicy.Absolute(parentPath);
        if (string.IsNullOrEmpty(leafName) || leafName.IndexOfAny(['\\', '/', ':', '\0']) >= 0)
            throw new ArgumentException("Restore destination must be a single path component.", nameof(leafName));
        var expectedPath = PathPolicy.Absolute(Path.Combine(parentPath, leafName));
        return InSta(() =>
        {
            var bin = OpenBin();
            IShellItem? source = null;
            IShellItem? destination = null;
            IShellItem? moved = null;
            ITransferSource? transfer = null;
            uint cookie = 0;
            var advised = false;
            var sink = new TransferSink();
            try
            {
                source = FindShellItem(bin, item.Pidl)
                    ?? throw new IOException("The tracked Recycle Bin item is no longer present; its record was retained.");
                var sourcePath = PhysicalPath(source);
                if (!sourcePath.Equals(item.PhysicalPath, StringComparison.Ordinal))
                    throw new IOException("The tracked Recycle Bin item's physical location changed; restoration was refused.");
                destination = ShellItem(parentPath);
                transfer = Bind<ITransferSource>(bin, TransferHandler, TransferSourceId);
                RequireOk(transfer.Advise(sink, out cookie), "Cannot observe Shell restoration");
                advised = true;
                beforeMove?.Invoke(sourcePath);
                // TSF_FAIL_EXIST=0。既存の置換・マージ・別名生成やcopy/deleteへのfallbackは行わない。
                var result = transfer.MoveItem(source, destination, leafName, 0, out moved);
                // ごみ箱providerはroot移動完了時に子の処理不要を返すことがある。
                // skip/merge等の他の情報値は許可せず、移動後のpathとCoreのID照合も必須にする。
                RequireCompletedTransfer(result, "Shell restoration did not complete without replacing the destination");
                if (moved is null) throw new IOException("Shell returned no restored item; the operation record was retained.");
                var actualPath = PhysicalPath(moved);
                if (!actualPath.Equals(expectedPath, StringComparison.Ordinal))
                    throw new IOException($"Shell returned an unexpected restore destination; data was retained at {actualPath}.");
                restored?.Invoke(actualPath);
                return actualPath;
            }
            finally
            {
                if (advised) _ = transfer!.Unadvise(cookie);
                Release(moved);
                Release(transfer);
                Release(destination);
                Release(source);
                Release(bin);
                GC.KeepAlive(sink);
            }
        });
    }

    private static T InSta<T>(Func<T> action)
    {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return ComInitialized(action);
        T? result = default;
        ExceptionDispatchInfo? failure = null;
        // 別STAスレッドでも呼出元の実効tokenを引き継ぎ、process tokenへの切替で権限を広げない。
        using var identity = WindowsIdentity.GetCurrent();
        var thread = new Thread(() =>
        {
            try { WindowsIdentity.RunImpersonated(identity.AccessToken, () => { result = ComInitialized(action); }); }
            catch (Exception exception) { failure = ExceptionDispatchInfo.Capture(exception); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        failure?.Throw();
        return result!;
    }

    private static T ComInitialized<T>(Func<T> action)
    {
        var result = CoInitializeEx(IntPtr.Zero, 2);
        if (result < 0) throw ShellError("Cannot initialize Shell STA", result);
        try { return action(); }
        finally { CoUninitialize(); }
    }

    private static IShellItem OpenBin()
    {
        var folder = RecycleFolder;
        var iid = ShellItemId;
        RequireOk(SHGetKnownFolderItem(ref folder, 0, IntPtr.Zero, ref iid, out var item), "Cannot open the current user's Recycle Bin");
        return item ?? throw new IOException("Shell returned no Recycle Bin item.");
    }

    private static IShellItem ShellItem(string path)
    {
        var iid = ShellItemId;
        RequireOk(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out var item), "Cannot resolve a Shell filesystem item");
        return item ?? throw new IOException("Shell returned no filesystem item.");
    }

    private static T Bind<T>(IShellItem item, Guid handler, Guid iid) where T : class
    {
        RequireOk(item.BindToHandler(IntPtr.Zero, ref handler, ref iid, out var pointer), "Cannot bind the required Shell handler");
        if (pointer == IntPtr.Zero) throw new IOException("Shell returned no handler.");
        try { return (T)Marshal.GetObjectForIUnknown(pointer); }
        finally { Marshal.Release(pointer); }
    }

    private static IShellItem? FindShellItem(IShellItem bin, string encoded)
    {
        var savedPidl = LoadPidl(encoded);
        IntPtr binPidl = IntPtr.Zero;
        try
        {
            RequireOk(SHGetIDListFromObject(bin, out binPidl), "Cannot identify the Recycle Bin namespace");
            if (binPidl == IntPtr.Zero || !ILIsParent(binPidl, savedPidl, true))
                throw new InvalidDataException("The stored PIDL is not a direct child of the current Recycle Bin.");
            return FindCurrentBinItem(bin, (_, candidatePidl) => ILIsEqual(savedPidl, candidatePidl));
        }
        finally
        {
            Marshal.FreeCoTaskMem(binPidl);
            Marshal.FreeCoTaskMem(savedPidl);
        }
    }

    private static IShellItem? FindCurrentBinItem(IShellItem bin, Func<IShellItem, IntPtr, bool> matches)
    {
        IntPtr binPidl = IntPtr.Zero;
        IEnumShellItems? enumerator = null;
        try
        {
            RequireOk(SHGetIDListFromObject(bin, out binPidl), "Cannot identify the Recycle Bin namespace");
            if (binPidl == IntPtr.Zero) throw new IOException("Shell returned no Recycle Bin PIDL.");
            enumerator = Bind<IEnumShellItems>(bin, EnumItemsHandler, EnumItemsId);
            while (true)
            {
                var result = enumerator.Next(1, out var candidate, out var fetched);
                if (result == 1 && fetched == 0) { Release(candidate); return null; }
                if (result != 0 || fetched != 1 || candidate is null)
                {
                    Release(candidate);
                    throw ShellError("Cannot enumerate current Recycle Bin items", result < 0 ? result : Abort);
                }
                var retain = false;
                IntPtr candidatePidl = IntPtr.Zero;
                try
                {
                    RequireOk(SHGetIDListFromObject(candidate, out candidatePidl), "Cannot identify a Recycle Bin item");
                    if (candidatePidl == IntPtr.Zero || !ILIsParent(binPidl, candidatePidl, true))
                        throw new InvalidDataException("Shell enumerated an item outside the current Recycle Bin namespace.");
                    if (matches(candidate, candidatePidl))
                    {
                        retain = true;
                        return candidate;
                    }
                }
                finally
                {
                    Marshal.FreeCoTaskMem(candidatePidl);
                    if (!retain) Release(candidate);
                }
            }
        }
        finally
        {
            Release(enumerator);
            Marshal.FreeCoTaskMem(binPidl);
        }
    }

    private static bool MatchesPhysicalItem(IShellItem candidate, string path, MoveEntryIdentity expected)
    {
        if (!PhysicalPath(candidate).Equals(path, StringComparison.Ordinal)) return false;
        using var handle = NativeFiles.OpenShellInspection(path);
        var actual = NativeFiles.MoveIdentity(handle);
        if (actual.VolumeSerialNumber != expected.VolumeSerialNumber || actual.FileId != expected.FileId
            || actual.IsDirectory != expected.IsDirectory || actual.ReparseTag != expected.ReparseTag)
            throw new IOException("The Recycle Bin physical item changed while resolving its namespace identity.");
        return true;
    }

    private static BinItem SnapshotRecycled(IShellItem returnedItem)
    {
        // RecycleItemの戻りがfilesystem表現でも、保存するPIDLは現在のごみ箱namespaceへ揃える。
        var path = PhysicalPath(returnedItem);
        using var handle = NativeFiles.OpenShellInspection(path);
        var identity = NativeFiles.MoveIdentity(handle);
        var bin = OpenBin();
        IShellItem? current = null;
        try
        {
            current = FindCurrentBinItem(bin, (candidate, _) => MatchesPhysicalItem(candidate, path, identity))
                ?? throw new IOException($"The recycled physical item could not be matched to the current Recycle Bin; data was retained at {path}.");
            return Snapshot(current);
        }
        finally { Release(current); Release(bin); }
    }

    private static BinItem Snapshot(IShellItem item)
    {
        IntPtr pidl = IntPtr.Zero;
        IStream? stream = null;
        try
        {
            RequireOk(SHGetIDListFromObject(item, out pidl), "Cannot capture a Recycle Bin item's PIDL");
            if (pidl == IntPtr.Zero) throw new IOException("Shell returned an empty PIDL.");
            RequireOk(CreateStreamOnHGlobal(IntPtr.Zero, true, out stream), "Cannot create a PIDL stream");
            RequireOk(ILSaveToStream(stream, pidl), "Cannot serialize a Recycle Bin item's PIDL");
            stream.Stat(out var stat, 1);
            if (stat.cbSize <= 0 || stat.cbSize > MaximumSerializedPidlBytes)
                throw new InvalidDataException("The serialized Recycle Bin PIDL has an invalid length.");
            stream.Seek(0, 0, IntPtr.Zero);
            var bytes = new byte[checked((int)stat.cbSize)];
            ReadExactly(stream, bytes);
            return new BinItem(Convert.ToBase64String(bytes), PhysicalPath(item));
        }
        finally { Release(stream); Marshal.FreeCoTaskMem(pidl); }
    }

    private static IntPtr LoadPidl(string encoded)
    {
        if (string.IsNullOrEmpty(encoded) || encoded.Length > ((MaximumSerializedPidlBytes + 2) / 3) * 4)
            throw new InvalidDataException("The stored Recycle Bin PIDL has an invalid length.");
        byte[] bytes;
        try { bytes = Convert.FromBase64String(encoded); }
        catch (FormatException exception) { throw new InvalidDataException("The stored Recycle Bin PIDL is not valid base64.", exception); }
        if (bytes.Length == 0 || bytes.Length > MaximumSerializedPidlBytes)
            throw new InvalidDataException("The stored Recycle Bin PIDL has an invalid length.");
        IStream? stream = null;
        IntPtr pidl = IntPtr.Zero;
        try
        {
            RequireOk(CreateStreamOnHGlobal(IntPtr.Zero, true, out stream), "Cannot create a stored PIDL stream");
            stream.Write(bytes, bytes.Length, IntPtr.Zero);
            stream.Seek(0, 0, IntPtr.Zero);
            RequireOk(ILLoadFromStreamEx(stream, out pidl), "Cannot deserialize the stored Recycle Bin PIDL");
            if (pidl == IntPtr.Zero) throw new InvalidDataException("The stored Recycle Bin PIDL is empty.");
            var loaded = pidl;
            pidl = IntPtr.Zero;
            return loaded;
        }
        finally { Release(stream); Marshal.FreeCoTaskMem(pidl); }
    }

    private static unsafe void ReadExactly(IStream stream, byte[] bytes)
    {
        var read = 0;
        stream.Read(bytes, bytes.Length, (IntPtr)(&read));
        if (read != bytes.Length) throw new EndOfStreamException("The serialized PIDL stream was truncated.");
    }

    private static string PhysicalPath(IShellItem item)
    {
        RequireOk(item.GetDisplayName(FileSystemPath, out var pointer), "Cannot resolve the Shell item's physical path");
        try
        {
            var path = Marshal.PtrToStringUni(pointer);
            if (string.IsNullOrEmpty(path)) throw new IOException("Shell returned no physical path.");
            return PathPolicy.FileSystemAbsolute(path);
        }
        finally { Marshal.FreeCoTaskMem(pointer); }
    }

    private static void RequireOk(int result, string message)
    {
        // 正のskip/merge/cancelも復元・削除の成功とは扱わない。
        if (result != 0) throw ShellError(message, result);
    }

    private static void RequireCompletedTransfer(int result, string message)
    {
        if (result != 0 && result != DontProcessChildren) throw ShellError(message, result);
    }

    private static IOException ShellError(string message, int result)
    {
        // SDKの共有違反とWin32の共有・ロック違反だけを使用中と案内し、アクセス拒否からは推測しない。
        var guidance = unchecked((uint)result) is 0x80270027 or 0x80270028 or 0x80070020 or 0x80070021
            ? " The target, one of its children, or the destination is in use by another process. Close the application using it and check both the original path and the Recycle Bin before retrying manually."
            : string.Empty;
        return new IOException($"{message} (HRESULT 0x{result:X8}).{guidance}", result);
    }
    private static void Release(object? value)
    {
        if (value is not null && Marshal.IsComObject(value)) _ = Marshal.ReleaseComObject(value);
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    private sealed class TransferSink : ITransferAdviseSink
    {
        public int UpdateProgress(ulong currentBytes, ulong totalBytes, int currentFiles, int totalFiles, int currentFolders, int totalFolders) => 0;
        public int UpdateTransferState(uint state) => 0;
        public int ConfirmOverwrite(IShellItem? source, IShellItem? destinationParent, string name) => AlreadyExists;
        public int ConfirmEncryptionLoss(IShellItem? source) => Abort;
        public int FileFailure(IShellItem? item, string? name, int error, IntPtr rename, uint renameLength) => error < 0 ? error : Abort;
        public int SubStreamFailure(IShellItem? item, string name, int error) => error < 0 ? error : Abort;
        public int PropertyFailure(IShellItem? item, IntPtr key, int error) => error < 0 ? error : Abort;
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        [PreserveSig] int BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr value);
        [PreserveSig] int GetParent(out IShellItem? parent);
        [PreserveSig] int GetDisplayName(uint kind, out IntPtr value);
        [PreserveSig] int GetAttributes(uint mask, out uint attributes);
        [PreserveSig] int Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("70629033-E363-4A28-A567-0DB78006E6D7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumShellItems
    {
        [PreserveSig] int Next(uint count, out IShellItem? item, out uint fetched);
        [PreserveSig] int Skip(uint count);
        [PreserveSig] int Reset();
        [PreserveSig] int Clone(out IEnumShellItems? value);
    }

    [ComImport, Guid("00ADB003-BDE9-45C6-8E29-D09F9353E108"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITransferSource
    {
        [PreserveSig] int Advise(ITransferAdviseSink sink, out uint cookie);
        [PreserveSig] int Unadvise(uint cookie);
        [PreserveSig] int SetProperties(IntPtr changes);
        [PreserveSig] int OpenItem(IShellItem item, uint flags, ref Guid iid, out IntPtr value);
        [PreserveSig] int MoveItem(IShellItem source, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, uint flags, out IShellItem? moved);
        [PreserveSig] int RecycleItem(IShellItem source, IShellItem destination, uint flags, out IShellItem? recycled);
    }

    [ComImport, ComVisible(true), Guid("D594D0D8-8DA7-457B-B3B4-CE5DBAAC0B88"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITransferAdviseSink
    {
        [PreserveSig] int UpdateProgress(ulong currentBytes, ulong totalBytes, int currentFiles, int totalFiles, int currentFolders, int totalFolders);
        [PreserveSig] int UpdateTransferState(uint state);
        [PreserveSig] int ConfirmOverwrite(IShellItem? source, IShellItem? destinationParent, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int ConfirmEncryptionLoss(IShellItem? source);
        [PreserveSig] int FileFailure(IShellItem? item, [MarshalAs(UnmanagedType.LPWStr)] string? name, int error, IntPtr rename, uint renameLength);
        [PreserveSig] int SubStreamFailure(IShellItem? item, [MarshalAs(UnmanagedType.LPWStr)] string name, int error);
        [PreserveSig] int PropertyFailure(IShellItem? item, IntPtr key, int error);
    }

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint flags);
    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();
    [DllImport("ole32.dll")]
    private static extern int CreateStreamOnHGlobal(IntPtr global, [MarshalAs(UnmanagedType.Bool)] bool deleteOnRelease, out IStream stream);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IShellItem? item);
    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderItem(ref Guid folder, uint flags, IntPtr token, ref Guid iid, out IShellItem? item);
    [DllImport("shell32.dll")]
    private static extern int SHGetIDListFromObject([MarshalAs(UnmanagedType.IUnknown)] object value, out IntPtr pidl);
    [DllImport("shell32.dll")]
    private static extern int ILSaveToStream(IStream stream, IntPtr pidl);
    [DllImport("shell32.dll")]
    private static extern int ILLoadFromStreamEx(IStream stream, out IntPtr pidl);
    [DllImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ILIsEqual(IntPtr first, IntPtr second);
    [DllImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ILIsParent(IntPtr parent, IntPtr child, [MarshalAs(UnmanagedType.Bool)] bool immediate);
}
