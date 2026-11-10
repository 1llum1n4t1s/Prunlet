//! Unix版の公開release照合。展開・配置・署名要件は各OSで扱う。
use super::package::is_hex;
use crate::json::parse_unique;
use anyhow::{Context, Result, ensure};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    io::Read,
    process::{Command, Stdio},
};

const REPO: &str = "1llum1n4t1s/Prunlet";

pub(crate) struct Candidate {
    pub version: String,
    pub commit: String,
    pub bytes: Vec<u8>,
}

pub(crate) fn request(url: &str, limit: u64, seconds: u32) -> Result<Vec<u8>> {
    // curlrcを読まず、HTTPSと最大転送量・時間を固定する。
    let mut child = Command::new("/usr/bin/curl")
        .args([
            "--disable",
            "--fail",
            "--silent",
            "--location",
            "--max-redirs",
            "3",
            "--proto",
            "=https",
            "--proto-redir",
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
        "GitHub response failed or exceeded its limit"
    );
    Ok(bytes)
}

fn version(text: &str) -> Option<[u64; 3]> {
    let mut result = [0; 3];
    let mut parts = text.split('.');
    for value in &mut result {
        let part = parts.next()?;
        if part.is_empty()
            || !part.bytes().all(|b| b.is_ascii_digit())
            || (part.len() > 1 && part.starts_with('0'))
        {
            return None;
        }
        *value = part.parse().ok()?;
    }
    parts.next().is_none().then_some(result)
}

pub(crate) fn newer(
    fetch: impl Fn(&str, u64, u32) -> Result<Vec<u8>>,
    installed_commit: &str,
    asset_name: &str,
    maximum: u64,
) -> Result<Option<Candidate>> {
    ensure!(is_hex(installed_commit, 40), "Installed commit is unknown");
    let api = |endpoint: &str| -> Result<Value> {
        parse_unique(&fetch(
            &format!("https://api.github.com/repos/{REPO}/{endpoint}"),
            8 * 1024 * 1024,
            5,
        )?)
    };
    let release = api("releases/latest")?;
    let tag = release["tag_name"]
        .as_str()
        .context("Release tag is missing")?;
    let candidate_version = tag.strip_prefix('v').context("Unsupported release tag")?;
    let candidate = version(candidate_version).context("Invalid release version")?;
    let installed = version(crate::VERSION).context("Invalid installed version")?;
    if candidate <= installed {
        return Ok(None);
    }
    ensure!(
        release["draft"] == false && release["prerelease"] == false,
        "Release is not stable"
    );
    let assets = release["assets"]
        .as_array()
        .context("Release assets missing")?;
    let mut matching = assets.iter().filter(|asset| asset["name"] == asset_name);
    let Some(asset) = matching.next() else {
        return Ok(None);
    };
    ensure!(
        matching.next().is_none() && asset["state"] == "uploaded",
        "Ambiguous release asset"
    );
    let size = asset["size"]
        .as_u64()
        .filter(|n| *n > 0 && *n <= maximum)
        .context("Invalid asset size")?;
    let digest = asset["digest"]
        .as_str()
        .and_then(|s| s.strip_prefix("sha256:"))
        .filter(|s| is_hex(s, 64))
        .context("Release asset has no SHA-256")?;
    let url = format!("https://github.com/{REPO}/releases/download/{tag}/{asset_name}");
    ensure!(
        asset["browser_download_url"] == url,
        "Unexpected release asset URL"
    );
    let candidate = api(&format!("commits/{tag}"))?;
    let commit = candidate["sha"]
        .as_str()
        .filter(|s| is_hex(s, 40))
        .context("Invalid release commit")?;
    let relation = api(&format!("compare/{installed_commit}...{commit}?per_page=1"))?;
    let main = api(&format!("compare/{commit}...main?per_page=1"))?;
    ensure!(
        relation["status"] == "ahead"
            && matches!(main["status"].as_str(), Some("ahead" | "identical")),
        "Release is not a newer main descendant"
    );
    let bytes = fetch(&url, size, 30)?;
    ensure!(
        bytes.len() as u64 == size
            && hex::encode(Sha256::digest(&bytes)).eq_ignore_ascii_case(digest),
        "Release asset differs from GitHub metadata"
    );
    Ok(Some(Candidate {
        version: candidate_version.into(),
        commit: commit.into(),
        bytes,
    }))
}
