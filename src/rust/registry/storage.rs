#![cfg(windows)]
use super::model::*;
use crate::{
    config::Config,
    platform::windows::{self as win, OwnedHandle, PinnedFile, security as sec},
};
use anyhow::{Context, Result, bail, ensure};
use chrono::{DateTime, FixedOffset, Timelike, Utc};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    borrow::Cow,
    collections::HashSet,
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    os::windows::io::FromRawHandle,
    path::{Path, PathBuf},
    ptr::null_mut,
};
use windows_sys::Win32::{Foundation::*, Storage::FileSystem::*, System::Threading::*};

pub const ROOT: &str = ".registry-records-v1";
pub const MANIFEST: &str = "registry-manifest.json";
pub const SNAPSHOT: &str = "registry-snapshot.json";
pub fn now() -> DateTime<FixedOffset> {
    let time = Utc::now();
    time.with_nanosecond(time.nanosecond() / 100 * 100)
        .unwrap()
        .fixed_offset()
}
// 所有予約のhashは.NET由来の途中公開にも一致させる。日時専用writerは文字列encoderを通らない。
pub fn serialize<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let bytes = super::session::dotnet_serialize(value)?;
    let source = std::str::from_utf8(&bytes)?;
    let pattern = regex::Regex::new(r#""(createdUtc|closedUtc)": "((?:\\.|[^"\\])*)""#)?;
    let mut output = String::with_capacity(source.len());
    let mut previous = 0;
    for captures in pattern.captures_iter(source) {
        let whole = captures.get(0).unwrap();
        let encoded = captures.get(2).unwrap();
        let text: String = serde_json::from_str(&format!("\"{}\"", encoded.as_str()))?;
        let date = DateTime::parse_from_rfc3339(&text)?;
        let mut rendered = date.format("%Y-%m-%dT%H:%M:%S").to_string();
        let fraction = date.nanosecond() / 100;
        if fraction != 0 {
            rendered.push('.');
            rendered.push_str(format!("{fraction:07}").trim_end_matches('0'));
        }
        rendered.push_str(&date.format("%:z").to_string());
        output.push_str(&source[previous..encoded.start()]);
        output.push_str(&rendered);
        previous = encoded.end();
        let _ = whole;
    }
    output.push_str(&source[previous..]);
    let source = output;
    let pattern = regex::Regex::new(
        r#""(security|data|contextSecurity|directorySecurity)": "((?:\\.|[^"\\])*)""#,
    )?;
    let mut output = String::with_capacity(source.len());
    let mut previous = 0;
    for captures in pattern.captures_iter(&source) {
        let encoded = captures.get(2).unwrap();
        let text: String = serde_json::from_str(&format!("\"{}\"", encoded.as_str()))?;
        output.push_str(&source[previous..encoded.start()]);
        output.push_str(&text);
        previous = encoded.end();
    }
    output.push_str(&source[previous..]);
    Ok(output.into_bytes())
}
fn none_zero(n: &u32) -> bool {
    *n == 0
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Layout {
    schema: u32,
    kind: String,
    operation_id: String,
    directory_identity: String,
    metadata_root_identity: String,
    machine_name: String,
    owner_sid: String,
    nonce: String,
    #[serde(default, skip_serializing_if = "none_zero")]
    publication_protocol: u32,
}
fn read_layout(path: &Path) -> Result<Layout> {
    let held = Held::read(path)?;
    ensure!(
        held.bytes.len() <= 8192,
        "Registry layout marker exceeds its size limit."
    );
    held.lifecycle()
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RootIntent {
    schema: u32,
    root_kind: String,
    stage_name: String,
    nonce: String,
    metadata_root_identity: String,
    machine_name: String,
    owner_sid: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct State {
    pub schema: u32,
    pub metadata_root_identity: String,
    pub registry_root_identity: String,
    pub machine_name: String,
    pub owner_sid: String,
    pub registry_ready: bool,
    pub assessment_complete: bool,
    pub complete: bool,
    pub retained_count: u32,
    #[serde(default, skip_serializing_if = "none_zero")]
    pub legacy_file_policy_version: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MoveIdentity {
    volume_serial_number: u64,
    file_id: String,
    is_directory: bool,
    reparse_tag: u32,
    attributes: u32,
}
impl MoveIdentity {
    pub fn of(handle: HANDLE) -> Result<Self> {
        let i = win::identity(handle)?;
        Ok(Self {
            volume_serial_number: i.volume,
            file_id: hex::encode_upper(i.id),
            is_directory: i.is_directory(),
            reparse_tag: i.reparse_tag,
            attributes: i.attributes,
        })
    }
    pub fn same(&self, other: &Self) -> bool {
        self.volume_serial_number == other.volume_serial_number
            && self.file_id.eq_ignore_ascii_case(&other.file_id)
            && self.is_directory == other.is_directory
            && self.reparse_tag == other.reparse_tag
    }
    pub fn exact(&self, other: &Self) -> bool {
        self.same(other) && self.attributes == other.attributes
    }
    pub fn valid(&self) -> bool {
        self.file_id.len() == 32
            && self.file_id.bytes().all(|b| b.is_ascii_hexdigit())
            && !self.file_id.bytes().all(|b| b == b'0')
            && self.reparse_tag == 0
            && self.attributes & 0x400 == 0
            && self.is_directory == (self.attributes & 0x10 != 0)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Publication {
    schema: u32,
    operation_id: String,
    metadata_root_identity: String,
    registry_root_identity: String,
    machine_name: String,
    owner_sid: String,
    directory_identity: MoveIdentity,
    final_name: String,
    pending_name: String,
    pending_identity: MoveIdentity,
    length: u64,
    sha256: String,
    created_utc: DateTime<FixedOffset>,
}

// Fileの所有権はDuplicateHandleで分け、実体を固定する元handleを保存する。
pub fn file(handle: HANDLE) -> Result<File> {
    unsafe {
        let mut copy = null_mut();
        let process = GetCurrentProcess();
        if DuplicateHandle(
            process,
            handle,
            process,
            &mut copy,
            0,
            0,
            DUPLICATE_SAME_ACCESS,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(File::from_raw_handle(copy))
    }
}
pub fn legacy_identity(handle: HANDLE) -> Result<String> {
    unsafe {
        let mut info: BY_HANDLE_FILE_INFORMATION = std::mem::zeroed();
        if GetFileInformationByHandle(handle, &mut info) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(format!(
            "{:08x}:{:08x}{:08x}",
            info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow
        ))
    }
}
pub fn machine() -> Result<String> {
    unsafe {
        let mut text = vec![0u16; 32768];
        let mut length = text.len() as u32;
        if GetComputerNameW(text.as_mut_ptr(), &mut length) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(String::from_utf16(&text[..length as usize])?)
    }
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetComputerNameW(name: *mut u16, length: *mut u32) -> i32;
}
pub fn exists(path: &Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.into()),
    }
}
pub fn verify(pin: &PinnedFile, directory: bool) -> Result<()> {
    let id = pin.identity()?;
    ensure!(
        id.is_directory() == directory && !id.is_reparse() && (directory || id.links == 1),
        "Registry metadata must be a plain single-link member."
    );
    pin.verify_named()?;
    sec::verify_private_security(pin.raw(), directory, false)?;
    win::reject_named_streams(&pin.final_path()?)?;
    if directory {
        pin.reject_case_sensitive()?;
    }
    pin.verify_named()?;
    Ok(())
}
pub fn directory(path: &Path) -> Result<PinnedFile> {
    win::path::reject_reparse_ancestors(path)?;
    let pin = PinnedFile::open(
        path,
        READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY,
        3,
    )?;
    verify(&pin, true)?;
    Ok(pin)
}
pub struct Held {
    pub pin: PinnedFile,
    pub bytes: Vec<u8>,
    security: Vec<u8>,
}
impl Held {
    pub fn read(path: &Path) -> Result<Self> {
        Self::from_pin(sec::open_lifecycle_metadata(path)?)
    }
    // 消費専用。閲覧用readにはDELETE権限を追加しない。
    pub fn read_delete(path: &Path) -> Result<Self> {
        Self::from_pin(sec::open_lifecycle_delete(path)?)
    }
    fn from_pin(pin: PinnedFile) -> Result<Self> {
        verify(&pin, false)?;
        let security = sec::read_member_security(pin.raw())?;
        let mut reader = file(pin.raw())?;
        let size = reader.metadata()?.len();
        ensure!(
            size > 0 && size <= MAX_BYTES as u64,
            "Registry metadata size is invalid."
        );
        let mut bytes = vec![0u8; size as usize];
        reader.seek(SeekFrom::Start(0))?;
        reader.read_exact(&mut bytes)?;
        pin.require_unchanged()?;
        pin.verify_named()?;
        ensure!(
            security == sec::read_member_security(pin.raw())?,
            "Fixed registry metadata security changed while reading."
        );
        Ok(Self {
            pin,
            bytes,
            security,
        })
    }
    // 読み取った同じDELETE handleを最終dispositionまで保持する。再openしない。
    pub fn consume(self) -> Result<()> {
        self.verify_current()?;
        sec::delete_fixed(self.pin.raw(), false)
    }
    pub fn decode<T: DeserializeOwned + Serialize>(&self) -> Result<T> {
        decode(&self.bytes)
    }
    pub fn lifecycle<T: DeserializeOwned + Serialize>(&self) -> Result<T> {
        decode_lifecycle(&self.bytes)
    }
    pub fn verify_current(&self) -> Result<()> {
        verify(&self.pin, false)?;
        ensure!(
            self.security == sec::read_member_security(self.pin.raw())?,
            "Fixed registry metadata security changed."
        );
        self.pin.require_unchanged()?;
        let mut reader = file(self.pin.raw())?;
        let size = reader.metadata()?.len();
        ensure!(
            size == self.bytes.len() as u64 && size <= MAX_BYTES as u64,
            "Fixed registry publication size changed before commit."
        );
        reader.seek(SeekFrom::Start(0))?;
        let mut actual = vec![0u8; size as usize];
        reader.read_exact(&mut actual)?;
        ensure!(
            actual == self.bytes,
            "Fixed registry publication bytes changed before commit."
        );
        self.pin.require_unchanged()?;
        self.pin.verify_named()?;
        Ok(())
    }
}
pub fn validate_publication(
    name: &str,
    actual: &[u8],
    expected: &[u8],
    length: u64,
    sha: &str,
) -> Result<()> {
    ensure!(
        actual.len() as u64 == length && actual == expected && hash(actual) == sha,
        "Registry publication persisted bytes/size/hash differ from reserved body; transaction must not commit."
    );
    match name {
        SNAPSHOT => {
            let _: Snapshot = decode(actual)?;
        }
        MANIFEST => {
            let _: Manifest = decode(actual)?;
        }
        _ => {
            ensure!(
                receipt_parts(name).is_some(),
                "Unknown registry publication destination."
            );
            let _: Receipt = decode(actual)?;
        }
    }
    Ok(())
}
pub fn remove(path: &Path) -> Result<()> {
    let pin = sec::open_lifecycle_delete(path)?;
    verify(&pin, false)?;
    sec::delete_fixed(pin.raw(), false)
}
pub fn write_handle(handle: HANDLE, bytes: &[u8]) -> Result<()> {
    let mut writer = file(handle)?;
    writer.seek(SeekFrom::Start(0))?;
    writer.set_len(0)?;
    writer.write_all(bytes)?;
    writer.sync_all()?;
    ensure!(
        writer.metadata()?.len() == bytes.len() as u64,
        "Persisted registry metadata length differs from the supplied body."
    );
    writer.seek(SeekFrom::Start(0))?;
    let mut actual = vec![0u8; bytes.len()];
    writer.read_exact(&mut actual)?;
    ensure!(
        actual == bytes,
        "Persisted registry metadata bytes differ from the supplied body."
    );
    Ok(())
}
#[cfg(test)]
fn checkpoint_write(
    handle: HANDLE,
    bytes: &[u8],
    event: &str,
    phase: &str,
    id: &str,
) -> Result<()> {
    let mut writer = file(handle)?;
    writer.seek(SeekFrom::Start(0))?;
    writer.set_len(0)?;
    let split = bytes.len() / 2;
    writer.write_all(&bytes[..split])?;
    writer.sync_all()?;
    super::verification_checkpoint(event, phase, id);
    writer.write_all(&bytes[split..])?;
    writer.sync_all()?;
    writer.seek(SeekFrom::Start(0))?;
    let mut actual = vec![0; bytes.len()];
    writer.read_exact(&mut actual)?;
    ensure!(
        writer.metadata()?.len() == bytes.len() as u64 && actual == bytes,
        "Checkpoint publication body differs from fresh bytes."
    );
    Ok(())
}
pub fn control<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let parent = directory(path.parent().context("Missing registry parent")?)?;
    let pending = path.with_file_name(format!(
        "{}.pending-{}",
        path.file_name().unwrap().to_string_lossy(),
        uuid::Uuid::new_v4().simple()
    ));
    let handle = sec::create_private_file(&pending)?;
    let bytes = serialize(value)?;
    write_handle(handle.raw(), &bytes)?;
    ensure!(
        crate::json::parse_unique(&bytes)?.is_object(),
        "Invalid registry control."
    );
    sec::rename_fixed(
        handle.raw(),
        parent.raw(),
        path.file_name()
            .unwrap()
            .to_str()
            .context("Invalid registry control name")?,
    )?;
    parent.verify_named()?;
    Ok(())
}
pub fn recovery_control<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    drop(recovery_control_held(path, value)?);
    Ok(())
}
// 公開時のRW|DELETE handleをそのまま返し、authorityのrelease/reopen窓を作らない。
pub fn recovery_control_held<T: Serialize>(path: &Path, value: &T) -> Result<Held> {
    let parent = directory(path.parent().context("Missing registry control parent")?)?;
    ensure!(
        !exists(path)?,
        "Registry control final already exists; pending retained."
    );
    let pending = path.with_file_name(format!(
        "{}.pending",
        path.file_name().unwrap().to_string_lossy()
    ));
    let bytes = serialize(value)?;
    ensure!(
        !bytes.is_empty() && bytes.len() <= 16 * 1024 * 1024,
        "Registry control size is invalid."
    );
    let handle = if exists(&pending)? {
        let pin = sec::open_lifecycle_pending_publisher(&pending)?;
        verify(&pin, false)?;
        duplicate(pin.raw())?
    } else {
        sec::create_private_file(&pending)?
    };
    let mut reader = file(handle.raw())?;
    let size = reader.metadata()?.len() as usize;
    ensure!(
        size <= bytes.len(),
        "Registry control partial body is oversized."
    );
    let mut prefix = vec![0; size];
    reader.seek(SeekFrom::Start(0))?;
    reader.read_exact(&mut prefix)?;
    ensure!(
        bytes.starts_with(&prefix),
        "Registry control pending differs from fresh record proof; retained."
    );
    #[cfg(test)]
    let control_binding = [
        (".registry-migration.json", "migration"),
        (".terminal.json", "terminal"),
        (".terminal-cleanup.json", "terminal-cleanup"),
    ]
    .into_iter()
    .find_map(|(suffix, kind)| {
        path.file_name()?
            .to_str()?
            .strip_suffix(suffix)
            .map(|id| (id, kind))
    });
    #[cfg(test)]
    if let Some((id, kind)) = control_binding {
        operation_id(id)?;
        super::verification_checkpoint("RegistryControlCheckpoint", &format!("{kind}.pending"), id);
    }
    #[cfg(test)]
    if super::verification_has_checkpoint() {
        if let Some((id, kind)) = control_binding {
            checkpoint_write(
                handle.raw(),
                &bytes,
                "RegistryControlCheckpoint",
                &format!("{kind}.prefix"),
                id,
            )?;
        } else {
            write_handle(handle.raw(), &bytes)?;
        }
    } else {
        write_handle(handle.raw(), &bytes)?;
    }
    #[cfg(not(test))]
    write_handle(handle.raw(), &bytes)?;
    #[cfg(test)]
    if let Some((id, kind)) = control_binding {
        super::verification_checkpoint("RegistryControlCheckpoint", &format!("{kind}.flushed"), id);
    }
    sec::rename_fixed(
        handle.raw(),
        parent.raw(),
        path.file_name()
            .unwrap()
            .to_str()
            .context("Invalid registry control name")?,
    )?;
    #[cfg(test)]
    if let Some((id, kind)) = control_binding {
        super::verification_checkpoint(
            "RegistryControlCheckpoint",
            &format!("{kind}.published"),
            id,
        );
    }
    let held = Held::from_pin(PinnedFile::from_handle(path.to_path_buf(), handle)?)?;
    ensure!(
        held.bytes == bytes,
        "Published registry control differs from expected raw bytes."
    );
    held.verify_current()?;
    Ok(held)
}
pub struct Store<'a> {
    pub config: &'a Config,
    pub root: PathBuf,
    // 共通基点の名前を要求終了まで固定するために保持する。
    _metadata: PinnedFile,
    pub registry: PinnedFile,
    pub state: State,
}
impl<'a> Store<'a> {
    pub fn open(config: &'a Config, create: bool) -> Result<Self> {
        let base = Path::new(&config.data.backup_directory);
        win::path::validate_local_path(base)?;
        win::path::reject_reparse_ancestors(base)?;
        let metadata = PinnedFile::open(base, FILE_READ_ATTRIBUTES | READ_CONTROL, 3)?;
        ensure!(
            metadata.identity()?.is_directory() && !metadata.identity()?.is_reparse(),
            "Invalid recovery metadata root."
        );
        metadata.reject_case_sensitive()?;
        metadata.verify_named()?;
        let metadata_id = legacy_identity(metadata.raw())?;
        let owner = sec::current_user_sid()?;
        let machine = machine()?;
        let root = base.join(ROOT);
        if create {
            Self::provision(base, &metadata_id, &owner, &machine)?;
        }
        ensure!(
            exists(&root)?,
            "migration_required: Registry storage is not initialized; run migrate --apply."
        );
        let registry = directory(&root)?;
        let layout = read_layout(&root.join("layout.json"))?;
        ensure!(
            layout.schema == 1
                && layout.kind == ROOT
                && layout.operation_id.is_empty()
                && layout.directory_identity == legacy_identity(registry.raw())?
                && layout.metadata_root_identity == metadata_id
                && layout.machine_name == machine
                && layout.owner_sid == owner
                && layout.publication_protocol == 0,
            "Registry storage layout differs from its private directory."
        );
        operation_id(&layout.nonce)?;
        let state = State {
            schema: 1,
            metadata_root_identity: metadata_id,
            registry_root_identity: legacy_identity(registry.raw())?,
            machine_name: machine,
            owner_sid: owner,
            registry_ready: false,
            assessment_complete: false,
            complete: false,
            retained_count: 0,
            legacy_file_policy_version: 0,
        };
        Ok(Self {
            config,
            root,
            _metadata: metadata,
            registry,
            state,
        })
    }
    fn provision(base: &Path, metadata_id: &str, owner: &str, machine: &str) -> Result<()> {
        let root = base.join(ROOT);
        let intent_path = base.join(format!("{ROOT}.create.json"));
        let mut intent: Option<RootIntent> = if exists(&intent_path)? {
            Some(Held::read(&intent_path)?.lifecycle()?)
        } else {
            None
        };
        if let Some(i) = &intent {
            operation_id(&i.nonce)?;
            ensure!(
                i.schema == 1
                    && i.root_kind == ROOT
                    && i.stage_name == format!("{ROOT}.stage-{}", i.nonce)
                    && i.metadata_root_identity == metadata_id
                    && i.owner_sid == owner
                    && i.machine_name == machine,
                "Registry root creation intent binding differs."
            );
        }
        if exists(&root)? {
            if let Some(i) = intent {
                let fixed = directory(&root)?;
                let layout = read_layout(&root.join("layout.json"))?;
                ensure!(
                    layout.schema == 1
                        && layout.kind == ROOT
                        && layout.operation_id.is_empty()
                        && layout.publication_protocol == 0
                        && layout.directory_identity == legacy_identity(fixed.raw())?
                        && layout.metadata_root_identity == metadata_id
                        && layout.machine_name == machine
                        && layout.owner_sid == owner
                        && layout.nonce == i.nonce
                        && !exists(&base.join(i.stage_name))?,
                    "Published and staged registry roots conflict."
                );
                remove(&intent_path)?;
            }
            return Ok(());
        }
        if intent.is_none() {
            for entry in std::fs::read_dir(base)? {
                let name = entry?.file_name().to_string_lossy().into_owned();
                ensure!(
                    !name.starts_with(&format!("{ROOT}.stage-"))
                        && !name.starts_with(&format!("{ROOT}.create.json.pending-")),
                    "Unpublished registry root creation evidence was retained."
                );
            }
            let nonce = uuid::Uuid::new_v4().simple().to_string();
            let value = RootIntent {
                schema: 1,
                root_kind: ROOT.into(),
                stage_name: format!("{ROOT}.stage-{nonce}"),
                nonce,
                metadata_root_identity: metadata_id.into(),
                machine_name: machine.into(),
                owner_sid: owner.into(),
            };
            // 共通基点はprivateと限らない。作成済みparentを固定して非上書き公開する。
            let parent = PinnedFile::open(base, FILE_READ_ATTRIBUTES | READ_CONTROL, 3)?;
            let pending = intent_path.with_file_name(format!(
                "{ROOT}.create.json.pending-{}",
                uuid::Uuid::new_v4().simple()
            ));
            let handle = sec::create_private_file(&pending)?;
            write_handle(handle.raw(), &serialize(&value)?)?;
            sec::rename_fixed(
                handle.raw(),
                parent.raw(),
                intent_path.file_name().unwrap().to_str().unwrap(),
            )?;
            drop(handle);
            let persisted: RootIntent = Held::read(&intent_path)?.lifecycle()?;
            ensure!(
                persisted == value,
                "Registry root creation intent changed before staging."
            );
            intent = Some(persisted);
        }
        let intent = intent.unwrap();
        let stage = base.join(&intent.stage_name);
        if !exists(&stage)? {
            drop(sec::create_private_directory(&stage)?);
        }
        let parent = directory(&stage)?;
        for name in win::directory_names(parent.raw())? {
            if name == "layout.json" {
                continue;
            }
            let suffix = name
                .strip_prefix("layout.json.pending-")
                .context("Unknown registry root stage contents retained")?;
            operation_id(suffix)?;
            let path = stage.join(&name);
            let pin = sec::open_lifecycle_metadata(&path)?;
            verify(&pin, false)?;
            let identity = pin.identity()?;
            let mut reader = file(pin.raw())?;
            ensure!(
                reader.metadata()?.len() <= 8192,
                "Oversized registry root partial metadata retained."
            );
            let mut bytes = vec![];
            reader.read_to_end(&mut bytes)?;
            if !bytes.is_empty() && crate::json::parse_unique(&bytes).is_ok() {
                let layout: Layout = decode_lifecycle(&bytes)?;
                ensure!(
                    layout.schema == 1
                        && layout.kind == ROOT
                        && layout.operation_id.is_empty()
                        && layout.publication_protocol == 0
                        && layout.directory_identity == legacy_identity(parent.raw())?
                        && layout.metadata_root_identity == metadata_id
                        && layout.machine_name == machine
                        && layout.owner_sid == owner
                        && layout.nonce == intent.nonce,
                    "Root stage partial binding differs."
                );
            }
            let digest = hash(&bytes);
            drop(reader);
            drop(pin);
            let deleting = sec::open_lifecycle_delete(&path)?;
            verify(&deleting, false)?;
            ensure!(
                identity.same_object(&deleting.identity()?),
                "Registry root partial identity changed."
            );
            let mut reader = file(deleting.raw())?;
            let mut current = vec![];
            reader.read_to_end(&mut current)?;
            ensure!(
                hash(&current) == digest,
                "Registry root partial bytes changed."
            );
            sec::delete_fixed(deleting.raw(), false)?;
        }
        if !exists(&stage.join("layout.json"))? {
            let names = win::directory_names(parent.raw())?;
            ensure!(
                names.is_empty(),
                "Incomplete registry root stage contains retained metadata."
            );
            let layout = Layout {
                schema: 1,
                kind: ROOT.into(),
                operation_id: String::new(),
                directory_identity: legacy_identity(parent.raw())?,
                metadata_root_identity: metadata_id.into(),
                machine_name: machine.into(),
                owner_sid: owner.into(),
                nonce: intent.nonce.clone(),
                publication_protocol: 0,
            };
            control(&stage.join("layout.json"), &layout)?;
        }
        let layout = read_layout(&stage.join("layout.json"))?;
        ensure!(
            layout.schema == 1
                && layout.operation_id.is_empty()
                && layout.publication_protocol == 0
                && layout.directory_identity == legacy_identity(parent.raw())?
                && layout.metadata_root_identity == metadata_id
                && layout.nonce == intent.nonce
                && layout.kind == ROOT
                && layout.owner_sid == owner
                && layout.machine_name == machine,
            "Registry stage layout differs."
        );
        drop(parent);
        let moving = sec::open_lifecycle_directory_move(&stage)?;
        verify(&moving, true)?;
        let parent = PinnedFile::open(base, FILE_READ_ATTRIBUTES | READ_CONTROL, 3)?;
        sec::rename_fixed(moving.raw(), parent.raw(), ROOT)?;
        drop(moving);
        remove(&intent_path)?;
        Ok(())
    }
    pub fn require_ready(&mut self) -> Result<()> {
        for name in win::directory_names(self.registry.raw())? {
            ensure!(
                !name.contains(".registry-migration.json"),
                "migration_required: A registry migration is pending."
            );
        }
        let state: State = Held::read(&self.root.join("storage-migration-v1.json"))?.lifecycle()?;
        self.validate_state(&state)?;
        ensure!(
            state.registry_ready && state.assessment_complete,
            "migration_required: Legacy registry records remain unresolved."
        );
        self.state = state;
        Ok(())
    }
    pub fn require_ready_check(&self) -> Result<()> {
        let state: State = Held::read(&self.root.join("storage-migration-v1.json"))?.lifecycle()?;
        self.validate_state(&state)?;
        ensure!(
            state.registry_ready && state.assessment_complete,
            "Registry storage is not ready."
        );
        Ok(())
    }
    pub fn validate_state(&self, state: &State) -> Result<()> {
        ensure!(
            state.schema == 1
                && state.metadata_root_identity == self.state.metadata_root_identity
                && state.registry_root_identity == self.state.registry_root_identity
                && state.machine_name == self.state.machine_name
                && state.owner_sid == self.state.owner_sid,
            "Registry storage assessment binding differs."
        );
        Ok(())
    }
    pub fn save_state(&self, state: &State) -> Result<()> {
        self.validate_state(state)?;
        let path = self.root.join("storage-migration-v1.json");
        let bytes = serialize(state)?;
        if exists(&path)? {
            let pin = sec::open_lifecycle_pending_publisher(&path)?;
            verify(&pin, false)?;
            write_handle(pin.raw(), &bytes)?;
        } else {
            let handle = sec::create_private_file(&path)?;
            write_handle(handle.raw(), &bytes)?;
        }
        let actual: State = Held::read(&path)?.lifecycle()?;
        self.validate_state(&actual)
    }
    pub fn ids(&self) -> Result<Vec<String>> {
        let mut ids = vec![];
        for name in win::directory_names(self.registry.raw())? {
            if operation_id(&name).is_ok() {
                ids.push(name);
            } else if std::fs::symlink_metadata(self.root.join(&name))?.is_dir() {
                bail!("Unknown registry operation directory was retained: {name}");
            }
        }
        ids.sort();
        Ok(ids)
    }
    pub fn record(&self, id: &str) -> Result<Record> {
        self.record_at(id, &self.root.join(id))
    }
    pub fn record_at(&self, id: &str, path: &Path) -> Result<Record> {
        operation_id(id)?;
        let parent = directory(path)?;
        let lock_path = path.join("operation.lock");
        let lock = sec::open_lifecycle_metadata(&lock_path)?;
        verify(&lock, false)?;
        let mut lock_file = file(lock.raw())?;
        ensure!(
            lock_file.metadata()?.len() == 0,
            "Registry operation lock is not empty."
        );
        // operation.lockと本文はshare-readで保持し、他要求の書込み・移動・消費を閉じる。
        let manifest = Held::read(&path.join(MANIFEST))?;
        let value: Manifest = manifest.decode()?;
        value.validate(
            id,
            &self.config.data.backup_directory,
            &self.state.owner_sid,
        )?;
        let manifest_hash = hash(&manifest.bytes);
        let mut held = vec![manifest];
        let mut receipts = HashSet::new();
        for name in win::directory_names(parent.raw())? {
            if matches!(name.as_str(), MANIFEST | SNAPSHOT | "operation.lock") {
                continue;
            }
            if let Some(final_name) = publication_final(&name)? {
                self.inspect_publication(id, path, &final_name)?;
                continue;
            }
            let Some((action, phase)) = receipt_parts(&name) else {
                bail!("Unknown registry recovery member was retained: {name}")
            };
            let h = Held::read(&path.join(&name))?;
            let receipt: Receipt = h.decode()?;
            ensure!(
                receipt.schema == 5
                    && receipt.operation_id == id
                    && receipt.manifest_sha256 == manifest_hash
                    && receipt.action == action
                    && receipt.phase == phase
                    && receipt.created_utc.timestamp() != -62135596800,
                "Registry receipt differs from its manifest or filename."
            );
            receipts.insert(name);
            held.push(h);
        }
        for action in ["delete", "restore", "purge"] {
            ensure!(
                !receipts.contains(&receipt_name(action, "complete"))
                    || receipts.contains(&receipt_name(action, "intent")),
                "Registry completion has no persisted intent."
            );
        }
        ensure!(
            (!receipts.contains(&receipt_name("restore", "intent"))
                && !receipts.contains(&receipt_name("purge", "intent")))
                || receipts.contains(&receipt_name("delete", "complete")),
            "Registry recovery action has no confirmed deletion."
        );
        ensure!(
            !(receipts.contains(&receipt_name("restore", "intent"))
                && receipts.contains(&receipt_name("purge", "intent"))),
            "Registry restore and purge receipts conflict."
        );
        let mut snapshot = None;
        let mut payload = None;
        if exists(&path.join(SNAPSHOT))? {
            let h = Held::read(&path.join(SNAPSHOT))?;
            ensure!(
                h.bytes.len() as u64 == value.size && hash(&h.bytes) == value.sha256,
                "Registry snapshot size/hash differs from manifest."
            );
            let s: Snapshot = h.decode()?;
            s.validate(&value)?;
            snapshot = Some(s);
            payload = Some(h);
        }
        ensure!(
            !(receipts.contains(&receipt_name("purge", "complete")) && payload.is_some()),
            "Completed registry purge still has its snapshot."
        );
        ensure!(
            payload.is_some()
                || receipts.contains(&receipt_name("restore", "complete"))
                || receipts.contains(&receipt_name("purge", "intent")),
            "Registry snapshot is absent without a confirmed consuming action."
        );
        lock_file.seek(SeekFrom::Start(0))?;
        Ok(Record {
            directory: path.into(),
            parent,
            lock,
            manifest: value,
            manifest_hash,
            held,
            payload,
            snapshot,
            receipts,
        })
    }
    fn publication(&self, id: &str, path: &Path, final_name: &str) -> Result<Publication> {
        let owner: Publication = Held::read(&path.join(owner_name(final_name)))?.lifecycle()?;
        let parent = directory(path)?;
        ensure!(
            owner.schema == 1
                && owner.operation_id == id
                && owner.metadata_root_identity == self.state.metadata_root_identity
                && owner.registry_root_identity == self.state.registry_root_identity
                && owner.machine_name == self.state.machine_name
                && owner.owner_sid == self.state.owner_sid
                && owner.final_name == final_name
                && is_final(final_name)
                && owner.pending_name == pending_name(final_name)
                && owner.directory_identity.valid()
                && owner
                    .directory_identity
                    .same(&MoveIdentity::of(parent.raw())?)
                && owner.pending_identity.valid()
                && !owner.pending_identity.is_directory
                && owner.length > 0
                && owner.length <= MAX_BYTES as u64
                && digest(&owner.sha256)
                && (final_name == SNAPSHOT || owner.created_utc.timestamp() != -62135596800),
            "Registry publication reservation binding differs."
        );
        Ok(owner)
    }
    fn inspect_publication(&self, id: &str, path: &Path, final_name: &str) -> Result<()> {
        let owner = self.publication(id, path, final_name)?;
        let pending = path.join(&owner.pending_name);
        let final_path = path.join(final_name);
        let has_pending = exists(&pending)?;
        let has_final = exists(&final_path)?;
        ensure!(
            has_pending ^ has_final,
            "Registry publication has conflicting or missing body locations."
        );
        let pin = sec::open_lifecycle_metadata(if has_final { &final_path } else { &pending })?;
        verify(&pin, false)?;
        ensure!(
            owner.pending_identity.same(&MoveIdentity::of(pin.raw())?),
            "Registry publication body identity changed."
        );
        let mut reader = file(pin.raw())?;
        let size = reader.metadata()?.len();
        ensure!(
            size <= owner.length && (!has_final || size == owner.length),
            "Registry publication body size differs."
        );
        if has_final {
            let mut bytes = vec![];
            reader.read_to_end(&mut bytes)?;
            ensure!(
                hash(&bytes) == owner.sha256,
                "Registry publication hash differs."
            );
        }
        Ok(())
    }
    pub fn publish<T: Serialize + DeserializeOwned>(
        &self,
        id: &str,
        name: &str,
        value: &T,
    ) -> Result<Held> {
        let bytes = serialize(value)?;
        self.publish_bytes(id, name, &bytes)
    }
    pub fn publish_bytes(&self, id: &str, name: &str, fresh: &[u8]) -> Result<Held> {
        operation_id(id)?;
        ensure!(
            is_final(name) && !fresh.is_empty() && fresh.len() <= MAX_BYTES,
            "Invalid registry publication body or destination."
        );
        let path = self.root.join(id);
        let parent = directory(&path)?;
        let owner_path = path.join(owner_name(name));
        let pending = path.join(pending_name(name));
        let mut bytes = Cow::Borrowed(fresh);
        let existing = exists(&owner_path)?;
        let (owner, handle) = if existing {
            let owner = self.publication(id, &path, name)?;
            ensure!(
                !exists(&path.join(name))?,
                "Registry publication final already exists; it was not overwritten."
            );
            // 再開日時は予約済みの値に再束縛し、snapshotは元bytesのまま照合する。
            if name != SNAPSHOT {
                bytes = Cow::Owned(if name == MANIFEST {
                    let mut value: Manifest = decode(&bytes)?;
                    value.created_utc = owner.created_utc;
                    serialize(&value)?
                } else {
                    let mut value: Receipt = decode(&bytes)?;
                    value.created_utc = owner.created_utc;
                    serialize(&value)?
                });
            }
            ensure!(
                owner.length == bytes.len() as u64 && owner.sha256 == hash(&bytes),
                "Registry publication retry differs from reserved complete body."
            );
            let pin = sec::open_lifecycle_pending_publisher(&pending)?;
            verify(&pin, false)?;
            ensure!(
                owner.pending_identity.same(&MoveIdentity::of(pin.raw())?),
                "Registry publication retry body ID differs."
            );
            let raw = duplicate(pin.raw())?;
            drop(pin);
            (owner, raw)
        } else {
            let handle = sec::create_private_file(&pending)?;
            let created = if name == SNAPSHOT {
                DateTime::parse_from_rfc3339("0001-01-01T00:00:00+00:00")?
            } else {
                crate::json::parse_unique(&bytes)?
                    .get("createdUtc")
                    .and_then(Value::as_str)
                    .context("Missing publication timestamp")?
                    .parse()?
            };
            let owner = Publication {
                schema: 1,
                operation_id: id.into(),
                metadata_root_identity: self.state.metadata_root_identity.clone(),
                registry_root_identity: self.state.registry_root_identity.clone(),
                machine_name: self.state.machine_name.clone(),
                owner_sid: self.state.owner_sid.clone(),
                directory_identity: MoveIdentity::of(parent.raw())?,
                final_name: name.into(),
                pending_name: pending_name(name),
                pending_identity: MoveIdentity::of(handle.raw())?,
                length: bytes.len() as u64,
                sha256: hash(&bytes),
                created_utc: created,
            };
            let reservation = sec::create_private_file(&owner_path)?;
            write_handle(reservation.raw(), &serialize(&owner)?)?;
            drop(reservation);
            self.publication(id, &path, name)?;
            (owner, handle)
        };
        #[cfg(test)]
        {
            super::verification_checkpoint(
                "RegistryPublicationCheckpoint",
                &format!("{name}.owner.published"),
                id,
            );
            super::verification_checkpoint(
                "RegistryPublicationCheckpoint",
                &format!("{name}.owner.durable"),
                id,
            );
        }
        let mut reader = file(handle.raw())?;
        let size = reader.metadata()?.len();
        ensure!(
            size <= owner.length,
            "Registry publication partial body is oversized."
        );
        let mut prefix = vec![0u8; size as usize];
        reader.seek(SeekFrom::Start(0))?;
        reader.read_exact(&mut prefix)?;
        ensure!(
            bytes.starts_with(&prefix),
            "Registry publication partial body differs from fresh preflight."
        );
        drop(prefix);
        #[cfg(test)]
        if super::verification_has_checkpoint() {
            checkpoint_write(
                handle.raw(),
                &bytes,
                "RegistryPublicationCheckpoint",
                &format!("{name}.body.prefix"),
                id,
            )?;
        } else {
            write_handle(handle.raw(), &bytes)?;
        }
        #[cfg(not(test))]
        write_handle(handle.raw(), &bytes)?;
        let size = reader.metadata()?.len();
        ensure!(
            size == owner.length && size <= MAX_BYTES as u64,
            "Registry publication persisted size differs."
        );
        reader.seek(SeekFrom::Start(0))?;
        let mut actual = vec![0; size as usize];
        reader.read_exact(&mut actual)?;
        validate_publication(name, &actual, &bytes, owner.length, &owner.sha256)?;
        drop(actual);
        ensure!(
            owner
                .pending_identity
                .same(&MoveIdentity::of(handle.raw())?),
            "Registry publication identity changed before publication."
        );
        sec::verify_private_member_security(handle.raw(), false)?;
        #[cfg(test)]
        super::verification_checkpoint(
            "RegistryPublicationCheckpoint",
            &format!("{name}.body.flushed"),
            id,
        );
        sec::rename_fixed(handle.raw(), parent.raw(), name)?;
        #[cfg(test)]
        super::verification_checkpoint(
            "RegistryPublicationCheckpoint",
            &format!("{name}.body.published"),
            id,
        );
        drop(reader);
        drop(handle);
        let held = Held::read(&path.join(name))?;
        ensure!(
            owner
                .pending_identity
                .same(&MoveIdentity::of(held.pin.raw())?),
            "Registry publication identity changed after publication."
        );
        validate_publication(name, &held.bytes, &bytes, owner.length, &owner.sha256)?;
        held.verify_current()?;
        remove(&owner_path)?;
        Ok(held)
    }
    pub fn create_record(&self, id: &str) -> Result<PinnedFile> {
        operation_id(id)?;
        let path = self.root.join(id);
        drop(sec::create_private_directory(&path)?);
        let pin = directory(&path)?;
        drop(sec::create_private_file(&path.join("operation.lock"))?);
        Ok(pin)
    }
    pub fn cleanup_publications(&self, id: &str) -> Result<bool> {
        operation_id(id)?;
        let path = self.root.join(id);
        let parent = directory(&path)?;
        let mut clean = true;
        for name in win::directory_names(parent.raw())? {
            if !name.starts_with(".registry-publication-") {
                continue;
            }
            let final_name =
                publication_final(&name)?.context("Invalid registry publication name")?;
            self.inspect_publication(id, &path, &final_name)?;
            if exists(&path.join(&final_name))? {
                remove(&path.join(name))?;
            } else {
                clean = false;
            }
        }
        for name in win::directory_names(parent.raw())? {
            if name.starts_with(".registry-pending-") {
                clean = false;
            }
        }
        Ok(clean)
    }
}
fn duplicate(handle: HANDLE) -> Result<OwnedHandle> {
    unsafe {
        let mut copy = null_mut();
        let p = GetCurrentProcess();
        if DuplicateHandle(p, handle, p, &mut copy, 0, 0, DUPLICATE_SAME_ACCESS) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        OwnedHandle::from_raw(copy)
    }
}
pub fn receipt_name(action: &str, phase: &str) -> String {
    format!("registry-{action}-{phase}.json")
}
pub fn receipt_parts(name: &str) -> Option<(&str, &str)> {
    let middle = name.strip_prefix("registry-")?.strip_suffix(".json")?;
    let (a, p) = middle.split_once('-')?;
    if matches!(a, "delete" | "restore" | "purge") && matches!(p, "intent" | "complete") {
        Some((a, p))
    } else {
        None
    }
}
fn is_final(name: &str) -> bool {
    matches!(name, MANIFEST | SNAPSHOT) || receipt_parts(name).is_some()
}
fn owner_name(name: &str) -> String {
    format!(".registry-publication-{name}.json")
}
fn pending_name(name: &str) -> String {
    format!(".registry-pending-{name}")
}
fn publication_final(name: &str) -> Result<Option<String>> {
    let final_name = if let Some(x) = name
        .strip_prefix(".registry-publication-")
        .and_then(|s| s.strip_suffix(".json"))
    {
        Some(x)
    } else {
        name.strip_prefix(".registry-pending-")
    };
    if let Some(x) = final_name {
        ensure!(
            is_final(x),
            "Unknown registry publication control was retained."
        );
    }
    Ok(final_name.map(str::to_string))
}
pub struct Record {
    pub directory: PathBuf,
    pub parent: PinnedFile,
    pub lock: PinnedFile,
    pub manifest: Manifest,
    pub manifest_hash: String,
    pub held: Vec<Held>,
    pub payload: Option<Held>,
    pub snapshot: Option<Snapshot>,
    pub receipts: HashSet<String>,
}
impl Record {
    pub fn verify_current(&self) -> Result<()> {
        verify(&self.parent, true)?;
        verify(&self.lock, false)?;
        ensure!(
            file(self.lock.raw())?.metadata()?.len() == 0,
            "Registry operation lock changed."
        );
        for h in &self.held {
            h.verify_current()?;
        }
        if let Some(payload) = &self.payload {
            payload.verify_current()?;
        }
        Ok(())
    }
    pub fn has(&self, action: &str, phase: &str) -> bool {
        self.receipts.contains(&receipt_name(action, phase))
    }
    pub fn ambiguous(&self) -> bool {
        !self.has("delete", "complete")
            || (self.has("restore", "intent") && !self.has("restore", "complete"))
    }
    pub fn receipt(&mut self, store: &Store, action: &str, phase: &str) -> Result<()> {
        let receipt = Receipt {
            schema: 5,
            operation_id: self.manifest.operation_id.clone(),
            manifest_sha256: self.manifest_hash.clone(),
            action: action.into(),
            phase: phase.into(),
            created_utc: now(),
        };
        let name = receipt_name(action, phase);
        let h = store.publish(&self.manifest.operation_id, &name, &receipt)?;
        self.receipts.insert(name);
        self.held.push(h);
        Ok(())
    }
    pub fn consume(&mut self) -> Result<()> {
        let Some(held) = self.payload.take() else {
            return Ok(());
        };
        let identity = held.pin.identity()?;
        let path = self.directory.join(SNAPSHOT);
        drop(held);
        let pin = sec::open_lifecycle_delete(&path)?;
        verify(&pin, false)?;
        ensure!(
            identity.same_object(&pin.identity()?),
            "Registry snapshot identity changed before consumption."
        );
        let mut reader = file(pin.raw())?;
        ensure!(
            reader.metadata()?.len() == self.manifest.size,
            "Registry snapshot size changed before consumption."
        );
        // 消費時は本文を使わない。固定handleからEOFまで全bytesをhashし、大きなVecを持たない。
        let mut digest = Sha256::new();
        let mut buffer = [0u8; 65536];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => digest.update(&buffer[..count]),
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error.into()),
            }
        }
        ensure!(
            hex::encode(digest.finalize()) == self.manifest.sha256,
            "Registry snapshot bytes changed before consumption."
        );
        sec::delete_fixed(pin.raw(), false)?;
        self.snapshot = None;
        Ok(())
    }
}

#[cfg(test)]
pub(crate) fn verification_snapshot_publication(config: &Config) -> Result<Value> {
    let _coord = crate::files::coordination::acquire(config, None, None)?;
    let store = Store::open(config, true)?;
    let mut cases = vec![];
    for mode in ["owner.durable", "body.prefix", "corrupt-prefix"] {
        let id = uuid::Uuid::new_v4().simple().to_string();
        let _directory = store.create_record(&id)?;
        let snapshot = Snapshot {
            scope: None,
            schema: 5,
            path: "HKEY_CURRENT_USER\\Software\\PrunletE2E\\Publication".into(),
            view: "64".into(),
            value_name: Some("payload".into()),
            keys: vec![],
            value: Some(ValueSnapshot {
                name: "payload".into(),
                r#type: 3,
                data: (0..65536).map(|i| (i % 251) as u8).collect(),
            }),
            context_security: Some(super::native::verification_security_descriptor(
                "O:SYG:SYD:(A;;KA;;;SY)S:(ML;;NW;;;ME)",
            )?),
        };
        let expected = serialize(&snapshot)?;
        let manifest = Manifest {
            scope: None,
            schema: 5,
            operation_id: id.clone(),
            created_utc: now(),
            metadata_root: config.data.backup_directory.clone(),
            owner_sid: store.state.owner_sid.clone(),
            path: snapshot.path.clone(),
            view: snapshot.view.clone(),
            value_name: snapshot.value_name.clone(),
            kind: "registry-value".into(),
            size: expected.len() as u64,
            sha256: hash(&expected),
        };
        snapshot.validate(&manifest)?;
        let phase = if mode == "corrupt-prefix" {
            "body.prefix"
        } else {
            mode
        };
        let target_phase = format!("{SNAPSHOT}.{phase}");
        let target_id = id.clone();
        let reached = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let signal = reached.clone();
        super::verification_set_checkpoint(Some(std::sync::Arc::new(
            move |event, phase, operation| {
                if event == "RegistryPublicationCheckpoint"
                    && phase == target_phase
                    && operation == target_id
                {
                    signal.store(true, std::sync::atomic::Ordering::SeqCst);
                    panic!("Prunlet injected publication checkpoint");
                }
            },
        )));
        let interrupted = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            store.publish_bytes(&id, SNAPSHOT, &expected)
        }));
        super::verification_set_checkpoint(None);
        ensure!(
            reached.load(std::sync::atomic::Ordering::SeqCst) && interrupted.is_err(),
            "Publication did not stop at the exact durable boundary."
        );
        let panic = interrupted.err().unwrap();
        ensure!(
            panic.downcast_ref::<&str>() == Some(&"Prunlet injected publication checkpoint"),
            "Unexpected panic while publishing snapshot."
        );
        let path = store.root.join(&id);
        let owner_path = path.join(owner_name(SNAPSHOT));
        let pending = path.join(pending_name(SNAPSHOT));
        let final_path = path.join(SNAPSHOT);
        ensure!(
            exists(&owner_path)? && exists(&pending)? && !exists(&final_path)?,
            "Interrupted publication ownership state differs."
        );
        let owner = store.publication(&id, &path, SNAPSHOT)?;
        ensure!(
            owner.length == expected.len() as u64 && owner.sha256 == hash(&expected),
            "Publication owner did not bind the reserved complete bytes."
        );
        let pin = sec::open_lifecycle_metadata(&pending)?;
        verify(&pin, false)?;
        let identity = pin.identity()?;
        let mut reader = file(pin.raw())?;
        let mut prefix = vec![];
        reader.read_to_end(&mut prefix)?;
        let prefix_len = if phase == "owner.durable" {
            0
        } else {
            expected.len() / 2
        };
        ensure!(
            prefix.len() == prefix_len && expected.starts_with(&prefix),
            "Publication prefix differs from initial bytes."
        );
        drop(reader);
        drop(pin);
        if mode == "corrupt-prefix" {
            prefix[0] ^= 1;
            let pin = sec::open_lifecycle_pending_publisher(&pending)?;
            verify(&pin, false)?;
            write_handle(pin.raw(), &prefix)?;
            drop(pin);
            let refused = store
                .publish_bytes(&id, SNAPSHOT, &expected)
                .err()
                .context("Corrupt publication prefix was accepted")?;
            ensure!(
                refused.to_string().contains("partial body differs"),
                "Corrupt prefix refusal had an unrelated cause: {refused}"
            );
            let pin = sec::open_lifecycle_metadata(&pending)?;
            verify(&pin, false)?;
            ensure!(
                identity.same_object(&pin.identity()?),
                "Refused prefix identity changed."
            );
            let mut reader = file(pin.raw())?;
            let mut actual = vec![];
            reader.read_to_end(&mut actual)?;
            ensure!(
                actual == prefix && !exists(&final_path)? && exists(&owner_path)?,
                "Rejected prefix or owner was not preserved."
            );
        } else {
            let held = store.publish_bytes(&id, SNAPSHOT, &expected)?;
            ensure!(
                held.bytes == expected && !exists(&owner_path)? && !exists(&pending)?,
                "Resumed snapshot or ownership cleanup differs."
            );
            held.verify_current()?;
        }
        cases.push(serde_json::json!({"mode":mode,"passed":true,"operationId":id,"length":expected.len(),"sha256":hash(&expected),"prefixLength":prefix_len,"privateAclFromCreation":true}));
    }
    Ok(
        serde_json::json!({"passed":true,"passedCount":cases.len(),"failed":0,"cases":cases,"scope":"Synthetic metadata only; no registry transaction or native-session E2E.","metadata":config.data.backup_directory}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        created_utc: DateTime<FixedOffset>,
        #[serde(with = "super::super::model::bytes")]
        data: Vec<u8>,
        name: String,
    }
    #[test]
    fn dotnet_publication_bytes_preserve_datetime_base64_and_web_encoder() {
        let fixture = Fixture {
            created_utc: DateTime::parse_from_rfc3339("2026-11-03T03:30:00.1234567+00:00").unwrap(),
            data: vec![251, 255],
            name: "日本語 + <>&'\"`".into(),
        };
        let bytes = serialize(&fixture).unwrap();
        let expected = "{\r\n  \"createdUtc\": \"2026-11-03T03:30:00.1234567+00:00\",\r\n  \"data\": \"+/8=\",\r\n  \"name\": \"\\u65E5\\u672C\\u8A9E \\u002B \\u003C\\u003E\\u0026\\u0027\\u0022\\u0060\"\r\n}";
        assert_eq!(String::from_utf8(bytes).unwrap(), expected);
    }
    #[test]
    fn persisted_corruption_refuses_publication_before_commit_callback() {
        let parent = std::env::temp_dir();
        assert!(parent.is_absolute());
        assert!(
            !win::path::within(&parent, Path::new(env!("CARGO_MANIFEST_DIR"))),
            "Test TEMP must be outside repository."
        );
        let _parents = win::path::pin_directories(&parent).unwrap();
        let path = parent.join(format!(
            "prunlet-registry-publication-fault-{}",
            uuid::Uuid::new_v4().simple()
        ));
        drop(sec::create_private_directory(&path).unwrap());
        let file_path = path.join("registry-delete-intent.json");
        let handle = sec::create_private_file(&file_path).unwrap();
        let receipt = Receipt {
            schema: 5,
            operation_id: uuid::Uuid::new_v4().simple().to_string(),
            manifest_sha256: "1".repeat(64),
            action: "delete".into(),
            phase: "intent".into(),
            created_utc: now(),
        };
        let expected = serialize(&receipt).unwrap();
        write_handle(handle.raw(), &expected).unwrap();
        let mut corrupt = String::from_utf8(expected.clone()).unwrap();
        corrupt = corrupt.replace("\"delete\"", "\"delXte\"");
        assert_ne!(corrupt.as_bytes(), expected);
        write_handle(handle.raw(), corrupt.as_bytes()).unwrap();
        let mut committed = false;
        let result = (|| -> Result<()> {
            let mut reader = file(handle.raw())?;
            reader.seek(SeekFrom::Start(0))?;
            let mut actual = vec![];
            reader.read_to_end(&mut actual)?;
            validate_publication(
                "registry-delete-intent.json",
                &actual,
                &expected,
                expected.len() as u64,
                &hash(&expected),
            )?;
            committed = true;
            Ok(())
        })();
        assert!(result.is_err());
        assert!(!committed);
        sec::delete_fixed(handle.raw(), false).unwrap();
        drop(handle);
        let directory = sec::open_lifecycle_directory_move(&path).unwrap();
        sec::delete_fixed(directory.raw(), false).unwrap();
    }
    #[test]
    fn fresh_private_store_publication_lease_and_consumption() -> Result<()> {
        for corrupt in [false, true] {
            let temp = std::env::temp_dir();
            ensure!(
                temp.is_absolute()
                    && !win::path::within(&temp, Path::new(env!("CARGO_MANIFEST_DIR"))),
                "Test TEMP must be external."
            );
            let _temp_parents = win::path::pin_directories(&temp)?;
            let base = temp.join(format!(
                "prunlet-registry-store-{}",
                uuid::Uuid::new_v4().simple()
            ));
            drop(sec::create_private_directory(&base)?);
            eprintln!("Registry storage fixture: {}", base.display());
            let config = Config {
                path: base.join("config.json"),
                data: crate::config::ConfigData {
                    backup_directory: base.to_str().unwrap().into(),
                    ..Default::default()
                },
            };
            let coord = crate::files::coordination::acquire(&config, None, None)?;
            let mut store = Store::open(&config, true)?;
            let mut state = store.state.clone();
            state.registry_ready = true;
            state.assessment_complete = true;
            state.complete = true;
            state.legacy_file_policy_version = 2;
            store.save_state(&state)?;
            store.require_ready()?;
            let id = uuid::Uuid::new_v4().simple().to_string();
            let parent = store.create_record(&id)?;
            // 保存境界だけのfixture。registryキーの生成・削除・旧schema goldenの捏造には使わない。
            let snapshot = Snapshot {
                scope: None,
                schema: 5,
                path: format!("HKEY_CURRENT_USER\\Software\\PrunletE2E\\{id}"),
                view: "64".into(),
                value_name: Some("storage-fixture".into()),
                keys: vec![],
                value: Some(ValueSnapshot {
                    name: "storage-fixture".into(),
                    r#type: 3,
                    data: (0..(2 * 65536 + 17)).map(|n| (n % 251) as u8).collect(),
                }),
                context_security: Some(sec::read_member_security(store.registry.raw())?),
            };
            let bytes = serialize(&snapshot)?;
            let payload = store.publish_bytes(&id, SNAPSHOT, &bytes)?;
            let manifest = Manifest {
                scope: None,
                schema: 5,
                operation_id: id.clone(),
                created_utc: now(),
                metadata_root: config.data.backup_directory.clone(),
                owner_sid: store.state.owner_sid.clone(),
                path: snapshot.path.clone(),
                view: snapshot.view.clone(),
                value_name: snapshot.value_name.clone(),
                kind: "registry-value".into(),
                size: payload.bytes.len() as u64,
                sha256: hash(&payload.bytes),
            };
            snapshot.validate(&manifest)?;
            let saved = store.publish(&id, MANIFEST, &manifest)?;
            let manifest_hash = hash(&saved.bytes);
            let mut held = vec![payload, saved];
            for phase in ["intent", "complete"] {
                let receipt = Receipt {
                    schema: 5,
                    operation_id: id.clone(),
                    manifest_sha256: manifest_hash.clone(),
                    action: "delete".into(),
                    phase: phase.into(),
                    created_utc: now(),
                };
                held.push(store.publish(&id, &receipt_name("delete", phase), &receipt)?);
            }
            for item in &held {
                item.verify_current()?;
            }
            drop(held);
            drop(parent);
            let mut record = store.record(&id)?;
            ensure!(
                !record.ambiguous() && record.payload.is_some(),
                "Published record was not readable."
            );
            record.verify_current()?;
            record.receipt(&store, "purge", "intent")?;
            ensure!(
                bytes.len() > 2 * 65536,
                "Consumption fixture must cross multiple hash chunks."
            );
            if corrupt {
                // production leaseの完全検査後に、別の新規fixtureだけを後半改変する。
                drop(record.payload.take());
                let snapshot_path = record.directory.join(SNAPSHOT);
                let handle = sec::open_lifecycle_pending_publisher(&snapshot_path)?;
                let mut corrupted = bytes.clone();
                let last = corrupted.len() - 2;
                corrupted[last] ^= 1;
                write_handle(handle.raw(), &corrupted)?;
                drop(handle);
                record.payload = Some(Held::read(&snapshot_path)?);
                let before = record.payload.as_ref().unwrap().pin.identity()?;
                let error = record.consume().unwrap_err();
                ensure!(
                    error
                        .to_string()
                        .contains("bytes changed before consumption"),
                    "Unexpected consume refusal: {error:#}"
                );
                let retained = Held::read(&snapshot_path)?;
                ensure!(
                    retained.bytes == corrupted && retained.pin.identity()?.same_object(&before),
                    "Digest mismatch removed or replaced snapshot."
                );
                eprintln!(
                    "Late corruption fixture retained without deletion retry: {}",
                    base.display()
                );
                continue;
            }
            record.consume()?;
            record.receipt(&store, "purge", "complete")?;
            record.verify_current()?;
            drop(record);
            let record = store.record(&id)?;
            ensure!(
                record.payload.is_none() && record.has("purge", "complete"),
                "Snapshot consumption was not persisted."
            );
            drop(record);
            let root = store.root.clone();
            drop(store);
            drop(coord);
            for name in [
                "operation.lock",
                MANIFEST,
                "registry-delete-intent.json",
                "registry-delete-complete.json",
                "registry-purge-intent.json",
                "registry-purge-complete.json",
            ] {
                remove(&root.join(&id).join(name))?;
            }
            let operation = sec::open_lifecycle_directory_move(&root.join(&id))?;
            sec::delete_fixed(operation.raw(), false)?;
            drop(operation);
            for name in ["layout.json", "storage-migration-v1.json"] {
                remove(&root.join(name))?;
            }
            let registry = sec::open_lifecycle_directory_move(&root)?;
            sec::delete_fixed(registry.raw(), false)?;
            drop(registry);
            let lock = sec::open_lifecycle_delete(&base.join("maintenance.lock"))?;
            sec::verify_private_member_security(lock.raw(), true)?;
            ensure!(
                file(lock.raw())?.metadata()?.len() == 0,
                "Test coordination lock was not empty."
            );
            sec::delete_fixed(lock.raw(), false)?;
            drop(lock);
            let metadata = sec::open_lifecycle_directory_move(&base)?;
            sec::delete_fixed(metadata.raw(), false)?;
        }
        Ok(())
    }
    #[test]
    fn interrupted_manifest_and_receipt_rebind_only_the_reserved_timestamp() -> Result<()> {
        let temp = std::env::temp_dir();
        ensure!(
            temp.is_absolute() && !win::path::within(&temp, Path::new(env!("CARGO_MANIFEST_DIR")))
        );
        let _parents = win::path::pin_directories(&temp)?;
        let base = temp.join(format!(
            "registry-timestamp-retry-{}",
            uuid::Uuid::new_v4().simple()
        ));
        drop(sec::create_private_directory(&base)?);
        eprintln!("Timestamp owner retry fixture retained: {}", base.display());
        let config = Config {
            path: base.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: base.to_str().unwrap().into(),
                ..Default::default()
            },
        };
        let store = Store::open(&config, true)?;
        for name in [MANIFEST, "registry-restore-intent.json"] {
            let id = uuid::Uuid::new_v4().simple().to_string();
            let _directory = store.create_record(&id)?;
            let created = DateTime::parse_from_rfc3339("2026-11-03T03:30:00.1234567+00:00")?;
            let later = created + chrono::Duration::seconds(9);
            let (expected, fresh, unrelated) = if name == MANIFEST {
                let value = Manifest {
                    scope: None,
                    schema: 5,
                    operation_id: id.clone(),
                    created_utc: created,
                    metadata_root: config.data.backup_directory.clone(),
                    owner_sid: store.state.owner_sid.clone(),
                    path: "HKEY_CURRENT_USER\\Software\\PrunletE2E\\TimestampRetry".into(),
                    view: "64".into(),
                    value_name: Some("payload".into()),
                    kind: "registry-value".into(),
                    size: 3,
                    sha256: hash(b"raw"),
                };
                let expected = serialize(&value)?;
                let mut value = value;
                value.created_utc = later;
                let fresh = serialize(&value)?;
                value.path.push_str("Changed");
                (expected, fresh, serialize(&value)?)
            } else {
                let mut value = Receipt {
                    schema: 5,
                    operation_id: id.clone(),
                    manifest_sha256: hash(b"original manifest"),
                    action: "restore".into(),
                    phase: "intent".into(),
                    created_utc: created,
                };
                let expected = serialize(&value)?;
                value.created_utc = later;
                let fresh = serialize(&value)?;
                value.manifest_sha256 = hash(b"another manifest");
                (expected, fresh, serialize(&value)?)
            };
            ensure!(fresh != expected);
            let operation = id.clone();
            let target_phase = format!("{name}.owner.durable");
            let reached = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let signal = reached.clone();
            super::super::verification_set_checkpoint(Some(std::sync::Arc::new(
                move |event, phase, id| {
                    if event == "RegistryPublicationCheckpoint"
                        && phase == target_phase
                        && id == operation
                    {
                        signal.store(true, std::sync::atomic::Ordering::SeqCst);
                        panic!("Timestamp retry durable checkpoint");
                    }
                },
            )));
            let interrupted = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                store.publish_bytes(&id, name, &expected)
            }));
            super::super::verification_set_checkpoint(None);
            ensure!(reached.load(std::sync::atomic::Ordering::SeqCst) && interrupted.is_err());
            ensure!(
                interrupted.err().unwrap().downcast_ref::<&str>()
                    == Some(&"Timestamp retry durable checkpoint")
            );
            let path = store.root.join(&id);
            let owner = store.publication(&id, &path, name)?;
            ensure!(owner.created_utc == created && owner.sha256 == hash(&expected));
            ensure!(
                store.publish_bytes(&id, name, &unrelated).is_err(),
                "Unrelated retry body was accepted"
            );
            ensure!(
                exists(&path.join(owner_name(name)))?
                    && exists(&path.join(pending_name(name)))?
                    && !exists(&path.join(name))?
            );
            let published = store.publish_bytes(&id, name, &fresh)?;
            ensure!(
                published.bytes == expected && hash(&published.bytes) == owner.sha256,
                "Retry did not retain original reserved bytes/hash"
            );
            published.verify_current()?;
            ensure!(
                !exists(&path.join(owner_name(name)))? && !exists(&path.join(pending_name(name)))?
            );
        }
        drop(store);
        let publication = verification_snapshot_publication(&config)?;
        ensure!(publication["passedCount"] == 3 && publication["failed"] == 0);
        eprintln!("Snapshot publication boundary result: {publication}");
        Ok(())
    }
}
