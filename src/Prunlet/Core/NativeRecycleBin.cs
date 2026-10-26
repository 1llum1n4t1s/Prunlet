using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;

using System.Security.Principal;

namespace Prunlet.Core;



// ごみ箱の実体・付随情報の変更はShellだけに任せる。
internal static class NativeRecycleBin
{
    private const int Abort = unchecked((int)0x80004004);
    private const int AlreadyExists = unchecked((int)0x80070050);
    private const int DontProcessChildren = 0x00270008;
    private const uint FileSystemPath = 0x80058000;

    private static readonly Guid RecycleFolder = new("B7534046-3ECB-4C18-BE4E-64CD4CB7D6AC");
    private static readonly Guid ShellItemId = new("43826D1E-E718-42EE-BC55-A1E261C37BFE");


    private static readonly Guid TransferHandler = new("D5E346A1-F753-4932-B403-4574800E2498");
    private static readonly Guid TransferSourceId = new("00ADB003-BDE9-45C6-8E29-D09F9353E108");

    // 記録を作らずWindowsへ移動だけを委ねる。PIDLの保存・実体列挙・ACL snapshotは行わない。
    internal static void RecycleUnrecorded(string sourcePath, Action<string> beforeDelete)
    {
        ArgumentNullException.ThrowIfNull(beforeDelete);
        sourcePath = PathPolicy.Absolute(sourcePath);
        InSta(() =>
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
                // 失敗・確認・再試行・昇格要求を永久削除等へ切り替えない。
                var result = transfer.RecycleItem(source, bin, 0, out created);
                RequireCompletedTransfer(result, "Windows did not confirm recycling");
                if (created is null) throw new IOException("Windows returned no recycled item; completion is unknown.");

                return true;
            }
            finally
            {
                if (advised) _ = transfer!.Unadvise(cookie);
                Release(created); Release(transfer); Release(bin); Release(parent); Release(source);
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
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IShellItem? item);
    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderItem(ref Guid folder, uint flags, IntPtr token, ref Guid iid, out IShellItem? item);
}
