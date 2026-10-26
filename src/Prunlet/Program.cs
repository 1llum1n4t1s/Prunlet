using System.Text.Json;
using Prunlet.Core;
using Prunlet.Protocol;

namespace Prunlet;

internal static class Program
{
    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false,
        TypeInfoResolver = PrunletConfig.JsonOptions.TypeInfoResolver
    };

    private static async Task<int> Main(string[] args)
    {
#if PRUNLET_MAINTENANCE_HOST
        // 非表示の定期保守入口は既存Coreの明示適用だけを受け付ける。
        if (args is not ["--config", _, "maintain", "--apply"]) return 2;
#else
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
#endif
        try
        {
            if (args.Length == 0 || args is ["--help"] or ["help"])
            {
                Console.WriteLine("""
                    Prunlet — Windows Recycle Bin deletion and registry recovery.
                    prunlet --config <absolute-json-path> init --backup-directory <directory>
                    prunlet --config <absolute-json-path> validate-config
                    prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]
                    prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>
                    prunlet --config <absolute-json-path> registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] [--dry-run] -- <registry-key-path>
                    prunlet --config <absolute-json-path> registry-session --minutes <1..60> --assert-native-windows
                    prunlet --config <absolute-json-path> registry-reconcile <operation-id>
                    prunlet --config <absolute-json-path> registry-restore <operation-id>
                    prunlet --config <absolute-json-path> restore <registry-operation-id>
                    prunlet --config <absolute-json-path> purge <operation-id> [--dry-run | --apply]
                    prunlet --config <absolute-json-path> maintain [--dry-run | --apply] [--audit-records]
                    prunlet --config <absolute-json-path> operations
                    prunlet --config <absolute-json-path> migrate [--dry-run | --apply]
                    prunlet --config <absolute-json-path> mcp
                    prunlet --config <absolute-json-path> hook [--hook-script <legacy-path>]
                    Legacy --allowed-root <directory> options are accepted but do not restrict target directories.
                    Metadata and volume recovery directories are protected.
                    Files and folders move into the Windows Recycle Bin without Prunlet operation records.
                    Restore files and folders using Windows Recycle Bin; no CLI or MCP file restore is provided.
                    Windows controls Recycle Bin retention; unavailable recycling fails without permanent-delete fallback.
                    Registry snapshots retain the configured 7-day / 1 GiB defaults.
                    Maintain and purge manage registry recovery only; inspection is the default.
                    Migrate discards owned legacy file recovery data through Windows Recycle Bin; registry recovery stays protected.
                    After checking an interrupted discard, use migrate --apply --retry-legacy-discard to explicitly acknowledge retry.
                    Restore and registry-restore accept registry operation IDs and never overwrite existing keys or values.
                    Recycled hard links share content with surviving aliases.
                    For ambiguous file results, inspect the source and Windows Recycle Bin; do not resend deletion.
                    Empty directories are supported; deleting directory contents requires --recursive.
                    Wildcard expansion is unsupported. Links are deleted without following their targets.
                    Registry view is required. Omit value-name for a key; an empty value-name selects the default value.
                    Registry key snapshots require full Owner/Group/DACL/SACL access and SeSecurityPrivilege; no automatic elevation or fallback.
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
                if (commandArgs.Length != 0 && (commandArgs.Length != 2 || commandArgs[0] != "--hook-script"))
                    throw new ArgumentException("Use hook with no arguments, or legacy --hook-script <path>.");
                return await HookRouter.RunAsync(configPath, commandArgs.Length == 2 ? commandArgs[1] : null);
            }
            var config = PrunletConfig.Load(configPath);
            if (command == "registry-session")
            {
                if (commandArgs.Length != 3 || commandArgs[0] != "--minutes" || !int.TryParse(commandArgs[1], out var minutes)
                    || commandArgs[2] != "--assert-native-windows")
                    throw new ArgumentException("Use registry-session --minutes <1..60> --assert-native-windows from a normal Windows desktop.");
                await RegistrySessionServer.RunAsync(config, minutes, assertNativeWindows: true);
                return 0;
            }
            var service = new DeletionService(config);
            service.RecoveryLockProgress += (elapsed, acquired) =>
            {
                Console.Error.WriteLine(RecoveryLockMessage(elapsed, acquired));
                Console.Error.Flush();
            };
            object result;
            switch (command)
            {
                case "validate-config":
                    if (commandArgs.Length != 0) throw new ArgumentException("Validate-config accepts no arguments.");
                    result = new { valid = true };
                    break;
                case "migrate":
                    if (commandArgs.Length > 3 || commandArgs.Distinct(StringComparer.Ordinal).Count() != commandArgs.Length
                        || commandArgs.Any(arg => arg is not ("--dry-run" or "--apply" or "--if-needed" or "--retry-legacy-discard"))
                        || commandArgs.Contains("--dry-run") && commandArgs.Contains("--apply")
                        || commandArgs.Contains("--if-needed") && !commandArgs.Contains("--apply")
                        || commandArgs.Contains("--retry-legacy-discard") && (!commandArgs.Contains("--apply") || commandArgs.Contains("--if-needed")))
                        throw new ArgumentException("Use migrate [--dry-run | --apply]. After checking the source and Windows Recycle Bin, use migrate --apply --retry-legacy-discard to acknowledge an interrupted legacy file discard. Installer may use migrate --apply --if-needed.");
                    result = service.MigrateRecoveryStorage(commandArgs.Contains("--apply"), commandArgs.Contains("--if-needed"), commandArgs.Contains("--retry-legacy-discard"));
                    break;
                case "delete":
                    var dryRun = false;
                    var recursive = false;
                    var offset = 0;
                    while (offset < commandArgs.Length && commandArgs[offset] is "--dry-run" or "--recursive")
                    {
                        var option = commandArgs[offset++];
                        if (option == "--dry-run" && !dryRun) dryRun = true;
                        else if (option == "--recursive" && !recursive) recursive = true;
                        else throw new ArgumentException($"Repeated delete option: {option}");
                    }
                    string[] paths;
                    if (commandArgs.Length == offset + 2 && commandArgs[offset] == "--paths-file")
                        paths = ReadDeletePathsFile(commandArgs[offset + 1]);
                    else if (commandArgs.Length > offset + 1 && commandArgs[offset] == "--")
                        paths = commandArgs[(offset + 1)..];
                    else
                        throw new ArgumentException("Use delete [--dry-run] [--recursive] -- <absolute-path> [...] or delete [--dry-run] [--recursive] --paths-file <absolute-json-file>.");
                    result = service.Delete(paths, dryRun, recursive);
                    break;
                case "registry-delete":
                    var registryOptions = ParseRegistryDelete(commandArgs);
                    result = service.DeleteRegistry(registryOptions.Request, registryOptions.DryRun);
                    break;
                case "registry-reconcile":
                    if (commandArgs.Length != 1) throw new ArgumentException("Registry reconciliation requires exactly one operation id.");
                    result = service.ReconcileRegistry(commandArgs[0]);
                    break;
                case "restore":
                case "registry-restore":
                    if (commandArgs.Length != 1) throw new ArgumentException("Registry restore requires exactly one registry operation id. Restore files with Windows Recycle Bin.");
                    result = service.RestoreRegistry(commandArgs[0]);
                    break;
                case "purge":
                    if (commandArgs.Length is < 1 or > 2
                        || (commandArgs.Length == 2 && commandArgs[1] is not ("--dry-run" or "--apply")))
                        throw new ArgumentException("Use purge <operation-id> [--dry-run | --apply]. Purge inspects only unless --apply is specified.");
                    result = service.Purge(commandArgs[0], commandArgs.Length == 2 && commandArgs[1] == "--apply");
                    break;
                case "operations":
                    if (commandArgs.Length != 0) throw new ArgumentException("Operations accepts no arguments.");
                    result = ListOperations(config);
                    break;
                case "maintain":
                    if (commandArgs.Length > 2 || commandArgs.Distinct(StringComparer.Ordinal).Count() != commandArgs.Length
                        || commandArgs.Any(arg => arg is not ("--dry-run" or "--apply" or "--audit-records"))
                        || commandArgs.Contains("--dry-run") && commandArgs.Contains("--apply"))
                        throw new ArgumentException("Use maintain [--dry-run | --apply] [--audit-records]. Maintenance inspects only unless --apply is specified.");
                    result = service.MaintainRecovery(commandArgs.Contains("--apply"), commandArgs.Contains("--audit-records"));
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

    private static (RegistryDeleteRequest Request, bool DryRun) ParseRegistryDelete(string[] args)
    {
        string? view = null;
        string? valueName = null;
        var hasValueName = false;
        var recursive = false;
        var dryRun = false;
        var index = 0;
        while (index < args.Length && args[index] != "--")
        {
            var option = args[index++];
            if (option == "--view" && view is null && index < args.Length && args[index] is "32" or "64")
                view = args[index++];
            else if (option == "--value-name" && !hasValueName && index < args.Length && args[index] != "--")
            {
                valueName = args[index++];
                hasValueName = true;
            }
            else if (option.StartsWith("--value-name=", StringComparison.Ordinal) && !hasValueName)
            {
                valueName = option["--value-name=".Length..];
                hasValueName = true;
            }
            else if (option == "--recursive" && !recursive) recursive = true;
            else if (option == "--dry-run" && !dryRun) dryRun = true;
            else throw new ArgumentException("Unknown, duplicate, missing or invalid registry-delete option: " + option);
        }
        if (view is null || index >= args.Length || args[index] != "--" || args.Length - index != 2)
            throw new ArgumentException("Use registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] [--dry-run] -- <single registry-key-path>.");
        if (hasValueName && recursive) throw new ArgumentException("Recursive cannot be combined with value-name.");
        return (new RegistryDeleteRequest { Path = args[index + 1], View = view, ValueName = valueName, Recursive = recursive }, dryRun);
    }

    private static string[] ReadDeletePathsFile(string path)
    {
        var normalized = PathPolicy.Resolve(path, allowMissing: false);
        using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(normalized)!);
        using var handle = NativeFiles.OpenBackup(normalized);
        NativeFiles.Verify(handle, normalized);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.RejectNamedStreams(normalized);
        using var stream = new FileStream(handle, FileAccess.Read);
        if (stream.Length > 1024 * 1024) throw new InvalidDataException("Paths file exceeds the 1 MiB limit.");
        var bytes = new byte[(int)stream.Length];
        stream.ReadExactly(bytes);
        var start = bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }) ? 3 : 0;
        // 不正な UTF-8 を置換文字へ変換せず拒否し、パス文字列は加工しない。
        var json = new System.Text.UTF8Encoding(false, true).GetString(bytes.AsSpan(start));
        var paths = JsonSerializer.Deserialize<string[]>(json, PrunletConfig.JsonOptions)
            ?? throw new InvalidDataException("Paths file must contain a JSON array of path strings.");
        if (paths.Length is < 1 or > 256 || paths.Any(value => value is null))
            throw new InvalidDataException("Paths file must contain between 1 and 256 path strings.");
        return paths;
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
        if (backupDirectory is null) throw new ArgumentException("Specify a backup directory.");
        var config = new PrunletConfig { Schema = 1, AllowedRoots = roots.ToArray(), BackupDirectory = backupDirectory, CapacityDefaultMigrationVersion = 1 };
        config.Validate();
        config.BackupDirectory = PathPolicy.Resolve(config.BackupDirectory, finalDirectory: true, allowMissing: false);
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

    internal static string RecoveryLockMessage(TimeSpan elapsed, bool acquired) =>
        acquired
            ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"[prunlet] Recovery lock acquired after {elapsed.TotalSeconds:F1}s.")
            : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"[prunlet] Waiting for recovery lock ({elapsed.TotalSeconds:F1}s elapsed).");

    private static object ListOperations(PrunletConfig config)
    {
        config.Validate();
        return new OperationsResult
        {
            Operations = new DeletionService(config).ListRecoveryOperations()
        };
    }

    internal static bool HasErrors(object result)
    {
        if (result is OperationsResult) return false;
        if (result is RecoveryMigrationResult migration)
            return !migration.DryRun && !migration.RegistryReady || migration.Operations.Any(operation => operation.Status is "failed" or "ambiguous");
        if (result is FileDeleteResult files)
            return files.Items.Any(item => !string.IsNullOrEmpty(item.Error) || item.Status is "failed" or "ambiguous");
        if (result is RecoveryMaintenanceResult maintenance)
            return !maintenance.Complete || !maintenance.CapacityKnown || !maintenance.BudgetSatisfied || maintenance.Operations.Any(HasErrors);
        var typedItems = result switch
        {
            DeleteResult deleted => deleted.Items,
            RestoreResult restored => restored.Items,
            PurgeResult purged => purged.Items,
            _ => null
        };
        if (typedItems is not null)
            return typedItems.Any(item => !string.IsNullOrEmpty(item.Error) ||
                item.Status is "failed" or "conflict" or "error" or "restore_failed" or "ambiguous" or "missing");

        return false;
    }

    private static void Write(object value) => Console.WriteLine(JsonSerializer.Serialize(value, JsonOptions));

    private sealed class OperationsResult
    {
        public RecoveryOperationSummary[] Operations { get; init; } = [];
    }

    private sealed class OperationSummary
    {
        public string OperationId { get; init; } = string.Empty;
    }
}
