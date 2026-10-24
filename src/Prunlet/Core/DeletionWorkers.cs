using System.Security.Principal;

namespace Prunlet.Core;

internal static class DeletionWorkers
{
    // MCPの要求数とbatchの件数を掛け合わせず、process全体で実処理を制限する。
    private static readonly SemaphoreSlim Slots = new(4, 4);

    internal static void For(int count, Action<int> action, bool sequential = false)
    {
        using var identity = WindowsIdentity.GetCurrent();
        Parallel.For(0, count, new ParallelOptions { MaxDegreeOfParallelism = sequential ? 1 : 4 }, index =>
        {
            Slots.Wait();
            try { WindowsIdentity.RunImpersonated(identity.AccessToken, () => action(index)); }
            finally { Slots.Release(); }
        });
    }
}
