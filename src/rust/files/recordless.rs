use super::coordination::{self, WorkerSlot};
use crate::{
    config::Config,
    platform::windows::{
        self as native, FileIdentity, PinnedFile,
        path::{self, DirectoryLease},
        recycle::{self, ImmediateDeleteSetting, RecycleOutcome},
        security,
    },
    service::Progress,
};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
#[cfg(test)]
use windows_sys::Win32::Foundation::GENERIC_WRITE;
use windows_sys::Win32::Storage::FileSystem::*;

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DeleteItem {
    pub path: String,
    pub kind: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DeleteResult {
    pub dry_run: bool,
    pub items: Vec<DeleteItem>,
    pub warnings: Vec<String>,
}
pub fn validate_config(config: &Config) -> Result<()> {
    let root = path::absolute(Path::new(&config.data.backup_directory))?;
    let actual = path::resolve(&root, false, false)?;
    let lease = path::pin_directories(&actual)?;
    for fixed in lease.handles {
        fixed.reject_case_sensitive()?;
    }
    let mut roots = BTreeSet::new();
    for (key, value) in &config.data.volume_recovery_directories {
        let key = path::absolute(Path::new(key))?;
        if key.to_string_lossy().len() != 3 || !roots.insert(key.to_string_lossy().to_uppercase()) {
            bail!("Volume recovery keys must be distinct local drive roots");
        }
        path::absolute(Path::new(value))?;
    }
    Ok(())
}
fn missing(error: &anyhow::Error) -> bool {
    error.chain().any(|e| {
        e.downcast_ref::<std::io::Error>()
            .is_some_and(|e| matches!(e.raw_os_error(), Some(2 | 3)))
    })
}
pub fn inspect(path: &Path) -> Result<Option<PinnedFile>> {
    match PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7) {
        Ok(f) => Ok(Some(f)),
        Err(error) if missing(&error) => Ok(None),
        Err(error) => Err(error),
    }
}
pub fn normalize_paths(config: &Config, args: &Value) -> Result<Vec<PathBuf>> {
    let input = args
        .get("paths")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("paths must be an array"))?;
    if input.is_empty() || input.len() > 256 {
        bail!("Specify between 1 and 256 paths");
    }
    let metadata = path::resolve(Path::new(&config.data.backup_directory), false, false)?;
    let mut result = vec![];
    for value in input {
        let value = value
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Each path must be a string"))?;
        let normalized = path::file_delete_absolute(Path::new(value))?;
        if normalized.to_string_lossy().len() == 3 {
            bail!("Drive root deletion is not permitted");
        }
        let parent = path::resolve(
            normalized
                .parent()
                .ok_or_else(|| anyhow::anyhow!("Target has no parent"))?,
            true,
            false,
        )?;
        let final_path = parent.join(
            normalized
                .file_name()
                .ok_or_else(|| anyhow::anyhow!("Target has no name"))?,
        );
        let (final_path, directory) = if let Some(fixed) = inspect(&final_path)? {
            (fixed.final_path()?, fixed.initial_identity().is_directory())
        } else {
            (final_path, false)
        };
        // 共通lockを新設する前に中央metadataとその祖先を拒否する。
        if path::within(&final_path, &metadata)
            || (directory && path::within(&metadata, &final_path))
        {
            bail!("Target path is inside or contains the metadata recovery directory");
        }
        result.push(final_path);
    }
    for (i, a) in result.iter().enumerate() {
        for b in &result[i + 1..] {
            if path::within(a, b) || path::within(b, a) {
                bail!("Duplicate or overlapping target paths are not allowed");
            }
        }
    }
    Ok(result)
}
fn protected_roots(config: &Config, target: &Path) -> Result<Vec<PathBuf>> {
    let mut roots = vec![path::resolve(
        Path::new(&config.data.backup_directory),
        false,
        false,
    )?];
    let sid = security::current_user_sid()?;
    let parent = target
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Missing target parent"))?;
    let mount = native::volume_mount_root(parent)?;
    if mount.to_string_lossy().trim_start_matches("\\\\?\\").len() != 3 {
        bail!("Recovery stores require a local drive-root volume mount");
    }
    let mount = path::absolute(&mount)?;
    for prefix in [".Prunlet-Recovery-", ".Prunlet-Restore-"] {
        roots.push(path::resolve(
            &mount.join(format!("{prefix}{sid}")),
            true,
            false,
        )?);
    }
    for (key, value) in &config.data.volume_recovery_directories {
        let expected = path::absolute(Path::new(key))?;
        for suffix in ["", ".restore"] {
            let root = path::resolve(Path::new(&format!("{value}{suffix}")), true, false).map_err(
                |error| {
                    error.context(format!(
                        "Configured recovery directory could not be validated: {value}{suffix}"
                    ))
                },
            )?;
            let actual = native::volume_mount_root(&root).map_err(|error| {
                error.context(format!(
                    "Configured recovery directory volume could not be validated: {value}{suffix}"
                ))
            })?;
            if !actual
                .to_string_lossy()
                .trim_start_matches("\\\\?\\")
                .eq_ignore_ascii_case(&expected.to_string_lossy())
            {
                bail!("Configured recovery directory must remain on its configured volume");
            }
            roots.push(root);
        }
    }
    roots.push(mount.join("$Recycle.Bin"));
    Ok(roots)
}
fn check_target(config: &Config, path: &Path, directory: bool) -> Result<()> {
    for (index, root) in protected_roots(config, path)?.into_iter().enumerate() {
        if path::within(path, &root) || (directory && path::within(&root, path)) {
            if index == 0 {
                bail!("Target is inside or contains the metadata recovery directory");
            }
            if root
                .file_name()
                .is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("$Recycle.Bin"))
            {
                bail!(
                    "Windows Recycle Bin storage is protected; use the Windows Recycle Bin to manage its contents"
                );
            }
            bail!("Target is inside or contains a volume recovery directory");
        }
    }
    Ok(())
}
fn kind(id: &FileIdentity) -> Result<&'static str> {
    Ok(match id.reparse_tag {
        0 => {
            if id.is_directory() {
                "directory"
            } else {
                "file"
            }
        }
        0xA0000003 => "junction",
        0xA000000C => "symlink",
        _ => bail!("Unsupported reparse point"),
    })
}
struct Prepared {
    path: PathBuf,
    parents: DirectoryLease,
    original: Option<PinnedFile>,
    identity: FileIdentity,
    parent_identity: FileIdentity,
    root: Option<PinnedFile>,
    reserved: bool,
    reparse: Option<Vec<u8>>,
}
fn verify_handle(fixed: &PinnedFile, path: &Path, expected: &FileIdentity) -> Result<()> {
    let actual = fixed.identity()?;
    if !expected.same_object(&actual)
        || expected.attributes != actual.attributes
        || fixed.final_path()? != path
    {
        bail!(
            "Fixed filesystem identity, parent, name or attributes changed: {}",
            path.display()
        );
    }
    Ok(())
}
fn empty_directory(path: &Path) -> Result<bool> {
    let _lease = path::pin_directories(path)?;
    let fixed = PinnedFile::open(path, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, 3)?;
    native::directory_is_empty(fixed.raw())
}
fn prepare(
    config: &Config,
    path: &Path,
    recursive: bool,
    exclusive: bool,
) -> Result<Option<Prepared>> {
    let original = inspect(path)?;
    check_target(
        config,
        path,
        original
            .as_ref()
            .is_some_and(|entry| entry.initial_identity().is_directory()),
    )?;
    let Some(original) = original else {
        return Ok(None);
    };
    let id = original.identity()?;
    kind(&id)?;
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Missing target parent"))?;
    let parents = path::pin_directories(parent)?;
    let parent_identity = parents
        .handles
        .last()
        .ok_or_else(|| anyhow::anyhow!("Missing fixed parent"))?
        .identity()?;
    verify_handle(&original, path, &id)?;
    let reparse = if id.is_reparse() {
        Some(native::read_reparse(original.raw())?)
    } else {
        None
    };
    let reserved = path::is_reserved_name(path.file_name().and_then(|x| x.to_str()).unwrap_or(""));
    if reserved && (id.is_directory() || id.is_reparse()) {
        bail!("Reserved names are supported only for ordinary files");
    }
    if id.is_directory() && !id.is_reparse() && !recursive && !empty_directory(path)? {
        bail!("Nonempty directories require explicit recursive deletion");
    }
    let root = if !exclusive && id.links > 1 && !id.is_directory() {
        None
    } else {
        let fixed = PinnedFile::open(path, DELETE | FILE_READ_ATTRIBUTES, 1)?;
        verify_handle(&fixed, path, &id)?;
        if exclusive { None } else { Some(fixed) }
    };
    Ok(Some(Prepared {
        path: path.to_owned(),
        parents,
        original: Some(original),
        identity: id,
        parent_identity,
        root,
        reserved,
        reparse,
    }))
}
pub fn execute(config: &Config, args: &Value, progress: Option<Progress>) -> Result<Value> {
    let paths = normalize_paths(config, args)?;
    let result = delete(
        config,
        &paths,
        args["dryRun"].as_bool().unwrap_or(false),
        args["recursive"].as_bool().unwrap_or(false),
        progress,
        None,
    )?;
    Ok(serde_json::to_value(result)?)
}
pub fn validate_queued_paths(config: &Config, paths: &[PathBuf]) -> Result<()> {
    for target in paths {
        let current = inspect(target)?
            .ok_or_else(|| anyhow::anyhow!("Queued deletion target does not exist"))?;
        check_target(config, target, current.initial_identity().is_directory())?;
    }
    Ok(())
}
pub fn delete(
    config: &Config,
    paths: &[PathBuf],
    dry_run: bool,
    recursive: bool,
    progress: Option<Progress>,
    snapshots: Option<&Mutex<Vec<Snapshot>>>,
) -> Result<DeleteResult> {
    let first = delete_inner(
        config,
        paths,
        dry_run,
        recursive,
        false,
        progress.clone(),
        snapshots,
    )?;
    match first {
        Some(result) => Ok(result),
        None => delete_inner(config, paths, dry_run, recursive, true, progress, snapshots)?
            .ok_or_else(|| anyhow::anyhow!("Exclusive preflight did not complete")),
    }
}
fn verify_snapshots(snapshots: Option<&Mutex<Vec<Snapshot>>>) -> Result<()> {
    if let Some(snapshots) = snapshots {
        for snapshot in snapshots
            .lock()
            .map_err(|_| anyhow::anyhow!("Queue snapshot unavailable"))?
            .iter()
        {
            snapshot.verify()?;
        }
    }
    Ok(())
}
fn verify_target_snapshot(snapshots: Option<&Mutex<Vec<Snapshot>>>, target: &Path) -> Result<()> {
    if let Some(snapshots) = snapshots {
        for snapshot in snapshots
            .lock()
            .map_err(|_| anyhow::anyhow!("Queue snapshot unavailable"))?
            .iter()
        {
            if snapshot.root() == target {
                snapshot.verify()?;
            }
        }
    }
    Ok(())
}
fn release_snapshot_tree(snapshots: Option<&Mutex<Vec<Snapshot>>>, target: &Path) -> Result<()> {
    if let Some(snapshots) = snapshots {
        for snapshot in snapshots
            .lock()
            .map_err(|_| anyhow::anyhow!("Queue snapshot unavailable"))?
            .iter_mut()
        {
            if snapshot.root() == target {
                for entry in &mut snapshot.entries {
                    entry.original.take();
                }
            }
        }
    }
    Ok(())
}
fn attempt_recycle(
    entry: &mut Prepared,
    recursive: bool,
    snapshots: Option<&Mutex<Vec<Snapshot>>>,
    expected: Option<&FileIdentity>,
) -> (Result<RecycleOutcome>, bool) {
    let mut started = false;
    let action = (|| -> Result<RecycleOutcome> {
        let _slot = WorkerSlot::acquire();
        let original = entry
            .original
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Source inspection was not retained"))?;
        verify_handle(original, &entry.path, &entry.identity)?;
        let current = original.identity()?;
        if let Some(expected) = expected {
            if current.creation_time != expected.creation_time
                || current.last_write_time != expected.last_write_time
                || current.change_time != expected.change_time
            {
                bail!("Shared source changed after a prior confirmed deletion");
            }
        }
        recycle::recycle(
            &entry.path,
            entry.identity.is_directory() && !entry.identity.is_reparse(),
            |physical| {
                verify_target_snapshot(snapshots, &entry.path)?;
                // Shellの8.3表記は通常実体だけ正規化し、名前の完全一致を要求する。
                if physical != entry.path
                    && (entry.identity.is_reparse()
                        || path::resolve(physical, false, false)? != entry.path)
                {
                    bail!("Shell source name differs from the fixed source");
                }
                verify_handle(original, &entry.path, &entry.identity)?;
                for parent in &entry.parents.handles {
                    parent.verify_named()?;
                }
                let fixed = PinnedFile::open(
                    &entry.path,
                    DELETE
                        | FILE_READ_ATTRIBUTES
                        | if entry.identity.is_directory()
                            && !entry.identity.is_reparse()
                            && !recursive
                        {
                            FILE_LIST_DIRECTORY
                        } else {
                            0
                        },
                    1,
                )?;
                verify_handle(&fixed, &entry.path, &entry.identity)?;
                if let Some(bytes) = &entry.reparse {
                    if native::read_reparse(fixed.raw())? != *bytes {
                        bail!("Reparse metadata changed before recycling");
                    }
                }
                if entry.identity.is_directory()
                    && !entry.identity.is_reparse()
                    && !recursive
                    && !native::directory_is_empty(fixed.raw())?
                {
                    bail!("Nonrecursive directory is no longer empty");
                }
                drop(fixed);
                started = true;
                #[cfg(test)]
                verification_checkpoint("before-shell", &entry.path)?;
                Ok(())
            },
            |destination| {
                #[cfg(test)]
                verification_checkpoint("shell-result-observed", destination)?;
                let recycled = PinnedFile::open(destination, FILE_READ_ATTRIBUTES, 7)?;
                if !entry.identity.same_object(&recycled.identity()?) {
                    bail!("Recycled object differs from the retained source identity");
                }
                #[cfg(test)]
                verification_checkpoint("shell-result-verified", &entry.path)?;
                Ok(())
            },
        )
    })();
    (action, started)
}
fn delete_inner(
    config: &Config,
    paths: &[PathBuf],
    dry_run: bool,
    recursive: bool,
    exclusive: bool,
    progress: Option<Progress>,
    snapshots: Option<&Mutex<Vec<Snapshot>>>,
) -> Result<Option<DeleteResult>> {
    let _coordination = if dry_run {
        None
    } else {
        Some(coordination::acquire(
            config,
            if exclusive { None } else { Some(paths) },
            progress.as_ref(),
        )?)
    };
    verify_snapshots(snapshots)?;
    let mut result = DeleteResult {
        dry_run,
        items: paths
            .iter()
            .map(|p| DeleteItem {
                path: p.to_string_lossy().into(),
                kind: "file".into(),
                status: "failed".into(),
                error: None,
            })
            .collect(),
        warnings: vec![],
    };
    let mut prepared = vec![];
    let mut hardlinks = false;
    for (index, path) in paths.iter().enumerate() {
        let _slot = WorkerSlot::acquire();
        match prepare(config, path, recursive, exclusive) {
            Ok(Some(entry)) => {
                result.items[index].kind = kind(&entry.identity)?.into();
                let item = &mut result.items[index];
                item.status = if entry.reserved {
                    "would_permanently_delete"
                } else {
                    "would_recycle"
                }
                .into();
                hardlinks |= entry.identity.links > 1 && !entry.identity.is_directory();
                prepared.push(Some(entry));
            }
            Ok(None) => {
                result.items[index].status = "already_absent".into();
                prepared.push(None);
            }
            Err(error) => {
                result.items[index].error = Some(diagnose_with(path, &error, !dry_run));
                prepared.push(None);
            }
        }
    }
    if hardlinks && !exclusive {
        return Ok(None);
    }
    if dry_run {
        if result.items.iter().any(|x| x.status == "would_recycle") {
            result.warnings.push("Dry-run cannot determine whether Windows will recycle an item; an oversized file or directory, or an item on a volume configured for immediate deletion, may be permanently deleted.".into());
        }
        return Ok(Some(result));
    }
    if result.items.iter().any(|x| x.status == "failed") {
        bail!(
            "Deletion preflight failed; original targets were retained. {}",
            result
                .items
                .iter()
                .filter_map(|x| x.error.as_deref())
                .collect::<Vec<_>>()
                .join(" ")
        );
    }
    let mut permanent: Vec<(usize, Option<ImmediateDeleteSetting>, bool)> = vec![];
    // 共有hardlinkは排他batchを保持し、全Shell完了後に限定された永久削除へ進む。
    let mut changed: BTreeMap<(u64, [u8; 16]), FileIdentity> = BTreeMap::new();
    let mut uncertain = BTreeSet::new();
    let mut permanent_guards: BTreeMap<(u64, [u8; 16]), HardlinkGuard> = BTreeMap::new();
    let mut concurrent: BTreeMap<usize, (Result<RecycleOutcome>, bool)> = BTreeMap::new();
    let token = native::EffectiveToken::capture()?;
    if !exclusive {
        for (base, chunk) in prepared.chunks_mut(4).enumerate() {
            let completed = std::thread::scope(|scope| -> Result<Vec<_>> {
                let mut tasks = vec![];
                let mut done = vec![];
                for (offset, entry) in chunk.iter_mut().enumerate() {
                    if let Some(entry) = entry.as_mut() {
                        entry.root.take();
                        if entry.reserved {
                            continue;
                        }
                        let token = &token;
                        let index = base * 4 + offset;
                        match native::process::spawn_scoped(scope,"file-shell-worker",move || {
                                token.run(|| Ok(attempt_recycle(entry, recursive, snapshots, None)))
                            }) {
                            Ok(task)=>tasks.push((index,task)),
                            Err(error)=>done.push((index,(Err(anyhow::anyhow!("Shell worker could not be started; this item was not submitted to Windows: {error}")),false))),
                        }
                    }
                }
                for (index, task) in tasks {
                    let outcome = match task.join() {
                        Ok(Ok(outcome)) => outcome,
                        Ok(Err(error)) => (Err(error), false),
                        Err(_) => (
                            Err(anyhow::anyhow!(
                                "Deletion worker stopped unexpectedly; outcome is unknown"
                            )),
                            true,
                        ),
                    };
                    done.push((index, outcome));
                }
                Ok(done)
            })?;
            concurrent.extend(completed);
        }
    }
    for index in 0..prepared.len() {
        let Some(entry) = prepared[index].as_mut() else {
            continue;
        };
        entry.root.take();
        if entry.reserved {
            permanent.push((index, None, false));
            continue;
        }
        let mut started = false;
        let key = (entry.identity.volume, entry.identity.id);
        let action = if let Some((action, was_started)) = concurrent.remove(&index) {
            started = was_started;
            action
        } else if uncertain.contains(&key) {
            Err(anyhow::anyhow!(
                "A prior shared hardlink outcome is unknown"
            ))
        } else {
            let expected = changed.get(&key).cloned();
            let (action, was_started) =
                attempt_recycle(entry, recursive, snapshots, expected.as_ref());
            started = was_started;
            action
        };
        match action {
            Ok(RecycleOutcome::PermanentAllowed(setting)) => {
                #[cfg(test)]
                if let Err(error) =
                    verification_checkpoint("shell-permanent-permitted", &entry.path)
                {
                    result.items[index].status = "ambiguous".into();
                    result.items[index].error = Some(format!("{error:#}. Do not resend deletion."));
                    uncertain.insert(key);
                    continue;
                }
                #[cfg(test)]
                if let Err(error) = verification_checkpoint(
                    if setting.is_none() {
                        "shell-size-permanent-permitted"
                    } else {
                        "shell-setting-permanent-permitted"
                    },
                    &entry.path,
                ) {
                    result.items[index].status = "ambiguous".into();
                    result.items[index].error = Some(format!("{error:#}. Do not resend deletion."));
                    uncertain.insert(key);
                    continue;
                }
                permanent.push((index, setting, true));
            }
            Ok(RecycleOutcome::Recycled) => {
                let completed = (|| -> Result<()> {
                    #[cfg(test)]
                    if let Some(checkpoint) = take_after_shell_checkpoint(&entry.path) {
                        checkpoint()?;
                    }
                    let original = entry.original.as_ref().ok_or_else(|| {
                        anyhow::anyhow!(
                            "Original inspection was not retained after Shell completion"
                        )
                    })?;
                    let current = original.identity()?;
                    changed.insert(key, current);
                    if entry.identity.links > 1
                        && !entry.identity.is_directory()
                        && !entry.identity.is_reparse()
                    {
                        let original = entry.original.take().unwrap();
                        permanent_guards
                            .entry(key)
                            .or_insert_with(|| HardlinkGuard {
                                base: original,
                                streams: None,
                                stream_handles: vec![],
                                unprotected_root: None,
                                recycled: true,
                                stream_limit: None,
                            });
                    } else {
                        entry.original.take();
                    }
                    release_snapshot_tree(snapshots, &entry.path)?;
                    if inspect(&entry.path)?.is_some() {
                        bail!("Source name is still present after confirmed Shell completion");
                    }
                    Ok(())
                })();
                match completed {
                    Ok(()) => result.items[index].status = "recycled".into(),
                    Err(error) => {
                        uncertain.insert(key);
                        result.items[index].status = "ambiguous".into();
                        result.items[index].error = Some(format!(
                            "Windows returned a recycled object but final verification failed: {error:#}. Inspect source and Windows Recycle Bin; do not resend deletion."
                        ));
                    }
                }
            }
            Err(error) => {
                if started {
                    uncertain.insert(key);
                }
                result.items[index].status = if started { "ambiguous" } else { "failed" }.into();
                result.items[index].error = Some(format!(
                    "{}{}",
                    diagnose(&entry.path, &error),
                    if started {
                        " The operation was not retried. Inspect source and Windows Recycle Bin before further action."
                    } else {
                        ""
                    }
                ));
            }
        }
    }
    let permanent_state = PermanentState::from_completed(changed, permanent_guards, uncertain);
    // rootは最大4 workerで並列実行し、同じFileIDの照合からdisposition後の確定までは個別に排他する。
    for chunk in permanent.chunks(4) {
        let completed = std::thread::scope(|scope| {
            let mut tasks = vec![];
            let mut done = vec![];
            for (index, setting, started) in chunk {
                let mut entry = prepared[*index].take().unwrap();
                let token = &token;
                let state = &permanent_state;
                match native::process::spawn_scoped(scope,"file-permanent-worker",move || {
                    let mut started = *started;
                    let action = token.run(|| {
                        let _slot = WorkerSlot::acquire();
                        verify_target_snapshot(snapshots, &entry.path)?;
                        let key = (entry.identity.volume, entry.identity.id);
                        if state.member(key)?.lock().map_err(|_| anyhow::anyhow!("Shared file state unavailable"))?.uncertain {
                            bail!("A prior shared hardlink outcome is unknown");
                        }
                        #[cfg(test)]
                        verification_checkpoint("permanent-root-start", &entry.path)?;
                        permanent_delete(config, &mut entry, recursive, setting.as_ref(), &mut started, state, snapshots)?;
                        entry.original.take();
                        verify_permanent_absence(&entry.path)?;
                        #[cfg(test)]
                        verification_checkpoint("permanent-root-finished", &entry.path)?;
                        Ok(())
                    });
                    match action {
                        Ok(()) => ("permanently_deleted".to_string(), None),
                        Err(error) => {
                            if let Ok(member) = state.member((entry.identity.volume, entry.identity.id)) {
                                if let Ok(mut member) = member.lock() { member.uncertain = true; }
                            }
                            let error = format!("{}{}", diagnose(&entry.path, &error), if started { " Some entries may have been permanently deleted. The operation was not retried. Inspect source and Windows Recycle Bin before further action." } else { "" });
                            (if started { "ambiguous" } else { "failed" }.to_string(), Some(error))
                        }
                    }
                }) {
                    Ok(task)=>tasks.push((*index,task)),
                    Err(error)=>done.push((*index,(if *started{"ambiguous"}else{"failed"}.into(),Some(format!("Permanent deletion worker could not be started; no permanent deletion was attempted by this worker: {error}. {}",if *started{"Windows was already called for this item. The operation was not retried. Inspect source and Windows Recycle Bin before further action; do not resend deletion."}else{"Earlier completed items were not retried."}))))),
                }
            }
            done.extend(tasks.into_iter().map(|(index,task)| (index, task.join().unwrap_or_else(|_| ("ambiguous".into(), Some("Permanent deletion worker stopped unexpectedly. Inspect source and Windows Recycle Bin; do not resend deletion.".into()))))));
            done
        });
        for (index, (status, error)) in completed {
            result.items[index].status = status;
            result.items[index].error = error;
        }
    }
    Ok(Some(result))
}
#[derive(Debug)]
struct FailureEntry(PathBuf);
impl std::fmt::Display for FailureEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Failure entry: {}",
            serde_json::json!(self.0.to_string_lossy())
        )
    }
}

impl std::error::Error for FailureEntry {}

pub fn diagnose(path: &Path, error: &anyhow::Error) -> String {
    diagnose_with(path, error, true)
}
fn diagnose_with(path: &Path, error: &anyhow::Error, inspect_locks: bool) -> String {
    let failure_path = error
        .downcast_ref::<FailureEntry>()
        .map(|e| e.0.as_path())
        .unwrap_or(path);
    let code = error.chain().find_map(|e| {
        e.downcast_ref::<std::io::Error>()
            .and_then(|e| e.raw_os_error())
    });
    let guidance = match code {
        Some(32 | 33) => {
            " Windows reported a sharing or lock violation; close the application using the target before a new manual request."
        }
        Some(5) => " Windows reported access denied. No permissions or owner were changed.",
        _ => "",
    };
    let text = format!("{error:#}").to_uppercase();
    let mut result = format!(
        "Target: {}. {error:#}",
        serde_json::json!(path.to_string_lossy())
    );
    if let Some(code) = code {
        result.push_str(&format!("; native error {code}."));
        // CLR例外の固定番号は再現せず、Win32値から導出したことを明示する。
        // COM/Shellが実際に返したHRESULTは元のerror内にそのまま保持する。
        if code > 0 {
            let hresult = 0x8007_0000_u32 | (code as u32 & 0xffff);
            result.push_str(&format!(
                " HRESULT 0x{hresult:08X} (derived from Win32 error {code})."
            ));
        }
    }
    result.push_str(guidance);
    if code == Some(5) || text.contains("0X80070005") {
        result.push_str(" Windows access denial can result from security restrictions, pending deletion, or other access conditions; error 5 alone does not identify the cause.");
    }
    if text.contains("(HRESULT 0X80270021)") {
        result.push_str(" Windows denied access to the source (COPYENGINE_E_ACCESS_DENIED_SRC); this does not identify a locking process.");
    }
    if text.contains("(HRESULT 0X80270022)") {
        result.push_str(" Windows denied access to the destination (COPYENGINE_E_ACCESS_DENIED_DEST); this does not identify a locking process.");
    }
    if inspect_locks
        && (matches!(code, Some(5 | 32 | 33))
            || [
                "0X80270021",
                "0X80270027",
                "0X80270028",
                "0X80070005",
                "0X80070020",
                "0X80070021",
            ]
            .iter()
            .any(|value| text.contains(value)))
    {
        match native::diagnostics::observe_users(failure_path){Ok(details)=>result.push_str(&details),Err(error)=>result.push_str(&format!(" Lock diagnostics unavailable ({error}); the original deletion result is unchanged."))}
    }
    result
}

struct TreeEntry {
    path: PathBuf,
    parent_identity: FileIdentity,
    original: Option<PinnedFile>,
    identity: FileIdentity,
    reparse: Option<Vec<u8>>,
    children: Vec<String>,
}
#[cfg(test)]
static PERMANENT_AFTER_CAPTURE: Mutex<Option<Box<dyn FnOnce() -> Result<()> + Send>>> =
    Mutex::new(None);
#[cfg(test)]
static AFTER_SHELL_VERIFICATION: Mutex<Option<(PathBuf, Box<dyn FnOnce() -> Result<()> + Send>)>> =
    Mutex::new(None);
#[cfg(test)]
fn take_after_shell_checkpoint(path: &Path) -> Option<Box<dyn FnOnce() -> Result<()> + Send>> {
    let mut fault = AFTER_SHELL_VERIFICATION.lock().unwrap();
    if fault.as_ref().is_some_and(|(expected, _)| expected == path) {
        fault.take().map(|(_, callback)| callback)
    } else {
        None
    }
}
#[cfg(test)]
type FileCheckpoint = std::sync::Arc<dyn Fn(&str, &Path) -> Result<()> + Send + Sync>;
#[cfg(test)]
static FILE_CHECKPOINT: Mutex<Option<FileCheckpoint>> = Mutex::new(None);
#[cfg(test)]
fn verification_checkpoint(phase: &str, path: &Path) -> Result<()> {
    let callback = FILE_CHECKPOINT.lock().unwrap().clone();
    if let Some(callback) = callback {
        callback(phase, path)?;
    }
    Ok(())
}
#[cfg(test)]
static PERMANENT_TEST_SERIAL: Mutex<()> = Mutex::new(());
struct HardlinkGuard {
    base: PinnedFile,
    streams: Option<Vec<native::NamedStream>>,
    stream_handles: Vec<native::OwnedHandle>,
    unprotected_root: Option<PathBuf>,
    recycled: bool,
    stream_limit: Option<usize>,
}
fn access_denied(error: &anyhow::Error) -> bool {
    error.chain().any(|e| {
        e.downcast_ref::<std::io::Error>()
            .is_some_and(|e| e.raw_os_error() == Some(5))
    })
}
fn open_hardlink_guard(path: &Path) -> Result<Option<PinnedFile>> {
    match PinnedFile::open(
        path,
        FILE_READ_ATTRIBUTES | FILE_EXECUTE,
        FILE_SHARE_READ | FILE_SHARE_DELETE,
    ) {
        Ok(guard) => Ok(Some(guard)),
        Err(error) if access_denied(&error) => match PinnedFile::open(
            path,
            FILE_READ_ATTRIBUTES | FILE_READ_DATA,
            FILE_SHARE_READ | FILE_SHARE_DELETE,
        ) {
            Ok(guard) => Ok(Some(guard)),
            Err(error) if access_denied(&error) => Ok(None),
            Err(error) => Err(error),
        },
        Err(error) => Err(error),
    }
}
fn retain_hardlink_streams(
    path: &Path,
    base: &PinnedFile,
    maximum: Option<usize>,
) -> Result<(Vec<native::NamedStream>, Vec<native::OwnedHandle>)> {
    let names = match maximum {
        Some(limit) => native::named_streams_bounded(base.raw(), limit)?,
        None => native::named_streams(base.raw())?,
    };
    let expected = base.identity()?;
    let mut handles = vec![];
    for stream in &names {
        let handle =
            native::open_hardlink_stream_guard(path, &stream.name, true).or_else(|error| {
                if access_denied(&error) {
                    native::open_hardlink_stream_guard(path, &stream.name, false)
                } else {
                    Err(error)
                }
            })?;
        if !expected.same_object(&native::identity(handle.raw())?) {
            bail!("Alternate hardlink stream identity changed while being retained");
        }
        handles.push(handle);
    }
    let current = match maximum {
        Some(_) => native::named_streams_bounded(base.raw(), names.len())?,
        None => native::named_streams(base.raw())?,
    };
    if current != names {
        bail!("Alternate hardlink stream list changed while being retained");
    }
    Ok((names, handles))
}
impl HardlinkGuard {
    fn can_continue(&self, root: &Path) -> bool {
        self.unprotected_root
            .as_ref()
            .is_none_or(|origin| origin == root)
    }
    fn streams_match(&self) -> Result<bool> {
        if self.unprotected_root.is_some() {
            return Ok(true);
        }
        Ok(self.streams.as_ref().is_some_and(|names| {
            match self.stream_limit {
                Some(limit) => native::named_streams_bounded(self.base.raw(), limit),
                None => native::named_streams(self.base.raw()),
            }
            .is_ok_and(|actual| actual == *names)
        }))
    }
    fn capture(path: &Path, identity: &FileIdentity, root: &Path) -> Result<Self> {
        Self::capture_with_stream_budget(path, identity, root, None)
    }
    fn capture_with_stream_budget(
        path: &Path,
        identity: &FileIdentity,
        root: &Path,
        budget: Option<&mut usize>,
    ) -> Result<Self> {
        let protected = open_hardlink_guard(path)?;
        let unprotected = protected.is_none();
        let base = match protected {
            Some(base) => base,
            None => PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7)?,
        };
        verify_handle(&base, path, identity)?;
        let bounded = budget.is_some();
        let retained = if let Some(budget) = budget {
            anyhow::ensure!(
                !unprotected,
                "Reserved-tree hardlinks require retained stream write guards"
            );
            let retained = retain_hardlink_streams(path, &base, Some(*budget))?;
            *budget -= retained.1.len();
            Some(retained)
        } else if unprotected {
            None
        } else {
            retain_hardlink_streams(path, &base, None).ok()
        };
        let (streams, stream_handles, unprotected_root) = match retained {
            Some((names, handles)) => (Some(names), handles, None),
            None => (None, vec![], Some(root.to_owned())),
        };
        let stream_limit = if bounded {
            streams.as_ref().map(Vec::len)
        } else {
            None
        };
        Ok(Self {
            base,
            streams,
            stream_handles,
            unprotected_root,
            recycled: false,
            stream_limit,
        })
    }
    fn upgrade_recycled(
        &mut self,
        path: &Path,
        identity: &FileIdentity,
        expected: &FileIdentity,
    ) -> Result<()> {
        if !self.recycled {
            return Ok(());
        }
        let prior = self.base.identity()?;
        if !identity.same_object(&prior)
            || prior.attributes != identity.attributes
            || prior.change_time != expected.change_time
        {
            bail!("Recycled hardlink changed before permanent deletion");
        }
        match open_hardlink_guard(path)? {
            Some(candidate) => {
                verify_handle(&candidate, path, identity)?;
                if candidate.identity()?.change_time != expected.change_time {
                    bail!("Recycled hardlink changed while its write guard was acquired");
                }
                match retain_hardlink_streams(path, &candidate, None) {
                    Ok((names, handles)) => {
                        self.base = candidate;
                        self.streams = Some(names);
                        self.stream_handles = handles;
                    }
                    Err(_) => {
                        self.unprotected_root = Some(PathBuf::new());
                    }
                }
            }
            None => {
                self.unprotected_root = Some(PathBuf::new());
            }
        }
        self.recycled = false;
        Ok(())
    }
}
type FileKey = (u64, [u8; 16]);
#[derive(Default)]
struct PermanentFileState {
    changed: Option<FileIdentity>,
    guard: Option<HardlinkGuard>,
    uncertain: bool,
}
#[derive(Default)]
struct PermanentState {
    members: Mutex<BTreeMap<FileKey, Arc<Mutex<PermanentFileState>>>>,
}
impl PermanentState {
    fn from_completed(
        changed: BTreeMap<FileKey, FileIdentity>,
        guards: BTreeMap<FileKey, HardlinkGuard>,
        uncertain: BTreeSet<FileKey>,
    ) -> Self {
        let mut members: BTreeMap<FileKey, Arc<Mutex<PermanentFileState>>> = BTreeMap::new();
        for (key, identity) in changed {
            members.entry(key).or_default().lock().unwrap().changed = Some(identity);
        }
        for (key, guard) in guards {
            members.entry(key).or_default().lock().unwrap().guard = Some(guard);
        }
        for key in uncertain {
            members.entry(key).or_default().lock().unwrap().uncertain = true;
        }
        Self {
            members: Mutex::new(members),
        }
    }
    fn member(&self, key: FileKey) -> Result<Arc<Mutex<PermanentFileState>>> {
        Ok(self
            .members
            .lock()
            .map_err(|_| anyhow::anyhow!("Shared file state unavailable"))?
            .entry(key)
            .or_default()
            .clone())
    }
}
fn pin_tree_directories(tree: &[TreeEntry]) -> Result<Vec<Option<PinnedFile>>> {
    tree.iter()
        .map(|entry| {
            if entry.identity.is_directory() && !entry.identity.is_reparse() {
                let pin = PinnedFile::open(&entry.path, FILE_READ_ATTRIBUTES, 3)?;
                verify_handle(&pin, &entry.path, &entry.identity)?;
                Ok(Some(pin))
            } else {
                Ok(None)
            }
        })
        .collect()
}
fn prepare_tree_hardlinks(
    tree: &[TreeEntry],
    root: &Path,
    states: &PermanentState,
    mut stream_budget: Option<&mut usize>,
) -> Result<()> {
    for entry in tree {
        if entry.identity.links > 1
            && !entry.identity.is_directory()
            && !entry.identity.is_reparse()
        {
            let state = states.member((entry.identity.volume, entry.identity.id))?;
            #[cfg(test)]
            verification_checkpoint("hardlink-state-waiting", &entry.path)?;
            #[cfg(test)]
            if matches!(state.try_lock(), Err(std::sync::TryLockError::WouldBlock)) {
                verification_checkpoint("hardlink-state-contended", &entry.path)?;
            }
            let mut state = state
                .lock()
                .map_err(|_| anyhow::anyhow!("Shared file state unavailable"))?;
            if state.guard.is_none() {
                state.guard = Some(match stream_budget.as_deref_mut() {
                    Some(budget) => HardlinkGuard::capture_with_stream_budget(
                        &entry.path,
                        &entry.identity,
                        root,
                        Some(budget),
                    )?,
                    None => HardlinkGuard::capture(&entry.path, &entry.identity, root)?,
                });
            }
            if !state.guard.as_ref().unwrap().can_continue(root) {
                bail!(
                    "A shared hardlink without retained write guards cannot continue in another root"
                );
            }
        }
    }
    Ok(())
}
fn permanent_delete(
    config: &Config,
    root: &mut Prepared,
    recursive: bool,
    setting: Option<&ImmediateDeleteSetting>,
    started: &mut bool,
    states: &PermanentState,
    snapshots: Option<&Mutex<Vec<Snapshot>>>,
) -> Result<()> {
    check_target(config, &root.path, root.identity.is_directory())?;
    let parent = root
        .parents
        .handles
        .last()
        .ok_or_else(|| anyhow::anyhow!("Missing fixed parent"))?;
    let current_parent = parent.identity()?;
    if !root.parent_identity.same_object(&current_parent)
        || root.parent_identity.attributes != current_parent.attributes
    {
        bail!("Permanent delete parent identity changed");
    }
    let mut tree = vec![];
    capture_tree(&root.path, recursive, &mut tree, usize::MAX, None)?;
    if !root.identity.same_object(&tree[0].identity)
        || root.identity.attributes != tree[0].identity.attributes
    {
        bail!("Permanent source identity changed");
    }
    #[cfg(test)]
    if let Some(checkpoint) = PERMANENT_AFTER_CAPTURE.lock().unwrap().take() {
        checkpoint()?;
    }
    // 捕捉後に親を別実体へ差し替えられても、子のhardlink IDだけでは通さない。
    // 全directoryの名前を先に固定し、各directory自身の削除直前まで保持する。
    let mut directory_pins = pin_tree_directories(&tree)?;
    prepare_tree_hardlinks(&tree, &root.path, states, None)?;
    for index in (0..tree.len()).rev() {
        let entry = &mut tree[index];
        let failure_path = entry.path.clone();
        let outcome = (|| -> Result<()> {
            directory_pins[index].take();
            let parent_path = entry
                .path
                .parent()
                .ok_or_else(|| anyhow::anyhow!("Missing permanent entry parent"))?;
            let _parents = path::pin_directories(parent_path)?;
            let parent = _parents
                .handles
                .last()
                .ok_or_else(|| anyhow::anyhow!("Missing captured parent pin"))?;
            if !entry.parent_identity.same_object(&parent.identity()?)
                || entry.parent_identity.attributes != parent.identity()?.attributes
            {
                bail!("Captured permanent-delete parent identity or attributes changed");
            }
            let key = (entry.identity.volume, entry.identity.id);
            let state = states.member(key)?;
            #[cfg(test)]
            if matches!(state.try_lock(), Err(std::sync::TryLockError::WouldBlock)) {
                verification_checkpoint("hardlink-state-contended", &entry.path)?;
            }
            let mut state = state
                .lock()
                .map_err(|_| anyhow::anyhow!("Shared file state unavailable"))?;
            if state.uncertain {
                bail!("A prior shared hardlink deletion has an unknown outcome");
            }
            let expected = state
                .changed
                .clone()
                .unwrap_or_else(|| entry.identity.clone());
            if let Some(guard) = state.guard.as_mut() {
                guard.upgrade_recycled(&entry.path, &entry.identity, &expected)?;
                if !guard.can_continue(&root.path) {
                    bail!(
                        "A shared hardlink without retained write guards cannot continue in another root"
                    );
                }
            }
            let fixed = PinnedFile::open(
                &entry.path,
                DELETE
                    | FILE_READ_ATTRIBUTES
                    | if entry.identity.is_directory() && !entry.identity.is_reparse() {
                        FILE_LIST_DIRECTORY
                    } else {
                        0
                    },
                1,
            )?;
            verify_handle(&fixed, &entry.path, &entry.identity)?;
            let actual = fixed.identity()?;
            if actual.creation_time != expected.creation_time
                || (!entry.identity.is_directory()
                    && (actual.last_write_time != expected.last_write_time
                        || actual.change_time != expected.change_time))
            {
                bail!(
                    "Permanent entry times changed after baseline capture: {}; volume={:016X}, id={}, expectedCreation={}, actualCreation={}, expectedLastWrite={}, actualLastWrite={}, expectedChange={}, actualChange={}",
                    entry.path.display(),
                    actual.volume,
                    hex::encode_upper(actual.id),
                    expected.creation_time,
                    actual.creation_time,
                    expected.last_write_time,
                    actual.last_write_time,
                    expected.change_time,
                    actual.change_time
                );
            }
            if let Some(bytes) = &entry.reparse {
                if native::read_reparse(fixed.raw())? != *bytes {
                    bail!("Permanent link metadata changed");
                }
            }
            if entry.identity.is_directory()
                && !entry.identity.is_reparse()
                && !native::directory_is_empty(fixed.raw())?
            {
                bail!("Directory membership changed or child deletion is not confirmed");
            }
            if let Some(setting) = setting {
                setting.revalidate(&root.path)?;
            }
            fixed.verify_named()?;
            #[cfg(test)]
            verification_checkpoint("permanent-child-pinned", &entry.path)?;
            if let Some(guard) = state.guard.as_ref() {
                let held = guard.base.identity()?;
                if !actual.same_object(&held)
                    || held.attributes != actual.attributes
                    || held.creation_time != actual.creation_time
                    || held.last_write_time != actual.last_write_time
                    || held.change_time != actual.change_time
                    || !guard.streams_match()?
                {
                    bail!(
                        "Retained hardlink or alternate streams changed before permanent deletion"
                    );
                }
            }
            *started = true;
            state.uncertain = true;
            security::delete_permanent_fixed(
                fixed.raw(),
                actual.attributes & FILE_ATTRIBUTE_READONLY != 0,
                state.guard.is_some(),
            )?;
            #[cfg(test)]
            verification_checkpoint("hardlink-delete-pending", &entry.path)?;
            if let Some(guard) = state.guard.as_ref() {
                let held = guard.base.identity()?;
                if held.change_time != actual.change_time
                    || held.last_write_time != actual.last_write_time
                    || !guard.streams_match()?
                {
                    bail!(
                        "Retained hardlink or alternate streams changed while deletion was pending"
                    );
                }
            }
            if let Some(snapshots) = snapshots {
                for snapshot in snapshots
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Queue snapshot unavailable"))?
                    .iter_mut()
                {
                    snapshot.release(&entry.path);
                }
            }
            entry.original.take();
            if index == 0 {
                root.original.take();
            }
            drop(fixed);
            verify_permanent_absence(&entry.path)?;
            if let Some(guard) = state.guard.as_ref() {
                let held = guard.base.identity()?;
                if !actual.same_object(&held)
                    || held.attributes != actual.attributes
                    || held.last_write_time != actual.last_write_time
                    || !guard.streams_match()?
                {
                    bail!(
                        "Retained hardlink or alternate streams changed during permanent deletion"
                    );
                }
                state.changed = Some(held);
            }
            state.uncertain = false;
            #[cfg(test)]
            verification_checkpoint("permanent-child-finished", &entry.path)?;
            Ok(())
        })();
        outcome.map_err(|error| error.context(FailureEntry(failure_path)))?;
    }
    Ok(())
}
fn verify_permanent_absence(path: &Path) -> Result<()> {
    (||->Result<()>{if inspect(path)?.is_some(){bail!("The source name is still present");}Ok(())})().with_context(||format!("Windows accepted a deletion request for the previously fixed object. Verification after Prunlet closed its deletion handle failed for entry {}",path.display()))
}
fn capture_tree(
    path: &Path,
    recursive: bool,
    tree: &mut Vec<TreeEntry>,
    limit: usize,
    enumerated: Option<(&FileIdentity, &native::DirectoryEntry)>,
) -> Result<()> {
    if tree.len() >= limit {
        bail!("Deletion snapshot exceeds its entry limit");
    }
    let _parents = path::pin_directories(
        path.parent()
            .ok_or_else(|| anyhow::anyhow!("Missing parent"))?,
    )?;
    let parent_identity = _parents
        .handles
        .last()
        .ok_or_else(|| anyhow::anyhow!("Missing captured parent"))?
        .identity()?;
    let original = PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7)?;
    let id = original.identity()?;
    verify_handle(&original, path, &id)?;
    if let Some((expected_parent, entry)) = enumerated {
        if !expected_parent.same_object(&parent_identity)
            || expected_parent.attributes != parent_identity.attributes
        {
            bail!("Captured child parent changed before baseline capture");
        }
        verify_enumerated_child(&id, expected_parent.volume, entry).with_context(|| {
            format!(
                "Cannot capture directory entry baseline '{}'",
                path.display()
            )
        })?;
    }
    kind(&id)?;
    let reparse = if id.is_reparse() {
        Some(native::read_reparse(original.raw())?)
    } else {
        None
    };
    let index = tree.len();
    tree.push(TreeEntry {
        path: path.to_owned(),
        parent_identity,
        original: Some(original),
        identity: id.clone(),
        reparse,
        children: vec![],
    });
    if id.is_directory() && !id.is_reparse() {
        let _directory = path::pin_directories(path)?;
        let enumerator = PinnedFile::open(path, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, 3)?;
        enumerator.reject_case_sensitive()?;
        let entries = native::directory_entries(enumerator.raw())?;
        if !recursive && !entries.is_empty() {
            bail!("Nonempty directories require explicit recursive deletion");
        }
        tree[index].children = entries.iter().map(|e| e.name.clone()).collect();
        tree[index].children.sort();
        for entry in entries {
            let child = path.join(&entry.name);
            capture_tree(&child, recursive, tree, limit, Some((&id, &entry))).map_err(|error| {
                // 最深の失敗entryを保持し、要求rootのDTOは変更しない。
                if error.downcast_ref::<FailureEntry>().is_some() {
                    error
                } else {
                    error.context(FailureEntry(child.clone()))
                }
            })?;
        }
    }
    Ok(())
}
// NTFSのdirectory列挙にはhardlink名に残った古い時刻が返る。
// 時刻の基準は、列挙IDと照合した後に保持した元handleからだけ取得する。
fn verify_enumerated_child(
    actual: &FileIdentity,
    volume: u64,
    entry: &native::DirectoryEntry,
) -> Result<()> {
    if actual.volume != volume
        || actual.id != entry.id
        || actual.attributes != entry.attributes
        || actual.reparse_tag != entry.reparse_tag
    {
        bail!(
            "Enumerated directory child identity, attributes or type changed before baseline capture. Baseline[volume={volume:016X},id={},attributes={:08X},tag={:08X}] Actual[volume={:016X},id={},attributes={:08X},tag={:08X}]",
            hex::encode_upper(entry.id),
            entry.attributes,
            entry.reparse_tag,
            actual.volume,
            hex::encode_upper(actual.id),
            actual.attributes,
            actual.reparse_tag
        );
    }
    Ok(())
}
pub struct Snapshot {
    entries: Vec<TreeEntry>,
    parent: PinnedFile,
}
impl Snapshot {
    pub fn root(&self) -> &Path {
        &self.entries[0].path
    }
    pub fn capture(path: &Path, recursive: bool) -> Result<Self> {
        let parent = PinnedFile::open(
            path.parent()
                .ok_or_else(|| anyhow::anyhow!("Missing snapshot parent"))?,
            FILE_READ_ATTRIBUTES,
            7,
        )?;
        let mut entries = vec![];
        capture_tree(path, recursive, &mut entries, 4095, None)?;
        let snapshot = Self { entries, parent };
        snapshot.verify()?;
        Ok(snapshot)
    }
    pub fn entry_count(&self) -> usize {
        self.entries.len() + 1
    }
    pub fn verify(&self) -> Result<()> {
        let expected = self.parent.initial_identity();
        verify_handle(&self.parent, &self.parent.path, expected)?;
        let current = PinnedFile::open(&self.parent.path, FILE_READ_ATTRIBUTES, 7)?;
        verify_handle(&current, &self.parent.path, expected)?;
        for entry in &self.entries {
            let Some(original) = entry.original.as_ref() else {
                continue;
            };
            let _parents = path::pin_directories(
                entry
                    .path
                    .parent()
                    .ok_or_else(|| anyhow::anyhow!("Missing snapshot parent"))?,
            )?;
            verify_handle(original, &entry.path, &entry.identity)?;
            let current = PinnedFile::open(&entry.path, FILE_READ_ATTRIBUTES, 7)?;
            verify_handle(&current, &entry.path, &entry.identity)?;
            if let Some(reparse) = &entry.reparse {
                if native::read_reparse(current.raw())? != *reparse {
                    bail!("Queued link metadata changed");
                }
            }
            if entry.identity.is_directory() && !entry.identity.is_reparse() {
                if current.identity()?.change_time != entry.identity.change_time {
                    bail!("Queued directory changed");
                }
                let _directories = path::pin_directories(&entry.path)?;
                let current =
                    PinnedFile::open(&entry.path, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, 3)?;
                let mut children = native::directory_names(current.raw())?;
                children.sort();
                if children != entry.children {
                    bail!("Queued directory membership changed");
                }
            }
        }
        Ok(())
    }
    pub fn probe(&self) -> Result<()> {
        self.verify()?;
        for entry in &self.entries {
            if entry.original.is_none() {
                continue;
            }
            let _parents = path::pin_directories(
                entry
                    .path
                    .parent()
                    .ok_or_else(|| anyhow::anyhow!("Missing probe parent"))?,
            )?;
            let fixed = PinnedFile::open(&entry.path, DELETE | FILE_READ_ATTRIBUTES, 1)?;
            verify_handle(&fixed, &entry.path, &entry.identity)?;
        }
        self.verify()
    }
    pub fn release(&mut self, path: &Path) {
        for entry in &mut self.entries {
            if entry.path == path {
                entry.original.take();
            }
        }
    }
}

#[cfg(test)]
pub(super) fn verification_native_contract(case: &str, fixture_root: &str) -> Result<Value> {
    let fixture = path::absolute(Path::new(fixture_root))?;
    let _parents = path::pin_directories(&fixture)?;
    match case {
        case if case.starts_with("file-root-pin-") => {
            return tests::root_pin_contract(case.trim_start_matches("file-root-pin-"), &fixture);
        }
        case if case.starts_with("file-before-recycle-") => {
            return tests::before_recycle_contract(
                case.trim_start_matches("file-before-recycle-"),
                &fixture,
            );
        }
        "file-hardlink-entry-times" => tests::native_hardlink_entry_time_contract()?,
        "file-hardlink-stream-guards" => tests::native_hardlink_stream_guard_contract()?,
        "file-parent-replacement" => {
            tests::native_permanent_parent_replacement_preserves_both_aliases()?
        }
        "file-post-shell-result-fault" => tests::native_post_shell_at(&fixture)?,
        "file-immediate-delete-replacement" => {
            return tests::immediate_replacement_contract(&fixture);
        }
        "file-size-permanent-spawn-fault" => {
            return tests::shell_permanent_spawn_fault(&fixture, false);
        }
        "file-setting-permanent-spawn-fault" => {
            return tests::shell_permanent_spawn_fault(&fixture, true);
        }
        "file-oversize-replace-root" => {
            return tests::oversize_root_race_contract("replace", &fixture);
        }
        "file-oversize-lock-root" => return tests::oversize_root_race_contract("lock", &fixture),
        case if case.starts_with("file-oversize-") => {
            return tests::oversize_native_contract(
                case.trim_start_matches("file-oversize-"),
                &fixture,
            );
        }
        "file-immediate-delete-setting" => {
            let setting = ImmediateDeleteSetting::capture(&fixture);
            return Ok(match setting {
                Some(setting) => {
                    setting.revalidate(&fixture)?;
                    serde_json::json!({"passed":true,"confirmed":true,"sid":setting.sid(),"volume":setting.volume(),"path":fixture})
                }
                None => serde_json::json!({"passed":true,"confirmed":false,"path":fixture}),
            });
        }
        _ => bail!("Unknown native file verification case: {case}"),
    }
    Ok(
        serde_json::json!({"passed":true,"case":case,"scope":"actual Windows native handles and candidate-source cfg(test) Core; shipping CLI/MCP verified separately","fixtureRoot":fixture,"retainedTempRoot":std::env::var_os("TEMP").map(PathBuf::from),"productFaultInjection":false}),
    )
}
#[cfg(test)]
pub(super) fn verification_independence(
    case: &str,
    fixture_root: &str,
    config: &Config,
) -> Result<Value> {
    tests::independence_contract(case, &path::absolute(Path::new(fixture_root))?, config)
}
#[cfg(test)]
mod tests {
    use super::*;

    // 既存fixtureのCore境界だけを実行し、実Shell報告と名前・IDを確認する。
    pub(super) fn independence_contract(
        case: &str,
        fixture: &Path,
        config: &Config,
    ) -> Result<Value> {
        use std::{
            os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
            sync::{
                Condvar,
                atomic::{AtomicBool, AtomicUsize, Ordering},
            },
            time::Duration,
        };
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        let _fixture = path::pin_directories(fixture)?;
        let is_parallel = case == "file-independent-roots";
        anyhow::ensure!(
            is_parallel || case == "file-recycled-alias-independent",
            "Unknown independence case"
        );
        let paths = if is_parallel {
            vec![fixture.join("root-0"), fixture.join("root-1")]
        } else {
            vec![
                fixture.join("recycled-small.txt"),
                fixture.join("huge-root"),
            ]
        };
        let first_child = paths[0].join("small.txt");
        let second_child = if is_parallel {
            paths[1].join("small.txt")
        } else {
            paths[1].join("small.txt")
        };
        let id = |path: &Path| -> Result<FileIdentity> {
            Ok(PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7)?.identity()?)
        };
        anyhow::ensure!(
            ImmediateDeleteSetting::capture(&paths[1]).is_none(),
            "Independence requires a recyclable fixture volume"
        );
        let alias_path = fixture.join("external-alias.txt");
        let alias_id = if is_parallel {
            anyhow::ensure!(
                ImmediateDeleteSetting::capture(&paths[0]).is_none(),
                "Both roots require a recyclable fixture volume"
            );
            let first = id(&first_child)?;
            for candidate in [
                &second_child,
                &paths[1].join("huge-sparse"),
                &paths[1].join("external-link"),
            ] {
                anyhow::ensure!(
                    !first.same_object(&id(candidate)?),
                    "Independent root child identities must be distinct"
                );
            }
            None
        } else {
            let original = id(&paths[0])?;
            let alias = id(&alias_path)?;
            anyhow::ensure!(
                original.same_object(&alias)
                    && alias.links == 2
                    && !id(&second_child)?.same_object(&alias),
                "Recycled alias fixture identities differ"
            );
            Some(alias)
        };
        let shell = Arc::new(AtomicUsize::new(0));
        let attempted = Arc::new(AtomicBool::new(false));
        let identity_matched = Arc::new(AtomicBool::new(false));
        let gate = Arc::new((Mutex::new((false, false, false)), Condvar::new()));
        let shell_gate = Arc::new((Mutex::new(BTreeSet::<PathBuf>::new()), Condvar::new()));
        let shell_gate_cb = shell_gate.clone();
        let shell_cb = shell.clone();
        let attempted_cb = attempted.clone();
        let identity_cb = identity_matched.clone();
        let gate_cb = gate.clone();
        let targets = paths.clone();
        let first = first_child.clone();
        let second = second_child.clone();
        let alias = alias_path.clone();
        let baseline = alias_id.clone();
        *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, current| {
            if is_parallel && phase == "before-shell" && targets.iter().any(|p| p == current) {
                let mut ready = shell_gate_cb
                    .0
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Shell gate unavailable"))?;
                anyhow::ensure!(
                    ready.insert(current.to_owned()),
                    "Shell pre-submit checkpoint repeated"
                );
                shell_gate_cb.1.notify_all();
                let (ready, timed) = shell_gate_cb
                    .1
                    .wait_timeout_while(ready, Duration::from_secs(10), |ready| ready.len() < 2)
                    .map_err(|_| anyhow::anyhow!("Shell gate unavailable"))?;
                anyhow::ensure!(
                    !timed.timed_out() || ready.len() == 2,
                    "Both independent Shell workers did not reach submission"
                );
            }
            if phase == "shell-size-permanent-permitted" && targets.iter().any(|p| p == current) {
                shell_cb.fetch_add(1, Ordering::SeqCst);
            }
            if phase != "permanent-child-pinned" {
                return Ok(());
            }
            if is_parallel && (current == first || current == second) {
                anyhow::ensure!(
                    shell_cb.load(Ordering::SeqCst) == 2,
                    "Both actual size refusals must precede disposition"
                );
                let mut state = gate_cb
                    .0
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Pin gate unavailable"))?;
                if current == first {
                    anyhow::ensure!(!state.0, "First pin checkpoint repeated");
                    state.0 = true;
                    gate_cb.1.notify_all();
                    let (mut state, timed) = gate_cb
                        .1
                        .wait_timeout_while(state, Duration::from_secs(10), |s| !s.1)
                        .map_err(|_| anyhow::anyhow!("Pin gate unavailable"))?;
                    anyhow::ensure!(
                        !timed.timed_out() || state.1,
                        "Independent second child did not pin while first was held"
                    );
                    state.2 = true;
                    gate_cb.1.notify_all();
                } else {
                    let (mut state, timed) = gate_cb
                        .1
                        .wait_timeout_while(state, Duration::from_secs(10), |s| !s.0)
                        .map_err(|_| anyhow::anyhow!("Pin gate unavailable"))?;
                    anyhow::ensure!(
                        !timed.timed_out() || state.0,
                        "First child pin was not observed"
                    );
                    anyhow::ensure!(
                        !state.1 && !state.2,
                        "Independent child did not arrive while first remained pinned"
                    );
                    state.1 = true;
                    gate_cb.1.notify_all();
                }
            } else if !is_parallel && current == second {
                anyhow::ensure!(
                    shell_cb.load(Ordering::SeqCst) == 1 && !targets[0].exists(),
                    "Shell results were not completed before unrelated child pin"
                );
                anyhow::ensure!(
                    !attempted_cb.swap(true, Ordering::SeqCst),
                    "Alias open checkpoint repeated"
                );
                let writer = std::fs::OpenOptions::new()
                    .write(true)
                    .share_mode(7)
                    .open(&alias)?;
                let actual = native::identity(writer.as_raw_handle())?;
                anyhow::ensure!(
                    baseline
                        .as_ref()
                        .is_some_and(|expected| expected.same_object(&actual)),
                    "Surviving alias identity changed"
                );
                identity_cb.store(true, Ordering::SeqCst);
                drop(writer);
            }
            Ok(())
        }));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                FILE_CHECKPOINT.lock().unwrap().take();
            }
        }
        let reset = Reset;
        let result = delete(config, &paths, false, true, None, None)?;
        drop(reset);
        let observed = *gate
            .0
            .lock()
            .map_err(|_| anyhow::anyhow!("Pin gate unavailable"))?;
        if is_parallel {
            anyhow::ensure!(
                shell.load(Ordering::SeqCst) == 2
                    && shell_gate
                        .0
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Shell gate unavailable"))?
                        .len()
                        == 2
                    && observed == (true, true, true),
                "Independent simultaneous child pins were not verified"
            );
            anyhow::ensure!(
                result.items.len() == 2
                    && result
                        .items
                        .iter()
                        .zip(&paths)
                        .all(|(item, path)| item.path == path.to_string_lossy()
                            && item.status == "permanently_deleted"
                            && !path.exists()),
                "Independent roots did not complete in input order: {result:?}"
            );
        } else {
            anyhow::ensure!(
                shell.load(Ordering::SeqCst) == 1
                    && attempted.load(Ordering::SeqCst)
                    && identity_matched.load(Ordering::SeqCst),
                "Surviving alias write-open was not verified"
            );
            anyhow::ensure!(
                result.items.len() == 2
                    && result.items[0].path == paths[0].to_string_lossy()
                    && result.items[0].status == "recycled"
                    && result.items[1].path == paths[1].to_string_lossy()
                    && result.items[1].status == "permanently_deleted"
                    && !paths[0].exists()
                    && !paths[1].exists(),
                "Mixed Shell outcomes differ: {result:?}"
            );
        }
        Ok(
            serde_json::json!({"passed":true,"result":result,"sizeRefusals":shell.load(Ordering::SeqCst),"parallelShellReady":is_parallel && shell_gate.0.lock().map_err(|_| anyhow::anyhow!("Shell gate unavailable"))?.len() == 2,"firstPinned":observed.0,"secondPinnedWhileFirstHeld":observed.1,"firstReleased":observed.2,"aliasWriteOpen":attempted.load(Ordering::SeqCst),"aliasIdentityMatched":identity_matched.load(Ordering::SeqCst),"scope":"actual Shell plus same-source cfg(test) Core; shipping CLI/MCP verified separately"}),
        )
    }

    // 外部fixtureの実体を通常preflightに渡し、製品と同じDELETE handleを観測する。
    pub(super) fn root_pin_contract(kind: &str, fixture: &Path) -> Result<Value> {
        use windows_sys::Win32::Foundation::HANDLE;
        #[link(name = "ntdll")]
        unsafe extern "system" {
            fn NtQueryObject(
                handle: HANDLE,
                class: u32,
                info: *mut std::ffi::c_void,
                length: u32,
                returned: *mut u32,
            ) -> i32;
        }
        anyhow::ensure!(
            matches!(
                kind,
                "file" | "directory" | "child" | "read-denied-delete-allowed"
            ),
            "Unknown root pin fixture"
        );
        let base = if kind == "child" {
            fixture.join("parent")
        } else {
            fixture.to_owned()
        };
        let source = base.join("source");
        let moved = base.join("moved");
        anyhow::ensure!(!moved.exists(), "Fixture destination must be absent");
        let config = Config {
            path: fixture.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: fixture.join("metadata").to_string_lossy().into_owned(),
                ..Default::default()
            },
        };
        let prepared = prepare(&config, &source, true, false)?.context("Missing fixed fixture")?;
        anyhow::ensure!(
            prepared.identity.is_directory() == (kind == "directory")
                && !prepared.identity.is_reparse(),
            "Fixture type differs"
        );
        let original_id = native::legacy_identity(
            prepared
                .original
                .as_ref()
                .context("Missing original pin")?
                .raw(),
        )?;
        let fixed = prepared.root.as_ref().context("Missing delete pin")?;
        let mut object = [0u8; 56];
        let mut returned = 0u32;
        let status = unsafe {
            NtQueryObject(
                fixed.raw(),
                0,
                object.as_mut_ptr().cast(),
                object.len() as u32,
                &mut returned,
            )
        };
        anyhow::ensure!(
            status >= 0 && returned == 56,
            "NtQueryObject failed: status={status}, length={returned}"
        );
        let granted = u32::from_ne_bytes(object[4..8].try_into()?);
        anyhow::ensure!(
            granted & (DELETE | FILE_READ_ATTRIBUTES) == DELETE | FILE_READ_ATTRIBUTES
                && granted & (READ_CONTROL | FILE_READ_DATA) == 0,
            "Delete pin has unexpected access: {granted:08X}"
        );
        let rename = std::fs::rename(&source, &moved).expect_err("Pinned source was renamed");
        anyhow::ensure!(
            rename.raw_os_error() == Some(32),
            "Pinned rename failed for unexpected reason: {rename}"
        );
        fixed.verify_named()?;
        drop(prepared);
        std::fs::rename(&source, &moved).context("Rename after pin release failed")?;
        let after = PinnedFile::open(&moved, FILE_READ_ATTRIBUTES, 7)?;
        anyhow::ensure!(
            native::legacy_identity(after.raw())? == original_id,
            "Fixture identity changed after rename"
        );
        Ok(
            serde_json::json!({"passed":true,"kind":kind,"source":source,"moved":moved,"originalId":original_id,"grantedAccess":granted,"renameWhileHeldError":32,"renameAfterReleaseSucceeded":true,"scope":"same-source cfg(test) actual preflight, not shipping CLI/MCP"}),
        )
    }

    #[test]
    fn access_denial_diagnostic_preserves_native_code_and_uncertain_cause() {
        let error = anyhow::Error::new(std::io::Error::from_raw_os_error(5))
            .context("Verification after deletion handle closed failed");
        let text = diagnose_with(Path::new(r"D:\owned\pending.dat"), &error, false);
        for expected in [
            "native error 5",
            "HRESULT 0x80070005 (derived from Win32 error 5)",
            r#"Target: "D:\\owned\\pending.dat"."#,
            "error 5 alone does not identify the cause",
            "pending deletion",
            "No permissions or owner were changed",
            "Verification after deletion handle closed failed",
        ] {
            assert!(
                text.contains(expected),
                "Missing diagnostic {expected}: {text}"
            );
        }
        assert!(!text.contains("Current users"));
        assert!(!text.contains("0x80131620"));
        let child = Path::new(r"D:\owned\nested\fixture.dll");
        let nested_error = anyhow::Error::new(std::io::Error::from_raw_os_error(5))
            .context(FailureEntry(child.to_owned()));
        let nested = diagnose_with(Path::new(r"D:\owned"), &nested_error, false);
        assert!(nested.contains(r#"Target: "D:\\owned"."#));
        assert!(nested.contains(&format!(
            "Failure entry: {}",
            serde_json::json!(child.to_string_lossy())
        )));
        for (code, role, label) in [
            (0x80270021u32, "source", "COPYENGINE_E_ACCESS_DENIED_SRC"),
            (0x80270022, "destination", "COPYENGINE_E_ACCESS_DENIED_DEST"),
        ] {
            let error = anyhow::anyhow!(
                "Windows did not confirm recycling (HRESULT 0x{code:08X}); the operation was not retried"
            );
            let text = diagnose_with(Path::new(r"D:\owned\denied.dat"), &error, false);
            assert!(
                text.contains(&format!("Windows denied access to the {role}"))
                    && text.contains(label)
                    && text.contains("does not identify a locking process"),
                "Missing qualified Shell access-denial hint: {text}"
            );
        }
    }
    fn fixture(label: &str) -> Result<PathBuf> {
        let temp = PathBuf::from(
            std::env::var_os("TEMP").ok_or_else(|| anyhow::anyhow!("TEMP is required"))?,
        );
        let temp = path::absolute(&temp)?;
        if !temp.to_string_lossy().starts_with("D:\\") {
            bail!("Native fixture TEMP must be external D:");
        }
        let _parents = path::pin_directories(&temp)?;
        let root = temp.join(format!("{label}-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&root)?;
        eprintln!(
            "Retained native fixture for Prunlet cleanup: {}",
            root.display()
        );
        Ok(root)
    }
    pub(super) fn before_recycle_contract(mode: &str, root: &Path) -> Result<Value> {
        use std::{
            io::{Read, Write},
            os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
            sync::atomic::{AtomicUsize, Ordering},
        };
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        if !["replace", "alias", "attributes", "large"].contains(&mode) {
            bail!("Unknown before-recycle mode");
        }
        let _parents = path::pin_directories(root)?;
        let data = root.join(format!("before-recycle-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&data)?;
        eprintln!("Retained before-recycle fixture: {}", data.display());
        let source = data.join("source.txt");
        let moved = data.join("original-moved.txt");
        let alias = data.join("original-alias.txt");
        let replacement_alias = data.join("replacement-alias.txt");
        let prefix = b"owned before-recycle original";
        let large = mode == "large";
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .access_mode(
                windows_sys::Win32::Foundation::GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
            )
            .open(&source)?;
        if large {
            let mut returned = 0;
            if unsafe {
                windows_sys::Win32::System::IO::DeviceIoControl(
                    file.as_raw_handle(),
                    0x900C4,
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    0,
                    &mut returned,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        file.write_all(prefix)?;
        if large {
            file.set_len(1u64 << 40)?;
        }
        file.sync_all()?;
        drop(file);
        if !large {
            std::fs::write(format!("{}:race", source.display()), b"owned original ADS")?;
            std::fs::hard_link(&source, &alias)?;
        }
        let original = PinnedFile::open(&source, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
        let before = original.identity()?;
        let original_id = native::legacy_identity(original.raw())?;
        let security_bytes = security::read_member_security(original.raw())?;
        let original_streams = native::named_streams(original.raw())?;
        let mut standard: FILE_STANDARD_INFO = unsafe { std::mem::zeroed() };
        if unsafe {
            GetFileInformationByHandleEx(
                original.raw(),
                FileStandardInfo,
                (&mut standard as *mut FILE_STANDARD_INFO).cast(),
                std::mem::size_of::<FILE_STANDARD_INFO>() as u32,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        if large
            && (before.size != 1u64 << 40
                || standard.AllocationSize < 0
                || standard.AllocationSize > 1024 * 1024)
        {
            bail!("Sparse original logical/allocation proof failed");
        }
        if ImmediateDeleteSetting::capture(&source).is_some() {
            bail!("Before-recycle probe requires a recyclable fixture volume");
        }
        let metadata_scope = fixture("before-recycle-metadata")?;
        let metadata = metadata_scope.join("metadata");
        std::fs::create_dir(&metadata)?;
        let config = Config {
            path: metadata_scope.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let count = Arc::new(AtomicUsize::new(0));
        let observed = Arc::new(Mutex::new(serde_json::json!({})));
        let checkpoint_count = count.clone();
        let evidence = observed.clone();
        let selected = source.clone();
        let parked = moved.clone();
        let replacement_anchor = replacement_alias.clone();
        let selected_mode = mode.to_owned();
        *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, path| {
            if phase == "before-shell" && path == selected {
                if checkpoint_count.fetch_add(1, Ordering::SeqCst) != 0 {
                    bail!("Before-recycle checkpoint repeated");
                }
                std::fs::rename(&selected, &parked)?;
                if selected_mode == "alias" {
                    std::fs::write(&replacement_anchor, b"owned before-recycle replacement")?;
                    std::fs::hard_link(&replacement_anchor, &selected)?;
                } else {
                    std::fs::write(&selected, b"owned before-recycle replacement")?;
                }
                std::fs::write(
                    format!("{}:race", selected.display()),
                    b"owned replacement ADS",
                )?;
                if selected_mode == "attributes" {
                    let wide = native::win32_path(&selected)?;
                    if unsafe {
                        SetFileAttributesW(
                            wide.as_ptr(),
                            FILE_ATTRIBUTE_HIDDEN
                                | FILE_ATTRIBUTE_READONLY
                                | FILE_ATTRIBUTE_ARCHIVE,
                        )
                    } == 0
                    {
                        return Err(std::io::Error::last_os_error().into());
                    }
                }
                let replacement =
                    PinnedFile::open(&selected, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
                let identity = replacement.identity()?;
                *evidence.lock().unwrap() = serde_json::json!({"replacementId":native::legacy_identity(replacement.raw())?,"replacementAttributes":identity.attributes,"replacementLinks":identity.links,"replacementSecurityHex":hex::encode(security::read_member_security(replacement.raw())?)});
            }
            if phase == "shell-size-permanent-permitted" && path == selected {
                evidence.lock().unwrap()["actualWindowsSizeRefusal"] = serde_json::json!(true);
            }
            if phase == "shell-result-observed" {
                // 他の並列テストのShell結果には介入せず、この置換IDの証拠だけを収集する。
                let Ok(fixed) = PinnedFile::open(path, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)
                else {
                    return Ok(());
                };
                let Ok(actual_id) = native::legacy_identity(fixed.raw()) else {
                    return Ok(());
                };
                let mut proof = evidence.lock().unwrap();
                if proof["replacementId"] != actual_id {
                    return Ok(());
                }
                proof["destination"] = serde_json::json!(path);
                proof["destinationId"] = serde_json::json!(actual_id);
                proof["destinationAttributes"] = serde_json::json!(fixed.identity()?.attributes);
                proof["destinationSecurityHex"] =
                    serde_json::json!(hex::encode(security::read_member_security(fixed.raw())?));
            }
            Ok(())
        }));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                FILE_CHECKPOINT.lock().unwrap().take();
            }
        }
        let _reset = Reset;
        let result = delete(&config, &[source.clone()], false, false, None, None)?;
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert_eq!(result.items[0].status, "ambiguous");
        let warning = result.items[0].error.as_deref().unwrap_or("");
        assert!(warning.contains("The operation was not retried"));
        assert!(warning.contains("Inspect source and Windows Recycle Bin before further action"));
        let mut proof = observed.lock().unwrap().clone();
        assert!(proof["replacementId"].is_string());
        assert_ne!(proof["replacementId"], original_id);
        if large {
            assert_eq!(proof["actualWindowsSizeRefusal"], serde_json::json!(true));
            assert!(
                proof.get("destination").is_none(),
                "Large replacement must remain at the original source name"
            );
            assert!(source.exists());
        }
        let retained = PinnedFile::open(&moved, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
        let after = retained.identity()?;
        assert!(before.same_object(&after));
        assert_eq!(before.attributes, after.attributes);
        assert_eq!(before.size, after.size);
        assert_eq!(before.links, after.links);
        assert_eq!(original_streams, native::named_streams(retained.raw())?);
        assert_eq!(
            security_bytes,
            security::read_member_security(retained.raw())?
        );
        drop(retained);
        let mut bytes = vec![0; prefix.len()];
        std::fs::File::open(&moved)?.read_exact(&mut bytes)?;
        assert_eq!(bytes, prefix);
        if !large {
            assert_eq!(
                std::fs::read(format!("{}:race", moved.display()))?,
                b"owned original ADS"
            );
            assert_eq!(std::fs::read(&alias)?, prefix);
            assert!(
                before.same_object(&PinnedFile::open(&alias, FILE_READ_ATTRIBUTES, 7)?.identity()?)
            );
        }
        let replacement_location = if let Some(destination) = proof["destination"].as_str() {
            assert!(!source.exists());
            assert_eq!(proof["destinationId"], proof["replacementId"]);
            assert_eq!(
                proof["destinationAttributes"],
                proof["replacementAttributes"]
            );
            PathBuf::from(destination)
        } else {
            source.clone()
        };
        let fixed = PinnedFile::open(
            &replacement_location,
            FILE_READ_ATTRIBUTES | READ_CONTROL,
            7,
        )?;
        assert_eq!(
            native::legacy_identity(fixed.raw())?,
            proof["replacementId"]
        );
        if large {
            assert_eq!(replacement_location, source);
            proof["retainedAtSource"] = serde_json::json!(true);
            proof["sourcePath"] = serde_json::json!(source);
        }
        assert_eq!(
            serde_json::json!(fixed.identity()?.attributes),
            proof["replacementAttributes"]
        );
        assert_eq!(
            serde_json::json!(fixed.identity()?.links),
            proof["replacementLinks"]
        );
        // Binへの移動時にWindowsが継承ACLを変えるため、移動後のsecurityを再照合する。
        let expected_security = if proof["destination"].is_string() {
            &proof["destinationSecurityHex"]
        } else {
            &proof["replacementSecurityHex"]
        };
        assert_eq!(
            hex::encode(security::read_member_security(fixed.raw())?),
            *expected_security
        );
        assert_eq!(
            std::fs::read(&replacement_location)?,
            b"owned before-recycle replacement"
        );
        assert_eq!(native::named_streams(fixed.raw())?.len(), 1);
        assert_eq!(
            std::fs::read(format!("{}:race", replacement_location.display()))?,
            b"owned replacement ADS"
        );
        if mode == "alias" {
            assert_eq!(
                std::fs::read(&replacement_alias)?,
                b"owned before-recycle replacement"
            );
        }
        drop(fixed);
        drop(original);
        let cleanup = if large {
            shrink_owned_sparse(&moved, &before, &security_bytes, prefix)?
        } else {
            serde_json::Value::Null
        };
        Ok(
            serde_json::json!({"passed":true,"mode":mode,"checkpointCount":1,"result":result,"originalId":original_id,"originalPath":moved,"originalAlias":if large {None}else{Some(alias)},"originalPreserved":true,"replacementPreserved":true,"replacement":proof,"largeSparse":large,"logicalSizeBefore":before.size,"allocationSizeBefore":standard.AllocationSize,"boundedOwnedSparseCleanup":cleanup,"retainedFixtureRoot":data,"metadataRoot":metadata,"productFaultInjection":false,"scope":"candidate-source cfg(test) Core and actual Windows Shell; fixtures and Bin items retained without deletion retry"}),
        )
    }
    #[test]
    fn native_before_recycle_replacement_retains_both_identities() -> Result<()> {
        let root = std::env::var_os("PRUNLET_NATIVE_RECYCLE_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("USERPROFILE").unwrap_or_default())
                    .join("PrunletValidation")
                    .join("rust-migration-20261103")
            });
        for mode in ["replace", "alias", "attributes", "large"] {
            let result = before_recycle_contract(mode, &root)?;
            eprintln!("Retained before-recycle proof: {result}");
        }
        Ok(())
    }
    pub(super) fn shell_permanent_spawn_fault(root: &Path, immediate: bool) -> Result<Value> {
        use std::{
            io::{Read, Write},
            os::windows::io::AsRawHandle,
            sync::atomic::{AtomicUsize, Ordering},
        };
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        let _parents = path::pin_directories(root)?;
        let scope = root.join(format!(
            "shell-permanent-spawn-fault-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir(&scope)?;
        if immediate {
            ImmediateDeleteSetting::capture(&scope).ok_or_else(||anyhow::anyhow!("Explicit immediate-delete setting must already be confirmed on the supplied fixture volume"))?.revalidate(&scope)?;
        }
        let source = scope.join("owned-source");
        let alias = scope.join("external-alias");
        let prefix = b"owned sparse prefix";
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&source)?;
        if !immediate {
            let mut returned = 0;
            if unsafe {
                windows_sys::Win32::System::IO::DeviceIoControl(
                    file.as_raw_handle(),
                    0x900C4,
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    0,
                    &mut returned,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        file.write_all(prefix)?;
        if !immediate {
            file.set_len(1u64 << 40)?;
        }
        file.sync_all()?;
        drop(file);
        std::fs::hard_link(&source, &alias)?;
        let ads = PathBuf::from(format!("{}:retained", source.display()));
        let alias_ads = PathBuf::from(format!("{}:retained", alias.display()));
        std::fs::write(&ads, b"owned retained stream")?;
        let original = PinnedFile::open(&source, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
        let before = original.identity()?;
        let acl = security::read_member_security(original.raw())?;
        let streams = native::named_streams(original.raw())?;
        let mut standard: FILE_STANDARD_INFO = unsafe { std::mem::zeroed() };
        if unsafe {
            GetFileInformationByHandleEx(
                original.raw(),
                FileStandardInfo,
                (&mut standard as *mut FILE_STANDARD_INFO).cast(),
                std::mem::size_of::<FILE_STANDARD_INFO>() as u32,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        assert_eq!(before.links, 2);
        assert_eq!(
            before.size,
            if immediate {
                prefix.len() as u64
            } else {
                1u64 << 40
            }
        );
        assert!(standard.AllocationSize >= 0 && standard.AllocationSize <= 1024 * 1024);
        drop(original);
        let metadata_scope = fixture("shell-permanent-spawn-fault-metadata")?;
        let metadata = metadata_scope.join("metadata");
        std::fs::create_dir(&metadata)?;
        let config = Config {
            path: metadata_scope.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let count = Arc::new(AtomicUsize::new(0));
        let observed = count.clone();
        let selected = source.clone();
        *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, path| {
            if path == selected
                && phase
                    == if immediate {
                        "shell-setting-permanent-permitted"
                    } else {
                        "shell-size-permanent-permitted"
                    }
            {
                observed.fetch_add(1, Ordering::SeqCst);
            }
            Ok(())
        }));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                FILE_CHECKPOINT.lock().unwrap().take();
            }
        }
        let _reset = Reset;
        let fault = native::process::test_faults::fail_spawn("file-permanent-worker", 1, None);
        let result = delete(&config, &[source.clone()], false, false, None, None)?;
        drop(fault);
        assert_eq!(
            count.load(Ordering::SeqCst),
            1,
            "Required actual Shell refusal was not observed"
        );
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].status, "ambiguous");
        let error = result.items[0].error.as_deref().unwrap_or("");
        for expected in [
            "could not be started",
            "not retried",
            "source",
            "Windows Recycle Bin",
            "do not resend",
        ] {
            assert!(
                error.contains(expected),
                "Missing post-Shell failure diagnostic {expected}: {error}"
            );
        }
        for path in [&source, &alias] {
            let fixed = PinnedFile::open(path, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
            assert_eq!(before, fixed.identity()?);
            assert_eq!(acl, security::read_member_security(fixed.raw())?);
            assert_eq!(streams, native::named_streams(fixed.raw())?);
            let mut bytes = vec![0; prefix.len()];
            std::fs::File::open(path)?.read_exact(&mut bytes)?;
            assert_eq!(bytes, prefix);
        }
        assert_eq!(std::fs::read(&ads)?, b"owned retained stream");
        assert_eq!(std::fs::read(&alias_ads)?, b"owned retained stream");
        Ok(
            serde_json::json!({"passed":true,"result":result,"actualWindowsSizeRefusal":!immediate,"actualConfiguredImmediateRefusal":immediate,"shellDispositionCount":1,"permanentWorkerNotStarted":true,"sourceAndExternalAliasPreserved":true,"identityAttributesAclSizeAndStreamsUnchanged":true,"logicalSize":before.size,"allocationSize":standard.AllocationSize,"retainedFixtureRoot":scope,"retainedMetadataRoot":metadata,"resizingOrDeletionResent":false,"productFaultInjection":false}),
        )
    }
    #[test]
    fn native_spawn_failure_keeps_completed_effects_and_unstarted_targets() -> Result<()> {
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        let base = PathBuf::from(r"C:\Users\IMT\PrunletValidation\rust-migration-20261103");
        let _parents = path::pin_directories(&base)?;
        let data = base.join(format!("spawn-fault-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&data)?;
        let metadata_scope = fixture("spawn-fault-metadata")?;
        let metadata = metadata_scope.join("metadata");
        std::fs::create_dir(&metadata)?;
        let config = Config {
            path: metadata_scope.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        for permanent in [false, true] {
            let mut paths = vec![];
            for index in 0..3 {
                let parent = data.join(format!(
                    "{}-{index}",
                    if permanent { "permanent" } else { "shell" }
                ));
                std::fs::create_dir(&parent)?;
                let target = parent.join(if permanent { "con.txt" } else { "owned.dat" });
                let native_path = PathBuf::from(format!(r"\\?\{}", target.display()));
                std::fs::write(&native_path, b"owned unstarted target must survive")?;
                paths.push(target);
            }
            let unstarted = PinnedFile::open(&paths[1], FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
            let before = unstarted.identity()?;
            let acl = security::read_member_security(unstarted.raw())?;
            drop(unstarted);
            let completed = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
            let notified = completed.clone();
            let first = paths[0].clone();
            *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, path| {
                if path == first
                    && phase
                        == if permanent {
                            "permanent-root-finished"
                        } else {
                            "shell-result-verified"
                        }
                {
                    *notified.0.lock().unwrap() = true;
                    notified.1.notify_all();
                }
                Ok(())
            }));
            struct Reset;
            impl Drop for Reset {
                fn drop(&mut self) {
                    FILE_CHECKPOINT.lock().unwrap().take();
                }
            }
            let _reset = Reset;
            let fault = native::process::test_faults::fail_spawn(
                if permanent {
                    "file-permanent-worker"
                } else {
                    "file-shell-worker"
                },
                2,
                Some(Box::new(move || {
                    let (done, timed) = completed
                        .1
                        .wait_timeout_while(
                            completed.0.lock().unwrap(),
                            std::time::Duration::from_secs(10),
                            |done| !*done,
                        )
                        .unwrap();
                    assert!(
                        !timed.timed_out() && *done,
                        "First actual effect did not precede the injected second-thread failure"
                    );
                })),
            );
            let result = delete(&config, &paths, false, false, None, None)?;
            drop(fault);
            assert_eq!(result.items.len(), 3);
            assert_eq!(
                result.items[0].status,
                if permanent {
                    "permanently_deleted"
                } else {
                    "recycled"
                }
            );
            assert_eq!(result.items[1].status, "failed");
            assert_eq!(result.items[2].status, result.items[0].status);
            assert!(
                result.items[1]
                    .error
                    .as_deref()
                    .unwrap_or("")
                    .contains("could not be started")
            );
            let retained = PinnedFile::open(&paths[1], FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
            assert_eq!(before, retained.identity()?);
            assert_eq!(acl, security::read_member_security(retained.raw())?);
            assert_eq!(
                std::fs::read(PathBuf::from(format!(r"\\?\{}", paths[1].display())))?,
                b"owned unstarted target must survive"
            );
            assert!(inspect(&paths[0])?.is_none() && inspect(&paths[2])?.is_none());
            for (item, path) in result.items.iter().zip(&paths) {
                assert_eq!(item.path, path.to_string_lossy());
            }
            eprintln!(
                "Native resource-failure proof: permanent={permanent}, first actual effect preceded spawn failure, completed DTOs retained, unstarted object ID/content/ACL/attributes preserved: {result:?}"
            );
        }
        Ok(())
    }
    #[test]
    pub(super) fn native_hardlink_entry_time_contract() -> Result<()> {
        let temp = PathBuf::from(
            std::env::var_os("TEMP").ok_or_else(|| anyhow::anyhow!("TEMP is required"))?,
        );
        let temp = path::absolute(&temp)?;
        if !temp.to_string_lossy().starts_with("D:\\") {
            bail!("Native fixture TEMP must be on external D:");
        }
        let _parents = path::pin_directories(&temp)?;
        let root = temp.join(format!("hardlink-time-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&root)?;
        let first = root.join("first");
        let second = root.join("second");
        std::fs::create_dir(&first)?;
        std::fs::create_dir(&second)?;
        let a = first.join("entry.dat");
        let b = second.join("alias.dat");
        std::fs::write(&a, b"pinned native hardlink baseline")?;
        std::fs::hard_link(&a, &b)?;
        let directory = PinnedFile::open(&first, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, 3)?;
        let entries = native::directory_entries(directory.raw())?;
        let enumerated = entries
            .iter()
            .find(|e| e.name == "entry.dat")
            .ok_or_else(|| anyhow::anyhow!("Missing native fixture entry"))?;
        let writer = PinnedFile::open(&b, FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES, 7)?;
        let original = writer.identity()?;
        let set_time = |timestamp: i64| -> Result<()> {
            let info = FILE_BASIC_INFO {
                CreationTime: 0,
                LastAccessTime: 0,
                LastWriteTime: timestamp,
                ChangeTime: 0,
                FileAttributes: 0,
            };
            if unsafe {
                SetFileInformationByHandle(
                    writer.raw(),
                    FileBasicInfo,
                    (&info as *const FILE_BASIC_INFO).cast(),
                    std::mem::size_of::<FILE_BASIC_INFO>() as u32,
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            Ok(())
        };
        set_time(original.last_write_time + 10_000_000)?;
        let retained = PinnedFile::open(&a, FILE_READ_ATTRIBUTES, 7)?;
        let baseline = retained.identity()?;
        assert_ne!(baseline.last_write_time, enumerated.last_write_time);
        verify_enumerated_child(&baseline, baseline.volume, enumerated)?;
        let different_path = root.join("different-native-identity");
        std::fs::write(&different_path, b"different owned native file")?;
        let different = PinnedFile::open(&different_path, FILE_READ_ATTRIBUTES, 7)?;
        let different_identity = different.identity()?;
        let mismatch = verify_enumerated_child(&different_identity, baseline.volume, enumerated)
            .with_context(|| format!("Cannot capture directory entry baseline '{}'", a.display()))
            .unwrap_err();
        let mismatch = format!("{mismatch:#}");
        for expected in [
            a.to_string_lossy().as_ref(),
            "Baseline[",
            "Actual[",
            &hex::encode_upper(baseline.id),
            &hex::encode_upper(different_identity.id),
        ] {
            assert!(
                mismatch.contains(expected),
                "Missing identity diagnostic {expected}: {mismatch}"
            );
        }
        let mut wrong = enumerated.clone();
        wrong.attributes ^= FILE_ATTRIBUTE_HIDDEN;
        assert!(verify_enumerated_child(&baseline, baseline.volume, &wrong).is_err());
        set_time(original.last_write_time + 20_000_000)?;
        assert!(
            retained.require_unchanged().is_err(),
            "Mutation after pinned baseline capture must be detected"
        );
        let mut tree = Vec::new();
        capture_tree(&root, true, &mut tree, 32, None)?;
        eprintln!(
            "Retained native fixture for Prunlet cleanup: {}",
            root.display()
        );
        Ok(())
    }
    #[test]
    pub(super) fn native_hardlink_stream_guard_contract() -> Result<()> {
        use std::os::windows::fs::OpenOptionsExt;
        let root = fixture("hardlink-streams")?;
        let first = root.join("first.dat");
        let second = root.join("second.dat");
        std::fs::write(&first, b"base")?;
        std::fs::hard_link(&first, &second)?;
        let ads = PathBuf::from(format!("{}:retained", first.display()));
        std::fs::write(&ads, b"stream")?;
        let inspection = PinnedFile::open(&first, FILE_READ_ATTRIBUTES, 7)?;
        let expected = inspection.identity()?;
        let blocker = std::fs::OpenOptions::new()
            .write(true)
            .share_mode(7)
            .open(&ads)?;
        let unprotected = HardlinkGuard::capture(&first, &expected, &root)?;
        assert!(
            unprotected.unprotected_root.is_some(),
            "A preexisting ADS writer must prevent full write-guard retention"
        );
        assert!(unprotected.can_continue(&root));
        assert!(!unprotected.can_continue(&root.join("other")));
        drop(blocker);
        drop(unprotected);
        let protected = HardlinkGuard::capture(&first, &inspection.identity()?, &root)?;
        assert!(protected.unprotected_root.is_none());
        assert_eq!(protected.stream_handles.len(), 1);
        assert!(protected.streams_match()?);
        let alias_ads = PathBuf::from(format!("{}:retained", second.display()));
        let write = std::fs::OpenOptions::new()
            .write(true)
            .share_mode(7)
            .open(alias_ads);
        assert!(
            write.is_err(),
            "A known ADS must reject an external alias writer while guarded"
        );
        let new_ads = PathBuf::from(format!("{}:new-stream", second.display()));
        std::fs::write(new_ads, b"new")?;
        assert!(
            !protected.streams_match()?,
            "Adding a new ADS must be detected before continuing deletion"
        );
        Ok(())
    }
    #[test]
    pub(super) fn native_permanent_parent_replacement_preserves_both_aliases() -> Result<()> {
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        let root = fixture("permanent-parent-swap")?;
        let target = root.join("target");
        let replacement = root.join("replacement");
        let parked = root.join("parked");
        let metadata = root.join("metadata");
        for path in [&target, &replacement, &metadata] {
            std::fs::create_dir(path)?;
        }
        let payload = target.join("same.dat");
        std::fs::write(&payload, b"parent identity must remain fixed")?;
        std::fs::hard_link(&payload, replacement.join("same.dat"))?;
        let config = Config {
            path: root.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let roots = protected_roots(&config, &target)
            .map_err(|e| e.context("native parent test: resolving protected roots"))?;
        eprintln!("Native parent test protected roots: {roots:?}");
        let mut prepared = prepare(&config, &target, true, true)
            .map_err(|e| e.context("native parent test: preparing original directory"))?
            .ok_or_else(|| anyhow::anyhow!("Missing native fixture target"))?;
        let attempted = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let checkpoint_attempted = attempted.clone();
        let source = target.clone();
        let parked_copy = parked.clone();
        let replacement_copy = replacement.clone();
        *PERMANENT_AFTER_CAPTURE.lock().unwrap() = Some(Box::new(move || {
            checkpoint_attempted.store(true, std::sync::atomic::Ordering::SeqCst);
            let parent = PinnedFile::open(
                source.parent().unwrap(),
                FILE_READ_ATTRIBUTES | FILE_ADD_SUBDIRECTORY,
                3,
            )?;
            let original = PinnedFile::open(&source, DELETE | FILE_READ_ATTRIBUTES, 7)?;
            security::rename_fixed(
                original.raw(),
                parent.raw(),
                parked_copy.file_name().unwrap().to_str().unwrap(),
            )?;
            let replacement =
                PinnedFile::open(&replacement_copy, DELETE | FILE_READ_ATTRIBUTES, 7)?;
            security::rename_fixed(
                replacement.raw(),
                parent.raw(),
                source.file_name().unwrap().to_str().unwrap(),
            )?;
            Ok(())
        }));
        let mut started = false;
        let states = PermanentState::default();
        let outcome = permanent_delete(
            &config,
            &mut prepared,
            true,
            None,
            &mut started,
            &states,
            None,
        );
        eprintln!(
            "Native parent replacement outcome: {outcome:?}; parked exists={}",
            parked.exists()
        );
        assert!(outcome.is_err());
        assert!(
            attempted.load(std::sync::atomic::Ordering::SeqCst),
            "Parent replacement checkpoint must actually be attempted"
        );
        assert!(
            !started,
            "Parent replacement must stop before any disposition call"
        );
        assert_eq!(
            std::fs::read(target.join("same.dat"))?,
            b"parent identity must remain fixed"
        );
        if parked.exists() {
            assert_eq!(
                std::fs::read(parked.join("same.dat"))?,
                b"parent identity must remain fixed"
            );
            eprintln!(
                "Native parent replacement occurred and captured parent identity rejected it before disposition."
            );
        } else {
            let error = outcome.unwrap_err();
            assert!(error.chain().any(|cause| {
                cause
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| matches!(e.raw_os_error(), Some(5 | 32 | 33)))
            }));
            assert_eq!(
                std::fs::read(replacement.join("same.dat"))?,
                b"parent identity must remain fixed"
            );
            eprintln!(
                "Windows rejected the attempted parent replacement while original entries were held; both original and external alias remain intact, and no disposition was issued. The post-replacement comparison branch was not reached on this host."
            );
        }
        Ok(())
    }
    #[test]
    fn native_post_shell_failure_keeps_every_item_result() -> Result<()> {
        let bin_root = std::env::var_os("PRUNLET_NATIVE_RECYCLE_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("USERPROFILE").unwrap_or_default())
                    .join("PrunletValidation")
                    .join("rust-migration-20261103")
            });
        native_post_shell_at(&bin_root)
    }
    pub(super) fn native_post_shell_at(bin_root: &Path) -> Result<()> {
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        let metadata_root = fixture("post-shell-metadata")?;
        let metadata = metadata_root.join("metadata");
        std::fs::create_dir(&metadata)?;
        let _parents = path::pin_directories(&bin_root)?;
        let root = bin_root.join(format!("post-shell-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&root)?;
        eprintln!("Retained native Shell fixture root: {}", root.display());
        let first = root.join("first.txt");
        let second = root.join("second.txt");
        std::fs::write(&first, b"first")?;
        std::fs::write(&second, b"second")?;
        if ImmediateDeleteSetting::capture(&first).is_some() {
            bail!("Post-Shell fault test requires the authorized recyclable C: fixture volume");
        }
        let config = Config {
            path: metadata_root.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        *AFTER_SHELL_VERIFICATION.lock().unwrap() = Some((
            first.clone(),
            Box::new(|| bail!("injected loss of post-Shell inspection")),
        ));
        let result = delete(
            &config,
            &[first.clone(), second.clone()],
            false,
            false,
            None,
            None,
        )?;
        assert_eq!(result.items.len(), 2);
        assert_eq!(result.items[0].status, "ambiguous");
        assert_eq!(result.items[1].status, "recycled");
        let error = result.items[0].error.as_deref().unwrap_or("");
        assert!(error.contains("injected loss"));
        assert!(error.contains("do not resend"));
        assert!(!first.exists() && !second.exists());
        Ok(())
    }

    pub(super) fn oversize_native_contract(mode: &str, bin_root: &Path) -> Result<Value> {
        use std::{
            io::Write,
            os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
            sync::{
                Arc,
                atomic::{AtomicBool, AtomicUsize, Ordering},
            },
        };
        if ![
            "rendezvous",
            "child-baseline-race",
            "child-race",
            "locked-child",
            "guard-probe",
            "time-probe",
            "external-change",
            "external-attributes",
            "external-masked-change",
        ]
        .contains(&mode)
        {
            bail!("Unknown oversize native boundary mode");
        }
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        let _bin_pin = path::pin_directories(bin_root)?;
        let root_parallel_proof = if mode == "rendezvous" {
            Some(permanent_root_parallel_contract()?)
        } else {
            None
        };
        let data = bin_root.join(format!("oversize-{mode}-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&data)?;
        let metadata_scope = fixture(&format!("oversize-{mode}-metadata"))?;
        let metadata = metadata_scope.join("metadata");
        std::fs::create_dir(&metadata)?;
        let config = Config {
            path: metadata_scope.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let survivor = data.join("surviving-alias");
        let original_bytes = b"owned native shared hardlink content";
        std::fs::write(&survivor, original_bytes)?;
        let ads = PathBuf::from(format!("{}:retained", survivor.display()));
        std::fs::write(&ads, b"owned native alternate stream")?;
        let roots = [data.join("first-root"), data.join("second-root")];
        let mut sparse = Vec::new();
        let mut sparse_proofs = Vec::new();
        for root in &roots {
            std::fs::create_dir(root)?;
            let path = root.join("z-oversized-sparse");
            let mut file = std::fs::OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .open(&path)?;
            let mut returned = 0;
            if unsafe {
                windows_sys::Win32::System::IO::DeviceIoControl(
                    file.as_raw_handle(),
                    0x900C4,
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    0,
                    &mut returned,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            file.write_all(b"owned sparse prefix")?;
            file.set_len(1u64 << 40)?;
            file.sync_all()?;
            let identity = native::identity(file.as_raw_handle())?;
            let mut info: FILE_STANDARD_INFO = unsafe { std::mem::zeroed() };
            if unsafe {
                GetFileInformationByHandleEx(
                    file.as_raw_handle(),
                    FileStandardInfo,
                    (&mut info as *mut FILE_STANDARD_INFO).cast(),
                    std::mem::size_of::<FILE_STANDARD_INFO>() as u32,
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            if identity.size != (1u64 << 40)
                || info.AllocationSize < 0
                || info.AllocationSize > 1024 * 1024
            {
                bail!("Native sparse fixture did not prove logical size and bounded allocation");
            }
            sparse_proofs.push(serde_json::json!({"path":path,"logicalSize":identity.size,"allocationSize":info.AllocationSize,"fileId":hex::encode_upper(identity.id)}));
            sparse.push((
                path,
                identity,
                security::read_member_security(file.as_raw_handle())?,
            ));
            drop(file);
            std::fs::hard_link(&survivor, root.join("alias-0"))?;
            std::fs::hard_link(&survivor, root.join("alias-1"))?;
        }
        let held = PinnedFile::open(&survivor, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
        let before = held.identity()?;
        let security_before = security::read_member_security(held.raw())?;
        let streams_before = native::named_streams(held.raw())?;
        let dry = delete(&config, &roots, true, true, None, None)?;
        assert!(dry.items.iter().all(|item| item.status == "would_recycle"));
        assert_eq!(std::fs::read_dir(&metadata)?.count(), 0);
        let shell_count = Arc::new(AtomicUsize::new(0));
        let root_count = Arc::new(AtomicUsize::new(0));
        let writer_blocked = Arc::new(AtomicBool::new(false));
        let mutation_reached = Arc::new(AtomicBool::new(false));
        let child_excluded = Arc::new(AtomicBool::new(false));
        let pending_writer_denied = Arc::new(AtomicBool::new(false));
        let concurrent_shell = Arc::new(AtomicBool::new(false));
        let shell_barrier = Arc::new((Mutex::new(0usize), std::sync::Condvar::new()));
        let holder = Arc::new(Mutex::new(None::<std::fs::File>));
        let shell_seen = shell_count.clone();
        let roots_seen = root_count.clone();
        let blocked = writer_blocked.clone();
        let mutation = mutation_reached.clone();
        let child = roots[1].join("alias-0");
        let alias = survivor.clone();
        let mode_owned = mode.to_owned();
        let held_file = holder.clone();
        let exclusion = child_excluded.clone();
        let pending_blocked = pending_writer_denied.clone();
        let concurrent = concurrent_shell.clone();
        let first_alias = roots[0].join("alias-0");
        let first_root = roots[0].clone();
        let second_root = roots[1].clone();
        let root_completion = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let permanent_barrier = Arc::new((Mutex::new(0usize), std::sync::Condvar::new()));
        let same_id_active = Arc::new(AtomicUsize::new(0));
        let same_id_maximum = Arc::new(AtomicUsize::new(0));
        let same_active = same_id_active.clone();
        let same_maximum = same_id_maximum.clone();
        let same_id_attempts = Arc::new((Mutex::new(BTreeSet::new()), std::sync::Condvar::new()));
        let contention = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let change_time = |path: &Path, attributes: bool| -> Result<()> {
            let writer = PinnedFile::open(path, FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES, 7)?;
            let current = writer.identity()?;
            let info = FILE_BASIC_INFO {
                CreationTime: 0,
                LastAccessTime: 0,
                LastWriteTime: if attributes {
                    0
                } else {
                    current.last_write_time + 20_000_000
                },
                ChangeTime: 0,
                FileAttributes: if attributes {
                    current.attributes ^ FILE_ATTRIBUTE_HIDDEN
                } else {
                    0
                },
            };
            if unsafe {
                SetFileInformationByHandle(
                    writer.raw(),
                    FileBasicInfo,
                    (&info as *const FILE_BASIC_INFO).cast(),
                    std::mem::size_of::<FILE_BASIC_INFO>() as u32,
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            Ok(())
        };
        *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, _path| {
            if mode_owned == "rendezvous" || mode_owned == "child-race" {
                if phase == "hardlink-state-contended" {
                    *contention.0.lock().unwrap() = true;
                    contention.1.notify_all();
                    exclusion.store(true, Ordering::SeqCst);
                }
                if phase == "hardlink-state-waiting" {
                    same_id_attempts
                        .0
                        .lock()
                        .unwrap()
                        .insert(_path.parent().unwrap().to_path_buf());
                    same_id_attempts.1.notify_all();
                }
                if _path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("alias-"))
                {
                    if phase == "permanent-child-pinned" {
                        let active = same_active.fetch_add(1, Ordering::SeqCst) + 1;
                        same_maximum.fetch_max(active, Ordering::SeqCst);
                        if active != 1 {
                            bail!("Same FileID reached permanent disposition concurrently");
                        }
                        let (roots, timed) = same_id_attempts
                            .1
                            .wait_timeout_while(
                                same_id_attempts.0.lock().unwrap(),
                                std::time::Duration::from_secs(10),
                                |roots| roots.len() < 2,
                            )
                            .unwrap();
                        if timed.timed_out() && roots.len() < 2 {
                            bail!("Both permanent roots did not contend for the same FileID");
                        }
                        drop(roots);
                        if mode_owned == "child-race" {
                            let (blocked, timed) = contention
                                .1
                                .wait_timeout_while(
                                    contention.0.lock().unwrap(),
                                    std::time::Duration::from_secs(10),
                                    |blocked| !*blocked,
                                )
                                .unwrap();
                            if timed.timed_out() && !*blocked {
                                bail!("Other root did not block on the retained FileID state");
                            }
                        }
                    } else if phase == "permanent-child-finished" {
                        same_active.fetch_sub(1, Ordering::SeqCst);
                    }
                }
            }
            if phase == "permanent-root-finished" && _path == first_root {
                *root_completion.0.lock().unwrap() = true;
                root_completion.1.notify_all();
            }
            if phase == "permanent-root-start" {
                if mode_owned == "rendezvous" || mode_owned == "child-race" {
                    let mut arrivals = permanent_barrier.0.lock().unwrap();
                    *arrivals += 1;
                    permanent_barrier.1.notify_all();
                    let (arrivals, timed) = permanent_barrier
                        .1
                        .wait_timeout_while(arrivals, std::time::Duration::from_secs(10), |count| {
                            *count < 2
                        })
                        .unwrap();
                    if timed.timed_out() && *arrivals < 2 {
                        bail!("Two actual permanent roots did not reach their worker concurrently");
                    }
                } else if _path == second_root {
                    let (done, timed) = root_completion
                        .1
                        .wait_timeout_while(
                            root_completion.0.lock().unwrap(),
                            std::time::Duration::from_secs(10),
                            |done| !*done,
                        )
                        .unwrap();
                    if timed.timed_out() && !*done {
                        bail!("First root failed before the second-root fault boundary");
                    }
                }
            }
            if phase == "before-shell" && mode_owned == "rendezvous" {
                let (mut arrivals, notify) = (shell_barrier.0.lock().unwrap(), &shell_barrier.1);
                *arrivals += 1;
                notify.notify_all();
                let (arrivals, timed) = notify
                    .wait_timeout_while(arrivals, std::time::Duration::from_secs(10), |count| {
                        *count < 2
                    })
                    .unwrap();
                if timed.timed_out() && *arrivals < 2 {
                    bail!("Two actual native Shell workers did not rendezvous before deletion");
                }
                concurrent.store(true, Ordering::SeqCst);
            }
            if phase == "hardlink-delete-pending"
                && mode_owned == "guard-probe"
                && _path == first_alias
            {
                match std::fs::OpenOptions::new()
                    .write(true)
                    .share_mode(7)
                    .open(&alias)
                {
                    Err(error) if matches!(error.raw_os_error(), Some(5 | 32 | 33)) => {
                        pending_blocked.store(true, Ordering::SeqCst);
                    }
                    Err(error) => return Err(error.into()),
                    Ok(_) => bail!("Writer opened while a hardlink deletion was pending"),
                }
            }
            if phase == "shell-permanent-permitted" {
                shell_seen.fetch_add(1, Ordering::SeqCst);
            }
            if phase != "permanent-root-start" {
                return Ok(());
            }
            if shell_seen.load(Ordering::SeqCst) != 2 {
                bail!("Permanent deletion started before all Shell dispositions completed");
            }
            let index = roots_seen.fetch_add(1, Ordering::SeqCst);
            if index != 1 {
                return Ok(());
            }
            match mode_owned.as_str() {
                "locked-child" => {
                    *held_file.lock().unwrap() = Some(
                        std::fs::OpenOptions::new()
                            .read(true)
                            .share_mode(FILE_SHARE_READ)
                            .open(&child)?,
                    );
                    mutation.store(true, Ordering::SeqCst);
                }
                "child-baseline-race" => {
                    let target = child.clone();
                    let mutation = mutation.clone();
                    *PERMANENT_AFTER_CAPTURE.lock().unwrap() = Some(Box::new(move || {
                        change_time(&target, false)?;
                        mutation.store(true, Ordering::SeqCst);
                        Ok(())
                    }));
                }
                "time-probe" | "external-attributes" => {
                    change_time(&alias, mode_owned == "external-attributes")?;
                    mutation.store(true, Ordering::SeqCst);
                }
                "guard-probe" | "external-change" | "external-masked-change" => {
                    let path = if mode_owned == "guard-probe" {
                        alias.clone()
                    } else {
                        PathBuf::from(format!("{}:retained", alias.display()))
                    };
                    match std::fs::OpenOptions::new()
                        .write(true)
                        .share_mode(7)
                        .open(&path)
                    {
                        Err(error) if matches!(error.raw_os_error(), Some(5 | 32 | 33)) => {
                            blocked.store(true, Ordering::SeqCst);
                        }
                        Err(error) => return Err(error.into()),
                        Ok(mut writer) => {
                            writer.write_all(b"unexpected externally writable stream")?;
                            mutation.store(true, Ordering::SeqCst);
                        }
                    }
                }
                _ => {}
            }
            Ok(())
        }));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                FILE_CHECKPOINT.lock().unwrap().take();
                PERMANENT_AFTER_CAPTURE.lock().unwrap().take();
            }
        }
        let _reset = Reset;
        let result = delete(&config, &roots, false, true, None, None)?;
        holder.lock().unwrap().take();
        eprintln!("Native oversized root outcomes: {result:?}");
        if mode == "rendezvous" || mode == "child-race" {
            assert_eq!(same_id_maximum.load(Ordering::SeqCst), 1);
            assert_eq!(same_id_active.load(Ordering::SeqCst), 0);
        }
        assert_eq!(shell_count.load(Ordering::SeqCst), 2);
        assert_eq!(root_count.load(Ordering::SeqCst), 2);
        assert_eq!(result.items.len(), 2);
        assert_eq!(result.items[0].status, "permanently_deleted");
        let expect_rejection = [
            "child-baseline-race",
            "locked-child",
            "time-probe",
            "external-attributes",
        ]
        .contains(&mode);
        if expect_rejection {
            assert!(mutation_reached.load(Ordering::SeqCst));
            if mode == "child-baseline-race" {
                let error = result.items[1].error.as_deref().unwrap_or("");
                assert!(
                    ["alias-0", "alias-1"]
                        .iter()
                        .any(|leaf| error.contains(roots[1].join(leaf).to_string_lossy().as_ref())),
                    "Missing actual affected hardlink path: {error}"
                );
                for expected in [
                    "expectedCreation=",
                    "actualCreation=",
                    "expectedLastWrite=",
                    "actualLastWrite=",
                    "expectedChange=",
                    "actualChange=",
                    &hex::encode_upper(before.id),
                ] {
                    assert!(
                        error.contains(expected),
                        "Missing pinned-time diagnostic {expected}: {error}"
                    );
                }
            }
            assert!(matches!(
                result.items[1].status.as_str(),
                "failed" | "ambiguous"
            ));
            assert!(roots[1].join("alias-0").exists());
            assert!(!roots[0].exists());
        } else {
            assert!(
                result
                    .items
                    .iter()
                    .all(|item| item.status == "permanently_deleted")
            );
            assert!(!roots[0].exists() && !roots[1].exists());
        }
        if ["guard-probe", "external-change", "external-masked-change"].contains(&mode) {
            assert!(writer_blocked.load(Ordering::SeqCst));
            assert!(!mutation_reached.load(Ordering::SeqCst));
        }
        if mode == "child-race" {
            assert!(child_excluded.load(Ordering::SeqCst));
        }
        if mode == "rendezvous" {
            assert!(concurrent_shell.load(Ordering::SeqCst));
        }
        let mut writer_allowed_after = false;
        if mode == "guard-probe" {
            assert!(pending_writer_denied.load(Ordering::SeqCst));
            let writer = std::fs::OpenOptions::new()
                .write(true)
                .share_mode(7)
                .open(&survivor)?;
            drop(writer);
            writer_allowed_after = true;
        }
        let after = held.identity()?;
        assert!(before.same_object(&after));
        assert_eq!(security::read_member_security(held.raw())?, security_before);
        assert_eq!(native::named_streams(held.raw())?, streams_before);
        assert_eq!(std::fs::read(&survivor)?, original_bytes);
        assert_eq!(std::fs::read(&ads)?, b"owned native alternate stream");
        let mut cleanup = Vec::new();
        for (path, identity, security_bytes) in sparse {
            if let Some(current) = inspect(&path)? {
                if !identity.same_object(&current.identity()?) || current.identity()?.links != 1 {
                    bail!("Sparse fixture identity changed; retained without resizing");
                }
                drop(current);
                cleanup.push(shrink_owned_sparse(
                    &path,
                    &identity,
                    &security_bytes,
                    b"owned sparse prefix",
                )?);
            }
        }
        let metadata_members: Vec<_> = std::fs::read_dir(&metadata)?
            .map(|entry| entry.map(|entry| entry.file_name()))
            .collect::<std::result::Result<_, _>>()?;
        assert_eq!(
            metadata_members,
            [std::ffi::OsString::from("maintenance.lock")]
        );
        Ok(
            serde_json::json!({"passed":true,"mode":mode,"result":result,"shellDispositions":2,"allShellBeforePermanent":true,"concurrentShellRendezvous":concurrent_shell.load(Ordering::SeqCst),"permanentRootStarts":2,"rootParallelProof":root_parallel_proof,"maximumSameFileIDDispositionWorkers":same_id_maximum.load(Ordering::SeqCst),"sharedChildDeleteExcluded":child_excluded.load(Ordering::SeqCst),"pendingWriterDenied":pending_writer_denied.load(Ordering::SeqCst),"writerAllowedAfter":writer_allowed_after,"externalWriterBlocked":writer_blocked.load(Ordering::SeqCst),"mutationReached":mutation_reached.load(Ordering::SeqCst),"sparseProofs":sparse_proofs,"boundedOwnedSparseCleanup":cleanup,"retainedFixtureRoot":data,"metadataRoot":metadata,"productFaultInjection":false}),
        )
    }
    fn permanent_root_parallel_contract() -> Result<Value> {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let scope = fixture("permanent-root-parallel")?;
        let metadata = scope.join("metadata");
        std::fs::create_dir(&metadata)?;
        let config = Config {
            path: scope.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let mut paths = vec![];
        for index in 0..8 {
            let parent = scope.join(format!("root-{index}"));
            std::fs::create_dir(&parent)?;
            let target = parent.join("con.txt");
            let bytes = b"owned independent reserved leaf";
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(PathBuf::from(format!("\\\\?\\{}", target.display())))?;
            std::io::Write::write_all(&mut file, bytes)?;
            paths.push(target);
        }
        let active = Arc::new(AtomicUsize::new(0));
        let maximum = Arc::new(AtomicUsize::new(0));
        let arrivals = Arc::new((Mutex::new(0usize), std::sync::Condvar::new()));
        let a = active.clone();
        let m = maximum.clone();
        *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, _| {
            if phase == "permanent-root-start" {
                let current = a.fetch_add(1, Ordering::SeqCst) + 1;
                m.fetch_max(current, Ordering::SeqCst);
                if current > 4 {
                    bail!("Permanent root worker limit exceeded");
                }
                let mut count = arrivals.0.lock().unwrap();
                *count += 1;
                arrivals.1.notify_all();
                let threshold = if *count <= 4 { 4 } else { 8 };
                let (count, timed) = arrivals
                    .1
                    .wait_timeout_while(count, std::time::Duration::from_secs(10), |count| {
                        *count < threshold
                    })
                    .unwrap();
                if timed.timed_out() && *count < threshold {
                    bail!("Four permanent roots did not reach independent workers concurrently");
                }
            } else if phase == "permanent-root-finished" {
                a.fetch_sub(1, Ordering::SeqCst);
            }
            Ok(())
        }));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                FILE_CHECKPOINT.lock().unwrap().take();
            }
        }
        let reset = Reset;
        let result = delete(&config, &paths, false, false, None, None)?;
        drop(reset);
        assert!(
            result
                .items
                .iter()
                .all(|item| item.status == "permanently_deleted"),
            "{result:?}"
        );
        assert_eq!(maximum.load(Ordering::SeqCst), 4);
        assert_eq!(active.load(Ordering::SeqCst), 0);
        for (item, path) in result.items.iter().zip(&paths) {
            assert_eq!(item.path, path.to_string_lossy());
        }
        Ok(
            serde_json::json!({"independentRoots":8,"maximumConcurrentPermanentWorkers":4,"allPermanentlyDeleted":true,"resultInputOrder":true,"retainedFixtureRoot":scope}),
        )
    }
    pub(super) fn oversize_root_race_contract(mode: &str, root: &Path) -> Result<Value> {
        use std::{
            io::Write,
            os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
            sync::{
                Arc,
                atomic::{AtomicUsize, Ordering},
            },
        };
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        if !["replace", "lock"].contains(&mode) {
            bail!("Unknown oversized root race");
        }
        let data = root.join(format!("oversize-{mode}-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&data)?;
        let source = data.join("owned-sparse");
        let moved = data.join("original-moved");
        let mut sparse = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .access_mode(
                windows_sys::Win32::Foundation::GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
            )
            .open(&source)?;
        let mut returned = 0;
        if unsafe {
            windows_sys::Win32::System::IO::DeviceIoControl(
                sparse.as_raw_handle(),
                0x900C4,
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                0,
                &mut returned,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let prefix = b"owned sparse prefix";
        sparse.write_all(prefix)?;
        sparse.set_len(1u64 << 40)?;
        sparse.sync_all()?;
        let before = native::identity(sparse.as_raw_handle())?;
        let security_bytes = security::read_member_security(sparse.as_raw_handle())?;
        let mut standard: FILE_STANDARD_INFO = unsafe { std::mem::zeroed() };
        if unsafe {
            GetFileInformationByHandleEx(
                sparse.as_raw_handle(),
                FileStandardInfo,
                (&mut standard as *mut FILE_STANDARD_INFO).cast(),
                std::mem::size_of::<FILE_STANDARD_INFO>() as u32,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        if before.size != (1u64 << 40)
            || standard.AllocationSize < 0
            || standard.AllocationSize > 1024 * 1024
        {
            bail!("Owned sparse logical/allocation proof failed");
        }
        drop(sparse);
        let metadata_scope = fixture(&format!("oversize-{mode}-metadata"))?;
        let metadata = metadata_scope.join("metadata");
        std::fs::create_dir(&metadata)?;
        let config = Config {
            path: metadata_scope.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let checkpoints = Arc::new(AtomicUsize::new(0));
        let observed = checkpoints.clone();
        let holder = Arc::new(Mutex::new(None));
        let held = holder.clone();
        let selected = source.clone();
        let destination = moved.clone();
        let replace = mode == "replace";
        *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, path| {
            if phase == "shell-size-permanent-permitted" && path == selected {
                if observed.fetch_add(1, Ordering::SeqCst) != 0 {
                    bail!("Size-only race checkpoint was repeated");
                }
                if replace {
                    std::fs::rename(&selected, &destination)?;
                    std::fs::write(&selected, b"replacement must survive")?;
                } else {
                    *held.lock().unwrap() = Some(
                        std::fs::OpenOptions::new()
                            .read(true)
                            .share_mode(FILE_SHARE_READ)
                            .open(&selected)?,
                    );
                }
            }
            Ok(())
        }));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                FILE_CHECKPOINT.lock().unwrap().take();
            }
        }
        let _reset = Reset;
        let result = delete(&config, &[source.clone()], false, false, None, None)?;
        holder.lock().unwrap().take();
        assert_eq!(
            checkpoints.load(Ordering::SeqCst),
            1,
            "Actual Windows size-only refusal was not reached"
        );
        assert_eq!(result.items[0].status, "ambiguous");
        let error = result.items[0].error.as_deref().unwrap_or("");
        assert!(
            error.contains("permanently")
                && (error.contains("not retried") || error.contains("do not resend")),
            "Missing partial/no-retry diagnostic: {error}"
        );
        let original = if replace { &moved } else { &source };
        let actual = PinnedFile::open(original, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
        assert!(before.same_object(&actual.identity()?));
        assert_eq!(before.attributes, actual.identity()?.attributes);
        assert_eq!(
            security_bytes,
            security::read_member_security(actual.raw())?
        );
        drop(actual);
        if replace {
            assert_eq!(std::fs::read(&source)?, b"replacement must survive");
        } else {
            assert!(!moved.exists());
        }
        let cleanup = shrink_owned_sparse(original, &before, &security_bytes, prefix)?;
        Ok(
            serde_json::json!({"passed":true,"mode":mode,"result":result,"checkpointCount":1,"actualWindowsSizeRefusal":true,"logicalSizeBefore":before.size,"allocationSizeBefore":standard.AllocationSize,"originalAndReplacementPreserved":true,"boundedOwnedSparseCleanup":cleanup,"retainedFixtureRoot":data,"metadataRoot":metadata,"productFaultInjection":false}),
        )
    }
    fn shrink_owned_sparse(
        path: &Path,
        expected: &FileIdentity,
        security_bytes: &[u8],
        prefix: &[u8],
    ) -> Result<Value> {
        use std::io::{Read, Seek, SeekFrom};
        #[repr(C)]
        #[derive(Clone, Copy, Default)]
        struct Range {
            offset: i64,
            length: i64,
        }
        let _parents = path::pin_directories(
            path.parent()
                .ok_or_else(|| anyhow::anyhow!("Missing sparse fixture parent"))?,
        )?;
        let fixed = PinnedFile::open(
            path,
            GENERIC_WRITE
                | windows_sys::Win32::Foundation::GENERIC_READ
                | FILE_READ_ATTRIBUTES
                | READ_CONTROL,
            1,
        )?;
        let original = fixed.identity()?;
        if !expected.same_object(&original)
            || original.attributes != expected.attributes
            || original.size != expected.size
            || original.links != 1
            || original.is_reparse()
            || security::read_member_security(fixed.raw())? != security_bytes
            || !native::named_streams(fixed.raw())?.is_empty()
        {
            bail!("Sparse fixture state changed; retained without resizing");
        }
        let query = Range {
            offset: 0,
            length: original.size.try_into()?,
        };
        let mut ranges = vec![Range::default(); 4096];
        let mut returned = 0;
        if unsafe {
            windows_sys::Win32::System::IO::DeviceIoControl(
                fixed.raw(),
                0x940CF,
                (&query as *const Range).cast(),
                16,
                ranges.as_mut_ptr().cast(),
                (ranges.len() * 16) as u32,
                &mut returned,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        if returned as usize > ranges.len() * 16 || returned % 16 != 0 {
            bail!("Invalid sparse allocation range buffer; retained");
        }
        ranges.truncate(returned as usize / 16);
        let mut allocated = 0u64;
        let mut prior_end = 0u64;
        let mut prefix_seen = vec![false; prefix.len()];
        let mut file = native::process::duplicate_file(fixed.raw())?;
        for range in &ranges {
            if range.offset < 0 || range.length <= 0 {
                bail!("Invalid sparse allocated range; retained");
            }
            let start = range.offset as u64;
            let length = range.length as u64;
            let end = start
                .checked_add(length)
                .ok_or_else(|| anyhow::anyhow!("Sparse range overflow"))?;
            allocated = allocated
                .checked_add(length)
                .ok_or_else(|| anyhow::anyhow!("Sparse allocation overflow"))?;
            if start < prior_end || end > original.size || allocated > 1024 * 1024 {
                bail!("Sparse allocation exceeded its owned bounded proof; retained");
            }
            prior_end = end;
            file.seek(SeekFrom::Start(start))?;
            let mut bytes = vec![0; length as usize];
            file.read_exact(&mut bytes)?;
            for (index, byte) in bytes.iter().enumerate() {
                let position = start + index as u64;
                let expected_byte = if position < (prefix.len() as u64) {
                    prefix_seen[position as usize] = true;
                    prefix[position as usize]
                } else {
                    0
                };
                if *byte != expected_byte {
                    bail!(
                        "Sparse allocated content changed at byte {position}; retained without resizing"
                    );
                }
            }
        }
        if prefix_seen.iter().any(|seen| !*seen) {
            bail!("Sparse prefix was not fully covered by allocation proof; retained");
        }
        fixed.require_unchanged()?;
        if security::read_member_security(fixed.raw())? != security_bytes
            || !native::named_streams(fixed.raw())?.is_empty()
        {
            bail!("Sparse metadata changed after proof; retained");
        }
        file.set_len(prefix.len() as u64)?;
        file.sync_all()?;
        let final_identity = fixed.identity()?;
        if !expected.same_object(&final_identity)
            || final_identity.attributes != expected.attributes
            || security::read_member_security(fixed.raw())? != security_bytes
        {
            bail!(
                "Sparse fixture finalization did not preserve native identity/attributes/security"
            );
        }
        Ok(
            serde_json::json!({"path":path,"resizedOwnedFixture":true,"logicalSize":final_identity.size,"verifiedAllocatedBytes":allocated,"verifiedAllocatedRanges":ranges.len(),"securityUnchanged":true}),
        )
    }
    pub(super) fn immediate_replacement_contract(data: &Path) -> Result<Value> {
        use std::sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        };
        let _serial = PERMANENT_TEST_SERIAL.lock().unwrap();
        let _parents = path::pin_directories(data)?;
        let setting = ImmediateDeleteSetting::capture(data).ok_or_else(|| {
            anyhow::anyhow!(
                "Explicit immediate-delete setting is required for this native boundary"
            )
        })?;
        setting.revalidate(data)?;
        let root = data.join(format!(
            "immediate-replacement-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir(&root)?;
        let source = root.join("source");
        let moved = root.join("original-moved");
        std::fs::write(&source, b"owned original")?;
        let metadata_scope = fixture("immediate-replacement-metadata")?;
        let metadata = metadata_scope.join("metadata");
        std::fs::create_dir(&metadata)?;
        let config = Config {
            path: metadata_scope.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let original = PinnedFile::open(&source, FILE_READ_ATTRIBUTES, 7)?;
        let identity = original.identity()?;
        let count = Arc::new(AtomicUsize::new(0));
        let observed = count.clone();
        let selected = source.clone();
        let destination = moved.clone();
        *FILE_CHECKPOINT.lock().unwrap() = Some(Arc::new(move |phase, path| {
            if phase == "shell-permanent-permitted" && path == selected {
                std::fs::rename(&selected, &destination)?;
                std::fs::write(&selected, b"replacement must survive")?;
                observed.fetch_add(1, Ordering::SeqCst);
            }
            Ok(())
        }));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self) {
                FILE_CHECKPOINT.lock().unwrap().take();
            }
        }
        let _reset = Reset;
        let result = delete(&config, &[source.clone()], false, false, None, None)?;
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert_eq!(result.items[0].status, "ambiguous");
        assert_eq!(std::fs::read(&source)?, b"replacement must survive");
        assert_eq!(std::fs::read(&moved)?, b"owned original");
        let actual = PinnedFile::open(&moved, FILE_READ_ATTRIBUTES, 7)?;
        assert!(identity.same_object(&actual.identity()?));
        Ok(
            serde_json::json!({"passed":true,"result":result,"checkpointCount":1,"source":source,"originalMoved":moved,"originalAndReplacementPreserved":true,"metadataRoot":metadata,"productFaultInjection":false}),
        )
    }
}
