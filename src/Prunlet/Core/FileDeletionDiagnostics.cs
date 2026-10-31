using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Prunlet.Core;

// 失敗時だけ現在の保持元を観測する。再削除・プロセス停止・リンク先や配下の走査はしない。
internal static class FileDeletionDiagnostics
{
    internal static string Describe(string path, Exception error, bool inspectLocks = true)
    {
        var native = NativeError(error);
        var message = $"{error.Message} Target: {JsonSerializer.Serialize(path)}; HRESULT 0x{error.HResult:X8}"
            + (native is null ? "." : $"; native error {native}.");
        message += unchecked((uint)error.HResult) switch
        {
            0x80270021 => " Windows denied access to the source (COPYENGINE_E_ACCESS_DENIED_SRC); this does not identify a locking process.",
            0x80270022 => " Windows denied access to the destination (COPYENGINE_E_ACCESS_DENIED_DEST); this does not identify a locking process.",
            _ => string.Empty
        };
        if (!inspectLocks || !IsSharingViolation(error)) return message;
        try { return message + ObserveUsers(path); }
        catch (Exception diagnosticError) when (DiagnosticFailure(diagnosticError))
        {
            return message + $" Lock diagnostics unavailable ({diagnosticError.GetType().Name}); the original deletion result is unchanged.";
        }
    }

    private static int? NativeError(Exception error)
    {
        for (Exception? current = error; current is not null; current = current.InnerException)
            if (current is Win32Exception native) return native.NativeErrorCode;
        return null;
    }

    private static bool IsSharingViolation(Exception error)
    {
        for (Exception? current = error; current is not null; current = current.InnerException)
            if (unchecked((uint)current.HResult) is 0x80270027 or 0x80270028 or 0x80070020 or 0x80070021
                || current is Win32Exception { NativeErrorCode: 32 or 33 }) return true;
        return false;
    }

    private static string ObserveUsers(string path)
    {
        var clock = Stopwatch.StartNew();
        var observations = new List<string>();
        var notes = new List<string>();
        var attributes = File.GetAttributes(path);
        var directory = (attributes & FileAttributes.Directory) != 0;
        if ((attributes & FileAttributes.ReparsePoint) != 0)
            return " Lock diagnostics: link targets were not inspected; no owner was identified.";
        if (!directory)
        {
            try { ObserveRestartManager(path, observations); }
            catch (Exception error) when (DiagnosticFailure(error)) { notes.Add("Restart Manager unavailable"); }
        }
        else notes.Add("file-handle owners inside directories are not enumerated");

        // 開いたfile handleがなくても、ロード済みDLLのimage mappingは残り得る。
        var inaccessible = false;
        var processes = Process.GetProcesses();
        try
        {
            foreach (var process in processes)
            {
                if (clock.ElapsedMilliseconds >= 10000 || observations.Count >= 8)
                {
                    notes.Add("diagnostic time/result limit reached");
                    break;
                }
                try
                {
                    foreach (ProcessModule module in process.Modules)
                    {
                        var modulePath = module.FileName;
                        if (!modulePath.Equals(path, StringComparison.OrdinalIgnoreCase)
                            && !(directory && modulePath.StartsWith(path.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))) continue;
                        observations.Add($"PID {process.Id} ({JsonSerializer.Serialize(process.ProcessName)}), loaded module {JsonSerializer.Serialize(modulePath)}");
                        break;
                    }
                }
                catch (Exception error) when (DiagnosticFailure(error)) { inaccessible = true; }
            }
        }
        finally { foreach (var process in processes) process.Dispose(); }
        if (inaccessible) notes.Add("some processes could not be inspected or exited");
        var result = observations.Count == 0 ? "no holding process identified" : string.Join("; ", observations);
        return " Lock diagnostics (current observation, not an exhaustive list): " + result
            + (notes.Count == 0 ? "." : "; " + string.Join("; ", notes) + ".");
    }

    private static void ObserveRestartManager(string path, List<string> observations)
    {
        var key = new StringBuilder(Guid.NewGuid().ToString("N"), 33);
        var status = RmStartSession(out var session, 0, key);
        if (status != 0) throw new Win32Exception(status);
        try
        {
            status = RmRegisterResources(session, 1, [path], 0, IntPtr.Zero, 0, IntPtr.Zero);
            if (status != 0) throw new Win32Exception(status);
            uint count = 0, reasons = 0;
            status = RmGetList(session, out var needed, ref count, null, ref reasons);
            // プロセスの増減に追従する回数と確保量を制限する。
            for (var attempt = 0; status == 234 && needed <= 256 && attempt < 2; attempt++)
            {
                var users = new ProcessInfo[needed];
                count = needed;
                status = RmGetList(session, out needed, ref count, users, ref reasons);
                if (status != 0) continue;
                foreach (var user in users.Take((int)count))
                {
                    // 自分がpreflightのため保持したhandleを原因として案内しない。
                    if (user.Process.Id == Environment.ProcessId) continue;
                    observations.Add($"PID {user.Process.Id} ({JsonSerializer.Serialize(user.ApplicationName)}), Restart Manager file user {JsonSerializer.Serialize(path)}");
                    if (observations.Count >= 8) break;
                }
            }
            if (status != 0) throw new Win32Exception(status);
        }
        finally { _ = RmEndSession(session); }
    }

    private static bool DiagnosticFailure(Exception error) => error is Win32Exception or IOException
        or UnauthorizedAccessException or InvalidOperationException or ArgumentException or NotSupportedException
        or System.Security.SecurityException or DllNotFoundException or EntryPointNotFoundException;

    [StructLayout(LayoutKind.Sequential)]
    private struct UniqueProcess
    {
        internal int Id;
        internal System.Runtime.InteropServices.ComTypes.FILETIME StartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessInfo
    {
        internal UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string ApplicationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string ServiceName;
        internal uint ApplicationType;
        internal uint Status;
        internal uint SessionId;
        [MarshalAs(UnmanagedType.Bool)] internal bool Restartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RmStartSession(out uint session, uint flags, StringBuilder key);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RmRegisterResources(uint session, uint fileCount, [In] string[] files,
        uint applicationCount, IntPtr applications, uint serviceCount, IntPtr services);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RmGetList(uint session, out uint needed, ref uint count,
        [In, Out] ProcessInfo[]? applications, ref uint reasons);
    [DllImport("rstrtmgr.dll", ExactSpelling = true)]
    private static extern int RmEndSession(uint session);
}
