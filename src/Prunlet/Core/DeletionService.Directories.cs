using Microsoft.Win32.SafeHandles;
using System.Security.Cryptography;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private string ValidateAnyTarget(string path)
    {
        var absolute = PathPolicy.Absolute(path);
        string normalized;
        try
        {
            // 論理パスの親を実体へ解決してから固定し、型検査中の差し替えを許さない。
            var canonicalParent = PathPolicy.Resolve(Path.GetDirectoryName(absolute) ?? absolute,
                finalDirectory: true, allowMissing: false);
            using var parents = PathPolicy.PinDirectories(canonicalParent);
            using var handle = NativeFiles.OpenAny(Path.Combine(canonicalParent, Path.GetFileName(absolute)));
            var directory = NativeFiles.IsDirectory(handle);
            normalized = NativeFiles.IsReparse(handle) ? NativeFiles.FinalPath(handle) : PathPolicy.Resolve(absolute, finalDirectory: directory);
            if (NativeFiles.IsReparse(handle)) VerifySpecialHandle(handle, normalized);
            else NativeFiles.Verify(handle, normalized, directory);
            if (directory && (normalized.Length == 3 || PathPolicy.Within(config.BackupDirectory, normalized)))
                throw new ArgumentException("A drive root or ancestor of the recovery directory cannot be deleted.");
        }
        catch (FileNotFoundException) { normalized = PathPolicy.Resolve(absolute); }
        catch (DirectoryNotFoundException) { normalized = PathPolicy.Resolve(absolute); }
        if (PathPolicy.Within(normalized, config.BackupDirectory))
            throw new ArgumentException("Target path is inside the recovery directory.");
        return normalized;
    }

    private static void ValidateTreeManifest(OperationManifest manifest)
    {
        var entries = manifest.Items.ToDictionary(entry => entry.Path, StringComparer.OrdinalIgnoreCase);
        var roots = manifest.Items.Where(entry => entry.TreeRoot == entry.Path).ToArray();
        for (var i = 0; i < roots.Length; i++)
            for (var j = i + 1; j < roots.Length; j++)
                if (PathPolicy.Within(roots[i].Path, roots[j].Path) || PathPolicy.Within(roots[j].Path, roots[i].Path))
                    throw new InvalidDataException("Manifest tree roots overlap.");
        var preceding = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in manifest.Items)
        {
            if (entry.TreeRoot is null)
            {
                if (entry.Kind != "file" || roots.Any(root => PathPolicy.Within(entry.Path, root.Path) || PathPolicy.Within(root.Path, entry.Path)))
                    throw new InvalidDataException("Standalone manifest entry overlaps a tree.");
            }
            else
            {
                if (!entries.TryGetValue(entry.TreeRoot, out var root) || entry.TreeRoot != root.Path
                    || root.Kind != "directory" || root.TreeRoot != root.Path
                    || !PathPolicy.Within(entry.Path, root.Path))
                    throw new InvalidDataException("Manifest tree root or containment is invalid.");
                if (entry.Path != root.Path)
                {
                    var parent = Path.GetDirectoryName(entry.Path)!;
                    if (!preceding.Contains(parent) || !entries.TryGetValue(parent, out var parentEntry)
                        || parentEntry.Kind != "directory" || parentEntry.TreeRoot != entry.TreeRoot)
                        throw new InvalidDataException("Manifest hierarchy is missing its preceding parent directory.");
                }
            }
            preceding.Add(entry.Path);
        }
    }

    private RestoreResult RestoreTrees(OperationManifest manifest, string directory)
    {
        var result = new RestoreResult { OperationId = manifest.OperationId };
        foreach (var entry in manifest.Items)
            result.Items.Add(new FileOperationResult { Path = entry.Path, Kind = entry.Kind, Status = "not_backed_up", Schema2Wire = true });
        var groups = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        var groupOrder = new List<List<int>>();
        for (var index = 0; index < manifest.Items.Count; index++)
        {
            var entry = manifest.Items[index];
            var key = entry.TreeRoot ?? entry.Path;
            if (!groups.TryGetValue(key, out var indexes))
            {
                indexes = [];
                groups.Add(key, indexes);
                groupOrder.Add(indexes);
            }
            indexes.Add(index);
        }
        foreach (var indexes in groupOrder)
        {
            var root = manifest.Items[indexes[0]];
            if (root.State != "backup_ready") continue;
            var copies = new Dictionary<int, FileStream>();
            var directoryPins = new DirectoryLease();
            var pinnedDirectories = new Dictionary<string, SafeFileHandle>(StringComparer.Ordinal);
            var restoredDirectories = new Dictionary<int, SafeFileHandle>();
            try
            {
                // ツリーの全コピーを検証し固定してから復元先に変更を加える。
                foreach (var index in indexes)
                {
                    var entry = manifest.Items[index];
                    if (entry.State != "backup_ready") throw new InvalidDataException("Prepared tree has an unprepared member.");
                    if (entry.Kind != "file") continue;
                    var item = result.Items[index];
                    item.BackupPath = BackupPath(directory, index); item.Size = entry.Size; item.Sha256 = entry.Sha256;
                    var handle = NativeFiles.OpenBackup(item.BackupPath);
                    FileStream? copy = null;
                    try
                    {
                        NativeFiles.Verify(handle, item.BackupPath); NativeFiles.VerifySingleLink(handle);
                        NativeFiles.RejectNamedStreams(item.BackupPath);
                        copy = new FileStream(handle, FileAccess.Read);
                        if (copy.Length != entry.Size || !Convert.ToHexString(SHA256.HashData(copy)).Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("Backup hash or size differs from the manifest.");
                        copies.Add(index, copy);
                    }
                    catch { if (copy is null) handle.Dispose(); else copy.Dispose(); throw; }
                }
                foreach (var index in indexes)
                {
                    var entry = manifest.Items[index];
                    var item = result.Items[index];
                    if (entry.Kind == "file")
                    {
                        try { RestoreOne(entry, item, copies[index]); }
                        catch (Exception ex) when (IsOperational(ex)) { item.Status = "failed"; item.Error = ex.Message; }
                        continue;
                    }
                    var target = PathPolicy.Resolve(entry.Path, finalDirectory: true);
                    if (PathPolicy.Within(target, config.BackupDirectory) || PathPolicy.Within(config.BackupDirectory, target))
                        throw new InvalidDataException("Restoration directory intersects recovery storage.");
                    using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(target)!);
                    var existed = Path.Exists(target);
                    if (!existed) NativeFiles.CreateDirectory(target);
                    PathPolicy.PinDirectories(target, directoryPins, pinnedDirectories);
                    NativeFiles.RejectNamedStreams(target);
                    if (!existed) restoredDirectories.Add(index, pinnedDirectories[target]);
                    item.Status = existed ? "already_present" : "restored";
                }
                foreach (var index in indexes.AsEnumerable().Reverse())
                {
                    var entry = manifest.Items[index];
                    if (entry.Kind == "directory" && result.Items[index].Status == "restored")
                    {
                        try { RestoreDirectoryMetadata(entry, restoredDirectories[index]); }
                        catch (Exception ex) when (IsOperational(ex))
                        {
                            result.Items[index].Status = "failed";
                            result.Items[index].Error = $"Directory contents were restored, but its metadata could not be restored: {ex.Message}";
                        }
                    }
                }
            }
            catch (Exception ex) when (IsOperational(ex))
            {
                foreach (var index in indexes)
                {
                    var item = result.Items[index];
                    if (item.Status == "not_backed_up") { item.Status = "failed"; item.Error = ex.Message; }
                }
            }
            finally
            {
                directoryPins.Dispose();
                foreach (var copy in copies.Values) copy.Dispose();
            }
        }
        TryWriteResult(Path.Combine(directory, $"restore-result-{Guid.NewGuid():N}.json"), result, result.Warnings);
        return result;
    }

    private static void RestoreDirectoryMetadata(ManifestEntry entry, SafeFileHandle pinned)
    {
        if (entry.LastWriteUtc is null && (entry.Attributes is null || entry.Attributes == NativeFiles.RestorableAttributes(pinned))) return;
        // 子の復元が完了してから、pinと同一実体のハンドルへ時刻・属性を適用する。
        using var handle = NativeFiles.OpenRestoreMetadata(NativeFiles.FinalPath(pinned));
        if (NativeFiles.Identity(handle) != NativeFiles.Identity(pinned) || NativeFiles.IsReparse(handle) || !NativeFiles.IsDirectory(handle))
            throw new IOException("Restored directory identity changed before metadata restoration.");
        if (entry.LastWriteUtc is DateTime timestamp) NativeFiles.RestoreLastWriteTime(handle, timestamp);
        NativeFiles.RestoreAttributes(handle, entry.Attributes);
    }

}
