//! 検証出力先の共通ガード。hookの実プロセス検証は`scripts/Verify-HookParsing.ps1`が
//! 全ケース（`src/rust/protocol/tests/hook-posix.json`を含む）を担うため、ここには専用の実行器を持たない。
use anyhow::{Context, Result, ensure};
use std::{
    fs,
    os::windows::fs::MetadataExt,
    path::{Path, PathBuf},
};

/// 検証出力先を作る。ドライブ文字には依存させず、通常のドライブ絶対パス（UNC・デバイスパス不可）で、
/// リポジトリとCodex homeの外にある未使用のディレクトリだけを受け付ける。
pub(crate) fn output_directory(path: &Path) -> Result<()> {
    let raw = path.to_string_lossy();
    let bytes = raw.as_bytes();
    ensure!(
        path.is_absolute()
            && bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && bytes[2] == b'\\',
        "Output must be an ordinary drive-absolute path outside the repository and Codex home; UNC and device paths are unsupported"
    );
    ensure!(!path.exists(), "Output directory already exists");
    let parent = path.parent().context("Output parent is missing")?;
    for ancestor in parent.ancestors() {
        let metadata = fs::symlink_metadata(ancestor)?;
        ensure!(
            metadata.is_dir() && metadata.file_attributes() & 0x400 == 0,
            "Output ancestor is not an ordinary directory: {}",
            ancestor.display()
        );
    }
    let parent = fs::canonicalize(parent)?;
    let repo = fs::canonicalize(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .context("Missing tools directory")?
            .parent()
            .context("Missing repository")?,
    )?;
    let mut excluded_roots = vec![repo];
    // Codex homeは存在する場合だけ除外する。未導入の環境でcanonicalizeが失敗して止まらないようにする。
    let homes = [
        std::env::var_os("USERPROFILE").map(|p| PathBuf::from(p).join(".codex")),
        std::env::var_os("CODEX_HOME").map(PathBuf::from),
    ];
    for home in homes.into_iter().flatten() {
        if home.exists() {
            excluded_roots.push(home);
        }
    }
    let normalized = parent.to_string_lossy().to_lowercase();
    for excluded in excluded_roots {
        let excluded = fs::canonicalize(excluded)?.to_string_lossy().to_lowercase();
        ensure!(
            normalized != excluded && !normalized.starts_with(&(excluded + "\\")),
            "Output inside repository or Codex home is excluded"
        );
    }
    // create_dirは既存対象を上書きせず、親の書込み可否もここで検査する。
    fs::create_dir(path)?;
    Ok(())
}
