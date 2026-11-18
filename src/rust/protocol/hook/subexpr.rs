use super::*;

/// `chars[start]`が`$`、`chars[start + 1]`が`(`のとき、対応する`)`の次の位置を返す。`limit`までに閉じなければ`None`。
/// 入れ子の括弧・`'`・`"`（二重引用の中の`$(…)`を含む）・`\`の退避を読む。
/// `posix`はPOSIX規則で、逆引用を閉じる逆引用までの入れ子のコマンド置換（中の`\`は次の1文字を退避）として、
/// `$'…'`をANSI-C引用（`\`は次の1文字を退避）として、`$$`を2文字の対として、`${…}`をパラメーター展開（中の`)`・`#`は閉じ・コメントでない）として、
/// 括弧の中の語頭の`#`から行末までをコメントとして、`<<<`をヒアストリングとして読む。
/// PowerShell規則では逆引用は次の1文字を退避する文字で、`$'`・`$$`は特別に扱わない。
/// `Inspector::expanded`と字句解析が同じ範囲を使う。入れ子は明示のスタックで追い、深い入れ子でも再帰しない。
pub(super) fn subexpression_close(
    chars: &[char],
    start: usize,
    limit: usize,
    posix: bool,
) -> Option<usize> {
    // 閉じる逆引用の次の位置。`i`は開く逆引用の位置。
    let backtick_close = |i: usize| -> Option<usize> {
        let mut k = i + 1;
        while k < limit {
            match chars[k] {
                '\\' => k += 2,
                '`' => return Some(k + 1),
                _ => k += 1,
            }
        }
        None
    };
    // 文脈のスタック。`(`は括弧の中、`"`は二重引用の中。
    let mut stack = vec!['('];
    // POSIX規則で、置換の直下（入れ子の括弧・算術の外）に書いたヒアドキュメントの（終端語, `<<-`か）。
    // 行末で本文を読み飛ばす（`"$(cat <<'EOF'`…`EOF`改行`)"`の本文の`'`を引用として数えない）。
    let mut heredocs: Vec<(Vec<char>, bool)> = Vec::new();
    // 直前の`\`の退避が終わった位置（退避した空白の直後の`#`をコメントの語頭と取り違えない）。
    let mut escape_end = usize::MAX;
    let mut i = start + 2;
    while i < limit {
        let c = chars[i];
        if posix && c == '`' {
            i = backtick_close(i)?;
            continue;
        }
        if posix && stack.len() == 1 && c == '\n' && !heredocs.is_empty() {
            // 記録した順に、終端語と行全体が一致する行まで（`<<-`は先頭のタブを除いて比べる）を本文として読み飛ばす。
            let mut position = i + 1;
            for (delimiter, strip_tabs) in heredocs.drain(..) {
                loop {
                    if position >= limit {
                        return None;
                    }
                    let end = chars[position..limit]
                        .iter()
                        .position(|&d| d == '\n')
                        .map_or(limit, |offset| position + offset);
                    let mut line = &chars[position..end];
                    if strip_tabs {
                        while let ['\t', rest @ ..] = line {
                            line = rest;
                        }
                    }
                    position = end + 1;
                    if line == delimiter.as_slice() {
                        break;
                    }
                }
            }
            i = position;
            continue;
        }
        // `<<<`はヒアストリング（後ろの語がそのまま入力になる）で、ヒアドキュメントの終端語を読まない。
        // 3文字をまとめて読み飛ばし、2文字目からの`<<`をヒアドキュメントと取り違えない。
        if posix
            && c == '<'
            && chars.get(i + 1) == Some(&'<')
            && chars.get(i + 2) == Some(&'<')
            && stack.last() != Some(&'"')
        {
            i += 3;
            continue;
        }
        if posix
            && stack.len() == 1
            && c == '<'
            && chars.get(i + 1) == Some(&'<')
            && chars.get(i + 2) != Some(&'<')
        {
            // 終端語を読む。引用は外し、ANSI-C引用・展開を含む終端語は範囲を確定できないため`None`。
            let mut j = i + 2;
            let strip_tabs = chars.get(j) == Some(&'-');
            if strip_tabs {
                j += 1;
            }
            while j < limit && matches!(chars[j], ' ' | '\t') {
                j += 1;
            }
            let mut delimiter = Vec::new();
            while j < limit
                && !chars[j].is_whitespace()
                && !matches!(chars[j], ';' | '|' | '&' | '(' | ')' | '<' | '>')
            {
                match chars[j] {
                    '\'' | '"' => {
                        let close = chars[j];
                        j += 1;
                        while j < limit && chars[j] != close {
                            if close == '"' && matches!(chars[j], '\\' | '$' | '`') {
                                return None;
                            }
                            delimiter.push(chars[j]);
                            j += 1;
                        }
                        if j >= limit {
                            return None;
                        }
                        j += 1;
                    }
                    '\\' => {
                        delimiter.push(*chars.get(j + 1)?);
                        j += 2;
                    }
                    '$' | '`' => return None,
                    other => {
                        delimiter.push(other);
                        j += 1;
                    }
                }
            }
            if chars.get(j) == Some(&'\r') && chars.get(j + 1) == Some(&'\n') {
                delimiter.push('\r');
            }
            heredocs.push((delimiter, strip_tabs));
            i = j;
            continue;
        }
        if stack.last() == Some(&'"') {
            match c {
                '\\' | '`' => i += 2,
                '"' => {
                    stack.pop();
                    i += 1;
                }
                '$' if chars.get(i + 1) == Some(&'(') => {
                    stack.push('(');
                    i += 2;
                }
                _ => i += 1,
            }
            continue;
        }
        match c {
            '\\' | '`' => {
                i += 2;
                escape_end = i;
            }
            '$' if posix && chars.get(i + 1) == Some(&'$') => i += 2,
            // POSIX規則の`${…}`（パラメーター展開）の中。`#`はコメントでなく（`${x:- #}`）、`)`は閉じではない。
            '$' if posix && chars.get(i + 1) == Some(&'{') => {
                stack.push('{');
                i += 2;
            }
            '}' if stack.last() == Some(&'{') => {
                stack.pop();
                i += 1;
            }
            ')' if stack.last() == Some(&'{') => i += 1,
            // ANSI-C引用の中は`\`が次の1文字を退避し、非退避の`'`で閉じる。
            '$' if posix && chars.get(i + 1) == Some(&'\'') => {
                let mut k = i + 2;
                loop {
                    match chars[..limit].get(k) {
                        None => return None,
                        Some('\\') => k += 2,
                        Some('\'') => break,
                        Some(_) => k += 1,
                    }
                }
                i = k + 1;
            }
            // POSIX規則で、括弧の中の語頭（直前が退避されていない空白・`;|&()`）の`#`から行末まではコメント。
            // 中の`'`・`)`を引用・閉じとして数えない（`"$(`改行`# don't`改行`…)"`）。改行は読み進めず、ヒアドキュメント本文の読み飛ばしの判定へ渡す。
            // `${#x}`・`$#`・`16#ff`・`\ #`の`#`と`${…}`の中の`#`は語頭のコメントではない。
            // 逆引用の中は`backtick_close`が閉じる逆引用までを読むため、ここへ来ない。
            '#' if posix
                && stack.last() == Some(&'(')
                && escape_end != i
                && (chars[i - 1].is_whitespace()
                    || matches!(chars[i - 1], ';' | '|' | '&' | '(' | ')')) =>
            {
                while i < limit && chars[i] != '\n' {
                    i += 1;
                }
            }
            // 単一引用の中は退避を含めて文字どおり。
            '\'' => match chars[i + 1..limit].iter().position(|&d| d == '\'') {
                Some(offset) => i += offset + 2,
                None => return None,
            },
            '"' | '(' => {
                stack.push(c);
                i += 1;
            }
            ')' => {
                stack.pop();
                i += 1;
                if stack.is_empty() {
                    return Some(i);
                }
            }
            _ => i += 1,
        }
    }
    None
}
/// 従来の読みで、`chars[start]`の`$(`に対応する`)`の次の位置を返す（閉じなければ`None`）。
/// 括弧の数と`'`・`"`の引用だけを数え、`\`・逆引用は次の1文字を退避する（入れ子の引用文脈は追わない）。
pub(super) fn subexpression_close_legacy(chars: &[char], start: usize) -> Option<usize> {
    let mut level = 1;
    let mut end = start + 2;
    let mut quote = '\0';
    while end < chars.len() && level > 0 {
        let c = chars[end];
        if c == '\\' || c == '`' {
            end += 2;
            continue;
        }
        if quote != '\0' {
            if c == quote {
                quote = '\0';
            }
            end += 1;
            continue;
        }
        if c == '\'' || c == '"' {
            quote = c;
        } else if c == '(' {
            level += 1;
        } else if c == ')' {
            level -= 1;
        }
        end += 1;
    }
    (level == 0).then_some(end)
}
/// POSIX規則で、`s[start]`の`{`から、bashの1語の終わり（引用外の空白・`;|&()<>`・逆引用）までを走査し、
/// 語の終わりの位置と、語が引用外のブレース展開（`,`か`..`を含む対応した`{…}`）を含むかを返す。
/// `${…}`はパラメーター展開として数えない。呼出し側は返した位置までを再走査しないため、全体は線形に保たれる。
pub(super) fn brace_word_scan(s: &[char], start: usize) -> (usize, bool) {
    // 開いている`{`ごとの（パラメーター展開か, 同じ階層に区切りを含むか）。
    let mut stack: Vec<(bool, bool)> = Vec::new();
    let mut found = false;
    let mut j = start;
    while j < s.len() {
        let c = s[j];
        if c.is_whitespace() || matches!(c, ';' | '|' | '&' | '(' | ')' | '<' | '>' | '`') {
            break;
        }
        match c {
            '\\' => {
                j += 2;
                continue;
            }
            '\'' => {
                j = s[j + 1..]
                    .iter()
                    .position(|&d| d == '\'')
                    .map_or(s.len(), |offset| j + offset + 2);
                continue;
            }
            '"' => {
                let mut k = j + 1;
                while k < s.len() && s[k] != '"' {
                    if s[k] == '\\' {
                        k += 1;
                    }
                    k += 1;
                }
                j = k + 1;
                continue;
            }
            '$' if s.get(j + 1) == Some(&'{') => {
                stack.push((true, false));
                j += 2;
                continue;
            }
            '{' => stack.push((false, false)),
            '}' => {
                if let Some((param, separated)) = stack.pop()
                    && !param
                    && separated
                {
                    found = true;
                }
            }
            ',' => {
                if let Some(top) = stack.last_mut()
                    && !top.0
                {
                    top.1 = true;
                }
            }
            '.' if s.get(j + 1) == Some(&'.') => {
                if let Some(top) = stack.last_mut()
                    && !top.0
                {
                    top.1 = true;
                }
            }
            _ => {}
        }
        j += 1;
    }
    (j.min(s.len()), found)
}
/// POSIX規則の語が`名前[`で始まり、引用外の`[`が語の中で`]`に閉じないまま終わるか（`a[1 + 1]=5`の`a[1`）。
pub(super) fn posix_unclosed_subscript(word: &Token) -> bool {
    let text = word.text.as_str();
    let name = text
        .char_indices()
        .take_while(|&(k, d)| d == '_' || d.is_ascii_alphabetic() || (k > 0 && d.is_ascii_digit()))
        .count();
    name > 0
        && text[name..].starts_with('[')
        && word.quote_start.is_none_or(|q| q > name)
        && !text[name..].contains(']')
}
/// POSIX規則の実行名の位置の語が、空に展開されて次の語を実行名にしうる引用なしの`${…}`だけの語か
/// （代入でなく、`${`で始まり、最後の`${…}`の後ろに残りがない）。`Inspector::command`が読み飛ばす語の判定に使う。
pub(super) fn posix_empty_parameter_word(word: &Token) -> Result<bool> {
    Ok(word.quote_start.is_none()
        && word.text.starts_with("${")
        && !compiled(&ASSIGNMENT)?.is_match(&word.text)
        && posix_parameter_rest(&word.text) == Some(""))
}
/// POSIX規則の語に含まれる最後の`${…}`（パラメーター展開）の後ろの残りを返す（`${X}rm`は`rm`、`${X}`は空）。
/// `${`を含まない、または対応する`}`が無い語は`None`。
pub(super) fn posix_parameter_rest(text: &str) -> Option<&str> {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let plain: Vec<char> = chars.iter().map(|&(_, d)| d).collect();
    let mut rest = None;
    let mut k = 0;
    while k + 1 < plain.len() {
        if plain[k] == '$' && plain[k + 1] == '{' {
            if let Some(end) = parameter_expansion_end(&plain, k, plain.len()) {
                rest = Some(chars.get(end).map_or(text.len(), |&(byte, _)| byte));
                k = end;
                continue;
            }
            break;
        }
        k += 1;
    }
    rest.map(|byte| &text[byte..])
}
/// POSIX規則で、`s[start]`の`$`に続く`${…}`（パラメーター展開）の、対応する`}`の次の位置を返す。
/// 入れ子の`{`・`}`を数え、`\`の退避・`'`・`"`の引用・`$(…)`・逆引用の中の`}`は数えない。
/// 改行を含む・閉じない形は`None`（呼出し側は従来どおり`{`・`}`で語を割って読む）。
/// `limit`より先は走査しない。改行を含む形は`None`なので、字句解析は行末（次の改行の位置）を渡し、
/// 閉じない`${…$(`が行ごとに並んでも入力の終わりまで走査し直さない（全体を線形に保つ）。
pub(super) fn parameter_expansion_end(s: &[char], start: usize, limit: usize) -> Option<usize> {
    let limit = limit.min(s.len());
    let mut depth = 0usize;
    let mut j = start + 1;
    while j < limit {
        match s[j] {
            '\r' | '\n' => return None,
            '\\' => {
                j += 2;
                continue;
            }
            '\'' => {
                let offset = s[j + 1..].iter().position(|&d| matches!(d, '\'' | '\n'))?;
                j += offset + 1;
                if s[j] != '\'' {
                    return None;
                }
            }
            '"' => {
                j += 1;
                while j < s.len() && s[j] != '"' {
                    match s[j] {
                        '\n' => return None,
                        '\\' => j += 2,
                        _ => j += 1,
                    }
                }
                if j >= s.len() {
                    return None;
                }
            }
            '$' if s.get(j + 1) == Some(&'(') => {
                let end = subexpression_close(s, j, limit, true)?;
                if s[j..end].contains(&'\n') {
                    return None;
                }
                j = end;
                continue;
            }
            '`' => {
                let offset = s[j + 1..].iter().position(|&d| matches!(d, '`' | '\n'))?;
                j += offset + 1;
                if s[j] != '`' {
                    return None;
                }
            }
            '{' => depth += 1,
            '}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(j + 1);
                }
            }
            _ => {}
        }
        j += 1;
    }
    None
}
