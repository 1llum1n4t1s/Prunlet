//! Setup（Velopack）版の nupkg の信頼の基点: R2 の署名付きマニフェスト。
//!
//! 取得元は `https://prunlet.kagayoi.com/manifests/<版>/velopack-win-x64.json`（版はフィード
//! `velopack/releases.win.json` が示す版。Velopack には `latest/` のポインタが無く、フィードが最新を兼ねる）。
//! 中身は [`crate::update::manifest`] の封筒で、固定公開鍵の署名を検証し、payload の product・repository・
//! runtime（`velopack-win-x64`）・版・固定 asset 名（`<packId>-<版>-full.nupkg`）・キー（`velopack/<名前>`）を照合する。
//! 照合に通った payload の SHA-256 だけを、取得した nupkg と比べる基準にする（[`super::trust::compare_release`]）。
//!
//! 旧実装は GitHub Release の `<nupkg>.sha256` を基準にしていたが、タグ・Release は使わなくなった。
//!
//! # fail-closed
//! - 取得できない・署名や形式が検証できない・導入済みより新しくない（後退）: Err を返す。呼出し側は適用せず次回へ延期する
//!   （`compare_release` が Deferred にし、24時間おきの確認で再試行する）。
//! - 検証済みのマニフェストと nupkg の SHA-256 が違う: `compare_release` が Refused にする。
//! - 取得はリダイレクトを辿らない（`update::http::get_without_redirects`）。応答は封筒の上限（16 KiB）までしか読まない。
//!
//! `velopack-test` 機能付きのビルドに限り、環境変数 `PRUNLET_VELOPACK_TEST_RELEASE_DIR` のフォルダーを R2 のベースに見立て、
//! `<フォルダー>/manifests/<版>/velopack-win-x64.json` を読む（R2 へ出ない隔離 E2E 用。テスト鍵 `prunlet-release-test-1`
//! の署名も、この機能付きのビルドでだけ受理する。配布ビルドにこの分岐は残らない）。
use std::time::Duration;

use crate::update::manifest::{self, Expected, Runtime};

/// 本番の packId（[`super::PACK_ID`]）以外の nupkg を、配布ビルドでは扱わない。
/// テスト用機能のビルドだけは E2E の packId（`PrunletVelopackTest` など）を許す。
fn package_id_allowed(package_id: &str) -> bool {
    cfg!(feature = "velopack-test") || package_id == super::PACK_ID
}

/// 取得の時間制限。ログオン時の起動をネットワーク不調で長く止めないため。
const TIMEOUT: Duration = Duration::from_secs(20);

/// 版付きマニフェストの URL（R2）。
pub fn manifest_url(version: &str) -> Result<String, String> {
    manifest::manifest_url(version, Runtime::VelopackWinX64).map_err(|e| e.to_string())
}

/// nupkg の署名付きマニフェストを取得・検証し、payload の SHA-256（小文字16進）を返す。
///
/// - `version`: フィードの資産の版（nupkg の版）。
/// - `nupkg_file_name`: フィードの資産のファイル名。`<package_id>-<version>-full.nupkg` と一致しなければ拒否。
/// - `package_id`: 導入済みアプリの packId。
/// - `installed_version`: 導入済みの版。マニフェストの版がこれより厳密に大きくなければ拒否（後退防止）。
pub fn fetch(
    version: &str,
    nupkg_file_name: &str,
    package_id: &str,
    installed_version: &str,
) -> Result<String, String> {
    verify_with(
        version,
        nupkg_file_name,
        package_id,
        installed_version,
        &read_manifest,
    )
}

/// 取得関数を差し替えられる本体（単体テスト用に分けている）。
fn verify_with(
    version: &str,
    nupkg_file_name: &str,
    package_id: &str,
    installed_version: &str,
    read: &dyn Fn(&str) -> Result<Vec<u8>, String>,
) -> Result<String, String> {
    if !package_id_allowed(package_id) {
        return Err("The package id is not the production Setup package.".into());
    }
    if manifest::parse_version(version).is_none()
        || nupkg_file_name != format!("{package_id}-{version}-full.nupkg")
    {
        return Err("The package version or file name is not valid.".into());
    }
    let envelope = read(version)?;
    let release = manifest::verify_release(
        &envelope,
        &Expected {
            runtime: Runtime::VelopackWinX64,
            package_id,
            version: Some(version),
            commit: None,
        },
    )
    .map_err(|e| format!("The signed release manifest was not accepted: {e:#}"))?;
    if release.asset_name != nupkg_file_name {
        return Err("The signed release manifest names a different package.".into());
    }
    match manifest::is_newer(&release.version, installed_version) {
        Ok(true) => Ok(release.sha256),
        Ok(false) => Err("The signed release is not newer than the installed version.".into()),
        Err(error) => Err(format!("{error:#}")),
    }
}

/// 版付きマニフェストの封筒を読む（本番は R2、テスト用機能では隔離フォルダー）。
fn read_manifest(version: &str) -> Result<Vec<u8>, String> {
    #[cfg(feature = "velopack-test")]
    if let Some(directory) = std::env::var_os("PRUNLET_VELOPACK_TEST_RELEASE_DIR") {
        let path = std::path::PathBuf::from(directory)
            .join("manifests")
            .join(version)
            .join(format!("{}.json", Runtime::VelopackWinX64.as_str()));
        let length = std::fs::metadata(&path).map_err(|e| e.to_string())?.len();
        if length > manifest::MAX_ENVELOPE_BYTES {
            return Err("The release manifest is too large.".into());
        }
        return std::fs::read(&path).map_err(|e| e.to_string());
    }
    let url = manifest_url(version)?;
    crate::update::download::fetch_bounded(&url, manifest::MAX_ENVELOPE_BYTES, TIMEOUT)
        .map_err(|e| format!("download failed: {e:#}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::update::manifest::test_support;

    const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn manifest_url_is_built_only_from_a_strict_version() {
        assert_eq!(
            manifest_url("1.0.48").unwrap(),
            "https://prunlet.kagayoi.com/manifests/1.0.48/velopack-win-x64.json"
        );
        for bad in ["", "1.0", "1.0.0/../x", "1.0.0-rc", "a/b"] {
            assert!(manifest_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn signed_manifest_is_the_only_hash_source() {
        let content = b"nupkg bytes";
        let good = test_support::envelope(Runtime::VelopackWinX64, "2.0.0", COMMIT, content);
        let name = "PrunletApp-2.0.0-full.nupkg";
        let read_good = |version: &str| -> Result<Vec<u8>, String> {
            assert_eq!(version, "2.0.0");
            Ok(good.clone())
        };
        let sha = verify_with("2.0.0", name, "PrunletApp", "1.0.47", &read_good).unwrap();
        assert_eq!(
            sha,
            hex::encode(<sha2::Sha256 as sha2::Digest>::digest(content))
        );
        // 同版・旧版（後退）は拒否（呼出し側で延期）。
        assert!(verify_with("2.0.0", name, "PrunletApp", "2.0.0", &read_good).is_err());
        assert!(verify_with("2.0.0", name, "PrunletApp", "3.0.0", &read_good).is_err());
        // ファイル名・版の不一致、取得失敗、署名の改ざんは拒否。
        assert!(
            verify_with(
                "2.0.0",
                "PrunletApp-2.0.1-full.nupkg",
                "PrunletApp",
                "1.0.0",
                &read_good
            )
            .is_err()
        );
        assert!(
            verify_with(
                "2.0.1",
                "PrunletApp-2.0.1-full.nupkg",
                "PrunletApp",
                "1.0.0",
                &|_| Ok(good.clone())
            )
            .is_err()
        );
        assert!(
            verify_with("2.0.0", name, "PrunletApp", "1.0.0", &|_| Err(
                "offline".into()
            ))
            .is_err()
        );
        let mut tampered = good.clone();
        let index = tampered.len() - 5;
        tampered[index] ^= 1;
        assert!(
            verify_with("2.0.0", name, "PrunletApp", "1.0.0", &|_| Ok(
                tampered.clone()
            ))
            .is_err()
        );
        // Windows ZIP の封筒（runtime 違い）は Velopack の基準にならない。
        let zip = test_support::envelope(Runtime::WinX64, "2.0.0", COMMIT, content);
        assert!(verify_with("2.0.0", name, "PrunletApp", "1.0.0", &|_| Ok(zip.clone())).is_err());
    }

    #[cfg(not(feature = "velopack-test"))]
    #[test]
    fn production_builds_accept_only_the_production_package_id() {
        let never = |_: &str| -> Result<Vec<u8>, String> { panic!("must not fetch") };
        assert!(
            verify_with(
                "2.0.0",
                "PrunletVelopackTest-2.0.0-full.nupkg",
                "PrunletVelopackTest",
                "1.0.0",
                &never
            )
            .is_err()
        );
    }
}
