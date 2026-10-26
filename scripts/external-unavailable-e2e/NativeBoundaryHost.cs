using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

// 失敗条件: 実production関数を使わない検査、pin中rename成功、release後もrename不能、
// 非空containerの再帰削除、子data変更、通知未配送の成功扱い、取消後の未drain解放、
// assembly/source不一致とcase欠落を検出する。Windows権限・OS境界の直接確認でありunitではない。
internal static class NativeBoundaryHost
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    static Type native = null!, store = null!, watchType = null!;
    static string root = "";
    static readonly List<object> results = [];
    static Dictionary<string, object?> observed = [];
    const BindingFlags Static = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static readonly string[] Cases = [
        "path-pin-file", "path-pin-directory", "path-pin-child",
        "by-id-lookup-file", "by-id-lookup-directory", "by-id-lookup-child",
        "c4-delete-handle-blocks-same-name-replacement", "c4-nonempty-nonrecursive-delete-preserves-child", "c4-empty-nonrecursive-delete-succeeds",
        "watch-unchanged-pending", "watch-deep-child-add", "watch-deep-child-rename", "watch-parent-pin-child-add",
        "watch-cancel-pending-drains", "watch-completed-dispose-drains", "watch-cancel-completion-race",
        "watch-burst-remains-invalid", "watch-directory-rename-pin",
        "by-id-path-lease-file", "by-id-path-lease-directory", "by-id-path-lease-child",
        "hardlink-all-alias-leases-same-parent", "hardlink-all-alias-leases-distinct-parents",
        "id-path-lease-wrong-identity-rejected", "id-path-lease-wrong-volume-rejected",
        "alias-path-invalid-suffixes-rejected", "id-path-lease-reparse-ancestor-rejected", "id-path-lease-ancestor-swap-refused",
        "id-path-lease-junction-leaf-preserves-target"
    ];
    [DllImport("ntdll.dll")]
    static extern int NtQueryObject(SafeFileHandle handle, int informationClass, byte[] information, uint length, out uint needed);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLinkW(string link, string target, IntPtr security);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputLength, IntPtr output, uint outputLength, out uint returned, IntPtr overlapped);
    [StructLayout(LayoutKind.Sequential)]
    struct PublicObjectBasicInformation
    {
        public uint Attributes, GrantedAccess, HandleCount, PointerCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)] public uint[] Reserved;
    }

    static void Assert(bool condition, string message) { if (!condition) throw new IOException(message); }
    static MethodInfo Method(Type type, string name, params Type[] parameters) => type.GetMethod(name, Static, parameters) ?? throw new MissingMethodException(type.FullName, name);
    static object? Invoke(MethodInfo method, object? target, params object?[] args)
    {
        try { return method.Invoke(target, args); }
        catch (TargetInvocationException ex) when (ex.InnerException is not null) { ExceptionDispatchInfo.Capture(ex.InnerException).Throw(); throw; }
    }
    static object? Call(string name, Type[] signature, params object?[] args) => Invoke(Method(native, name, signature), null, args);
    static SafeFileHandle OpenPin(string path) => (SafeFileHandle)Call("OpenExternalPin", [typeof(string)], path)!;
    static object Identity(SafeFileHandle handle) => Call("MoveIdentity", [typeof(SafeFileHandle)], handle)!;
    static string LegacyIdentity(SafeFileHandle handle) => (string)Call("Identity", [typeof(SafeFileHandle)], handle)!;
    static object IdentityAt(string path) { using var pin = OpenPin(path); return Identity(pin); }
    static string Sha(string path) { using var stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)); }
    static string TextSha(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    static string Serialize(object? value) => JsonSerializer.Serialize(value, Json);
    static uint GrantedAccess(SafeFileHandle handle)
    {
        var bytes = new byte[Marshal.SizeOf<PublicObjectBasicInformation>()]; int status = NtQueryObject(handle, 0, bytes, (uint)bytes.Length, out uint needed);
        Assert(status >= 0, "Cannot inspect actual OS granted access: NTSTATUS " + status + ", required bytes " + needed + ", supplied bytes " + bytes.Length); return BitConverter.ToUInt32(bytes, 4);
    }
    static object Proof(string path)
    {
        using var handle = OpenPin(path);
        return Proof(handle, path);
    }
    static object Proof(SafeFileHandle handle, string path)
    {
        return new { identity = Identity(handle), legacyIdentity = LegacyIdentity(handle), securityBase64 = Convert.ToBase64String((byte[])Call("ReadRecycleSecurity", [typeof(SafeFileHandle)], handle)!),
            bytesSha256 = File.Exists(path) ? Sha(path) : null, fileLength = File.Exists(path) ? new FileInfo(path).Length : (long?)null };
    }
    static void Same(string path, object expected) => Assert(Serialize(Proof(path)) == Serialize(expected), "Owned fixture ID/data/OGD/attributes changed: " + path);
    static string Scope(string name)
    {
        string path = Path.Combine(root, name); Assert(!Directory.Exists(path) && !File.Exists(path), "Fresh case scope required."); Directory.CreateDirectory(path); return path;
    }
    static string NewFile(string directory, string name = "source.txt")
    {
        string path = Path.Combine(directory, name); File.WriteAllText(path, "native-boundary-owned-data:" + name); return path;
    }
    static int? Win32(Exception ex)
    {
        for (Exception? current = ex; current is not null; current = current.InnerException) if (current is Win32Exception win) return win.NativeErrorCode;
        return (ex.HResult & unchecked((int)0xffff0000)) == unchecked((int)0x80070000) ? ex.HResult & 0xffff : null;
    }
    static void Move(string source, string destination)
    {
        Assert(!File.Exists(destination) && !Directory.Exists(destination), "Rename destination must be unused.");
        if (Directory.Exists(source)) Directory.Move(source, destination); else File.Move(source, destination, false);
    }
    static void RequireRenameDenied(string source, string destination)
    {
        Exception? failure = null; bool moved = false;
        try { Move(source, destination); moved = true; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { failure = ex; }
        if (moved) Move(destination, source);
        observed["renameAttempt"] = new { source, destination, moveSucceeded = moved, error = failure?.ToString(), nativeError = failure is null ? null : Win32(failure) };
        Assert(!moved && failure is not null && Win32(failure) is 5 or 32, "Actual production pin did not refuse rename with an OS access/sharing failure.");
    }
    static SafeFileHandle ById(string hintPath, object expected)
    {
        using var hint = OpenPin(hintPath); object?[] args = [hint, expected, 0];
        var method = Method(native, "TryOpenExternalId", typeof(SafeFileHandle), expected.GetType(), typeof(int).MakeByRefType());
        var handle = (SafeFileHandle?)Invoke(method, null, args);
        observed["byId"] = new { error = args[2], hintIdentity = Identity(hint), expected };
        Assert(handle is not null && !handle.IsInvalid && (int)args[2]! == 0, "A live fixture ID was not opened by the actual production lookup.");
        return handle!;
    }
    static string GuidRoot(SafeFileHandle handle)
    {
        string path = (string)Call("ExternalFinalPath", [typeof(SafeFileHandle), typeof(bool)], handle, true)!;
        int end = path.IndexOf('}'); Assert(path.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase) && end > 0 && path.Length > end + 1 && path[end + 1] == '\\', "Lookup did not return a canonical volume GUID path.");
        _ = Guid.Parse(path.Substring(11, end - 11)); return path[..(end + 2)];
    }
    static object OpenIdLease(SafeFileHandle lookup, object expected, string volume) => Call("PinExternalIdLocation", [typeof(SafeFileHandle), expected.GetType(), typeof(string)], lookup, expected, volume)!;
    static SafeFileHandle Leaf(object lease) => (SafeFileHandle)(lease.GetType().GetProperty("Leaf", Instance)?.GetValue(lease) ?? throw new MissingMemberException("Production ID path lease has no Leaf."));
    static void VerifyLease(object lease) => Invoke(lease.GetType().GetMethod("VerifyUnchanged", Instance) ?? throw new MissingMethodException("Production ID path lease verification is absent."), lease);
    static string LeasePath(object lease) => (string)(lease.GetType().GetProperty("GuidPath", Instance)?.GetValue(lease) ?? throw new MissingMemberException("Production ID path lease GUID path absent."));
    static string[] LeaseAliases(object lease) => ((IEnumerable<string>)(lease.GetType().GetProperty("Aliases", Instance)?.GetValue(lease) ?? throw new MissingMemberException("Production ID path lease alias inventory absent."))).ToArray();
    static void ObserveLookupRename(string source, string destination, SafeFileHandle lookup)
    {
        string before = (string)Call("ExternalFinalPath", [typeof(SafeFileHandle), typeof(bool)], lookup, false)!;
        Exception? failure = null; bool moved = false; string? during = null;
        try { Move(source, destination); moved = true; during = (string)Call("ExternalFinalPath", [typeof(SafeFileHandle), typeof(bool)], lookup, false)!; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { failure = ex; }
        finally { if (moved) Move(destination, source); }
        observed["rawLookupRenameObservation"] = new { moveSucceeded = moved, error = failure?.ToString(), nativeError = failure is null ? null : Win32(failure), before, during, after = Call("ExternalFinalPath", [typeof(SafeFileHandle), typeof(bool)], lookup, false), guarantee = "identity/location lookup only; name locking is tested separately through the path lease" };
        Assert(failure is null || Win32(failure) is 5 or 32, "Raw lookup rename observation failed for an unrelated OS reason.");
    }
    static void PinCase(string name, string acquisition, string kind)
    {
        string scope = Scope(name); string parent = Path.Combine(scope, "parent"); Directory.CreateDirectory(parent);
        string hint = NewFile(scope, "volume-hint.txt"); string source;
        if (kind == "directory") { source = Path.Combine(parent, "source-dir"); Directory.CreateDirectory(source); NewFile(source); }
        else if (kind == "child") { string deep = Path.Combine(parent, "deep"); Directory.CreateDirectory(deep); source = NewFile(deep); }
        else source = NewFile(parent);
        string destination = source + ".retained"; var proof = Proof(source); var expected = IdentityAt(source);
        observed["originalProof"] = new { path = source, proof };
        string? data = kind == "directory" ? Path.Combine(source, "source.txt") : null; object? childProof = data is null ? null : Proof(data);
        SafeFileHandle? lookup = null, direct = null; object? lease = null;
        try
        {
            SafeFileHandle pin;
            if (acquisition == "path") pin = direct = OpenPin(source);
            else
            {
                lookup = ById(hint, expected);
                if (acquisition == "lease") { lease = OpenIdLease(lookup, expected, GuidRoot(lookup)); pin = Leaf(lease); VerifyLease(lease); observed["leaseGuidPath"] = LeasePath(lease); }
                else pin = lookup;
            }
            uint grantedAccess = GrantedAccess(pin);
            observed["productionHandle"] = new { acquisition, grantedAccess, readDataOrListDirectoryGranted = (grantedAccess & 1) != 0, identity = Identity(pin), legacyIdentity = LegacyIdentity(pin) };
            Assert((grantedAccess & 1) != 0, "Actual pin handle lacks mapped FILE_READ_DATA/LIST_DIRECTORY rights.");
            // 親pinを重ねてByID/child自身の共有不備を隠さない。
            try { if (acquisition == "lookup") ObserveLookupRename(source, destination, lookup!); else RequireRenameDenied(source, destination); }
            finally
            {
                var afterAttempt = Proof(pin, source); observed["afterAttemptProof"] = afterAttempt; Assert(Serialize(afterAttempt) == Serialize(proof), "Rename attempt changed original ID/data/OGD/attributes.");
                if (data is not null) { var childAfter = Proof(data); observed["directoryChildProof"] = new { before = childProof, after = childAfter }; Assert(Serialize(childAfter) == Serialize(childProof), "Directory rename attempt changed its child's ID/data/OGD/attributes."); }
            }
            Same(source, proof); if (data is not null) Same(data, childProof!);
            if (lease is not null) VerifyLease(lease);
        }
        finally { (lease as IDisposable)?.Dispose(); direct?.Dispose(); lookup?.Dispose(); }
        Move(source, destination); Same(destination, proof); if (data is not null) Same(Path.Combine(destination, "source.txt"), childProof!);
        observed["releasedRename"] = new { succeeded = true, retainedPath = destination, proof };
    }
    static void AliasLeaseCase(string name, bool distinctParents)
    {
        string scope = Scope(name); string firstParent = Path.Combine(scope, "first"); Directory.CreateDirectory(firstParent);
        string secondParent = distinctParents ? Path.Combine(scope, "second") : firstParent; Directory.CreateDirectory(secondParent);
        string first = NewFile(firstParent, "first-name.txt"); string second = Path.Combine(secondParent, "second-name.txt");
        if (!CreateHardLinkW(second, first, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create owned hardlink fixture.");
        object proof = Proof(first); Same(second, proof); object expected = IdentityAt(first); string hint = NewFile(scope, "hint.txt");
        observed["aliasOriginalProof"] = new { first, second, proof };
        var attempts = new List<object?>();
        using (var lookup = ById(hint, expected))
        {
            var beforeNames = ((IEnumerable<string>)Call("ExternalFileNames", [typeof(SafeFileHandle)], lookup)!).ToArray();
            Assert(beforeNames.Length == 2 && beforeNames.Distinct(StringComparer.Ordinal).Count() == 2, "Owned fixture did not produce exactly two live NTFS aliases.");
            object lease = OpenIdLease(lookup, expected, GuidRoot(lookup));
            try
            {
                var pinnedNames = LeaseAliases(lease);
                Assert(pinnedNames.Order(StringComparer.Ordinal).SequenceEqual(beforeNames.Order(StringComparer.Ordinal), StringComparer.Ordinal), "Production path lease did not retain every actual hardlink name.");
                observed["aliasLease"] = new { guidPath = LeasePath(lease), beforeNames, pinnedNames, leafIdentity = Identity(Leaf(lease)), distinctParents };
                foreach (string path in new[] { first, second })
                {
                    RequireRenameDenied(path, path + ".retained"); attempts.Add(observed["renameAttempt"]); Same(path, proof); VerifyLease(lease);
                }
                observed["allAliasRenameAttempts"] = attempts;
            }
            finally { ((IDisposable)lease).Dispose(); }
        }
        Move(first, first + ".retained"); Move(second, second + ".retained"); Same(first + ".retained", proof); Same(second + ".retained", proof);
        observed["releasedAliases"] = new[] { first + ".retained", second + ".retained" };
        observed["releasedAliasProofs"] = new[] { new { path = first + ".retained", proof = Proof(first + ".retained") }, new { path = second + ".retained", proof = Proof(second + ".retained") } };
    }
    static void RequireLeaseFailure(string source, SafeFileHandle lookup, object expected, string volume)
    {
        object proof = Proof(source); object? unexpected = null; Exception? failure = null;
        try { unexpected = OpenIdLease(lookup, expected, volume); }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException) { failure = ex; }
        finally { (unexpected as IDisposable)?.Dispose(); }
        observed["rejectedLease"] = new { expected, volume, error = failure?.ToString(), unexpectedLeaseCreated = unexpected is not null };
        Assert(unexpected is null && failure is not null, "Production path lease accepted a mismatched or unsafe binding."); Same(source, proof);
    }
    static void WrongLeaseCase(string name, bool wrongIdentity)
    {
        string scope = Scope(name); string source = NewFile(scope); string other = NewFile(scope, "other.txt"); string hint = NewFile(scope, "hint.txt");
        object expected = IdentityAt(source), otherIdentity = IdentityAt(other); object original = Proof(source), otherProof = Proof(other);
        using (var lookup = ById(hint, expected))
        {
            string volume = GuidRoot(lookup);
            if (wrongIdentity) RequireLeaseFailure(source, lookup, otherIdentity, volume);
            else
            {
                char replacement = volume[11] == '0' ? '1' : '0'; string wrongVolume = volume[..11] + replacement + volume[12..];
                RequireLeaseFailure(source, lookup, expected, wrongVolume);
            }
        }
        Move(source, source + ".retained"); Same(source + ".retained", original); Same(other, otherProof);
        observed["failureReleasedAllPins"] = true;
    }
    static void AliasLexicalCase()
    {
        string scope = Scope(Cases[25]); string volumeRoot = Path.GetPathRoot(scope)!;
        string[] invalid = ["", "plain.txt", @"\\server\share", @"\..\outside", @"\dir\..\outside", @"\file:ads", @"\dir\\file", @"\trailing\", "\\trailing ", "\\trailing."];
        var failures = new List<object>(); observed["invalidSuffixes"] = failures;
        foreach (string suffix in invalid)
        {
            Exception? failure = null; object? result = null;
            try { result = Call("ExternalAliasPath", [typeof(string), typeof(string)], volumeRoot, suffix); }
            catch (Exception ex) when (ex is IOException or ArgumentException) { failure = ex; }
            failures.Add(new { suffix, result, error = failure?.ToString() });
            Assert(failure is not null && result is null, "Production alias suffix validator accepted an unsafe or noncanonical relative name.");
        }
        observed["invalidSuffixes"] = failures;
        string valid = @"\owned\ordinary.txt"; string actual = (string)Call("ExternalAliasPath", [typeof(string), typeof(string)], volumeRoot, valid)!;
        Assert(actual == Path.Combine(volumeRoot, @"owned\ordinary.txt"), "Production alias path validator changed an ordinary volume-relative name."); observed["validSuffix"] = actual;
    }
    static void CreateOwnedJunction(string path, string target)
    {
        Directory.CreateDirectory(path); string substitute = @"\??\" + Path.GetFullPath(target); byte[] sub = Encoding.Unicode.GetBytes(substitute), print = Encoding.Unicode.GetBytes(target);
        int dataLength = 8 + sub.Length + 2 + print.Length + 2; var bytes = new byte[8 + dataLength];
        BitConverter.GetBytes(0xa0000003u).CopyTo(bytes, 0); BitConverter.GetBytes(checked((ushort)dataLength)).CopyTo(bytes, 4);
        BitConverter.GetBytes(checked((ushort)sub.Length)).CopyTo(bytes, 10); BitConverter.GetBytes(checked((ushort)(sub.Length + 2))).CopyTo(bytes, 12); BitConverter.GetBytes(checked((ushort)print.Length)).CopyTo(bytes, 14);
        sub.CopyTo(bytes, 16); print.CopyTo(bytes, 16 + sub.Length + 2);
        using var handle = CreateFileW(path, 0x40000000, 0, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero); if (handle.IsInvalid) throw new Win32Exception();
        if (!DeviceIoControl(handle, 0x900a4, bytes, (uint)bytes.Length, IntPtr.Zero, 0, out _, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create owned junction fixture.");
    }
    static void ReparseLeaseCase()
    {
        string scope = Scope(Cases[26]); string target = Path.Combine(scope, "target"); Directory.CreateDirectory(target); string targetFile = NewFile(target); object targetProof = Proof(targetFile);
        string link = Path.Combine(scope, "owned-junction"); CreateOwnedJunction(link, target); object linkIdentity = IdentityAt(link), expected = IdentityAt(targetFile); string hint = NewFile(scope, "hint.txt");
        Assert((uint)linkIdentity.GetType().GetProperty("ReparseTag")!.GetValue(linkIdentity)! != 0, "Owned reparse fixture is not a real junction.");
        using (var lookup = ById(hint, expected))
        {
            object lease = OpenIdLease(lookup, expected, GuidRoot(lookup));
            try
            {
                Exception? failure = null; object? result = null; string aliasThroughReparse = Path.Combine(link, "source.txt");
                try { result = Invoke(lease.GetType().GetMethod("PinName", Instance) ?? throw new MissingMethodException(), lease, aliasThroughReparse); }
                catch (Exception ex) when (ex is IOException or ArgumentException) { failure = ex; }
                observed["reparseAncestorAttempt"] = new { actualProductionMethod = "ExternalIdPathPin.PinName", aliasThroughReparse, error = failure?.ToString(), pinReturned = result is not null, linkIdentity };
                Assert(failure is not null && result is null, "Production alias name pin followed an actual junction ancestor."); VerifyLease(lease);
            }
            finally { ((IDisposable)lease).Dispose(); }
        }
        Same(targetFile, targetProof); observed["retainedJunction"] = new { link, linkIdentity, target, targetProof };
    }
    static void JunctionLeafCase()
    {
        string scope = Scope(Cases[28]); string target = Path.Combine(scope, "target"); Directory.CreateDirectory(target); string targetFile = NewFile(target);
        object targetProof = Proof(targetFile), targetDirectoryProof = Proof(target); string link = Path.Combine(scope, "owned-junction"); CreateOwnedJunction(link, target);
        object expected = IdentityAt(link), linkProof = Proof(link); string hint = NewFile(scope, "hint.txt");
        using (var lookup = ById(hint, expected))
        {
            object lease = OpenIdLease(lookup, expected, GuidRoot(lookup));
            try
            {
                Assert(Serialize(Identity(Leaf(lease))) == Serialize(expected) && LeaseAliases(lease).Length == 1, "Known junction leaf adopted its target or non-self alias identity.");
                observed["junctionLeafLease"] = new { identity = Identity(Leaf(lease)), guidPath = LeasePath(lease), aliases = LeaseAliases(lease), target, targetProof, targetDirectoryProof };
                RequireRenameDenied(link, link + ".retained"); VerifyLease(lease); Same(targetFile, targetProof); Same(target, targetDirectoryProof);
            }
            finally { ((IDisposable)lease).Dispose(); }
        }
        Move(link, link + ".retained"); Same(link + ".retained", linkProof); Same(targetFile, targetProof); Same(target, targetDirectoryProof);
    }
    static void AncestorLeaseCase()
    {
        string scope = Scope(Cases[27]); string parent = Path.Combine(scope, "ancestor"); Directory.CreateDirectory(parent); string source = NewFile(parent); string hint = NewFile(scope, "hint.txt");
        object original = Proof(source), parentProof = Proof(parent), expected = IdentityAt(source);
        observed["ancestorOriginalProof"] = new { source, original, parent, parentProof };
        using (var lookup = ById(hint, expected))
        {
            object lease = OpenIdLease(lookup, expected, GuidRoot(lookup));
            try { RequireRenameDenied(parent, parent + ".retained"); VerifyLease(lease); Same(source, original); Same(parent, parentProof); }
            finally { ((IDisposable)lease).Dispose(); }
        }
        Move(parent, parent + ".retained"); Same(parent + ".retained", parentProof); Same(Path.Combine(parent + ".retained", "source.txt"), original); observed["releasedAncestorRename"] = new { succeeded = true, parentProof = Proof(parent + ".retained"), childProof = Proof(Path.Combine(parent + ".retained", "source.txt")) };
    }
    static string PrivateContainer(string scope)
    {
        string path = Path.Combine(scope, "empty-container"); var created = Invoke(Method(store, "CreateSecureDirectory", typeof(string), typeof(bool)), null, path, false);
        Assert(created is true, "Production private container fixture was not freshly created."); return path;
    }
    static SafeFileHandle OpenContainer(string path, object expected)
    {
        var handle = (SafeFileHandle)Invoke(Method(store, "OpenExternalEmptyOperation", typeof(string), expected.GetType()), null, path, expected)!;
        uint grantedAccess = GrantedAccess(handle);
        observed["containerHandle"] = new { grantedAccess, readDataOrListDirectoryGranted = (grantedAccess & 1) != 0, deleteGranted = (grantedAccess & 0x10000) != 0, identity = Identity(handle), expected };
        Assert((grantedAccess & 0x10001) == 0x10001, "Actual empty-container handle lacks mapped DELETE/LIST_DIRECTORY rights.");
        return handle;
    }
    static void SetDelete(SafeFileHandle handle) => Call("SetOriginalDeletePending", [typeof(SafeFileHandle), typeof(bool)], handle, true);
    static void ContainerRename()
    {
        string scope = Scope(Cases[6]); string source = PrivateContainer(scope); var expected = IdentityAt(source); var proof = Proof(source);
        using (var handle = OpenContainer(source, expected))
        {
            RequireRenameDenied(source, source + ".retained");
            // DELETE holderと新NoDelete readerは互換でない。既に保持する同じhandleで証拠を読む。
            Assert(Serialize(Proof(handle, source)) == Serialize(proof) && Directory.Exists(source), "Held C4 container evidence changed.");
        }
        Move(source, source + ".retained"); Same(source + ".retained", proof); observed["releasedRename"] = new { succeeded = true, retainedPath = source + ".retained" };
    }
    static void ContainerNonempty()
    {
        string scope = Scope(Cases[7]); string path = PrivateContainer(scope); var expected = IdentityAt(path); string child;
        object childProof; Exception? failure = null;
        using (var handle = OpenContainer(path, expected))
        {
            child = NewFile(path); childProof = Proof(child);
            try { SetDelete(handle); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { failure = ex; }
            observed["nonrecursiveDelete"] = new { error = failure?.ToString(), nativeError = failure is null ? null : Win32(failure) };
            Assert(failure is not null && Win32(failure) == 145, "A nonempty private container did not refuse nonrecursive deletion with ERROR_DIR_NOT_EMPTY.");
            Same(child, childProof);
        }
        Assert(Serialize(IdentityAt(path)) == Serialize(expected), "Nonrecursive refusal lost the original private container identity."); Same(child, childProof);
        observed["retainedChild"] = new { path = child, proof = childProof };
    }
    static void ContainerEmpty()
    {
        string scope = Scope(Cases[8]); string path = PrivateContainer(scope); var expected = IdentityAt(path);
        using (var handle = OpenContainer(path, expected)) SetDelete(handle);
        Exception? failure = null; try { using var unexpected = OpenPin(path); } catch (Exception ex) { failure = ex; }
        observed["strictAbsence"] = new { error = failure?.ToString(), nativeError = failure is null ? null : Win32(failure) };
        Assert(failure is not null && Win32(failure) is 2 or 3 && !Directory.Exists(path), "Closed own DELETE handle did not produce strict missing-path evidence.");
    }
    static object Watch(string path)
    {
        try { return Activator.CreateInstance(watchType, Instance, null, [path], null) ?? throw new IOException("Production watch ctor returned null."); }
        catch (TargetInvocationException ex) when (ex.InnerException is not null) { ExceptionDispatchInfo.Capture(ex.InnerException).Throw(); throw; }
    }
    static void VerifyWatch(object watch) => Invoke(watchType.GetMethod("VerifyUnchanged", Instance) ?? throw new MissingMethodException(), watch);
    static bool Invalidated(object watch) => (bool)(watchType.GetProperty("Invalidated", Instance)?.GetValue(watch) ?? throw new MissingMemberException());
    static object? Field(object watch, string name) => watchType.GetField(name, Instance)?.GetValue(watch);
    static void DisposeWatch(object watch)
    {
        var dir = Field(watch, "directory") as SafeFileHandle; var completion = Field(watch, "completion") as SafeWaitHandle;
        var timer = Stopwatch.StartNew(); ((IDisposable)watch).Dispose();
        Assert(timer.Elapsed < TimeSpan.FromSeconds(10), "Production watch dispose did not cancel/drain promptly.");
        Assert(dir is not null && dir.IsClosed && completion is not null && completion.IsClosed
            && Field(watch, "buffer") is IntPtr buffer && buffer == IntPtr.Zero && Field(watch, "overlapped") is IntPtr overlapped && overlapped == IntPtr.Zero,
            "Production watch released incompletely drained or retained resources.");
        observed["dispose"] = new { milliseconds = timer.Elapsed.TotalMilliseconds, directoryClosed = dir!.IsClosed, eventClosed = completion!.IsClosed, bufferFreed = true, overlappedFreed = true };
        Exception? failure = null; try { VerifyWatch(watch); } catch (Exception ex) { failure = ex; }
        Assert(failure is ObjectDisposedException, "Disposed production watch still accepted polling.");
    }
    static string Detect(object watch)
    {
        var timer = Stopwatch.StartNew(); int pendingPolls = 0; IOException? failure = null;
        while (timer.ElapsedMilliseconds < 5000)
        {
            try { VerifyWatch(watch); pendingPolls++; } catch (IOException ex) { failure = ex; break; }
            Thread.Sleep(1);
        }
        observed["nativePoll"] = new { milliseconds = timer.Elapsed.TotalMilliseconds, pendingPolls, error = failure?.ToString(), invalidated = Invalidated(watch) };
        Assert(failure is not null && Invalidated(watch), "Production native one-shot polling did not observe real directory changes.");
        IOException? repeated = null; try { VerifyWatch(watch); } catch (IOException ex) { repeated = ex; }
        Assert(repeated is not null && Invalidated(watch), "Completed one-shot watch was reused as an unchanged snapshot.");
        return failure!.Message;
    }
    static void WatchCase(string name, string behavior)
    {
        string scope = Scope(name); string directory = Path.Combine(scope, "watched"); string deep = Path.Combine(directory, "one", "two"); Directory.CreateDirectory(deep);
        string existing = NewFile(deep); object proof = Proof(existing); object watch = Watch(directory); bool disposed = false;
        try
        {
            Assert(!Invalidated(watch), "A new native watch was already invalidated."); VerifyWatch(watch);
            switch (behavior)
            {
                case "unchanged":
                    for (int i = 0; i < 64; i++) VerifyWatch(watch);
                    Assert(!Invalidated(watch) && Field(watch, "armed") is true, "Unchanged watch did not remain armed/pending."); observed["unchangedPolls"] = 65; break;
                case "add": NewFile(deep, "added.txt"); Detect(watch); break;
                case "rename": Move(existing, existing + ".retained"); Detect(watch); Same(existing + ".retained", proof); break;
                case "parent-pin":
                    using (var pin = OpenPin(directory)) { NewFile(deep, "added-with-parent-pin.txt"); Detect(watch); }
                    observed["parentPinDidNotFreezeChildCreation"] = true; break;
                case "cancel": VerifyWatch(watch); break;
                case "complete": NewFile(deep, "completed.txt"); Detect(watch); break;
                case "burst":
                    for (int i = 0; i < 512; i++) NewFile(deep, $"burst-{i:D4}-long-owned-name.txt");
                    observed["burstCount"] = 512; observed["completionMessage"] = Detect(watch); break;
                case "rename-directory":
                    RequireRenameDenied(directory, directory + ".retained"); DisposeWatch(watch); disposed = true;
                    Move(directory, directory + ".retained"); Same(Path.Combine(directory + ".retained", "one", "two", "source.txt"), proof);
                    observed["releasedDirectoryRename"] = true; break;
                default: throw new InvalidOperationException("Unknown native watch behavior.");
            }
            if (behavior != "rename" && behavior != "rename-directory") Same(existing, proof);
        }
        finally { if (!disposed) DisposeWatch(watch); }
    }
    static void WatchRace()
    {
        string scope = Scope(Cases[15]); var samples = new List<object>();
        for (int i = 0; i < 64; i++)
        {
            string path = Path.Combine(scope, $"race-{i:D3}"); Directory.CreateDirectory(path); object watch = Watch(path);
            using var start = new ManualResetEventSlim(false); string file = Path.Combine(path, "created.txt");
            var writer = Task.Run(() => { start.Wait(); File.WriteAllText(file, "completion-race-owned-data"); });
            start.Set(); if ((i & 1) != 0) Thread.Yield(); var timer = Stopwatch.StartNew();
            DisposeWatch(watch); Assert(writer.Wait(TimeSpan.FromSeconds(5)), "Completion-race writer did not finish.");
            Assert(File.ReadAllText(file) == "completion-race-owned-data", "Cancel/completion race changed fixture data.");
            samples.Add(new { iteration = i, milliseconds = timer.Elapsed.TotalMilliseconds, invalidated = Invalidated(watch), fileSha256 = Sha(file) });
        }
        observed["cancelCompletionSamples"] = samples;
    }
    static void Test(string name, Action body)
    {
        observed = []; var timer = Stopwatch.StartNew();
        try { body(); results.Add(new { name, passed = true, milliseconds = timer.Elapsed.TotalMilliseconds, observed }); }
        catch (Exception ex) { results.Add(new { name, passed = false, milliseconds = timer.Elapsed.TotalMilliseconds, error = ex.ToString(), nativeError = Win32(ex), observed }); }
    }
    static Dictionary<string,string> Args(string[] args)
    {
        Assert(args.Length % 2 == 0, "Named input pairs required."); var values = new Dictionary<string,string>(StringComparer.Ordinal);
        for (int i = 0; i < args.Length; i += 2) Assert(values.TryAdd(args[i], args[i + 1]), "Duplicate input."); return values;
    }
    public static int Main(string[] args)
    {
        var input = Args(args); string assemblyPath = Path.GetFullPath(input["--assembly"]); root = Path.GetFullPath(input["--output"]);
        string reportPath = Path.GetFullPath(input["--report"]); var sources = new[] { (input["--native-source"], input["--native-source-sha"]), (input["--store-source"], input["--store-source-sha"]), (input["--host-source"], input["--host-source-sha"]) };
        Assert(Sha(assemblyPath).Equals(input["--assembly-sha"], StringComparison.OrdinalIgnoreCase), "Production assembly hash differs from its supplied official-build binding.");
        foreach (var source in sources) Assert(Sha(source.Item1).Equals(source.Item2, StringComparison.OrdinalIgnoreCase), "Recorded source binding changed: " + source.Item1);
        Assert(Path.GetPathRoot(root) == @"D:\" && !Directory.Exists(root) && !File.Exists(root), "Fresh external D fixture root required.");
        Directory.CreateDirectory(root); var production = Assembly.LoadFrom(assemblyPath);
        native = production.GetType("Prunlet.Core.NativeFiles", true)!; store = production.GetType("Prunlet.Core.VolumeRecoveryStore", true)!;
        watchType = native.GetNestedType("ExternalDirectoryWatch", BindingFlags.NonPublic) ?? throw new MissingMemberException("Production native watch type absent.");
        Test(Cases[0], () => PinCase(Cases[0], "path", "file")); Test(Cases[1], () => PinCase(Cases[1], "path", "directory")); Test(Cases[2], () => PinCase(Cases[2], "path", "child"));
        Test(Cases[3], () => PinCase(Cases[3], "lookup", "file")); Test(Cases[4], () => PinCase(Cases[4], "lookup", "directory")); Test(Cases[5], () => PinCase(Cases[5], "lookup", "child"));
        Test(Cases[6], ContainerRename); Test(Cases[7], ContainerNonempty); Test(Cases[8], ContainerEmpty);
        Test(Cases[9], () => WatchCase(Cases[9], "unchanged")); Test(Cases[10], () => WatchCase(Cases[10], "add")); Test(Cases[11], () => WatchCase(Cases[11], "rename"));
        Test(Cases[12], () => WatchCase(Cases[12], "parent-pin")); Test(Cases[13], () => WatchCase(Cases[13], "cancel")); Test(Cases[14], () => WatchCase(Cases[14], "complete"));
        Test(Cases[15], WatchRace); Test(Cases[16], () => WatchCase(Cases[16], "burst")); Test(Cases[17], () => WatchCase(Cases[17], "rename-directory"));
        Test(Cases[18], () => PinCase(Cases[18], "lease", "file")); Test(Cases[19], () => PinCase(Cases[19], "lease", "directory")); Test(Cases[20], () => PinCase(Cases[20], "lease", "child"));
        Test(Cases[21], () => AliasLeaseCase(Cases[21], false)); Test(Cases[22], () => AliasLeaseCase(Cases[22], true));
        Test(Cases[23], () => WrongLeaseCase(Cases[23], true)); Test(Cases[24], () => WrongLeaseCase(Cases[24], false));
        Test(Cases[25], AliasLexicalCase); Test(Cases[26], ReparseLeaseCase); Test(Cases[27], AncestorLeaseCase);
        Test(Cases[28], JunctionLeafCase);
        int failed = results.Count(item => !(bool)item.GetType().GetProperty("passed")!.GetValue(item)!);
        var report = new { scope = "Actual published managed production assembly; owned external D paths only; OS rights/notification boundary verification, not full lifecycle E2E", assemblyPath, assemblySha256 = Sha(assemblyPath), hostAssemblyPath = Assembly.GetExecutingAssembly().Location, hostAssemblySha256 = Sha(Assembly.GetExecutingAssembly().Location), sources = sources.Select(source => new { path = source.Item1, sha256 = Sha(source.Item1) }), expectedCases = Cases.Length, executedCases = results.Count, passed = results.Count - failed, failed, retainedDirectory = root, results };
        File.WriteAllText(reportPath, Serialize(report), new UTF8Encoding(false)); Console.WriteLine(Serialize(new { report.expectedCases, report.executedCases, report.passed, report.failed }));
        return failed == 0 && results.Count == Cases.Length ? 0 : 1;
    }
}
