//! 署名付きリリースマニフェスト（封筒）の解析・検証と、版の比較。
//!
//! # 目的
//! 更新の信頼の基点を GitHub Release（タグ・`releases/latest`・compare API）から、R2
//! （`https://prunlet.kagayoi.com`）に置いた「固定公開鍵で署名したマニフェスト」へ移す。
//! クライアントは R2 の応答そのものを信頼せず、この封筒の署名だけを信頼する。配布物の URL・長さ・SHA-256・
//! commit・版は、すべて署名済みの payload から導く（呼出し元の引数や HTTP 応答の他の部分からは導かない）。
//!
//! # 封筒（envelope）
//! UTF-8・BOM なし・compact・末尾改行なし・16384 バイト以下。キーは次の4つだけをこの順で持つ。
//! `{"schema":1,"keyId":"prunlet-release-1","payload":"<base64>","signature":"<base64 DER>"}`
//! - base64 は標準アルファベット・パディング付きで、再エンコードして元と一致する正規形だけを受理する。
//! - 署名対象は payload を復号した生バイト。ECDSA P-256 + SHA-256、形式は RFC 3279 の DER
//!   （`SEQUENCE { r INTEGER, s INTEGER }`）。.NET 既定の r‖s（64 バイト）は拒否する。
//!
//! # payload
//! UTF-8・compact・キー順固定。
//! `{"schema":1,"product":"Prunlet","repository":"1llum1n4t1s/Prunlet","runtime":..,"version":"x.y.z",
//!   "commit":"<40桁小文字hex>","defaultBranch":..,"asset":{"name":..,"key":..,"bytes":<整数>,"sha256":"<64桁小文字hex>"}}`
//!
//! # 厳密さの実装方針
//! 「解析 → 型と値の検査 → 自分で正規形のバイト列を組み立て直す → 入力と完全一致」の順で照合する。
//! これで、キーの順序・重複キー・追加キー・空白・BOM・末尾改行・文字列のエスケープの揺れを1か所でまとめて拒否できる
//! （発行側 `scripts/PrunletRelease.Common.ps1` の Utf8JsonWriter が出す形と同じバイト列だけを受ける）。
//!
//! # fail-closed
//! どの検査に外れても Err を返す。呼出し側は適用せず次回へ延期する（取得失敗も同じ扱い）。
//! 後退防止のため、版は導入済みより「厳密に大きい」場合だけ候補にする（[`is_newer`]）。
//!
//! # 鍵
//! 受理する鍵は配列（[`trusted_keys`]）で持ち、鍵の交代に備える。本番鍵の定数名
//! `PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64` は、配信側の鍵整合の関門（`scripts/Test-PrunletReleaseKeyGate.ps1`）が
//! `src/rust/**/*.rs` から「識別子と同じ行の100文字以上の base64 リテラル」をちょうど1件抽出する規則に合わせている。
//! **この識別子と同じ行に別の長い base64 リテラルを書かない**（テスト鍵は別名・別の行に置く）。
//! テスト鍵（`prunlet-release-test-1`）は `cfg(test)`・`velopack-test` 機能・Unix / Windows ZIP の更新テスト用の
//! デバッグ cfg（`prunlet_linux_update_tests`・`prunlet_macos_race_tests`・`prunlet_windows_update_tests`）の中だけで
//! 受理し、配布ビルドには経路を残さない。
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use p256::ecdsa::{DerSignature, VerifyingKey, signature::Verifier};
use p256::pkcs8::DecodePublicKey;
use serde_json::Value;
use sha2::{Digest, Sha256};

/// 配布元（R2 の公開ドメイン）。末尾 `/` なし。配布物・マニフェストの URL はこのベースと固定のキーだけから組み立てる。
pub const DISTRIBUTION_BASE: &str = "https://prunlet.kagayoi.com";
/// payload の `product`。
pub const PRODUCT: &str = "Prunlet";
/// payload の `repository`（大文字小文字も含めて完全一致）。
pub const REPOSITORY: &str = "1llum1n4t1s/Prunlet";
/// 封筒の最大バイト数（発行側の `$PrunletReleaseEnvelopeMaxBytes` と同じ）。
pub const MAX_ENVELOPE_BYTES: u64 = 16384;

/// 本番の鍵 ID。
const PRUNLET_RELEASE_KEY_ID: &str = "prunlet-release-1";
/// 本番の公開鍵（P-256 の SubjectPublicKeyInfo DER を標準 base64 にしたもの）。
/// 鍵整合の関門がこの行を抽出する。rustfmt で識別子とリテラルが別行に割れないよう、整形の対象から外す。
#[rustfmt::skip]
const PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64: &str = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMIbQQg1ZUrL1G3V5sKqnQm74bz087XUrB5+wnCXOfBnP8kREgm960J5b9S/fT0rUgopgPODpO9/PINkkCFhJbA==";

/// テスト専用の鍵 ID と公開鍵（`scripts/release-test-fixtures/` の鍵対）。配布ビルドではコンパイルされない。
#[cfg(any(
    test,
    feature = "velopack-test",
    all(debug_assertions, prunlet_linux_update_tests),
    all(debug_assertions, prunlet_macos_race_tests),
    all(debug_assertions, prunlet_windows_update_tests)
))]
pub const TEST_KEY_ID: &str = "prunlet-release-test-1";
#[cfg(any(
    test,
    feature = "velopack-test",
    all(debug_assertions, prunlet_linux_update_tests),
    all(debug_assertions, prunlet_macos_race_tests),
    all(debug_assertions, prunlet_windows_update_tests)
))]
#[rustfmt::skip]
const TEST_PUBLIC_KEY: &str =
    "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEJI+6YwDlXyUv0vHL2JzfI/YaEgEgIxrMHfsZelS5IR1dnI4FCu2vZRtmWXJTStqbRIkPWH1yrwnJkW6ZF+b2Mw==";

/// 受理する鍵 1 件（ID と SPKI の base64）。
struct TrustedKey {
    id: &'static str,
    spki_base64: &'static str,
}

/// 受理する鍵の一覧。鍵を交代するときは新旧を並べ、旧鍵は全クライアントの移行後に外す。
fn trusted_keys() -> Vec<TrustedKey> {
    #[allow(unused_mut)]
    let mut keys = vec![TrustedKey {
        id: PRUNLET_RELEASE_KEY_ID,
        spki_base64: PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64,
    }];
    #[cfg(any(
        test,
        feature = "velopack-test",
        all(debug_assertions, prunlet_linux_update_tests),
        all(debug_assertions, prunlet_macos_race_tests),
        all(debug_assertions, prunlet_windows_update_tests)
    ))]
    keys.push(TrustedKey {
        id: TEST_KEY_ID,
        spki_base64: TEST_PUBLIC_KEY,
    });
    keys
}

/// 配布物の種類。名前は payload の `runtime` とマニフェストのキーにそのまま使う。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Runtime {
    WinX64,
    WinArm64,
    OsxArm64,
    LinuxX64,
    LinuxArm64,
    /// Setup（Velopack）版の Full nupkg。`latest/` のポインタを持たない（フィードが最新を兼ねる）。
    VelopackWinX64,
}

impl Runtime {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "win-x64" => Self::WinX64,
            "win-arm64" => Self::WinArm64,
            "osx-arm64" => Self::OsxArm64,
            "linux-x64" => Self::LinuxX64,
            "linux-arm64" => Self::LinuxArm64,
            "velopack-win-x64" => Self::VelopackWinX64,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::WinX64 => "win-x64",
            Self::WinArm64 => "win-arm64",
            Self::OsxArm64 => "osx-arm64",
            Self::LinuxX64 => "linux-x64",
            Self::LinuxArm64 => "linux-arm64",
            Self::VelopackWinX64 => "velopack-win-x64",
        }
    }

    /// 配布物の上限バイト数（発行側の Get-PrunletReleaseDescriptor と同じ。既存クライアントの上限に合わせている）。
    pub fn max_bytes(self) -> u64 {
        match self {
            Self::WinX64 | Self::WinArm64 | Self::VelopackWinX64 => 512 * 1024 * 1024,
            Self::OsxArm64 | Self::LinuxX64 | Self::LinuxArm64 => 64 * 1024 * 1024,
        }
    }

    /// 配布物のキーの拡張子。
    fn extension(self) -> &'static str {
        match self {
            Self::LinuxX64 | Self::LinuxArm64 => "tar.gz",
            Self::VelopackWinX64 => "nupkg",
            _ => "zip",
        }
    }

    /// 固定の asset 名。Velopack だけは版と packId を含む（`<packId>-<版>-full.nupkg`）。
    /// 本番の packId は `PrunletApp` で、呼出し側（`app_update::release`）がそれ以外を拒否する。
    pub fn asset_name(self, version: &str, package_id: &str) -> String {
        match self {
            Self::WinX64 => "prunlet-update-win-x64.zip".into(),
            Self::WinArm64 => "prunlet-update-win-arm64.zip".into(),
            Self::OsxArm64 => "prunlet-update-osx-arm64.zip".into(),
            Self::LinuxX64 => "prunlet-linux-x64.tar.gz".into(),
            Self::LinuxArm64 => "prunlet-linux-arm64.tar.gz".into(),
            Self::VelopackWinX64 => format!("{package_id}-{version}-full.nupkg"),
        }
    }
}

/// 最新ポインタ（`latest/<runtime>.json`）の URL。Velopack には無い（フィードの版から版付きマニフェストを引く）。
pub fn latest_url(runtime: Runtime) -> Result<String> {
    ensure!(
        runtime != Runtime::VelopackWinX64,
        "The Setup feed has no latest manifest pointer."
    );
    Ok(format!(
        "{DISTRIBUTION_BASE}/latest/{}.json",
        runtime.as_str()
    ))
}

/// 版付きマニフェスト（`manifests/<版>/<runtime>.json`）の URL。版は厳密な x.y.z だけを URL に入れる。
pub fn manifest_url(version: &str, runtime: Runtime) -> Result<String> {
    ensure!(
        parse_version(version).is_some(),
        "The release version is not a strict x.y.z version."
    );
    Ok(format!(
        "{DISTRIBUTION_BASE}/manifests/{version}/{}.json",
        runtime.as_str()
    ))
}

/// 厳密な `x.y.z`（各部は先頭 0 なしの 1〜9 桁の10進。prerelease・build metadata は不可）。
/// 発行側の Test-PrunletReleaseVersion と同じ規則。
pub fn parse_version(text: &str) -> Option<[u64; 3]> {
    let mut result = [0; 3];
    let mut parts = text.split('.');
    for value in &mut result {
        let part = parts.next()?;
        if part.is_empty()
            || part.len() > 9
            || !part.bytes().all(|b| b.is_ascii_digit())
            || (part.len() > 1 && part.starts_with('0'))
        {
            return None;
        }
        *value = part.parse().ok()?;
    }
    parts.next().is_none().then_some(result)
}

/// `candidate` が導入済みの `installed` より厳密に大きいか（後退・同版の再適用を防ぐ）。
/// 導入済みの版を読めない場合は Err（判断できないので適用しない）。
pub fn is_newer(candidate: &str, installed: &str) -> Result<bool> {
    let candidate = parse_version(candidate).context("Invalid release version")?;
    let installed = parse_version(installed).context("Invalid installed version")?;
    Ok(candidate > installed)
}

fn lower_hex(value: &str, count: usize) -> bool {
    value.len() == count
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

/// 署名を検証できた payload から読み取った配布物の情報。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release {
    pub runtime: Runtime,
    pub version: String,
    /// 40 桁の小文字 hex。
    pub commit: String,
    pub default_branch: String,
    pub asset_name: String,
    /// R2 のキー（クライアントが自分で組み立てた値と完全一致を確認済み）。
    pub asset_key: String,
    pub bytes: u64,
    /// 64 桁の小文字 hex。
    pub sha256: String,
}

impl Release {
    /// 配布物の不変 URL（ベース + 検証済みのキー）。任意の URL は辿らない。
    pub fn asset_url(&self) -> String {
        format!("{DISTRIBUTION_BASE}/{}", self.asset_key)
    }

    /// 取得した配布物の長さと SHA-256 が payload と一致するか。
    pub fn check_content(&self, bytes: &[u8]) -> Result<()> {
        ensure!(
            bytes.len() as u64 == self.bytes && hex::encode(Sha256::digest(bytes)) == self.sha256,
            "The downloaded release asset differs from its signed manifest"
        );
        Ok(())
    }
}

/// 配布物のキー（R2）。win・mac・linux は commit / runtime / sha256 を含む不変キー、Velopack は `velopack/<名前>`。
/// キーのリポジトリ部は小文字（発行側の `$Repository.ToLowerInvariant()` と同じ）。
pub fn asset_key(runtime: Runtime, commit: &str, sha256: &str, asset_name: &str) -> String {
    if runtime == Runtime::VelopackWinX64 {
        format!("velopack/{asset_name}")
    } else {
        format!(
            "releases/{}/{commit}/{}/{sha256}.{}",
            REPOSITORY.to_ascii_lowercase(),
            runtime.as_str(),
            runtime.extension()
        )
    }
}

/// 封筒を検査して署名を検証し、payload の生バイトを返す。
pub fn verify_envelope(bytes: &[u8]) -> Result<Vec<u8>> {
    ensure!(
        bytes.len() >= 2 && bytes.len() as u64 <= MAX_ENVELOPE_BYTES,
        "Release manifest size is invalid"
    );
    // 重複キーは parse_unique が拒否する。順序・追加キー・空白・BOM は下の正規形との一致で拒否する。
    let value = crate::json::parse_unique(bytes).context("Release manifest is malformed")?;
    let object = value
        .as_object()
        .context("Release manifest must be an object")?;
    ensure!(
        object.len() == 4 && object.get("schema").and_then(Value::as_u64) == Some(1),
        "Release manifest has an unsupported shape"
    );
    let text = |name: &str| -> Result<&str> {
        object
            .get(name)
            .and_then(Value::as_str)
            .with_context(|| format!("Release manifest field {name} must be a string"))
    };
    let key_id = text("keyId")?;
    let payload_text = text("payload")?;
    let signature_text = text("signature")?;
    let canonical = format!(
        "{{\"schema\":1,\"keyId\":{},\"payload\":{},\"signature\":{}}}",
        serde_json::to_string(key_id)?,
        serde_json::to_string(payload_text)?,
        serde_json::to_string(signature_text)?
    );
    ensure!(
        canonical.as_bytes() == bytes,
        "Release manifest is not in its canonical form"
    );
    let keys = trusted_keys();
    let key = keys
        .iter()
        .find(|k| k.id == key_id)
        .context("Release manifest is signed with an unknown key ID")?;
    let payload =
        canonical_base64(payload_text).context("Release payload is not canonical base64")?;
    let signature =
        canonical_base64(signature_text).context("Release signature is not canonical base64")?;
    // DER だけを受ける。from_bytes は厳密な DER の SEQUENCE{r,s} を要求し、r‖s の64バイトは読めない。
    // さらに再エンコードして元と一致することを求め、冗長な符号化（余分な 0x00 など）も拒否する。
    let der = DerSignature::from_bytes(&signature).context("Release signature is not DER")?;
    ensure!(
        der.as_bytes() == signature.as_slice(),
        "Release signature is not canonical DER"
    );
    let spki = STANDARD
        .decode(key.spki_base64)
        .context("Trusted release key is invalid")?;
    let verifying =
        VerifyingKey::from_public_key_der(&spki).context("Trusted release key is invalid")?;
    verifying
        .verify(&payload, &der)
        .ok()
        .context("Release manifest signature verification failed")?;
    Ok(payload)
}

/// 標準 base64（パディング付き）で、再エンコードして元と一致する正規形だけを復号する。
fn canonical_base64(text: &str) -> Option<Vec<u8>> {
    let decoded = STANDARD.decode(text).ok()?;
    (STANDARD.encode(&decoded) == text && !decoded.is_empty()).then_some(decoded)
}

/// 検証で照合する期待値。`None` の項目は照合しない（最新ポインタでは版・commit は未知）。
#[derive(Clone, Copy, Debug)]
pub struct Expected<'a> {
    pub runtime: Runtime,
    /// Velopack の packId（asset 名の組み立てに使う）。Velopack 以外では使わない。
    pub package_id: &'a str,
    pub version: Option<&'a str>,
    pub commit: Option<&'a str>,
}

impl<'a> Expected<'a> {
    pub fn runtime(runtime: Runtime) -> Self {
        Self {
            runtime,
            package_id: "PrunletApp",
            version: None,
            commit: None,
        }
    }
}

/// 封筒の署名を検証し、payload を厳密に検査して [`Release`] を返す。
pub fn verify_release(envelope: &[u8], expected: &Expected<'_>) -> Result<Release> {
    let payload = verify_envelope(envelope)?;
    parse_payload(&payload, expected)
}

/// 署名済み payload の検査（キー順・型・値・固定 asset 名・キーの再構成）。
fn parse_payload(payload: &[u8], expected: &Expected<'_>) -> Result<Release> {
    let value = crate::json::parse_unique(payload).context("Release payload is malformed")?;
    let text = |object: &Value, name: &str| -> Result<String> {
        object
            .get(name)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .with_context(|| format!("Release payload field {name} must be a string"))
    };
    ensure!(
        value.as_object().is_some_and(|o| o.len() == 8)
            && value.get("schema").and_then(Value::as_u64) == Some(1),
        "Release payload has an unsupported shape"
    );
    let asset = value
        .get("asset")
        .filter(|a| a.as_object().is_some_and(|o| o.len() == 4))
        .context("Release payload asset must be an object")?;
    let product = text(&value, "product")?;
    let repository = text(&value, "repository")?;
    let runtime_text = text(&value, "runtime")?;
    let version = text(&value, "version")?;
    let commit = text(&value, "commit")?;
    let default_branch = text(&value, "defaultBranch")?;
    let asset_name = text(asset, "name")?;
    let key = text(asset, "key")?;
    let sha256 = text(asset, "sha256")?;
    let bytes = asset
        .get("bytes")
        .and_then(Value::as_u64)
        .context("Release payload asset bytes must be a non-negative integer")?;
    // 正規形の再構成と完全一致（キー順・compact・数値表記・エスケープの揺れを拒否）。
    let canonical = format!(
        "{{\"schema\":1,\"product\":{},\"repository\":{},\"runtime\":{},\"version\":{},\"commit\":{},\"defaultBranch\":{},\"asset\":{{\"name\":{},\"key\":{},\"bytes\":{bytes},\"sha256\":{}}}}}",
        serde_json::to_string(&product)?,
        serde_json::to_string(&repository)?,
        serde_json::to_string(&runtime_text)?,
        serde_json::to_string(&version)?,
        serde_json::to_string(&commit)?,
        serde_json::to_string(&default_branch)?,
        serde_json::to_string(&asset_name)?,
        serde_json::to_string(&key)?,
        serde_json::to_string(&sha256)?
    );
    ensure!(
        canonical.as_bytes() == payload,
        "Release payload is not in its canonical form"
    );
    ensure!(
        product == PRODUCT && repository == REPOSITORY,
        "Release payload is for a different product"
    );
    let runtime = Runtime::parse(&runtime_text).context("Release payload runtime is unknown")?;
    ensure!(
        runtime == expected.runtime,
        "Release payload is for a different runtime"
    );
    ensure!(
        parse_version(&version).is_some(),
        "Release payload version is not a strict x.y.z version"
    );
    if let Some(wanted) = expected.version {
        ensure!(version == wanted, "Release payload version differs");
    }
    ensure!(lower_hex(&commit, 40), "Release payload commit is invalid");
    if let Some(wanted) = expected.commit {
        ensure!(
            commit.eq_ignore_ascii_case(wanted),
            "Release payload commit differs"
        );
    }
    ensure!(
        super::package::valid_branch(&default_branch),
        "Release payload default branch is invalid"
    );
    ensure!(
        asset_name == runtime.asset_name(&version, expected.package_id),
        "Release payload asset name differs from the fixed name"
    );
    ensure!(lower_hex(&sha256, 64), "Release payload SHA-256 is invalid");
    ensure!(
        bytes > 0 && bytes <= runtime.max_bytes(),
        "Release payload asset size is outside its limit"
    );
    // asset.key は辿る前に自分で組み立てた値と完全一致させる（署名済みでも任意のキー・URL へは行かない）。
    ensure!(
        key == asset_key(runtime, &commit, &sha256, &asset_name),
        "Release payload asset key differs from the expected key"
    );
    Ok(Release {
        runtime,
        version,
        commit,
        default_branch,
        asset_name,
        asset_key: key,
        bytes,
        sha256,
    })
}

/// 取得関数の型。`(URL, 最大バイト数) -> 本文`。リダイレクトは辿らない実装を渡すこと。
/// 最大バイト数を超える応答は Err にすること（途中で打ち切って成功にしない）。
pub type Fetch<'a> = dyn Fn(&str, u64) -> Result<Vec<u8>> + 'a;

/// 最新ポインタを取得・検証し、導入済み（`installed_version`）より新しければ返す。同版・旧版は `Ok(None)`。
pub fn latest_newer(
    fetch: &Fetch<'_>,
    runtime: Runtime,
    installed_version: &str,
) -> Result<Option<Release>> {
    let envelope = fetch(&latest_url(runtime)?, MAX_ENVELOPE_BYTES)?;
    let release = verify_release(&envelope, &Expected::runtime(runtime))?;
    Ok(is_newer(&release.version, installed_version)?.then_some(release))
}

/// 版付きマニフェストを取得・検証する（版・commit も照合する）。導入済みより新しくなければ Err。
pub fn versioned_newer(
    fetch: &Fetch<'_>,
    expected: &Expected<'_>,
    installed_version: &str,
) -> Result<Release> {
    let version = expected
        .version
        .context("A versioned manifest requires its version")?;
    let envelope = fetch(
        &manifest_url(version, expected.runtime)?,
        MAX_ENVELOPE_BYTES,
    )?;
    let release = verify_release(&envelope, expected)?;
    if !is_newer(&release.version, installed_version)? {
        bail!("The signed release is not newer than the installed version");
    }
    Ok(release)
}

/// Unix の起動時更新の候補（配布物の本体まで取得・照合済み）。
#[cfg_attr(not(any(unix, test)), allow(dead_code))]
pub(crate) struct Candidate {
    pub version: String,
    pub commit: String,
    pub bytes: Vec<u8>,
}

/// Unix の起動時更新: 最新ポインタを検証し、新しければ不変 URL から配布物を取得して長さ・SHA-256 を照合する。
/// 実行体の自己申告（版・commit）の照合は、展開後に各 OS の実装が行う。
#[cfg_attr(not(any(unix, test)), allow(dead_code))]
pub(crate) fn unix_candidate(
    fetch: &Fetch<'_>,
    runtime: Runtime,
    installed_version: &str,
) -> Result<Option<Candidate>> {
    let Some(release) = latest_newer(fetch, runtime, installed_version)? else {
        return Ok(None);
    };
    let bytes = fetch(&release.asset_url(), release.bytes)?;
    release.check_content(&bytes)?;
    Ok(Some(Candidate {
        version: release.version,
        commit: release.commit,
        bytes,
    }))
}

#[cfg(test)]
pub(crate) mod test_support {
    //! テスト用の封筒を作る（テスト鍵で署名）。秘密鍵は `scripts/release-test-fixtures/test-signing-private.pem`
    //! と同じテスト専用の鍵で、本番鍵には一切触れない。
    use super::*;
    use p256::ecdsa::{SigningKey, signature::Signer};
    use p256::pkcs8::DecodePrivateKey;

    pub const TEST_PRIVATE_PEM: &str =
        include_str!("../../../scripts/release-test-fixtures/test-signing-private.pem");

    pub fn signing_key() -> SigningKey {
        SigningKey::from_pkcs8_pem(TEST_PRIVATE_PEM).expect("test signing key")
    }

    /// payload の正規形のバイト列を作る（発行側の New-PrunletReleasePayloadBytes と同じ形）。
    pub fn payload(
        runtime: Runtime,
        version: &str,
        commit: &str,
        sha256: &str,
        bytes: u64,
    ) -> String {
        let name = runtime.asset_name(version, "PrunletApp");
        let key = asset_key(runtime, commit, sha256, &name);
        format!(
            "{{\"schema\":1,\"product\":\"Prunlet\",\"repository\":\"1llum1n4t1s/Prunlet\",\"runtime\":\"{}\",\"version\":\"{version}\",\"commit\":\"{commit}\",\"defaultBranch\":\"main\",\"asset\":{{\"name\":\"{name}\",\"key\":\"{key}\",\"bytes\":{bytes},\"sha256\":\"{sha256}\"}}}}",
            runtime.as_str()
        )
    }

    /// 任意の payload バイト列をテスト鍵で DER 署名し、正規形の封筒にする。
    pub fn envelope_for(payload: &[u8], key_id: &str) -> Vec<u8> {
        let signature: p256::ecdsa::DerSignature = signing_key().sign(payload);
        format!(
            "{{\"schema\":1,\"keyId\":\"{key_id}\",\"payload\":\"{}\",\"signature\":\"{}\"}}",
            STANDARD.encode(payload),
            STANDARD.encode(signature.as_bytes())
        )
        .into_bytes()
    }

    /// 配布物の中身から正しい封筒を作る。
    pub fn envelope(runtime: Runtime, version: &str, commit: &str, content: &[u8]) -> Vec<u8> {
        let sha = hex::encode(Sha256::digest(content));
        envelope_for(
            payload(runtime, version, commit, &sha, content.len() as u64).as_bytes(),
            TEST_KEY_ID,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use p256::ecdsa::{Signature, signature::Signer};
    use std::cell::RefCell;

    const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";

    fn sample() -> Vec<u8> {
        include_bytes!("../../../scripts/release-test-fixtures/sample-envelope.json").to_vec()
    }

    fn error_text(result: Result<impl std::fmt::Debug>) -> String {
        format!("{:#}", result.expect_err("must be rejected"))
    }

    /// 発行側（PowerShell/.NET）が実際に作った封筒を、Rust の検証で受理できること（相互運用の基準）。
    #[test]
    fn publisher_sample_envelope_is_accepted() {
        let release = verify_release(&sample(), &Expected::runtime(Runtime::WinX64)).unwrap();
        assert_eq!(release.version, "1.2.3");
        assert_eq!(release.commit, "a".repeat(40));
        assert_eq!(release.default_branch, "main");
        assert_eq!(release.asset_name, "prunlet-update-win-x64.zip");
        assert_eq!(release.bytes, 12345);
        assert_eq!(release.sha256, "b".repeat(64));
        assert_eq!(
            release.asset_url(),
            format!(
                "https://prunlet.kagayoi.com/releases/1llum1n4t1s/prunlet/{}/win-x64/{}.zip",
                "a".repeat(40),
                "b".repeat(64)
            )
        );
        // 公開鍵ファイルとテスト用定数が同じであること。
        let file = include_str!("../../../scripts/release-test-fixtures/test-public-spki.b64");
        assert_eq!(file.trim(), TEST_PUBLIC_KEY);
    }

    #[test]
    fn rust_signed_envelope_round_trips_for_every_runtime() {
        for runtime in [
            Runtime::WinX64,
            Runtime::WinArm64,
            Runtime::OsxArm64,
            Runtime::LinuxX64,
            Runtime::LinuxArm64,
            Runtime::VelopackWinX64,
        ] {
            let envelope = envelope(runtime, "2.0.0", COMMIT, b"content");
            let release = verify_release(&envelope, &Expected::runtime(runtime)).unwrap();
            assert_eq!(release.runtime, runtime);
            release.check_content(b"content").unwrap();
        }
        let velopack = verify_release(
            &envelope(Runtime::VelopackWinX64, "2.0.0", COMMIT, b"x"),
            &Expected::runtime(Runtime::VelopackWinX64),
        )
        .unwrap();
        assert_eq!(velopack.asset_name, "PrunletApp-2.0.0-full.nupkg");
        assert_eq!(
            velopack.asset_url(),
            "https://prunlet.kagayoi.com/velopack/PrunletApp-2.0.0-full.nupkg"
        );
    }

    #[test]
    fn signature_and_key_failures_are_rejected() {
        let good = sample();
        // 署名の改ざん（DER のまま最後の1バイトを変える）。
        let text = String::from_utf8(good.clone()).unwrap();
        let value: Value = serde_json::from_str(&text).unwrap();
        let mut signature = STANDARD
            .decode(value["signature"].as_str().unwrap())
            .unwrap();
        let last = signature.len() - 1;
        signature[last] ^= 1;
        let tampered = text.replace(
            value["signature"].as_str().unwrap(),
            &STANDARD.encode(&signature),
        );
        assert!(error_text(verify_envelope(tampered.as_bytes())).contains("verification failed"));
        // payload の改ざん（署名は元のまま）。
        let payload = STANDARD.decode(value["payload"].as_str().unwrap()).unwrap();
        let changed = String::from_utf8(payload)
            .unwrap()
            .replace("1.2.3", "1.2.4");
        let swapped = text.replace(
            value["payload"].as_str().unwrap(),
            &STANDARD.encode(changed.as_bytes()),
        );
        assert!(error_text(verify_envelope(swapped.as_bytes())).contains("verification failed"));
        // 未知の鍵 ID。
        let unknown = text.replace("prunlet-release-test-1", "prunlet-release-9");
        assert!(error_text(verify_envelope(unknown.as_bytes())).contains("unknown key ID"));
        // テスト鍵で署名して本番鍵 ID を名乗っても通らない（鍵 ID と鍵の対応を固定している）。
        let impostor = envelope_for(b"{}", "prunlet-release-1");
        assert!(error_text(verify_envelope(&impostor)).contains("verification failed"));
        // r‖s（64 バイト）の署名は拒否する。
        let raw: Signature = signing_key().sign(b"payload");
        let raw_envelope = format!(
            "{{\"schema\":1,\"keyId\":\"{TEST_KEY_ID}\",\"payload\":\"{}\",\"signature\":\"{}\"}}",
            STANDARD.encode(b"payload"),
            STANDARD.encode(raw.to_bytes())
        );
        assert!(error_text(verify_envelope(raw_envelope.as_bytes())).contains("not DER"));
        // 冗長な DER（INTEGER の先頭に不要な 0x00）を拒否する。
        let der = raw.to_der();
        let bytes = der.as_bytes();
        let r_len = bytes[3] as usize;
        let mut padded = vec![0x30, bytes[1] + 1, 0x02, (r_len + 1) as u8, 0x00];
        padded.extend_from_slice(&bytes[4..]);
        let padded_envelope = format!(
            "{{\"schema\":1,\"keyId\":\"{TEST_KEY_ID}\",\"payload\":\"{}\",\"signature\":\"{}\"}}",
            STANDARD.encode(b"payload"),
            STANDARD.encode(&padded)
        );
        assert!(verify_envelope(padded_envelope.as_bytes()).is_err());
    }

    #[test]
    fn envelope_format_violations_are_rejected() {
        let good = String::from_utf8(sample()).unwrap();
        assert!(verify_envelope(good.as_bytes()).is_ok());
        let cases = [
            // 重複キー
            good.replacen("{\"schema\":1,", "{\"schema\":1,\"schema\":1,", 1),
            // 追加キー
            good.replacen("{\"schema\":1,", "{\"schema\":1,\"extra\":\"x\",", 1),
            // キー順の違い
            {
                let v: Value = serde_json::from_str(&good).unwrap();
                format!(
                    "{{\"keyId\":{},\"schema\":1,\"payload\":{},\"signature\":{}}}",
                    v["keyId"], v["payload"], v["signature"]
                )
            },
            // 空白・末尾改行・BOM
            good.replacen("\"schema\":1", "\"schema\": 1", 1),
            format!("{good}\n"),
            format!("\u{feff}{good}"),
            // schema の値・型
            good.replacen("\"schema\":1", "\"schema\":2", 1),
            good.replacen("\"schema\":1", "\"schema\":\"1\"", 1),
            // 文字列のエスケープの揺れ（意味は同じでも正規形でない）
            good.replacen("prunlet-release-test-1", "prunlet\\u002drelease-test-1", 1),
            // パディングなし・非正規の base64
            {
                let v: Value = serde_json::from_str(&good).unwrap();
                let s = v["signature"].as_str().unwrap();
                good.replace(s, s.trim_end_matches('='))
            },
            {
                // URL-safe アルファベット
                let v: Value = serde_json::from_str(&good).unwrap();
                let s = v["signature"].as_str().unwrap();
                assert!(s.contains('+') || s.contains('/'));
                good.replace(s, &s.replace('+', "-").replace('/', "_"))
            },
        ];
        for (index, case) in cases.iter().enumerate() {
            assert_ne!(case, &good, "case {index} must differ");
            assert!(verify_envelope(case.as_bytes()).is_err(), "case {index}");
        }
        // 非正規の base64（末尾の余りビットが 0 でない）。"QQ==" は正規、"QR==" は非正規。
        assert!(canonical_base64("QQ==").is_some());
        assert!(canonical_base64("QR==").is_none());
        assert!(canonical_base64("QQ").is_none());
        // サイズ超過（正規形でも 16384 バイトを超えれば拒否）。
        let big_payload = vec![b'x'; 13000];
        let big = envelope_for(&big_payload, TEST_KEY_ID);
        assert!(big.len() as u64 > MAX_ENVELOPE_BYTES);
        assert!(error_text(verify_envelope(&big)).contains("size"));
        // 上限ちょうど付近は受理される（サイズ判定の境界）。
        let fits = envelope_for(&vec![b'x'; 11000], TEST_KEY_ID);
        assert!(fits.len() as u64 <= MAX_ENVELOPE_BYTES);
        assert!(verify_envelope(&fits).is_ok());
    }

    #[test]
    fn payload_violations_are_rejected() {
        let sha = "c".repeat(64);
        let base = payload(Runtime::WinX64, "2.0.0", COMMIT, &sha, 10);
        let expect = Expected::runtime(Runtime::WinX64);
        assert!(verify_release(&envelope_for(base.as_bytes(), TEST_KEY_ID), &expect).is_ok());
        let cases: Vec<(String, &str)> = vec![
            (
                base.replace("\"Prunlet\",\"repository\"", "\"Other\",\"repository\""),
                "different product",
            ),
            (
                base.replace("1llum1n4t1s/Prunlet", "1llum1n4t1s/prunlet"),
                "different product",
            ),
            (
                base.replace("\"version\":\"2.0.0\"", "\"version\":\"2.0.0-rc.1\""),
                "strict",
            ),
            (
                base.replace("\"version\":\"2.0.0\"", "\"version\":\"02.0.0\""),
                "strict",
            ),
            (base.replace(COMMIT, &COMMIT.to_ascii_uppercase()), "commit"),
            (base.replace(&sha, &"C".repeat(64)), "SHA-256"),
            (base.replace("\"bytes\":10", "\"bytes\":0"), "limit"),
            (
                base.replace(
                    "\"bytes\":10",
                    &format!("\"bytes\":{}", 512u64 * 1024 * 1024 + 1),
                ),
                "limit",
            ),
            (base.replace("\"bytes\":10", "\"bytes\":10.0"), "integer"),
            (
                base.replace(
                    "prunlet-update-win-x64.zip\"",
                    "prunlet-update-win-arm64.zip\"",
                ),
                "fixed name",
            ),
            (
                base.replace("\"defaultBranch\":\"main\"", "\"defaultBranch\":\"../x\""),
                "branch",
            ),
            (
                base.replace("\"schema\":1,\"product\"", "\"product\""),
                "shape",
            ),
            (
                base.replace("{\"schema\":1,", "{\"schema\":1, "),
                "canonical",
            ),
        ];
        for (index, (text, needle)) in cases.iter().enumerate() {
            let message = error_text(verify_release(
                &envelope_for(text.as_bytes(), TEST_KEY_ID),
                &expect,
            ));
            assert!(message.contains(needle), "case {index}: {message}");
        }
        // runtime 違い（署名は正しい win-arm64 を win-x64 として要求）。
        let arm = payload(Runtime::WinArm64, "2.0.0", COMMIT, &sha, 10);
        assert!(
            error_text(verify_release(
                &envelope_for(arm.as_bytes(), TEST_KEY_ID),
                &expect
            ))
            .contains("runtime")
        );
        // キー不一致（自分で組み立てたキーと違う。名前は正しい）。
        for other_key in [
            format!(
                "releases/1llum1n4t1s/prunlet/{COMMIT}/win-x64/{}.zip",
                "d".repeat(64)
            ),
            format!("releases/1llum1n4t1s/Prunlet/{COMMIT}/win-x64/{sha}.zip"),
            format!("releases/1llum1n4t1s/prunlet/{COMMIT}/win-x64/{sha}.zip?x=1"),
            "../../evil.zip".to_owned(),
        ] {
            let text = base.replace(
                &asset_key(Runtime::WinX64, COMMIT, &sha, "prunlet-update-win-x64.zip"),
                &other_key,
            );
            assert!(
                error_text(verify_release(
                    &envelope_for(text.as_bytes(), TEST_KEY_ID),
                    &expect
                ))
                .contains("key")
            );
        }
        // 期待した版・commit との不一致。
        let mut versioned = expect;
        versioned.version = Some("2.0.1");
        assert!(
            error_text(verify_release(
                &envelope_for(base.as_bytes(), TEST_KEY_ID),
                &versioned
            ))
            .contains("version differs")
        );
        let mut committed = expect;
        committed.commit = Some("f".repeat(40).leak());
        assert!(
            error_text(verify_release(
                &envelope_for(base.as_bytes(), TEST_KEY_ID),
                &committed
            ))
            .contains("commit differs")
        );
    }

    #[test]
    fn version_rules_and_rollback_protection() {
        assert_eq!(parse_version("1.0.47"), Some([1, 0, 47]));
        assert_eq!(parse_version("999999999.0.0"), Some([999_999_999, 0, 0]));
        for bad in [
            "",
            "1",
            "1.0",
            "1.0.0.0",
            "01.0.0",
            "1.0.0-rc",
            "v1.0.0",
            "1.0.x",
            "1000000000.0.0",
            " 1.0.0",
        ] {
            assert_eq!(parse_version(bad), None, "{bad}");
        }
        assert!(is_newer("1.0.48", "1.0.47").unwrap());
        assert!(is_newer("1.10.0", "1.9.9").unwrap());
        assert!(!is_newer("1.0.47", "1.0.47").unwrap());
        assert!(!is_newer("1.0.46", "1.0.47").unwrap());
        assert!(is_newer("1.0.48", "garbage").is_err());
        assert!(manifest_url("1.0.0/../x", Runtime::WinX64).is_err());
        assert_eq!(
            manifest_url("1.2.3", Runtime::VelopackWinX64).unwrap(),
            "https://prunlet.kagayoi.com/manifests/1.2.3/velopack-win-x64.json"
        );
        assert_eq!(
            latest_url(Runtime::LinuxArm64).unwrap(),
            "https://prunlet.kagayoi.com/latest/linux-arm64.json"
        );
        assert!(latest_url(Runtime::VelopackWinX64).is_err());
    }

    /// 取得を差し替えた Unix の起動時更新の判定: 新版は取得・照合、同版・旧版は静かに None、
    /// 取得失敗・長さ/hash 不一致は Err（呼出し側で延期）。
    #[test]
    fn unix_candidate_fetches_only_signed_newer_assets() {
        let content = b"linux package".to_vec();
        let calls = RefCell::new(Vec::<(String, u64)>::new());
        let run = |envelope: Vec<u8>, asset: Vec<u8>, installed: &str| {
            calls.borrow_mut().clear();
            let fetch = |url: &str, limit: u64| -> Result<Vec<u8>> {
                calls.borrow_mut().push((url.to_owned(), limit));
                if url.ends_with("/latest/linux-x64.json") {
                    Ok(envelope.clone())
                } else {
                    Ok(asset.clone())
                }
            };
            unix_candidate(&fetch, Runtime::LinuxX64, installed)
        };
        let good = envelope(Runtime::LinuxX64, "2.0.0", COMMIT, &content);
        let candidate = run(good.clone(), content.clone(), "1.9.9")
            .unwrap()
            .unwrap();
        assert_eq!(candidate.version, "2.0.0");
        assert_eq!(candidate.commit, COMMIT);
        assert_eq!(candidate.bytes, content);
        let sha = hex::encode(Sha256::digest(&content));
        assert_eq!(
            *calls.borrow(),
            vec![
                (
                    "https://prunlet.kagayoi.com/latest/linux-x64.json".to_owned(),
                    16384
                ),
                (
                    format!(
                        "https://prunlet.kagayoi.com/releases/1llum1n4t1s/prunlet/{COMMIT}/linux-x64/{sha}.tar.gz"
                    ),
                    content.len() as u64
                ),
            ]
        );
        // 同版・旧版は配布物を取りに行かず None。
        assert!(
            run(good.clone(), content.clone(), "2.0.0")
                .unwrap()
                .is_none()
        );
        assert!(
            run(good.clone(), content.clone(), "2.0.1")
                .unwrap()
                .is_none()
        );
        assert_eq!(calls.borrow().len(), 1);
        // 中身の不一致（長さ・hash）は拒否。
        assert!(run(good.clone(), b"linux packagX".to_vec(), "1.0.0").is_err());
        assert!(run(good.clone(), b"linux package!".to_vec(), "1.0.0").is_err());
        // 別 runtime の封筒は拒否。
        let arm = envelope(Runtime::LinuxArm64, "2.0.0", COMMIT, &content);
        assert!(run(arm, content.clone(), "1.0.0").is_err());
        // 取得失敗は Err（延期）。
        let failing = |_: &str, _: u64| -> Result<Vec<u8>> { bail!("offline") };
        assert!(unix_candidate(&failing, Runtime::LinuxX64, "1.0.0").is_err());
    }

    #[test]
    fn versioned_manifest_checks_version_commit_and_rollback() {
        let content = b"zip".to_vec();
        let good = envelope(Runtime::WinX64, "2.0.0", COMMIT, &content);
        let fetch = |url: &str, limit: u64| -> Result<Vec<u8>> {
            assert_eq!(
                url,
                "https://prunlet.kagayoi.com/manifests/2.0.0/win-x64.json"
            );
            assert_eq!(limit, MAX_ENVELOPE_BYTES);
            Ok(good.clone())
        };
        let expected = Expected {
            runtime: Runtime::WinX64,
            package_id: "PrunletApp",
            version: Some("2.0.0"),
            commit: Some(COMMIT),
        };
        assert!(versioned_newer(&fetch, &expected, "1.0.0").is_ok());
        assert!(versioned_newer(&fetch, &expected, "2.0.0").is_err());
        assert!(versioned_newer(&fetch, &expected, "3.0.0").is_err());
        let wrong_commit = Expected {
            commit: Some("1123456789abcdef0123456789abcdef01234567"),
            ..expected
        };
        assert!(versioned_newer(&fetch, &wrong_commit, "1.0.0").is_err());
    }
}
