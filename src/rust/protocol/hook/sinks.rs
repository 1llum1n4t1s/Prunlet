use super::*;

/// 書き出し先のPOSIXパスが、通常のファイルと確定できない先（`/dev/`・`/proc/`の配下、`..`区間を含む先）か。
/// 連続する`/`をまとめ、`.`区間を除いた字句上の正規形で判定する（`//dev/stdout`・`/./dev/stdout`を見逃さない）。
/// `..`はシンボリックリンクの解決順で行き先が変わりうるため、正規化せずに拒否側へ倒す。
fn posix_device_path(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let mut parts = Vec::new();
    for part in lower.split('/') {
        match part {
            "" | "." => {}
            ".." => return true,
            other => parts.push(other),
        }
    }
    lower.starts_with('/') && matches!(parts.first(), Some(&("dev" | "proc")))
}
/// 書き出し先のPOSIXパスが、字句上の正規形で`/dev/null`か。
fn posix_null_path(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let parts: Vec<&str> = lower
        .split('/')
        .filter(|p| !matches!(*p, "" | "."))
        .collect();
    lower.starts_with('/') && parts == ["dev", "null"]
}
/// ヒアドキュメントを受け取る文が、本文をshellへ渡さない形（ファイルへの`cat`・インタプリタ）か。
pub(super) fn heredoc_consumer_is_data_sink(words: &[Token]) -> Result<bool> {
    let assignment = compiled(&ASSIGNMENT)?;
    let mut command: Vec<&Token> = Vec::new();
    let mut stdout_to_file = false;
    let mut stdout_to_null = false;
    let mut k = 0;
    while k < words.len() {
        let word = &words[k];
        let text = word.text.as_str();
        // 文の終わり（CRLFの`\r`等）。同じ行で後ろに続く文は呼出し側の`boundary_after`で拒否済み。
        if word.boundary {
            break;
        }
        // `<<`・`<<-`（終端語が直結していれば同じ語、離れていれば次の語が終端語）。
        // リダイレクトは字句解析が演算子の印を付けた語だけ（退避・引用した`\>x`・`">"x`は通常の引数）。
        if word.redirect && text.starts_with("<<") {
            let rest = text[2..].strip_prefix('-').unwrap_or(&text[2..]);
            k += if rest.is_empty() && !word.quoted {
                2
            } else {
                1
            };
            continue;
        }
        if !word.quoted && text.starts_with('<') {
            return Ok(false);
        }
        // 出力リダイレクト（`>`・`>>`・`1>`・`2>`。対象は直結か次の語）。
        let digits = text.len() - text.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if word.redirect && text[digits..].starts_with('>') {
            // `>|`（noclobberを無視する出力）の`|`も演算子の一部で、書き出し先ではない。
            let operator = text[digits..].trim_start_matches('>');
            let operator = operator.strip_prefix('|').unwrap_or(operator);
            let (target, step) = if operator.is_empty() {
                match words.get(k + 1) {
                    Some(next) => (next, 2),
                    None => return Ok(false),
                }
            } else {
                (word, 1)
            };
            let target_text = if operator.is_empty() {
                target.text.as_str()
            } else {
                operator
            };
            // ブレース展開（`> f{a,b}`）も出力先を静的に確定できない。
            if target.dynamic || target.brace || target.boundary || target_text.is_empty() {
                return Ok(false);
            }
            // `>&2`・`>&-`などのfd複製は書き出し先として扱わない。
            if target_text.starts_with('&') {
                return Ok(false);
            }
            // 標準出力はfdが空か`1`のとき。それ以外のfd（`3>`等）は別の書き出し先で、`tee`の標準出力を決めない。
            if !matches!(&text[..digits], "" | "1" | "2") {
                return Ok(false);
            }
            if &text[..digits] != "2" {
                if posix_null_path(target_text) {
                    // 出力の破棄だけは、`tee`が本文を標準出力へ流さない形として認める（`cat`は従来どおり拒否）。
                    stdout_to_null = true;
                    k += step;
                    continue;
                }
                if posix_device_path(target_text) {
                    return Ok(false);
                }
                stdout_to_file = true;
            }
            k += step;
            continue;
        }
        command.push(word);
        k += 1;
    }
    // 先頭の静的な代入（`PYTHONUTF8=1 python - <<'EOF'`）は実行名ではない。
    let start = command
        .iter()
        .take_while(|w| !w.quoted && !w.dynamic && assignment.is_match(&w.text))
        .count();
    let command = &command[start..];
    let Some(first) = command.first() else {
        return Ok(false);
    };
    if first.quoted || first.dynamic || first.brace {
        return Ok(false);
    }
    let static_option = |w: &&Token| !w.quoted && !w.dynamic && !w.brace && w.text.starts_with('-');
    Ok(match leaf(&first.text).as_str() {
        "cat" => command.len() == 1 && stdout_to_file,
        // `tee`は本文を標準出力へも流すため、標準出力がファイルか`/dev/null`へ向く場合だけdataとして扱う。
        "tee" => (stdout_to_file || stdout_to_null) && tee_writes_only_files(&command[1..]),
        "python" | "python3" | "py" | "node" => command[1..].iter().all(static_option),
        _ => false,
    })
}
/// `tee`の引数が、静的なoption（`-a`・`-i`・`-p`・`--append`・`--ignore-interrupts`・`--`）と
/// 1つ以上の静的な書き出し先（`/dev/`・`/proc/`以外）だけか。標準出力の向き先は呼出し側が確認する。
fn tee_writes_only_files(args: &[&Token]) -> bool {
    let mut options_done = false;
    let mut paths = 0;
    for word in args {
        let text = word.text.as_str();
        if !options_done && text.starts_with('-') {
            // 引用・展開を含む語は静的なoptionと確定できない（`tee "-a"`）。
            if word.quoted || word.dynamic || word.brace {
                return false;
            }
            match text {
                "--" => options_done = true,
                "-a" | "-i" | "-p" | "--append" | "--ignore-interrupts" => {}
                _ => return false,
            }
            continue;
        }
        if word.boundary || word.dynamic || word.brace || text.is_empty() || posix_device_path(text)
        {
            return false;
        }
        paths += 1;
    }
    paths > 0
}
/// 文頭に並ぶリダイレクト（演算子と対象）が占める語数。`>f`・`2>&1`・`>-`は1語、`>`・`<`・`2>`・`<<`・`<<-`は対象の次の語まで2語。
/// 字句解析が引用外・非退避の演算子で始まる語に付けた印（`Token::redirect`）の語だけを数える。
/// 退避・引用した`\>`・`">"`・`2">"x`と、PowerShell規則のブロックコメント開始`<#`はリダイレクトではない。
pub(super) fn leading_redirect_words(words: &[Token], powershell: bool) -> usize {
    let mut k = 0;
    while let Some(word) = words.get(k) {
        let text = word.text.as_str();
        let digits = text.len() - text.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if !word.redirect
            || !text[digits..].starts_with(['<', '>'])
            || (powershell && text.starts_with("<#"))
        {
            break;
        }
        let operator = &text[digits..];
        // 対象語を次の語に取るのは、`<`・`>`の並びの後ろが空か`&`・`|`の1文字だけの演算子（`>`・`>>`・`<>`・`>&`・`>|`・`<<<`）と、
        // ヒアドキュメントの`<<-`だけ。`-`を演算子の一部として読むのは`<<-`と`>&-`・`<&-`（fdを閉じる完結した1語）に限り、
        // `>-`・`<-`は`-`という名前のファイルを対象に含めた1語（bashも同じ）。
        let rest = operator.trim_start_matches(['<', '>']);
        k += if matches!(rest, "" | "&" | "|") || operator == "<<-" {
            2
        } else {
            1
        };
    }
    k.min(words.len())
}
/// 語列から、位置を問わずリダイレクト（演算子と対象。数え方は`leading_redirect_words`と同じ）を除いた複製を返す。
/// 前置コマンド・wrapperのoption解析と本文の再構成で、リダイレクトの語をoptionの値や本文と取り違えないために使う
/// （リダイレクトは外側のshellが処理し、前置コマンド・wrapperへ引数として渡らない）。
pub(super) fn without_redirect_words(words: &[Token], powershell: bool) -> Vec<Token> {
    let mut out = Vec::with_capacity(words.len());
    let mut k = 0;
    while k < words.len() {
        let redirects = leading_redirect_words(&words[k..], powershell);
        if redirects > 0 {
            k += redirects;
            continue;
        }
        out.push(words[k].clone());
        k += 1;
    }
    out
}
/// 語がリダイレクト演算子の途中か（引用・退避・展開がなく、数字だけ、または先頭の数字に`<`・`>`だけが続く）。
/// POSIX・CMD規則で`<`・`>`の手前で語を切るかの判定に使う（`2>`・`>>`・`<<`・`2>>`は1つの演算子のまま）。
pub(super) fn redirect_operator_prefix(t: &Token) -> bool {
    t.quote_start.is_none()
        && !t.escaped
        && !t.dynamic
        && t.text
            .trim_start_matches(|d: char| d.is_ascii_digit())
            .chars()
            .all(|d| matches!(d, '<' | '>'))
}
