using System.Text.Json;
using System.Text.RegularExpressions;
namespace Prunlet.Core;
public sealed partial class DeletionService
{
    private static readonly JsonSerializerOptions MoveJsonOptions = new(PrunletConfig.JsonOptions)
        { PropertyNameCaseInsensitive = false };

    private static void ValidateMoveOperationId(string id)
    {
        if (!Guid.TryParseExact(id, "N", out var guid) || guid.ToString("N") != id)
            throw new ArgumentException("Operation ID must be a lowercase 32-character GUID.");
    }

    private static bool ValidMoveIdentity(MoveEntryIdentity? identity) => identity is not null
        && Regex.IsMatch(identity.FileId, "^[0-9A-Fa-f]{32}$", RegexOptions.CultureInvariant)
        && identity.FileId.Any(character => character != '0')
        && identity.IsDirectory == ((identity.Attributes & (uint)FileAttributes.Directory) != 0)
        && (identity.ReparseTag == 0) == ((identity.Attributes & (uint)FileAttributes.ReparsePoint) == 0);

    private static bool SameMoveObject(MoveEntryIdentity expected, MoveEntryIdentity actual) =>
        expected.VolumeSerialNumber == actual.VolumeSerialNumber && expected.FileId.Equals(actual.FileId, StringComparison.OrdinalIgnoreCase)
        && expected.IsDirectory == actual.IsDirectory && expected.ReparseTag == actual.ReparseTag;

    private void CheckMoveTarget(string path, bool directory)
    {
        if (path != PathPolicy.Absolute(path) || path.Length == 3 || PathPolicy.Within(path, config.BackupDirectory)
            || (directory && PathPolicy.Within(config.BackupDirectory, path)))
            throw new ArgumentException("Target is inside or contains the metadata recovery directory.");
        // 他volumeの設定値も短縮名等を実体へ解決して保護する。不正・未検証なら削除しない。
        var protectedRoots = VolumeRecoveryStore.ProtectedRoots(config, path)
            .Concat(config.VolumeRecoveryDirectories.SelectMany(ConfiguredRecoveryRoots));
        foreach (var root in protectedRoots)
            if (PathPolicy.Within(path, root) || (directory && PathPolicy.Within(root, path)))
                throw new ArgumentException("Target is inside or contains a volume recovery directory.");
    }

    private static IEnumerable<string> ConfiguredRecoveryRoots(KeyValuePair<string, string> pair)
    {
        var expectedVolume = PathPolicy.Absolute(pair.Key);
        foreach (var value in new[] { pair.Value, pair.Value + ".restore" })
            yield return ResolveConfiguredRecoveryRoot(value, expectedVolume);
    }

    private static string ResolveConfiguredRecoveryRoot(string value, string expectedVolume)
    {
        string resolved;
        string actualVolume;
        try
        {
            resolved = PathPolicy.Resolve(value, finalDirectory: true, allowMissing: true);
            actualVolume = NativeFiles.VolumeMountRoot(resolved);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
        {
            throw new InvalidDataException($"Configured recovery directory could not be validated: {value}. {ex.Message}", ex);
        }
        if (!actualVolume.Equals(expectedVolume, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"Configured recovery directory must remain on its configured volume: {value} (expected {expectedVolume}, actual {actualVolume}).");
        return resolved;
    }

    private static MoveEntryIdentity? InspectMoveLocation(string path)
    {
        try
        {
            using var handle = NativeFiles.OpenMoveMeasurement(path);
            if (NativeFiles.FinalPath(handle) != path) throw new IOException("Move location differs from its canonical path.");
            return NativeFiles.MoveIdentity(handle);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

}
