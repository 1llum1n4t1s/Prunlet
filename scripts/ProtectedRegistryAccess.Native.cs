using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using Microsoft.Win32.SafeHandles;

// 隔離fixtureのopen適合性だけを検査する。キー・値の削除APIは持たない。
public static class ProtectedRegistryAccessProbe
{
    [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct BasicObjectInformation
    {
        public uint Attributes, GrantedAccess, HandleCount, PointerCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=10)] public uint[] Reserved;
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] static extern SafeFileHandle OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out SafeFileHandle token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(SafeFileHandle token, int information, byte[] data, uint length, out uint returned);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValueW(string system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(SafeFileHandle token, bool disable, ref Privileges requested, uint size, out Privileges previous, out uint returned);
    [DllImport("ntdll.dll")] static extern int NtOpenKeyEx(out SafeRegistryHandle key, uint access, ref ObjectAttributes attributes, uint options);
    [DllImport("ntdll.dll")] static extern int NtOpenKeyTransactedEx(out SafeRegistryHandle key, uint access, ref ObjectAttributes attributes, uint options, SafeFileHandle transaction);
    [DllImport("ntdll.dll")] static extern uint RtlNtStatusToDosError(int status);
    [DllImport("ntdll.dll")] static extern int NtQueryKey(SafeRegistryHandle key, int information, byte[] data, uint length, out uint returned);
    [DllImport("ntdll.dll")] static extern int NtQueryObject(SafeRegistryHandle key, int information, byte[] data, uint length, out uint returned);
    [DllImport("KtmW32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateTransaction(IntPtr security, IntPtr unit, uint options, uint isolation, uint flags, uint timeout, string description);
    [DllImport("KtmW32.dll", SetLastError=true)] static extern bool RollbackTransaction(SafeFileHandle transaction);
    [DllImport("KtmW32.dll", SetLastError=true)] static extern bool CommitTransaction(SafeFileHandle transaction);
    [DllImport("advapi32.dll")] static extern int RegGetKeySecurity(SafeRegistryHandle key, uint information, byte[] data, ref uint length);
    [DllImport("advapi32.dll")] static extern int RegSetKeySecurity(SafeRegistryHandle key, uint information, byte[] data);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegQueryValueExW(SafeRegistryHandle key, string name, IntPtr reserved, out uint type, byte[] data, ref uint length);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegSetValueExW(SafeRegistryHandle key, string name, uint reserved, uint type, byte[] data, uint length);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegQueryInfoKeyW(SafeRegistryHandle key, StringBuilder keyClass, ref uint classLength, IntPtr reserved, out uint children, out uint maximumName, out uint maximumClass, out uint values, out uint maximumValueName, out uint maximumValueData, out uint securityLength, out long lastWrite);

    public sealed class PrivilegeLease : IDisposable
    {
        readonly SafeFileHandle token;
        readonly List<Privileges> previous = new List<Privileges>();
        public Dictionary<string, string> Before, Enabled, After;
        public bool Restored;
        public readonly List<int> RestoreErrors = new List<int>();
        public PrivilegeLease()
        {
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Before = Snapshot(token);
            try
            {
                foreach (var name in new[] { "SeBackupPrivilege", "SeRestorePrivilege", "SeSecurityPrivilege" })
                {
                    Luid luid;
                    if (!LookupPrivilegeValueW(null, name, out luid)) throw new Win32Exception(Marshal.GetLastWin32Error(), name);
                    var requested = new Privileges { Count = 1, Luid = luid, Attributes = 2 };
                    Privileges old; uint returned;
                    if (!AdjustTokenPrivileges(token, false, ref requested, (uint)Marshal.SizeOf<Privileges>(), out old, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error(), name);
                    int error = Marshal.GetLastWin32Error();
                    if (error != 0) throw new Win32Exception(error, name + " unavailable in the effective process token");
                    previous.Add(old);
                }
                Enabled = Snapshot(token);
            }
            catch { Dispose(); throw; }
        }
        public void Dispose()
        {
            for (int i = previous.Count - 1; i >= 0; i--)
            {
                var old = previous[i]; Privileges ignored; uint returned;
                bool success = AdjustTokenPrivileges(token, false, ref old, (uint)Marshal.SizeOf<Privileges>(), out ignored, out returned);
                int error = Marshal.GetLastWin32Error(); if (!success || error != 0) RestoreErrors.Add(error);
            }
            previous.Clear();
            try
            {
                After = Snapshot(token); Restored = RestoreErrors.Count == 0;
                foreach (var item in Before) if (!After.ContainsKey(item.Key) || After[item.Key] != item.Value) Restored = false;
            }
            finally { token.Dispose(); }
            if (!Restored) throw new InvalidOperationException("Privilege restoration did not preserve the original token attributes.");
        }
        internal static Dictionary<string, string> Snapshot(SafeFileHandle token)
        {
            uint size; GetTokenInformation(token, 3, null, 0, out size);
            if (size < 4 || size > 65536) throw new InvalidOperationException("Invalid token privilege information size.");
            var data = new byte[size]; if (!GetTokenInformation(token, 3, data, size, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new Dictionary<string, string>();
            foreach (var name in new[] { "SeBackupPrivilege", "SeRestorePrivilege", "SeSecurityPrivilege" })
            {
                Luid luid; if (!LookupPrivilegeValueW(null, name, out luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
                string value = "absent";
                for (int i = 0; i < BitConverter.ToUInt32(data, 0); i++)
                {
                    int offset = 4 + i * 12;
                    if (BitConverter.ToUInt32(data, offset) == luid.Low && BitConverter.ToInt32(data, offset + 4) == luid.High) value = "0x" + BitConverter.ToUInt32(data, offset + 8).ToString("X8");
                }
                result[name] = value;
            }
            return result;
        }
    }
    public static Dictionary<string, string> ProcessPrivileges(uint processId)
    {
        using (var process = OpenProcess(0x1000, false, processId))
        {
            if (process.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            SafeFileHandle token;
            if (!OpenProcessToken(process.DangerousGetHandle(), 8, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            using (token) return PrivilegeLease.Snapshot(token);
        }
    }
    public sealed class OpenResult : IDisposable
    {
        public SafeRegistryHandle Handle;
        public int Error;
        public string Status;
        public uint GrantedAccess;
        public void Dispose() { Handle?.Dispose(); }
    }
    public static OpenResult Open(SafeFileHandle transaction, SafeRegistryHandle parent, string name, uint options, bool raw, uint access)
    {
        var text = Marshal.StringToHGlobalUni(name);
        var unicode = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
        try
        {
            Marshal.StructureToPtr(new UnicodeString { Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)((name.Length + 1) * 2)), Buffer = text }, unicode, false);
            var attributes = new ObjectAttributes { Length = Marshal.SizeOf<ObjectAttributes>(), RootDirectory = parent == null ? IntPtr.Zero : parent.DangerousGetHandle(), ObjectName = unicode, Attributes = 0x40u | 0x1000u | (raw ? 0x100u : 0) };
            SafeRegistryHandle handle;
            int status = transaction == null ? NtOpenKeyEx(out handle, access, ref attributes, options) : NtOpenKeyTransactedEx(out handle, access, ref attributes, options, transaction);
            var result = new OpenResult { Handle = handle, Error = status < 0 ? checked((int)RtlNtStatusToDosError(status)) : 0, Status = status.ToString("X8") };
            if (status >= 0)
            {
                try
                {
                    var data = new byte[Marshal.SizeOf<BasicObjectInformation>()]; uint returned;
                    CheckStatus(NtQueryObject(handle, 0, data, (uint)data.Length, out returned));
                    result.GrantedAccess = BitConverter.ToUInt32(data, 4);
                }
                catch { handle.Dispose(); throw; }
            }
            return result;
        }
        finally { Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(text); }
    }
    public static string Name(SafeRegistryHandle key)
    {
        uint size; NtQueryKey(key, 3, null, 0, out size);
        if (size < 4 || size > 131072) throw new InvalidOperationException("Invalid native key name size.");
        var data = new byte[size]; CheckStatus(NtQueryKey(key, 3, data, size, out size));
        return new UnicodeEncoding(false, false, true).GetString(data, 4, BitConverter.ToInt32(data, 0));
    }
    public static byte[] Security(SafeRegistryHandle key)
    {
        uint size = 0; int error = RegGetKeySecurity(key, 0x10000, null, ref size);
        if (error != 0 && error != 122) throw new Win32Exception(error);
        var data = new byte[size]; Check(RegGetKeySecurity(key, 0x10000, data, ref size)); return data;
    }
    public static string Class(SafeRegistryHandle key)
    {
        var text = new StringBuilder(1024); uint length = (uint)text.Capacity;
        uint children, maximumName, maximumClass, values, maximumValueName, maximumValueData, securityLength; long lastWrite;
        Check(RegQueryInfoKeyW(key, text, ref length, IntPtr.Zero, out children, out maximumName, out maximumClass, out values, out maximumValueName, out maximumValueData, out securityLength, out lastWrite));
        return text.ToString();
    }
    public static void Restrict(SafeRegistryHandle key)
    {
        var descriptor = new RawSecurityDescriptor("D:P(D;;KA;;;WD)");
        var data = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(data, 0); Check(RegSetKeySecurity(key, 4, data));
    }
    public static byte[] Read(SafeRegistryHandle key)
    {
        uint size = 0, type; Check(RegQueryValueExW(key, "sentinel", IntPtr.Zero, out type, null, ref size));
        var data = new byte[size]; Check(RegQueryValueExW(key, "sentinel", IntPtr.Zero, out type, data, ref size));
        if (type != 3) throw new InvalidOperationException("Raw type changed."); return data;
    }
    public static string Value(SafeRegistryHandle key, string name)
    {
        uint size = 0, type; Check(RegQueryValueExW(key, name, IntPtr.Zero, out type, null, ref size));
        var data = new byte[size]; Check(RegQueryValueExW(key, name, IntPtr.Zero, out type, data, ref size));
        return type.ToString() + ":" + Convert.ToBase64String(data);
    }
    public static int Set(SafeRegistryHandle key, byte[] data) { return RegSetValueExW(key, "sentinel", 0, 3, data, (uint)data.Length); }
    public static SafeFileHandle Begin()
    {
        var transaction = CreateTransaction(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 30000, "Prunlet isolated backup/restore open probe");
        if (transaction.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error()); return transaction;
    }
    public static int Rollback(SafeFileHandle transaction) { return RollbackTransaction(transaction) ? 0 : Marshal.GetLastWin32Error(); }
    public static int Commit(SafeFileHandle transaction) { return CommitTransaction(transaction) ? 0 : Marshal.GetLastWin32Error(); }
    static void Check(int error) { if (error != 0) throw new Win32Exception(error); }
    static void CheckStatus(int status) { if (status < 0) throw new Win32Exception(checked((int)RtlNtStatusToDosError(status))); }
}
