// 人が端末で読む固定文言（現在は CLI のヘルプ）を、利用者の言語設定に合わせて出す。
//
// 判定順（D:\Dev\APP-DISTRIBUTION.md「8. ローカライズ」と Remnifold の locale.rs に揃える）:
// 1. PRUNLET_LANGUAGE（明示の上書き。テストや、OS と別の言語で使いたい利用者向け）
// 2. POSIX の LC_ALL → LC_MESSAGES → LANG（空・C・POSIX は「未設定」とみなして次へ進む）
// 3. OS の表示言語（Windows は GetUserDefaultUILanguage、macOS は AppleLanguages の先頭）
// 4. どれも判定できない・未対応の言語なら英語
//
// 対応言語は ja・en・zh-CN・zh-TW・ko・es・fr・de・pt-BR の9つ。文言は言語ごとの JSON 辞書
// （`locales/<タグ>.json`）に持ち、キーは英語の原文とする（en.json は原文を原文へ写す）。
// 辞書に無いキーは英語、英語にも無ければキーそのもの（＝英語の原文）を返すため、英語の出力は
// 辞書の有無に関係なく従来と同じ文字列になる。
//
// 注意: AI が読む文言（MCP ツールの説明・フックの拒否理由・共通指示）と、機械可読の出力
// （削除結果やエラーの JSON、フックのプロトコル応答）はここを通さず英語のまま固定する。
// 判定はヘルプ表示の経路だけで行い、hook・MCP・削除の経路では呼ばない（macOS は子プロセスを使うため）。
// 1プロセスで判定は1回だけ行い、結果を使い回す。
use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Language {
    Japanese,
    English,
    ChineseSimplified,
    ChineseTraditional,
    Korean,
    Spanish,
    French,
    German,
    PortugueseBrazil,
}

impl Language {
    /// 対応する全言語。辞書ファイルの一覧・整合テストはこの並びを基準にする。
    pub const ALL: [Language; 9] = [
        Language::Japanese,
        Language::English,
        Language::ChineseSimplified,
        Language::ChineseTraditional,
        Language::Korean,
        Language::Spanish,
        Language::French,
        Language::German,
        Language::PortugueseBrazil,
    ];

    /// 辞書ファイル名にも使う言語タグ。
    pub fn tag(self) -> &'static str {
        match self {
            Language::Japanese => "ja",
            Language::English => "en",
            Language::ChineseSimplified => "zh-CN",
            Language::ChineseTraditional => "zh-TW",
            Language::Korean => "ko",
            Language::Spanish => "es",
            Language::French => "fr",
            Language::German => "de",
            Language::PortugueseBrazil => "pt-BR",
        }
    }

    /// 辞書の JSON 原文（コンパイル時に埋め込む。配布物へ別ファイルを足さないため）。
    pub fn dictionary_source(self) -> &'static str {
        match self {
            Language::Japanese => include_str!("locales/ja.json"),
            Language::English => include_str!("locales/en.json"),
            Language::ChineseSimplified => include_str!("locales/zh-CN.json"),
            Language::ChineseTraditional => include_str!("locales/zh-TW.json"),
            Language::Korean => include_str!("locales/ko.json"),
            Language::Spanish => include_str!("locales/es.json"),
            Language::French => include_str!("locales/fr.json"),
            Language::German => include_str!("locales/de.json"),
            Language::PortugueseBrazil => include_str!("locales/pt-BR.json"),
        }
    }

    fn index(self) -> usize {
        Language::ALL
            .iter()
            .position(|language| *language == self)
            .expect("every language is listed")
    }
}

static CURRENT: OnceLock<Language> = OnceLock::new();

/// 現在の環境の言語。初回呼び出しで判定し、以後は同じ値を返す。
pub fn current() -> Language {
    *CURRENT.get_or_init(detect)
}

fn detect() -> Language {
    // 明示の上書きと POSIX のロケール変数は、空・C・POSIX 以外なら最初に見つかった値で決める。
    for name in ["PRUNLET_LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"] {
        if let Some(language) = std::env::var(name).ok().as_deref().and_then(parse) {
            return language;
        }
    }
    os_language().unwrap_or(Language::English)
}

/// `ja`、`ja_JP.UTF-8`、`zh-Hant-TW`、`pt_BR`、`Japanese_Japan.932` などを対応言語に照合する。
/// 照合規則: `zh-Hans`・`zh-CN`・`zh-SG` は zh-CN、`zh-Hant`・`zh-TW`・`zh-HK`・`zh-MO` は zh-TW、
/// `pt`（`pt-PT` を含む）は pt-BR、それ以外は主言語で照合する。未対応の言語は英語。
/// 空文字・`C`・`POSIX`（`C.UTF-8` を含む）は判定材料にならないため None を返す。
pub fn parse(value: &str) -> Option<Language> {
    let value = value.trim();
    let base = value
        .split(['.', '@'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    if base.is_empty() || base == "c" || base == "posix" {
        return None;
    }
    let mut subtags = base.split(['_', '-']);
    let primary = subtags.next().unwrap_or_default();
    let rest: Vec<&str> = subtags.collect();
    Some(match primary {
        "ja" | "japanese" => Language::Japanese,
        "zh" => chinese(&rest),
        // Windows の英語名ロケール（`Chinese (Traditional)_Taiwan.950` など）。
        name if name.starts_with("chinese") => {
            if ["traditional", "taiwan", "hong kong", "macao", "macau"]
                .iter()
                .any(|marker| base.contains(marker))
            {
                Language::ChineseTraditional
            } else {
                Language::ChineseSimplified
            }
        }
        "ko" | "korean" => Language::Korean,
        "es" | "spanish" => Language::Spanish,
        "fr" | "french" => Language::French,
        "de" | "german" => Language::German,
        "pt" | "portuguese" => Language::PortugueseBrazil,
        _ => Language::English,
    })
}

/// `zh` の続きのタグから簡体字・繁体字を決める。文字体系（Hans/Hant）を地域より優先し、
/// どちらも無い `zh` だけの指定は簡体字とする。
fn chinese(rest: &[&str]) -> Language {
    if rest.contains(&"hant") {
        return Language::ChineseTraditional;
    }
    if rest.contains(&"hans") {
        return Language::ChineseSimplified;
    }
    if rest.iter().any(|tag| ["tw", "hk", "mo"].contains(tag)) {
        return Language::ChineseTraditional;
    }
    Language::ChineseSimplified
}

#[cfg(windows)]
fn os_language() -> Option<Language> {
    // LANGID の下位10bitが主言語、上位6bitが副言語。中国語は副言語で簡体字・繁体字を分ける。
    let id = unsafe { windows_sys::Win32::Globalization::GetUserDefaultUILanguage() };
    Some(language_from_langid(id))
}

/// Windows の LANGID を対応言語へ変換する。未対応の言語は英語。
#[cfg_attr(not(windows), allow(dead_code))]
fn language_from_langid(id: u16) -> Language {
    match id & 0x3ff {
        0x11 => Language::Japanese,
        0x12 => Language::Korean,
        0x0a => Language::Spanish,
        0x0c => Language::French,
        0x07 => Language::German,
        // pt-PT（0x0816）も pt-BR として扱う。
        0x16 => Language::PortugueseBrazil,
        0x04 => {
            // 副言語: 0x01 台湾・0x03 香港・0x05 マカオ・0x1f（zh-Hant 0x7c04）は繁体字。
            match id >> 10 {
                0x01 | 0x03 | 0x05 | 0x1f => Language::ChineseTraditional,
                _ => Language::ChineseSimplified,
            }
        }
        _ => Language::English,
    }
}

#[cfg(target_os = "macos")]
fn os_language() -> Option<Language> {
    // GUI から起動されたホストなどでは LANG が無いことがあるため、OS の言語順の先頭を読む。
    // 出力は `(\n    "ja-JP",\n    "en-JP"\n)` の形式。固定の絶対パスだけを起動する。
    let output = std::process::Command::new("/usr/bin/defaults")
        .args(["read", "-g", "AppleLanguages"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    let text = String::from_utf8_lossy(&output.stdout);
    let first = text
        .split(['(', ')', ',', '\n'])
        .map(|part| part.trim().trim_matches('"'))
        .find(|part| !part.is_empty())?;
    parse(first)
}

#[cfg(not(any(windows, target_os = "macos")))]
fn os_language() -> Option<Language> {
    None
}

type Dictionary = HashMap<String, String>;

/// 言語ごとの辞書。初回参照時に JSON を読み、以後は使い回す（壊れた辞書は空として扱い、英語へ落とす）。
fn dictionary(language: Language) -> &'static Dictionary {
    static DICTIONARIES: [OnceLock<Dictionary>; 9] = [const { OnceLock::new() }; 9];
    DICTIONARIES[language.index()]
        .get_or_init(|| serde_json::from_str(language.dictionary_source()).unwrap_or_default())
}

/// 指定した言語でキーの文言を返す。辞書に無ければ英語、英語にも無ければキーそのもの。
pub fn tr_in(language: Language, key: &'static str) -> &'static str {
    dictionary(language)
        .get(key)
        .or_else(|| dictionary(Language::English).get(key))
        .map_or(key, String::as_str)
}

/// 現在の言語でキーの文言を返す。
pub fn tr(key: &'static str) -> &'static str {
    tr_in(current(), key)
}

/// `{name}` 形式のプレースホルダーを値に置き換える。
pub fn fill(template: &str, values: &[(&str, &str)]) -> String {
    let mut result = template.to_owned();
    for (name, value) in values {
        result = result.replace(&format!("{{{name}}}"), value);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn parses_locale_identifiers() {
        for value in [
            "ja",
            "ja_JP.UTF-8",
            "ja-JP",
            "JA_jp",
            "Japanese_Japan.932",
            "ja_JP@calendar=japanese",
        ] {
            assert_eq!(parse(value), Some(Language::Japanese), "{value}");
        }
        for value in ["en_US.UTF-8", "en", "en-GB", "it_IT", "ru"] {
            assert_eq!(parse(value), Some(Language::English), "{value}");
        }
        for value in ["", "  ", "C", "C.UTF-8", "POSIX"] {
            assert_eq!(parse(value), None, "{value:?}");
        }
    }

    #[test]
    fn matches_chinese_scripts_and_regions() {
        for value in [
            "zh",
            "zh-CN",
            "zh_CN.UTF-8",
            "zh-Hans",
            "zh-Hans-CN",
            "zh-SG",
            "zh-Hans-SG",
            "zh-Hans-HK",
            "Chinese_China.936",
        ] {
            assert_eq!(parse(value), Some(Language::ChineseSimplified), "{value}");
        }
        for value in [
            "zh-TW",
            "zh_TW.UTF-8",
            "zh-Hant",
            "zh-Hant-TW",
            "zh-HK",
            "zh-MO",
            "zh-Hant-CN",
            "Chinese (Traditional)_Taiwan.950",
        ] {
            assert_eq!(parse(value), Some(Language::ChineseTraditional), "{value}");
        }
    }

    #[test]
    fn matches_other_primary_languages() {
        for (value, expected) in [
            ("ko", Language::Korean),
            ("ko_KR.UTF-8", Language::Korean),
            ("Korean_Korea.949", Language::Korean),
            ("es", Language::Spanish),
            ("es-MX", Language::Spanish),
            ("es_ES@euro", Language::Spanish),
            ("fr_FR@euro", Language::French),
            ("fr-CA", Language::French),
            ("de_DE", Language::German),
            ("de-AT", Language::German),
            ("pt", Language::PortugueseBrazil),
            ("pt-BR", Language::PortugueseBrazil),
            ("pt_PT.UTF-8", Language::PortugueseBrazil),
            ("Portuguese_Brazil.1252", Language::PortugueseBrazil),
        ] {
            assert_eq!(parse(value), Some(expected), "{value}");
        }
    }

    #[test]
    fn maps_windows_language_ids() {
        for (id, expected) in [
            (0x0411, Language::Japanese),
            (0x0409, Language::English),
            (0x0804, Language::ChineseSimplified),
            (0x1004, Language::ChineseSimplified),
            (0x0004, Language::ChineseSimplified),
            (0x0404, Language::ChineseTraditional),
            (0x0c04, Language::ChineseTraditional),
            (0x1404, Language::ChineseTraditional),
            (0x7c04, Language::ChineseTraditional),
            (0x0412, Language::Korean),
            (0x0c0a, Language::Spanish),
            (0x040c, Language::French),
            (0x0407, Language::German),
            (0x0416, Language::PortugueseBrazil),
            (0x0816, Language::PortugueseBrazil),
            (0x0410, Language::English),
        ] {
            assert_eq!(language_from_langid(id), expected, "{id:#06x}");
        }
    }

    #[test]
    fn tags_are_unique_and_round_trip() {
        let tags: BTreeSet<_> = Language::ALL.iter().map(|l| l.tag()).collect();
        assert_eq!(tags.len(), Language::ALL.len());
        for language in Language::ALL {
            assert_eq!(parse(language.tag()), Some(language));
        }
    }

    #[test]
    fn missing_keys_fall_back_to_english_then_key() {
        assert_eq!(
            tr_in(Language::French, "no.such.key"),
            "no.such.key",
            "unknown keys return themselves"
        );
    }
}
