//! Setup（Velopack）版が読み書きする場所の解決。
//!
//! # 置き場の契約（`D:\tmp\prunlet-velopack\design.md` のパス契約）
//! - 状態（ロック・適用中マーカー・設定・ログ・導入記録）: `%LOCALAPPDATA%\Prunlet\state\`
//! - フックの複製: `%LOCALAPPDATA%\Prunlet\hook\prunlet-hook.exe`
//! - 新規利用者の config: `%LOCALAPPDATA%\Prunlet\config.json`
//! - 旧導入（≤1.0.47）の利用者の config・recovery: `%USERPROFILE%\.local\Prunlet\` をそのまま使い続ける。
//!
//! どれも Velopack の root（`%LOCALAPPDATA%\<packId>`）の外に置く。root は更新のたびに入れ替わり、
//! アンインストールで消えるため、削除ガードの状態を置くと更新中に壊れる、または一緒に消えるからである。
//!
//! # 隔離テスト（`velopack-test` 機能）
//! 配布ビルドでは実環境の場所しか返さない。`velopack-test` を付けたビルドだけが差し替え用の環境変数を読み、
//! **環境変数が無い項目は `None`（何もしない）** を返す。実機の `~/.claude`・`%LOCALAPPDATA%\Prunlet`・
//! `%APPDATA%` へフォールバックして書き込む事故を、構造的に起こさないためである。
//! 使う環境変数（梱包担当の E2E が設定する）:
//! - `PRUNLET_VELOPACK_TEST_DATA_DIR` … `%LOCALAPPDATA%\Prunlet` の代わり
//! - `PRUNLET_VELOPACK_TEST_HOME` … `%USERPROFILE%` の代わり（`.local\Prunlet`・`.claude`・`.codex` の親）
//! - `PRUNLET_VELOPACK_TEST_APPDATA` … `%APPDATA%` の代わり（Toolport の registry.json の親）
//! - `CLAUDE_CONFIG_DIR` … `~/.claude` の代わり（テスト用機能でのみ読む）
//! - `CODEX_HOME` … `~/.codex` の代わり（テスト用機能でのみ読む）
use std::path::{Path, PathBuf};

/// 環境変数が絶対パスのときだけ採用する（相対パスは実行場所で意味が変わるため無視する）。
fn absolute_env(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

/// `%LOCALAPPDATA%\Prunlet`（状態・フック複製・新規 config の親）。
pub fn data_dir() -> Option<PathBuf> {
    #[cfg(feature = "velopack-test")]
    {
        absolute_env("PRUNLET_VELOPACK_TEST_DATA_DIR")
    }
    #[cfg(not(feature = "velopack-test"))]
    {
        absolute_env("LOCALAPPDATA").map(|dir| dir.join("Prunlet"))
    }
}

/// 状態フォルダー。
pub fn state_dir() -> Option<PathBuf> {
    data_dir().map(|dir| dir.join("state"))
}

/// フック複製のフォルダー。
pub fn hook_dir() -> Option<PathBuf> {
    data_dir().map(|dir| dir.join("hook"))
}

/// フック複製の実行ファイルのパス（ホスト設定が参照する）。
pub fn hook_executable() -> Option<PathBuf> {
    hook_dir().map(|dir| dir.join(HOOK_FILE_NAME))
}

/// フック複製のファイル名。`cli::run` がこの名前でフックの入口を選ぶ。
pub const HOOK_FILE_NAME: &str = "prunlet-hook.exe";

/// 利用者のホーム。
pub fn home_dir() -> Option<PathBuf> {
    #[cfg(feature = "velopack-test")]
    {
        absolute_env("PRUNLET_VELOPACK_TEST_HOME")
    }
    #[cfg(not(feature = "velopack-test"))]
    {
        absolute_env("USERPROFILE")
    }
}

/// `%APPDATA%`（Toolport の登録の親）。
pub fn roaming_dir() -> Option<PathBuf> {
    #[cfg(feature = "velopack-test")]
    {
        absolute_env("PRUNLET_VELOPACK_TEST_APPDATA")
    }
    #[cfg(not(feature = "velopack-test"))]
    {
        absolute_env("APPDATA")
    }
}

/// Claude Code の設定フォルダー（`~/.claude`）。
pub fn claude_dir() -> Option<PathBuf> {
    #[cfg(feature = "velopack-test")]
    {
        absolute_env("CLAUDE_CONFIG_DIR")
    }
    #[cfg(not(feature = "velopack-test"))]
    {
        home_dir().map(|home| home.join(".claude"))
    }
}

/// Codex のホーム（`~/.codex`）。
pub fn codex_dir() -> Option<PathBuf> {
    #[cfg(feature = "velopack-test")]
    {
        absolute_env("CODEX_HOME")
    }
    #[cfg(not(feature = "velopack-test"))]
    {
        absolute_env("CODEX_HOME").or_else(|| home_dir().map(|home| home.join(".codex")))
    }
}

/// Toolport の登録ファイル（`%APPDATA%\Toolport\registry.json`）。
pub fn toolport_registry() -> Option<PathBuf> {
    roaming_dir().map(|dir| dir.join("Toolport").join("registry.json"))
}

/// 旧導入（≤1.0.47）のルート（`%USERPROFILE%\.local\Prunlet`）。
pub fn legacy_root() -> Option<PathBuf> {
    home_dir().map(|home| home.join(".local").join("Prunlet"))
}

/// 旧導入の `bin`（旧 CLI・旧 hook の置き場。消さない・シムも作らない）。
pub fn legacy_bin() -> Option<PathBuf> {
    legacy_root().map(|root| root.join("bin"))
}

/// どの config を使うか。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigChoice {
    pub path: PathBuf,
    /// `legacy`（旧導入の config をそのまま使う）か `new`（新規利用者の置き場）。
    pub source: &'static str,
    pub exists: bool,
}

/// 旧導入の config があればそれを、無ければ新規の置き場を返す。
/// どちらの場所も解決できない（テスト用ビルドで環境変数が無いなど）場合は None。
pub fn resolve_config() -> Option<ConfigChoice> {
    choose_config(legacy_root().as_deref(), data_dir().as_deref())
}

/// [`resolve_config`] の本体（場所を引数で受ける）。
pub fn choose_config(legacy_root: Option<&Path>, data_dir: Option<&Path>) -> Option<ConfigChoice> {
    if let Some(root) = legacy_root {
        let path = root.join("config.json");
        if path.is_file() {
            return Some(ConfigChoice {
                path,
                source: "legacy",
                exists: true,
            });
        }
    }
    let path = data_dir?.join("config.json");
    let exists = path.is_file();
    Some(ConfigChoice {
        path,
        source: "new",
        exists,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "prunlet-paths-{name}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn legacy_config_wins_only_when_it_exists() {
        let legacy = scratch("legacy");
        let data = scratch("data");
        // 旧 config が無ければ新規の置き場（まだ無くてもパスは返す）。
        let choice = choose_config(Some(&legacy), Some(&data)).unwrap();
        assert_eq!(choice.source, "new");
        assert!(!choice.exists);
        assert_eq!(choice.path, data.join("config.json"));
        // 旧 config があれば、それをそのまま使い続ける。
        std::fs::write(legacy.join("config.json"), b"{}").unwrap();
        let choice = choose_config(Some(&legacy), Some(&data)).unwrap();
        assert_eq!(choice.source, "legacy");
        assert!(choice.exists);
        // どちらも解決できなければ None。
        assert!(choose_config(None, None).is_none());
        let _ = std::fs::remove_dir_all(&legacy);
        let _ = std::fs::remove_dir_all(&data);
    }
}
