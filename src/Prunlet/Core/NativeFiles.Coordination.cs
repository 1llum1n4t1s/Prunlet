using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

internal static partial class NativeFiles
{
    internal static SafeFileHandle OpenSharedCoordination(string path)
        => Open(path, Read, 1, 4, OpenReparse);

    internal static bool TryClaimCoordination(SafeFileHandle handle, uint slot, bool exclusive)
    {
        var overlap = new CoordinationOverlapped { Offset = slot + 1 };
        if (LockFileEx(handle, exclusive ? 3u : 1u, 0, 1, 0, ref overlap)) return true;
        var error = Marshal.GetLastWin32Error();
        if (error == 33) return false;
        throw new IOException("Cannot claim deletion target.", new Win32Exception(error));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CoordinationOverlapped
    {
        internal IntPtr Internal, InternalHigh;
        internal uint Offset, OffsetHigh;
        internal IntPtr Event;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LockFileEx(SafeFileHandle handle, uint flags, uint reserved,
        uint lengthLow, uint lengthHigh, ref CoordinationOverlapped overlapped);
}
