using System.Buffers.Binary;
using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

public sealed class DeferredDeleteQueueResult
{
    public string JobId { get; set; } = "";
    public string Status { get; set; } = "pending";
    public FileDeleteResult? Result { get; set; }
    public string? Error { get; set; }
    public string? WaitReason { get; set; }
    public int WorkerProcessId { get; set; }
    public int? MaxWaitSeconds { get; set; }
    public int RetentionSeconds { get; set; } = 3600;
    public DateTimeOffset? ExpiresUtc { get; set; }
}

public static class DeferredDeleteQueue
{
    private const int MaximumFrameBytes = 1024 * 1024;
    private static readonly JsonSerializerOptions Options = new(PrunletConfig.JsonOptions)
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        MaxDepth = 16
    };

    private sealed class Request
    {
        public string JobId { get; set; } = "";
        public string[] Paths { get; set; } = [];
        public bool Recursive { get; set; }
    }

    public static DeferredDeleteQueueResult Enqueue(string configPath, string[] paths, bool recursive)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Prunlet requires Windows.");
        if (!Path.IsPathFullyQualified(configPath)) throw new ArgumentException("Config path must be absolute.");
        ArgumentNullException.ThrowIfNull(paths);
        if (paths.Length is 0 or > 256) throw new ArgumentException("Specify between 1 and 256 paths.");
        var jobId = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        var request = new Request { JobId = jobId, Paths = paths, Recursive = recursive };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(request, Options);
        if (bytes.Length > MaximumFrameBytes) throw new ArgumentException("Queue request is too large.");
        var executable = Environment.ProcessPath ?? throw new IOException("Current executable is unavailable.");
        using var process = WorkerPipes.Start(executable, Path.GetFullPath(configPath));
        // 診断を親の標準出力へ流さず、閉鎖後もworkerが待機できるよう全通信を限定する。
        DeferredDeleteQueueResult response;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            WriteFrameAsync(process.Input, bytes, timeout.Token).WaitAsync(timeout.Token).GetAwaiter().GetResult();
            process.Input.Close();
            response = ReadAsync<DeferredDeleteQueueResult>(process.Output, timeout.Token).WaitAsync(timeout.Token).GetAwaiter().GetResult();
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or JsonException)
        {
            throw new IOException($"Queue acceptance could not be confirmed for job {jobId}. Inspect its status and the source; do not resend deletion. {ex.Message}", ex);
        }
        if (response.Status == "failed") throw new IOException(response.Error ?? "Queue request was rejected before deletion started.");
        if (response.JobId != jobId || response.Status != "pending")
            throw new IOException($"Invalid queue acceptance for job {jobId}. Inspect its status; do not resend deletion.");
        return response;
    }

    public static DeferredDeleteQueueResult Status(string jobId) => Contact(jobId, "status");
    public static DeferredDeleteQueueResult Cancel(string jobId) => Contact(jobId, "cancel");

    private static DeferredDeleteQueueResult Contact(string jobId, string command)
    {
        ValidateId(jobId);
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            using var pipe = new NamedPipeClientStream(".", PipeName(jobId), PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            pipe.ConnectAsync(timeout.Token).GetAwaiter().GetResult();
            WriteAsync(pipe, command, timeout.Token).GetAwaiter().GetResult();
            var response = ReadAsync<DeferredDeleteQueueResult>(pipe, timeout.Token).GetAwaiter().GetResult();
            if (response.JobId != jobId) throw new IOException("Queue response identity differs.");
            return response;
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or UnauthorizedAccessException or JsonException)
        {
            return new DeferredDeleteQueueResult
            {
                JobId = jobId, Status = "unavailable",
                Error = "Worker is inaccessible, stopped, or its result expired. Deletion outcome is unknown; inspect the source and Windows Recycle Bin and do not resend deletion. " + ex.Message
            };
        }
    }

    public static Task<int> RunWorkerAsync(string configPath) => Task.Run(() =>
    {
        // Mutexの所有threadを固定し、異常終了時もabandoned mutexとして枠を回収する。
        using var slot = AcquireSlot();
        if (slot is null)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var rejected = ReadAsync<Request>(Console.OpenStandardInput(), timeout.Token).GetAwaiter().GetResult();
            WriteAsync(Console.OpenStandardOutput(), new DeferredDeleteQueueResult
            { JobId = rejected.JobId, Status = "failed", Error = "Deletion queue is full (maximum 8 workers per user and Windows session); deletion was not started." }, timeout.Token).GetAwaiter().GetResult();
            return 1;
        }
        try { return RunCoreAsync(configPath).GetAwaiter().GetResult(); }
        finally { slot.ReleaseMutex(); }
    });

    private static Mutex? AcquireSlot()
    {
        var user = WindowsIdentity.GetCurrent().User?.Value ?? throw new IOException("Effective user SID is unavailable.");
        var key = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(user)));
        for (var i = 0; i < 8; i++)
        {
            var slot = new Mutex(false, $"Local\\Prunlet.DeleteQueue.v1.{key}.{i}");
            try { if (slot.WaitOne(0)) return slot; }
            catch (AbandonedMutexException) { return slot; }
            slot.Dispose();
        }
        return null;
    }

    private static async Task<int> RunCoreAsync(string configPath)
    {
        var state = new DeferredDeleteQueueResult { WorkerProcessId = Environment.ProcessId };
        var snapshots = new List<DeferredDeletePreflight>();
        try
        {
            using var inputTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var request = await ReadAsync<Request>(Console.OpenStandardInput(), inputTimeout.Token);
            ValidateId(request.JobId); state.JobId = request.JobId;
            var service = new DeletionService(PrunletConfig.Load(configPath));
            var normalized = service.ValidateQueuedTargets(request.Paths);
            var entryCount = 0;
            foreach (var path in normalized)
            {
                var snapshot = DeferredDeletePreflight.Capture(path, request.Recursive);
                snapshots.Add(snapshot);
                entryCount += snapshot.EntryCount;
                if (entryCount > 4096) throw new IOException("Queue snapshot exceeds the total limit of 4096 entries including parents.");
            }
            // Pipe名を先に占有し、受付前のsnapshotと同じ実体だけを後から削除する。
            using var firstPipe = NewPipe(state.JobId);
            await WriteAsync(Console.OpenStandardOutput(), state, inputTimeout.Token);
            var gate = new object();
            using var finished = new CancellationTokenSource();
            var server = ServeAsync(firstPipe, state, gate, finished.Token);
            var execution = Task.Run(async () =>
            {
                var started = false;
                try
                {
                    while (true)
                    {
                        lock (gate) { if (state.Status == "cancelled") return; }
                        foreach (var snapshot in snapshots) snapshot.VerifyUnchanged();
                        try { foreach (var snapshot in snapshots) snapshot.Probe(); }
                        catch (IOException ex) when (IsSharingViolation(ex))
                        {
                            lock (gate) { if (state.Status == "pending") state.WaitReason = "Waiting for a Windows sharing or lock violation to clear: " + ex.Message; }
                            await Task.Delay(TimeSpan.FromSeconds(1));
                            continue;
                        }
                        lock (gate)
                        {
                            if (state.Status == "cancelled") return;
                            foreach (var snapshot in snapshots) snapshot.VerifyUnchanged();
                            state.WaitReason = null; state.Status = "running"; started = true;
                        }
                        // この呼出し開始後は例外・failed・ambiguousのいずれも再送しない。
                        var result = service.DeleteQueued(normalized, request.Recursive, snapshots);
                        lock (gate)
                        {
                            state.Result = result;
                            state.Status = result.Items.Any(x => x.Status == "ambiguous") ? "ambiguous"
                                : result.Items.Any(x => x.Status == "failed") ? "failed" : "completed";
                            if (state.Status is "failed" or "ambiguous")
                                state.Error = "Deletion did not fully succeed. Inspect item results and Windows Recycle Bin; do not resend deletion.";
                            state.ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(state.RetentionSeconds);
                        }
                        return;
                    }
                }
                catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
                {
                    lock (gate)
                    {
                        if (state.Status == "cancelled") return;
                        state.WaitReason = null;
                        state.Status = started ? "ambiguous" : "failed";
                        state.Error = (started ? "Deletion started; outcome is unknown. Do not resend deletion. " : "Deletion was not started. ") + ex.Message;
                        state.ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(state.RetentionSeconds);
                    }
                }
                finally
                {
                    foreach (var snapshot in snapshots) snapshot.Dispose();
                    lock (gate) { state.ExpiresUtc ??= DateTimeOffset.UtcNow.AddSeconds(state.RetentionSeconds); }
                }
            });
            await execution;
            await Task.Delay(TimeSpan.FromSeconds(state.RetentionSeconds));
            finished.Cancel();
            await server;
            return 0;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            state.Status = "failed"; state.Error = "Queue request was not accepted; deletion was not started. " + ex.Message;
            try { await WriteAsync(Console.OpenStandardOutput(), state, CancellationToken.None); }
            catch (IOException) { }
            return 1;
        }
        finally { foreach (var snapshot in snapshots) snapshot.Dispose(); }
    }

    private static async Task ServeAsync(NamedPipeServerStream first, DeferredDeleteQueueResult state, object gate, CancellationToken stop)
    {
        var pipe = first;
        try
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    await pipe.WaitForConnectionAsync(stop);
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop);
                    timeout.CancelAfter(TimeSpan.FromSeconds(5));
                    var command = await ReadAsync<string>(pipe, timeout.Token);
                    byte[] response;
                    lock (gate)
                    {
                        string? error = null;
                        if (command == "cancel")
                        {
                            if (state.Status == "pending")
                            {
                                state.Status = "cancelled"; state.Error = null; state.WaitReason = null;
                                state.ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(state.RetentionSeconds);
                            }
                            else error = "Cancellation refused: deletion has started or the job is already terminal. Do not resend deletion.";
                        }
                        else if (command != "status") error = "Unknown queue command.";
                        var copy = new DeferredDeleteQueueResult
                        {
                            JobId = state.JobId, Status = state.Status, Result = state.Result,
                            Error = error ?? state.Error, WaitReason = state.WaitReason, WorkerProcessId = state.WorkerProcessId,
                            ExpiresUtc = state.ExpiresUtc, RetentionSeconds = state.RetentionSeconds
                        };
                        response = JsonSerializer.SerializeToUtf8Bytes(copy, Options);
                    }
                    await WriteFrameAsync(pipe, response, timeout.Token);
                }
                catch (Exception ex) when (ex is IOException or OperationCanceledException or JsonException) { }
                if (stop.IsCancellationRequested) break;
                // 同じpipe instanceを保持し、照会間に名前を他processへ明け渡さない。
                if (pipe.IsConnected) pipe.Disconnect();
            }
        }
        finally { pipe.Dispose(); }
    }

    private static NamedPipeServerStream NewPipe(string id) => new(PipeName(id), PipeDirection.InOut, 1,
        PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly | PipeOptions.FirstPipeInstance);
    private static string PipeName(string id) => "Prunlet.DeleteQueue.v1." + id;
    private static void ValidateId(string id)
    {
        if (id is null || id.Length != 32 || id.Any(c => c is not (>= '0' and <= '9') and not (>= 'a' and <= 'f')))
            throw new ArgumentException("Queue job ID must contain 32 lowercase hexadecimal characters.");
    }

    private static bool IsSharingViolation(Exception ex)
    {
        for (Exception? current = ex; current is not null; current = current.InnerException)
            if ((current.HResult & 0xffff) is 32 or 33 || current is Win32Exception { NativeErrorCode: 32 or 33 }) return true;
        return false;
    }

    private static Task WriteAsync<T>(Stream stream, T value, CancellationToken cancellation)
        => WriteFrameAsync(stream, JsonSerializer.SerializeToUtf8Bytes(value, Options), cancellation);

    private static async Task WriteFrameAsync(Stream stream, byte[] bytes, CancellationToken cancellation)
    {
        if (bytes.Length is 0 or > MaximumFrameBytes) throw new IOException("Queue frame exceeds the limit.");
        var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
        await stream.WriteAsync(header, cancellation); await stream.WriteAsync(bytes, cancellation);
        await stream.FlushAsync(cancellation);
    }

    private static async Task<T> ReadAsync<T>(Stream stream, CancellationToken cancellation)
    {
        var header = new byte[4]; await stream.ReadExactlyAsync(header, cancellation);
        var size = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (size is <= 0 or > MaximumFrameBytes) throw new IOException("Invalid queue frame length.");
        var bytes = new byte[size]; await stream.ReadExactlyAsync(bytes, cancellation);
        return JsonSerializer.Deserialize<T>(bytes, Options) ?? throw new IOException("Queue frame is empty.");
    }

    // Process.Startは継承可能な呼出元のpipeまで子へ渡すため、専用3handleだけを列挙する。
    private sealed class WorkerPipes : IDisposable
    {
        internal FileStream Input { get; }
        internal FileStream Output { get; }
        private readonly FileStream error;

        private WorkerPipes(FileStream input, FileStream output, FileStream error)
        {
            Input = input; Output = output; this.error = error;
            _ = DrainErrorAsync(error);
        }

        private static async Task DrainErrorAsync(Stream stream)
        {
            try { await stream.CopyToAsync(Stream.Null); }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException) { }
        }

        public void Dispose()
        {
            // 通信失敗の本来の結果をclose時の例外で隠さず、各handleを必ず閉じる。
            foreach (var stream in new[] { Input, Output, error })
            {
                try { stream.Dispose(); }
                catch (Exception ex) when (ex is IOException or ObjectDisposedException) { }
            }
        }

        internal static WorkerPipes Start(string executable, string configPath)
        {
            if (!Path.IsPathFullyQualified(executable)) throw new IOException("Worker executable path must be absolute.");
            var security = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), InheritHandle = 1 };
            if (!CreatePipe(out var inputChild, out var inputParent, ref security, 0)) ThrowNative("Cannot create worker input pipe");
            using var childInput = inputChild;
            using var parentInput = inputParent;
            if (!CreatePipe(out var outputParent, out var outputChild, ref security, 0)) ThrowNative("Cannot create worker output pipe");
            using var parentOutput = outputParent;
            using var childOutput = outputChild;
            if (!CreatePipe(out var errorParent, out var errorChild, ref security, 0)) ThrowNative("Cannot create worker error pipe");
            using var parentError = errorParent;
            using var childError = errorChild;
            foreach (var handle in new[] { parentInput, parentOutput, parentError })
                if (!SetHandleInformation(handle, 1, 0)) ThrowNative("Cannot disable parent pipe inheritance");

            nuint size = 0;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            if (size == 0 || size > int.MaxValue) throw new IOException("Worker attribute list size is invalid.");
            var attributes = Marshal.AllocHGlobal((int)size);
            var handles = Marshal.AllocHGlobal(3 * IntPtr.Size);
            var initialized = false;
            FileStream? input = null; FileStream? output = null; FileStream? error = null;
            try
            {
                if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size)) ThrowNative("Cannot initialize worker handle list");
                initialized = true;
                Marshal.WriteIntPtr(handles, 0, childInput.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, IntPtr.Size, childOutput.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, 2 * IntPtr.Size, childError.DangerousGetHandle());
                if (!UpdateProcThreadAttribute(attributes, 0, (nuint)0x00020002, handles,
                    (nuint)(3 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) ThrowNative("Cannot restrict worker inherited handles");
                var startup = new StartupInfoEx
                {
                    StartupInfo = new StartupInfo
                    {
                        Size = Marshal.SizeOf<StartupInfoEx>(), Flags = 0x100,
                        Input = childInput.DangerousGetHandle(), Output = childOutput.DangerousGetHandle(), Error = childError.DangerousGetHandle()
                    },
                    AttributeList = attributes
                };
                // CRT規則で引用し、shellを介さず同じ絶対exeを起動する。
                var command = new StringBuilder(QuoteArgument(executable) + " --config " + QuoteArgument(configPath) + " __delete-queue-worker");
                if (!CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, true,
                    0x08000000 | 0x00080000, IntPtr.Zero, null, ref startup, out var process))
                    ThrowNative("Cannot start deletion queue worker");
                // 起動後のprocess所有は保持せず、子の継続を親の寿命に依存させない。
                CloseHandle(process.Thread); CloseHandle(process.Process);
                input = new FileStream(DuplicateParent(parentInput), FileAccess.Write, 1, false);
                output = new FileStream(DuplicateParent(parentOutput), FileAccess.Read, 4096, false);
                error = new FileStream(DuplicateParent(parentError), FileAccess.Read, 4096, false);
                return new WorkerPipes(input, output, error);
            }
            catch { input?.Dispose(); output?.Dispose(); error?.Dispose(); throw; }
            finally
            {
                if (initialized) DeleteProcThreadAttributeList(attributes);
                Marshal.FreeHGlobal(handles); Marshal.FreeHGlobal(attributes);
            }
        }

        private static SafeFileHandle DuplicateParent(SafeFileHandle handle)
        {
            var process = GetCurrentProcess();
            if (!DuplicateHandle(process, handle, process, out var duplicate, 0, false, 2)) ThrowNative("Cannot retain worker pipe");
            return duplicate;
        }

        private static string QuoteArgument(string value)
        {
            var result = new StringBuilder("\"");
            var slashes = 0;
            foreach (var character in value)
            {
                if (character == '\\') { slashes++; continue; }
                result.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
                result.Append(character); slashes = 0;
            }
            result.Append('\\', slashes * 2); result.Append('"');
            return result.ToString();
        }

        private static void ThrowNative(string message)
        {
            var error = new Win32Exception(Marshal.GetLastWin32Error());
            throw new IOException(message + ": " + error.Message, error);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int InheritHandle; }
        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            internal int Size;
            internal IntPtr Reserved, Desktop, Title;
            internal int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            internal short ShowWindow, Reserved2Size;
            internal IntPtr Reserved2, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx { internal StartupInfo StartupInfo; internal IntPtr AttributeList; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation { internal IntPtr Process, Thread; internal uint ProcessId, ThreadId; }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref SecurityAttributes attributes, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref nuint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, nuint attribute, IntPtr value, nuint size, IntPtr previous, IntPtr returnedSize);
        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags,
            IntPtr environment, string? directory, ref StartupInfoEx startup, out ProcessInformation process);
        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DuplicateHandle(IntPtr sourceProcess, SafeFileHandle source, IntPtr targetProcess,
            out SafeFileHandle target, uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);
    }
}
