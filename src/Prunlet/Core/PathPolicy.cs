using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static class PathPolicy
{
    internal static string Absolute(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length < 3 || !char.IsAsciiLetter(value[0])
            || value[1] != ':' || value[2] != '\\' || value.Contains('/')
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
        Inspect(path, true);
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException($"Required directory does not exist: {path}");
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

    internal static void Inspect(string path, bool finalDirectory = false)
    {
        var components = Components(path).ToArray();
        for (var i = 0; i < components.Length; i++)
        {
            FileAttributes attributes;
            try { attributes = File.GetAttributes(components[i]); }
            catch (FileNotFoundException) { return; }
            catch (DirectoryNotFoundException) { return; }
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new ArgumentException($"Reparse points are not allowed: {components[i]}");
            var expectDirectory = i != components.Length - 1 || finalDirectory;
            if (((attributes & FileAttributes.Directory) != 0) != expectDirectory)
                throw new ArgumentException(expectDirectory ? "An ancestor is not a directory." : "Only files may be deleted or restored.");
            if (expectDirectory)
            {
                using var handle = NativeFiles.OpenDirectory(components[i]);
                NativeFiles.Verify(handle, components[i], directory: true);
            }
        }
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
