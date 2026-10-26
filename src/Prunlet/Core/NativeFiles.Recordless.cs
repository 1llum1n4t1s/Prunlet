using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static partial class NativeFiles
{
    // 実削除に必要なDELETEと属性読取だけを要求し、本文を読む権限を増やさない。
    // preflight中だけrootを名前で固定し、Shell呼出し前に解放する。
    internal static SafeFileHandle OpenRecordlessPreflight(string path)
        => Open(path, Delete | 0x80, 1, 3, OpenReparse | BackupSemantics);
}
