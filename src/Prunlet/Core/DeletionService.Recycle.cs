using System.Runtime.InteropServices;

namespace Prunlet.Core;

public sealed partial class DeletionService
{

    private void CheckRecycleTarget(string path, bool directory)
    {
        CheckMoveTarget(path, directory);
        var bin = Path.Combine(Path.GetPathRoot(path)!, "$Recycle.Bin");
        if (PathPolicy.Within(path, bin) || directory && PathPolicy.Within(bin, path))
            throw new ArgumentException("Windows Recycle Bin storage is protected; use the Windows Recycle Bin to manage its contents.");
    }

    private static bool IsRecycleFailure(Exception exception) => IsMoveFailure(exception) || exception is COMException or NotSupportedException;
}
