use super::bounded_input::read_to_end;
use anyhow::{Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use regex::Regex;
use serde_json::{Value, json};
use std::{io, path::Path, sync::LazyLock};

static REDIRECTION: LazyLock<std::result::Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\A[0-9]*[<>]"));
static ASSIGNMENT: LazyLock<std::result::Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\A[A-Za-z_][A-Za-z0-9_]*="));

fn compiled(
    pattern: &'static LazyLock<std::result::Result<Regex, regex::Error>>,
) -> Result<&'static Regex> {
    pattern
        .as_ref()
        .map_err(|error| anyhow::anyhow!(error.to_string()))
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Cmd,
    PowerShell,
    Posix,
}
#[derive(Clone, Debug)]
struct Token {
    text: String,
    boundary: bool,
    quoted: bool,
    quote_start: Option<usize>,
    backticks: usize,
    subexpression: bool,
    equality: Option<usize>,
    quoted_after_equality: bool,
    dynamic: bool,
    /// CMD規則で、引用外かつ`^`で退避されていない`,`の位置（`text`内のbyte offset）。
    /// cmd.exeは`,`を空白相当の区切りとして読むため、`if`の条件を語に割り直すのに使う。
    commas: Vec<usize>,
    /// 語に含まれる引用の区間数（`'a'`は1、`'a','b'`や`'a'"b"`は2）。
    quote_segments: usize,
    /// 単一引用以外（二重引用・ヒアストリング）を含むか。PowerShellの二重引用は変数展開しうる。
    non_single_quote: bool,
    /// 引用外（退避を含む）で語へ加えた文字数。完全な単一引用リテラルかの判定に使う。
    bare_chars: usize,
    /// 引用外で退避文字（PowerShellの`` ` ``）を含むか。字句解析後は元の綴りを失うため、静的値として扱わない。
    escaped: bool,
}
impl Token {
    fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            boundary: false,
            quoted: false,
            quote_start: None,
            backticks: 0,
            subexpression: false,
            equality: None,
            quoted_after_equality: false,
            dynamic: false,
            commas: Vec::new(),
            quote_segments: 0,
            non_single_quote: false,
            bare_chars: 0,
            escaped: false,
        }
    }
    /// 語全体が1つの単一引用だけでできたPowerShellの静的リテラルか（`'...'`、`''`は`'`）。
    /// 二重引用・ヒアストリング・連結（`'a'$x`・`'a','b'`）は値が展開や配列になりうるため含めない。
    fn single_quoted_literal(&self) -> bool {
        self.quoted
            && self.quote_start == Some(0)
            && self.quote_segments == 1
            && !self.non_single_quote
            && self.bare_chars == 0
    }
}

/// CMD規則の語を、引用外の`,`で割り直す（`if exist x,del y`の条件末尾に直結した実行名を分離する）。
///
/// cmd.exeは`if`の条件を`,`でも区切るが、字句解析は`,`を語の区切りにしない（`cmd ,/c`のような
/// switch解析や他の判定を変えないため）。`if`の検査に限ってこの関数で語を分ける。
/// 各片の引用・`==`の情報は、元の語での位置が片の範囲に入る場合だけ引き継ぐ。
/// 2つ目以降の引用は位置を保持していないため、その片は引用外として扱う（判定は拒否側に倒れる）。
fn split_cmd_commas(words: &[Token]) -> Vec<Token> {
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
fn admin_cmd_start_process(args: &[Token], cli: &str, config: &str) -> bool {
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
            && !t.text.contains(['$', '@', '\'', '"', ',', '(', ')', '[', ']', '{', '}']);
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
fn static_powershell_file(args: &[Token]) -> bool {
    let plain = |t: &Token| {
        !t.escaped
            && !t.text.is_empty()
            && !t.text.contains(['$', '(', ')', '@', '{', '}', '`', '\'', '"', ',', ';'])
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
                if !args.get(k + 1).is_some_and(|value| !value.quoted && plain(value)) {
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
fn powershell_property_subexpression(rest: &[char]) -> bool {
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
fn posix_test_builtin(word: &Token) -> bool {
    !word.quoted && matches!(word.text.as_str(), "[" | "[[")
}
/// 語列がリダイレクト（`2>`・`>/dev/null`・`< file`等）とその対象だけでできているか。
/// 演算子だけの語（`<`・`2>`）の次の語は対象として読み飛ばす（`&`で割れた`2>&1`は演算子で終わる）。
fn posix_redirections_only(words: &[Token]) -> Result<bool> {
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
fn leaf(value: &str) -> String {
    raw_leaf(value).to_ascii_lowercase()
}
fn raw_leaf(value: &str) -> &str {
    let name = value.rsplit(['/', '\\']).next().unwrap_or(value);
    if name.to_ascii_lowercase().ends_with(".exe") {
        &name[..name.len() - 4]
    } else {
        name
    }
}
fn shell(name: &str) -> Option<Mode> {
    match name {
        "pwsh" | "powershell" => Some(Mode::PowerShell),
        "cmd" => Some(Mode::Cmd),
        "sh" | "bash" | "zsh" if !cfg!(windows) => Some(Mode::Posix),
        _ => None,
    }
}
fn wrapper(name: &str) -> bool {
    matches!(name, "cmd" | "bash" | "sh" | "zsh" | "pwsh" | "powershell")
}
fn option(value: &str) -> String {
    let name = value.trim_start_matches(['-', '/', '\u{2013}', '\u{2014}', '\u{2015}']);
    if name.len() == value.len() {
        String::new()
    } else {
        name.to_ascii_lowercase()
    }
}
fn encoded(v: &str) -> bool {
    let n = option(v);
    !n.is_empty() && (n == "ec" || "encodedcommand".starts_with(&n))
}
fn file_option(v: &str) -> bool {
    let n = option(v);
    !n.is_empty() && "file".starts_with(&n)
}
fn command_option(v: &str) -> bool {
    let n = option(v);
    !n.is_empty() && ("command".starts_with(&n) || matches!(n.as_str(), "cwa" | "commandwithargs"))
}
/// cmd.exe の起動switchを解析した結果。
#[derive(Debug, PartialEq, Eq)]
enum CmdSwitches {
    /// 本文switch（/C・/K・/R）を見つけた。`token`はそのswitchを含む語の位置、
    /// `attached`はswitch文字の直後に直結した本文（例: `/cdel x`の`del x`）。
    Body { token: usize, attached: String },
    /// 本文switchがない（対話起動や`/?`）。実行される本文が無いため検査対象もない。
    NoBody,
    /// 解釈できないswitchや、本文switchより前の未知の引数。安全側に拒否する。
    Unknown(String),
}

/// cmd.exe のswitch列を左から解析し、本文の開始位置を返す。
///
/// cmd.exe は `/` の後の1文字でswitchを判定し、`/d/c`のような連結や`/cdel`のような直結本文も受け付ける。
/// MSYS/Git Bash ではパス変換を避けるため`//c`のように`/`を重ねるので、先頭の`/`の連続は1つと同等に扱う。
/// 大文字小文字は区別しない。既知の非本文switchだけを読み飛ばし、未知のswitchは途中に本文switchが
/// 隠れている可能性があるため`Unknown`として呼出し元で拒否させる。PowerShell の`-c`系とは別関数で扱う。
fn cmd_switches(words: &[Token], start: usize) -> CmdSwitches {
    // 本文switchより前に現れた`/`で始まらない語。後ろに本文switchが続いた時点で拒否理由にする。
    let mut stray: Option<&str> = None;
    for (index, word) in words.iter().enumerate().skip(start) {
        let text = word.text.as_str();
        if !text.starts_with('/') {
            // 旧実装はcmdでも`-c`・`-lc`・`-Command`を本文switchとして検査していたため、
            // 検知範囲を狭めないよう互換として本文扱いを維持する。
            if matches!(text, "-c" | "-lc" | "-Command" | "-command") {
                return match stray {
                    Some(s) => CmdSwitches::Unknown(s.to_owned()),
                    None => CmdSwitches::Body {
                        token: index,
                        attached: String::new(),
                    },
                };
            }
            // cmd.exe はコマンドライン全体から`/C`・`/K`を探すため、`x/c del …`や`,/c del …`のように
            // 語の途中にある`/`以降も本文switchになり得る。途中の`/`を含む語は解釈を推測せず拒否する。
            if text.contains('/') {
                return CmdSwitches::Unknown(text.to_owned());
            }
            stray.get_or_insert(text);
            continue;
        }
        let mut rest = text;
        let mut first = true;
        loop {
            rest = rest.trim_start_matches('/');
            if rest.is_empty() {
                // `/`だけの語は意味を確定できない。連結の末尾の`/`は無害として扱う。
                if first {
                    return CmdSwitches::Unknown(text.to_owned());
                }
                break;
            }
            first = false;
            let mut chars = rest.chars();
            let letter = chars.next().map(|c| c.to_ascii_lowercase());
            rest = chars.as_str();
            match letter {
                Some('c' | 'k' | 'r') => {
                    return match stray {
                        Some(s) => CmdSwitches::Unknown(s.to_owned()),
                        None => CmdSwitches::Body {
                            token: index,
                            attached: rest.to_owned(),
                        },
                    };
                }
                Some('?') => return CmdSwitches::NoBody,
                Some('d' | 'q' | 's' | 'a' | 'u' | 'x' | 'y') => {}
                Some(kind @ ('e' | 'v' | 'f' | 't')) => {
                    if let Some(value) = rest.strip_prefix(':') {
                        let end = value.find('/').unwrap_or(value.len());
                        let (argument, tail) = value.split_at(end);
                        let valid = if kind == 't' {
                            // 色指定は1〜2桁の16進数。
                            (1..=2).contains(&argument.len())
                                && argument.chars().all(|c| c.is_ascii_hexdigit())
                        } else {
                            argument.eq_ignore_ascii_case("on")
                                || argument.eq_ignore_ascii_case("off")
                        };
                        if !valid {
                            return CmdSwitches::Unknown(text.to_owned());
                        }
                        rest = tail;
                    } else if kind == 't' {
                        return CmdSwitches::Unknown(text.to_owned());
                    }
                }
                _ => return CmdSwitches::Unknown(text.to_owned()),
            }
            // 非本文switchの直後は語の終わりか次の`/`だけを許す（`/dq`などは解釈を推測しない）。
            if !rest.is_empty() && !rest.starts_with('/') {
                return CmdSwitches::Unknown(text.to_owned());
            }
        }
    }
    CmdSwitches::NoBody
}

/// CMD規則での実行名の先頭から落とす文字。
///
/// cmd.exe は `,` `;` `=` を空白と同じ区切りとして読み飛ばすため、`,del x`や`=del x`も`del x`として
/// 実行される。`@`（echo抑制）と同じく、実行名の判定前に落とす。実行名の位置だけに適用し、
/// `set X=1`や`if a==b`のような引数側の`=`には触れない。
const CMD_NAME_PREFIX: [char; 4] = ['@', ',', ';', '='];

/// CMD規則で、実行名が`cmd`/`cmd.exe`のまま直後に区切り文字や`/`が直結した語を分解する。
///
/// cmd.exe は実行名を最初の `/` `,` `;` `=` で打ち切るため、`cmd/c del x`・`cmd.exe/c del x`・
/// `cmd,/c del x`・`cmd=/c del x` はいずれも`cmd`＋`/c del x`として実行される。
/// 一方、`leaf()`は`/`で語を切って`c`と判定してしまい、wrapper本文が素通りしていた。
/// `C:/Windows/System32/cmd.exe/c`のように`/`区切りの経路が前置される形も受けるため、
/// パス区切り（`/` `\`）で更新する語頭から区切り文字までを区間として照合する（1回の走査で線形）。
/// 区間が`cmd`・`cmd.exe`なら、その区切り文字以降（区切りを含む）を返す。該当なしは`None`。
fn cmd_glued_tail(text: &str, explicit: bool) -> Option<&str> {
    let mut segment_start = 0;
    for (position, c) in text.char_indices() {
        if matches!(c, '/' | ',' | ';' | '=') {
            let segment = &text[segment_start..position];
            // 区間が`cmd`の場合だけ`=`の打切り条件を確かめる。先に区間を比べることで、
            // `x=,=,=,…`のような語でも`=`ごとの前方走査が起きず、全体が線形に保たれる。
            if (segment.eq_ignore_ascii_case("cmd") || segment.eq_ignore_ascii_case("cmd.exe"))
                && cmd_cut_at(text, position, explicit)
            {
                return Some(&text[position..]);
            }
        }
        if matches!(c, '/' | '\\') {
            segment_start = position + c.len_utf8();
        }
    }
    None
}

/// 実行名の判定結果。`glued`はCMD規則で`cmd`の直後に直結していた残り（区切り文字を含む）。
struct ExecName<'a> {
    name: String,
    /// 拒否理由に表示する実行名（先頭記号を落とし、`.exe`を除いた元の大小文字の名前）。
    shown: &'a str,
    glued: Option<&'a str>,
}

/// 実行名の位置で削除命令とみなす名前（POSIX以外の規則）。`Inspector::command`の判定と同じ集合。
fn non_posix_delete_name(name: &str) -> bool {
    matches!(
        name,
        "remove-item"
            | "ri"
            | "rm"
            | "rmdir"
            | "rd"
            | "del"
            | "erase"
            | "remove-itemproperty"
            | "rp"
    )
}

/// CMD規則で、最初の`/` `,` `;` `=`より前の部分（`head`）が「単純名」かどうか。
///
/// cmd.exe は`\`や`:`を含まず`.`で始まらない単純名の実行名を、最初の`/` `,` `;` `=`で打ち切る
/// （`rd/s/q x`は`rd /s/q x`、`del,x`は`del x`）。`C:/tools/del/x`（headが`C:`）・`./del`（headが`.`）・
/// `/c/bin/del`（headが空）のような経路形式では`/`が経路区切りとして読まれ得るため、
/// 呼出し側は従来どおり`leaf()`（最後の区切り以降）で判定する。
fn cmd_simple_name(head: &str) -> bool {
    !head.is_empty() && !head.contains(['\\', ':']) && !head.starts_with('.')
}

/// CMD規則で、`text`の`position`にある区切り文字で実行名を打ち切るか。
///
/// `/` `,` `;`は常に打ち切る。`=`はshellがcmdと明示された場合（`explicit`）だけ無条件に打ち切る。
/// shell不明でCMD規則を候補として当てる場合、`rm=1`・`ri=0`・`rp=$(...)`のようなPOSIX代入を
/// 削除命令と誤認しないよう、`=`（続く`, ; =`を含む）の直後が`/`のとき（`rd=/s x`）に限って打ち切る。
fn cmd_cut_at(text: &str, position: usize, explicit: bool) -> bool {
    if explicit || !text[position..].starts_with('=') {
        return true;
    }
    text[position..]
        .trim_start_matches([',', ';', '='])
        .starts_with('/')
}

/// CMD規則で実行名の位置に置かれ、直結した残りを次の実行名として扱う語。
/// `call,del x`・`call=del x`・`for … do,del %i`・`… else,del x`はcmd.exeでいずれも`del`を実行する。
fn cmd_prefix_word(name: &str) -> bool {
    matches!(name, "call" | "do" | "else")
}

/// 1語の中で区切りにより直結した制御語（`do,do,call,del`等）を順に剥がす回数の上限。
/// 実用の命令では数個で足りる。超えた入力は検査せず拒否し、計算量を入力長に対して線形に保つ。
const CMD_GLUED_PREFIX_LIMIT: usize = 32;

/// 語の実行名を求める。CMD規則だけ、先頭の`@ , ; =`を落とし、`cmd`直結の残りを分離する。
/// 単純名が最初の`/ , ; =`で切れて削除命令・`reg`・`call`・`do`・`else`になる場合は、
/// その名前と残り（区切りを含む）を返す。
/// POSIX・PowerShell規則では従来どおり先頭の`@`だけを落として`leaf()`で判定する。
/// shellがcmdと明示された前提で判定する。shell不明の候補判定は`exec_name_in`で`explicit=false`を渡す。
#[cfg(test)]
fn exec_name(text: &str, mode: Option<Mode>) -> ExecName<'_> {
    exec_name_in(text, mode, true)
}

/// `exec_name`の本体。`explicit`はCMD規則がshellの明示によるものか（`cmd_cut_at`参照）。
fn exec_name_in(text: &str, mode: Option<Mode>, explicit: bool) -> ExecName<'_> {
    if mode == Some(Mode::Cmd) {
        let trimmed = text.trim_start_matches(CMD_NAME_PREFIX);
        if let Some(glued) = cmd_glued_tail(trimmed, explicit) {
            return ExecName {
                name: "cmd".into(),
                shown: raw_leaf(&trimmed[..trimmed.len() - glued.len()]),
                glued: Some(glued),
            };
        }
        // 単純名かどうかは区切りより前の部分で判断する。`del,"C:\x"`の`C:\x`は引数側なので経路扱いしない。
        // 最初の区切りで判断する。打ち切らない`=`（shell不明時のPOSIX代入）に当たった場合は切らない。
        if let Some(cut) = trimmed.find(['/', ',', ';', '='])
            && cmd_cut_at(trimmed, cut, explicit)
            && cmd_simple_name(&trimmed[..cut])
        {
            let head = &trimmed[..cut];
            let name = leaf(head);
            // 削除命令・`reg`・後続を実行名とする語だけを切った名前で判定する。その他の名前は
            // 従来の`leaf()`判定を保ち、`foo/rm x`のような既存の拒否を緩めない。
            if non_posix_delete_name(&name) || name == "reg" || cmd_prefix_word(&name) {
                return ExecName {
                    name,
                    shown: raw_leaf(head),
                    glued: Some(&trimmed[cut..]),
                };
            }
        }
        return ExecName {
            name: leaf(trimmed),
            shown: raw_leaf(trimmed),
            glued: None,
        };
    }
    let trimmed = text.trim_start_matches('@');
    ExecName {
        name: leaf(trimmed),
        shown: raw_leaf(trimmed),
        glued: None,
    }
}

#[derive(Default)]
struct Inspector {
    mode: Option<Mode>,
    /// CMD規則で、いま検査している文の直後が`;`だったか。cmd.exeでは`;`は空白相当の区切りで、
    /// `cmd /d;/c del x`のように`cmd`の引数列を途中で割れない。字句解析は`;`を文境界にするため、
    /// 本文switchを持たない`cmd`の直後に`;`が続く形をwrapper側で拒否するのに使う。
    cmd_semicolon: bool,
    /// いまのshell規則が明示されたものか（hookのshell指定・`cmd /c`等の本文）。
    /// shell不明で候補の規則を順に当てている間はfalse。CMD規則の`=`での実行名打切りに使う。
    explicit: bool,
    detection: Option<String>,
    posix_script: bool,
    /// 入力全体が単独の静的EncodedCommandで、復号本文をPowerShellとして確定検査したか。
    /// このときshell不明時の「候補の解釈」注記とEncodedCommand案内は事実に合わないため付けない。
    standalone_encoded: bool,
    /// このhookを起動した配置済みCLIと設定の絶対パス。管理者起動の許可リスト照合だけに使う。
    /// 空のとき（単体の検査器テスト等）は管理者起動を一切許可しない。
    admin_cli: String,
    admin_config: String,
    /// 最初の検知が削除命令（ファイル・レジストリ）か。検査不能による拒否と区別し、
    /// 拒否理由に付ける案内の長さを変えるのに使う。
    deletion: bool,
}
impl Inspector {
    fn detected(&mut self, reason: &str, token: &str) -> bool {
        if self.detection.is_none() {
            self.deletion = matches!(reason, "deletion command" | "registry deletion command");
            let label = match self.mode {
                Some(Mode::Cmd) => "CMD",
                Some(Mode::PowerShell) => "PowerShell",
                Some(Mode::Posix) => "POSIX",
                None => "undetermined",
            };
            self.detection = Some(format!(
                "Prunlet rejected this command: {reason}; detected token {}; interpretation={label}.",
                json!(token)
            ));
        }
        true
    }
    fn contains(
        &mut self,
        script: &str,
        depth: usize,
        mode: Option<Mode>,
        strict: bool,
    ) -> Result<bool> {
        // 深さ上限を超えた本文は検査していないため、shell規則を問わず安全側に拒否する。
        if depth > 4 {
            return Ok(self.detected("inspection depth limit exceeded", &depth.to_string()));
        }
        if depth == 0 {
            let re = Regex::new(
                r"(?i)\A[ \t]*(?:pwsh|powershell)(?:\.exe)?[ \t]+-NoProfile[ \t]+-EncodedCommand[ \t]+([A-Za-z0-9+/]+={0,2})[ \t]*\z",
            )?;
            if let Some(m) = re.captures(script) {
                let data = &m[1];
                if data.starts_with('/') {
                    bail!("EncodedCommand cannot begin with a slash.");
                }
                let bytes = STANDARD.decode(data)?;
                if bytes.is_empty() || bytes.len() % 2 != 0 || STANDARD.encode(&bytes) != data {
                    bail!("EncodedCommand requires canonical UTF-16LE Base64.");
                }
                let units: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .collect();
                let decoded = String::from_utf16(&units)?;
                if decoded.contains('\0') {
                    bail!("EncodedCommand contains a NUL character.");
                }
                self.standalone_encoded = true;
                return self.contains(&decoded, depth + 1, Some(Mode::PowerShell), true);
            }
        }
        let modes = if let Some(m) = mode {
            vec![m]
        } else if cfg!(windows) {
            vec![Mode::Cmd, Mode::PowerShell, Mode::Posix]
        } else {
            vec![Mode::Posix]
        };
        for m in modes {
            let previous = self.mode;
            let previous_semicolon = self.cmd_semicolon;
            let previous_explicit = self.explicit;
            self.mode = Some(m);
            self.explicit = mode.is_some();
            let result = (|| {
                let tokens = tokens(script, m, strict)?;
                let mut words = Vec::new();
                let mut control = self.posix_script;
                for token in tokens {
                    if token.boundary {
                        // CMD規則の字句解析だけが`;`の境界に";"を載せる。直前の文の末尾が`;`かを伝える。
                        self.cmd_semicolon = token.text == ";";
                        if self.statement(&words, depth, strict, &mut control)? {
                            return Ok(true);
                        }
                        words.clear();
                    } else {
                        words.push(token);
                    }
                }
                // 最後の文の後ろは、入れ子の本文ならそれを含む外側の文の終端を引き継ぐ。
                // cmd.exeは`cmd /c cmd;/c del x`の本文を`;`以降まで含めて渡すため、本文末尾の`cmd`も
                // `;`に続く引数を受ける。最上位（previous_semicolon=false）では終端なしになる。
                self.cmd_semicolon = previous_semicolon;
                self.statement(&words, depth, strict, &mut control)
            })();
            self.mode = previous;
            self.cmd_semicolon = previous_semicolon;
            self.explicit = previous_explicit;
            if result? {
                return Ok(true);
            }
        }
        Ok(false)
    }
    fn statement(
        &mut self,
        words: &[Token],
        depth: usize,
        strict: bool,
        control: &mut bool,
    ) -> Result<bool> {
        if self.mode == Some(Mode::Posix) {
            if let Some(first) = words.first() {
                *control |= matches!(
                    first.text.as_str(),
                    "if" | "elif"
                        | "then"
                        | "else"
                        | "while"
                        | "until"
                        | "for"
                        | "select"
                        | "do"
                        | "case"
                        | "coproc"
                );
                // 代入（`b=$(basename $f)`）の右辺は実行名ではないため、制御構文の中でも
                // posix_prefixで代入を剥がした後の実行名だけを動的かどうか判定する。
                // `[`・`[[`はtest組込みで、`[`単独はglobとして展開されない。
                let static_head = compiled(&ASSIGNMENT)?.is_match(&first.text)
                    || posix_test_builtin(first);
                if *control
                    && ((first.dynamic && !static_head)
                        || compiled(&REDIRECTION)?.is_match(&first.text))
                {
                    return Ok(self.detected(
                        "dynamic or unsupported POSIX control body cannot be inspected",
                        &first.text,
                    ));
                }
            }
        }
        self.command(words, depth, strict)
    }
    fn command(&mut self, w: &[Token], depth: usize, strict: bool) -> Result<bool> {
        if w.is_empty() {
            return Ok(false);
        }
        // contains()と同じく、深さ上限はshell規則を問わずfail-closedにする。
        if depth > 4 {
            return Ok(self.detected("inspection depth limit exceeded", &depth.to_string()));
        }
        if self.noncanonical(w, depth)? {
            return Ok(true);
        }
        if self.mode == Some(Mode::Posix) {
            if let Some(result) = self.posix_prefix(w, depth, strict)? {
                return Ok(result);
            }
            if let Some(result) = self.posix_shell(w, depth, strict)? {
                return Ok(result);
            }
        }
        let mut i = 0;
        // CMD規則では先頭の`, ; =`も落とし、`cmd`直結の`/c`等を分離する（exec_name参照）。
        let mut current = exec_name_in(&w[0].text, self.mode, self.explicit);
        // CMDの`for ... do <cmd>`・`... else <cmd>`は括弧なしでも後続をコマンドとして実行する。
        // 字句解析で括弧は文の境界になるため、先頭に残った`do`/`else`を剥がして残りを検査する。
        // `do,del %i`・`else=del x`・`call,del x`のように区切りで直結した残りも、cmd.exeは
        // 次の実行名として実行するため、同じ語の位置のまま残りを評価し直す（残りは`w`を借用するだけで複製しない）。
        // 再帰でなくループで剥がし、大量に並んだ入力でも深さや計算量を増やさない。
        // POSIXの制御語はposix_prefixが別に扱うため、ここではCMD規則に限定する。
        // 直結のない`call`は従来どおり下の`call|command|exec`分岐で扱い、正規CLI呼出しの判定を変えない。
        if self.mode == Some(Mode::Cmd) {
            // いま実行名として評価している文字列（語全体か、制御語に直結した残り）。
            let mut text = w[0].text.as_str();
            // 同じ語の中で直結した残りを評価し直した回数。各評価は残りの長さに比例するため、
            // `do,do,do,…`のような1語の連鎖で計算量が二乗にならないよう上限を設け、超えたら拒否する。
            let mut glued_steps = 0usize;
            loop {
                let control = match current.glued {
                    // 区切りで切れた名前（cmd_prefix_word）。語の引用の有無は問わない（`call,"del" x`）。
                    Some(_) => cmd_prefix_word(&current.name),
                    // 引用されていない語全体が`do`/`else`（先頭の`@ , ; =`は落として比べる）。
                    // 経路形式（`x/do`）や引用された`"do"`は従来どおり制御語とみなさない。
                    None => {
                        let bare = text.trim_start_matches(CMD_NAME_PREFIX);
                        !w[i].quoted
                            && (bare.eq_ignore_ascii_case("do")
                                || bare.eq_ignore_ascii_case("else"))
                    }
                };
                if !control {
                    break;
                }
                let rest = current
                    .glued
                    .map(|tail| tail.trim_start_matches([',', ';', '=']))
                    .filter(|tail| !tail.is_empty());
                text = match rest {
                    Some(rest) => {
                        glued_steps += 1;
                        if glued_steps > CMD_GLUED_PREFIX_LIMIT {
                            return Ok(self.detected(
                                "too many CMD control words joined by delimiters cannot be inspected",
                                &current.name,
                            ));
                        }
                        rest
                    }
                    None => {
                        i += 1;
                        if i == w.len() {
                            return Ok(false);
                        }
                        &w[i].text
                    }
                };
                current = exec_name_in(text, self.mode, self.explicit);
            }
        }
        let ExecName {
            name: first_name,
            shown: first_shown,
            glued: first_glued,
        } = current;
        let mut name = first_name;
        let mut shown = first_shown;
        let mut glued = first_glued;
        if strict && w[i].quote_start == Some(0) {
            return Ok(false);
        }
        // PowerShellのdot呼出し演算子（`. <command>`）は後続語をコマンドとして現在のscopeで実行する。
        // strictでは字句解析の段階で拒否済みなので、ここに来るのは非strictのPowerShell規則だけである。
        // `.\x.ps1`や`./x`は語全体が実行名なので対象外とし、語がちょうど`.`の場合だけ後続を実行名にする。
        if self.mode == Some(Mode::PowerShell) && w[i].text == "." && !w[i].quoted {
            i += 1;
            if i >= w.len() {
                return Ok(false);
            }
            let next = exec_name_in(&w[i].text, self.mode, self.explicit);
            name = next.name;
            shown = next.shown;
            glued = next.glued;
        }
        if matches!(name.as_str(), "call" | "command" | "exec") {
            i += 1;
            if i >= w.len() || w[i].text.starts_with('-') {
                return Ok(false);
            }
            let next = exec_name_in(&w[i].text, self.mode, self.explicit);
            name = next.name;
            shown = next.shown;
            glued = next.glued;
        }
        // 条件中のquoted dataをCMD/PowerShellのalias名だけでPOSIX削除と推定しない。
        let posix_delete =
            self.mode == Some(Mode::Posix) && matches!(name.as_str(), "rm" | "rmdir" | "unlink");
        if posix_delete || self.mode != Some(Mode::Posix) && non_posix_delete_name(&name) {
            // 報告する語も判定と同じ名前にする（`,del`は`del`、`rd/s/q`は`rd`）。
            return Ok(self.detected("deletion command", shown));
        }
        if name == "reg" {
            // CMD規則で`reg,delete x`・`reg/delete x`のように実行名へ直結した残りがある場合、
            // reg.exeが受け取る引数の区切りを確定できないため、残りの先頭が`delete`なら拒否側に倒す。
            let attached_delete = glued.is_some_and(|tail| {
                let tail = tail.trim_start_matches(['/', ',', ';', '=']);
                tail.get(..6)
                    .is_some_and(|head| head.eq_ignore_ascii_case("delete"))
            });
            let next_delete = w
                .get(i + 1)
                .is_some_and(|t| t.text.eq_ignore_ascii_case("delete"));
            return Ok((attached_delete || next_delete)
                && self.detected("registry deletion command", "reg delete"));
        }
        // 共通指示の管理者起動だけは、EncodedCommand内のStart-Processでも許可する。
        // 引数文字列を再びCMD規則で字句解析すると、cmd.exeが実際に解釈する形（引用剥がし・`&`等）との
        // ずれを検査器が抱えるため、固定形の許可リスト照合に限る（`admin_cmd_start_process`参照）。
        if strict
            && self.mode == Some(Mode::PowerShell)
            && matches!(name.as_str(), "start-process" | "start" | "saps")
            && admin_cmd_start_process(&w[i + 1..], &self.admin_cli, &self.admin_config)
        {
            return Ok(false);
        }
        if strict
            && matches!(
                name.as_str(),
                "iex" | "invoke-expression" | "start-process" | "start" | "saps"
            )
        {
            return Ok(self.detected(
                "dynamic invocation inside EncodedCommand cannot be inspected",
                &name,
            ));
        }
        // 静的な`.ps1`を`-File`で実行するpwshは、非strictの検査と同じくscriptファイル実行として扱う
        // （ファイル内容はどちらの経路でも検査しない）。`-Command`・EncodedCommand・標準入力（`-File -`）・
        // 動的なパス・未知の起動オプションは従来どおり入れ子shellとして拒否する。
        if strict
            && matches!(name.as_str(), "pwsh" | "powershell")
            && static_powershell_file(&w[i + 1..])
        {
            return Ok(false);
        }
        if strict && wrapper(&name) {
            return Ok(self.detected(
                "nested shell inside EncodedCommand cannot be inspected",
                &name,
            ));
        }
        // 代入右辺や`return`等の式はPowerShellではコマンドとして実行される。
        // EncodedCommand復号本文（strict）だけでなく、明示pwshや`pwsh -Command`本文などの
        // 非strictなPowerShell規則でも検査する。引用された右辺・ヒアストリングはdataとして扱う。
        if strict || self.mode == Some(Mode::PowerShell) {
            if matches!(name.as_str(), "return" | "throw" | "exit") {
                return self.expression(w, i + 1, depth, strict);
            }
            if let Some(v) = self.assignment(w, i, depth, strict)? {
                return Ok(v);
            }
        }
        if name == "if" {
            // CMD規則では、条件の語に引用外の`,`が直結した形（`if exist x,del y`・
            // `if exist C:\x,del/q,C:\x`）もcmd.exeは`,`で区切って後続を実行する。
            // `if_command`は語単位で条件を数えるため、先に引用外の`,`で語を割り直してから判定する。
            // 割り直しは`,`を含む語がある場合だけ行い、それ以外は従来の語列をそのまま使う。
            if self.mode == Some(Mode::Cmd) && w[i + 1..].iter().any(|t| !t.commas.is_empty()) {
                let split = split_cmd_commas(&w[i + 1..]);
                let mut c = 0;
                if split
                    .get(c)
                    .is_some_and(|t| t.text.eq_ignore_ascii_case("/i"))
                {
                    c += 1;
                }
                if split
                    .get(c)
                    .is_some_and(|t| t.text.eq_ignore_ascii_case("not"))
                {
                    c += 1;
                }
                return match if_command(&split, c) {
                    Some(s) => self.command(&split[s..], depth + 1, strict),
                    None => Ok(false),
                };
            }
            let mut c = i + 1;
            if w.get(c).is_some_and(|t| t.text.eq_ignore_ascii_case("/i")) {
                c += 1;
            }
            if w.get(c).is_some_and(|t| t.text.eq_ignore_ascii_case("not")) {
                c += 1;
            }
            return match if_command(w, c) {
                Some(s) => self.command(&w[s..], depth + 1, strict),
                None => Ok(false),
            };
        }
        if !wrapper(&name) {
            return Ok(false);
        }
        // cmd.exeはPowerShell・POSIX shellと異なるswitch規則を持つため専用に解析する。
        if name == "cmd" {
            // 実行名に直結した`/c`・`,/c`・`=/c`は、直結部分を先頭の語として差し替えた複製で解析する。
            // 先頭の`, ; =`を落として何も残らない（`cmd,`など）場合は、その語を読み飛ばして続きを解析する。
            let replaced;
            let (words, start): (&[Token], usize) = match glued {
                Some(tail) => {
                    let head = tail.trim_start_matches([',', ';', '=']);
                    let mut copy = w.to_vec();
                    copy[i].text = head.to_owned();
                    replaced = copy;
                    (&replaced, if head.is_empty() { i + 1 } else { i })
                }
                None => (w, i + 1),
            };
            let w = words;
            return match cmd_switches(w, start) {
                CmdSwitches::NoBody => {
                    // cmd.exeでは`;`は引数の区切りなので、本文switchを持たない`cmd`の直後の`;`は
                    // 後続を引数として受ける（`cmd /d;/c del x`）。字句解析で割れた後続を見落とさない。
                    if self.cmd_semicolon && self.mode == Some(Mode::Cmd) {
                        Ok(
                            self.detected(
                                "unsupported CMD wrapper switch cannot be inspected",
                                ";",
                            ),
                        )
                    } else {
                        Ok(false)
                    }
                }
                CmdSwitches::Unknown(token) => {
                    Ok(self.detected("unsupported CMD wrapper switch cannot be inspected", &token))
                }
                CmdSwitches::Body { token, attached } => {
                    let rest = &w[token + 1..];
                    let body = if attached.is_empty() {
                        if rest.is_empty() {
                            return Ok(false);
                        }
                        if rest.len() == 1 && rest[0].quoted {
                            rest[0].text.clone()
                        } else {
                            rest.iter()
                                .map(|t| quote_token(t, true))
                                .collect::<Vec<_>>()
                                .join(" ")
                        }
                    } else {
                        // 直結本文は引用し直さず生のまま使う。`/c"rd /s /q x"`を再引用すると
                        // 1つの実行名になり、本文中の削除を見逃すため。
                        std::iter::once(attached)
                            .chain(rest.iter().map(|t| quote_token(t, true)))
                            .collect::<Vec<_>>()
                            .join(" ")
                    };
                    self.contains(&body, depth + 1, Some(Mode::Cmd), strict)
                }
            };
        }
        let ps = shell(&name) == Some(Mode::PowerShell);
        for j in i + 1..w.len() {
            if ps && encoded(&w[j].text) {
                return Ok(self.detected("noncanonical EncodedCommand invocation", &w[j].text));
            }
            if ps && file_option(&w[j].text) {
                return Ok(false);
            }
            // `/c`・`/k`はcmd専用分岐へ移したが、cmd以外のwrapperでも従来どおり本文として検査し、
            // 検知範囲を狭めない。
            if !(ps && command_option(&w[j].text))
                && !matches!(
                    w[j].text.as_str(),
                    "-c" | "-lc" | "-Command" | "-command" | "/c" | "/C" | "/k" | "/K"
                )
            {
                continue;
            }
            if j + 1 >= w.len() {
                return Ok(false);
            }
            let body = if w.len() == j + 2 && w[j + 1].quoted {
                w[j + 1].text.clone()
            } else {
                w[j + 1..]
                    .iter()
                    .map(|t| quote_token(t, name == "cmd"))
                    .collect::<Vec<_>>()
                    .join(" ")
            };
            return self.contains(&body, depth + 1, shell(&name), strict);
        }
        Ok(false)
    }
    fn posix_prefix(
        &mut self,
        words: &[Token],
        depth: usize,
        strict: bool,
    ) -> Result<Option<bool>> {
        let assignment = compiled(&ASSIGNMENT)?;
        let mut start = 0;
        while start < words.len() && assignment.is_match(&words[start].text) {
            start += 1;
        }
        if start == words.len() {
            return Ok(Some(false));
        }
        if start > 0 {
            return self.posix_nested(&words[start..], depth, strict).map(Some);
        }
        let name = leaf(&words[0].text);
        if matches!(
            name.as_str(),
            "then" | "do" | "else" | "elif" | "if" | "while" | "until" | "!"
        ) {
            // 制御語の後ろも文頭と同じく代入を剥がしてから実行名を調べる（`do n=$(...)`）。
            let mut rest = 1;
            while rest < words.len() && assignment.is_match(&words[rest].text) {
                rest += 1;
            }
            return if rest == words.len() {
                Ok(Some(false))
            } else {
                self.posix_nested(&words[rest..], depth, strict).map(Some)
            };
        }
        if matches!(name.as_str(), "for" | "select") {
            // loopの変数名とin以降はdata。展開されるsubexpressionは上の字句検査で調べる。
            if words.len() >= 2
                && !words[1].dynamic
                && Regex::new(r"\A[A-Za-z_][A-Za-z0-9_]*\z")?.is_match(&words[1].text)
                && (words.len() == 2 || words[2].text == "in")
            {
                return Ok(Some(false));
            }
            return Ok(Some(self.detected(
                "unsupported POSIX loop syntax cannot be inspected",
                &words[0].text,
            )));
        }
        if matches!(name.as_str(), "fi" | "done" | "esac") {
            // 終端語の後ろがリダイレクトだけ（`done 2>&1`・`done < list`）なら、構文全体の入出力先の
            // 指定であってコマンドは実行しない。それ以外の語が続く形は従来どおり検査不能とする。
            return Ok(Some(
                words.len() > 1
                    && !posix_redirections_only(&words[1..])?
                    && self.detected(
                        "unsupported POSIX control suffix cannot be inspected",
                        &words[0].text,
                    ),
            ));
        }
        if matches!(name.as_str(), "case" | "coproc") {
            return Ok(Some(self.detected(
                "unsupported POSIX control syntax cannot be inspected",
                &words[0].text,
            )));
        }
        if !matches!(
            name.as_str(),
            "env" | "sudo" | "time" | "nice" | "command" | "exec" | "nohup"
        ) {
            return Ok(None);
        }
        let mut index = 1;
        let mut options = true;
        while index < words.len() {
            let word = &words[index];
            let value = word.text.as_str();
            if word.dynamic {
                return Ok(Some(self.detected(
                    "dynamic POSIX prefix arguments cannot be inspected",
                    &word.text,
                )));
            }
            if options && value == "--" {
                options = false;
                index += 1;
                continue;
            }
            if name == "env" && assignment.is_match(value) {
                index += 1;
                continue;
            }
            if !options || !value.starts_with('-') || value == "-" && name != "env" {
                break;
            }
            let mut takes_value = false;
            let accepted = match name.as_str() {
                "env" => {
                    takes_value = matches!(value, "-u" | "--unset" | "-C" | "--chdir");
                    takes_value
                        || matches!(
                            value,
                            "-" | "-i"
                                | "--ignore-environment"
                                | "-0"
                                | "--null"
                                | "-v"
                                | "--debug"
                        )
                        || value.starts_with("--unset=")
                        || value.starts_with("--chdir=")
                }
                "sudo" => {
                    if matches!(value, "-l" | "--list" | "-V" | "--version" | "--help") {
                        return Ok(Some(false));
                    }
                    // -s/-iは利用者shellの本文を新しく構築するため推測しない。
                    takes_value = matches!(
                        value,
                        "-u" | "--user"
                            | "-g"
                            | "--group"
                            | "-h"
                            | "--host"
                            | "-p"
                            | "--prompt"
                            | "-C"
                            | "--close-from"
                            | "-T"
                            | "--command-timeout"
                            | "-R"
                            | "--chroot"
                            | "-D"
                            | "--chdir"
                            | "-r"
                            | "--role"
                            | "-t"
                            | "--type"
                    );
                    takes_value
                        || matches!(
                            value,
                            "-n" | "--non-interactive"
                                | "-E"
                                | "--preserve-env"
                                | "-H"
                                | "--set-home"
                                | "-S"
                                | "--stdin"
                                | "-k"
                                | "--reset-timestamp"
                                | "-b"
                                | "--background"
                                | "-P"
                                | "--preserve-groups"
                        )
                        || [
                            "--user=",
                            "--group=",
                            "--host=",
                            "--prompt=",
                            "--close-from=",
                            "--command-timeout=",
                            "--chroot=",
                            "--chdir=",
                            "--role=",
                            "--type=",
                            "--preserve-env=",
                        ]
                        .iter()
                        .any(|p| value.starts_with(p))
                        || value.len() > 2
                            && ["-u", "-g", "-h", "-p", "-C", "-T", "-R", "-D", "-r", "-t"]
                                .iter()
                                .any(|p| value.starts_with(p))
                }
                "time" => {
                    if matches!(value, "--help" | "--version") {
                        return Ok(Some(false));
                    }
                    takes_value = matches!(value, "-o" | "--output" | "-f" | "--format");
                    takes_value
                        || matches!(
                            value,
                            "-p" | "--portability"
                                | "-a"
                                | "--append"
                                | "-q"
                                | "--quiet"
                                | "-v"
                                | "--verbose"
                                | "-l"
                        )
                        || value.starts_with("--output=")
                        || value.starts_with("--format=")
                }
                "nice" => {
                    if matches!(value, "--help" | "--version") {
                        return Ok(Some(false));
                    }
                    takes_value = matches!(value, "-n" | "--adjustment");
                    takes_value
                        || value.starts_with("--adjustment=")
                        || value
                            .strip_prefix('-')
                            .is_some_and(|n| !n.is_empty() && n.parse::<i32>().is_ok())
                }
                "command" => {
                    if !value.starts_with("--")
                        && value[1..].chars().all(|c| matches!(c, 'p' | 'v' | 'V'))
                    {
                        if value.contains(['v', 'V']) {
                            return Ok(Some(false));
                        }
                        true
                    } else {
                        false
                    }
                }
                "exec" => {
                    takes_value = value == "-a";
                    takes_value
                        || !value.starts_with("--")
                            && value[1..].chars().all(|c| matches!(c, 'c' | 'l'))
                }
                "nohup" => {
                    if matches!(value, "--help" | "--version") {
                        return Ok(Some(false));
                    }
                    false
                }
                _ => false,
            };
            if !accepted {
                return Ok(Some(self.detected(
                    "unsupported POSIX prefix syntax cannot be inspected",
                    value,
                )));
            }
            index += 1;
            if takes_value {
                if index == words.len() || words[index].dynamic {
                    return Ok(Some(self.detected(
                        "missing or dynamic POSIX prefix option value cannot be inspected",
                        value,
                    )));
                }
                index += 1;
            }
        }
        if index == words.len() {
            return Ok(Some(false));
        }
        self.posix_nested(&words[index..], depth, strict).map(Some)
    }
    fn posix_nested(&mut self, words: &[Token], depth: usize, strict: bool) -> Result<bool> {
        if depth >= 4 {
            return Ok(self.detected(
                "POSIX prefix inspection depth limit exceeded",
                &words[0].text,
            ));
        }
        // `[`・`[[`はtest組込み（引数の評価だけでコマンドを実行しない）。
        if posix_test_builtin(&words[0]) {
            return Ok(false);
        }
        if words[0].dynamic {
            return Ok(self.detected(
                "dynamic POSIX invocation cannot be inspected",
                &words[0].text,
            ));
        }
        if compiled(&REDIRECTION)?.is_match(&words[0].text) {
            return Ok(self.detected(
                "POSIX redirection prefix cannot be inspected",
                &words[0].text,
            ));
        }
        self.command(words, depth + 1, strict)
    }
    fn posix_shell(&mut self, words: &[Token], depth: usize, strict: bool) -> Result<Option<bool>> {
        if !matches!(leaf(&words[0].text).as_str(), "sh" | "bash" | "zsh") {
            return Ok(None);
        }
        let mut index = 1;
        while index < words.len() {
            let word = &words[index];
            if word.dynamic {
                return Ok(Some(self.detected(
                    "dynamic POSIX shell arguments cannot be inspected",
                    &word.text,
                )));
            }
            let option = word.text.as_str();
            if option == "--" || !option.starts_with(['-', '+']) {
                return Ok(Some(false));
            }
            if matches!(option, "--help" | "--version") {
                return Ok(Some(false));
            }
            if matches!(
                option,
                "-o" | "+o" | "-O" | "+O" | "--rcfile" | "--init-file"
            ) {
                index += 1;
                if index == words.len() || words[index].dynamic {
                    return Ok(Some(self.detected(
                        "missing or dynamic POSIX shell option cannot be inspected",
                        option,
                    )));
                }
            } else if option.starts_with('-')
                && !option.starts_with("--")
                && option[1..].contains('c')
            {
                index += 1;
                if index == words.len() || words[index].dynamic {
                    return Ok(Some(self.detected(
                        "missing or dynamic POSIX shell command cannot be inspected",
                        option,
                    )));
                }
                let previous = self.posix_script;
                self.posix_script = true;
                let result =
                    self.contains(&words[index].text, depth + 1, Some(Mode::Posix), strict);
                self.posix_script = previous;
                return result.map(Some);
            } else if !matches!(
                option,
                "--noprofile" | "--norc" | "--posix" | "--restricted" | "--verbose" | "--login"
            ) && (option.starts_with("--")
                || !option[1..]
                    .chars()
                    .all(|c| "abefhkmnptuvxBCEHPTilrs".contains(c)))
            {
                return Ok(Some(self.detected(
                    "unsupported POSIX shell options cannot be inspected",
                    option,
                )));
            }
            index += 1;
        }
        // 外部script本文や対話入力は読まない。
        Ok(Some(false))
    }
    /// 式の位置にある語をコマンドとして検査する。引用で始まる式は文字列dataとして扱う。
    /// `strict`は呼出し元の規則を引き継ぎ、非strictのPowerShell規則でEncodedCommand専用の拒否を働かせない。
    fn expression(&mut self, w: &[Token], i: usize, depth: usize, strict: bool) -> Result<bool> {
        if i >= w.len() || w[i].quote_start == Some(0) {
            Ok(false)
        } else {
            self.command(&w[i..], depth + 1, strict)
        }
    }
    /// PowerShellの代入・`foreach ($x in ...)`の右辺をコマンドとして検査する。
    /// 代入でない場合は`None`を返し、呼出し元が通常のコマンド検査を続ける。
    fn assignment(
        &mut self,
        w: &[Token],
        mut i: usize,
        depth: usize,
        strict: bool,
    ) -> Result<Option<bool>> {
        if w[i].text.eq_ignore_ascii_case("foreach")
            && w.get(i + 1).is_some_and(|t| t.text.starts_with('$'))
        {
            i += 1;
        }
        let t = &w[i];
        let v = &t.text;
        if !v.starts_with(['$', '.', '[', '=']) {
            return Ok(None);
        }
        if let Some(eq) = v.find('=') {
            // 引用を含む代入先は、復号本文（strict）では解釈を確定できないため拒否する。
            // 非strictでは入力全体を拒否せず、右辺の検査を続ける。
            if strict && t.quote_start.is_some_and(|q| q <= eq) {
                bail!("EncodedCommand quoted assignment targets cannot be inspected.");
            }
            if t.quote_start == Some(eq + 1) {
                return Ok(Some(false));
            }
            let rhs = &v[eq + 1..];
            if rhs.is_empty() {
                return Ok(Some(self.expression(w, i + 1, depth, strict)?));
            }
            let mut expression = vec![Token::new(rhs)];
            expression[0].quoted = t.quoted;
            expression.extend_from_slice(&w[i + 1..]);
            return Ok(Some(self.command(&expression, depth + 1, strict)?));
        }
        if let Some(n) = w.get(i + 1) {
            if (v.starts_with('$') && n.text.eq_ignore_ascii_case("in"))
                || (n.text.ends_with('=') && n.text.chars().all(|c| "=+-*/%?".contains(c)))
            {
                return Ok(Some(self.expression(w, i + 2, depth, strict)?));
            }
        }
        Ok(None)
    }
    fn expanded(&mut self, text: &str, depth: usize) -> Result<bool> {
        let chars: Vec<char> = text.chars().collect();
        let mut start = 0;
        while start + 1 < chars.len() {
            if chars[start] != '$' || chars[start + 1] != '(' {
                start += 1;
                continue;
            }
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
            let body_end = if level == 0 { end - 1 } else { chars.len() };
            if self.contains(
                &chars[start + 2..body_end].iter().collect::<String>(),
                depth + 1,
                None,
                false,
            )? {
                return Ok(true);
            }
            start = if level == 0 { end } else { chars.len() };
        }
        Ok(false)
    }
    fn noncanonical(&mut self, w: &[Token], depth: usize) -> Result<bool> {
        let mut parts = Vec::<String>::new();
        let (mut wrapper_seen, mut executable_position, mut output_only, mut in_backtick) =
            (false, true, false, false);
        let mut backtick_script = String::new();
        let mut prefix_name = String::new();
        let mut prefix_option = false;
        let expression_lead = w[0].text.starts_with(['$', '=', '.', '[', '(']);
        for (index, word) in w.iter().enumerate() {
            let executable = leaf(word.text.trim_start_matches('@'));
            let option_value = executable_position && prefix_option;
            if option_value {
                prefix_option = false;
            }
            if executable_position
                && !option_value
                && matches!(
                    executable.as_str(),
                    "echo" | "write-output" | "write-host" | "write-information" | "printf"
                )
            {
                output_only = true;
            }
            let quoted_executable = !option_value
                && word.quote_start == Some(0)
                && (executable_position || wrapper_seen)
                && !output_only
                && !(index > 0 && w[index - 1].text == "=")
                && shell(&executable) == Some(Mode::PowerShell);
            if executable_position
                && !option_value
                && (wrapper(&executable)
                    || matches!(
                        executable.as_str(),
                        "env" | "sudo" | "time" | "nice" | "call" | "command" | "exec"
                    ))
            {
                wrapper_seen = true;
            }
            if quoted_executable {
                wrapper_seen = true;
            }
            if executable_position && !option_value && matches!(executable.as_str(), "env" | "nice")
            {
                prefix_name = executable.clone();
            }
            if executable_position
                && !option_value
                && ((prefix_name == "env"
                    && matches!(word.text.as_str(), "-u" | "--unset" | "-C" | "--chdir"))
                    || (prefix_name == "nice"
                        && matches!(word.text.as_str(), "-n" | "--adjustment")))
            {
                prefix_option = true;
            }
            let prefix = executable_position
                && (option_value
                    || matches!(
                        executable.as_str(),
                        "call" | "command" | "exec" | "env" | "sudo" | "time" | "nice"
                    )
                    || word.text.starts_with('-'));
            if executable_position && !prefix && !wrapper(&executable) && !quoted_executable {
                wrapper_seen = false;
            }
            if !(prefix || (executable_position && compiled(&ASSIGNMENT)?.is_match(&word.text))) {
                executable_position = false;
            }
            let expandable = in_backtick || word.backticks > 0 || word.subexpression;
            if word.subexpression && self.expanded(&word.text, depth)? {
                return Ok(true);
            }
            if in_backtick || word.backticks > 0 {
                if !backtick_script.is_empty() {
                    backtick_script.push(' ');
                }
                backtick_script.push_str(&word.text);
            }
            if word.backticks & 1 != 0 {
                in_backtick = !in_backtick;
            }
            if !backtick_script.is_empty() && !in_backtick {
                if let (Some(start), Some(end)) =
                    (backtick_script.find('`'), backtick_script.rfind('`'))
                {
                    if end > start
                        && self.contains(
                            &backtick_script[start + 1..end],
                            depth + 1,
                            None,
                            false,
                        )?
                    {
                        return Ok(true);
                    }
                }
                backtick_script.clear();
            }
            if output_only && index > 0 && !expandable {
                continue;
            }
            if word.quote_start.is_some() && !wrapper_seen && !expandable {
                continue;
            }
            if !executable_position && !wrapper_seen && !expression_lead {
                continue;
            }
            for part in word.text.split_whitespace() {
                parts.push(if wrapper_seen && word.quote_start.is_some() {
                    part.trim_matches(['\'', '"']).to_owned()
                } else {
                    part.to_owned()
                });
            }
        }
        // 各PowerShell実行名の後ろで、最初に現れるEncodedCommand系optionが
        // -File/-Commandより前にあれば非正規の呼出しとして拒否する。
        // 実行名ごとに前方へ走査すると実行名が大量に並ぶ入力で二次計算量になるため、
        // 後ろから1回だけ走査し「直後で最初に現れるencoded/停止option」を保持して線形にする。
        // 報告するtokenは従来の前方走査と同じく、最も前の実行名に対応するものにする。
        enum Next<'a> {
            Encoded(&'a str),
            Stop,
        }
        let mut next: Option<Next> = None;
        let mut hit: Option<&str> = None;
        for part in parts.iter().rev() {
            let original = part.as_str();
            let mut name = original;
            if let Some(eq) = name.rfind('=') {
                if eq + 1 < name.len() {
                    name = &name[eq + 1..];
                }
            }
            if let Some(sub) = name.rfind("$(") {
                name = &name[sub + 2..];
            }
            name = name.trim_matches(['@', '$', '(', ')', '{', '}', '`']);
            // 後ろから走査しているため、上書きし続けると最も前の実行名の結果が残る。
            if let Some(Next::Encoded(token)) = next
                && shell(&leaf(name)) == Some(Mode::PowerShell)
            {
                hit = Some(token);
            }
            // 従来の前方走査と同じく、encodedの判定を停止optionより優先する。
            if encoded(original) {
                next = Some(Next::Encoded(original));
            } else if file_option(original) || command_option(original) {
                next = Some(Next::Stop);
            }
        }
        if let Some(token) = hit {
            return Ok(self.detected("noncanonical EncodedCommand invocation", token));
        }
        Ok(false)
    }
}
fn if_command(w: &[Token], c: usize) -> Option<usize> {
    if c + 2 >= w.len() {
        return None;
    }
    if !w[c].quoted
        && matches!(
            w[c].text.to_ascii_lowercase().as_str(),
            "exist" | "defined" | "errorlevel" | "cmdextversion"
        )
    {
        return Some(c + 2);
    }
    let mut comparison = c;
    if w[comparison].equality.is_none() {
        comparison += 1;
        if matches!(
            w[comparison].text.to_ascii_lowercase().as_str(),
            "equ" | "neq" | "lss" | "leq" | "gtr" | "geq"
        ) {
            return (c + 3 < w.len()).then_some(c + 3);
        }
        if w[comparison].equality != Some(0) {
            return None;
        }
    }
    let t = &w[comparison];
    let right = t.equality.unwrap() + 2 < t.text.len() || t.quoted_after_equality;
    let start = comparison + if right { 1 } else { 2 };
    (start < w.len()).then_some(start)
}
fn quote_token(t: &Token, cmd: bool) -> String {
    fn q(v: &str) -> String {
        format!("\"{}\"", v.replace('"', "\"\""))
    }
    if cmd && t.quoted {
        if let Some(eq) = t.equality {
            let left = &t.text[..eq];
            let right = &t.text[eq + 2..];
            return format!(
                "{}=={}",
                if !left.is_empty() || t.quote_start == Some(0) {
                    q(left)
                } else {
                    String::new()
                },
                if !right.is_empty() || t.quoted_after_equality {
                    q(right)
                } else {
                    String::new()
                }
            );
        }
    }
    if t.quoted { q(&t.text) } else { t.text.clone() }
}
fn here_string(s: &[char], position: &mut usize, quote: char) -> Result<String> {
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
            && s[end] == quote
            && s[end + 1] == '@'
        {
            let body = &s[start..end];
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
fn append(t: &mut Token, c: char, previous_equal: &mut bool) {
    if c == '=' {
        if *previous_equal && t.equality.is_none() {
            t.equality = Some(t.text.len() - 1);
        }
        *previous_equal = true;
    } else {
        *previous_equal = false;
    }
    t.text.push(c);
}
fn flush(t: &mut Token, out: &mut Vec<Token>) {
    if !t.text.is_empty() || t.quoted {
        out.push(std::mem::replace(t, Token::new("")));
    }
}
fn boundary(out: &mut Vec<Token>) {
    let mut t = Token::new("");
    t.boundary = true;
    out.push(t);
}
/// POSIX規則で見つけたヒアドキュメント1つ分の情報。本文を読み飛ばせるかの判定に使う。
struct Heredoc {
    /// 引用を除いた終端語。
    delimiter: String,
    /// 終端語が引用・退避されているか（本文で展開・コマンド置換が起きない）。
    quoted: bool,
    /// `<<`を含む文がtokens出力のどこから始まるか。
    statement_start: usize,
    /// `<<`より前の状況が読み飛ばし可能か（括弧の入れ子なし、算術・`[[`・逆引用なし）。
    context_ok: bool,
}
/// ヒアドキュメント本文を読み飛ばしてよい場合に、本文の次の文字位置を返す。
///
/// 読み飛ばすのは、終端語が引用された本文（展開なしのdata）を、ファイルへ書き出す`cat`か、
/// 本文をコードとして読むインタプリタ（`python`・`node`。`-c`の本文と同じく検査対象外）が受け取る形だけ。
/// shellへ渡りうる形（パイプ・入れ子のグループ・同じ行の後続文・`/dev`への出力）は従来どおり本文を文として検査する。
/// 本文の終わりはbashより早めに判定する（前後の空白を除いて終端語と一致した行）。早く終われば残りを
/// 文として検査するだけなので安全側に倒れる。
fn heredoc_skip(
    s: &[char],
    body_start: usize,
    heredocs: &[Heredoc],
    out: &[Token],
    boundary_after: bool,
) -> Result<Option<usize>> {
    if boundary_after || heredocs.is_empty() {
        return Ok(None);
    }
    for heredoc in heredocs {
        if !heredoc.quoted
            || !heredoc.context_ok
            || heredoc.delimiter.is_empty()
            || !heredoc_consumer_is_data_sink(&out[heredoc.statement_start.min(out.len())..])?
        {
            return Ok(None);
        }
    }
    let mut position = body_start;
    for heredoc in heredocs {
        loop {
            if position >= s.len() {
                // 終端のないヒアドキュメントはbashでも入力の終わりまでが本文になる。
                return Ok(Some(s.len()));
            }
            let end = s[position..]
                .iter()
                .position(|&c| c == '\n')
                .map_or(s.len(), |offset| position + offset);
            let line: String = s[position..end].iter().collect();
            position = (end + 1).min(s.len());
            if line.trim() == heredoc.delimiter {
                break;
            }
        }
    }
    Ok(Some(position))
}
/// ヒアドキュメントを受け取る文が、本文をshellへ渡さない形（ファイルへの`cat`・インタプリタ）か。
fn heredoc_consumer_is_data_sink(words: &[Token]) -> Result<bool> {
    let assignment = compiled(&ASSIGNMENT)?;
    let mut command: Vec<&Token> = Vec::new();
    let mut stdout_to_file = false;
    let mut k = 0;
    while k < words.len() {
        let word = &words[k];
        let text = word.text.as_str();
        // 文の終わり（CRLFの`\r`等）。同じ行で後ろに続く文は呼出し側の`boundary_after`で拒否済み。
        if word.boundary {
            break;
        }
        // `<<`・`<<-`（終端語が直結していれば同じ語、離れていれば次の語が終端語）。
        if word.quote_start != Some(0) && text.starts_with("<<") {
            let rest = text[2..].strip_prefix('-').unwrap_or(&text[2..]);
            k += if rest.is_empty() && !word.quoted { 2 } else { 1 };
            continue;
        }
        if !word.quoted && text.starts_with('<') {
            return Ok(false);
        }
        // 出力リダイレクト（`>`・`>>`・`1>`・`2>`。対象は直結か次の語）。
        let digits = text.len() - text.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if word.quote_start != Some(0) && text[digits..].starts_with('>') {
            let operator = text[digits..].trim_start_matches('>');
            let (target, step) = if operator.is_empty() {
                match words.get(k + 1) {
                    Some(next) => (next, 2),
                    None => return Ok(false),
                }
            } else {
                (word, 1)
            };
            let target_text = if operator.is_empty() { target.text.as_str() } else { operator };
            if target.dynamic || target.boundary || target_text.is_empty() {
                return Ok(false);
            }
            if &text[..digits] != "2" {
                let lower = target_text.to_ascii_lowercase();
                if lower.starts_with("/dev/") || lower.starts_with("/proc/") {
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
    if first.quoted || first.dynamic {
        return Ok(false);
    }
    let static_option = |w: &&Token| !w.quoted && !w.dynamic && w.text.starts_with('-');
    Ok(match leaf(&first.text).as_str() {
        "cat" => command.len() == 1 && stdout_to_file,
        "python" | "python3" | "py" | "node" => command[1..].iter().all(static_option),
        _ => false,
    })
}
/// PowerShell strict検査で、`s[i]`の単独の`.`がdot-sourcingではなく、前のコマンドへ渡す
/// 引数（カレントディレクトリ）かを判定する。`rg -n x .`・`Get-ChildItem -Path .`・
/// `git grep x -- .`のような形を拒否しないために使う。
///
/// dot-sourcingはコマンド位置（文頭・`;`・`|`・`&`・`{`・`(`・`=`の直後や、
/// パイプラインを取るキーワードの直後）でだけ働く。そこで、同じ行で直前に
/// 空白以外の文字があり、それが通常の語の末尾として使われる文字で、かつ直前の語が
/// 文境界やキーワードでない場合だけ引数とみなす。`.(`は動的なdot-sourcingになりうるため、
/// 後続が空白の場合に限る。判定できない形は従来どおり拒否側に倒す。
fn powershell_dot_argument(s: &[char], i: usize, out: &[Token]) -> bool {
    if s.get(i + 1).is_none_or(|c| !c.is_whitespace()) {
        return false;
    }
    // 改行・行継続は文の区切りを曖昧にするので、同じ行の空白とタブだけを読み飛ばす。
    let mut j = i;
    while j > 0 && matches!(s[j - 1], ' ' | '\t') {
        j -= 1;
    }
    if j == 0 || j == i {
        return false;
    }
    let previous = s[j - 1];
    if !(previous.is_alphanumeric()
        || matches!(previous, '\'' | '"' | '-' | '_' | '.' | '/' | '\\' | ':' | '*'))
    {
        return false;
    }
    let Some(last) = out.last() else {
        return false;
    };
    if last.boundary || last.dynamic || last.subexpression {
        return false;
    }
    // パイプラインや文を後ろに取るキーワードの直後はコマンド位置になる。
    const KEYWORDS: &[&str] = &[
        "return", "throw", "exit", "in", "else", "elseif", "if", "do", "try", "catch",
        "finally", "begin", "process", "end", "param", "trap", "switch", "while", "until",
        "foreach", "for", "data", "dynamicparam", "filter", "function", "break", "continue",
        "class", "enum", "using", "workflow", "parallel", "sequence", "inlinescript",
    ];
    if !last.quoted && KEYWORDS.iter().any(|k| last.text.eq_ignore_ascii_case(k)) {
        return false;
    }
    true
}
fn tokens(script: &str, mode: Mode, strict: bool) -> Result<Vec<Token>> {
    let s: Vec<char> = script.chars().collect();
    let mut out = Vec::new();
    let mut t = Token::new("");
    let mut quote = '\0';
    let mut previous_equal = false;
    let mut i = 0;
    // POSIX規則のヒアドキュメント追跡（heredoc_skip参照）。
    let mut heredocs: Vec<Heredoc> = Vec::new();
    let mut statement_start = 0usize;
    let mut group_depth = 0i32;
    let mut line_start = 0usize;
    let mut heredoc_boundary_after = false;
    while i < s.len() {
        let mut c = s[i];
        // 引用外の`<<`（`<<<`を除く）を見つけたら終端語を読み取って記録する。字句解析は通常どおり続ける。
        if mode == Mode::Posix
            && quote == '\0'
            && c == '<'
            && s.get(i + 1) == Some(&'<')
            && s.get(i + 2) != Some(&'<')
            && (i == 0 || s[i - 1] != '<')
        {
            let mut j = i + 2;
            if s.get(j) == Some(&'-') {
                j += 1;
            }
            while j < s.len() && matches!(s[j], ' ' | '\t') {
                j += 1;
            }
            let mut delimiter = String::new();
            let mut quoted = false;
            let mut complete = true;
            while j < s.len() && !s[j].is_whitespace() && !matches!(s[j], ';' | '|' | '&' | '(' | ')' | '<' | '>') {
                match s[j] {
                    '\'' | '"' => {
                        let close = s[j];
                        quoted = true;
                        j += 1;
                        while j < s.len() && s[j] != close {
                            delimiter.push(s[j]);
                            j += 1;
                        }
                        if j == s.len() {
                            complete = false;
                        }
                        j += 1;
                    }
                    '\\' => {
                        quoted = true;
                        if let Some(&next) = s.get(j + 1) {
                            delimiter.push(next);
                        }
                        j += 2;
                    }
                    other => {
                        delimiter.push(other);
                        j += 1;
                    }
                }
            }
            let before: String = s[line_start..i].iter().collect();
            heredocs.push(Heredoc {
                delimiter,
                quoted: quoted && complete,
                statement_start,
                context_ok: group_depth == 0
                    && !before.contains("((")
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
                    let mut target = String::new();
                    let mut end = next + 1;
                    while end < s.len() {
                        let value = s[end];
                        if matches!(value, '\r' | '\n')
                            || ('\u{2018}'..='\u{201e}').contains(&value)
                        {
                            bail!("EncodedCommand invocation target cannot be inspected.");
                        }
                        if value != '\'' {
                            target.push(value);
                            end += 1;
                            continue;
                        }
                        if s.get(end + 1) == Some(&'\'') {
                            target.push('\'');
                            end += 2;
                            continue;
                        }
                        break;
                    }
                    if end == s.len()
                        || target.is_empty()
                        || s.get(end + 1)
                            .is_some_and(|c| !c.is_whitespace() && !matches!(c, ';' | '|' | '&'))
                    {
                        bail!(
                            "EncodedCommand invocation target must be a complete static literal."
                        );
                    }
                    if target.starts_with(char::is_whitespace)
                        || target.ends_with(char::is_whitespace)
                        || target.ends_with('.')
                    {
                        bail!("EncodedCommand invocation target has an ambiguous name.");
                    }
                    if leaf(&target) == "reg" {
                        bail!("EncodedCommand quoted reg invocation cannot be inspected.");
                    }
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
        if mode == Mode::Posix && c == '`' && quote != '\'' {
            t.backticks += 1;
        }
        if matches!(mode, Mode::Posix | Mode::PowerShell)
            && quote == '"'
            && c == '$'
            && s.get(i + 1) == Some(&'(')
        {
            t.subexpression = true;
        }
        if mode == Mode::Posix
            && quote != '\''
            && (matches!(c, '$' | '`') || quote == '\0' && matches!(c, '*' | '?' | '['))
        {
            t.dynamic = true;
        }
        if quote != '\0' {
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
            if c == quote {
                if mode != Mode::Posix && s.get(i + 1) == Some(&quote) {
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
            i += 1;
            c = s[i];
            // 行継続でつないだ語も、shellによって語の割れ方が変わりうるため退避ありとして扱う。
            t.escaped = true;
            if matches!(c, '\r' | '\n') {
                if c == '\r' && s.get(i + 1) == Some(&'\n') {
                    i += 1;
                }
            } else {
                t.bare_chars += 1;
                append(&mut t, c, &mut previous_equal);
            }
            i += 1;
            continue;
        }
        if mode == Mode::PowerShell && c == '@' && matches!(s.get(i + 1), Some('\'' | '"')) {
            if t.quote_start.is_none() {
                t.quote_start = Some(t.text.len());
            }
            let here_quote = s[i + 1];
            let body = here_string(&s, &mut i, here_quote)?;
            t.text.push_str(&body);
            t.quoted = true;
            t.quote_segments += 1;
            t.non_single_quote = true;
            i += 1;
            continue;
        }
        if c == '"' || (c == '\'' && mode != Mode::Cmd) {
            if t.quote_start.is_none() {
                t.quote_start = Some(t.text.len());
            }
            if t.equality.is_some() {
                t.quoted_after_equality = true;
            }
            previous_equal = false;
            quote = c;
            t.quoted = true;
            t.quote_segments += 1;
            if c != '\'' {
                t.non_single_quote = true;
            }
            i += 1;
            continue;
        }
        if mode != Mode::Cmd && c == '#' && t.text.is_empty() {
            while i < s.len() && !matches!(s[i], '\r' | '\n') {
                i += 1;
            }
            c = '\n';
        }
        let is_boundary = matches!(c, ';' | '|' | '&' | '\r' | '\n' | '(' | ')' | '{' | '}');
        if c.is_whitespace() || is_boundary {
            flush(&mut t, &mut out);
            previous_equal = false;
            // 行末で、記録したヒアドキュメントの本文をdataとして読み飛ばせるか判定する。
            if mode == Mode::Posix && c == '\n' {
                let skip = heredoc_skip(&s, i + 1, &heredocs, &out, heredoc_boundary_after)?;
                heredocs.clear();
                heredoc_boundary_after = false;
                if let Some(next) = skip {
                    boundary(&mut out);
                    statement_start = out.len();
                    i = next;
                    line_start = next;
                    continue;
                }
                line_start = i + 1;
            }
            if mode == Mode::Posix && is_boundary && !matches!(c, '\r' | '\n') {
                if !heredocs.is_empty() {
                    heredoc_boundary_after = true;
                }
                match c {
                    '(' | '{' => group_depth += 1,
                    ')' | '}' => group_depth -= 1,
                    _ => {}
                }
            }
            if is_boundary {
                boundary(&mut out);
                statement_start = out.len();
                // CMDでは`;`は空白相当の区切りで文の境界ではない。検査のため文は割るが、
                // 境界が`;`だったことを残し、`cmd`wrapperの引数列が割れた形を呼出し側で拒否できるようにする。
                if mode == Mode::Cmd
                    && c == ';'
                    && let Some(last) = out.last_mut()
                {
                    last.text = ";".into();
                }
            }
        } else {
            // 引用外・非退避の`,`だけを記録する（引用内は上で、`^,`は退避分岐で処理済み）。
            if mode == Mode::Cmd && c == ',' {
                t.commas.push(t.text.len());
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

fn inspect(input: &Value, config: &Path, cli: &Path) -> Result<Value> {
    if !input.is_object() {
        bail!("Hook input must be an object.");
    }
    let name = input
        .get("tool_name")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Hook tool_name must be a string."))?;
    if !matches!(name, "Bash" | "exec_command" | "functions.exec_command") {
        return Ok(json!({}));
    }
    let arguments = input
        .get("tool_input")
        .filter(|v| v.is_object())
        .ok_or_else(|| anyhow::anyhow!("Hook tool_input must be an object."))?;
    let command = arguments
        .get("command")
        .or_else(|| arguments.get("cmd"))
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Hook command must be a string."))?;
    let mode = if name != "Bash" {
        arguments
            .get("shell")
            .and_then(Value::as_str)
            .and_then(|s| shell(&leaf(s)))
    } else {
        None
    };
    let mut inspection = Inspector {
        admin_cli: cli.to_string_lossy().into_owned(),
        admin_config: config.to_string_lossy().into_owned(),
        ..Inspector::default()
    };
    if !inspection.contains(command, 0, mode, false)? {
        return Ok(json!({}));
    }
    // 単独EncodedCommandは復号本文をPowerShellとして確定検査しているため、
    // shell不明時の候補注記とEncodedCommandへの変換案内を付けない。
    let standalone_encoded = inspection.standalone_encoded;
    let deletion = inspection.deletion;
    let mut reason = inspection.detection.unwrap_or_else(|| {
        "Prunlet rejected this command because an invocation could not be safely classified.".into()
    });
    let executable = cli.to_string_lossy();
    let config = config.to_string_lossy();
    // 削除命令を検知していない拒否（構文を静的に検査できない場合）は、削除の手順を長く添えても
    // 役に立たず、拒否のたびに大量の文脈を消費する。原因と書き換えの方向だけを短く返す。
    if !deletion {
        if mode.is_none() && cfg!(windows) && !standalone_encoded {
            reason.push_str(" Shell metadata is missing or unsupported; this is a candidate interpretation, not a confirmed local deletion.");
        }
        // CLIの表記は各OSの完全な案内と同じ引用規則にそろえる。
        let quote = |s: &str| {
            if !cfg!(windows) {
                format!("'{}'", s.replace('\'', "'\\''"))
            } else if s.chars().any(char::is_whitespace) {
                format!("\"{s}\"")
            } else {
                s.into()
            }
        };
        reason.push_str(&format!(
            " The hook did not execute the command. This is an inspection limit, not a detected deletion: rewrite the command without that construct (for example, run the logic from a script file). For authorized deletions use the installed Prunlet CLI: {} --config {} delete --paths-file <absolute-json-file>.",
            quote(&executable),
            quote(&config)
        ));
        return Ok(deny(&reason));
    }
    if mode.is_none() && cfg!(windows) && !standalone_encoded {
        reason.push_str(" Shell metadata is missing or unsupported; this is a candidate interpretation, not a confirmed local deletion. Quoted search text or remote script data may be interpreted as command syntax. If the host forwards the tool as Bash without shell metadata, setting exec_command.shell alone cannot resolve this ambiguity. For an authorized SSH script sent from PowerShell, encode the entire local PowerShell script as UTF-16LE Base64 and submit the standalone form pwsh -NoProfile -EncodedCommand <base64>. The hook decodes and inspects that script; it does not exempt SSH names or remote deletion targets from inspection. See docs/integration.md for the supported form.");
    }
    if cfg!(windows) {
        let quote = |s: &str| {
            if s.chars().any(char::is_whitespace) {
                format!("\"{s}\"")
            } else {
                s.into()
            }
        };
        reason.push_str(&format!(" The hook did not execute the command. The following CLI guidance applies only to authorized Windows deletion targets. For explicitly authorized targets, use the installed Prunlet CLI from the start with shell=cmd.exe and login=false: {} --config {} delete --paths-file <absolute-json-file>; for registry keys/values use {} --config {} registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] -- <registry-key-path>. File and folder deletions have no Prunlet operation record. Normally restore recycled items using Windows Recycle Bin; a file or folder Windows reports as too large may instead be permanently deleted. Dry-run cannot predict the final disposition. Keep registry operationId and use registry-restore <operationId>. On hosts supporting exec_command sandbox permissions, request sandbox_permissions=\"require_escalated\" from the first real file deletion because Recycle Bin access may be restricted. This is a formal host permission request, not Windows UAC or administrator elevation. A dry-run does not prove real-operation permissions. Existing host approvals and policies still apply. Do not retry a policy-rejected target through another route or automatically resend a failed deletion; check uncertain file results using the source and Windows Recycle Bin; reconcile registry results using registry-reconcile <operationId> before deciding next steps.",quote(&executable),quote(&config),quote(&executable),quote(&config)));
    } else if cfg!(target_os = "linux") {
        let q = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
        reason.push_str(&format!(" The hook did not execute the command. For explicitly authorized local Linux targets use the installed Prunlet CLI: {} --config {} delete --paths-file <absolute-json-file>. Items move to the freedesktop home Trash on the same mount. Existing host approvals and policies still apply. Do not resend ambiguous deletion; inspect the source and Trash.", q(&executable), q(&config)));
    } else {
        let q = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
        reason.push_str(&format!(" The hook did not execute the command. For explicitly authorized local macOS targets use the installed native Prunlet CLI: {} --config {} delete --paths-file <absolute-json-file>. Files normally go to macOS Trash without Prunlet operation records. On macOS, delete-queue waits only for cooperating processes that hold an advisory flock; merely opening a file or mapping a dylib does not delay deletion. Registry operations are Windows-only and are unsupported on macOS. SSH names and remote script text do not bypass inspection. Existing host approvals and policies still apply. Do not resend failed or ambiguous deletion; inspect the source and Trash.",q(&executable),q(&config)));
    }
    Ok(deny(&reason))
}
fn deny(reason: &str) -> Value {
    json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":reason}})
}
pub fn run(config_path: &Path, cli_path: &Path) -> i32 {
    let result = (|| -> Result<Value> {
        let text = read_to_end(io::stdin().lock())?;
        let input: Value = serde_json::from_str(&text)?;
        inspect(&input, config_path, cli_path)
    })();
    let output = match result {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Prunlet hook: {e}");
            deny(&format!("Prunlet could not inspect the hook input: {e}"))
        }
    };
    println!("{output}");
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assignments_and_redirections_keep_command_detection() {
        for command in [
            "A=1 rm -- /tmp/owned-fixture",
            "env A=1 rm -- /tmp/owned-fixture",
            "if true; then 2>/tmp/owned-output rm -- /tmp/owned-fixture; fi",
        ] {
            let result = Inspector::default().contains(command, 0, Some(Mode::Posix), false);
            assert!(result.is_err() || result.unwrap(), "{command}");
        }
        for command in ["A=1 printf '%s' rm", "env A=1 printf '%s' safe"] {
            assert!(
                !Inspector::default()
                    .contains(command, 0, Some(Mode::Posix), false)
                    .unwrap(),
                "{command}"
            );
        }
    }

    /// hook入力を組み立ててinspectへ渡し、拒否なら理由を返す。検査errorもrun()と同じく拒否として扱う。
    /// 文字列はhookへ渡すだけで実行しない。
    fn reason(command: &str, tool: &str, shell: Option<&str>) -> Option<String> {
        let mut tool_input = json!({ "command": command });
        if let Some(shell) = shell {
            tool_input["shell"] = json!(shell);
        }
        let input = json!({ "tool_name": tool, "tool_input": tool_input });
        match inspect(
            &input,
            Path::new(r"C:\fixture\config.json"),
            Path::new(r"C:\fixture\prunlet.exe"),
        ) {
            Ok(value) if value == json!({}) => None,
            Ok(value) => Some(
                value["hookSpecificOutput"]["permissionDecisionReason"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned(),
            ),
            Err(error) => Some(format!("Prunlet could not inspect the hook input: {error}")),
        }
    }
    fn denied(command: &str, shell: &str) -> bool {
        reason(command, "exec_command", Some(shell)).is_some()
    }

    // 正規のPrunlet CLI呼出し。`/d /c`とMSYS向けの`//d //c`、call付きの各形を通過させる。
    const CANONICAL_CLI: [&str; 4] = [
        r#"cmd.exe /d /c "C:\Users\me\.local\Prunlet\bin\prunlet.exe --config C:\Users\me\.local\Prunlet\config.json delete --paths-file D:\work\paths.json""#,
        r#"cmd.exe //d //c "C:\Users\me\.local\Prunlet\bin\prunlet.exe --config C:\Users\me\.local\Prunlet\config.json delete --paths-file D:\work\paths.json""#,
        r#"cmd.exe /d /c call "C:\Users\me\.local\Prunlet\bin\prunlet.exe" --config "C:\Users\me\.local\Prunlet\config.json" delete --paths-file "D:\work\paths.json""#,
        r#"cmd.exe //d //c call "C:\Users\me\.local\Prunlet\bin\prunlet.exe" --config "C:\Users\me\.local\Prunlet\config.json" delete --paths-file "D:\work\paths.json""#,
    ];

    #[test]
    fn cmd_wrapper_switch_forms_inspect_the_body() {
        for command in [
            r"cmd.exe //c del C:\fixture\file.txt",
            r"cmd.exe //d //c del C:\fixture\file.txt",
            r"cmd /R del C:\fixture\file.txt",
            r"cmd /r del C:\fixture\file.txt",
            r"cmd /K del C:\fixture\file.txt",
            r"cmd /cdel C:\fixture\file.txt",
            r"cmd /d/c del C:\fixture\file.txt",
            r"cmd //d//c del C:\fixture\file.txt",
            r#"cmd /D/Q/C "del C:\fixture\file.txt""#,
            r#"cmd /c"rd /s /q C:\fixture\dir""#,
            r"cmd /e:on /v:off /f:ON /t:0a /s /a /u /c del C:\fixture\file.txt",
            r"cmd /d /c reg delete HKCU\Software\PrunletHookProbe /f",
            r#"cmd /c "echo ok & del C:\fixture\file.txt""#,
            r"cmd -c del C:\fixture\file.txt",
        ] {
            for shell in ["cmd.exe", "pwsh"] {
                assert!(denied(command, shell), "{shell}: {command}");
            }
        }
        // 未知switch・本文前の未知引数は本文を確定できないためfail-closedにする。
        for command in [
            "cmd /z /c echo ok",
            "cmd /dq /c echo ok",
            "cmd /t:zz /c echo ok",
            "cmd / /c echo ok",
            "cmd stray /c echo ok",
        ] {
            let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
            assert!(
                reason.contains("unsupported CMD wrapper switch"),
                "{command}: {reason}"
            );
        }
        for command in CANONICAL_CLI.into_iter().chain([
            "cmd /?",
            "cmd",
            "cmd /d",
            "cmd /c",
            r"cmd /c reg query HKCU\Software\PrunletHookProbe",
            r"cmd /c echo del C:\fixture\file.txt",
            r"cmd //c echo rd /s /q",
        ]) {
            for shell in ["cmd.exe", "pwsh"] {
                assert!(!denied(command, shell), "{shell}: {command}");
            }
        }
        if cfg!(windows) {
            for command in CANONICAL_CLI {
                assert_eq!(reason(command, "Bash", None), None, "{command}");
            }
            assert!(reason(r"cmd.exe //d //c del C:\fixture\file.txt", "Bash", None).is_some());
        }
    }

    /// scripts/Verify-HookParsing.ps1 に追加した回帰ケースと同じ文字列・期待値。
    /// E2EではBashはshellを無視して全規則で検査されるため、Bash側の期待値もここで確かめる。
    #[test]
    fn verify_script_regression_cases_match_expectations() {
        let file = r"D:\fixture\hook-sentinel.txt";
        // 文字列としてhookへ渡すだけの架空パス。特定の開発環境のパスに依存させない。
        let exe = r"D:\example\build\publish\prunlet.exe";
        let config = r"C:\Users\example\.local\Prunlet\config.json";
        let json = r"D:\example\hook\hook-paths.json";
        let here = "$script = @'\nRemove-Item -LiteralPath \"<FILE>\"\n$y = Remove-Item -LiteralPath \"<FILE>\"\n'@\nWrite-Output $script";
        let canonical =
            format!(r#"cmd.exe /d /c "{exe} --config {config} delete --paths-file {json}""#);
        let canonical_msys =
            format!(r#"cmd.exe //d //c "{exe} --config {config} delete --paths-file {json}""#);
        let call = format!(
            r#"cmd.exe /d /c call "{exe}" --config "{config}" delete --paths-file "{json}""#
        );
        let call_msys = format!(
            r#"cmd.exe //d //c call "{exe}" --config "{config}" delete --paths-file "{json}""#
        );
        // (コマンド, shell, exec_commandでの通過, Bashでの通過)
        let cases: Vec<(&str, Option<&str>, bool, bool)> = vec![
            (r#"cmd.exe //c del "<FILE>""#, Some("cmd.exe"), false, false),
            (
                r#"cmd.exe //d //c del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"cmd.exe //d //c del "<FILE>""#,
                Some("pwsh"),
                false,
                false,
            ),
            (r#"cmd /R del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /cdel "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /d/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /D/Q/C "del <FILE>""#, Some("cmd.exe"), false, false),
            (
                r#"cmd /e:on /v:off /t:0a /s /c del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r"cmd.exe //d //c reg delete HKCU\Software\PrunletHookProbe /f",
                None,
                false,
                false,
            ),
            ("cmd /z /c echo ok", Some("cmd.exe"), false, false),
            ("cmd stray /c echo ok", Some("cmd.exe"), false, false),
            ("cmd /?", Some("cmd.exe"), true, true),
            (
                r"cmd.exe //d //c reg query HKCU\Software\PrunletHookProbe",
                Some("cmd.exe"),
                true,
                true,
            ),
            (
                r#"cmd.exe //d //c echo del "<FILE>""#,
                Some("cmd.exe"),
                true,
                true,
            ),
            (&canonical, Some("cmd.exe"), true, true),
            (&canonical, None, true, true),
            (&canonical_msys, None, true, true),
            (&call, Some("cmd.exe"), true, true),
            (&call_msys, None, true, true),
            (
                "cmd /c cmd /c cmd /c cmd /c echo ok",
                Some("cmd.exe"),
                true,
                true,
            ),
            (
                "cmd /c cmd /c cmd /c cmd /c cmd /c echo ok",
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                "pwsh -c pwsh -c pwsh -c pwsh -c pwsh -c Write-Output ok",
                Some("pwsh"),
                false,
                false,
            ),
            (
                r#"for %i in ("<FILE>") do del %i"#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"for %i in ("<FILE>") do if exist %i del %i"#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"if exist "<FILE>" (echo keep) else del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r"if 1==2 (echo keep) else reg delete HKCU\Software\PrunletHookProbe /f",
                Some("cmd.exe"),
                false,
                false,
            ),
            ("for %i in (a) do echo del %i", Some("cmd.exe"), true, false),
            (
                "if 1==1 (echo keep) else echo del",
                Some("cmd.exe"),
                true,
                true,
            ),
            (
                r#"$x = Remove-Item -LiteralPath "<FILE>""#,
                Some("pwsh"),
                false,
                false,
            ),
            (
                r#"$x=Remove-Item -LiteralPath "<FILE>""#,
                Some("pwsh"),
                false,
                false,
            ),
            (
                r#"return Remove-Item -LiteralPath "<FILE>""#,
                Some("pwsh"),
                false,
                false,
            ),
            (
                r#". Remove-Item -LiteralPath "<FILE>""#,
                Some("pwsh"),
                false,
                false,
            ),
            (
                r#"pwsh -Command "$x = Remove-Item -LiteralPath <FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"$x = 'Remove-Item -LiteralPath "<FILE>"'"#,
                Some("pwsh"),
                true,
                true,
            ),
            (here, Some("pwsh"), true, false),
            (
                r#"$hits = Select-String -Pattern 'Remove-Item' -Path "<FILE>""#,
                Some("pwsh"),
                true,
                true,
            ),
            (
                r#"rg -n '$x = Remove-Item' "<FILE>""#,
                Some("pwsh"),
                true,
                true,
            ),
            (r". .\env.ps1", Some("pwsh"), true, true),
            // 語の途中の本文switch（cmd.exeはコマンドライン全体から/Cを探す）。
            (r#"cmd x/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd "x"/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd ,/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /d x/c del "<FILE>""#, Some("cmd.exe"), false, false),
            // cmd.exeは`;` `,` `=`を空白相当の区切りとして扱い、実行名も最初の`/ , ; =`で打ち切る。
            // `;`で割れた`cmd`wrapper、実行名直結の`/c`、実行名・本文先頭の`, =`はいずれも本文を実行する。
            (r#"cmd;/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd ;/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /d;/c del "<FILE>""#, Some("cmd.exe"), false, false),
            ("cmd\t;/c del \"<FILE>\"", Some("cmd.exe"), false, false),
            (r#"cmd,/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd=/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd.exe/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (
                r#"C:/Windows/System32/cmd.exe/c del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"C:\Windows\System32\cmd.exe/c del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (r#"call cmd/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (
                r#"cmd /c cmd;/c del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (r#"cmd /c=del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /c,del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#",del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"=del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /c ,del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd =/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"cmd /d/q=/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (
                r#"cmd /e:on,/c del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (r#"cmd /c;del "<FILE>""#, Some("cmd.exe"), false, false),
            ("cmd\t/c del \"<FILE>\"", Some("cmd.exe"), false, false),
            (r#"cmd ';/c' del "<FILE>""#, Some("pwsh"), false, false),
            // 単純名の削除命令に直結した`/ , =`も、cmd.exeは実行名の終端として読む。
            (r#"rd/s/q "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"RD/S/Q "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"del/q "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"del,"<FILE>""#, Some("cmd.exe"), false, false),
            (r#"rd=/s "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"erase/f "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"rmdir/s "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"call del/q "<FILE>""#, Some("cmd.exe"), false, false),
            (
                r#"if exist "<FILE>" del/q "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (r#"cmd /c rd/s/q "<FILE>""#, Some("cmd.exe"), false, false),
            (
                r"reg,delete HKCU\Software\PrunletHookProbe /f",
                Some("cmd.exe"),
                false,
                false,
            ),
            // 経路形式（`:` `\`を含む・`.` `/`始まり）の実行名は`/`を経路区切りとして読み、
            // 最後の要素で判定する。`C:/tools/del/x`は外部プログラム`x`の実行とみなして通す。
            (r"C:/tools/del/x", Some("cmd.exe"), true, true),
            ("tools/del/x", Some("cmd.exe"), true, true),
            ("echo del/q x", Some("cmd.exe"), true, true),
            ("dir/b", Some("cmd.exe"), true, true),
            ("reg/?", Some("cmd.exe"), true, true),
            // 誤拒否してはいけない形。`=` `,` `;` `/`は実行名とcmdのswitch位置以外では通常の文字として扱う。
            (r#"cmd /k echo hi/there"#, Some("cmd.exe"), true, true),
            ("cmd /c echo a;b", Some("cmd.exe"), true, true),
            ("echo ok;cmd /c echo hi", Some("cmd.exe"), true, true),
            ("set X=1", Some("cmd.exe"), true, true),
            ("if a==b echo x", Some("cmd.exe"), true, true),
            ("echo a;b", Some("cmd.exe"), true, true),
            ("echo a/b", Some("cmd.exe"), true, true),
            ("echo ,del x", Some("cmd.exe"), true, true),
            (r"dir C:/Windows /b", Some("cmd.exe"), true, true),
            (
                r"reg query HKCU\Software\PrunletHookProbe",
                Some("cmd.exe"),
                true,
                true,
            ),
            // 制御語（call・do・else）や`if`の条件に`, =`で直結した実行名も、cmd.exeは実行する。
            // `=`での打切りはshellがcmdと明示された場合だけ無条件に行い、shell不明（Bash）では
            // POSIX代入と区別できないため`=`の直後が`/`の場合に限る（`call=del`はBashでは通す）。
            (r#"call,del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"call=del "<FILE>""#, Some("cmd.exe"), false, true),
            (r#"call,cmd/c del "<FILE>""#, Some("cmd.exe"), false, false),
            (r#"call,"del" "<FILE>""#, Some("cmd.exe"), false, false),
            (
                r#"if exist "<FILE>",del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r"if exist <FILE>,del/q,<FILE>",
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"if not exist "<FILE>.x",del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"for %i in ("<FILE>") do,del %i"#,
                Some("cmd.exe"),
                false,
                false,
            ),
            // Bashでは`do=del`をCMD候補では通すが、POSIX候補の`for`構文検査で拒否される。
            (
                r#"for %i in ("<FILE>") do=del %i"#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"if 1==2 (echo no) else,del "<FILE>""#,
                Some("cmd.exe"),
                false,
                false,
            ),
            (
                r#"if 1==2 (echo no) else=del "<FILE>""#,
                Some("cmd.exe"),
                false,
                true,
            ),
            (r#"cmd=/c del "<FILE>""#, Some("cmd.exe"), false, false),
            // shell不明（Bash）でのPOSIX代入は削除命令とみなさない。
            ("rm=1; echo ok", None, true, true),
            ("ri=0", None, true, true),
            ("rd=foo", None, true, true),
            ("rp=$(realpath x)", None, true, true),
            ("cmd=1; echo ok", None, true, true),
            // 引用内の`,`や、削除命令以外への直結は通す。
            (r#"if exist "a,b.txt" echo ok"#, Some("cmd.exe"), true, true),
            ("if exist a,b echo ok", Some("cmd.exe"), true, true),
            ("type a.txt,b.txt", Some("cmd.exe"), true, true),
            ("call,echo ok", Some("cmd.exe"), true, true),
            ("for %i in (a;b) do echo %i", Some("cmd.exe"), true, false),
            ("set PATH=C:\\x;%PATH%", Some("cmd.exe"), true, true),
        ];
        for (command, shell, pass, bash_pass) in cases {
            let command = command.replace("<FILE>", file);
            let actual = reason(&command, "exec_command", shell);
            assert_eq!(
                actual.is_none(),
                pass,
                "exec_command {shell:?}: {command}: {actual:?}"
            );
            if cfg!(windows) {
                let actual = reason(&command, "Bash", None);
                assert_eq!(actual.is_none(), bash_pass, "Bash: {command}: {actual:?}");
            }
        }
    }

    #[test]
    fn cmd_switch_parser_separates_switches_and_attached_body() {
        let words = |s: &str| tokens(s, Mode::Cmd, false).unwrap();
        assert_eq!(
            cmd_switches(&words("cmd /d/cdel x"), 1),
            CmdSwitches::Body {
                token: 1,
                attached: "del".into()
            }
        );
        assert_eq!(
            cmd_switches(&words("cmd //D //Q //E:OFF //K"), 1),
            CmdSwitches::Body {
                token: 4,
                attached: String::new()
            }
        );
        assert_eq!(cmd_switches(&words("cmd /d /q"), 1), CmdSwitches::NoBody);
        assert_eq!(
            cmd_switches(&words("cmd /w /c x"), 1),
            CmdSwitches::Unknown("/w".into())
        );
        assert_eq!(
            cmd_switches(&words("cmd x /c y"), 1),
            CmdSwitches::Unknown("x".into())
        );
        // 語の途中にある本文switchもcmd.exeは解釈するため、解析せず拒否側へ倒す。
        for command in ["cmd x/c y", "cmd ,/c y", "cmd /d x/c y"] {
            assert!(
                matches!(cmd_switches(&words(command), 1), CmdSwitches::Unknown(_)),
                "{command}"
            );
        }
    }

    #[test]
    fn cmd_executable_name_is_cut_at_the_first_delimiter() {
        // 実行名が`cmd`/`cmd.exe`で直後に区切りが直結した形だけを分解し、区切り以降を返す。
        for (text, tail) in [
            ("cmd/c", "/c"),
            ("cmd.exe/c", "/c"),
            ("CMD.EXE/C", "/C"),
            ("cmd,/c", ",/c"),
            ("cmd=/c", "=/c"),
            ("cmd;/c", ";/c"),
            ("cmd/cdel", "/cdel"),
            (r"C:\Windows\System32\cmd.exe/c", "/c"),
            ("C:/Windows/System32/cmd.exe/c", "/c"),
        ] {
            assert_eq!(cmd_glued_tail(text, true), Some(tail), "{text}");
        }
        // 直結のない通常の実行名・経路・他のコマンド名は分解しない。
        for text in [
            "cmd",
            "cmd.exe",
            r"C:\Windows\System32\cmd.exe",
            "C:/Windows/System32/cmd.exe",
            "/c/Windows/System32/cmd.exe",
            "echo",
            "echo/c",
            "x/cmd",
            "cmdx/c",
            "C:/Windows",
            "",
        ] {
            assert_eq!(cmd_glued_tail(text, true), None, "{text}");
        }
        // 先頭の`@ , ; =`はCMD規則だけで落とす。POSIX・PowerShell規則の判定は変えない。
        assert_eq!(exec_name(",del", Some(Mode::Cmd)).name, "del");
        assert_eq!(exec_name("@=,del", Some(Mode::Cmd)).name, "del");
        assert_eq!(exec_name("cmd/c", Some(Mode::Cmd)).name, "cmd");
        assert_eq!(exec_name("cmd.exe/c", Some(Mode::Cmd)).glued, Some("/c"));
        assert_eq!(exec_name(",del", Some(Mode::Posix)).name, ",del");
        assert_eq!(exec_name("=del", Some(Mode::PowerShell)).name, "=del");
        assert_eq!(exec_name("@del", Some(Mode::Posix)).name, "del");
        assert_eq!(exec_name("cmd/c", Some(Mode::Posix)).glued, None);
        // 単純名の削除命令・regは最初の`/ , ; =`で切る。表示名も切った名前にする。
        for (text, name, shown, glued) in [
            ("rd/s/q", "rd", "rd", "/s/q"),
            ("RD/S/Q", "rd", "RD", "/S/Q"),
            ("del,x", "del", "del", ",x"),
            ("rd=/s", "rd", "rd", "=/s"),
            ("erase/f", "erase", "erase", "/f"),
            ("rmdir/s", "rmdir", "rmdir", "/s"),
            ("@,del/q", "del", "del", "/q"),
            ("reg,delete", "reg", "reg", ",delete"),
        ] {
            let found = exec_name(text, Some(Mode::Cmd));
            assert_eq!(
                (found.name.as_str(), found.shown, found.glued),
                (name, shown, Some(glued)),
                "{text}"
            );
        }
        // 経路形式と、削除命令以外の単純名は従来の`leaf()`判定のまま（`x/del`の既存拒否も保つ）。
        for (text, name) in [
            ("C:/tools/del/x", "x"),
            (r"C:\tools\del/x", "x"),
            ("./del", "del"),
            ("/c/bin/rd/x", "x"),
            ("tools/del/x", "x"),
            ("x/del", "del"),
            ("dir/b", "b"),
        ] {
            let found = exec_name(text, Some(Mode::Cmd));
            assert_eq!((found.name.as_str(), found.glued), (name, None), "{text}");
        }
        // 制御語（call・do・else）も切った名前と直結した残りを返す。
        for (text, name, glued) in [
            ("call,del", "call", ",del"),
            ("call=del", "call", "=del"),
            ("DO,del", "do", ",del"),
            ("else=del", "else", "=del"),
        ] {
            let found = exec_name(text, Some(Mode::Cmd));
            assert_eq!(
                (found.name.as_str(), found.glued),
                (name, Some(glued)),
                "{text}"
            );
        }
        // shell不明の候補判定では、`=`は直後（`, ; =`を除く）が`/`の場合だけ打ち切る。
        for (text, name, glued) in [
            ("rm=1", "rm=1", None),
            ("rd=foo", "rd=foo", None),
            ("call=del", "call=del", None),
            ("rd=/s", "rd", Some("=/s")),
            ("rd=,/s", "rd", Some("=,/s")),
            ("del,x", "del", Some(",x")),
        ] {
            let found = exec_name_in(text, Some(Mode::Cmd), false);
            assert_eq!((found.name.as_str(), found.glued), (name, glued), "{text}");
        }
        assert_eq!(cmd_glued_tail("cmd=1", false), None);
        assert_eq!(cmd_glued_tail("cmd=/c", false), Some("=/c"));
        assert_eq!(cmd_glued_tail("cmd=1", true), Some("=1"));
        // POSIX・PowerShell規則では切らない。
        assert_eq!(exec_name("rd/s/q", Some(Mode::Posix)).name, "q");
        assert_eq!(exec_name("del,x", Some(Mode::PowerShell)).name, "del,x");
    }

    #[test]
    fn cmd_semicolon_boundary_is_marked_only_in_cmd_rules() {
        let marks = |mode: Mode, s: &str| -> Vec<String> {
            tokens(s, mode, false)
                .unwrap()
                .into_iter()
                .filter(|t| t.boundary)
                .map(|t| t.text)
                .collect()
        };
        assert_eq!(marks(Mode::Cmd, "cmd;/c x & y"), [";", ""]);
        assert_eq!(marks(Mode::Posix, "cmd;/c x"), [""]);
        assert_eq!(marks(Mode::PowerShell, "cmd;/c x"), [""]);
        // 引用された`;`は境界ではない。
        assert!(marks(Mode::Cmd, r#"cmd "a;b""#).is_empty());
    }

    #[test]
    fn cmd_wrapper_split_by_semicolon_is_rejected_only_without_a_body() {
        // 本文switchを持たない`cmd`の直後の`;`は拒否する。理由はswitch解析不能と同じ。
        for command in [
            "cmd;/c del x",
            "cmd /d;/c del x",
            "cmd ;/c echo ok",
            "cmd;",
            "cmd /?;",
        ] {
            let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
            assert!(
                reason.contains("unsupported CMD wrapper switch"),
                "{command}: {reason}"
            );
        }
        // 本文switchが`;`より前にあれば従来どおり本文を検査し、無害な本文は通す。
        for command in [
            "cmd /c echo a;b",
            "cmd /d /c echo a;b",
            "echo a; cmd",
            "echo a;cmd /c echo b",
        ] {
            assert!(!denied(command, "cmd.exe"), "{command}");
        }
        // 先頭の`,`や`=`を付けた削除命令は、記号を落とした名前で報告する。
        for command in [",del x", "=del x", "cmd /c,del x", "cmd /c=del x"] {
            let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
            assert!(
                reason.contains(r#"detected token "del""#),
                "{command}: {reason}"
            );
        }
        for (command, token) in [
            ("rd/s/q x", "rd"),
            ("RD/S/Q x", "RD"),
            ("erase/f x", "erase"),
            ("del,x", "del"),
        ] {
            let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
            assert!(
                reason.contains(&format!(r#"detected token "{token}""#)),
                "{command}: {reason}"
            );
        }
        let reason_reg =
            reason(r"reg/delete HKCU\x /f", "exec_command", Some("cmd.exe")).expect("reg/delete");
        assert!(
            reason_reg.contains("registry deletion command"),
            "{reason_reg}"
        );
        // CMD以外のshell規則では`;`は通常の文境界で、判定を変えない。
        assert!(!denied("cmd;/c echo ok", "pwsh"));
        if cfg!(windows) {
            // shell不明（Bash）ではCMD規則でも検査するため拒否される。
            assert!(reason("cmd;/c echo ok", "Bash", None).is_some());
        }
    }

    #[test]
    fn cmd_do_and_else_bodies_are_inspected() {
        for command in [
            r"for %i in (a b) do del %i",
            r"for /f %i in ('dir /b') do del %i",
            r"for %i in (a) do if exist %i del %i",
            r"for %i in (a) do DO call del %i",
            r"if exist x (echo a) else del x",
            r"if exist x (echo a) ELSE reg delete HKCU\Software\PrunletHookProbe /f",
            r#"cmd /c "for %i in (a) do del %i""#,
            // `, =`で直結した形と、`do,`のように残りが空の形（次の語が実行名）。
            r"for %i in (a) do,del %i",
            r"for %i in (a) do=del %i",
            r"for %i in (a) do, del %i",
            r"for %i in (a) do,do,call,del %i",
            r"if exist x (echo a) else,del x",
            r"if exist x (echo a) ELSE=reg delete HKCU\Software\PrunletHookProbe /f",
            r"if exist x,del x",
            r"if /i not exist x,del x",
            r"call,cmd/c del x",
        ] {
            assert!(denied(command, "cmd.exe"), "{command}");
        }
        for command in [
            r"for %i in (a) do echo del %i",
            r"if 1==1 (echo a) else echo del",
            "do",
            "else",
            "do,",
            "call,echo ok",
        ] {
            assert!(!denied(command, "cmd.exe"), "{command}");
        }
        // 上限以内の直結連鎖は削除命令として報告し、上限を超える連鎖は検査不能として拒否する。
        let within = format!("{}del x", "do,".repeat(CMD_GLUED_PREFIX_LIMIT));
        let found = reason(&within, "exec_command", Some("cmd.exe")).expect("within");
        assert!(found.contains(r#"detected token "del""#), "{found}");
        // 入力上限に近い1語の連鎖でも、評価し直す回数を抑えて線形時間で終わる。
        let long = format!("{}echo x", "do,".repeat(300_000));
        let found = reason(&long, "exec_command", Some("cmd.exe")).expect("long");
        assert!(
            found.contains("too many CMD control words joined by delimiters"),
            "{found}"
        );
        // shell不明時の`=`判定も、`x=,=,=,…`のような語で`=`ごとに前方走査しない。
        let equals = format!("x{}", "=,".repeat(400_000));
        assert!(cmd_glued_tail(&equals, false).is_none());
        assert_eq!(exec_name_in(&equals, Some(Mode::Cmd), false).glued, None);
        let equals_cmd = format!("cmd{}", "=,".repeat(400_000));
        assert!(cmd_glued_tail(&equals_cmd, false).is_none());
    }

    #[test]
    fn non_strict_powershell_assignments_and_dot_calls_are_inspected() {
        for command in [
            r#"$x = Remove-Item -LiteralPath "C:\fixture\file.txt""#,
            r"$x=Remove-Item C:\fixture\file.txt",
            r"[string]$x = rm C:\fixture\file.txt",
            r"$x += del C:\fixture\file.txt",
            r"return Remove-Item C:\fixture\file.txt",
            r"foreach ($f in Remove-Item C:\fixture\file.txt) { $f }",
            r"$x = reg.exe delete HKCU\Software\PrunletHookProbe /f",
            r"$o.'Length' = Remove-Item C:\fixture\file.txt",
            r"$x = cmd //c del C:\fixture\file.txt",
            r". Remove-Item C:\fixture\file.txt",
            r". rm C:\fixture\file.txt",
        ] {
            assert!(denied(command, "pwsh"), "{command}");
        }
        assert!(denied(
            r#"pwsh -Command "$x = Remove-Item C:\fixture\file.txt""#,
            "cmd.exe"
        ));
        // 検索文字列・引用・ヒアストリング内のdataは誤拒否しない。
        for command in [
            r"$x = 'Remove-Item C:\fixture\file.txt'",
            r#"$pattern = "rm -rf""#,
            "$script = @'\nRemove-Item C:\\fixture\\file.txt\n$y = rm x\n'@\nWrite-Output $script",
            "$script=@'\n. Remove-Item x\n'@",
            r"rg -n '$x = Remove-Item' .",
            r"$hits = Select-String -Pattern 'Remove-Item' -Path a.txt",
            r". .\env.ps1",
            r"$o.'Length' = 5",
            r"$files = Get-ChildItem; foreach ($f in $files) { $f.Name }",
            r"$x -= 1",
        ] {
            assert!(!denied(command, "pwsh"), "{command}");
        }
        assert!(!denied(
            r#"pwsh -Command "$x = 'Remove-Item C:\fixture\file.txt'""#,
            "cmd.exe"
        ));
    }

    #[test]
    fn depth_limit_is_fail_closed_for_every_shell() {
        let chain =
            |prefix: &str, count: usize, tail: &str| format!("{}{tail}", prefix.repeat(count));
        for (prefix, shell) in [
            ("cmd /c ", "cmd.exe"),
            ("pwsh -c ", "pwsh"),
            ("cmd /c ", "pwsh"),
        ] {
            assert!(
                !denied(&chain(prefix, 4, "echo ok"), shell),
                "{shell}: 4 levels"
            );
            let reason = reason(&chain(prefix, 5, "echo ok"), "exec_command", Some(shell))
                .expect("5 levels must be denied");
            assert!(
                reason.contains("inspection depth limit exceeded"),
                "{reason}"
            );
        }
    }

    #[test]
    fn noncanonical_scan_is_linear_and_reports_the_first_match() {
        let detection = |command: &str| {
            let mut inspector = Inspector::default();
            let found = inspector
                .contains(command, 0, Some(Mode::Posix), false)
                .unwrap();
            found.then(|| inspector.detection.unwrap())
        };
        // 最初のpwshは-Fileで停止し、2つ目のpwshの直後の-encを検出する。
        let found = detection("time pwsh -File x pwsh -enc AAAA").unwrap();
        assert!(found.contains(r#"detected token "-enc""#), "{found}");
        // 複数該当時は最も前の実行名に対応するtokenを報告する（従来の前方走査と同じ）。
        let found = detection("time pwsh -enc AAAA pwsh -ec BBBB").unwrap();
        assert!(found.contains(r#"detected token "-enc""#), "{found}");
        // -Commandより後ろのencoded optionは本文側の語として扱い、ここでは検出しない。
        assert!(detection("time pwsh -Command Write-Output -enc").is_none());
        // 実行名が大量に並ぶ入力でも1回の走査で完了する。
        let many = format!("time {}-enc AAAA", "pwsh ".repeat(20_000));
        let found = detection(&many).unwrap();
        assert!(found.contains(r#"detected token "-enc""#), "{found}");
    }

    #[test]
    fn standalone_encoded_detection_has_no_candidate_note() {
        if !cfg!(windows) {
            return;
        }
        let encode = |script: &str| {
            let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
            STANDARD.encode(bytes)
        };
        let data = encode(r"Remove-Item -LiteralPath C:\fixture\file.txt");
        let confirmed = reason(
            &format!("pwsh -NoProfile -EncodedCommand {data}"),
            "Bash",
            None,
        )
        .expect("standalone encoded delete must be denied");
        assert!(
            confirmed.contains("interpretation=PowerShell"),
            "{confirmed}"
        );
        assert!(
            !confirmed.contains("candidate interpretation"),
            "{confirmed}"
        );
        assert!(!confirmed.contains("UTF-16LE Base64"), "{confirmed}");
        // 単独形式でない呼出しは従来どおり候補注記と変換案内を付ける。
        let candidate = reason(&format!("pwsh -NoProfile -e {data}"), "Bash", None)
            .expect("noncanonical encoded command must be denied");
        assert!(
            candidate.contains("candidate interpretation"),
            "{candidate}"
        );
    }

    /// 共通指示の管理者起動（名前付きの静的cmd.exe＋固定形の単一引用引数）だけを許可し、
    /// 本文の削除・入れ子shell・メタ文字による文の分割・位置引数や既定値による注入は拒否する。
    #[test]
    fn encoded_admin_cmd_start_process_accepts_only_the_fixed_form() {
        if !cfg!(windows) {
            return;
        }
        let encode = |script: &str| {
            let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
            format!("pwsh -NoProfile -EncodedCommand {}", STANDARD.encode(bytes))
        };
        // reason()がhookへ渡す配置済みCLI・設定（C:\fixture\…）と同じパスだけが許可される。
        let cli = r#""C:\fixture\prunlet.exe" --config "C:\fixture\config.json""#;
        let admin_registry = format!(
            r#"Start-Process -FilePath cmd.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '/d /c "{cli} registry-delete --view 64 --recursive -- HKEY_CURRENT_USER\Software\PrunletE2E\x > D:\tmp\out.json 2>&1"'"#
        );
        for allowed in [
            admin_registry.clone(),
            format!(
                r#"New-Item -ItemType Directory -Path D:\tmp\x -Force | Out-Null; {admin_registry}"#
            ),
            format!(r#"$p = {admin_registry}"#),
            format!(
                r#"Start-Process -ArgumentList '/d /c "{cli} delete --paths-file D:\tmp\x\list.json"' -Verb RunAs -PassThru -FilePath cmd"#
            ),
            format!(
                r#"saps -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList '/d /c "{cli} delete --paths-file D:\tmp\x\list.json"' -Verb RunAs"#
            ),
            // CLI・設定パスのASCII大文字小文字の違いは同じ配置として扱う。
            r#"Start-Process -FilePath cmd.exe -ArgumentList '/d /c ""c:\FIXTURE\Prunlet.exe" --config "C:\fixture\CONFIG.json" delete --paths-file D:\a.json"'"#.to_owned(),
        ] {
            assert_eq!(reason(&encode(&allowed), "Bash", None), None, "{allowed}");
        }
        let body = |arguments: &str| {
            format!("Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '{arguments}'")
        };
        let mut denied = vec![
            // 本文の削除・入れ子shell・CMDのstart・実行体の差し替え。
            body(r"/d /c del C:\fixture\file.txt"),
            body(r"/d /c rd /s /q C:\fixture"),
            body(r"/d /c reg delete HKCU\Software\X /f"),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete" & del C:\fixture"#),
            // 配置済みCLI・設定以外の実行体や設定（同名の任意exeを含む）は昇格させない。
            body(r#"/d /c ""C:\x\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\x\config.json" delete --paths-file C:\a.json""#),
            body(r#"/d /c ""C:\fixture\..\x\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json""#),
            // 出力リダイレクト先は.jsonだけ（任意ファイルを管理者権限で切り詰めさせない）。ADS指定も拒否する。
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\Windows\System32\drivers\etc\hosts 2>&1""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\o.json:x.json 2>&1""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\o.json""#),
            // ASCII以外の大文字小文字畳み込み（ケルビン記号・長いs）で許可文字やパスに一致させない。
            body("/d /c \"\"C:\\fixture\\prunlet.exe\" --config \"C:\\fixture\\config.json\" delete --paths-file C:\\a.j\u{17f}on\""),
            body("/d /c \"\"C:\\fixture\\prunlet.exe\" --config \"C:\\fixture\\config.j\u{17f}on\" delete --paths-file C:\\a.json\""),
            // cmd.exeが実際に解釈する区切り・演算子・引用・展開（検査器との解釈のずれ）。
            body(r"& /d /c del C:\x"),
            body(r"| /d /c del C:\x"),
            body(r"( /d /c del C:\x"),
            body(r") /d /c del C:\x"),
            body(r"/d & /c del C:\x"),
            body("x\n/d /c del C:\\x"),
            body("/d\n/c del C:\\x"),
            body(r#"/d /c "reg" delete HKCU\Software\X /f"#),
            body(r#"/d /c "del" C:\x"#),
            body(r#"/d /c "C:\Windows\System32\cmd.exe" /c del C:\x"#),
            body(r#"/d /c "ver" "& del C:\x""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json" & del C:\x"#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file %ComSpec%""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file ^C:\a.json""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\o.json 2>&1 & del C:\x""#),
            // 位置引数・括弧式・scriptblock・既定値による注入・ArgumentListの省略。
            r"Start-Process cmd.exe ('/d /c del C:\x') -Verb RunAs".to_owned(),
            r"Start-Process cmd.exe {/d /c del C:\x}".to_owned(),
            r"$a='/c del C:\x'; Start-Process cmd.exe ($a)".to_owned(),
            r"Start-Process cmd.exe '/d /c exit 1' -Verb RunAs".to_owned(),
            r"$PSDefaultParameterValues.Add('Start-Process:ArgumentList','/d /c del C:\x'); Start-Process -FilePath cmd.exe -Verb RunAs".to_owned(),
            r"Start-Process -FilePath cmd.exe -Verb RunAs".to_owned(),
            r"Start-Process cmd -Verb RunAs".to_owned(),
            // 起動先がcmd以外・動的、引数が配列・二重引用・変数・連結・ヒアストリングの形。
            r"Start-Process -FilePath pwsh -ArgumentList '-NoProfile'".to_owned(),
            r"Start-Process -FilePath powershell.exe -Verb RunAs".to_owned(),
            r"Start-Process rm".to_owned(),
            r"Start-Process -FilePath $exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/d','/c','del C:\fixture'".to_owned(),
            r#"Start-Process -FilePath cmd.exe -ArgumentList "/d /c $x""#.to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList $arguments".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/d /c'$tail".to_owned(),
            "Start-Process -FilePath cmd.exe -ArgumentList @'\n/d /c dir\n'@".to_owned(),
            // 省略形・colon形・未知や重複の引数・退避文字は受理しない。
            r"Start-Process -File cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -Args '/c dir' -FilePath cmd.exe".to_owned(),
            r"Start-Process -FilePath:cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/c dir' -Credential $c".to_owned(),
            r"Start-Process -FilePath cmd.exe -FilePath cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/c dir' extra".to_owned(),
            r"Start-Process -FilePath cmd.exe. -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath D:\tmp\cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.`exe -ArgumentList '/c dir'".to_owned(),
            // 呼出し演算子での名前指定・Invoke-Expressionは従来どおり拒否する。
            r"& 'Start-Process' rm".to_owned(),
            r#"Invoke-Expression "cmd /c dir""#.to_owned(),
        ];
        // 本文が正規形でも、同じ形の拒否理由が`Start-Process`起点であることを確認するための別名・switch重複。
        denied.push(format!(
            r#"Start-Process -FilePath cmd.exe -Wait -Wait -ArgumentList '/d /c "{cli} delete --paths-file D:\a.json"'"#
        ));
        for command in &denied {
            assert!(
                reason(&encode(command), "Bash", None).is_some(),
                "{command}"
            );
        }
    }

    /// POSIX規則だけで検査した結果（Windowsの候補解釈がPOSIX固有の穴を覆い隠さないようにする）。
    fn posix_denied(command: &str) -> bool {
        let result = Inspector::default().contains(command, 0, Some(Mode::Posix), false);
        result.is_err() || result.unwrap()
    }

    /// 引用終端のヒアドキュメントは、ファイルへの`cat`・インタプリタが受け取る形に限って本文をdataとして読み、
    /// shellへ渡りうる形や本文の後ろの削除命令は従来どおり拒否する。
    #[test]
    fn quoted_heredoc_bodies_are_data_only_for_file_sinks_and_interpreters() {
        for allowed in [
            "cat > /d/tmp/x.js <<'EOF'\nfor (const f of files) { rm(f) }\nrm -rf /tmp/y\nEOF\necho done",
            "mkdir -p /d/tmp/x && cat > /d/tmp/x/a.py <<'EOF'\nfor f in x:\n    pass\nEOF",
            "cat <<\"EOF\" > out.txt\nwhile true; do rm -rf /tmp/y; done\nEOF",
            "cat >> notes.md <<-'EOF'\n\tcase x in *) rm -rf /tmp/y;; esac\n\tEOF",
            "cat > f <<\\EOF\nrm -rf /tmp/y\nEOF",
            "cat > f 2>/dev/null <<'EOF'\nrm -rf /tmp/y\nEOF",
            "python - <<'EOF'\nfor i in range(3):\n    print(i)\nEOF",
            "PYTHONUTF8=1 python3 -I - <<'EOF'\nimport os\nEOF",
            "node <<'EOF'\nfor (const x of []) {}\nEOF",
            "cat > f <<'EOF'\r\nrm -rf /tmp/y\r\nEOF\r\necho ok",
            // 終端のない本文はbashでも入力の終わりまでがdata。
            "cat > f <<'EOF'\nrm -rf /tmp/y\n",
        ] {
            assert!(!posix_denied(allowed), "{allowed:?}");
        }
        for denied in [
            // 本文の後ろの削除命令。
            "cat > /d/tmp/x <<'EOF'\nx\nEOF\nrm -rf /tmp/y",
            "cat > f <<'EOF'\r\nx\r\nEOF\r\nrm -rf /tmp/y",
            // shellへ渡りうる形（パイプ・同じ行の後続文・グループ・/dev出力・動的な出力先・shell自体）。
            "cat <<'EOF' | sh\nrm -rf /tmp/y\nEOF",
            "cat <<'EOF' |\nrm -rf /tmp/y\nEOF",
            "cat > f <<'EOF' && sh f\nrm -rf /tmp/y\nEOF",
            "(\ncat > /tmp/f <<'EOF'\nrm -rf /tmp/y\nEOF\n) | sh",
            "{ cat > /tmp/f <<'EOF'\nrm -rf /tmp/y\nEOF\n} | sh",
            "cat > /dev/stdout <<'EOF'\nrm -rf /tmp/y\nEOF",
            "cat > /proc/self/fd/1 <<'EOF'\nrm -rf /tmp/y\nEOF",
            "cat > \"$out\" <<'EOF'\nrm -rf /tmp/y\nEOF",
            "cat <<'EOF'\nrm -rf /tmp/y\nEOF",
            "bash <<'EOF'\nrm -rf /tmp/y\nEOF",
            "sh -s <<'EOF'\nrm -rf /tmp/y\nEOF",
            "ssh mac <<'EOF'\nrm -rf /tmp/y\nEOF",
            "cat > f <<'EOF' x\nrm -rf /tmp/y\nEOF",
            "python -c 'import sys' <<'EOF' | sh\nrm -rf /tmp/y\nEOF",
            "python -m pip <<'EOF'\nrm -rf /tmp/y\nEOF",
            // 展開される本文（終端語が引用されていない）は文として検査する。
            "cat > f <<EOF\n$(rm -rf /tmp/y)\nEOF",
            "cat > f <<EOF\nrm -rf /tmp/y\nEOF",
            // `<<`を算術・`[[`・逆引用・コマンド置換の中で書いた形は読み飛ばさない。
            "echo $((1<<'X'))\nrm -rf /tmp/y\nX",
            "[[ a << 'X' ]]\nrm -rf /tmp/y\nX",
            "x=$(cat > f <<'EOF'\nrm -rf /tmp/y\nEOF\n)",
            "echo `cat > f <<'EOF'`\nrm -rf /tmp/y\nEOF",
            // here-string（`<<<`）はヒアドキュメントではない。
            "cat > f <<<'EOF'\nrm -rf /tmp/y\nEOF",
        ] {
            assert!(posix_denied(denied), "{denied:?}");
        }
    }

    /// 制御構文の中の代入・`[`・終端語のリダイレクトは実行名ではないため検査不能にしない。削除命令は拒否する。
    #[test]
    fn posix_control_flow_assignments_tests_and_redirections_are_inspected() {
        for allowed in [
            "for f in a b; do n=$(basename $f); echo $n; done",
            "for f in *.rs; do if [ -f \"$f\" ]; then echo $f; fi; done 2>&1 | head",
            "while read f; do echo $f; done < list.txt",
            "for f in *; do\n  b=$(basename $f)\n  [ -f \"$f\" ] && echo $b\ndone",
            "if [[ -n \"$x\" ]]; then echo ok; fi >/dev/null",
            "until [ -s out ]; do sleep 1; done",
        ] {
            assert!(!posix_denied(allowed), "{allowed:?}");
        }
        for denied in [
            "for f in a; do rm -rf $f; done",
            "for f in a; do x=1 rm -rf $f; done",
            "for f in a; do n=$(rm -rf $f); done",
            "for f in a; do n=1 $cmd $f; done",
            "[ -f x ] && rm -rf y",
            "if [ -f x ]; then rm -rf y; fi",
            "for f in a; do echo; done rm -rf y",
            "for f in a; do echo; done > out; rm -rf y",
        ] {
            assert!(posix_denied(denied), "{denied:?}");
        }
    }

    /// EncodedCommand内の`"$(...)"`は参照だけの形、pwshは静的な`.ps1`の`-File`実行だけを許可する。
    #[test]
    fn encoded_property_subexpressions_and_static_pwsh_file_are_allowed() {
        if !cfg!(windows) {
            return;
        }
        let encode = |script: &str| {
            let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
            format!("pwsh -NoProfile -EncodedCommand {}", STANDARD.encode(bytes))
        };
        for allowed in [
            r#"$sw = [Diagnostics.Stopwatch]::StartNew(); "test sec: $($sw.Elapsed.TotalSeconds)""#,
            r#""first: $($r.items[0].Name) of $($r.Count)""#,
            r#""home=$($env:USERPROFILE)""#,
            r"pwsh -NoProfile -File D:\tmp\x\run.ps1 -Label a",
            r"& pwsh -NoProfile -NonInteractive -File 'D:\tmp\x y\run.ps1'; 'exit=' + $LASTEXITCODE",
            r"powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\setup.ps1",
        ] {
            assert_eq!(reason(&encode(allowed), "Bash", None), None, "{allowed}");
        }
        for denied in [
            r#""$(Remove-Item C:\fixture\x)""#,
            r#""$($f.Delete())""#,
            r#""$($x.Prop)$(Remove-Item C:\fixture\x)""#,
            r#""$($x | Remove-Item)""#,
            r#""$($x.Prop; Remove-Item C:\fixture\x)""#,
            r#""$($x[$i])""#,
            r"pwsh -File -",
            r"pwsh -NoProfile -File $s",
            r"pwsh -Command Remove-Item C:\fixture\x",
            r"pwsh -NoProfile -File x.ps1; Remove-Item C:\fixture\x",
            r"pwsh -f x.ps1",
            r"pwsh -File x.txt",
            r"pwsh -ExecutionPolicy $p -File x.ps1",
            r"pwsh -EncodedCommand AAAA -File x.ps1",
            r"cmd /c D:\tmp\x.cmd",
        ] {
            assert!(reason(&encode(denied), "Bash", None).is_some(), "{denied}");
        }
    }

    /// EncodedCommand内で引数として渡す単独の`.`（カレントディレクトリ）はdot-sourcingとみなさず、
    /// コマンド位置の`.`（文頭・区切りやキーワードの直後）は従来どおり拒否する。
    #[test]
    fn encoded_dot_argument_is_not_dot_sourcing() {
        if !cfg!(windows) {
            return;
        }
        let encode = |script: &str| {
            let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
            format!("pwsh -NoProfile -EncodedCommand {}", STANDARD.encode(bytes))
        };
        for allowed in [
            r#"rg -n "net8" -g "*.csproj" . ; dotnet build -c Release"#,
            r"Get-ChildItem -Recurse -Force -Filter config.toml -Path . -Depth 3",
            r#"git grep -n "x" -- . ':!RELEASE_NOTES.md' | Select-Object -First 3"#,
            r"dotnet new console -n EtlSplit -o . --force 2>&1 | Select-Object -Last 1",
            r"git add . 2>&1",
            "Set-Location D:\\x\nrg -n \"catalog\" . ; 'done'",
            r"rg -n 'x' .",
        ] {
            assert_eq!(reason(&encode(allowed), "Bash", None), None, "{allowed}");
        }
        for denied in [
            r". ./build/DevelopmentOutput.ps1; Get-X",
            r". 'D:\tmp\x\inventory.ps1'",
            r"Get-Item x; . ./a.ps1",
            r"Get-Item x | . ./a.ps1",
            r"if ($a) { . ./a.ps1 }",
            r"$x = . ./a.ps1",
            r"return . ./a.ps1",
            "Get-Item x\n. ./a.ps1",
            "Get-Item x `\n. ./a.ps1",
            r"Get-Item x .('./a.ps1')",
            r"Get-Item . ; Remove-Item C:\fixture\x",
        ] {
            assert!(reason(&encode(denied), "Bash", None).is_some(), "{denied}");
        }
    }

    /// 削除命令の拒否は従来どおりCLIの完全な案内を付け、検査不能による拒否は短い案内だけを返す。
    #[test]
    fn inspection_limit_rejections_use_a_short_reason() {
        let deletion = reason(r"Remove-Item -LiteralPath C:\fixture\x", "exec_command", Some("pwsh"))
            .expect("deletion must be denied");
        assert!(deletion.contains("detected token \"Remove-Item\""), "{deletion}");
        assert!(deletion.contains("delete --paths-file"), "{deletion}");
        let limit = reason("case x in a) echo;; esac", "exec_command", Some("bash"))
            .expect("unsupported syntax must be denied");
        assert!(limit.contains("interpretation="), "{limit}");
        assert!(limit.contains("inspection limit, not a detected deletion"), "{limit}");
        assert!(limit.contains("delete --paths-file"), "{limit}");
        assert!(limit.len() < 700, "{} chars: {limit}", limit.len());
        if cfg!(windows) {
            assert!(deletion.len() > limit.len() * 2, "{deletion}");
            let candidate = reason("case x in a) echo;; esac", "Bash", None)
                .expect("unsupported syntax must be denied");
            assert!(candidate.contains("candidate interpretation"), "{candidate}");
            assert!(candidate.len() < 800, "{} chars: {candidate}", candidate.len());
        }
    }

    #[test]
    #[expect(
        clippy::invalid_regex,
        reason = "意図的な不正patternでcompile失敗がpanicせず検査errorになることを確認する"
    )]
    fn invalid_cached_pattern_remains_a_fallible_inspection_error() {
        static INVALID: LazyLock<std::result::Result<Regex, regex::Error>> =
            LazyLock::new(|| Regex::new("["));
        assert!(compiled(&INVALID).is_err());
    }
}
