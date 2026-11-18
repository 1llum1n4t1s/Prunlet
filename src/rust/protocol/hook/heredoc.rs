use super::*;

/// `smart`は非strictのPowerShell規則の新しい読みで、スマート引用符を同じ種類のASCII引用符と同じに扱う
/// （`@‘`で開いて`'@`・`’@`で閉じる）。`quote`は見出しの引用符の種類（`'`か`"`）。
pub(super) fn here_string(
    s: &[char],
    position: &mut usize,
    quote: char,
    smart: bool,
) -> Result<String> {
    let same_kind = |c: char| {
        if smart {
            powershell_quote_kind(c) == Some(quote)
        } else {
            c == quote
        }
    };
    let mut start = *position + 2;
    while start < s.len() && matches!(s[start], ' ' | '\t') {
        start += 1;
    }
    if start >= s.len() || !matches!(s[start], '\r' | '\n') {
        bail!("PowerShell here-string header must end with a newline.");
    }
    let cr = s[start] == '\r';
    start += 1;
    if cr && start < s.len() && s[start] == '\n' {
        start += 1;
    }
    for end in start..s.len().saturating_sub(1) {
        if (end == start || matches!(s[end - 1], '\r' | '\n'))
            && same_kind(s[end])
            && s[end + 1] == '@'
        {
            // 終端の直前の行終端（`\n`か`\r\n`）は本文に含まれない（言語仕様）。空の本文では何も除かない。
            let mut body = &s[start..end];
            if let [rest @ .., '\n'] = body {
                body = rest;
            }
            if let [rest @ .., '\r'] = body {
                body = rest;
            }
            if quote == '"' {
                let mut i = 0;
                while i + 1 < body.len() {
                    if body[i] == '`' {
                        i += 2;
                        continue;
                    }
                    if body[i] == '$' && body[i + 1] == '(' {
                        bail!(
                            "PowerShell expandable here-string subexpressions cannot be inspected; use a single-quoted literal here-string for remote script data."
                        );
                    }
                    i += 1;
                }
            }
            *position = end + 1;
            return Ok(body.iter().collect());
        }
    }
    bail!("PowerShell here-string has no valid closing marker.")
}
/// POSIX規則で見つけたヒアドキュメント1つ分の情報。本文の範囲と、本文を読み飛ばせるかの判定に使う。
pub(super) struct Heredoc {
    /// 引用除去後の終端語。`None`はbashと同じ終端語を確定できない形（退避を含む`$'…'`・閉じていない引用）で、
    /// 本文を入力の終わりまでとみなす（遅く終われば終端の後ろも本文として文の検査を続けるだけなので安全側に倒れる）。
    pub(super) delimiter: Option<String>,
    /// `<<-`か（本文の各行と終端行の先頭のタブだけを除いて比べる）。
    pub(super) strip_tabs: bool,
    /// 終端語が引用・退避されているか（本文で展開・コマンド置換が起きない）。
    pub(super) quoted: bool,
    /// 終端語が単純な文字（英数字・`_`・`-`・`.`）だけで、退避・`$`・逆引用を含まないか。読み飛ばしの条件に使う。
    pub(super) simple: bool,
    /// `<<`を含む文がtokens出力のどこから始まるか。
    pub(super) statement_start: usize,
    /// `<<`より前の状況が読み飛ばし可能か（括弧の入れ子なし、算術・`[[`・逆引用なし）。
    pub(super) context_ok: bool,
}
/// 同じ行で記録したヒアドキュメントの本文を、すべてdataとして読み飛ばしてよいか。
///
/// 読み飛ばすのは、単純な終端語を引用した本文（展開なしのdata）を、ファイルへ書き出す`cat`か、
/// 本文をコードとして読むインタプリタ（`python`・`node`。`-c`の本文と同じく検査対象外）が受け取る形だけ。
/// shellへ渡りうる形（パイプ・入れ子のグループ・同じ行の後続文・`/dev`への出力）は本文を文として検査する。
pub(super) fn heredoc_skippable(
    heredocs: &[Heredoc],
    out: &[Token],
    boundary_after: bool,
) -> Result<bool> {
    if boundary_after || heredocs.is_empty() {
        return Ok(false);
    }
    for heredoc in heredocs {
        if !heredoc.quoted
            || !heredoc.simple
            || !heredoc.context_ok
            || !heredoc_consumer_is_data_sink(&out[heredoc.statement_start.min(out.len())..])?
        {
            return Ok(false);
        }
    }
    Ok(true)
}
/// `start`から始まるヒアドキュメント本文の範囲を、bashと同じ規則（終端語と行全体の完全一致。`<<-`は先頭のタブだけを除く）で求める。
/// 戻り値は（本文の終わり＝終端行の先頭, 終端行の次の位置）。行末の`\r`も行の一部として比べる
/// （CRLFの入力では、見出しの終端語の直後の`\r`を終端語に含めて記録するため、`EOF\r`の行で終わる）。
/// 終端が見つからない、または終端語を確定できない場合は入力の終わりまでを本文とする（bashも入力の終わりで本文を閉じる）。
///
/// 入力の全行を内容ごとに索引し、終端行を二分探索で求める。行ごとに入力の終わりまで走査すると、
/// 終端のないヒアドキュメントが行ごとに並ぶ入力（本文を区切らない従来の読みで毎行記録する`cat <<EOF`の連続）で二乗になるため。
pub(super) struct HeredocLines {
    /// 行の内容 → その内容の行の（先頭, 改行の位置）の昇順の一覧。
    exact: std::collections::HashMap<String, Vec<(usize, usize)>>,
    /// 先頭のタブを除いた行の内容 → 同上（`<<-`の終端行の照合に使う）。
    pub(super) stripped: std::collections::HashMap<String, Vec<(usize, usize)>>,
    pub(super) len: usize,
}
impl HeredocLines {
    pub(super) fn new(s: &[char]) -> Self {
        let mut exact: std::collections::HashMap<String, Vec<(usize, usize)>> =
            std::collections::HashMap::new();
        let mut stripped: std::collections::HashMap<String, Vec<(usize, usize)>> =
            std::collections::HashMap::new();
        let mut position = 0;
        while position < s.len() {
            let end = s[position..]
                .iter()
                .position(|&c| c == '\n')
                .map_or(s.len(), |offset| position + offset);
            let line = &s[position..end];
            let tabs = line.iter().take_while(|&&c| c == '\t').count();
            exact
                .entry(line.iter().collect())
                .or_default()
                .push((position, end));
            stripped
                .entry(line[tabs..].iter().collect())
                .or_default()
                .push((position, end));
            position = end + 1;
        }
        Self {
            exact,
            stripped,
            len: s.len(),
        }
    }
    pub(super) fn body_end(&self, start: usize, heredoc: &Heredoc) -> (usize, usize) {
        let Some(delimiter) = heredoc.delimiter.as_deref() else {
            return (self.len, self.len);
        };
        let index = if heredoc.strip_tabs {
            &self.stripped
        } else {
            &self.exact
        };
        let Some(lines) = index.get(delimiter) else {
            return (self.len, self.len);
        };
        let first = lines.partition_point(|&(line, _)| line < start);
        match lines.get(first) {
            Some(&(line, end)) => (line, (end + 1).min(self.len)),
            None => (self.len, self.len),
        }
    }
}
/// `s[position]`の`@'`・`@"`の後ろが、空白・タブだけを挟んで行末になるか（PowerShellのヒアストリングの見出し）。
pub(super) fn here_string_header(s: &[char], position: usize) -> bool {
    let mut k = position + 2;
    while k < s.len() && matches!(s[k], ' ' | '\t') {
        k += 1;
    }
    k < s.len() && matches!(s[k], '\r' | '\n')
}
