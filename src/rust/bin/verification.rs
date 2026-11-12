//! libtest専用の検証入口。製品binaryにはコンパイルせず、固定された外部入力だけを使う。
#[path = "../migration/store.rs"]
mod fixture_store;

use crate::{
    config::Config,
    json,
    platform::windows::{self, path},
    registry,
};
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    io::Write,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    schema: u32,
    root_path: String,
    candidate_path: String,
    candidate_sha256: String,
    expected_probe_sha256: String,
    config_path: String,
    #[serde(default)]
    config_sha256: String,
    result_path: String,
    #[serde(default)]
    signal_path: String,
    #[serde(default)]
    event_name: String,
    #[serde(default)]
    checkpoint: String,
    #[serde(default)]
    operation_id: String,
    #[serde(default)]
    action: String,
    #[serde(default)]
    case: String,
    #[serde(default)]
    fixture_relative: String,
    #[serde(default)]
    fixture_root: String,
    #[serde(skip)]
    root_pin: Option<path::DirectoryLease>,
}
fn digest(path: &Path) -> Result<String> {
    Ok(hex::encode(Sha256::digest(windows::read_plain_file(
        path,
        512 * 1024 * 1024,
        false,
    )?)))
}
fn contained(root: &Path, value: &str) -> Result<PathBuf> {
    let value = path::absolute(Path::new(value))?;
    ensure!(
        path::within(&value, root) && value != root,
        "Verification output escaped its fixed external scope."
    );
    let _pin = path::pin_directories(value.parent().context("Missing output parent")?)?;
    Ok(value)
}
fn input(native_registry: bool) -> Result<Request> {
    let request_path = PathBuf::from(
        std::env::var("PRUNLET_VERIFICATION_REQUEST")
            .context("A fixed native verification request is required")?,
    );
    let request_bytes = windows::read_plain_file(&request_path, 65536, true)?;
    ensure!(
        hex::encode(Sha256::digest(&request_bytes))
            .eq_ignore_ascii_case(&std::env::var("PRUNLET_VERIFICATION_REQUEST_SHA256")?),
        "Fixed verification request changed."
    );
    let mut request: Request = serde_json::from_value(json::parse_unique(&request_bytes)?)?;
    ensure!(request.schema == 1, "Unsupported verification request.");
    // 出力rootはドライブ文字を問わず、通常のドライブ絶対パスでリポジトリとCodex homeの外に限る。
    // 呼出し元のRustProbe.Common.ps1も同じ条件で検査する。
    let root = path::external_verification_path(Path::new(&request.root_path))?;
    request.root_pin = Some(path::pin_directories(&root)?);
    contained(
        &root,
        request_path.to_str().context("Non-Unicode request path")?,
    )?;
    contained(&root, &request.result_path)?;
    if !request.signal_path.is_empty() {
        contained(&root, &request.signal_path)?;
    }
    ensure!(
        digest(Path::new(&request.candidate_path))?.eq_ignore_ascii_case(&request.candidate_sha256),
        "Prepared candidate executable changed."
    );
    ensure!(
        digest(&std::env::current_exe()?)?.eq_ignore_ascii_case(&request.expected_probe_sha256),
        "Prepared Rust verification probe changed."
    );
    // 製品と同じ実token/native view判定を通し、6801を成功へ置き換えない。
    if native_registry {
        registry::native::verify_native_session_context()?;
    }
    Ok(request)
}
fn output(request: &Request, value: Value, scope: &str) -> Result<()> {
    let root = path::absolute(Path::new(&request.root_path))?;
    let result = contained(&root, &request.result_path)?;
    let report = json!({"schema":1,"runtime":"rust-libtest","candidateSha256":request.candidate_sha256,"probeSha256":request.expected_probe_sha256,"realNativeScopeVerified":scope=="native-registry","nativeFileProbe":scope=="native-file","syntheticMetadataOnly":scope=="synthetic-registry-metadata","result":value});
    windows::write_new_plain_file(&result, &serde_json::to_vec_pretty(&report)?)
}

#[test]
#[ignore = "Requires a fixed external native file coordination request"]
fn coordination_hold() -> Result<()> {
    use std::io::BufRead;
    let request = input(false)?;
    let root = path::absolute(Path::new(&request.root_path))?;
    let config_path = contained(&root, &request.config_path)?;
    ensure!(
        !request.config_sha256.is_empty()
            && digest(&config_path)?.eq_ignore_ascii_case(&request.config_sha256),
        "Fixed coordination config changed."
    );
    let target = contained(&root, &request.fixture_root)?;
    ensure!(target.exists(), "Owned coordination target is missing.");
    let config = Config::load(&config_path)?;
    let backup = path::absolute(Path::new(&config.data.backup_directory))?;
    ensure!(
        path::within(&backup, &root) && backup != root,
        "Coordination metadata escaped owned scope."
    );
    let signal = contained(&root, &request.signal_path)?;
    // 製品と同一の本物のclaimを保持し、試験側が解放するまで別processを待たせる。
    let claim =
        crate::files::coordination::acquire(&config, Some(std::slice::from_ref(&target)), None)?;
    windows::write_new_plain_file(
        &signal,
        format!("{}\n{}", std::process::id(), target.display()).as_bytes(),
    )?;
    println!("PRUNLET_COORDINATION_HELD {}", std::process::id());
    std::io::stdout().flush()?;
    let mut release = String::new();
    let count = std::io::stdin().lock().read_line(&mut release)?;
    ensure!(
        count != 0 && release.trim_end_matches(['\r', '\n']) == "release",
        "Coordination release was not confirmed."
    );
    drop(claim);
    output(
        &request,
        json!({"passed":true,"target":target.to_string_lossy(),"released":true}),
        "native-file",
    )
}

#[test]
#[ignore = "Requires a fixed Prepare-bound external native-verification request and actual native Windows token"]
fn checkpoint() -> Result<()> {
    let request = input(true)?;
    ensure!(
        uuid::Uuid::parse_str(&request.operation_id)
            .is_ok_and(|id| id.simple().to_string() == request.operation_id),
        "Invalid checkpoint operation id."
    );
    ensure!(
        matches!(
            request.event_name.as_str(),
            "RegistryControlCheckpoint" | "RegistryPublicationCheckpoint"
        ),
        "Invalid checkpoint event."
    );
    ensure!(
        matches!(
            request.action.as_str(),
            "Migrate" | "MigrateMaintain" | "Restore"
        ),
        "Invalid checkpoint action."
    );
    let signal = contained(Path::new(&request.root_path), &request.signal_path)?;
    let selected = (
        request.event_name.clone(),
        request.checkpoint.clone(),
        request.operation_id.clone(),
    );
    registry::verification_set_checkpoint(Some(Arc::new(move |event, phase, id| {
        if event != selected.0 || phase != selected.1 || id != selected.2 {
            return;
        }
        let published = (|| -> Result<()> {
            let pending = signal.with_extension("writing");
            let bytes = format!("{phase}\n{id}\n{}", std::process::id());
            windows::write_new_plain_file(&pending, bytes.as_bytes())?;
            ensure!(!signal.exists(), "Owned checkpoint signal already exists.");
            std::fs::rename(&pending, &signal)?;
            println!("PRUNLET_VERIFICATION_CHECKPOINT");
            std::io::stdout().flush()?;
            Ok(())
        })();
        if let Err(error) = published {
            panic!("Cannot publish owned verification checkpoint: {error:#}");
        }
        // 親がこの所有childを停止する。既存fixtureの他processは触らない。
        loop {
            std::thread::park();
        }
    })));
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            registry::verification_set_checkpoint(None);
        }
    }
    let _reset = Reset;
    let config = Config::load(Path::new(&request.config_path))?;
    if request.action == "Restore" {
        registry::execute(
            &config,
            "registry-restore",
            &json!({"operationId":request.operation_id}),
            None,
        )?;
    } else {
        registry::execute(&config, "migrate", &json!({"apply":true}), None)?;
        if request.action == "MigrateMaintain" {
            registry::execute(&config, "maintain", &json!({"apply":true}), None)?;
        }
    }
    bail!("Public operation ended without the selected durable checkpoint.")
}

#[test]
#[ignore = "Requires a fixed Prepare-bound external native-verification request and actual native Windows token"]
fn native_contract() -> Result<()> {
    let request = input(true)?;
    let fixture = registry::model::Target::new(&request.fixture_relative, "64", None, "normal")?;
    let segments = &fixture.segments;
    ensure!(
        segments.len() >= 3
            && ((fixture.hive == "HKEY_CURRENT_USER" && segments[0] == "Software")
                || (fixture.hive == "HKEY_LOCAL_MACHINE" && segments[0] == "SYSTEM"))
            && segments[1] == "PrunletE2E"
            && uuid::Uuid::parse_str(&segments[2])
                .is_ok_and(|id| id.simple().to_string() == segments[2]),
        "Native API probe requires the owned GUID fixture root."
    );
    ensure!(
        matches!(
            request.case.as_str(),
            "classes-alias-guard" | "incomplete-links" | "snapshot-publication-rollback"
        ),
        "Unknown native API contract probe."
    );
    let case = match request.case.as_str() {
        "classes-alias-guard" => "core-classes-alias-proof-permission-and-staged-commit-conflict",
        "incomplete-links" => "core-incomplete-links-cannot-be-used-as-ordinary-keys",
        "snapshot-publication-rollback" => {
            "core-snapshot-publication-fault-rolls-back-staged-value"
        }
        _ => unreachable!(),
    };
    let result = registry::verification_native_contract(case, &request.fixture_relative)?;
    output(&request, result, "native-registry")
}

#[test]
#[ignore = "Requires a fixed external request and an owned native file fixture"]
fn files_contract() -> Result<()> {
    let request = input(false)?;
    let fixture = path::absolute(Path::new(&request.fixture_root))?;
    ensure!(
        !fixture
            .to_string_lossy()
            .contains("hardlink-protected-20261102"),
        "The retired dangerous fixture must not be reused."
    );
    let _fixture = path::pin_directories(&fixture)?;
    let result = if matches!(
        request.case.as_str(),
        "file-independent-roots" | "file-recycled-alias-independent"
    ) {
        let config_path = contained(Path::new(&request.root_path), &request.config_path)?;
        ensure!(
            request.config_sha256.len() == 64
                && digest(&config_path)?.eq_ignore_ascii_case(&request.config_sha256),
            "Fixed file probe configuration changed"
        );
        let config = Config::load(&config_path)?;
        crate::files::verification_independence(&request.case, &request.fixture_root, &config)?
    } else {
        crate::files::verification_native_contract(&request.case, &request.fixture_root)?
    };
    output(&request, result, "native-file")
}

#[test]
#[ignore = "Requires a fixed external metadata-only publication verification request"]
fn snapshot_publication() -> Result<()> {
    let request = input(false)?;
    ensure!(
        request.action == "snapshot-publication",
        "Unknown metadata-only verification action."
    );
    let config = Config::load(Path::new(&request.config_path))?;
    let result = registry::verification_snapshot_publication(&config)?;
    output(&request, result, "synthetic-registry-metadata")
}

#[test]
#[ignore = "Requires fixed same-build product/probe request and newly owned legacy fixture"]
fn legacy_discard() -> Result<()> {
    let request = input(false)?;
    ensure!(
        matches!(request.action.as_str(), "Checkpoint" | "Swap"),
        "Invalid legacy discard action."
    );
    ensure!(
        matches!(
            request.checkpoint.as_str(),
            "gate.flushed" | "shell.ready" | "shell.returned"
        ),
        "Invalid legacy discard checkpoint."
    );
    ensure!(
        request.action != "Swap" || request.checkpoint == "shell.ready",
        "Swap requires shell.ready."
    );
    let target = path::absolute(Path::new(&request.fixture_root))?;
    let phase = request.checkpoint.clone();
    let signal = contained(Path::new(&request.root_path), &request.signal_path)?;
    let resume = request.action == "Swap";
    let reached = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let signal_reached = reached.clone();
    crate::migration::verification_set_checkpoint(Some(Arc::new(move |observed, actual| {
        if phase != observed
            || !registry::model::ordinal_eq(&target.to_string_lossy(), &actual.to_string_lossy())
        {
            return;
        }
        signal_reached.store(true, std::sync::atomic::Ordering::SeqCst);
        let notified = (|| -> Result<()> {
            // continuationはnamed eventで待つ。ファイルの短周期pollを追加しない。
            let event_name = format!("Local\\PrunletLegacyDiscard-{}", std::process::id());
            let event = unsafe {
                windows::OwnedHandle::from_raw(
                    windows_sys::Win32::System::Threading::CreateEventW(
                        std::ptr::null(),
                        1,
                        0,
                        windows::wide(std::ffi::OsStr::new(&event_name))?.as_ptr(),
                    ),
                )?
            };
            let body = format!("{observed}\n{}\n{}", actual.display(), std::process::id());
            let pending = signal.with_extension("writing");
            let handle = windows::security::create_private_file(&pending)?;
            windows::write_handle(handle.raw(), body.as_bytes())?;
            let parent = windows::PinnedFile::open(
                signal.parent().context("Missing signal parent")?,
                windows_sys::Win32::Storage::FileSystem::FILE_READ_ATTRIBUTES,
                3,
            )?;
            windows::security::rename_fixed(
                handle.raw(),
                parent.raw(),
                signal
                    .file_name()
                    .and_then(|s| s.to_str())
                    .context("Invalid signal leaf")?,
            )?;
            // 通知は回復authorityではない。公開完了後に書込handleを閉じ、親のread共有と競合させない。
            drop(handle);
            drop(parent);
            println!("PRUNLET_LEGACY_DISCARD_CHECKPOINT");
            std::io::stdout().flush()?;
            if resume {
                ensure!(
                    unsafe {
                        windows_sys::Win32::System::Threading::WaitForSingleObject(
                            event.raw(),
                            60000,
                        )
                    } == 0,
                    "Legacy discard continuation not received."
                );
            } else {
                loop {
                    std::thread::park();
                }
            }
            Ok(())
        })();
        if let Err(error) = notified {
            panic!("Cannot bind legacy discard checkpoint: {error:#}");
        }
    })));
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            crate::migration::verification_set_checkpoint(None);
        }
    }
    let _reset = Reset;
    let config = Config::load(Path::new(&request.config_path))?;
    let result = registry::execute(&config, "migrate", &json!({"apply":true}), None)?;
    ensure!(
        request.action == "Swap" && reached.load(std::sync::atomic::Ordering::SeqCst),
        "Migration ended without selected checkpoint."
    );
    println!("{}", serde_json::to_string(&result)?);
    output(&request, result, "native-file")
}

#[test]
#[ignore = "Requires fixed same-source probe and owned marker fixture"]
fn owned_markers() -> Result<()> {
    let request = input(false)?;
    ensure!(
        matches!(
            request.action.as_str(),
            "CreateTypedRoots" | "CreateRestoreRoot"
        ),
        "Unknown marker fixture action"
    );
    let metadata = path::absolute(Path::new(&request.fixture_root))?;
    let store_parent = path::absolute(Path::new(&request.fixture_relative))?;
    let repository = Path::new(env!("CARGO_MANIFEST_DIR"));
    for anchor in [&metadata, &store_parent] {
        ensure!(
            anchor.to_string_lossy().len() > 3 && !path::within(anchor, repository),
            "Fixture anchor must be an external non-root directory"
        );
        let _pin = path::pin_directories(anchor)?;
    }
    ensure!(
        request.config_sha256.len() == 64
            && digest(Path::new(&request.config_path))?
                .eq_ignore_ascii_case(&request.config_sha256),
        "Fixed fixture configuration changed"
    );
    let config = Config::load(Path::new(&request.config_path))?;
    let result = fixture_store::verification_owned_markers(
        &config,
        &request.action,
        &metadata,
        &store_parent,
    )?;
    output(&request, result, "native-file")
}
