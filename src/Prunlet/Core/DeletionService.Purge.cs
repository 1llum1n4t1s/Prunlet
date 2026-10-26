using System.Security.Cryptography;
using System.Text.Json;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    public PurgeResult Purge(string operationId, bool apply = false)
    {
        using var coordination = AcquireRecoveryCoordination(create: apply);
        ValidateMoveOperationId(operationId);
        if (apply) EnsureRegistryOperationAvailable(operationId);
        var result = PurgeRegistryCore(operationId, apply);
        if (apply && result.Items.All(item => item.Status != "failed")) CaptureRegistryTerminal(operationId, result.Warnings);
        return result;
    }

    private static FileStream HoldPurgeMetadata(string path, List<FileStream> held)
    {
        var handle = NativeFiles.OpenBackup(path);
        try
        {
            NativeFiles.Verify(handle, path);
            NativeFiles.VerifySingleLink(handle);
            NativeFiles.RejectNamedStreams(path);
            var stream = new FileStream(handle, FileAccess.Read);
            held.Add(stream);
            return stream;
        }
        catch { handle.Dispose(); throw; }
    }

    private static string HashStream(FileStream stream)
    {
        stream.Position = 0;
        var hash = Convert.ToHexStringLower(SHA256.HashData(stream));
        stream.Position = 0;
        return hash;
    }

}
