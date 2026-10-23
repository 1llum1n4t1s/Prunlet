using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Prunlet.Core;

internal sealed class RegistrySessionDescriptor
{
    public int Schema { get; set; } = 1;
    public string PipeName { get; set; } = "";
    public string Capability { get; set; } = "";
    public DateTimeOffset ExpiresUtc { get; set; }
    public uint ServerProcessId { get; set; }
    public long ServerCreationTime { get; set; }
    public uint WindowsSessionId { get; set; }
    public string AuthenticationId { get; set; } = "";
    public string ExecutableSha256 { get; set; } = "";
    public string ConfigurationSha256 { get; set; } = "";
    public RegistryScopeIdentity Scope { get; set; } = new();
}

internal sealed class RegistrySessionRequest
{
    public string Operation { get; set; } = "";
    public string OperationId { get; set; } = "";
    public RegistryDeleteRequest? Delete { get; set; }
    public bool DryRun { get; set; }
    public string ConfigurationSha256 { get; set; } = "";
}

internal sealed class RegistrySessionFrame
{
    public string Kind { get; set; } = "";
    public string? Challenge { get; set; }
    public RegistryScopeIdentity? Scope { get; set; }
    public string? Authentication { get; set; }
    public RegistrySessionRequest? Request { get; set; }
    public string? OperationId { get; set; }
    public JsonElement? Result { get; set; }
    public string? Error { get; set; }
    public double ElapsedSeconds { get; set; }
    public bool Acquired { get; set; }
}

internal static class RegistrySessionWire
{
    internal static readonly JsonSerializerOptions Options = new(PrunletConfig.JsonOptions)
    {
        PropertyNameCaseInsensitive = false, MaxDepth = 12,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
    private const int MaximumFrame = 1024 * 1024;
    internal static void Write(Stream stream, RegistrySessionFrame frame)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(frame, Options);
        if (bytes.Length > MaximumFrame) throw new InvalidDataException("Registry session response is too large.");
        Span<byte> header = stackalloc byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
        stream.Write(header); stream.Write(bytes); stream.Flush();
    }

    internal static RegistrySessionFrame Read(Stream stream)
    {
        Span<byte> header = stackalloc byte[4]; stream.ReadExactly(header);
        var bytes = new byte[Size(header, MaximumFrame)]; stream.ReadExactly(bytes);
        return Parse(bytes);
    }

    internal static async Task<RegistrySessionFrame> ReadRequestAsync(Stream stream, CancellationToken cancellation)
    {
        var header = new byte[4]; await stream.ReadExactlyAsync(header, cancellation);
        var bytes = new byte[Size(header, 65536)]; await stream.ReadExactlyAsync(bytes, cancellation);
        return Parse(bytes);
    }

    private static int Size(ReadOnlySpan<byte> header, int limit)
    {
        var size = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (size is <= 0 || size > limit) throw new InvalidDataException("Registry session frame exceeds its limit.");
        return size;
    }

    private static RegistrySessionFrame Parse(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 12 });
        Unique(document.RootElement);
        return document.RootElement.Deserialize<RegistrySessionFrame>(Options) ?? throw new InvalidDataException("Empty registry session frame.");
        static void Unique(JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Object)
            {
                var names = new HashSet<string>(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject())
                {
                    if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate registry session field.");
                    Unique(property.Value);
                }
            }
            else if (element.ValueKind == JsonValueKind.Array) foreach (var child in element.EnumerateArray()) Unique(child);
        }
    }

    internal static string Authenticate(byte[] capability, string challenge, RegistrySessionRequest request)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(request, Options);
        var nonce = Convert.FromBase64String(challenge);
        if (nonce.Length != 32) throw new InvalidDataException("Invalid registry session challenge.");
        var input = new byte[nonce.Length + body.Length]; nonce.CopyTo(input, 0); body.CopyTo(input, nonce.Length);
        return Convert.ToHexStringLower(HMACSHA256.HashData(capability, input));
    }

    internal static void ValidateRequest(RegistrySessionRequest request, string fingerprint)
    {
        if (request.ConfigurationSha256 != fingerprint || !Guid.TryParseExact(request.OperationId, "N", out var id) || id.ToString("N") != request.OperationId)
            throw new InvalidDataException("Registry session configuration or operation identity differs.");
        if (request.Operation == "delete")
        {
            if (request.Delete is null) throw new InvalidDataException("Registry delete request is missing.");
            _ = NativeRegistry.Target(request.Delete);
        }
        else if (request.Operation is "restore" or "reconcile")
        {
            if (request.Delete is not null || request.DryRun) throw new InvalidDataException("Invalid registry recovery request.");
        }
        else throw new InvalidDataException("Unknown registry session operation.");
    }
}

internal static class RegistrySessionServer
{
    internal static async Task RunAsync(PrunletConfig config, int minutes, bool assertNativeWindows)
    {
        config.Validate();
        if (config.RegistryScope != "nativeWindows" || config.RegistrySessionFile is null)
            throw new ArgumentException("registry-session requires nativeWindows configuration and an absolute registrySessionFile.");
        if (!assertNativeWindows) throw new ArgumentException("Explicit --assert-native-windows is required when manually starting the session from a normal Windows desktop.");
        if (minutes is < 1 or > 60) throw new ArgumentException("Session minutes must be between 1 and 60.");
        var scope = NativeRegistry.VerifyNativeSessionContext();
        using var self = RegistrySessionNative.Self();
        var descriptor = new RegistrySessionDescriptor
        {
            PipeName = "prunlet-registry-" + Guid.NewGuid().ToString("N"), Capability = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)),
            ExpiresUtc = DateTimeOffset.UtcNow.AddMinutes(minutes), ServerProcessId = self.ProcessId, ServerCreationTime = self.CreationTime,
            WindowsSessionId = self.SessionId, AuthenticationId = self.AuthenticationId, ExecutableSha256 = self.ExecutableHash,
            ConfigurationSha256 = RegistrySessionConfiguration.Fingerprint(config), Scope = scope
        };
        var capability = Convert.FromBase64String(descriptor.Capability);
        using var directories = PathPolicy.PinRecoveryDirectories(Path.GetDirectoryName(config.RegistrySessionFile)!);
        NamedPipeServerStream? nextPipe = RegistrySessionNative.CreatePipe(descriptor.PipeName, self.Sid);
        try
        {
            using var handle = NativeFiles.CreatePrivateRegistryFile(config.RegistrySessionFile);
            NativeFiles.Verify(handle, config.RegistrySessionFile); NativeFiles.VerifySingleLink(handle);
            NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.RejectNamedStreams(config.RegistrySessionFile);
            using var file = new FileStream(handle, FileAccess.ReadWrite);
            JsonSerializer.Serialize(file, descriptor, RegistrySessionWire.Options); file.Flush(true);
            using var stop = new CancellationTokenSource(descriptor.ExpiresUtc - DateTimeOffset.UtcNow);
            ConsoleCancelEventHandler cancel = (_, args) => { args.Cancel = true; stop.Cancel(); };
            Console.CancelKeyPress += cancel;
            try
            {
                Console.WriteLine(JsonSerializer.Serialize(new { status = "registry_session_ready", sessionFile = config.RegistrySessionFile, descriptor.ExpiresUtc, scope }, Program.JsonOptions));
                Console.Out.Flush();
                // 一度に一要求だけ。期限は新規受付を止め、開始済みCoreのcommit/rollbackには渡さない。
                while (!stop.IsCancellationRequested && DateTimeOffset.UtcNow < descriptor.ExpiresUtc)
                {
                    using var pipe = nextPipe ?? throw new InvalidOperationException("Registry session pipe is unavailable."); nextPipe = null;
                    try
                    {
                        await pipe.WaitForConnectionAsync(stop.Token);
                        using var client = RegistrySessionNative.PipePeer(pipe, server: true);
                        self.RequireSameLogonAndExecutable(client);
                        var challenge = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
                        RegistrySessionWire.Write(pipe, new RegistrySessionFrame { Kind = "challenge", Challenge = challenge, Scope = scope });
                        using var handshake = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                        handshake.CancelAfter(TimeSpan.FromSeconds(15));
                        var frame = await RegistrySessionWire.ReadRequestAsync(pipe, handshake.Token);
                        var request = frame.Request ?? throw new InvalidDataException("Missing registry session request.");
                        RegistrySessionWire.ValidateRequest(request, descriptor.ConfigurationSha256);
                        var authentication = RegistrySessionWire.Authenticate(capability, challenge, request);
                        if (frame.Kind != "request" || frame.Authentication is null || frame.Authentication.Length != authentication.Length
                            || !CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(frame.Authentication), Encoding.ASCII.GetBytes(authentication)))
                            throw new UnauthorizedAccessException("Registry session capability authentication failed.");
                        if (stop.IsCancellationRequested || DateTimeOffset.UtcNow >= descriptor.ExpiresUtc) throw new InvalidOperationException("Registry session has expired.");
                        client.RequireAlive();
                        RegistrySessionWire.Write(pipe, new RegistrySessionFrame { Kind = "accepted", OperationId = request.OperationId });
                        object? result = null;
                        // 同期Coreを同じthreadのeffective client token内で完結し、返信前に必ず戻す。
                        pipe.RunAsClient(() =>
                        {
                            using var token = RegistrySessionNative.DuplicateEffectiveToken(client);
                            WindowsIdentity.RunImpersonated(token, () =>
                            {
                                RegistryScopeIdentity.RequireExecutionMatch(scope, NativeRegistry.VerifyNativeSessionContext());
                                var service = new DeletionService(config, new RegistrySessionContext(scope));
                                service.RecoveryLockProgress += (elapsed, acquired) => TryWrite(pipe,
                                    new RegistrySessionFrame { Kind = "progress", ElapsedSeconds = elapsed.TotalSeconds, Acquired = acquired });
                                result = request.Operation switch
                                {
                                    "delete" => service.DeleteRegistryLocal(request.Delete!, request.DryRun, request.OperationId),
                                    "restore" => service.RestoreRegistry(request.OperationId),
                                    "reconcile" => service.ReconcileRegistry(request.OperationId),
                                    _ => throw new InvalidDataException("Unknown registry session operation.")
                                };
                            });
                        });
                        TryWrite(pipe, new RegistrySessionFrame { Kind = "result", Result = JsonSerializer.SerializeToElement(result, PrunletConfig.JsonOptions) });
                    }
                    catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
                    catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
                    {
                        TryWrite(pipe, new RegistrySessionFrame { Kind = "error", Error = ex.Message });
                    }
                    pipe.Dispose();
                    if (!stop.IsCancellationRequested && DateTimeOffset.UtcNow < descriptor.ExpiresUtc)
                        nextPipe = RegistrySessionNative.CreatePipe(descriptor.PipeName, self.Sid);
                }
            }
            finally { Console.CancelKeyPress -= cancel; }
            Console.WriteLine(JsonSerializer.Serialize(new { status = "registry_session_closed", sessionFile = config.RegistrySessionFile }, Program.JsonOptions));
        }
        finally { nextPipe?.Dispose(); CryptographicOperations.ZeroMemory(capability); }
    }

    private static void TryWrite(Stream pipe, RegistrySessionFrame frame)
    {
        try { RegistrySessionWire.Write(pipe, frame); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException) { }
    }
}

internal static class RegistrySessionClient
{
    internal static DeleteResult Delete(PrunletConfig config, RegistryDeleteRequest delete, bool dryRun, Action<TimeSpan, bool>? progress)
        => Call<DeleteResult>(config, new RegistrySessionRequest { Operation = "delete", OperationId = Guid.NewGuid().ToString("N"), Delete = delete, DryRun = dryRun }, progress);
    internal static RestoreResult Restore(PrunletConfig config, string id, Action<TimeSpan, bool>? progress)
        => Call<RestoreResult>(config, new RegistrySessionRequest { Operation = "restore", OperationId = id }, progress);
    internal static DeleteResult Reconcile(PrunletConfig config, string id, Action<TimeSpan, bool>? progress)
        => Call<DeleteResult>(config, new RegistrySessionRequest { Operation = "reconcile", OperationId = id }, progress);

    private static T Call<T>(PrunletConfig config, RegistrySessionRequest request, Action<TimeSpan, bool>? progress)
    {
        config.Validate();
        var path = config.RegistrySessionFile ?? throw new InvalidDataException("Registry session file is missing.");
        using var directories = PathPolicy.PinRecoveryDirectories(Path.GetDirectoryName(path)!);
        using var handle = RegistrySessionNative.OpenDescriptor(path);
        NativeFiles.Verify(handle, path); NativeFiles.VerifySingleLink(handle); NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.RejectNamedStreams(path);
        using var file = new FileStream(handle, FileAccess.Read);
        if (file.Length is <= 0 or > 16384) throw new InvalidDataException("Registry session descriptor size is invalid.");
        var descriptor = JsonSerializer.Deserialize<RegistrySessionDescriptor>(file, RegistrySessionWire.Options) ?? throw new InvalidDataException("Registry session descriptor is empty.");
        RegistryScopeIdentity.Validate(descriptor.Scope);
        request.ConfigurationSha256 = RegistrySessionConfiguration.Fingerprint(config);
        RegistrySessionWire.ValidateRequest(request, descriptor.ConfigurationSha256);
        using var self = RegistrySessionNative.Self();
        if (descriptor.Schema != 1 || descriptor.Scope.Kind != "nativeWindows" || descriptor.Scope.OwnerSid != self.Sid
            || descriptor.AuthenticationId != self.AuthenticationId || descriptor.WindowsSessionId != self.SessionId
            || descriptor.ExecutableSha256 != self.ExecutableHash || descriptor.ServerProcessId == 0 || descriptor.ServerCreationTime <= 0
            || descriptor.PipeName is null || !System.Text.RegularExpressions.Regex.IsMatch(descriptor.PipeName, "^prunlet-registry-[0-9a-f]{32}$")
            || descriptor.ExpiresUtc <= DateTimeOffset.UtcNow || descriptor.ExpiresUtc > DateTimeOffset.UtcNow.AddMinutes(61))
            throw new UnauthorizedAccessException("Registry session is expired or its scope, executable, or Windows logon differs.");
        var capability = Convert.FromBase64String(descriptor.Capability);
        if (capability.Length != 32) throw new InvalidDataException("Registry session capability has an invalid size.");
        var accepted = false;
        try
        {
            using var pipe = new NamedPipeClientStream(".", descriptor.PipeName, PipeDirection.InOut, PipeOptions.None, TokenImpersonationLevel.Impersonation);
            pipe.Connect(5000);
            RegistrySessionNative.VerifyPipeSecurity(pipe.SafePipeHandle, self.Sid);
            using var server = RegistrySessionNative.PipePeer(pipe, server: false);
            self.RequireSameLogonAndExecutable(server);
            if (server.ProcessId != descriptor.ServerProcessId || server.CreationTime != descriptor.ServerCreationTime)
                throw new UnauthorizedAccessException("Registry session server process differs from the capability owner.");
            var challenge = RegistrySessionWire.Read(pipe);
            if (challenge.Kind != "challenge" || challenge.Challenge is null || challenge.Scope != descriptor.Scope)
                throw new InvalidDataException("Registry session challenge or execution scope differs from the capability file.");
            RegistrySessionWire.Write(pipe, new RegistrySessionFrame
            {
                Kind = "request", Request = request,
                Authentication = RegistrySessionWire.Authenticate(capability, challenge.Challenge, request)
            });
            while (true)
            {
                var frame = RegistrySessionWire.Read(pipe);
                switch (frame.Kind)
                {
                    case "accepted" when !accepted && frame.OperationId == request.OperationId:
                        accepted = true; break;
                    case "progress" when accepted:
                        if (!double.IsFinite(frame.ElapsedSeconds) || frame.ElapsedSeconds < 0) throw new InvalidDataException("Invalid registry progress.");
                        progress?.Invoke(TimeSpan.FromSeconds(frame.ElapsedSeconds), frame.Acquired); break;
                    case "result" when accepted && frame.Result is JsonElement result:
                        return result.Deserialize<T>(PrunletConfig.JsonOptions) ?? throw new InvalidDataException("Empty registry session result.");
                    case "error": throw new RegistrySessionRejectedException(frame.Error ?? "Registry session rejected the request.");
                    default: throw new InvalidDataException("Unexpected registry session response.");
                }
            }
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or JsonException)
        {
            throw new IOException($"Native registry session communication failed. Operation ID: {request.OperationId}. Outcome may be unknown; do not repeat deletion. Use registry-reconcile with this ID. {ex.Message}", ex);
        }
        finally { CryptographicOperations.ZeroMemory(capability); }
    }

    private sealed class RegistrySessionRejectedException(string message) : InvalidOperationException(message);
}
