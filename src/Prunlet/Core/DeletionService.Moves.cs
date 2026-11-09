namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private static bool IsMoveFailure(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or OverflowException or System.ComponentModel.Win32Exception;
}
