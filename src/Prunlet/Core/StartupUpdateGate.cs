namespace Prunlet.Core;

internal static class StartupUpdateGate
{
    internal static void EnsureReady(string configPath)
    {
        var executable = Environment.ProcessPath
            ?? throw new IOException("Cannot determine the executable path for update state inspection.");
        var name = Path.GetFileName(executable);
        var bin = Path.GetDirectoryName(executable);
        string? executableRoot = null;
        if (bin is not null && Path.GetFileName(bin).Equals("bin", StringComparison.OrdinalIgnoreCase)
            && (name.Equals("prunlet.exe", StringComparison.OrdinalIgnoreCase)
                || name.Equals("prunlet-maintenance.exe", StringComparison.OrdinalIgnoreCase)))
        {
            executableRoot = Path.GetDirectoryName(bin)
                ?? throw new IOException("Cannot determine the installation directory for update state inspection.");
            EnsureRootReady(executableRoot);
        }
        if (Path.GetFileName(configPath).Equals("config.json", StringComparison.OrdinalIgnoreCase))
        {
            var configRoot = Path.GetDirectoryName(configPath)
                ?? throw new IOException("Cannot determine the configuration directory for update state inspection.");
            if (!configRoot.Equals(executableRoot, StringComparison.OrdinalIgnoreCase)) EnsureRootReady(configRoot);
        }
    }

    private static void EnsureRootReady(string root)
    {
        try
        {
            // coordinatorと同じ版・全fieldの検査を使い、未対応の状態を通常入口でも保全する。
            var state = StartupUpdateCoordinator.ReadState(root);
            if (state is not null && state.Phase != "idle")
                throw new InvalidDataException("Update state is not a supported idle state.");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            throw new IOException("Prunlet cannot start while its update state is incomplete or unreadable: " + ex.Message, ex);
        }
    }
}
