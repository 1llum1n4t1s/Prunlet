using System.Text.Json;
using System.Reflection;
using Prunlet.Core;

namespace Prunlet.Protocol;

internal sealed class McpServer(DeletionService service, Func<object> listOperations)
{
    private bool initialized;
    private bool ready;
    private readonly object writerGate = new();
    private static readonly string[] SupportedVersions = ["2025-11-25", "2025-06-18", "2024-11-05"];

    public async Task RunAsync(TextReader input, TextWriter output)
    {
        var reader = new BoundedInputReader(input, BoundedInputReader.RequestLimit);
        var pending = new List<Task>();
        using var requests = new SemaphoreSlim(4, 4);
        try
        {
        while (await reader.ReadLineAsync() is { } line)
        {
            foreach (var failed in pending.Where(task => task.IsFaulted)) await failed;
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
                var parameters = request.TryGetProperty("params", out var p) ? p.Clone() : default;
                var parallelDelete = method == "tools/call" && ready && parameters.ValueKind == JsonValueKind.Object
                    && parameters.TryGetProperty("name", out var toolName) && toolName.ValueKind == JsonValueKind.String
                    && toolName.GetString() == "delete_files";
                if (method == "tools/call" && !parallelDelete)
                {
                    // レジストリのprocess privilege等を並行するfile workerへ持ち込まない。
                    await Task.WhenAll(pending);
                    pending.Clear();
                }
                if (parallelDelete)
                {
                    var requestService = service.CreateRequestService();
                    await requests.WaitAsync();
                    var requestIdCopy = id;
                    pending.RemoveAll(task => task.IsCompletedSuccessfully);
                    pending.Add(Task.Run(() =>
                    {
                        try
                        {
                            object toolResponse;
                            try { toolResponse = new { jsonrpc = "2.0", id = requestIdCopy, result = DispatchWithProgress(method, parameters, output, requestService) }; }
                            catch (RpcException ex) { toolResponse = Error(requestIdCopy, ex.Code, ex.Message); }
                            catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
                            { toolResponse = Error(requestIdCopy, -32603, ex.Message); }
                            WriteResponse(output, toolResponse);
                        }
                        finally { requests.Release(); }
                    }));
                    continue;
                }
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
            WriteResponse(output, response);
        }
        }
        finally { await Task.WhenAll(pending); }
    }

    private void WriteResponse(TextWriter output, object response)
    {
        lock (writerGate)
        {
            output.WriteLine(JsonSerializer.Serialize(response, Program.JsonOptions));
            output.Flush();
        }
    }

    private object DispatchWithProgress(string method, JsonElement parameters, TextWriter output, DeletionService? requestService = null)
    {
        var targetService = requestService ?? service;
        // 進捗は要求に紐づけ、最終応答後やtokenのない要求へ流さない。
        if (method != "tools/call" || parameters.ValueKind != JsonValueKind.Object ||
            !parameters.TryGetProperty("_meta", out var metadata) || metadata.ValueKind != JsonValueKind.Object ||
            !metadata.TryGetProperty("progressToken", out var token) ||
            (token.ValueKind != JsonValueKind.String && (token.ValueKind != JsonValueKind.Number || !token.TryGetInt64(out _))))
            return Dispatch(method, parameters, targetService);

        long progress = 0;
        var active = true;
        void Report(TimeSpan elapsed, bool acquired)
        {
            lock (writerGate)
            {
                if (!active) return;
                WriteResponse(output, new
                {
                    jsonrpc = "2.0", method = "notifications/progress",
                    @params = new { progressToken = token, progress = ++progress, message = Program.RecoveryLockMessage(elapsed, acquired) }
                });
            }
        }
        targetService.RecoveryLockProgress += Report;
        try { return Dispatch(method, parameters, targetService); }
        finally
        {
            lock (writerGate) active = false;
            targetService.RecoveryLockProgress -= Report;
        }
    }

    private object Dispatch(string method, JsonElement parameters, DeletionService targetService)
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
                instructions = "Use delete_files for authorized absolute Windows files and empty directories without a target directory allowlist. Set recursive=true for directory contents. Files and directories normally go to the Windows Recycle Bin without Prunlet operation records. If Windows reports that an item is too large for the bin and its original identity is confirmed, Prunlet attempts to permanently delete its original name. Only confirmed removal returns permanently_deleted; an uncertain attempt returns ambiguous. A permanently deleted name cannot be restored from the bin. Other recycling failures do not trigger permanent deletion. Dry-run cannot predict the final disposition. File results have no operationId. For ambiguous results, do not resend deletion; inspect the source and Windows Recycle Bin. Windows controls bin retention and users may empty it. Metadata and legacy volume recovery directories and their ancestors remain protected. Links are handled without following their targets. Hard links share content with surviving aliases. Prunlet retention and capacity settings default to 7 days and 1 GiB for registry snapshots only, never for the Windows bin. list_operations lists registry recovery only. Use delete_registry for explicitly authorized local keys/values with required view 32 or 64, and restore_registry for their operationId. Empty valueName selects the default value; omitted valueName selects the key. Full key ACL snapshots require SeSecurityPrivilege; no automatic elevation or nontransactional fallback. Existing host approvals and policies still apply."
            };
        }
        if (!ready) throw new RpcException(-32600, "Initialize and send notifications/initialized first.");
        return method switch
        {
            "tools/list" => new { tools = Tools() },
            "tools/call" => CallTool(parameters, targetService),
            _ => throw new RpcException(-32601, $"Unknown method: {method}")
        };
    }

    private object CallTool(JsonElement parameters, DeletionService service)
    {
        var name = StringProperty(parameters, "name");
        var args = parameters.TryGetProperty("arguments", out var a) ? a : JsonSerializer.SerializeToElement(new { });
        if (args.ValueKind != JsonValueKind.Object) throw new RpcException(-32602, "Arguments must be an object.");
        if (name is not "delete_files" and not "delete_registry" and not "restore_registry" and not "reconcile_registry" and not "list_operations")
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
            name = "delete_files", title = "Delete files and folders",
            description = "Delete authorized absolute Windows files and empty directories without persisting operation records. Items normally go to the Windows Recycle Bin; if Windows reports a file or folder too large for the bin and its original identity is confirmed, Prunlet attempts permanent deletion. Confirmed removal returns permanently_deleted; an uncertain attempt returns ambiguous. Other recycling failures never trigger permanent deletion. Dry-run cannot predict the final disposition. Ambiguous results require inspecting the source and Windows Recycle Bin without resending deletion. Set recursive=true for folder contents. Metadata and legacy recovery storage stay protected. Hard links retain shared content. Does not expand wildcards or follow link targets.",
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
            name = "list_operations", title = "List registry recovery operations",
            description = "List registry operation ids available in the configured recovery directory. File and folder deletions have no Prunlet operation records.",
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
