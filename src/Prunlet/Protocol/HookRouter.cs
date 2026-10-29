using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Prunlet.Protocol;

internal static class HookRouter
{
    // 外側のshellが不明でも、3種のshellで同じ引数になる静的な形だけを受け付ける。
    private static readonly Regex EncodedPowerShell = new(
        @"\A[ \t]*(?:pwsh|powershell)(?:\.exe)?[ \t]+-NoProfile[ \t]+-EncodedCommand[ \t]+(?<data>[A-Za-z0-9+/]+={0,2})[ \t]*\z",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly HashSet<string> DeleteCommands = new(StringComparer.OrdinalIgnoreCase)
    {
        "Remove-Item", "ri", "rm", "rmdir", "rd", "del", "erase", "Remove-ItemProperty", "rp"
    };

    // 旧登録の --hook-script は受理するが、外部コードとして読み取ったり実行したりしない。
    internal static async Task<int> RunAsync(string configPath, string? legacyHookScript = null, string? commandExecutable = null)
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
            if (!ContainsDirectDeletion(command.GetString()!, mode: ExecutionMode(name.GetString()!, arguments))) return Pass();

            var executable = commandExecutable ?? Environment.ProcessPath ?? "prunlet.exe";
            return Deny($"Direct shell deletion is blocked. For explicitly authorized targets, use the installed Prunlet CLI from the start with shell=cmd.exe and login=false: {CmdPath(executable)} --config {CmdPath(configPath)} delete --paths-file <absolute-json-file>; for registry keys/values use {CmdPath(executable)} --config {CmdPath(configPath)} registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] -- <registry-key-path>. File and folder deletions have no Prunlet operation record. Normally restore recycled items using Windows Recycle Bin; a file or folder Windows reports as too large may instead be permanently deleted. Dry-run cannot predict the final disposition. Keep registry operationId and use {CmdPath(executable)} --config {CmdPath(configPath)} registry-restore <operationId>. On hosts supporting exec_command sandbox permissions, request sandbox_permissions=\"require_escalated\" from the first real file deletion because Recycle Bin access may be restricted. This is a formal host permission request, not Windows UAC or administrator elevation. A dry-run does not prove real-operation permissions. Existing host approvals and policies still apply. Do not retry a policy-rejected target through another route or automatically resend a failed deletion; check uncertain file results using the source and Windows Recycle Bin; reconcile registry results using registry-reconcile <operationId> before deciding next steps.");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Console.Error.WriteLine("Prunlet hook: " + ex.Message);
            return Deny("Prunlet could not inspect the hook input: " + ex.Message);
        }
    }

    private static string CmdPath(string value) => value.Any(char.IsWhiteSpace) ? "\"" + value + "\"" : value;

    private static EscapeMode? ExecutionMode(string tool, JsonElement arguments)
    {
        // Bashの追加propertyや既定shellは実行器の根拠にしない。
        if (tool is not ("exec_command" or "functions.exec_command")
            || !arguments.TryGetProperty("shell", out var shell) || shell.ValueKind != JsonValueKind.String)
            return null;
        return WindowsShellMode(CommandLeaf(shell.GetString()!));
    }

    private static EscapeMode? WindowsShellMode(string name) => name.ToLowerInvariant() switch
    {
        "pwsh" or "powershell" => EscapeMode.PowerShell,
        "cmd" => EscapeMode.Cmd,
        // Windowsホストには未知shellをCMDで実行するものもある。Posixとは推測しない。
        _ => null
    };

    private static bool ContainsDirectDeletion(string script, int depth = 0, EscapeMode? mode = null, bool strictEncoded = false)
    {
        if (depth > 4) return strictEncoded;
        if (depth == 0)
        {
            var match = EncodedPowerShell.Match(script);
            if (match.Success)
            {
                var data = match.Groups["data"].Value;
                // Git Bashは先頭スラッシュの引数をパスとして変換することがある。
                if (data[0] == '/') throw new InvalidDataException("EncodedCommand cannot begin with a slash.");
                var bytes = Convert.FromBase64String(data);
                if (bytes.Length == 0 || bytes.Length % 2 != 0 || Convert.ToBase64String(bytes) != data)
                    throw new InvalidDataException("EncodedCommand requires canonical UTF-16LE Base64.");
                var decoded = new UnicodeEncoding(false, false, true).GetString(bytes);
                if (decoded.Contains('\0')) throw new InvalidDataException("EncodedCommand contains a NUL character.");
                return ContainsDirectDeletion(decoded, depth + 1, EscapeMode.PowerShell, strictEncoded: true);
            }
        }
        if (mode is { } known) return ContainsDirectDeletion(script, depth, known, strictEncoded);
        foreach (var candidate in new[] { EscapeMode.Cmd, EscapeMode.PowerShell, EscapeMode.Posix })
            if (ContainsDirectDeletion(script, depth, candidate, strictEncoded)) return true;
        return false;
    }

    private static bool ContainsDirectDeletion(string script, int depth, EscapeMode mode, bool strictEncoded)
    {
        var command = new List<ShellToken>();
        foreach (var token in Tokens(script, mode, strictEncoded))
        {
            if (token.Boundary)
            {
                if (IsDeletionCommand(command, depth, strictEncoded)) return true;
                command.Clear();
            }
            else command.Add(token);
        }
        return IsDeletionCommand(command, depth, strictEncoded);
    }

    private static bool IsDeletionCommand(List<ShellToken> words, int depth, bool strictEncoded)
    {
        if (words.Count == 0) return false;
        if (depth > 4) return strictEncoded;
        if (ContainsNoncanonicalEncodedInvocation(words, depth)) return true;
        var index = 0;
        var name = CommandLeaf(words[index].Text.TrimStart('@'));
        if (strictEncoded && words[index].QuoteStart == 0) return false;
        // 静的な呼出しprefixだけを解釈する。command -v は実行ではなく照会。
        if (name.Equals("call", StringComparison.OrdinalIgnoreCase)
            || name.Equals("command", StringComparison.OrdinalIgnoreCase)
            || name.Equals("exec", StringComparison.OrdinalIgnoreCase))
        {
            if (++index >= words.Count || words[index].Text.StartsWith('-')) return false;
            name = CommandLeaf(words[index].Text.TrimStart('@'));
        }
        // 削除名は代入の推定より先に判定する（'='を削除対象にすることもある）。
        if (DeleteCommands.Contains(name)) return true;
        if (name.Equals("reg", StringComparison.OrdinalIgnoreCase))
            return index + 1 < words.Count && words[index + 1].Text.Equals("delete", StringComparison.OrdinalIgnoreCase);
        if (strictEncoded && (name.Equals("iex", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Invoke-Expression", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Start-Process", StringComparison.OrdinalIgnoreCase)
            || name.Equals("start", StringComparison.OrdinalIgnoreCase)
            || name.Equals("saps", StringComparison.OrdinalIgnoreCase))) return true;
        if (strictEncoded && IsShellWrapper(name)) return true;
        if (strictEncoded)
        {
            // 代入・return等の右辺もPowerShellではコマンドとして実行される。
            if (name.Equals("return", StringComparison.OrdinalIgnoreCase)
                || name.Equals("throw", StringComparison.OrdinalIgnoreCase)
                || name.Equals("exit", StringComparison.OrdinalIgnoreCase))
                return InspectPowerShellExpression(words, index + 1, depth);
            var assigned = InspectPowerShellAssignment(words, index, depth);
            if (assigned.HasValue) return assigned.Value;
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
            return IsDeletionCommand(words.GetRange(condition + 2, words.Count - condition - 2), depth + 1, strictEncoded);
        }
        if (!IsShellWrapper(name)) return false;
        var isPowerShell = WindowsShellMode(name) == EscapeMode.PowerShell;
        for (var i = index + 1; i < words.Count; i++)
        {
            if (isPowerShell && IsEncodedOption(words[i].Text)) return true;
            // -Fileの後ろは外部scriptの引数であり、起動オプションではない。
            if (isPowerShell && IsPowerShellFileOption(words[i].Text)) return false;
            if (!(isPowerShell && IsPowerShellCommandOption(words[i].Text))
                && words[i].Text is not ("-c" or "-lc" or "-Command" or "-command" or "/c" or "/C" or "/k" or "/K"))
                continue;
            if (i + 1 >= words.Count) return false;
            var body = words.Count == i + 2 && words[i + 1].Quoted
                ? words[i + 1].Text
                : string.Join(" ", words.Skip(i + 1).Select(QuoteToken));
            return ContainsDirectDeletion(body, depth + 1, WindowsShellMode(name), strictEncoded);
        }
        // -Fileや外部scriptの内容、動的な名前、他言語のコードは検査しない。
        return false;
    }

    private static bool ContainsNoncanonicalEncodedInvocation(List<ShellToken> words, int depth)
    {
        // wrapper本文と実行される展開は調べる。通常の引用データはコマンドではない。
        var parts = new List<string>();
        var wrapperSeen = false;
        var executablePosition = true;
        var outputOnly = false;
        var inBacktickSubstitution = false;
        var backtickScript = new StringBuilder();
        var prefixName = "";
        var prefixOptionValue = false;
        var expressionLead = words[0].Text.StartsWith('$') || words[0].Text.StartsWith('=')
            || words[0].Text.StartsWith('.') || words[0].Text.StartsWith('[') || words[0].Text.StartsWith('(');
        for (var wordIndex = 0; wordIndex < words.Count; wordIndex++)
        {
            var word = words[wordIndex];
            var executable = CommandLeaf(word.Text.TrimStart('@'));
            var optionValue = executablePosition && prefixOptionValue;
            if (optionValue) prefixOptionValue = false;
            if (executablePosition && !optionValue && (executable.Equals("echo", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("Write-Output", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("Write-Host", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("Write-Information", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("printf", StringComparison.OrdinalIgnoreCase))) outputOnly = true;
            var quotedExecutable = !optionValue && word.QuoteStart == 0 && (executablePosition || wrapperSeen) && !outputOnly
                && !(wordIndex > 0 && words[wordIndex - 1].Text == "=")
                && WindowsShellMode(executable) == EscapeMode.PowerShell;
            if (executablePosition && !optionValue && (IsShellWrapper(executable)
                || executable.Equals("env", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("sudo", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("time", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("nice", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("call", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("command", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("exec", StringComparison.OrdinalIgnoreCase))) wrapperSeen = true;
            if (quotedExecutable) wrapperSeen = true;
            if (executablePosition && !optionValue && (executable.Equals("env", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("nice", StringComparison.OrdinalIgnoreCase))) prefixName = executable;
            if (executablePosition && !optionValue
                && ((prefixName.Equals("env", StringComparison.OrdinalIgnoreCase) && word.Text is ("-u" or "--unset" or "-C" or "--chdir"))
                    || (prefixName.Equals("nice", StringComparison.OrdinalIgnoreCase) && word.Text is ("-n" or "--adjustment"))))
                prefixOptionValue = true;
            var prefix = executablePosition && (optionValue || executable.Equals("call", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("command", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("exec", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("env", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("sudo", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("time", StringComparison.OrdinalIgnoreCase)
                || executable.Equals("nice", StringComparison.OrdinalIgnoreCase)
                || word.Text.StartsWith('-'));
            if (executablePosition && !prefix && !IsShellWrapper(executable) && !quotedExecutable)
                wrapperSeen = false;
            if (!prefix && !(executablePosition && Regex.IsMatch(word.Text, @"\A[A-Za-z_][A-Za-z0-9_]*=", RegexOptions.CultureInvariant)))
                executablePosition = false;
            var backticks = word.CommandSubstitutionBackticks;
            var expandable = inBacktickSubstitution || backticks > 0
                || word.QuotedSubexpression;
            if (word.QuotedSubexpression
                && ContainsExpandedSubexpression(word.Text, depth)) return true;
            if (inBacktickSubstitution || backticks > 0)
            {
                if (backtickScript.Length > 0) backtickScript.Append(' ');
                backtickScript.Append(word.Text);
            }
            if ((backticks & 1) != 0) inBacktickSubstitution = !inBacktickSubstitution;
            if (backtickScript.Length > 0 && !inBacktickSubstitution)
            {
                var body = backtickScript.ToString();
                var start = body.IndexOf('\u0060');
                var end = body.LastIndexOf('\u0060');
                if (start >= 0 && end > start && ContainsDirectDeletion(body[(start + 1)..end], depth + 1)) return true;
                backtickScript.Clear();
            }
            if (outputOnly && wordIndex > 0 && !expandable) continue;
            if (word.QuoteStart >= 0 && !wrapperSeen && !expandable)
                continue;
            // 通常コマンドの引数は実行名ではない。式・wrapper・展開は従来どおり調べる。
            if (!executablePosition && !wrapperSeen && !expressionLead) continue;
            foreach (var part in word.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
                parts.Add(wrapperSeen && word.QuoteStart >= 0 ? part.Trim('\'', '"') : part);
        }
        for (var i = 0; i < parts.Count; i++)
        {
            var part = parts[i];
            var equals = part.LastIndexOf('=');
            if (equals >= 0 && equals + 1 < part.Length) part = part[(equals + 1)..];
            var subexpression = part.LastIndexOf("$(", StringComparison.Ordinal);
            if (subexpression >= 0) part = part[(subexpression + 2)..];
            part = part.Trim('@', '$', '(', ')', '{', '}', '\u0060');
            if (WindowsShellMode(CommandLeaf(part)) != EscapeMode.PowerShell) continue;
            for (var j = i + 1; j < parts.Count; j++)
            {
                if (IsEncodedOption(parts[j])) return true;
                if (IsPowerShellFileOption(parts[j]) || IsPowerShellCommandOption(parts[j])) break;
            }
        }
        return false;
    }

    private static bool ContainsExpandedSubexpression(string text, int depth)
    {
        var start = 0;
        while ((start = text.IndexOf("$(", start, StringComparison.Ordinal)) >= 0)
        {
            var level = 1;
            var end = start + 2;
            char quote = '\0';
            for (; end < text.Length && level > 0; end++)
            {
                var c = text[end];
                if (c == '\\' || c == '\u0060') { end++; continue; }
                if (quote != '\0') { if (c == quote) quote = '\0'; continue; }
                if (c is '\'' or '"') { quote = c; continue; }
                if (c == '(') level++;
                else if (c == ')') level--;
            }
            var bodyEnd = level == 0 ? end - 1 : text.Length;
            if (ContainsDirectDeletion(text[(start + 2)..bodyEnd], depth + 1)) return true;
            start = level == 0 ? end : text.Length;
        }
        return false;
    }

    private static bool? InspectPowerShellAssignment(List<ShellToken> words, int index, int depth)
    {
        // [type] $x と [type]$x の両方を扱う。括弧・プロパティ後の代入も調べる。
        if (words[index].Text.StartsWith('[') && words[index].Text.EndsWith(']')
            && index + 1 < words.Count && words[index + 1].Text.StartsWith('$')) index++;
        var token = words[index];
        var value = token.Text;
        if (!(value.StartsWith('$') || value.StartsWith('.') || value.StartsWith('[') || value.StartsWith('='))) return null;
        var equals = value.IndexOf('=');
        if (equals >= 0)
        {
            if (token.QuoteStart >= 0 && token.QuoteStart <= equals)
                throw new InvalidDataException("EncodedCommand quoted assignment targets cannot be inspected.");
            if (token.QuoteStart == equals + 1) return false;
            var rhs = value[(equals + 1)..];
            if (rhs.Length == 0) return InspectPowerShellExpression(words, index + 1, depth);
            var expression = new List<ShellToken> { new(rhs, false, token.Quoted) };
            expression.AddRange(words.Skip(index + 1));
            return IsDeletionCommand(expression, depth + 1, strictEncoded: true);
        }
        if (index + 1 >= words.Count) return null;
        var next = words[index + 1].Text;
        if ((value.StartsWith('$') && next.Equals("in", StringComparison.OrdinalIgnoreCase))
            || (next.EndsWith('=') && next.All(c => c is '=' or '+' or '-' or '*' or '/' or '%' or '?')))
            return InspectPowerShellExpression(words, index + 2, depth);
        return null;
    }

    private static bool InspectPowerShellExpression(List<ShellToken> words, int index, int depth)
    {
        if (index >= words.Count) return false;
        // 式の先頭が引用文字列ならコマンドではない。展開式は字句検査で拒否する。
        if (words[index].QuoteStart == 0) return false;
        return IsDeletionCommand(words.GetRange(index, words.Count - index), depth + 1, strictEncoded: true);
    }

    private static string PowerShellOptionName(string value)
    {
        var index = 0;
        while (index < value.Length && value[index] is '-' or '/' or '\u2013' or '\u2014' or '\u2015') index++;
        return index == 0 ? "" : value[index..];
    }

    private static bool IsEncodedOption(string value)
    {
        var name = PowerShellOptionName(value);
        return name.Length > 0 && (name.Equals("ec", StringComparison.OrdinalIgnoreCase)
            || "encodedcommand".StartsWith(name, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsPowerShellFileOption(string value)
    {
        var name = PowerShellOptionName(value);
        return name.Length > 0 && "file".StartsWith(name, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsPowerShellCommandOption(string value)
    {
        var name = PowerShellOptionName(value);
        return name.Length > 0 && ("command".StartsWith(name, StringComparison.OrdinalIgnoreCase)
            || name.Equals("cwa", StringComparison.OrdinalIgnoreCase)
            || name.Equals("commandwithargs", StringComparison.OrdinalIgnoreCase));
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

    private static IEnumerable<ShellToken> Tokens(string script, EscapeMode mode, bool strictEncoded)
    {
        var text = new StringBuilder();
        var quoted = false;
        var quoteStart = -1;
        char quoteKind = '\0';
        char quote = '\0';
        var substitutionBackticks = 0;
        var quotedSubexpression = false;
        for (var i = 0; i < script.Length; i++)
        {
            var c = script[i];
            if (strictEncoded && mode == EscapeMode.PowerShell)
            {
                // 未対応構文を推測で通さない。単引用here-string本文はこのiteratorに渡らない。
                if (c is >= '\u2018' and <= '\u201E')
                    throw new InvalidDataException("EncodedCommand contains unsupported smart quotation marks.");
                if (quote == '\0' && c == '<' && i + 1 < script.Length && script[i + 1] == '#')
                    throw new InvalidDataException("EncodedCommand block comments cannot be inspected.");
                if (quote == '\0' && c == '@' && i + 1 < script.Length && script[i + 1] == '{')
                    throw new InvalidDataException("EncodedCommand hashtables cannot be inspected.");
                if (quote == '\0' && c == '$' && i + 1 < script.Length && script[i + 1] == '{')
                    throw new InvalidDataException("EncodedCommand braced variables cannot be inspected.");
                if (quote != '\'' && c == '\u0060' && i + 2 < script.Length
                    && script[i + 1] is 'u' or 'U' && script[i + 2] == '{')
                    throw new InvalidDataException("EncodedCommand Unicode escapes cannot be inspected.");
                if (quote == '"' && c == '$' && i + 1 < script.Length && script[i + 1] == '(')
                    throw new InvalidDataException("EncodedCommand expandable string subexpressions cannot be inspected.");
                if (quote == '\0' && c == '&')
                {
                    var next = i + 1;
                    while (next < script.Length && char.IsWhiteSpace(script[next])) next++;
                    if (next < script.Length && script[next] is '(' or '$' or '@' or '{' or '\'' or '"' or '\u0060')
                        throw new InvalidDataException("EncodedCommand dynamic invocation cannot be inspected.");
                }
                if (quote == '\0' && c == '.' && text.Length == 0 && i + 1 < script.Length
                    && (char.IsWhiteSpace(script[i + 1]) || script[i + 1] == '('))
                    throw new InvalidDataException("EncodedCommand dot-sourcing cannot be inspected.");
            }
            // POSIXの未escapeバッククォートだけをコマンド置換として数える。
            // escapeは直前の反復で次の文字を消費するため、ここへ到達しない。
            if (mode == EscapeMode.Posix && c == '\u0060' && quote != '\'') substitutionBackticks++;
            if ((mode is EscapeMode.Posix or EscapeMode.PowerShell) && quote == '"'
                && c == '$' && i + 1 < script.Length && script[i + 1] == '(')
                quotedSubexpression = true;
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
            if (mode == EscapeMode.PowerShell && c == '@' && i + 1 < script.Length && script[i + 1] is '\'' or '"')
            {
                if (quoteStart < 0) { quoteStart = text.Length; quoteKind = script[i + 1]; }
                var body = ReadPowerShellHereString(script, ref i, script[i + 1]);
                text.Append(body);
                quoted = true;
                continue;
            }
            // CMDでは単引用符は通常の文字で、内部の & 等も実行境界になる。
            if (c == '"' || (c == '\'' && mode != EscapeMode.Cmd))
            {
                if (quoteStart < 0) { quoteStart = text.Length; quoteKind = c; }
                quote = c; quoted = true; continue;
            }
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
                    yield return new ShellToken(text.ToString(), false, quoted, quoteStart, quoteKind, substitutionBackticks, quotedSubexpression);
                    text.Clear(); quoted = false; quoteStart = -1; quoteKind = '\0'; substitutionBackticks = 0; quotedSubexpression = false;
                }
                if (boundary) yield return new ShellToken("", true, false);
            }
            else text.Append(c);
        }
        if (strictEncoded && quote != '\0') throw new InvalidDataException("EncodedCommand has an unterminated string.");
        if (text.Length > 0 || quoted) yield return new ShellToken(text.ToString(), false, quoted, quoteStart, quoteKind, substitutionBackticks, quotedSubexpression);
    }

    private static string ReadPowerShellHereString(string script, ref int position, char quote)
    {
        var start = position + 2;
        while (start < script.Length && script[start] is ' ' or '\t') start++;
        if (start >= script.Length || script[start] is not ('\r' or '\n'))
            throw new InvalidDataException("PowerShell here-string header must end with a newline.");
        if (script[start++] == '\r' && start < script.Length && script[start] == '\n') start++;
        for (var end = start; end + 1 < script.Length; end++)
        {
            // 終端は行頭だけ。終端直後のローカルコマンドは通常の字句検査へ戻す。
            if ((end == start || script[end - 1] is '\r' or '\n')
                && script[end] == quote && script[end + 1] == '@')
            {
                var body = script[start..end];
                if (quote == '"')
                {
                    for (var i = 0; i + 1 < body.Length; i++)
                    {
                        if (body[i] == '\u0060') { i++; continue; }
                        // 展開式はローカルで実行される。限定lexerでは許可せずliteral形式を案内する。
                        if (body[i] == '$' && body[i + 1] == '(')
                            throw new InvalidDataException("PowerShell expandable here-string subexpressions cannot be inspected; use a single-quoted literal here-string for remote script data.");
                    }
                }
                position = end + 1;
                return body;
            }
        }
        throw new InvalidDataException("PowerShell here-string has no valid closing marker.");
    }

    private readonly record struct ShellToken(string Text, bool Boundary, bool Quoted, int QuoteStart = -1, char QuoteKind = '\0', int CommandSubstitutionBackticks = 0, bool QuotedSubexpression = false);

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
