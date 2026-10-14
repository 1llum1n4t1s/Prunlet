using Microsoft.Win32.SafeHandles;
using System.Security.Cryptography;
using System.Text.Json;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private const long MaximumManifestBytes = 8 * 1024 * 1024;

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
            normalized = PathPolicy.Resolve(absolute, finalDirectory: directory);
            NativeFiles.Verify(handle, normalized, directory);
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
        DirectoryLease? storage = null, operation = null;
        SafeFileHandle? operationLock = null;
        string? directory = null;
        try
        {
            if (!dryRun)
            {
                storage = PathPolicy.PinDirectories(config.BackupDirectory);
                result.OperationId = manifest.OperationId = Guid.NewGuid().ToString("N");
                directory = Path.Combine(config.BackupDirectory, manifest.OperationId);
                NativeFiles.CreateDirectory(directory);
                operation = PathPolicy.PinDirectories(directory);
                operationLock = NativeFiles.CreateDestination(Path.Combine(directory, "operation.lock"));
                NativeFiles.Verify(operationLock, Path.Combine(directory, "operation.lock"));
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
                            var check = CheckOnly(node.Entry.Path);
                            if (check.Status != "would_delete")
                                throw new IOException(check.Error ?? "Tree member disappeared during inspection.");
                            node.Item.Size = check.Size;
                        }
                        else
                        {
                            node.File = Prepare(node.Entry.Path, BackupPath(directory!, node.Index), node.Entry, node.Item);
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
                if (JsonSerializer.SerializeToUtf8Bytes(manifest, PrunletConfig.JsonOptions).LongLength > MaximumManifestBytes)
                    throw new IOException("Expanded operation manifest exceeds the 8 MiB recovery record limit.");
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
            operationLock?.Dispose(); operation?.Dispose(); storage?.Dispose();
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
        // パスだけでも上限を超える場合は、コピーや過大な展開を始めない。
        long minimumRecordBytes = manifest.Items.Sum(entry => (long)entry.Path.Length + 64);
        while (pending.TryDequeue(out var node))
        {
            node.Directory = NativeFiles.OpenDirectory(node.Entry.Path);
            NativeFiles.Verify(node.Directory, node.Entry.Path, directory: true);
            NativeFiles.RejectNamedStreams(node.Entry.Path);
            node.Identity = NativeFiles.Identity(node.Directory);
            node.Entry.LastWriteUtc = Directory.GetLastWriteTimeUtc(node.Entry.Path);
            var children = new List<string>();
            foreach (var child in Directory.EnumerateFileSystemEntries(node.Entry.Path))
            {
                minimumRecordBytes += (long)child.Length + 64;
                if (minimumRecordBytes > MaximumManifestBytes)
                    throw new IOException("Expanded operation exceeds the 8 MiB recovery record limit.");
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
                NativeFiles.DeleteHandle(node.File.Source.SafeFileHandle);
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
                if (NativeFiles.Identity(handle) != node.Identity) throw new IOException("Prepared directory identity changed; deletion stopped.");
                NativeFiles.RejectNamedStreams(node.Entry.Path);
                if (Directory.EnumerateFileSystemEntries(node.Entry.Path).Any())
                    throw new IOException("Directory is no longer empty; unprepared members were retained.");
                // Windows自身も同じハンドルの空確認を行うため、確認後の追加も削除されない。
                NativeFiles.DeleteHandle(handle);
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
        var handled = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var rootIndex = 0; rootIndex < manifest.Items.Count; rootIndex++)
        {
            var root = manifest.Items[rootIndex];
            var key = root.TreeRoot ?? root.Path;
            if (!handled.Add(key)) continue;
            var indexes = manifest.Items.Select((entry, index) => (entry, index))
                .Where(pair => (pair.entry.TreeRoot ?? pair.entry.Path) == key).Select(pair => pair.index).ToArray();
            if (root.State != "backup_ready") continue;
            var copies = new List<FileStream>();
            var directoryPins = new List<DirectoryLease>();
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
                        copies.Add(copy);
                    }
                    catch { if (copy is null) handle.Dispose(); else copy.Dispose(); throw; }
                }
                foreach (var index in indexes)
                {
                    var entry = manifest.Items[index];
                    var item = result.Items[index];
                    if (entry.Kind == "file")
                    {
                        try { RestoreOne(entry, item); }
                        catch (Exception ex) when (IsOperational(ex)) { item.Status = "failed"; item.Error = ex.Message; }
                        continue;
                    }
                    var target = PathPolicy.Resolve(entry.Path, finalDirectory: true);
                    if (PathPolicy.Within(target, config.BackupDirectory) || PathPolicy.Within(config.BackupDirectory, target))
                        throw new InvalidDataException("Restoration directory intersects recovery storage.");
                    using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(target)!);
                    var existed = Path.Exists(target);
                    if (!existed) NativeFiles.CreateDirectory(target);
                    var pin = PathPolicy.PinDirectories(target);
                    directoryPins.Add(pin);
                    NativeFiles.RejectNamedStreams(target);
                    item.Status = existed ? "already_present" : "restored";
                }
                foreach (var index in indexes.Reverse())
                {
                    var entry = manifest.Items[index];
                    if (entry.Kind == "directory" && result.Items[index].Status == "restored" && entry.LastWriteUtc.HasValue)
                    {
                        try { Directory.SetLastWriteTimeUtc(entry.Path, entry.LastWriteUtc.Value); }
                        catch (Exception ex) when (IsOperational(ex))
                        {
                            result.Items[index].Status = "failed";
                            result.Items[index].Error = $"Directory contents were restored, but its timestamp could not be restored: {ex.Message}";
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
                for (var i = directoryPins.Count - 1; i >= 0; i--) directoryPins[i].Dispose();
                foreach (var copy in copies) copy.Dispose();
            }
        }
        TryWriteResult(Path.Combine(directory, $"restore-result-{Guid.NewGuid():N}.json"), result, result.Warnings);
        return result;
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
