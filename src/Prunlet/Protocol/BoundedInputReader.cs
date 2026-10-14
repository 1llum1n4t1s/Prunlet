using System.Text;

namespace Prunlet.Protocol;

internal sealed class BoundedInputReader(TextReader input, int maxLength)
{
    internal const int RequestLimit = 1_048_576;
    private readonly char[] character = new char[1];
    private bool skipLineFeed;

    internal async ValueTask<BoundedInput?> ReadLineAsync()
    {
        var text = new StringBuilder();
        var hasCharacters = false;
        var exceedsLimit = false;
        var isWhiteSpace = true;
        // 大きな読み取り単位で行末後の入力を待たないよう、1文字ずつ読む。
        while (await input.ReadAsync(character.AsMemory()) != 0)
        {
            var value = character[0];
            if (skipLineFeed)
            {
                skipLineFeed = false;
                if (value == '\n') continue;
            }
            if (value is '\r' or '\n')
            {
                // CR単独でも行を返し、次回に続くLFだけを読み飛ばす。
                skipLineFeed = value == '\r';
                return Result();
            }

            hasCharacters = true;
            isWhiteSpace = isWhiteSpace && char.IsWhiteSpace(value);
            if (text.Length < maxLength) text.Append(value);
            else exceedsLimit = true;
            // 超過した行も区切りまで読み進め、次の要求を残す。
        }
        return hasCharacters ? Result() : null;

        BoundedInput Result() => new(exceedsLimit ? string.Empty : text.ToString(), exceedsLimit, isWhiteSpace);
    }

    internal static async Task<BoundedInput> ReadToEndAsync(TextReader input, int maxLength)
    {
        var buffer = new char[4096];
        var text = new StringBuilder();
        while (true)
        {
            // 上限の次の1文字までしか読まず、超過時はEOFを待たない。
            var count = await input.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, maxLength - text.Length + 1)));
            if (count == 0) return new(text.ToString(), false, false);
            if (count > maxLength - text.Length) return new(string.Empty, true, false);
            text.Append(buffer, 0, count);
        }
    }
}

internal readonly record struct BoundedInput(string Text, bool ExceedsLimit, bool IsWhiteSpace);
