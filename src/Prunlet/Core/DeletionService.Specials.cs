using Microsoft.Win32.SafeHandles;
namespace Prunlet.Core;
public sealed partial class DeletionService
{
    private static void VerifySpecialHandle(SafeFileHandle handle, string path)
    {
        if (NativeFiles.FinalPath(handle) != path) throw new IOException("Special object handle path differs from the validated canonical path.");
    }

}
