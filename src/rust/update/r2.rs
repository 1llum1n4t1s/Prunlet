//! Unix 版（macOS・Linux）の起動時更新の取得。配布元は R2（`https://prunlet.kagayoi.com`）。
//!
//! 旧実装（GitHub の `releases/latest`・`commits/{tag}`・compare API・asset の digest）は使わない。
//! 信頼の基点は `latest/<runtime>.json` の署名付きマニフェストだけで、判定は [`super::manifest`] に集約している。
//! ここは「curl でリダイレクトを辿らずに取得する」ことと、OS 側の呼出し形に合わせることだけを持つ。
//! 展開・配置・実行体の自己申告（版・commit）や署名要件の照合は、各 OS の実装（`platform/*/startup.rs`）が行う。
use super::{
    manifest::{self, Runtime},
    package::is_hex,
};
use anyhow::{Context, Result, ensure};
use std::{
    io::Read,
    process::{Command, Stdio},
};

pub(crate) use super::manifest::Candidate;

/// マニフェストの取得の時間制限（秒）。起動を長く止めない。
const MANIFEST_SECONDS: u32 = 5;
/// 配布物の取得の時間制限（秒）。
const ASSET_SECONDS: u32 = 30;

/// HTTPS で1回だけ取得する。リダイレクトは辿らない（`--location` を付けない・`--max-redirs 0`）。
/// 3xx の本文が返っても、署名・長さ・SHA-256 の照合で必ず拒否される（fail-closed）。
pub(crate) fn request(url: &str, limit: u64, seconds: u32) -> Result<Vec<u8>> {
    // curlrc を読まず（--disable）、HTTPS と最大転送量・時間を固定する。
    let mut child = Command::new("/usr/bin/curl")
        .args([
            "--disable",
            "--fail",
            "--silent",
            "--max-redirs",
            "0",
            "--proto",
            "=https",
            "--max-time",
            &seconds.to_string(),
            "--max-filesize",
            &limit.to_string(),
            "--header",
            "User-Agent: Prunlet",
            "--",
            url,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut bytes = Vec::new();
    let read = child
        .stdout
        .take()
        .context("Missing transfer stream")?
        .take(limit + 1)
        .read_to_end(&mut bytes);
    if read.is_err() || bytes.len() as u64 > limit {
        let _ = child.kill();
    }
    let status = child.wait()?;
    read?;
    ensure!(
        status.success() && bytes.len() as u64 <= limit,
        "Distribution response failed or exceeded its limit"
    );
    Ok(bytes)
}

/// 署名付きの最新ポインタを検証し、導入済みより厳密に新しい場合だけ、不変 URL から配布物を取得して照合する。
/// 同版・旧版は `Ok(None)`（毎回の起動で延期ログを出さない）。取得失敗・検証失敗は Err（呼出し側で延期）。
pub(crate) fn newer(
    fetch: impl Fn(&str, u64, u32) -> Result<Vec<u8>>,
    installed_commit: &str,
    runtime: Runtime,
) -> Result<Option<Candidate>> {
    // 公式ビルド（commit を埋め込んだもの）だけが更新する。
    ensure!(is_hex(installed_commit, 40), "Installed commit is unknown");
    let latest = manifest::latest_url(runtime)?;
    let adapter = |url: &str, limit: u64| {
        let seconds = if url == latest {
            MANIFEST_SECONDS
        } else {
            ASSET_SECONDS
        };
        fetch(url, limit, seconds)
    };
    manifest::unix_candidate(&adapter, runtime, crate::VERSION)
}
