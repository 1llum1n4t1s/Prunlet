using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static class RegistrySessionNative
{
    internal static SafeFileHandle OpenDescriptor(string path)
    {
        // serverの作成handleはWRITE/DELETEを持つ。こちらは読取のみで既存handleとの共有を許す。
        // serverがshare-readで保持する間、第三者のwrite/delete openは引き続き拒否される。
        var handle = CreateFileW(@"\\?\" + PathPolicy.Absolute(path), 0x80000000, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw Error("Cannot open registry session descriptor"); }
        return handle;
    }

    internal sealed class Peer : IDisposable
    {
        internal SafeProcessHandle Handle { get; }
        internal uint ProcessId { get; }
        internal long CreationTime { get; }
        internal string Sid { get; }
        internal string AuthenticationId { get; }
        internal uint SessionId { get; }
        internal string ExecutablePath { get; }
        internal FileStream Executable { get; }
        internal string ExecutableHash { get; }

        internal Peer(uint processId)
        {
            ProcessId = processId;
            Handle = OpenProcess(0x101000, false, processId);
            if (Handle.IsInvalid) { Handle.Dispose(); throw Error("Cannot pin session peer process"); }
            try
            {
                RequireAlive();
                if (!GetProcessTimes(Handle, out var created, out _, out _, out _)) throw Error("Cannot inspect session peer lifetime");
                CreationTime = created;
                var text = new StringBuilder(32768); var length = (uint)text.Capacity;
                if (!QueryFullProcessImageNameW(Handle, 0, text, ref length)) throw Error("Cannot inspect session peer executable");
                ExecutablePath = PathPolicy.Absolute(text.ToString());
                var image = NativeFiles.OpenBackup(ExecutablePath);
                try { NativeFiles.Verify(image, ExecutablePath); Executable = new FileStream(image, FileAccess.Read); }
                catch { image.Dispose(); throw; }
                ExecutableHash = Convert.ToHexStringLower(SHA256.HashData(Executable));
                if (!OpenProcessToken(Handle, 8, out var token)) throw Error("Cannot inspect session peer token");
                using (token)
                using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
                {
                    Sid = identity.User?.Value ?? throw new UnauthorizedAccessException("Session peer has no user SID.");
                    var statistics = TokenInformation<TokenStatistics>(token, 10);
                    AuthenticationId = $"{statistics.AuthenticationId.High:X8}:{statistics.AuthenticationId.Low:X8}";
                    SessionId = TokenInformation<uint>(token, 12);
                    if (TokenInformation<uint>(token, 29) != 0) throw new UnauthorizedAccessException("AppContainer peers cannot use a native registry session.");
                }
                RequireAlive();
            }
            catch { Executable?.Dispose(); Handle.Dispose(); throw; }
        }

        internal void RequireAlive()
        {
            if (WaitForSingleObject(Handle, 0) != 258) throw new UnauthorizedAccessException("Session peer exited or its process identity is unavailable.");
        }

        internal void RequireSameLogonAndExecutable(Peer other)
        {
            RequireAlive(); other.RequireAlive();
            if (Sid != other.Sid || AuthenticationId != other.AuthenticationId || SessionId != other.SessionId
                || !ExecutablePath.Equals(other.ExecutablePath, StringComparison.OrdinalIgnoreCase) || ExecutableHash != other.ExecutableHash)
                throw new UnauthorizedAccessException("Registry session requires the same executable and Windows logon.");
        }

        public void Dispose() { Executable.Dispose(); Handle.Dispose(); }
    }

    internal static Peer Self() => new((uint)Environment.ProcessId);

    internal static Peer PipePeer(PipeStream pipe, bool server)
    {
        var success = server ? GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var processId)
            : GetNamedPipeServerProcessId(pipe.SafePipeHandle, out processId);
        if (!success || processId == 0) throw Error("Cannot identify registry pipe peer");
        return new Peer(processId);
    }

    internal static bool HasPackageIdentity()
    {
        uint length = 0;
        var status = GetPackageFullName(GetCurrentProcess(), ref length, null);
        if (status == 15700) return false;
        if (status is 0 or 122) return true;
        throw new IOException($"Cannot inspect native session package identity (Win32 {status}).");
    }

    internal static NamedPipeServerStream CreatePipe(string name, string owner)
    {
        var security = new RawSecurityDescriptor($"O:{owner}D:P(A;;FA;;;{owner})");
        var bytes = new byte[security.BinaryLength]; security.GetBinaryForm(bytes, 0);
        var descriptor = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, descriptor, bytes.Length);
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor };
            // 最初のinstanceだけ、remote拒否、非継承handle。別serverによる同名横取りは失敗する。
            var handle = CreateNamedPipeW(@"\\.\pipe\" + name, 0x40080003, 8, 1, 65536, 65536, 1000, ref attributes);
            if (handle.IsInvalid) { handle.Dispose(); throw Error("Cannot create private registry pipe"); }
            try
            {
                VerifyPipeSecurity(handle, owner);
                return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
            }
            catch { handle.Dispose(); throw; }
        }
        finally { Marshal.FreeHGlobal(descriptor); }
    }

    internal static void VerifyPipeSecurity(SafePipeHandle pipe, string owner)
    {
        var error = GetSecurityInfo(pipe, 1, 5, out _, out _, out _, out _, out var descriptor);
        if (error != 0) throw new IOException($"Cannot inspect registry session pipe ACL (Win32 {error}).");
        try
        {
            var size = GetSecurityDescriptorLength(descriptor);
            if (size is 0 or > 65536) throw new InvalidDataException("Invalid registry session pipe security descriptor.");
            var bytes = new byte[size]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            var security = new RawSecurityDescriptor(bytes, 0);
            if (security.Owner?.Value != owner || (security.ControlFlags & (ControlFlags.DiscretionaryAclProtected | ControlFlags.DiscretionaryAclPresent))
                    != (ControlFlags.DiscretionaryAclProtected | ControlFlags.DiscretionaryAclPresent)
                || security.DiscretionaryAcl is not RawAcl acl || acl.Count != 1 || acl[0] is not CommonAce ace
                || ace.IsCallback || ace.AceQualifier != AceQualifier.AccessAllowed || ace.AceFlags != AceFlags.None
                || ace.AccessMask != (int)FileSystemRights.FullControl || ace.SecurityIdentifier.Value != owner)
                throw new UnauthorizedAccessException("Registry session pipe does not have the required private owner ACL.");
        }
        finally { _ = LocalFree(descriptor); }
    }

    internal static SafeAccessTokenHandle DuplicateEffectiveToken(Peer expected)
    {
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query | TokenAccessLevels.Duplicate);
        if (identity.ImpersonationLevel != TokenImpersonationLevel.Impersonation && identity.ImpersonationLevel != TokenImpersonationLevel.Delegation)
            throw new UnauthorizedAccessException("Registry session requires client impersonation.");
        var statistics = TokenInformation<TokenStatistics>(identity.AccessToken, 10);
        if (identity.User?.Value != expected.Sid || $"{statistics.AuthenticationId.High:X8}:{statistics.AuthenticationId.Low:X8}" != expected.AuthenticationId
            || TokenInformation<uint>(identity.AccessToken, 12) != expected.SessionId)
            throw new UnauthorizedAccessException("The effective client token differs from the authenticated Windows logon.");
        if (!DuplicateTokenEx(identity.AccessToken, 0x2E, IntPtr.Zero, 2, 2, out var duplicate))
            throw Error("Cannot duplicate the effective client token");
        return duplicate;
    }

    private static T TokenInformation<T>(SafeAccessTokenHandle token, int information) where T : struct
    {
        var size = Marshal.SizeOf<T>(); var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!GetTokenInformation(token, information, buffer, size, out _)) throw Error("Cannot inspect session token identity");
            return Marshal.PtrToStructure<T>(buffer);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static IOException Error(string action) => new($"{action} (Win32 {Marshal.GetLastWin32Error()}).");
    [StructLayout(LayoutKind.Sequential)] private struct Luid { internal uint Low; internal int High; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenStatistics
    {
        internal Luid TokenId, AuthenticationId;
        internal long Expiration;
        internal int Type, Impersonation;
        internal uint DynamicCharged, DynamicAvailable, GroupCount, PrivilegeCount;
        internal Luid ModifiedId;
    }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(SafeProcessHandle process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageNameW(SafeProcessHandle process, uint flags, StringBuilder path, ref uint length);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetPackageFullName(IntPtr process, ref uint length, StringBuilder? name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafePipeHandle CreateNamedPipeW(string name, uint openMode, uint pipeMode, uint instances, uint outSize, uint inSize, uint timeout, ref SecurityAttributes security);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int information, IntPtr buffer, int size, out int required);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DuplicateTokenEx(SafeAccessTokenHandle token, uint access, IntPtr attributes, int level, int type, out SafeAccessTokenHandle duplicate);
    [DllImport("advapi32.dll")] private static extern uint GetSecurityInfo(SafePipeHandle handle, int type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll")] private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
}
