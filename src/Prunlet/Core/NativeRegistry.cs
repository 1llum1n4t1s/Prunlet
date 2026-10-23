using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static class NativeRegistry
{
    internal const long MaximumSnapshotBytes = 128L * 1024 * 1024;
    internal const int MaximumKeys = 4096;
    internal const int MaximumValues = 65536;
    internal const int MaximumDepth = 128;
    private const uint Query = 1, SetValue = 2, CreateSubKey = 4, Enumerate = 8;
    private const uint ReadControl = 0x20000, Delete = 0x10000, SystemSecurity = 0x1000000;
    private const uint FullSecurity = 0x00010000; // BACKUP_SECURITY_INFORMATIONはmandatory label等も含む全SDを読む。

    internal static RegistryTarget Target(RegistryDeleteRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.View is not ("32" or "64")) throw new ArgumentException("Registry view must be explicitly 32 or 64.");
        var path = request.Path;
        ValidateText(path, 32760, "Registry path");
        const string provider = @"Microsoft.PowerShell.Core\Registry::";
        if (path.StartsWith(provider, StringComparison.OrdinalIgnoreCase)) path = path[provider.Length..];
        else if (path.StartsWith("Registry::", StringComparison.OrdinalIgnoreCase)) path = path[10..];
        var slash = path.IndexOf('\\');
        if (slash < 0) throw new ArgumentException("Specify an absolute registry key below a supported hive.");
        var hive = path[..slash].ToUpperInvariant();
        hive = hive switch
        {
            "HKCU:" or "HKEY_CURRENT_USER" => "HKEY_CURRENT_USER",
            "HKLM:" or "HKEY_LOCAL_MACHINE" => "HKEY_LOCAL_MACHINE",
            "HKU:" or "HKEY_USERS" => "HKEY_USERS",
            _ => throw new ArgumentException("Only HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, and HKEY_USERS are supported.")
        };
        var segments = path[(slash + 1)..].Split('\\');
        if (segments.Length > MaximumDepth || segments.Any(segment => segment.Length == 0 || segment.Length > 255
            || segment is "." or ".." || segment.IndexOfAny(['*', '?', '[', ']', '/', ':']) >= 0))
            throw new ArgumentException("Registry paths cannot be roots, relative, wildcarded, or contain empty/unsupported segments.");
        if (request.ValueName is not null) ValidateText(request.ValueName, 16383, "Registry value name", allowEmpty: true);
        return new RegistryTarget(hive + "\\" + string.Join('\\', segments), hive, segments, request.View, request.ValueName);
    }

    internal static void ValidateText(string? text, int maximum, string label, bool allowEmpty = false)
    {
        if (text is null || (!allowEmpty && text.Length == 0) || text.Length > maximum || text.Contains('\0'))
            throw new ArgumentException($"{label} is empty, oversized, or contains NUL.");
        for (var i = 0; i < text.Length; i++)
        {
            if (!char.IsSurrogate(text[i])) continue;
            if (!char.IsHighSurrogate(text[i]) || ++i >= text.Length || !char.IsLowSurrogate(text[i]))
                throw new ArgumentException($"{label} contains invalid UTF-16.");
        }
    }

    internal static string CurrentSid
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            return identity.User?.Value ?? throw new UnauthorizedAccessException("The current Windows user SID is unavailable.");
        }
    }

    internal sealed class Transaction : IDisposable
    {
        internal SafeFileHandle Handle { get; }
        internal List<SafeRegistryHandle> HeldKeys { get; } = [];
        private readonly List<(SafeRegistryHandle Key, string Name)> pinnedNames = [];
        private readonly List<(RegistryTarget Target, string Name)> namespaceNames = [];
        internal void PinName(SafeRegistryHandle key, string name) => pinnedNames.Add((key, name));
        internal void PinNamespace(RegistryTarget target, string name) => namespaceNames.Add((target, name));
        internal void VerifyPinnedNames()
        {
            foreach (var pinned in pinnedNames)
                if (NtKeyName(pinned.Key) != pinned.Name)
                    throw new IOException("A pinned registry key or ancestor was renamed; the transaction was rolled back.");
            foreach (var expected in namespaceNames)
            {
                // 同じviewで要求pathを新しく辿るため、WOW64のnative投影をhardcodeしない。
                using var fresh = Open(null, expected.Target, parent: false);
                if (NtKeyName(fresh) != expected.Name)
                    throw new IOException("The requested registry namespace no longer names the pinned key; nothing was committed.");
            }
        }
        private bool completed;
        internal Transaction()
        {
            Handle = CreateTransaction(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 0, "Prunlet registry recovery");
            if (Handle.IsInvalid) Throw(Marshal.GetLastWin32Error(), "Cannot create registry transaction");
        }
        internal void Commit()
        {
            VerifyPinnedNames();
            if (!CommitTransaction(Handle)) Throw(Marshal.GetLastWin32Error(), "Registry transaction commit failed; no commit was confirmed");
            completed = true;
        }
        public void Dispose()
        {
            if (!completed) _ = RollbackTransaction(Handle);
            for (var i = HeldKeys.Count - 1; i >= 0; i--) HeldKeys[i].Dispose();
            Handle.Dispose();
        }
    }

    internal sealed class PrivilegeScope : IDisposable
    {
        private readonly SafeFileHandle token;
        private readonly List<TokenPrivileges> previous = [];
        internal PrivilegeScope(bool restore, bool requireEffectiveThreadToken = false)
        {
            // セッション中は呼出し元のeffective tokenだけを変更し、server自身の権限を借りない。
            if (!OpenThreadToken(GetCurrentThread(), 0x28, false, out token))
            {
                var error = Marshal.GetLastWin32Error();
                if (requireEffectiveThreadToken) Throw(error, "The native registry session has no effective client token");
                if (error != 1008) Throw(error, "Cannot open effective thread token");
                token.Dispose();
                if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) Throw(Marshal.GetLastWin32Error(), "Cannot open process token");
            }
            try
            {
                Enable("SeSecurityPrivilege");
                if (restore) Enable("SeRestorePrivilege");
            }
            catch { Dispose(); throw; }
        }
        private void Enable(string name)
        {
            if (!LookupPrivilegeValueW(null, name, out var luid)) Throw(Marshal.GetLastWin32Error(), "Cannot resolve registry security privilege");
            var requested = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
            if (!AdjustTokenPrivileges(token, false, ref requested, (uint)Marshal.SizeOf<TokenPrivileges>(), out var old, out _))
                Throw(Marshal.GetLastWin32Error(), "Cannot enable registry security privilege");
            var error = Marshal.GetLastWin32Error();
            if (error == 1300) throw new UnauthorizedAccessException($"{name} is absent from the current token. Complete registry-key ACL preservation requires an appropriately privileged process; no elevation or ACL changes were attempted.");
            if (error != 0) Throw(error, "Cannot enable registry security privilege");
            previous.Add(old);
        }
        public void Dispose()
        {
            for (var i = previous.Count - 1; i >= 0; i--)
            {
                var old = previous[i];
                _ = RestoreTokenPrivileges(token, false, ref old, 0, IntPtr.Zero, IntPtr.Zero);
            }
            previous.Clear();
            token.Dispose();
        }
    }

    internal static RegistryScopeIdentity VerifyNativeSessionContext()
    {
        // package identityの不在だけではnativeとは判定しない。同じSoftware objectへのTx bindも要求する。
        if (RegistrySessionNative.HasPackageIdentity())
            throw new InvalidOperationException("Start registry-session explicitly from a normal Windows desktop outside a packaged host.");
        foreach (var view in new[] { "64", "32" })
        {
            var target = Target(new RegistryDeleteRequest { Path = @"HKEY_CURRENT_USER\Software", View = view });
            using var key = Open(null, target, parent: false);
            var expected = @"\Registry\User\" + CurrentSid + @"\Software";
            if (!NtKeyName(key).Equals(expected, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The session HKCU Software path is not the native Windows user hive.");
            using var transaction = new Transaction();
            var bound = BindTransaction(transaction, target, key, 0);
            if (!NtKeyName(bound).Equals(expected, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The session registry transaction is not bound to native Windows Software.");
        }
        var machineTarget = Target(new RegistryDeleteRequest { Path = @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", View = "64" });
        using var machine = Open(null, machineTarget, parent: false);
        var machineGuid = ReadValue(machine, "MachineGuid");
        if (machineGuid.Type != 1 || machineGuid.Data.Length is < 4 or > 256)
            throw new InvalidDataException("Native Windows machine identity is unavailable.");
        var machineId = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(machineGuid.Data));
        return new RegistryScopeIdentity { Kind = "nativeWindows", MachineId = machineId, OwnerSid = CurrentSid };
    }

    // 全ての祖先を1 segmentずつOPEN_LINKで開く。Win32のtransacted openはulOptions=0のため使わない。
    internal static SafeRegistryHandle Open(Transaction? transaction, RegistryTarget target, bool parent, uint extraAccess = 0, bool fullSecurity = false)
    {
        var root = target.Hive switch
        {
            "HKEY_LOCAL_MACHINE" => @"\Registry\Machine",
            "HKEY_USERS" => @"\Registry\User",
            _ => @"\Registry\User\" + CurrentSid
        };
        var access = Query | Enumerate | ReadControl | extraAccess | View(target);
        if (fullSecurity) access |= SystemSecurity;
        var count = target.Segments.Length - (parent ? 1 : 0);
        var traversal = Query | Enumerate | ReadControl | View(target);
        // NTの固定hive anchorはresource managerを持たないことがある。利用者指定segmentからtransactionを使用する。
        var current = OpenNative(null, null, root, count == 0 ? access : traversal);
        try
        {
            RejectLink(current);
            for (var i = 0; i < count; i++)
            {
                var next = OpenNative(transaction, current, target.Segments[i], i == count - 1 ? access : traversal);
                current.Dispose(); current = next;
                RejectLink(current);
            }
            return current;
        }
        catch { current.Dispose(); throw; }
    }

    private static SafeRegistryHandle OpenNative(Transaction? transaction, SafeRegistryHandle? parent, string name, uint access)
    {
        var text = Marshal.StringToHGlobalUni(name);
        var unicode = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
        var pinned = false;
        try
        {
            parent?.DangerousAddRef(ref pinned);
            Marshal.StructureToPtr(new UnicodeString { Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)((name.Length + 1) * 2)), Buffer = text }, unicode, false);
            // 実registry linkはOpenOptions=REG_OPTION_OPEN_LINKだけでは追跡されたため、
            // OBJ_OPENLINKも指定してlink自身を開き、REG_LINK検査で拒否する。
            var attributes = new ObjectAttributes { Length = Marshal.SizeOf<ObjectAttributes>(), RootDirectory = parent?.DangerousGetHandle() ?? IntPtr.Zero, ObjectName = unicode, Attributes = 0x40 | 0x100 };
            SafeRegistryHandle handle;
            var status = transaction is null ? NtOpenKeyEx(out handle, access, ref attributes, 8)
                : NtOpenKeyTransactedEx(out handle, access, ref attributes, 8, transaction.Handle);
            if (status >= 0) return handle;
            handle.Dispose();
            Throw((int)RtlNtStatusToDosError(status), "Cannot open registry key without following links");
            throw new IOException("Unreachable registry status.");
        }
        finally
        {
            if (pinned) parent!.DangerousRelease();
            Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(text);
        }
    }

    private static SafeRegistryHandle OpenChild(Transaction? transaction, RegistryTarget target, SafeRegistryHandle parent, string name, uint extra = 0, bool security = false)
    {
        var handle = OpenNative(transaction, parent, name, Query | Enumerate | ReadControl | extra | View(target) | (security ? SystemSecurity : 0));
        try { RejectLink(handle); return handle; } catch { handle.Dispose(); throw; }
    }

    private static uint View(RegistryTarget target) => target.View == "32" ? 0x200u : 0x100u;
    private static void RejectLink(SafeRegistryHandle key)
    {
        uint size = 0;
        var error = RegQueryValueExW(key, "SymbolicLinkValue", IntPtr.Zero, out var type, null, ref size);
        if (error is not (0 or 2 or 234)) Throw(error, "Cannot inspect registry link metadata");
        if (error != 2 && type == 6) throw new IOException("Registry links and link-like keys are unsupported; nothing was followed or deleted.");
    }

    internal static RegistrySnapshot Snapshot(Transaction? transaction, RegistryTarget target, bool recursive)
    {
        SafeRegistryHandle opened;
        try { opened = Open(transaction, target, parent: false, fullSecurity: target.ValueName is null); }
        catch (FileNotFoundException ex) { throw new RegistryTargetMissingException(ex.Message); }
        using var root = opened;
        var snapshot = new RegistrySnapshot { Path = ActualTargetPath(root, target), View = target.View, ValueName = target.ValueName };
        if (target.ValueName is not null)
        {
            try
            {
                snapshot.ValueName = ActualValueName(root, target.ValueName);
                snapshot.Value = ReadValue(root, snapshot.ValueName);
            }
            catch (FileNotFoundException ex) { throw new RegistryTargetMissingException(ex.Message); }
            snapshot.ContextSecurity = Security(root, full: false);
            return snapshot;
        }
        var totalValues = 0;
        long totalBytes = 0;
        Capture(root, "", 0);
        return snapshot;

        void Capture(SafeRegistryHandle key, string relative, int depth)
        {
            if (depth > MaximumDepth || snapshot.Keys.Count >= MaximumKeys) throw new IOException("Registry snapshot key/depth limit exceeded.");
            var node = ReadNode(key, relative, ref totalValues, ref totalBytes, out var children);
            if (children > 0 && !recursive) throw new ArgumentException("Registry keys with subkeys require explicit recursive deletion.");
            snapshot.Keys.Add(node);
            foreach (var name in ChildNames(key))
            {
                using var child = OpenChild(transaction, target, key, name, security: true);
                Capture(child, relative.Length == 0 ? name : relative + "\\" + name, depth + 1);
            }
        }
    }

    private static RegistryKeySnapshot ReadNode(SafeRegistryHandle key, string relative, ref int totalValues, ref long totalBytes, out uint children)
    {
        var information = ReadKeyInformation(key);
        children = information.Children;
        var values = information.Values;
        if (values > MaximumValues - totalValues) throw new IOException("Registry snapshot value limit exceeded.");
        var node = new RegistryKeySnapshot { RelativePath = relative, Class = information.Class, Security = Security(key, full: true), LastWriteFileTime = information.LastWrite };
        ValidateText(node.Class, 32767, "Registry class", allowEmpty: true);
        totalBytes = checked(totalBytes + node.Security.Length + (relative.Length + node.Class.Length) * 2L);
        if (totalBytes > MaximumSnapshotBytes / 2) throw new IOException("Registry snapshot payload limit exceeded.");
        for (uint i = 0; i < values; i++)
        {
            var name = new StringBuilder(16384); uint length = (uint)name.Capacity;
            Check(RegEnumValueW(key, i, name, ref length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero), "Cannot enumerate registry values");
            if (length != name.Length) throw new IOException("Registry value name contains an unsupported embedded NUL.");
            var value = ReadValue(key, name.ToString());
            totalBytes = checked(totalBytes + value.Data.Length + value.Name.Length * 2L);
            if (totalBytes > MaximumSnapshotBytes / 2) throw new IOException("Registry snapshot payload limit exceeded.");
            node.Values.Add(value); totalValues++;
        }
        return node;
    }

    private static (string Class, uint Children, uint Values, long LastWrite) ReadKeyInformation(SafeRegistryHandle key)
    {
        // Win32内部のUNICODE_STRINGはbyte長がUSHORT。終端込み32768文字を渡すと長さがwrapする。
        // 小さく開始し、ERROR_MORE_DATAだけを上限付きで拡張して再読する。
        var capacity = 256;
        while (true)
        {
            var className = new StringBuilder(capacity);
            uint length = (uint)capacity;
            var error = RegQueryInfoKeyW(key, className, ref length, IntPtr.Zero, out var children, out _, out _, out var values, out _, out _, out _, out var lastWrite);
            if (error == 0)
            {
                if (length != className.Length) throw new IOException("Registry class contains an unsupported embedded NUL.");
                return (className.ToString(), children, values, lastWrite);
            }
            if (error != 234) Throw(error, "Cannot inspect registry key");
            if (capacity == 32767 || length >= 32767) throw new IOException("Registry key class exceeds the supported native string capacity.");
            capacity = Math.Min(32767, Math.Max(capacity * 2, checked((int)length + 1)));
        }
    }

    private static List<string> ChildNames(SafeRegistryHandle key)
    {
        var result = new List<string>();
        for (uint i = 0; ; i++)
        {
            var name = new StringBuilder(256); uint length = (uint)name.Capacity;
            var error = RegEnumKeyExW(key, i, name, ref length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (error == 259) return result;
            Check(error, "Cannot enumerate registry subkeys");
            if (length != name.Length) throw new IOException("Registry subkey name contains an unsupported embedded NUL.");
            var value = name.ToString(); ValidateText(value, 255, "Registry subkey name");
            if (value.Contains('\\') || result.Count >= MaximumKeys) throw new IOException("Registry subkey is unsupported or the key limit was exceeded.");
            result.Add(value);
        }
    }

    internal static RegistryValueSnapshot ReadValue(SafeRegistryHandle key, string name)
    {
        ValidateText(name, 16383, "Registry value name", allowEmpty: true);
        for (var attempt = 0; attempt < 4; attempt++)
        {
            uint size = 0;
            Check(RegQueryValueExW(key, name, IntPtr.Zero, out _, null, ref size), "Cannot read registry value size");
            if (size > MaximumSnapshotBytes / 2) throw new IOException("Registry value data limit exceeded.");
            var bytes = new byte[checked((int)size)];
            var error = RegQueryValueExW(key, name, IntPtr.Zero, out var type, bytes, ref size);
            if (error == 234) continue;
            Check(error, "Cannot read raw registry value");
            if (size != bytes.Length) Array.Resize(ref bytes, checked((int)size));
            return new RegistryValueSnapshot { Name = name, Type = type, Data = bytes };
        }
        throw new IOException("Registry value repeatedly changed during snapshot.");
    }

    internal static byte[] Security(SafeRegistryHandle key, bool full)
    {
        uint size = 0;
        var information = full ? FullSecurity : 1u | 2u | 4u;
        var error = RegGetKeySecurity(key, information, null, ref size);
        if (error is not (0 or 122)) Throw(error, "Cannot read registry security descriptor");
        if (size is 0 or > 1024 * 1024) throw new IOException("Registry security descriptor size is unsupported.");
        var descriptor = new byte[size];
        Check(RegGetKeySecurity(key, information, descriptor, ref size), "Cannot read complete registry security descriptor");
        if (size != descriptor.Length) Array.Resize(ref descriptor, checked((int)size));
        ValidateSecurity(descriptor);
        return descriptor;
    }

    internal static void ValidateSecurity(byte[] descriptor)
    {
        if (descriptor.Length is 0 or > 1024 * 1024 || !IsValidSecurityDescriptor(descriptor)) throw new InvalidDataException("Registry security descriptor is invalid.");
        var parsed = new RawSecurityDescriptor(descriptor, 0);
        if (parsed.Owner is null || parsed.Group is null || (parsed.ControlFlags & ControlFlags.SelfRelative) == 0)
            throw new InvalidDataException("Registry security descriptor is missing owner/group or self-relative format.");
    }

    // visibleな削除はcommitだけで行う。先に同じobjectへ削除をstageし、
    // その後nonTxの保持handleから元データを読み、snapshot後の外部変更をcommit競合にする。
    internal static RegistrySnapshot StageDeletionAndSnapshot(Transaction transaction, RegistryTarget target, bool recursive)
    {
        SafeRegistryHandle root;
        try { root = OpenPinnedOriginal(transaction, target, target.ValueName is null ? Delete : SetValue, target.ValueName is null); }
        catch (FileNotFoundException ex) { throw new RegistryTargetMissingException(ex.Message); }
        var snapshot = new RegistrySnapshot { Path = ActualTargetPath(root, target), View = target.View, ValueName = target.ValueName };
        if (target.ValueName is not null)
        {
            var key = BindTransaction(transaction, target, root, SetValue);
            var error = RegDeleteValueW(key, target.ValueName);
            if (error == 2) throw new RegistryTargetMissingException("Registry value is already absent.");
            Check(error, "Cannot stage registry value deletion");
            snapshot.ValueName = ActualValueName(root, target.ValueName);
            snapshot.Value = ReadValue(root, snapshot.ValueName);
            snapshot.ContextSecurity = Security(root, full: false);
            // OSが保存済みの型とraw bytesを再設定できることを、同じprivate transaction内だけで確認する。
            SetRaw(key, snapshot.Value);
            Check(RegDeleteValueW(key, snapshot.ValueName), "Cannot reinstate the staged registry value deletion after raw restoration preflight");
            return snapshot;
        }
        var originals = new List<(string Path, SafeRegistryHandle Key)>();
        var rootName = NtKeyName(root);
        Stage(root, "", 0);
        transaction.VerifyPinnedNames();
        var totalValues = 0;
        long totalBytes = 0;
        foreach (var original in originals)
            snapshot.Keys.Add(ReadNode(original.Key, original.Path, ref totalValues, ref totalBytes, out _));
        return snapshot;

        void Stage(SafeRegistryHandle original, string relative, int depth)
        {
            if (depth > MaximumDepth || originals.Count >= MaximumKeys) throw new IOException("Registry deletion key/depth limit exceeded.");
            var expectedName = rootName + (relative.Length == 0 ? "" : "\\" + relative);
            if (NtKeyName(original) != expectedName)
                throw new IOException("Registry key name changed between enumeration and staging; nothing was committed.");
            transaction.PinName(original, expectedName);
            var source = relative.Length == 0 ? target : new RegistryTarget(target.Path + "\\" + relative, target.Hive,
                target.Segments.Concat(relative.Split('\\')).ToArray(), target.View, null);
            transaction.PinNamespace(source, expectedName);
            originals.Add((relative, original));
            var children = ChildNames(original);
            if (children.Count > 0 && !recursive) throw new ArgumentException("Registry keys with subkeys require explicit recursive deletion.");
            foreach (var name in children)
            {
                var child = OpenChild(null, target, original, name, Delete, security: true);
                transaction.HeldKeys.Add(child);
                Stage(child, relative.Length == 0 ? name : relative + "\\" + name, depth + 1);
            }
            var key = BindTransaction(transaction, target, original, Delete);
            var status = NtDeleteKey(key);
            if (status < 0) Throw((int)RtlNtStatusToDosError(status), "Cannot stage deletion of the pinned registry key");
        }
    }

    private static SafeRegistryHandle OpenPinnedOriginal(Transaction transaction, RegistryTarget target, uint extraAccess, bool fullSecurity)
    {
        var root = target.Hive switch
        {
            "HKEY_LOCAL_MACHINE" => @"\Registry\Machine",
            "HKEY_USERS" => @"\Registry\User",
            _ => @"\Registry\User\" + CurrentSid
        };
        var traversal = Query | Enumerate | ReadControl | View(target);
        var current = OpenNative(null, null, root, traversal | (target.Segments.Length == 0 ? extraAccess | (fullSecurity ? SystemSecurity : 0) : 0));
        transaction.HeldKeys.Add(current); RejectLink(current);
        var parentName = NtKeyName(current);
        if (!parentName.Equals(root, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The registry hive anchor differs from its expected native path.");
        transaction.PinName(current, parentName);
        for (var i = 0; i < target.Segments.Length; i++)
        {
            var access = traversal | (i == target.Segments.Length - 1 ? extraAccess | (fullSecurity ? SystemSecurity : 0) : 0);
            current = OpenNative(null, current, target.Segments[i], access);
            transaction.HeldKeys.Add(current); RejectLink(current);
            var name = NtKeyName(current);
            transaction.PinName(current, name);
            parentName = name;
        }
        transaction.PinNamespace(target, parentName);
        return current;
    }

    private static SafeRegistryHandle BindTransaction(Transaction transaction, RegistryTarget target, SafeRegistryHandle original, uint extraAccess)
    {
        // 空の相対名は保持中の同じkey objectをtransactionへ結び、pathを再解決しない。
        var key = OpenNative(transaction, original, "", Query | Enumerate | ReadControl | extraAccess | View(target));
        transaction.HeldKeys.Add(key);
        return key;
    }

    private static string ActualTargetPath(SafeRegistryHandle key, RegistryTarget target)
    {
        var ntName = NtKeyName(key);
        var name = ntName[(ntName.LastIndexOf('\\') + 1)..];
        ValidateText(name, 255, "Registry key name");
        if (!name.Equals(target.Segments[^1], StringComparison.OrdinalIgnoreCase))
            throw new IOException("The pinned registry key name differs from the requested target.");
        return target.Path[..(target.Path.LastIndexOf('\\') + 1)] + name;
    }

    private static string NtKeyName(SafeRegistryHandle key)
    {
        var status = NtQueryKey(key, 3, null, 0, out var size);
        if (status >= 0 || (status != unchecked((int)0xc0000023) && status != unchecked((int)0x80000005)))
        {
            if (status < 0) Throw((int)RtlNtStatusToDosError(status), "Cannot query the pinned registry key name");
        }
        if (size is < 4 or > 131072) throw new IOException("Registry key name size is invalid.");
        var bytes = new byte[size];
        status = NtQueryKey(key, 3, bytes, size, out _);
        if (status < 0) Throw((int)RtlNtStatusToDosError(status), "Cannot query the pinned registry key name");
        var length = BitConverter.ToInt32(bytes, 0);
        if (length < 2 || length > bytes.Length - 4 || length % 2 != 0) throw new IOException("Registry key name is invalid.");
        var ntName = new UnicodeEncoding(false, false, true).GetString(bytes, 4, length);
        ValidateText(ntName, 65532, "Native registry key path");
        return ntName;
    }

    private static string ActualValueName(SafeRegistryHandle key, string requested)
    {
        for (uint index = 0; index < MaximumValues; index++)
        {
            var name = new StringBuilder(16384); uint length = (uint)name.Capacity;
            var error = RegEnumValueW(key, index, name, ref length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (error == 259) throw new FileNotFoundException("The registry value is absent.");
            Check(error, "Cannot enumerate the original registry value name");
            if (name.Length != length) throw new IOException("Registry value name contains an unsupported embedded NUL.");
            var actual = name.ToString(); ValidateText(actual, 16383, "Registry value name", allowEmpty: true);
            if (actual.Equals(requested, StringComparison.OrdinalIgnoreCase)) return actual;
        }
        throw new IOException("Registry value enumeration limit exceeded.");
    }

    internal static void Restore(Transaction transaction, RegistryTarget target, RegistrySnapshot snapshot)
    {
        if (target.ValueName is not null)
        {
            var original = OpenPinnedOriginal(transaction, target, SetValue, fullSecurity: false);
            var key = BindTransaction(transaction, target, original, SetValue);
            // first writeをstageしてから外部viewの不存在を調べる。先にqueryするだけでは同時作成を閉じられない。
            SetRaw(key, snapshot.Value!);
            uint size = 0;
            var error = RegQueryValueExW(original, target.ValueName, IntPtr.Zero, out _, null, ref size);
            if (error is 0 or 234) throw new RegistryConflictException("Registry value already exists; nothing was overwritten.");
            if (error != 2) Throw(error, "Cannot check registry value destination");
            var actual = ReadValue(key, target.ValueName);
            if (actual.Type != snapshot.Value!.Type || !actual.Data.AsSpan().SequenceEqual(snapshot.Value.Data))
                throw new IOException("Restored registry value verification failed.");
            return;
        }
        var parentSegments = target.Segments[..^1];
        var parentTarget = new RegistryTarget(target.Hive + (parentSegments.Length == 0 ? "" : "\\" + string.Join('\\', parentSegments)),
            target.Hive, parentSegments, target.View, null);
        var originalParent = OpenPinnedOriginal(transaction, parentTarget, CreateSubKey, fullSecurity: false);
        var parent = BindTransaction(transaction, parentTarget, originalParent, CreateSubKey);
        var keys = new Dictionary<string, SafeRegistryHandle>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var node in snapshot.Keys)
            {
                var split = node.RelativePath.LastIndexOf('\\');
                var container = node.RelativePath.Length == 0 ? parent : keys[split < 0 ? "" : node.RelativePath[..split]];
                var name = node.RelativePath.Length == 0 ? target.Segments[^1] : node.RelativePath[(split + 1)..];
                var descriptor = Marshal.AllocHGlobal(node.Security.Length);
                try
                {
                    Marshal.Copy(node.Security, 0, descriptor, node.Security.Length);
                    var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), SecurityDescriptor = descriptor };
                    var error = RegCreateKeyTransactedW(container, name, 0, node.Class, 0,
                        Query | SetValue | CreateSubKey | Enumerate | ReadControl | 0x00040000 | SystemSecurity | View(target), ref attributes,
                        out var key, out var disposition, transaction.Handle, IntPtr.Zero);
                    if (error != 0) { key?.Dispose(); Throw(error, "Cannot create restored registry key with its original security"); }
                    if (disposition != 1) { key.Dispose(); throw new RegistryConflictException("Registry key already exists; nothing was overwritten."); }
                    keys.Add(node.RelativePath, key);
                    foreach (var value in node.Values) SetRaw(key, value);
                }
                finally { Marshal.FreeHGlobal(descriptor); }
            }
            // 親のAIを先に戻すと、後続の子作成時にSACL不在のAIが失われるため、全キー作成後に適用する。
            foreach (var node in snapshot.Keys) RestoreAclControl(keys[node.RelativePath], node.Security);
            // 作成時のACLを含め、復元した全内容を同じtransactionで再読してからcommitする。
            var actual = Snapshot(transaction, target, recursive: true);
            var difference = Difference(snapshot, actual);
            if (difference is not null) throw new IOException($"Restored registry key verification failed ({difference}); the transaction was rolled back.");
        }
        finally { foreach (var key in keys.Values) key.Dispose(); }
    }

    private static void SetRaw(SafeRegistryHandle key, RegistryValueSnapshot value) =>
        Check(RegSetValueExW(key, value.Name, 0, value.Type, value.Data, (uint)value.Data.Length), "Cannot restore raw registry value");

    private static void RestoreAclControl(SafeRegistryHandle key, byte[] original)
    {
        var security = new RawSecurityDescriptor(original, 0);
        var flags = security.ControlFlags;
        uint information = 0;
        if ((flags & ControlFlags.DiscretionaryAclPresent) != 0)
        {
            information |= 4;
            if ((flags & ControlFlags.DiscretionaryAclAutoInherited) != 0) flags |= ControlFlags.DiscretionaryAclAutoInheritRequired;
        }
        if ((flags & ControlFlags.SystemAclPresent) != 0)
        {
            information |= 8;
            if ((flags & ControlFlags.SystemAclAutoInherited) != 0) flags |= ControlFlags.SystemAclAutoInheritRequired;
        }
        if (information == 0) return;
        // createで失われるAIを、元AIがあるACLだけREQとして再適用する。
        // SetSecurityInfoの子伝播を使わず、同じprivate keyのACE・owner/groupを保持する。
        security.SetFlags(flags);
        var descriptor = new byte[security.BinaryLength]; security.GetBinaryForm(descriptor, 0);
        Check(RegSetKeySecurity(key, information, descriptor), "Cannot restore exact registry ACL control flags");
    }

    internal static string? Difference(RegistrySnapshot expected, RegistrySnapshot actual)
    {
        if (expected.Keys.Count != actual.Keys.Count) return "key count";
        var nodes = actual.Keys.ToDictionary(node => node.RelativePath, StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < expected.Keys.Count; index++)
        {
            var node = expected.Keys[index];
            var position = index == 0 ? "root" : $"child #{index}";
            if (!nodes.TryGetValue(node.RelativePath, out var other) || node.RelativePath != other.RelativePath) return position + " key name";
            if (node.Class != other.Class) return position + " class";
            if (!node.Security.AsSpan().SequenceEqual(other.Security)) return position + " " + SecurityDifference(node.Security, other.Security);
            if (node.Values.Count != other.Values.Count) return position + " value count";
            var values = other.Values.ToDictionary(value => value.Name, StringComparer.OrdinalIgnoreCase);
            foreach (var value in node.Values)
            {
                if (!values.TryGetValue(value.Name, out var found) || value.Name != found.Name) return position + " value name";
                if (value.Type != found.Type) return position + " raw value type";
                if (!value.Data.AsSpan().SequenceEqual(found.Data)) return position + " raw value bytes";
            }
        }
        return null;
    }

    private static string SecurityDifference(byte[] expected, byte[] actual)
    {
        var left = new RawSecurityDescriptor(expected, 0);
        var right = new RawSecurityDescriptor(actual, 0);
        if (left.Owner != right.Owner) return "security owner";
        if (left.Group != right.Group) return "security group";
        if (left.ControlFlags != right.ControlFlags) return $"security control flags ({(int)left.ControlFlags:X4}/{(int)right.ControlFlags:X4})";
        if (!SameAcl(left.DiscretionaryAcl, right.DiscretionaryAcl)) return "security DACL";
        if (!SameAcl(left.SystemAcl, right.SystemAcl)) return "security SACL";
        return "security binary layout";
        static bool SameAcl(RawAcl? first, RawAcl? second)
        {
            if (first is null || second is null) return first is null && second is null;
            var a = new byte[first.BinaryLength]; var b = new byte[second.BinaryLength];
            first.GetBinaryForm(a, 0); second.GetBinaryForm(b, 0);
            return a.AsSpan().SequenceEqual(b);
        }
    }

    internal static void Check(int error, string message) { if (error != 0) Throw(error, message); }
    [System.Diagnostics.CodeAnalysis.DoesNotReturn]
    private static void Throw(int error, string message)
    {
        var inner = new Win32Exception(error);
        var description = $"{message} (Win32 {error}): {inner.Message}";
        if (error == 6801)
            description += " The registry transaction resource manager is unavailable in this context. MSIX or other virtualized registry views can cause this; 6801 alone does not establish hive corruption. Another launch context may resolve the same path to a different key or no key; absence is not proof of successful cleanup. Prunlet does not fall back to nontransactional deletion.";
        if (error is 2 or 3) throw new FileNotFoundException(description, inner);
        if (error is 5 or 1314) throw new UnauthorizedAccessException(description, inner);
        throw new IOException(description, inner);
    }

    [StructLayout(LayoutKind.Sequential)] private struct UnicodeString { internal ushort Length, MaximumLength; internal IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct ObjectAttributes { internal int Length; internal IntPtr RootDirectory, ObjectName; internal uint Attributes; internal IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { internal int Length; internal IntPtr SecurityDescriptor; internal int InheritHandle; }
    [StructLayout(LayoutKind.Sequential)] private struct Luid { internal uint Low; internal int High; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { internal uint Count; internal Luid Luid; internal uint Attributes; }
    [DllImport("ntdll.dll")] private static extern int NtOpenKeyTransactedEx(out SafeRegistryHandle key, uint access, ref ObjectAttributes attributes, uint options, SafeFileHandle transaction);
    [DllImport("ntdll.dll")] private static extern int NtOpenKeyEx(out SafeRegistryHandle key, uint access, ref ObjectAttributes attributes, uint options);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
    [DllImport("KtmW32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateTransaction(IntPtr attributes, IntPtr uow, uint options, uint isolationLevel, uint isolationFlags, uint timeout, string description);
    [DllImport("KtmW32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CommitTransaction(SafeFileHandle transaction);
    [DllImport("KtmW32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RollbackTransaction(SafeFileHandle transaction);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentThread();
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenThreadToken(IntPtr thread, uint access, bool openAsSelf, out SafeFileHandle token);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(IntPtr process, uint access, out SafeFileHandle token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool LookupPrivilegeValueW(string? system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AdjustTokenPrivileges(SafeFileHandle token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges state, uint length, out TokenPrivileges previous, out uint returned);
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RestoreTokenPrivileges(SafeFileHandle token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returned);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegQueryValueExW(SafeRegistryHandle key, string value, IntPtr reserved, out uint type, byte[]? data, ref uint length);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegEnumValueW(SafeRegistryHandle key, uint index, StringBuilder name, ref uint length, IntPtr reserved, IntPtr type, IntPtr data, IntPtr dataLength);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegEnumKeyExW(SafeRegistryHandle key, uint index, StringBuilder name, ref uint length, IntPtr reserved, IntPtr className, IntPtr classLength, IntPtr lastWrite);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegQueryInfoKeyW(SafeRegistryHandle key, StringBuilder className, ref uint classLength, IntPtr reserved, out uint subkeys, out uint maxSubkey, out uint maxClass, out uint values, out uint maxValueName, out uint maxValueData, out uint securityLength, out long lastWrite);
    [DllImport("advapi32.dll")] private static extern int RegGetKeySecurity(SafeRegistryHandle key, uint information, byte[]? descriptor, ref uint length);
    [DllImport("advapi32.dll")] private static extern int RegSetKeySecurity(SafeRegistryHandle key, uint information, byte[] descriptor);
    [DllImport("advapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsValidSecurityDescriptor(byte[] descriptor);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegDeleteValueW(SafeRegistryHandle key, string name);
    [DllImport("ntdll.dll")] private static extern int NtDeleteKey(SafeRegistryHandle key);
    [DllImport("ntdll.dll")] private static extern int NtQueryKey(SafeRegistryHandle key, int informationClass, byte[]? buffer, uint length, out uint required);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegSetValueExW(SafeRegistryHandle key, string name, uint reserved, uint type, byte[] data, uint length);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegCreateKeyTransactedW(SafeRegistryHandle key, string subkey, uint reserved, string className, uint options, uint access, ref SecurityAttributes attributes, out SafeRegistryHandle created, out uint disposition, SafeFileHandle transaction, IntPtr extended);
}

internal sealed class RegistryConflictException(string message) : IOException(message);
internal sealed class RegistryTargetMissingException(string message) : IOException(message);
