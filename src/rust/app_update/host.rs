//! ホスト設定の自動書換え（インストール・更新の直後に Velopack のフックから行う）。
//!
//! 旧導入（≤1.0.47）の利用者のホスト設定は、旧 `bin` の実行ファイルを指している。Setup 版へ移ったあとも
//! hook が働き続けるよう、**Prunlet が所有する箇所だけ**を新しいパスへ置き換える。
//!
//! # 置換するもの（旧パスの完全一致だけ）
//! - `<旧 bin>\prunlet-hook.exe` → `%LOCALAPPDATA%\Prunlet\hook\prunlet-hook.exe`
//! - `<旧 bin>\prunlet.exe` → `%LOCALAPPDATA%\PrunletApp\current\prunlet.exe`
//!
//! 他の行・キーは1バイトも変えない（JSON もテキストのまま置換し、キー順・他のフックを保つ。
//! parse → serialize はしない。parse は書換え前後の検証にだけ使う）。`\` が1つの表記（CLAUDE.md など）と、
//! JSON・TypeScript の文字列で `\\` に重ねた表記の両方を扱い、前後の文字が別のパスの一部でないことを確かめる。
//!
//! # 対象
//! - Claude Code: `settings.json`（hook の行）、`PRUNLET.md`、`CLAUDE.md`、`hooks/powershell-guard.ts`
//! - Toolport の `registry.json` と Codex の `config.toml`（`# BEGIN PRUNLET MCP` 区間）: MCP の登録は
//!   旧 ps1 ランチャー経由（`pwsh -File …\start-prunlet-mcp.ps1 -ExecutablePath … -ConfigPath …`）なので、
//!   command と args を**構造ごと**直接起動（`<current\prunlet.exe> --config <その登録の config> mcp`）へ書き換える。
//!   Prunlet 所有のエントリ（Toolport は id が `prunlet`）で、ps1 と exe が旧 bin のもの、config が絶対パスで
//!   確実に取り出せる場合だけ書き換える。それ以外の形は書き換えず「未移行」として報告する。
//! - Codex の `hooks.json`: hook のコマンドを変えると Codex が信頼を外す恐れがあるため、**書き換えず**、
//!   旧パスを指していれば「未移行」として報告するだけにする（`/hooks` での再信頼が必要な場合がある）。
//! - `--cli-executable` を伴わない旧形式の hook 呼び出し（`call <旧bin>\prunlet.exe --config … hook`）は、
//!   置換すると意味が変わるため置換せず、未移行として報告する。
//!
//! # 安全条件
//! - 新しい hook 複製と新 CLI が存在することを確かめてから書き換える。無ければ何も書かない。
//! - 書換え前に、同じフォルダーへ `.<名前>.prunlet-backup-<時刻>` を作る。書込みは一時ファイル →
//!   原子的な置換。冪等（2回目は変化なし・バックアップも作らない）。
//! - 通常ファイル以外（リンク・フォルダー）、UTF-8 として読めないもの、置換後の検証（JSON の再 parse と
//!   値の照合）に通らないものは書き換えない。
//! - 書換え結果は `host-rewrite.json`（状態フォルダー）に残し、`setup status` で表示する。
use std::{
    fs,
    path::{Path, PathBuf},
};

use serde::Serialize;
use serde_json::Value;

/// 置換から除外するかの判定（テキスト・開始位置・終了位置）。
type SkipFn = dyn Fn(&str, usize, usize) -> bool;

/// 置換の対（旧パス → 新パス。いずれも `\` が1つの通常表記）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mapping {
    pub pairs: Vec<(String, String)>,
    /// 旧 `bin\prunlet.exe`（MCP の登録が引数で渡していた CLI）。
    pub old_cli: String,
    /// 旧 `bin\start-prunlet-mcp.ps1`（旧 launcher）。
    pub launcher: String,
    /// 新しい `current\prunlet.exe`。
    pub new_cli: String,
}

impl Mapping {
    /// 旧 `bin` と新しい CLI・hook のパスから作る。
    pub fn new(legacy_bin: &Path, new_cli: &Path, new_hook: &Path) -> Self {
        let text = |path: &Path| path.to_string_lossy().into_owned();
        Self {
            pairs: vec![
                (text(&legacy_bin.join("prunlet-hook.exe")), text(new_hook)),
                (text(&legacy_bin.join("prunlet.exe")), text(new_cli)),
            ],
            old_cli: text(&legacy_bin.join("prunlet.exe")),
            launcher: text(&legacy_bin.join("start-prunlet-mcp.ps1")),
            new_cli: text(new_cli),
        }
    }

    /// `\` を重ねた表記（JSON・TypeScript の文字列リテラル内）の対。
    fn escaped(&self) -> Vec<(String, String)> {
        self.pairs
            .iter()
            .map(|(old, new)| (old.replace('\\', "\\\\"), new.replace('\\', "\\\\")))
            .collect()
    }
}

/// パスの一部になりうる文字（前後がこれだと、別のパスの途中とみなして置換しない）。
fn is_path_character(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | '\\' | '/')
}

/// `text` 内の `old` を `new` へ置き換える。前後の文字が別のパスの一部なら置換しない。置換数も返す。
fn replace_bounded(
    text: &str,
    old: &str,
    new: &str,
    skip: Option<&SkipFn>,
) -> (String, usize, usize) {
    if old.is_empty() {
        return (text.to_owned(), 0, 0);
    }
    let mut output = String::with_capacity(text.len());
    let mut count = 0;
    let mut skipped = 0;
    let mut rest = 0;
    let mut search = 0;
    while let Some(found) = text[search..].find(old) {
        let start = search + found;
        let end = start + old.len();
        let before = text[..start].chars().next_back();
        let tail = &text[end..];
        let after = tail.chars().next();
        // JSON・TypeScript の文字列では、パスの直後に `\"`（エスケープした引用符）が続く。
        // その `\` はパスの続きではないので、`\"` は境界として扱う。
        let after_continues =
            after.is_some_and(|c| is_path_character(c) && !tail.starts_with("\\\""));
        let bounded = before.is_none_or(|c| !is_path_character(c)) && !after_continues;
        if bounded && skip.is_some_and(|skip| skip(text, start, end)) {
            skipped += 1;
        } else if bounded {
            output.push_str(&text[rest..start]);
            output.push_str(new);
            rest = end;
            count += 1;
        }
        search = end;
    }
    output.push_str(&text[rest..]);
    (output, count, skipped)
}

/// `--cli-executable` を伴わない旧形式の hook 呼び出し（`<旧bin>\prunlet.exe --config … hook`）か。
/// `text[start..end]` が旧 CLI のパスで、直前が `--cli-executable` ではなく、同じ行の後ろに
/// `--config … hook` が続く場合に真。これを新パスへ置換すると、複製ではなく CLI 自身が hook として動く
/// 呼び出しになり意味が変わる（hook は root の外の複製から動かす契約）ので、置換しない。
fn is_legacy_hook_form(text: &str, start: usize, end: usize) -> bool {
    static HOOK_TAIL: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r#"^\\?"?\s+--config\s.*?\shook(?:\s|\\?"|$)"#).expect("static pattern")
    });
    let before = text[..start].trim_end_matches(['"', '\\', ' ']);
    if before.ends_with("--cli-executable") {
        return false;
    }
    let line = text[end..].split('\n').next().unwrap_or("");
    let tail: String = line.chars().take(800).collect();
    !tail.contains("--cli-executable") && HOOK_TAIL.is_match(&tail)
}

/// テキストを書き換える（通常表記と `\\` 表記の両方）。置換数と、旧形式の hook 呼び出しとして置換しなかった数を返す。
pub fn rewrite_text_full(text: &str, mapping: &Mapping) -> (String, usize, usize) {
    let mut current = text.to_owned();
    let (mut total, mut skipped_total) = (0, 0);
    for pairs in [mapping.pairs.clone(), mapping.escaped()] {
        for (old, new) in pairs {
            let is_cli = old.replace("\\\\", "\\") == mapping.old_cli;
            let skip: Option<&SkipFn> = if is_cli {
                Some(&is_legacy_hook_form)
            } else {
                None
            };
            let (next, count, skipped) = replace_bounded(&current, &old, &new, skip);
            current = next;
            total += count;
            skipped_total += skipped;
        }
    }
    (current, total, skipped_total)
}

/// [`rewrite_text_full`] の置換数だけを返す版。
pub fn rewrite_text(text: &str, mapping: &Mapping) -> (String, usize) {
    let (text, count, _) = rewrite_text_full(text, mapping);
    (text, count)
}

/// 値のレベルで同じ置換を行う（JSON の書換え後の検証に使う。文字列の中身は `\` が1つの表記）。
fn rewrite_value(value: &Value, mapping: &Mapping) -> Value {
    match value {
        Value::String(text) => {
            let mut current = text.clone();
            for (old, new) in &mapping.pairs {
                let skip: Option<&SkipFn> = if *old == mapping.old_cli {
                    Some(&is_legacy_hook_form)
                } else {
                    None
                };
                current = replace_bounded(&current, old, new, skip).0;
            }
            Value::String(current)
        }
        Value::Array(items) => {
            Value::Array(items.iter().map(|v| rewrite_value(v, mapping)).collect())
        }
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), rewrite_value(v, mapping)))
                .collect(),
        ),
        other => other.clone(),
    }
}

/// 1ファイルの結果。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileResult {
    pub path: PathBuf,
    /// `rewritten` / `unchanged` / `absent` / `skipped` / `unmigrated`。
    pub status: &'static str,
    /// 置換した箇所の数（`rewritten` のとき）。
    pub replacements: usize,
    /// 作ったバックアップ（`rewritten` のとき）。
    pub backup: Option<PathBuf>,
    /// `skipped`・`unmigrated` の理由。
    pub reason: Option<String>,
}

impl FileResult {
    fn new(path: &Path, status: &'static str) -> Self {
        Self {
            path: path.to_path_buf(),
            status,
            replacements: 0,
            backup: None,
            reason: None,
        }
    }

    fn with_reason(mut self, reason: impl Into<String>) -> Self {
        self.reason = Some(reason.into());
        self
    }
}

/// 対象ファイルの種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Json,
    Text,
    /// Toolport の `registry.json`。パスの置換に加え、Prunlet の MCP 登録（id が `prunlet`）を
    /// 旧 launcher 経由から直接起動へ構造ごと書き換える。
    Toolport,
    /// Codex の `config.toml`。パスの置換に加え、`# BEGIN PRUNLET MCP` 区間を直接起動へ書き換える。
    CodexToml,
    /// 書き換えず、旧パスを指していれば「未移行」として報告するだけ（Codex の `hooks.json`）。
    Report,
}

/// バックアップの名前 `.<名前>.prunlet-backup-<時刻>`。
fn backup_path(path: &Path, timestamp: &str) -> PathBuf {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    path.with_file_name(format!(".{name}.prunlet-backup-{timestamp}"))
}

/// 1ファイルを書き換える。
pub fn rewrite_file(path: &Path, kind: Kind, mapping: &Mapping, timestamp: &str) -> FileResult {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(_) => return FileResult::new(path, "absent"),
    };
    if !meta.is_file() {
        return FileResult::new(path, "skipped").with_reason("not a regular file");
    }
    let Ok(bytes) = fs::read(path) else {
        return FileResult::new(path, "skipped").with_reason("unreadable");
    };
    let Ok(text) = String::from_utf8(bytes.clone()) else {
        return FileResult::new(path, "skipped").with_reason("not UTF-8");
    };
    if kind == Kind::Report {
        let (_, count, skipped) = rewrite_text_full(&text, mapping);
        return if count + skipped > 0 {
            FileResult::new(path, "unmigrated").with_reason(
                "registers the legacy hook; it was not rewritten because changing a hook command can reset Codex's trust (review it in /hooks)",
            )
        } else {
            FileResult::new(path, "unchanged")
        };
    }
    // MCP の登録（旧 launcher 経由）は、構造ごと直接起動へ書き換える。確実に書き換えられなければ触らず未移行にする。
    let (rewritten, count, skipped) = match kind {
        Kind::Toolport | Kind::CodexToml => {
            let (rewritten, count) = if kind == Kind::Toolport {
                rewrite_toolport(&text, mapping)
            } else {
                rewrite_codex_block(&text, mapping)
            };
            if mentions_legacy_launcher(&rewritten, mapping) {
                return FileResult::new(path, "unmigrated").with_reason(
                    "an MCP entry still launches the legacy start-prunlet-mcp.ps1 (unrecognized shape or no absolute config path)",
                );
            }
            // 同じファイル内の hook などのパスも、他と同じ規則で置換する。
            let (rewritten, more, skipped) = rewrite_text_full(&rewritten, mapping);
            (rewritten, count + more, skipped)
        }
        _ => rewrite_text_full(&text, mapping),
    };
    if count == 0 {
        return if skipped > 0 {
            FileResult::new(path, "unmigrated").with_reason(format!(
                "{skipped} legacy-form hook invocation(s) without --cli-executable were left unchanged"
            ))
        } else {
            FileResult::new(path, "unchanged")
        };
    }
    if kind == Kind::Toolport {
        // 構造の検証: 書換え後も JSON で、id が prunlet のエントリ以外は1つも変わっていないこと。
        let before = serde_json::from_str::<Value>(text.trim_start_matches('\u{feff}'));
        let after = serde_json::from_str::<Value>(rewritten.trim_start_matches('\u{feff}'));
        match (before, after) {
            (Ok(before), Ok(after)) if rewrite_toolport_value(&before, mapping) == after => {}
            _ => return FileResult::new(path, "skipped").with_reason("JSON verification failed"),
        }
    }
    if kind == Kind::Json {
        // 書換え前後の構造を確かめる: 書換え後も JSON として読め、値の置換以外に変化が無いこと。
        let before = serde_json::from_str::<Value>(text.trim_start_matches('\u{feff}'));
        let after = serde_json::from_str::<Value>(rewritten.trim_start_matches('\u{feff}'));
        match (before, after) {
            (Ok(before), Ok(after)) if rewrite_value(&before, mapping) == after => {}
            _ => return FileResult::new(path, "skipped").with_reason("JSON verification failed"),
        }
    }
    let backup = backup_path(path, timestamp);
    // バックアップは新規作成のみ（既存を上書きしない）。作れなければ書き換えない。
    let backed_up = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&backup)
        .and_then(|mut file| std::io::Write::write_all(&mut file, &bytes));
    if let Err(error) = backed_up {
        let _ = fs::remove_file(&backup);
        return FileResult::new(path, "skipped").with_reason(format!("backup failed: {error}"));
    }
    if let Err(error) = super::atomic_write(path, rewritten.as_bytes()) {
        return FileResult::new(path, "skipped").with_reason(format!("write failed: {error}"));
    }
    FileResult {
        path: path.to_path_buf(),
        status: "rewritten",
        replacements: count,
        backup: Some(backup),
        reason: (skipped > 0).then(|| {
            format!("{skipped} legacy-form hook invocation(s) without --cli-executable were left unchanged")
        }),
    }
}

/// 旧 `bin` の ps1 ランチャー（`start-prunlet-mcp.ps1`）を指しているか（通常・`\\` 両方の表記）。
fn mentions_legacy_launcher(text: &str, mapping: &Mapping) -> bool {
    text.contains(&mapping.launcher) || text.contains(&mapping.launcher.replace('\\', "\\\\"))
}

/// JSON・TOML の二重引用符つき文字列リテラル（エスケープを含む）の正規表現。
const STRING_LITERAL: &str = r#""(?:[^"\\]|\\.)*""#;

/// リテラル（"…"）を値へ戻す。
fn unquote(literal: &str) -> Option<String> {
    serde_json::from_str::<String>(literal).ok()
}

/// 値を JSON の文字列リテラルにする。
fn quote(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

fn is_absolute_config(value: &str) -> bool {
    Path::new(value).is_absolute() && value.to_ascii_lowercase().ends_with(".json")
}

/// 旧 launcher 経由の引数列から、config を取り出す。形が想定どおりで、ps1 と exe が旧 bin のもので、
/// config が絶対パスのときだけ Some。-CodexHome <値> の組は許す（直接起動では使わない）。
fn extract_config(args: &[String], mapping: &Mapping) -> Option<String> {
    let expected_head = ["-NoProfile", "-NonInteractive", "-File"];
    if args.len() < 8 || args[..3] != expected_head {
        return None;
    }
    if args[3] != mapping.launcher
        || args[4] != "-ExecutablePath"
        || args[5] != mapping.old_cli
        || args[6] != "-ConfigPath"
    {
        return None;
    }
    let config = &args[7];
    let tail_ok = match &args[8..] {
        [] => true,
        [flag, _] => flag == "-CodexHome",
        _ => false,
    };
    (tail_ok && is_absolute_config(config)).then(|| config.clone())
}

/// Toolport の registry.json のテキストを書き換える。旧 launcher 経由の "args" と "command" の組を
/// "args": ["--config", <config>, "mcp"] と "command": <新 CLI> へ変える。他は1バイトも変えない。
/// 変更したエントリが id: prunlet のものだけであることは、呼び出し側が値の照合で確かめる。
fn rewrite_toolport(text: &str, mapping: &Mapping) -> (String, usize) {
    let pattern = format!(
        r#"(?P<indent>[ \t]*)"args":\s*\[(?P<list>\s*(?:{s}\s*,?\s*)+)\],(?P<gap>\s*)"command":\s*(?P<command>{s}),"#,
        s = STRING_LITERAL
    );
    let regex = regex::Regex::new(&pattern).expect("static pattern");
    let literal = regex::Regex::new(STRING_LITERAL).expect("static pattern");
    let mut count = 0;
    let output = regex.replace_all(text, |caps: &regex::Captures<'_>| {
        let whole = caps[0].to_owned();
        let args: Option<Vec<String>> = literal
            .find_iter(&caps["list"])
            .map(|m| unquote(m.as_str()))
            .collect();
        let Some(config) = args.and_then(|a| extract_config(&a, mapping)) else {
            return whole;
        };
        count += 1;
        let indent = &caps["indent"];
        let gap = &caps["gap"];
        let config = quote(&config);
        let command = quote(&mapping.new_cli);
        if whole.contains('\n') {
            format!(
                "{indent}\"args\": [\n{indent}  \"--config\",\n{indent}  {config},\n{indent}  \"mcp\"\n{indent}],{gap}\"command\": {command},"
            )
        } else {
            format!("{indent}\"args\": [\"--config\", {config}, \"mcp\"],{gap}\"command\": {command},")
        }
    });
    (output.into_owned(), count)
}

/// rewrite_toolport と同じ変更を値のレベルで行う（書換え後の検証用。id が prunlet のエントリだけが対象）。
fn rewrite_toolport_value(value: &Value, mapping: &Mapping) -> Value {
    match value {
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|v| rewrite_toolport_value(v, mapping))
                .collect(),
        ),
        Value::Object(map) => {
            let mut map: serde_json::Map<String, Value> = map
                .iter()
                .map(|(k, v)| (k.clone(), rewrite_toolport_value(v, mapping)))
                .collect();
            let owned = map.get("id").and_then(Value::as_str) == Some("prunlet");
            let config = map
                .get("args")
                .and_then(Value::as_array)
                .and_then(|args| {
                    args.iter()
                        .map(|a| a.as_str().map(str::to_owned))
                        .collect::<Option<Vec<_>>>()
                })
                .and_then(|args| extract_config(&args, mapping));
            if let (true, Some(config)) = (owned, config) {
                map.insert(
                    "args".into(),
                    serde_json::json!(["--config", config, "mcp"]),
                );
                map.insert("command".into(), Value::String(mapping.new_cli.clone()));
            }
            Value::Object(map)
        }
        other => other.clone(),
    }
}

/// Codex の config.toml の "# BEGIN PRUNLET MCP" 区間を、直接起動へ書き換える。
/// 区間が想定の形（command・args・任意の startup_timeout_sec）で、旧 launcher と旧 exe、絶対の config を
/// 指しているときだけ書き換える。区間の外は1バイトも変えない。
fn rewrite_codex_block(text: &str, mapping: &Mapping) -> (String, usize) {
    let pattern = format!(
        r#"(?m)^# BEGIN PRUNLET MCP(?P<nl>\r?\n)\[mcp_servers\.prunlet\]\r?\ncommand = (?P<command>{s})\r?\nargs = \[(?P<list>(?:\s*{s}\s*,?)+)\]\r?\n(?P<rest>(?:startup_timeout_sec = [0-9]+\r?\n)?)# END PRUNLET MCP"#,
        s = STRING_LITERAL
    );
    let regex = regex::Regex::new(&pattern).expect("static pattern");
    let literal = regex::Regex::new(STRING_LITERAL).expect("static pattern");
    let mut count = 0;
    let output = regex.replace_all(text, |caps: &regex::Captures<'_>| {
        let whole = caps[0].to_owned();
        let args: Option<Vec<String>> = literal
            .find_iter(&caps["list"])
            .map(|m| unquote(m.as_str()))
            .collect();
        let Some(config) = args.and_then(|a| extract_config(&a, mapping)) else {
            return whole;
        };
        count += 1;
        let nl = &caps["nl"];
        format!(
            "# BEGIN PRUNLET MCP{nl}[mcp_servers.prunlet]{nl}command = {}{nl}args = [\"--config\", {}, \"mcp\"]{nl}{}# END PRUNLET MCP",
            quote(&mapping.new_cli),
            quote(&config),
            &caps["rest"]
        )
    });
    (output.into_owned(), count)
}

/// 書き換え対象の場所（本番は [`HostPaths::resolve`]、テストは隔離フォルダーを渡す）。
#[derive(Debug, Clone, Default)]
pub struct HostPaths {
    pub claude: Option<PathBuf>,
    pub codex: Option<PathBuf>,
    pub toolport_registry: Option<PathBuf>,
}

impl HostPaths {
    pub fn resolve() -> Self {
        Self {
            claude: super::paths::claude_dir(),
            codex: super::paths::codex_dir(),
            toolport_registry: super::paths::toolport_registry(),
        }
    }
}

/// 全体の結果。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RewriteReport {
    /// 書換えを行わなかった理由（前提を満たさない）。None なら前提は満たした。
    pub skipped_reason: Option<String>,
    pub files: Vec<FileResult>,
}

/// すべての対象を書き換える。前提（新 hook 複製と新 CLI の存在）を満たさなければ何も書かない。
pub fn rewrite_all(
    hosts: &HostPaths,
    legacy_bin: Option<&Path>,
    new_cli: &Path,
    new_hook: &Path,
    timestamp: &str,
) -> RewriteReport {
    if !new_hook.is_file() || !new_cli.is_file() {
        return RewriteReport {
            skipped_reason: Some("the new CLI or the hook copy does not exist yet".into()),
            files: Vec::new(),
        };
    }
    let Some(legacy_bin) = legacy_bin else {
        return RewriteReport {
            skipped_reason: Some("the legacy install location is unknown".into()),
            files: Vec::new(),
        };
    };
    let mapping = Mapping::new(legacy_bin, new_cli, new_hook);
    let mut files = Vec::new();
    if let Some(claude) = &hosts.claude {
        for (name, kind) in [
            ("settings.json", Kind::Json),
            ("PRUNLET.md", Kind::Text),
            ("CLAUDE.md", Kind::Text),
            ("hooks/powershell-guard.ts", Kind::Text),
        ] {
            files.push(rewrite_file(&claude.join(name), kind, &mapping, timestamp));
        }
    }
    if let Some(codex) = &hosts.codex {
        // Codex は存在する場合のみ（無いフォルダーを作らない）。
        if codex.is_dir() {
            files.push(rewrite_file(
                &codex.join("hooks.json"),
                Kind::Report,
                &mapping,
                timestamp,
            ));
            files.push(rewrite_file(
                &codex.join("config.toml"),
                Kind::CodexToml,
                &mapping,
                timestamp,
            ));
        }
    }
    if let Some(registry) = &hosts.toolport_registry {
        // Toolport の登録は、旧 launcher 経由から直接起動へ構造ごと書き換える（ファイルが無ければ何もしない）。
        let result = rewrite_file(registry, Kind::Toolport, &mapping, timestamp);
        if result.status != "absent" {
            files.push(result);
        }
    }
    RewriteReport {
        skipped_reason: None,
        files,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("prunlet-host-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    const OLD_BIN: &str = r"C:\Users\T\.local\Prunlet\bin";
    const NEW_CLI: &str = r"C:\Users\T\AppData\Local\PrunletApp\current\prunlet.exe";
    const NEW_HOOK: &str = r"C:\Users\T\AppData\Local\Prunlet\hook\prunlet-hook.exe";

    fn mapping() -> Mapping {
        Mapping::new(Path::new(OLD_BIN), Path::new(NEW_CLI), Path::new(NEW_HOOK))
    }

    fn escaped(text: &str) -> String {
        text.replace('\\', "\\\\")
    }

    fn settings_json() -> String {
        // キー順が「普通でない」並びと、別のフック・別の設定を含む（保たれること）。
        format!(
            "{{\n  \"zeta\": 1,\n  \"hooks\": {{\n    \"PreToolUse\": [\n      {{\n        \"matcher\": \"Bash\",\n        \"hooks\": [\n          {{\"type\": \"command\", \"command\": \"\\\"{hook}\\\" --config \\\"C:\\\\Users\\\\T\\\\.local\\\\Prunlet\\\\config.json\\\" hook --cli-executable \\\"{cli}\\\"\"}},\n          {{\"type\": \"command\", \"command\": \"rtk hook claude\"}}\n        ]\n      }}\n    ]\n  }},\n  \"alpha\": \"{other}\"\n}}\n",
            hook = escaped(&format!(r"{OLD_BIN}\prunlet-hook.exe")),
            cli = escaped(&format!(r"{OLD_BIN}\prunlet.exe")),
            other = escaped(r"C:\Users\T\.local\Prunlet\bin\prunlet.previous.exe"),
        )
    }

    // 合否基準7: 旧パスだけが置換され、他は不変、バックアップがあり、冪等、hook 複製が無ければ書き換えない。

    #[test]
    fn only_old_paths_are_replaced_and_everything_else_is_byte_identical() {
        let original = settings_json();
        let (updated, count) = rewrite_text(&original, &mapping());
        assert_eq!(count, 2);
        assert!(updated.contains(&escaped(NEW_HOOK)));
        assert!(updated.contains(&escaped(NEW_CLI)));
        // 旧パスの完全一致以外（`prunlet.previous.exe`、config の行）は残る。
        assert!(updated.contains(&escaped(
            r"C:\Users\T\.local\Prunlet\bin\prunlet.previous.exe"
        )));
        assert!(updated.contains("config.json"));
        assert!(updated.contains("rtk hook claude"));
        // 置換部分を元へ戻せば、元のバイト列に一致する（他の部分は1バイトも変わらない）。
        let restored = updated
            .replace(
                &escaped(NEW_HOOK),
                &escaped(&format!(r"{OLD_BIN}\prunlet-hook.exe")),
            )
            .replace(
                &escaped(NEW_CLI),
                &escaped(&format!(r"{OLD_BIN}\prunlet.exe")),
            );
        assert_eq!(restored, original);
        // キー順が保たれている（zeta が hooks より前、alpha が最後）。
        let zeta = updated.find("\"zeta\"").unwrap();
        let hooks = updated.find("\"hooks\"").unwrap();
        let alpha = updated.find("\"alpha\"").unwrap();
        assert!(zeta < hooks && hooks < alpha);
        // 冪等: 2回目は変化しない。
        let (again, count) = rewrite_text(&updated, &mapping());
        assert_eq!(count, 0);
        assert_eq!(again, updated);
    }

    #[test]
    fn plain_backslash_and_escaped_forms_are_both_handled() {
        // CLAUDE.md は `\` が1つ、powershell-guard.ts は文字列リテラルで `\\`。
        let md =
            format!("- Prunlet CLI: `{OLD_BIN}\\prunlet.exe --config C:\\x\\config.json delete`\n");
        let (updated, count) = rewrite_text(&md, &mapping());
        assert_eq!(count, 1);
        assert!(updated.contains(&format!("`{NEW_CLI} --config")));
        let ts = format!(
            "const H = \"{}\";\n",
            escaped(&format!(r"{OLD_BIN}\prunlet-hook.exe"))
        );
        let (updated, count) = rewrite_text(&ts, &mapping());
        assert_eq!(count, 1);
        assert_eq!(updated, format!("const H = \"{}\";\n", escaped(NEW_HOOK)));
        // 前後が別のパスの一部なら置換しない。
        let part = format!("X{OLD_BIN}\\prunlet.exe and {OLD_BIN}\\prunlet.exe.bak");
        assert_eq!(rewrite_text(&part, &mapping()).1, 0);
    }

    fn fixture() -> (PathBuf, HostPaths, PathBuf, PathBuf) {
        let dir = scratch();
        let claude = dir.join(".claude");
        fs::create_dir_all(claude.join("hooks")).unwrap();
        fs::write(claude.join("settings.json"), settings_json()).unwrap();
        fs::write(
            claude.join("CLAUDE.md"),
            format!("# x\n- Prunlet CLI: `{OLD_BIN}\\prunlet.exe --config C:\\c.json`\n"),
        )
        .unwrap();
        // PRUNLET.md は旧パスを含まない（実機と同じ）。何も書かず、バックアップも作らない。
        fs::write(
            claude.join("PRUNLET.md"),
            "guide with <installed-exe> only\n",
        )
        .unwrap();
        fs::write(
            claude.join("hooks").join("powershell-guard.ts"),
            format!(
                "const H = \"{}\";\n",
                escaped(&format!(r"{OLD_BIN}\prunlet-hook.exe"))
            ),
        )
        .unwrap();
        let cli = dir.join("cli").join("prunlet.exe");
        let hook = dir.join("hook").join("prunlet-hook.exe");
        for file in [&cli, &hook] {
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, b"exe").unwrap();
        }
        let hosts = HostPaths {
            claude: Some(claude),
            codex: Some(dir.join("no-codex")),
            toolport_registry: None,
        };
        (dir, hosts, cli, hook)
    }

    #[test]
    fn rewrite_all_backs_up_writes_atomically_and_is_idempotent() {
        let (dir, hosts, cli, hook) = fixture();
        let claude = hosts.claude.clone().unwrap();
        let original_settings = fs::read(claude.join("settings.json")).unwrap();
        let original_guide = fs::read(claude.join("PRUNLET.md")).unwrap();
        let report = rewrite_all(
            &hosts,
            Some(Path::new(OLD_BIN)),
            &cli,
            &hook,
            "20261115-000000",
        );
        assert!(report.skipped_reason.is_none());
        let status = |name: &str| {
            report
                .files
                .iter()
                .find(|f| f.path.ends_with(name))
                .unwrap_or_else(|| panic!("{name}"))
                .status
        };
        assert_eq!(status("settings.json"), "rewritten");
        assert_eq!(status("CLAUDE.md"), "rewritten");
        assert_eq!(status("powershell-guard.ts"), "rewritten");
        assert_eq!(status("PRUNLET.md"), "unchanged");
        // バックアップは元のバイト列そのもの。
        let backup = claude.join(".settings.json.prunlet-backup-20261115-000000");
        assert_eq!(fs::read(&backup).unwrap(), original_settings);
        // 旧パスを含まない PRUNLET.md は変わらず、バックアップも作らない。
        assert_eq!(fs::read(claude.join("PRUNLET.md")).unwrap(), original_guide);
        assert!(
            !claude
                .join(".PRUNLET.md.prunlet-backup-20261115-000000")
                .exists()
        );
        // 書換え後の settings.json は JSON として読め、新パスを指す。
        let written = fs::read_to_string(claude.join("settings.json")).unwrap();
        serde_json::from_str::<Value>(&written).unwrap();
        assert!(
            written.contains(&escaped(&hook.to_string_lossy()))
                && written.contains(&escaped(&cli.to_string_lossy()))
        );
        // 一時ファイルを残さない（元のファイル・バックアップのみ）。
        assert!(
            fs::read_dir(&claude).unwrap().all(|e| !e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp"))
        );
        // Codex が無ければ作らない・触らない。
        assert!(!dir.join("no-codex").exists());
        // 冪等: 2回目は全て unchanged で、バックアップも増えない。
        let backups = |dir: &Path| {
            fs::read_dir(dir)
                .unwrap()
                .filter(|e| {
                    e.as_ref()
                        .unwrap()
                        .file_name()
                        .to_string_lossy()
                        .contains("prunlet-backup")
                })
                .count()
        };
        let before = backups(&claude);
        let again = rewrite_all(
            &hosts,
            Some(Path::new(OLD_BIN)),
            &cli,
            &hook,
            "20261115-000001",
        );
        assert!(
            again.files.iter().all(|f| f.status == "unchanged"),
            "{again:?}"
        );
        assert_eq!(backups(&claude), before);
        assert_eq!(
            fs::read_to_string(claude.join("settings.json")).unwrap(),
            written
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn nothing_is_written_while_the_hook_copy_or_cli_is_missing() {
        let (dir, hosts, cli, hook) = fixture();
        let claude = hosts.claude.clone().unwrap();
        let before = fs::read(claude.join("settings.json")).unwrap();
        fs::remove_file(&hook).unwrap();
        let report = rewrite_all(&hosts, Some(Path::new(OLD_BIN)), &cli, &hook, "t");
        assert!(report.skipped_reason.is_some());
        assert!(report.files.is_empty());
        assert_eq!(fs::read(claude.join("settings.json")).unwrap(), before);
        assert!(!claude.join(".settings.json.prunlet-backup-t").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn unsafe_targets_are_skipped_and_launcher_registrations_are_reported_not_rewritten() {
        let dir = scratch();
        let mapping = mapping();
        // JSON として壊れる置換は書かない（壊れた元ファイルは JSON 検証に通らない）。
        let broken = dir.join("settings.json");
        fs::write(&broken, format!("{{ not json {OLD_BIN}\\prunlet.exe")).unwrap();
        let result = rewrite_file(&broken, Kind::Json, &mapping, "t");
        assert_eq!(result.status, "skipped");
        // UTF-8 でないファイルは触らない。
        let binary = dir.join("b.md");
        fs::write(&binary, [0xff, 0xfe, 0x00]).unwrap();
        assert_eq!(
            rewrite_file(&binary, Kind::Text, &mapping, "t").status,
            "skipped"
        );
        // フォルダーは触らない。
        assert_eq!(
            rewrite_file(&dir, Kind::Text, &mapping, "t").status,
            "skipped"
        );
        // 無いファイルは absent。
        assert_eq!(
            rewrite_file(&dir.join("none"), Kind::Text, &mapping, "t").status,
            "absent"
        );
        // 旧 ps1 ランチャーを指す config.toml は書き換えず、未移行として報告する。
        let toml = dir.join("config.toml");
        let body = format!(
            "args = [\"-File\", \"{}\", \"-ExecutablePath\", \"{}\"]\n",
            escaped(&format!(r"{OLD_BIN}\start-prunlet-mcp.ps1")),
            escaped(&format!(r"{OLD_BIN}\prunlet.exe"))
        );
        fs::write(&toml, &body).unwrap();
        let result = rewrite_file(&toml, Kind::CodexToml, &mapping, "t");
        assert_eq!(result.status, "unmigrated");
        assert_eq!(fs::read_to_string(&toml).unwrap(), body);
        let _ = fs::remove_dir_all(&dir);
    }

    // MCP 登録（Toolport・Codex）の構造ごとの書換え。

    const CONFIG: &str = r"C:\Users\T\.local\Prunlet\config.json";

    /// 実機の registry.json と同じ形（キーはアルファベット順、2スペース）の、Prunlet 以外のエントリを含む登録。
    fn registry(config: &str, exe: &str) -> String {
        format!(
            "{{\n  \"version\": 3,\n  \"servers\": [\n    {{\n      \"args\": [\"--stdio\"],\n      \"command\": \"D:\\\\x\\\\plumivox.exe\",\n      \"id\": \"plumivox\"\n    }},\n    {{\n      \"args\": [\n        \"-NoProfile\",\n        \"-NonInteractive\",\n        \"-File\",\n        \"{ps1}\",\n        \"-ExecutablePath\",\n        \"{exe}\",\n        \"-ConfigPath\",\n        \"{config}\"\n      ],\n      \"command\": \"C:\\\\pwsh.exe\",\n      \"cwd\": \"C:\\\\Users\\\\T\",\n      \"enabled\": true,\n      \"env\": [\n        {{\n          \"key\": \"TEMP\",\n          \"secret\": false,\n          \"value\": \"D:\\\\t\"\n        }}\n      ],\n      \"id\": \"prunlet\",\n      \"name\": \"prunlet\",\n      \"transport\": \"stdio\"\n    }}\n  ]\n}}\n",
            ps1 = escaped(&format!(r"{OLD_BIN}\start-prunlet-mcp.ps1")),
            exe = escaped(exe),
            config = escaped(config),
        )
    }

    #[test]
    fn toolport_launcher_entry_becomes_a_direct_launch_and_nothing_else_changes() {
        let dir = scratch();
        let path = dir.join("registry.json");
        let original = registry(CONFIG, &format!(r"{OLD_BIN}\prunlet.exe"));
        fs::write(&path, &original).unwrap();
        let result = rewrite_file(&path, Kind::Toolport, &mapping(), "t");
        assert_eq!(result.status, "rewritten", "{result:?}");
        let updated = fs::read_to_string(&path).unwrap();
        let value: Value = serde_json::from_str(&updated).unwrap();
        let entry = &value["servers"][1];
        assert_eq!(entry["command"], NEW_CLI);
        assert_eq!(
            entry["args"],
            serde_json::json!(["--config", CONFIG, "mcp"])
        );
        // 他のキー・他のエントリ・env は元のまま。
        assert_eq!(
            value["servers"][0],
            serde_json::from_str::<Value>(&original).unwrap()["servers"][0]
        );
        assert_eq!(entry["env"][0]["value"], r"D:\t");
        assert_eq!(entry["cwd"], r"C:\Users\T");
        // 構造を除けば1バイトも変わらない（プレフィックスと、args の後ろの cwd 以降が同一）。
        assert!(updated.starts_with(&original[..original.find("      \"args\": [\n").unwrap()]));
        assert!(updated.ends_with(&original[original.find("      \"cwd\"").unwrap()..]));
        // バックアップは元のバイト列、冪等、一時ファイルを残さない。
        assert_eq!(
            fs::read_to_string(dir.join(".registry.json.prunlet-backup-t")).unwrap(),
            original
        );
        assert_eq!(
            rewrite_file(&path, Kind::Toolport, &mapping(), "u").status,
            "unchanged"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), updated);
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 2);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn toolport_entries_that_cannot_be_migrated_for_sure_are_reported_not_rewritten() {
        let dir = scratch();
        let path = dir.join("registry.json");
        // config が相対パス、旧 bin ではない exe、想定外の引数は、どれも書き換えず未移行にする。
        let cases = [
            registry(r"relative\config.json", &format!(r"{OLD_BIN}\prunlet.exe")),
            registry(CONFIG, r"D:\other\bin\prunlet.exe"),
            registry(CONFIG, &format!(r"{OLD_BIN}\prunlet.exe"))
                .replace("\"-ConfigPath\"", "\"-Extra\", \"-ConfigPath\""),
        ];
        for body in cases {
            fs::write(&path, &body).unwrap();
            let result = rewrite_file(&path, Kind::Toolport, &mapping(), "t");
            assert_eq!(result.status, "unmigrated", "{body}");
            assert_eq!(fs::read_to_string(&path).unwrap(), body);
        }
        assert!(
            fs::read_dir(&dir).unwrap().all(|e| !e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains("backup"))
        );
        // 別の id のエントリは、形が同じでも書き換えない（値の照合で検出して止める）。
        let other = registry(CONFIG, &format!(r"{OLD_BIN}\prunlet.exe"))
            .replace("\"id\": \"prunlet\"", "\"id\": \"other\"");
        fs::write(&path, &other).unwrap();
        assert_eq!(
            rewrite_file(&path, Kind::Toolport, &mapping(), "t").status,
            "skipped"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), other);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn codex_mcp_block_becomes_a_direct_launch_and_the_rest_is_untouched() {
        let dir = scratch();
        let path = dir.join("config.toml");
        for nl in ["\n", "\r\n"] {
            let block = [
                "# BEGIN PRUNLET MCP".to_owned(),
                "[mcp_servers.prunlet]".to_owned(),
                "command = \"pwsh\"".to_owned(),
                format!(
                    "args = [\"-NoProfile\", \"-NonInteractive\", \"-File\", \"{}\", \"-ExecutablePath\", \"{}\", \"-ConfigPath\", \"{}\", \"-CodexHome\", \"C:\\\\h\\\\.codex\"]",
                    escaped(&format!(r"{OLD_BIN}\start-prunlet-mcp.ps1")),
                    escaped(&format!(r"{OLD_BIN}\prunlet.exe")),
                    escaped(CONFIG)
                ),
                "startup_timeout_sec = 600".to_owned(),
                "# END PRUNLET MCP".to_owned(),
            ]
            .join(nl);
            let original = format!("model = \"x\"{nl}{block}{nl}[features]{nl}hooks = true{nl}");
            fs::write(&path, &original).unwrap();
            let result = rewrite_file(
                &path,
                Kind::CodexToml,
                &mapping(),
                nl.len().to_string().as_str(),
            );
            assert_eq!(result.status, "rewritten", "{result:?}");
            let updated = fs::read_to_string(&path).unwrap();
            let expected_block = [
                "# BEGIN PRUNLET MCP".to_owned(),
                "[mcp_servers.prunlet]".to_owned(),
                format!("command = \"{}\"", escaped(NEW_CLI)),
                format!("args = [\"--config\", \"{}\", \"mcp\"]", escaped(CONFIG)),
                "startup_timeout_sec = 600".to_owned(),
                "# END PRUNLET MCP".to_owned(),
            ]
            .join(nl);
            assert_eq!(
                updated,
                format!("model = \"x\"{nl}{expected_block}{nl}[features]{nl}hooks = true{nl}")
            );
            // 冪等。
            assert_eq!(
                rewrite_file(&path, Kind::CodexToml, &mapping(), "z").status,
                "unchanged"
            );
        }
        let _ = fs::remove_dir_all(&dir);
    }
}
