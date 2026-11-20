use super::*;

/// POSIX規則のANSI-C引用（`$'…'`）を読んでいる間の`quote`の値。`\`は次の1文字を退避し、非退避の`'`で閉じる。
const ANSI_C_QUOTE: char = '\u{1}';
/// 字句解析の読み方の選択。POSIX規則で解釈が分かれる箇所を、呼出し側が両方の読みで検査するために使う。
#[derive(Clone, Copy, Default)]
pub(super) struct LexOptions {
    /// `>&`・`<&`の後ろに数字でも`-`でもない語が続く形（`>& /tmp/z unlink y`）の読み方。
    /// falseは従来どおり`&`で文を割って次の語を実行名として読み、trueは次の語をリダイレクト対象として
    /// 同じ語へつなぐ（bashの`>&word`は`&>word`と同じ出力先の指定）。
    pub(super) attach_ampersand_name: bool,
    /// 終端語を引用しないヒアドキュメント（`<<EOF`）の本文を、bashと同じく`'`・`"`を引用として扱わず
    /// （`$(…)`・逆引用の中を除く）、`#`もコメントにしない読み方。falseは本文を通常の文として読む従来の読み方。
    pub(super) literal_heredoc_body: bool,
    /// 従来の読み。新しい読みが従来の解釈を置き換えた次の機能を無効にし、従来と同じ解釈で読む。
    /// - POSIX: 語頭判定のコメント（従来は語が空なら`#`以降をコメント）、ANSI-C引用（`$'…'`）と`$$`の対、
    ///   二重引用内の`$(…)`の取り込み、`${…}`の1語化、ヒアドキュメント本文・終端行の独立した字句解析と状態の初期化
    ///   （従来どおり本文も通常の文として続けて読む。dataとして読み飛ばす判定は新しい読みと同じ）。
    /// - 非strictのPowerShell: スマート引用符を引用符として読むこと、ブロックコメント（`<#…#>`）。
    ///   ヒアストリングの開始条件（見出しが行末で終わる）は両方の読みで同じ。
    pub(super) legacy: bool,
}
/// 字句解析で見つけた、別の読み方（`LexOptions`）でも検査すべき箇所。
#[derive(Default)]
pub(super) struct LexFound {
    /// `>&`・`<&`の後ろに名前が続く形があった。
    pub(super) ampersand_name: bool,
    /// 文として検査する、終端語を引用しないヒアドキュメント本文があった。
    pub(super) unquoted_heredoc_body: bool,
    /// 新しい読みで、終わりを確定できず検査不能な構文（拒否理由と語）。最初の1つだけを持つ。
    pub(super) uninspectable: Option<(&'static str, String)>,
}
impl LexFound {
    pub(super) fn uninspectable(&mut self, reason: &'static str, token: &str) {
        if self.uninspectable.is_none() {
            self.uninspectable = Some((reason, token.to_owned()));
        }
    }
}
/// 新しい読みの既定の字句解析（単体テストで語の分け方を確認するのに使う）。
#[cfg(test)]
pub(super) fn tokens(script: &str, mode: Mode, strict: bool) -> Result<Vec<Token>> {
    let mut found = LexFound::default();
    tokens_with(script, mode, strict, LexOptions::default(), &mut found)
}
/// 字句解析の本体。
///
/// `options`で読み方を選び（`LexOptions`参照）、別の読み方でも検査すべき箇所があれば`found`へ記録する。
/// 呼出し側は`found`に応じて両方の読みで検査する。
pub(super) fn tokens_with(
    script: &str,
    mode: Mode,
    strict: bool,
    options: LexOptions,
    found: &mut LexFound,
) -> Result<Vec<Token>> {
    let s: Vec<char> = script.chars().collect();
    let mut out = Vec::new();
    let mut t = Token::new("");
    let mut quote = '\0';
    let mut previous_equal = false;
    let mut i = 0;
    // 非strictのPowerShell規則では、スマート引用符もASCIIと同じ種類の引用符として読む（従来の読みを除く）。
    let smart_quotes = mode == Mode::PowerShell && !strict && !options.legacy;
    // POSIX規則の新しい読み（LexOptions::legacy参照）。
    let posix_new = mode == Mode::Posix && !options.legacy;
    // 直前の行継続（`\`＋改行）の次の位置と、その行継続の直前の文字。コメントの語頭判定で行継続を読み飛ばす。
    let mut continuation_end = usize::MAX;
    let mut continuation_previous: Option<char> = None;
    // `${…}`の走査が閉じなかった行の終わり（この位置までは`${`を1語として読まない）。
    let mut parameter_unclosed_until = 0usize;
    // `${…}`の走査の上限に使う、直近に求めた次の改行の位置（無ければ入力の長さ）。
    let mut next_newline: Option<usize> = None;
    // POSIX規則のヒアドキュメント追跡（heredoc_skippable参照）。
    let mut heredocs: Vec<Heredoc> = Vec::new();
    let mut statement_start = 0usize;
    let mut group_depth = 0i32;
    // 従来の読みのヒアドキュメント読み飛ばし判定に使う、下限を切らない括弧の深さ。
    let mut legacy_group_depth = 0i32;
    let mut line_start = 0usize;
    let mut heredoc_boundary_after = false;
    // 単一引用・ANSI-C引用の外で開いたままの逆引用があるか。行をまたいで追う。
    let mut backtick_open = false;
    // 最後に逆引用を開閉した位置（開いたままなら開いた位置）。同じ行で開いた逆引用の中かの判定に使う。
    let mut backtick_opened_at = 0usize;
    // 読み飛ばさないヒアドキュメントの本文・終端行を検査している間の区切り位置（降順。末尾が次の区切り）。
    // 本文と終端行はそれぞれ独立に字句解析し、区切りで引用・括弧・逆引用の状態を本文の前へ戻す。
    // 2つ目の値は、その区切りで終わる区間が終端語を引用しないヒアドキュメントの本文か。
    let mut body_cuts: Vec<(usize, bool)> = Vec::new();
    let mut body_saved = (0i32, false);
    // `literal_heredoc_body`の読みで、引用を有効に戻す`$(…)`の終わり（この位置より前は通常の引用規則）。
    let mut literal_until = 0usize;
    // POSIX規則のブレース展開。`brace_scanned`まではブレースの走査済み、`brace_until`までの`{`・`}`は語の一部。
    let mut brace_scanned = 0usize;
    let mut brace_until = 0usize;
    // 直近に記録したヒアドキュメントの本文・終端行の終わり。読みの系統（新しい読み・従来の読み）を問わず記録し、
    // この位置までの`{`ではブレース展開の語を作らない（本文の区切り`body_cuts`は従来の読みでは作らないため別に持つ）。
    let mut heredoc_body_until = 0usize;
    // ヒアドキュメント本文の終端行の索引（最初のヒアドキュメントで1回だけ作る）。
    let mut heredoc_lines: Option<HeredocLines> = None;
    while i < s.len() {
        // 本文・終端行の区切りでは、引用状態を持ち越さずに語と文を閉じる。
        while let Some(&(cut, _)) = body_cuts.last()
            && i >= cut
        {
            body_cuts.pop();
            flush(&mut t, &mut out);
            quote = '\0';
            previous_equal = false;
            boundary(&mut out);
            statement_start = out.len();
            (group_depth, backtick_open) = body_saved;
            line_start = i;
        }
        let in_body = !body_cuts.is_empty();
        let mut c = s[i];
        // 引用しない終端語の本文を`literal_heredoc_body`で読む区間か。`$(…)`と逆引用の中では引用が有効なので、
        // `$(`を見つけたら対応する`)`まで（閉じなければ次の区切りまで）は通常の引用規則に戻す。
        let literal_body =
            options.literal_heredoc_body && body_cuts.last().is_some_and(|&(_, unquoted)| unquoted);
        if literal_body
            && quote == '\0'
            && i >= literal_until
            && c == '$'
            && s.get(i + 1) == Some(&'(')
        {
            let limit = body_cuts.last().map_or(s.len(), |&(cut, _)| cut);
            literal_until = subexpression_close(&s, i, limit, true).unwrap_or(limit);
        }
        let literal_text = literal_body && i >= literal_until && !backtick_open;
        // 引用外の`<<`（`<<<`を除く）を見つけたら終端語を読み取って記録する。字句解析は通常どおり続ける。
        // 本文の中の`<<`は追跡しない（本文はbashにとってdataで、読み飛ばすと展開される`$(…)`を見落とすため）。
        // 新しい読みでは、ヒアドキュメントでありうるか不確かな文脈（同じ行の`((`・`$((`・`$[`の後ろの算術、
        // 同じ行で開いた逆引用の中）の`<<`を記録しない。記録すると終端行の一致で引用状態を初期化し、
        // 以降の引用を反転させうるため。記録しなければ本文も通常の文として続けて読む（従来の読みと同じ）。
        // 前の行で開いた逆引用の中は従来どおり記録し、本文を読み飛ばさずに区切って検査する。
        if mode == Mode::Posix
            && !in_body
            && quote == '\0'
            && c == '<'
            && s.get(i + 1) == Some(&'<')
            && s.get(i + 2) != Some(&'<')
            && (i == 0 || s[i - 1] != '<')
            && !(posix_new
                && ((backtick_open && backtick_opened_at >= line_start)
                    || s[line_start..i]
                        .windows(2)
                        .any(|w| w == ['(', '('] || w == ['$', '['])))
        {
            let HeredocHeader {
                end: j,
                strip_tabs,
                delimiter,
                quoted,
                complete,
                simple,
                ansi_escape,
            } = heredoc_header(&s, i);
            let determined = complete && !ansi_escape;
            // 新しい読みでは、終端語を確定できないヒアドキュメントの本文の範囲を推測せず、検査不能として拒否する。
            if posix_new && !determined {
                found.uninspectable(
                    "POSIX here-document delimiter cannot be determined",
                    &s[i..j.min(s.len())].iter().collect::<String>(),
                );
            }
            let before: String = s[line_start..i].iter().collect();
            heredocs.push(Heredoc {
                delimiter: determined.then_some(delimiter),
                strip_tabs,
                quoted: quoted && complete,
                simple,
                statement_start,
                // 従来の読みは従来の判定（下限を切らない括弧の深さ、前の行で開いた逆引用を数えない）で読み飛ばす。
                // 従来の読みは本文を区切らないため、読み飛ばさないと本文の引用を後ろへ持ち越し、従来なら検知できた
                // 終端の後ろの削除を見落としうる。shellが読む形の本文の検査は、区切って読む新しい読みが担う。
                context_ok: if options.legacy {
                    legacy_group_depth == 0
                } else {
                    group_depth == 0 && !backtick_open
                } && !before.contains("((")
                    && !before.contains("[[")
                    && !before.contains('`')
                    && !before.contains("$("),
            });
        }
        if strict && mode == Mode::PowerShell {
            if ('\u{2018}'..='\u{201e}').contains(&c) {
                bail!("EncodedCommand contains unsupported smart quotation marks.");
            }
            if quote == '\0' && c == '<' && s.get(i + 1) == Some(&'#') {
                bail!("EncodedCommand block comments cannot be inspected.");
            }
            if quote == '\0' && c == '@' && s.get(i + 1) == Some(&'{') {
                bail!("EncodedCommand hashtables cannot be inspected.");
            }
            if quote == '\0' && c == '$' && s.get(i + 1) == Some(&'{') {
                bail!("EncodedCommand braced variables cannot be inspected.");
            }
            if quote != '\''
                && c == '`'
                && matches!(s.get(i + 1), Some('u' | 'U'))
                && s.get(i + 2) == Some(&'{')
            {
                bail!("EncodedCommand Unicode escapes cannot be inspected.");
            }
            // 二重引用内の`$(...)`は任意のコマンドを実行しうるため原則拒否する。
            // ただし変数の参照・プロパティ参照・数値添字だけの形（`$($sw.Elapsed.TotalSeconds)`・
            // `$($r.items[0].Name)`）はコマンドもメソッドも呼ばないため、そのまま文字列として読む。
            if quote == '"'
                && c == '$'
                && s.get(i + 1) == Some(&'(')
                && !powershell_property_subexpression(&s[i + 2..])
            {
                bail!("EncodedCommand expandable string subexpressions cannot be inspected.");
            }
            if quote == '\0' && c == '&' {
                let mut next = i + 1;
                while next < s.len() && s[next].is_whitespace() {
                    next += 1;
                }
                if next < s.len() && s[next] == '\'' && (i == 0 || s[i - 1] != '&') {
                    if s[i + 1..next].iter().any(|c| matches!(c, '\r' | '\n')) {
                        bail!("EncodedCommand invocation target cannot cross a line boundary.");
                    }
                    let (target, end) = strict_call_target(&s, next)?;
                    flush(&mut t, &mut out);
                    previous_equal = false;
                    boundary(&mut out);
                    out.push(Token::new(target));
                    i = end + 1;
                    continue;
                }
                if next < s.len() && matches!(s[next], '(' | '$' | '@' | '{' | '\'' | '"' | '`') {
                    bail!("EncodedCommand dynamic invocation cannot be inspected.");
                }
            }
            if quote == '\0'
                && c == '.'
                && t.text.is_empty()
                && s.get(i + 1).is_some_and(|c| c.is_whitespace() || *c == '(')
                && !powershell_dot_argument(&s, i, &out)
            {
                bail!("EncodedCommand dot-sourcing cannot be inspected.");
            }
        }
        let literal_quote = matches!(quote, '\'' | ANSI_C_QUOTE);
        if mode == Mode::Posix && c == '`' && !literal_quote {
            t.backticks += 1;
            backtick_open = !backtick_open;
            backtick_opened_at = i;
        }
        if matches!(mode, Mode::Posix | Mode::PowerShell)
            && quote == '"'
            && c == '$'
            && s.get(i + 1) == Some(&'(')
        {
            t.subexpression = true;
        }
        if mode == Mode::Posix
            && !literal_quote
            && (matches!(c, '$' | '`') || quote == '\0' && matches!(c, '*' | '?' | '['))
        {
            t.dynamic = true;
        }
        if quote != '\0' {
            if quote == ANSI_C_QUOTE {
                if c == '\\' && i + 1 < s.len() {
                    t.text.push(s[i + 1]);
                    i += 2;
                    continue;
                }
                if c == '\'' {
                    quote = '\0';
                } else {
                    t.text.push(c);
                }
                i += 1;
                continue;
            }
            // 二重引用内の`$(…)`は外側と独立した引用文脈を持つ（`"$(echo '"')"`の内側の`"`で外側を閉じない）。
            // 対応する`)`まで生のまま語へ取り込み、本文は`Inspector::expanded`が再帰検査する。
            // 従来の読みでは取り込まず、二重引用の中を1文字ずつ読む。
            if posix_new && quote == '"' && c == '$' && s.get(i + 1) == Some(&'(') {
                let limit = body_cuts.last().map_or(s.len(), |&(cut, _)| cut);
                // ヒアドキュメント本文の中で閉じていない`$(`は、次の区切りまでを本文として取り込む（expandedが再帰検査する）。
                // 本文の外で閉じていない`$(`は、どこまでが置換かを確定できないため検査不能として拒否する。
                let close = subexpression_close(&s, i, limit, true);
                if close.is_none() && body_cuts.is_empty() {
                    found.uninspectable(
                        "unterminated POSIX command substitution cannot be inspected",
                        "$(",
                    );
                }
                let end = close.unwrap_or(limit);
                t.text.extend(&s[i..end]);
                i = end;
                continue;
            }
            if quote == '"'
                && i + 1 < s.len()
                && ((mode == Mode::PowerShell && c == '`')
                    || (mode == Mode::Posix
                        && c == '\\'
                        && matches!(s[i + 1], '"' | '\\' | '$' | '`')))
            {
                i += 1;
                t.text.push(s[i]);
                i += 1;
                continue;
            }
            let same_kind = |value: char| {
                if smart_quotes {
                    powershell_quote_kind(value) == Some(quote)
                } else {
                    value == quote
                }
            };
            if same_kind(c) {
                if mode != Mode::Posix && s.get(i + 1).is_some_and(|&n| same_kind(n)) {
                    t.text.push(c);
                    i += 1;
                } else {
                    quote = '\0';
                }
            } else {
                t.text.push(c);
            }
            i += 1;
            continue;
        }
        if ((mode == Mode::Cmd && c == '^')
            || (mode == Mode::PowerShell && c == '`')
            || (mode == Mode::Posix && c == '\\'))
            && i + 1 < s.len()
        {
            let escape_start = i;
            i += 1;
            c = s[i];
            if matches!(c, '\r' | '\n') {
                if c == '\r' && s.get(i + 1) == Some(&'\n') {
                    i += 1;
                }
                if mode == Mode::Posix {
                    // bashは行継続を語の分割前に取り除く。退避した文字とは区別し、語頭・演算子の判定を変えない。
                    t.continued = true;
                    if escape_start != continuation_end {
                        continuation_previous = escape_start.checked_sub(1).map(|k| s[k]);
                    }
                    continuation_end = i + 1;
                } else {
                    // CMD・PowerShellの行継続でつないだ語は、静的な値の判定から外すため退避ありとして扱う。
                    t.escaped = true;
                }
            } else {
                t.escaped = true;
                t.bare_chars += 1;
                append(&mut t, c, &mut previous_equal);
            }
            i += 1;
            continue;
        }
        // 非strictのPowerShell規則のブロックコメント（従来の読みを除く）。語頭か代入の直後（`$x=<# c #>`）の`<#`から
        // 最初の`#>`までを空白として読み飛ばす（閉じがなければ残り全体がコメント）。行コメントと誤認して`#>`以降の行を捨てない。
        if smart_quotes
            && c == '<'
            && s.get(i + 1) == Some(&'#')
            && ((t.text.is_empty() && !t.quoted) || t.text.ends_with('='))
        {
            let close =
                (i + 2..s.len().saturating_sub(1)).find(|&k| s[k] == '#' && s[k + 1] == '>');
            i = close.map_or(s.len(), |k| k + 2);
            previous_equal = false;
            continue;
        }
        // ヒアストリングは見出し（`@'`・`@"`、新しい読みではスマート引用符の同等形も）の後ろが行末で終わる場合だけ。
        // PowerShellは語頭・代入の直後に限らず`,`や演算子の後ろでも開始する（`Write-Output 1,@'`）。
        // 非strictでは、見出しの後ろが行末でない形（`ssh user@"host" ls`）を、通常の`@`と引用として読む。
        let here_kind = s.get(i + 1).and_then(|&q| {
            if smart_quotes {
                powershell_quote_kind(q)
            } else {
                matches!(q, '\'' | '"').then_some(q)
            }
        });
        if mode == Mode::PowerShell
            && c == '@'
            && let Some(here_quote) = here_kind
            && (strict || here_string_header(&s, i))
        {
            if t.quote_start.is_none() {
                t.quote_start = Some(t.text.len());
            }
            let body = here_string(&s, &mut i, here_quote, smart_quotes)?;
            t.text.push_str(&body);
            t.quoted = true;
            t.quote_segments += 1;
            t.non_single_quote = true;
            i += 1;
            continue;
        }
        // POSIX規則の新しい読みで、引用外の`$$`（シェルのPID）は2文字の対。続く`'`は通常の単一引用で、
        // `$'…'`（ANSI-C引用）の開始ではない（`echo $$'\'`）。
        if posix_new && c == '$' && s.get(i + 1) == Some(&'$') && !literal_text {
            t.bare_chars += 2;
            append(&mut t, '$', &mut previous_equal);
            append(&mut t, '$', &mut previous_equal);
            i += 2;
            continue;
        }
        // POSIX規則の新しい読みで、引用外の`${…}`（パラメーター展開）は対応する`}`までを1語の一部として読み、
        // 中の`#`・`{`・`}`・空白で語を割らない（`${#arr[@]}`・`${x:- #}`）。行をまたぐ・閉じない形は従来どおり読む。
        // 中の`$(…)`・逆引用は語の印（subexpression・backticks）を付け、`Inspector::noncanonical`が再帰検査する。
        // 閉じなかった走査の行の終わりまでは再走査しない（同じ行に`${`が多数並んでも線形に保つ）。
        let parameter_end = if posix_new
            && c == '$'
            && s.get(i + 1) == Some(&'{')
            && !literal_text
            && i >= parameter_unclosed_until
        {
            // 行末は行ごとに1回だけ求める（同じ行の`${`ごとに求めると、改行のない長い行で二乗になる）。
            if next_newline.is_none_or(|n| n < i) {
                next_newline = Some(
                    s[i..]
                        .iter()
                        .position(|&d| d == '\n')
                        .map_or(s.len(), |offset| i + offset),
                );
            }
            let line_end = next_newline.unwrap_or(s.len());
            let end = parameter_expansion_end(&s, i, line_end);
            if end.is_none() {
                parameter_unclosed_until = line_end;
            }
            end
        } else {
            None
        };
        if let Some(end) = parameter_end {
            for (k, &d) in s[i..end].iter().enumerate() {
                if d == '`' {
                    t.backticks += 1;
                    backtick_open = !backtick_open;
                    backtick_opened_at = i + k;
                }
                t.bare_chars += 1;
                t.text.push(d);
            }
            if s[i..end].windows(2).any(|w| w == ['$', '(']) {
                t.subexpression = true;
            }
            t.dynamic = true;
            previous_equal = false;
            i = end;
            continue;
        }
        // POSIX規則のANSI-C引用（`$'…'`）。`\'`は引用を閉じない。語は`$`を含むため従来どおり動的として扱う。
        // 引用しない終端語の本文を文字どおりに読む区間と、従来の読みでは、`$'`も引用ではない。
        if posix_new && c == '$' && s.get(i + 1) == Some(&'\'') && !literal_text {
            t.bare_chars += 1;
            append(&mut t, c, &mut previous_equal);
            if t.quote_start.is_none() {
                t.quote_start = Some(t.text.len());
            }
            if t.equality.is_some() {
                t.quoted_after_equality = true;
            }
            previous_equal = false;
            quote = ANSI_C_QUOTE;
            t.quoted = true;
            t.quote_segments += 1;
            i += 2;
            continue;
        }
        let opening = if smart_quotes {
            powershell_quote_kind(c)
        } else if literal_text {
            // 引用しない終端語の本文では、`'`・`"`は通常の文字（bashは本文の引用を解釈しない）。
            None
        } else if c == '"' || (c == '\'' && mode != Mode::Cmd) {
            Some(c)
        } else {
            None
        };
        if let Some(kind) = opening {
            if t.quote_start.is_none() {
                t.quote_start = Some(t.text.len());
            }
            if t.equality.is_some() {
                t.quoted_after_equality = true;
            }
            previous_equal = false;
            quote = kind;
            t.quoted = true;
            t.quote_segments += 1;
            if kind != '\'' {
                t.non_single_quote = true;
            }
            i += 1;
            continue;
        }
        // 行コメント。POSIX規則の新しい読みでは、語の先頭（行継続を除いた直前の生の文字が空白・改行・`;|&()`か
        // 入力の先頭）で、語に引用・退避を含まない`#`だけをコメントにする（`${#x}`・`""#`・`{\`改行`#`の`#`は語の一部）。
        // 従来の読みでは、語がまだ空なら`#`以降をコメントにする。
        let comment = c == '#'
            && t.text.is_empty()
            && match mode {
                Mode::Cmd => false,
                Mode::PowerShell => true,
                Mode::Posix if options.legacy => true,
                // 引用しない終端語の本文を文字どおりに読む区間では、`#`もコメントにしない（bashは本文を展開して渡すだけ）。
                Mode::Posix => {
                    let previous = if i == continuation_end {
                        continuation_previous
                    } else {
                        i.checked_sub(1).map(|k| s[k])
                    };
                    !literal_body
                        && !t.quoted
                        && !t.escaped
                        && previous.is_none_or(|p| {
                            p.is_whitespace() || matches!(p, ';' | '|' | '&' | '(' | ')')
                        })
                }
            };
        if comment {
            // 新しい読みで、開いた逆引用の中のコメントは閉じる逆引用で終わる（bashは逆引用の範囲を先に決める）。
            let backtick_comment = posix_new && backtick_open;
            while i < s.len() && !matches!(s[i], '\r' | '\n') && !(backtick_comment && s[i] == '`')
            {
                i += 1;
            }
            if i == s.len() {
                break;
            }
            if s[i] == '`' {
                continue;
            }
            c = s[i];
        }
        // fdの複製・閉じ（`2>&1`・`>&2`・`<&0`・`>&-`）の`&`は文の区切りではなく、リダイレクト演算子の一部。
        // 語を割ると、後ろの`1 rm x`が別の文になり、リダイレクトの後の実行名を検査できない。
        // 直後（空白を除く）が数字か`-`のときだけ結合する。`>&del x`・`>&"del" x`・`>& del x`は従来どおり`&`で文を割り、`del x`を検査する。
        // `&`と数字・`-`の間の空白（`2>& 1`）も飛ばして結合する（bashもcmdも`2>&1`と同じ複製として読む）。
        // `>& del x`は名前が続くので結合しない。
        if matches!(mode, Mode::Posix | Mode::Cmd)
            && c == '&'
            && t.quote_start.is_none()
            && (t.text.ends_with('>') || t.text.ends_with('<'))
            && t.text
                .trim_end_matches(['<', '>'])
                .chars()
                .all(|d| d.is_ascii_digit())
            && let Some(offset) = s[i + 1..].iter().position(|d| !matches!(d, ' ' | '\t'))
            && (s[i + 1 + offset].is_ascii_digit() || s[i + 1 + offset] == '-')
        {
            let next = s[i + 1 + offset];
            t.bare_chars += 1;
            append(&mut t, c, &mut previous_equal);
            if next == '-' && mode == Mode::Posix {
                // POSIX規則では`&-`（fdを閉じる）で演算子が完結し、直結した語（`>&-rm x`）は別の語。
                t.bare_chars += 1;
                append(&mut t, next, &mut previous_equal);
                flush(&mut t, &mut out);
                previous_equal = false;
                i += offset + 2;
            } else {
                i += 1 + offset;
            }
            continue;
        }
        // POSIX規則で`>&`・`<&`の後ろに名前が続く形。bashは名前を出力先として読むため（`>& /tmp/z unlink y`は
        // `unlink y`を実行する）、`&`で割る読みに加えて、名前をリダイレクト対象としてつなぐ読みでも検査させる。
        if mode == Mode::Posix
            && c == '&'
            && (t.text.ends_with('>') || t.text.ends_with('<'))
            && redirect_operator_prefix(&t)
        {
            found.ampersand_name = true;
            if options.attach_ampersand_name {
                t.bare_chars += 1;
                append(&mut t, c, &mut previous_equal);
                i += 1;
                while i < s.len() && matches!(s[i], ' ' | '\t') {
                    i += 1;
                }
                continue;
            }
        }
        // POSIX規則の`>|`（`N>|`を含む。noclobberを無視する出力）は1つの演算子で、`|`はパイプではない。
        if mode == Mode::Posix
            && c == '|'
            && redirect_operator_prefix(&t)
            && t.text.trim_start_matches(|d: char| d.is_ascii_digit()) == ">"
        {
            t.bare_chars += 1;
            append(&mut t, c, &mut previous_equal);
            i += 1;
            continue;
        }
        // POSIX規則のブレース展開（`r{m,}`・`{unlink,x}`・`{1..3}`）。`$`直後の`{`（`${…}`）と、空白を伴うグループ
        // （`{ …; }`）・`{}`・区切りのない`{x}`は従来どおり文の境界として読む。展開を含む語は`{`・`}`で割らずに
        // 1語のまま印を付け、実行名の位置では`Inspector::command`が検査不能として拒否する。
        // ヒアドキュメント本文（読み飛ばさずに文として読む本文）の中では、ブレース展開の語を作らず`{`・`}`を従来どおり境界として読む
        // （本文のJSON行`{"a":1,"b":2}`を実行名の位置のブレース展開として拒否しない。main 4ec0b8fと同じ読み）。
        if mode == Mode::Posix
            && c == '{'
            && i >= brace_scanned
            && i >= heredoc_body_until
            && (i == 0 || s[i - 1] != '$')
        {
            let (end, expansion) = brace_word_scan(&s, i);
            brace_scanned = end;
            if expansion {
                brace_until = end;
                t.brace = true;
            }
        }
        let in_brace = i < brace_until && matches!(c, '{' | '}');
        let is_boundary =
            !in_brace && matches!(c, ';' | '|' | '&' | '\r' | '\n' | '(' | ')' | '{' | '}');
        if c.is_whitespace() || is_boundary {
            flush(&mut t, &mut out);
            previous_equal = false;
            // 行末で、記録したヒアドキュメントの本文の範囲を確定し、dataとして読み飛ばすか、文として別に検査する。
            if mode == Mode::Posix && c == '\n' {
                if !heredocs.is_empty() {
                    let skip = heredoc_skippable(&heredocs, &out, heredoc_boundary_after)?;
                    let mut cuts = Vec::new();
                    let mut position = i + 1;
                    let mut unquoted_body = false;
                    for heredoc in &heredocs {
                        let (body_end, next) = heredoc_lines
                            .get_or_insert_with(|| HeredocLines::new(&s))
                            .body_end(position, heredoc);
                        // 本文の区間には、終端語を引用しない（bashが本文を展開する）かを持たせる。終端行は持たない。
                        cuts.push((body_end, !heredoc.quoted));
                        cuts.push((next, false));
                        unquoted_body |= !heredoc.quoted;
                        position = next;
                    }
                    heredocs.clear();
                    heredoc_boundary_after = false;
                    heredoc_body_until = position;
                    if skip {
                        boundary(&mut out);
                        statement_start = out.len();
                        i = position;
                        line_start = position;
                        continue;
                    }
                    // 従来の読みでは、読み飛ばさない本文も区切らず、通常の文として続けて読む。
                    if !options.legacy {
                        // 引用しない終端語の本文は、呼出し側が`literal_heredoc_body`の読みでも検査する。
                        found.unquoted_heredoc_body |= unquoted_body;
                        // 読み飛ばさない本文と終端行は、それぞれ独立に文として検査する。本文の引用状態を
                        // 終端の後ろへ持ち越さず、終端行の次からは通常の状態で読み直す。
                        // 同じ位置の区切り（終端のない本文）は、本文側の印を残して1つにまとめる。
                        cuts.dedup_by_key(|cut| cut.0);
                        cuts.reverse();
                        body_cuts = cuts;
                        body_saved = (group_depth, backtick_open);
                    }
                }
                line_start = i + 1;
            }
            if mode == Mode::Posix && is_boundary && !matches!(c, '\r' | '\n') {
                if !heredocs.is_empty() {
                    heredoc_boundary_after = true;
                }
                match c {
                    '(' | '{' => {
                        group_depth += 1;
                        legacy_group_depth += 1;
                    }
                    // 引数の`}`（`echo }`）で負にならないよう0で下限を切る。負のまま`{`で0へ戻ると、
                    // グループの中のヒアドキュメントを外側と誤認するため。従来の読みの判定用には下限を切らない値も持つ。
                    ')' | '}' => {
                        group_depth = (group_depth - 1).max(0);
                        legacy_group_depth -= 1;
                    }
                    _ => {}
                }
            }
            if is_boundary {
                boundary(&mut out);
                statement_start = out.len();
                // CMDでは`;`は空白相当の区切りで文の境界ではない。検査のため文は割るが、
                // 境界が`;`だったことを残し、`cmd`wrapperの引数列が割れた形を呼出し側で拒否できるようにする。
                // `(`の境界も印を残し、`for /f … in ('del x')`のコマンド集合の先頭語を呼出し側が判定できるようにする。
                if mode == Mode::Cmd
                    && matches!(c, ';' | '(')
                    && let Some(last) = out.last_mut()
                {
                    last.text = c.to_string();
                }
            }
        } else {
            // POSIX・CMD規則では、引用外・非退避の`<`・`>`の手前で語を切る（`rm>/dev/null x`の実行名は`rm`）。
            // 数字だけの語（`2>`のfd番号）と演算子の途中（`>>`・`<<`）は切らない。PowerShellは`<`・`>`で一般の語を切らない。
            if matches!(mode, Mode::Posix | Mode::Cmd)
                && matches!(c, '<' | '>')
                && !redirect_operator_prefix(&t)
            {
                flush(&mut t, &mut out);
                previous_equal = false;
            }
            // 引用外・非退避の`,`だけを記録する（引用内は上で、`^,`は退避分岐で処理済み）。
            if mode == Mode::Cmd && c == ',' {
                t.commas.push(t.text.len());
            }
            // 語が空か引用・退避のないfd番号（数字）だけのところへ足す引用外・非退避の`<`・`>`は、リダイレクト演算子の始まり。
            // 語が空のときの`escaped`は、CMD・PowerShellの行継続（`^`・`` ` ``＋改行）が語の前に立てた印で、演算子自体は退避されていない。
            if matches!(c, '<' | '>')
                && t.quote_start.is_none()
                && (t.text.is_empty() || !t.escaped)
                && !t.dynamic
                && t.text.chars().all(|d| d.is_ascii_digit())
            {
                t.redirect = true;
            }
            t.bare_chars += 1;
            append(&mut t, c, &mut previous_equal);
        }
        i += 1;
    }
    if strict && quote != '\0' {
        bail!("EncodedCommand has an unterminated string.");
    }
    flush(&mut t, &mut out);
    Ok(out)
}
