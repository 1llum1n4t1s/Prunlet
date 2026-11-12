#![cfg(windows)]
use super::model::*;
use anyhow::{Context, Result, bail, ensure};
use std::{
    ffi::c_void,
    ptr::{null, null_mut},
    sync::Arc,
};
type Handle = *mut c_void;
const QUERY: u32 = 1;
const SET: u32 = 2;
const CREATE: u32 = 4;
const ENUM: u32 = 8;
const READ: u32 = 0x20000;
const DELETE: u32 = 0x10000;
const SACL: u32 = 0x1000000;

#[derive(Debug)]
pub struct WinError(pub u32, pub &'static str);
impl std::fmt::Display for WinError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} (Win32 {}).", self.1, self.0)
    }
}
impl std::error::Error for WinError {}
pub fn missing(e: &anyhow::Error) -> bool {
    e.downcast_ref::<WinError>()
        .is_some_and(|x| matches!(x.0, 2 | 3))
}
#[derive(Debug)]
pub struct TargetMissing;
impl std::fmt::Display for TargetMissing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Registry target is already absent.")
    }
}
impl std::error::Error for TargetMissing {}
pub fn target_missing(e: &anyhow::Error) -> bool {
    e.is::<TargetMissing>()
}
fn check(code: u32, label: &'static str) -> Result<()> {
    if code != 0 {
        Err(WinError(code, label).into())
    } else {
        Ok(())
    }
}
fn ntcheck(code: i32, label: &'static str) -> Result<()> {
    if code < 0 {
        check(unsafe { RtlNtStatusToDosError(code) }, label)
    } else {
        Ok(())
    }
}
fn last(label: &'static str) -> anyhow::Error {
    WinError(unsafe { GetLastError() }, label).into()
}
fn wide(s: &str) -> Result<Vec<u16>> {
    validate_text(s, 32766, true)?;
    Ok(s.encode_utf16().chain(Some(0)).collect())
}
fn text(v: &[u16]) -> Result<String> {
    ensure!(!v.contains(&0), "Registry native text contains NUL.");
    Ok(String::from_utf16(v)?)
}
#[derive(Debug)]
pub struct Key(Handle);
impl Drop for Key {
    fn drop(&mut self) {
        unsafe {
            RegCloseKey(self.0);
        }
    }
}
#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum: u16,
    buffer: *const u16,
}
#[repr(C)]
struct ObjectAttributes {
    length: u32,
    root: Handle,
    name: *mut UnicodeString,
    attributes: u32,
    security: Handle,
    qos: Handle,
}
#[repr(C)]
struct SecurityAttributes {
    length: u32,
    descriptor: *const u8,
    inherit: i32,
}

pub struct Transaction {
    handle: Handle,
    committed: bool,
    held: Vec<Arc<Key>>,
    names: Vec<(Arc<Key>, String)>,
    namespace: Vec<(Target, String, bool)>,
    aliases: Vec<(Arc<Key>, Vec<u8>)>,
}
impl Transaction {
    pub fn new() -> Result<Self> {
        let description = wide("Prunlet registry recovery")?;
        let handle = unsafe { CreateTransaction(null(), null(), 0, 0, 0, 0, description.as_ptr()) };
        ensure!(
            !handle.is_null() && handle as isize != -1,
            "Cannot create registry transaction: {}",
            std::io::Error::last_os_error()
        );
        Ok(Self {
            handle,
            committed: false,
            held: vec![],
            names: vec![],
            namespace: vec![],
            aliases: vec![],
        })
    }
    fn hold(&mut self, key: Arc<Key>) -> Arc<Key> {
        self.held.push(key.clone());
        key
    }
    fn pin(&mut self, key: Arc<Key>) -> Result<()> {
        let name = key_name(&key)?;
        self.names.push((key, name));
        Ok(())
    }
    pub fn has_alias(&self) -> bool {
        !self.aliases.is_empty()
    }
    pub fn verify(&self) -> Result<()> {
        for (key, name) in &self.names {
            ensure!(
                key_name(key)? == *name,
                "A pinned registry key or ancestor was renamed; nothing was committed."
            );
        }
        for (key, bytes) in &self.aliases {
            ensure!(
                read_value(key, "SymbolicLinkValue")?.data == *bytes,
                "Classes alias changed; nothing was committed."
            );
        }
        for (target, name, parent) in &self.namespace {
            let key = traverse(None, target, *parent, 0, false, false, false)?;
            ensure!(
                key_name(&key)? == *name,
                "The requested namespace no longer names the pinned key."
            );
        }
        Ok(())
    }
    pub fn commit(&mut self) -> Result<()> {
        self.verify()?;
        if unsafe { CommitTransaction(self.handle) } == 0 {
            return Err(last("Registry transaction commit was not confirmed"));
        }
        self.committed = true;
        Ok(())
    }
}
impl Drop for Transaction {
    fn drop(&mut self) {
        if !self.committed {
            unsafe {
                RollbackTransaction(self.handle);
            }
        }
        self.held.clear();
        unsafe {
            CloseHandle(self.handle);
        }
    }
}

fn open(
    tx: Option<&Transaction>,
    parent: Option<&Key>,
    name: &str,
    access: u32,
    backup: bool,
    ordinary: bool,
    follow: bool,
) -> Result<Arc<Key>> {
    let chars = wide(name)?;
    let mut unicode = UnicodeString {
        length: ((chars.len() - 1) * 2).try_into()?,
        maximum: (chars.len() * 2).try_into()?,
        buffer: chars.as_ptr(),
    };
    let mut attributes = ObjectAttributes {
        length: std::mem::size_of::<ObjectAttributes>() as u32,
        root: parent.map_or(null_mut(), |k| k.0),
        name: &mut unicode,
        attributes: 0x40
            | if follow {
                0
            } else {
                0x1000 | if ordinary { 0 } else { 0x100 }
            },
        security: null_mut(),
        qos: null_mut(),
    };
    let options = if !ordinary && !follow { 8 } else { 0 } | if backup { 4 } else { 0 };
    let mut raw = null_mut();
    let status = unsafe {
        match tx {
            Some(tx) => {
                NtOpenKeyTransactedEx(&mut raw, access, &mut attributes, options, tx.handle)
            }
            None => NtOpenKeyEx(&mut raw, access, &mut attributes, options),
        }
    };
    if status < 0 {
        if !raw.is_null() {
            unsafe {
                RegCloseKey(raw);
            }
        }
        ntcheck(status, "Cannot open registry key without reparsing")?;
    }
    Ok(Arc::new(Key(raw)))
}
fn ordinary(
    tx: Option<&Transaction>,
    raw: &Key,
    parent: Option<&Key>,
    name: &str,
    access: u32,
    backup: bool,
) -> Result<Arc<Key>> {
    let expected = key_name(raw)?;
    reject_link(raw)?;
    let key = open(tx, parent, name, access, backup, true, false).map_err(|error| {
        if missing(&error) {
            // OPENLINKのraw実体は存在する。未設定link等の通常open失敗を対象不在へ変えない。
            // C# OpenOrdinaryKeyWithModeのIOExceptionと同じ、非missing分類にする。
            anyhow::anyhow!("An existing registry key could not be opened as an ordinary key without reparsing; nothing was committed: {error:#}")
        } else {
            error
        }
    })?;
    ensure!(
        ordinal_eq(&key_name(&key)?, &expected),
        "Registry key changed while opening without reparsing."
    );
    reject_link(&key)?;
    Ok(key)
}
// OSが返す固定hive/alias名は表記の大小を保存する。C# RequireNameと同じordinal比較。
fn require_name(key: &Key, expected: &str) -> Result<()> {
    let actual = key_name(key)?;
    ensure!(
        ordinal_eq(&actual, expected),
        "Registry hive anchor differs: expected {expected}, actual {actual}."
    );
    Ok(())
}
fn reject_link(key: &Key) -> Result<()> {
    match read_value(key, "SymbolicLinkValue") {
        Ok(value) => ensure!(
            value.r#type != 6,
            "Registry link or link-like key is unsupported; nothing was committed."
        ),
        Err(e) => {
            if !missing(&e) {
                return Err(e);
            }
        }
    };
    Ok(())
}
fn view(target: &Target) -> u32 {
    if target.view == "32" { 0x200 } else { 0x100 }
}
fn traverse(
    mut tx: Option<&mut Transaction>,
    target: &Target,
    parent: bool,
    extra: u32,
    security: bool,
    pin: bool,
    stage_alias: bool,
) -> Result<Arc<Key>> {
    let sid = current_sid()?;
    let root = match target.hive.as_str() {
        "HKEY_LOCAL_MACHINE" => "\\Registry\\Machine".into(),
        "HKEY_USERS" => "\\Registry\\User".into(),
        _ => format!("\\Registry\\User\\{sid}"),
    };
    let count = target.segments.len() - usize::from(parent);
    let access = QUERY | ENUM | READ | view(target) | extra | if security { SACL } else { 0 };
    let traversal = QUERY | ENUM | READ | view(target);
    let backup = target.access_mode == "backupRestore";
    let mut all: Vec<Arc<Key>> = vec![];
    let mut pending = vec![];
    let mut current = open(
        None,
        None,
        &root,
        if count == 0 { access } else { traversal },
        backup,
        true,
        false,
    )?;
    require_name(&current, &root)?;
    reject_link(&current)?;
    all.push(current.clone());
    for i in 0..count {
        let segment_access = if i == count - 1 { access } else { traversal };
        let start = if target.hive == "HKEY_CURRENT_USER" {
            Some(0)
        } else if target.hive == "HKEY_USERS"
            && target
                .segments
                .first()
                .is_some_and(|s| s.eq_ignore_ascii_case(&sid))
        {
            Some(1)
        } else {
            None
        };
        let alias = start.is_some_and(|s| {
            i == s + 1
                && target.segments.len() > i + 1
                && target.segments[s].eq_ignore_ascii_case("Software")
                && target.segments[i].eq_ignore_ascii_case("Classes")
        });
        let raw = open(
            if pin || alias { None } else { tx.as_deref() },
            Some(&current),
            &target.segments[i],
            segment_access,
            backup,
            false,
            false,
        )?;
        all.push(raw.clone());
        let link = match read_value(&raw, "SymbolicLinkValue") {
            Ok(v) if v.r#type == 6 => Some(v),
            Ok(_) => None,
            Err(e) if missing(&e) => None,
            Err(e) => return Err(e),
        };
        let next = if alias && link.is_some() {
            let value = link.unwrap();
            let destination = format!("\\Registry\\User\\{sid}_Classes");
            let expected: Vec<u8> = destination
                .encode_utf16()
                .flat_map(u16::to_le_bytes)
                .collect();
            ensure!(
                ordinal_eq(
                    &key_name(&raw)?,
                    &format!("\\Registry\\User\\{sid}\\Software\\Classes")
                ) && value.data == expected,
                "Unsupported Classes alias destination."
            );
            verify_alias(
                &raw,
                &current,
                &target.segments[i],
                &destination,
                traversal,
                &expected,
                backup,
            )?;
            pending.push((raw.clone(), value));
            let user = open(
                None,
                None,
                "\\Registry\\User",
                traversal,
                backup,
                true,
                false,
            )?;
            reject_link(&user)?;
            require_name(&user, "\\Registry\\User")?;
            all.push(user.clone());
            let name = format!("{sid}_Classes");
            let raw_destination = open(
                None,
                Some(&user),
                &name,
                segment_access,
                backup,
                false,
                false,
            )?;
            all.push(raw_destination.clone());
            let next = ordinary(
                if pin { None } else { tx.as_deref() },
                &raw_destination,
                Some(&user),
                &name,
                segment_access,
                backup,
            )?;
            ensure!(
                ordinal_eq(&key_name(&next)?, &destination),
                "Classes destination changed."
            );
            next
        } else {
            ordinary(
                if pin { None } else { tx.as_deref() },
                &raw,
                Some(&current),
                &target.segments[i],
                segment_access,
                backup,
            )?
        };
        all.push(next.clone());
        current = next;
    }
    if let Some(tx) = tx.as_deref_mut() {
        for (key, value) in pending {
            guard_alias(tx, target, key, &value, stage_alias)?;
        }
        for key in all {
            if pin {
                tx.pin(key.clone())?;
            }
            tx.hold(key);
        }
        if pin {
            tx.namespace
                .push((target.clone(), key_name(&current)?, parent));
        }
    }
    Ok(current)
}
fn bind(tx: &mut Transaction, target: &Target, key: &Key, extra: u32) -> Result<Arc<Key>> {
    let bound = open(
        Some(tx),
        Some(key),
        "",
        QUERY | ENUM | READ | extra | view(target),
        target.access_mode == "backupRestore",
        false,
        false,
    )?;
    Ok(tx.hold(bound))
}
fn verify_alias(
    alias: &Key,
    parent: &Key,
    name: &str,
    destination: &str,
    access: u32,
    expected: &[u8],
    backup: bool,
) -> Result<()> {
    let value = read_value(alias, "SymbolicLinkValue")?;
    ensure!(
        value.r#type == 6 && value.data == expected,
        "Classes alias raw metadata differs."
    );
    let resolved = open(None, Some(parent), name, access, backup, false, true)?;
    ensure!(
        ordinal_eq(&key_name(&resolved)?, destination),
        "Classes link metadata does not resolve to its verified destination."
    );
    reject_link(&resolved)?;
    ensure!(
        read_value(alias, "SymbolicLinkValue")? == value,
        "Classes alias changed during inspection."
    );
    Ok(())
}
fn guard_alias(
    tx: &mut Transaction,
    target: &Target,
    key: Arc<Key>,
    value: &ValueSnapshot,
    stage: bool,
) -> Result<()> {
    let bound = bind(tx, target, &key, SET)?;
    ensure!(
        ordinal_eq(&key_name(&bound)?, &key_name(&key)?)
            && read_value(&bound, "SymbolicLinkValue")? == *value,
        "Classes transaction guard differs."
    );
    if stage {
        set_raw(&bound, value)?;
    }
    ensure!(
        read_value(&key, "SymbolicLinkValue")? == *value,
        "Classes alias changed while acquiring transaction guard."
    );
    tx.pin(key.clone())?;
    tx.aliases.push((key, value.data.clone()));
    Ok(())
}

#[cfg(test)]
pub(crate) fn verification_native_contract(
    case: &str,
    fixture_root: &str,
) -> Result<serde_json::Value> {
    with_request_context(|| verification::run(case, fixture_root))
}
#[cfg(test)]
pub(crate) fn verification_security_descriptor(sddl: &str) -> Result<Vec<u8>> {
    verification::descriptor(sddl)
}
#[cfg(test)]
mod verification {
    use super::*;
    use serde_json::json;
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn RegCreateKeyExW(
            parent: Handle,
            name: *const u16,
            reserved: u32,
            class: *const u16,
            options: u32,
            access: u32,
            attributes: *const c_void,
            key: *mut Handle,
            disposition: *mut u32,
        ) -> u32;
        fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text: *const u16,
            revision: u32,
            descriptor: *mut Handle,
            size: *mut u32,
        ) -> i32;
    }
    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn NtRenameKey(key: Handle, name: *mut UnicodeString) -> i32;
    }
    #[test]
    fn real_incomplete_link_is_not_an_absent_ordinary_target() -> Result<()> {
        let owner = Target::new(
            "HKEY_CURRENT_USER\\Software\\PrunletE2E",
            "64",
            None,
            "normal",
        )?;
        let parent = traverse(None, &owner, false, CREATE, false, false, false)?;
        let leaf = uuid::Uuid::new_v4().simple().to_string();
        let fixture = create(&parent, &leaf, false)?;
        let link = create(&fixture, "incomplete", true)?;
        let before_name = key_name(&link)?;
        eprintln!(
            "Incomplete link volatile fixture retained: {}\\{}\\incomplete",
            owner.path, leaf
        );
        let error = ordinary(
            None,
            &link,
            Some(&fixture),
            "incomplete",
            QUERY | ENUM | READ | 0x100,
            false,
        )
        .err()
        .context("Incomplete link was accepted as ordinary")?;
        ensure!(
            !missing(&error) && !target_missing(&error),
            "Existing raw link was classified absent: {error:#}"
        );
        ensure!(
            error.to_string().contains("existing registry key"),
            "Unexpected ordinary refusal: {error:#}"
        );
        let target = Target::new(
            &format!("{}\\{leaf}\\incomplete", owner.path),
            "64",
            None,
            "normal",
        )?;
        let traversal = traverse(None, &target, false, 0, false, false, false)
            .err()
            .context("Incomplete link passed production traversal")?;
        ensure!(
            !missing(&traversal) && !target_missing(&traversal),
            "Production traversal classified existing link absent: {traversal:#}"
        );
        ensure!(key_name(&link)? == before_name && value_names(&link)?.is_empty());
        eprintln!(
            "Actual ordinary-open refusal: {error:#}; production traversal refusal: {traversal:#}"
        );
        Ok(())
    }
    fn create(parent: &Key, name: &str, link: bool) -> Result<Arc<Key>> {
        let mut raw = null_mut();
        let mut disposition = 0;
        check(
            unsafe {
                RegCreateKeyExW(
                    parent.0,
                    wide(name)?.as_ptr(),
                    0,
                    null(),
                    1 | if link { 2 } else { 0 },
                    0xf003f | 0x100,
                    null(),
                    &mut raw,
                    &mut disposition,
                )
            },
            "Cannot create owned volatile registry probe",
        )?;
        let key = Arc::new(Key(raw));
        ensure!(
            disposition == 1,
            "Volatile probe already exists; no existing key was modified."
        );
        Ok(key)
    }
    pub(super) fn descriptor(sddl: &str) -> Result<Vec<u8>> {
        let mut raw = null_mut();
        let mut size = 0;
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide(sddl)?.as_ptr(),
                1,
                &mut raw,
                &mut size,
            )
        } == 0
        {
            return Err(last("Cannot construct probe-only security descriptor"));
        }
        let bytes = unsafe { std::slice::from_raw_parts(raw.cast::<u8>(), size as usize).to_vec() };
        unsafe {
            LocalFree(raw);
        }
        Ok(bytes)
    }
    fn time(key: &Key) -> Result<i64> {
        let mut value = 0;
        check(
            unsafe {
                RegQueryInfoKeyW(
                    key.0,
                    null_mut(),
                    null_mut(),
                    null(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    &mut value,
                )
            },
            "Cannot read probe key timestamp",
        )?;
        Ok(value)
    }
    fn raw_commit(tx: &Transaction) -> (bool, u32) {
        let ok = unsafe { CommitTransaction(tx.handle) } != 0;
        (ok, if ok { 0 } else { unsafe { GetLastError() } })
    }
    fn target(path: &str, value: Option<&str>) -> Result<Target> {
        Target::new(path, "64", value.map(str::to_string), "normal")
    }
    fn rename(key: &Key, name: &str) -> Result<u32> {
        let chars = wide(name)?;
        let mut text = UnicodeString {
            length: ((chars.len() - 1) * 2).try_into()?,
            maximum: (chars.len() * 2).try_into()?,
            buffer: chars.as_ptr(),
        };
        let status = unsafe { NtRenameKey(key.0, &mut text) };
        Ok(if status < 0 {
            unsafe { RtlNtStatusToDosError(status) }
        } else {
            0
        })
    }
    pub fn run(case: &str, fixture: &str) -> Result<serde_json::Value> {
        ensure!(
            matches!(
                case,
                "core-classes-alias-proof-permission-and-staged-commit-conflict"
                    | "core-incomplete-links-cannot-be-used-as-ordinary-keys"
                    | "core-snapshot-publication-fault-rolls-back-staged-value"
            ),
            "Unknown native registry contract probe."
        );
        let root_target = target(fixture, None)?;
        ensure!(
            root_target.segments.len() == 3
                && matches!(
                    root_target.hive.as_str(),
                    "HKEY_CURRENT_USER" | "HKEY_LOCAL_MACHINE"
                )
                && root_target.segments[1] == "PrunletE2E"
                && root_target.segments[0]
                    == if root_target.hive == "HKEY_CURRENT_USER" {
                        "Software"
                    } else {
                        "SYSTEM"
                    },
            "Native probe requires a dedicated PrunletE2E GUID fixture."
        );
        operation_id(&root_target.segments[2])?;
        let scope = verify_native_session_context()?;
        let mut privileges = Privileges::new(true, false, true)?;
        let result = (|| -> Result<serde_json::Value> {
            let _existing_fixture = traverse(None, &root_target, false, 0, false, false, false)?;
            if case == "core-snapshot-publication-fault-rolls-back-staged-value" {
                return publication_fault(&root_target, &scope);
            }
            // 実fixtureの親から、既存の通常データと分離したvolatile link専用領域だけへ作成する。
            let parent = traverse(None, &root_target, true, CREATE, false, false, false)?;
            let container_name = format!("{}-link-probes", root_target.segments[2]);
            let access = 0xf003f | 0x100;
            let container = match open(
                None,
                Some(&parent),
                &container_name,
                access,
                false,
                true,
                false,
            ) {
                Ok(key) => {
                    reject_link(&key)?;
                    key
                }
                Err(e) if missing(&e) => create(&parent, &container_name, false)?,
                Err(e) => return Err(e),
            };
            let leaf = format!("rust-probe-{}", uuid::Uuid::new_v4().simple());
            let probe = create(&container, &leaf, false)?;
            let base = format!(
                "{}\\{}\\{}",
                fixture.rsplit_once('\\').unwrap().0,
                container_name,
                leaf
            );
            let result = if case.contains("incomplete") {
                incomplete(&probe, &base)?
            } else {
                classes(&probe, &base)?
            };
            Ok(
                json!({"passed":true,"case":case,"scope":scope,"volatileFixture":base,"retainedVolatileLinkRoot":format!("{}\\{}",fixture.rsplit_once('\\').unwrap().0,container_name),"evidence":result}),
            )
        })();
        let restored = privileges.finish();
        match (result, restored) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(error), Ok(())) => Err(error),
            (Ok(_), Err(error)) => Err(error),
            (Err(error), Err(restoration)) => {
                bail!("{error} Probe privilege restoration failed: {restoration}")
            }
        }
    }
    fn publication_fault(root: &Target, scope: &Scope) -> Result<serde_json::Value> {
        use std::io::{Read, Seek, SeekFrom, Write};
        let parent = traverse(None, root, false, CREATE, false, false, false)?;
        let leaf = format!("rust-publication-fault-{}", uuid::Uuid::new_v4().simple());
        let key = create(&parent, &leaf, false)?;
        let value = ValueSnapshot {
            name: "sentinel".into(),
            r#type: 3,
            data: vec![42, 0, 255, 0, 251],
        };
        set_raw(&key, &value)?;
        let fixture = format!("{}\\{}", root.path, leaf);
        let tree = target(&fixture, None)?;
        let selected = target(&fixture, Some("sentinel"))?;
        let before = read_snapshot(None, &tree, true)?;
        // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
        let temp =
            crate::platform::windows::path::external_verification_path(&std::env::temp_dir())?;
        let _pins = crate::platform::windows::path::pin_directories(&temp)?;
        let directory = temp.join(format!(
            "registry-publication-fault-{}",
            uuid::Uuid::new_v4().simple()
        ));
        drop(crate::platform::windows::security::create_private_directory(&directory)?);
        let file_path = directory.join("registry-snapshot.json");
        let mut tx = Transaction::new()?;
        let snapshot = delete_snapshot(&mut tx, &selected, false, false)?;
        let bound = bind(&mut tx, &selected, &key, SET)?;
        let staged = read_value(&bound, "sentinel")
            .err()
            .context("Registry value deletion was not actually staged")?;
        ensure!(
            missing(&staged),
            "Staged absence had an unrelated failure: {staged}"
        );
        let expected = super::super::storage::serialize(&snapshot)?;
        let handle = crate::platform::windows::security::create_private_file(&file_path)?;
        super::super::storage::write_handle(handle.raw(), &expected)?;
        let mut stream = super::super::storage::file(handle.raw())?;
        stream.seek(SeekFrom::Start(0))?;
        stream.write_all(&[expected[0] ^ 1])?;
        stream.sync_all()?;
        stream.seek(SeekFrom::Start(0))?;
        let mut actual = vec![];
        stream.read_to_end(&mut actual)?;
        let refused = super::super::storage::validate_publication(
            "registry-snapshot.json",
            &actual,
            &expected,
            expected.len() as u64,
            &hash(&expected),
        )
        .err()
        .context("Corrupted persisted snapshot was accepted before native commit")?;
        ensure!(actual != expected, "Fault did not change persisted bytes.");
        tx.verify()?;
        drop(bound);
        drop(tx);
        let after = read_snapshot(None, &tree, true)?;
        ensure!(
            before.difference(&after).is_none() && read_value(&key, "sentinel")? == value,
            "Publication refusal did not preserve the original registry value/full security."
        );
        crate::platform::windows::security::verify_private_member_security(handle.raw(), false)?;
        Ok(
            json!({"passed":true,"case":"core-snapshot-publication-fault-rolls-back-staged-value","scope":scope,"fixture":fixture,"metadataFixture":file_path,"evidence":{"realTransactionStaged":true,"actualPersistedBytesCorrupted":true,"expectedSha256":hash(&expected),"actualSha256":hash(&actual),"publicationRefused":refused.to_string(),"nativeCommitCalled":false,"originalRegistryRawBytesAndFullSecurityPreserved":true,"privateAclFromCreation":true},"retainedFixture":true}),
        )
    }
    fn incomplete(parent: &Key, base: &str) -> Result<serde_json::Value> {
        let target_key = create(parent, "target", false)?;
        let child = create(&target_key, "child", false)?;
        let plain = create(parent, "ordinary", false)?;
        let link = create(parent, "source", true)?;
        set_raw(
            &target_key,
            &ValueSnapshot {
                name: "sentinel".into(),
                r#type: 3,
                data: vec![42, 0, 255],
            },
        )?;
        set_raw(
            &child,
            &ValueSnapshot {
                name: "sentinel".into(),
                r#type: 3,
                data: vec![17, 18, 19],
            },
        )?;
        set_raw(
            &plain,
            &ValueSnapshot {
                name: "SymbolicLinkValue".into(),
                r#type: 1,
                data: "ordinary text\0"
                    .encode_utf16()
                    .flat_map(u16::to_le_bytes)
                    .collect(),
            },
        )?;
        let real_target = target(&format!("{base}\\target"), None)?;
        let plain_target = target(&format!("{base}\\ordinary"), None)?;
        let before = read_snapshot(None, &real_target, true)?;
        let plain_before = read_snapshot(None, &plain_target, true)?;
        let ordinary_key = ordinary(
            None,
            &plain,
            Some(parent),
            "ordinary",
            QUERY | ENUM | READ | 0x100,
            false,
        )?;
        ensure!(
            key_name(&ordinary_key)? == key_name(&plain)?,
            "Ordinary-key proof returned another key."
        );
        let missing = ordinary(
            None,
            &link,
            Some(parent),
            "source",
            QUERY | ENUM | READ | 0x100,
            false,
        )
        .err()
        .context("Incomplete actual link was accepted as an ordinary key")?;
        let link_target = target(&format!("{base}\\source"), Some("sentinel"))?;
        let mut tx = Transaction::new()?;
        let refusal = delete_snapshot(&mut tx, &link_target, false, true)
            .err()
            .context("Incomplete link passed production deletion preflight")?;
        ensure!(
            !target_missing(&refusal),
            "Incomplete link was falsely reported as an absent target."
        );
        drop(tx);
        let destination = key_name(&target_key)?;
        set_raw(
            &link,
            &ValueSnapshot {
                name: "SymbolicLinkValue".into(),
                r#type: 6,
                data: destination
                    .encode_utf16()
                    .flat_map(u16::to_le_bytes)
                    .collect(),
            },
        )?;
        let restored = ordinary(
            None,
            &link,
            Some(parent),
            "source",
            QUERY | ENUM | READ | 0x100,
            false,
        )
        .err()
        .context("Restored actual link was accepted as ordinary")?;
        let child_failure = open(
            None,
            Some(&link),
            "child",
            QUERY | ENUM | READ | 0x100,
            false,
            false,
            false,
        )
        .err()
        .context("Held raw link parent was followed")?;
        let child_error = child_failure.downcast_ref::<WinError>().map(|e| e.0);
        ensure!(
            child_error == Some(4395),
            "Held raw link parent refusal was not ERROR_REPARSE_POINT_ENCOUNTERED: {child_failure}"
        );
        ensure!(
            before
                .difference(&read_snapshot(None, &real_target, true)?)
                .is_none()
                && plain_before
                    .difference(&read_snapshot(None, &plain_target, true)?)
                    .is_none(),
            "Ordinary-open probe changed raw target data or complete security."
        );
        Ok(
            json!({"ordinaryKeyAccepted":true,"missingMetadataRefused":missing.to_string(),"missingLinkNotAbsent":true,"restoredMetadataRefused":restored.to_string(),"rawParentChildError":child_error,"targetAndOrdinaryPreserved":true}),
        )
    }
    fn classes(parent: &Key, base: &str) -> Result<serde_json::Value> {
        let a = create(parent, "target-a", false)?;
        let b = create(parent, "target-b", false)?;
        let plain = create(parent, "plain", false)?;
        let alias = create(parent, "real", true)?;
        let denied = create(parent, "denied", true)?;
        let sentinel = ValueSnapshot {
            name: "sentinel".into(),
            r#type: 3,
            data: vec![42, 0, 255],
        };
        set_raw(&a, &sentinel)?;
        set_raw(&b, &sentinel)?;
        let destination = key_name(&a)?;
        let value = ValueSnapshot {
            name: "SymbolicLinkValue".into(),
            r#type: 6,
            data: destination
                .encode_utf16()
                .flat_map(u16::to_le_bytes)
                .collect(),
        };
        let changed = ValueSnapshot {
            name: value.name.clone(),
            r#type: 6,
            data: key_name(&b)?
                .encode_utf16()
                .flat_map(u16::to_le_bytes)
                .collect(),
        };
        for key in [&plain, &alias, &denied] {
            set_raw(key, &value)?;
        }
        let a_target = target(&format!("{base}\\target-a"), Some("sentinel"))?;
        let a_tree = target(&format!("{base}\\target-a"), None)?;
        let b_tree = target(&format!("{base}\\target-b"), None)?;
        let a_before = read_snapshot(None, &a_tree, true)?;
        let b_before = read_snapshot(None, &b_tree, true)?;
        let access = QUERY | ENUM | READ | 0x100;
        ensure!(
            verify_alias(
                &plain,
                parent,
                "plain",
                &destination,
                access,
                &value.data,
                false
            )
            .is_err(),
            "Ordinary matching REG_LINK metadata was accepted as a real alias."
        );
        let raw = open(None, Some(parent), "real", access, false, false, false)?;
        verify_alias(
            &raw,
            parent,
            "real",
            &destination,
            access,
            &value.data,
            false,
        )?;
        let alias_target = target(&format!("{base}\\real"), None)?;
        let before = (read_value(&alias, "SymbolicLinkValue")?, time(&alias)?);
        {
            let mut tx = Transaction::new()?;
            guard_alias(&mut tx, &alias_target, raw.clone(), &value, false)?;
        }
        ensure!(
            (read_value(&alias, "SymbolicLinkValue")?, time(&alias)?) == before,
            "Permission-only alias guard wrote bytes or last-write time."
        );
        let denied_raw = open(None, Some(parent), "denied", access, false, false, false)?;
        let saved = security(&denied, false)?;
        let sddl = descriptor(&format!(
            "D:P(D;;0x00000002;;;{})(A;;KA;;;{})(A;;KA;;;SY)",
            current_sid()?,
            current_sid()?
        ))?;
        check(
            unsafe { RegSetKeySecurity(denied.0, 4, sddl.as_ptr()) },
            "Cannot set owned probe-only denied DACL",
        )?;
        let denied_result = (|| -> Result<u32> {
            let before = (read_value(&denied, "SymbolicLinkValue")?, time(&denied)?);
            let mut tx = Transaction::new()?;
            let error = guard_alias(&mut tx, &alias_target, denied_raw, &value, true)
                .err()
                .context("Alias guard bypassed SetValue denial")?;
            let code = error
                .downcast_ref::<WinError>()
                .map(|e| e.0)
                .context("Alias denial had no native Win32 status")?;
            ensure!(
                code == 5,
                "Alias guard refusal was not access denied: {error}"
            );
            drop(tx);
            ensure!(
                (read_value(&denied, "SymbolicLinkValue")?, time(&denied)?) == before,
                "Denied guard changed alias bytes/time."
            );
            Ok(code)
        })();
        check(
            unsafe { RegSetKeySecurity(denied.0, 4, saved.as_ptr()) },
            "Cannot restore owned probe-only DACL",
        )?;
        let denied_error = denied_result?;
        let staged = ValueSnapshot {
            name: "sentinel".into(),
            r#type: 3,
            data: vec![99, 88, 77],
        };
        let mut tx = Transaction::new()?;
        guard_alias(&mut tx, &alias_target, raw, &value, true)?;
        let bound = bind(&mut tx, &a_target, &a, SET)?;
        set_raw(&bound, &staged)?;
        ensure!(
            read_value(&bound, "sentinel")? == staged,
            "Target mutation was not staged."
        );
        tx.verify()?;
        let write_error = unsafe {
            RegSetValueExW(
                alias.0,
                wide(&changed.name)?.as_ptr(),
                0,
                6,
                changed.data.as_ptr(),
                changed.data.len() as u32,
            )
        };
        let (committed, commit_error) = raw_commit(&tx);
        drop(bound);
        drop(tx);
        ensure!(
            write_error == 0 && !committed && read_value(&alias, "SymbolicLinkValue")? == changed,
            "Staged alias guard did not preserve accepted external writer and reject raw commit (write={write_error},commit={commit_error})."
        );
        ensure!(
            a_before
                .difference(&read_snapshot(None, &a_tree, true)?)
                .is_none()
                && b_before
                    .difference(&read_snapshot(None, &b_tree, true)?)
                    .is_none(),
            "Alias guard committed staged target mutation after final verification."
        );
        let rename_alias = create(parent, "rename", true)?;
        set_raw(&rename_alias, &value)?;
        let rename_raw = open(None, Some(parent), "rename", access, false, false, false)?;
        let mut tx = Transaction::new()?;
        guard_alias(&mut tx, &alias_target, rename_raw, &value, true)?;
        let bound = bind(&mut tx, &a_target, &a, SET)?;
        set_raw(&bound, &staged)?;
        tx.verify()?;
        let rename_error = rename(&rename_alias, "renamed")?;
        let mut replacement = None;
        let (mut rename_committed, mut rename_commit_error) = (false, 0);
        if rename_error == 0 {
            let key = create(parent, "rename", true)?;
            set_raw(&key, &changed)?;
            replacement = Some(key);
            (rename_committed, rename_commit_error) = raw_commit(&tx);
        }
        drop(bound);
        drop(tx);
        ensure!(
            rename_error == 6800 || (rename_error == 0 && !rename_committed),
            "Alias rename/replacement was not blocked or rolled back: {rename_error}/{rename_commit_error}"
        );
        ensure!(
            read_value(&rename_alias, "SymbolicLinkValue")? == value
                && replacement.as_ref().is_none_or(
                    |key| read_value(key, "SymbolicLinkValue").is_ok_and(|v| v == changed)
                ),
            "Rename probe changed original or replacement alias bytes."
        );
        ensure!(
            a_before
                .difference(&read_snapshot(None, &a_tree, true)?)
                .is_none()
                && b_before
                    .difference(&read_snapshot(None, &b_tree, true)?)
                    .is_none(),
            "Rename guard did not roll back target mutation."
        );
        Ok(
            json!({"ordinaryMatchingBytesRejected":true,"dryRunNoWrite":true,"deniedSetValueError":denied_error,"externalWriteError":write_error,"rawCommitAccepted":committed,"rawCommitError":commit_error,"writerBytesPreserved":true,"targetMutationRolledBack":true,"renameError":rename_error,"renameCommitError":rename_commit_error,"replacementCreated":replacement.is_some(),"replacementPreserved":true,"renamedSourcePreserved":true}),
        )
    }
}
fn key_name(key: &Key) -> Result<String> {
    let mut size = 0;
    let status = unsafe { NtQueryKey(key.0, 3, null_mut(), 0, &mut size) };
    ensure!(
        status >= 0 || status as u32 == 0xc0000023 || status as u32 == 0x80000005,
        "Cannot query registry key name."
    );
    ensure!(
        (4..=131072).contains(&size),
        "Invalid native registry key name size."
    );
    let mut data = vec![0u8; size as usize];
    ntcheck(
        unsafe { NtQueryKey(key.0, 3, data.as_mut_ptr().cast(), size, &mut size) },
        "Cannot read registry key name",
    )?;
    let length = u32::from_le_bytes(data[..4].try_into()?) as usize;
    ensure!(
        length >= 2 && length <= data.len() - 4 && length % 2 == 0,
        "Invalid native registry key name."
    );
    text(
        &data[4..4 + length]
            .chunks_exact(2)
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
            .collect::<Vec<_>>(),
    )
}
pub fn read_value(key: &Key, name: &str) -> Result<ValueSnapshot> {
    let wide = wide(name)?;
    for _ in 0..4 {
        let mut size = 0;
        let mut kind = 0;
        check(
            unsafe {
                RegQueryValueExW(
                    key.0,
                    wide.as_ptr(),
                    null(),
                    &mut kind,
                    null_mut(),
                    &mut size,
                )
            },
            "Cannot read registry value size",
        )?;
        ensure!(
            size as usize <= MAX_BYTES / 2,
            "Registry value data limit exceeded."
        );
        let mut data = vec![0u8; size as usize];
        let status = unsafe {
            RegQueryValueExW(
                key.0,
                wide.as_ptr(),
                null(),
                &mut kind,
                data.as_mut_ptr(),
                &mut size,
            )
        };
        if status == 234 {
            continue;
        }
        check(status, "Cannot read raw registry value")?;
        data.truncate(size as usize);
        return Ok(ValueSnapshot {
            name: name.into(),
            r#type: kind,
            data,
        });
    }
    bail!("Registry value changed repeatedly during capture.")
}
fn value_names(key: &Key) -> Result<Vec<String>> {
    let mut names = vec![];
    let mut total_units = 0usize;
    for index in 0..=MAX_VALUES as u32 {
        let mut chars = vec![0u16; 16384];
        let mut length = chars.len() as u32;
        let status = unsafe {
            RegEnumValueW(
                key.0,
                index,
                chars.as_mut_ptr(),
                &mut length,
                null(),
                null_mut(),
                null_mut(),
                null_mut(),
            )
        };
        if status == 259 {
            return Ok(names);
        }
        check(status, "Cannot enumerate registry values")?;
        ensure!(names.len() < MAX_VALUES, "Registry value limit exceeded.");
        total_units += length as usize;
        ensure!(
            total_units <= MAX_BYTES / 4,
            "Registry value names exceed snapshot payload limit."
        );
        names.push(text(&chars[..length as usize])?);
    }
    bail!("Registry value enumeration limit exceeded.")
}
fn child_names(key: &Key) -> Result<Vec<String>> {
    let mut names = vec![];
    for index in 0..=MAX_KEYS as u32 {
        let mut chars = [0u16; 256];
        let mut length = 256;
        let status = unsafe {
            RegEnumKeyExW(
                key.0,
                index,
                chars.as_mut_ptr(),
                &mut length,
                null(),
                null_mut(),
                null_mut(),
                null_mut(),
            )
        };
        if status == 259 {
            return Ok(names);
        }
        check(status, "Cannot enumerate registry children")?;
        let name = text(&chars[..length as usize])?;
        validate_text(&name, 255, false)?;
        ensure!(
            !name.contains('\\') && names.len() < MAX_KEYS,
            "Invalid or excessive registry children."
        );
        names.push(name);
    }
    bail!("Registry child limit exceeded.")
}
fn security(key: &Key, full: bool) -> Result<Vec<u8>> {
    let information = if full { 0x10000 } else { 7 };
    let mut size = 0;
    let code = unsafe { RegGetKeySecurity(key.0, information, null_mut(), &mut size) };
    ensure!(
        code == 122 || code == 0,
        "Cannot size registry security (Win32 {code})."
    );
    ensure!(
        size > 0 && size <= 1024 * 1024,
        "Invalid registry security size."
    );
    let mut bytes = vec![0u8; size as usize];
    check(
        unsafe { RegGetKeySecurity(key.0, information, bytes.as_mut_ptr(), &mut size) },
        "Cannot read registry security",
    )?;
    bytes.truncate(size as usize);
    validate_security(&bytes)?;
    ensure!(
        unsafe { IsValidSecurityDescriptor(bytes.as_ptr()) } != 0,
        "Native security descriptor validation failed."
    );
    Ok(bytes)
}
fn node(
    key: &Key,
    relative: &str,
    total_values: &mut usize,
    total_bytes: &mut usize,
) -> Result<KeySnapshot> {
    let mut capacity = 256;
    let (class, last_write) = loop {
        let mut chars = vec![0u16; capacity];
        let mut length = capacity as u32;
        let mut time = 0i64;
        let code = unsafe {
            RegQueryInfoKeyW(
                key.0,
                chars.as_mut_ptr(),
                &mut length,
                null(),
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                &mut time,
            )
        };
        if code == 0 {
            break (text(&chars[..length as usize])?, time);
        }
        check(
            if code == 234 { 0 } else { code },
            "Cannot read registry key information",
        )?;
        ensure!(
            capacity < 32767 && length < 32767,
            "Registry class exceeds native capacity."
        );
        capacity = (capacity * 2).max(length as usize + 1).min(32767);
    };
    let security = security(key, true)?;
    let mut values = vec![];
    *total_bytes +=
        security.len() + (relative.encode_utf16().count() + class.encode_utf16().count()) * 2;
    ensure!(
        *total_bytes <= MAX_BYTES / 2,
        "Registry snapshot payload limit exceeded."
    );
    for name in value_names(key)? {
        let value = read_value(key, &name)?;
        *total_values += 1;
        *total_bytes += value.data.len() + value.name.encode_utf16().count() * 2;
        ensure!(
            *total_values <= MAX_VALUES && *total_bytes <= MAX_BYTES / 2,
            "Registry snapshot limits exceeded."
        );
        values.push(value);
    }
    Ok(KeySnapshot {
        relative_path: relative.into(),
        class,
        security,
        last_write_file_time: last_write,
        values,
    })
}
fn actual_target(key: &Key, target: &Target) -> Result<String> {
    let name = key_name(key)?;
    let leaf = name
        .rsplit('\\')
        .next()
        .context("Missing registry key name")?;
    ensure!(
        ordinal_eq(leaf, target.segments.last().unwrap()),
        "Registry key name differs from request."
    );
    Ok(format!(
        "{}\\{}",
        target.path.rsplit_once('\\').unwrap().0,
        leaf
    ))
}
fn set_raw(key: &Key, value: &ValueSnapshot) -> Result<()> {
    check(
        unsafe {
            RegSetValueExW(
                key.0,
                wide(&value.name)?.as_ptr(),
                0,
                value.r#type,
                value.data.as_ptr(),
                value.data.len() as u32,
            )
        },
        "Cannot restore raw registry value",
    )
}

pub fn delete_snapshot(
    tx: &mut Transaction,
    target: &Target,
    recursive: bool,
    dry_run: bool,
) -> Result<Snapshot> {
    let root = match traverse(
        Some(tx),
        target,
        false,
        if target.value_name.is_some() {
            SET
        } else {
            DELETE
        },
        target.value_name.is_none(),
        true,
        !dry_run,
    ) {
        Ok(root) => root,
        Err(e) if missing(&e) => return Err(TargetMissing.into()),
        Err(e) => return Err(e),
    };
    let mut snapshot = Snapshot {
        scope: None,
        schema: 5,
        path: actual_target(&root, target)?,
        view: target.view.clone(),
        value_name: target.value_name.clone(),
        keys: vec![],
        value: None,
        context_security: None,
    };
    if let Some(requested) = &target.value_name {
        let bound = bind(tx, target, &root, SET)?;
        if !dry_run {
            let code = unsafe { RegDeleteValueW(bound.0, wide(requested)?.as_ptr()) };
            if code == 2 {
                return Err(TargetMissing.into());
            }
            check(code, "Cannot stage registry value deletion")?;
        }
        let name = value_names(&root)?
            .into_iter()
            .find(|n| ordinal_eq(n, requested))
            .ok_or(TargetMissing)?;
        let value = read_value(&root, &name)?;
        snapshot.value_name = Some(name.clone());
        snapshot.context_security = Some(security(&root, false)?);
        if !dry_run {
            set_raw(&bound, &value)?;
            check(
                unsafe { RegDeleteValueW(bound.0, wide(&name)?.as_ptr()) },
                "Cannot reinstate staged registry value deletion",
            )?;
        }
        snapshot.value = Some(value);
        tx.verify()?;
        return Ok(snapshot);
    }
    let mut originals = vec![];
    let root_name = key_name(&root)?;
    fn visit(
        tx: &mut Transaction,
        target: &Target,
        key: Arc<Key>,
        relative: String,
        depth: usize,
        root_name: &str,
        recursive: bool,
        dry: bool,
        originals: &mut Vec<(String, Arc<Key>)>,
    ) -> Result<()> {
        ensure!(
            depth <= MAX_DEPTH && originals.len() < MAX_KEYS,
            "Registry deletion key/depth limit exceeded."
        );
        let expected = format!(
            "{}{}{}",
            root_name,
            if relative.is_empty() { "" } else { "\\" },
            relative
        );
        ensure!(
            key_name(&key)? == expected,
            "Registry key changed during deletion preflight."
        );
        tx.pin(key.clone())?;
        let mut source = target.clone();
        if !relative.is_empty() {
            source.path.push('\\');
            source.path.push_str(&relative);
            source
                .segments
                .extend(relative.split('\\').map(str::to_string));
        }
        tx.namespace.push((source, expected, false));
        originals.push((relative.clone(), key.clone()));
        let children = child_names(&key)?;
        ensure!(
            recursive || children.is_empty(),
            "Registry keys with children require explicit recursive deletion."
        );
        for name in children {
            let access = QUERY | ENUM | READ | DELETE | SACL | view(target);
            let raw = open(
                None,
                Some(&key),
                &name,
                access,
                target.access_mode == "backupRestore",
                false,
                false,
            )?;
            let child = ordinary(
                None,
                &raw,
                Some(&key),
                &name,
                access,
                target.access_mode == "backupRestore",
            )?;
            tx.hold(raw);
            tx.hold(child.clone());
            visit(
                tx,
                target,
                child,
                if relative.is_empty() {
                    name
                } else {
                    format!("{relative}\\{name}")
                },
                depth + 1,
                root_name,
                recursive,
                dry,
                originals,
            )?;
        }
        let bound = bind(tx, target, &key, DELETE)?;
        if !dry {
            ntcheck(
                unsafe { NtDeleteKey(bound.0) },
                "Cannot stage deletion of pinned registry key",
            )?;
        }
        Ok(())
    }
    visit(
        tx,
        target,
        root,
        String::new(),
        0,
        &root_name,
        recursive,
        dry_run,
        &mut originals,
    )?;
    tx.verify()?;
    let (mut total_values, mut total_bytes) = (0, 0);
    for (relative, key) in originals {
        snapshot
            .keys
            .push(node(&key, &relative, &mut total_values, &mut total_bytes)?);
    }
    Ok(snapshot)
}

pub fn restore(tx: &mut Transaction, target: &Target, snapshot: &Snapshot) -> Result<()> {
    if let Some(name) = &target.value_name {
        let original = traverse(Some(tx), target, false, SET, false, true, true)?;
        let bound = bind(tx, target, &original, SET)?;
        let value = snapshot.value.as_ref().context("Value snapshot missing")?;
        set_raw(&bound, value)?;
        match read_value(&original, name) {
            Ok(_) => bail!("Registry value already exists; nothing was overwritten."),
            Err(e) => {
                if !missing(&e) {
                    return Err(e);
                }
            }
        };
        ensure!(
            read_value(&bound, name)? == *value,
            "Restored raw registry value verification failed."
        );
        return Ok(());
    }
    let original = traverse(Some(tx), target, true, CREATE, false, true, true)?;
    let parent = bind(tx, target, &original, CREATE)?;
    let mut keys: std::collections::HashMap<String, Arc<Key>> = std::collections::HashMap::new();
    for node in &snapshot.keys {
        let (container, name) = if node.relative_path.is_empty() {
            (parent.clone(), target.segments.last().unwrap().clone())
        } else {
            let (parent, name) = node
                .relative_path
                .rsplit_once('\\')
                .unwrap_or(("", &node.relative_path));
            (
                keys.get(parent).context("Snapshot parent missing")?.clone(),
                name.into(),
            )
        };
        let mut attributes = SecurityAttributes {
            length: std::mem::size_of::<SecurityAttributes>() as u32,
            descriptor: node.security.as_ptr(),
            inherit: 0,
        };
        let mut key = null_mut();
        let mut disposition = 0;
        let class = wide(&node.class)?;
        check(
            unsafe {
                RegCreateKeyTransactedW(
                    container.0,
                    wide(&name)?.as_ptr(),
                    0,
                    class.as_ptr(),
                    if target.access_mode == "backupRestore" {
                        4
                    } else {
                        0
                    },
                    QUERY | SET | CREATE | ENUM | READ | 0x40000 | SACL | view(target),
                    &mut attributes,
                    &mut key,
                    &mut disposition,
                    tx.handle,
                    null(),
                )
            },
            "Cannot create restored registry key with original security",
        )?;
        let key = Arc::new(Key(key));
        ensure!(
            disposition == 1,
            "Registry key already exists; nothing was overwritten."
        );
        for value in &node.values {
            set_raw(&key, value)?;
        }
        tx.hold(key.clone());
        keys.insert(node.relative_path.clone(), key);
    }
    for node in &snapshot.keys {
        let mut bytes = node.security.clone();
        let mut flags = u16::from_le_bytes([bytes[2], bytes[3]]);
        let mut info = 0;
        if flags & 4 != 0 {
            info |= 4;
            if flags & 0x400 != 0 {
                flags |= 0x100;
            }
        }
        if flags & 0x10 != 0 {
            info |= 8;
            if flags & 0x800 != 0 {
                flags |= 0x200;
            }
        }
        if info != 0 {
            bytes[2..4].copy_from_slice(&flags.to_le_bytes());
            check(
                unsafe { RegSetKeySecurity(keys[&node.relative_path].0, info, bytes.as_ptr()) },
                "Cannot restore exact registry ACL control flags",
            )?;
        }
    }
    let actual = read_snapshot(Some(tx), target, true)?;
    ensure!(
        snapshot.difference(&actual).is_none(),
        "Restored registry key verification failed: {:?}",
        snapshot.difference(&actual)
    );
    Ok(())
}

pub fn read_snapshot(
    mut tx: Option<&mut Transaction>,
    target: &Target,
    recursive: bool,
) -> Result<Snapshot> {
    let root = traverse(
        tx.as_deref_mut(),
        target,
        false,
        0,
        target.value_name.is_none(),
        false,
        false,
    )?;
    let mut snapshot = Snapshot {
        scope: None,
        schema: 5,
        path: actual_target(&root, target)?,
        view: target.view.clone(),
        value_name: target.value_name.clone(),
        keys: vec![],
        value: None,
        context_security: None,
    };
    if let Some(requested) = &target.value_name {
        let name = value_names(&root)?
            .into_iter()
            .find(|n| ordinal_eq(n, requested))
            .ok_or_else(|| WinError(2, "Registry value is absent"))?;
        snapshot.value_name = Some(name.clone());
        snapshot.value = Some(read_value(&root, &name)?);
        snapshot.context_security = Some(security(&root, false)?);
        return Ok(snapshot);
    }
    fn capture(
        tx: Option<&Transaction>,
        target: &Target,
        key: &Key,
        relative: String,
        depth: usize,
        recursive: bool,
        snapshot: &mut Snapshot,
        total_values: &mut usize,
        total_bytes: &mut usize,
    ) -> Result<()> {
        ensure!(
            depth <= MAX_DEPTH && snapshot.keys.len() < MAX_KEYS,
            "Registry snapshot key/depth limit exceeded."
        );
        let children = child_names(key)?;
        ensure!(
            recursive || children.is_empty(),
            "Registry keys with children require explicit recursive deletion."
        );
        snapshot
            .keys
            .push(node(key, &relative, total_values, total_bytes)?);
        for name in children {
            let access = QUERY | ENUM | READ | SACL | view(target);
            let raw = open(
                tx,
                Some(key),
                &name,
                access,
                target.access_mode == "backupRestore",
                false,
                false,
            )?;
            let child = ordinary(
                tx,
                &raw,
                Some(key),
                &name,
                access,
                target.access_mode == "backupRestore",
            )?;
            capture(
                tx,
                target,
                &child,
                if relative.is_empty() {
                    name
                } else {
                    format!("{relative}\\{name}")
                },
                depth + 1,
                recursive,
                snapshot,
                total_values,
                total_bytes,
            )?;
        }
        Ok(())
    }
    capture(
        tx.as_deref(),
        target,
        &root,
        String::new(),
        0,
        recursive,
        &mut snapshot,
        &mut 0,
        &mut 0,
    )?;
    Ok(snapshot)
}

pub fn current_sid() -> Result<String> {
    let token = Token::effective(8)?;
    let bytes = token.information(1)?;
    ensure!(
        bytes.len() >= std::mem::size_of::<Handle>(),
        "Invalid token user information."
    );
    let sid = unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast::<Handle>()) };
    let mut output = null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut output) } == 0 {
        return Err(last("Cannot read current user SID"));
    }
    let mut n = 0;
    unsafe {
        while *output.add(n) != 0 {
            n += 1;
        }
        let result = String::from_utf16(std::slice::from_raw_parts(output, n));
        LocalFree(output.cast());
        Ok(result?)
    }
}
pub fn verify_native_session_context() -> Result<Scope> {
    let mut length = 0;
    let package = unsafe { GetCurrentPackageFullName(&mut length, null_mut()) };
    ensure!(
        package == 15700,
        "Start registry-session explicitly outside a packaged host."
    );
    let sid = current_sid()?;
    for view in ["64", "32"] {
        let target = Target::new("HKEY_CURRENT_USER\\Software", view, None, "normal")?;
        let original = traverse(None, &target, false, 0, false, false, false)?;
        let expected = format!("\\Registry\\User\\{sid}\\Software");
        ensure!(
            ordinal_eq(&key_name(&original)?, &expected),
            "Session HKCU Software is not the native Windows user hive."
        );
        let mut tx = Transaction::new()?;
        let bound = bind(&mut tx, &target, &original, 0)?;
        ensure!(
            ordinal_eq(&key_name(&bound)?, &expected),
            "Session registry transaction is not bound to native Windows Software."
        );
    }
    let target = Target::new(
        "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography",
        "64",
        None,
        "normal",
    )?;
    let key = traverse(None, &target, false, 0, false, false, false)?;
    let guid = read_value(&key, "MachineGuid")?;
    ensure!(
        guid.r#type == 1 && (4..=256).contains(&guid.data.len()),
        "Native Windows machine identity is unavailable."
    );
    Ok(Scope {
        kind: "nativeWindows".into(),
        machine_id: hash(&guid.data),
        owner_sid: sid,
    })
}
struct Token(Handle);
// 所有token handleを専用threadへ一度だけ移す。参照の共有やprocess token変更はしない。
unsafe impl Send for Token {}
pub fn with_request_context(
    action: impl FnOnce() -> Result<serde_json::Value> + Send,
) -> Result<serde_json::Value> {
    let caller = Token::effective(0xa)?;
    let mut raw = null_mut();
    if unsafe { DuplicateTokenEx(caller.0, 0x2002f, null(), 2, 2, &mut raw) } == 0 {
        return Err(last("Cannot isolate registry request token"));
    }
    let token = Token(raw);
    std::thread::scope(|scope| {
        scope.spawn(move||{
        let token=token;
        if unsafe{SetThreadToken(null(),token.0)}==0{return Err(last("Cannot establish isolated registry request token"));}
        let outcome=action();
        if unsafe{SetThreadToken(null(),null_mut())}==0{
            let id=outcome.as_ref().ok().and_then(|v|v.get("operationId")).and_then(serde_json::Value::as_str).unwrap_or("unknown");
            bail!("Registry worker token restoration failed; the dedicated request thread has terminated. Do not repeat deletion or restoration; inspect registry-reconcile {id}. Outcome: {}",outcome.as_ref().err().map(ToString::to_string).unwrap_or_else(||"the operation may already be committed".into()));
        }
        outcome
    }).join().map_err(|_|anyhow::anyhow!("Registry request worker terminated unexpectedly. Outcome may be unknown; do not resend deletion or restoration; use registry-reconcile."))?
    })
}
impl Drop for Token {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
impl Token {
    fn effective(access: u32) -> Result<Self> {
        let mut raw = null_mut();
        if unsafe { OpenThreadToken(GetCurrentThread(), access, 0, &mut raw) } == 0 {
            let error = unsafe { GetLastError() };
            check(
                if error == 1008 { 0 } else { error },
                "Cannot open effective thread token",
            )?;
            if unsafe { OpenProcessToken(GetCurrentProcess(), access, &mut raw) } == 0 {
                return Err(last("Cannot open process token"));
            }
        }
        Ok(Self(raw))
    }
    fn information(&self, kind: u32) -> Result<Vec<u8>> {
        let mut size = 0;
        unsafe {
            GetTokenInformation(self.0, kind, null_mut(), 0, &mut size);
        }
        ensure!(
            size > 0 && size < 1024 * 1024,
            "Invalid token information size."
        );
        let mut bytes = vec![0u8; size as usize];
        if unsafe { GetTokenInformation(self.0, kind, bytes.as_mut_ptr().cast(), size, &mut size) }
            == 0
        {
            return Err(last("Cannot read effective token information"));
        }
        Ok(bytes)
    }
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Luid {
    low: u32,
    high: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct TokenPrivilege {
    count: u32,
    luid: Luid,
    attributes: u32,
}
pub struct Privileges {
    token: Token,
    previous: Vec<TokenPrivilege>,
    original: Vec<u8>,
    isolated: bool,
    previous_token: Option<Token>,
}
impl Privileges {
    pub fn new(restore: bool, backup: bool, full_security: bool) -> Result<Self> {
        let current = Token::effective(0xe)?;
        let mut previous = null_mut();
        let previous_token =
            if unsafe { OpenThreadToken(GetCurrentThread(), 0xc, 1, &mut previous) } != 0 {
                Some(Token(previous))
            } else {
                let error = unsafe { GetLastError() };
                check(
                    if error == 1008 { 0 } else { error },
                    "Cannot capture current thread token",
                )?;
                None
            };
        let mut duplicate = null_mut();
        if unsafe { DuplicateTokenEx(current.0, 0x2002f, null(), 2, 2, &mut duplicate) } == 0 {
            return Err(last("Cannot isolate effective registry caller token"));
        }
        let token = Token(duplicate);
        let original = token.information(3)?;
        if unsafe { SetThreadToken(null(), token.0) } == 0 {
            return Err(last("Cannot impersonate isolated registry caller"));
        }
        let mut scope = Self {
            original,
            token,
            previous: vec![],
            isolated: true,
            previous_token,
        };
        let names: Vec<_> = [
            ("SeSecurityPrivilege", full_security),
            ("SeBackupPrivilege", backup),
            ("SeRestorePrivilege", restore || backup),
        ]
        .into_iter()
        .filter_map(|(n, b)| b.then_some(n))
        .collect();
        let enabled = (|| -> Result<()> {
            for name in names {
                let mut luid = Luid { low: 0, high: 0 };
                if unsafe { LookupPrivilegeValueW(null(), wide(name)?.as_ptr(), &mut luid) } == 0 {
                    return Err(last("Cannot resolve registry security privilege"));
                }
                let requested = TokenPrivilege {
                    count: 1,
                    luid,
                    attributes: 2,
                };
                let mut old = TokenPrivilege {
                    count: 0,
                    luid,
                    attributes: 0,
                };
                let mut returned = 0;
                unsafe {
                    SetLastError(0);
                }
                if unsafe {
                    AdjustTokenPrivileges(
                        scope.token.0,
                        0,
                        &requested,
                        std::mem::size_of::<TokenPrivilege>() as u32,
                        &mut old,
                        &mut returned,
                    )
                } == 0
                {
                    return Err(last("Cannot enable registry security privilege"));
                }
                let error = unsafe { GetLastError() };
                if error == 1300 {
                    bail!(
                        "{name} is absent from the effective token. The explicit registry access mode or complete key ACL preservation requires an appropriately privileged process; no elevation or ACL changes were attempted."
                    );
                }
                check(error, "Cannot enable registry security privilege")?;
                scope.previous.push(old);
            }
            Ok(())
        })();
        if let Err(failure) = enabled {
            if let Err(restoration) = scope.finish() {
                bail!("{failure} Privilege restoration also failed: {restoration}");
            }
            return Err(failure);
        }
        Ok(scope)
    }
    pub fn finish(&mut self) -> Result<()> {
        let mut failures = vec![];
        for old in self.previous.drain(..).rev() {
            unsafe {
                SetLastError(0);
            }
            if unsafe { AdjustTokenPrivileges(self.token.0, 0, &old, 0, null_mut(), null_mut()) }
                == 0
                || unsafe { GetLastError() } != 0
            {
                failures.push("privilege restoration failed");
            }
        }
        match self.token.information(3) {
            Ok(bytes) if bytes == self.original => {}
            _ => failures
                .push("effective token privilege attributes could not be restored and verified"),
        }
        if self.isolated {
            if unsafe {
                SetThreadToken(
                    null(),
                    self.previous_token.as_ref().map_or(null_mut(), |t| t.0),
                )
            } == 0
            {
                failures.push("thread impersonation restoration failed");
            } else {
                self.isolated = false;
            }
        }
        ensure!(failures.is_empty(), "{}", failures.join("; "));
        Ok(())
    }
}
impl Drop for Privileges {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtOpenKeyEx(
        key: *mut Handle,
        access: u32,
        attributes: *mut ObjectAttributes,
        options: u32,
    ) -> i32;
    fn NtOpenKeyTransactedEx(
        key: *mut Handle,
        access: u32,
        attributes: *mut ObjectAttributes,
        options: u32,
        tx: Handle,
    ) -> i32;
    fn NtQueryKey(
        key: Handle,
        class: u32,
        buffer: *mut c_void,
        length: u32,
        required: *mut u32,
    ) -> i32;
    fn NtDeleteKey(key: Handle) -> i32;
    fn RtlNtStatusToDosError(status: i32) -> u32;
}
#[link(name = "ktmw32")]
unsafe extern "system" {
    fn CreateTransaction(
        attributes: *const c_void,
        uow: *const c_void,
        options: u32,
        isolation: u32,
        flags: u32,
        timeout: u32,
        description: *const u16,
    ) -> Handle;
    fn CommitTransaction(tx: Handle) -> i32;
    fn RollbackTransaction(tx: Handle) -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CloseHandle(handle: Handle) -> i32;
    fn GetLastError() -> u32;
    fn SetLastError(error: u32);
    fn GetCurrentThread() -> Handle;
    fn GetCurrentProcess() -> Handle;
    fn LocalFree(ptr: Handle) -> Handle;
    fn GetCurrentPackageFullName(length: *mut u32, name: *mut u16) -> u32;
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn RegCloseKey(key: Handle) -> u32;
    fn RegQueryValueExW(
        key: Handle,
        name: *const u16,
        reserved: *const c_void,
        kind: *mut u32,
        data: *mut u8,
        size: *mut u32,
    ) -> u32;
    fn RegEnumValueW(
        key: Handle,
        index: u32,
        name: *mut u16,
        length: *mut u32,
        reserved: *const c_void,
        kind: *mut u32,
        data: *mut u8,
        size: *mut u32,
    ) -> u32;
    fn RegEnumKeyExW(
        key: Handle,
        index: u32,
        name: *mut u16,
        length: *mut u32,
        reserved: *const c_void,
        class: *mut u16,
        class_length: *mut u32,
        time: *mut i64,
    ) -> u32;
    fn RegQueryInfoKeyW(
        key: Handle,
        class: *mut u16,
        class_length: *mut u32,
        reserved: *const c_void,
        children: *mut u32,
        max_child: *mut u32,
        max_class: *mut u32,
        values: *mut u32,
        max_value: *mut u32,
        max_data: *mut u32,
        security: *mut u32,
        time: *mut i64,
    ) -> u32;
    fn RegGetKeySecurity(key: Handle, info: u32, data: *mut u8, size: *mut u32) -> u32;
    fn RegSetKeySecurity(key: Handle, info: u32, data: *const u8) -> u32;
    fn IsValidSecurityDescriptor(data: *const u8) -> i32;
    fn RegDeleteValueW(key: Handle, name: *const u16) -> u32;
    fn RegSetValueExW(
        key: Handle,
        name: *const u16,
        reserved: u32,
        kind: u32,
        data: *const u8,
        length: u32,
    ) -> u32;
    fn RegCreateKeyTransactedW(
        parent: Handle,
        name: *const u16,
        reserved: u32,
        class: *const u16,
        options: u32,
        access: u32,
        attributes: *mut SecurityAttributes,
        key: *mut Handle,
        disposition: *mut u32,
        tx: Handle,
        extended: *const c_void,
    ) -> u32;
    fn OpenThreadToken(thread: Handle, access: u32, as_self: i32, token: *mut Handle) -> i32;
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        kind: u32,
        data: *mut c_void,
        length: u32,
        returned: *mut u32,
    ) -> i32;
    fn ConvertSidToStringSidW(sid: Handle, text: *mut *mut u16) -> i32;
    fn DuplicateTokenEx(
        existing: Handle,
        access: u32,
        security: *const c_void,
        level: u32,
        kind: u32,
        duplicate: *mut Handle,
    ) -> i32;
    fn SetThreadToken(thread: *const Handle, token: Handle) -> i32;
    fn LookupPrivilegeValueW(system: *const u16, name: *const u16, luid: *mut Luid) -> i32;
    fn AdjustTokenPrivileges(
        token: Handle,
        disable: i32,
        state: *const TokenPrivilege,
        length: u32,
        previous: *mut TokenPrivilege,
        returned: *mut u32,
    ) -> i32;
}

#[cfg(test)]
mod name_contract_tests {
    use super::*;
    #[test]
    fn real_native_hive_names_follow_windows_ordinal_contract() -> Result<()> {
        let sid = current_sid()?;
        for expected in [
            "\\Registry\\Machine".to_string(),
            "\\Registry\\User".to_string(),
            format!("\\Registry\\User\\{sid}"),
        ] {
            let key = open(
                None,
                None,
                &expected,
                QUERY | ENUM | READ,
                false,
                true,
                false,
            )?;
            let actual = key_name(&key)?;
            eprintln!(
                "Readonly hive name proof: expected={expected} actual={actual} exact={}",
                actual == expected
            );
            require_name(&key, &expected)?;
            require_name(&key, &expected.to_ascii_uppercase())?;
            require_name(&key, &expected.to_ascii_lowercase())?;
            ensure!(require_name(&key, &format!("{expected}\\different-hive")).is_err());
        }
        // NtQueryKeyの名前検査まで実際の通常traversalを通す。Tx/書込/fixture作成はしない。
        for view in ["64", "32"] {
            let target = Target::new("HKEY_CURRENT_USER\\Software", view, None, "normal")?;
            let key = traverse(None, &target, false, 0, false, false, false)?;
            require_name(&key, &format!("\\Registry\\User\\{sid}\\Software"))?;
        }
        Ok(())
    }
}
