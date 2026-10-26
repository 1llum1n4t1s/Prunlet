using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static partial class NativeFiles
{
    internal static SafeFileHandle CreatePrivateRegistryFile(string path) => CreatePrivateRegistryMember(path, directory: false);
    internal static SafeFileHandle CreatePrivateRegistryDirectory(string path) => CreatePrivateRegistryMember(path, directory: true);
    internal static SafeFileHandle OpenPrivateRegistryDirectory(string path) => Open(path, 0x00020080, 3, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenLifecycleMetadata(string path) => Open(path, Read | 0x00020000, 1, 3, OpenReparse);
    internal static SafeFileHandle OpenLifecycleDelete(string path) => Open(path, Read | Delete | 0x00020000, 1, 3, OpenReparse | BackupSemantics);
    internal static SafeFileHandle OpenLifecyclePendingPublisher(string path) => Open(path, Read | Write | Delete | 0x00020000, 1, 3, OpenReparse);
    internal static SafeFileHandle OpenLifecycleDirectoryMove(string path) => Open(path, Delete | 0x80 | 0x00020000, 1, 3, OpenReparse | BackupSemantics);

    // private親から継承された既存のresult JSONも、許可主体・権利を弱めずに検査する。
    internal static void VerifyPrivateRecoveryMemberSecurity(SafeFileHandle handle) => VerifyPrivateRegistrySecurity(handle, allowInherited: true);

    internal static byte[] ReadRegistryMemberSecurity(SafeFileHandle handle)
    {
        var error = RegistryGetSecurityInfo(handle, 1, 7, out _, out _, out _, out _, out var descriptor);
        if (error != 0) throw new IOException($"Cannot inspect registry metadata owner/group/DACL (Win32 {error}).");
        try
        {
            var length = RegistrySecurityDescriptorLength(descriptor);
            if (length is 0 or > 65536) throw new InvalidDataException("Registry metadata security size is invalid.");
            var bytes = new byte[length]; Marshal.Copy(descriptor, bytes, 0, bytes.Length); return bytes;
        }
        finally { _ = RegistryLocalFree(descriptor); }
    }

    private static SafeFileHandle CreatePrivateRegistryMember(string path, bool directory)
    {
        var owner = NativeRegistry.CurrentSid;
        var principals = new[] { owner, "S-1-5-18" }.Distinct(StringComparer.Ordinal);
        var inheritance = directory ? "OICI" : "";
        var security = new RawSecurityDescriptor($"O:{owner}D:P" + string.Concat(principals.Select(sid => $"(A;{inheritance};FA;;;{sid})")));
        var bytes = new byte[security.BinaryLength]; security.GetBinaryForm(bytes, 0);
        var name = @"\??\" + PathPolicy.Absolute(path);
        if (name.Length > 32766) throw new ArgumentException("Private registry recovery path is too long.");
        var text = Marshal.StringToHGlobalUni(name);
        var unicode = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
        var descriptor = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, descriptor, bytes.Length);
            Marshal.StructureToPtr(new UnicodeString { Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)((name.Length + 1) * 2)), Buffer = text }, unicode, false);
            var attributes = new ObjectAttributes { Length = Marshal.SizeOf<ObjectAttributes>(), ObjectName = unicode, SecurityDescriptor = descriptor };
            // FILE_CREATEを使い、最初のbyteを書き込む前から本人とSYSTEMだけに限定する。
            var status = NtCreateFile(out var handle, Read | Write | (directory ? 0u : Delete) | 0x00100000, ref attributes, out _, IntPtr.Zero,
                directory ? (uint)FileAttributes.Directory : (uint)FileAttributes.Archive, directory ? 3u : 1u, 2,
                directory ? 0x00200021u : 0x00200060u, IntPtr.Zero, 0);
            if (status < 0)
            {
                handle.Dispose();
                var error = (int)RtlNtStatusToDosError(status);
                throw new IOException($"Cannot exclusively create private registry recovery member (Win32 {error}): {new Win32Exception(error).Message}");
            }
            try
            {
                Verify(handle, path, directory);
                VerifySingleLink(handle);
                RejectNamedStreams(path);
                VerifyPrivateRegistrySecurity(handle, directory);
                return handle;
            }
            catch { handle.Dispose(); throw; }
        }
        finally { Marshal.FreeHGlobal(descriptor); Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(text); }
    }

    internal static void VerifyPrivateRegistrySecurity(SafeFileHandle handle, bool directory = false, bool allowInherited = false)
    {
        var error = RegistryGetSecurityInfo(handle, 1, 5, out _, out _, out _, out _, out var descriptor);
        if (error != 0) throw new IOException($"Cannot inspect private registry recovery ACL (Win32 {error}): {new Win32Exception((int)error).Message}");
        try
        {
            var length = RegistrySecurityDescriptorLength(descriptor);
            if (length is 0 or > 65536) throw new InvalidDataException("Private registry recovery security descriptor size is invalid.");
            var bytes = new byte[length]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            var security = new RawSecurityDescriptor(bytes, 0);
            var owner = NativeRegistry.CurrentSid;
            var expected = new HashSet<string>([owner, "S-1-5-18"], StringComparer.Ordinal);
            var required = ControlFlags.DiscretionaryAclPresent | (allowInherited ? 0 : ControlFlags.DiscretionaryAclProtected);
            if (security.Owner?.Value != owner || (security.ControlFlags & required) != required
                || security.DiscretionaryAcl is not RawAcl acl || acl.Count != expected.Count)
                throw new InvalidDataException("Registry recovery member has an unexpected owner or unprotected ACL; it was retained without changing permissions.");
            var flags = directory ? AceFlags.ObjectInherit | AceFlags.ContainerInherit : AceFlags.None;
            foreach (var ace in acl)
                if (ace is not CommonAce allowed || allowed.IsCallback || allowed.AceQualifier != AceQualifier.AccessAllowed
                    || (allowInherited ? allowed.AceFlags & ~AceFlags.Inherited : allowed.AceFlags) != flags
                    || allowed.AccessMask != (int)FileSystemRights.FullControl || !expected.Remove(allowed.SecurityIdentifier.Value))
                    throw new InvalidDataException("Registry recovery ACL must grant only the current user and SYSTEM full control; it was retained.");
        }
        finally { _ = RegistryLocalFree(descriptor); }
    }

    [DllImport("advapi32.dll", EntryPoint = "GetSecurityInfo")]
    private static extern uint RegistryGetSecurityInfo(SafeFileHandle handle, int objectType, uint information,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll", EntryPoint = "GetSecurityDescriptorLength")]
    private static extern uint RegistrySecurityDescriptorLength(IntPtr descriptor);
    [DllImport("kernel32.dll", EntryPoint = "LocalFree")]
    private static extern IntPtr RegistryLocalFree(IntPtr descriptor);
}
