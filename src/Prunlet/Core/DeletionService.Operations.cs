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

        internal static NewOperationLease Create(string backupDirectory)
        {
            var storage = PathPolicy.PinRecoveryDirectories(backupDirectory);
            DirectoryLease? directories = null;
            SafeFileHandle? operationLock = null;
            try
            {
                var operationId = Guid.NewGuid().ToString("N");
                var directory = Path.Combine(backupDirectory, operationId);
                NativeFiles.CreateDirectory(directory);
                directories = PathPolicy.PinRecoveryDirectories(directory);
                operationLock = NativeFiles.CreateDestination(Path.Combine(directory, "operation.lock"));
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
