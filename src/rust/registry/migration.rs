use super::{
    model::*,
    storage::{self, Held, MoveIdentity, Record, Store},
};
use crate::{
    config::Config,
    migration::{MigrationOperation, MigrationResult},
    platform::windows::{self as win, security as sec},
    service::Progress,
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeSet, io::Read, path::Path};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MigrationFile {
    pub name: String,
    pub identity: MoveIdentity,
    pub length: u64,
    pub sha256: String,
    #[serde(with = "super::model::bytes")]
    pub security: Vec<u8>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Intent {
    pub schema: u32,
    pub operation_id: String,
    pub metadata_root_identity: String,
    pub registry_root_identity: String,
    pub machine_name: String,
    pub owner_sid: String,
    pub directory_identity: MoveIdentity,
    #[serde(with = "super::model::bytes")]
    pub directory_security: Vec<u8>,
    pub files: Vec<MigrationFile>,
}
pub fn capture(store: &Store, record: &Record) -> Result<Intent> {
    let mut files = vec![];
    let mut names = win::directory_names(record.parent.raw())?;
    names.sort();
    for name in names {
        if name == "operation.lock" {
            files.push(MigrationFile {
                name,
                identity: MoveIdentity::of(record.lock.raw())?,
                length: 0,
                sha256: hash(&[]),
                security: sec::read_member_security(record.lock.raw())?,
            });
            continue;
        }
        let held = Held::read(&record.directory.join(&name))?;
        files.push(MigrationFile {
            name,
            identity: MoveIdentity::of(held.pin.raw())?,
            length: held.bytes.len() as u64,
            sha256: hash(&held.bytes),
            security: sec::read_member_security(held.pin.raw())?,
        });
    }
    Ok(Intent {
        schema: 1,
        operation_id: record.manifest.operation_id.clone(),
        metadata_root_identity: store.state.metadata_root_identity.clone(),
        registry_root_identity: store.state.registry_root_identity.clone(),
        machine_name: store.state.machine_name.clone(),
        owner_sid: store.state.owner_sid.clone(),
        directory_identity: MoveIdentity::of(record.parent.raw())?,
        directory_security: sec::read_member_security(record.parent.raw())?,
        files,
    })
}
pub fn validate(store: &Store, id: &str, intent: &Intent) -> Result<()> {
    operation_id(id)?;
    ensure!(
        intent.schema == 1
            && intent.operation_id == id
            && intent.metadata_root_identity == store.state.metadata_root_identity
            && intent.registry_root_identity == store.state.registry_root_identity
            && intent.machine_name == store.state.machine_name
            && intent.owner_sid == store.state.owner_sid
            && intent.directory_identity.valid()
            && !intent.directory_security.is_empty()
            && (2..=16).contains(&intent.files.len()),
        "Registry migration intent binding differs."
    );
    let mut names = BTreeSet::new();
    for entry in &intent.files {
        ensure!(
            !entry.name.contains(['\\', '/', ':', '\0'])
                && !matches!(entry.name.as_str(), "." | "..")
                && names.insert(&entry.name)
                && entry.identity.valid()
                && (entry.name == "operation.lock" || entry.length > 0)
                && digest(&entry.sha256)
                && !entry.security.is_empty(),
            "Invalid registry migration member binding."
        );
    }
    ensure!(
        names.contains(&storage::MANIFEST.to_string())
            && names.contains(&"operation.lock".to_string()),
        "Registry migration lacks manifest or lock."
    );
    Ok(())
}
pub fn verify_directory(
    _store: &Store,
    path: &Path,
    intent: &Intent,
    remaining: bool,
) -> Result<()> {
    let parent = storage::directory(path)?;
    ensure!(
        intent
            .directory_identity
            .same(&MoveIdentity::of(parent.raw())?)
            && intent.directory_security == sec::read_member_security(parent.raw())?,
        "Registry directory identity/security changed."
    );
    let names = win::directory_names(parent.raw())?;
    require_membership(
        &intent
            .files
            .iter()
            .map(|f| f.name.clone())
            .collect::<Vec<_>>(),
        &names,
        remaining,
    )?;
    for name in names {
        let saved = intent
            .files
            .iter()
            .find(|f| f.name == name)
            .context("Unknown registry recovery member retained")?;
        let pin = sec::open_lifecycle_metadata(&path.join(&name))?;
        storage::verify(&pin, false)?;
        ensure!(
            saved.identity.exact(&MoveIdentity::of(pin.raw())?)
                && saved.security == sec::read_member_security(pin.raw())?,
            "Registry member identity/security changed."
        );
        let mut reader = storage::file(pin.raw())?;
        ensure!(
            reader.metadata()?.len() == saved.length && saved.length <= MAX_BYTES as u64,
            "Registry member length changed."
        );
        let mut bytes = vec![];
        reader.read_to_end(&mut bytes)?;
        ensure!(
            hash(&bytes) == saved.sha256,
            "Registry member bytes changed."
        );
    }
    Ok(())
}
pub fn require_membership(expected: &[String], actual: &[String], partial: bool) -> Result<()> {
    let expected: BTreeSet<_> = expected.iter().collect();
    let actual_set: BTreeSet<_> = actual.iter().collect();
    ensure!(
        actual_set.len() == actual.len()
            && actual_set.is_subset(&expected)
            && (partial || actual_set == expected),
        "Registry terminal membership changed before an authenticated cleanup; evidence retained."
    );
    Ok(())
}
pub fn ensure_available(store: &Store, id: &str) -> Result<()> {
    operation_id(id)?;
    if storage::exists(&store.root.join(format!("{id}.terminal.json")))? {
        return Ok(());
    }
    let path = store.root.join(id);
    let control = store.root.join(format!("{id}.registry-migration.json"));
    if storage::exists(&path)?
        && !storage::exists(&control)?
        && !storage::exists(
            &control.with_file_name(format!("{id}.registry-migration.json.pending")),
        )?
    {
        return Ok(());
    }
    let migrated = move_operation(store, id, true)?;
    ensure!(
        migrated.status == "migrated",
        "{}",
        migrated
            .error
            .unwrap_or_else(|| "Registry operation migration remains unresolved.".into())
    );
    Ok(())
}
fn move_operation(store: &Store, id: &str, apply: bool) -> Result<MigrationOperation> {
    operation_id(id)?;
    let mut result = MigrationOperation {
        operation_id: id.into(),
        schema: Some(5),
        status: "would_migrate".into(),
        ..Default::default()
    };
    let source = Path::new(&store.config.data.backup_directory).join(id);
    let destination = store.root.join(id);
    let control = store.root.join(format!("{id}.registry-migration.json"));
    let pending = store
        .root
        .join(format!("{id}.registry-migration.json.pending"));
    let has_source = storage::exists(&source)?;
    let has_dest = storage::exists(&destination)?;
    ensure!(
        !(has_source && has_dest),
        "Registry migration has both source and destination; both retained."
    );
    let intent = if storage::exists(&control)? {
        ensure!(
            !storage::exists(&pending)?,
            "Registry migration has pending and final controls; both retained."
        );
        let intent: Intent = Held::read(&control)?.lifecycle()?;
        validate(store, id, &intent)?;
        intent
    } else {
        ensure!(has_source, "Legacy registry operation is absent.");
        let record = store.record_at(id, &source)?;
        if record.ambiguous() {
            result.status = "retained".into();
            result.error = Some(
                "Registry transaction outcome is ambiguous; source and snapshot retained.".into(),
            );
            return Ok(result);
        }
        if !apply {
            return Ok(result);
        }
        let intent = capture(store, &record)?;
        validate(store, id, &intent)?;
        storage::recovery_control(&control, &intent)?;
        intent
    };
    if !apply {
        return Ok(result);
    }
    ensure!(
        has_source || has_dest,
        "Both registry migration locations are absent."
    );
    {
        let record = store.record_at(id, if has_source { &source } else { &destination })?;
        ensure!(
            !record.ambiguous(),
            "Registry migration source has an ambiguous transaction outcome; evidence retained."
        );
    }
    verify_directory(
        store,
        if has_source { &source } else { &destination },
        &intent,
        false,
    )?;
    if has_source {
        let moving = sec::open_lifecycle_directory_move(&source)?;
        storage::verify(&moving, true)?;
        ensure!(
            intent
                .directory_identity
                .same(&MoveIdentity::of(moving.raw())?)
                && intent.directory_security == sec::read_member_security(moving.raw())?,
            "Registry migration directory changed before publication."
        );
        sec::rename_fixed(moving.raw(), store.registry.raw(), id)?;
    }
    verify_directory(store, &destination, &intent, false)?;
    {
        let record = store.record_at(id, &destination)?;
        ensure!(
            !record.ambiguous(),
            "Registry migration destination has an ambiguous transaction outcome; evidence retained."
        );
    }
    ensure!(
        !storage::exists(&source)?,
        "Registry migration source reappeared."
    );
    storage::remove(&control)?;
    result.status = "migrated".into();
    Ok(result)
}
pub fn execute(config: &Config, args: &Value, progress: Option<Progress>) -> Result<Value> {
    let apply = super::boolean(args, "apply", false)?;
    let if_needed = super::boolean(args, "ifNeeded", false)?;
    let retry = super::boolean(args, "retryLegacyDiscard", false)?;
    ensure!(
        !retry || (apply && !if_needed),
        "Legacy discard acknowledgement requires explicit migrate --apply without --if-needed."
    );
    let _coord = if apply {
        crate::files::coordination::acquire(config, None, progress.as_ref())?
    } else {
        crate::files::coordination::acquire_readonly(config, progress.as_ref())?
    };
    let root_exists =
        storage::exists(&Path::new(&config.data.backup_directory).join(storage::ROOT))?;
    if !root_exists && !apply {
        let mut result = MigrationResult {
            dry_run: true,
            complete: false,
            registry_ready: false,
            ..Default::default()
        };
        result.warnings.push(
            "Registry storage is not initialized; explicit migrate --apply is required.".into(),
        );
        crate::migration::files(config, false, true, retry, &mut result)?;
        return Ok(serde_json::to_value(result)?);
    }
    let store = Store::open(config, apply)?;
    let state_path = store.root.join("storage-migration-v1.json");
    let previous = if if_needed && storage::exists(&state_path)? {
        Held::read(&state_path)
            .and_then(|h| h.lifecycle::<storage::State>())
            .and_then(|s| {
                store.validate_state(&s)?;
                Ok(s)
            })
            .ok()
    } else {
        None
    };
    let evaluated = previous
        .as_ref()
        .is_some_and(|s| s.registry_ready && s.assessment_complete);
    let mut result = MigrationResult {
        dry_run: !apply,
        registry_ready: true,
        complete: true,
        ..Default::default()
    };
    let mut ids = BTreeSet::new();
    for name in win::directory_names(store.registry.raw())? {
        if let Some(id) = name
            .strip_suffix(".registry-migration.json")
            .or_else(|| name.strip_suffix(".registry-migration.json.pending"))
        {
            if operation_id(id).is_ok() {
                ids.insert(id.to_string());
            } else {
                result.registry_ready = false;
                result
                    .warnings
                    .push("Unknown registry migration control retained.".into());
            }
        }
    }
    if !evaluated {
        for entry in std::fs::read_dir(&config.data.backup_directory)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if operation_id(&name).is_err() {
                continue;
            }
            let pin = win::PinnedFile::open(
                &entry.path(),
                windows_sys::Win32::Storage::FileSystem::FILE_READ_ATTRIBUTES,
                3,
            )?;
            let identity = pin.identity()?;
            if !identity.is_directory() || identity.is_reparse() {
                continue;
            }
            pin.verify_named()?;
            if storage::exists(&entry.path().join(storage::MANIFEST))? {
                ids.insert(name);
            }
        }
    }
    for id in ids {
        match move_operation(&store, &id, apply) {
            Ok(operation) => {
                if !matches!(operation.status.as_str(), "migrated" | "would_migrate") {
                    result.registry_ready = false;
                }
                result.operations.push(operation);
            }
            Err(error) => {
                result.registry_ready = false;
                result.operations.push(MigrationOperation {
                    operation_id: id,
                    schema: Some(5),
                    status: "failed".into(),
                    error: Some(error.to_string()),
                    ..Default::default()
                });
            }
        }
    }
    for name in win::directory_names(store.registry.raw())? {
        if name.ends_with(".terminal.json.pending")
            || name.ends_with(".terminal-cleanup.json.pending")
        {
            if let Err(e) = super::terminal::inspect_member(&store, &name, apply) {
                result.registry_ready = false;
                result.warnings.push(e.to_string());
            }
        }
    }
    if !apply && !evaluated {
        result.registry_ready = store.require_ready_check().is_ok();
    }
    result.complete =
        result.registry_ready && previous.as_ref().is_none_or(|s| !evaluated || s.complete);
    if evaluated && previous.as_ref().is_some_and(|s| s.retained_count != 0) {
        result.warnings.push(format!(
            "Previous migration retained {} file records. Explicit migrate --apply rechecks them.",
            previous.as_ref().unwrap().retained_count
        ));
    }
    crate::migration::files(
        config,
        apply,
        !evaluated
            || previous
                .as_ref()
                .is_none_or(|s| s.legacy_file_policy_version != 2),
        retry,
        &mut result,
    )?;
    if result
        .operations
        .iter()
        .any(|o| matches!(o.status.as_str(), "retained" | "failed" | "ambiguous"))
    {
        result.complete = false;
    }
    if apply {
        let mut state = store.state.clone();
        state.registry_ready = result.registry_ready;
        state.assessment_complete = true;
        state.complete = result.complete;
        state.retained_count = result
            .operations
            .iter()
            .filter(|o| {
                o.schema != Some(5)
                    && matches!(o.status.as_str(), "retained" | "failed" | "ambiguous")
            })
            .count()
            .try_into()?;
        state.legacy_file_policy_version = 2;
        store.save_state(&state)?;
    }
    Ok(serde_json::to_value(result)?)
}
