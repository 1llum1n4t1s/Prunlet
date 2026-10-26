using System.Text.RegularExpressions;
namespace Prunlet.Core;
public sealed partial class DeletionService
{
    private static bool Digest(string value) => Regex.IsMatch(value, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant);
}
