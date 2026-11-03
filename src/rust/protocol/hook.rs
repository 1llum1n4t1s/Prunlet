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
        }
    }
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
#[derive(Default)]
struct Inspector {
    mode: Option<Mode>,
    detection: Option<String>,
    posix_script: bool,
}
impl Inspector {
    fn detected(&mut self, reason: &str, token: &str) -> bool {
        if self.detection.is_none() {
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
        if depth > 4 {
            return Ok(
                (strict || mode == Some(Mode::Posix) || self.mode == Some(Mode::Posix))
                    && self.detected("inspection depth limit exceeded", &depth.to_string()),
            );
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
            self.mode = Some(m);
            let result = (|| {
                let tokens = tokens(script, m, strict)?;
                let mut words = Vec::new();
                let mut control = self.posix_script;
                for token in tokens {
                    if token.boundary {
                        if self.statement(&words, depth, strict, &mut control)? {
                            return Ok(true);
                        }
                        words.clear();
                    } else {
                        words.push(token);
                    }
                }
                self.statement(&words, depth, strict, &mut control)
            })();
            self.mode = previous;
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
                if *control && (first.dynamic || compiled(&REDIRECTION)?.is_match(&first.text)) {
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
        if depth > 4 {
            return Ok((strict || self.mode == Some(Mode::Posix))
                && self.detected("inspection depth limit exceeded", &depth.to_string()));
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
        let mut name = leaf(w[i].text.trim_start_matches('@'));
        if strict && w[i].quote_start == Some(0) {
            return Ok(false);
        }
        if matches!(name.as_str(), "call" | "command" | "exec") {
            i += 1;
            if i >= w.len() || w[i].text.starts_with('-') {
                return Ok(false);
            }
            name = leaf(w[i].text.trim_start_matches('@'));
        }
        // 条件中のquoted dataをCMD/PowerShellのalias名だけでPOSIX削除と推定しない。
        let posix_delete =
            self.mode == Some(Mode::Posix) && matches!(name.as_str(), "rm" | "rmdir" | "unlink");
        if posix_delete
            || self.mode != Some(Mode::Posix)
                && matches!(
                    name.as_str(),
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
        {
            return Ok(self.detected(
                "deletion command",
                raw_leaf(w[i].text.trim_start_matches('@')),
            ));
        }
        if name == "reg" {
            return Ok(w
                .get(i + 1)
                .is_some_and(|t| t.text.eq_ignore_ascii_case("delete"))
                && self.detected("registry deletion command", "reg delete"));
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
        if strict && wrapper(&name) {
            return Ok(self.detected(
                "nested shell inside EncodedCommand cannot be inspected",
                &name,
            ));
        }
        if strict {
            if matches!(name.as_str(), "return" | "throw" | "exit") {
                return self.expression(w, i + 1, depth);
            }
            if let Some(v) = self.assignment(w, i, depth)? {
                return Ok(v);
            }
        }
        if name == "if" {
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
        let ps = shell(&name) == Some(Mode::PowerShell);
        for j in i + 1..w.len() {
            if ps && encoded(&w[j].text) {
                return Ok(self.detected("noncanonical EncodedCommand invocation", &w[j].text));
            }
            if ps && file_option(&w[j].text) {
                return Ok(false);
            }
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
            return if words.len() == 1 {
                Ok(Some(false))
            } else {
                self.posix_nested(&words[1..], depth, strict).map(Some)
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
            return Ok(Some(
                words.len() > 1
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
    fn expression(&mut self, w: &[Token], i: usize, depth: usize) -> Result<bool> {
        if i >= w.len() || w[i].quote_start == Some(0) {
            Ok(false)
        } else {
            self.command(&w[i..], depth + 1, true)
        }
    }
    fn assignment(&mut self, w: &[Token], mut i: usize, depth: usize) -> Result<Option<bool>> {
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
            if t.quote_start.is_some_and(|q| q <= eq) {
                bail!("EncodedCommand quoted assignment targets cannot be inspected.");
            }
            if t.quote_start == Some(eq + 1) {
                return Ok(Some(false));
            }
            let rhs = &v[eq + 1..];
            if rhs.is_empty() {
                return Ok(Some(self.expression(w, i + 1, depth)?));
            }
            let mut expression = vec![Token::new(rhs)];
            expression[0].quoted = t.quoted;
            expression.extend_from_slice(&w[i + 1..]);
            return Ok(Some(self.command(&expression, depth + 1, true)?));
        }
        if let Some(n) = w.get(i + 1) {
            if (v.starts_with('$') && n.text.eq_ignore_ascii_case("in"))
                || (n.text.ends_with('=') && n.text.chars().all(|c| "=+-*/%?".contains(c)))
            {
                return Ok(Some(self.expression(w, i + 2, depth)?));
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
        for (i, part) in parts.iter().enumerate() {
            let mut part = part.as_str();
            if let Some(eq) = part.rfind('=') {
                if eq + 1 < part.len() {
                    part = &part[eq + 1..];
                }
            }
            if let Some(sub) = part.rfind("$(") {
                part = &part[sub + 2..];
            }
            part = part.trim_matches(['@', '$', '(', ')', '{', '}', '`']);
            if shell(&leaf(part)) != Some(Mode::PowerShell) {
                continue;
            }
            for p in &parts[i + 1..] {
                if encoded(p) {
                    return Ok(self.detected("noncanonical EncodedCommand invocation", p));
                }
                if file_option(p) || command_option(p) {
                    break;
                }
            }
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
fn tokens(script: &str, mode: Mode, strict: bool) -> Result<Vec<Token>> {
    let s: Vec<char> = script.chars().collect();
    let mut out = Vec::new();
    let mut t = Token::new("");
    let mut quote = '\0';
    let mut previous_equal = false;
    let mut i = 0;
    while i < s.len() {
        let mut c = s[i];
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
            if quote == '"' && c == '$' && s.get(i + 1) == Some(&'(') {
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
            if matches!(c, '\r' | '\n') {
                if c == '\r' && s.get(i + 1) == Some(&'\n') {
                    i += 1;
                }
            } else {
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
            if is_boundary {
                boundary(&mut out);
            }
        } else {
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
    let mut inspection = Inspector::default();
    if !inspection.contains(command, 0, mode, false)? {
        return Ok(json!({}));
    }
    let mut reason = inspection.detection.unwrap_or_else(|| {
        "Prunlet rejected this command because an invocation could not be safely classified.".into()
    });
    if mode.is_none() && cfg!(windows) {
        reason.push_str(" Shell metadata is missing or unsupported; this is a candidate interpretation, not a confirmed local deletion. Quoted search text or remote script data may be interpreted as command syntax. If the host forwards the tool as Bash without shell metadata, setting exec_command.shell alone cannot resolve this ambiguity. For an authorized SSH script sent from PowerShell, encode the entire local PowerShell script as UTF-16LE Base64 and submit the standalone form pwsh -NoProfile -EncodedCommand <base64>. The hook decodes and inspects that script; it does not exempt SSH names or remote deletion targets from inspection. See docs/integration.md for the supported form.");
    }
    let executable = cli.to_string_lossy();
    let config = config.to_string_lossy();
    if cfg!(windows) {
        let quote = |s: &str| {
            if s.chars().any(char::is_whitespace) {
                format!("\"{s}\"")
            } else {
                s.into()
            }
        };
        reason.push_str(&format!(" The hook did not execute the command. The following CLI guidance applies only to authorized Windows deletion targets. For explicitly authorized targets, use the installed Prunlet CLI from the start with shell=cmd.exe and login=false: {} --config {} delete --paths-file <absolute-json-file>; for registry keys/values use {} --config {} registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] -- <registry-key-path>. File and folder deletions have no Prunlet operation record. Normally restore recycled items using Windows Recycle Bin; a file or folder Windows reports as too large may instead be permanently deleted. Dry-run cannot predict the final disposition. Keep registry operationId and use registry-restore <operationId>. On hosts supporting exec_command sandbox permissions, request sandbox_permissions=\"require_escalated\" from the first real file deletion because Recycle Bin access may be restricted. This is a formal host permission request, not Windows UAC or administrator elevation. A dry-run does not prove real-operation permissions. Existing host approvals and policies still apply. Do not retry a policy-rejected target through another route or automatically resend a failed deletion; check uncertain file results using the source and Windows Recycle Bin; reconcile registry results using registry-reconcile <operationId> before deciding next steps.",quote(&executable),quote(&config),quote(&executable),quote(&config)));
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
