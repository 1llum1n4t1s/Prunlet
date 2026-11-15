//! 取得した更新パッケージ（nupkg）の信頼検査（適用の直前・fail-closed）。
//!
//! R2 からの HTTPS と Velopack のフィードのハッシュは、転送の破損と配信経路の改ざんは防ぐが、
//! 「配信元（R2）に別のビルドが置かれた」場合は防げない。Prunlet は削除ガードなので、
//! 適用の直前に次をすべて確かめ、1つでも満たさなければ適用しない。
//!
//! 1. **エントリの集合**: 名前が曖昧でなく（`\`・`:`・`..`・絶対パスなし、重複なし）、`lib/app/` には許可した
//!    ファイルだけがあること（[`entry_policy`]）。余分なファイルを混ぜた梱包を拒否する。
//! 2. **nuspec**: id と版が期待（フィードの資産）と一致すること。
//! 3. **全 PE の署名**: `.exe`・`.dll` すべてが Authenticode Valid・署名者の CN が本人・タイムスタンプ付き。
//! 4. **製品名・版**: `prunlet.exe`・`prunlet-maintenance.exe` の版リソースの製品名が `Prunlet`、
//!    版が nupkg の版と一致すること（Squirrel.exe は Velopack の製品なので対象外）。
//! 5. **machine**: 全 PE の machine が実行中のビルドと同じこと（別 CPU 向けの差し替えを拒否）。
//! 6. **署名付きマニフェスト**: nupkg の SHA-256 が、R2 の `manifests/<版>/velopack-win-x64.json`（固定公開鍵で署名した封筒。
//!    [`super::release`]）の payload と一致すること。配信元（R2）に別のビルドを置かれても、署名鍵が無ければ通らない。
//!    取得・検証できない場合も適用せず次回へ延期する。
//!
//! 事実の取り出し（[`super::authenticode`]・zip の読み取り）と合否の判断（このモジュールの純関数）を分け、
//! 判断は実物の署名済みファイルが無くても単体テストで網羅する。
//!
//! # 限界
//! - 検査から適用までの間に同じ利用者権限で nupkg を差し替える競合は、適用直前の再ハッシュで狭めるが、
//!   同じ権限なら導入先の実行ファイルそのものも書き換えられるため、この検査の脅威モデルの外とする。
//! - 失効確認（OCSP/CRL）は行わない（ログオン時にネットワークが無くても判断を終えるため）。
use std::{
    collections::HashSet,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use sha2::{Digest, Sha256};

use super::authenticode::{self, PeFactsSource, SignatureFacts, VersionFacts};

/// 期待する署名者の CN（本人の共通のコード署名証明書。thumbprint は年次更新で変わるため CN で照合する）。
pub const EXPECTED_SIGNER_COMMON_NAME: &str = "Open Source Developer Yuichiro Shinozaki";
/// 版リソースの製品名（Prunlet 自身の exe だけが対象）。
pub const EXPECTED_PRODUCT_NAME: &str = "Prunlet";
/// 製品の exe（`lib/app/` 直下）。製品名・版の照合の対象。
pub const PRODUCT_EXES: [&str; 2] = ["prunlet.exe", "prunlet-maintenance.exe"];
/// Velopack の Update.exe の、パッケージ内での名前。
pub const UPDATER_ENTRY: &str = "squirrel.exe";
/// 1つの PE の展開サイズの上限（zip 爆弾で一時領域を使い切られないため）。
const MAX_ENTRY_BYTES: u64 = 256 * 1024 * 1024;
/// 展開する PE の合計サイズの上限。
const MAX_TOTAL_BYTES: u64 = 512 * 1024 * 1024;

/// 検査に使う期待値。
#[derive(Debug, Clone)]
pub struct Policy {
    /// 期待する署名者の CN。
    pub signer_common_name: String,
    /// 期待する machine（実行中のビルドと同じ）。
    pub machine: u16,
    /// 署名（Valid・CN・タイムスタンプ）を要求するか。**テスト用機能でだけ false にできる**。
    pub require_signature: bool,
    /// 期待する packId（nuspec の id）。
    pub package_id: String,
    /// 期待する版（フィードの資産の版）。
    pub version: String,
}

/// PE 1つについて得た事実。
#[derive(Debug, Clone)]
pub struct PeFacts {
    /// nupkg 内のエントリ名。
    pub entry: String,
    pub signature: SignatureFacts,
    pub version: VersionFacts,
    pub machine: Option<u16>,
}

/// パッケージ全体について得た事実。
#[derive(Debug, Clone, Default)]
pub struct PackageFacts {
    /// 全エントリ名（zip の中央ディレクトリの順）。
    pub names: Vec<String>,
    /// nuspec の `<id>`。
    pub nuspec_id: Option<String>,
    /// nuspec の `<version>`。
    pub nuspec_version: Option<String>,
    /// 全 PE の事実。
    pub pes: Vec<PeFacts>,
    /// nupkg 全体の SHA-256（小文字16進）。
    pub sha256: String,
}

/// 検査の結果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// すべて満たした。
    Trusted,
    /// 信頼できない。適用しない（`untrusted`、終了コード 2）。
    Refused(String),
    /// 確かめられない（Release のハッシュを取得できないなど）。適用せず次回へ延期する。
    Deferred(String),
    /// 検査そのものが、ローカルの I/O の失敗（作業フォルダーを作れない・読めないなど）で行えなかった。
    /// 信頼できないという判断ではないので、`Refused`（untrusted）とは区別する。適用しない。
    Failed(String),
}

/// 事実の収集・検査の失敗。パッケージの中身が悪い（`Refused`）と、こちら側の I/O の失敗（`Failed`）を区別する。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerifyError {
    /// パッケージが期待を満たさない（信頼しない）。
    Refused(String),
    /// ローカルの I/O の失敗で検査できなかった。
    Failed(String),
}

impl std::fmt::Display for VerifyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.reason())
    }
}

impl VerifyError {
    /// 理由の文。
    pub fn reason(&self) -> &str {
        match self {
            VerifyError::Refused(reason) | VerifyError::Failed(reason) => reason,
        }
    }

    /// [`Verdict`] へ。
    pub fn into_verdict(self) -> Verdict {
        match self {
            VerifyError::Refused(reason) => Verdict::Refused(reason),
            VerifyError::Failed(reason) => Verdict::Failed(reason),
        }
    }
}

/// エントリ名が書き出し先で曖昧にならないか。
fn name_is_unambiguous(name: &str) -> bool {
    !name.is_empty()
        && !name.contains(['\\', ':', '\0'])
        && !name.starts_with('/')
        && !name.split('/').any(|part| part == "..")
}

/// `lib/app/` に置いてよいファイル名（小文字）。
///
/// vpk 1.2.161 の Windows の nupkg が作る `lib/app/` は6ファイル（梱包担当の実測）: `prunlet.exe`・
/// `prunlet-maintenance.exe`・`LICENSE`・`Squirrel.exe`（更新器）・`Prunlet_ExecutionStub.exe`（packTitle 由来の実行スタブ。
/// PE なので署名検証の対象）・`sq.version`。この集合以外は拒否する。ps1 や PRUNLET.md は同梱しない（共通指示は exe に埋め込む）。
pub fn entry_policy(file: &str) -> bool {
    matches!(
        file.to_ascii_lowercase().as_str(),
        "prunlet.exe"
            | "prunlet-maintenance.exe"
            | "squirrel.exe"
            | "sq.version"
            | "prunlet_executionstub.exe"
            | "license"
    )
}

/// エントリの集合を検査する（純関数）。
pub fn check_entries(names: &[String], package_id: &str) -> Result<(), String> {
    let nuspec = format!("{}.nuspec", package_id.to_ascii_lowercase());
    let mut seen = HashSet::new();
    let (mut product, mut maintenance, mut updater, mut specs) = (0, 0, 0, 0);
    for name in names {
        if !name_is_unambiguous(name) {
            return Err("The update package has an entry name that is not allowed.".into());
        }
        let lower = name.to_ascii_lowercase();
        if !seen.insert(lower.clone()) {
            return Err("The update package has duplicate entries.".into());
        }
        // フォルダーのエントリは、許可した置き場だけ。
        if let Some(directory) = lower.strip_suffix('/') {
            if matches!(
                directory,
                "lib"
                    | "lib/app"
                    | "_rels"
                    | "package"
                    | "package/services"
                    | "package/services/metadata"
                    | "package/services/metadata/core-properties"
            ) {
                continue;
            }
            return Err("The update package has a folder entry that is not allowed.".into());
        }
        if let Some(file) = lower.strip_prefix("lib/app/") {
            if file.contains('/') || !entry_policy(file) {
                return Err(format!(
                    "The update package has an entry that is not allowed: {name}"
                ));
            }
            product += usize::from(file == "prunlet.exe");
            maintenance += usize::from(file == "prunlet-maintenance.exe");
            updater += usize::from(file == UPDATER_ENTRY);
            continue;
        }
        if lower == nuspec {
            specs += 1;
            continue;
        }
        // 梱包の定型のファイル（OPC の定義と、vpk が置くアイコン）。
        if matches!(
            lower.as_str(),
            "[content_types].xml" | "_rels/.rels" | "setup.ico"
        ) {
            continue;
        }
        // OPC のコアプロパティ（`.psmdcp`。現行の vpk の実物には出ないが、NuGet 系の梱包で付くことがある）。
        if lower
            .strip_prefix("package/services/metadata/core-properties/")
            .is_some_and(|file| !file.contains('/') && file.ends_with(".psmdcp"))
        {
            continue;
        }
        return Err(format!(
            "The update package has an entry that is not allowed: {name}"
        ));
    }
    if product != 1 || maintenance != 1 || updater != 1 || specs != 1 {
        return Err(
            "The update package must contain exactly one prunlet.exe, prunlet-maintenance.exe, updater and package manifest."
                .into(),
        );
    }
    Ok(())
}

/// 署名の事実を検査する（純関数）。
fn check_signature(entry: &str, signature: &SignatureFacts, policy: &Policy) -> Result<(), String> {
    if !signature.valid {
        return Err(format!(
            "{entry} in the update package has no valid Authenticode signature."
        ));
    }
    match signature.common_name.as_deref() {
        Some(name) if name == policy.signer_common_name => {}
        Some(_) => {
            return Err(format!(
                "{entry} in the update package is signed by an unexpected publisher."
            ));
        }
        None => {
            return Err(format!(
                "The signer of {entry} in the update package could not be read."
            ));
        }
    }
    if !signature.timestamped {
        return Err(format!(
            "The signature of {entry} in the update package has no timestamp."
        ));
    }
    Ok(())
}

/// 版リソースが製品名と版の期待を満たすか（純関数）。`ProductVersion` は `<版>+<コミット>` の形なので、
/// `+` より前を比べる。FILEVERSION は `major.minor.patch.0` で、nupkg の版（SemVer の主・副・修正）と比べる。
fn check_version(entry: &str, facts: &VersionFacts, expected_version: &str) -> Result<(), String> {
    if facts.product_name.as_deref() != Some(EXPECTED_PRODUCT_NAME) {
        return Err(format!(
            "{entry} in the update package is not a Prunlet executable."
        ));
    }
    let core = expected_version
        .split(['-', '+'])
        .next()
        .unwrap_or(expected_version);
    let parts: Vec<Option<u16>> = core.split('.').map(|part| part.parse().ok()).collect();
    let numeric = match parts.as_slice() {
        [Some(a), Some(b), Some(c)] => Some([*a, *b, *c]),
        _ => None,
    };
    let file_version_matches = match (facts.file_version, numeric) {
        (Some([a, b, c, _]), Some([x, y, z])) => a == x && b == y && c == z,
        _ => false,
    };
    let product_version_matches = facts
        .product_version
        .as_deref()
        .is_some_and(|text| text.split('+').next() == Some(expected_version));
    if !file_version_matches || !product_version_matches {
        return Err(format!(
            "{entry} in the update package does not match the package version."
        ));
    }
    Ok(())
}

/// 事実が期待を満たすかを判断する（署名付きマニフェストの照合以外。純関数）。
pub fn evaluate_package(facts: &PackageFacts, policy: &Policy) -> Result<(), String> {
    check_entries(&facts.names, &policy.package_id)?;
    // nuspec の id・版。
    if facts
        .nuspec_id
        .as_deref()
        .is_none_or(|id| !id.eq_ignore_ascii_case(&policy.package_id))
    {
        return Err("The update package is for a different application.".into());
    }
    if facts.nuspec_version.as_deref() != Some(policy.version.as_str()) {
        return Err("The update package version does not match the feed.".into());
    }
    for pe in &facts.pes {
        if policy.require_signature {
            check_signature(&pe.entry, &pe.signature, policy)?;
        }
        if pe.machine != Some(policy.machine) {
            return Err(format!(
                "{} in the update package targets a different CPU architecture.",
                pe.entry
            ));
        }
        let file = pe.entry.rsplit('/').next().unwrap_or(&pe.entry);
        if PRODUCT_EXES
            .iter()
            .any(|exe| file.eq_ignore_ascii_case(exe))
        {
            check_version(&pe.entry, &pe.version, &policy.version)?;
        }
    }
    // 製品の exe は必ず PE として読めていること（読めなかったものを素通りさせない）。
    for exe in PRODUCT_EXES {
        let entry = format!("lib/app/{exe}");
        if !facts
            .pes
            .iter()
            .any(|pe| pe.entry.eq_ignore_ascii_case(&entry))
        {
            return Err(format!("{exe} could not be inspected."));
        }
    }
    Ok(())
}

/// nupkg の SHA-256 と、署名付きマニフェストの payload の SHA-256（[`super::release::fetch`]）を照合する。
/// `release` が Err（取得できない・署名や形式を検証できない・後退）なら延期、値が違えば拒否。
pub fn compare_release(package_sha256: &str, release: Result<String, String>) -> Verdict {
    match release {
        Err(reason) => Verdict::Deferred(format!(
            "The signed release manifest could not be confirmed ({reason}); the update was deferred."
        )),
        Ok(expected) if expected.eq_ignore_ascii_case(package_sha256) => Verdict::Trusted,
        Ok(_) => Verdict::Refused(
            "The update package does not match the SHA-256 in its signed release manifest.".into(),
        ),
    }
}

/// ファイルの SHA-256（小文字16進）。
pub fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// nuspec から `<tag>…</tag>` の最初の本文を取り出す（vpk の nuspec は単純な XML で、属性なしの要素を読むだけ）。
pub fn nuspec_value(xml: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = xml.find(&open)? + open.len();
    let end = xml[start..].find(&close)? + start;
    let value = xml[start..end].trim();
    (!value.is_empty()).then(|| value.to_owned())
}

/// nupkg を読み、事実を集める。PE は私的な作業フォルダー（`work`）へ取り出して調べ、終わったら消す。
/// `inspect` は署名・版・machine を読む関数（本番は [`authenticode`]、単体テストは差し替え可能）。
pub fn collect_facts(
    package: &Path,
    work: &Path,
    inspect: &dyn Fn(&Path) -> PeFactsSource,
) -> Result<PackageFacts, VerifyError> {
    let refused = |text: &str| VerifyError::Refused(text.to_owned());
    let file = fs::File::open(package)
        .map_err(|e| VerifyError::Failed(format!("The update package cannot be read: {e}")))?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|_| refused("The update package is not a readable archive."))?;
    let mut facts = PackageFacts {
        sha256: sha256_file(package).map_err(|e| {
            VerifyError::Failed(format!("The update package cannot be hashed: {e}"))
        })?,
        ..Default::default()
    };
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(|_| refused("The update package has an unreadable entry."))?;
        // 名前が UTF-8 として読めないエントリは、曖昧な名前としてパッケージごと拒否する。
        let name = entry
            .name()
            .map(|name| name.into_owned())
            .map_err(|_| refused("The update package has an entry name that is not allowed."))?;
        facts.names.push(name);
    }
    // 構造の検査に通らないパッケージは、展開もしない（曖昧な名前での書き出しを避ける）。
    // id は nuspec のファイル名から判断できないため、ここでは名前の曖昧さだけを先に確かめる。
    if facts.names.iter().any(|name| !name_is_unambiguous(name)) {
        return Err(refused(
            "The update package has an entry name that is not allowed.",
        ));
    }
    fs::create_dir_all(work).map_err(|e| {
        VerifyError::Failed(format!("The verification folder cannot be created: {e}"))
    })?;
    let mut total = 0u64;
    for index in 0..archive.len() {
        let name = facts.names[index].clone();
        let lower = name.to_ascii_lowercase();
        if lower.ends_with(".nuspec") && !lower.contains('/') {
            let mut text = String::new();
            let mut entry = archive
                .by_index(index)
                .map_err(|_| refused("The package manifest is unreadable."))?;
            entry
                .by_ref()
                .take(1024 * 1024)
                .read_to_string(&mut text)
                .map_err(|_| refused("The package manifest is not valid text."))?;
            facts.nuspec_id = nuspec_value(&text, "id");
            facts.nuspec_version = nuspec_value(&text, "version");
            continue;
        }
        if !(lower.ends_with(".exe") || lower.ends_with(".dll")) {
            continue;
        }
        let temporary: PathBuf = work.join(format!("pe-{index}.exe"));
        let result = (|| -> Result<(), VerifyError> {
            let mut entry = archive
                .by_index(index)
                .map_err(|_| refused("An executable in the update package is unreadable."))?;
            let mut output = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(|e| {
                    VerifyError::Failed(format!("The verification file cannot be created: {e}"))
                })?;
            // 圧縮データが壊れている場合も読み出しが失敗するので、パッケージの不正（Refused）として扱う。
            let copied = io::copy(&mut entry.by_ref().take(MAX_ENTRY_BYTES + 1), &mut output)
                .map_err(|e| {
                    VerifyError::Refused(format!("An executable could not be extracted: {e}"))
                })?;
            if copied > MAX_ENTRY_BYTES {
                return Err(refused("An executable in the update package is too large."));
            }
            total += copied;
            if total > MAX_TOTAL_BYTES {
                return Err(refused(
                    "The executables in the update package are too large.",
                ));
            }
            output.flush().map_err(|e| {
                VerifyError::Failed(format!("The verification file cannot be written: {e}"))
            })?;
            Ok(())
        })();
        let inspected = result.map(|()| inspect(&temporary));
        let _ = fs::remove_file(&temporary);
        let inspected = inspected?;
        facts.pes.push(PeFacts {
            entry: name,
            signature: inspected.signature,
            version: inspected.version,
            machine: inspected.machine,
        });
    }
    Ok(facts)
}

/// 本番の事実の取り出し（Authenticode・版リソース・PE ヘッダー）。
pub fn inspect_pe(path: &Path) -> PeFactsSource {
    let header = fs::File::open(path)
        .and_then(|mut file| {
            let mut buffer = vec![0u8; 4096];
            let read = file.read(&mut buffer)?;
            buffer.truncate(read);
            Ok(buffer)
        })
        .unwrap_or_default();
    PeFactsSource {
        signature: authenticode::signature_facts(path),
        version: authenticode::version_facts(path),
        machine: authenticode::pe_machine(&header),
    }
}

/// 署名の省略を許すか。`velopack-test` 機能付きのビルドで、環境変数が明示されたときだけ真。
/// 配布ビルドでは常に偽で、この分岐自体がコンパイルされない。省けるのは**署名の検査だけ**で、
/// エントリ集合・製品名・版・machine・Release ハッシュの検査は常に行う。
pub fn unsigned_allowed_for_test() -> bool {
    #[cfg(feature = "velopack-test")]
    {
        std::env::var_os("PRUNLET_VELOPACK_TEST_ALLOW_UNSIGNED").is_some_and(|value| value == "1")
    }
    #[cfg(not(feature = "velopack-test"))]
    {
        false
    }
}

/// 本番の期待値。
pub fn policy_for(package_id: &str, version: &str) -> Policy {
    Policy {
        signer_common_name: EXPECTED_SIGNER_COMMON_NAME.to_owned(),
        machine: authenticode::running_machine(),
        require_signature: !unsigned_allowed_for_test(),
        package_id: package_id.to_owned(),
        version: version.to_owned(),
    }
}

/// nupkg を検査する（Release のハッシュ以外）。通れば事実（SHA-256 を含む）を返す。
///
/// `work_root` は検査用の置き場（私的なフォルダー）。実行ごとに一意のサブフォルダーを作り、終わったら消す
/// （並行する検査同士や、前回の失敗の残骸と取り違えない）。
pub fn verify_package(
    package: &Path,
    work_root: &Path,
    policy: &Policy,
) -> Result<PackageFacts, VerifyError> {
    let work = work_root.join(format!("verify-{}", uuid::Uuid::new_v4().simple()));
    let result = collect_facts(package, &work, &inspect_pe);
    let _ = fs::remove_dir_all(&work);
    let facts = result?;
    evaluate_package(&facts, policy).map_err(VerifyError::Refused)?;
    Ok(facts)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    /// vpk の実物の並びに近い、正しいパッケージ。
    fn good_names() -> Vec<String> {
        names(&[
            "[Content_Types].xml",
            "setup.ico",
            "PrunletApp.nuspec",
            "_rels/.rels",
            "lib/app/prunlet.exe",
            "lib/app/prunlet-maintenance.exe",
            "lib/app/sq.version",
            "lib/app/Squirrel.exe",
            "lib/app/Prunlet_ExecutionStub.exe",
            "lib/app/LICENSE",
        ])
    }

    fn policy() -> Policy {
        Policy {
            signer_common_name: EXPECTED_SIGNER_COMMON_NAME.into(),
            machine: authenticode::MACHINE_AMD64,
            require_signature: true,
            package_id: "PrunletApp".into(),
            version: "1.0.48".into(),
        }
    }

    fn signed() -> SignatureFacts {
        SignatureFacts {
            valid: true,
            common_name: Some(EXPECTED_SIGNER_COMMON_NAME.into()),
            timestamped: true,
        }
    }

    fn product_version() -> VersionFacts {
        VersionFacts {
            product_name: Some("Prunlet".into()),
            file_version: Some([1, 0, 48, 0]),
            product_version: Some("1.0.48+0123456789abcdef0123456789abcdef01234567".into()),
        }
    }

    fn pe(entry: &str) -> PeFacts {
        PeFacts {
            entry: entry.into(),
            signature: signed(),
            version: product_version(),
            machine: Some(authenticode::MACHINE_AMD64),
        }
    }

    /// 全項目が正しいパッケージの事実。
    fn good_facts() -> PackageFacts {
        let mut updater = pe("lib/app/Squirrel.exe");
        // Squirrel.exe は Velopack の製品。製品名・版は照合しない。
        updater.version = VersionFacts::default();
        PackageFacts {
            names: good_names(),
            nuspec_id: Some("PrunletApp".into()),
            nuspec_version: Some("1.0.48".into()),
            pes: vec![
                pe("lib/app/prunlet.exe"),
                pe("lib/app/prunlet-maintenance.exe"),
                updater,
            ],
            sha256: "ab".repeat(32),
        }
    }

    #[test]
    fn a_correct_package_is_accepted() {
        evaluate_package(&good_facts(), &policy()).unwrap();
    }

    // 合否基準4: 7種の拒否をそれぞれ適用前に拒否する。

    #[test]
    fn refuses_unsigned_executables() {
        let mut facts = good_facts();
        facts.pes[1].signature = SignatureFacts::default();
        let error = evaluate_package(&facts, &policy()).unwrap_err();
        assert!(error.contains("no valid Authenticode signature"), "{error}");
        // 署名が Valid でも、タイムスタンプが無ければ拒否する。
        let mut facts = good_facts();
        facts.pes[0].signature.timestamped = false;
        assert!(
            evaluate_package(&facts, &policy())
                .unwrap_err()
                .contains("no timestamp")
        );
        // 署名者を読めない場合も拒否する。
        let mut facts = good_facts();
        facts.pes[0].signature.common_name = None;
        assert!(evaluate_package(&facts, &policy()).is_err());
        // Squirrel.exe（更新器）が未署名でも拒否する（全 PE が対象）。
        let mut facts = good_facts();
        facts.pes[2].signature.valid = false;
        assert!(evaluate_package(&facts, &policy()).is_err());
    }

    #[test]
    fn refuses_a_different_signer() {
        let mut facts = good_facts();
        facts.pes[0].signature.common_name = Some("Someone Else".into());
        let error = evaluate_package(&facts, &policy()).unwrap_err();
        assert!(error.contains("unexpected publisher"), "{error}");
    }

    #[test]
    fn refuses_a_different_product_name() {
        let mut facts = good_facts();
        facts.pes[1].version.product_name = Some("Other".into());
        let error = evaluate_package(&facts, &policy()).unwrap_err();
        assert!(error.contains("not a Prunlet executable"), "{error}");
        let mut facts = good_facts();
        facts.pes[0].version = VersionFacts::default();
        assert!(evaluate_package(&facts, &policy()).is_err());
    }

    #[test]
    fn refuses_a_version_mismatch() {
        // 版リソースがパッケージの版と違う（FILEVERSION・ProductVersion のどちらでも）。
        let mut facts = good_facts();
        facts.pes[0].version.file_version = Some([1, 0, 47, 0]);
        assert!(
            evaluate_package(&facts, &policy())
                .unwrap_err()
                .contains("package version")
        );
        let mut facts = good_facts();
        facts.pes[1].version.product_version = Some("1.0.47+abc".into());
        assert!(evaluate_package(&facts, &policy()).is_err());
        // nuspec の版がフィードの版と違う。
        let mut facts = good_facts();
        facts.nuspec_version = Some("1.0.49".into());
        assert!(
            evaluate_package(&facts, &policy())
                .unwrap_err()
                .contains("does not match the feed")
        );
        // nuspec の id が違う（別のアプリのパッケージ）。
        let mut facts = good_facts();
        facts.nuspec_id = Some("OtherApp".into());
        assert!(evaluate_package(&facts, &policy()).is_err());
    }

    #[test]
    fn refuses_extra_or_missing_entries() {
        for extra in [
            "lib/app/extra.dll",
            "lib/app/start-prunlet-mcp.ps1",
            "lib/app/PRUNLET.md",
            "lib/app/sub/prunlet.exe",
            "lib/other.exe",
            "evil.exe",
            "lib/app/",
        ] {
            let mut items = good_names();
            items.push(extra.into());
            let result = check_entries(&items, "PrunletApp");
            // 許可した置き場のフォルダーエントリ（lib/app/）だけは通る。
            if extra == "lib/app/" {
                assert!(result.is_ok(), "{extra}");
            } else {
                assert!(result.is_err(), "{extra}");
            }
        }
        // 必須の exe が無い・重複している。
        let missing: Vec<String> = good_names()
            .into_iter()
            .filter(|n| n != "lib/app/prunlet-maintenance.exe")
            .collect();
        assert!(check_entries(&missing, "PrunletApp").is_err());
        let mut duplicated = good_names();
        duplicated.push("LIB/APP/PRUNLET.EXE".into());
        assert!(check_entries(&duplicated, "PrunletApp").is_err());
        // 曖昧な名前はパッケージごと拒否する。
        for bad in [
            "lib/app/..\\x.exe",
            "lib/../prunlet.exe",
            "C:/x.exe",
            "/abs.exe",
            "lib\\app\\prunlet.exe",
        ] {
            let mut items = good_names();
            items.push(bad.into());
            assert!(check_entries(&items, "PrunletApp").is_err(), "{bad}");
        }
    }

    #[test]
    fn refuses_a_different_machine() {
        let mut facts = good_facts();
        facts.pes[0].machine = Some(authenticode::MACHINE_ARM64);
        assert!(
            evaluate_package(&facts, &policy())
                .unwrap_err()
                .contains("different CPU")
        );
        // 読めない PE も拒否する。
        let mut facts = good_facts();
        facts.pes[2].machine = None;
        assert!(evaluate_package(&facts, &policy()).is_err());
    }

    #[test]
    fn product_executable_that_was_not_inspected_is_refused() {
        let mut facts = good_facts();
        facts.pes.remove(0);
        assert!(
            evaluate_package(&facts, &policy())
                .unwrap_err()
                .contains("could not be inspected")
        );
    }

    #[test]
    fn signed_manifest_hash_is_compared() {
        // 照合: 一致なら信頼、不一致は拒否、取得・検証の失敗は延期。マニフェスト自体の検査は release.rs のテスト。
        let package = "ab".repeat(32);
        assert_eq!(
            compare_release(&package, Ok(package.clone())),
            Verdict::Trusted
        );
        assert!(matches!(
            compare_release(&package, Ok("cd".repeat(32))),
            Verdict::Refused(_)
        ));
        assert!(matches!(
            compare_release(&package, Err("offline".into())),
            Verdict::Deferred(_)
        ));
    }

    #[test]
    fn nuspec_values_are_read_without_a_full_xml_parser() {
        let xml = "<?xml version=\"1.0\"?><package><metadata><id>PrunletApp</id>\n<version> 1.0.48 </version></metadata></package>";
        assert_eq!(nuspec_value(xml, "id").as_deref(), Some("PrunletApp"));
        assert_eq!(nuspec_value(xml, "version").as_deref(), Some("1.0.48"));
        assert_eq!(nuspec_value(xml, "title"), None);
    }

    // 実際の zip を読む経路（合否基準4を、実在する PE と署名の API まで通して確かめる）。

    fn scratch() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("prunlet-trust-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 指定の実体で nupkg を作る。
    fn build_package(path: &Path, entries: &[(&str, &[u8])]) {
        let file = fs::File::create(path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        for (name, bytes) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(bytes).unwrap();
        }
        writer.finish().unwrap();
    }

    #[test]
    fn real_package_with_unsigned_executables_is_refused_by_the_real_api() {
        let dir = scratch();
        let exe = fs::read(std::env::current_exe().unwrap()).unwrap();
        let nuspec =
            b"<package><metadata><id>PrunletApp</id><version>1.0.48</version></metadata></package>";
        let package = dir.join("PrunletApp-1.0.48-full.nupkg");
        build_package(
            &package,
            &[
                ("[Content_Types].xml", b"x"),
                ("_rels/.rels", b"x"),
                ("PrunletApp.nuspec", nuspec),
                ("lib/app/prunlet.exe", &exe),
                ("lib/app/prunlet-maintenance.exe", &exe),
                ("lib/app/Squirrel.exe", &exe),
            ],
        );
        let work = dir.join("work");
        let mut policy = policy();
        // 署名を要求すると、未署名の実体は実際の WinVerifyTrust で拒否される。
        let error = verify_package(&package, &work, &policy).unwrap_err();
        assert!(
            error.reason().contains("no valid Authenticode signature"),
            "{error}"
        );
        // 作業用の取り出し先は、拒否のときも空に戻っている。
        assert_eq!(fs::read_dir(&work).unwrap().count(), 0);
        // 署名を省いても、テストの exe は製品名・版リソースを持たない（`Prunlet` ではない）ので拒否される。
        policy.require_signature = false;
        let error = verify_package(&package, &work, &policy).unwrap_err();
        assert!(
            error.reason().contains("not a Prunlet executable"),
            "{error}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_package_with_a_wrong_hash_or_layout_is_refused() {
        let dir = scratch();
        let work = dir.join("work");
        // 余分なエントリ（ps1）を混ぜた梱包は、展開より前に構造で拒否される。
        let package = dir.join("p.nupkg");
        build_package(
            &package,
            &[
                (
                    "PrunletApp.nuspec",
                    b"<id>PrunletApp</id><version>1.0.48</version>",
                ),
                ("lib/app/start-prunlet-mcp.ps1", b"x"),
            ],
        );
        let error = verify_package(&package, &work, &policy()).unwrap_err();
        assert!(error.reason().contains("not allowed"), "{error}");
        // zip でないファイルは拒否される。
        fs::write(&package, b"not a zip").unwrap();
        assert!(verify_package(&package, &work, &policy()).is_err());
        // SHA-256 は内容から計算される（別の内容なら別の値）。
        let a = dir.join("a");
        let b = dir.join("b");
        fs::write(&a, b"one").unwrap();
        fs::write(&b, b"two").unwrap();
        assert_ne!(sha256_file(&a).unwrap(), sha256_file(&b).unwrap());
        assert_eq!(sha256_file(&a).unwrap().len(), 64);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn local_io_failures_are_distinguished_from_refusals_and_work_folders_are_unique() {
        let dir = scratch();
        let work = dir.join("work");
        // 存在しない nupkg は、パッケージの不正ではなくローカルの I/O の失敗（Failed）。
        let missing = verify_package(&dir.join("missing.nupkg"), &work, &policy()).unwrap_err();
        assert!(matches!(missing, VerifyError::Failed(_)), "{missing:?}");
        assert!(matches!(missing.into_verdict(), Verdict::Failed(_)));
        // zip でないものはパッケージの不正（Refused）。
        let bad = dir.join("bad.nupkg");
        fs::write(&bad, b"not a zip").unwrap();
        assert!(matches!(
            verify_package(&bad, &work, &policy()).unwrap_err(),
            VerifyError::Refused(_)
        ));
        // 検査用フォルダーは実行ごとの一意の名前で、終わったら残らない（固定名の取り違えがない）。
        assert!(!work.exists() || fs::read_dir(&work).unwrap().count() == 0);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn opc_core_properties_are_allowed_but_other_package_entries_are_not() {
        let mut items = good_names();
        items.push("package/services/metadata/core-properties/abc.psmdcp".into());
        items.push("package/".into());
        items.push("package/services/metadata/core-properties/".into());
        assert!(check_entries(&items, "PrunletApp").is_ok());
        for bad in [
            "package/services/metadata/core-properties/a.exe",
            "package/services/metadata/core-properties/x/y.psmdcp",
            "package/other.psmdcp",
        ] {
            let mut items = good_names();
            items.push(bad.into());
            assert!(check_entries(&items, "PrunletApp").is_err(), "{bad}");
        }
    }
}
