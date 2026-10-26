using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private FileDeleteResult DeleteRecordless(string[] paths, bool dryRun, bool recursive)
        => DeleteRecordlessCore(paths, dryRun, recursive, exclusive: false)
            ?? DeleteRecordlessCore(paths, dryRun, recursive, exclusive: true)!;

    private FileDeleteResult? DeleteRecordlessCore(string[] paths, bool dryRun, bool recursive, bool exclusive)
    {
        ArgumentNullException.ThrowIfNull(paths);
        if (paths.Length is 0 or > 256) throw new ArgumentException("Specify between 1 and 256 paths.");
        var normalized = paths.Select(ValidateAnyTarget).ToArray();
        for (var i = 0; i < normalized.Length; i++)
            for (var j = i + 1; j < normalized.Length; j++)
                if (PathPolicy.Within(normalized[i], normalized[j]) || PathPolicy.Within(normalized[j], normalized[i]))
                    throw new ArgumentException("Duplicate or overlapping target paths are not allowed.");
        using var coordination = dryRun ? null : AcquireRecoveryCoordination(create: true, deletionTargets: exclusive ? null : normalized);
        var result = new FileDeleteResult { DryRun = dryRun };
        result.Items.AddRange(normalized.Select(path => new FileDeleteItem { Path = path, Status = "failed" }));
        var parents = new DirectoryLease?[paths.Length];
        var roots = new SafeFileHandle?[paths.Length];
        var identities = new MoveEntryIdentity?[paths.Length];
        var parentIdentities = new MoveEntryIdentity?[paths.Length];
        var needsExclusive = new bool[paths.Length];
        try
        {
            // 実体の全木を読まず、入力rootと親だけを全件preflightする。
            DeletionWorkers.For(paths.Length, index =>
            {
                var path = normalized[index]; var item = result.Items[index];
                try
                {
                    var current = InspectMoveLocation(path);
                    CheckRecycleTarget(path, current?.IsDirectory == true);
                    if (current is null) { item.Status = "already_absent"; return; }
                    var parentPath = Path.GetDirectoryName(path)!;
                    parents[index] = PathPolicy.PinDirectories(parentPath);
                    using var parent = NativeFiles.OpenDirectory(parentPath);
                    NativeFiles.Verify(parent, parentPath, directory: true);
                    parentIdentities[index] = NativeFiles.MoveIdentity(parent);
                    var root = NativeFiles.OpenRecordlessPreflight(path); roots[index] = root;
                    var identity = NativeFiles.MoveIdentity(root);
                    if (!SameRecordlessObject(identity, current)) throw new IOException("Recycle source identity changed during preflight.");
                    if (identity.ReparseTag == 0) NativeFiles.Verify(root, path, identity.IsDirectory);
                    else if (!NativeFiles.FinalPath(root).Equals(path, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("Recycle link root resolved to another path.");
                    if (identity.ReparseTag != 0 && NativeFiles.ValidateReparse(NativeFiles.ReadReparse(root)) != identity.ReparseTag)
                        throw new IOException("Recycle source reparse metadata differs.");
                    identities[index] = identity;
                    item.Kind = identity.ReparseTag switch { 0 => identity.IsDirectory ? "directory" : "file", 0xa0000003 => "junction", 0xa000000c => "symlink", _ => throw new IOException("Unsupported reparse point.") };
                    if (identity.IsDirectory && identity.ReparseTag == 0 && !recursive && Directory.EnumerateFileSystemEntries(path).Any())
                        throw new ArgumentException("Nonempty directories require explicit recursive deletion.");
                    needsExclusive[index] = !identity.IsDirectory && NativeFiles.HasMultipleLinks(root);
                    item.Status = "would_recycle";
                }
                catch (Exception ex) when (IsRecycleFailure(ex)) { item.Error = ex.Message; }
            }, sequential: exclusive);
            if (dryRun) return result;
            if (result.Items.Any(item => item.Status == "failed"))
                throw new IOException("Deletion preflight failed; original targets were retained. " + string.Join(" ", result.Items.Where(item => item.Error is not null).Select(item => item.Error)));
            // 子のhandle/ACL/group状態は保持しない。独立directoryは並行し、複数aliasのfile rootだけ取り直す。
            if (!exclusive && needsExclusive.Any(value => value)) return null;
            // 同一実体の別名pinがShell自身のDELETEを塞がないよう、排他batchは全rootを先に解放する。
            if (exclusive) foreach (var root in roots) root?.Dispose();
            DeletionWorkers.For(paths.Length, index =>
            {
                var item = result.Items[index];
                if (item.Status == "already_absent") return;
                var started = false;
                try
                {
                    roots[index]?.Dispose();
                    NativeRecycleBin.RecycleUnrecorded(item.Path, resolved =>
                    {
                        if (!resolved.Equals(item.Path, StringComparison.OrdinalIgnoreCase)) throw new IOException("Shell resolved a different recycle source path.");
                        CheckRecycleTarget(item.Path, identities[index]!.IsDirectory);
                        using var parent = NativeFiles.OpenDirectory(Path.GetDirectoryName(item.Path)!);
                        if (!SameRecordlessObject(parentIdentities[index]!, NativeFiles.MoveIdentity(parent))) throw new IOException("Recycle parent identity changed.");
                        using var source = NativeFiles.OpenShellInspection(item.Path);
                        var current = NativeFiles.MoveIdentity(source);
                        if (!SameRecordlessObject(identities[index]!, current) || current.Attributes != identities[index]!.Attributes)
                            throw new IOException("Recycle source identity or attributes changed.");
                        if (current.ReparseTag != 0) _ = NativeFiles.ReadReparse(source);
                        started = true;
                    });
                    if (InspectMoveLocation(item.Path) is not null) throw new IOException("A source name is still present after Shell recycling.");
                    item.Status = "recycled";
                }
                catch (Exception ex) when (IsRecycleFailure(ex))
                {
                    item.Status = started ? "ambiguous" : "failed";
                    item.Error = ex.Message + (started ? " The operation was not retried. Inspect the Windows Recycle Bin before any further action." : "");
                }
            }, sequential: exclusive);
            return result;
        }
        finally
        {
            foreach (var root in roots) root?.Dispose();
            foreach (var parent in parents) parent?.Dispose();
        }
    }

    private static bool SameRecordlessObject(MoveEntryIdentity expected, MoveEntryIdentity actual)
        => expected.VolumeSerialNumber == actual.VolumeSerialNumber && expected.FileId.Equals(actual.FileId, StringComparison.OrdinalIgnoreCase)
            && expected.IsDirectory == actual.IsDirectory && expected.ReparseTag == actual.ReparseTag;
}
