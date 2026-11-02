using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.RecordlessE2E;

// 削除要求はCLI/MCPだけが行う。このhelperはDELETE共有の観測handleとfixtureのDACLだけを扱う。
public sealed class AccessDeniedFixture : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] struct Standard { public long Allocation, End; public uint Links; public byte Pending, Directory; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out Standard value, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, byte[] bytes, uint size);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[] bytes, uint length, out uint needed);
    [DllImport("ntdll.dll")] static extern int NtSetSecurityObject(SafeFileHandle handle, uint information, byte[] descriptor);
    readonly SafeFileHandle handle;
    readonly byte[] original;
    readonly bool writableAcl;
    bool changed;

    public AccessDeniedFixture(string path, bool writableAcl = false)
    {
        this.writableAcl = writableAcl;
        handle = CreateFileW(path, writableAcl ? 0x60080u : 0x20080u, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception();
        try { original = Security(); } catch { handle.Dispose(); throw; }
    }

    public static int OpenError(string path, uint access)
    {
        using var probe = CreateFileW(path, access, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        return probe.IsInvalid ? Marshal.GetLastWin32Error() : 0;
    }

    byte[] Security()
    {
        if (GetKernelObjectSecurity(handle, 7, null, 0, out uint needed) || Marshal.GetLastWin32Error() != 122 || needed < 20 || needed > 1048576)
            throw new IOException("Fixture security length unavailable.");
        var bytes = new byte[needed];
        if (!GetKernelObjectSecurity(handle, 7, bytes, needed, out needed)) throw new Win32Exception();
        return bytes;
    }

    public object State()
    {
        if (!GetFileInformationByHandleEx(handle, 1, out Standard standard, (uint)Marshal.SizeOf<Standard>())) throw new Win32Exception();
        var id = new byte[24];
        if (!GetFileInformationByHandleEx(handle, 18, id, 24)) throw new Win32Exception();
        return new { id = Convert.ToHexString(id), deletePending = standard.Pending != 0, links = standard.Links, security = Convert.ToBase64String(Security()) };
    }

    void Apply(byte[] bytes)
    {
        var descriptor = new RawSecurityDescriptor(bytes, 0);
        if ((descriptor.ControlFlags & ControlFlags.DiscretionaryAclAutoInherited) != 0)
            descriptor.SetFlags(descriptor.ControlFlags | ControlFlags.DiscretionaryAclAutoInheritRequired);
        var input = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(input, 0);
        int status = NtSetSecurityObject(handle, 4, input);
        if (status < 0) throw new IOException("Fixture DACL NTSTATUS " + status);
    }

    public void DenyDelete(bool directory)
    {
        if (!writableAcl) throw new InvalidOperationException("DACL setup was not selected.");
        var descriptor = new RawSecurityDescriptor(original, 0);
        // 親のDELETE_CHILDと子のDELETEを両方拒否し、所有者の暗黙READ_CONTROLとは区別する。
        descriptor.DiscretionaryAcl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessDenied,
            directory ? 0x40 : 0x10001, WindowsIdentity.GetCurrent().User, false, null));
        var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
        Apply(bytes); changed = true;
    }

    public void Dispose()
    {
        try { if (changed) { Apply(original); changed = false; } }
        finally { handle.Dispose(); }
    }
}
