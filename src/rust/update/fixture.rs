//! Windows ZIP の起動時更新を、R2 へ出ずに検証するための応答の差し替え（テスト専用ビルドだけ）。
//!
//! # 有効化の条件
//! このモジュールは `all(windows, debug_assertions, prunlet_windows_update_tests)` のときだけコンパイルされる
//! （`update/mod.rs` の宣言を参照）。Unix の `prunlet_linux_update_tests` / `prunlet_macos_race_tests` と同じ設計で、
//! 配布の release ビルド（debug_assertions なし・cfg なし）には、この入口も環境変数名もテスト鍵も残らない。
//! テスト鍵 `prunlet-release-test-1` の受理も同じ cfg で `manifest.rs` が有効にする。
//!
//! # 差し替えの仕組み
//! - `PRUNLET_WINDOWS_UPDATE_FIXTURE`（絶対パスのフォルダー）があると、launcher が呼ぶ内部コマンド
//!   （`__check-release-manifest`・`__download-release-package`・`__prepare-release-package`）の R2 取得を、
//!   「URL の UTF-8 バイト列の SHA-256（小文字 hex 64 桁）」をファイル名にしたフォルダー内のファイルで置き換える。
//!   `scripts/Verify-UnixStartupUpdate.ts` と同じ命名規則で、対象 URL は次の3種類（どれも Rust が自分で組み立てる）。
//!   - `https://prunlet.kagayoi.com/latest/<runtime>.json`（最新ポインタの封筒）
//!   - `https://prunlet.kagayoi.com/manifests/<版>/<runtime>.json`（版付きマニフェストの封筒）
//!   - `https://prunlet.kagayoi.com/releases/1llum1n4t1s/prunlet/<commit>/<runtime>/<sha256>.zip`（配布物）
//! - 環境変数があるのに該当ファイルが無い場合は Err（取得失敗＝launcher は延期）にし、ネットワークへは落とさない。
//! - `PRUNLET_WINDOWS_UPDATE_FIXTURE_VERSION`（厳密な x.y.z）があると、版の新旧の判定に使う「導入済みの版」を
//!   `crate::VERSION` の代わりにこの値にする。検証の製品は1つのビルドの版リソースだけを書き換えた写しなので、
//!   launcher が版リソースから読む導入済みの版と、Rust の判定の基準をこの指定で揃える。
//!
//! 署名・正規形・runtime・版・commit・長さ・SHA-256 の照合は差し替えず、本番と同じコードで行う。
use super::{http::Response, manifest};
use anyhow::{Context, Result, ensure};
use sha2::{Digest, Sha256};
use std::{fs::File, path::PathBuf};

/// 応答ファイルを置くフォルダー（絶対パス）。
const DIRECTORY: &str = "PRUNLET_WINDOWS_UPDATE_FIXTURE";
/// 版の判定に使う導入済みの版（厳密な x.y.z）。
const INSTALLED_VERSION: &str = "PRUNLET_WINDOWS_UPDATE_FIXTURE_VERSION";

/// fixture が指定されていれば、その URL の応答をファイルから返す。指定が無ければ `None`（本番の取得へ進む）。
pub(super) fn response(url: &str) -> Option<Result<Response>> {
    let directory = std::env::var_os(DIRECTORY)?;
    Some(read(PathBuf::from(directory), url))
}

fn read(directory: PathBuf, url: &str) -> Result<Response> {
    ensure!(
        directory.is_absolute(),
        "The Windows update fixture directory must be absolute"
    );
    // 配布元以外の URL は差し替えない（Rust が組み立てる R2 の URL だけが対象）。
    ensure!(
        url.starts_with(&format!("{}/", manifest::DISTRIBUTION_BASE)),
        "The Windows update fixture accepts only distribution URLs"
    );
    // 名前は URL の SHA-256 の hex だけなので、区切り文字や親参照は入らない。
    let path = directory.join(hex::encode(Sha256::digest(url.as_bytes())));
    let file = File::open(&path)
        .with_context(|| format!("Windows update fixture has no response for {url}"))?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file(),
        "Windows update fixture response is not a file"
    );
    // 実際の応答と同じく、宣言長（Content-Length 相当）を付けて返す。上限・宣言長・実長の照合は呼出し側が行う。
    Ok(Response {
        length: Some(metadata.len()),
        body: Box::new(file),
    })
}

/// fixture が導入済みの版を指定していれば返す（厳密な x.y.z 以外は Err）。指定が無ければ `None`。
pub(super) fn installed_version() -> Result<Option<String>> {
    let Some(value) = std::env::var_os(INSTALLED_VERSION) else {
        return Ok(None);
    };
    let value = value
        .into_string()
        .ok()
        .filter(|text| manifest::parse_version(text).is_some())
        .context("The Windows update fixture version must be a strict x.y.z version")?;
    Ok(Some(value))
}

#[cfg(test)]
mod tests {
    //! `--cfg prunlet_windows_update_tests` を付けた `cargo test` でだけ動く（通常の `cargo test` ではモジュールごと無い）。
    use super::*;
    use std::io::Read;

    #[test]
    fn responses_are_named_by_the_url_sha256_and_never_fall_back() -> Result<()> {
        let directory =
            std::env::temp_dir().join(format!("prunlet-fixture-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&directory)?;
        let url = "https://prunlet.kagayoi.com/latest/win-x64.json";
        // scripts/Verify-UnixStartupUpdate.ts と同じ命名（URL の UTF-8 の SHA-256 小文字 hex）。
        let name = hex::encode(Sha256::digest(url.as_bytes()));
        std::fs::write(directory.join(&name), b"envelope")?;
        let mut response = read(directory.clone(), url)?;
        let mut body = Vec::new();
        response.body.read_to_end(&mut body)?;
        assert_eq!(
            (response.length, body.as_slice()),
            (Some(8), &b"envelope"[..])
        );
        // 置いていない URL は取得失敗（本番の取得へは落とさない）。
        assert!(
            read(
                directory.clone(),
                "https://prunlet.kagayoi.com/latest/win-arm64.json"
            )
            .is_err()
        );
        // 配布元以外・相対フォルダーは拒否する。
        assert!(read(directory.clone(), "https://example.com/latest/win-x64.json").is_err());
        assert!(read(PathBuf::from("relative"), url).is_err());
        drop(response);
        std::fs::remove_file(directory.join(name))?;
        std::fs::remove_dir(&directory)?;
        Ok(())
    }
}
