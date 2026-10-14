using System.Text;
using System.Text.Json;

namespace Prunlet.Protocol;

internal static class HookRouter
{
    private static readonly HashSet<string> DeleteCommands = new(StringComparer.OrdinalIgnoreCase)
    {
        "Remove-Item", "ri", "rm", "rmdir", "rd", "del", "erase"
    };

    // 旧登録の --hook-script は受理するが、外部コードとして読み取ったり実行したりしない。
    internal static async Task<int> RunAsync(string configPath, string? legacyHookScript = null)
    {
        try
        {
            var payload = await BoundedInputReader.ReadToEndAsync(Console.In, BoundedInputReader.RequestLimit);
            if (payload.ExceedsLimit) throw new ArgumentException("Hook input exceeds 1 MiB.");
            using var document = JsonDocument.Parse(payload.Text);
            var input = document.RootElement;
            if (input.ValueKind != JsonValueKind.Object) throw new ArgumentException("Hook input must be an object.");
            if (!input.TryGetProperty("tool_name", out var name) || name.ValueKind != JsonValueKind.String)
                throw new ArgumentException("Hook tool_name must be a string.");
            if (name.GetString() is not "Bash" and not "exec_command" and not "functions.exec_command")
                return Pass();
            if (!input.TryGetProperty("tool_input", out var arguments) || arguments.ValueKind != JsonValueKind.Object)
                throw new ArgumentException("Hook tool_input must be an object.");
            var command = arguments.TryGetProperty("command", out var text) ? text
                : arguments.TryGetProperty("cmd", out text) ? text : default;
            if (command.ValueKind != JsonValueKind.String) throw new ArgumentException("Hook command must be a string.");
            if (!ContainsDirectDeletion(command.GetString()!)) return Pass();

            var executable = Environment.ProcessPath ?? "prunlet.exe";
            return Deny($"Direct shell deletion is blocked. For an authorized target, use the installed Prunlet CLI from the start with shell=cmd.exe and login=false: {CmdPath(executable)} --config {CmdPath(configPath)} delete --paths-file <absolute-json-file>. Keep its operationId for restore. Do not retry a policy-rejected target through another route.");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Console.Error.WriteLine("Prunlet hook: " + ex.Message);
            return Deny("Prunlet could not inspect the hook input: " + ex.Message);
        }
    }

    private static string CmdPath(string value) => value.Any(char.IsWhiteSpace) ? "\"" + value + "\"" : value;

    private static bool ContainsDirectDeletion(string script, int depth = 0)
    {
        if (depth > 4) return false;
        foreach (var mode in new[] { EscapeMode.Cmd, EscapeMode.PowerShell, EscapeMode.Posix })
            if (ContainsDirectDeletion(script, depth, mode)) return true;
        return false;
    }

    private static bool ContainsDirectDeletion(string script, int depth, EscapeMode mode)
    {
        var command = new List<ShellToken>();
        foreach (var token in Tokens(script, mode))
        {
            if (token.Boundary)
            {
                if (IsDeletionCommand(command, depth)) return true;
                command.Clear();
            }
            else command.Add(token);
        }
        return IsDeletionCommand(command, depth);
    }

    private static bool IsDeletionCommand(List<ShellToken> words, int depth)
    {
        if (words.Count == 0 || depth > 4) return false;
        var index = 0;
        var name = CommandLeaf(words[index].Text.TrimStart('@'));
        // 静的な呼出しprefixだけを解釈する。command -v は実行ではなく照会。
        if (name.Equals("call", StringComparison.OrdinalIgnoreCase)
            || name.Equals("command", StringComparison.OrdinalIgnoreCase)
            || name.Equals("exec", StringComparison.OrdinalIgnoreCase))
        {
            if (++index >= words.Count || words[index].Text.StartsWith('-')) return false;
            name = CommandLeaf(words[index].Text.TrimStart('@'));
        }
        // CMDの静的なIF条件の直後だけを調べる。echo等の引数は探索しない。
        if (name.Equals("if", StringComparison.OrdinalIgnoreCase))
        {
            var condition = index + 1;
            if (condition < words.Count && words[condition].Text.Equals("/i", StringComparison.OrdinalIgnoreCase)) condition++;
            if (condition < words.Count && words[condition].Text.Equals("not", StringComparison.OrdinalIgnoreCase)) condition++;
            if (condition + 2 >= words.Count) return false;
            var kind = words[condition].Text;
            if (!kind.Equals("exist", StringComparison.OrdinalIgnoreCase)
                && !kind.Equals("defined", StringComparison.OrdinalIgnoreCase)
                && !kind.Equals("errorlevel", StringComparison.OrdinalIgnoreCase)) return false;
            return IsDeletionCommand(words.GetRange(condition + 2, words.Count - condition - 2), depth + 1);
        }
        if (DeleteCommands.Contains(name)) return true;
        if (!IsShellWrapper(name)) return false;
        for (var i = index + 1; i + 1 < words.Count; i++)
        {
            if (words[i].Text is not ("-c" or "-lc" or "-Command" or "-command" or "/c" or "/C" or "/k" or "/K"))
                continue;
            var body = words.Count == i + 2 && words[i + 1].Quoted
                ? words[i + 1].Text
                : string.Join(" ", words.Skip(i + 1).Select(QuoteToken));
            return ContainsDirectDeletion(body, depth + 1);
        }
        // -Fileや外部scriptの内容、動的な名前、他言語のコードは検査しない。
        return false;
    }

    private static string QuoteToken(ShellToken token) => token.Quoted
        ? "\"" + token.Text.Replace("\"", "\"\"") + "\"" : token.Text;

    private static string CommandLeaf(string value)
    {
        var slash = Math.Max(value.LastIndexOf('/'), value.LastIndexOf('\\'));
        var name = value[(slash + 1)..];
        return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
    }

    private static bool IsShellWrapper(string name) =>
        name.Equals("cmd", StringComparison.OrdinalIgnoreCase)
        || name.Equals("bash", StringComparison.OrdinalIgnoreCase)
        || name.Equals("sh", StringComparison.OrdinalIgnoreCase)
        || name.Equals("zsh", StringComparison.OrdinalIgnoreCase)
        || name.Equals("pwsh", StringComparison.OrdinalIgnoreCase)
        || name.Equals("powershell", StringComparison.OrdinalIgnoreCase);

    // shell未提供の正式hook入力でも使える限定字句検査。完全なshell parserではない。
    private enum EscapeMode { Cmd, PowerShell, Posix }

    private static IEnumerable<ShellToken> Tokens(string script, EscapeMode mode)
    {
        var text = new StringBuilder();
        var quoted = false;
        char quote = '\0';
        for (var i = 0; i < script.Length; i++)
        {
            var c = script[i];
            if (quote != '\0')
            {
                if (quote == '"' && i + 1 < script.Length
                    && ((mode == EscapeMode.PowerShell && c == '\u0060')
                        || (mode == EscapeMode.Posix && c == '\\' && script[i + 1] is ('"' or '\\' or '$' or '\u0060'))))
                {
                    text.Append(script[++i]);
                    continue;
                }
                if (c == quote)
                {
                    if (i + 1 < script.Length && script[i + 1] == quote) { text.Append(c); i++; }
                    else quote = '\0';
                }
                // CMD modeではbackslash/backtickを閉じ引用符のescapeと解釈しない。
                else text.Append(c);
                continue;
            }
            if (((mode == EscapeMode.Cmd && c == '^')
                || (mode == EscapeMode.PowerShell && c == '\u0060')
                || (mode == EscapeMode.Posix && c == '\\')) && i + 1 < script.Length)
            {
                c = script[++i];
                if (c is '\r' or '\n') { if (c == '\r' && i + 1 < script.Length && script[i + 1] == '\n') i++; }
                else text.Append(c);
                continue;
            }
            if (c is '\'' or '"') { quote = c; quoted = true; continue; }
            if (c == '#' && text.Length == 0)
            {
                while (i < script.Length && script[i] is not ('\r' or '\n')) i++;
                c = '\n';
            }
            var boundary = c is ';' or '|' or '&' or '\r' or '\n' or '(' or ')' or '{' or '}';
            if (char.IsWhiteSpace(c) || boundary)
            {
                if (text.Length > 0 || quoted)
                {
                    yield return new ShellToken(text.ToString(), false, quoted);
                    text.Clear(); quoted = false;
                }
                if (boundary) yield return new ShellToken("", true, false);
            }
            else text.Append(c);
        }
        if (text.Length > 0 || quoted) yield return new ShellToken(text.ToString(), false, quoted);
    }

    private readonly record struct ShellToken(string Text, bool Boundary, bool Quoted);

    private static int Pass() { Console.WriteLine("{}"); return 0; }

    private static int Deny(string reason)
    {
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            hookSpecificOutput = new
            {
                hookEventName = "PreToolUse",
                permissionDecision = "deny",
                permissionDecisionReason = reason
            }
        }));
        return 0;
    }
}
