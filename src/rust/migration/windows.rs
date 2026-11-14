use super::{MigrationOperation, MigrationResult};
use crate::{
    config::Config,
    platform::windows::{
        self as native, FileIdentity, OwnedHandle, PinnedFile, path, recycle, security,
    },
};
use anyhow::{Context, Result, bail, ensure};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
#[path = "store.rs"]
mod store;
// libtestの検証入口（bin/verification.rs）へ所有markerモデルを渡す。
// 以前は検証入口が同じstore.rsを`#[path]`で再ロードしており、二重コンパイル・テスト重複実行・dead code警告を生んでいた。
#[cfg(test)]
pub(crate) use store::verification_owned_markers;

const GATE: &str = ".legacy-file-discard-in-progress";
const REGISTRY: &str = ".registry-records-v1";
const RECYCLE: &str = ".recycle-records-v1";
const CLOSED: &str = ".closed-records-v1";
const SHARE_ALL: u32 = 7;
const INSPECT: u32 = 0x00020081;

struct Target {
    path: PathBuf,
    identity: FileIdentity,
    ownership: Ownership,
}
enum Ownership {
    Store(store::Location),
    Central { typed: bool, reserved: bool },
}

fn missing(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<std::io::Error>()
        .is_some_and(|e| matches!(e.raw_os_error(), Some(2 | 3)))
}
fn inspect(path: &Path) -> Result<Option<PinnedFile>> {
    match PinnedFile::open(path, 0x80, SHARE_ALL) {
        Ok(handle) => Ok(Some(handle)),
        Err(error) if missing(&error) => Ok(None),
        Err(error) => Err(error),
    }
}
fn registry_signal(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.starts_with("registry-") || name.starts_with(".registry-") || name == REGISTRY
}
fn same_identity(expected: &FileIdentity, actual: &FileIdentity) -> Result<()> {
    ensure!(
        expected.same_object(actual) && !actual.is_reparse() && actual.reparse_tag == 0,
        "Legacy candidate identity changed or is a link."
    );
    Ok(())
}
/// 旧ディレクトリ直下にregistry signalがあることを示すエラー。
/// 呼出し元が「所有不明として保持（retained）」と「処分の失敗（failed）」を型で区別するために使う。
#[derive(Debug)]
struct RegistrySignal;
impl std::fmt::Display for RegistrySignal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Registry signals protect this legacy directory.")
    }
}
impl std::error::Error for RegistrySignal {}

fn no_registry(path: &Path, expected: &FileIdentity) -> Result<()> {
    let handle = PinnedFile::open(path, INSPECT, SHARE_ALL)?;
    let actual = handle.identity()?;
    same_identity(expected, &actual)?;
    ensure!(
        actual.is_directory(),
        "Legacy candidate is no longer a directory."
    );
    if native::any_pinned_directory_name(handle.raw(), registry_signal)? {
        return Err(RegistrySignal.into());
    }
    handle.verify_named()?;
    Ok(())
}

/// 個別対象の失敗状態を決める。
/// Shell投入後は結果不明（ambiguous）。gate取得前（dry-runは常にこちら）の事前検査でregistry signalを
/// 検出した場合は、中央候補と同じく警告して保持（retained）する。
/// 先行対象の処理でgateを取得済みなら、gate保持で停止する従来の扱いを変えず失敗（failed）とし、
/// 不確実性gateが残ったままCLIが成功終了しないようにする。それ以外も失敗（failed）。
fn failure_status(started: bool, registry_signal: bool, gate_attempted: bool) -> &'static str {
    if started {
        "ambiguous"
    } else if registry_signal && !gate_attempted {
        "retained"
    } else {
        "failed"
    }
}
fn private_file(path: &Path, limit: usize) -> Result<serde_json::Value> {
    let fixed = security::open_lifecycle_metadata(path)?;
    let id = fixed.identity()?;
    ensure!(
        !id.is_directory() && !id.is_reparse() && id.links == 1,
        "Lifecycle marker must be a plain single-link file."
    );
    security::verify_private_member_security(fixed.raw(), false)?;
    native::reject_named_streams(path)?;
    let data = native::read_plain_file(path, limit, true)?;
    fixed.verify_named()?;
    fixed.require_unchanged()?;
    crate::json::parse_unique(&data)
}
fn typed_layout(metadata: &Path, root: &Path, kind: &str) -> Result<()> {
    let _parents = path::pin_directories(root)?;
    let directory = security::open_private_directory(root)?;
    let id = directory.identity()?;
    ensure!(
        id.is_directory() && !id.is_reparse() && id.links == 1,
        "Lifecycle root must be an ordinary directory."
    );
    directory.reject_case_sensitive()?;
    native::reject_named_streams(root)?;
    security::verify_private_security(directory.raw(), true, false)?;
    let metadata = PinnedFile::open(metadata, 0x80, 3)?;
    let marker = private_file(&root.join("layout.json"), 8192)?;
    let fields = marker
        .as_object()
        .context("Lifecycle marker must be an object.")?;
    let required = [
        "schema",
        "kind",
        "operationId",
        "directoryIdentity",
        "metadataRootIdentity",
        "machineName",
        "ownerSid",
        "nonce",
    ];
    ensure!(
        required.iter().all(|n| fields.contains_key(*n))
            && fields
                .keys()
                .all(|n| required.contains(&n.as_str()) || n == "publicationProtocol")
            && fields.values().all(|v| !v.is_null()),
        "Lifecycle marker has unknown, missing, or null fields."
    );
    let nonce = marker["nonce"].as_str().unwrap_or("");
    let parsed = uuid::Uuid::parse_str(nonce)?;
    ensure!(
        marker["schema"].as_u64() == Some(1)
            && marker["kind"].as_str() == Some(kind)
            && marker["operationId"] == ""
            && marker["directoryIdentity"].as_str()
                == Some(native::legacy_identity(directory.raw())?.as_str())
            && marker["metadataRootIdentity"].as_str()
                == Some(native::legacy_identity(metadata.raw())?.as_str())
            && marker["machineName"].as_str() == Some(native::machine_name()?.as_str())
            && marker["ownerSid"].as_str() == Some(security::current_user_sid()?.as_str())
            && if kind == RECYCLE {
                marker["publicationProtocol"].as_i64() == Some(1)
            } else {
                marker.get("publicationProtocol").is_none()
            }
            && nonce == parsed.simple().to_string(),
        "Recovery record layout marker does not match its private directory."
    );
    directory.verify_named()?;
    Ok(())
}

fn validate(config: &Config, target: &Target) -> Result<()> {
    match &target.ownership {
        Ownership::Store(location) => {
            store::validate(location, Some(&target.identity))?;
        }
        Ownership::Central { typed, reserved } => {
            let access = if target.identity.is_directory() {
                INSPECT
            } else {
                0x80
            };
            let handle = PinnedFile::open(&target.path, access, SHARE_ALL)?;
            let actual = handle.identity()?;
            same_identity(&target.identity, &actual)?;
            let entries = if actual.is_directory() {
                native::directory_names(handle.raw())?
            } else {
                Vec::new()
            };
            let registry = entries.iter().any(|n| registry_signal(n));
            if *typed {
                ensure!(
                    actual.is_directory() && !registry,
                    "Legacy typed file root ownership differs."
                );
                typed_layout(
                    Path::new(&config.data.backup_directory),
                    &target.path,
                    target
                        .path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .context("Invalid lifecycle name.")?,
                )?;
            } else if *reserved {
                let backup =
                    security::open_private_directory(Path::new(&config.data.backup_directory))?;
                security::verify_private_security(backup.raw(), true, false)?;
                ensure!(!registry, "Registry signals protect this legacy candidate.");
            } else {
                ensure!(
                    actual.is_directory()
                        && !registry
                        && entries.iter().any(|n| matches!(
                            n.as_str(),
                            "manifest.json" | "move-manifest.json" | "recycle-manifest.json"
                        )),
                    "Unknown or registry-bearing legacy operation was retained."
                );
            }
            handle.verify_named()?;
        }
    }
    Ok(())
}

fn verify_gate(path: &Path, raw: windows_sys::Win32::Foundation::HANDLE) -> Result<()> {
    let id = native::identity(raw)?;
    ensure!(
        !id.is_directory() && !id.is_reparse() && id.links == 1 && native::file_size(raw)? == 0,
        "Legacy discard gate is not an empty ordinary single-link file."
    );
    security::verify_private_security(raw, false, false)?;
    native::reject_named_streams(path)?;
    let current = PinnedFile::open(path, 0x80, SHARE_ALL)?;
    ensure!(
        id.same_object(&current.identity()?),
        "Legacy discard gate identity changed."
    );
    Ok(())
}
/// 開いたgate handleの実体を照合して削除し、handle解放後に名前の消失を確認する。
/// `handle`は`raw`の所有者で、削除設定の直後（名前確認の前）に必ず閉じる。
fn delete_gate_handle<H>(
    path: &Path,
    handle: H,
    raw: windows_sys::Win32::Foundation::HANDLE,
) -> Result<()> {
    verify_gate(path, raw)?;
    // POSIX削除を先に試し、外部の共有handleが残っていても名前をすぐ解放する（非対応FSだけ従来設定）。
    // 従来設定のままだと名前がdelete-pendingで残り、直後の名前確認がアクセス拒否になる。
    security::delete_permanent_fixed(raw, false, false)?;
    drop(handle);
    ensure!(
        inspect(path)?.is_none(),
        "Legacy discard gate still exists after deletion."
    );
    Ok(())
}
fn remove_gate(path: &Path) -> Result<()> {
    let fixed = security::open_lifecycle_delete(path)?;
    let raw = fixed.raw();
    delete_gate_handle(path, fixed, raw)
}

pub fn migrate(
    config: &Config,
    apply: bool,
    scan_central: bool,
    retry: bool,
    result: &mut MigrationResult,
) -> Result<()> {
    let metadata = path::absolute(Path::new(&config.data.backup_directory))?;
    let gate = metadata.join(GATE);
    let gate_check = (|| -> Result<()> {
        if inspect(&gate)?.is_some() {
            ensure!(
                retry,
                "Legacy file discard is uncertain. Inspect the original locations and Windows Recycle Bin, then explicitly acknowledge retry with migrate --apply --retry-legacy-discard. Registry processing remains available."
            );
            remove_gate(&gate)?;
        }
        Ok(())
    })();
    if let Err(error) = gate_check {
        result.complete = false;
        result
            .warnings
            .push(format!("Legacy file discard gate was retained: {error}"));
        return Ok(());
    }
    let mut targets = Vec::new();
    let mut names = HashSet::new();
    let mut unavailable = Vec::new();
    store::inspect(
        config,
        |location, identity| {
            if names.insert(location.root.to_string_lossy().to_uppercase()) {
                targets.push(Target {
                    path: location.root.clone(),
                    identity,
                    ownership: Ownership::Store(location),
                });
            }
        },
        |path, error| {
            unavailable.push(format!(
                "Legacy file store is unavailable; explicit migration can retry: {path}: {error}"
            ))
        },
    );
    if !unavailable.is_empty() {
        result.complete = false;
        result.warnings.extend(unavailable);
    }
    if scan_central {
        let discover = (|| -> Result<()> {
            let _parents = path::pin_directories(&metadata)?;
            let backup = PinnedFile::open(&metadata, INSPECT, 3)?;
            for name in native::directory_names(backup.raw())? {
                if matches!(name.as_str(), GATE | REGISTRY | "maintenance.lock") {
                    continue;
                }
                let typed = matches!(name.as_str(), RECYCLE | CLOSED);
                let reserved = name.starts_with(".legacy-file-migration-")
                    || name.starts_with(".prunlet-file-migration-");
                let operation =
                    uuid::Uuid::parse_str(&name).is_ok_and(|id| id.simple().to_string() == name);
                if !typed && !reserved && !operation {
                    continue;
                }
                let path = metadata.join(&name);
                let candidate = (|| -> Result<Target> {
                    let handle = inspect(&path)?.context("Legacy candidate disappeared.")?;
                    let target = Target {
                        path: path.clone(),
                        identity: handle.identity()?,
                        ownership: Ownership::Central { typed, reserved },
                    };
                    validate(config, &target)?;
                    Ok(target)
                })();
                match candidate {
                    Ok(target) => {
                        if names.insert(path.to_string_lossy().to_uppercase()) {
                            targets.push(target);
                        }
                    }
                    Err(e) => {
                        result.complete = false;
                        result.operations.push(MigrationOperation {
                            path: Some(path.display().to_string()),
                            status: "retained".into(),
                            error: Some(e.to_string()),
                            ..Default::default()
                        });
                    }
                }
            }
            Ok(())
        })();
        if let Err(error) = discover {
            result.complete = false;
            result.warnings.push(format!(
                "Legacy central file discovery is unavailable: {error}"
            ));
        }
    }
    let mut gate_lease: Option<OwnedHandle> = None;
    let mut gate_attempted = false;
    let mut uncertain = false;
    for target in targets {
        let mut item = MigrationOperation {
            path: Some(target.path.display().to_string()),
            status: "would_recycle".into(),
            ..Default::default()
        };
        let started = Arc::new(AtomicBool::new(false));
        // 投入前の事前検査でregistry signalを検出したか。gate取得前ならdry-runでもCLIを非0にしないため、
        // failedではなくretainedへ分類する（failure_status参照）。
        let mut signal_detected = false;
        let attempt = (|| -> Result<()> {
            let Some(original) = inspect(&target.path)? else {
                item.status = "already_absent".into();
                return Ok(());
            };
            validate(config, &target)?;
            if target.identity.is_directory() {
                no_registry(&target.path, &target.identity).inspect_err(|error| {
                    signal_detected = error.is::<RegistrySignal>();
                })?;
            }
            if !apply {
                return Ok(());
            }
            same_identity(&target.identity, &original.identity()?)?;
            let _parents = path::pin_directories(
                target
                    .path
                    .parent()
                    .context("Legacy candidate has no parent.")?,
            )?;
            if gate_lease.is_none() {
                gate_attempted = true;
                let lease = security::create_private_file(&gate)?;
                native::write_handle(lease.raw(), &[])?;
                verify_gate(&gate, lease.raw())?;
                gate_lease = Some(lease);
                #[cfg(test)]
                verification_checkpoint("gate.flushed", &target.path);
            }
            let started_callback = started.clone();
            let outcome = recycle::recycle(
                &target.path,
                true,
                |resolved| {
                    ensure!(
                        resolved
                            .to_string_lossy()
                            .eq_ignore_ascii_case(&target.path.to_string_lossy()),
                        "Shell resolved another legacy migration source."
                    );
                    validate(config, &target)?;
                    if target.identity.is_directory() {
                        no_registry(&target.path, &target.identity)?;
                    }
                    started_callback.store(true, Ordering::Release);
                    #[cfg(test)]
                    verification_checkpoint("shell.ready", &target.path);
                    Ok(())
                },
                |recycled| {
                    let access = if target.identity.is_directory() {
                        INSPECT
                    } else {
                        0x80
                    };
                    let fixed = PinnedFile::open(recycled, access, SHARE_ALL)?;
                    same_identity(&target.identity, &fixed.identity()?)?;
                    if target.identity.is_directory() {
                        ensure!(
                            !native::any_pinned_directory_name(fixed.raw(), registry_signal)?,
                            "Registry signals appeared in the recycled legacy directory."
                        );
                    }
                    fixed.verify_named()?;
                    Ok(())
                },
            )?;
            #[cfg(test)]
            verification_checkpoint("shell.returned", &target.path);
            match outcome {
                recycle::RecycleOutcome::Recycled => {}
                recycle::RecycleOutcome::PermanentAllowed(_) => bail!(
                    "Legacy file migration requires Windows Recycle Bin; permanent deletion is not permitted."
                ),
            }
            ensure!(
                inspect(&target.path)?.is_none(),
                "Legacy source remains after Shell recycle."
            );
            item.status = "recycled".into();
            Ok(())
        })();
        if let Err(error) = attempt {
            // 事前検査はこの対象のgate取得より前なので、ここでのgate_attemptedは先行対象で取得済みかを表す。
            // gate取得後の不確実性の扱い（下のgate_attempted分岐）は従来どおり。
            item.status = failure_status(
                started.load(Ordering::Acquire),
                signal_detected,
                gate_attempted,
            )
            .into();
            item.error = Some(error.to_string());
            result.complete = false;
            if gate_attempted {
                uncertain = true;
                result.warnings.push("Legacy file discard stopped with its uncertainty gate retained. Inspect the original location and Windows Recycle Bin before explicitly acknowledging retry.".into());
            }
        }
        result.operations.push(item);
        if uncertain {
            break;
        }
    }
    if !uncertain {
        if let Some(lease) = gate_lease.take() {
            let raw = lease.raw();
            if let Err(error) = delete_gate_handle(&gate, lease, raw) {
                result.complete = false;
                result.warnings.push(format!("Legacy discard succeeded but its uncertainty gate removal could not be confirmed: {error}"));
            }
        }
    }
    Ok(())
}

// 検証probeだけが設定する。製品runtimeに故障注入の入力・fallbackを追加しない。
#[cfg(test)]
type VerificationCheckpoint = Arc<dyn Fn(&str, &Path) + Send + Sync>;
#[cfg(test)]
static VERIFICATION_CHECKPOINT: std::sync::Mutex<Option<VerificationCheckpoint>> =
    std::sync::Mutex::new(None);
#[cfg(test)]
pub(crate) fn verification_set_checkpoint(callback: Option<VerificationCheckpoint>) {
    *VERIFICATION_CHECKPOINT
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = callback;
}
#[cfg(test)]
fn verification_checkpoint(phase: &str, target: &Path) {
    let callback = VERIFICATION_CHECKPOINT
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    if let Some(callback) = callback {
        callback(phase, target);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // テスト用の外部TEMP配下に一意の通常ディレクトリを作る。リポジトリ内には作らない。
    fn fixture_directory(label: &str) -> PathBuf {
        let parent = std::env::temp_dir();
        assert!(parent.is_absolute());
        assert!(
            !path::within(&parent, Path::new(env!("CARGO_MANIFEST_DIR"))),
            "Test TEMP must be outside repository."
        );
        let directory = parent.join(format!(
            "prunlet-migration-{label}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir(&directory).unwrap();
        directory
    }

    #[test]
    fn pre_dispatch_registry_signal_is_retained_not_failed() {
        let directory = fixture_directory("registry-signal");
        std::fs::create_dir(directory.join(".registry-records-v1")).unwrap();
        let identity = PinnedFile::open(&directory, 0x80, SHARE_ALL)
            .unwrap()
            .identity()
            .unwrap();
        let error = no_registry(&directory, &identity).unwrap_err();
        assert!(error.is::<RegistrySignal>());
        assert_eq!(
            failure_status(false, error.is::<RegistrySignal>(), false),
            "retained"
        );
        // 先行対象でgate取得済みなら、gate保持で停止する従来どおりfailedとする。
        assert_eq!(
            failure_status(false, error.is::<RegistrySignal>(), true),
            "failed"
        );
    }

    #[test]
    fn directory_without_registry_signal_passes_and_other_failures_stay_failed() {
        let directory = fixture_directory("no-signal");
        std::fs::create_dir(directory.join("ordinary-child")).unwrap();
        let identity = PinnedFile::open(&directory, 0x80, SHARE_ALL)
            .unwrap()
            .identity()
            .unwrap();
        no_registry(&directory, &identity).unwrap();
        assert_eq!(failure_status(false, false, false), "failed");
        assert_eq!(failure_status(false, false, true), "failed");
        // Shell投入後はregistry signalの有無に関わらず結果不明として扱う。
        assert_eq!(failure_status(true, false, true), "ambiguous");
        assert_eq!(failure_status(true, true, true), "ambiguous");
    }

    /// 外部の共有handleがgateを開いたままでも、POSIX削除で名前が即座に解放され、
    /// 直後の名前確認がdelete-pendingのアクセス拒否（Win32 5）にならないことを確かめる。
    #[test]
    fn gate_removal_releases_the_name_while_an_external_handle_remains_open() {
        let directory = fixture_directory("gate-external-handle");
        let gate = directory.join(GATE);
        let lease = security::create_private_file(&gate).unwrap();
        let raw = lease.raw();
        verify_gate(&gate, raw).unwrap();
        let external = PinnedFile::open(&gate, 0x80, SHARE_ALL).unwrap();
        delete_gate_handle(&gate, lease, raw).unwrap();
        assert!(inspect(&gate).unwrap().is_none());
        drop(external);
    }
}
