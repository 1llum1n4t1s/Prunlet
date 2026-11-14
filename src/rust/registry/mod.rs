//! Windowsレジストリの退避と復元。ファイル削除とは別namespaceのschema 5を保持する。
#[cfg(windows)]
mod migration;
pub mod model;
#[cfg(all(test, windows))]
type VerificationCheckpoint = std::sync::Arc<dyn Fn(&str, &str, &str) + Send + Sync>;
#[cfg(all(test, windows))]
static VERIFICATION_CHECKPOINT: std::sync::Mutex<Option<VerificationCheckpoint>> =
    std::sync::Mutex::new(None);
#[cfg(all(test, windows))]
pub(crate) fn verification_set_checkpoint(hook: Option<VerificationCheckpoint>) {
    *VERIFICATION_CHECKPOINT
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = hook;
}
#[cfg(all(test, windows))]
fn verification_has_checkpoint() -> bool {
    VERIFICATION_CHECKPOINT
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .is_some()
}
#[cfg(all(test, windows))]
fn verification_checkpoint(event: &str, phase: &str, id: &str) {
    let callback = VERIFICATION_CHECKPOINT
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    if let Some(callback) = callback {
        callback(event, phase, id);
    }
}
#[cfg(all(test, windows))]
pub(crate) fn verification_native_contract(
    case: &str,
    fixture_root: &str,
) -> anyhow::Result<serde_json::Value> {
    native::verification_native_contract(case, fixture_root)
}
#[cfg(all(test, windows))]
pub(crate) fn verification_snapshot_publication(
    config: &crate::config::Config,
) -> anyhow::Result<serde_json::Value> {
    storage::verification_snapshot_publication(config)
}
#[cfg(windows)]
pub mod native;
#[cfg(windows)]
pub mod session;
#[cfg(windows)]
mod storage;
#[cfg(windows)]
mod terminal;
use crate::{config::Config, service::Progress};
use anyhow::Result;
#[cfg(windows)]
use anyhow::{Context, ensure};
use serde_json::Value;
#[cfg(windows)]
use serde_json::json;

pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    #[cfg(not(windows))]
    {
        let _ = (config, command, args, progress);
        anyhow::bail!(
            "Registry deletion, recovery, maintenance and native sessions are supported only on Windows; existing recovery data was not changed."
        );
    }
    #[cfg(windows)]
    {
        if command == "registry-session" || command.starts_with("registry-session-") {
            return session::execute(config, command, args, progress);
        }
        if config.data.registry_scope == "nativeWindows"
            && matches!(
                command,
                "registry-delete" | "registry-restore" | "registry-reconcile"
            )
        {
            return session::route(config, command, args, progress);
        }
        execute_local(config, command, args, progress, None)
    }
}

#[cfg(windows)]
pub fn execute_local(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
    scope: Option<model::Scope>,
) -> Result<Value> {
    native::with_request_context(move || execute_local_core(config, command, args, progress, scope))
}
#[cfg(windows)]
fn execute_local_core(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
    scope: Option<model::Scope>,
) -> Result<Value> {
    config.data.validate_fields()?;
    if let Some(scope) = &scope {
        scope.validate()?;
    }
    ensure!(
        !matches!(
            command,
            "registry-delete" | "registry-restore" | "registry-reconcile"
        ) || config.data.registry_scope != "nativeWindows"
            || scope.is_some(),
        "Native registry execution requires a verified session context."
    );
    let apply = boolean(args, "apply", false)?;
    let dry = boolean(args, "dryRun", false)?;
    if command == "registry-delete" {
        let _ = parse_target(args)?;
        let _ = boolean(args, "recursive", false)?;
    }
    let mode = args
        .get("accessMode")
        .and_then(Value::as_str)
        .unwrap_or("normal");
    ensure!(
        matches!(mode, "normal" | "backupRestore"),
        "Registry accessMode must be normal or backupRestore."
    );
    if command == "migrate" {
        return migration::execute(config, args, progress);
    }
    let create = match command {
        "registry-delete" => !dry,
        "registry-restore" | "registry-reconcile" => true,
        "purge" | "maintain" => apply,
        _ => false,
    };
    let _coord = if create {
        crate::files::coordination::acquire(config, None, progress.as_ref())?
    } else {
        crate::files::coordination::acquire_readonly(config, progress.as_ref())?
    };
    let mut store = storage::Store::open(
        config,
        matches!(command, "registry-restore" | "registry-reconcile")
            || (command == "purge" && apply),
    )?;
    match command {
        "registry-delete" => {
            store.require_ready()?;
            delete(&store, args, dry, scope)
        }
        "registry-restore" => {
            let id = string(args, "operationId")?;
            migration::ensure_available(&store, id)?;
            restore(&store, id, mode, scope)
        }
        "registry-reconcile" => {
            let id = string(args, "operationId")?;
            migration::ensure_available(&store, id)?;
            if !storage::exists(&store.root.join(id).join(storage::MANIFEST))? {
                // manifest公開前に止まった記録は未commitが確定している。対象pathはmanifestに無いため返さない。
                store.unpublished(id)?;
                return Ok(
                    json!({"operationId":id,"dryRun":true,"items":[{"kind":null,"path":null,"status":"not_committed","error":null,"backupPath":null,"sha256":null,"size":null}],"warnings":[]}),
                );
            }
            let record = store.record(id)?;
            ensure!(
                record.manifest.scope == scope,
                "Registry recovery scope differs from execution scope."
            );
            let target = model::Target::new(
                &record.manifest.path,
                &record.manifest.view,
                record.manifest.value_name.clone(),
                "normal",
            )?;
            let mut i = item(&target);
            // 正式receiptが無い記録は未commit確定であり、結果不明（ambiguous）とは区別して返す。
            i["status"] = json!(if record.not_committed() {
                "not_committed"
            } else if record.ambiguous() {
                "ambiguous"
            } else if record.has("restore", "complete") {
                "restored"
            } else if record.has("purge", "complete") {
                "purged"
            } else {
                "deleted"
            });
            Ok(json!({"operationId":id,"dryRun":true,"items":[i],"warnings":[]}))
        }
        "operations" => {
            store.require_ready()?;
            let mut out = vec![];
            for id in store.ids()? {
                if let Some(summary) = terminal::summary(&store, &id)? {
                    out.push(summary);
                    continue;
                }
                if !storage::exists(&store.root.join(&id).join(storage::MANIFEST))? {
                    // manifest公開前の残骸も一覧全体を失敗させず、未commitとして示す。
                    store.unpublished(&id)?;
                    out.push(json!({"operationId":id,"lifecycleState":"not_committed","originalSchema":5,"terminalReason":null}));
                    continue;
                }
                let record = store.record(&id)?;
                let state = if record.not_committed() {
                    "not_committed"
                } else if record.ambiguous() {
                    "ambiguous"
                } else {
                    "active"
                };
                out.push(json!({"operationId":id,"lifecycleState":state,"originalSchema":5,"terminalReason":null}));
            }
            Ok(json!({"operations":out}))
        }
        "purge" => {
            let id = string(args, "operationId")?;
            if apply {
                migration::ensure_available(&store, id)?;
            }
            purge(&store, id, apply)
        }
        "maintain" => {
            store.require_ready()?;
            maintain(&store, apply, 0, boolean(args, "auditRecords", false)?)
        }
        _ => anyhow::bail!("Unknown registry command: {command}"),
    }
}
#[cfg(windows)]
fn string<'a>(args: &'a Value, name: &str) -> Result<&'a str> {
    args.get(name)
        .and_then(Value::as_str)
        .with_context(|| format!("Missing {name}"))
}
#[cfg(windows)]
fn boolean(args: &Value, name: &str, default: bool) -> Result<bool> {
    match args.get(name) {
        None => Ok(default),
        Some(Value::Bool(value)) => Ok(*value),
        _ => anyhow::bail!("{name} must be a boolean."),
    }
}
#[cfg(windows)]
fn parse_target(args: &Value) -> Result<model::Target> {
    model::Target::new(
        string(args, "path")?,
        string(args, "view")?,
        match args.get("valueName") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s.clone()),
            _ => anyhow::bail!("valueName must be a string or null."),
        },
        match args.get("accessMode") {
            None => "normal",
            Some(Value::String(s)) => s,
            _ => anyhow::bail!("accessMode must be a string."),
        },
    )
}
#[cfg(windows)]
fn item(target: &model::Target) -> Value {
    json!({"kind":target.kind(),"path":target.path,"status":"","error":null,"backupPath":null,"sha256":null,"size":null})
}
#[cfg(windows)]
fn delete(
    store: &storage::Store,
    args: &Value,
    dry: bool,
    scope: Option<model::Scope>,
) -> Result<Value> {
    use model::*;
    let target = parse_target(args)?;
    let mut result = json!({"operationId":null,"dryRun":dry,"items":[item(&target)],"warnings":[]});
    let mut committed = false;
    let mut privileges = None;
    let operation = (|| -> Result<()> {
        privileges = Some(native::Privileges::new(
            false,
            target.access_mode == "backupRestore",
            target.value_name.is_none(),
        )?);
        let mut tx = native::Transaction::new()?;
        let mut snapshot = match native::delete_snapshot(
            &mut tx,
            &target,
            boolean(args, "recursive", false)?,
            dry,
        ) {
            Ok(s) => s,
            Err(e) if native::target_missing(&e) => {
                result["items"][0]["status"] = json!("already_absent");
                result["items"][0]["size"] = json!(0);
                return Ok(());
            }
            Err(e) => return Err(e),
        };
        snapshot.scope = scope;
        let bytes = storage::serialize(&snapshot)?;
        ensure!(
            bytes.len() <= MAX_BYTES,
            "Serialized registry snapshot exceeds maximum size."
        );
        result["items"][0]["path"] = json!(snapshot.path);
        result["items"][0]["size"] = json!(bytes.len());
        result["items"][0]["status"] = json!("would_delete");
        if tx.has_alias() {
            warning(
                &mut result,
                "The verified current-user Classes alias uses a transaction guard with the same REG_LINK bytes; committing may change its last-write timestamp. Dry-run does not stage this write.",
            );
        }
        if target.access_mode == "backupRestore" {
            warning(
                &mut result,
                "Explicit backupRestore access temporarily enables isolated caller backup/restore privileges and bypasses ordinary ACL checks. Restoration requires its own explicit access-mode choice.",
            );
        }
        if target.value_name.is_none() {
            warning(
                &mut result,
                "Registry class, raw values and complete owner/group/DACL/SACL are preserved. Last-write timestamps are recorded but not restored; restored keys are nonvolatile.",
            );
        }
        // dry-runもschema shape/securityを同じ検証経路へ通す。
        let id = args
            .get("operationId")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| uuid::Uuid::new_v4().simple().to_string());
        operation_id(&id)?;
        let manifest = Manifest {
            scope: snapshot.scope.clone(),
            schema: 5,
            operation_id: id.clone(),
            created_utc: storage::now(),
            metadata_root: store.config.data.backup_directory.clone(),
            owner_sid: store.state.owner_sid.clone(),
            path: snapshot.path.clone(),
            view: snapshot.view.clone(),
            value_name: snapshot.value_name.clone(),
            kind: target.kind().into(),
            size: bytes.len() as u64,
            sha256: hash(&bytes),
        };
        manifest.validate(
            &id,
            &store.config.data.backup_directory,
            &store.state.owner_sid,
        )?;
        snapshot.validate(&manifest)?;
        if dry {
            return Ok(());
        }
        let maintenance = maintain(store, true, bytes.len() as u64, false)?;
        let incoming = bytes.len() as u64;
        let budget = store.config.data.max_recovery_bytes.max(incoming);
        ensure!(
            maintenance["capacityKnown"] == true
                && maintenance["budgetSatisfied"] == true
                && maintenance["retainedBytesAfter"]
                    .as_u64()
                    .context("Invalid capacity assessment")?
                    <= budget - incoming,
            "Recovery capacity could not be safely reserved; registry target was retained. {}",
            maintenance["warnings"]
        );
        for entry in maintenance["warnings"].as_array().into_iter().flatten() {
            result["warnings"]
                .as_array_mut()
                .unwrap()
                .push(entry.clone());
        }
        if incoming > store.config.data.max_recovery_bytes {
            warning(
                &mut result,
                "This single registry snapshot exceeds the configured budget; the exception applies only to this operation.",
            );
        }
        let _parent = store.create_record(&id)?;
        result["operationId"] = json!(id);
        let payload = store.publish_bytes(&id, storage::SNAPSHOT, &bytes)?;
        let mut manifest = manifest;
        manifest.size = payload.bytes.len() as u64;
        manifest.sha256 = hash(&payload.bytes);
        let persisted: Snapshot = payload.decode()?;
        persisted.validate(&manifest)?;
        ensure!(
            payload.bytes == bytes && manifest.size == incoming,
            "Published registry snapshot differs from reserved snapshot."
        );
        result["items"][0]["backupPath"] = json!(store.root.join(&id).join(storage::SNAPSHOT));
        result["items"][0]["sha256"] = json!(manifest.sha256);
        let saved = store.publish(&id, storage::MANIFEST, &manifest)?;
        let persisted_manifest: Manifest = saved.decode()?;
        persisted_manifest.validate(
            &id,
            &store.config.data.backup_directory,
            &store.state.owner_sid,
        )?;
        persisted.validate(&persisted_manifest)?;
        let manifest_hash = hash(&saved.bytes);
        let receipt = |phase: &str| Receipt {
            schema: 5,
            operation_id: id.clone(),
            manifest_sha256: manifest_hash.clone(),
            action: "delete".into(),
            phase: phase.into(),
            created_utc: storage::now(),
        };
        let saved_intent = store.publish(
            &id,
            &storage::receipt_name("delete", "intent"),
            &receipt("intent"),
        )?;
        let persisted_intent: Receipt = saved_intent.decode()?;
        ensure!(
            persisted_intent.schema == 5
                && persisted_intent.operation_id == id
                && persisted_intent.manifest_sha256 == manifest_hash
                && persisted_intent.action == "delete"
                && persisted_intent.phase == "intent",
            "Published registry deletion intent binding differs."
        );
        payload.verify_current()?;
        saved.verify_current()?;
        saved_intent.verify_current()?;
        // 公開後に残った所有予約が検証できない場合は、commit前に止める（commit後に記録を読めなくなるため）。
        store.verify_reservations(&id)?;
        tx.commit()?;
        committed = true;
        let saved_complete = store.publish(
            &id,
            &storage::receipt_name("delete", "complete"),
            &receipt("complete"),
        )?;
        result["items"][0]["status"] = json!("deleted");
        drop((payload, saved, saved_intent, saved_complete));
        Ok(())
    })();
    for note in store.take_notes() {
        warning(&mut result, &note);
    }
    if let Err(e) = operation {
        result["items"][0]["status"] = json!("failed");
        result["items"][0]["error"] = json!(e.to_string());
        // プロセス内のフラグだけで案内すると、正式receiptの公開後（rename後）に失敗した場合などに
        // 保存された記録の状態と食い違う。保存済みの記録を読み直して案内を決める。
        // Transactionはcommitされずにdropでrollbackされた場合、対象は残っている。
        if let Some(id) = result["operationId"].as_str().map(str::to_string) {
            let message = delete_failure_warning(store, &id, committed);
            warning(&mut result, &message);
        }
    }
    if let Some(mut privileges) = privileges {
        if let Err(e) = privileges.finish() {
            let id = result["operationId"]
                .as_str()
                .unwrap_or("unknown")
                .to_string();
            privilege_failure(&mut result, &e, committed, "deletion", &id);
        }
    }
    Ok(result)
}
#[cfg(windows)]
fn restore(
    store: &storage::Store,
    id: &str,
    mode: &str,
    scope: Option<model::Scope>,
) -> Result<Value> {
    let mut record = store.record(id)?;
    let target = model::Target::new(
        &record.manifest.path,
        &record.manifest.view,
        record.manifest.value_name.clone(),
        mode,
    )?;
    let mut i = item(&target);
    i["backupPath"] = json!(record.directory.join(storage::SNAPSHOT));
    i["size"] = json!(record.manifest.size);
    i["sha256"] = json!(record.manifest.sha256);
    let mut result = json!({"operationId":id,"items":[i],"warnings":[]});
    let mut committed = false;
    let mut privileges = None;
    let operation = (|| -> Result<()> {
        ensure!(
            record.manifest.scope == scope,
            "Registry recovery scope differs from execution scope."
        );
        // 未commit確定の記録は対象を削除していない。privilege・transactionへ進む前に拒否し、
        // 外部で消えたキーを古いsnapshotから再作成しない。
        ensure!(
            !record.not_committed(),
            "Registry deletion was not committed; the target was not deleted by this operation and restoration is refused."
        );
        ensure!(
            !record.ambiguous(),
            "Registry commit outcome is ambiguous; snapshot retained and restoration refused."
        );
        ensure!(
            !record.has("purge", "intent"),
            "Registry snapshot is scheduled for purge."
        );
        if record.has("restore", "complete") {
            result["items"][0]["status"] = json!("already_restored");
            consume_restored(&mut record, &mut result);
            return Ok(());
        }
        let snapshot = record
            .snapshot
            .as_ref()
            .context("Registry snapshot is absent")?;
        privileges = Some(native::Privileges::new(
            target.value_name.is_none(),
            mode == "backupRestore",
            target.value_name.is_none(),
        )?);
        let mut tx = native::Transaction::new()?;
        native::restore(&mut tx, &target, snapshot)?;
        if mode == "backupRestore" {
            warning(
                &mut result,
                "Explicit backupRestore restoration temporarily enables the isolated caller's backup/restore privileges and bypasses ordinary ACL checks; existing destinations remain refused.",
            );
        }
        if tx.has_alias() {
            warning(
                &mut result,
                "The verified current-user Classes alias requires SetValue access. Restoration stages the same REG_LINK bytes in its transaction; committing may change the alias key's last-write timestamp.",
            );
        }
        record.receipt(store, "restore", "intent")?;
        record.verify_current()?;
        // 公開後に残った所有予約が検証できない場合は、commit前に止める（commit後に記録を読めなくなるため）。
        store.verify_reservations(id)?;
        tx.commit()?;
        committed = true;
        record.receipt(store, "restore", "complete")?;
        result["items"][0]["status"] = json!("restored");
        // commitとcomplete receiptの公開後なので、snapshot消費の失敗で結果をfailedへ戻さない。
        consume_restored(&mut record, &mut result);
        if target.value_name.is_none() {
            warning(
                &mut result,
                "Registry timestamps and volatile attributes are not restored; class, raw values and complete security were verified before commit.",
            );
        }
        Ok(())
    })();
    if let Err(e) = operation {
        result["items"][0]["status"] = json!(if e
            .to_string()
            .contains("already exists; nothing was overwritten")
        {
            "conflict"
        } else {
            "failed"
        });
        result["items"][0]["error"] = json!(e.to_string());
        // deleteと同じく、保存済みの記録を読み直して案内を決める。
        // 失敗前から復元intentがあった記録も、読み直しで同じ分類になる。
        if let Some(message) = restore_failure_warning(store, id, committed) {
            warning(&mut result, &message);
        }
    }
    for note in store.take_notes() {
        warning(&mut result, &note);
    }
    if let Some(mut privileges) = privileges {
        if let Err(e) = privileges.finish() {
            privilege_failure(&mut result, &e, committed, "restoration", id);
        }
    }
    drop(record);
    if let Err(e) = terminal::capture(store, id) {
        warning(
            &mut result,
            &format!("Registry terminal metadata retained: {e}"),
        );
    }
    Ok(result)
}
// 復元complete receiptの公開後に行うsnapshot消費。復元はcommit済みでcomplete receiptもあるため、
// 消費に失敗しても状態はrestored/already_restoredのまま、未消費をwarningで返す。
// 残ったsnapshotは後続のscan(apply)（restore complete+payloadの消費）が回収する。
#[cfg(windows)]
fn consume_restored(record: &mut storage::Record, result: &mut Value) {
    if let Err(e) = record.consume() {
        warning(
            result,
            &format!(
                "Registry restoration is complete, but snapshot consumption did not finish; maintain --apply reclaims it. Do not repeat restoration: {e}"
            ),
        );
    }
}
// 結果を推測できないときの案内。記録は削除も変更もせず保全する。
#[cfg(windows)]
fn unclassified_warning(id: &str, error: &anyhow::Error) -> String {
    format!(
        "Registry operation {id} could not be re-read to classify the failure ({error}); the outcome is not inferred and the recovery data is retained."
    )
}
// deleteが失敗した後の案内を、保存済みの記録を読み直して決める（読取りだけで、記録は変更しない）。
// - 正式manifestが無い: 未commit確定。空の記録だけpurgeで整理でき、所有予約を持つ記録はpurgeが保全する。
// - 正式receiptが無い: 未commit確定（正式intentの公開前に失敗）。
// - complete receiptまで公開済み: 失敗は公開後の検証（rename後）で起きており、削除は完了している。
// - 正式intentのみ: commitの成否を推測しない。snapshotとintentを保全し、purge・restoreは拒否される。
// 正式intentのrename後に失敗した場合もここへ来るため、プロセス内のcommit済みフラグだけでは判定できない。
#[cfg(windows)]
fn delete_failure_warning(store: &storage::Store, id: &str, committed: bool) -> String {
    match storage::exists(&store.root.join(id).join(storage::MANIFEST)) {
        Ok(true) => match store.record(id) {
            Ok(record) if record.has("delete", "complete") => format!(
                "Registry deletion committed and its completion receipt is published; the failure came after publication. Snapshot retained; restoration is available for {id}."
            ),
            Ok(record) if record.not_committed() => format!(
                "Registry deletion was not committed before its intent was published; the registry target was retained. Recovery data {id} is counted toward capacity and purge --apply removes it unless an unverifiable receipt reservation remains."
            ),
            Ok(_) if committed => "Registry deletion committed but completion is unconfirmed. Snapshot retained; automatic purge and restoration are refused.".into(),
            Ok(_) => "Registry commit was not confirmed. Snapshot and intent are retained without inferring the outcome; automatic purge and restoration are refused.".into(),
            Err(e) => unclassified_warning(id, &e),
        },
        Ok(false) => match store.unpublished(id) {
            Ok(residue) if residue.empty => format!(
                "Registry deletion was not committed before its manifest was published; the registry target was retained. The empty recovery record {id} can be removed with purge --apply."
            ),
            Ok(_) => format!(
                "Registry deletion was not committed before its manifest was published; the registry target was retained. Recovery data {id} is counted toward capacity and retained because its reservation residue cannot be verified; purge --apply reports it retained."
            ),
            Err(e) => unclassified_warning(id, &e),
        },
        Err(e) => unclassified_warning(id, &e),
    }
}
// restoreが失敗した後の案内。deleteと同じく保存済みの記録から決める。
// 復元intentが無ければNone（拒否・競合など、記録へ影響しない失敗）。
#[cfg(windows)]
fn restore_failure_warning(store: &storage::Store, id: &str, committed: bool) -> Option<String> {
    match store.record(id) {
        // スコープ不一致などで拒否された、すでに復元済みの記録には、この失敗の警告を付けない。
        Ok(record) if committed && record.has("restore", "complete") => Some(format!(
            "Registry restoration is complete (its completion receipt is published); the failure came afterwards. Do not repeat restoration; maintain --apply reclaims the snapshot of {id}."
        )),
        Ok(record) if record.has("restore", "intent") && !record.has("restore", "complete") => Some(
            if committed {
                "Registry restoration committed but completion is unconfirmed. Snapshot retained; repeat restoration and automatic purge are refused."
            } else {
                "Registry restoration intent has no confirmed completion; the snapshot was retained and repeat restoration is refused."
            }
            .into(),
        ),
        Ok(_) => None,
        Err(e) => Some(unclassified_warning(id, &e)),
    }
}
#[cfg(windows)]
pub(super) fn purge(store: &storage::Store, id: &str, apply: bool) -> Result<Value> {
    // 下のパス存在確認より前にIDの形を検証し、走査形の入力でfilesystemへ触れない。
    model::operation_id(id)?;
    if !storage::exists(&store.root.join(id).join(storage::MANIFEST))? {
        return purge_unpublished(store, id, apply);
    }
    let mut record = store.record(id)?;
    let target = model::Target::new(
        &record.manifest.path,
        &record.manifest.view,
        record.manifest.value_name.clone(),
        "normal",
    )?;
    let mut i = item(&target);
    i["backupPath"] = json!(record.directory.join(storage::SNAPSHOT));
    i["size"] = json!(record.manifest.size);
    i["sha256"] = json!(record.manifest.sha256);
    let mut result =
        json!({"operationId":id,"dryRun":!apply,"purgedBytes":0,"items":[i],"warnings":[]});
    if record.not_committed() {
        return Ok(purge_uncommitted(store, record, result, apply));
    }
    let operation = (|| -> Result<()> {
        ensure!(
            !record.ambiguous(),
            "Registry commit outcome is ambiguous; purge refused and snapshot retained."
        );
        if record.payload.is_none() {
            if apply && record.has("purge", "intent") && !record.has("purge", "complete") {
                record.receipt(store, "purge", "complete")?;
            }
            result["items"][0]["status"] = json!(if record.has("restore", "complete") {
                "already_restored"
            } else {
                "already_purged"
            });
            return Ok(());
        }
        result["items"][0]["status"] = json!("would_purge");
        if !apply {
            return Ok(());
        }
        let restored = record.has("restore", "complete");
        if !restored && !record.has("purge", "intent") {
            record.receipt(store, "purge", "intent")?;
        }
        record.consume()?;
        result["purgedBytes"] = json!(record.manifest.size);
        if !restored && !record.has("purge", "complete") {
            record.receipt(store, "purge", "complete")?;
        }
        result["items"][0]["status"] = json!("purged");
        Ok(())
    })();
    if let Err(e) = operation {
        result["items"][0]["status"] = json!("failed");
        result["items"][0]["error"] = json!(e.to_string());
        warning(
            &mut result,
            &format!("Registry snapshot retained where possible: {e}"),
        );
    }
    drop(record);
    if apply {
        if let Err(e) = terminal::capture(store, id) {
            warning(
                &mut result,
                &format!("Registry terminal metadata retained: {e}"),
            );
        }
    }
    Ok(result)
}
// 未commit確定（正式receiptなし）の記録のpurge。registryは変更されていないため、purge receiptや
// terminalは作らず（record_atの不変条件を変えない）、既存の固定handle経路で記録そのものを整理する。
// snapshotはRecord::consume（identity・size・hash照合）、残るmanifest・lock・ディレクトリは
// Store::discard_uncommittedで消す。receiptの公開予約・pendingが残る場合はmetadataを保全する。
#[cfg(windows)]
fn purge_uncommitted(
    store: &storage::Store,
    mut record: storage::Record,
    mut result: Value,
    apply: bool,
) -> Value {
    let has_payload = record.payload.is_some();
    result["items"][0]["status"] = json!(if has_payload {
        "would_purge"
    } else {
        "already_purged"
    });
    if !apply {
        return result;
    }
    if has_payload {
        if let Err(e) = record.consume() {
            result["items"][0]["status"] = json!("failed");
            result["items"][0]["error"] = json!(e.to_string());
            warning(
                &mut result,
                &format!("Uncommitted registry snapshot retained where possible: {e}"),
            );
            return result;
        }
        result["purgedBytes"] = json!(record.manifest.size);
        result["items"][0]["status"] = json!("purged");
    }
    match store.discard_uncommitted(record) {
        Ok(true) => {}
        Ok(false) => warning(
            &mut result,
            "Uncommitted registry operation metadata was retained because an unpublished receipt reservation remains.",
        ),
        Err(e) => warning(
            &mut result,
            &format!("Uncommitted registry operation metadata retained: {e}"),
        ),
    }
    result
}
// 正式manifestの公開前に止まった記録（未commit確定）のpurge。
// operation.lockだけの記録は整理し、所有予約・snapshotを持つ記録は本文を検証できないため保全する。
#[cfg(windows)]
fn purge_unpublished(store: &storage::Store, id: &str, apply: bool) -> Result<Value> {
    let residue = store.unpublished(id)?;
    let mut result = json!({"operationId":id,"dryRun":!apply,"purgedBytes":0,"items":[{"kind":null,"path":null,"status":"","error":null,"backupPath":null,"sha256":null,"size":residue.bytes}],"warnings":[]});
    if !residue.empty {
        result["items"][0]["status"] = json!("retained");
        warning(
            &mut result,
            "Registry operation has no published manifest; its unverifiable reservation residue is counted toward capacity and retained.",
        );
        return Ok(result);
    }
    result["items"][0]["status"] = json!(if apply { "purged" } else { "would_purge" });
    if apply && let Err(e) = store.discard_empty_record(id) {
        result["items"][0]["status"] = json!("failed");
        result["items"][0]["error"] = json!(e.to_string());
    }
    Ok(result)
}
// scanの名前確認。単体テストでは、指定した名前だけ確認を失敗させて、1件の失敗がmaintain全体へ
// 波及しないこと（per-member隔離）を決定的に確かめる。実処理はstorage::existsと同じ。
#[cfg(all(test, windows))]
thread_local! {
    static SCAN_EXISTS_FAULT: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}
#[cfg(windows)]
fn scan_member_exists(store: &storage::Store, name: &str) -> Result<bool> {
    #[cfg(test)]
    if SCAN_EXISTS_FAULT.with(|fault| fault.borrow().as_deref() == Some(name)) {
        anyhow::bail!("Access is denied. (os error 5)");
    }
    storage::exists(&store.root.join(name))
}
#[cfg(windows)]
fn scan(
    store: &storage::Store,
    apply: bool,
    warnings: &mut Vec<String>,
) -> Result<(
    u64,
    bool,
    Vec<(String, chrono::DateTime<chrono::FixedOffset>)>,
)> {
    let mut bytes = 0u64;
    let mut known = true;
    let mut candidates = vec![];
    for name in crate::platform::windows::directory_names(store.registry.raw())? {
        // 1件の名前確認の失敗でmaintain全体を止めない。
        // 他の記録の期限整理は続け、この項目は容量を確定できないものとして警告する（保護は弱めない）。
        match scan_member_exists(store, &name) {
            Ok(true) => {}
            Ok(false) => continue,
            Err(e) => {
                known = false;
                warnings.push(format!(
                    "Registry storage member {name} could not be checked and was retained: {e}"
                ));
                continue;
            }
        }
        if matches!(name.as_str(), "layout.json" | "storage-migration-v1.json") {
            continue;
        }
        if model::operation_id(&name).is_ok() {
            let inspected = (|| -> Result<()> {
                if terminal::summary(store, &name)?.is_some() {
                    return Ok(());
                }
                if apply {
                    let _ = store.cleanup_publications(&name)?;
                }
                // apply時の整理は、共通ロックを排他取得した経路（registry-delete・purge/maintain --apply）
                // だけが到達する。その間に公開途中のdelete()は無く、未commitの記録は残骸と確定できる。
                // apply=falseでは何も削除しない。
                if !storage::exists(&store.root.join(&name).join(storage::MANIFEST))? {
                    // manifest公開前の未commit記録。所有予約に結び付く範囲で容量を数え、本文は保全する。
                    let residue = store.unpublished(&name)?;
                    if residue.empty {
                        if apply {
                            store.discard_empty_record(&name)?;
                        }
                    } else {
                        bytes = bytes
                            .checked_add(residue.bytes)
                            .context("Recovery capacity overflow")?;
                    }
                    return Ok(());
                }
                let mut record = store.record(&name)?;
                if apply && record.has("restore", "complete") && record.payload.is_some() {
                    record.consume()?;
                }
                // purge中にsnapshot消費後のcomplete公開が失敗すると、purge intentありpayloadなしcompleteなしの
                // 記録が残る。restoreのcompleteと同様にscanで回収する。applyは共通ロックの排他下であり、
                // record_atの不変条件によりpayload不在はpurge intentで説明済み（不変条件を変えない）。
                if apply
                    && record.payload.is_none()
                    && record.has("purge", "intent")
                    && !record.has("purge", "complete")
                {
                    record.receipt(store, "purge", "complete")?;
                }
                if record.payload.is_some() {
                    bytes = bytes
                        .checked_add(record.manifest.size)
                        .context("Recovery capacity overflow")?;
                }
                if record.ambiguous() {
                    known = false;
                    warnings.push(format!(
                        "Registry operation {name} has an ambiguous outcome and was retained."
                    ));
                } else if record.payload.is_some() {
                    // 未commit確定の記録も既知容量として数え、保持期限・予算による既存の整理対象にする。
                    candidates.push((name.clone(), record.manifest.created_utc));
                } else if apply && record.not_committed() {
                    // snapshot消費後に中断した未commit記録の残りmetadataを整理する。
                    // receiptの公開予約が残る場合は保全し、容量0として扱う。
                    let _ = store.discard_uncommitted(record)?;
                    return Ok(());
                }
                drop(record);
                if apply {
                    terminal::capture(store, &name)?;
                }
                Ok(())
            })();
            if let Err(e) = inspected {
                known = false;
                warnings.push(format!(
                    "Registry operation {name} cannot be safely inspected: {e}"
                ));
            }
            continue;
        }
        match terminal::inspect_member(store, &name, apply) {
            Ok(true) => {}
            Ok(false) => {
                known = false;
                warnings.push(format!(
                    "Unknown registry storage member was retained: {name}"
                ));
            }
            Err(e) => {
                known = false;
                warnings.push(format!("Registry storage control {name} was retained: {e}"));
            }
        }
    }
    Ok((bytes, known, candidates))
}
#[cfg(windows)]
fn maintain(store: &storage::Store, apply: bool, incoming: u64, audit: bool) -> Result<Value> {
    let mut warnings = vec![];
    let (before, mut known, mut candidates) = scan(store, apply, &mut warnings)?;
    let mut after = before;
    let mut purged = 0;
    let mut planned = 0;
    let mut operations = vec![];
    let budget = store
        .config
        .data
        .max_recovery_bytes
        .saturating_sub(incoming);
    let now = storage::now();
    let expiry = now - chrono::Duration::days(store.config.data.retention_days as i64);
    candidates.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));
    for (id, created) in candidates {
        if created > now {
            warnings.push(format!(
                "Registry operation {id} has a future timestamp and was retained."
            ));
            continue;
        }
        if created > expiry && after <= budget {
            continue;
        }
        match purge(store, &id, apply) {
            Ok(result) => {
                let bytes = if apply {
                    result["purgedBytes"].as_u64().unwrap_or(0)
                } else {
                    result["items"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|i| i["status"] == "would_purge")
                        .filter_map(|i| i["size"].as_u64())
                        .sum()
                };
                after = after.saturating_sub(bytes);
                if apply {
                    purged += bytes
                } else {
                    planned += bytes
                }
                for w in result["warnings"].as_array().into_iter().flatten() {
                    if let Some(w) = w.as_str() {
                        warnings.push(w.into());
                    }
                }
                operations.push(result);
            }
            Err(e) => warnings.push(format!("Registry operation {id} was retained: {e}")),
        }
    }
    if apply {
        let scanned = scan(store, true, &mut warnings)?;
        after = scanned.0;
        known = scanned.1;
    }
    let satisfied = known && after <= budget;
    Ok(
        json!({"recordAuditRequested":audit,"recordAuditComplete":audit&&known,"recordAuditScope":"registry-records-only","dryRun":!apply,"retentionDays":store.config.data.retention_days,"maxRecoveryBytes":store.config.data.max_recovery_bytes,"retainedBytesBefore":before,"retainedBytesAfter":after,"purgedBytes":purged,"plannedPurgeBytes":planned,"capacityKnown":known,"budgetSatisfied":satisfied,"complete":satisfied&&warnings.is_empty(),"operations":operations,"warnings":warnings}),
    )
}
#[cfg(windows)]
fn warning(result: &mut Value, message: &str) {
    result["warnings"]
        .as_array_mut()
        .unwrap()
        .push(json!(message));
}
#[cfg(windows)]
fn privilege_failure(
    result: &mut Value,
    error: &anyhow::Error,
    committed: bool,
    action: &str,
    id: &str,
) {
    let previous = result["items"][0]["error"].as_str().unwrap_or("");
    let detail = if previous.is_empty() {
        format!("Registry privilege restoration failed: {error}")
    } else {
        format!("{previous} Registry privilege restoration failed: {error}")
    };
    result["items"][0]["status"] = json!("failed");
    result["items"][0]["error"] = json!(detail);
    warning(
        result,
        &if committed {
            format!(
                "Registry {action} committed, but privilege restoration failed. Do not repeat {action}; inspect registry-reconcile {id}."
            )
        } else {
            "Registry privilege restoration failed before a confirmed commit.".into()
        },
    );
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    #[test]
    fn committed_privilege_failure_keeps_error_and_forbids_resend() {
        let mut value =
            json!({"operationId":"123","items":[{"status":"deleted","error":null}],"warnings":[]});
        privilege_failure(
            &mut value,
            &anyhow::anyhow!("injected restore failure"),
            true,
            "deletion",
            "123",
        );
        assert_eq!(value["items"][0]["status"], "failed");
        assert!(
            value["items"][0]["error"]
                .as_str()
                .unwrap()
                .contains("injected restore failure")
        );
        let warning = value["warnings"][0].as_str().unwrap();
        assert!(
            warning.contains("committed")
                && warning.contains("Do not repeat")
                && warning.contains("registry-reconcile 123")
        );
    }
    use crate::platform::windows::{self as win, security as sec};
    use storage::{MANIFEST, SNAPSHOT, Store};

    // 外部（リポジトリとCodex homeの外）のTEMPに、registry readyのstateだけを持つ新しい記録領域を作る。
    // 記録ファイルだけのfixtureであり、実registryのキー作成・削除・復元には使わない。
    fn uncommitted_fixture(label: &str) -> Result<Config> {
        let temp = win::path::external_verification_path(&std::env::temp_dir())?;
        let _parents = win::path::pin_directories(&temp)?;
        let base = temp.join(format!(
            "registry-{label}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        drop(sec::create_private_directory(&base)?);
        eprintln!("Registry uncommitted fixture retained: {}", base.display());
        let config = Config {
            path: base.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: base.to_str().unwrap().into(),
                ..Default::default()
            },
        };
        let store = Store::open(&config, true)?;
        let mut state = store.state.clone();
        state.registry_ready = true;
        state.assessment_complete = true;
        state.complete = true;
        state.legacy_file_policy_version = 2;
        store.save_state(&state)?;
        Ok(config)
    }
    fn fixture_snapshot(store: &Store, id: &str) -> Result<(model::Snapshot, Vec<u8>)> {
        let snapshot = model::Snapshot {
            scope: None,
            schema: 5,
            path: format!("HKEY_CURRENT_USER\\Software\\PrunletE2E\\{id}"),
            view: "64".into(),
            value_name: Some("uncommitted-fixture".into()),
            keys: vec![],
            value: Some(model::ValueSnapshot {
                name: "uncommitted-fixture".into(),
                r#type: 3,
                data: (0..4099).map(|n| (n % 251) as u8).collect(),
            }),
            context_security: Some(sec::read_member_security(store.registry.raw())?),
        };
        let bytes = storage::serialize(&snapshot)?;
        Ok((snapshot, bytes))
    }
    fn fixture_manifest(
        store: &Store,
        id: &str,
        snapshot: &model::Snapshot,
        bytes: &[u8],
    ) -> model::Manifest {
        model::Manifest {
            scope: None,
            schema: 5,
            operation_id: id.into(),
            created_utc: storage::now(),
            metadata_root: store.config.data.backup_directory.clone(),
            owner_sid: store.state.owner_sid.clone(),
            path: snapshot.path.clone(),
            view: snapshot.view.clone(),
            value_name: snapshot.value_name.clone(),
            kind: "registry-value".into(),
            size: bytes.len() as u64,
            sha256: model::hash(bytes),
        }
    }
    // delete()と同じ順でsnapshot・manifest・指定receiptを正式公開した記録を作る。
    fn published_record(store: &Store, receipts: &[(&str, &str)]) -> Result<(String, u64)> {
        let id = uuid::Uuid::new_v4().simple().to_string();
        let _parent = store.create_record(&id)?;
        let (snapshot, bytes) = fixture_snapshot(store, &id)?;
        drop(store.publish_bytes(&id, SNAPSHOT, &bytes)?);
        let manifest = fixture_manifest(store, &id, &snapshot, &bytes);
        let saved = store.publish(&id, MANIFEST, &manifest)?;
        let manifest_hash = model::hash(&saved.bytes);
        drop(saved);
        for (action, phase) in receipts {
            let receipt = model::Receipt {
                schema: 5,
                operation_id: id.clone(),
                manifest_sha256: manifest_hash.clone(),
                action: (*action).into(),
                phase: (*phase).into(),
                created_utc: storage::now(),
            };
            drop(store.publish(&id, &storage::receipt_name(action, phase), &receipt)?);
        }
        Ok((id, bytes.len() as u64))
    }
    // registry-delete直前と同じ容量判定（maintain apply + incoming）を通るかを返す。
    fn delete_gate(store: &Store, incoming: u64) -> Result<Value> {
        let maintenance = maintain(store, true, incoming, false)?;
        let budget = store.config.data.max_recovery_bytes.max(incoming);
        let reserved = maintenance["capacityKnown"] == true
            && maintenance["budgetSatisfied"] == true
            && maintenance["retainedBytesAfter"].as_u64().unwrap() <= budget - incoming;
        Ok(json!({"reserved":reserved,"maintenance":maintenance}))
    }
    fn names(store: &Store, id: &str) -> Result<Vec<String>> {
        let mut names = win::directory_names(storage::directory(&store.root.join(id))?.raw())?;
        names.sort();
        Ok(names)
    }

    #[test]
    fn uncommitted_record_counts_capacity_refuses_restore_and_purges() -> Result<()> {
        let config = uncommitted_fixture("uncommitted")?;
        let store = Store::open(&config, false)?;
        let (id, size) = published_record(&store, &[])?;
        let record = store.record(&id)?;
        ensure!(record.not_committed() && !record.ambiguous() && record.payload.is_some());
        drop(record);
        let dry = maintain(&store, false, 0, false)?;
        ensure!(
            dry["capacityKnown"] == true && dry["retainedBytesBefore"] == size,
            "Uncommitted capacity was not known: {dry}"
        );
        let gate = delete_gate(&store, 4096)?;
        ensure!(
            gate["reserved"] == true,
            "Uncommitted record blocked deletion: {gate}"
        );
        ensure!(storage::exists(&store.root.join(&id).join(SNAPSHOT))?);
        drop(store);
        let reconcile = execute(
            &config,
            "registry-reconcile",
            &json!({"operationId":id}),
            None,
        )?;
        ensure!(
            reconcile["items"][0]["status"] == "not_committed",
            "Unexpected reconcile: {reconcile}"
        );
        let operations = execute(&config, "operations", &json!({}), None)?;
        ensure!(
            operations["operations"][0]["lifecycleState"] == "not_committed",
            "Unexpected operations: {operations}"
        );
        // privilege・transactionの前に拒否するため、実registryには触れない。
        let restore = execute(
            &config,
            "registry-restore",
            &json!({"operationId":id}),
            None,
        )?;
        ensure!(
            restore["items"][0]["status"] == "failed"
                && restore["items"][0]["error"]
                    .as_str()
                    .unwrap()
                    .contains("not committed"),
            "Uncommitted restore was not refused: {restore}"
        );
        let preview = execute(&config, "purge", &json!({"operationId":id}), None)?;
        ensure!(preview["items"][0]["status"] == "would_purge");
        let purged = execute(
            &config,
            "purge",
            &json!({"operationId":id,"apply":true}),
            None,
        )?;
        ensure!(
            purged["items"][0]["status"] == "purged"
                && purged["purgedBytes"] == size
                && purged["warnings"].as_array().unwrap().is_empty(),
            "Uncommitted purge failed: {purged}"
        );
        let store = Store::open(&config, false)?;
        ensure!(
            !storage::exists(&store.root.join(&id))?,
            "Uncommitted record remained."
        );
        let after = maintain(&store, true, 0, false)?;
        ensure!(
            after["capacityKnown"] == true && after["complete"] == true,
            "{after}"
        );
        Ok(())
    }
    #[test]
    fn uncommitted_record_is_reclaimed_by_existing_budget_maintenance() -> Result<()> {
        let mut config = uncommitted_fixture("uncommitted-budget")?;
        config.data.max_recovery_bytes = 1;
        let store = Store::open(&config, false)?;
        let (id, _) = published_record(&store, &[])?;
        let result = maintain(&store, true, 0, false)?;
        ensure!(
            result["capacityKnown"] == true
                && result["retainedBytesAfter"] == 0
                && !storage::exists(&store.root.join(&id))?,
            "Budget maintenance retained the uncommitted record: {result}"
        );
        Ok(())
    }
    #[test]
    fn formal_intent_without_completion_remains_ambiguous() -> Result<()> {
        let config = uncommitted_fixture("intent-ambiguous")?;
        let store = Store::open(&config, false)?;
        let (id, _) = published_record(&store, &[("delete", "intent")])?;
        let record = store.record(&id)?;
        ensure!(record.ambiguous() && !record.not_committed());
        drop(record);
        let gate = delete_gate(&store, 4096)?;
        ensure!(
            gate["reserved"] == false && gate["maintenance"]["capacityKnown"] == false,
            "Ambiguous record did not block: {gate}"
        );
        ensure!(storage::exists(&store.root.join(&id).join(SNAPSHOT))?);
        let refused = purge(&store, &id, true)?;
        ensure!(
            refused["items"][0]["status"] == "failed"
                && storage::exists(&store.root.join(&id).join(SNAPSHOT))?,
            "Ambiguous purge was accepted: {refused}"
        );
        drop(store);
        let reconcile = execute(
            &config,
            "registry-reconcile",
            &json!({"operationId":id}),
            None,
        )?;
        ensure!(
            reconcile["items"][0]["status"] == "ambiguous",
            "{reconcile}"
        );
        Ok(())
    }
    #[test]
    fn uncommitted_pending_intent_reservation_is_never_promoted() -> Result<()> {
        let config = uncommitted_fixture("pending-intent")?;
        let store = Store::open(&config, false)?;
        let (id, size) = published_record(&store, &[])?;
        let manifest_hash = model::hash(&std::fs::read(store.root.join(&id).join(MANIFEST))?);
        let intent = model::Receipt {
            schema: 5,
            operation_id: id.clone(),
            manifest_sha256: manifest_hash,
            action: "delete".into(),
            phase: "intent".into(),
            created_utc: storage::now(),
        };
        let body = storage::serialize(&intent)?;
        let intent_name = storage::receipt_name("delete", "intent");
        // 本文を全て書いたがrename前に止まったpending。正式intentへは昇格しない。
        storage::test_reservation(&store, &id, &intent_name, &body, body.len())?;
        let record = store.record(&id)?;
        ensure!(record.not_committed() && !record.has("delete", "intent"));
        drop(record);
        let gate = delete_gate(&store, 4096)?;
        ensure!(gate["reserved"] == true, "{gate}");
        let purged = purge(&store, &id, true)?;
        ensure!(
            purged["items"][0]["status"] == "purged" && purged["purgedBytes"] == size,
            "{purged}"
        );
        let retained = names(&store, &id)?;
        ensure!(
            !retained.contains(&SNAPSHOT.to_string())
                && !retained.contains(&intent_name)
                && retained.contains(&MANIFEST.to_string())
                && retained.iter().any(|n| n.starts_with(".registry-pending-")),
            "Unexpected retained members: {retained:?}"
        );
        let after = maintain(&store, true, 0, false)?;
        ensure!(
            after["capacityKnown"] == true && after["retainedBytesAfter"] == 0,
            "{after}"
        );
        ensure!(
            names(&store, &id)? == retained,
            "Maintenance changed pending evidence."
        );
        Ok(())
    }
    #[test]
    fn reservation_only_residue_is_counted_and_retained_while_lock_only_is_discarded() -> Result<()>
    {
        let config = uncommitted_fixture("reservation-only")?;
        let store = Store::open(&config, false)?;
        // A: snapshot公開途中（所有予約と半分のpending）。
        let partial = uuid::Uuid::new_v4().simple().to_string();
        drop(store.create_record(&partial)?);
        let (_, snapshot_bytes) = fixture_snapshot(&store, &partial)?;
        storage::test_reservation(
            &store,
            &partial,
            SNAPSHOT,
            &snapshot_bytes,
            snapshot_bytes.len() / 2,
        )?;
        // B: 正式snapshotとmanifest公開途中（予約のみ）。
        let staged = uuid::Uuid::new_v4().simple().to_string();
        drop(store.create_record(&staged)?);
        let (snapshot, staged_bytes) = fixture_snapshot(&store, &staged)?;
        drop(store.publish_bytes(&staged, SNAPSHOT, &staged_bytes)?);
        let manifest =
            storage::serialize(&fixture_manifest(&store, &staged, &snapshot, &staged_bytes))?;
        storage::test_reservation(&store, &staged, MANIFEST, &manifest, 0)?;
        // C: create_record直後に止まったlockだけの記録。
        let empty = uuid::Uuid::new_v4().simple().to_string();
        drop(store.create_record(&empty)?);
        let before_a = names(&store, &partial)?;
        let before_b = names(&store, &staged)?;
        let dry = maintain(&store, false, 0, false)?;
        let expected = (snapshot_bytes.len() + staged_bytes.len()) as u64;
        ensure!(
            dry["capacityKnown"] == true
                && dry["retainedBytesBefore"] == expected
                && storage::exists(&store.root.join(&empty))?,
            "Dry-run changed or misclassified residue: {dry}"
        );
        let gate = delete_gate(&store, 4096)?;
        ensure!(
            gate["reserved"] == true && gate["maintenance"]["retainedBytesAfter"] == expected,
            "Reservation residue blocked deletion: {gate}"
        );
        ensure!(
            !storage::exists(&store.root.join(&empty))?,
            "Lock-only record was retained."
        );
        ensure!(names(&store, &partial)? == before_a && names(&store, &staged)? == before_b);
        let retained = purge(&store, &partial, true)?;
        ensure!(retained["items"][0]["status"] == "retained", "{retained}");
        ensure!(names(&store, &partial)? == before_a);
        drop(store);
        let reconcile = execute(
            &config,
            "registry-reconcile",
            &json!({"operationId":staged}),
            None,
        )?;
        ensure!(
            reconcile["items"][0]["status"] == "not_committed",
            "{reconcile}"
        );
        let operations = execute(&config, "operations", &json!({}), None)?;
        ensure!(
            operations["operations"]
                .as_array()
                .unwrap()
                .iter()
                .all(|o| o["lifecycleState"] == "not_committed"),
            "{operations}"
        );
        Ok(())
    }
    #[test]
    fn receipt_reservation_without_manifest_keeps_capacity_unknown() -> Result<()> {
        let config = uncommitted_fixture("receipt-reservation")?;
        let store = Store::open(&config, false)?;
        let id = uuid::Uuid::new_v4().simple().to_string();
        drop(store.create_record(&id)?);
        let receipt = model::Receipt {
            schema: 5,
            operation_id: id.clone(),
            manifest_sha256: model::hash(b"unpublished manifest"),
            action: "delete".into(),
            phase: "intent".into(),
            created_utc: storage::now(),
        };
        let body = storage::serialize(&receipt)?;
        storage::test_reservation(
            &store,
            &id,
            &storage::receipt_name("delete", "intent"),
            &body,
            1,
        )?;
        let before = names(&store, &id)?;
        let gate = delete_gate(&store, 4096)?;
        ensure!(
            gate["reserved"] == false && gate["maintenance"]["capacityKnown"] == false,
            "Unverifiable residue was accepted: {gate}"
        );
        ensure!(names(&store, &id)? == before);
        Ok(())
    }
    #[test]
    fn restored_snapshot_consumption_failure_keeps_restored_with_warning() -> Result<()> {
        let config = uncommitted_fixture("restore-consume")?;
        let store = Store::open(&config, false)?;
        let receipts = [
            ("delete", "intent"),
            ("delete", "complete"),
            ("restore", "intent"),
            ("restore", "complete"),
        ];
        for corrupt in [false, true] {
            let (id, _) = published_record(&store, &receipts)?;
            let mut record = store.record(&id)?;
            ensure!(!record.ambiguous() && record.payload.is_some());
            let snapshot_path = record.directory.join(SNAPSHOT);
            if corrupt {
                // 読取り済みleaseの後に同じ実体を改変し、consumeのhash照合だけを失敗させる。
                drop(record.payload.take());
                let original = std::fs::read(&snapshot_path)?;
                let mut changed = original.clone();
                let last = changed.len() - 2;
                changed[last] ^= 1;
                let handle = sec::open_lifecycle_pending_publisher(&snapshot_path)?;
                storage::write_handle(handle.raw(), &changed)?;
                drop(handle);
                record.payload = Some(storage::Held::read(&snapshot_path)?);
            }
            let mut result = json!({"operationId":id,"items":[{"status":"restored","error":null}],"warnings":[]});
            consume_restored(&mut record, &mut result);
            ensure!(result["items"][0]["status"] == "restored");
            let warnings = result["warnings"].as_array().unwrap();
            if corrupt {
                ensure!(
                    warnings.len() == 1
                        && warnings[0]
                            .as_str()
                            .unwrap()
                            .contains("snapshot consumption")
                        && storage::exists(&snapshot_path)?,
                    "{result}"
                );
            } else {
                ensure!(
                    warnings.is_empty() && !storage::exists(&snapshot_path)?,
                    "{result}"
                );
            }
        }
        Ok(())
    }
    #[test]
    fn invalid_dry_run_flag_is_never_coerced_to_actual_execution() {
        assert!(boolean(&json!({"dryRun":"true"}), "dryRun", false).is_err());
    }
    #[test]
    fn registry_request_uses_a_separate_joined_thread_and_preserves_caller_identity() {
        let caller = format!("{:?}", std::thread::current().id());
        let sid = native::current_sid().unwrap();
        let result=native::with_request_context(||Ok(json!({"thread":format!("{:?}",std::thread::current().id()),"sid":native::current_sid()?}))).unwrap();
        assert_ne!(result["thread"].as_str().unwrap(), caller);
        assert_eq!(result["sid"].as_str().unwrap(), sid);
        assert_eq!(native::current_sid().unwrap(), sid);
        assert!(
            native::with_request_context(|| Err(anyhow::anyhow!("injected worker failure")))
                .is_err()
        );
        assert_eq!(native::current_sid().unwrap(), sid);
    }
    // ---- 独立検証で見つかった保存境界・表示の不具合の回帰テスト（fixtureのmetadataだけを使い、実registryには触れない） ----

    // 外部プロセス相当のhandle。FILE_SHARE_DELETEを許す／許さないを選んで読取りで開く。
    fn external_reader(
        path: &std::path::Path,
        share_delete: bool,
    ) -> std::io::Result<std::fs::File> {
        use std::os::windows::fs::OpenOptionsExt;
        // FILE_SHARE_READ(1) | FILE_SHARE_WRITE(2) | FILE_SHARE_DELETE(4)
        std::fs::OpenOptions::new()
            .read(true)
            .share_mode(if share_delete { 7 } else { 3 })
            .open(path)
    }
    fn receipt_for(id: &str, manifest_sha256: String, action: &str, phase: &str) -> model::Receipt {
        model::Receipt {
            schema: 5,
            operation_id: id.into(),
            manifest_sha256,
            action: action.into(),
            phase: phase.into(),
            created_utc: storage::now(),
        }
    }

    // 正式本文の公開（rename）後に所有予約の削除だけが失敗しても、公開は成功として扱う。
    // 修正前はremoveの失敗がErrで返り、公開済みの正式intentを「未公開」と誤認させていた。
    #[test]
    fn reservation_removal_failure_after_verified_publication_is_nonfatal() -> Result<()> {
        let config = uncommitted_fixture("reservation-remove")?;
        let store = Store::open(&config, false)?;
        let id = uuid::Uuid::new_v4().simple().to_string();
        let _parent = store.create_record(&id)?;
        let (snapshot, bytes) = fixture_snapshot(&store, &id)?;
        drop(store.publish_bytes(&id, SNAPSHOT, &bytes)?);
        let manifest = fixture_manifest(&store, &id, &snapshot, &bytes);
        let saved = store.publish(&id, MANIFEST, &manifest)?;
        let manifest_hash = model::hash(&saved.bytes);
        drop(saved);
        let intent_name = storage::receipt_name("delete", "intent");
        // 本文の途中まで書込み済みの予約（中断した公開）を作り、その所有予約をDELETEを許さない読取りhandleで
        // 固定してから公開を再開させる。renameと本文の再検証は成功し、予約の削除だけが失敗する。
        // 全プロセス共通のcheckpoint hookは他のテストと干渉するため使わない。
        let receipt = receipt_for(&id, manifest_hash, "delete", "intent");
        let body = storage::serialize(&receipt)?;
        storage::test_reservation(&store, &id, &intent_name, &body, body.len() / 2)?;
        let dir = store.root.join(&id);
        let reservation = names(&store, &id)?
            .into_iter()
            .find(|n| n.starts_with(".registry-publication-") && n.contains("intent"))
            .context("intent reservation")?;
        let holder = external_reader(&dir.join(reservation), false)?;
        let published = store.publish(&id, &intent_name, &receipt)?;
        // 予約が残った状態（正式本文あり・holder生存中）でも、commit前の予約検証は通る。
        store.verify_reservations(&id)?;
        let notes = store.take_notes();
        ensure!(
            notes.len() == 1 && notes[0].contains("reservation"),
            "Reservation removal failure was not downgraded to a note: {notes:?}"
        );
        drop(published);
        // 公開済みの正式intentは保存され、残った予約付きでも記録は読める。曖昧状態（intentのみ）として保全される。
        let record = store.record(&id)?;
        ensure!(record.has("delete", "intent") && record.ambiguous());
        drop(record);
        let warning = delete_failure_warning(&store, &id, false);
        ensure!(
            warning.contains("commit was not confirmed")
                && !warning.contains("purge --apply removes"),
            "Stored intent was described as not committed: {warning}"
        );
        // holderを閉じた後は、後続のcleanupが所有予約を整理する。
        drop(holder);
        ensure!(store.cleanup_publications(&id)?);
        ensure!(
            names(&store, &id)?
                .iter()
                .all(|n| !n.starts_with(".registry-publication-"))
        );
        Ok(())
    }

    // commit前の予約検証: 検証できる予約は通し、改変されて検証できない予約はcommit前に止める。
    // 予約削除の失敗を非致命にしたため、改変された予約を見逃してcommitすると記録が読めなくなる。
    #[test]
    fn unverifiable_reservation_is_refused_before_commit() -> Result<()> {
        let config = uncommitted_fixture("reservation-verify")?;
        let store = Store::open(&config, false)?;
        let id = uuid::Uuid::new_v4().simple().to_string();
        let _parent = store.create_record(&id)?;
        let (snapshot, bytes) = fixture_snapshot(&store, &id)?;
        drop(store.publish_bytes(&id, SNAPSHOT, &bytes)?);
        let manifest = fixture_manifest(&store, &id, &snapshot, &bytes);
        let saved = store.publish(&id, MANIFEST, &manifest)?;
        let manifest_hash = model::hash(&saved.bytes);
        drop(saved);
        let intent_name = storage::receipt_name("delete", "intent");
        let receipt = receipt_for(&id, manifest_hash, "delete", "intent");
        let body = storage::serialize(&receipt)?;
        storage::test_reservation(&store, &id, &intent_name, &body, body.len() / 2)?;
        store.verify_reservations(&id)?;
        let reservation = names(&store, &id)?
            .into_iter()
            .find(|n| n.starts_with(".registry-publication-") && n.contains("intent"))
            .context("intent reservation")?;
        std::fs::write(store.root.join(&id).join(reservation), b"x")?;
        ensure!(
            store.verify_reservations(&id).is_err(),
            "A tampered reservation was accepted before commit"
        );
        Ok(())
    }

    // deleteの失敗後の案内は、保存済みの記録の状態で決める。
    #[test]
    fn delete_failure_warning_follows_the_stored_record() -> Result<()> {
        let config = uncommitted_fixture("delete-warning")?;
        let store = Store::open(&config, false)?;
        // 正式receiptなし: 未commit確定。
        let (a, _) = published_record(&store, &[])?;
        let w = delete_failure_warning(&store, &a, false);
        ensure!(
            w.contains("not committed before its intent was published"),
            "{w}"
        );
        // 正式intentのみ: commitの成否を推測しない。
        let (b, _) = published_record(&store, &[("delete", "intent")])?;
        let w = delete_failure_warning(&store, &b, false);
        ensure!(
            w.contains("commit was not confirmed") && w.contains("without inferring"),
            "{w}"
        );
        let w = delete_failure_warning(&store, &b, true);
        ensure!(w.contains("committed but completion is unconfirmed"), "{w}");
        // complete公開済み: 失敗はrename後の検証で起きており、削除は完了している。
        let (c, _) = published_record(&store, &[("delete", "intent"), ("delete", "complete")])?;
        let w = delete_failure_warning(&store, &c, true);
        ensure!(
            w.contains("completion receipt is published") && !w.contains("unconfirmed"),
            "{w}"
        );
        // manifest公開前: 空の記録はpurgeで整理でき、所有予約・snapshotを持つ記録は保全される。
        let empty = uuid::Uuid::new_v4().simple().to_string();
        drop(store.create_record(&empty)?);
        let w = delete_failure_warning(&store, &empty, false);
        ensure!(w.contains("empty recovery record"), "{w}");
        let staged = uuid::Uuid::new_v4().simple().to_string();
        drop(store.create_record(&staged)?);
        let (_, staged_bytes) = fixture_snapshot(&store, &staged)?;
        drop(store.publish_bytes(&staged, SNAPSHOT, &staged_bytes)?);
        let w = delete_failure_warning(&store, &staged, false);
        ensure!(
            w.contains("retained") && !w.contains("can be removed with purge"),
            "{w}"
        );
        ensure!(purge(&store, &staged, true)?["items"][0]["status"] == "retained");
        Ok(())
    }

    // restoreの失敗後の案内。intentの有無・complete公開済みを保存状態から分類する。
    #[test]
    fn restore_failure_warning_follows_the_stored_record() -> Result<()> {
        let config = uncommitted_fixture("restore-warning")?;
        let store = Store::open(&config, false)?;
        let base = [("delete", "intent"), ("delete", "complete")];
        let (none, _) = published_record(&store, &base)?;
        ensure!(restore_failure_warning(&store, &none, false).is_none());
        let with_intent = [base[0], base[1], ("restore", "intent")];
        let (intent, _) = published_record(&store, &with_intent)?;
        // 呼出元のフラグ（intent公開の確認前に失敗）に依らず、保存されたintentから警告する。
        let w = restore_failure_warning(&store, &intent, false).unwrap();
        ensure!(w.contains("no confirmed completion"), "{w}");
        let w = restore_failure_warning(&store, &intent, true).unwrap();
        ensure!(w.contains("committed but completion is unconfirmed"), "{w}");
        let with_complete = [
            base[0],
            base[1],
            ("restore", "intent"),
            ("restore", "complete"),
        ];
        let (complete, _) = published_record(&store, &with_complete)?;
        // すでに復元済みの記録を、スコープ不一致などで拒否した場合（commitしていない）は警告を付けない。
        ensure!(restore_failure_warning(&store, &complete, false).is_none());
        let w = restore_failure_warning(&store, &complete, true).unwrap();
        ensure!(
            w.contains("restoration is complete") && !w.contains("unconfirmed"),
            "{w}"
        );
        Ok(())
    }

    // purge中にsnapshot消費後のcomplete公開が失敗して残った記録を、maintain --applyが回収する。
    #[test]
    fn scan_apply_completes_a_purge_interrupted_after_snapshot_consumption() -> Result<()> {
        let config = uncommitted_fixture("purge-complete")?;
        let store = Store::open(&config, false)?;
        let receipts = [
            ("delete", "intent"),
            ("delete", "complete"),
            ("purge", "intent"),
        ];
        let (id, _) = published_record(&store, &receipts)?;
        // purgeがsnapshotを消費した直後に止まった状態を作る。
        store.record(&id)?.consume()?;
        let record = store.record(&id)?;
        ensure!(
            record.payload.is_none() && !record.has("purge", "complete") && !record.ambiguous()
        );
        drop(record);
        // dry-runは何も変更しない。
        maintain(&store, false, 0, false)?;
        ensure!(!store.record(&id)?.has("purge", "complete"));
        let applied = maintain(&store, true, 0, false)?;
        ensure!(applied["capacityKnown"] == true, "{applied}");
        // complete公開後はterminalへ閉じる（記録の本文は保持期間まで残る）。
        ensure!(
            storage::exists(&store.root.join(format!("{id}.terminal.json")))?,
            "Interrupted purge was not completed and closed: {applied}"
        );
        Ok(())
    }

    // 外部のFILE_SHARE_DELETE付きhandleが残っても、消費したmetadataの名前はその場で名前空間から外れる。
    // 従来のdelete設定ではdelete-pendingの名前が残り、親の削除が145、名前のopenが5で失敗した。
    #[test]
    fn consumed_snapshot_name_disappears_despite_external_delete_sharing_handle() -> Result<()> {
        let config = uncommitted_fixture("posix-consume")?;
        let store = Store::open(&config, false)?;
        let receipts = [
            ("delete", "intent"),
            ("delete", "complete"),
            ("purge", "intent"),
        ];
        let (id, _) = published_record(&store, &receipts)?;
        let snapshot_path = store.root.join(&id).join(SNAPSHOT);
        let external = external_reader(&snapshot_path, true)?;
        store.record(&id)?.consume()?;
        let exists = storage::exists(&snapshot_path);
        drop(external);
        ensure!(
            matches!(exists, Ok(false)),
            "Consumed snapshot name stayed delete-pending: {exists:?}"
        );
        Ok(())
    }

    // 1件の名前確認の失敗でmaintain全体が失敗せず、他の記録の整理は続く。実OSで名前確認が失敗する条件は再現できておらず、失敗の注入で確かめる。
    #[test]
    fn scan_isolates_a_member_that_cannot_be_checked() -> Result<()> {
        let mut config = uncommitted_fixture("scan-isolation")?;
        config.data.max_recovery_bytes = 1;
        let store = Store::open(&config, false)?;
        let (expired, _) = published_record(&store, &[])?;
        // 名前の確認だけが失敗する項目を、確認の失敗を注入して再現する。
        drop(sec::create_private_file(
            &store.root.join("stuck-member.tmp"),
        )?);
        SCAN_EXISTS_FAULT.with(|fault| *fault.borrow_mut() = Some("stuck-member.tmp".into()));
        let result = maintain(&store, true, 0, false);
        SCAN_EXISTS_FAULT.with(|fault| *fault.borrow_mut() = None);
        let result = result?;
        ensure!(
            result["capacityKnown"] == false
                && result["warnings"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|w| w.as_str().unwrap().contains("stuck-member.tmp")),
            "Unreadable member was not reported: {result}"
        );
        ensure!(
            !storage::exists(&store.root.join(&expired))?,
            "Other records were not maintained: {result}"
        );
        Ok(())
    }

    // 書込み途中で終了したstorage状態は、通常の改変拒否ではなくmigrate --applyで直せる状態として示す。
    #[test]
    fn truncated_storage_state_is_reported_as_migration_required_and_self_heals() -> Result<()> {
        let config = uncommitted_fixture("state-truncated")?;
        let state_path = std::path::Path::new(&config.data.backup_directory)
            .join(storage::ROOT)
            .join("storage-migration-v1.json");
        let original = std::fs::read(&state_path)?;
        let mut store = Store::open(&config, false)?;
        // Store::openの状態は未準備なので、fixtureと同じ準備済みの状態を保存対象にする。
        let mut saved = store.state.clone();
        saved.registry_ready = true;
        saved.assessment_complete = true;
        saved.complete = true;
        saved.legacy_file_policy_version = 2;
        for body in [&original[..0], &original[..original.len() / 2]] {
            let handle = sec::open_lifecycle_pending_publisher(&state_path)?;
            storage::write_handle(handle.raw(), body)?;
            drop(handle);
            let error = store.require_ready().unwrap_err().to_string();
            ensure!(
                error.starts_with("migration_required:") && error.contains("migrate --apply"),
                "Interrupted state write was not mapped: {error}"
            );
        }
        // 改変（有効なJSONだが別の束縛）はmigration_requiredへ写さず、そのまま拒否する。
        let mut tampered = saved.clone();
        tampered.owner_sid = "S-1-5-21-0-0-0-1".into();
        let handle = sec::open_lifecycle_pending_publisher(&state_path)?;
        storage::write_handle(handle.raw(), &storage::serialize(&tampered)?)?;
        drop(handle);
        let error = store.require_ready().unwrap_err().to_string();
        ensure!(
            !error.starts_with("migration_required:") && error.contains("binding differs"),
            "Tampered state was not refused as such: {error}"
        );
        // migrateが使う書込み（save_state）で自己修復できる。
        store.save_state(&saved)?;
        store.require_ready()?;
        Ok(())
    }
}
