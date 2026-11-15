// 人が読む文言の9言語辞書の整合テスト（D:\Dev\APP-DISTRIBUTION.md「8. ローカライズ」）。
//
// 対象は3か所で、どれもキーは英語の原文とする:
// - Rust の CLI ヘルプ: `src/rust/locales/<タグ>.json`（en.json は原文→原文）
// - Windows のインストーラー: `scripts/Install-Prunlet.ps1` に埋め込んだ JSON（英語以外の8言語）
// - Apple Silicon のインストーラー: `scripts/Install-Prunlet.sh` に埋め込んだ表（英語以外の8言語）
// 確認すること: 全言語のキー集合が同じこと、訳文のプレースホルダー `{name}` が原文と同じ集合であること、
// コードが参照するキーが辞書にあり、辞書に参照されないキーが残っていないこと、英語の出力が従来と同じこと。
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use prunlet::help;
use prunlet::locale::{self, Language};

/// 英語以外の8言語のタグ（インストーラーの埋め込み辞書が持つべき集合）。
fn translated_tags() -> BTreeSet<String> {
    Language::ALL
        .iter()
        .filter(|language| **language != Language::English)
        .map(|language| language.tag().to_owned())
        .collect()
}

fn repository_file(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()))
        .replace("\r\n", "\n")
}

/// `{name}` 形式（小文字・数字・下線）のプレースホルダー名を集める。
fn placeholders(text: &str) -> BTreeSet<String> {
    regex::Regex::new(r"\{([a-z0-9_]+)\}")
        .unwrap()
        .captures_iter(text)
        .map(|capture| capture[1].to_owned())
        .collect()
}

/// 辞書（言語→キー→訳文）が、参照されるキーの集合とちょうど一致し、各訳文のプレースホルダーが原文と同じことを確かめる。
fn assert_consistent(
    name: &str,
    tables: &BTreeMap<String, BTreeMap<String, String>>,
    expected_tags: &BTreeSet<String>,
    referenced: &BTreeSet<String>,
) {
    assert!(
        !referenced.is_empty(),
        "{name}: no key references were found"
    );
    let tags: BTreeSet<String> = tables.keys().cloned().collect();
    assert_eq!(&tags, expected_tags, "{name}: language set differs");
    for (tag, table) in tables {
        let keys: BTreeSet<String> = table.keys().cloned().collect();
        let missing: Vec<_> = referenced.difference(&keys).collect();
        let unused: Vec<_> = keys.difference(referenced).collect();
        assert!(missing.is_empty(), "{name} {tag}: missing keys {missing:?}");
        assert!(unused.is_empty(), "{name} {tag}: unused keys {unused:?}");
        for (key, value) in table {
            assert!(
                !value.trim().is_empty(),
                "{name} {tag}: empty text for {key}"
            );
            assert_eq!(
                placeholders(value),
                placeholders(key),
                "{name} {tag}: placeholders differ for {key}"
            );
        }
    }
}

fn dictionary_of(language: Language) -> BTreeMap<String, String> {
    serde_json::from_str(language.dictionary_source())
        .unwrap_or_else(|error| panic!("{}.json: {error}", language.tag()))
}

#[test]
fn cli_dictionaries_cover_every_translatable_help_line() {
    // 3OS のヘルプで訳す行の全体（用法の行は訳さない）。
    let referenced: BTreeSet<String> = [help::LINUX, help::MACOS, help::WINDOWS]
        .into_iter()
        .flat_map(help::translatable_lines)
        .map(str::to_owned)
        .collect();
    let tables: BTreeMap<String, BTreeMap<String, String>> = Language::ALL
        .iter()
        .map(|language| (language.tag().to_owned(), dictionary_of(*language)))
        .collect();
    let all_tags: BTreeSet<String> = Language::ALL.iter().map(|l| l.tag().to_owned()).collect();
    assert_consistent("CLI help", &tables, &all_tags, &referenced);
    // en.json は原文をそのまま写す（英語の出力が従来の文字列と同じになる根拠）。
    for (key, value) in &tables["en"] {
        assert_eq!(key, value, "en.json must map the original text to itself");
    }
}

#[test]
fn english_help_is_unchanged_and_other_languages_keep_usage_lines() {
    for text in [help::LINUX, help::MACOS, help::WINDOWS] {
        assert_eq!(help::render(text, Language::English), text);
        for language in Language::ALL {
            let rendered = help::render(text, language);
            // 行数・末尾の改行・用法の行は全言語で同じにする。
            assert_eq!(rendered.ends_with('\n'), text.ends_with('\n'));
            let original: Vec<&str> = text.lines().collect();
            let localized: Vec<&str> = rendered.lines().collect();
            assert_eq!(localized.len(), original.len(), "{}", language.tag());
            for (before, after) in original.iter().zip(&localized) {
                if help::is_usage_line(before) {
                    assert_eq!(
                        before,
                        after,
                        "{}: usage lines are not translated",
                        language.tag()
                    );
                } else if language != Language::English {
                    assert_ne!(
                        before,
                        after,
                        "{}: untranslated line {before}",
                        language.tag()
                    );
                }
            }
        }
    }
    // 既存のテストや利用者が照合する用法の行が残っていること。
    assert!(
        help::WINDOWS
            .contains("migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]")
    );
}

fn rust_sources(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_sources(&path, found);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            found.push(path);
        }
    }
}

#[test]
fn rust_code_references_only_known_keys() {
    // ヘルプ以外で `tr("…")`・`tr_in(language, "…")` を直接使う箇所があれば、そのキーも辞書に要る。
    let pattern =
        regex::Regex::new(r#"\btr(?:_in)?\(\s*(?:[A-Za-z_:]+\s*,\s*)?"((?:[^"\\]|\\.)+)""#)
            .unwrap();
    let english = dictionary_of(Language::English);
    let mut files = Vec::new();
    rust_sources(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    for file in files {
        // 辞書の実装とその単体テスト（未知のキーの扱いを確かめる）は走査しない。
        if file.file_name().is_some_and(|name| name == "locale.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&file).unwrap();
        for capture in pattern.captures_iter(&source) {
            assert!(
                english.contains_key(&capture[1]),
                "{}: unknown dictionary key {}",
                file.display(),
                &capture[1]
            );
        }
    }
}

#[test]
fn language_tags_match_the_shared_rules() {
    for (value, expected) in [
        ("ja-JP", "ja"),
        ("zh-Hans", "zh-CN"),
        ("zh-SG", "zh-CN"),
        ("zh-Hant", "zh-TW"),
        ("zh-HK", "zh-TW"),
        ("zh-MO", "zh-TW"),
        ("pt", "pt-BR"),
        ("pt-PT", "pt-BR"),
        ("ko_KR.UTF-8", "ko"),
        ("es-419", "es"),
        ("fr_CA", "fr"),
        ("de-CH", "de"),
        ("it", "en"),
    ] {
        assert_eq!(
            locale::parse(value).map(Language::tag),
            Some(expected),
            "{value}"
        );
    }
    for value in ["", "C", "C.UTF-8", "POSIX"] {
        assert_eq!(locale::parse(value), None, "{value:?}");
    }
}

#[test]
fn windows_installer_messages_are_consistent() {
    let source = repository_file("scripts/Install-Prunlet.ps1");
    let begin = source
        .find("# BEGIN PRUNLET INSTALLER MESSAGES")
        .expect("begin marker");
    let end = source
        .find("# END PRUNLET INSTALLER MESSAGES")
        .expect("end marker");
    let section = &source[begin..end];
    let json_start = section.find("@'\n").expect("here-string start") + 3;
    let json_end = section.find("\n'@").expect("here-string end");
    let tables: BTreeMap<String, BTreeMap<String, String>> =
        serde_json::from_str(&section[json_start..json_end]).expect("installer messages JSON");
    // `Format-PrunletMessage '<英語の原文>'` で参照するキー（単一引用符の中に ' を含めない規約）。
    let referenced: BTreeSet<String> = regex::Regex::new(r"Format-PrunletMessage '([^']*)'")
        .unwrap()
        .captures_iter(&source)
        .map(|capture| capture[1].to_owned())
        .collect();
    assert_consistent(
        "Install-Prunlet.ps1",
        &tables,
        &translated_tags(),
        &referenced,
    );
    // 置換用の値を渡す呼出しでは、渡す名前が原文のプレースホルダーと一致すること。
    let call = regex::Regex::new(r"Format-PrunletMessage '([^']*)' @\{([^}]*)\}").unwrap();
    let names = regex::Regex::new(r"(?:^|;)\s*([a-z]+)\s*=").unwrap();
    for capture in call.captures_iter(&source) {
        let given: BTreeSet<String> = names
            .captures_iter(&capture[2])
            .map(|name| name[1].to_owned())
            .collect();
        assert_eq!(
            given,
            placeholders(&capture[1]),
            "values for {}",
            &capture[1]
        );
    }
}

#[test]
fn macos_installer_messages_are_consistent() {
    let source = repository_file("scripts/Install-Prunlet.sh");
    let start = source.find("<<'PRUNLET_MESSAGES'\n").expect("table start")
        + "<<'PRUNLET_MESSAGES'\n".len();
    let length = source[start..]
        .find("\nPRUNLET_MESSAGES\n")
        .expect("table end");
    let mut tables: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for line in source[start..start + length].lines() {
        let mut fields = line.split('\t');
        let (Some(tag), Some(key), Some(value), None) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            panic!("table rows need exactly three tab-separated fields: {line:?}");
        };
        let previous = tables
            .entry(tag.to_owned())
            .or_default()
            .insert(key.to_owned(), value.to_owned());
        assert!(previous.is_none(), "duplicate row for {tag}: {key}");
    }
    let referenced: BTreeSet<String> = regex::Regex::new(r"\bt '([^']*)'")
        .unwrap()
        .captures_iter(&source)
        .map(|capture| capture[1].to_owned())
        .collect();
    assert_consistent(
        "Install-Prunlet.sh",
        &tables,
        &translated_tags(),
        &referenced,
    );
    // fill <文言> <名前> <値> の名前が、その文言のプレースホルダーであること。
    let fill = regex::Regex::new(r#"fill "\$\(t '([^']*)'\)" ([a-z]+) "#).unwrap();
    for capture in fill.captures_iter(&source) {
        assert!(
            placeholders(&capture[1]).contains(&capture[2]),
            "fill name {} is not a placeholder of {}",
            &capture[2],
            &capture[1]
        );
    }
}
