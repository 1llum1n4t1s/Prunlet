use super::{
    budget,
    coordinator::*,
    package::{MAX_ARCHIVE_BYTES, is_hex},
};
use crate::platform::windows::{self as native, path};
use anyhow::{Context, Result, ensure};
use std::{
    path::Path,
    time::{Duration, Instant},
};
use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE};

pub(super) fn receive_release(
    root: &Path,
    repository: &str,
    commit: &str,
    asset: u64,
    hash: &str,
    bytes: u64,
    tag: Option<&str>,
) -> Result<bool> {
    ensure!(
        regex::Regex::new(r"\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\z")?
            .is_match(repository)
            && asset > 0
            && (1..=MAX_ARCHIVE_BYTES).contains(&bytes)
            && is_hex(hash, 64),
        "Published asset identity is invalid."
    );
    let url = if let Some(tag) = tag {
        ensure!(
            regex::Regex::new(r"\Av?[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.-]+)?\z")?
                .is_match(tag),
            "Published release tag is invalid."
        );
        let runtime = match std::env::consts::ARCH {
            "x86_64" => "win-x64",
            "aarch64" => "win-arm64",
            _ => anyhow::bail!("Published Windows runtime is unsupported."),
        };
        // APIで確認したdigestを使い、ZIP本体はREST枠を消費しない公開URLから取得する。
        format!(
            "https://github.com/{repository}/releases/download/{tag}/prunlet-update-{runtime}.zip"
        )
    } else {
        // 出荷済みlauncherからの引数を維持する。
        format!("https://api.github.com/repos/{repository}/releases/assets/{asset}")
    };
    receive_with(root, commit, hash, bytes, &url, |url| {
        super::http::get(url, Instant::now() + Duration::from_secs(120))
    })
}

/// 取得先の応答を`fetch`で差し替えられる形にした本体。状態遷移と既存ファイルの扱いを
/// ネットワークなしで検証できるよう、URLの組立てとは分けている。
pub(super) fn receive_with(
    root: &Path,
    commit: &str,
    hash: &str,
    bytes: u64,
    url: &str,
    fetch: impl FnOnce(&str) -> Result<super::http::Response>,
) -> Result<bool> {
    let stage = stage_path(root);
    let _parents = path::pin_directories(&stage)?;
    let _mutex = InstallationMutexes::acquire(root)?;
    let mut state = read_state(root)?.context("Published download has no prepared state")?;
    ensure!(
        state.phase == "idle"
            && state.stage_cleanup == "pending"
            && state.candidate_commit.eq_ignore_ascii_case(commit),
        "Published download does not match its prepared state."
    );
    verify_stage_owner(&stage, root, commit)?;
    budget::ensure(root, 0)?;
    let used = budget::measure(root)?;
    let mut existing = None;
    let destination = stage.join(&state.package_name);
    if let Ok(pin) = plain(&destination, GENERIC_READ | GENERIC_WRITE, 0) {
        let verified = (|| -> Result<_> {
            native::reject_named_streams(&destination)?;
            let mut file = stream(&pin)?;
            let actual = hash_stream(&mut file)?;
            let length = file.metadata()?.len();
            Ok((file, actual, length))
        })();
        if let Ok((file, actual, length)) = verified {
            if length == bytes && actual.eq_ignore_ascii_case(hash) {
                drop(file);
                drop(pin);
                state.package_status = "ready".into();
                state.package_previous_sha256 = hash.into();
                state.package_previous_bytes = bytes as i64;
                write_state(root, &state)?;
                return Ok(true);
            }
            // 上書きしてよいのは、stateが記録した名前の次の2つだけ。
            // - ready: 記録済みの長さ・hashと現物が一致する（来歴を確認済みの旧ZIP）。
            // - writing: 取得の途中で止まった部分ファイル。hashは確定していないので内容では
            //   判定せず、stateが書込み前に記録した名前・単一link・代替ストリームなし・長さが
            //   これから書く長さ（bytes）以下であることだけを条件にする。
            // 記録と異なる内容（readyなのに変わっている等）は上書きせず、下で新しい名前へ逃がす。
            let ready_unchanged = state.package_status == "ready"
                && state.package_previous_bytes == length as i64
                && state.package_previous_sha256.eq_ignore_ascii_case(&actual);
            let recorded_partial = state.package_status == "writing" && length <= bytes;
            if ready_unchanged || recorded_partial {
                existing = Some((pin, file, length));
            }
        }
    }
    let (pin, mut output) = if let Some((pin, file, length)) = existing {
        budget::ensure_snapshot(used, bytes.saturating_sub(length))?;
        state.package_status = "writing".into();
        let _guards = budget::with_guards(&[&pin])?;
        write_state(root, &state)?;
        (pin, file)
    } else {
        budget::ensure_snapshot(used, bytes)?;
        // 書込み中と記録した名前のファイルが失われている場合は、新しい名前を作らず記録済みの
        // 名前で作り直す（名前を失うと旧ファイルがstateから見えない孤児になる）。
        // 実体はあるが上書きできない（内容・代替ストリーム・linkの不一致）場合は保持して別名を使う。
        let recreate = state.package_status == "writing" && !exists(&destination)?;
        if !recreate {
            state.package_name = format!("package-{}.zip", uuid::Uuid::new_v4().simple());
        }
        state.package_status = "writing".into();
        write_state(root, &state)?;
        create_plain(&stage.join(&state.package_name))?
    };
    transfer(url, &mut output, bytes, hash, fetch)?;
    pin.verify_named()?;
    native::reject_named_streams(&stage.join(&state.package_name))?;
    drop(output);
    drop(pin);
    state.package_status = "ready".into();
    state.package_previous_sha256 = hash.into();
    state.package_previous_bytes = bytes as i64;
    write_state(root, &state)?;
    budget::ensure(root, 0)?;
    Ok(false)
}

fn transfer(
    url: &str,
    output: &mut std::fs::File,
    bytes: u64,
    hash: &str,
    fetch: impl FnOnce(&str) -> Result<super::http::Response>,
) -> Result<()> {
    let mut response = fetch(url)?;
    ensure!(
        response.length.is_none_or(|n| n == bytes),
        "Published package response length differs from its asset metadata"
    );
    copy_verified(&mut response.body, output, bytes, hash)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::Digest;
    use std::io::{Cursor, Read, Seek};

    fn contents(file: &mut std::fs::File) -> Vec<u8> {
        file.rewind().unwrap();
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).unwrap();
        bytes
    }

    #[test]
    fn selected_endpoint_stream_is_verified_and_failure_has_no_fallback() -> Result<()> {
        // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
        let parent = native::path::external_test_temp()?;
        let _parents = native::path::pin_directories(&parent)?;
        let root = parent.join(format!(
            "distribution-stream-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _root = native::security::create_private_directory(&root)?;
        let payload = b"authenticated fixture package";
        let hash = hex::encode_upper(sha2::Sha256::digest(payload));
        let url = "https://api.github.com/repos/example/Prunlet/releases/assets/1".to_owned();
        for (index, (data, length, digest, success)) in [
            (
                payload.to_vec(),
                Some(payload.len() as u64),
                hash.clone(),
                true,
            ),
            (payload.to_vec(), None, "0".repeat(64), false),
            (payload[..3].to_vec(), None, hash.clone(), false),
            (
                [payload.as_slice(), b"extra"].concat(),
                None,
                hash.clone(),
                false,
            ),
            (payload.to_vec(), Some(1), hash.clone(), false),
        ]
        .into_iter()
        .enumerate()
        {
            let mut calls = Vec::new();
            let (_pin, mut output) = create_plain(&root.join(format!("case-{index}")))?;
            let result = transfer(&url, &mut output, payload.len() as u64, &digest, |target| {
                calls.push(target.to_owned());
                Ok(super::super::http::Response {
                    length,
                    body: Box::new(Cursor::new(data)),
                })
            });
            assert_eq!(result.is_ok(), success);
            assert_eq!(calls, vec![url.clone()]);
            if success {
                assert_eq!(contents(&mut output), payload);
            }
        }
        let mut calls = Vec::new();
        let (_pin, mut failed_output) = create_plain(&root.join("fetch-failure"))?;
        assert!(
            transfer(
                &url,
                &mut failed_output,
                payload.len() as u64,
                &hash,
                |target| {
                    calls.push(target.to_owned());
                    anyhow::bail!("isolated transport failure")
                }
            )
            .is_err()
        );
        assert_eq!(calls, vec![url.clone()]);
        struct BrokenReader(bool);
        impl Read for BrokenReader {
            fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
                if self.0 {
                    return Err(std::io::Error::other("fixture read failure"));
                }
                self.0 = true;
                out[..3].copy_from_slice(b"abc");
                Ok(3)
            }
        }
        let (_pin, mut output) = create_plain(&root.join("read-failure"))?;
        assert!(
            transfer(&url, &mut output, payload.len() as u64, &hash, |_| Ok(
                super::super::http::Response {
                    length: None,
                    body: Box::new(BrokenReader(false))
                }
            ))
            .is_err()
        );
        assert_eq!(contents(&mut output), b"abc");
        eprintln!("Retained distribution stream fixture: {}", root.display());
        Ok(())
    }
}
