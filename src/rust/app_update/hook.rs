//! フック複製（`%LOCALAPPDATA%\Prunlet\hook\prunlet-hook.exe`）の配置。
//!
//! hook は Velopack の root の外から動かす。root の入れ替え（Update.exe の適用）やアンインストールの最中でも、
//! hook が起動失敗せず、必ず deny か allow を返せるようにするためである（hook はロックにも参加しない）。
//!
//! 配置の手順（名前が無い瞬間を作らない）:
//! 1. 署名済みの `current\prunlet.exe` を、同じフォルダーの一時名へ複製する。
//! 2. 複製の SHA-256 が元と一致することを確かめる（呼び出し側が渡す検証関数で署名も確かめる）。
//! 3. 一時名を `prunlet-hook.exe` へ上書き rename する。
//!
//! 実行中の hook がある・ウイルス対策が掴んでいるなどで上書きできないときは、旧 hook を**そのまま残して**
//! 延期する（[`Outcome::Deferred`]）。次のログオン・MCP 起動・`setup repair` で再試行する。旧 hook を先に消す
//! ことはしない。
use std::{
    fs, io,
    path::{Path, PathBuf},
};

use super::trust::sha256_file;

/// 配置の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// 新しく作った。
    Created,
    /// 内容を更新した。
    Updated,
    /// すでに同じ内容だった。
    Unchanged,
    /// 上書きできず旧 hook を残した（理由つき）。
    Deferred(String),
}

/// 一時名の接頭辞・接尾辞（残骸の掃除にも使う）。
const TEMP_PREFIX: &str = "prunlet-hook.";
const TEMP_SUFFIX: &str = ".tmp";

/// `source`（`current\prunlet.exe`）を `directory\prunlet-hook.exe` として配置する。
/// `verify` は複製に対する追加の検証（本番は署名の確認）。失敗したら配置しない。
/// 失敗（Err）は「複製を作れなかった・検証に通らなかった」で、旧 hook は変わらない。
pub fn install(
    source: &Path,
    directory: &Path,
    verify: &dyn Fn(&Path) -> Result<(), String>,
) -> Result<Outcome, String> {
    let destination = directory.join(super::paths::HOOK_FILE_NAME);
    let source_hash = sha256_file(source).map_err(|e| format!("The CLI cannot be read: {e}"))?;
    if destination.is_file() && sha256_file(&destination).ok().as_deref() == Some(&source_hash) {
        return Ok(Outcome::Unchanged);
    }
    fs::create_dir_all(directory).map_err(|e| format!("The hook folder cannot be created: {e}"))?;
    sweep_temporary(directory);
    let temporary: PathBuf = directory.join(format!(
        "{TEMP_PREFIX}{}{TEMP_SUFFIX}",
        uuid::Uuid::new_v4().simple()
    ));
    let existed = destination.is_file();
    let prepared = (|| -> Result<(), String> {
        fs::copy(source, &temporary).map_err(|e| format!("The hook cannot be copied: {e}"))?;
        // 内容をディスクへ確定してから rename する（電源断などで、名前だけ新しく中身が欠けた hook を残さない）。
        fs::OpenOptions::new()
            .write(true)
            .open(&temporary)
            .and_then(|file| file.sync_all())
            .map_err(|e| format!("The hook copy cannot be flushed: {e}"))?;
        let copied =
            sha256_file(&temporary).map_err(|e| format!("The hook copy cannot be read: {e}"))?;
        if copied != source_hash {
            return Err("The hook copy does not match the CLI.".into());
        }
        verify(&temporary)
    })();
    if let Err(error) = prepared {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    match rename_over(&temporary, &destination) {
        Ok(()) => Ok(if existed {
            Outcome::Updated
        } else {
            Outcome::Created
        }),
        Err(error) => {
            // 使用中などで置き換えられない。旧 hook を残し、一時ファイルだけを片付けて延期する。
            let _ = fs::remove_file(&temporary);
            Ok(Outcome::Deferred(format!(
                "The existing hook could not be replaced ({error}); it was kept."
            )))
        }
    }
}

/// 既存を上書きする rename（Windows の `MoveFileExW(REPLACE_EXISTING)` と同じで、`fs::rename` が行う）。
fn rename_over(from: &Path, to: &Path) -> io::Result<()> {
    fs::rename(from, to)
}

/// 過去の失敗で残った一時ファイルを片付ける（自分の命名のものだけ）。
fn sweep_temporary(directory: &Path) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(TEMP_PREFIX) && name.ends_with(TEMP_SUFFIX) {
            let _ = fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("prunlet-hook-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn ok(_: &Path) -> Result<(), String> {
        Ok(())
    }

    #[test]
    fn hook_is_created_updated_and_left_alone_when_unchanged() {
        let dir = scratch();
        let source = dir.join("prunlet.exe");
        let hooks = dir.join("hook");
        fs::write(&source, b"v1").unwrap();
        assert_eq!(install(&source, &hooks, &ok).unwrap(), Outcome::Created);
        assert_eq!(fs::read(hooks.join("prunlet-hook.exe")).unwrap(), b"v1");
        assert_eq!(install(&source, &hooks, &ok).unwrap(), Outcome::Unchanged);
        fs::write(&source, b"v2").unwrap();
        assert_eq!(install(&source, &hooks, &ok).unwrap(), Outcome::Updated);
        assert_eq!(fs::read(hooks.join("prunlet-hook.exe")).unwrap(), b"v2");
        // 一時ファイルを残さない。
        assert_eq!(fs::read_dir(&hooks).unwrap().count(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn failed_verification_keeps_the_old_hook() {
        let dir = scratch();
        let source = dir.join("prunlet.exe");
        let hooks = dir.join("hook");
        fs::write(&source, b"v1").unwrap();
        install(&source, &hooks, &ok).unwrap();
        fs::write(&source, b"v2").unwrap();
        let error = install(&source, &hooks, &|_| Err("unsigned".into())).unwrap_err();
        assert_eq!(error, "unsigned");
        assert_eq!(fs::read(hooks.join("prunlet-hook.exe")).unwrap(), b"v1");
        assert_eq!(fs::read_dir(&hooks).unwrap().count(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_running_hook_is_kept_and_the_update_is_deferred() {
        let dir = scratch();
        let hooks = dir.join("hook");
        fs::create_dir_all(&hooks).unwrap();
        // 実行中の実行ファイルは上書きできない（本物の ping.exe の複製を hook として動かす）。
        let system = std::env::var_os("SystemRoot")
            .map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from);
        let hook = hooks.join("prunlet-hook.exe");
        fs::copy(system.join("System32").join("ping.exe"), &hook).unwrap();
        let old = fs::read(&hook).unwrap();
        let mut child = std::process::Command::new(&hook)
            .args(["-n", "20", "127.0.0.1"])
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let source = dir.join("prunlet.exe");
        fs::write(&source, b"new").unwrap();
        let outcome = install(&source, &hooks, &ok).unwrap();
        let _ = child.kill();
        let _ = child.wait();
        assert!(matches!(outcome, Outcome::Deferred(_)), "{outcome:?}");
        // 旧 hook はそのまま、一時ファイルも残っていない。
        assert_eq!(fs::read(&hook).unwrap(), old);
        assert_eq!(fs::read_dir(&hooks).unwrap().count(), 1);
        // 止まった後なら更新できる。
        assert_eq!(install(&source, &hooks, &ok).unwrap(), Outcome::Updated);
        let _ = fs::remove_dir_all(&dir);
    }
}
