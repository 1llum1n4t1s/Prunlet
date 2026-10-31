using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

// 待機前の実体をメモリー内だけで保持する。削除や再送、待機そのものは行わない。
// 名前空間全体の原子的なsnapshotではなく、削除開始直前の既存検査も引き続き必要。
internal sealed class DeferredDeletePreflight : IDisposable
{
    // 永続化や無制限のhandle取得へ退避せず、大きすぎる木は安全側に拒否する。
    internal const int MaximumEntries = 4096;
    private readonly List<Entry> entries = [];
    private bool disposed;

    internal int EntryCount => entries.Count;

    // 削除pendingを同じ実体へ設定した後にだけ解放する。通常削除は全handleのcloseまで確定しない。
    internal void ReleaseDeletedEntry(string path)
    {
        var entry = entries.Skip(1).FirstOrDefault(item => item.Path.Equals(path, StringComparison.Ordinal));
        if (entry is null) throw new IOException("Deleted entry was not present in the queued snapshot.");
        entry.Handle.Dispose();
    }

    private sealed record Entry(string Path, SafeFileHandle Handle, MoveEntryIdentity Identity,
        byte[]? Reparse, bool EnumerateChildren, long? DirectoryChangeTime)
    {
        internal string[] Children { get; set; } = [];
    }

    private DeferredDeletePreflight() { }

    // pathは呼出し元が検証済みの絶対canonical path。親も保持して待機中の変更を検出する。
    // 共有違反時もこのsnapshotを使い続け、待機後にCaptureし直して変更を受け入れない。
    internal static DeferredDeletePreflight Capture(string path, bool recursive)
    {
        var snapshot = new DeferredDeletePreflight();
        try
        {
            snapshot.Add(Path.GetDirectoryName(path) ?? throw new IOException("Deletion target has no parent."), false);
            snapshot.Add(path, true);
            for (var index = 1; index < snapshot.entries.Count; index++)
            {
                var entry = snapshot.entries[index];
                if (!entry.EnumerateChildren) continue;
                using var parents = PathPolicy.PinDirectories(entry.Path);
                snapshot.VerifyEntry(entry);
                entry.Children = snapshot.ReadChildren(entry.Path);
                if (!recursive && entry.Children.Length != 0)
                    throw new IOException("A nonrecursive deletion directory is not empty.");
                foreach (var child in entry.Children) snapshot.Add(child, recursive);
            }
            snapshot.VerifyUnchanged();
            return snapshot;
        }
        catch { snapshot.Dispose(); throw; }
    }

    // DELETE handleは一度に一つだけ取得する。共有hardlinkを複数固定して自己競合しない。
    // 他のOpenRecordlessPreflight handleを保持する前に実行すること。
    // native 32/33を含む元例外は、そのまま呼出し元の待機判定へ渡す。
    internal void Probe()
    {
        VerifyUnchanged();
        foreach (var entry in entries.Skip(1))
        {
            using var parents = PinParent(entry.Path);
            using var probe = NativeFiles.OpenRecordlessPreflight(entry.Path);
            VerifyHandle(entry, probe);
        }
        VerifyUnchanged();
    }

    internal void VerifyUnchanged()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        foreach (var entry in entries)
        {
            using var parents = PinParent(entry.Path);
            VerifyEntry(entry);
            if (!entry.EnumerateChildren) continue;
            // 列挙対象自体も固定してから列挙し、途中でlinkへ差し替えられても辿らない。
            using var directory = PathPolicy.PinDirectories(entry.Path);
            VerifyEntry(entry);
            if (!entry.Children.SequenceEqual(ReadChildren(entry.Path), StringComparer.Ordinal))
                throw new IOException($"Deletion directory membership changed while waiting: {entry.Path}");
        }
    }

    private void Add(string path, bool recursive)
    {
        if (entries.Count >= MaximumEntries)
            throw new IOException($"Deferred deletion preflight exceeds its {MaximumEntries}-entry limit.");
        using var parents = PinParent(path);
        var handle = NativeFiles.OpenShellInspection(path);
        try
        {
            var identity = NativeFiles.MoveIdentity(handle);
            if (identity.VolumeSerialNumber == 0 || identity.FileId.Length != 32
                || identity.FileId.All(c => c == '0') || identity.FileId.All(c => c is 'F' or 'f')
                || ((identity.Attributes & (uint)FileAttributes.ReparsePoint) != 0) != (identity.ReparseTag != 0))
                throw new IOException($"Deletion preflight identity is unavailable: {path}");
            byte[]? reparse = identity.ReparseTag == 0 ? null : NativeFiles.ReadReparse(handle);
            if (reparse is not null && NativeFiles.ValidateReparse(reparse) != identity.ReparseTag)
                throw new IOException($"Deletion preflight reparse metadata differs: {path}");
            var entry = new Entry(path, handle, identity, reparse,
                recursive && identity.IsDirectory && identity.ReparseTag == 0,
                recursive && identity.IsDirectory && identity.ReparseTag == 0 ? NativeFiles.PinnedChangeTime(handle) : null);
            VerifyHandle(entry, handle);
            entries.Add(entry);
        }
        catch { handle.Dispose(); throw; }
    }

    private void VerifyEntry(Entry entry)
    {
        VerifyHandle(entry, entry.Handle);
        using var current = NativeFiles.OpenShellInspection(entry.Path);
        VerifyHandle(entry, current);
    }

    private static void VerifyHandle(Entry entry, SafeFileHandle handle)
    {
        if (NativeFiles.MoveIdentity(handle) != entry.Identity
            || !NativeFiles.FinalPath(handle).Equals(entry.Path, StringComparison.Ordinal)
            || (entry.DirectoryChangeTime is long changeTime && NativeFiles.PinnedChangeTime(handle) != changeTime))
            throw new IOException($"Deletion target identity, parent, name or attributes changed while waiting: {entry.Path}");
        if (entry.Reparse is not null)
        {
            if (!entry.Reparse.AsSpan().SequenceEqual(NativeFiles.ReadReparse(handle)))
                throw new IOException($"Deletion link metadata changed while waiting: {entry.Path}");
        }
        else
        {
            NativeFiles.Verify(handle, entry.Path, entry.Identity.IsDirectory);
            if (entry.Identity.IsDirectory) NativeFiles.RejectCaseSensitive(handle);
        }
    }

    private static DirectoryLease PinParent(string path)
        => PathPolicy.PinDirectories(Path.GetDirectoryName(path) ?? path);

    private string[] ReadChildren(string path)
    {
        var children = new List<string>();
        foreach (var child in Directory.EnumerateFileSystemEntries(path))
        {
            if (children.Count >= MaximumEntries)
                throw new IOException($"Deferred deletion preflight exceeds its {MaximumEntries}-entry limit.");
            children.Add(child);
        }
        children.Sort(StringComparer.Ordinal);
        return children.ToArray();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var entry in entries) entry.Handle.Dispose();
        entries.Clear();
    }
}
