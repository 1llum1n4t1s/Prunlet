using System.Buffers;
using System.Security.Cryptography;
using System.Text.Json;
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

    private static bool HasSpecialTarget(string path, bool recursive)
    {
        try
        {
            using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(path)!);
            if (parents.Handles.Any(NativeFiles.IsCaseSensitive)) return true;
            using var handle = NativeFiles.OpenAny(path);
            VerifySpecialHandle(handle, path);
            if (NativeFiles.IsReparse(handle)) return true;
            var directory = NativeFiles.IsDirectory(handle);
            if ((directory && NativeFiles.IsCaseSensitive(handle)) || (!directory && NativeFiles.LinkCount(handle) != 1)
                || NativeFiles.NamedStreams(handle).Count != 0) return true;
            return directory && recursive && Directory.EnumerateFileSystemEntries(path).Any(child => HasSpecialTarget(child, true));
        }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    private DeleteResult DeleteSpecial(string[] paths, bool dryRun, bool recursive)
    {
        var result = new DeleteResult { DryRun = dryRun };
        var manifest = new OperationManifest { Schema = 3 };
        var nodes = new List<SpecialNode>();
        // 最初に全階層を調べ、再帰指定の不足やリンクの先を展開しない。
        foreach (var path in paths) ScanSpecial(path, null, recursive, nodes, manifest, result);
        if (nodes.Count == 0) return result;
        if (dryRun)
        {
            foreach (var node in nodes)
            {
                try
                {
                    using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(node.Entry.Path)!);
                    using var handle = NativeFiles.OpenSpecial(node.Entry.Path);
                    CaptureSpecial(handle, node.Entry, null);
                    node.Item.Size = node.Entry.Size;
                    node.Item.Status = "would_delete";
                }
                catch (FileNotFoundException) { node.Item.Status = "already_absent"; }
                catch (DirectoryNotFoundException) { node.Item.Status = "already_absent"; }
                catch (Exception ex) when (IsOperational(ex)) { node.Item.Status = "failed"; node.Item.Error = ex.Message; }
            }
            return result;
        }
        using var operation = NewOperationLease.Create(config.BackupDirectory);
        result.OperationId = manifest.OperationId = operation.OperationId;
        var directory = operation.Directory;
        FileStream? manifestFile = null;
        try
        {
            var prepared = true;
            foreach (var node in nodes)
            {
                try
                {
                    using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(node.Entry.Path)!);
                    using var source = NativeFiles.OpenSpecial(node.Entry.Path);
                    VerifySpecialHandle(source, node.Entry.Path);
                    node.Identity = NativeFiles.Identity(source);
                    var backupPath = BackupPath(directory, node.Index);
                    var backupHandle = NativeFiles.CreateDestination(backupPath);
                    FileStream backup;
                    try { NativeFiles.Verify(backupHandle, backupPath); backup = new FileStream(backupHandle, FileAccess.ReadWrite); }
                    catch { backupHandle.Dispose(); throw; }
                    node.Backup = backup;
                    CaptureSpecial(source, node.Entry, backup, reserve: ReserveRecoveryBytes);
                    backup.Flush(true);
                    VerifySpecialBackup(backup, node.Entry);
                    node.Entry.State = node.Item.Status = "backup_ready";
                    node.Item.BackupPath = backupPath; node.Item.Sha256 = node.Entry.Sha256; node.Item.Size = node.Entry.Size;
                }
                catch (FileNotFoundException) when (node.Entry.TreeRoot is null && node.Entry.Kind == "file") { node.Entry.State = node.Item.Status = "already_absent"; }
                catch (DirectoryNotFoundException) when (node.Entry.TreeRoot is null && node.Entry.Kind == "file") { node.Entry.State = node.Item.Status = "already_absent"; }
                catch (Exception ex) when (IsOperational(ex)) { prepared = false; node.Entry.State = node.Item.Status = "failed"; node.Item.Error = ex.Message; }
            }
            try
            {
                ValidateManifest(manifest, manifest.OperationId);
                var manifestPath = Path.Combine(directory, "manifest.json");
                var handle = NativeFiles.CreateDestination(manifestPath);
                try { NativeFiles.Verify(handle, manifestPath); manifestFile = new FileStream(handle, FileAccess.ReadWrite); }
                catch { handle.Dispose(); throw; }
                JsonSerializer.Serialize(manifestFile, manifest, PrunletConfig.JsonOptions);
                manifestFile.Flush(true);
            }
            catch (Exception ex) when (IsOperational(ex))
            {
                foreach (var node in nodes) { node.Item.Status = "failed"; node.Item.Error = $"No deletion was attempted because manifest persistence failed: {ex.Message}"; }
                return result;
            }
            if (!prepared)
            {
                foreach (var node in nodes.Where(node => node.Item.Status == "backup_ready"))
                { node.Item.Status = "failed"; node.Item.Error = "No member was deleted because operation preparation failed."; }
            }
            else
            {
                var identities = nodes.ToDictionary(node => node.Entry.Path, node => node.Identity, StringComparer.Ordinal);
                foreach (var node in nodes.AsEnumerable().Reverse().Where(node => node.Entry.State == "backup_ready"))
                {
                    try
                    {
                        using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(node.Entry.Path)!);
                        foreach (var parent in parents.Handles)
                            if (identities.TryGetValue(NativeFiles.FinalPath(parent), out var identity) && NativeFiles.Identity(parent) != identity)
                                throw new IOException("Prepared ancestor identity changed.");
                        using var source = NativeFiles.OpenSpecial(node.Entry.Path, deleting: true);
                        VerifySpecialHandle(source, node.Entry.Path);
                        if (NativeFiles.Identity(source) != node.Identity) throw new IOException("Prepared object identity changed.");
                        var current = NewSpecialEntry(node.Entry.Path, node.Entry.Kind, node.Entry.TreeRoot);
                        // 削除ハンドルと各ストリームを同時に保持し、保存後の変更を検出する。
                        CaptureSpecial(source, current, null, () =>
                        {
                            if (!EquivalentSpecial(current, node.Entry)) throw new IOException("Prepared object content, streams, or metadata changed.");
                            if (current.Kind == "directory" && Directory.EnumerateFileSystemEntries(current.Path).Any())
                                throw new IOException("Directory is no longer empty; unprepared members were retained.");
                            MarkSpecialDeleted(source, current);
                        });
                        node.Item.Status = "deleted";
                    }
                    catch (Exception ex) when (IsOperational(ex)) { node.Item.Status = "failed"; node.Item.Error = ex.Message; }
                }
            }
            TryWriteResult(Path.Combine(directory, "delete-result.json"), result, result.Warnings);
            return result;
        }
        finally { manifestFile?.Dispose(); foreach (var node in nodes) node.Backup?.Dispose(); }
    }

    private static ManifestEntry NewSpecialEntry(string path, string kind, string? root) => new()
    { Path = path, Kind = kind, TreeRoot = root, Schema2Wire = true, Schema3Wire = true };

    private static void ScanSpecial(string path, string? root, bool recursive, List<SpecialNode> nodes, OperationManifest manifest, DeleteResult result)
    {
        string kind = "file";
        List<string> children = [];
        try
        {
            using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(path)!);
            using var handle = NativeFiles.OpenAny(path);
            VerifySpecialHandle(handle, path);
            if (NativeFiles.IsReparse(handle)) kind = NativeFiles.ValidateReparse(NativeFiles.ReadReparse(handle)) == 0xa0000003 ? "junction" : "symlink";
            else if (NativeFiles.IsDirectory(handle))
            {
                kind = "directory";
                children = Directory.EnumerateFileSystemEntries(path).Order(StringComparer.Ordinal).ToList();
                if (!recursive && children.Count != 0) throw new ArgumentException("Nonempty directories require explicit recursive deletion.");
                root ??= path;
            }
        }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
        var entry = NewSpecialEntry(path, kind, root);
        var item = new FileOperationResult { Path = path, Kind = kind, Status = "failed", Schema2Wire = true };
        nodes.Add(new SpecialNode { Entry = entry, Item = item, Index = manifest.Items.Count });
        manifest.Items.Add(entry); result.Items.Add(item);
        foreach (var child in children) ScanSpecial(child, root, recursive, nodes, manifest, result);
    }

    private static void CaptureSpecial(SafeFileHandle source, ManifestEntry entry, FileStream? destination, Action? verified = null, Action<int>? reserve = null)
    {
        VerifySpecialHandle(source, entry.Path);
        entry.Attributes = NativeFiles.RestorableAttributes(source);
        var directory = NativeFiles.IsDirectory(source);
        using var total = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long offset = 0;
        if (NativeFiles.IsReparse(source))
        {
            var bytes = NativeFiles.ReadReparse(source);
            entry.ReparseTag = NativeFiles.ValidateReparse(bytes); entry.LinkDirectory = directory;
            if (entry.ReparseTag == 0xa000000c) _ = NativeFiles.SymbolicTarget(bytes);
            if ((entry.ReparseTag == 0xa0000003 ? "junction" : "symlink") != entry.Kind || (entry.Kind == "junction" && !directory))
                throw new IOException("Prepared reparse object type changed.");
            // 未対応のリンク付随ストリームは、リンク先を開かず安全側に拒否する。
            if (NativeFiles.NamedStreams(source).Count != 0) throw new IOException("Named streams on reparse points are unsupported.");
            if (destination is not null) { reserve?.Invoke(bytes.Length); destination.Write(bytes); }
            total.AppendData(bytes); offset = bytes.Length;
        }
        else
        {
            if ((directory ? "directory" : "file") != entry.Kind) throw new IOException("Prepared object type changed.");
            entry.CaseSensitive = directory && NativeFiles.IsCaseSensitive(source);
            entry.LastWriteUtc = directory ? Directory.GetLastWriteTimeUtc(entry.Path) : File.GetLastWriteTimeUtc(entry.Path);
            var names = NativeFiles.NamedStreams(source);
            entry.Streams = [];
            var held = new List<FileStream>();
            try
            {
                foreach (var name in (directory ? names : new[] { "" }.Concat(names)))
                {
                    FileStream stream;
                    if (name.Length == 0)
                    {
                        // 所有する削除ハンドルをFileStreamへ移譲しない。
                        stream = new FileStream(new SafeFileHandle(source.DangerousGetHandle(), ownsHandle: false), FileAccess.Read);
                    }
                    else stream = new FileStream(NativeFiles.OpenStream(entry.Path, name), FileAccess.Read);
                    held.Add(stream);
                    if (NativeFiles.Identity(stream.SafeFileHandle) != NativeFiles.Identity(source)) throw new IOException("Stream belongs to a different object.");
                    var record = new ManifestStream { Name = name, Offset = offset };
                    using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    var buffer = ArrayPool<byte>.Shared.Rent(CopyBufferSize);
                    try
                    {
                        int count;
                        while ((count = stream.Read(buffer, 0, CopyBufferSize)) != 0)
                        { if (destination is not null) { reserve?.Invoke(count); destination.Write(buffer, 0, count); } digest.AppendData(buffer, 0, count); total.AppendData(buffer, 0, count); record.Size += count; }
                    }
                    finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
                    record.Sha256 = Convert.ToHexStringLower(digest.GetHashAndReset());
                    offset = checked(offset + record.Size); entry.Streams.Add(record);
                }
                if (!names.SequenceEqual(NativeFiles.NamedStreams(source), StringComparer.Ordinal)) throw new IOException("Alternate stream membership changed during capture.");
                entry.Size = offset; entry.Sha256 = Convert.ToHexStringLower(total.GetHashAndReset());
                verified?.Invoke();
                return;
            }
            finally { foreach (var stream in held) stream.Dispose(); }
        }
        entry.Size = offset; entry.Sha256 = Convert.ToHexStringLower(total.GetHashAndReset());
        verified?.Invoke();
    }

    private static bool EquivalentSpecial(ManifestEntry left, ManifestEntry right) => left.Kind == right.Kind && left.Size == right.Size
        && left.Sha256 == right.Sha256 && left.ReparseTag == right.ReparseTag && left.LinkDirectory == right.LinkDirectory
        && left.CaseSensitive == right.CaseSensitive && left.Attributes == right.Attributes
        && EquivalentStreams(left.Streams, right.Streams);

    private static bool EquivalentStreams(List<ManifestStream>? left, List<ManifestStream>? right)
    {
        if (ReferenceEquals(left, right)) return true;
        if (left is null || right is null || left.Count != right.Count) return false;
        for (var i = 0; i < left.Count; i++)
        {
            var a = left[i]; var b = right[i];
            if (ReferenceEquals(a, b)) continue;
            if (a is null || b is null || !string.Equals(a.Name, b.Name, StringComparison.Ordinal)
                || a.Offset != b.Offset || a.Size != b.Size || !string.Equals(a.Sha256, b.Sha256, StringComparison.Ordinal))
                return false;
        }
        return true;
    }

    private static void MarkSpecialDeleted(SafeFileHandle source, ManifestEntry entry)
    {
        NativeFiles.SetOriginalDeletePending(source, true);
        try
        {
            // 最後の名前を削除保留にすると、新しいストリームの作成も拒否される。
            // 他のhardlink名が残る場合は、その名前が元データを保持する。
            var expected = entry.Streams?.Where(stream => stream.Name.Length != 0).Select(stream => stream.Name).Order(StringComparer.Ordinal).ToArray() ?? [];
            if (!NativeFiles.NamedStreams(source).SequenceEqual(expected, StringComparer.Ordinal))
                throw new IOException("Alternate stream membership changed before pending deletion; deletion was cancelled.");
        }
        catch (Exception original)
        {
            try { NativeFiles.SetOriginalDeletePending(source, false); }
            catch (Exception cancellation)
            { throw new IOException($"{original.Message} Pending deletion could not be cancelled: {cancellation.Message}", original); }
            throw;
        }
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

    private sealed class SpecialNode
    {
        internal int Index { get; init; }
        internal ManifestEntry Entry { get; init; } = null!;
        internal FileOperationResult Item { get; init; } = null!;
        internal string? Identity { get; set; }
        internal FileStream? Backup { get; set; }
    }
}
