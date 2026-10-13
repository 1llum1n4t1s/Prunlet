using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Prunlet.Protocol;

internal static class HookRouter
{
    // 候補の検出だけを行う。置換の可否はPowerShell ASTで判定する。
    private static readonly Regex DeleteCandidate = new(@"\b(?:remove-item|ri|rm|rmdir|rd|del|erase)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    internal static async Task<int> RunAsync(string configPath, string hookScript)
    {
        try
        {
            var payload = await Console.In.ReadToEndAsync();
            if (payload.Length > 1_048_576) throw new ArgumentException("Hook input exceeds 1 MiB.");
            using var document = JsonDocument.Parse(payload);
            var input = document.RootElement;
            if (input.ValueKind != JsonValueKind.Object) throw new ArgumentException("Hook input must be an object.");
            if (!input.TryGetProperty("tool_name", out var name) || name.ValueKind != JsonValueKind.String)
                throw new ArgumentException("Hook tool_name must be a string.");
            var toolName = name.GetString();
            if (toolName is not "Bash" and not "exec_command" and not "functions.exec_command")
                return Pass();
            if (!input.TryGetProperty("tool_input", out var arguments) || arguments.ValueKind != JsonValueKind.Object)
                throw new ArgumentException("Hook tool_input must be an object.");
            var command = arguments.TryGetProperty("command", out var text) ? text : arguments.TryGetProperty("cmd", out text) ? text : default;
            if (command.ValueKind != JsonValueKind.String) throw new ArgumentException("Hook command must be a string.");
            var commandText = command.GetString()!;
            if (!commandText.Contains('`') && !DeleteCandidate.IsMatch(commandText)) return Pass();

            if (!Path.IsPathFullyQualified(hookScript) || !File.Exists(hookScript))
                throw new ArgumentException("Hook script must be an existing absolute path.");
            var executable = Environment.ProcessPath ?? throw new IOException("Cannot resolve the Prunlet executable.");
            var start = new ProcessStartInfo("pwsh")
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new System.Text.UTF8Encoding(false),
                StandardOutputEncoding = new System.Text.UTF8Encoding(false),
                StandardErrorEncoding = new System.Text.UTF8Encoding(false)
            };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-File", hookScript, "-ExecutablePath", executable, "-ConfigPath", configPath })
                start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new IOException("Cannot start the PowerShell hook backend.");
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            await process.StandardInput.WriteAsync(payload);
            process.StandardInput.Close();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException)
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
                throw new IOException("PowerShell hook backend timed out; no deletion was performed by this hook.");
            }
            var result = await stdout;
            var errors = await stderr;
            if (process.ExitCode != 0) throw new IOException($"PowerShell hook backend failed: {errors.Trim()}");
            using var validated = JsonDocument.Parse(result);
            if (validated.RootElement.ValueKind != JsonValueKind.Object) throw new IOException("Invalid hook backend result.");
            Console.WriteLine(JsonSerializer.Serialize(validated.RootElement, Program.JsonOptions));
            return 0;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                hookSpecificOutput = new
                {
                    hookEventName = "PreToolUse", permissionDecision = "deny",
                    permissionDecisionReason = $"Prunlet hook: {ex.Message}"
                }
            }, Program.JsonOptions));
            return 0;
        }
    }

    private static int Pass() { Console.WriteLine("{}"); return 0; }
}
