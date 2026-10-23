using System.Text.Json;
using System.Reflection;
using Prunlet.Core;

namespace Prunlet.Protocol;

internal sealed class McpServer(DeletionService service, Func<object> listOperations)
{
    private bool initialized;
    private bool ready;
    private static readonly string[] SupportedVersions = ["2025-11-25", "2025-06-18", "2024-11-05"];

    public async Task RunAsync(TextReader input, TextWriter output)
    {
        var reader = new BoundedInputReader(input, BoundedInputReader.RequestLimit);
        while (await reader.ReadLineAsync() is { } line)
        {
            if (line.IsWhiteSpace) continue;
            JsonElement? id = null;
            object response;
            try
            {
                if (line.ExceedsLimit) throw new RpcException(-32600, "Request exceeds 1 MiB.");
                using var document = JsonDocument.Parse(line.Text);
                var request = document.RootElement;
                if (request.ValueKind != JsonValueKind.Object) throw new RpcException(-32600, "Expected a JSON-RPC object.");
                if (request.TryGetProperty("id", out var requestId))
                {
                    if (requestId.ValueKind is not JsonValueKind.String and not JsonValueKind.Number)
                        throw new RpcException(-32600, "Request id must be a string or number.");
                    id = requestId.Clone();
                }
                if (!request.TryGetProperty("jsonrpc", out var rpc) || rpc.GetString() != "2.0" ||
                    !request.TryGetProperty("method", out var methodElement) || methodElement.ValueKind != JsonValueKind.String)
                    throw new RpcException(-32600, "Invalid JSON-RPC request.");
                var method = methodElement.GetString()!;
                if (id is null)
                {
                    // tools/callをnotificationとして受けても副作用を起こさない。
                    if (method == "notifications/initialized" && initialized) ready = true;
                    continue;
                }
                var parameters = request.TryGetProperty("params", out var p) ? p : default;
                var result = DispatchWithProgress(method, parameters, output);
                response = new { jsonrpc = "2.0", id, result };
            }
            catch (JsonException)
            {
                response = Error(id, -32700, "Invalid JSON.");
            }
            catch (RpcException ex)
            {
                response = Error(id, ex.Code, ex.Message);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
            {
                response = Error(id, -32603, ex.Message);
            }
            await output.WriteLineAsync(JsonSerializer.Serialize(response, Program.JsonOptions));
            await output.FlushAsync();
        }
    }

    private object DispatchWithProgress(string method, JsonElement parameters, TextWriter output)
    {
        // 進捗は要求に紐づけ、最終応答後やtokenのない要求へ流さない。
        if (method != "tools/call" || parameters.ValueKind != JsonValueKind.Object ||
            !parameters.TryGetProperty("_meta", out var metadata) || metadata.ValueKind != JsonValueKind.Object ||
            !metadata.TryGetProperty("progressToken", out var token) ||
            (token.ValueKind != JsonValueKind.String && (token.ValueKind != JsonValueKind.Number || !token.TryGetInt64(out _))))
            return Dispatch(method, parameters);

        long progress = 0;
        void Report(TimeSpan elapsed, bool acquired)
        {
            output.WriteLine(JsonSerializer.Serialize(new
            {
                jsonrpc = "2.0", method = "notifications/progress",
                @params = new { progressToken = token, progress = ++progress, message = Program.RecoveryLockMessage(elapsed, acquired) }
            }, Program.JsonOptions));
            output.Flush();
        }
        service.RecoveryLockProgress += Report;
        try { return Dispatch(method, parameters); }
        finally { service.RecoveryLockProgress -= Report; }
    }

    private object Dispatch(string method, JsonElement parameters)
    {
        if (method == "ping") return new { };
        if (method == "initialize")
        {
            if (initialized) throw new RpcException(-32600, "Already initialized.");
            var requestedVersion = StringProperty(parameters, "protocolVersion");
            initialized = true;
            return new
            {
                protocolVersion = SupportedVersions.Contains(requestedVersion) ? requestedVersion : SupportedVersions[0],
                capabilities = new { tools = new { listChanged = false } },
                serverInfo = new { name = "prunlet", title = "Prunlet", version = typeof(McpServer).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion },
                instructions = "Use delete_files for authorized absolute Windows files and empty directories without a target directory allowlist. Set recursive=true to include directory contents. Metadata and volume recovery directories and their ancestors are protected. Prunlet scans capacity and persists a manifest before moving each selected root into private recovery storage on the same volume. Recovery data expire after 7 days by default; a shared 10 GiB budget may evict older operations sooner. Use restore_files with operationId while recovery data remain. Restore consumes moved items and never overwrites existing destinations; legacy copy records remain supported. Use dryRun to inspect targets. Symbolic links and junctions move as links without following their targets. ADS and case-sensitive directory names are preserved. Moved hard links share content with surviving aliases, so alias writes also change the recovery data; legacy copies restore as independent snapshots. Wildcards and unknown reparse tags are unsupported. Existing host approvals and policies still apply."
            };
        }
        if (!ready) throw new RpcException(-32600, "Initialize and send notifications/initialized first.");
        return method switch
        {
            "tools/list" => new { tools = Tools() },
            "tools/call" => CallTool(parameters),
            _ => throw new RpcException(-32601, $"Unknown method: {method}")
        };
    }

    private object CallTool(JsonElement parameters)
    {
        var name = StringProperty(parameters, "name");
        var args = parameters.TryGetProperty("arguments", out var a) ? a : JsonSerializer.SerializeToElement(new { });
        if (args.ValueKind != JsonValueKind.Object) throw new RpcException(-32602, "Arguments must be an object.");
        if (name is not "delete_files" and not "restore_files" and not "list_operations")
            throw new RpcException(-32602, $"Unknown tool: {name}");
        object result;
        try
        {
            switch (name)
            {
                case "delete_files":
                    RejectExtraProperties(args, "paths", "dryRun", "recursive");
                    if (!args.TryGetProperty("paths", out var paths) || paths.ValueKind != JsonValueKind.Array || paths.GetArrayLength() == 0 || paths.GetArrayLength() > 256)
                        throw new RpcException(-32602, "Paths must contain 1 to 256 strings.");
                    if (paths.EnumerateArray().Any(path => path.ValueKind != JsonValueKind.String))
                        throw new RpcException(-32602, "Each path must be a string.");
                    if (args.TryGetProperty("dryRun", out var dryRun) && dryRun.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
                        throw new RpcException(-32602, "DryRun must be boolean.");
                    if (args.TryGetProperty("recursive", out var recursive) && recursive.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
                        throw new RpcException(-32602, "Recursive must be boolean.");
                    result = service.Delete(paths.EnumerateArray().Select(path => path.GetString()!).ToArray(), dryRun.ValueKind == JsonValueKind.True, recursive.ValueKind == JsonValueKind.True);
                    break;
                case "restore_files":
                    RejectExtraProperties(args, "operationId");
                    result = service.Restore(StringProperty(args, "operationId"));
                    break;
                default:
                    RejectExtraProperties(args);
                    result = listOperations();
                    break;
            }
        }
        catch (RpcException) { throw; }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            return new { content = new[] { new { type = "text", text = ex.Message } }, isError = true };
        }
        return new
        {
            content = new[] { new { type = "text", text = JsonSerializer.Serialize(result, Program.JsonOptions) } },
            structuredContent = result,
            isError = Program.HasErrors(result)
        };
    }

    private static object[] Tools() =>
    [
        new
        {
            name = "delete_files", title = "Move files and folders into recovery storage",
            description = "Delete authorized absolute Windows files and empty directories by moving each selected root into private recovery storage on the same volume after a capacity scan and durable manifest. Set recursive=true to move a folder with its contents. Recovery data expire after 7 days and share a 10 GiB budget by default. Metadata and volume recovery directories and their ancestors are protected. Moved hard links still share content with surviving aliases. Does not expand wildcards or follow links.",
            inputSchema = new
            {
                type = "object", properties = new
                {
                    paths = new { type = "array", items = new { type = "string" }, minItems = 1, maxItems = 256 },
                    dryRun = new { type = "boolean", description = "Inspect without changing files or directories." },
                    recursive = new { type = "boolean", description = "Explicitly include all files and subdirectories of directory targets. Defaults to false." }
                },
                required = new[] { "paths" }, additionalProperties = false
            },
            annotations = new { readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false }
        },
        new
        {
            name = "restore_files", title = "Restore a deletion operation",
            description = "Restore retained recovery data by operationId. Moving an item back consumes its recovery payload and refuses any existing destination. Legacy copy records restore as independent snapshots without overwriting existing files.",
            inputSchema = new
            {
                type = "object", properties = new { operationId = new { type = "string" } },
                required = new[] { "operationId" }, additionalProperties = false
            },
            annotations = new { readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false }
        },
        new
        {
            name = "list_operations", title = "List recovery operations",
            description = "List operation ids available in the configured recovery directory.",
            inputSchema = new { type = "object", properties = new { }, additionalProperties = false },
            annotations = new { readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false }
        }
    ];

    private static string StringProperty(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(name, out var item) || item.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(item.GetString()))
            throw new RpcException(-32602, $"Missing or invalid string: {name}");
        return item.GetString()!;
    }

    private static void RejectExtraProperties(JsonElement args, params string[] allowed)
    {
        if (args.EnumerateObject().Any(p => !allowed.Contains(p.Name, StringComparer.Ordinal)))
            throw new RpcException(-32602, "Unknown argument property.");
    }

    private static object Error(JsonElement? id, int code, string message) => new { jsonrpc = "2.0", id, error = new { code, message } };
    private sealed class RpcException(int code, string message) : Exception(message) { public int Code { get; } = code; }
}
