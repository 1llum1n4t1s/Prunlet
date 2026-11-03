use super::{
    budget,
    package::is_hex,
    state::{AUXILIARY_NAMES, STATE_NAME, UpdateState},
};
use crate::{
    config::Config,
    platform::windows::{self as native, OwnedHandle, PinnedFile, path},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    os::windows::io::FromRawHandle,
    path::{Path, PathBuf},
};
use windows_sys::Win32::{Foundation::*, Storage::FileSystem::*, System::Threading::*};

pub const PRODUCTS: [&str; 3] = ["prunlet.exe", "prunlet-maintenance.exe", "prunlet-hook.exe"];
pub const STAGE: &str = ".prunlet-update-stage";
#[derive(Debug)]
struct Deferred(String);
impl std::fmt::Display for Deferred {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for Deferred {}
pub fn stage_path(root: &Path) -> PathBuf {
    root.join(STAGE)
}
pub fn auxiliary_path(name: &str) -> PathBuf {
    PathBuf::from(if name == "Install-Prunlet.ps1" {
        "scripts"
    } else {
        "integration"
    })
    .join(name)
}
pub fn absent(error: &anyhow::Error) -> bool {
    error
        .chain()
        .filter_map(|e| e.downcast_ref::<std::io::Error>())
        .any(|e| matches!(e.raw_os_error(), Some(2 | 3)))
}
pub fn exists(path: &Path) -> Result<bool> {
    match PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7) {
        Ok(p) => {
            ensure!(
                !p.identity()?.is_reparse(),
                "A reparse entry was preserved."
            );
            Ok(true)
        }
        Err(e) if absent(&e) => Ok(false),
        Err(e) => Err(e),
    }
}
pub fn plain(path: &Path, access: u32, share: u32) -> Result<PinnedFile> {
    let pin = PinnedFile::open(path, access, share)?;
    let id = pin.identity()?;
    ensure!(
        !id.is_directory() && !id.is_reparse() && id.reparse_tag == 0 && id.links == 1,
        "Update product is not a single-link plain file: {}",
        path.display()
    );
    pin.verify_named()?;
    Ok(pin)
}
pub fn stream(pin: &PinnedFile) -> Result<File> {
    unsafe {
        let mut handle = std::ptr::null_mut();
        ensure!(
            DuplicateHandle(
                GetCurrentProcess(),
                pin.raw(),
                GetCurrentProcess(),
                &mut handle,
                0,
                0,
                DUPLICATE_SAME_ACCESS
            ) != 0,
            "Cannot duplicate update handle: {}",
            std::io::Error::last_os_error()
        );
        Ok(File::from_raw_handle(handle))
    }
}
pub fn hash_stream(file: &mut File) -> Result<String> {
    file.seek(SeekFrom::Start(0))?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 131072];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    file.seek(SeekFrom::Start(0))?;
    Ok(hex::encode_upper(hash.finalize()))
}
pub fn hash_file(path: &Path) -> Result<String> {
    let _parents = path::pin_directories(path.parent().context("Missing file parent")?)?;
    let pin = plain(path, GENERIC_READ, FILE_SHARE_READ)?;
    let hash = hash_stream(&mut stream(&pin)?)?;
    pin.verify_named()?;
    Ok(hash)
}
pub fn verify_hash(path: &Path, hash: &str) -> Result<()> {
    ensure!(
        is_hex(hash, 64) && hash_file(path)?.eq_ignore_ascii_case(hash),
        "Product contents do not match the confirmed provenance: {}",
        path.display()
    );
    Ok(())
}
pub fn read_state(root: &Path) -> Result<Option<UpdateState>> {
    let file = root.join(STATE_NAME);
    match native::read_plain_file(&file, 65536, true) {
        Ok(bytes) => Ok(Some(UpdateState::parse(&bytes)?)),
        Err(e) if absent(&e) => Ok(None),
        Err(e) => Err(e),
    }
}
pub fn write_state(root: &Path, state: &UpdateState) -> Result<()> {
    let bytes = state.bytes()?;
    budget::ensure(root, bytes.len() as u64)?;
    let _parents = path::pin_directories(root)?;
    let target = root.join(STATE_NAME);
    let temporary = root.join(format!(
        ".prunlet-update-state.{}.pending",
        uuid::Uuid::new_v4().simple()
    ));
    native::write_new_plain_file(&temporary, &bytes)?;
    if read_state(root)?.is_some() {
        replace(&temporary, &target, None)?;
    } else {
        rename_no_replace(&temporary, &target)?;
    }
    Ok(())
}
pub fn replace(candidate: &Path, current: &Path, backup: Option<&Path>) -> Result<()> {
    unsafe {
        let current = native::win32_path(current)?;
        let candidate = native::win32_path(candidate)?;
        let backup = backup.map(native::win32_path).transpose()?;
        if ReplaceFileW(
            current.as_ptr(),
            candidate.as_ptr(),
            backup.as_ref().map_or(std::ptr::null(), |x| x.as_ptr()),
            0,
            std::ptr::null(),
            std::ptr::null(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    }
}
pub fn rename_no_replace(source: &Path, target: &Path) -> Result<()> {
    let pin = plain(source, GENERIC_READ | DELETE, FILE_SHARE_READ)?;
    let parent = PinnedFile::open(
        target.parent().context("Missing rename parent")?,
        FILE_READ_ATTRIBUTES | FILE_ADD_FILE,
        7,
    )?;
    native::security::rename_fixed(
        pin.raw(),
        parent.raw(),
        target
            .file_name()
            .and_then(|x| x.to_str())
            .context("Invalid rename name")?,
    )?;
    Ok(())
}
pub struct InstallationMutexes {
    handles: Vec<OwnedHandle>,
}
impl InstallationMutexes {
    pub fn acquire(root: &Path) -> Result<Self> {
        let key = hex::encode_upper(Sha256::digest(
            root.to_string_lossy().to_lowercase().as_bytes(),
        ));
        let mut result = Self {
            handles: Vec::new(),
        };
        for scope in ["Global", "Local"] {
            let name = native::wide(std::ffi::OsStr::new(&format!(
                "{scope}\\Prunlet-Install-{key}"
            )))?;
            let handle =
                unsafe { OwnedHandle::from_raw(CreateMutexW(std::ptr::null(), 0, name.as_ptr())) }?;
            let status = unsafe { WaitForSingleObject(handle.raw(), 0) };
            ensure!(
                status == WAIT_OBJECT_0 || status == WAIT_ABANDONED,
                "Another Prunlet installation or update is in progress."
            );
            result.handles.push(handle);
        }
        Ok(result)
    }
}
impl Drop for InstallationMutexes {
    fn drop(&mut self) {
        for h in self.handles.iter().rev() {
            unsafe {
                ReleaseMutex(h.raw());
            }
        }
    }
}
pub fn installation_root(config: &Path) -> Result<PathBuf> {
    ensure!(
        config.is_absolute()
            && config
                .file_name()
                .is_some_and(|x| x.eq_ignore_ascii_case("config.json")),
        "The update coordinator requires the installed config.json."
    );
    let config = path::resolve(config, false, false)?;
    let root = config
        .parent()
        .context("Missing installation root")?
        .to_path_buf();
    let _parents = path::pin_directories(&root)?;
    plain(&config, GENERIC_READ, FILE_SHARE_READ)?;
    Ok(root)
}
#[derive(Clone, Debug)]
pub struct Provenance {
    pub commit: String,
    pub cli_hash: String,
    pub maintenance_hash: String,
    pub hook_hash: String,
    pub auxiliary_hashes: BTreeMap<String, String>,
}
pub fn read_provenance(path: &Path) -> Result<Provenance> {
    let value = crate::json::parse_unique(&native::read_plain_file(path, 65536, false)?)?;
    let object = value
        .as_object()
        .context("Product provenance must be an object.")?;
    let field = |name: &str, len: usize| -> Result<String> {
        let v = object
            .get(name)
            .and_then(Value::as_str)
            .context("Missing provenance identity")?;
        ensure!(is_hex(v, len), "Invalid product provenance {name}");
        Ok(v.to_ascii_uppercase())
    };
    let cli = field("executableSha256", 64)?;
    let hook = field("hookExecutableSha256", 64)?;
    ensure!(
        hook == cli,
        "Hook product does not match the CLI executable."
    );
    let map = object
        .get("auxiliarySha256")
        .and_then(Value::as_object)
        .context("Invalid auxiliary map")?;
    ensure!(
        map.len() == AUXILIARY_NAMES.len(),
        "Unknown or missing auxiliary products"
    );
    let mut auxiliary = BTreeMap::new();
    for name in AUXILIARY_NAMES {
        let key = format!("bin\\{name}");
        let hash = map
            .get(&key)
            .and_then(Value::as_str)
            .context("Missing auxiliary hash")?;
        ensure!(is_hex(hash, 64), "Invalid auxiliary hash");
        auxiliary.insert(key, hash.to_ascii_uppercase());
    }
    Ok(Provenance {
        commit: field("commitSha", 40)?,
        cli_hash: cli,
        maintenance_hash: field("maintenanceExecutableSha256", 64)?,
        hook_hash: hook,
        auxiliary_hashes: auxiliary,
    })
}
pub fn verify_stage_owner(stage: &Path, root: &Path, commit: &str) -> Result<()> {
    let value = crate::json::parse_unique(&native::read_plain_file(
        &stage.join(".prunlet-stage-owner.json"),
        65536,
        false,
    )?)?;
    let map = value.as_object().context("Stage owner must be an object")?;
    ensure!(
        map.len() == 5
            && value["product"] == "Prunlet"
            && value["schema"] == 1
            && value["epoch"] == 1
            && value["installRoot"]
                .as_str()
                .is_some_and(|x| x.eq_ignore_ascii_case(&root.to_string_lossy()))
            && value["candidateCommit"]
                .as_str()
                .is_some_and(|x| x.eq_ignore_ascii_case(commit)),
        "Stage ownership does not match the pending update state."
    );
    Ok(())
}
pub fn verify_candidate_process(stage: &Path) -> Result<()> {
    ensure!(
        path::resolve(&std::env::current_exe()?, false, false)? == stage.join("prunlet.exe"),
        "The update coordinator must run from the fixed candidate executable."
    );
    Ok(())
}
pub fn create_plain(path: &Path) -> Result<(PinnedFile, File)> {
    let name = native::win32_path(path)?;
    let handle = unsafe {
        OwnedHandle::from_raw(CreateFileW(
            name.as_ptr(),
            GENERIC_READ | GENERIC_WRITE | DELETE,
            0,
            std::ptr::null(),
            CREATE_NEW,
            FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        ))
    }?;
    let pin = PinnedFile::from_handle(path.to_path_buf(), handle)?;
    let file = stream(&pin)?;
    Ok((pin, file))
}
pub fn copy_verified(
    input: &mut dyn Read,
    output: &mut File,
    bytes: u64,
    hash: &str,
) -> Result<()> {
    ensure!(
        bytes > 0 && bytes <= 536870912 && is_hex(hash, 64),
        "Invalid product length or hash"
    );
    output.seek(SeekFrom::Start(0))?;
    output.set_len(0)?;
    let mut digest = Sha256::new();
    let mut total = 0u64;
    let mut buffer = [0u8; 131072];
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        total = total
            .checked_add(n as u64)
            .context("Product length overflow")?;
        ensure!(total <= bytes, "Product exceeds its authenticated length");
        output.write_all(&buffer[..n])?;
        digest.update(&buffer[..n]);
    }
    output.sync_all()?;
    ensure!(
        total == bytes && hex::encode_upper(digest.finalize()).eq_ignore_ascii_case(hash),
        "Product hash or length differs; partial output was preserved."
    );
    output.seek(SeekFrom::Start(0))?;
    Ok(())
}
pub fn stage_product(
    root: &Path,
    state: &mut UpdateState,
    name: &str,
    path: &Path,
    input: &mut dyn Read,
    bytes: u64,
    new_hash: &str,
    old_hash: Option<&str>,
) -> Result<()> {
    if !exists(path)? {
        ensure!(
            state.stage_write_name != name,
            "An interrupted staged cache file is missing and was not recreated."
        );
        budget::ensure(root, bytes)?;
        let (pin, mut output) = create_plain(path)?;
        copy_verified(input, &mut output, bytes, new_hash)?;
        pin.verify_named()?;
        return Ok(());
    }
    native::reject_named_streams(path)?;
    let actual = hash_file(path)?;
    if actual.eq_ignore_ascii_case(new_hash) {
        if state.stage_write_name == name {
            ensure!(
                state.stage_write_new_sha256.eq_ignore_ascii_case(new_hash)
                    && state.stage_write_bytes == bytes as i64
                    && old_hash
                        .is_some_and(|h| state.stage_write_old_sha256.eq_ignore_ascii_case(h)),
                "Staged write record differs from candidate"
            );
            clear_stage_write(root, state)?;
        }
        return Ok(());
    }
    let old_hash = old_hash.context("An unexpected staged cache file was preserved")?;
    ensure!(
        is_hex(old_hash, 64) && actual.eq_ignore_ascii_case(old_hash),
        "A changed staged cache file was preserved: {}",
        path.display()
    );
    ensure!(
        state.stage_write_name.is_empty()
            || (state.stage_write_name == name
                && state.stage_write_old_sha256.eq_ignore_ascii_case(old_hash)
                && state.stage_write_new_sha256.eq_ignore_ascii_case(new_hash)
                && state.stage_write_bytes == bytes as i64),
        "A different interrupted staged write was preserved"
    );
    let pin = plain(
        path,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_DELETE,
    )?;
    let mut output = stream(&pin)?;
    ensure!(
        hash_stream(&mut output)?.eq_ignore_ascii_case(old_hash),
        "Staged content changed before writing"
    );
    native::reject_named_streams(path)?;
    budget::ensure(root, bytes.saturating_sub(output.metadata()?.len()))?;
    state.stage_write_name = name.into();
    state.stage_write_old_sha256 = old_hash.into();
    state.stage_write_new_sha256 = new_hash.into();
    state.stage_write_bytes = bytes as i64;
    write_state(root, state)?;
    copy_verified(input, &mut output, bytes, new_hash)?;
    pin.verify_named()?;
    native::reject_named_streams(path)?;
    clear_stage_write(root, state)
}
fn clear_stage_write(root: &Path, state: &mut UpdateState) -> Result<()> {
    state.stage_write_name.clear();
    state.stage_write_old_sha256.clear();
    state.stage_write_new_sha256.clear();
    state.stage_write_bytes = 0;
    write_state(root, state)
}

pub fn execute(config: &Config, command: &str, args: &Value) -> Result<Value> {
    let argv = args
        .get("argv")
        .and_then(Value::as_array)
        .context("Update command requires argv")?
        .iter()
        .map(|v| v.as_str().context("Update arguments must be strings"))
        .collect::<Result<Vec<_>>>()?;
    let root = installation_root(&config.path)?;
    match command {
        "__begin-published-update" => {
            ensure!(
                argv.len() == 2,
                "Resolved release and expected installed commits are required."
            );
            begin(&root, argv[0], argv[1])
        }
        "__check-startup-budget" => {
            ensure!(
                argv.len() == 1,
                "Specify the additional update storage bytes."
            );
            budget::ensure(&root, number(argv[0])?)?;
            Ok(json!({"status":"available"}))
        }
        "__download-published-package" => {
            ensure!(
                argv.len() == 5 || argv.len() == 7,
                "Published download requires repository, commit, asset ID, SHA-256 and byte length."
            );
            let cache_reused = super::download::receive_from(
                &root,
                argv[0],
                argv[1],
                number(argv[2])?,
                argv[3],
                number(argv[4])?,
                super::distribution::Source::parse(argv.get(5).copied())?,
                argv.get(6).copied(),
            )?;
            Ok(json!({"status":"downloaded","cacheReused":cache_reused}))
        }
        "__prepare-published-package" => {
            ensure!(
                argv.len() == 7 || argv.len() == 8,
                "Published preparation requires repository, branch, commit, runtime, SHA-256, byte length and asset ID."
            );
            prepare_from(
                &root,
                argv[0],
                argv[1],
                argv[2],
                argv[3],
                argv[4],
                number(argv[5])?,
                number(argv[6])?,
                super::distribution::Source::parse(argv.get(7).copied())?,
            )
        }
        "__apply-startup-update" => {
            ensure!(argv.is_empty(), "Startup update accepts no arguments");
            apply(config, &root)
        }
        "__apply-startup-integration" => {
            ensure!(argv.is_empty(), "Startup integration accepts no arguments");
            super::integration::apply(config)?;
            Ok(json!({"status":"integration_applied"}))
        }
        "__confirm-startup-integration" => {
            ensure!(argv.is_empty(), "Startup integration accepts no arguments");
            super::integration::confirm(config)?;
            Ok(json!({"status":"integration_confirmed"}))
        }
        "__cleanup-startup-stage" => {
            ensure!(argv.is_empty(), "Stage cleanup accepts no arguments");
            super::gate::ensure_ready(&config.path)?;
            cleanup(&root)
        }
        _ => bail!("Unknown startup update command"),
    }
}
fn number(text: &str) -> Result<u64> {
    ensure!(
        !text.is_empty() && text.bytes().all(|c| c.is_ascii_digit()),
        "Update numeric arguments must contain decimal digits only"
    );
    let value: u64 = text.parse()?;
    ensure!(
        value <= i64::MAX as u64,
        "Update numeric argument exceeds the supported signed 64-bit range"
    );
    Ok(value)
}

fn owner_bytes(root: &Path, commit: &str) -> Result<Vec<u8>> {
    protocol_json(
        &json!({"product":"Prunlet","schema":1,"installRoot":root,"candidateCommit":commit.to_ascii_uppercase(),"epoch":1}),
        &[
            "product",
            "schema",
            "installRoot",
            "candidateCommit",
            "epoch",
        ],
    )
}
// 旧CLIもprepareを再実行するため、意味だけでなく正本のJSON bytesも維持する。
// JsonSerializerDefaults.Web/JavaScriptEncoder.DefaultのASCII出力と宣言順に合わせる。
fn protocol_json(value: &Value, order: &[&str]) -> Result<Vec<u8>> {
    fn quoted(text: &str, output: &mut String) {
        output.push('"');
        for unit in text.encode_utf16() {
            match unit {
                8 => output.push_str("\\b"),
                9 => output.push_str("\\t"),
                10 => output.push_str("\\n"),
                12 => output.push_str("\\f"),
                13 => output.push_str("\\r"),
                92 => output.push_str("\\\\"),
                0..=31 | 127..=65535 | 34 | 38 | 39 | 43 | 60 | 62 | 96 => {
                    use std::fmt::Write;
                    let _ = write!(output, "\\u{unit:04X}");
                }
                _ => output.push(char::from_u32(unit as u32).expect("ASCII code unit")),
            }
        }
        output.push('"');
    }
    fn write(value: &Value, order: Option<&[&str]>, output: &mut String) -> Result<()> {
        match value {
            Value::String(text) => quoted(text, output),
            Value::Object(map) => {
                output.push('{');
                let keys: Vec<String> = if let Some(order) = order {
                    ensure!(
                        map.len() == order.len() && order.iter().all(|k| map.contains_key(*k)),
                        "Protocol JSON fields differ"
                    );
                    order.iter().map(|s| s.to_string()).collect()
                } else {
                    map.keys().cloned().collect()
                };
                for (i, key) in keys.iter().enumerate() {
                    if i != 0 {
                        output.push(',');
                    }
                    quoted(key, output);
                    output.push(':');
                    if key == "auxiliarySha256" {
                        let names: Vec<String> = AUXILIARY_NAMES
                            .iter()
                            .map(|n| format!("bin\\{n}"))
                            .collect();
                        let names: Vec<&str> = names.iter().map(String::as_str).collect();
                        write(&map[key], Some(&names), output)?;
                    } else {
                        write(&map[key], None, output)?;
                    }
                }
                output.push('}');
            }
            Value::Array(items) => {
                output.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i != 0 {
                        output.push(',');
                    }
                    write(item, None, output)?;
                }
                output.push(']');
            }
            _ => output.push_str(&value.to_string()),
        }
        Ok(())
    }
    let mut output = String::new();
    write(value, Some(order), &mut output)?;
    Ok(output.into_bytes())
}
fn update_owner(root: &Path, state: &mut UpdateState) -> Result<()> {
    let bytes = owner_bytes(root, &state.candidate_commit)?;
    let hash = hex::encode_upper(Sha256::digest(&bytes));
    let old = state.prior_owner_sha256.clone();
    let owner = stage_path(root).join(".prunlet-stage-owner.json");
    if adopt_equal_json(
        root,
        state,
        "owner",
        &owner,
        &crate::json::parse_unique(&bytes)?,
        Some(&old),
    )? {
        return verify_stage_owner(&stage_path(root), root, &state.candidate_commit);
    }
    stage_product(
        root,
        state,
        "owner",
        &stage_path(root).join(".prunlet-stage-owner.json"),
        &mut bytes.as_slice(),
        bytes.len() as u64,
        &hash,
        Some(&old),
    )?;
    verify_stage_owner(&stage_path(root), root, &state.candidate_commit)
}
// 旧実装が確定した同じJSONは、キー順やUnicodeエスケープの違いだけで書き直さない。
// 未完了journalを消す場合も、記録済みbytes/hashと現物が一致した完全出力だけを認める。
fn adopt_equal_json(
    root: &Path,
    state: &mut UpdateState,
    key: &str,
    path: &Path,
    expected: &Value,
    old: Option<&str>,
) -> Result<bool> {
    if !exists(path)? {
        return Ok(false);
    }
    let bytes = native::read_plain_file(path, 65536, true)?;
    let value = crate::json::parse_unique(&bytes)?;
    if &value != expected {
        return Ok(false);
    }
    if !state.stage_write_name.is_empty() {
        ensure!(
            state.stage_write_name == key
                && state
                    .stage_write_new_sha256
                    .eq_ignore_ascii_case(&hex::encode_upper(Sha256::digest(&bytes)))
                && state.stage_write_bytes == bytes.len() as i64
                && old.is_some_and(|h| h.eq_ignore_ascii_case(&state.stage_write_old_sha256)),
            "A different or incomplete staged JSON write was preserved"
        );
        clear_stage_write(root, state)?;
    }
    Ok(true)
}
fn stage_reserve(path: &Path, bytes: u64, hash: &str, old: Option<&str>) -> Result<u64> {
    if !exists(path)? {
        return Ok(bytes);
    }
    let pin = plain(path, GENERIC_READ, FILE_SHARE_READ)?;
    native::reject_named_streams(path)?;
    let mut file = stream(&pin)?;
    let actual = hash_stream(&mut file)?;
    ensure!(
        actual.eq_ignore_ascii_case(hash) || old.is_some_and(|h| h.eq_ignore_ascii_case(&actual)),
        "Changed staged cache file was preserved"
    );
    if old.is_none() {
        ensure!(
            file.metadata()?.len() == bytes,
            "Staged product length differs from confirmed product"
        );
    }
    Ok(bytes.saturating_sub(file.metadata()?.len()))
}
fn plain_directory(path: &Path) -> Result<()> {
    if !exists(path)? {
        std::fs::create_dir(path)?;
    }
    let _parents = path::pin_directories(path)?;
    let pin = PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7)?;
    ensure!(
        pin.identity()?.is_directory() && !pin.identity()?.is_reparse(),
        "Update directory is not plain"
    );
    Ok(())
}
fn ensure_slots(root: &Path) -> Result<()> {
    let directory = root.join(".prunlet-update-slots");
    let marker = directory.join(".prunlet-slot-owner.json");
    let bytes = serde_json::to_vec(&json!({"product":"Prunlet","schema":1,"installRoot":root}))?;
    if exists(&directory)? {
        let old = native::read_plain_file(&marker, 65536, true)?;
        let value = crate::json::parse_unique(&old)?;
        ensure!(
            value.as_object().is_some_and(|v| v.len() == 3)
                && value["product"] == "Prunlet"
                && value["schema"] == 1
                && value["installRoot"]
                    .as_str()
                    .is_some_and(|v| v.eq_ignore_ascii_case(&root.to_string_lossy())),
            "Slot directory ownership differs"
        );
    } else {
        plain_directory(&directory)?;
        budget::ensure(root, bytes.len() as u64)?;
        native::write_new_plain_file(&marker, &bytes)?;
    }
    super::slot::measure(&directory)?;
    Ok(())
}
pub fn begin(root: &Path, commit: &str, expected_installed: &str) -> Result<Value> {
    ensure!(
        is_hex(commit, 40) && is_hex(expected_installed, 40),
        "Resolved release and expected installed commits are required."
    );
    let _parents = path::pin_directories(root)?;
    let _mutex = InstallationMutexes::acquire(root)?;
    let installed_info = root.join("source-info.json");
    let installed = read_provenance(&installed_info)?;
    ensure!(
        installed.commit.eq_ignore_ascii_case(expected_installed),
        "Installed commit changed after release ancestry was checked; update deferred"
    );
    let installed_hash = hash_file(&installed_info)?;
    let stage = stage_path(root);
    let state = read_state(root)?;
    let mut warnings = Vec::<String>::new();
    if let Some(mut state) = state.clone() {
        ensure!(
            state.phase == "idle",
            "A previous update is still active and was preserved"
        );
        if state.stage_cleanup == "pending" {
            if state.migration_complete && exists(&stage)? && !state.candidate_cli_sha256.is_empty()
            {
                ensure!(
                    !state.candidate_commit.eq_ignore_ascii_case(commit),
                    "Requested release is already installed"
                );
                verify_stage_owner(&stage, root, &state.candidate_commit)?;
                native::reject_named_streams(&stage.join(".prunlet-stage-owner.json"))?;
                verify_hash(
                    &stage.join("source-info.json"),
                    &state.candidate_source_info_sha256,
                )?;
                verify_hash(&installed_info, &state.candidate_source_info_sha256)?;
                ensure!(
                    installed.commit == state.candidate_commit.to_ascii_uppercase(),
                    "Installed provenance does not match retained stage"
                );
                let prior = read_provenance(&stage.join("previous-source-info.json"))?;
                ensure!(
                    prior.commit == state.old_commit.to_ascii_uppercase(),
                    "Previous provenance differs from retained stage"
                );
                let previous_hash = hash_file(&stage.join("previous-source-info.json"))?;
                verify_hash(
                    &stage.join("previous-source-info-original.json"),
                    &previous_hash,
                )?;
                let mut prior_auxiliary = prior.auxiliary_hashes.clone();
                for (key, hash) in &state.auxiliary_backup_sha256 {
                    let name = key
                        .strip_prefix("bin\\")
                        .context("Invalid auxiliary backup key")?;
                    let backup = stage.join("previous-auxiliary").join(name);
                    native::reject_named_streams(&backup)?;
                    verify_hash(&backup, hash)?;
                    prior_auxiliary.insert(key.clone(), hash.clone());
                }
                let owner_hash = hash_file(&stage.join(".prunlet-stage-owner.json"))?;
                let package_path = stage.join(&state.package_name);
                let package_identity = (|| -> Result<(String, i64)> {
                    let v = crate::json::parse_unique(&native::read_plain_file(
                        &installed_info,
                        65536,
                        false,
                    )?)?;
                    let hash = v["archiveSha256"]
                        .as_str()
                        .context("Missing archive hash")?;
                    ensure!(is_hex(hash, 64), "Invalid archive hash");
                    native::reject_named_streams(&package_path)?;
                    verify_hash(&package_path, hash)?;
                    Ok((
                        hash.to_string(),
                        std::fs::metadata(&package_path)?.len() as i64,
                    ))
                })();
                let (package_name, package_hash, package_bytes) = match package_identity {
                    Ok((h, b)) => (state.package_name.clone(), h, b),
                    Err(_) => {
                        warnings
                            .push("A previous package cache was retained and not reused.".into());
                        (
                            format!("package-{}.zip", uuid::Uuid::new_v4().simple()),
                            String::new(),
                            0,
                        )
                    }
                };
                state = UpdateState {
                    candidate_commit: commit.to_ascii_uppercase(),
                    prepared_installed_source_info_sha256: installed_hash,
                    stage_cleanup: "pending".into(),
                    slot_cli: state.slot_cli,
                    slot_maintenance: state.slot_maintenance,
                    slot_hook: state.slot_hook,
                    prior_stage_commit: installed.commit,
                    prior_stage_info_sha256: state.candidate_source_info_sha256,
                    prior_previous_info_sha256: previous_hash,
                    prior_owner_sha256: owner_hash,
                    prior_cli_sha256: prior.cli_hash,
                    prior_maintenance_sha256: prior.maintenance_hash,
                    prior_hook_sha256: prior.hook_hash,
                    prior_auxiliary_sha256: Some(prior_auxiliary),
                    auxiliary_backup_sha256: state.auxiliary_backup_sha256,
                    package_name,
                    package_status: if package_hash.is_empty() {
                        "none"
                    } else {
                        "ready"
                    }
                    .into(),
                    package_previous_sha256: package_hash,
                    package_previous_bytes: package_bytes,
                    ..Default::default()
                };
                write_state(root, &state)?;
                update_owner(root, &mut state)?;
                return Ok(
                    json!({"status":"ready","candidateCommit":commit.to_ascii_uppercase(),"warnings":warnings}),
                );
            }
            ensure!(
                state.candidate_commit.eq_ignore_ascii_case(commit)
                    && state.candidate_cli_sha256.is_empty()
                    && !state.migration_complete
                    && !state.integration_ready,
                "A previous update stage requires attention and was preserved"
            );
            ensure!(
                installed_hash.eq_ignore_ascii_case(&state.prepared_installed_source_info_sha256),
                "Installed provenance changed after preparation"
            );
            if exists(&stage)? {
                if !state.prior_stage_commit.is_empty() {
                    update_owner(root, &mut state)?;
                }
                verify_stage_owner(&stage, root, commit)?;
                return Ok(
                    json!({"status":"existing","candidateCommit":commit.to_ascii_uppercase()}),
                );
            }
        } else {
            ensure!(
                matches!(state.stage_cleanup.as_str(), "none" | "done"),
                "Prior stage cleanup outcome is uncertain"
            );
            ensure!(
                state.candidate_cli_sha256.is_empty()
                    || [
                        &state.cleanup_cli,
                        &state.cleanup_maintenance,
                        &state.cleanup_hook
                    ]
                    .iter()
                    .all(|s| s.as_str() == "done"),
                "A previous update or its cleanup requires attention and was preserved"
            );
            ensure!(!exists(&stage)?, "An unowned update stage was preserved");
        }
    } else {
        ensure!(!exists(&stage)?, "An unowned update stage was preserved");
    }
    let already_pending = state.as_ref().is_some_and(|s| s.stage_cleanup == "pending");
    let state = if already_pending {
        state.context("Pending update state missing")?
    } else {
        UpdateState {
            candidate_commit: commit.to_ascii_uppercase(),
            stage_cleanup: "pending".into(),
            prepared_installed_source_info_sha256: installed_hash,
            slot_cli: state.as_ref().and_then(|s| s.slot_cli.clone()),
            slot_maintenance: state.as_ref().and_then(|s| s.slot_maintenance.clone()),
            slot_hook: state.as_ref().and_then(|s| s.slot_hook.clone()),
            ..Default::default()
        }
    };
    if !already_pending {
        write_state(root, &state)?;
    }
    plain_directory(&stage)?;
    let bytes = owner_bytes(root, commit)?;
    budget::ensure(root, bytes.len() as u64)?;
    native::write_new_plain_file(&stage.join(".prunlet-stage-owner.json"), &bytes)?;
    verify_stage_owner(&stage, root, commit)?;
    Ok(json!({"status":"ready","candidateCommit":commit.to_ascii_uppercase()}))
}
const SOURCE_INFO_FIELDS: [&str; 10] = [
    "repository",
    "defaultBranch",
    "commitSha",
    "downloadUrl",
    "archiveSha256",
    "executableSha256",
    "maintenanceExecutableSha256",
    "hookExecutableSha256",
    "auxiliarySha256",
    "runtime",
];

fn source_info(
    products: &[super::package::Product],
    repository: &str,
    branch: &str,
    commit: &str,
    runtime: &str,
    hash: &str,
    url: &str,
) -> Result<(Value, Vec<u8>)> {
    let lookup = |name: &str| {
        products
            .iter()
            .find(|p| p.name == format!("bin/{name}"))
            .map(|p| p.sha256.clone())
            .context("Missing package product hash")
    };
    let mut auxiliary = BTreeMap::new();
    for name in AUXILIARY_NAMES {
        auxiliary.insert(format!("bin\\{name}"), lookup(name)?);
    }
    let info = json!({"repository":repository,"defaultBranch":branch,"commitSha":commit.to_ascii_lowercase(),"downloadUrl":url,"archiveSha256":hash.to_ascii_uppercase(),"executableSha256":lookup(PRODUCTS[0])?,"maintenanceExecutableSha256":lookup(PRODUCTS[1])?,"hookExecutableSha256":lookup(PRODUCTS[2])?,"auxiliarySha256":auxiliary,"runtime":runtime});
    let bytes = protocol_json(&info, &SOURCE_INFO_FIELDS)?;
    Ok((info, bytes))
}

pub fn resolve_distribution(
    stage: &Path,
    state: &UpdateState,
    repository: &str,
    branch: Option<&str>,
    commit: &str,
    runtime: Option<&str>,
    hash: &str,
    bytes: u64,
    asset: u64,
    requested: super::distribution::Source,
) -> Result<(super::distribution::Source, String)> {
    use super::distribution::Source;
    let requested_url = requested.url(repository, commit, runtime, hash, asset)?;
    let info_path = stage.join("source-info.json");
    if !exists(&info_path)? {
        return Ok((requested, requested_url));
    }
    let info_pin = plain(&info_path, GENERIC_READ, FILE_SHARE_READ)?;
    native::reject_named_streams(&info_path)?;
    let actual = native::read_plain_file(&info_path, 65536, true)?;
    let info = crate::json::parse_unique(&actual)?;
    let actual_hash = hex::encode_upper(Sha256::digest(&actual));
    let recorded_commit = info
        .get("commitSha")
        .and_then(Value::as_str)
        .context("Prepared provenance has no commit")?;
    if !recorded_commit.eq_ignore_ascii_case(commit) {
        assert_distribution_binding(stage, state, commit, &requested_url)?;
        info_pin.verify_named()?;
        return Ok((requested, requested_url));
    }
    let runtime = runtime
        .or_else(|| info.get("runtime").and_then(Value::as_str))
        .context("Prepared distribution has no runtime")?;
    let branch = branch
        .or_else(|| info.get("defaultBranch").and_then(Value::as_str))
        .context("Prepared distribution has no branch")?;
    let url = info
        .get("downloadUrl")
        .and_then(Value::as_str)
        .context("Prepared distribution has no URL")?;
    let github = Source::Github.url(repository, commit, Some(runtime), hash, asset)?;
    let selected = if url == github {
        Source::Github
    } else {
        ensure!(
            url == Source::R2.url(repository, commit, Some(runtime), hash, asset)?,
            "Unknown prepared distribution URL was preserved"
        );
        Source::R2
    };
    let package_path = stage.join(&state.package_name);
    let package_pin = plain(&package_path, GENERIC_READ, FILE_SHARE_READ)?;
    native::reject_named_streams(&package_path)?;
    let package = super::package::VerifiedPackage::open(
        stream(&package_pin)?,
        repository,
        branch,
        commit,
        runtime,
        hash,
        bytes,
    )?;
    let (expected, _) = source_info(
        &package.products,
        repository,
        branch,
        commit,
        runtime,
        hash,
        url,
    )?;
    ensure!(
        info == expected,
        "Prepared distribution provenance differs from the authenticated package"
    );
    ensure!(
        state.candidate_source_info_sha256.is_empty()
            || state
                .candidate_source_info_sha256
                .eq_ignore_ascii_case(&actual_hash),
        "Prepared distribution hash differs from its state"
    );
    if !state.stage_write_name.is_empty() {
        ensure!(
            state.stage_write_name == "source-info.json"
                && state
                    .stage_write_new_sha256
                    .eq_ignore_ascii_case(&actual_hash)
                && state
                    .stage_write_old_sha256
                    .eq_ignore_ascii_case(&state.prior_stage_info_sha256)
                && state.stage_write_bytes == actual.len() as i64,
            "Incomplete prepared distribution provenance was preserved"
        );
    }
    package_pin.verify_named()?;
    info_pin.verify_named()?;
    Ok((selected, url.to_owned()))
}
pub fn prepare(
    root: &Path,
    repository: &str,
    branch: &str,
    commit: &str,
    runtime: &str,
    hash: &str,
    bytes: u64,
    asset: u64,
) -> Result<Value> {
    prepare_from(
        root,
        repository,
        branch,
        commit,
        runtime,
        hash,
        bytes,
        asset,
        super::distribution::Source::Github,
    )
}

// source-infoのURLは接続履歴ではなく、このdigestに対して選択した正規配布先。
// 同じcandidateのprepare完了後は、cache経由でも配布先を再bindしない。
pub fn assert_distribution_binding(
    stage: &Path,
    state: &UpdateState,
    commit: &str,
    url: &str,
) -> Result<()> {
    let path = stage.join("source-info.json");
    if !exists(&path)? {
        return Ok(());
    }
    let bytes = native::read_plain_file(&path, 65536, true)?;
    let info = crate::json::parse_unique(&bytes)?;
    let recorded_commit = info
        .get("commitSha")
        .and_then(Value::as_str)
        .context("Staged provenance has no commit")?;
    if recorded_commit.eq_ignore_ascii_case(commit) {
        ensure!(
            info.get("downloadUrl").and_then(Value::as_str) == Some(url),
            "Prepared distribution source differs; the staged provenance was preserved"
        );
    } else {
        ensure!(
            recorded_commit.eq_ignore_ascii_case(&state.prior_stage_commit)
                && hex::encode_upper(Sha256::digest(&bytes))
                    .eq_ignore_ascii_case(&state.prior_stage_info_sha256),
            "Unknown staged provenance was preserved"
        );
    }
    Ok(())
}

#[cfg(test)]
mod distribution_binding_tests {
    use super::*;
    #[test]
    fn prepared_distribution_does_not_rebind_as_known_previous_bytes() -> Result<()> {
        let temp = PathBuf::from(std::env::var_os("TEMP").context("External TEMP required")?);
        ensure!(
            temp.is_absolute() && temp.to_string_lossy().starts_with("D:\\"),
            "External D TEMP required"
        );
        let _parents = path::pin_directories(&temp)?;
        let stage = temp.join(format!(
            "distribution-binding-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _stage = native::security::create_private_directory(&stage)?;
        let commit = "a".repeat(40);
        let old_url = "https://api.github.com/repos/1llum1n4t1s/Prunlet/releases/assets/1";
        let bytes = serde_json::to_vec(&json!({"commitSha":commit,"downloadUrl":old_url}))?;
        let (_pin, mut file) = create_plain(&stage.join("source-info.json"))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        drop(_pin);
        let mut state = UpdateState::default();
        state.prior_stage_commit = commit.clone();
        state.prior_stage_info_sha256 = hex::encode_upper(Sha256::digest(&bytes));
        assert_distribution_binding(&stage, &state, &commit, old_url)?;
        let new_url = super::super::distribution::Source::R2.url(
            super::super::distribution::OFFICIAL_REPOSITORY,
            &commit,
            Some("win-x64"),
            &"b".repeat(64),
            1,
        )?;
        assert!(assert_distribution_binding(&stage, &state, &commit, &new_url).is_err());
        assert_distribution_binding(&stage, &state, &"c".repeat(40), &new_url)?;
        state.prior_stage_info_sha256 = "d".repeat(64);
        assert!(assert_distribution_binding(&stage, &state, &"c".repeat(40), &new_url).is_err());
        ensure!(
            native::read_plain_file(&stage.join("source-info.json"), 65536, true)? == bytes,
            "Binding check changed provenance"
        );
        eprintln!("Retained distribution binding fixture: {}", stage.display());
        Ok(())
    }
}

fn prepare_from(
    root: &Path,
    repository: &str,
    branch: &str,
    commit: &str,
    runtime: &str,
    hash: &str,
    bytes: u64,
    asset: u64,
    source: super::distribution::Source,
) -> Result<Value> {
    ensure!(
        asset > 0
            && regex::Regex::new(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z")?.is_match(repository),
        "Valid authenticated release repository and asset ID required"
    );
    let _mutex = InstallationMutexes::acquire(root)?;
    let mut state = read_state(root)?.context("Update preparation state is missing")?;
    ensure!(
        state.phase == "idle"
            && state.stage_cleanup == "pending"
            && !state.migration_complete
            && state.candidate_cli_sha256.is_empty()
            && state.candidate_commit.eq_ignore_ascii_case(commit),
        "Update stage is not ready for package preparation"
    );
    let stage = stage_path(root);
    let _parents = path::pin_directories(&stage)?;
    verify_stage_owner(&stage, root, commit)?;
    let (_, download_url) = resolve_distribution(
        &stage,
        &state,
        repository,
        Some(branch),
        commit,
        Some(runtime),
        hash,
        bytes,
        asset,
        source,
    )?;
    let package_path = stage.join(&state.package_name);
    let pin = plain(&package_path, GENERIC_READ, FILE_SHARE_READ)?;
    native::reject_named_streams(&package_path)?;
    let mut package = super::package::VerifiedPackage::open(
        stream(&pin)?,
        repository,
        branch,
        commit,
        runtime,
        hash,
        bytes,
    )?;
    budget::ensure(root, 0)?;
    ensure_slots(root)?;
    let prior = if state.prior_stage_commit.is_empty() {
        None
    } else {
        Some(read_provenance(&root.join("source-info.json"))?)
    };
    if let Some(prior) = &prior {
        ensure!(
            prior.commit.eq_ignore_ascii_case(&state.prior_stage_commit),
            "Installed provenance changed from prior stage"
        );
    }
    let mut warnings = Vec::<String>::new();
    for (index, leaf) in PRODUCTS.iter().enumerate() {
        let name = format!("bin/{leaf}");
        let product = package
            .products
            .iter()
            .find(|p| p.name == name)
            .context("Missing package product")?
            .clone();
        let previous = match index {
            0 => state.slot_cli.clone(),
            1 => state.slot_maintenance.clone(),
            _ => state.slot_hook.clone(),
        };
        if previous.as_ref().is_some_and(|p| p.status == "writing") {
            warnings.push(format!("An interrupted product slot was retained: {leaf}"));
        }
        let reusable = previous.filter(|p| p.status == "ready");
        let old = prior.as_ref().map(|p| {
            [
                p.cli_hash.as_str(),
                p.maintenance_hash.as_str(),
                p.hook_hash.as_str(),
            ][index]
        });
        let reserve = stage_reserve(&stage.join(leaf), product.bytes, &product.sha256, old)?;
        budget::ensure(
            root,
            product
                .bytes
                .checked_add(reserve)
                .context("Product capacity overflow")?,
        )?;
        let mut lease = super::slot::acquire(
            root,
            ["cli", "maintenance", "hook"][index],
            reusable.as_ref(),
            product.bytes,
        )?;
        if !lease.reused && reusable.is_some() {
            warnings.push(format!(
                "A previous product slot was retained: {leaf} ({})",
                lease.previous_status
            ));
        }
        let slot = super::state::PublishedSlot {
            generation: lease.generation.clone(),
            sha256: product.sha256.clone(),
            bytes: product.bytes as i64,
            status: "writing".into(),
        };
        match index {
            0 => state.slot_cli = Some(slot),
            1 => state.slot_maintenance = Some(slot),
            _ => state.slot_hook = Some(slot),
        }
        let _guards = budget::with_guards(&[&lease.pin])?;
        write_state(root, &state)?;
        if !lease.reused
            || reusable.as_ref().is_none_or(|p| {
                !p.sha256.eq_ignore_ascii_case(&product.sha256) || p.bytes != product.bytes as i64
            })
        {
            lease.write(
                &mut package.open_product(&name)?,
                product.bytes,
                &product.sha256,
            )?;
        } else {
            lease.verify(product.bytes, &product.sha256)?;
        }
        match index {
            0 => state.slot_cli.as_mut(),
            1 => state.slot_maintenance.as_mut(),
            _ => state.slot_hook.as_mut(),
        }
        .unwrap()
        .status = "ready".into();
        write_state(root, &state)?;
        lease.verify(product.bytes, &product.sha256)?;
        let old = prior.as_ref().map(|p| {
            [
                p.cli_hash.as_str(),
                p.maintenance_hash.as_str(),
                p.hook_hash.as_str(),
            ][index]
        });
        stage_product(
            root,
            &mut state,
            leaf,
            &stage.join(leaf),
            &mut lease.file,
            product.bytes,
            &product.sha256,
            old,
        )?;
        lease.verify(product.bytes, &product.sha256)?;
    }
    plain_directory(&stage.join("scripts"))?;
    plain_directory(&stage.join("integration"))?;
    for name in AUXILIARY_NAMES {
        let key = format!("bin\\{name}");
        let product = package
            .products
            .iter()
            .find(|p| p.name == format!("bin/{name}"))
            .context("Missing auxiliary product")?
            .clone();
        let relative = auxiliary_path(name);
        let old = prior
            .as_ref()
            .and_then(|p| p.auxiliary_hashes.get(&key))
            .map(String::as_str);
        stage_product(
            root,
            &mut state,
            &relative.to_string_lossy(),
            &stage.join(&relative),
            &mut package.open_product(&product.name)?,
            product.bytes,
            &product.sha256,
            old,
        )?;
    }
    let (info, bytes) = source_info(
        &package.products,
        repository,
        branch,
        commit,
        runtime,
        hash,
        &download_url,
    )?;
    let new_hash = hex::encode_upper(Sha256::digest(&bytes));
    let old = if prior.is_some() {
        Some(state.prior_stage_info_sha256.clone())
    } else {
        None
    };
    if !adopt_equal_json(
        root,
        &mut state,
        "source-info.json",
        &stage.join("source-info.json"),
        &info,
        old.as_deref(),
    )? {
        stage_product(
            root,
            &mut state,
            "source-info.json",
            &stage.join("source-info.json"),
            &mut bytes.as_slice(),
            bytes.len() as u64,
            &new_hash,
            old.as_deref(),
        )?;
    }
    pin.verify_named()?;
    native::reject_named_streams(&package_path)?;
    budget::ensure(root, 0)?;
    Ok(
        json!({"status":"prepared","candidateCommit":commit.to_ascii_lowercase(),"warnings":warnings}),
    )
}

pub fn verify_staged_products(root: &Path, candidate: &Provenance) -> Result<()> {
    let stage = stage_path(root);
    for (leaf, hash) in PRODUCTS.iter().zip([
        &candidate.cli_hash,
        &candidate.maintenance_hash,
        &candidate.hook_hash,
    ]) {
        verify_hash(&stage.join(leaf), hash)?;
    }
    for name in AUXILIARY_NAMES {
        verify_hash(
            &stage.join(auxiliary_path(name)),
            &candidate.auxiliary_hashes[&format!("bin\\{name}")],
        )?;
    }
    Ok(())
}
pub fn old_guard(path: &Path, hash: &str, hook: bool) -> Result<PinnedFile> {
    let pin = plain(
        path,
        if hook {
            GENERIC_READ
        } else {
            GENERIC_READ | GENERIC_WRITE
        },
        FILE_SHARE_READ | FILE_SHARE_DELETE,
    )?;
    super::rotation::verify_guard(&pin, hash)?;
    Ok(pin)
}
fn guard_name(
    bin: &Path,
    leaf: &str,
    old_hash: &str,
    new_hash: &str,
    saved: &str,
    state: &UpdateState,
) -> Result<String> {
    if !saved.is_empty() {
        verify_hash(&bin.join(saved), old_hash)?;
        verify_hash(&bin.join(leaf), new_hash)?;
        return Ok(saved.into());
    }
    if state.phase == "idle" {
        return Ok(leaf.into());
    }
    let actual = hash_file(&bin.join(leaf))?;
    if actual.eq_ignore_ascii_case(old_hash)
        && !(state.rotation_name == leaf
            && matches!(
                state.rotation_status.as_str(),
                "candidate_named" | "switched"
            ))
    {
        return Ok(leaf.into());
    }
    let backup = if state.rotation_name == leaf && !state.rotation_backup_name.is_empty() {
        state.rotation_backup_name.clone()
    } else {
        format!("{}.previous.exe", leaf.strip_suffix(".exe").unwrap())
    };
    if actual.eq_ignore_ascii_case(new_hash) {
        match verify_hash(&bin.join(&backup), old_hash) {
            Ok(()) => return Ok(backup),
            Err(error) if absent(&error) => {}
            Err(error) => return Err(error),
        }
    }
    ensure!(
        actual.eq_ignore_ascii_case(old_hash),
        "Installed product does not match a recoverable rotation state"
    );
    Ok(leaf.into())
}
fn save_completed_rotation(root: &Path, state: &mut UpdateState) -> Result<()> {
    if state.rotation_status != "switched" {
        return Ok(());
    }
    match state.rotation_name.as_str() {
        "prunlet.exe" => state.rotation_cli_backup = state.rotation_backup_name.clone(),
        "prunlet-maintenance.exe" => {
            state.rotation_maintenance_backup = state.rotation_backup_name.clone()
        }
        "prunlet-hook.exe" => state.rotation_hook_backup = state.rotation_backup_name.clone(),
        _ => bail!("Unknown completed rotation product"),
    }
    state.rotation_name.clear();
    state.rotation_status.clear();
    state.rotation_prior_sha256.clear();
    state.rotation_candidate_sha256.clear();
    state.rotation_backup_name.clear();
    write_state(root, state)
}
fn switch_products(root: &Path) -> Result<UpdateState> {
    let stage = stage_path(root);
    verify_candidate_process(&stage)?;
    let _parents = path::pin_directories(&stage)?;
    let _mutex = InstallationMutexes::acquire(root)?;
    let mut state = read_state(root)?.context("Update preparation state is missing")?;
    ensure!(
        state.stage_cleanup == "pending" && matches!(state.phase.as_str(), "idle" | "switching"),
        "Update is not in product switching phase"
    );
    verify_stage_owner(&stage, root, &state.candidate_commit)?;
    let candidate = read_provenance(&stage.join("source-info.json"))?;
    ensure!(
        candidate
            .commit
            .eq_ignore_ascii_case(&state.candidate_commit),
        "Candidate provenance differs from prepared commit"
    );
    verify_staged_products(root, &candidate)?;
    let source = root.join("source-info.json");
    let previous = stage.join("previous-source-info.json");
    if state.phase == "idle" {
        verify_hash(&source, &state.prepared_installed_source_info_sha256)?;
    }
    let old = read_provenance(if state.phase == "idle" {
        &source
    } else {
        &previous
    })?;
    if state.phase == "switching" {
        ensure!(
            old.commit.eq_ignore_ascii_case(&state.old_commit)
                && candidate
                    .cli_hash
                    .eq_ignore_ascii_case(&state.candidate_cli_sha256)
                && candidate
                    .maintenance_hash
                    .eq_ignore_ascii_case(&state.candidate_maintenance_sha256),
            "Product provenance differs from active update state"
        );
        verify_hash(
            &stage.join("source-info.json"),
            &state.candidate_source_info_sha256,
        )?;
    }
    ensure!(
        !matches!(state.rotation_status.as_str(), "replacing" | "ambiguous"),
        "An uncertain product replacement was preserved; it will not be retried"
    );
    save_completed_rotation(root, &mut state)?;
    let bin = root.join("bin");
    let old_hashes = [&old.cli_hash, &old.maintenance_hash, &old.hook_hash];
    let new_hashes = [
        &candidate.cli_hash,
        &candidate.maintenance_hash,
        &candidate.hook_hash,
    ];
    let saved = [
        &state.rotation_cli_backup,
        &state.rotation_maintenance_backup,
        &state.rotation_hook_backup,
    ];
    let mut guards = Vec::new();
    for i in 0..3 {
        let name = guard_name(
            &bin,
            PRODUCTS[i],
            old_hashes[i],
            new_hashes[i],
            saved[i],
            &state,
        )?;
        guards.push(old_guard(&bin.join(name), old_hashes[i], i == 2)?);
    }
    let _guards = budget::with_guards(&guards.iter().collect::<Vec<_>>())?;
    if state.phase == "idle" {
        (|| -> Result<()> {
            for guard in &guards {native::reject_named_streams(&guard.final_path()?)?;}
            native::reject_named_streams(&source)?;
            for name in AUXILIARY_NAMES {native::reject_named_streams(&bin.join(name))?;}
            Ok(())
        })().map_err(|error| anyhow::Error::new(Deferred(format!("A current product has named streams or cannot be inspected; all products were retained. {error}"))))?;
        let pin = plain(&source, GENERIC_READ, FILE_SHARE_READ)?;
        let length = stream(&pin)?.metadata()?.len();
        ensure!(length <= 65536, "Product provenance exceeds supported size");
        let source_hash = hash_stream(&mut stream(&pin)?)?;
        let prior = if state.prior_stage_commit.is_empty() {
            None
        } else {
            Some(state.prior_previous_info_sha256.clone())
        };
        stage_product(
            root,
            &mut state,
            "previous-source-info.json",
            &previous,
            &mut stream(&pin)?,
            length,
            &source_hash,
            prior.as_deref(),
        )?;
        state.old_commit = old.commit.clone();
        state.candidate_commit = candidate.commit.clone();
        state.candidate_cli_sha256 = candidate.cli_hash.clone();
        state.candidate_maintenance_sha256 = candidate.maintenance_hash.clone();
        state.candidate_source_info_sha256 = hash_file(&stage.join("source-info.json"))?;
        state.cleanup_cli = "pending".into();
        state.cleanup_maintenance = "pending".into();
        state.cleanup_hook = "pending".into();
        state.integration_ready = false;
        state.migration_complete = false;
        state.migration_file_complete = None;
        state.phase = "switching".into();
        write_state(root, &state)?;
    }
    let priors = [
        state.prior_cli_sha256.clone(),
        state.prior_maintenance_sha256.clone(),
        state.prior_hook_sha256.clone(),
    ];
    for i in 0..3 {
        let saved = match i {
            0 => &state.rotation_cli_backup,
            1 => &state.rotation_maintenance_backup,
            _ => &state.rotation_hook_backup,
        };
        if !saved.is_empty() {
            ensure!(
                guards[i].final_path()? == bin.join(saved),
                "Saved old guard has unexpected path"
            );
            verify_hash(&bin.join(PRODUCTS[i]), new_hashes[i])?;
            continue;
        }
        super::rotation::rotate(
            root,
            PRODUCTS[i],
            old_hashes[i],
            new_hashes[i],
            if priors[i].is_empty() {
                None
            } else {
                Some(&priors[i])
            },
            &guards[i],
            &mut state,
        )?;
        save_completed_rotation(root, &mut state)?;
    }
    Ok(state)
}
fn apply(config: &Config, root: &Path) -> Result<Value> {
    let mut state = read_state(root)?.context("Update preparation state is missing")?;
    if state.phase == "idle" && !state.candidate_cli_sha256.is_empty() {
        verify_candidate_process(&stage_path(root))?;
        return cleanup_previous(root, &state);
    }
    if matches!(state.phase.as_str(), "idle" | "switching") {
        match switch_products(root) {
            Ok(updated) => state = updated,
            Err(error) => {
                let sharing = error
                    .chain()
                    .filter_map(|e| e.downcast_ref::<std::io::Error>())
                    .any(|e| e.raw_os_error() == Some(32));
                if sharing
                    || error.downcast_ref::<Deferred>().is_some()
                    || error.to_string().contains("Another Prunlet installation")
                {
                    return Ok(
                        json!({"status":"deferred","phase":read_state(root)?.map(|s|s.phase).unwrap_or("idle".into()),"warnings":[error.to_string()]}),
                    );
                }
                return Err(error);
            }
        }
    }
    ensure!(
        matches!(state.phase.as_str(), "switching" | "migrating"),
        "Update is not in a resumable phase"
    );
    let candidate = read_provenance(&stage_path(root).join("source-info.json"))?;
    if !state.integration_ready || !super::integration::products_match(root, &candidate)? {
        return Ok(
            json!({"status":"integration_required","phase":state.phase,"registryReady":false}),
        );
    }
    let mut warnings = finalize(config, root)?;
    let state = read_state(root)?.context("Finalized state missing")?;
    let mut result = cleanup_previous(root, &state)?;
    warnings.extend(
        result["warnings"]
            .as_array()
            .context("Cleanup warnings are missing")?
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned),
    );
    result["warnings"] = json!(warnings);
    Ok(result)
}
fn finalize(config: &Config, root: &Path) -> Result<Vec<String>> {
    let stage = stage_path(root);
    verify_candidate_process(&stage)?;
    let _parents = path::pin_directories(&stage)?;
    let _mutex = InstallationMutexes::acquire(root)?;
    let mut state = read_state(root)?.context("Update state missing")?;
    ensure!(
        matches!(state.phase.as_str(), "switching" | "migrating")
            && state.stage_cleanup == "pending",
        "Update is not ready for recovery migration"
    );
    verify_stage_owner(&stage, root, &state.candidate_commit)?;
    let candidate_info = stage.join("source-info.json");
    let previous_info = stage.join("previous-source-info.json");
    let candidate = read_provenance(&candidate_info)?;
    let old = read_provenance(&previous_info)?;
    ensure!(
        candidate
            .commit
            .eq_ignore_ascii_case(&state.candidate_commit)
            && old.commit.eq_ignore_ascii_case(&state.old_commit)
            && candidate
                .cli_hash
                .eq_ignore_ascii_case(&state.candidate_cli_sha256)
            && candidate
                .maintenance_hash
                .eq_ignore_ascii_case(&state.candidate_maintenance_sha256),
        "Product provenance differs from active update state"
    );
    verify_hash(&candidate_info, &state.candidate_source_info_sha256)?;
    verify_staged_products(root, &candidate)?;
    ensure!(
        state.integration_ready
            && state.auxiliary_rotation_status.is_empty()
            && super::integration::products_match(root, &candidate)?,
        "Auxiliary products or their registration have not been confirmed"
    );
    let bin = root.join("bin");
    let mut guards = Vec::new();
    for (i, (saved, old_hash, new_hash)) in [
        (
            &state.rotation_cli_backup,
            &old.cli_hash,
            &candidate.cli_hash,
        ),
        (
            &state.rotation_maintenance_backup,
            &old.maintenance_hash,
            &candidate.maintenance_hash,
        ),
        (
            &state.rotation_hook_backup,
            &old.hook_hash,
            &candidate.hook_hash,
        ),
    ]
    .into_iter()
    .enumerate()
    {
        ensure!(
            !saved.is_empty(),
            "Product rotation has not completed for all products"
        );
        guards.push(old_guard(&bin.join(saved), old_hash, i == 2)?);
        verify_hash(&bin.join(PRODUCTS[i]), new_hash)?;
    }
    let _guards = budget::with_guards(&guards.iter().collect::<Vec<_>>())?;
    let installed_info = root.join("source-info.json");
    let previous_hash = hash_file(&previous_info)?;
    let installed_hash = if exists(&installed_info)? {
        Some(hash_file(&installed_info)?)
    } else {
        None
    };
    let mut warnings = Vec::new();
    if !state.migration_complete {
        ensure!(
            installed_hash
                .as_ref()
                .is_some_and(|h| h.eq_ignore_ascii_case(&previous_hash)),
            "Migration completion is not recorded and installed provenance is not old provenance"
        );
        if state.phase == "switching" {
            state.phase = "migrating".into();
            write_state(root, &state)?;
        }
        let result = crate::registry::execute(
            config,
            "migrate",
            &json!({"apply":true,"ifNeeded":true}),
            None,
        )?;
        ensure!(
            result["registryReady"] == true,
            "Registry recovery migration is not ready; candidate and state preserved"
        );
        warnings.extend(
            result["warnings"]
                .as_array()
                .context("Migration warnings are missing")?
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned),
        );
        state.migration_complete = true;
        state.migration_file_complete = Some(
            result["complete"]
                .as_bool()
                .context("Migration completion result missing")?,
        );
        write_state(root, &state)?;
    }
    ensure!(
        state.phase == "migrating",
        "Candidate provenance cannot commit outside migration"
    );
    ensure!(
        installed_hash
            .as_ref()
            .is_none_or(|h| h.eq_ignore_ascii_case(&previous_hash)
                || h.eq_ignore_ascii_case(&state.candidate_source_info_sha256)),
        "Installed provenance differs from both old and candidate provenance"
    );
    commit_provenance(
        root,
        &mut state,
        &candidate_info,
        &previous_hash,
        installed_hash.as_deref(),
    )?;
    state.phase = "idle".into();
    write_state(root, &state)?;
    Ok(warnings)
}
fn commit_provenance(
    root: &Path,
    state: &mut UpdateState,
    source: &Path,
    old_hash: &str,
    installed_hash: Option<&str>,
) -> Result<()> {
    let temporary = root.join("source-info.candidate.json");
    let backup = stage_path(root).join("previous-source-info-original.json");
    let mut backup_hash = if exists(&backup)? {
        Some(hash_file(&backup)?)
    } else {
        None
    };
    if installed_hash.is_some_and(|h| h.eq_ignore_ascii_case(old_hash))
        && backup_hash.as_ref().is_some_and(|h| {
            !state.prior_stage_commit.is_empty()
                && (h.eq_ignore_ascii_case(&state.prior_previous_info_sha256)
                    || h.eq_ignore_ascii_case(&state.candidate_source_info_sha256))
        })
    {
        let pin = plain(source, GENERIC_READ, FILE_SHARE_READ)?;
        let length = stream(&pin)?.metadata()?.len();
        let new_hash = state.candidate_source_info_sha256.clone();
        let prior = state.prior_previous_info_sha256.clone();
        stage_product(
            root,
            state,
            "previous-source-info-original.json",
            &backup,
            &mut stream(&pin)?,
            length,
            &new_hash,
            Some(&prior),
        )?;
        native::reject_named_streams(&backup)?;
        rename_no_replace(&backup, &temporary)?;
        backup_hash = None;
    }
    ensure!(
        backup_hash
            .as_ref()
            .is_none_or(|h| h.eq_ignore_ascii_case(old_hash)),
        "Original provenance backup differs from old provenance and was preserved"
    );
    if installed_hash.is_some_and(|h| h.eq_ignore_ascii_case(&state.candidate_source_info_sha256)) {
        ensure!(
            backup_hash.is_some(),
            "Candidate provenance lacks its original backup"
        );
        return Ok(());
    }
    ensure!(
        installed_hash.is_some() || backup_hash.is_some(),
        "Installed provenance and its original backup are both missing; all files preserved"
    );
    ensure!(
        installed_hash.is_none() || backup_hash.is_none(),
        "An unexpected original provenance backup was preserved"
    );
    if exists(&temporary)? {
        verify_hash(&temporary, &state.candidate_source_info_sha256)?;
    } else {
        let source = plain(source, GENERIC_READ, FILE_SHARE_READ)?;
        let mut input = stream(&source)?;
        let bytes = input.metadata()?.len();
        budget::ensure(root, bytes)?;
        let (pin, mut output) = create_plain(&temporary)?;
        copy_verified(
            &mut input,
            &mut output,
            bytes,
            &state.candidate_source_info_sha256,
        )?;
        pin.verify_named()?;
    }
    if installed_hash.is_none() {
        rename_no_replace(&temporary, &root.join("source-info.json"))?;
    } else {
        replace(&temporary, &root.join("source-info.json"), Some(&backup))?;
    }
    verify_hash(
        &root.join("source-info.json"),
        &state.candidate_source_info_sha256,
    )?;
    budget::ensure(root, 0)
}
fn cleanup_previous(root: &Path, state: &UpdateState) -> Result<Value> {
    let stage = stage_path(root);
    verify_candidate_process(&stage)?;
    let _parents = path::pin_directories(&stage)?;
    let _mutex = InstallationMutexes::acquire(root)?;
    ensure!(
        state.phase == "idle" && state.stage_cleanup == "pending",
        "Previous-product cleanup not ready"
    );
    verify_stage_owner(&stage, root, &state.candidate_commit)?;
    let candidate = read_provenance(&root.join("source-info.json"))?;
    let old = read_provenance(&stage.join("previous-source-info.json"))?;
    verify_hash(
        &root.join("source-info.json"),
        &state.candidate_source_info_sha256,
    )?;
    ensure!(
        candidate
            .commit
            .eq_ignore_ascii_case(&state.candidate_commit)
            && old.commit.eq_ignore_ascii_case(&state.old_commit),
        "Cleanup provenance differs from state"
    );
    let mut warnings = Vec::new();
    for (saved, expected, product) in [
        (&state.rotation_cli_backup, "prunlet.previous.exe", "CLI"),
        (
            &state.rotation_maintenance_backup,
            "prunlet-maintenance.previous.exe",
            "maintenance",
        ),
        (
            &state.rotation_hook_backup,
            "prunlet-hook.previous.exe",
            "hook",
        ),
    ] {
        if saved != expected {
            warnings.push(format!("An unusual {product} backup was retained: {saved}"));
        }
    }
    for (leaf, status) in PRODUCTS.iter().zip([
        &state.cleanup_cli,
        &state.cleanup_maintenance,
        &state.cleanup_hook,
    ]) {
        if status == "attempting" {
            warnings.push(format!(
                "An earlier cleanup outcome is uncertain and will not be retried: {leaf}"
            ));
        } else if status != "done" {
            warnings.push(format!("Previous product was retained until its complete contents can be proven owned: {leaf}"));
        }
    }
    Ok(
        json!({"status":if [&state.cleanup_cli,&state.cleanup_maintenance,&state.cleanup_hook].contains(&&"attempting".to_string()){"ambiguous"}else if [&state.cleanup_cli,&state.cleanup_maintenance,&state.cleanup_hook].iter().any(|s|s.as_str()=="pending"){"cleanup_pending"}else{"updated"},"phase":"idle","registryReady":true,"fileComplete":state.migration_file_complete,"warnings":warnings}),
    )
}
fn cleanup(root: &Path) -> Result<Value> {
    ensure!(
        path::resolve(&std::env::current_exe()?, false, false)?
            == root.join("bin").join("prunlet.exe"),
        "Stage cleanup is available only from installed Prunlet CLI"
    );
    let _parents = path::pin_directories(root)?;
    let _mutex = InstallationMutexes::acquire(root)?;
    let mut state = read_state(root)?.context("Stage cleanup has no owned state")?;
    ensure!(
        state.phase == "idle",
        "Stage cleanup blocked while update active"
    );
    if state.stage_cleanup == "done" {
        return Ok(json!({"status":"already_cleaned"}));
    }
    ensure!(
        state.stage_cleanup == "pending",
        "Stage cleanup outcome is uncertain; it will not be retried"
    );
    ensure!(
        state.candidate_cli_sha256.is_empty()
            || [
                &state.cleanup_cli,
                &state.cleanup_maintenance,
                &state.cleanup_hook
            ]
            .iter()
            .all(|s| s.as_str() == "done"),
        "Stage cleanup blocked while previous products require attention"
    );
    let stage = stage_path(root);
    if !exists(&stage)? {
        state.stage_cleanup = "done".into();
        write_state(root, &state)?;
        return Ok(json!({"status":"already_cleaned"}));
    }
    verify_stage_owner(&stage, root, &state.candidate_commit)?;
    Ok(
        json!({"status":"retained","error":"The update stage was preserved because its complete contents cannot be proven owned."}),
    )
}

#[cfg(test)]
mod compatibility_tests {
    use super::*;
    #[test]
    fn published_json_matches_csharp_declaration_order_and_default_encoder() {
        // Windows上のSystem.Text.Json既存producerで取得したbytesを固定する。
        let value = json!({"other":1,"text":"\"'+`<>&/\u{7f}é😀\u{8}\t\n\u{c}\r\u{1}\\"});
        let encoded = protocol_json(&value, &["text", "other"]).unwrap();
        assert_eq!(
            String::from_utf8(encoded).unwrap(),
            r#"{"text":"\u0022\u0027\u002B\u0060\u003C\u003E\u0026/\u007F\u00E9\uD83D\uDE00\b\t\n\f\r\u0001\\","other":1}"#
        );
    }
}
