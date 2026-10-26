using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

// 内容のコピーを行わず、同じボリュームの専用領域と移動先の親を固定する。
internal static class VolumeRecoveryStore
{
    internal static string OwnerSid
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            return identity.User?.Value ?? throw new IOException("Cannot determine the current user's SID.");
        }
    }

    internal static string StoreKey(string metadataRoot)
    {
        var canonical = PathPolicy.Resolve(metadataRoot, finalDirectory: true, allowMissing: false);
        return StoreKeyFromResolvedRoot(canonical);
    }

    // 呼出し元で直前に物理解決したパスだけを受け、同じ祖先を再度開く処理を省く。
    // SIDは呼出しごとに取得し、設定や実行主体をまたぐキャッシュは持たない。
    private static string StoreKeyFromResolvedRoot(string canonical) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical.ToUpperInvariant() + "\n" + OwnerSid)))[..32];

    internal static string ExpectedRoot(PrunletConfig config, string sourcePath) => Location(config, sourcePath).Root;

    internal static IReadOnlyList<string> ProtectedRoots(PrunletConfig config, string sourcePath)
    {
        var location = Location(config, sourcePath);
        var restore = Location(config, sourcePath, restore: true);
        var defaultRestore = Location(config, sourcePath, useDefault: true, restore: true);
        return [location.PrivateBase, location.Root, restore.PrivateBase, restore.Root, defaultRestore.PrivateBase, defaultRestore.Root];
    }

    // 明示移行のroot所有確認だけ。作成・ACL変更・子payloadや他StoreKeyの列挙は行わない。
    internal static void InspectExistingRoots(PrunletConfig config,
        Action<string, string, MoveEntryIdentity> inspect, Action<string, Exception> unavailable, bool includeRestore = false)
        => InspectExistingRoots(config, (root, volume, identity, _) => inspect(root, volume, identity), unavailable, includeRestore);

    internal static void InspectExistingRoots(PrunletConfig config,
        Action<string, string, MoveEntryIdentity, bool> inspect, Action<string, Exception> unavailable, bool includeRestore = false)
    {
        var drives = new HashSet<string>(config.VolumeRecoveryDirectories.Keys.Select(PathPolicy.Absolute), StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var drive in DriveInfo.GetDrives())
            {
                try
                {
                    if ((drive.DriveType is DriveType.Fixed or DriveType.Removable or DriveType.Ram) && drive.IsReady)
                        drives.Add(PathPolicy.Absolute(drive.Name));
                }
                catch (Exception ex) when (IsInventoryFailure(ex)) { unavailable(drive.Name, ex); }
            }
        }
        catch (Exception ex) when (IsInventoryFailure(ex)) { unavailable("local volumes", ex); }

        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var drive in drives.Order(StringComparer.OrdinalIgnoreCase))
        {
            // overrideへの移行前に使った既定領域も同じmetadata StoreKeyに限って検査する。
            foreach (var useDefault in new[] { false, true })
            foreach (var restore in includeRestore ? new[] { false, true } : new[] { false })
            {
                var label = drive;
                try
                {
                    var location = Location(config, drive, useDefault, restore);
                    label = location.Root;
                    if (!paths.Add(location.Root)) continue;
                    DirectoryLease pin;
                    try { pin = PathPolicy.PinRecoveryDirectories(location.Root); }
                    catch (FileNotFoundException) { continue; }
                    catch (DirectoryNotFoundException) { continue; }
                    using (pin)
                    {
                        using var rootGuard = NativeFiles.OpenMovePurgePin(location.Root);
                        NativeFiles.Verify(rootGuard, location.Root, directory: true);
                        VerifySecureDirectory(location.PrivateBase, restore);
                        VerifySecureDirectory(location.Root, restore);
                        var identity = NativeFiles.MoveIdentity(rootGuard);
                        VerifyVolume(location, identity);
                        using var marker = ReadMarker(Path.Combine(location.Root, "store.json"), location, identity);
                        var key = location.VolumeName.ToUpperInvariant() + ":" + identity.VolumeSerialNumber + ":" + identity.FileId;
                        if (!identities.Add(key)) continue;
                        inspect(location.Root, location.VolumeName, identity, restore);
                    }
                }
                catch (Exception ex) when (IsInventoryFailure(ex)) { unavailable(label, ex); }
            }
        }
    }

    // Shell直前の再検査専用。返却時にはrootとmarkerのDELETE非共有pinを全て解放する。
    internal static void ValidateExistingRoot(PrunletConfig config, string path, MoveEntryIdentity expected, bool restore)
    {
        var location = new[] { Location(config, path, restore: restore), Location(config, path, useDefault: true, restore: restore) }
            .FirstOrDefault(candidate => candidate.Root.Equals(path, StringComparison.OrdinalIgnoreCase))
            ?? throw new IOException("Legacy recovery root is outside its configured ownership location.");
        using var pin = PathPolicy.PinRecoveryDirectories(location.Root);
        VerifySecureDirectory(location.PrivateBase, restore);
        VerifySecureDirectory(location.Root, restore);
        using var root = NativeFiles.OpenMovePurgePin(location.Root);
        NativeFiles.Verify(root, location.Root, directory: true);
        var actual = NativeFiles.MoveIdentity(root);
        if (actual.VolumeSerialNumber != expected.VolumeSerialNumber || actual.FileId != expected.FileId)
            throw new IOException("Legacy recovery root identity changed.");
        VerifyVolume(location, actual);
        using var marker = ReadMarker(Path.Combine(location.Root, "store.json"), location, actual);
    }

    private static bool IsInventoryFailure(Exception ex) => ex is IOException or InvalidDataException or UnauthorizedAccessException
        or ArgumentException or System.Security.SecurityException or JsonException or InvalidOperationException or FormatException or OverflowException;

    private static StoreLocation Location(PrunletConfig config, string sourcePath, bool useDefault = false, bool restore = false)
    {
        var source = PathPolicy.Absolute(sourcePath);
        // reparse対象自身ではなく、その名前が置かれているボリュームを選ぶ。
        var sourceParent = Path.GetDirectoryName(source) ?? source;
        var mountRoot = NativeFiles.VolumeMountRoot(sourceParent);
        if (mountRoot.Length != 3) throw new IOException("Recovery stores require a local drive-root volume mount.");
        var volumeName = NativeFiles.VolumeName(mountRoot);
        var metadata = PathPolicy.Resolve(config.BackupDirectory, finalDirectory: true, allowMissing: false);
        var privateBase = Path.Combine(mountRoot, (restore ? ".Prunlet-Restore-" : ".Prunlet-Recovery-") + OwnerSid);
        string? configured = null;
        if (!useDefault && config.VolumeRecoveryDirectories is not null)
        {
            foreach (var pair in config.VolumeRecoveryDirectories)
            {
                var key = PathPolicy.Resolve(PathPolicy.Absolute(pair.Key), finalDirectory: true, allowMissing: false);
                if (!key.Equals(mountRoot, StringComparison.OrdinalIgnoreCase)) continue;
                if (configured is not null) throw new InvalidDataException("Duplicate recovery directory configuration for the same volume mount root.");
                configured = PathPolicy.Absolute(pair.Value);
            }
        }
        if (configured is not null) privateBase = configured + (restore ? ".restore" : string.Empty);
        privateBase = PathPolicy.Resolve(privateBase, finalDirectory: true, allowMissing: true);
        var recoveryMountRoot = NativeFiles.VolumeMountRoot(privateBase);
        if (recoveryMountRoot.Length != 3) throw new IOException("Recovery stores require a local drive-root volume mount.");
        if (!NativeFiles.VolumeName(recoveryMountRoot).Equals(volumeName, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Recovery directory and source must belong to the same volume; copying is not permitted.");
        if (PathPolicy.Within(privateBase, metadata) || PathPolicy.Within(metadata, privateBase))
            throw new IOException("The volume recovery directory and central metadata directory must not contain each other.");
        var storeKey = StoreKeyFromResolvedRoot(metadata);
        return new StoreLocation(privateBase, Path.Combine(privateBase, storeKey), metadata, storeKey, volumeName);
    }

    private static void VerifyVolume(StoreLocation location, MoveEntryIdentity identity)
    {
        if (!identity.IsDirectory || identity.ReparseTag != 0 || (identity.Attributes & (uint)FileAttributes.ReparsePoint) != 0)
            throw new IOException("Recovery storage must be an ordinary directory.");
        using var volume = NativeFiles.OpenDirectory(NativeFiles.VolumeMountRoot(location.PrivateBase));
        if (NativeFiles.MoveIdentity(volume).VolumeSerialNumber != identity.VolumeSerialNumber
            || !NativeFiles.VolumeName(NativeFiles.VolumeMountRoot(location.Root)).Equals(location.VolumeName, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Recovery directory volume identity changed.");
    }

    private static FileStream ReadMarker(string path, StoreLocation location, MoveEntryIdentity root)
    {
        var handle = NativeFiles.OpenBackup(path);
        FileStream? stream = null;
        try
        {
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(path);
            stream = new FileStream(handle, FileAccess.Read);
            if (stream.Length is <= 0 or > 8192) throw new InvalidDataException("Recovery store marker has an invalid size.");
            using var document = JsonDocument.Parse(stream, new JsonDocumentOptions { MaxDepth = 4 });
            var marker = document.RootElement;
            if (marker.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Recovery store marker must be an object.");
            var members = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in marker.EnumerateObject())
            {
                if (property.Name is not ("schema" or "ownerSid" or "metadataRoot" or "storeKey" or "volumeName" or "volumeSerial" or "rootFileId")
                    || !members.Add(property.Name))
                    throw new InvalidDataException("Recovery store marker contains unknown or duplicate members.");
            }
            if (members.Count != 7 || marker.GetProperty("schema").GetInt32() != 1
                || marker.GetProperty("ownerSid").GetString() != OwnerSid
                || marker.GetProperty("metadataRoot").GetString() != location.MetadataRoot
                || marker.GetProperty("storeKey").GetString() != location.StoreKey
                || !string.Equals(marker.GetProperty("volumeName").GetString(), location.VolumeName, StringComparison.OrdinalIgnoreCase)
                || marker.GetProperty("volumeSerial").GetUInt64() != root.VolumeSerialNumber
                || marker.GetProperty("rootFileId").GetString() != root.FileId)
                throw new InvalidDataException("Recovery store marker does not match its owner, metadata root, volume, or directory identity.");
            return stream;
        }
        catch
        {
            if (stream is not null) stream.Dispose();
            else handle.Dispose();
            throw;
        }
    }

    private static void VerifySecureDirectory(string path, bool restore = false)
    {
        using var handle = CreateFileW(Extended(path), 0x00020080, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) ThrowNative("Cannot inspect recovery directory owner and permissions");
        VerifySecureDirectory(handle, path, restore);
    }

    private static void VerifySecureDirectory(SafeFileHandle handle, string path, bool restore = false)
    {
        NativeFiles.Verify(handle, path, directory: true);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.RejectCaseSensitive(handle);
        NativeFiles.RejectNamedStreams(path);
        // 所有者とDACLを同じ固定済みディレクトリハンドルから読む。
        var error = GetSecurityInfo(handle, 1, 5, out _, out _, out _, out _, out var descriptor);
        if (error != 0) throw new IOException("Cannot read recovery directory security: " + new Win32Exception((int)error).Message);
        try
        {
            var length = GetSecurityDescriptorLength(descriptor);
            if (length is 0 or > 65536) throw new IOException("Invalid recovery directory security descriptor.");
            var bytes = new byte[(int)length];
            Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            var security = new RawSecurityDescriptor(bytes, 0);
            var expected = new HashSet<string>(restore ? [OwnerSid, "S-1-5-18"] : [OwnerSid, "S-1-5-18", "S-1-5-32-544"], StringComparer.Ordinal);
            if (security.Owner?.Value != OwnerSid || (security.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0
                || security.DiscretionaryAcl is not RawAcl acl || acl.Count != expected.Count)
                throw new IOException("Existing recovery directory has an unexpected owner or unprotected permissions; its ACL was not modified.");
            foreach (var ace in acl)
            {
                if (ace is not CommonAce common || common.IsCallback || common.AceQualifier != AceQualifier.AccessAllowed
                    || common.AceFlags != (AceFlags.ContainerInherit | AceFlags.ObjectInherit)
                    || common.AccessMask != (int)FileSystemRights.FullControl || !expected.Remove(common.SecurityIdentifier.Value))
                    throw new IOException("Existing recovery directory permissions do not match the private store ACL; its ACL was not modified.");
            }
        }
        finally { _ = LocalFree(descriptor); }
    }

    private static string Extended(string path) => @"\\?\" + PathPolicy.Absolute(path);
    private static void ThrowNative(string message)
    {
        var error = Marshal.GetLastWin32Error();
        throw new IOException(message + ": " + new Win32Exception(error).Message, new Win32Exception(error));
    }

    private sealed record StoreLocation(string PrivateBase, string Root, string MetadataRoot, string StoreKey, string VolumeName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("advapi32.dll")]
    private static extern uint GetSecurityInfo(SafeFileHandle handle, int objectType, uint information,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll")]
    private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
