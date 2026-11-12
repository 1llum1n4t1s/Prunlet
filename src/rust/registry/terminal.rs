use super::{
    migration::{self, Intent},
    model::*,
    storage::{self, Held, MoveIdentity, Store},
};
use crate::platform::windows::{self as win, security as sec};
use anyhow::{Context, Result, ensure};
use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{Read, Seek, SeekFrom};
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Terminal {
    schema: u32,
    closed_utc: DateTime<FixedOffset>,
    reason: String,
    binding: Intent,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cleanup {
    schema: u32,
    operation_id: String,
    terminal_sha256: String,
}
fn cleanup_authority(
    store: &Store,
    id: &str,
    terminal: &Held,
    consume: bool,
) -> Result<Option<Held>> {
    let path = store.root.join(format!("{id}.terminal-cleanup.json"));
    if !storage::exists(&path)? {
        return Ok(None);
    }
    ensure!(
        !storage::exists(
            &store
                .root
                .join(format!("{id}.terminal-cleanup.json.pending"))
        )?,
        "Registry terminal cleanup has pending and final controls; both retained."
    );
    let held = read_control(&path, consume)?;
    let cleanup: Cleanup = held.lifecycle()?;
    validate_cleanup(&cleanup, id, &terminal.bytes)?;
    Ok(Some(held))
}
fn validate_cleanup(cleanup: &Cleanup, id: &str, terminal: &[u8]) -> Result<()> {
    ensure!(
        cleanup.schema == 1
            && cleanup.operation_id == id
            && cleanup.terminal_sha256 == hash(terminal),
        "Registry terminal cleanup binding differs."
    );
    Ok(())
}
fn verify_remaining(
    store: &Store,
    id: &str,
    state: &Terminal,
    terminal: &Held,
    consume: bool,
) -> Result<Option<Held>> {
    let authority = cleanup_authority(store, id, terminal, consume)?;
    let partial = authority.is_some();
    let path = store.root.join(id);
    if !storage::exists(&path)? {
        ensure!(
            !storage::exists(
                &store
                    .root
                    .join(format!("{id}.terminal-cleanup.json.pending"))
            )?,
            "Unpublished registry cleanup has no complete source inventory; pending retained."
        );
        ensure!(
            partial
                || state.closed_utc
                    <= storage::now()
                        - chrono::Duration::days(store.config.data.retention_days as i64),
            "Registry terminal directory disappeared before expiry."
        );
        return Ok(authority);
    }
    migration::verify_directory(store, &path, &state.binding, partial)?;
    Ok(authority)
}
fn read_control(path: &std::path::Path, consume: bool) -> Result<Held> {
    if consume {
        Held::read_delete(path)
    } else {
        Held::read(path)
    }
}
fn read(store: &Store, id: &str, consume: bool) -> Result<(Terminal, Held)> {
    operation_id(id)?;
    let pending = storage::exists(&store.root.join(format!("{id}.terminal.json.pending")))?;
    ensure!(
        !(pending && storage::exists(&store.root.join(format!("{id}.terminal.json")))?),
        "Registry terminal has both pending and final controls; both retained."
    );
    ensure!(
        !pending,
        "Registry terminal pending has not been reconciled."
    );
    let held = read_control(&store.root.join(format!("{id}.terminal.json")), consume)?;
    let state: Terminal = held.lifecycle()?;
    migration::validate(store, id, &state.binding)?;
    ensure!(
        state.schema == 1
            && state.closed_utc.timestamp() != -62135596800
            && matches!(state.reason.as_str(), "restored" | "purged")
            && !state
                .binding
                .files
                .iter()
                .any(|f| f.name == storage::SNAPSHOT)
            && state.binding.files.iter().any(|f| f.name
                == storage::receipt_name(
                    if state.reason == "restored" {
                        "restore"
                    } else {
                        "purge"
                    },
                    "complete"
                )),
        "Registry terminal state is invalid."
    );
    Ok((state, held))
}
pub fn capture(store: &Store, id: &str) -> Result<()> {
    let path = store.root.join(format!("{id}.terminal.json"));
    if storage::exists(&path)? {
        let _ = read(store, id, false)?;
        return Ok(());
    }
    if !store.cleanup_publications(id)? {
        return Ok(());
    }
    let record = store.record(id)?;
    if record.ambiguous()
        || record.payload.is_some()
        || (!record.has("restore", "complete") && !record.has("purge", "complete"))
    {
        return Ok(());
    }
    let action = if record.has("restore", "complete") {
        "restore"
    } else {
        "purge"
    };
    let receipt: Receipt = Held::read(
        &record
            .directory
            .join(storage::receipt_name(action, "complete")),
    )?
    .decode()?;
    let state = Terminal {
        schema: 1,
        closed_utc: receipt.created_utc,
        reason: if action == "restore" {
            "restored"
        } else {
            "purged"
        }
        .into(),
        binding: migration::capture(store, &record)?,
    };
    storage::recovery_control(&path, &state)?;
    Ok(())
}
pub fn summary(store: &Store, id: &str) -> Result<Option<Value>> {
    if !storage::exists(&store.root.join(format!("{id}.terminal.json")))? {
        return Ok(None);
    }
    let (state, terminal) = read(store, id, false)?;
    verify_remaining(store, id, &state, &terminal, false)?;
    Ok(Some(
        json!({"operationId":id,"lifecycleState":"closed","originalSchema":5,"terminalReason":state.reason}),
    ))
}
fn expire(store: &Store, id: &str) -> Result<()> {
    let (state, terminal) = read(store, id, true)?;
    #[cfg(test)]
    fault_checkpoint("terminal.decoded", store, id);
    let path = store.root.join(id);
    let mut authority = verify_remaining(store, id, &state, &terminal, true)?;
    #[cfg(test)]
    fault_checkpoint("inventory.verified", store, id);
    let now = storage::now();
    if state.closed_utc > now
        || state.closed_utc > now - chrono::Duration::days(store.config.data.retention_days as i64)
    {
        return Ok(());
    }
    let cleanup_path = store.root.join(format!("{id}.terminal-cleanup.json"));
    let expected = Cleanup {
        schema: 1,
        operation_id: id.into(),
        terminal_sha256: hash(&terminal.bytes),
    };
    // decodeした同一実体とraw bytesを、cleanup公開と消費完了まで固定する。
    if storage::exists(&path)? {
        let directory = win::PinnedFile::open(
            &path,
            windows_sys::Win32::Storage::FileSystem::DELETE
                | windows_sys::Win32::Storage::FileSystem::READ_CONTROL
                | windows_sys::Win32::Storage::FileSystem::FILE_READ_ATTRIBUTES
                | windows_sys::Win32::Storage::FileSystem::FILE_LIST_DIRECTORY,
            1,
        )?;
        storage::verify(&directory, true)?;
        ensure!(
            state
                .binding
                .directory_identity
                .same(&MoveIdentity::of(directory.raw())?)
                && state.binding.directory_security == sec::read_member_security(directory.raw())?,
            "Registry terminal directory changed."
        );
        let expected_names = state
            .binding
            .files
            .iter()
            .map(|f| f.name.clone())
            .collect::<Vec<_>>();
        let names = win::directory_names(directory.raw())?;
        migration::require_membership(&expected_names, &names, authority.is_some())?;
        let mut held = vec![];
        for name in names {
            let saved = state
                .binding
                .files
                .iter()
                .find(|f| f.name == name)
                .context("Unknown terminal recovery member retained")?;
            let pin = sec::open_lifecycle_delete(&path.join(&name))?;
            storage::verify(&pin, false)?;
            ensure!(
                saved.identity.exact(&MoveIdentity::of(pin.raw())?)
                    && saved.security == sec::read_member_security(pin.raw())?,
                "Registry terminal member identity/security changed."
            );
            let mut reader = storage::file(pin.raw())?;
            reader.seek(SeekFrom::Start(0))?;
            ensure!(
                reader.metadata()?.len() == saved.length && saved.length <= MAX_BYTES as u64,
                "Registry terminal member size changed."
            );
            let mut bytes = vec![];
            reader.read_to_end(&mut bytes)?;
            ensure!(
                hash(&bytes) == saved.sha256,
                "Registry terminal member bytes changed."
            );
            drop(reader);
            held.push((name, pin));
        }
        // 全DELETE handleと親を保持した状態で公開直前の完全な集合を再検査する。
        #[cfg(test)]
        fault_checkpoint("members.pinned", store, id);
        storage::verify(&directory, true)?;
        migration::require_membership(
            &expected_names,
            &win::directory_names(directory.raw())?,
            authority.is_some(),
        )?;
        ensure!(
            held.len() == win::directory_names(directory.raw())?.len(),
            "Registry terminal inventory changed while pinning."
        );
        terminal.verify_current()?;
        if let Some(cleanup) = &authority {
            cleanup.verify_current()?;
        } else {
            authority = Some(storage::recovery_control_held(&cleanup_path, &expected)?);
        }
        #[cfg(test)]
        fault_checkpoint("cleanup.pinned", store, id);
        for (name, pin) in &held {
            let saved = state
                .binding
                .files
                .iter()
                .find(|f| &f.name == name)
                .unwrap();
            storage::verify(pin, false)?;
            ensure!(
                saved.identity.exact(&MoveIdentity::of(pin.raw())?)
                    && saved.security == sec::read_member_security(pin.raw())?,
                "Registry terminal member changed before deletion."
            );
            let mut reader = storage::file(pin.raw())?;
            reader.seek(SeekFrom::Start(0))?;
            ensure!(
                reader.metadata()?.len() == saved.length,
                "Registry terminal member size changed before deletion."
            );
            let mut bytes = vec![];
            reader.read_to_end(&mut bytes)?;
            ensure!(
                hash(&bytes) == saved.sha256,
                "Registry terminal member bytes changed before deletion."
            );
            terminal.verify_current()?;
            authority
                .as_ref()
                .context("Missing fixed cleanup authority")?
                .verify_current()?;
            sec::delete_fixed(pin.raw(), false)?;
            #[cfg(test)]
            fault_checkpoint("member.consumed", store, id);
        }
        drop(held);
        sec::delete_fixed(directory.raw(), false)?;
        drop(directory);
    }
    #[cfg(test)]
    fault_checkpoint("cleanup.consume", store, id);
    terminal.verify_current()?;
    if let Some(cleanup) = authority {
        let current: Cleanup = cleanup.lifecycle()?;
        validate_cleanup(&current, id, &terminal.bytes)?;
        cleanup.consume()?;
    } else {
        ensure!(
            !storage::exists(&cleanup_path)?,
            "Unexpected registry cleanup authority retained."
        );
    }
    #[cfg(test)]
    fault_checkpoint("terminal.consume", store, id);
    terminal.consume()?;
    Ok(())
}
pub fn inspect_member(store: &Store, name: &str, apply: bool) -> Result<bool> {
    if let Some(id) = name.strip_suffix(".terminal.json") {
        operation_id(id)?;
        let (state, terminal) = read(store, id, false)?;
        verify_remaining(store, id, &state, &terminal, false)?;
        drop(terminal);
        if apply {
            expire(store, id)?;
        }
        return Ok(true);
    }
    if let Some(id) = name.strip_suffix(".terminal-cleanup.json") {
        operation_id(id)?;
        ensure!(
            !storage::exists(
                &store
                    .root
                    .join(format!("{id}.terminal-cleanup.json.pending"))
            )?,
            "Registry cleanup has both pending and final controls; retained."
        );
        let cleanup: Cleanup = Held::read(&store.root.join(name))?.lifecycle()?;
        let terminal = Held::read(&store.root.join(format!("{id}.terminal.json")))?;
        ensure!(
            cleanup.schema == 1
                && cleanup.operation_id == id
                && cleanup.terminal_sha256 == hash(&terminal.bytes),
            "Registry terminal cleanup binding differs."
        );
        drop(terminal);
        if apply {
            expire(store, id)?;
        }
        return Ok(true);
    }
    if let Some(id) = name.strip_suffix(".terminal.json.pending") {
        operation_id(id)?;
        if apply {
            capture(store, id)?;
        }
        ensure!(
            !storage::exists(&store.root.join(name))?,
            "Registry terminal pending requires fresh record proof; retained."
        );
        return Ok(true);
    }
    if let Some(id) = name.strip_suffix(".terminal-cleanup.json.pending") {
        operation_id(id)?;
        if apply {
            expire(store, id)?;
        }
        ensure!(
            !storage::exists(&store.root.join(name))?,
            "Registry cleanup pending requires fresh record proof; retained."
        );
        return Ok(true);
    }
    Ok(false)
}

// 要求thread内だけの実filesystem競合注入。出荷binaryには含めない。
#[cfg(test)]
type FaultHook = Box<dyn Fn(&str, &Store, &str)>;
#[cfg(test)]
thread_local! {
    static FAULT_HOOK: std::cell::RefCell<Option<FaultHook>> = const { std::cell::RefCell::new(None) };
}
#[cfg(test)]
fn fault_checkpoint(phase: &str, store: &Store, id: &str) {
    FAULT_HOOK.with(|hook| {
        if let Some(callback) = hook.borrow().as_ref() {
            callback(phase, store, id);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_member_before_cleanup_is_refused_without_authority() {
        let expected = vec![
            "operation.lock".into(),
            "registry-manifest.json".into(),
            "registry-purge-complete.json".into(),
        ];
        let missing = vec![
            "operation.lock".into(),
            "registry-purge-complete.json".into(),
        ];
        assert!(migration::require_membership(&expected, &missing, false).is_err());
        let stale = Cleanup {
            schema: 1,
            operation_id: "1".repeat(32),
            terminal_sha256: hash(b"different terminal"),
        };
        assert!(validate_cleanup(&stale, &"1".repeat(32), b"actual terminal").is_err());
    }
    #[test]
    fn authenticated_cleanup_accepts_only_bound_remaining_subset() {
        let id = "1".repeat(32);
        let terminal = b"actual terminal";
        let cleanup = Cleanup {
            schema: 1,
            operation_id: id.clone(),
            terminal_sha256: hash(terminal),
        };
        validate_cleanup(&cleanup, &id, terminal).unwrap();
        let expected = vec![
            "operation.lock".into(),
            "registry-manifest.json".into(),
            "registry-purge-complete.json".into(),
        ];
        let subset = vec!["operation.lock".into()];
        assert!(migration::require_membership(&expected, &subset, true).is_ok());
        let unknown = vec!["foreign.json".into()];
        assert!(migration::require_membership(&expected, &unknown, true).is_err());
    }
    fn filesystem_fixture() -> Result<(crate::config::Config, String)> {
        // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
        let temp = win::path::external_verification_path(&std::env::temp_dir())?;
        let _parents = win::path::pin_directories(&temp)?;
        let base = temp.join(format!(
            "registry-terminal-race-{}",
            uuid::Uuid::new_v4().simple()
        ));
        drop(sec::create_private_directory(&base)?);
        eprintln!("Terminal filesystem fixture retained: {}", base.display());
        let config = crate::config::Config {
            path: base.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: base.to_str().unwrap().into(),
                ..Default::default()
            },
        };
        let store = Store::open(&config, true)?;
        let id = uuid::Uuid::new_v4().simple().to_string();
        let parent = store.create_record(&id)?;
        // 保存集合だけのfixture。実registryや旧版の真正記録としては使用しない。
        for name in [
            storage::MANIFEST.to_string(),
            storage::receipt_name("purge", "complete"),
        ] {
            let file = sec::create_private_file(&store.root.join(&id).join(name))?;
            storage::write_handle(file.raw(), b"synthetic terminal inventory")?;
        }
        let mut files = vec![];
        for name in win::directory_names(parent.raw())? {
            let pin = sec::open_lifecycle_metadata(&store.root.join(&id).join(&name))?;
            let bytes = std::fs::read(store.root.join(&id).join(&name))?;
            files.push(migration::MigrationFile {
                name,
                identity: MoveIdentity::of(pin.raw())?,
                length: bytes.len() as u64,
                sha256: hash(&bytes),
                security: sec::read_member_security(pin.raw())?,
            });
        }
        let terminal = Terminal {
            schema: 1,
            closed_utc: storage::now() - chrono::Duration::days(30),
            reason: "purged".into(),
            binding: Intent {
                schema: 1,
                operation_id: id.clone(),
                metadata_root_identity: store.state.metadata_root_identity.clone(),
                registry_root_identity: store.state.registry_root_identity.clone(),
                machine_name: store.state.machine_name.clone(),
                owner_sid: store.state.owner_sid.clone(),
                directory_identity: MoveIdentity::of(parent.raw())?,
                directory_security: sec::read_member_security(parent.raw())?,
                files,
            },
        };
        storage::recovery_control(&store.root.join(format!("{id}.terminal.json")), &terminal)?;
        drop(parent);
        drop(store);
        Ok((config, id))
    }
    struct HookReset;
    impl Drop for HookReset {
        fn drop(&mut self) {
            FAULT_HOOK.with(|h| *h.borrow_mut() = None);
        }
    }
    #[test]
    fn filesystem_member_removed_after_inventory_preserves_remaining_evidence() -> Result<()> {
        let (config, id) = filesystem_fixture()?;
        let store = Store::open(&config, false)?;
        let terminal_path = store.root.join(format!("{id}.terminal.json"));
        let original = std::fs::read(&terminal_path)?;
        FAULT_HOOK.with(|h| {
            *h.borrow_mut() = Some(Box::new(|phase, store, id| {
                if phase == "inventory.verified" {
                    let pin =
                        sec::open_lifecycle_delete(&store.root.join(id).join(storage::MANIFEST))
                            .unwrap();
                    sec::delete_fixed(pin.raw(), false).unwrap();
                }
            }))
        });
        let _reset = HookReset;
        let error = expire(&store, &id).unwrap_err();
        ensure!(
            error.to_string().contains("membership changed"),
            "Unexpected error: {error:#}"
        );
        ensure!(std::fs::read(&terminal_path)? == original);
        ensure!(!storage::exists(
            &store.root.join(format!("{id}.terminal-cleanup.json"))
        )?);
        ensure!(!storage::exists(
            &store
                .root
                .join(format!("{id}.terminal-cleanup.json.pending"))
        )?);
        let names = win::directory_names(storage::directory(&store.root.join(&id))?.raw())?;
        ensure!(
            names.len() == 2
                && names.contains(&"operation.lock".into())
                && names.contains(&storage::receipt_name("purge", "complete"))
        );
        Ok(())
    }
    #[test]
    fn filesystem_terminal_replacement_is_blocked_from_decode_through_publication() -> Result<()> {
        let (config, id) = filesystem_fixture()?;
        let store = Store::open(&config, false)?;
        let terminal_path = store.root.join(format!("{id}.terminal.json"));
        let original = std::fs::read(&terminal_path)?;
        let replacement = store.root.join("replacement-terminal.json");
        let file = sec::create_private_file(&replacement)?;
        storage::write_handle(file.raw(), b"different terminal state")?;
        drop(file);
        // 同じprivate ACL/Win32置換APIがpin無しなら成功することを先に固定する。
        let control = store.root.join("replace-control.json");
        drop(sec::create_private_file(&control)?);
        let source_name = win::win32_path(&replacement)?;
        let control_name = win::win32_path(&control)?;
        ensure!(
            unsafe {
                windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                    source_name.as_ptr(),
                    control_name.as_ptr(),
                    windows_sys::Win32::Storage::FileSystem::MOVEFILE_REPLACE_EXISTING,
                )
            } != 0,
            "Unpinned replacement control failed: {}",
            std::io::Error::last_os_error()
        );
        let file = sec::create_private_file(&replacement)?;
        storage::write_handle(file.raw(), b"different terminal state")?;
        drop(file);
        let observed = std::rc::Rc::new(std::cell::Cell::new(0u32));
        let count = observed.clone();
        FAULT_HOOK.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |phase, store, id| {
                if matches!(phase, "terminal.decoded" | "members.pinned") {
                    let target = store.root.join(format!("{id}.terminal.json"));
                    let source =
                        win::win32_path(&store.root.join("replacement-terminal.json")).unwrap();
                    let dest = win::win32_path(&target).unwrap();
                    let moved = unsafe {
                        windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                            source.as_ptr(),
                            dest.as_ptr(),
                            windows_sys::Win32::Storage::FileSystem::MOVEFILE_REPLACE_EXISTING,
                        )
                    };
                    assert_eq!(
                        moved, 0,
                        "Terminal replacement succeeded during protected lifetime"
                    );
                    let error = std::io::Error::last_os_error().raw_os_error();
                    assert!(
                        matches!(error, Some(5 | 32)),
                        "Unexpected replacement refusal: {error:?}"
                    );
                    let write = std::fs::OpenOptions::new()
                        .write(true)
                        .open(&target)
                        .unwrap_err();
                    assert_eq!(write.raw_os_error(), Some(32));
                    assert_eq!(std::fs::read(target).unwrap(), original);
                    count.set(count.get() + 1);
                }
            }))
        });
        let _reset = HookReset;
        expire(&store, &id)?;
        ensure!(observed.get() == 2);
        ensure!(!storage::exists(&terminal_path)? && !storage::exists(&store.root.join(&id))?);
        ensure!(std::fs::read(&replacement)? == b"different terminal state");
        Ok(())
    }
    #[test]
    fn filesystem_extra_member_at_publication_preserves_all_members() -> Result<()> {
        let (config, id) = filesystem_fixture()?;
        let store = Store::open(&config, false)?;
        FAULT_HOOK.with(|h| {
            *h.borrow_mut() = Some(Box::new(|phase, store, id| {
                if phase == "members.pinned" {
                    drop(
                        sec::create_private_file(&store.root.join(id).join("foreign-member"))
                            .unwrap(),
                    );
                }
            }))
        });
        let _reset = HookReset;
        let error = expire(&store, &id).unwrap_err();
        ensure!(
            error.to_string().contains("membership changed"),
            "Unexpected error: {error:#}"
        );
        ensure!(!storage::exists(
            &store.root.join(format!("{id}.terminal-cleanup.json"))
        )?);
        ensure!(win::directory_names(storage::directory(&store.root.join(&id))?.raw())?.len() == 4);
        Ok(())
    }
    #[test]
    fn filesystem_authenticated_cleanup_resumes_bound_subset() -> Result<()> {
        let (config, id) = filesystem_fixture()?;
        let store = Store::open(&config, false)?;
        let terminal = std::fs::read(store.root.join(format!("{id}.terminal.json")))?;
        storage::recovery_control(
            &store.root.join(format!("{id}.terminal-cleanup.json")),
            &Cleanup {
                schema: 1,
                operation_id: id.clone(),
                terminal_sha256: hash(&terminal),
            },
        )?;
        let pin = sec::open_lifecycle_delete(&store.root.join(&id).join(storage::MANIFEST))?;
        sec::delete_fixed(pin.raw(), false)?;
        drop(pin);
        expire(&store, &id)?;
        ensure!(
            !storage::exists(&store.root.join(&id))?
                && !storage::exists(&store.root.join(format!("{id}.terminal.json")))?
                && !storage::exists(&store.root.join(format!("{id}.terminal-cleanup.json")))?
        );
        Ok(())
    }
    fn authority_lifetime_fixture(existing: bool) -> Result<()> {
        let (config, id) = filesystem_fixture()?;
        let store = Store::open(&config, false)?;
        let terminal_path = store.root.join(format!("{id}.terminal.json"));
        let terminal_bytes = std::fs::read(&terminal_path)?;
        let cleanup_path = store.root.join(format!("{id}.terminal-cleanup.json"));
        if existing {
            storage::recovery_control(
                &cleanup_path,
                &Cleanup {
                    schema: 1,
                    operation_id: id.clone(),
                    terminal_sha256: hash(&terminal_bytes),
                },
            )?;
        }
        for name in ["terminal-swap.json", "cleanup-swap.json"] {
            let file = sec::create_private_file(&store.root.join(name))?;
            storage::write_handle(file.raw(), b"same-private-ACL different-file evidence")?;
        }
        let counts = std::rc::Rc::new(std::cell::RefCell::new([0usize; 2]));
        let observed = counts.clone();
        FAULT_HOOK.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |phase, store, id| {
                if matches!(
                    phase,
                    "cleanup.pinned" | "member.consumed" | "cleanup.consume" | "terminal.consume"
                ) {
                    for (index, (suffix, replacement)) in [
                        ("terminal.json", "terminal-swap.json"),
                        ("terminal-cleanup.json", "cleanup-swap.json"),
                    ]
                    .iter()
                    .enumerate()
                    {
                        if index == 1 && phase == "terminal.consume" {
                            continue;
                        }
                        let path = store.root.join(format!("{id}.{suffix}"));
                        let before = std::fs::read(&path).unwrap();
                        if index == 0 {
                            assert_eq!(before, terminal_bytes);
                        }
                        let source = win::win32_path(&store.root.join(replacement)).unwrap();
                        let dest = win::win32_path(&path).unwrap();
                        let moved = unsafe {
                            windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                                source.as_ptr(),
                                dest.as_ptr(),
                                windows_sys::Win32::Storage::FileSystem::MOVEFILE_REPLACE_EXISTING,
                            )
                        };
                        assert_eq!(moved, 0, "{suffix} replaced at {phase}");
                        let error = std::io::Error::last_os_error().raw_os_error();
                        assert!(
                            matches!(error, Some(5 | 32)),
                            "Unexpected replacement refusal: {error:?}"
                        );
                        let writer = std::fs::OpenOptions::new()
                            .write(true)
                            .open(&path)
                            .unwrap_err();
                        assert_eq!(writer.raw_os_error(), Some(32));
                        // 名前削除用DELETE accessも同じ固定handleの共有modeで拒否される。
                        assert!(
                            sec::open_lifecycle_delete(&path).is_err(),
                            "{suffix} became deletable at {phase}"
                        );
                        assert_eq!(std::fs::read(&path).unwrap(), before);
                        observed.borrow_mut()[index] += 1;
                    }
                }
            }))
        });
        let _reset = HookReset;
        expire(&store, &id)?;
        ensure!(
            *counts.borrow() == [6, 5],
            "Expected every authority lifetime boundary: {:?}",
            counts.borrow()
        );
        ensure!(
            !storage::exists(&terminal_path)?
                && !storage::exists(&cleanup_path)?
                && !storage::exists(&store.root.join(&id))?
        );
        for name in ["terminal-swap.json", "cleanup-swap.json"] {
            ensure!(
                std::fs::read(store.root.join(name))?
                    == b"same-private-ACL different-file evidence"
            );
        }
        Ok(())
    }
    #[test]
    fn filesystem_new_cleanup_and_terminal_remain_fixed_through_final_disposition() -> Result<()> {
        authority_lifetime_fixture(false)
    }
    #[test]
    fn filesystem_existing_cleanup_and_terminal_remain_fixed_through_final_disposition()
    -> Result<()> {
        authority_lifetime_fixture(true)
    }
    #[test]
    fn filesystem_both_terminal_controls_have_specific_refusal_and_preserve_evidence() -> Result<()>
    {
        let (config, id) = filesystem_fixture()?;
        let store = Store::open(&config, false)?;
        let mut state = store.state.clone();
        state.registry_ready = true;
        state.assessment_complete = true;
        state.complete = true;
        state.legacy_file_policy_version = 2;
        store.save_state(&state)?;
        let terminal_path = store.root.join(format!("{id}.terminal.json"));
        let pending_path = store.root.join(format!("{id}.terminal.json.pending"));
        let bytes = std::fs::read(&terminal_path)?;
        let pending = sec::create_private_file(&pending_path)?;
        storage::write_handle(pending.raw(), &bytes)?;
        drop(pending);
        let before = win::directory_names(storage::directory(&store.root.join(&id))?.raw())?;
        // CLIと同じ共通maintain経路を実ファイルへ通す。native registryの変更はない。
        drop(store);
        let result = super::super::execute(&config, "maintain", &json!({"apply": true}), None)?;
        ensure!(
            result["capacityKnown"] == false,
            "Dual controls were accepted: {result}"
        );
        let warnings = result["warnings"].to_string();
        ensure!(
            warnings.contains("both pending and final controls"),
            "Dual controls refused for unrelated reason: {warnings}"
        );
        ensure!(std::fs::read(&terminal_path)? == bytes && std::fs::read(&pending_path)? == bytes);
        let store = Store::open(&config, false)?;
        let after = win::directory_names(storage::directory(&store.root.join(&id))?.raw())?;
        ensure!(before == after);
        ensure!(!storage::exists(
            &store.root.join(format!("{id}.terminal-cleanup.json"))
        )?);
        Ok(())
    }
}
