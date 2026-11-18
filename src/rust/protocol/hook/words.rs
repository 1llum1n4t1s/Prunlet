use super::*;

pub(super) fn if_command(w: &[Token], c: usize) -> Option<usize> {
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
pub(super) fn quote_token(t: &Token, cmd: bool) -> String {
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
pub(super) fn append(t: &mut Token, c: char, previous_equal: &mut bool) {
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
pub(super) fn flush(t: &mut Token, out: &mut Vec<Token>) {
    if !t.text.is_empty() || t.quoted {
        out.push(std::mem::replace(t, Token::new("")));
    }
}
pub(super) fn boundary(out: &mut Vec<Token>) {
    let mut t = Token::new("");
    t.boundary = true;
    out.push(t);
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
pub(super) fn powershell_dot_argument(s: &[char], i: usize, out: &[Token]) -> bool {
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
        || matches!(
            previous,
            '\'' | '"' | '-' | '_' | '.' | '/' | '\\' | ':' | '*'
        ))
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
        "return",
        "throw",
        "exit",
        "in",
        "else",
        "elseif",
        "if",
        "do",
        "try",
        "catch",
        "finally",
        "begin",
        "process",
        "end",
        "param",
        "trap",
        "switch",
        "while",
        "until",
        "foreach",
        "for",
        "data",
        "dynamicparam",
        "filter",
        "function",
        "break",
        "continue",
        "class",
        "enum",
        "using",
        "workflow",
        "parallel",
        "sequence",
        "inlinescript",
    ];
    if !last.quoted && KEYWORDS.iter().any(|k| last.text.eq_ignore_ascii_case(k)) {
        return false;
    }
    true
}
/// 非strictのPowerShell規則で、引用符の種類（単一は`'`、二重は`"`）を返す。PowerShellはスマート引用符
/// （U+2018〜U+201Bを単一、U+201C〜U+201Eを二重）をASCIIの引用符と同じ種類として扱う。
pub(super) fn powershell_quote_kind(c: char) -> Option<char> {
    match c {
        '\'' | '\u{2018}'..='\u{201b}' => Some('\''),
        '"' | '\u{201c}'..='\u{201e}' => Some('"'),
        _ => None,
    }
}
