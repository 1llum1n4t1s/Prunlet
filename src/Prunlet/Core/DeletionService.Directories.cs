using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private string ValidateAnyTarget(string path)
    {
        var absolute = PathPolicy.FileDeleteAbsolute(path);
        string normalized;
        try
        {
            // 論理パスの親を実体へ解決してから固定し、型検査中の差し替えを許さない。
            var canonicalParent = PathPolicy.Resolve(Path.GetDirectoryName(absolute) ?? absolute,
                finalDirectory: true, allowMissing: false);
            using var parents = PathPolicy.PinDirectories(canonicalParent);
            using var handle = NativeFiles.OpenAny(Path.Combine(canonicalParent, Path.GetFileName(absolute)));
            var directory = NativeFiles.IsDirectory(handle);
            normalized = NativeFiles.IsReparse(handle) ? NativeFiles.FinalPath(handle) : PathPolicy.Resolve(absolute, finalDirectory: directory, allowReservedLeaf: true);
            if (NativeFiles.IsReparse(handle)) VerifySpecialHandle(handle, normalized);
            else NativeFiles.Verify(handle, normalized, directory);
            if (directory && (normalized.Length == 3 || PathPolicy.Within(config.BackupDirectory, normalized)))
                throw new ArgumentException("A drive root or ancestor of the recovery directory cannot be deleted.");
        }
        catch (FileNotFoundException) { normalized = PathPolicy.Resolve(absolute, allowReservedLeaf: true); }
        catch (DirectoryNotFoundException) { normalized = PathPolicy.Resolve(absolute, allowReservedLeaf: true); }
        if (PathPolicy.Within(normalized, config.BackupDirectory))
            throw new ArgumentException("Target path is inside the recovery directory.");
        return normalized;
    }

}
