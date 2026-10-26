using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{

    private static void VerifyMoveHandle(SafeFileHandle handle, string path, MoveEntryIdentity identity)
    {
        if (!NativeFiles.FinalPath(handle).Equals(path, StringComparison.Ordinal)
            || !SameMoveObject(identity, NativeFiles.MoveIdentity(handle)))
            throw new IOException("The move object's identity or canonical path changed.");
    }

    private static bool IsMoveFailure(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or OverflowException or System.ComponentModel.Win32Exception;
}
