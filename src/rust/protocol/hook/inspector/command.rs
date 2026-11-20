use super::*;
use std::ops::ControlFlow;

impl Inspector {
    pub(super) fn command(&mut self, w: &[Token], depth: usize, strict: bool) -> Result<bool> {
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
        // 先頭のリダイレクト（`2>/dev/null rm x`・`>out rm x`）は実行名ではない。対象語まで読み飛ばし、
        // 次の語を実行名として検査する（飛ばさないと、リダイレクトの語が実行名になり削除名が隠れる）。
        let redirects = leading_redirect_words(w, self.mode == Some(Mode::PowerShell));
        if redirects > 0 {
            return if redirects >= w.len() {
                Ok(false)
            } else {
                self.command(&w[redirects..], depth, strict)
            };
        }
        if self.mode == Some(Mode::Posix) {
            // bashはブレース展開の後で実行名を決める（`r{m,} x`は`rm r x`、`{unlink,x}`は`unlink x`）。
            // 実行名の位置の語にブレース展開があれば、展開後の名前を推測せず検査不能として拒否する。
            // 代入語（`a={x,y}`）はbashが展開しないため、posix_prefixで剥がしてから後続を同じく判定する。
            if w[0].brace && !compiled(&ASSIGNMENT)?.is_match(&w[0].text) {
                return Ok(self.detected(
                    "POSIX brace expansion in the command name cannot be inspected",
                    &w[0].text,
                ));
            }
            // 添字に空白を含む配列代入（`a[1 + 1]=5 unlink y`）は、bashは添字の中の空白ごと1語の代入として読むが、
            // 字句解析は空白で語を割る。実行名の位置で`名前[`が同じ語の中で閉じないまま終わる形は検査不能として拒否する。
            if posix_unclosed_subscript(&w[0]) {
                return Ok(self.detected(
                    "POSIX array subscript with blanks cannot be inspected",
                    &w[0].text,
                ));
            }
            // 実行名の位置の`${…}`（パラメーター展開）は、空に展開されると語の残りや後続の語が実行名になる
            // （`${X}rm -rf y`・`${X} rm -rf y`）。展開の後ろの残り（空なら後続の語）を実行名として検査する。
            if !compiled(&ASSIGNMENT)?.is_match(&w[0].text)
                && let Some(rest) = posix_parameter_rest(&w[0].text)
            {
                // 語全体が引用なしの展開だけ（`${X}`）なら、空に展開されて次の語が実行名になりうる。
                // 同じ形の語とリダイレクトが続く間は読み飛ばし、最初の残りの語から1回だけ検査する。
                // 語ごとに再帰すると、大量に並んだ入力（`${a} ${a} …`）で再帰の深さと計算量が語数に比例して増える。
                let found = if rest.is_empty() {
                    let empty = posix_empty_parameter_word(&w[0])?;
                    let mut next = 1;
                    if empty {
                        while next < w.len() {
                            let redirects = leading_redirect_words(&w[next..], false);
                            if redirects > 0 {
                                next += redirects;
                            } else if posix_empty_parameter_word(&w[next])? {
                                next += 1;
                            } else {
                                break;
                            }
                        }
                    }
                    empty && next < w.len() && self.command(&w[next..], depth, strict)?
                } else {
                    let mut copy = Vec::with_capacity(w.len());
                    let mut head = Token::new(rest);
                    head.dynamic = rest.contains(['$', '`', '*', '?', '[']);
                    copy.push(head);
                    copy.extend_from_slice(&w[1..]);
                    self.command(&copy, depth, strict)?
                };
                if found {
                    return Ok(true);
                }
            }
            if let Some(result) = self.posix_prefix(w, depth, strict)? {
                return Ok(result);
            }
            if let Some(result) = self.posix_shell(w, depth, strict, Some(Mode::Posix))? {
                return Ok(result);
            }
        }
        let mut i = 0;
        // CMD規則では先頭の`, ; =`も落とし、`cmd`直結の`/c`等を分離する（exec_name参照）。
        let mut current = exec_name_in(&w[0].text, self.mode, self.explicit);
        if self.mode == Some(Mode::Cmd) {
            match self.cmd_exec_position(w, i, current)? {
                ControlFlow::Break(result) => return Ok(result),
                ControlFlow::Continue((next, name)) => {
                    i = next;
                    current = name;
                }
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
            let (words, mut c): (Cow<[Token]>, usize) = if self.mode == Some(Mode::Cmd)
                && w[i + 1..].iter().any(|t| !t.commas.is_empty())
            {
                (Cow::Owned(split_cmd_commas(&w[i + 1..])), 0)
            } else {
                (Cow::Borrowed(w), i + 1)
            };
            if words
                .get(c)
                .is_some_and(|t| t.text.eq_ignore_ascii_case("/i"))
            {
                c += 1;
            }
            if words
                .get(c)
                .is_some_and(|t| t.text.eq_ignore_ascii_case("not"))
            {
                c += 1;
            }
            return match if_command(&words, c) {
                Some(s) => self.command(&words[s..], depth + 1, strict),
                None => Ok(false),
            };
        }
        if !wrapper(&name) {
            return Ok(false);
        }
        // cmd.exeはPowerShell・POSIX shellと異なるswitch規則を持つため専用に解析する。
        if name == "cmd" {
            return self.cmd_wrapper(w, i, glued, depth, strict);
        }
        // 外側の規則（PowerShell・CMD）が何であれ、`sh`・`bash`・`zsh`はPOSIXのoption規則で起動される。
        // 結合flag（`-ec`・`-xc`）や`-c`後の`--`・option（`-c -- "<本文>"`）を、完全一致だけの下の走査が
        // 見落とさないよう先に解析する。検知しなければ従来の走査へ進み、検知範囲は狭めない。
        if matches!(name.as_str(), "sh" | "bash" | "zsh")
            && self.mode != Some(Mode::Posix)
            && let Some(true) = self.posix_shell(&w[i..], depth, strict, shell(&name))?
        {
            return Ok(true);
        }
        // Windows PowerShell 5.1の`powershell`は、名前のない位置引数を`-Command`として実行する
        // （pwsh 7は`-File`扱い）。値を取る既知optionを読み飛ばした最初の位置引数以降を本文として検査する。
        if name == "powershell"
            && let Some(result) = self.powershell_positional(w, i, depth, strict)
        {
            return result;
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
            return self.wrapper_body(&w[j + 1..], depth, shell(&name), strict);
        }
        Ok(false)
    }
    /// wrapperの本文（`-Command`・`-c`・位置引数の後ろの語列）を組み立てて検査する。
    ///
    /// 本文の後ろのリダイレクト（`pwsh -Command "Remove-Item y" > out.txt`・`2>&1`）は外側のshellが処理し、
    /// wrapperへ渡らない。除かずに連結すると引用した本文が1つの実行名として引用し直され、中の削除名を見落とすため、
    /// リダイレクトを除いた語列で検査する。除いた場合は、従来どおり除かない語列でも検査する（検知範囲を狭めない）。
    pub(super) fn wrapper_body(
        &mut self,
        rest: &[Token],
        depth: usize,
        body_mode: Option<Mode>,
        strict: bool,
    ) -> Result<bool> {
        let build = |words: &[Token]| {
            if words.len() == 1 && words[0].quoted {
                words[0].text.clone()
            } else {
                words
                    .iter()
                    .map(|t| quote_token(t, false))
                    .collect::<Vec<_>>()
                    .join(" ")
            }
        };
        let stripped = without_redirect_words(rest, self.mode == Some(Mode::PowerShell));
        if self.contains(&build(&stripped), depth + 1, body_mode, strict)? {
            return Ok(true);
        }
        if stripped.len() != rest.len() {
            return self.contains(&build(rest), depth + 1, body_mode, strict);
        }
        Ok(false)
    }
    /// CMD規則の実行名の位置を、変化がなくなるまで1つのループで整理する。
    /// 戻り値の`Break`は検査の結果が確定した場合、`Continue`は整理後の語の位置と実行名。
    /// 整理の規則は以下のとおり。
    // CMDの実行名の位置を、変化がなくなるまで1つのループで整理する。
    // - リダイレクトと対象語（`call >out del x`・`do >nul del %i`）は実行名ではないので読み飛ばす。
    // - 接頭辞の記号だけの語（`@ del x`・`, del x`・`@>nul del x`の`@`）は実行名ではないので読み飛ばす。
    // - `for ... do <cmd>`・`... else <cmd>`の`do`/`else`と`call`を剥がし、後続を実行名として読む
    //   （字句解析で括弧は文の境界になるため、先頭に残った制御語を剥がす）。
    // `do,del %i`・`else=del x`・`call,del x`のように区切りで直結した残りも、cmd.exeは
    // 次の実行名として実行するため、同じ語の位置のまま残りを評価し直す（残りは`w`を借用するだけで複製しない）。
    // 再帰でなくループで剥がし、大量に並んだ入力でも深さや計算量を増やさない。語を進める処理は語数で、
    // 同じ語の中で直結した残りを評価し直す処理は`CMD_GLUED_PREFIX_LIMIT`で回数が抑えられる。
    // POSIXの制御語はposix_prefixが別に扱うため、ここではCMD規則に限定する。
    fn cmd_exec_position<'a>(
        &mut self,
        w: &'a [Token],
        mut i: usize,
        mut current: ExecName<'a>,
    ) -> Result<ControlFlow<bool, (usize, ExecName<'a>)>> {
        // いま実行名として評価している文字列（語全体か、制御語に直結した残り）。
        let mut text = w[0].text.as_str();
        // `text`が語全体か（制御語に直結した残りでないか）。リダイレクトは語単位でだけ読み飛ばす。
        let mut whole = true;
        // 同じ語の中で直結した残りを評価し直した回数。各評価は残りの長さに比例するため、
        // `do,do,do,…`のような1語の連鎖で計算量が二乗にならないよう上限を設け、超えたら拒否する。
        let mut glued_steps = 0usize;
        loop {
            // 次の語へ進む語数（0なら今の位置で制御語を判定する）。
            let skip = if whole && leading_redirect_words(&w[i..i + 1], false) > 0 {
                leading_redirect_words(&w[i..], false)
            } else if (!whole || !w[i].quoted)
                && text.trim_start_matches(CMD_NAME_PREFIX).is_empty()
            {
                1
            } else {
                let control = match current.glued {
                    // 区切りで切れた名前（cmd_prefix_word）。語の引用の有無は問わない（`call,"del" x`）。
                    Some(_) => cmd_prefix_word(&current.name),
                    // 引用されていない語全体が`do`/`else`/`call`（先頭の`@ , ; =`は落として比べる）。
                    // 経路形式（`x/do`）や引用された`"do"`は従来どおり制御語とみなさない。
                    None => {
                        let bare = text.trim_start_matches(CMD_NAME_PREFIX);
                        !w[i].quoted
                            && (bare.eq_ignore_ascii_case("do")
                                || bare.eq_ignore_ascii_case("else")
                                || bare.eq_ignore_ascii_case("call"))
                    }
                };
                if !control {
                    break;
                }
                let rest = current
                    .glued
                    .map(|tail| tail.trim_start_matches([',', ';', '=']))
                    .filter(|tail| !tail.is_empty());
                if let Some(rest) = rest {
                    glued_steps += 1;
                    if glued_steps > CMD_GLUED_PREFIX_LIMIT {
                        return Ok(ControlFlow::Break(self.detected(
                            "too many CMD control words joined by delimiters cannot be inspected",
                            &current.name,
                        )));
                    }
                    text = rest;
                    whole = false;
                    current = exec_name_in(text, self.mode, self.explicit);
                    continue;
                }
                1
            };
            i += skip;
            if i >= w.len() {
                return Ok(ControlFlow::Break(false));
            }
            text = &w[i].text;
            whole = true;
            current = exec_name_in(text, self.mode, self.explicit);
        }
        Ok(ControlFlow::Continue((i, current)))
    }
    /// cmd.exeはPowerShell・POSIX shellと異なるswitch規則を持つため、専用に解析して本文を再検査する。
    /// `glued`は実行名に直結していた残り、`i`は実行名の語の位置。
    fn cmd_wrapper(
        &mut self,
        w: &[Token],
        i: usize,
        glued: Option<&str>,
        depth: usize,
        strict: bool,
    ) -> Result<bool> {
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
        match cmd_switches(w, start) {
            CmdSwitches::NoBody => {
                // cmd.exeでは`;`は引数の区切りなので、本文switchを持たない`cmd`の直後の`;`は
                // 後続を引数として受ける（`cmd /d;/c del x`）。字句解析で割れた後続を見落とさない。
                if self.cmd_semicolon && self.mode == Some(Mode::Cmd) {
                    Ok(self.detected("unsupported CMD wrapper switch cannot be inspected", ";"))
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
                if self.contains(&body, depth + 1, Some(Mode::Cmd), strict)? {
                    return Ok(true);
                }
                // cmd.exeは本文が`"`で始まると、`/s`なし・引用符がちょうど2つ・間に特殊文字なし・空白あり・
                // 引用内が実行ファイル名の全てを満たす場合を除き、最初の`"`と最後の`"`を外して実行する
                // （`cmd /c "del x" y`は`del x y`）。実行ファイルの有無は判定できないため、外した形も同じ深さで
                // 追加検査し、どちらかで検知すれば拒否する（空白入りパスの実行ファイルを引用する形は両方で通る）。
                match body.strip_prefix('"') {
                    Some(inner) => {
                        let unquoted = match inner.rfind('"') {
                            Some(last) => format!("{}{}", &inner[..last], &inner[last + 1..]),
                            None => inner.to_owned(),
                        };
                        self.contains(&unquoted, depth + 1, Some(Mode::Cmd), strict)
                    }
                    None => Ok(false),
                }
            }
        }
    }
}
