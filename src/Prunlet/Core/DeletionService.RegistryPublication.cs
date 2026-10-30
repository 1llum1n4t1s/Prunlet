using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    internal static event Action<string, string>? RegistryPublicationCheckpoint;

    private sealed class RegistryPublicationOwner
    {
        public int Schema { get; set; } = 1;
        public string OperationId { get; set; } = "";
        public string MetadataRootIdentity { get; set; } = "";
        public string RegistryRootIdentity { get; set; } = "";
        public string MachineName { get; set; } = "";
        public string OwnerSid { get; set; } = "";
        public MoveEntryIdentity DirectoryIdentity { get; set; } = null!;
        public string FinalName { get; set; } = "";
        public string PendingName { get; set; } = "";
        public MoveEntryIdentity PendingIdentity { get; set; } = null!;
        public long Length { get; set; }
        public string Sha256 { get; set; } = "";
        public DateTimeOffset CreatedUtc { get; set; }
    }

    private static bool IsRegistryFinalName(string name) => name is RegistryManifestName or RegistrySnapshotName
        || Regex.IsMatch(name, "^registry-(delete|restore|purge)-(intent|complete)\\.json$", RegexOptions.CultureInvariant);
    private static string RegistryOwnerName(string final) => ".registry-publication-" + final + ".json";
    private static string RegistryPendingName(string final) => ".registry-pending-" + final;

    private static string? RegistryPublicationFinalName(string name)
    {
        string final;
        if (name.StartsWith(".registry-publication-", StringComparison.Ordinal) && name.EndsWith(".json", StringComparison.Ordinal))
            final = name[22..^5];
        else if (name.StartsWith(".registry-pending-", StringComparison.Ordinal)) final = name[18..];
        else return null;
        if (!IsRegistryFinalName(final)) throw new InvalidDataException("Unknown registry publication control was retained.");
        return final;
    }

    private RegistryPublicationOwner ReadRegistryPublicationOwner(string directory, string id, string final)
    {
        var owner = ReadLifecycleJson<RegistryPublicationOwner>(Path.Combine(directory, RegistryOwnerName(final)));
        var binding = NewRegistryStorageState(RegistryRoot(create: false));
        using var parent = NativeFiles.OpenPrivateRegistryDirectory(directory);
        if (owner.Schema != 1 || owner.OperationId != id || owner.FinalName != final || !IsRegistryFinalName(final)
            || owner.PendingName != RegistryPendingName(final) || owner.MetadataRootIdentity != binding.MetadataRootIdentity
            || owner.RegistryRootIdentity != binding.RegistryRootIdentity || owner.MachineName != binding.MachineName || owner.OwnerSid != binding.OwnerSid
            || !ValidMoveIdentity(owner.DirectoryIdentity) || !SameMoveObject(owner.DirectoryIdentity, NativeFiles.MoveIdentity(parent))
            || !ValidMoveIdentity(owner.PendingIdentity) || owner.PendingIdentity.IsDirectory || owner.PendingIdentity.ReparseTag != 0
            || owner.Length is <= 0 or > NativeRegistry.MaximumSnapshotBytes || !Digest(owner.Sha256)
            || final != RegistrySnapshotName && owner.CreatedUtc == default)
            throw new InvalidDataException("Registry publication reservation binding differs.");
        return owner;
    }

    private bool InspectRegistryPublication(string directory, string id, string final)
    {
        var owner = ReadRegistryPublicationOwner(directory, id, final);
        var pending = Path.Combine(directory, owner.PendingName); var target = Path.Combine(directory, final);
        var hasPending = InspectMoveLocation(pending) is not null; var hasFinal = InspectMoveLocation(target) is not null;
        if (hasPending && hasFinal) throw new InvalidDataException("Registry publication has both pending and final members; both were retained.");
        if (!hasPending && !hasFinal) throw new InvalidDataException("Registry publication has no bound body; its reservation was retained.");
        var body = hasFinal ? target : pending;
        using var handle = NativeFiles.OpenLifecycleMetadata(body);
        NativeFiles.Verify(handle, body); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(body); NativeFiles.VerifyPrivateRegistrySecurity(handle);
        if (!SameMoveObject(owner.PendingIdentity, NativeFiles.MoveIdentity(handle))) throw new InvalidDataException("Registry publication body identity changed.");
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length > owner.Length || hasFinal && (stream.Length != owner.Length || HashStream(stream) != owner.Sha256))
            throw new InvalidDataException("Registry publication body size/hash differs.");
        // 未公開bodyは長さ/IDまでの保全情報。formal receiptとしてpromotionしない。
        return hasFinal;
    }

    private bool CleanupRegistryPublications(string id, List<string> warnings)
    {
        var directory = RegistryOperationDirectory(id, allowLegacy: false);
        var clean = true;
        using var parents = PathPolicy.PinRecoveryDirectories(directory);
        var lockPath = Path.Combine(directory, "operation.lock");
        using var operationLock = NativeFiles.OpenLock(lockPath);
        NativeFiles.Verify(operationLock, lockPath); NativeFiles.VerifySingleLink(operationLock); NativeFiles.RejectNamedStreams(lockPath);
        NativeFiles.VerifyPrivateRegistrySecurity(operationLock);
        if (RandomAccess.GetLength(operationLock) != 0) throw new InvalidDataException("Registry operation lock is not empty.");
        foreach (var path in Directory.EnumerateFiles(directory, ".registry-publication-*.json").ToArray())
        {
            try
            {
                var final = RegistryPublicationFinalName(Path.GetFileName(path))!;
                clean &= CleanupRegistryPublication(directory, id, final, warnings);
            }
            catch (Exception ex) when (IsOperational(ex)) { clean = false; warnings.Add($"Registry publication cleanup for {id} was retained: {ex.Message}"); }
        }
        if (Directory.EnumerateFiles(directory, ".registry-pending-*").Any()) clean = false;
        return clean;
    }

    private bool CleanupRegistryPublication(string directory, string id, string final, List<string>? warnings)
    {
        var owner = Path.Combine(directory, RegistryOwnerName(final));
        if (InspectMoveLocation(owner) is null) return InspectMoveLocation(Path.Combine(directory, RegistryPendingName(final))) is null;
        try
        {
            if (!InspectRegistryPublication(directory, id, final)) return false;
            DeleteLifecycleRecord(owner); return true;
        }
        catch (Exception ex) when (IsOperational(ex))
        { warnings?.Add($"Registry publication cleanup for {id} was retained: {ex.Message}"); return false; }
    }

    private FileStream PublishRegistryOwnedJson<T>(string finalPath, string id, T value, List<FileStream> held, List<string>? warnings, byte[]? snapshotBytes = null)
    {
        var directory = Path.GetDirectoryName(finalPath)!; var final = Path.GetFileName(finalPath);
        var checkpoint = RegistryPublicationCheckpoint;
        if (!IsRegistryFinalName(final) || directory != Path.Combine(RegistryRoot(create: false), id))
            throw new InvalidDataException("Registry publication destination is outside its private operation.");
        if (snapshotBytes is not null && (value is not RegistrySnapshot || final != RegistrySnapshotName))
            throw new InvalidDataException("Pre-serialized registry data is restricted to snapshots.");
        var ownerPath = Path.Combine(directory, RegistryOwnerName(final)); var pending = Path.Combine(directory, RegistryPendingName(final));
        RegistryPublicationOwner? owner = null;
        if (InspectMoveLocation(ownerPath) is not null)
        {
            owner = ReadRegistryPublicationOwner(directory, id, final);
            if (value is RegistryReceipt receipt) receipt.CreatedUtc = owner.CreatedUtc;
            else if (value is RegistryManifest manifest) manifest.CreatedUtc = owner.CreatedUtc;
        }
        var bytes = snapshotBytes ?? JsonSerializer.SerializeToUtf8Bytes(value, RegistryJsonOptions);
        var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
        if (owner is not null && (owner.Length != bytes.Length || owner.Sha256 != hash))
            throw new InvalidDataException("Registry publication retry differs from its reserved complete body.");
        Microsoft.Win32.SafeHandles.SafeFileHandle? handle = null;
        FileStream? stream = null;
        var ownerDurable = owner is not null;
        try
        {
            if (owner is null)
            {
                // 0byte bodyの作成後、本文を書き込む前に固定名/parent ID/body ID/hashの予約をflushする。
                handle = NativeFiles.CreatePrivateRegistryFile(pending);
                var binding = NewRegistryStorageState(RegistryRoot(create: false));
                using var parent = NativeFiles.OpenPrivateRegistryDirectory(directory);
                owner = new RegistryPublicationOwner { OperationId = id, MetadataRootIdentity = binding.MetadataRootIdentity, RegistryRootIdentity = binding.RegistryRootIdentity,
                    MachineName = binding.MachineName, OwnerSid = binding.OwnerSid, DirectoryIdentity = NativeFiles.MoveIdentity(parent), FinalName = final,
                    PendingName = RegistryPendingName(final), PendingIdentity = NativeFiles.MoveIdentity(handle), Length = bytes.Length, Sha256 = hash,
                    CreatedUtc = value is RegistryReceipt r ? r.CreatedUtc : value is RegistryManifest m ? m.CreatedUtc : default };
                using (var ownerHandle = NativeFiles.CreatePrivateRegistryFile(ownerPath))
                using (var ownerStream = new FileStream(ownerHandle, FileAccess.ReadWrite))
                {
                    try
                    {
                        JsonSerializer.Serialize(ownerStream, owner, MoveJsonOptions); ownerStream.Flush(true);
                        _ = ReadLifecycleJson<RegistryPublicationOwner>(ownerStream);
                    }
                    catch
                    {
                        try { NativeFiles.DeleteOriginalHandle(ownerHandle); } catch (Exception ex) when (IsOperational(ex)) { }
                        throw;
                    }
                }
                _ = ReadRegistryPublicationOwner(directory, id, final); ownerDurable = true;
            }
            else
            {
                if (InspectMoveLocation(finalPath) is not null) throw new InvalidDataException("Registry publication final already exists; it was not overwritten.");
                handle = NativeFiles.OpenLifecyclePendingPublisher(pending);
                NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(pending);
                if (!SameMoveObject(owner.PendingIdentity, NativeFiles.MoveIdentity(handle))) throw new InvalidDataException("Registry publication retry body ID differs.");
            }
            checkpoint?.Invoke(final + ".owner.durable", id);
            stream = new FileStream(handle, FileAccess.ReadWrite);
            if (stream.Length > bytes.Length) throw new InvalidDataException("Registry publication retry exceeds its reserved body.");
            // 正式callerがNativeのcurrent-data/ACL preflightを再実行した場合だけ完全bytesで再利用する。
            var previous = new byte[checked((int)stream.Length)]; stream.Position = 0; stream.ReadExactly(previous);
            if (!previous.AsSpan().SequenceEqual(bytes.AsSpan(0, previous.Length))) throw new InvalidDataException("Registry publication partial body differs from the fresh caller.");
            stream.Position = 0; stream.SetLength(0);
            if (checkpoint is null) stream.Write(bytes);
            else
            {
                // 実プロセス検証の購読時だけ、本文途中のdurable境界を観測する。
                var split = bytes.Length / 2;
                stream.Write(bytes.AsSpan(0, split)); stream.Flush(true);
                checkpoint(final + ".body.prefix", id);
                stream.Write(bytes.AsSpan(split));
            }
            stream.Flush(true);
            checkpoint?.Invoke(final + ".body.flushed", id);
            _ = ReadRegistryJson<T>(stream);
            NativeFiles.RenameHandle(handle, finalPath); NativeFiles.Verify(handle, finalPath); NativeFiles.VerifyPrivateRegistrySecurity(handle);
            checkpoint?.Invoke(final + ".body.published", id);
            held.Add(stream);
            try { DeleteLifecycleRecord(ownerPath); }
            catch (Exception ex) when (IsOperational(ex)) { warnings?.Add($"Registry publication completed; owned cleanup is pending: {ex.Message}"); }
            return stream;
        }
        catch
        {
            if (!ownerDurable && handle is not null)
            {
                // 今回の生きた作成handleだけ。再起動後のowner不明/partial記録へ一般化しない。
                try { if (NativeFiles.FinalPath(handle) == pending) NativeFiles.DeleteOriginalHandle(handle); } catch (Exception ex) when (IsOperational(ex)) { }
            }
            if (stream is not null) stream.Dispose(); else handle?.Dispose();
            throw;
        }
    }
}
