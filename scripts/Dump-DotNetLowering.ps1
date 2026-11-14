param([Parameter(Mandatory)][string]$Output)
# .NETのToLowerInvariantが1文字を変える全コードポイント（サロゲートを除く）を「codepoint:変換後のcodepoint列」で書き出す。
# Rust側のinvariant_lowerとの総当たり照合の基準にする。
$lines = [Collections.Generic.List[string]]::new()
for ($cp = 0; $cp -le 0x10FFFF; $cp++) {
    if ($cp -ge 0xD800 -and $cp -le 0xDFFF) { continue }
    $text = [char]::ConvertFromUtf32($cp)
    $lower = $text.ToLowerInvariant()
    if ($lower -cne $text) {
        $points = [Collections.Generic.List[string]]::new()
        $i = 0
        while ($i -lt $lower.Length) {
            $value = [char]::ConvertToUtf32($lower, $i)
            $points.Add(('{0:X}' -f $value))
            $i += if ([char]::IsSurrogatePair($lower, $i)) { 2 } else { 1 }
        }
        $lines.Add(('{0:X}:{1}' -f $cp, ($points -join ',')))
    }
}
[IO.File]::WriteAllLines($Output, $lines, [Text.UTF8Encoding]::new($false))
"$($lines.Count) changed code points; $($PSVersionTable.PSVersion); $([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
