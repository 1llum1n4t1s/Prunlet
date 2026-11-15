//! 旧導入（≤1.0.47、`%USERPROFILE%\.local\Prunlet\bin`）の検知。
//!
//! 旧導入は**検知して案内するだけ**で、消さない・シムも作らない（protocol・storageEpoch も変えない）。
//! - 旧導入の `.prunlet-update-state.json` が `idle` でない config では、Setup 版は起動を拒否し、
//!   旧 launcher での回復を案内する（旧更新の途中状態を、新しい exe が読み書きして壊さないため）。
//! - `.prunlet-update-state.*.pending` が残っていても警告するだけで拒否しない。
use std::path::Path;

use serde::Serialize;

/// 旧更新の状態ファイル名（`update::state::STATE_NAME` と同じ。旧コードは変更しないので値を写す）。
const STATE_NAME: &str = ".prunlet-update-state.json";

/// 検知結果。
#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyInfo {
    /// 旧 `bin\prunlet.exe` が残っている。
    pub installed: bool,
    /// 旧更新の状態（`idle` など。ファイルが無ければ None）。
    pub update_phase: Option<String>,
    /// 残っている `.pending` の数（警告のみ）。
    pub pending_files: usize,
}

/// `root`（旧導入のルート）を調べる。
pub fn inspect(root: &Path) -> LegacyInfo {
    let installed = root.join("bin").join("prunlet.exe").is_file();
    let update_phase = std::fs::read(root.join(STATE_NAME)).ok().map(|bytes| {
        serde_json::from_slice::<serde_json::Value>(&bytes)
            .ok()
            .and_then(|v| v.get("phase").and_then(|p| p.as_str()).map(str::to_owned))
            // 読めない・phase が無い状態は、完了していないものとして扱う。
            .unwrap_or_else(|| "unreadable".to_owned())
    });
    let pending_files = std::fs::read_dir(root).map_or(0, |entries| {
        entries
            .flatten()
            .filter(|entry| {
                let name = entry.file_name().to_string_lossy().into_owned();
                name.starts_with(".prunlet-update-state.") && name.ends_with(".pending")
            })
            .count()
    });
    LegacyInfo {
        installed,
        update_phase,
        pending_files,
    }
}

/// 旧更新が途中なら、起動を拒否するエラーを返す。`config` と同じフォルダー（旧導入では旧導入のルート）の
/// 旧更新の状態ファイルを見る。新規利用者の config のフォルダーには状態ファイルが無いので、何も起きない。
pub fn refuse_if_unfinished(config: &Path) -> Result<(), String> {
    let Some(root) = config.parent() else {
        return Ok(());
    };
    let info = inspect(root);
    match info.update_phase.as_deref() {
        None | Some("idle") => Ok(()),
        Some(phase) => Err(format!(
            "The legacy Prunlet update is unfinished (phase: {phase}). Recover it first by starting the legacy installation once: {}\\bin\\prunlet.exe. The command was not run.",
            root.display()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("prunlet-legacy-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        dir
    }

    #[test]
    fn unfinished_legacy_update_blocks_and_pending_only_warns() {
        let root = scratch();
        let config = root.join("config.json");
        // 何も無ければ通る。
        assert_eq!(inspect(&root), LegacyInfo::default());
        assert!(refuse_if_unfinished(&config).is_ok());
        // 旧 CLI の存在は検知する。
        std::fs::write(root.join("bin").join("prunlet.exe"), b"x").unwrap();
        assert!(inspect(&root).installed);
        // idle は通る。
        std::fs::write(root.join(STATE_NAME), br#"{"phase":"idle"}"#).unwrap();
        assert!(refuse_if_unfinished(&config).is_ok());
        // `.pending` だけは警告（数える）で、拒否しない。
        std::fs::write(root.join(".prunlet-update-state.abc.pending"), b"x").unwrap();
        assert_eq!(inspect(&root).pending_files, 1);
        assert!(refuse_if_unfinished(&config).is_ok());
        // idle でない・読めない状態は拒否し、回復の案内を含める。
        for body in [&br#"{"phase":"switching"}"#[..], b"{ broken", b"{}"] {
            std::fs::write(root.join(STATE_NAME), body).unwrap();
            let error = refuse_if_unfinished(&config).unwrap_err();
            assert!(error.contains("Recover it first"), "{error}");
        }
        let _ = std::fs::remove_dir_all(&root);
    }
}
