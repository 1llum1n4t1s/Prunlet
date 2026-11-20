use super::*;

impl Inspector {
    /// Windows PowerShell 5.1（`powershell`）の位置引数を本文として検査する。
    ///
    /// 起動optionを左から読み、`-Command`・`-File`・`-EncodedCommand`が先に現れる場合は従来の走査へ任せる
    /// （`None`）。値を取る既知optionは値を読み飛ばし、最初の位置引数以降を`-Command`本文として再帰検査する。
    /// 未知のoptionは位置引数の手前に本文が隠れている可能性があるため拒否する。
    /// 位置引数が`.ps1`のパスなら実行名として評価され、削除でなければ通過する。
    pub(super) fn powershell_positional(
        &mut self,
        w: &[Token],
        i: usize,
        depth: usize,
        strict: bool,
    ) -> Option<Result<bool>> {
        // (正式名, 値を取るか)。PowerShellは一意な前方一致の省略形を受け付ける。
        const OPTIONS: [(&str, bool); 16] = [
            // `-ep`は`-ExecutionPolicy`の公式の短縮名（前方一致では得られない）。
            ("ep", true),
            ("noexit", false),
            ("nologo", false),
            ("noninteractive", false),
            ("noprofile", false),
            ("sta", false),
            ("mta", false),
            ("help", false),
            ("executionpolicy", true),
            ("inputformat", true),
            ("outputformat", true),
            ("windowstyle", true),
            ("configurationname", true),
            ("psconsolefile", true),
            ("version", true),
            ("encodedarguments", true),
        ];
        let mut j = i + 1;
        while j < w.len() {
            let text = w[j].text.as_str();
            let dashed = text.starts_with(['-', '/', '\u{2013}', '\u{2014}', '\u{2015}']);
            if !dashed {
                // 位置引数。以降すべてが本文（後ろのリダイレクトはwrapper_bodyが除く）。
                return Some(self.wrapper_body(&w[j..], depth, Some(Mode::PowerShell), strict));
            }
            if encoded(text) || file_option(text) || command_option(text) {
                return None;
            }
            let name = option(text);
            if matches!(name.as_str(), "?" | "h") {
                return Some(Ok(false));
            }
            let matches: Vec<bool> = if name.is_empty() {
                Vec::new()
            } else {
                OPTIONS
                    .iter()
                    .filter(|(full, _)| full.starts_with(&name))
                    .map(|(_, value)| *value)
                    .collect()
            };
            // 一致しない・値の有無が食い違う省略形は、本文の位置を確定できない。
            if matches.is_empty() || matches.iter().any(|v| *v != matches[0]) {
                return Some(Ok(self.detected(
                    "unsupported PowerShell wrapper option cannot be inspected",
                    text,
                )));
            }
            j += 1;
            if matches[0] {
                j += 1;
            }
        }
        None
    }
    /// 式の位置にある語をコマンドとして検査する。引用で始まる式は文字列dataとして扱う。
    /// `strict`は呼出し元の規則を引き継ぎ、非strictのPowerShell規則でEncodedCommand専用の拒否を働かせない。
    pub(super) fn expression(
        &mut self,
        w: &[Token],
        i: usize,
        depth: usize,
        strict: bool,
    ) -> Result<bool> {
        if i >= w.len() || w[i].quote_start == Some(0) {
            Ok(false)
        } else {
            self.command(&w[i..], depth + 1, strict)
        }
    }
    /// PowerShellの代入・`foreach ($x in ...)`の右辺をコマンドとして検査する。
    /// 代入でない場合は`None`を返し、呼出し元が通常のコマンド検査を続ける。
    pub(super) fn assignment(
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
            // 閉じていない`$(`は入力の終わりまでを本文として検査する。従来の読みでは従来の閉じ探索を使う。
            let close = if self.reading == Some(true) {
                subexpression_close_legacy(&chars, start)
            } else {
                subexpression_close(&chars, start, chars.len(), self.mode == Some(Mode::Posix))
            };
            let body_end = close.map_or(chars.len(), |end| end - 1);
            if self.contains(
                &chars[start + 2..body_end].iter().collect::<String>(),
                depth + 1,
                None,
                false,
            )? {
                return Ok(true);
            }
            start = close.unwrap_or(chars.len());
        }
        Ok(false)
    }
    pub(super) fn noncanonical(&mut self, w: &[Token], depth: usize) -> Result<bool> {
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
