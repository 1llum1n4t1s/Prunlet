using Microsoft.Win32;

namespace Prunlet.Core;

// NukeOnDeleteは公開API契約ではない。Shellの回収不能通知と、明示したDWORD 1の組合せだけを扱う。
// 設定を書き換えず、未設定・未知の形式・policy・読取失敗から即時削除を推測しない。
internal sealed record RecycleImmediateDeleteSetting(string Sid, string Volume)
{
    private const string Explorer = @"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\";
    private const string Policy = @"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";

    internal static RecycleImmediateDeleteSetting? TryCapture(string path)
    {
        try { return Capture(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    internal void Revalidate(string path)
    {
        if (TryCapture(path) != this)
            throw new IOException("The volume's immediate-delete setting or effective user changed or could not be confirmed. Immediate deletion stopped.");
    }

    private static RecycleImmediateDeleteSetting? Capture(string path)
    {
        var sid = NativeRegistry.CurrentSid;
        // リンク自身の所属先はリンク先ではなく、固定する親ディレクトリのボリューム。
        var parent = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(parent)) return null;
        var volume = NativeFiles.VolumeName(NativeFiles.VolumeMountRoot(parent));
        if (!volume.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase)
            || !volume.EndsWith(@"}\", StringComparison.Ordinal)
            || !Guid.TryParseExact(volume[10..^1], "B", out var guid)) return null;

        // HKCUのprocess内cacheを使わず、Shellへ引き継いだ実効tokenのSIDを明示する。
        using var users = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using var user = users.OpenSubKey(sid, writable: false);
        if (user is null) return null;
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
            using var machinePolicy = machine.OpenSubKey(Policy, writable: false);
            using var userView = RegistryKey.OpenBaseKey(RegistryHive.Users, view);
            using var userPolicy = userView.OpenSubKey(sid + @"\" + Policy, writable: false);
            if (HasPolicy(machinePolicy) || HasPolicy(userPolicy)) return null;
        }
        using var setting = user.OpenSubKey(Explorer + guid.ToString("B"), writable: false);
        if (setting is null || !setting.GetValueNames().Contains("NukeOnDelete", StringComparer.OrdinalIgnoreCase)
            || setting.GetValueKind("NukeOnDelete") != RegistryValueKind.DWord
            || setting.GetValue("NukeOnDelete", null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not int value
            || value != 1) return null;
        return new(sid, volume.ToUpperInvariant());
    }

    private static bool HasPolicy(RegistryKey? key)
        => key is not null && key.GetValueNames().Contains("NoRecycleFiles", StringComparer.OrdinalIgnoreCase);
}
