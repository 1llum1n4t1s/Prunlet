use super::*;

/// for/selectの変数名（一度だけコンパイルする）。
static LOOP_VARIABLE: LazyLock<std::result::Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\A[A-Za-z_][A-Za-z0-9_]*\z"));

impl Inspector {
    pub(super) fn posix_prefix(
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
                && compiled(&LOOP_VARIABLE)?.is_match(&words[1].text)
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
        // option・値の位置にあるリダイレクト（`env -u >/dev/null FOO unlink y`）は前置コマンドの引数ではない。
        // 先に除いてからoptionを解析し、リダイレクトの語を値と取り違えて実行名の位置をずらさない。
        let stripped: Vec<Token> = std::iter::once(words[0].clone())
            .chain(without_redirect_words(&words[1..], false))
            .collect();
        let words = stripped.as_slice();
        let mut index = 1;
        let mut options = true;
        while index < words.len() {
            let word = &words[index];
            let value = word.text.as_str();
            // ブレース展開は語の数を変え、option・値・実行名の位置をずらしうるため動的な語と同じく扱う。
            if word.dynamic || word.brace {
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
                if index == words.len() || words[index].dynamic || words[index].brace {
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
        // prefix・代入の後ろのリダイレクトと対象語（`exec 3>&-`・`exec >log 2>&1`・`FOO=1 >out`）は実行名ではない。
        // 読み飛ばして何も残らなければコマンドを実行しない。残れば、その先頭語に対して下の判定をやり直す
        // （リダイレクト1語の前置きで動的名・削除名の判定を外さない）。
        let words = &words[leading_redirect_words(words, false).min(words.len())..];
        let Some(first) = words.first() else {
            return Ok(false);
        };
        // `[`・`[[`はtest組込み（引数の評価だけでコマンドを実行しない）。
        if posix_test_builtin(first) {
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
    /// `sh`・`bash`・`zsh`の起動optionを左から解析し、`-c`の本文を再帰検査する。
    ///
    /// POSIX shellは`-c`を見つけた後もoption解析を続け、`--`または最初の非option語を本文とする
    /// （`bash -c -- "<本文>"`・`sh -c -x "<本文>"`）。値を取る`o`・`O`はclusterに結合しても
    /// （`-oc posix "<本文>"`）、clusterの後に値が1語ずつ続く。値や本文が欠落・動的なら検査不能として拒否する。
    /// `body_mode`は本文を検査する規則。POSIX規則では`Some(Posix)`、外側がCMD・PowerShell規則のときは
    /// 従来の汎用wrapperと同じ`shell(name)`を渡し、検知範囲を狭めない。
    pub(super) fn posix_shell(
        &mut self,
        words: &[Token],
        depth: usize,
        strict: bool,
        body_mode: Option<Mode>,
    ) -> Result<Option<bool>> {
        if !matches!(leaf(&words[0].text).as_str(), "sh" | "bash" | "zsh") {
            return Ok(None);
        }
        // リダイレクト（`>/dev/null`・`2>&1`・`> f`）はshellの引数ではない。位置を問わず先に除き、
        // 値を取るoption（`-o >/dev/null posix`）の値や本文と取り違えない。
        let stripped: Vec<Token> = std::iter::once(words[0].clone())
            .chain(without_redirect_words(&words[1..], false))
            .collect();
        let words = stripped.as_slice();
        // `-c`を含むoption語（本文欠落時の拒否理由に使う）。
        let mut command: Option<&str> = None;
        let mut index = 1;
        while index < words.len() {
            // リダイレクト（`>/dev/null`・`2>&1`・`> f`・`bash>/dev/null`の分割後）はshellの引数ではない。
            // 対象語ごと読み飛ばし、後ろの`-c`と本文を見落とさない。
            let redirect = leading_redirect_words(&words[index..], false);
            if redirect > 0 {
                index += redirect;
                continue;
            }
            let word = &words[index];
            if word.dynamic {
                return Ok(Some(match command {
                    Some(option) => self.detected(
                        "missing or dynamic POSIX shell command cannot be inspected",
                        option,
                    ),
                    None => self.detected(
                        "dynamic POSIX shell arguments cannot be inspected",
                        &word.text,
                    ),
                }));
            }
            let option = word.text.as_str();
            if option == "--" {
                // option列の終端。`-c`済みなら次の語が本文。
                index += 1;
                break;
            }
            if !option.starts_with(['-', '+']) {
                break;
            }
            if matches!(option, "--help" | "--version") {
                return Ok(Some(false));
            }
            // この語の後ろに続く値の数（`-o`・`-O`・`--rcfile`・`--init-file`）。
            let mut values = 0;
            if matches!(option, "--rcfile" | "--init-file") {
                values = 1;
            } else if matches!(
                option,
                "--noprofile" | "--norc" | "--posix" | "--restricted" | "--verbose" | "--login"
            ) {
                // 値を取らない既知の長いoption。
            } else if option.starts_with("--") {
                return Ok(Some(self.detected(
                    "unsupported POSIX shell options cannot be inspected",
                    option,
                )));
            } else {
                let letters = &option[1..];
                let has_command = option.starts_with('-') && letters.contains('c');
                if has_command {
                    command.get_or_insert(option);
                }
                for letter in letters.chars() {
                    if matches!(letter, 'o' | 'O') {
                        values += 1;
                    } else if !has_command && !"abefhkmnptuvxBCEHPTilrs".contains(letter) {
                        // `-c`を含む語の未知文字は従来どおり本文検査を優先し、拒否しない。
                        return Ok(Some(self.detected(
                            "unsupported POSIX shell options cannot be inspected",
                            option,
                        )));
                    }
                }
            }
            index += 1;
            for _ in 0..values {
                if index == words.len() || words[index].dynamic {
                    return Ok(Some(self.detected(
                        "missing or dynamic POSIX shell option cannot be inspected",
                        option,
                    )));
                }
                index += 1;
            }
        }
        let Some(option) = command else {
            // 外部script本文や対話入力は読まない。
            return Ok(Some(false));
        };
        if index == words.len() || words[index].dynamic {
            return Ok(Some(self.detected(
                "missing or dynamic POSIX shell command cannot be inspected",
                option,
            )));
        }
        let previous = self.posix_script;
        // 外側がCMD・PowerShell規則で本文を全規則に当てる場合は、従来の汎用wrapperと同じく
        // 制御本文扱い（動的な先頭語の拒否）にしない。拒否が増えるのは新しく解析できた形だけに保つ。
        self.posix_script = previous || body_mode == Some(Mode::Posix);
        let result = self.contains(&words[index].text, depth + 1, body_mode, strict);
        self.posix_script = previous;
        result.map(Some)
    }
}
