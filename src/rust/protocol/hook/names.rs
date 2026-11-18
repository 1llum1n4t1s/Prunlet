use super::*;

pub(super) fn leaf(value: &str) -> String {
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
pub(super) fn shell(name: &str) -> Option<Mode> {
    match name {
        "pwsh" | "powershell" => Some(Mode::PowerShell),
        "cmd" => Some(Mode::Cmd),
        "sh" | "bash" | "zsh" if !cfg!(windows) => Some(Mode::Posix),
        _ => None,
    }
}
pub(super) fn wrapper(name: &str) -> bool {
    matches!(name, "cmd" | "bash" | "sh" | "zsh" | "pwsh" | "powershell")
}
pub(super) fn option(value: &str) -> String {
    let name = value.trim_start_matches(['-', '/', '\u{2013}', '\u{2014}', '\u{2015}']);
    if name.len() == value.len() {
        String::new()
    } else {
        name.to_ascii_lowercase()
    }
}
pub(super) fn encoded(v: &str) -> bool {
    let n = option(v);
    !n.is_empty() && (n == "ec" || "encodedcommand".starts_with(&n))
}
pub(super) fn file_option(v: &str) -> bool {
    let n = option(v);
    !n.is_empty() && "file".starts_with(&n)
}
pub(super) fn command_option(v: &str) -> bool {
    let n = option(v);
    !n.is_empty() && ("command".starts_with(&n) || matches!(n.as_str(), "cwa" | "commandwithargs"))
}
/// cmd.exe の起動switchを解析した結果。
#[derive(Debug, PartialEq, Eq)]
pub(super) enum CmdSwitches {
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
pub(super) fn cmd_switches(words: &[Token], start: usize) -> CmdSwitches {
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
pub(super) const CMD_NAME_PREFIX: [char; 4] = ['@', ',', ';', '='];
/// CMD規則で、実行名が`cmd`/`cmd.exe`のまま直後に区切り文字や`/`が直結した語を分解する。
///
/// cmd.exe は実行名を最初の `/` `,` `;` `=` で打ち切るため、`cmd/c del x`・`cmd.exe/c del x`・
/// `cmd,/c del x`・`cmd=/c del x` はいずれも`cmd`＋`/c del x`として実行される。
/// 一方、`leaf()`は`/`で語を切って`c`と判定してしまい、wrapper本文が素通りしていた。
/// `C:/Windows/System32/cmd.exe/c`のように`/`区切りの経路が前置される形も受けるため、
/// パス区切り（`/` `\`）で更新する語頭から区切り文字までを区間として照合する（1回の走査で線形）。
/// 区間が`cmd`・`cmd.exe`なら、その区切り文字以降（区切りを含む）を返す。該当なしは`None`。
pub(super) fn cmd_glued_tail(text: &str, explicit: bool) -> Option<&str> {
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
pub(super) struct ExecName<'a> {
    pub(super) name: String,
    /// 拒否理由に表示する実行名（先頭記号を落とし、`.exe`を除いた元の大小文字の名前）。
    pub(super) shown: &'a str,
    pub(super) glued: Option<&'a str>,
}
/// 実行名の位置で削除命令とみなす名前（POSIX以外の規則）。`Inspector::command`の判定と同じ集合。
pub(super) fn non_posix_delete_name(name: &str) -> bool {
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
pub(super) fn cmd_prefix_word(name: &str) -> bool {
    matches!(name, "call" | "do" | "else")
}
/// 1語の中で区切りにより直結した制御語（`do,do,call,del`等）を順に剥がす回数の上限。
/// 実用の命令では数個で足りる。超えた入力は検査せず拒否し、計算量を入力長に対して線形に保つ。
pub(super) const CMD_GLUED_PREFIX_LIMIT: usize = 32;
/// 語の実行名を求める。CMD規則だけ、先頭の`@ , ; =`を落とし、`cmd`直結の残りを分離する。
/// 単純名が最初の`/ , ; =`で切れて削除命令・`reg`・`call`・`do`・`else`になる場合は、
/// その名前と残り（区切りを含む）を返す。
/// POSIX・PowerShell規則では従来どおり先頭の`@`だけを落として`leaf()`で判定する。
/// shellがcmdと明示された前提で判定する。shell不明の候補判定は`exec_name_in`で`explicit=false`を渡す。
#[cfg(test)]
pub(super) fn exec_name(text: &str, mode: Option<Mode>) -> ExecName<'_> {
    exec_name_in(text, mode, true)
}
/// `exec_name`の本体。`explicit`はCMD規則がshellの明示によるものか（`cmd_cut_at`参照）。
pub(super) fn exec_name_in(text: &str, mode: Option<Mode>, explicit: bool) -> ExecName<'_> {
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
