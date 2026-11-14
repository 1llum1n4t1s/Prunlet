use super::{
    budget,
    package::{is_hex, valid_branch},
    state::{AUXILIARY_NAMES, STATE_NAME, StageCacheBaseline, UpdateState},
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
/// 配置先直下の更新slot領域名と、stage内の所有者記録名。値は既存の保存形式そのもの。
pub const SLOTS_NAME: &str = ".prunlet-update-slots";
pub const STAGE_OWNER_NAME: &str = ".prunlet-stage-owner.json";
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
    // 一時ファイルは非公開ACLで作り、作成時の実体（File ID）を控えておく。
    let created = {
        let handle = native::security::create_private_file(&temporary)?;
        native::write_handle(handle.raw(), &bytes)?;
        native::identity(handle.raw())?
    };
    let published = (|| -> Result<()> {
        if read_state(root)?.is_none() {
            return rename_no_replace(&temporary, &target);
        }
        // stateは起動のたびに複数のCLI・MCP（gate）が短時間読む。読取り中は置換が共有違反(32)や
        // 置換不可(1175)で失敗するが、どちらも何も変えない失敗なので、短い間隔で数回だけ再試行する。
        let mut attempt = 0;
        loop {
            match replace(&temporary, &target, None) {
                Err(error) if attempt < STATE_REPLACE_RETRIES && retryable_replace(&error) => {
                    attempt += 1;
                    std::thread::sleep(STATE_REPLACE_INTERVAL);
                }
                other => return other,
            }
        }
    })();
    if let Err(error) = published {
        // 何も変わっていないと確定できる失敗（共有違反・置換不可）だけ、残した一時ファイルを
        // 回収する。1176・1177など結果が不明な失敗では、新しいstateの唯一の写しなので保持する。
        if retryable_replace(&error) {
            discard_pending(&temporary, &created, &bytes);
        }
        return Err(error);
    }
    Ok(())
}
const STATE_REPLACE_RETRIES: u32 = 8;
const STATE_REPLACE_INTERVAL: std::time::Duration = std::time::Duration::from_millis(50);
/// ReplaceFileWが元のファイルも置換元も変えずに失敗した場合（ERROR_SHARING_VIOLATION=32、
/// ERROR_UNABLE_TO_REMOVE_REPLACED=1175）。
fn retryable_replace(error: &anyhow::Error) -> bool {
    error
        .chain()
        .filter_map(|e| e.downcast_ref::<std::io::Error>())
        .any(|e| matches!(e.raw_os_error(), Some(32 | 1175)))
}
/// 自分が作った一時ファイルだけを削除する。開き直した実体が、作成時のFile ID・単一link・
/// 代替ストリームなし・同じ内容であり、同じhandleのまま削除を設定できる場合に限る。
/// 照合できない・削除できない場合は何もせず残す（残骸はlauncherが警告として報告する）。
fn discard_pending(path: &Path, created: &native::FileIdentity, bytes: &[u8]) {
    let _ = (|| -> Result<()> {
        let pin = plain(path, GENERIC_READ | DELETE, 7)?;
        ensure!(
            pin.identity()?.same_object(created),
            "The pending state file is not the one that was created."
        );
        native::reject_named_streams(path)?;
        let mut file = stream(&pin)?;
        let mut actual = Vec::new();
        file.read_to_end(&mut actual)?;
        ensure!(actual == bytes, "The pending state file contents differ.");
        pin.verify_named()?;
        native::security::delete_fixed(pin.raw(), false)
    })();
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
/// .NETの`String.ToLowerInvariant()`と同じ写像。1文字を1文字へ置き換えるだけで、複数文字になる
/// 展開（U+0130 İ→i+結合点）と、語末のΣをςにする文脈依存の規則（Rustの`str::to_lowercase`）は使わない。
/// 出荷済みのlauncher・installerが同じ鍵を作るための互換仕様で、全コードポイントの一致を
/// `installation_key_lowering_matches_dotnet_for_every_code_point`（PowerShellの出力との総当たり）で確認する。
///
/// RustのUnicodeデータは.NET 11（ICU）より新しく、後から追加された大文字（Garay・Tolong Siki等）は
/// .NETが変えないため、同じ文字を変えないよう`dotnet_keeps`で除く。使用中の.NETのUnicode版がさらに
/// 新しくなると、これらの文字だけ鍵が食い違い得る（該当文字を含む導入先は事実上ない）。
pub fn invariant_lower(text: &str) -> String {
    text.chars()
        .map(|c| {
            if dotnet_keeps(c as u32) {
                return c;
            }
            let mut lower = c.to_lowercase();
            match (lower.next(), lower.next()) {
                (Some(single), None) => single,
                _ => c,
            }
        })
        .collect()
}
/// Rustは小文字を持つが、.NET 11のToLowerInvariantは変えないコードポイント（Unicode 16・17で
/// 追加された大文字）。総当たり照合で得た一覧そのもの。
fn dotnet_keeps(cp: u32) -> bool {
    matches!(
        cp,
        0x1C89
            | 0xA7CB
            | 0xA7CC
            | 0xA7CE
            | 0xA7D2
            | 0xA7D4
            | 0xA7DA
            | 0xA7DC
            | 0xA7DD
            | 0xA7E2
            | 0xAB6C
            | 0xAB6D
            | 0x10D50..=0x10D65
            | 0x16EA0..=0x16EB8
            | 0x1DF40
            | 0x1DF48
            | 0x1DF4A
            | 0x1DF4D
            | 0x1DF51
            | 0x1DF68
            | 0x1DF6A
            | 0x1DF6C
            | 0x1DF6E
            | 0x1DF72
            | 0x1DF74
            | 0x1DF76
            | 0x1DF78
            | 0x1DF7A
            | 0x1DF7C
            | 0x1DF7E
    )
}
/// 導入mutexの鍵。PowerShell側（launcher・installer）の`ToLowerInvariant()`+UTF-8+SHA-256と一致させる。
pub fn installation_key(root: &Path) -> String {
    hex::encode_upper(Sha256::digest(
        invariant_lower(&root.to_string_lossy()).as_bytes(),
    ))
}
impl InstallationMutexes {
    pub fn acquire(root: &Path) -> Result<Self> {
        let key = installation_key(root);
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
            // 他の導入・更新が保持中の場合は、呼出し側が文言に頼らず延期と判定できる型で返す。
            if status != WAIT_OBJECT_0 && status != WAIT_ABANDONED {
                return Err(anyhow::Error::new(Deferred(
                    "Another Prunlet installation or update is in progress.".into(),
                )));
            }
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
    parse_provenance(&native::read_plain_file(path, 65536, false)?)
}
/// 来歴JSONのbytesを解釈する。hash照合とparseを同じbytesで行う呼出し側のために分けている。
pub fn parse_provenance(bytes: &[u8]) -> Result<Provenance> {
    let value = crate::json::parse_unique(bytes)?;
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
        &stage.join(STAGE_OWNER_NAME),
        65536,
        false,
    )?)?;
    value.as_object().context("Stage owner must be an object")?;
    ensure!(
        owner_value_matches(&value, root, commit),
        "Stage ownership does not match the pending update state."
    );
    Ok(())
}
/// 所有者記録の内容が、この導入先・この候補commitのものであること。
fn owner_value_matches(value: &Value, root: &Path, commit: &str) -> bool {
    value.as_object().is_some_and(|map| map.len() == 5)
        && value["product"] == "Prunlet"
        && value["schema"] == 1
        && value["epoch"] == 1
        && value["installRoot"]
            .as_str()
            .is_some_and(|x| x.eq_ignore_ascii_case(&root.to_string_lossy()))
        && value["candidateCommit"]
            .as_str()
            .is_some_and(|x| x.eq_ignore_ascii_case(commit))
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
                matches!(argv.len(), 5 | 6),
                "Published download requires repository, commit, asset ID, SHA-256, byte length and an optional release tag."
            );
            super::download::receive_release(
                &root,
                argv[0],
                argv[1],
                number(argv[2])?,
                argv[3],
                number(argv[4])?,
                argv.get(5).copied(),
            )?;
            Ok(json!({"status":"downloaded"}))
        }
        "__prepare-published-package" => {
            ensure!(
                argv.len() == 7,
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
    let old = state
        .cache_baseline
        .as_ref()
        .map(|c| c.owner_sha256.clone())
        .unwrap_or_else(|| state.prior_owner_sha256.clone());
    let owner = stage_path(root).join(STAGE_OWNER_NAME);
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
        &stage_path(root).join(STAGE_OWNER_NAME),
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
    let directory = root.join(SLOTS_NAME);
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
// 未適用stageを、次の候補が上書きしてよい基準へ作り直す。
//
// stageは削除しない固定のcacheなので、上書きしてよい基準（来歴）はstage自身の記録から導く。
// 適用済みstageは「導入済み==stageの候補」、未適用stageは「新品の状態」だけを受け付けると、
// 取得失敗・中断・適用済み来歴付きの候補・基準付きの候補が未適用のまま次のreleaseが来た時点で、
// 旧候補が二度と進まなくなる。そこで、書込み対象の固定14パス（owner・source-info.json・
// 3製品・9補助）の現物hashが、次のいずれかであることだけを条件に、現物のhashを新しい基準にする。
// - それまでの基準（cache_baseline、または適用済み来歴のprior_*。新品なら「存在しない」）
// - 置き換わる候補（検証済みのZIPの製品表と、来歴の内容照合で認める）
// - 進行中のstage_write記録のold/new
// 固定名以外の未知の項目は変更せず、容量にだけ数えて保持する（更新は止めない）。
// 記録と異なる内容・代替ストリーム・link・所有印の不一致は、従来どおり変更せず拒否する。
struct Replacement {
    baseline: StageCacheBaseline,
    /// previous-source-info.jsonの現物が、記録済みの旧hashまたは準備時の導入済みhashのときだけ入る。
    prior_previous_info: Option<String>,
}

/// 書込み対象の固定14パス。keyはstage_write_nameと同じ表記（owner・source-info.json・製品名・
/// 補助製品のstage相対パス）。
fn fixed_stage_paths(stage: &Path) -> Vec<(String, PathBuf)> {
    let mut paths = vec![
        ("owner".to_string(), stage.join(STAGE_OWNER_NAME)),
        (
            "source-info.json".to_string(),
            stage.join("source-info.json"),
        ),
    ];
    for leaf in PRODUCTS {
        paths.push((leaf.to_string(), stage.join(leaf)));
    }
    for name in AUXILIARY_NAMES {
        let relative = auxiliary_path(name);
        paths.push((
            relative.to_string_lossy().into_owned(),
            stage.join(relative),
        ));
    }
    paths
}

/// 固定名の1パスを、単一linkで代替ストリームのない通常ファイルとして1回だけ読む。
/// owner・source-infoは内容の照合にも使うため、keepならbytesも返す。存在しなければNone。
/// 基準にするhashは、照合に使ったこの読取りから取る（照合後に読み直さない）。
fn read_fixed(path: &Path, keep: bool) -> Result<Option<(String, Vec<u8>)>> {
    if !exists(path)? {
        return Ok(None);
    }
    let _parents = path::pin_directories(path.parent().context("Missing stage parent")?)?;
    native::reject_named_streams(path)?;
    let pin = plain(path, GENERIC_READ, FILE_SHARE_READ)?;
    let mut file = stream(&pin)?;
    let (hash, bytes) = if keep {
        ensure!(
            file.metadata()?.len() <= 65536,
            "Stage metadata exceeds its supported size."
        );
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        (hex::encode_upper(Sha256::digest(&bytes)), bytes)
    } else {
        (hash_stream(&mut file)?, Vec::new())
    };
    pin.verify_named()?;
    native::reject_named_streams(path)?;
    Ok(Some((hash, bytes)))
}

fn allow(map: &mut BTreeMap<String, Vec<Option<String>>>, key: &str, hash: &str) {
    map.entry(key.to_string())
        .or_default()
        .push(if hash.is_empty() {
            None
        } else {
            Some(hash.to_ascii_uppercase())
        });
}

/// 置き換わる候補の配布ZIP。stateが準備済み（ready）と記録し、認証済みのhash・長さと現物が
/// 一致する場合だけ得られる。repository・runtimeは導入済みの来歴から取る。
struct UnappliedPackage {
    repository: String,
    runtime: String,
    products: Vec<super::package::Product>,
}
fn open_unapplied_package(
    root: &Path,
    stage: &Path,
    state: &UpdateState,
) -> Option<UnappliedPackage> {
    if state.package_status != "ready"
        || !is_hex(&state.package_previous_sha256, 64)
        || state.package_previous_bytes <= 0
    {
        return None;
    }
    let installed = native::read_plain_file(&root.join("source-info.json"), 65536, false).ok()?;
    let installed = crate::json::parse_unique(&installed).ok()?;
    let repository = installed["repository"].as_str()?.to_owned();
    let branch = installed["defaultBranch"].as_str()?.to_owned();
    let runtime = installed["runtime"].as_str()?.to_owned();
    let path = stage.join(&state.package_name);
    let pin = plain(&path, GENERIC_READ, FILE_SHARE_READ).ok()?;
    native::reject_named_streams(&path).ok()?;
    let package = super::package::VerifiedPackage::open(
        stream(&pin).ok()?,
        &repository,
        &branch,
        &state.candidate_commit,
        &runtime,
        &state.package_previous_sha256,
        state.package_previous_bytes as u64,
    )
    .ok()?;
    pin.verify_named().ok()?;
    Some(UnappliedPackage {
        repository,
        runtime,
        products: package.products,
    })
}

/// stage/source-info.jsonが、置き換わる候補（検証済みのZIP）の来歴であることを内容で照合する。
fn unapplied_info_matches(
    bytes: &[u8],
    state: &UpdateState,
    package: &UnappliedPackage,
) -> Result<()> {
    let info = crate::json::parse_unique(bytes)?;
    let object = info
        .as_object()
        .context("Staged provenance must be an object")?;
    ensure!(
        object.len() == SOURCE_INFO_FIELDS.len()
            && SOURCE_INFO_FIELDS.iter().all(|n| object.contains_key(*n))
            && SOURCE_INFO_FIELDS
                .iter()
                .all(|n| if *n == "auxiliarySha256" {
                    object[*n].is_object()
                } else {
                    object[*n].is_string()
                }),
        "Unapplied stage provenance has unknown or malformed fields."
    );
    let repository = info["repository"].as_str().context("Missing repository")?;
    let branch = info["defaultBranch"].as_str().context("Missing branch")?;
    let runtime = info["runtime"].as_str().context("Missing runtime")?;
    let url = info["downloadUrl"].as_str().context("Missing URL")?;
    let prefix = format!("https://api.github.com/repos/{repository}/releases/assets/");
    let asset = url.strip_prefix(&prefix).and_then(|s| {
        if !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()) {
            s.parse::<i64>().ok()
        } else {
            None
        }
    });
    ensure!(
        regex::Regex::new(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z")?.is_match(repository)
            && valid_branch(branch)
            && asset.is_some_and(|n| n > 0)
            && matches!(runtime, "win-x64" | "win-arm64")
            && repository.eq_ignore_ascii_case(&package.repository)
            && runtime == package.runtime,
        "Unapplied stage provenance has unsupported release metadata."
    );
    let candidate = parse_provenance(bytes)?;
    ensure!(
        candidate
            .commit
            .eq_ignore_ascii_case(&state.candidate_commit)
            && info["archiveSha256"]
                .as_str()
                .is_some_and(|s| s.eq_ignore_ascii_case(&state.package_previous_sha256)),
        "The staged provenance differs from its package state."
    );
    for product in &package.products {
        let leaf = product
            .name
            .strip_prefix("bin/")
            .context("Invalid package product")?;
        let expected = match leaf {
            "prunlet.exe" => &candidate.cli_hash,
            "prunlet-maintenance.exe" => &candidate.maintenance_hash,
            "prunlet-hook.exe" => &candidate.hook_hash,
            _ => candidate
                .auxiliary_hashes
                .get(&format!("bin\\{leaf}"))
                .context("Missing auxiliary identity")?,
        };
        ensure!(
            product.sha256.eq_ignore_ascii_case(expected),
            "Staged product differs from package manifest."
        );
    }
    Ok(())
}

fn derive_replacement(root: &Path, state: &UpdateState) -> Result<Replacement> {
    ensure!(
        [
            &state.cleanup_cli,
            &state.cleanup_maintenance,
            &state.cleanup_hook
        ]
        .iter()
        .all(|s| s.as_str() == "pending")
            && [
                &state.rotation_name,
                &state.rotation_status,
                &state.rotation_prior_sha256,
                &state.rotation_candidate_sha256,
                &state.rotation_backup_name,
                &state.auxiliary_rotation_name,
                &state.auxiliary_rotation_status,
                &state.auxiliary_rotation_old_sha256,
                &state.auxiliary_rotation_new_sha256,
                &state.candidate_maintenance_sha256,
                &state.candidate_source_info_sha256,
                &state.old_commit,
                &state.rotation_cli_backup,
                &state.rotation_maintenance_backup,
                &state.rotation_hook_backup
            ]
            .iter()
            .all(|s| s.is_empty())
            && !state.integration_ready
            && state.auxiliary_rotation_status.is_empty()
            // 進行中の書込み記録は、固定14パスかprevious-source-info.json（切替の準備）だけを許す。
            && (state.stage_write_name.is_empty()
                || state.stage_write_name == "previous-source-info.json"
                || fixed_stage_paths(&stage_path(root))
                    .iter()
                    .any(|(key, _)| *key == state.stage_write_name))
            // prior_*は適用済み来歴を持つ場合に限って意味があり、孤立した値は異常として止める。
            && (!state.prior_stage_commit.is_empty()
                || ([
                    &state.prior_stage_info_sha256,
                    &state.prior_previous_info_sha256,
                    &state.prior_owner_sha256,
                    &state.prior_cli_sha256,
                    &state.prior_maintenance_sha256,
                    &state.prior_hook_sha256
                ]
                .iter()
                .all(|s| s.is_empty())
                    && state.prior_auxiliary_sha256.is_none()
                    && state.auxiliary_backup_sha256.is_empty())),
        "The previous unapplied stage has incomplete or active provenance."
    );
    let stage = stage_path(root);
    let _parents = path::pin_directories(&stage)?;
    native::reject_named_streams(&stage)?;
    // 補助製品の親ディレクトリ（scripts・integration）もADSを持たないこと。
    for directory in ["scripts", "integration"] {
        let directory = stage.join(directory);
        if exists(&directory)? {
            native::reject_named_streams(&directory)?;
        }
    }
    let paths = fixed_stage_paths(&stage);
    // 許容するhash（Noneは存在しないこと）を、パスごとに集める。
    let mut allowed = BTreeMap::<String, Vec<Option<String>>>::new();
    if let Some(cache) = &state.cache_baseline {
        allow(&mut allowed, "owner", &cache.owner_sha256);
        allow(&mut allowed, "source-info.json", &cache.source_info_sha256);
        for (leaf, hash) in PRODUCTS.iter().zip([
            &cache.cli_sha256,
            &cache.maintenance_sha256,
            &cache.hook_sha256,
        ]) {
            allow(&mut allowed, leaf, hash);
        }
        for name in AUXILIARY_NAMES {
            allow(
                &mut allowed,
                &auxiliary_path(name).to_string_lossy(),
                cache
                    .auxiliary_sha256
                    .get(&format!("bin\\{name}"))
                    .map_or("", String::as_str),
            );
        }
    } else if !state.prior_stage_commit.is_empty() {
        allow(&mut allowed, "owner", &state.prior_owner_sha256);
        allow(
            &mut allowed,
            "source-info.json",
            &state.prior_stage_info_sha256,
        );
        // 製品の旧hashは、記録済みの旧来歴を内容で確認できた場合だけ許す。
        if let Some(prior) = prior_stage_provenance(root, &stage, state)? {
            for (leaf, hash) in
                PRODUCTS
                    .iter()
                    .zip([&prior.cli_hash, &prior.maintenance_hash, &prior.hook_hash])
            {
                allow(&mut allowed, leaf, hash);
            }
            for name in AUXILIARY_NAMES {
                allow(
                    &mut allowed,
                    &auxiliary_path(name).to_string_lossy(),
                    prior
                        .auxiliary_hashes
                        .get(&format!("bin\\{name}"))
                        .map_or("", String::as_str),
                );
            }
        }
    } else {
        for (key, _) in &paths {
            allow(&mut allowed, key, "");
        }
    }
    let unapplied = open_unapplied_package(root, &stage, state);
    if let Some(package) = &unapplied {
        for product in &package.products {
            let leaf = product.name.strip_prefix("bin/").unwrap_or_default();
            let key = if PRODUCTS.contains(&leaf) {
                leaf.to_string()
            } else {
                auxiliary_path(leaf).to_string_lossy().into_owned()
            };
            allow(&mut allowed, &key, &product.sha256);
        }
    }
    if !state.stage_write_name.is_empty() {
        allow(
            &mut allowed,
            &state.stage_write_name,
            &state.stage_write_old_sha256,
        );
        allow(
            &mut allowed,
            &state.stage_write_name,
            &state.stage_write_new_sha256,
        );
    }
    let mut baseline = StageCacheBaseline {
        commit: state.candidate_commit.clone(),
        ..Default::default()
    };
    for (key, path) in &paths {
        let keep = key == "owner" || key == "source-info.json";
        let current = read_fixed(path, keep)?;
        let hash = current.as_ref().map(|(hash, _)| hash.clone());
        if !allowed.get(key).is_some_and(|list| list.contains(&hash)) {
            match key.as_str() {
                "owner" => ensure!(
                    current.as_ref().is_some_and(|(_, bytes)| {
                        crate::json::parse_unique(bytes).is_ok_and(|value| {
                            owner_value_matches(&value, root, &state.candidate_commit)
                        })
                    }),
                    "Stage ownership does not match the pending update state."
                ),
                "source-info.json" => match (&current, &unapplied) {
                    (Some((_, bytes)), Some(package)) => {
                        unapplied_info_matches(bytes, state, package)?
                    }
                    _ => bail!(
                        "A changed staged cache file was preserved: {}",
                        path.display()
                    ),
                },
                _ => bail!(
                    "A changed staged cache file was preserved: {}",
                    path.display()
                ),
            }
        }
        let value = hash.unwrap_or_default();
        match key.as_str() {
            "owner" => baseline.owner_sha256 = value,
            "source-info.json" => baseline.source_info_sha256 = value,
            "prunlet.exe" => baseline.cli_sha256 = value,
            "prunlet-maintenance.exe" => baseline.maintenance_sha256 = value,
            "prunlet-hook.exe" => baseline.hook_sha256 = value,
            relative => {
                let name = AUXILIARY_NAMES
                    .iter()
                    .find(|n| auxiliary_path(n).to_string_lossy() == relative)
                    .context("Unknown staged auxiliary product")?;
                baseline
                    .auxiliary_sha256
                    .insert(format!("bin\\{name}"), value);
            }
        }
    }
    // 適用済み来歴を持つstageで、切替が準備の途中で中断してprevious-source-info.jsonが先に書かれた
    // 場合だけ、その現物のhashを旧hashとして引き継ぐ。記録済みの旧hash・準備時の導入済みhashの
    // どちらでもない内容は記録せず、そのまま保持する。進行中の書込み記録（stage_write）が
    // このファイルを指す場合は、現物がold/newのどちらかのときだけ解消し、書込み途中の現物は拒否する。
    let previous_info = stage.join("previous-source-info.json");
    let mut prior_previous_info = None;
    if state.stage_write_name == "previous-source-info.json" {
        let current = read_fixed(&previous_info, false)?.map(|(hash, _)| hash);
        ensure!(
            current.as_ref().is_some_and(|hash| {
                hash.eq_ignore_ascii_case(&state.stage_write_old_sha256)
                    || hash.eq_ignore_ascii_case(&state.stage_write_new_sha256)
            }),
            "A changed staged cache file was preserved: {}",
            previous_info.display()
        );
        prior_previous_info = current;
    } else if !state.prior_stage_commit.is_empty()
        && let Ok(Some((hash, _))) = read_fixed(&previous_info, false)
        && (hash.eq_ignore_ascii_case(&state.prior_previous_info_sha256)
            || hash.eq_ignore_ascii_case(&state.prepared_installed_source_info_sha256))
    {
        prior_previous_info = Some(hash);
    }
    budget::ensure(root, 0)?;
    Ok(Replacement {
        baseline,
        prior_previous_info,
    })
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
            if !state.candidate_commit.eq_ignore_ascii_case(commit)
                && !state.migration_complete
                && state.candidate_cli_sha256.is_empty()
            {
                // 取得失敗・中断・適用済み来歴付き・基準付きのどの未適用候補からでも、次の候補向けに
                // 作り直す。条件はstage内の実物とstateが記録したhashだけで判定する（derive_replacement）。
                ensure!(
                    exists(&stage)? && !state.integration_ready,
                    "A previous unapplied update requires attention and was preserved."
                );
                let replacement = derive_replacement(root, &state)?;
                state = UpdateState {
                    candidate_commit: commit.to_ascii_uppercase(),
                    stage_cleanup: "pending".into(),
                    prepared_installed_source_info_sha256: installed_hash,
                    cache_baseline: Some(replacement.baseline),
                    slot_cli: state.slot_cli,
                    slot_maintenance: state.slot_maintenance,
                    slot_hook: state.slot_hook,
                    // ZIPの名前と状態は、書込み中でもそのまま引き継ぐ（同じ名前で再取得する）。
                    package_name: state.package_name,
                    package_status: state.package_status,
                    package_previous_sha256: state.package_previous_sha256,
                    package_previous_bytes: state.package_previous_bytes,
                    // 適用済みstage由来のprior_*は、切替までそのまま保持する。
                    prior_stage_commit: state.prior_stage_commit,
                    prior_stage_info_sha256: state.prior_stage_info_sha256,
                    prior_previous_info_sha256: replacement
                        .prior_previous_info
                        .unwrap_or(state.prior_previous_info_sha256),
                    prior_owner_sha256: state.prior_owner_sha256,
                    prior_cli_sha256: state.prior_cli_sha256,
                    prior_maintenance_sha256: state.prior_maintenance_sha256,
                    prior_hook_sha256: state.prior_hook_sha256,
                    prior_auxiliary_sha256: state.prior_auxiliary_sha256,
                    auxiliary_backup_sha256: state.auxiliary_backup_sha256,
                    // 進行中の書込み記録は、derive_replacementが現物のhashで解消した上で基準へ畳み込む。
                    ..Default::default()
                };
                // 旧実体の証明を先に記録し、owner更新の中断時も同じhashで再開する。
                write_state(root, &state)?;
                update_owner(root, &mut state)?;
                return Ok(json!({"status":"ready","candidateCommit":commit.to_ascii_uppercase()}));
            }
            if state.migration_complete && exists(&stage)? && !state.candidate_cli_sha256.is_empty()
            {
                // 比較先は導入済みのcommit。手動導入で導入済みがstageと別でも、要求releaseが
                // すでに導入済みの場合だけ止める。
                ensure!(
                    !installed.commit.eq_ignore_ascii_case(commit),
                    "Requested release is already installed"
                );
                verify_stage_owner(&stage, root, &state.candidate_commit)?;
                native::reject_named_streams(&stage.join(STAGE_OWNER_NAME))?;
                // stageの再利用基準は、導入済みのsource-info.jsonではなく、stage自身についてstateが
                // 記録した来歴（stage/source-info.jsonのhash・commit・12製品のhash）に置く。
                // 手動導入（Install-Prunlet.ps1）は導入済み来歴をstateとは無関係に書き換えるため、
                // 「導入済み==stageの候補」を前提にすると、以後の自動更新が永久に止まる。
                // 照合は外さず、起点だけを導入済み来歴からstate記録のhashへ移す。
                let stage_info_path = stage.join("source-info.json");
                let stage_info_bytes = native::read_plain_file(&stage_info_path, 65536, true)?;
                ensure!(
                    is_hex(&state.candidate_source_info_sha256, 64)
                        && hex::encode_upper(Sha256::digest(&stage_info_bytes))
                            .eq_ignore_ascii_case(&state.candidate_source_info_sha256),
                    "Product contents do not match the confirmed provenance: {}",
                    stage_info_path.display()
                );
                let staged = parse_provenance(&stage_info_bytes)?;
                ensure!(
                    staged.commit.eq_ignore_ascii_case(&state.candidate_commit),
                    "Retained stage provenance does not match its recorded commit"
                );
                verify_staged_products(root, &staged)?;
                if !installed_hash.eq_ignore_ascii_case(&state.candidate_source_info_sha256) {
                    warnings.push(
                        "Installed provenance differs from the retained stage; the stage was re-verified by its own recorded provenance.".into(),
                    );
                }
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
                let owner_hash = hash_file(&stage.join(STAGE_OWNER_NAME))?;
                let package_path = stage.join(&state.package_name);
                let package_identity = (|| -> Result<(String, i64)> {
                    // 配布ZIPのhashもstage自身の来歴（照合済みのbytes）から取る。
                    let v = crate::json::parse_unique(&stage_info_bytes)?;
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
                    // 通常経路（導入済み==stage）では導入済みcommitと同じ値になる。
                    prior_stage_commit: staged.commit.clone(),
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
            // 未切替（上のensureで候補・移行・統合が未着手、phaseはidle）の間に導入済み来歴が変わった
            // （手動導入）場合は拒否しない。この値の役割は「beginから切替までの間に導入済みが
            // 変わっていないか」の検査なので、導入mutexを保持したまま今回のbegin時点を基準に
            // 記録し直しても性質は保たれる。切替時は従来どおり再照合する。
            if !installed_hash.eq_ignore_ascii_case(&state.prepared_installed_source_info_sha256) {
                state.prepared_installed_source_info_sha256 = installed_hash.clone();
                write_state(root, &state)?;
                warnings.push(
                    "Installed provenance changed after preparation; the baseline was recorded again.".into(),
                );
            }
            if exists(&stage)? {
                if !state.prior_stage_commit.is_empty() || state.cache_baseline.is_some() {
                    update_owner(root, &mut state)?;
                }
                verify_stage_owner(&stage, root, commit)?;
                return Ok(
                    json!({"status":"existing","candidateCommit":commit.to_ascii_uppercase(),"warnings":warnings}),
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
    native::write_new_plain_file(&stage.join(STAGE_OWNER_NAME), &bytes)?;
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

/// 適用済みstageの旧来歴を、stateが記録した`prior_stage_info_sha256`と照合して取得する。
/// 先にstage/source-info.json、次に導入済みのsource-info.jsonを見て、1回読んだbytesのhashが
/// 記録と一致したものだけを同じbytesからparseする。手動導入で導入済みが別物でも、stage側が
/// 旧来歴のままなら通る。どちらも一致しない（stage側が今回の来歴へ書換済みで導入済みも別物）
/// 場合はNoneを返し、製品は新hashとの一致だけで通し、旧hash一致の上書きは行わない（安全側）。
fn prior_stage_provenance(
    root: &Path,
    stage: &Path,
    state: &UpdateState,
) -> Result<Option<Provenance>> {
    for path in [
        stage.join("source-info.json"),
        root.join("source-info.json"),
    ] {
        let bytes = match native::read_plain_file(&path, 65536, false) {
            Ok(bytes) => bytes,
            Err(error) if absent(&error) => continue,
            Err(error) => return Err(error),
        };
        if !hex::encode_upper(Sha256::digest(&bytes))
            .eq_ignore_ascii_case(&state.prior_stage_info_sha256)
        {
            continue;
        }
        let prior = parse_provenance(&bytes)?;
        ensure!(
            prior.commit.eq_ignore_ascii_case(&state.prior_stage_commit),
            "Provenance differs from prior stage"
        );
        return Ok(Some(prior));
    }
    Ok(None)
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
    let download_url = format!("https://api.github.com/repos/{repository}/releases/assets/{asset}");
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
    let prior = if let Some(cache) = &state.cache_baseline {
        Some(Provenance {
            commit: cache.commit.clone(),
            cli_hash: cache.cli_sha256.clone(),
            maintenance_hash: cache.maintenance_sha256.clone(),
            hook_hash: cache.hook_sha256.clone(),
            auxiliary_hashes: cache.auxiliary_sha256.clone(),
        })
    } else if state.prior_stage_commit.is_empty() {
        None
    } else {
        prior_stage_provenance(root, &stage, &state)?
    };
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
        let reusable = previous.clone().filter(|p| p.status == "ready");
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
            // 書込み中のslotも渡し、記録済みのgenerationのまま書き直す。
            previous.as_ref(),
            product.bytes,
        )?;
        if let Some(interrupted) = previous.as_ref().filter(|p| p.status == "writing") {
            warnings.push(if interrupted.generation == lease.generation {
                format!("An interrupted product slot was resumed: {leaf}")
            } else {
                format!("An interrupted product slot was retained: {leaf}")
            });
        }
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
        budget::ensure(
            root,
            stage_reserve(&stage.join(&relative), product.bytes, &product.sha256, old)?,
        )?;
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
    let old = if let Some(cache) = &state.cache_baseline {
        Some(cache.source_info_sha256.clone())
    } else if !state.prior_stage_commit.is_empty() {
        Some(state.prior_stage_info_sha256.clone())
    } else {
        None
    };
    budget::ensure(
        root,
        stage_reserve(
            &stage.join("source-info.json"),
            bytes.len() as u64,
            &new_hash,
            old.as_deref(),
        )?,
    )?;
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
        // 基準はprepareと未適用候補の置換だけが使う。切替へ進んだ以降は参照しないので、
        // switchingへ移る書込みで消し、旧版が読めない形式の期間を未適用の間だけに限る。
        state.cache_baseline = None;
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
                if sharing || error.downcast_ref::<Deferred>().is_some() {
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
#[cfg(test)]
mod installation_mutex_tests {
    use super::*;
    /// 別スレッドが保持している間の取得失敗は、延期として分類できるDeferred型で、
    /// warningsへ出る文言（`error.to_string()`）が従来と一致する。
    /// Win32 mutexは同一スレッドなら再入できるため、保持側を別スレッドにする。
    #[test]
    fn contended_acquire_is_deferred_with_existing_message() {
        let root = std::path::PathBuf::from(format!(
            r"D:\prunlet-installation-mutex-test-{}",
            std::process::id()
        ));
        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let holder_root = root.clone();
        let holder = std::thread::spawn(move || {
            let _held = InstallationMutexes::acquire(&holder_root).unwrap();
            held_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
        held_rx.recv().unwrap();
        let error = match InstallationMutexes::acquire(&root) {
            Err(error) => error,
            Ok(_) => panic!("a held installation mutex must not be acquired again"),
        };
        release_tx.send(()).unwrap();
        holder.join().unwrap();
        assert!(error.downcast_ref::<Deferred>().is_some());
        assert_eq!(
            error.to_string(),
            "Another Prunlet installation or update is in progress."
        );
        // 保持側の解放後は再び取得できる。
        InstallationMutexes::acquire(&root).unwrap();
    }
}

/// 手動導入（Install-Prunlet.ps1）後の`begin`・`prepare`が、導入済み来歴ではなくstage自身の
/// 記録した来歴で適用済みstageを再照合することを、実体のあるfixtureで確認する。
/// fixtureはTEMP配下の一意なディレクトリへ作り、テスト側では削除しない（作業終了時にPrunletで清掃する）。
#[cfg(test)]
mod manual_install_tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    pub(super) const OLD: &str = "1111111111111111111111111111111111111111";
    pub(super) const CANDIDATE: &str = "3333333333333333333333333333333333333333";
    pub(super) const NEXT: &str = "4444444444444444444444444444444444444444";
    pub(super) const MANUAL: &str = "ffffffffffffffffffffffffffffffffffffffff";

    pub(super) fn sha(bytes: &[u8]) -> String {
        hex::encode_upper(Sha256::digest(bytes))
    }
    pub(super) fn fixture_root(name: &str) -> PathBuf {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let root = std::env::temp_dir().join(format!(
            "prunlet-manual-install-{}-{}-{name}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(root.join("bin")).unwrap();
        root
    }
    /// 配布物と同じ10項目の来歴。hook製品はCLIと同じ実体のため同じhashにする。
    fn info(
        commit: &str,
        cli: &str,
        maintenance: &str,
        auxiliary: &BTreeMap<String, String>,
        archive: &str,
    ) -> Value {
        json!({
            "repository": "owner/repo", "defaultBranch": "main", "commitSha": commit,
            "downloadUrl": "https://example.invalid/asset", "archiveSha256": archive,
            "executableSha256": cli, "maintenanceExecutableSha256": maintenance,
            "hookExecutableSha256": cli, "auxiliarySha256": auxiliary, "runtime": "win-x64"
        })
    }
    pub(super) fn write(path: &Path, bytes: &[u8]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }
    fn auxiliary_hashes(tag: &str) -> (BTreeMap<String, String>, Vec<(String, Vec<u8>)>) {
        let mut map = BTreeMap::new();
        let mut files = Vec::new();
        for name in AUXILIARY_NAMES {
            let body = format!("{tag}-{name}").into_bytes();
            map.insert(format!("bin\\{name}"), sha(&body));
            files.push((name.to_string(), body));
        }
        (map, files)
    }
    pub(super) struct Applied {
        pub(super) root: PathBuf,
        pub(super) stage: PathBuf,
        pub(super) stage_info: Vec<u8>,
        pub(super) state: UpdateState,
    }
    /// 候補（CANDIDATE）を適用し終えてstageを保持した状態を作る。`manual`で導入済み来歴を選ぶ。
    pub(super) fn applied(name: &str, manual: bool) -> Applied {
        let root = fixture_root(name);
        let stage = stage_path(&root);
        std::fs::create_dir_all(&stage).unwrap();
        let (aux, aux_files) = auxiliary_hashes("candidate");
        for (leaf, body) in [
            ("prunlet.exe", b"candidate-cli".as_slice()),
            (
                "prunlet-maintenance.exe",
                b"candidate-maintenance".as_slice(),
            ),
            ("prunlet-hook.exe", b"candidate-cli".as_slice()),
        ] {
            write(&stage.join(leaf), body);
        }
        for (aux_name, body) in &aux_files {
            write(&stage.join(auxiliary_path(aux_name)), body);
        }
        let package = b"candidate-package";
        let package_name = format!("package-{}.zip", "ab".repeat(16));
        write(&stage.join(&package_name), package);
        let stage_info = serde_json::to_vec(&info(
            CANDIDATE,
            &sha(b"candidate-cli"),
            &sha(b"candidate-maintenance"),
            &aux,
            &sha(package),
        ))
        .unwrap();
        write(&stage.join("source-info.json"), &stage_info);
        // 適用前（OLD）の来歴と、置換した補助製品の退避。
        let (old_aux, _) = auxiliary_hashes("old");
        let previous_info = serde_json::to_vec(&info(
            OLD,
            &sha(b"old-cli"),
            &sha(b"old-maintenance"),
            &old_aux,
            &sha(b"old-package"),
        ))
        .unwrap();
        write(&stage.join("previous-source-info.json"), &previous_info);
        write(
            &stage.join("previous-source-info-original.json"),
            &previous_info,
        );
        let backup_body = b"old-PRUNLET.md".to_vec();
        write(
            &stage.join("previous-auxiliary").join("PRUNLET.md"),
            &backup_body,
        );
        write(
            &stage.join(STAGE_OWNER_NAME),
            &owner_bytes(&root, CANDIDATE).unwrap(),
        );
        // 導入済み来歴。通常は候補と同じbytes、手動導入はインストーラーの整形出力（CRLF・別commit・別hash）。
        let installed_bytes = if manual {
            let mut text = serde_json::to_string_pretty(&info(
                MANUAL,
                &sha(b"manual-cli"),
                &sha(b"manual-maintenance"),
                &aux,
                &sha(b"manual-package"),
            ))
            .unwrap()
            .replace('\n', "\r\n");
            text.push_str("\r\n");
            text.into_bytes()
        } else {
            stage_info.clone()
        };
        write(&root.join("source-info.json"), &installed_bytes);
        let state = UpdateState {
            old_commit: OLD.into(),
            candidate_commit: CANDIDATE.into(),
            candidate_cli_sha256: sha(b"candidate-cli"),
            candidate_maintenance_sha256: sha(b"candidate-maintenance"),
            candidate_source_info_sha256: sha(&stage_info),
            prepared_installed_source_info_sha256: sha(&installed_bytes),
            stage_cleanup: "pending".into(),
            integration_ready: true,
            migration_complete: true,
            migration_file_complete: Some(true),
            package_name: package_name.clone(),
            package_status: "ready".into(),
            package_previous_sha256: sha(package),
            package_previous_bytes: package.len() as i64,
            auxiliary_backup_sha256: BTreeMap::from([(
                "bin\\PRUNLET.md".to_string(),
                sha(&backup_body),
            )]),
            ..Default::default()
        };
        write_state(&root, &state).unwrap();
        Applied {
            root,
            stage,
            stage_info,
            state,
        }
    }
    pub(super) fn state_bytes(root: &Path) -> Vec<u8> {
        std::fs::read(root.join(STATE_NAME)).unwrap()
    }

    #[test]
    fn begin_after_normal_apply_records_the_stage_commit_as_prior() {
        let f = applied("normal", false);
        let result = begin(&f.root, NEXT, CANDIDATE).unwrap();
        assert_eq!(result["status"], "ready");
        let state = read_state(&f.root).unwrap().unwrap();
        assert_eq!(state.prior_stage_commit, CANDIDATE);
        assert_eq!(state.prior_stage_info_sha256, sha(&f.stage_info));
        assert!(result["warnings"].as_array().unwrap().is_empty());
    }

    #[test]
    fn begin_after_manual_install_reverifies_the_stage_by_its_own_provenance() {
        let f = applied("manual", true);
        let installed_before = std::fs::read(f.root.join("source-info.json")).unwrap();
        let result = begin(&f.root, NEXT, MANUAL).unwrap();
        assert_eq!(result["status"], "ready");
        assert!(
            result["warnings"]
                .to_string()
                .contains("re-verified by its own recorded provenance"),
            "{result}"
        );
        let state = read_state(&f.root).unwrap().unwrap();
        // 手動導入のcommitではなく、stage自身のcommitと来歴hashを旧来歴として記録する。
        assert_eq!(state.prior_stage_commit, CANDIDATE);
        assert_eq!(state.prior_stage_info_sha256, sha(&f.stage_info));
        assert_eq!(state.candidate_commit, NEXT);
        assert_eq!(
            state.prepared_installed_source_info_sha256,
            sha(&installed_before)
        );
        // 導入済み来歴には触れない。
        assert_eq!(
            std::fs::read(f.root.join("source-info.json")).unwrap(),
            installed_before
        );
        // ZIPはstage自身の来歴のhashで照合して再利用する（新しい名前へ作り直さない）。
        assert_eq!(state.package_name, f.state.package_name);
        assert_eq!(state.package_status, "ready");
        // 旧来歴はstage側から読み、手動導入側のbytesは使われない。
        let prior = prior_stage_provenance(&f.root, &f.stage, &state)
            .unwrap()
            .unwrap();
        assert_eq!(prior.commit, CANDIDATE);
        assert_eq!(prior.cli_hash, sha(b"candidate-cli"));
    }

    #[test]
    fn begin_rejects_the_requested_release_that_is_already_installed() {
        let f = applied("installed-commit", true);
        let error = begin(&f.root, MANUAL, MANUAL).unwrap_err().to_string();
        assert!(error.contains("already installed"), "{error}");
        // 手動導入で古い版を入れた場合に、stageのcommitと同じ最新releaseは止まらない。
        let f = applied("stage-commit-is-latest", true);
        assert_eq!(
            begin(&f.root, CANDIDATE, MANUAL).unwrap()["status"],
            "ready"
        );
    }

    /// stage自身の照合は弱まっていない。手動導入後でも、改変は拒否され、状態もstageも変わらない。
    #[test]
    fn begin_after_manual_install_still_rejects_tampering() {
        type Tamper = fn(&Applied);
        let cases: [(&str, &str, Tamper); 7] = [
            ("product", "do not match", |f| {
                write(&f.stage.join("prunlet-maintenance.exe"), b"changed");
            }),
            ("auxiliary-product", "do not match", |f| {
                write(&f.stage.join(auxiliary_path("PRUNLET.md")), b"changed");
            }),
            ("source-info", "do not match", |f| {
                let mut bytes = f.stage_info.clone();
                bytes.push(b' ');
                write(&f.stage.join("source-info.json"), &bytes);
            }),
            ("previous-auxiliary", "do not match", |f| {
                write(
                    &f.stage.join("previous-auxiliary").join("PRUNLET.md"),
                    b"changed",
                );
            }),
            ("previous-source-info", "do not match", |f| {
                let mut bytes = std::fs::read(f.stage.join("previous-source-info.json")).unwrap();
                bytes.push(b' ');
                write(&f.stage.join("previous-source-info.json"), &bytes);
            }),
            ("owner", "ownership", |f| {
                write(
                    &f.stage.join(STAGE_OWNER_NAME),
                    &owner_bytes(&f.root, NEXT).unwrap(),
                );
            }),
            ("state-hash", "do not match", |f| {
                let mut state = f.state.clone();
                state.candidate_source_info_sha256 = "A".repeat(64);
                std::fs::write(f.root.join(STATE_NAME), state.bytes().unwrap()).unwrap();
            }),
        ];
        for (name, expected, tamper) in cases {
            let f = applied(&format!("tamper-{name}"), true);
            tamper(&f);
            let state_before = state_bytes(&f.root);
            let info_before = std::fs::read(f.root.join("source-info.json")).unwrap();
            let error = begin(&f.root, NEXT, MANUAL)
                .expect_err(&format!("tampering was accepted: {name}"))
                .to_string();
            assert!(
                error.contains(expected),
                "{name}: unexpected refusal: {error}"
            );
            assert_eq!(state_bytes(&f.root), state_before, "state changed: {name}");
            assert_eq!(
                std::fs::read(f.root.join("source-info.json")).unwrap(),
                info_before,
                "installed provenance changed: {name}"
            );
        }
    }

    #[test]
    fn prior_provenance_prefers_the_stage_then_the_installed_file_and_never_a_different_hash() {
        let f = applied("prior", true);
        begin(&f.root, NEXT, MANUAL).unwrap();
        let state = read_state(&f.root).unwrap().unwrap();
        // stage側が旧来歴のまま: stageから読む。
        let prior = prior_stage_provenance(&f.root, &f.stage, &state)
            .unwrap()
            .unwrap();
        assert_eq!(prior.commit, CANDIDATE);
        // 通常導入（導入済み==旧stage）で、stage側が新来歴へ書換済み: 導入済みから読む。
        write(&f.stage.join("source-info.json"), b"{\"new\":true}");
        write(&f.root.join("source-info.json"), &f.stage_info);
        let prior = prior_stage_provenance(&f.root, &f.stage, &state)
            .unwrap()
            .unwrap();
        assert_eq!(prior.commit, CANDIDATE);
        // どちらも記録hashと一致しない: 旧hashを与えない（Noneにして上書きを許可しない）。
        write(&f.root.join("source-info.json"), b"{\"manual\":true}");
        assert!(
            prior_stage_provenance(&f.root, &f.stage, &state)
                .unwrap()
                .is_none()
        );
        // hashは一致してもcommitが記録と違う: 拒否する。
        let mut other = state.clone();
        other.prior_stage_commit = OLD.into();
        write(&f.stage.join("source-info.json"), &f.stage_info);
        assert!(prior_stage_provenance(&f.root, &f.stage, &other).is_err());
    }

    /// 未切替の候補を準備した後に手動導入し、同じcommitでbeginした場合は拒否せず、
    /// 導入済み来歴の基準を今回のbegin時点へ記録し直す。切替が始まっていれば従来どおり拒否する。
    #[test]
    fn begin_resumes_an_unapplied_candidate_after_a_manual_install() {
        let build = |name: &str| {
            let root = fixture_root(name);
            let stage = stage_path(&root);
            std::fs::create_dir_all(&stage).unwrap();
            let (aux, _) = auxiliary_hashes("old");
            let installed = serde_json::to_vec(&info(
                OLD,
                &sha(b"old-cli"),
                &sha(b"old-maintenance"),
                &aux,
                &sha(b"old-package"),
            ))
            .unwrap();
            write(&root.join("source-info.json"), &installed);
            write(
                &stage.join(STAGE_OWNER_NAME),
                &owner_bytes(&root, NEXT).unwrap(),
            );
            let state = UpdateState {
                candidate_commit: NEXT.into(),
                stage_cleanup: "pending".into(),
                prepared_installed_source_info_sha256: sha(&installed),
                ..Default::default()
            };
            write_state(&root, &state).unwrap();
            // 手動導入: 別commit・別bytes。
            let manual = serde_json::to_vec_pretty(&info(
                MANUAL,
                &sha(b"manual-cli"),
                &sha(b"manual-maintenance"),
                &aux,
                &sha(b"manual-package"),
            ))
            .unwrap();
            write(&root.join("source-info.json"), &manual);
            (root, manual, state)
        };
        let (root, manual, _) = build("resume");
        let result = begin(&root, NEXT, MANUAL).unwrap();
        assert_eq!(result["status"], "existing");
        assert!(
            result["warnings"].to_string().contains("recorded again"),
            "{result}"
        );
        let state = read_state(&root).unwrap().unwrap();
        assert_eq!(state.prepared_installed_source_info_sha256, sha(&manual));
        // 2回目は基準が一致しているので警告なし。
        assert!(
            begin(&root, NEXT, MANUAL).unwrap()["warnings"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        // 候補が切替済み（migration_completeなし・candidate_cliあり）なら、再記録せず従来どおり止める。
        let (root, _, mut state) = build("resume-started");
        state.candidate_cli_sha256 = sha(b"candidate-cli");
        state.candidate_maintenance_sha256 = sha(b"candidate-maintenance");
        state.candidate_source_info_sha256 = sha(b"x");
        state.old_commit = OLD.into();
        state.phase = "switching".into();
        let started = state.bytes().unwrap();
        std::fs::write(root.join(STATE_NAME), &started).unwrap();
        assert!(begin(&root, NEXT, MANUAL).is_err());
        assert_eq!(state_bytes(&root), started);
    }
}

#[cfg(test)]
mod unapplied_chain_tests;
