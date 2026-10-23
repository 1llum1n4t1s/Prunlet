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
                instructions = "Use delete_files for authorized absolute Windows files and empty directories without a target directory allowlist. Set recursive=true to include directory contents. Metadata and volume recovery directories and their ancestors are protected. Prunlet scans capacity and persists a manifest before moving each selected root into private recovery storage on the same volume. Recovery data expire after 7 days by default; a shared 10 GiB budget may evict older operations sooner. Use restore_files with operationId while recovery data remain. Restore consumes moved items and never overwrites existing destinations; legacy copy records remain supported. Use dryRun to inspect targets. Symbolic links and junctions move as links without following their targets. ADS and case-sensitive directory names are preserved. Moved hard links share content with surviving aliases, so alias writes also change the recovery data; legacy copies restore as independent snapshots. Wildcards and unknown reparse tags are unsupported. Use delete_registry for explicitly authorized local registry keys/values with required view 32 or 64, and restore_registry for their operationId. Empty valueName selects the default value; omitted valueName selects the key. Full key ACL snapshots require SeSecurityPrivilege; no automatic elevation or nontransactional fallback. Existing host approvals and policies still apply."
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
        if (name is not "delete_files" and not "restore_files" and not "delete_registry" and not "restore_registry" and not "reconcile_registry" and not "list_operations")
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
                    result = service.RestoreFiles(StringProperty(args, "operationId"));
                    break;
                case "delete_registry":
                    RejectExtraProperties(args, "path", "view", "valueName", "recursive", "dryRun");
                    var view = StringProperty(args, "view");
                    if (view is not ("32" or "64")) throw new RpcException(-32602, "View must be 32 or 64.");
                    if (args.TryGetProperty("valueName", out var valueName) && valueName.ValueKind != JsonValueKind.String)
                        throw new RpcException(-32602, "ValueName must be a string, including an empty string for the default value.");
                    if (args.TryGetProperty("recursive", out var registryRecursive) && registryRecursive.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
                        throw new RpcException(-32602, "Recursive must be boolean.");
                    if (args.TryGetProperty("dryRun", out var registryDryRun) && registryDryRun.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
                        throw new RpcException(-32602, "DryRun must be boolean.");
                    if (valueName.ValueKind == JsonValueKind.String && registryRecursive.ValueKind == JsonValueKind.True)
                        throw new RpcException(-32602, "Recursive cannot be combined with valueName.");
                    result = service.DeleteRegistry(new RegistryDeleteRequest
                    {
                        Path = StringProperty(args, "path"), View = view,
                        ValueName = valueName.ValueKind == JsonValueKind.String ? valueName.GetString() : null,
                        Recursive = registryRecursive.ValueKind == JsonValueKind.True
                    }, registryDryRun.ValueKind == JsonValueKind.True);
                    break;
                case "restore_registry":
                    RejectExtraProperties(args, "operationId");
                    result = service.RestoreRegistry(StringProperty(args, "operationId"));
                    break;
                case "reconcile_registry":
                    RejectExtraProperties(args, "operationId");
                    result = service.ReconcileRegistry(StringProperty(args, "operationId"));
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
            name = "restore_files", title = "Restore a file deletion operation",
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
            name = "delete_registry", title = "Back up and delete a registry key or value",
            description = "Delete an explicitly authorized local HKCU/HKLM/HKU key or literal value in required view 32 or 64. Omit valueName for a key; empty string selects the default value. Key trees require recursive=true. Full key Owner/Group/DACL/SACL backup requires SeSecurityPrivilege; no automatic elevation or nontransactional fallback. Recovery shares the configured retention and capacity budget. Host approvals and policies still apply.",
            inputSchema = new
            {
                type = "object", properties = new
                {
                    path = new { type = "string" }, view = new { type = "string", @enum = new[] { "32", "64" } },
                    valueName = new { type = "string", description = "Literal value name; empty string selects the default value. Omit to delete the key." },
                    recursive = new { type = "boolean" }, dryRun = new { type = "boolean" }
                },
                required = new[] { "path", "view" }, additionalProperties = false
            },
            annotations = new { readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false }
        },
        new
        {
            name = "restore_registry", title = "Restore a registry deletion operation",
            description = "Restore a retained registry operation by operationId in its recorded view. Refuse existing destinations, including an empty existing default value. Restore consumes recovery data after a successful transaction. Insufficient owner/SACL permissions or ambiguous commit state preserve recovery data and do not fall back.",
            inputSchema = new
            {
                type = "object", properties = new { operationId = new { type = "string" } },
                required = new[] { "operationId" }, additionalProperties = false
            },
            annotations = new { readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false }
        },
        new
        {
            name = "reconcile_registry", title = "Inspect a registry operation outcome",
            description = "Read retained receipts for the original operationId after a disconnected native registry request. Does not repeat deletion or restore and does not infer an unconfirmed transaction outcome.",
            inputSchema = new
            {
                type = "object", properties = new { operationId = new { type = "string" } },
                required = new[] { "operationId" }, additionalProperties = false
            },
            annotations = new { readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false }
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
