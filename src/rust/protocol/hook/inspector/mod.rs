use super::*;

mod command;
mod operands;
mod posix;

#[derive(Default)]
pub(super) struct Inspector {
    pub(super) mode: Option<Mode>,
    /// CMD規則で、いま検査している文の直後が`;`だったか。cmd.exeでは`;`は空白相当の区切りで、
    /// `cmd /d;/c del x`のように`cmd`の引数列を途中で割れない。字句解析は`;`を文境界にするため、
    /// 本文switchを持たない`cmd`の直後に`;`が続く形をwrapper側で拒否するのに使う。
    pub(super) cmd_semicolon: bool,
    /// いまのshell規則が明示されたものか（hookのshell指定・`cmd /c`等の本文）。
    /// shell不明で候補の規則を順に当てている間はfalse。CMD規則の`=`での実行名打切りに使う。
    pub(super) explicit: bool,
    pub(super) detection: Option<String>,
    pub(super) posix_script: bool,
    /// 入力全体が単独の静的EncodedCommandで、復号本文をPowerShellとして確定検査したか。
    /// このときshell不明時の「候補の解釈」注記とEncodedCommand案内は事実に合わないため付けない。
    pub(super) standalone_encoded: bool,
    /// このhookを起動した配置済みCLIと設定の絶対パス。管理者起動の許可リスト照合だけに使う。
    /// 空のとき（単体の検査器テスト等）は管理者起動を一切許可しない。
    pub(super) admin_cli: String,
    pub(super) admin_config: String,
    /// 最初の検知が削除命令（ファイル・レジストリ）か。検査不能による拒否と区別し、
    /// 拒否理由に付ける案内の長さを変えるのに使う。
    pub(super) deletion: bool,
    /// 字句解析の読みの系統（`LexOptions::legacy`）。`None`は最上位で、新しい読みと従来の読みの両方で検査する。
    /// 入れ子の本文（`$(…)`・wrapperの本文）は外側の読みの系統を引き継ぎ、読みの数を深さごとに増やさない。
    pub(super) reading: Option<bool>,
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
    pub(super) fn contains(
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
            let previous_reading = self.reading;
            let result = (|| -> Result<bool> {
                // POSIX規則で解釈が分かれる箇所は、別の読みでも検査する（LexOptions参照）。
                // `>& 名前`があれば名前をリダイレクト対象としてつなぐ読み、引用しない終端語のヒアドキュメント
                // 本文があれば本文の`'`・`"`を引用としない読みでも検査し、どれかで検知すれば拒否する。
                // POSIX規則と非strictのPowerShell規則では、新しい読みに加えて従来の読み（`legacy`）でも検査する。
                // 新しい読みが置き換えた解釈の誤りで、従来の読みなら検知できた削除を見逃さないため。
                let legacy_applies = m == Mode::Posix || (m == Mode::PowerShell && !strict);
                let readings: &[bool] = match previous_reading {
                    _ if !legacy_applies => &[false],
                    None => &[false, true],
                    Some(false) => &[false],
                    Some(true) => &[true],
                };
                let mut found = LexFound::default();
                for &legacy in readings {
                    for (attach, literal) in
                        [(false, false), (true, false), (false, true), (true, true)]
                    {
                        if (attach && !found.ampersand_name)
                            || (literal && (legacy || !found.unquoted_heredoc_body))
                        {
                            continue;
                        }
                        let options = LexOptions {
                            attach_ampersand_name: attach,
                            literal_heredoc_body: literal,
                            legacy,
                        };
                        // 入れ子の本文はこの読みの系統で検査する。CMD規則など読みの区別のない規則では外側の系統を保つ。
                        self.reading = if legacy_applies {
                            Some(legacy)
                        } else {
                            previous_reading
                        };
                        if self.lexed(script, m, depth, strict, options, &mut found)? {
                            return Ok(true);
                        }
                    }
                }
                Ok(false)
            })();
            self.reading = previous_reading;
            self.mode = previous;
            self.cmd_semicolon = previous_semicolon;
            self.explicit = previous_explicit;
            if result? {
                return Ok(true);
            }
        }
        Ok(false)
    }
    /// 1つの読み（`options`）で字句解析し、文ごとに検査する。
    fn lexed(
        &mut self,
        script: &str,
        m: Mode,
        depth: usize,
        strict: bool,
        options: LexOptions,
        found: &mut LexFound,
    ) -> Result<bool> {
        // 外側の文の終端（呼出し時点の値）。各読みの最後の文で引き継ぐ。
        let previous_semicolon = self.cmd_semicolon;
        found.uninspectable = None;
        let tokens = tokens_with(script, m, strict, options, found)?;
        // 新しい読みで終わりを確定できない構文（閉じない`"$(`・終端語を確定できないヒアドキュメント）は拒否する。
        if let Some((reason, token)) = found.uninspectable.take() {
            return Ok(self.detected(reason, &token));
        }
        let mut words = Vec::new();
        let mut control = self.posix_script;
        // CMD規則で、いま集めている文が`(`の直後から始まったか（`for /f … in ('del x')`）。
        let mut after_paren = false;
        for token in tokens {
            if token.boundary {
                // CMD規則の字句解析だけが`;`・`(`の境界に";"・"("を載せる。直前の文の末尾が`;`かを伝える。
                self.cmd_semicolon = token.text == ";";
                if self.statement_with(&words, depth, strict, &mut control, after_paren)? {
                    return Ok(true);
                }
                after_paren = token.text == "(";
                words.clear();
            } else {
                words.push(token);
            }
        }
        // 最後の文の後ろは、入れ子の本文ならそれを含む外側の文の終端を引き継ぐ。
        // cmd.exeは`cmd /c cmd;/c del x`の本文を`;`以降まで含めて渡すため、本文末尾の`cmd`も
        // `;`に続く引数を受ける。最上位（previous_semicolon=false）では終端なしになる。
        self.cmd_semicolon = previous_semicolon;
        self.statement_with(&words, depth, strict, &mut control, after_paren)
    }
    /// 文を検査する。CMD規則で`(`の直後から始まる文（`for /f … in ('del x')`・usebackqの`` (`del x`) ``の
    /// コマンド集合）は、先頭語の語頭・語末の`'`・`` ` ``を外して実行名を判定する。CMD規則の字句解析は
    /// `'`・`` ` ``を引用符として読まないため、外さないと`'del`が実行名になり削除名が隠れる。
    /// 外して空になった語（`(' del x')`の`'`）は取り除き、次の語を実行名として読む。
    fn statement_with(
        &mut self,
        words: &[Token],
        depth: usize,
        strict: bool,
        control: &mut bool,
        after_paren: bool,
    ) -> Result<bool> {
        if after_paren
            && self.mode == Some(Mode::Cmd)
            && let Some(first) = words.first()
        {
            let trimmed = first
                .text
                .trim_start_matches(['\'', '`'])
                .trim_end_matches(['\'', '`']);
            if trimmed.len() != first.text.len() {
                let mut copy = words.to_vec();
                if trimmed.is_empty() {
                    copy.remove(0);
                } else {
                    copy[0].text = trimmed.to_owned();
                }
                return self.statement(&copy, depth, strict, control);
            }
        }
        self.statement(words, depth, strict, control)
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
            }
            // 文頭のリダイレクトと対象語（`>out`・`2>&1`）は実行名ではないため、読み飛ばした先の語を判定する。
            // 飛ばした先が無ければ（`>out`だけの文）コマンドを実行しない。
            if let Some(head) = words.get(leading_redirect_words(words, false)) {
                // 代入（`b=$(basename $f)`）の右辺は実行名ではないため、制御構文の中でも
                // posix_prefixで代入を剥がした後の実行名だけを動的かどうか判定する。
                // `[`・`[[`はtest組込みで、`[`単独はglobとして展開されない。
                let static_head =
                    compiled(&ASSIGNMENT)?.is_match(&head.text) || posix_test_builtin(head);
                if *control
                    && ((head.dynamic && !static_head)
                        || compiled(&REDIRECTION)?.is_match(&head.text))
                {
                    return Ok(self.detected(
                        "dynamic or unsupported POSIX control body cannot be inspected",
                        &head.text,
                    ));
                }
            }
        }
        self.command(words, depth, strict)
    }
}
