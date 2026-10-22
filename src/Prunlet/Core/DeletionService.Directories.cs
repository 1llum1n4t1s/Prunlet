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

    private static bool IsDirectoryPath(string path)
    {
        try
        {
            using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(path) ?? path);
            using var handle = NativeFiles.OpenAny(path);
            var directory = NativeFiles.IsDirectory(handle);
            if (NativeFiles.IsReparse(handle)) { VerifySpecialHandle(handle, path); return false; }
            NativeFiles.Verify(handle, path, directory);
            return directory;
        }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    private DeleteResult DeleteTrees(string[] paths, bool dryRun, bool recursive)
    {
        if (!recursive)
            foreach (var path in paths.Where(IsDirectoryPath))
            {
                using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(path)!);
                using var handle = NativeFiles.OpenDirectory(path);
                NativeFiles.Verify(handle, path, directory: true);
                if (Directory.EnumerateFileSystemEntries(path).Any())
                    throw new ArgumentException("Nonempty directories require explicit recursive deletion.");
            }
        var result = new DeleteResult { DryRun = dryRun };
        var manifest = new OperationManifest { Schema = 2 };
        var trees = new List<PreparedTree>();
        NewOperationLease? operation = null;
        string? directory = null;
        try
        {
            if (!dryRun)
            {
                operation = NewOperationLease.Create(config.BackupDirectory);
                result.OperationId = manifest.OperationId = operation.OperationId;
                directory = operation.Directory;
            }
            foreach (var path in paths)
            {
                var tree = new PreparedTree();
                trees.Add(tree);
                var root = AddTreeEntry(tree, manifest, result, path, IsDirectoryPath(path) ? "directory" : "file", null);
                if (root.Entry.Kind == "directory") root.Entry.TreeRoot = path;
                try
                {
                    tree.Parents = PathPolicy.PinDirectories(Path.GetDirectoryName(path)!);
                    if (root.Entry.Kind == "directory") ScanTree(tree, manifest, result, recursive);
                    foreach (var node in tree.Nodes.Where(node => node.Entry.Kind == "file"))
                    {
                        if (dryRun)
                        {
                            // ScanTreeの全ディレクトリとtree.Parentsが全ファイル処理の終了まで祖先を固定する。
                            var check = CheckOnly(node.Entry.Path, parentsPinned: true);
                            if (check.Status != "would_delete")
                                throw new IOException(check.Error ?? "Tree member disappeared during inspection.");
                            node.Item.Size = check.Size;
                        }
                        else
                        {
                            node.File = Prepare(node.Entry.Path, BackupPath(directory!, node.Index), node.Entry, node.Item, parentsPinned: true);
                            node.Entry.State = "backup_ready";
                        }
                    }
                    foreach (var node in tree.Nodes)
                    {
                        node.Entry.State = "backup_ready";
                        node.Item.Status = dryRun ? "would_delete" : "backup_ready";
                    }
                    tree.Ready = true;
                }
                catch (FileNotFoundException) when (tree.Nodes.Count == 1 && root.Entry.Kind == "file")
                { root.Entry.State = root.Item.Status = "already_absent"; }
                catch (DirectoryNotFoundException) when (tree.Nodes.Count == 1 && root.Entry.Kind == "file")
                { root.Entry.State = root.Item.Status = "already_absent"; }
                catch (Exception ex) when (IsOperational(ex))
                {
                    foreach (var node in tree.Nodes)
                    {
                        if (node.File is null) node.Entry.State = "failed";
                        node.Item.Status = "failed";
                        node.Item.Error = $"No tree member was deleted because preparation failed: {ex.Message}";
                    }
                    tree.Release();
                }
            }
            if (dryRun) return result;
            try
            {
                ValidateManifest(manifest, manifest.OperationId);
                WriteNewJson(Path.Combine(directory!, "manifest.json"), manifest);
            }
            catch (Exception ex) when (IsOperational(ex))
            {
                foreach (var tree in trees.Where(tree => tree.Ready))
                    foreach (var node in tree.Nodes)
                    { node.Item.Status = "failed"; node.Item.Error = $"No deletion was attempted because manifest persistence failed: {ex.Message}"; }
                return result;
            }
            foreach (var tree in trees.Where(tree => tree.Ready)) DeletePreparedTree(tree);
            TryWriteResult(Path.Combine(directory!, "delete-result.json"), result, result.Warnings);
            return result;
        }
        finally
        {
            foreach (var tree in trees) tree.Dispose();
            operation?.Dispose();
        }
    }

    private static TreeNode AddTreeEntry(PreparedTree tree, OperationManifest manifest, DeleteResult result,
        string path, string kind, string? root)
    {
        var node = new TreeNode
        {
            Index = manifest.Items.Count,
            Entry = new ManifestEntry { Path = path, Kind = kind, TreeRoot = root, Schema2Wire = true },
            Item = new FileOperationResult { Path = path, Kind = kind, Status = "failed", Schema2Wire = true }
        };
        manifest.Items.Add(node.Entry); result.Items.Add(node.Item); tree.Nodes.Add(node);
        return node;
    }

    private void ScanTree(PreparedTree tree, OperationManifest manifest, DeleteResult result, bool recursive)
    {
        var root = tree.Nodes[0].Entry.Path;
        var pending = new Queue<TreeNode>();
        pending.Enqueue(tree.Nodes[0]);
        while (pending.TryDequeue(out var node))
        {
            node.Directory = NativeFiles.OpenDirectory(node.Entry.Path);
            NativeFiles.Verify(node.Directory, node.Entry.Path, directory: true);
            NativeFiles.RejectCaseSensitive(node.Directory);
            NativeFiles.RejectNamedStreams(node.Entry.Path);
            node.Identity = NativeFiles.Identity(node.Directory);
            node.Entry.Attributes = NativeFiles.RestorableAttributes(node.Directory);
            node.Entry.LastWriteUtc = Directory.GetLastWriteTimeUtc(node.Entry.Path);
            var children = new List<string>();
            foreach (var child in Directory.EnumerateFileSystemEntries(node.Entry.Path))
            {
                children.Add(child);
            }
            children.Sort(StringComparer.OrdinalIgnoreCase);
            if (!recursive && children.Count != 0) throw new IOException("Nonempty directories require explicit recursive deletion.");
            foreach (var child in children)
            {
                var canonical = ValidateAnyTarget(child);
                if (!PathPolicy.Within(canonical, root) || !canonical.Equals(child, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Tree member resolves outside its recorded hierarchy.");
                var nested = AddTreeEntry(tree, manifest, result, canonical, IsDirectoryPath(canonical) ? "directory" : "file", root);
                if (nested.Entry.Kind == "directory") pending.Enqueue(nested);
            }
        }
    }

    private static void DeletePreparedTree(PreparedTree tree)
    {
        foreach (var node in tree.Nodes.Where(node => node.File is not null))
        {
            try
            {
                NativeFiles.Verify(node.File!.Source.SafeFileHandle, node.Entry.Path);
                NativeFiles.VerifySingleLink(node.File.Source.SafeFileHandle);
                NativeFiles.RejectNamedStreams(node.Entry.Path);
                NativeFiles.DeleteOriginalHandle(node.File.Source.SafeFileHandle);
                node.File.Source.Dispose();
                node.Item.Status = "deleted";
            }
            catch (Exception ex) when (IsOperational(ex)) { node.Item.Status = "failed"; node.Item.Error = ex.Message; }
        }
        // 子ファイルの祖先pinも閉じてから、ディレクトリを子から消す。
        foreach (var node in tree.Nodes) { node.File?.Dispose(); node.File = null; node.Directory?.Dispose(); node.Directory = null; }
        var identities = tree.Nodes.Where(node => node.Entry.Kind == "directory")
            .ToDictionary(node => node.Entry.Path, node => node.Identity, StringComparer.OrdinalIgnoreCase);
        foreach (var node in tree.Nodes.Where(node => node.Entry.Kind == "directory").Reverse())
        {
            try
            {
                using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(node.Entry.Path)!);
                foreach (var parent in parents.Handles)
                {
                    var actual = NativeFiles.ResolveVerified(parent, directory: true);
                    if (identities.TryGetValue(actual, out var expected) && NativeFiles.Identity(parent) != expected)
                        throw new IOException("Prepared ancestor directory identity changed; deletion stopped.");
                }
                using var handle = NativeFiles.OpenDirectorySource(node.Entry.Path);
                NativeFiles.Verify(handle, node.Entry.Path, directory: true);
                NativeFiles.RejectCaseSensitive(handle);
                if (NativeFiles.Identity(handle) != node.Identity) throw new IOException("Prepared directory identity changed; deletion stopped.");
                NativeFiles.RejectNamedStreams(node.Entry.Path);
                if (Directory.EnumerateFileSystemEntries(node.Entry.Path).Any())
                    throw new IOException("Directory is no longer empty; unprepared members were retained.");
                // Windows自身も同じハンドルの空確認を行うため、確認後の追加も削除されない。
                NativeFiles.DeleteOriginalHandle(handle);
                node.Item.Status = "deleted";
            }
            catch (Exception ex) when (IsOperational(ex)) { node.Item.Status = "failed"; node.Item.Error = ex.Message; }
        }
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

    private sealed class TreeNode
    {
        internal int Index { get; init; }
        internal ManifestEntry Entry { get; init; } = null!;
        internal FileOperationResult Item { get; init; } = null!;
        internal PreparedFile? File { get; set; }
        internal SafeFileHandle? Directory { get; set; }
        internal string? Identity { get; set; }
    }

    private sealed class PreparedTree : IDisposable
    {
        internal List<TreeNode> Nodes { get; } = [];
        internal DirectoryLease? Parents { get; set; }
        internal bool Ready { get; set; }
        internal void Release()
        {
            foreach (var node in Nodes) { node.File?.Dispose(); node.File = null; node.Directory?.Dispose(); node.Directory = null; }
            Parents?.Dispose(); Parents = null;
        }
        public void Dispose() => Release();
    }
}
