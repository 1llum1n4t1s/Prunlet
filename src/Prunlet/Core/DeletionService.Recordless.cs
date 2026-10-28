using System.Collections.Concurrent;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    internal static event Action<string, string>? OversizedDeleteCheckpoint;

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
        var inspections = new SafeFileHandle?[paths.Length];
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
                    if (!UsableRecordlessIdentity(parentIdentities[index]!)) throw new IOException("Recycle parent identity is unavailable.");
                    // 後続の名前固定handleを解放しても、元のFILE_IDを再利用させない。
                    var inspection = NativeFiles.OpenShellInspection(path); inspections[index] = inspection;
                    var identity = NativeFiles.MoveIdentity(inspection);
                    if (!UsableRecordlessIdentity(identity) || !UsableRecordlessIdentity(current)
                        || !SameRecordlessObject(identity, current))
                        throw new IOException("Recycle source identity changed or is unavailable during preflight.");
                    if (identity.ReparseTag == 0) NativeFiles.Verify(inspection, path, identity.IsDirectory);
                    else if (!NativeFiles.FinalPath(inspection).Equals(path, StringComparison.Ordinal))
                        throw new IOException("Recycle link root resolved to another path.");
                    if (identity.ReparseTag != 0 && NativeFiles.ValidateReparse(NativeFiles.ReadReparse(inspection)) != identity.ReparseTag)
                        throw new IOException("Recycle source reparse metadata differs.");
                    identities[index] = identity;
                    item.Kind = identity.ReparseTag switch { 0 => identity.IsDirectory ? "directory" : "file", 0xa0000003 => "junction", 0xa000000c => "symlink", _ => throw new IOException("Unsupported reparse point.") };
                    if (identity.IsDirectory && identity.ReparseTag == 0 && !recursive && Directory.EnumerateFileSystemEntries(path).Any())
                        throw new ArgumentException("Nonempty directories require explicit recursive deletion.");
                    needsExclusive[index] = !identity.IsDirectory && NativeFiles.HasMultipleLinks(inspection);
                    if (!exclusive && needsExclusive[index]) { item.Status = "would_recycle"; return; }
                    var root = NativeFiles.OpenRecordlessPreflight(path); roots[index] = root;
                    var fixedIdentity = NativeFiles.MoveIdentity(root);
                    if (!SameRecordlessObject(identity, fixedIdentity) || fixedIdentity.Attributes != identity.Attributes)
                        throw new IOException("Recycle source identity changed while fixing its name.");
                    VerifyPermanentHandle(root, path, fixedIdentity);
                    // 同一実体の別aliasもpreflightできるよう、排他batchは各rootを順に解放する。
                    if (exclusive) { root.Dispose(); roots[index] = null; }
                    item.Status = "would_recycle";
                }
                catch (Exception ex) when (IsRecycleFailure(ex)) { item.Error = ex.Message; }
            }, sequential: exclusive);
            if (!exclusive && needsExclusive.Any(value => value)) return null;
            if (dryRun)
            {
                if (result.Items.Any(item => item.Status == "would_recycle"))
                    result.Warnings.Add("Dry-run cannot determine whether Windows will recycle an item; an oversized file or directory may be permanently deleted.");
                return result;
            }
            if (result.Items.Any(item => item.Status == "failed"))
                throw new IOException("Deletion preflight failed; original targets were retained. " + string.Join(" ", result.Items.Where(item => item.Error is not null).Select(item => item.Error)));
            // Shellを全件試した後、容量超過だけを固定削除する。同じbatchのShellと固定削除を重ねない。
            using var oversizedHardlinks = new OversizedHardlinkState();
            var oversized = new bool[paths.Length];
            DeletionWorkers.For(paths.Length, index =>
            {
                var item = result.Items[index];
                if (item.Status == "already_absent") return;
                var started = false;
                var identity = identities[index]!;
                var fileKey = (identity.VolumeSerialNumber, identity.FileId);
                var trackHardlink = exclusive && needsExclusive[index] && !identity.IsDirectory && identity.ReparseTag == 0;
                try
                {
                    roots[index]?.Dispose();
                    // FILE_IDの再利用を避け、Shell処理中も元の実体を共有handleで保持する。
                    var original = inspections[index] ?? throw new IOException("Recycle source inspection was not retained.");
                    var held = NativeFiles.MoveIdentity(original);
                    if (!SameRecordlessObject(identity, held) || held.Attributes != identity.Attributes)
                        throw new IOException("Recycle source identity or attributes changed before Shell processing.");
                    if (trackHardlink && oversizedHardlinks.Uncertain.ContainsKey(fileKey))
                        throw new IOException("A prior hardlink deletion could not be confirmed.");
                    string? recycledPath = null;
                    var recycled = NativeRecycleBin.RecycleDeleteTarget(item.Path, identity.IsDirectory && identity.ReparseTag == 0, resolved =>
                    {
                        if (!resolved.Equals(item.Path, StringComparison.Ordinal)) throw new IOException("Shell resolved a different recycle source path.");
                        CheckRecycleTarget(item.Path, identity.IsDirectory);
                        using var parent = NativeFiles.OpenDirectory(Path.GetDirectoryName(item.Path)!);
                        if (!SameRecordlessObject(parentIdentities[index]!, NativeFiles.MoveIdentity(parent))) throw new IOException("Recycle parent identity changed.");
                        using var source = NativeFiles.OpenShellInspection(item.Path);
                        var current = NativeFiles.MoveIdentity(source);
                        if (!SameRecordlessObject(identity, current) || current.Attributes != identity.Attributes)
                            throw new IOException("Recycle source identity or attributes changed.");
                        if (current.ReparseTag != 0) _ = NativeFiles.ReadReparse(source);
                        if (!recursive && current.IsDirectory && current.ReparseTag == 0
                            && Directory.EnumerateFileSystemEntries(item.Path).Any())
                            throw new IOException("A nonrecursive directory is no longer empty.");
                        started = true;
                    }, path =>
                    {
                        VerifyRecycledObject(path, identity);
                        recycledPath = path;
                    });
                    if (!recycled)
                    {
                        OversizedDeleteCheckpoint?.Invoke("oversize-reported", item.Path);
                        oversized[index] = true;
                        return;
                    }
                    if (trackHardlink)
                    {
                        oversizedHardlinks.Uncertain.TryAdd(fileKey, 0);
                        RetainRecycledHardlink(oversizedHardlinks, identity, recycledPath!);
                    }
                    original.Dispose();
                    if (InspectMoveLocation(item.Path) is not null) throw new IOException("A source name is still present after the Windows deletion attempt.");
                    if (trackHardlink)
                    {
                        oversizedHardlinks.Changed[fileKey] = NativeFiles.PinnedChangeTime(oversizedHardlinks.Guards[fileKey]);
                        oversizedHardlinks.Uncertain.TryRemove(fileKey, out _);
                    }
                    item.Status = "recycled";
                }
                catch (Exception ex) when (IsRecycleFailure(ex))
                {
                    inspections[index]?.Dispose();
                    if (started && trackHardlink) oversizedHardlinks.Uncertain.TryAdd(fileKey, 0);
                    item.Status = started ? "ambiguous" : "failed";
                    item.Error = ex.Message + (started ? " The operation was not retried. Inspect the Windows Recycle Bin and the source before any further action." : "");
                }
            }, sequential: exclusive);
            // Shellが全件終わってから容量超過を処理し、同一実体だけを排他する。
            DeletionWorkers.For(paths.Length, index =>
            {
                if (!oversized[index]) return;
                var item = result.Items[index];
                try
                {
                    using var original = inspections[index] ?? throw new IOException("Recycle source inspection was not retained.");
                    DeleteOversizedTarget(item.Path, identities[index]!, parentIdentities[index]!, original, recursive, oversizedHardlinks);
                    original.Dispose();
                    if (InspectMoveLocation(item.Path) is not null) throw new IOException("A source name is still present after the Windows deletion attempt.");
                    item.Status = "permanently_deleted";
                }
                catch (Exception ex) when (IsRecycleFailure(ex))
                {
                    item.Status = "ambiguous";
                    item.Error = ex.Message + " Some entries may already have been permanently deleted. The operation was not retried. Inspect the Windows Recycle Bin and the source before any further action.";
                }
            }, sequential: exclusive);
            return result;
        }
        finally
        {
            foreach (var root in roots) root?.Dispose();
            foreach (var inspection in inspections) inspection?.Dispose();
            foreach (var parent in parents) parent?.Dispose();
        }
    }

    private static bool SameRecordlessObject(MoveEntryIdentity expected, MoveEntryIdentity actual)
        => expected.VolumeSerialNumber == actual.VolumeSerialNumber && expected.FileId.Equals(actual.FileId, StringComparison.OrdinalIgnoreCase)
            && expected.IsDirectory == actual.IsDirectory && expected.ReparseTag == actual.ReparseTag;

    private static bool UsableRecordlessIdentity(MoveEntryIdentity identity)
        => ValidMoveIdentity(identity) && !identity.FileId.All(character => character is 'F' or 'f');

    private static void VerifyRecycledObject(string path, MoveEntryIdentity expected)
    {
        using var recycledItem = NativeFiles.OpenShellInspection(path);
        VerifyRecycledObject(recycledItem, expected);
    }

    private static void VerifyRecycledObject(SafeFileHandle recycledItem, MoveEntryIdentity expected)
    {
        var actual = NativeFiles.MoveIdentity(recycledItem);
        if (!UsableRecordlessIdentity(expected) || !UsableRecordlessIdentity(actual) || !SameRecordlessObject(expected, actual))
            throw new IOException("The recycled object identity differs from the preflight source or cannot be verified.");
    }

    private static void RetainRecycledHardlink(OversizedHardlinkState hardlinks, MoveEntryIdentity expected, string recycledPath)
    {
        var key = (expected.VolumeSerialNumber, expected.FileId);
        if (!hardlinks.Guards.TryGetValue(key, out var guard))
        {
            guard = NativeFiles.OpenShellInspection(recycledPath);
            try
            {
                if (!SameRecordlessObject(expected, NativeFiles.MoveIdentity(guard)))
                    throw new IOException("Recycled hardlink identity changed.");
                if (!hardlinks.Guards.TryAdd(key, guard)) throw new IOException("Recycled hardlink guard already exists.");
                hardlinks.Recycled.TryAdd(key, 0);
            }
            catch { guard.Dispose(); throw; }
        }
        if (!SameRecordlessObject(expected, NativeFiles.MoveIdentity(guard)))
            throw new IOException("Retained hardlink identity changed.");
    }

    private void DeleteOversizedTarget(string path, MoveEntryIdentity expected, MoveEntryIdentity expectedParent, SafeFileHandle original, bool recursive, OversizedHardlinkState hardlinks)
    {
        CheckRecycleTarget(path, expected.IsDirectory);
        using var parent = NativeFiles.OpenDirectory(Path.GetDirectoryName(path)!);
        NativeFiles.Verify(parent, Path.GetDirectoryName(path)!, directory: true);
        var currentParent = NativeFiles.MoveIdentity(parent);
        if (!UsableRecordlessIdentity(expectedParent) || !UsableRecordlessIdentity(currentParent)
            || !SameRecordlessObject(expectedParent, currentParent))
            throw new IOException("Oversized target parent identity changed or is unavailable.");
        var held = NativeFiles.MoveIdentity(original);
        if (!UsableRecordlessIdentity(expected) || !UsableRecordlessIdentity(held)
            || !SameRecordlessObject(expected, held) || held.Attributes != expected.Attributes
            || !NativeFiles.FinalPath(original).Equals(path, StringComparison.Ordinal))
            throw new IOException("Oversized target identity, path, or attributes changed.");
        using var rootLease = !expected.IsDirectory && expected.ReparseTag == 0
            ? hardlinks.Hold((expected.VolumeSerialNumber, expected.FileId)) : null;
        using var pinned = expected.IsDirectory && expected.ReparseTag == 0
            ? NativeFiles.OpenPermanentDirectory(path) : NativeFiles.OpenRecordlessPreflight(path);
        var current = NativeFiles.MoveIdentity(pinned);
        if (!UsableRecordlessIdentity(current) || !SameRecordlessObject(held, current)
            || current.Attributes != held.Attributes)
            throw new IOException("Oversized target changed before its name could be fixed.");
        VerifyPermanentHandle(pinned, path, current);
        DeletePinnedOversized(pinned, path, current, recursive, hardlinks);
    }

    private static void VerifyPermanentHandle(SafeFileHandle handle, string path, MoveEntryIdentity identity)
    {
        if (identity.ReparseTag == 0) NativeFiles.Verify(handle, path, identity.IsDirectory);
        else if (!NativeFiles.FinalPath(handle).Equals(path, StringComparison.Ordinal)
            || NativeFiles.ValidateReparse(NativeFiles.ReadReparse(handle)) != identity.ReparseTag)
            throw new IOException("Oversized link identity or reparse data changed.");
    }

    private static void DeletePinnedOversized(SafeFileHandle handle, string path, MoveEntryIdentity identity, bool recursive, OversizedHardlinkState hardlinks)
    {
        var stack = new Stack<PermanentDeleteFrame>();
        stack.Push(new(handle, path, identity, ownsHandle: false));
        try
        {
            while (stack.TryPeek(out var frame))
            {
                if (frame.Entries is null)
                {
                    // 固定した親から列挙し、開いた子のIDと時刻を再照合する。
                    frame.Entries = frame.Identity.IsDirectory && frame.Identity.ReparseTag == 0
                        ? NativeFiles.ReadPinnedDirectory(frame.Handle) : [];
                    if (stack.Count == 1 && !recursive && frame.Entries.Count != 0)
                        throw new IOException("A nonrecursive oversized directory is no longer empty.");
                }
                if (frame.Next < frame.Entries.Count)
                {
                    var entry = frame.Entries[frame.Next++];
                    var childPath = PathPolicy.FileSystemAbsolute(Path.Combine(frame.Path, entry.Name));
                    if (!PathPolicy.Within(childPath, frame.Path) || childPath.Equals(frame.Path, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("Oversized directory entry escaped its fixed parent.");
                    var isDirectory = (entry.Attributes & (uint)FileAttributes.Directory) != 0;
                    var lease = !isDirectory && entry.ReparseTag == 0
                        ? hardlinks.Hold((frame.Identity.VolumeSerialNumber, entry.FileId)) : null;
                    SafeFileHandle child;
                    try
                    {
                        child = isDirectory && entry.ReparseTag == 0
                            ? NativeFiles.OpenPermanentDirectory(childPath) : NativeFiles.OpenRecordlessPreflight(childPath);
                    }
                    catch (Exception ex) when (IsRecycleFailure(ex))
                    {
                        lease?.Dispose();
                        OversizedDeleteCheckpoint?.Invoke("child-open-failed", childPath);
                        throw;
                    }
                    catch { lease?.Dispose(); throw; }
                    try
                    {
                        OversizedDeleteCheckpoint?.Invoke("child-pinned", childPath);
                        var current = NativeFiles.MoveIdentity(child);
                        if (!UsableRecordlessIdentity(current) || current.VolumeSerialNumber != frame.Identity.VolumeSerialNumber
                            || !current.FileId.Equals(entry.FileId, StringComparison.OrdinalIgnoreCase)
                            || current.Attributes != entry.Attributes || current.ReparseTag != entry.ReparseTag)
                            throw new IOException("Oversized directory entry changed after enumeration.");
                        var key = (current.VolumeSerialNumber, current.FileId);
                        if (hardlinks.Uncertain.ContainsKey(key))
                            throw new IOException("A prior hardlink deletion could not be confirmed.");
                        if (!hardlinks.CanContinueInRoot(key, path))
                            throw new IOException("A shared hardlink without a retained write guard cannot continue in another root.");
                        var ownLinkChange = hardlinks.Changed.TryGetValue(key, out var changeTime);
                        if (ownLinkChange && (!hardlinks.Guards.TryGetValue(key, out var guard)
                            || !SameRecordlessObject(current, NativeFiles.MoveIdentity(guard))))
                            throw new IOException("A shared hardlink identity could not be retained.");
                        var verifiedTimes = NativeFiles.VerifyPinnedEntryTimes(child, entry, ownLinkChange ? changeTime : null);
                        VerifyPermanentHandle(child, childPath, current);
                        stack.Push(new(child, childPath, current, ownsHandle: true) { VerifiedChangeTime = verifiedTimes.ChangeTime, VerifiedLastWriteTime = verifiedTimes.LastWriteTime, Lease = lease });
                        lease = null;
                    }
                    catch { child.Dispose(); lease?.Dispose(); throw; }
                    continue;
                }
                var ordinaryFile = !frame.Identity.IsDirectory && frame.Identity.ReparseTag == 0;
                var fileKey = (frame.Identity.VolumeSerialNumber, frame.Identity.FileId);
                if (ordinaryFile && hardlinks.Uncertain.ContainsKey(fileKey))
                    throw new IOException("A prior hardlink deletion could not be confirmed.");
                if (ordinaryFile) hardlinks.UpgradeRecycledGuard(fileKey, frame.Path);
                if (ordinaryFile && !hardlinks.CanContinueInRoot(fileKey, path))
                    throw new IOException("A shared hardlink without a retained write guard cannot continue in another root.");
                if (ordinaryFile && hardlinks.Changed.TryGetValue(fileKey, out var priorChange)
                    && (!hardlinks.Guards.TryGetValue(fileKey, out var retained)
                        || !SameRecordlessObject(frame.Identity, NativeFiles.MoveIdentity(retained))
                        || NativeFiles.PinnedChangeTime(frame.Handle) != priorChange))
                    throw new IOException("The retained hardlink changed after a prior deletion.");
                if (ordinaryFile && NativeFiles.HasMultipleLinks(frame.Handle)
                    && !hardlinks.Guards.ContainsKey(fileKey))
                {
                    var guard = OpenHardlinkGuard(frame.Path);
                    var unprotected = guard is null;
                    guard ??= NativeFiles.OpenShellInspection(frame.Path);
                    try
                    {
                        if (!SameRecordlessObject(frame.Identity, NativeFiles.MoveIdentity(guard)))
                            throw new IOException("Hardlink identity changed before deletion.");
                        if (!hardlinks.Guards.TryAdd(fileKey, guard)) throw new IOException("Hardlink guard already exists.");
                        if (unprotected || !hardlinks.RetainStreams(fileKey, frame.Path, guard))
                            hardlinks.MarkUnprotected(fileKey, path);
                    }
                    catch
                    {
                        hardlinks.Guards.TryRemove(fileKey, out _);
                        hardlinks.Uncertain.TryAdd(fileKey, 0);
                        guard.Dispose();
                        throw;
                    }
                }
                var posix = ordinaryFile && hardlinks.Guards.ContainsKey(fileKey);
                // DELETE非共有の同じhandleにだけ設定する。別pathやShellへ再送しない。
                var verifiedTime = frame.VerifiedChangeTime ?? (posix ? NativeFiles.PinnedChangeTime(frame.Handle) : 0);
                var verifiedWriteTime = frame.VerifiedLastWriteTime ?? (posix ? NativeFiles.PinnedLastWriteTime(frame.Handle) : 0);
                if (posix)
                {
                    hardlinks.Uncertain.TryAdd(fileKey, 0);
                    if (verifiedTime == 0 || NativeFiles.PinnedChangeTime(frame.Handle) != verifiedTime
                        || NativeFiles.PinnedLastWriteTime(frame.Handle) != verifiedWriteTime)
                        throw new IOException("A hardlink changed before deletion.");
                }
                NativeFiles.SetPermanentDeletePending(frame.Handle, posix);
                if (posix) OversizedDeleteCheckpoint?.Invoke("hardlink-pending", frame.Path);
                if (posix && (NativeFiles.PinnedChangeTime(hardlinks.Guards[fileKey]) != verifiedTime
                    || NativeFiles.PinnedLastWriteTime(hardlinks.Guards[fileKey]) != verifiedWriteTime
                    || !hardlinks.StreamsMatch(fileKey)))
                    throw new IOException("A hardlink changed while its deletion was pending.");
                stack.Pop();
                try
                {
                    if (frame.OwnsHandle || posix)
                    {
                        frame.Handle.Dispose();
                        if (InspectMoveLocation(frame.Path) is not null)
                            throw new IOException("An oversized directory entry is still present after deletion.");
                    }
                    if (posix)
                    {
                        OversizedDeleteCheckpoint?.Invoke("hardlink-unlinked", frame.Path);
                        var guard = hardlinks.Guards[fileKey];
                        var retainedIdentity = NativeFiles.MoveIdentity(guard);
                        if (!SameRecordlessObject(frame.Identity, retainedIdentity) || retainedIdentity.Attributes != frame.Identity.Attributes
                            || NativeFiles.PinnedLastWriteTime(guard) != verifiedWriteTime || !hardlinks.StreamsMatch(fileKey))
                            throw new IOException("A retained hardlink changed while its deletion was completed.");
                        hardlinks.Changed[fileKey] = NativeFiles.PinnedChangeTime(guard);
                        hardlinks.Uncertain.TryRemove(fileKey, out _);
                    }
                }
                finally { frame.Lease?.Dispose(); }
            }
        }
        finally
        {
            foreach (var frame in stack)
            {
                if (frame.OwnsHandle) frame.Handle.Dispose();
                frame.Lease?.Dispose();
            }
        }
    }

    private static SafeFileHandle? OpenHardlinkGuard(string path)
    {
        try { return NativeFiles.OpenHardlinkExecuteGuard(path); }
        catch (IOException ex) when (ex.InnerException is System.ComponentModel.Win32Exception { NativeErrorCode: 5 })
        {
            try { return NativeFiles.OpenHardlinkReadGuard(path); }
            catch (IOException denied) when (denied.InnerException is System.ComponentModel.Win32Exception { NativeErrorCode: 5 })
            { return null; }
        }
    }

    // 同一実体の固定削除を排他し、共有実体の同一性と時刻を追跡する。
    private sealed class OversizedHardlinkState : IDisposable
    {
        internal ConcurrentDictionary<(ulong Volume, string FileId), SafeFileHandle> Guards { get; } = new();
        internal ConcurrentDictionary<(ulong Volume, string FileId), long> Changed { get; } = new();
        internal ConcurrentDictionary<(ulong Volume, string FileId), byte> Uncertain { get; } = new();
        internal ConcurrentDictionary<(ulong Volume, string FileId), byte> Recycled { get; } = new();
        private readonly ConcurrentDictionary<(ulong Volume, string FileId), string> unprotectedRoots = new();
        private readonly ConcurrentDictionary<(ulong Volume, string FileId), List<SafeFileHandle>> streamGuards = new();
        private readonly ConcurrentDictionary<(ulong Volume, string FileId), List<string>> streamNames = new();
        private readonly object[] stripes = Enumerable.Range(0, 256).Select(_ => new object()).ToArray();

        internal IDisposable Hold((ulong Volume, string FileId) key)
        {
            var stripe = stripes[(int)((uint)key.GetHashCode() % (uint)stripes.Length)];
            Monitor.Enter(stripe);
            return new StripeLease(stripe);
        }

        private sealed class StripeLease(object stripe) : IDisposable
        {
            private object? held = stripe;
            public void Dispose()
            {
                var current = Interlocked.Exchange(ref held, null);
                if (current is not null) Monitor.Exit(current);
            }
        }

        internal bool RetainStreams((ulong Volume, string FileId) key, string path, SafeFileHandle guard)
        {
            var retained = new List<SafeFileHandle>();
            try
            {
                var names = NativeFiles.NamedStreams(guard);
                foreach (var name in names)
                {
                    SafeFileHandle stream;
                    try { stream = NativeFiles.OpenHardlinkStreamGuard(path, name, execute: true); }
                    catch (IOException ex) when (ex.InnerException is System.ComponentModel.Win32Exception { NativeErrorCode: 5 })
                    { stream = NativeFiles.OpenHardlinkStreamGuard(path, name, execute: false); }
                    retained.Add(stream);
                    if (!SameRecordlessObject(NativeFiles.MoveIdentity(guard), NativeFiles.MoveIdentity(stream)))
                        throw new IOException("An alternate hardlink stream changed identity.");
                }
                if (!names.SequenceEqual(NativeFiles.NamedStreams(guard), StringComparer.Ordinal))
                    throw new IOException("The alternate hardlink streams changed while being retained.");
                if (!streamGuards.TryAdd(key, retained)) throw new IOException("Hardlink stream guard already exists.");
                if (!streamNames.TryAdd(key, names))
                {
                    streamGuards.TryRemove(key, out _);
                    throw new IOException("Hardlink stream names already exist.");
                }
                retained = [];
                return true;
            }
            catch (IOException ex) when (ex.InnerException is System.ComponentModel.Win32Exception) { return false; }
            catch (InvalidDataException) { return false; }
            finally { foreach (var stream in retained) stream.Dispose(); }
        }

        internal void MarkUnprotected((ulong Volume, string FileId) key, string root)
        {
            unprotectedRoots.TryAdd(key, root);
        }

        internal bool CanContinueInRoot((ulong Volume, string FileId) key, string root)
            => !unprotectedRoots.TryGetValue(key, out var origin) || origin.Equals(root, StringComparison.Ordinal);

        internal bool StreamsMatch((ulong Volume, string FileId) key)
            => unprotectedRoots.ContainsKey(key) || (streamNames.TryGetValue(key, out var names)
                && names.SequenceEqual(NativeFiles.NamedStreams(Guards[key]), StringComparer.Ordinal));
        internal void UpgradeRecycledGuard((ulong Volume, string FileId) key, string path)
        {
            if (!Recycled.ContainsKey(key)) return;
            SafeFileHandle? candidate = null;
            try
            {
                if (!Changed.TryGetValue(key, out var expectedTime)) throw new IOException("Recycled hardlink time is unavailable.");
                var original = Guards[key];
                candidate = OpenHardlinkGuard(path);
                if (candidate is null)
                {
                    if (NativeFiles.PinnedChangeTime(original) != expectedTime)
                        throw new IOException("Recycled hardlink changed before fixed deletion.");
                    MarkUnprotected(key, "");
                }
                else
                {
                    var identity = NativeFiles.MoveIdentity(candidate);
                    var originalIdentity = NativeFiles.MoveIdentity(original);
                    if (identity.VolumeSerialNumber != key.Volume || identity.FileId != key.FileId
                        || !SameRecordlessObject(originalIdentity, identity) || originalIdentity.Attributes != identity.Attributes
                        || NativeFiles.PinnedChangeTime(original) != expectedTime
                        || NativeFiles.PinnedChangeTime(candidate) != expectedTime)
                        throw new IOException("Recycled hardlink changed before fixed deletion.");
                    if (!RetainStreams(key, path, candidate)) MarkUnprotected(key, "");
                    else { Guards[key] = candidate; candidate = null; original.Dispose(); }
                }
                Recycled.TryRemove(key, out _);
            }
            catch (Exception ex) when (IsRecycleFailure(ex)) { Uncertain.TryAdd(key, 0); throw; }
            finally { candidate?.Dispose(); }
        }
        public void Dispose()
        {
            foreach (var group in streamGuards.Values) foreach (var guard in group) guard.Dispose();
            foreach (var guard in Guards.Values) guard.Dispose();
        }
    }

    private sealed class PermanentDeleteFrame(SafeFileHandle handle, string path, MoveEntryIdentity identity, bool ownsHandle)
    {
        internal SafeFileHandle Handle { get; } = handle;
        internal string Path { get; } = path;
        internal MoveEntryIdentity Identity { get; } = identity;
        internal bool OwnsHandle { get; } = ownsHandle;
        internal long? VerifiedChangeTime { get; init; }
        internal long? VerifiedLastWriteTime { get; init; }
        internal IDisposable? Lease { get; init; }
        internal IReadOnlyList<PinnedDirectoryEntry>? Entries { get; set; }
        internal int Next { get; set; }
    }
}
