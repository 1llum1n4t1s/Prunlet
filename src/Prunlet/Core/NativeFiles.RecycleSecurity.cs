using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static partial class NativeFiles
{
    private const int MaximumRecycleSecurityBytes = 1024 * 1024;
    private const uint RecycleOwnerGroupDacl = 1 | 2 | 4;

    // データ読取りやリンク先の列挙は要求しない。File IDの照合は呼出元がこの同じhandleで行う。
    internal static SafeFileHandle OpenRecycleSecurity(string path, bool writable = false) =>
        Open(path, 0x20080u | (writable ? 0x40000u : 0u), 7, 3, OpenReparse | BackupSemantics);

    // stage到着後、DACLの補正前にrootのDELETE権限を確保し、最後の非上書き移動まで同じhandleを使う。
    // 全nodeのsecurity handleと共存させるため、読取り・書込み・削除共有を許可する。
    internal static SafeFileHandle OpenRecycleRestoreRoot(string path) =>
        Open(path, Delete | 0x60080u, 7, 3, OpenReparse | BackupSemantics);

    internal static byte[] ReadRecycleSecurity(SafeFileHandle handle)
    {
        var succeeded = RecycleGetKernelObjectSecurity(handle, RecycleOwnerGroupDacl, null, 0, out var needed);
        var error = Marshal.GetLastWin32Error();
        if (!succeeded && error != 122)
            throw new IOException($"Cannot measure recycle security descriptor (Win32 {error}).", new Win32Exception(error));
        if (needed is < 20 or > MaximumRecycleSecurityBytes)
            throw new InvalidDataException("Recycle security descriptor size is unsupported.");

        var descriptor = new byte[needed];
        if (!RecycleGetKernelObjectSecurity(handle, RecycleOwnerGroupDacl, descriptor, needed, out var written))
        {
            error = Marshal.GetLastWin32Error();
            throw new IOException($"Cannot read recycle owner/group/DACL (Win32 {error}).", new Win32Exception(error));
        }
        if (written is < 20 || written > descriptor.Length)
            throw new InvalidDataException("Recycle security descriptor length changed unexpectedly.");
        if (written != descriptor.Length) Array.Resize(ref descriptor, checked((int)written));
        ValidateRecycleSecurity(descriptor);
        return descriptor;
    }

    internal static void ValidateRecycleSecurity(byte[] descriptor)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        if (descriptor.Length is < 20 or > MaximumRecycleSecurityBytes)
            throw new InvalidDataException("Recycle security descriptor size is unsupported.");
        RawSecurityDescriptor parsed;
        try { parsed = new RawSecurityDescriptor(descriptor, 0); }
        catch (Exception error) when (error is ArgumentException or OverflowException or IndexOutOfRangeException)
        {
            throw new InvalidDataException("Recycle security descriptor is invalid.", error);
        }
        if (parsed.Owner is null || parsed.Group is null || (parsed.ControlFlags & ControlFlags.SelfRelative) == 0)
            throw new InvalidDataException("Recycle security descriptor is missing owner/group or self-relative format.");
        if ((parsed.ControlFlags & ControlFlags.DiscretionaryAclPresent) == 0 || parsed.DiscretionaryAcl is null)
            throw new InvalidDataException("Recycle security descriptor has an absent or null DACL.");
    }

    internal static void RestoreRecycleDacl(SafeFileHandle handle, byte[] expected)
    {
        ArgumentNullException.ThrowIfNull(expected);
        if (expected.Length is < 20 or > MaximumRecycleSecurityBytes)
            throw new InvalidDataException("Recycle security descriptor size is unsupported.");
        // 呼出元の配列を変更せず、検証後も同じ原本bytesで比較する。
        var original = (byte[])expected.Clone();
        ValidateRecycleSecurity(original);
        var current = ReadRecycleSecurity(handle);
        var originalDescriptor = new RawSecurityDescriptor(original, 0);
        var currentDescriptor = new RawSecurityDescriptor(current, 0);
        if (!Equals(originalDescriptor.Owner, currentDescriptor.Owner) || !Equals(originalDescriptor.Group, currentDescriptor.Group))
            throw new IOException("Recycle owner/group differs from the original; DACL restoration was refused.");
        if (current.AsSpan().SequenceEqual(original)) return;

        // 元の保護状態・ACE順序・Inherited flagsを保持する。AIのある原本だけREQを入力に加える。
        // NtSetSecurityObjectの出力ではREQが消えAIが保持されることを専用fixtureで検証している。
        if ((originalDescriptor.ControlFlags & ControlFlags.DiscretionaryAclAutoInherited) != 0)
            originalDescriptor.SetFlags(originalDescriptor.ControlFlags | ControlFlags.DiscretionaryAclAutoInheritRequired);
        var input = new byte[originalDescriptor.BinaryLength];
        originalDescriptor.GetBinaryForm(input, 0);

        // DACL=4だけを要求し、所有者・group・SACLは設定しない。Windows移動によるSACLの結果までは保証しない。
        // File IDの照合と移動との順序制御は呼出元が同じhandleに対して行う。
        var status = RecycleNtSetSecurityObject(handle, 4, input);
        if (status < 0)
            throw new IOException($"Cannot restore recycle DACL (NTSTATUS 0x{unchecked((uint)status):X8}).", status);
        if (!ReadRecycleSecurity(handle).AsSpan().SequenceEqual(original))
            throw new IOException("Restored recycle owner/group/DACL bytes differ from the original.");
    }

    [DllImport("advapi32.dll", EntryPoint = "GetKernelObjectSecurity", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RecycleGetKernelObjectSecurity(SafeFileHandle handle, uint information,
        [Out] byte[]? descriptor, uint length, out uint needed);

    [DllImport("ntdll.dll", EntryPoint = "NtSetSecurityObject")]
    private static extern int RecycleNtSetSecurityObject(SafeFileHandle handle, uint information, [In] byte[] descriptor);
}
