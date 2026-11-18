use super::*;

/// CMD規則の語を、引用外の`,`で割り直す（`if exist x,del y`の条件末尾に直結した実行名を分離する）。
///
/// cmd.exeは`if`の条件を`,`でも区切るが、字句解析は`,`を語の区切りにしない（`cmd ,/c`のような
/// switch解析や他の判定を変えないため）。`if`の検査に限ってこの関数で語を分ける。
/// 各片の引用・`==`の情報は、元の語での位置が片の範囲に入る場合だけ引き継ぐ。
/// 2つ目以降の引用は位置を保持していないため、その片は引用外として扱う（判定は拒否側に倒れる）。
pub(super) fn split_cmd_commas(words: &[Token]) -> Vec<Token> {
    let mut out = Vec::with_capacity(words.len());
    for word in words {
        if word.commas.is_empty() {
            out.push(word.clone());
            continue;
        }
        let mut start = 0;
        for end in word.commas.iter().copied().chain([word.text.len()]) {
            if end > start {
                let mut piece = Token::new(&word.text[start..end]);
                let inside = |position: usize| position >= start && position < end;
                piece.quote_start = word.quote_start.filter(|&q| inside(q)).map(|q| q - start);
                piece.quoted = piece.quote_start.is_some();
                // リダイレクトの印は語の先頭の片だけが引き継ぐ。
                piece.redirect = word.redirect && start == 0;
                if let Some(e) = word.equality.filter(|&e| inside(e)) {
                    piece.equality = Some(e - start);
                    piece.quoted_after_equality = word.quoted_after_equality;
                }
                out.push(piece);
            }
            start = end + 1;
        }
    }
    out
}
/// 共通指示の管理者起動`Start-Process -FilePath cmd.exe -ArgumentList '<引数>' ...`だけを許可するか判定する。
///
/// 起動先と引数文字列は、次をすべて満たす場合に限る許可リスト照合で受理する。
/// - `-FilePath`と`-ArgumentList`は両方とも名前付き・必須。位置引数・省略形・`-Name:value`形・重複・未知の引数は受理しない。
///   位置引数を許すと`(…)`・`{…}`が文境界として落ち、検査していない値が束縛されうる。
///   ArgumentListの省略も、`$PSDefaultParameterValues`で注入された値が使われうるため受理しない。
/// - 起動先は静的な`cmd`・`cmd.exe`・`C:\Windows\System32\cmd.exe`。引用なしの素の語か単一引用リテラルのみ。
/// - 引数は完全な単一引用リテラル1つで、`admin_cmd_arguments`の固定形に一致すること。
///   cmd.exeが実際に解釈する形（先頭・末尾の引用剥がし、`&`・`|`・改行による文の分割等）とのずれを避けるため、
///   cmd規則で再び字句解析せず、メタ文字を含められない形だけを許可する。
/// - 併用できるのは`-Verb`・`-WindowStyle`・`-WorkingDirectory`（静的な値）と
///   `-Wait`・`-PassThru`・`-NoNewWindow`（値なしswitch）だけ。
pub(super) fn admin_cmd_start_process(args: &[Token], cli: &str, config: &str) -> bool {
    // 値として静的に読める語（引用なしの素の語、または単一引用リテラル）。バッククォートで退避した語は
    // 字句解析後に元の綴りを失うため受理しない。
    fn static_value(t: &Token) -> Option<&str> {
        if t.escaped {
            return None;
        }
        if t.single_quoted_literal() {
            return Some(&t.text);
        }
        let plain = !t.quoted
            && !t.text.is_empty()
            && !t.text.starts_with('-')
            && !t
                .text
                .contains(['$', '@', '\'', '"', ',', '(', ')', '[', ']', '{', '}']);
        plain.then_some(t.text.as_str())
    }
    let mut file: Option<&str> = None;
    let mut arguments: Option<&Token> = None;
    let mut seen = std::collections::HashSet::new();
    let mut k = 0;
    while k < args.len() {
        let t = &args[k];
        // 引数名は引用なし・退避なしの`-名前`だけを受理する（それ以外は位置引数になるため拒否）。
        if t.quoted || t.escaped || !t.text.starts_with('-') {
            return false;
        }
        let parameter = t.text[1..].to_ascii_lowercase();
        let canonical = match parameter.as_str() {
            "filepath" => "filepath",
            "argumentlist" => "argumentlist",
            "verb" => "verb",
            "windowstyle" => "windowstyle",
            "workingdirectory" => "workingdirectory",
            "wait" | "passthru" | "nonewwindow" => {
                if !seen.insert(parameter) {
                    return false;
                }
                k += 1;
                continue;
            }
            _ => return false,
        };
        if !seen.insert(canonical.to_owned()) {
            return false;
        }
        let Some(value) = args.get(k + 1) else {
            return false;
        };
        match canonical {
            "filepath" => match static_value(value) {
                Some(v) => file = Some(v),
                None => return false,
            },
            "argumentlist" => {
                if value.escaped || !value.single_quoted_literal() {
                    return false;
                }
                arguments = Some(value);
            }
            _ => {
                if static_value(value).is_none() {
                    return false;
                }
            }
        }
        k += 2;
    }
    let (Some(file), Some(arguments)) = (file, arguments) else {
        return false;
    };
    matches!(
        file.to_ascii_lowercase().as_str(),
        "cmd" | "cmd.exe" | r"c:\windows\system32\cmd.exe"
    ) && admin_cmd_arguments(&arguments.text, cli, config)
}
/// 管理者起動のcmd.exeへ渡す引数文字列が、固定形
/// `/d /c ""<hookのCLI>" --config "<hookの設定>" <引数>[ > <出力jsonの絶対パス> 2>&1]"`
/// に一致するか。
/// - 実行体と設定は、このhookを起動した配置済みCLI（`--cli-executable`）と設定（`--config`）に限る
///   （ASCII大文字小文字のみ無視）。名前だけの照合では、同名の任意exeが昇格して動きうるため。
/// - `<引数>`・出力先・CLI/設定のパスは、cmd.exeの区切り・演算子・展開に使われる文字
///   （`& | < > ^ % ( ) ! " ; , '`と改行等）を含められないASCIIの許可文字だけにする。
/// - 出力リダイレクト先は拡張子`.json`に限る。cmd.exeは起動前に対象を管理者権限で切り詰めるため、
///   任意のファイルを指せると内容破壊になる。
fn admin_cmd_arguments(arguments: &str, cli: &str, config: &str) -> bool {
    fn safe_path(path: &str) -> bool {
        let bytes = path.as_bytes();
        bytes.len() >= 4
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && bytes[2] == b'\\'
            // `:`はドライブ指定の位置だけ（NTFSの代替データストリーム指定を含めない）。
            && bytes[2..]
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b' ' | b'\\' | b'-'))
    }
    // 先頭からASCII大文字小文字を無視して`expected`を剥がす。
    fn strip<'a>(text: &'a str, expected: &str) -> Option<&'a str> {
        let head = text.get(..expected.len())?;
        head.eq_ignore_ascii_case(expected)
            .then(|| &text[expected.len()..])
    }
    if !safe_path(cli) || !safe_path(config) {
        return false;
    }
    let Some(rest) = strip(arguments, "/d /c \"\"")
        .and_then(|r| strip(r, cli))
        .and_then(|r| strip(r, "\" --config \""))
        .and_then(|r| strip(r, config))
        .and_then(|r| strip(r, "\" "))
        .and_then(|r| r.strip_suffix('"'))
    else {
        return false;
    };
    // 末尾の任意の出力リダイレクト` > <X:\…\name.json> 2>&1`を分離する。
    let body = match rest.strip_suffix(" 2>&1").and_then(|r| r.rsplit_once(" > ")) {
        Some((body, output)) => {
            let lower = output.to_ascii_lowercase();
            if !safe_path(output) || output.contains(' ') || !lower.ends_with(".json") {
                return false;
            }
            body
        }
        None => rest,
    };
    !body.is_empty()
        && body
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'\\' | b' ' | b'=' | b'-'))
}
/// pwshの引数が`[-NoProfile|-NonInteractive|-NoLogo|-ExecutionPolicy <値>]... -File <静的な.ps1> [script引数...]`か。
/// 名前は完全一致だけを受理し、省略形・`-Command`・`-EncodedCommand`・`-File -`（標準入力）は含めない。
pub(super) fn static_powershell_file(args: &[Token]) -> bool {
    let plain = |t: &Token| {
        !t.escaped
            && !t.text.is_empty()
            && !t
                .text
                .contains(['$', '(', ')', '@', '{', '}', '`', '\'', '"', ',', ';'])
    };
    let mut k = 0;
    while k < args.len() {
        let word = &args[k];
        if word.quoted || word.escaped || !word.text.starts_with('-') {
            return false;
        }
        match word.text.to_ascii_lowercase().as_str() {
            "-noprofile" | "-noninteractive" | "-nologo" => k += 1,
            "-executionpolicy" => {
                if !args
                    .get(k + 1)
                    .is_some_and(|value| !value.quoted && plain(value))
                {
                    return false;
                }
                k += 2;
            }
            "-file" => {
                let Some(path) = args.get(k + 1) else {
                    return false;
                };
                // 単一引用の静的リテラルか、引用なしの素の語に限る（変数・式でスクリプトを差し替えない）。
                let literal = (path.single_quoted_literal() && !path.text.contains(['$', '`']))
                    || (!path.quoted && plain(path));
                return literal && path.text.to_ascii_lowercase().ends_with(".ps1");
            }
            _ => return false,
        }
    }
    false
}
/// `$(`の直後から`)`までが、`$名前`（`$env:名前`可）に`.プロパティ名`・`[数字]`だけが続く形か。
/// メソッド呼出し（`(`）・演算子・引用・入れ子の`$`は含めない。
pub(super) fn powershell_property_subexpression(rest: &[char]) -> bool {
    let identifier = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let mut k = 0;
    if rest.first() != Some(&'$') {
        return false;
    }
    k += 1;
    let start = k;
    while k < rest.len() && identifier(rest[k]) {
        k += 1;
    }
    if k == start {
        return false;
    }
    // スコープ・ドライブ修飾（`$env:PATH`・`$script:x`）は1回だけ。
    if rest.get(k) == Some(&':') {
        k += 1;
        let start = k;
        while k < rest.len() && identifier(rest[k]) {
            k += 1;
        }
        if k == start {
            return false;
        }
    }
    loop {
        match rest.get(k) {
            Some(')') => return true,
            Some('.') => {
                k += 1;
                let start = k;
                while k < rest.len() && identifier(rest[k]) {
                    k += 1;
                }
                if k == start {
                    return false;
                }
            }
            Some('[') => {
                k += 1;
                let start = k;
                while k < rest.len() && rest[k].is_ascii_digit() {
                    k += 1;
                }
                if k == start || rest.get(k) != Some(&']') {
                    return false;
                }
                k += 1;
            }
            _ => return false,
        }
    }
}
/// POSIXの`[`・`[[`（test組込み）か。引用なしの語がちょうどこの綴りの場合だけ。
/// 字句解析は`[`をglob文字として動的扱いにするが、`[`単独は一致する名前がなく展開されない。
pub(super) fn posix_test_builtin(word: &Token) -> bool {
    !word.quoted && matches!(word.text.as_str(), "[" | "[[")
}
/// 語列がリダイレクト（`2>`・`>/dev/null`・`< file`等）とその対象だけでできているか。
/// 演算子だけの語（`<`・`2>`）の次の語は対象として読み飛ばす（`&`で割れた`2>&1`は演算子で終わる）。
pub(super) fn posix_redirections_only(words: &[Token]) -> Result<bool> {
    let redirection = compiled(&REDIRECTION)?;
    let mut index = 0;
    while index < words.len() {
        let text = words[index].text.as_str();
        if words[index].quoted || !redirection.is_match(text) {
            return Ok(false);
        }
        let operator_only = text
            .trim_start_matches(|c: char| c.is_ascii_digit())
            .chars()
            .all(|c| matches!(c, '<' | '>' | '|'));
        index += if operator_only { 2 } else { 1 };
    }
    Ok(true)
}
