using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static class PathPolicy
{
    internal static string Absolute(string? value)
    {
        // 拡張長形式も通常のローカルドライブに限り、同じ構文検査へ通す。
        if (value?.StartsWith(@"\\?\", StringComparison.Ordinal) == true) value = value[4..];
        value = value?.Replace('/', '\\');
        if (string.IsNullOrWhiteSpace(value) || value.Length < 3 || !char.IsAsciiLetter(value[0])
            || value[1] != ':' || value[2] != '\\'
            || value.AsSpan(2).Contains(':') || value.IndexOfAny(['*', '?', '\0']) >= 0)
            throw new ArgumentException("Use an absolute local drive path without wildcards, ADS, UNC, or device syntax.");
        var path = value.TrimEnd('\\');
        if (path.Length == 2) path += "\\";
        foreach (var component in path[3..].Split('\\', StringSplitOptions.None))
        {
            if (path.Length == 3) break;
            if (component.Length == 0 || component is "." or ".." || component.EndsWith('.') || component.EndsWith(' ')
                || component.IndexOfAny(['<', '>', '"', '|']) >= 0 || component.Any(char.IsControl))
                throw new ArgumentException("Path components cannot contain traversal, empty components, invalid characters, or trailing dots/spaces.");
            var stem = component.Split('.')[0].ToUpperInvariant();
            if (stem is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$"
                || (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal))
                    && "123456789¹²³".Contains(stem[3])))
                throw new ArgumentException("Device names are not allowed.");
        }
        return Path.GetFullPath(path);
    }

    internal static bool Within(string path, string root) => path.Equals(root, StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);

    internal static void ExistingDirectory(string path)
    {
        var actual = Resolve(path, finalDirectory: true, allowMissing: false);
        using var directories = PinDirectories(actual);
        foreach (var handle in directories.Handles) NativeFiles.RejectCaseSensitive(handle);
    }

    // 入力の全祖先と、ハンドルが示す実体の全祖先を固定してから実体パスを返す。
    // 欠損対象は最後に確認できた実体の親へ連結し、短縮名やホスト転送を引き継がない。
    internal static string Resolve(string path, bool finalDirectory = false, bool allowMissing = true)
    {
        path = Absolute(path);
        var components = Components(path).ToArray();
        using var lease = new DirectoryLease();
        var pinned = new HashSet<string>(StringComparer.Ordinal);
        var actual = path[..3];
        for (var i = 0; i < components.Length; i++)
        {
            var directory = i != components.Length - 1 || finalDirectory;
            SafeFileHandle handle;
            try { handle = directory ? NativeFiles.OpenDirectory(components[i]) : NativeFiles.OpenInspect(components[i]); }
            catch (Exception ex) when (allowMissing && ex is FileNotFoundException or DirectoryNotFoundException)
            {
                if (i == 0) throw;
                foreach (var suffix in components.Skip(i)) actual = Path.Combine(actual, Path.GetFileName(suffix));
                return actual;
            }
            lease.Handles.Add(handle);
            actual = NativeFiles.ResolveVerified(handle, directory);
            var parent = directory ? actual : Path.GetDirectoryName(actual)!;
            foreach (var ancestor in Components(parent))
            {
                if (!pinned.Add(ancestor)) continue;
                var canonicalHandle = NativeFiles.OpenDirectory(ancestor);
                lease.Handles.Add(canonicalHandle);
                NativeFiles.Verify(canonicalHandle, ancestor, directory: true);
            }
        }
        return actual;
    }

    // OPEN_REPARSE_POINT と削除共有を許さない親ハンドルで、検査後の差し替えを阻止する。
    internal static DirectoryLease PinDirectories(string path)
    {
        var lease = new DirectoryLease();
        try
        {
            foreach (var ancestor in Components(path))
            {
                var handle = NativeFiles.OpenDirectory(ancestor);
                lease.Handles.Add(handle);
                NativeFiles.Verify(handle, ancestor, directory: true);
            }
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    // 同じ復元範囲で固定済みの祖先を共有し、失敗時は今回の取得分だけを戻す。
    internal static void PinDirectories(string path, DirectoryLease lease, Dictionary<string, SafeFileHandle> pinned)
    {
        var firstHandle = lease.Handles.Count;
        var addedPaths = new List<string>();
        try
        {
            foreach (var ancestor in Components(path))
            {
                if (pinned.TryGetValue(ancestor, out var existing))
                {
                    NativeFiles.Verify(existing, ancestor, directory: true);
                    continue;
                }
                var handle = NativeFiles.OpenDirectory(ancestor);
                lease.Handles.Add(handle);
                NativeFiles.Verify(handle, ancestor, directory: true);
                addedPaths.Add(ancestor);
                pinned.Add(ancestor, handle);
            }
        }
        catch
        {
            for (var i = lease.Handles.Count - 1; i >= firstHandle; i--) lease.Handles[i].Dispose();
            lease.Handles.RemoveRange(firstHandle, lease.Handles.Count - firstHandle);
            foreach (var ancestor in addedPaths) pinned.Remove(ancestor);
            throw;
        }
    }

    internal static DirectoryLease PinRecoveryDirectories(string path)
    {
        var lease = PinDirectories(path);
        try
        {
            foreach (var handle in lease.Handles) NativeFiles.RejectCaseSensitive(handle);
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    private static IEnumerable<string> Components(string path)
    {
        yield return path[..3];
        var current = path[..3];
        foreach (var segment in path[3..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            yield return current;
        }
    }
}

internal sealed class DirectoryLease : IDisposable
{
    internal List<SafeFileHandle> Handles { get; } = [];
    public void Dispose()
    {
        for (var i = Handles.Count - 1; i >= 0; i--) Handles[i].Dispose();
    }
}
