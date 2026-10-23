using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    // 新規operationの保存先とロックを、作成順の逆順で処理終了まで保持する。
    private sealed class NewOperationLease(DirectoryLease storage, DirectoryLease directories,
        SafeFileHandle operationLock, string operationId, string directory) : IDisposable
    {
        internal string OperationId { get; } = operationId;
        internal string Directory { get; } = directory;

        internal static NewOperationLease Create(string backupDirectory, bool privateRegistry = false, string? requestedOperationId = null)
        {
            var storage = PathPolicy.PinRecoveryDirectories(backupDirectory);
            DirectoryLease? directories = null;
            SafeFileHandle? operationLock = null;
            try
            {
                var operationId = requestedOperationId ?? Guid.NewGuid().ToString("N");
                ValidateMoveOperationId(operationId);
                var directory = Path.Combine(backupDirectory, operationId);
                using var createdDirectory = privateRegistry ? NativeFiles.CreatePrivateRegistryDirectory(directory) : null;
                if (!privateRegistry) NativeFiles.CreateDirectory(directory);
                directories = PathPolicy.PinRecoveryDirectories(directory);
                operationLock = privateRegistry ? NativeFiles.CreatePrivateRegistryFile(Path.Combine(directory, "operation.lock"))
                    : NativeFiles.CreateDestination(Path.Combine(directory, "operation.lock"));
                NativeFiles.Verify(operationLock, Path.Combine(directory, "operation.lock"));
                return new NewOperationLease(storage, directories, operationLock, operationId, directory);
            }
            catch
            {
                operationLock?.Dispose(); directories?.Dispose(); storage.Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            operationLock.Dispose(); directories.Dispose(); storage.Dispose();
        }
    }
}
