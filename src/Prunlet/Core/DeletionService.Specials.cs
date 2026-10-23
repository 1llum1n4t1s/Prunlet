using System.Buffers;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private static bool ExactWithin(string path, string root) => path == root || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.Ordinal);
    private static bool HasRecoveryCopy(OperationManifest manifest, ManifestEntry entry) => entry.State == "backup_ready" && (entry.Kind == "file" || manifest.Schema == 3);
    private static void VerifySpecialHandle(SafeFileHandle handle, string path)
    {
        if (NativeFiles.FinalPath(handle) != path) throw new IOException("Special object handle path differs from the validated canonical path.");
    }

    private static void ValidateSpecialManifest(OperationManifest manifest)
    {
        var entries = manifest.Items.ToDictionary(entry => entry.Path, StringComparer.Ordinal);
        var preceding = new HashSet<string>(StringComparer.Ordinal);
        var roots = manifest.Items.Where(entry => entry.TreeRoot == entry.Path).ToArray();
        foreach (var entry in manifest.Items)
        {
            if (entry.TreeRoot is null)
            {
                if (entry.Kind == "directory" || roots.Any(root => ExactWithin(entry.Path, root.Path) || ExactWithin(root.Path, entry.Path)))
                    throw new InvalidDataException("Standalone special record overlaps a tree.");
            }
            else
            {
                if (!entries.TryGetValue(entry.TreeRoot, out var root) || root.Kind != "directory" || root.TreeRoot != root.Path || !ExactWithin(entry.Path, root.Path))
                    throw new InvalidDataException("Special tree containment is invalid.");
                if (entry.Path != root.Path)
                {
                    var parent = Path.GetDirectoryName(entry.Path)!;
                    if (!preceding.Contains(parent) || !entries.TryGetValue(parent, out var parentEntry) || parentEntry.Kind != "directory" || parentEntry.TreeRoot != entry.TreeRoot)
                        throw new InvalidDataException("Special tree hierarchy is invalid.");
                }
            }
            preceding.Add(entry.Path);
            if (entry.State != "backup_ready") continue;
            if (entry.Kind is "symlink" or "junction")
            {
                if (entry.Streams is not null || entry.CaseSensitive || entry.Size is < 16 or > 16384
                    || entry.ReparseTag != (entry.Kind == "junction" ? 0xa0000003u : 0xa000000cu) || (entry.Kind == "junction" && !entry.LinkDirectory))
                    throw new InvalidDataException("Invalid reparse manifest metadata.");
                continue;
            }
            if (entry.ReparseTag is not null || entry.LinkDirectory || (entry.CaseSensitive && entry.Kind != "directory") || entry.Streams is null || entry.Streams.Count > 1024)
                throw new InvalidDataException("Invalid stream manifest metadata.");
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); long offset = 0;
            for (var i = 0; i < entry.Streams.Count; i++)
            {
                var stream = entry.Streams[i];
                if (stream is null || !seen.Add(stream.Name) || stream.Offset != offset || stream.Size < 0 || stream.Size > entry.Size - offset
                    || stream.Sha256 is null || stream.Sha256.Length != 64 || !stream.Sha256.All(char.IsAsciiHexDigit))
                    throw new InvalidDataException("Invalid stream size, hash, name, or offset.");
                if (entry.Kind == "file" && i == 0) { if (stream.Name != "") throw new InvalidDataException("Missing unnamed file stream."); }
                else NativeFiles.ValidateStreamName(stream.Name);
                offset += stream.Size;
            }
            if (offset != entry.Size || (entry.Kind == "file" && entry.Streams.Count == 0)) throw new InvalidDataException("Stream container length is inconsistent.");
        }
        for (var i = 0; i < roots.Length; i++)
            for (var j = i + 1; j < roots.Length; j++)
                if (ExactWithin(roots[i].Path, roots[j].Path) || ExactWithin(roots[j].Path, roots[i].Path)) throw new InvalidDataException("Special tree roots overlap.");
    }

    private static void VerifySpecialBackup(FileStream backup, ManifestEntry entry)
    {
        backup.Position = 0;
        if (backup.Length != entry.Size || !Convert.ToHexString(SHA256.HashData(backup)).Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Backup hash or size differs from the manifest.");
        VerifySpecialBackupContents(backup, entry);
    }

    private static void VerifySpecialBackupContents(FileStream backup, ManifestEntry entry)
    {
        if (entry.Kind is "symlink" or "junction")
        {
            backup.Position = 0; var bytes = new byte[checked((int)backup.Length)]; backup.ReadExactly(bytes);
            if (NativeFiles.ValidateReparse(bytes) != entry.ReparseTag) throw new InvalidDataException("Backup reparse tag differs from the manifest.");
            if (entry.Kind == "symlink") _ = NativeFiles.SymbolicTarget(bytes);
            return;
        }
        foreach (var stream in entry.Streams!)
        {
            backup.Position = stream.Offset;
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            CopyRange(backup, null, stream.Size, digest);
            if (!Convert.ToHexString(digest.GetHashAndReset()).Equals(stream.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Backup stream hash differs from the manifest.");
        }
    }

    private RestoreResult RestoreSpecial(OperationManifest manifest, string directory)
    {
        var result = new RestoreResult { OperationId = manifest.OperationId };
        foreach (var entry in manifest.Items) result.Items.Add(new FileOperationResult { Path = entry.Path, Kind = entry.Kind, Schema2Wire = true, Status = "not_backed_up" });
        var copies = new Dictionary<int, FileStream>();
        var pins = new DirectoryLease();
        var pinnedDirectories = new Dictionary<string, SafeFileHandle>(StringComparer.Ordinal);
        var restoredDirectories = new Dictionary<int, SafeFileHandle>();
        try
        {
            // どの復元先も作る前に、全コピーとストリーム記録を検証する。
            for (var i = 0; i < manifest.Items.Count; i++)
            {
                var entry = manifest.Items[i]; if (entry.State != "backup_ready") continue;
                var path = BackupPath(directory, i); var handle = NativeFiles.OpenBackup(path);
                FileStream? backup = null;
                try
                {
                    NativeFiles.Verify(handle, path); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(path);
                    backup = new FileStream(handle, FileAccess.Read); VerifySpecialBackup(backup, entry); copies.Add(i, backup);
                    var item = result.Items[i]; item.BackupPath = path; item.Size = entry.Size; item.Sha256 = entry.Sha256;
                }
                catch { if (backup is null) handle.Dispose(); else backup.Dispose(); throw; }
            }
            var blocked = new HashSet<string>(StringComparer.Ordinal);
            for (var i = 0; i < manifest.Items.Count; i++)
            {
                var entry = manifest.Items[i]; var item = result.Items[i];
                if (!copies.TryGetValue(i, out var backup)) continue;
                if (HasBlockedAncestor(entry.Path, blocked)) { item.Status = "conflict"; item.Error = "Parent directory could not be restored."; continue; }
                try
                {
                    var parent = PathPolicy.Resolve(Path.GetDirectoryName(entry.Path)!, finalDirectory: true, allowMissing: false);
                    var target = Path.Combine(parent, Path.GetFileName(entry.Path));
                    if (PathPolicy.Within(target, config.BackupDirectory) || (entry.Kind == "directory" && PathPolicy.Within(config.BackupDirectory, target)))
                        throw new InvalidDataException("Restoration intersects recovery storage.");
                    using var parents = PathPolicy.PinDirectories(parent);
                    if (SpecialExists(target))
                    {
                        if (entry.Kind == "directory")
                        {
                            using var existing = NativeFiles.OpenAny(target);
                            if (!NativeFiles.IsReparse(existing) && NativeFiles.IsDirectory(existing) && NativeFiles.IsCaseSensitive(existing) == entry.CaseSensitive
                                && NativeFiles.NamedStreams(existing).Count == 0 && entry.Streams!.Count == 0)
                            { item.Status = "already_present"; PathPolicy.PinDirectories(target, pins, pinnedDirectories); continue; }
                        }
                        item.Status = "conflict"; item.Error = "Original path already exists; nothing was overwritten.";
                        if (entry.Kind == "directory") blocked.Add(entry.Path);
                        continue;
                    }
                    RestoreSpecialOne(entry, target, backup);
                    item.Status = "restored";
                    if (entry.Kind == "directory")
                    {
                        PathPolicy.PinDirectories(target, pins, pinnedDirectories);
                        restoredDirectories.Add(i, pinnedDirectories[target]);
                    }
                }
                catch (Exception ex) when (IsOperational(ex))
                { item.Status = "failed"; item.Error = ex.Message; if (entry.Kind == "directory") blocked.Add(entry.Path); }
            }
            for (var i = manifest.Items.Count - 1; i >= 0; i--)
                if (manifest.Items[i].Kind == "directory" && result.Items[i].Status == "restored")
                    try { RestoreDirectoryMetadata(manifest.Items[i], restoredDirectories[i]); }
                    catch (Exception ex) when (IsOperational(ex)) { result.Items[i].Status = "failed"; result.Items[i].Error = ex.Message; }
        }
        catch (Exception ex) when (IsOperational(ex))
        { foreach (var item in result.Items.Where(item => item.Status == "not_backed_up")) { item.Status = "failed"; item.Error = ex.Message; } }
        finally { pins.Dispose(); foreach (var backup in copies.Values) backup.Dispose(); }
        TryWriteResult(Path.Combine(directory, $"restore-result-{Guid.NewGuid():N}.json"), result, result.Warnings);
        return result;
    }

    private static bool SpecialExists(string path)
    {
        try { using var handle = NativeFiles.OpenAny(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    private static void RestoreSpecialOne(ManifestEntry entry, string target, FileStream backup)
    {
        var directory = entry.Kind == "directory" || entry.LinkDirectory;
        SafeFileHandle handle;
        if (entry.Kind == "symlink")
        {
            backup.Position = 0; var bytes = new byte[checked((int)backup.Length)]; backup.ReadExactly(bytes);
            handle = NativeFiles.CreateSymbolicDestination(target, bytes, entry.LinkDirectory);
        }
        else if (directory)
        {
            handle = NativeFiles.CreateDirectoryDestination(target);
        }
        else handle = NativeFiles.CreateDestination(target);
        using (handle)
        {
            try
            {
                VerifySpecialHandle(handle, target);
                if (entry.Kind is "symlink" or "junction")
                {
                    if (entry.Kind == "junction")
                    {
                        backup.Position = 0; var bytes = new byte[checked((int)backup.Length)]; backup.ReadExactly(bytes);
                        NativeFiles.WriteReparse(handle, bytes);
                    }
                    NativeFiles.RestoreAttributes(handle, entry.Attributes);
                    return;
                }
                if (directory) NativeFiles.SetCaseSensitive(handle, entry.CaseSensitive);
                foreach (var record in entry.Streams!)
                {
                    using var streamHandle = record.Name.Length == 0 ? new SafeFileHandle(handle.DangerousGetHandle(), ownsHandle: false) : NativeFiles.OpenStream(target, record.Name, create: true);
                    using var destination = new FileStream(streamHandle, FileAccess.ReadWrite);
                    backup.Position = record.Offset; CopyRange(backup, destination, record.Size, null); destination.Flush(true); destination.Position = 0;
                    if (destination.Length != record.Size || !Convert.ToHexString(SHA256.HashData(destination)).Equals(record.Sha256, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("Restored stream hash or size differs.");
                }
                if (!directory)
                {
                    if (entry.LastWriteUtc is DateTime timestamp) NativeFiles.RestoreLastWriteTime(handle, timestamp);
                    NativeFiles.RestoreAttributes(handle, entry.Attributes);
                }
            }
            catch (Exception original) when (IsOperational(original))
            {
                try { NativeFiles.DeleteOriginalHandle(handle); }
                catch (Exception cleanup) when (IsOperational(cleanup)) { throw new IOException($"{original.Message} Partial object cleanup failed: {cleanup.Message}", original); }
                throw;
            }
        }
    }

    private static bool HasBlockedAncestor(string path, HashSet<string> blocked)
    {
        for (string? ancestor = path; ancestor is not null; ancestor = Path.GetDirectoryName(ancestor))
            if (blocked.Contains(ancestor)) return true;
        return false;
    }

    private static void CopyRange(Stream source, Stream? destination, long length, IncrementalHash? digest)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(CopyBufferSize);
        try
        {
            while (length > 0)
            {
                var count = source.Read(buffer, 0, (int)Math.Min(CopyBufferSize, length));
                if (count == 0) throw new InvalidDataException("Truncated stream container.");
                destination?.Write(buffer, 0, count); digest?.AppendData(buffer, 0, count); length -= count;
            }
        }
        finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
    }

}
