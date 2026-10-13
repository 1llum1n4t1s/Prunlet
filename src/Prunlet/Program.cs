using System.Text.Json;
using Prunlet.Core;
using Prunlet.Protocol;

namespace Prunlet;

internal static class Program
{
    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false
    };

    private static async Task<int> Main(string[] args)
    {
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        try
        {
            if (args.Length == 0 || args is ["--help"] or ["help"])
            {
                Console.WriteLine("""
                    Prunlet — Windows file deletion with verified recovery copies.
                    prunlet --config <absolute-json-path> init --allowed-root <directory> [...] --backup-directory <directory>
                    prunlet --config <absolute-json-path> delete [--dry-run] -- <absolute-file-path> [...]
                    prunlet --config <absolute-json-path> restore <operation-id>
                    prunlet --config <absolute-json-path> operations
                    prunlet --config <absolute-json-path> mcp
                    prunlet --config <absolute-json-path> hook --hook-script <absolute-ps1-path>
                    Directories, recursive deletion, wildcard expansion and links are unsupported.
                    """);
                return 0;
            }

            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Prunlet requires Windows.");
            if (args.Length < 3 || args[0] != "--config")
                throw new ArgumentException("Specify --config <absolute-json-path> before the command.");
            var configPath = Path.GetFullPath(args[1]);
            if (!Path.IsPathFullyQualified(args[1])) throw new ArgumentException("Config path must be absolute.");
            var command = args[2];
            var commandArgs = args[3..];
            if (command == "init") return Initialize(configPath, commandArgs);
            if (command == "hook")
            {
                if (commandArgs.Length != 2 || commandArgs[0] != "--hook-script")
                    throw new ArgumentException("Hook requires --hook-script <absolute-ps1-path>.");
                return await HookRouter.RunAsync(configPath, commandArgs[1]);
            }
            var config = PrunletConfig.Load(configPath);
            var service = new DeletionService(config);
            object result;
            switch (command)
            {
                case "delete":
                    var dryRun = commandArgs.Length > 0 && commandArgs[0] == "--dry-run";
                    var offset = dryRun ? 1 : 0;
                    if (commandArgs.Length <= offset + 1 || commandArgs[offset] != "--")
                        throw new ArgumentException("Use delete [--dry-run] -- <absolute-file-path> [...].");
                    result = service.Delete(commandArgs[(offset + 1)..], dryRun);
                    break;
                case "restore":
                    if (commandArgs.Length != 1) throw new ArgumentException("Restore requires exactly one operation id.");
                    result = service.Restore(commandArgs[0]);
                    break;
                case "operations":
                    if (commandArgs.Length != 0) throw new ArgumentException("Operations accepts no arguments.");
                    result = ListOperations(config);
                    break;
                case "mcp":
                    if (commandArgs.Length != 0) throw new ArgumentException("MCP accepts no arguments.");
                    await new McpServer(service, () => ListOperations(config)).RunAsync(Console.In, Console.Out);
                    return 0;
                default:
                    throw new ArgumentException($"Unknown command: {command}");
            }
            Write(result);
            return HasErrors(result) ? 1 : 0;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            // MCP起動前のエラーもプロトコルstdoutへ混ぜない。
            if (args.Contains("mcp", StringComparer.Ordinal)) Console.Error.WriteLine(ex.Message);
            else Write(new { error = ex.Message, type = ex.GetType().Name });
            return 1;
        }
    }

    private static int Initialize(string configPath, string[] args)
    {
        var roots = new List<string>();
        string? backupDirectory = null;
        for (var i = 0; i < args.Length; i++)
        {
            if (i + 1 >= args.Length) throw new ArgumentException("Init options require values.");
            switch (args[i])
            {
                case "--allowed-root": roots.Add(args[++i]); break;
                case "--backup-directory" when backupDirectory is null: backupDirectory = args[++i]; break;
                default: throw new ArgumentException($"Unknown or repeated init option: {args[i]}");
            }
        }
        if (roots.Count == 0 || backupDirectory is null) throw new ArgumentException("Specify allowed roots and a backup directory.");
        var config = new PrunletConfig { Schema = 1, AllowedRoots = roots.ToArray(), BackupDirectory = backupDirectory };
        config.Validate();
        var parent = Path.GetDirectoryName(configPath)!;
        if (!Directory.Exists(parent)) throw new ArgumentException("Config parent directory must already exist.");
        // 初期化は既存の設定を上書きしない。
        using (var stream = new FileStream(configPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            JsonSerializer.Serialize(stream, config, JsonOptions);
            stream.Flush(true);
        }
        Write(new { status = "initialized", configPath, config.AllowedRoots, config.BackupDirectory });
        return 0;
    }

    internal static object ListOperations(PrunletConfig config)
    {
        config.Validate();
        return new
        {
            operations = Directory.EnumerateDirectories(config.BackupDirectory)
                .Where(p => Guid.TryParseExact(Path.GetFileName(p), "N", out _))
                .Select(p => new { operationId = Path.GetFileName(p) })
                .OrderBy(p => p.operationId, StringComparer.Ordinal).ToArray()
        };
    }

    internal static bool HasErrors(object result)
    {
        var json = JsonSerializer.SerializeToElement(result, JsonOptions);
        if (!json.TryGetProperty("items", out var items)) return false;
        return items.EnumerateArray().Any(item =>
            item.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(error.GetString()) ||
            item.TryGetProperty("status", out var status) && status.GetString() is "failed" or "conflict" or "error" or "restore_failed");
    }

    private static void Write(object value) => Console.WriteLine(JsonSerializer.Serialize(value, JsonOptions));
}
