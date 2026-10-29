namespace Prunlet.Core;

// レジストリ保持予算とは別の、更新関連データ全体に対する固定上限。
internal static class StartupUpdateBudget
{
    private const long Limit = 2L * 1024 * 1024 * 1024;
    private const int MaxEntries = 100_000;
    private const int MaxDepth = 64;
    [ThreadStatic] private static Microsoft.Win32.SafeHandles.SafeFileHandle[]? currentGuards;

    internal static IDisposable WithGuards(params Microsoft.Win32.SafeHandles.SafeFileHandle[] guards)
    {
        var previous = currentGuards;
        currentGuards = guards;
        return new GuardScope(previous);
    }

    private sealed class GuardScope(Microsoft.Win32.SafeHandles.SafeFileHandle[]? previous) : IDisposable
    {
        public void Dispose() => currentGuards = previous;
    }

    internal static void Ensure(string root, long additionalBytes)
    {
        if (additionalBytes < 0 || additionalBytes > Limit) throw new ArgumentException("Invalid update allocation size.");
        var used = Measure(root);
        EnsureSnapshot(used, additionalBytes);
    }

    internal static void EnsureSnapshot(long used, long additionalBytes)
    {
        if (used < 0 || additionalBytes < 0 || additionalBytes > Limit) throw new ArgumentException("Invalid update allocation size.");
        if (used > Limit - additionalBytes)
            throw new IOException("The update storage budget is exhausted; existing and unknown data were retained.");
    }

    internal static long Measure(string root)
    {
        long total = 0;
        var count = 0;
        MeasureTreeIfPresent(Path.Combine(root, ".prunlet-update-stage"), ref total, ref count);
        MeasureTreeIfPresent(Path.Combine(root, ".prunlet-update-slots"), ref total, ref count);
        var bin = Path.Combine(root, "bin");
        using var binParents = PathPolicy.PinDirectories(bin);
        foreach (var name in new[] { "prunlet.previous.exe", "prunlet-maintenance.previous.exe", "prunlet-hook.previous.exe",
            "prunlet.candidate.exe", "prunlet-maintenance.candidate.exe", "prunlet-hook.candidate.exe" })
            MeasureFileIfPresent(Path.Combine(bin, name), ref total, ref count);
        foreach (var item in StartupUpdateCoordinator.AuxiliaryProducts)
            MeasureFileIfPresent(Path.Combine(bin, ".prunlet-candidate-" + item.BinName), ref total, ref count);
        foreach (var path in Directory.EnumerateFileSystemEntries(bin))
        {
            var name = Path.GetFileName(path);
            if (System.Text.RegularExpressions.Regex.IsMatch(name,
                @"\Aprunlet(?:-maintenance|-hook)?\.(?:previous|candidate)-[0-9a-f]{32}\.exe\z"))
                MeasureFileIfPresent(path, ref total, ref count);
        }
        MeasureFileIfPresent(Path.Combine(root, "source-info.candidate.json"), ref total, ref count);
        MeasureFileIfPresent(Path.Combine(root, ".prunlet-update-state.json"), ref total, ref count);
        foreach (var path in Directory.EnumerateFileSystemEntries(root))
        {
            var name = Path.GetFileName(path);
            if (System.Text.RegularExpressions.Regex.IsMatch(name, @"\A\.prunlet-update-state\.[0-9a-f]{32}\.pending\z"))
                MeasureFileIfPresent(path, ref total, ref count);
        }
        return total;
    }

    private static void MeasureTreeIfPresent(string path, ref long total, ref int count)
    {
        try
        {
            using var directory = NativeFiles.OpenDirectory(path);
            NativeFiles.Verify(directory, path, directory: true);
        }
        catch (FileNotFoundException) { return; }
        MeasureTree(path, 0, ref total, ref count);
    }

    private static void MeasureTree(string path, int depth, ref long total, ref int count)
    {
        if (depth > MaxDepth) throw new IOException("Update storage is too deeply nested to measure safely.");
        using var parents = PathPolicy.PinDirectories(path);
        Add(StartupUpdateSlot.MeasureDirectory(path), ref total);
        foreach (var child in Directory.EnumerateFileSystemEntries(path))
        {
            if (++count > MaxEntries) throw new IOException("Update storage contains too many entries to measure safely.");
            using var handle = NativeFiles.OpenAny(child);
            var identity = NativeFiles.MoveIdentity(handle);
            if (identity.ReparseTag != 0 || (identity.Attributes & (uint)FileAttributes.ReparsePoint) != 0)
                throw new IOException("An update storage reparse point was preserved; its capacity cannot be safely measured.");
            NativeFiles.Verify(handle, child, directory: identity.IsDirectory);
            if (identity.IsDirectory) MeasureTree(child, depth + 1, ref total, ref count);
            else Add(MeasureFile(child), ref total);
        }
    }

    private static void MeasureFileIfPresent(string path, ref long total, ref int count)
    {
        try
        {
            var bytes = MeasureFile(path);
            if (++count > MaxEntries) throw new IOException("Update storage contains too many entries to measure safely.");
            Add(bytes, ref total);
        }
        catch (FileNotFoundException) { }
    }

    private static long MeasureFile(string path)
    {
        if (currentGuards is not null)
            foreach (var guard in currentGuards)
                if (!guard.IsClosed && !guard.IsInvalid && NativeFiles.FinalPath(guard).Equals(path, StringComparison.Ordinal))
                    return StartupUpdateSlot.MeasureFile(path, guard);
        return StartupUpdateSlot.MeasureFile(path);
    }

    private static void Add(long bytes, ref long total)
    {
        total = checked(total + bytes);
        if (total > Limit) throw new IOException("The update storage budget is exhausted; existing and unknown data were retained.");
    }
}
