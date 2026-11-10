//! 検証専用のWindowsファイル観測。製品Coreへの依存は持たない。
#[path = "file_shell.rs"]
mod file_shell;
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    ffi::OsStr,
    io::{Read, Write},
    os::windows::{ffi::OsStrExt, fs::OpenOptionsExt, io::FromRawHandle},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, FreeLibrary, GetLastError, HANDLE, INVALID_HANDLE_VALUE},
    Security::{
        GetKernelObjectSecurity, GetLengthSid, GetTokenInformation, TOKEN_QUERY, TOKEN_USER,
        TokenUser,
    },
    Storage::FileSystem::*,
    System::{
        IO::DeviceIoControl,
        LibraryLoader::{DONT_RESOLVE_DLL_REFERENCES, LoadLibraryExW},
        Threading::{GetCurrentProcess, OpenProcessToken},
    },
};

#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtSetSecurityObject(
        handle: HANDLE,
        information: u32,
        descriptor: *const std::ffi::c_void,
    ) -> i32;
    fn RtlNtStatusToDosError(status: i32) -> u32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CompareStringOrdinal(
        left: *const u16,
        left_len: i32,
        right: *const u16,
        right_len: i32,
        ignore_case: i32,
    ) -> i32;
    fn CreateJobObjectW(attributes: *const std::ffi::c_void, name: *const u16) -> HANDLE;
    fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) -> i32;
    fn QueryInformationJobObject(
        job: HANDLE,
        class: i32,
        info: *mut std::ffi::c_void,
        length: u32,
        returned: *mut u32,
    ) -> i32;
    fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) -> HANDLE;
    fn Process32FirstW(snapshot: HANDLE, entry: *mut ProcessEntry) -> i32;
    fn Process32NextW(snapshot: HANDLE, entry: *mut ProcessEntry) -> i32;
}
#[repr(C)]
struct ProcessEntry {
    size: u32,
    usage: u32,
    process_id: u32,
    heap: usize,
    module_id: u32,
    threads: u32,
    parent_id: u32,
    priority: i32,
    flags: u32,
    executable: [u16; 260],
}
#[repr(C)]
struct JobAccounting {
    user: i64,
    kernel: i64,
    period_user: i64,
    period_kernel: i64,
    page_faults: u32,
    total: u32,
    active: u32,
    terminated: u32,
}
fn jobs() -> &'static Mutex<HashMap<String, usize>> {
    static JOBS: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}
fn job_open(args: &Value) -> Result<Value> {
    let raw = args
        .get("processHandle")
        .and_then(Value::as_u64)
        .context("Missing borrowed process handle")?;
    ensure!(raw != 0 && raw != u64::MAX, "Invalid process handle");
    let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    if handle.is_null() {
        return Err(std::io::Error::last_os_error().into());
    }
    let job = Handle(handle);
    if unsafe { AssignProcessToJobObject(job.0, raw as usize as HANDLE) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let id = uuid::Uuid::new_v4().simple().to_string();
    let mut table = jobs()
        .lock()
        .map_err(|_| anyhow::anyhow!("Job fixture table unavailable"))?;
    ensure!(!table.contains_key(&id), "Job fixture collision");
    let raw = job.0 as usize;
    std::mem::forget(job);
    table.insert(id.clone(), raw);
    Ok(json!({"leaseId":id}))
}
fn job_cpu(args: &Value) -> Result<Value> {
    let table = jobs()
        .lock()
        .map_err(|_| anyhow::anyhow!("Job fixture table unavailable"))?;
    let raw = *table
        .get(field(args, "leaseId")?)
        .context("Unknown job lease")? as HANDLE;
    let mut accounting: JobAccounting = unsafe { std::mem::zeroed() };
    if unsafe {
        QueryInformationJobObject(
            raw,
            1,
            (&mut accounting as *mut JobAccounting).cast(),
            std::mem::size_of::<JobAccounting>() as u32,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(json!(
        accounting
            .user
            .checked_add(accounting.kernel)
            .context("Job CPU accounting overflow")? as f64
            / 10000.0
    ))
}
fn job_release(args: &Value) -> Result<Value> {
    let mut table = jobs()
        .lock()
        .map_err(|_| anyhow::anyhow!("Job fixture table unavailable"))?;
    let id = field(args, "leaseId")?;
    let raw = *table.get(id).context("Unknown job lease")? as HANDLE;
    if unsafe { CloseHandle(raw) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    table.remove(id);
    Ok(json!({"released":true}))
}
fn child_pids(args: &Value) -> Result<Value> {
    let parent = u32::try_from(
        args.get("parentPid")
            .and_then(Value::as_u64)
            .context("Missing parent PID")?,
    )?;
    let raw = unsafe { CreateToolhelp32Snapshot(2, 0) };
    if raw == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error().into());
    }
    let snapshot = Handle(raw);
    let mut entry: ProcessEntry = unsafe { std::mem::zeroed() };
    entry.size = std::mem::size_of::<ProcessEntry>() as u32;
    let mut result = Vec::new();
    if unsafe { Process32FirstW(snapshot.0, &mut entry) } != 0 {
        loop {
            if entry.parent_id == parent {
                result.push(entry.process_id);
            }
            if unsafe { Process32NextW(snapshot.0, &mut entry) } == 0 {
                break;
            }
        }
    }
    Ok(json!(result))
}

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

fn field<'a>(args: &'a Value, name: &str) -> Result<&'a str> {
    args.get(name)
        .and_then(Value::as_str)
        .with_context(|| format!("Missing string argument: {name}"))
}
fn wide(path: &OsStr) -> Result<Vec<u16>> {
    let mut value: Vec<u16> = path.encode_wide().collect();
    ensure!(!value.contains(&0), "Embedded NUL in fixture path");
    value.push(0);
    Ok(value)
}
fn wide_path(path: &Path) -> Result<Vec<u16>> {
    let value = path.to_str().context("Fixture path is not Unicode")?;
    let extended = if value.starts_with(r"\\?\") {
        value.to_owned()
    } else if let Some(unc) = value.strip_prefix(r"\\") {
        format!(r"\\?\UNC\{unc}")
    } else {
        format!(r"\\?\{value}")
    };
    wide(OsStr::new(&extended))
}
fn absolute(text: &str) -> Result<PathBuf> {
    let path = PathBuf::from(text);
    ensure!(path.is_absolute(), "Fixture path must be absolute");
    let literal = text.strip_prefix(r"\\?\").unwrap_or(text);
    ensure!(
        !literal
            .chars()
            .any(|ch| ch == '\0' || ch == '*' || ch == '?'),
        "Fixture path contains a wildcard or NUL"
    );
    ensure!(
        !literal
            .split(['\\', '/'])
            .any(|part| part == "." || part == ".."),
        "Fixture path contains relative components"
    );
    Ok(path)
}
fn within(path: &Path, root: &Path) -> bool {
    // 予約名を参照するextended DOS pathと通常のfixture rootを同じ表記で照合する。
    fn scope_name(value: &Path) -> String {
        let value = value.to_string_lossy().replace('/', "\\");
        let value = if let Some(unc) = value.strip_prefix(r"\\?\UNC\") {
            format!(r"\\{unc}")
        } else {
            value.strip_prefix(r"\\?\").unwrap_or(&value).to_owned()
        };
        value.trim_end_matches('\\').to_owned()
    }
    let path: Vec<u16> = scope_name(path).encode_utf16().collect();
    let root: Vec<u16> = scope_name(root).encode_utf16().collect();
    if root.len() >= path.len()
        || path[root.len()] != b'\\' as u16
        || root.len() > i32::MAX as usize
    {
        return false;
    }
    // Windowsのordinal大文字小文字比較を使い、Unicode展開による別pathの同一視を防ぐ。
    unsafe {
        CompareStringOrdinal(
            path.as_ptr(),
            root.len() as i32,
            root.as_ptr(),
            root.len() as i32,
            1,
        ) == 2
    }
}
fn pin_parents(path: &Path) -> Result<Vec<Handle>> {
    let mut names: Vec<_> = path.ancestors().collect();
    names.reverse();
    let mut held = Vec::new();
    for name in names {
        let fixed = open(name, 0x20080, FILE_SHARE_READ | FILE_SHARE_WRITE)?;
        let info = node(fixed.0)?;
        ensure!(
            info["Directory"] == true && info["ReparseTag"] == 0,
            "Fixture ancestor is not an ordinary directory"
        );
        held.push(fixed);
    }
    Ok(held)
}
fn create_hardlink(args: &Value) -> Result<Value> {
    let source = absolute(field(args, "source")?)?;
    let link = absolute(field(args, "link")?)?;
    let scope = absolute(field(args, "scope")?)?;
    ensure!(
        within(&source, &scope) && within(&link, &scope),
        "Fixture paths escaped their owned scope"
    );
    let _source_parents = pin_parents(source.parent().context("Missing source parent")?)?;
    let _link_parents = pin_parents(link.parent().context("Missing destination parent")?)?;
    let fixed = open(&source, 0x20080, FILE_SHARE_READ | FILE_SHARE_WRITE)?;
    let expected = field(args, "expectedId")?;
    ensure!(
        identity(fixed.0)? == expected,
        "Fixture source identity changed"
    );
    let proof = node(fixed.0)?;
    ensure!(
        proof["Directory"] == false && proof["ReparseTag"] == 0,
        "Hardlink source must be an ordinary file"
    );
    let name = wide_path(&link)?;
    let original = wide_path(&source)?;
    if unsafe { CreateHardLinkW(name.as_ptr(), original.as_ptr(), std::ptr::null()) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let created = open(
        &link,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    ensure!(
        identity(created.0)? == expected && identity(fixed.0)? == expected,
        "Hardlink identity changed after creation"
    );
    Ok(json!({"created":true,"id":expected}))
}
fn case_sensitive(args: &Value, create: bool) -> Result<Value> {
    let path = absolute(field(args, "path")?)?;
    if !create {
        let handle = open(
            &path,
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        )?;
        let mut flags = 0u32;
        // FileCaseSensitiveInfoは固定4 bytes。既存fixtureのnative flagを読む。
        if unsafe { GetFileInformationByHandleEx(handle.0, 23, (&mut flags as *mut u32).cast(), 4) }
            == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        return Ok(json!((flags & 1) != 0));
    }
    let scope = absolute(field(args, "scope")?)?;
    ensure!(
        within(&path, &scope),
        "Case-sensitive fixture escaped its scope"
    );
    let parent = path
        .parent()
        .context("Missing case-sensitive fixture parent")?;
    let _parents = pin_parents(parent)?;
    let directory = open(
        parent,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
    )?;
    ensure!(
        identity(directory.0)? == field(args, "expectedParentId")?,
        "Fixture parent identity changed"
    );
    let contents = STANDARD.decode(field(args, "contentBase64")?)?;
    ensure!(
        contents.len() <= 1048576,
        "Case-sensitive fixture exceeds its bounded input"
    );
    let raw = unsafe {
        CreateFileW(
            wide_path(&path)?.as_ptr(),
            0x40000000,
            0,
            std::ptr::null(),
            CREATE_NEW,
            FILE_FLAG_POSIX_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        )
    };
    if raw == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error().into());
    }
    // 所有権をFileへ移し、書込みとflushが終わるまで同じhandleを保持する。
    let mut file = unsafe { std::fs::File::from_raw_handle(raw) };
    file.write_all(&contents)?;
    file.sync_all()?;
    Ok(json!({"created":true}))
}
fn file_times(args: &Value, change: bool) -> Result<Value> {
    let path = absolute(field(args, "path")?)?;
    let scope = absolute(field(args, "scope")?)?;
    ensure!(within(&path, &scope), "Time fixture escaped its scope");
    let _parents = pin_parents(path.parent().context("Missing fixture parent")?)?;
    let handle = open(&path, if change { 0x180 } else { 0x80 }, 7)?;
    ensure!(
        identity(handle.0)? == field(args, "expectedId")?,
        "Time fixture identity changed"
    );
    let mut basic: FILE_BASIC_INFO = unsafe { std::mem::zeroed() };
    if unsafe {
        GetFileInformationByHandleEx(
            handle.0,
            FileBasicInfo,
            (&mut basic as *mut FILE_BASIC_INFO).cast(),
            std::mem::size_of::<FILE_BASIC_INFO>() as u32,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    if change {
        basic.ChangeTime = basic
            .ChangeTime
            .checked_add(100_000_000)
            .context("Fixture change time overflow")?;
        if unsafe {
            SetFileInformationByHandle(
                handle.0,
                FileBasicInfo,
                (&basic as *const FILE_BASIC_INFO).cast(),
                std::mem::size_of::<FILE_BASIC_INFO>() as u32,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    Ok(
        json!({"CreationTime":basic.CreationTime,"LastAccessTime":basic.LastAccessTime,"LastWriteTime":basic.LastWriteTime,"ChangeTime":basic.ChangeTime,"Attributes":basic.FileAttributes}),
    )
}
fn listed_change_time(args: &Value) -> Result<Value> {
    let path = absolute(field(args, "path")?)?;
    let scope = absolute(field(args, "scope")?)?;
    ensure!(within(&path, &scope), "Directory fixture escaped its scope");
    let _parents = pin_parents(path.parent().context("Missing fixture parent")?)?;
    let handle = open(&path, 0x81, 7)?;
    ensure!(
        identity(handle.0)? == field(args, "expectedId")?,
        "Directory fixture identity changed"
    );
    let expected = field(args, "name")?;
    ensure!(
        !expected.contains(['\\', '/']) && !expected.is_empty(),
        "Invalid entry name"
    );
    let mut data = vec![0u8; 65536];
    let mut first = true;
    for _ in 0..65536 {
        let class = if first { 20 } else { 19 };
        first = false;
        if unsafe {
            GetFileInformationByHandleEx(
                handle.0,
                class,
                data.as_mut_ptr().cast(),
                data.len() as u32,
            )
        } == 0
        {
            let error = unsafe { GetLastError() };
            if error == 18 {
                bail!("Fixture directory member missing");
            }
            return Err(std::io::Error::from_raw_os_error(error as i32).into());
        }
        let mut offset = 0usize;
        loop {
            ensure!(offset <= data.len() - 88, "Malformed directory entry");
            let read_u32 = |at: usize| u32::from_le_bytes(data[at..at + 4].try_into().unwrap());
            let next = read_u32(offset) as usize;
            let len = read_u32(offset + 60) as usize;
            ensure!(
                len % 2 == 0 && len <= data.len() - offset - 88,
                "Malformed directory name"
            );
            let words: Vec<u16> = data[offset + 88..offset + 88 + len]
                .chunks_exact(2)
                .map(|v| u16::from_le_bytes([v[0], v[1]]))
                .collect();
            if String::from_utf16(&words)? == expected {
                return Ok(json!(i64::from_le_bytes(
                    data[offset + 32..offset + 40].try_into()?
                )));
            }
            if next == 0 {
                break;
            }
            ensure!(
                next >= 88 && next <= data.len() - offset,
                "Malformed directory continuation"
            );
            offset += next;
        }
    }
    bail!("Fixture directory enumeration exceeded its bound")
}
fn open(path: &Path, access: u32, share: u32) -> Result<Handle> {
    let name = wide_path(path)?;
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            access,
            share,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(Handle(handle))
}
fn identity(handle: HANDLE) -> Result<String> {
    let mut bytes = [0u8; 24];
    if unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileIdInfo,
            bytes.as_mut_ptr().cast(),
            bytes.len() as u32,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(hex::encode_upper(bytes))
}
fn legacy_identity(handle: HANDLE) -> Result<String> {
    let mut value: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    if unsafe { GetFileInformationByHandle(handle, &mut value) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(format!(
        "{:08x}:{:08x}{:08x}",
        value.dwVolumeSerialNumber, value.nFileIndexHigh, value.nFileIndexLow
    ))
}
fn security(handle: HANDLE) -> Result<Vec<u8>> {
    let mut needed = 0u32;
    let initial =
        unsafe { GetKernelObjectSecurity(handle, 7, std::ptr::null_mut(), 0, &mut needed) };
    ensure!(
        initial == 0
            && std::io::Error::last_os_error().raw_os_error() == Some(122)
            && (20..=1_048_576).contains(&needed),
        "Fixture security length unavailable"
    );
    let mut bytes = vec![0u8; needed as usize];
    if unsafe { GetKernelObjectSecurity(handle, 7, bytes.as_mut_ptr().cast(), needed, &mut needed) }
        == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    bytes.truncate(needed as usize);
    Ok(bytes)
}
fn current_sid() -> Result<Vec<u8>> {
    let mut token: HANDLE = std::ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let token = Handle(token);
    let mut needed = 0u32;
    unsafe {
        GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut needed);
    }
    ensure!(
        needed >= std::mem::size_of::<TOKEN_USER>() as u32 && needed <= 1_048_576,
        "Effective token SID length is invalid"
    );
    let mut bytes = vec![0u8; needed as usize];
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            bytes.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    let user = unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast::<TOKEN_USER>()) };
    let len = unsafe { GetLengthSid(user.User.Sid) } as usize;
    ensure!((8..=68).contains(&len), "Effective SID length is invalid");
    let start = user.User.Sid as usize;
    let base = bytes.as_ptr() as usize;
    ensure!(
        start >= base
            && start
                .checked_add(len)
                .is_some_and(|end| end <= base + bytes.len()),
        "Effective SID escaped the token buffer"
    );
    Ok(unsafe { std::slice::from_raw_parts(user.User.Sid.cast::<u8>(), len) }.to_vec())
}
fn deny_descriptor(original: &[u8], mask: u32) -> Result<Vec<u8>> {
    // self-relative security descriptorの既存DACLを保ち、本人への拒否ACEだけを先頭に加える。
    ensure!(
        original.len() >= 20 && original[0] == 1,
        "Fixture security descriptor is invalid"
    );
    let control = u16::from_le_bytes(original[2..4].try_into()?);
    ensure!(
        control & 0x8004 == 0x8004,
        "Fixture requires an existing self-relative DACL"
    );
    let offset = u32::from_le_bytes(original[16..20].try_into()?) as usize;
    ensure!(
        offset >= 20 && offset + 8 <= original.len(),
        "Fixture DACL offset is invalid"
    );
    let acl_size = u16::from_le_bytes(original[offset + 2..offset + 4].try_into()?) as usize;
    let ace_count = u16::from_le_bytes(original[offset + 4..offset + 6].try_into()?);
    ensure!(
        acl_size >= 8
            && offset
                .checked_add(acl_size)
                .is_some_and(|end| end <= original.len()),
        "Fixture DACL length is invalid"
    );
    let sid = current_sid()?;
    let ace_size = 8 + sid.len();
    let total: u16 = (acl_size + ace_size)
        .try_into()
        .context("Fixture DACL too large")?;
    let count = ace_count
        .checked_add(1)
        .context("Fixture ACE count overflow")?;
    let mut acl = original[offset..offset + 8].to_vec();
    acl[2..4].copy_from_slice(&total.to_le_bytes());
    acl[4..6].copy_from_slice(&count.to_le_bytes());
    acl.push(1);
    acl.push(0);
    acl.extend_from_slice(&(ace_size as u16).to_le_bytes());
    acl.extend_from_slice(&mask.to_le_bytes());
    acl.extend_from_slice(&sid);
    acl.extend_from_slice(&original[offset + 8..offset + acl_size]);
    let mut descriptor = original.to_vec();
    while descriptor.len() % 4 != 0 {
        descriptor.push(0);
    }
    let new_offset: u32 = descriptor
        .len()
        .try_into()
        .context("Security descriptor too large")?;
    descriptor[16..20].copy_from_slice(&new_offset.to_le_bytes());
    descriptor.extend_from_slice(&acl);
    Ok(descriptor)
}
fn set_dacl(handle: HANDLE, descriptor: &[u8]) -> Result<()> {
    let status = unsafe { NtSetSecurityObject(handle, 4, descriptor.as_ptr().cast()) };
    if status < 0 {
        return Err(std::io::Error::from_raw_os_error(
            unsafe { RtlNtStatusToDosError(status) } as i32
        )
        .into());
    }
    Ok(())
}
fn set_lease_dacl(handle: HANDLE, descriptor: &[u8]) -> Result<()> {
    ensure!(
        descriptor.len() >= 20,
        "Fixture security descriptor is too short"
    );
    // 旧fixtureと同様、継承済みDACLを設定するときは継承の再計算を要求する。
    // 比較対象の元bytesは変更せず、復帰後は完全一致を必須とする。
    let mut input = descriptor.to_vec();
    let control = u16::from_le_bytes(input[2..4].try_into()?);
    if control & 0x0400 != 0 {
        input[2..4].copy_from_slice(&(control | 0x0100).to_le_bytes());
    }
    set_dacl(handle, &input)
}
fn descriptor_sid<'a>(descriptor: &'a [u8], offset_at: usize) -> Result<&'a [u8]> {
    ensure!(descriptor.len() >= 20, "Security descriptor is too short");
    let offset = u32::from_le_bytes(descriptor[offset_at..offset_at + 4].try_into()?) as usize;
    ensure!(
        offset >= 20 && offset + 8 <= descriptor.len(),
        "Security descriptor SID is invalid"
    );
    let length = 8usize
        .checked_add(descriptor[offset + 1] as usize * 4)
        .context("SID length overflow")?;
    ensure!(
        offset + length <= descriptor.len(),
        "Security descriptor SID is truncated"
    );
    Ok(&descriptor[offset..offset + length])
}
fn set_owned_dacl(args: &Value) -> Result<Value> {
    let path = absolute(field(args, "path")?)?;
    let scope = absolute(field(args, "scope")?)?;
    ensure!(
        within(&path, &scope),
        "DACL fixture escaped its owned scope"
    );
    let _parents = pin_parents(path.parent().context("Missing fixture parent")?)?;
    let fixed = open(&path, 0x60080, FILE_SHARE_READ)?;
    ensure!(
        identity(fixed.0)? == field(args, "expectedId")?,
        "DACL fixture identity changed"
    );
    ensure!(
        node(fixed.0)?["ReparseTag"] == 0,
        "DACL fixture cannot be a reparse point"
    );
    let before = security(fixed.0)?;
    let expected = STANDARD.decode(field(args, "expectedCurrentSecurityBase64")?)?;
    let desired = STANDARD.decode(field(args, "securityBase64")?)?;
    ensure!(
        before == expected && desired.len() <= 1_048_576,
        "DACL fixture security changed or supplied descriptor is oversized"
    );
    ensure!(
        desired.len() >= 20
            && desired[0] == 1
            && u16::from_le_bytes(desired[2..4].try_into()?) & 0x8004 == 0x8004
            && u32::from_le_bytes(desired[16..20].try_into()?) != 0,
        "DACL fixture requires an explicit self-relative DACL"
    );
    // NtSetSecurityObjectはDACLだけを更新するが、取得後にもOwner/Groupの不変を確認する。
    set_dacl(fixed.0, &desired)?;
    let after = security(fixed.0)?;
    ensure!(
        descriptor_sid(&before, 4)? == descriptor_sid(&after, 4)?
            && descriptor_sid(&before, 8)? == descriptor_sid(&after, 8)?,
        "Fixture owner or group changed after DACL update"
    );
    Ok(json!({"securityBase64":STANDARD.encode(after),"id":identity(fixed.0)?}))
}
struct FileLease {
    handle: usize,
    path: PathBuf,
    expected_id: String,
    original: Vec<u8>,
    changed: bool,
    writable_acl: bool,
}
fn file_leases() -> &'static Mutex<HashMap<String, FileLease>> {
    static LEASES: OnceLock<Mutex<HashMap<String, FileLease>>> = OnceLock::new();
    LEASES.get_or_init(|| Mutex::new(HashMap::new()))
}
fn held_files() -> &'static Mutex<HashMap<String, usize>> {
    static HELD: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    HELD.get_or_init(|| Mutex::new(HashMap::new()))
}
fn hold_open(args: &Value) -> Result<Value> {
    let path = absolute(field(args, "path")?)?;
    let scope = absolute(field(args, "scope")?)?;
    ensure!(
        within(&path, &scope) || path == scope,
        "Held fixture escaped its scope"
    );
    let _parents = if let Some(parent) = path.parent() {
        pin_parents(parent)?
    } else {
        Vec::new()
    };
    let mode = field(args, "mode")?;
    let share = match mode {
        "no-delete" => FILE_SHARE_READ,
        "parent" | "report-parent" => FILE_SHARE_READ | FILE_SHARE_WRITE,
        _ => bail!("Unknown file hold mode"),
    };
    let fixed = open(
        &path,
        if mode == "report-parent" {
            0x20082
        } else {
            0x80020080
        },
        share,
    )?;
    let expected = field(args, "expectedId")?;
    ensure!(
        identity(fixed.0)? == expected,
        "Held fixture identity changed"
    );
    let proof = node(fixed.0)?;
    if mode == "parent" || mode == "report-parent" {
        ensure!(
            proof["Directory"] == true && proof["ReparseTag"] == 0,
            "Held parent must be an ordinary directory"
        );
    }
    let token = uuid::Uuid::new_v4().simple().to_string();
    let mut table = held_files()
        .lock()
        .map_err(|_| anyhow::anyhow!("Held fixture table unavailable"))?;
    ensure!(!table.contains_key(&token), "Fixture lease collision");
    let raw = fixed.0;
    std::mem::forget(fixed);
    table.insert(token.clone(), raw as usize);
    Ok(json!({"leaseId":token,"id":expected}))
}
fn hold_release(args: &Value) -> Result<Value> {
    let mut table = held_files()
        .lock()
        .map_err(|_| anyhow::anyhow!("Held fixture table unavailable"))?;
    let id = field(args, "leaseId")?;
    let raw = *table.get(id).context("Unknown held fixture lease")?;
    if unsafe { CloseHandle(raw as HANDLE) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    table.remove(id);
    Ok(json!({"released":true}))
}
fn lease_open(args: &Value) -> Result<Value> {
    let path = absolute(field(args, "path")?)?;
    let scope = absolute(field(args, "scope")?)?;
    ensure!(
        within(&path, &scope),
        "Fixture lease path escaped its owned scope"
    );
    let _parents = pin_parents(path.parent().context("Missing fixture parent")?)?;
    let writable_acl = args
        .get("writableAcl")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let access = if writable_acl { 0x60080 } else { 0x20080 };
    let fixed = open(
        &path,
        access,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    let expected = field(args, "expectedId")?;
    ensure!(
        identity(fixed.0)? == expected,
        "Fixture lease identity changed"
    );
    ensure!(
        node(fixed.0)?["ReparseTag"] == 0,
        "Fixture ACL lease cannot target a reparse point"
    );
    let original = security(fixed.0)?;
    if let Some(expected_security) = args.get("expectedSecurityBase64").and_then(Value::as_str) {
        ensure!(
            STANDARD.decode(expected_security)? == original,
            "Fixture ACL differs from its recorded baseline"
        );
    }
    let token = uuid::Uuid::new_v4().simple().to_string();
    let mut table = file_leases()
        .lock()
        .map_err(|_| anyhow::anyhow!("Fixture lease table unavailable"))?;
    ensure!(!table.contains_key(&token), "Fixture lease collision");
    let raw = fixed.0;
    std::mem::forget(fixed);
    let baseline = STANDARD.encode(&original);
    table.insert(
        token.clone(),
        FileLease {
            handle: raw as usize,
            path,
            expected_id: expected.to_owned(),
            original,
            changed: false,
            writable_acl,
        },
    );
    Ok(json!({"leaseId":token,"id":expected,"baselineSecurityBase64":baseline}))
}
fn lease_state(args: &Value) -> Result<Value> {
    let table = file_leases()
        .lock()
        .map_err(|_| anyhow::anyhow!("Fixture lease table unavailable"))?;
    let lease = table
        .get(field(args, "leaseId")?)
        .context("Unknown fixture lease")?;
    let handle = lease.handle as HANDLE;
    let mut info: FILE_STANDARD_INFO = unsafe { std::mem::zeroed() };
    if unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileStandardInfo,
            (&mut info as *mut FILE_STANDARD_INFO).cast(),
            std::mem::size_of::<FILE_STANDARD_INFO>() as u32,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(
        json!({"id":identity(handle)?,"deletePending":info.DeletePending,"links":info.NumberOfLinks,"security":STANDARD.encode(security(handle)?)}),
    )
}
fn lease_deny(args: &Value, read_only: bool) -> Result<Value> {
    let mut table = file_leases()
        .lock()
        .map_err(|_| anyhow::anyhow!("Fixture lease table unavailable"))?;
    let lease = table
        .get_mut(field(args, "leaseId")?)
        .context("Unknown fixture lease")?;
    ensure!(
        lease.writable_acl && !lease.changed,
        "DACL modification was not selected or was already applied"
    );
    let mask = if read_only {
        1
    } else if args
        .get("directory")
        .and_then(Value::as_bool)
        .context("Missing directory selector")?
    {
        0x40
    } else {
        0x10001
    };
    let handle = lease.handle as HANDLE;
    let mut buffer = vec![0u16; 32768];
    let count =
        unsafe { GetFinalPathNameByHandleW(handle, buffer.as_mut_ptr(), buffer.len() as u32, 0) }
            as usize;
    ensure!(
        count > 0 && count < buffer.len(),
        "Fixture handle path cannot be verified"
    );
    let actual = String::from_utf16(&buffer[..count])?;
    let actual = actual.strip_prefix(r"\\?\").unwrap_or(&actual);
    let expected = lease
        .path
        .to_str()
        .context("Fixture lease path is not Unicode")?;
    let expected = expected.strip_prefix(r"\\?\").unwrap_or(expected);
    ensure!(
        actual.eq_ignore_ascii_case(expected) && identity(handle)? == lease.expected_id,
        "Fixture name or identity changed before DACL modification"
    );
    ensure!(
        security(handle)? == lease.original,
        "Fixture ACL changed before modification"
    );
    let modified = deny_descriptor(&lease.original, mask)?;
    // APIがエラーを返した場合も状態は不明として、復帰用leaseを保全する。
    lease.changed = true;
    set_lease_dacl(handle, &modified)?;
    Ok(json!({"applied":true}))
}
fn lease_release(args: &Value) -> Result<Value> {
    let id = field(args, "leaseId")?;
    let mut table = file_leases()
        .lock()
        .map_err(|_| anyhow::anyhow!("Fixture lease table unavailable"))?;
    let lease = table.get_mut(id).context("Unknown fixture lease")?;
    // 復帰に失敗したleaseは閉じずに保持し、失敗をそのまま呼出元へ返す。
    if lease.changed {
        let update = set_lease_dacl(lease.handle as HANDLE, &lease.original);
        let actual = security(lease.handle as HANDLE).with_context(|| {
            format!("Fixture ACL after restoration is unavailable; update result: {update:?}")
        })?;
        if update.is_err() || actual != lease.original {
            let expected = &lease.original;
            let offsets: Vec<usize> = (0..expected.len().max(actual.len()))
                .filter(|&i| expected.get(i) != actual.get(i))
                .take(64)
                .collect();
            let control = |bytes: &[u8]| {
                if bytes.len() >= 4 {
                    Some(u16::from_le_bytes([bytes[2], bytes[3]]))
                } else {
                    None
                }
            };
            bail!(
                "Fixture ACL restoration did not match its baseline: {}",
                json!({
                    "expectedLength":expected.len(),"actualLength":actual.len(),
                    "expectedSha256":hex::encode_upper(Sha256::digest(expected)),"actualSha256":hex::encode_upper(Sha256::digest(&actual)),
                "expectedControl":control(expected),"actualControl":control(&actual),"firstDifferentOffsets":offsets,
                "updateError":update.err().map(|error|error.to_string())
                })
            );
        }
        lease.changed = false;
    }
    if unsafe { CloseHandle(lease.handle as HANDLE) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    table.remove(id).context("Fixture lease disappeared")?;
    Ok(json!({"released":true}))
}
fn node(handle: HANDLE) -> Result<Value> {
    let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    if unsafe { GetFileInformationByHandle(handle, &mut info) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut id = [0u8; 24];
    if unsafe { GetFileInformationByHandleEx(handle, FileIdInfo, id.as_mut_ptr().cast(), 24) } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    let volume = u64::from_le_bytes(id[..8].try_into()?);
    let reparse = if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        let mut bytes = vec![0u8; 16384];
        let mut used = 0;
        if unsafe {
            DeviceIoControl(
                handle,
                0x900A8,
                std::ptr::null(),
                0,
                bytes.as_mut_ptr().cast(),
                bytes.len() as u32,
                &mut used,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        ensure!(
            used >= 8 && (used as usize) <= bytes.len(),
            "Malformed fixture reparse data"
        );
        bytes.truncate(used as usize);
        let tag = u32::from_le_bytes(bytes[..4].try_into()?);
        ensure!(
            matches!(tag, 0xA0000003 | 0xA000000C)
                && u16::from_le_bytes(bytes[4..6].try_into()?) as usize + 8 == bytes.len(),
            "Unsupported fixture reparse data"
        );
        Some((tag, STANDARD.encode(bytes)))
    } else {
        None
    };
    Ok(
        json!({"Relative":"","Id":hex::encode_upper(id),"VolumeSerialNumber":volume,"FileId":hex::encode_upper(&id[8..]),"SecurityBase64":STANDARD.encode(security(handle)?),"Attributes":info.dwFileAttributes,"Directory":info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0,"NumberOfLinks":info.nNumberOfLinks,"ReparseTag":reparse.as_ref().map_or(0, |r|r.0),"ReparseBase64":reparse.map_or_else(String::new, |r|r.1),"Streams":[]}),
    )
}
struct Find(HANDLE);
impl Drop for Find {
    fn drop(&mut self) {
        unsafe {
            FindClose(self.0);
        }
    }
}
fn streams(path: &Path, directory: bool) -> Result<Vec<Value>> {
    let name = wide_path(path)?;
    let mut data = WIN32_FIND_STREAM_DATA::default();
    let search = unsafe {
        FindFirstStreamW(
            name.as_ptr(),
            FindStreamInfoStandard,
            (&mut data as *mut WIN32_FIND_STREAM_DATA).cast(),
            0,
        )
    };
    if search == INVALID_HANDLE_VALUE {
        let error = std::io::Error::last_os_error();
        if directory && error.raw_os_error() == Some(38) {
            return Ok(vec![]);
        }
        if !directory && error.raw_os_error() == Some(38) {
            let input = std::fs::OpenOptions::new()
                .read(true)
                .share_mode(FILE_SHARE_READ)
                .open(path)?;
            ensure!(
                input.metadata()?.len() == 0,
                "Nonempty fixture stream enumeration was incomplete"
            );
            return Ok(vec![
                json!({"Name":"::$DATA","Length":0,"Sha256":hex::encode_upper(Sha256::digest([]))}),
            ]);
        }
        return Err(error.into());
    }
    let _search = Find(search);
    let mut result = Vec::new();
    loop {
        let n = data
            .cStreamName
            .iter()
            .position(|x| *x == 0)
            .context("Unterminated stream name")?;
        let stream_name = String::from_utf16(&data.cStreamName[..n])?;
        ensure!(
            data.StreamSize >= 0 && stream_name.starts_with(':') && stream_name.ends_with(":$DATA"),
            "Unknown fixture stream"
        );
        if !(directory && stream_name == "::$DATA") {
            let stream_path = if stream_name == "::$DATA" {
                path.to_owned()
            } else {
                PathBuf::from(format!("{}{}", path.display(), stream_name))
            };
            let mut input = std::fs::OpenOptions::new()
                .read(true)
                .share_mode(FILE_SHARE_READ)
                .open(&stream_path)?;
            ensure!(
                input.metadata()?.len() == data.StreamSize as u64,
                "Fixture stream length changed"
            );
            let mut hash = Sha256::new();
            let mut buffer = [0u8; 65536];
            loop {
                let count = input.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                hash.update(&buffer[..count]);
            }
            result.push(json!({"Name":stream_name,"Length":data.StreamSize,"Sha256":hex::encode_upper(hash.finalize())}));
        }
        if unsafe { FindNextStreamW(search, (&mut data as *mut WIN32_FIND_STREAM_DATA).cast()) }
            == 0
        {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(38) {
                return Err(error.into());
            }
            break;
        }
    }
    result.sort_by(|a, b| a["Name"].as_str().cmp(&b["Name"].as_str()));
    ensure!(
        directory || result.iter().any(|s| s["Name"] == "::$DATA"),
        "Default fixture stream absent"
    );
    Ok(result)
}
fn children(path: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = std::fs::read_dir(path)?
        .map(|e| e.map(|e| e.path()))
        .collect::<std::io::Result<Vec<_>>>()?;
    paths.sort_by_key(|p| p.as_os_str().encode_wide().collect::<Vec<_>>());
    Ok(paths)
}
fn snapshot(root: &Path) -> Result<Value> {
    // 全entryを共有削除禁止で保持し、本文hash後に名前と属性を再照合する。
    let mut pending = vec![root.to_owned()];
    let mut held = Vec::new();
    let mut memberships = BTreeMap::new();
    let root_text = root.to_str().context("Fixture path must be Unicode")?;
    while let Some(path) = pending.pop() {
        ensure!(held.len() < 65536, "Fixture node bound exceeded");
        let fixed = open(&path, 0x80020080, FILE_SHARE_READ)?;
        let mut proof = node(fixed.0)?;
        let text = path.to_str().context("Fixture path must be Unicode")?;
        proof["Relative"] = json!(
            text.strip_prefix(root_text)
                .context("Fixture escaped snapshot root")?
        );
        let directory = proof["Directory"] == true;
        let reparse = proof["ReparseTag"].as_u64().unwrap_or(0) != 0;
        if directory && !reparse {
            let list = children(&path)?;
            pending.extend(list.iter().rev().cloned());
            memberships.insert(path.clone(), list);
        }
        if !reparse {
            proof["Streams"] = json!(streams(&path, directory)?);
        }
        held.push((path, fixed, proof));
    }
    for (path, fixed, expected) in &held {
        let now = node(fixed.0)?;
        for key in [
            "Id",
            "SecurityBase64",
            "Attributes",
            "NumberOfLinks",
            "ReparseTag",
            "ReparseBase64",
        ] {
            ensure!(
                now[key] == expected[key],
                "Fixture changed during snapshot: {}",
                path.display()
            );
        }
        let current = open(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ)?;
        ensure!(
            identity(current.0)? == expected["Id"].as_str().unwrap_or(""),
            "Fixture name changed during snapshot"
        );
    }
    for (path, expected) in memberships {
        ensure!(children(&path)? == expected, "Fixture membership changed");
    }
    let mut result: Vec<Value> = held.into_iter().map(|(_, _, proof)| proof).collect();
    result.sort_by_key(|proof| {
        proof["Relative"]
            .as_str()
            .unwrap_or("")
            .encode_utf16()
            .collect::<Vec<_>>()
    });
    Ok(json!(result))
}
fn modules() -> &'static Mutex<HashMap<String, usize>> {
    static MODULES: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    MODULES.get_or_init(|| Mutex::new(HashMap::new()))
}
fn load_module(path: &Path) -> Result<Value> {
    // 検証対象DLLは同じPowerShellプロセスに載せ、lease解放まで参照を維持する。
    for ancestor in path.ancestors() {
        let metadata = std::fs::symlink_metadata(ancestor)?;
        use std::os::windows::fs::MetadataExt;
        ensure!(
            metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0,
            "Module path contains a reparse point"
        );
    }
    let held = open(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ)?;
    let expected = identity(held.0)?;
    // 旧loaderは呼出元が指定した絶対pathをそのまま渡す。通常DOS pathを
    // 拡張pathへ変えると、他processから観測するmodule名の比較が変わる。
    let name = wide(path.as_os_str())?;
    // 元fixtureと同じくDllMainや依存DLLを実行せず、image mappingだけを保持する。
    let module = unsafe {
        LoadLibraryExW(
            name.as_ptr(),
            std::ptr::null_mut(),
            DONT_RESOLVE_DLL_REFERENCES,
        )
    };
    if module.is_null() {
        return Err(std::io::Error::last_os_error().into());
    }
    let id = uuid::Uuid::new_v4().simple().to_string();
    let mut table = modules()
        .lock()
        .map_err(|_| anyhow::anyhow!("Module lease table unavailable"))?;
    table.insert(id.clone(), module as usize);
    Ok(json!({"leaseId":id,"fileId":expected,"processId":std::process::id(),"path":path}))
}
fn release_module(id: &str) -> Result<Value> {
    let mut table = modules()
        .lock()
        .map_err(|_| anyhow::anyhow!("Module lease table unavailable"))?;
    let module = *table.get(id).context("Unknown module lease")?;
    if unsafe { FreeLibrary(module as _) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    table.remove(id);
    Ok(json!({"released":true}))
}

/// 返す値はJSONのみ。handleの寿命は同一プロセス内の明示的leaseに結び付ける。
pub fn dispatch(op: &str, args: &Value) -> Result<Value> {
    match op {
        "file.identity" | "file.legacy_identity" => {
            let path = absolute(field(args, "path")?)?;
            let fixed = open(
                &path,
                FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            )?;
            Ok(json!(if op == "file.identity" {
                identity(fixed.0)?
            } else {
                legacy_identity(fixed.0)?
            }))
        }
        "file.snapshot" => snapshot(&absolute(field(args, "path")?)?),
        "file.create_hardlink" => create_hardlink(args),
        "file.security" => {
            let path = absolute(field(args, "path")?)?;
            let fixed = open(
                &path,
                0x20080,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            )?;
            Ok(json!(STANDARD.encode(security(fixed.0)?)))
        }
        "file.acl.set_owned" => set_owned_dacl(args),
        "file.node" => {
            let path = absolute(field(args, "path")?)?;
            let fixed = open(
                &path,
                0x20080,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            )?;
            node(fixed.0)
        }
        "file.parent.can_add" => {
            let path = absolute(field(args, "path")?)?;
            // FILE_ADD_SUBDIRECTORYを実際に要求し、親を変更せずに可否だけ確認する。
            let _handle = open(&path, 4, FILE_SHARE_READ | FILE_SHARE_WRITE)?;
            Ok(json!(true))
        }
        "file.job.open" => job_open(args),
        "file.job.cpu" => job_cpu(args),
        "file.job.release" => job_release(args),
        "file.process.children" => child_pids(args),
        "file.node.borrowed" => {
            // callerはDangerousAddRefで寿命を固定し、handleの所有権は渡さない。
            let raw = args
                .get("handle")
                .and_then(Value::as_u64)
                .context("Missing borrowed handle")?;
            ensure!(raw != 0 && raw != u64::MAX, "Invalid borrowed handle");
            node(raw as usize as HANDLE)
        }
        "file.token.elevated" => {
            let raw = args
                .get("handle")
                .and_then(Value::as_u64)
                .context("Missing borrowed token")?;
            ensure!(raw != 0 && raw != u64::MAX, "Invalid borrowed token");
            let mut elevated = 0u32;
            let mut returned = 0u32;
            if unsafe {
                GetTokenInformation(
                    raw as usize as HANDLE,
                    20,
                    (&mut elevated as *mut u32).cast(),
                    4,
                    &mut returned,
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            ensure!(returned == 4, "Invalid token elevation response");
            Ok(json!(elevated != 0))
        }
        "file.case_sensitive.query" => case_sensitive(args, false),
        "file.case_sensitive.create" => case_sensitive(args, true),
        "file.times.read" => file_times(args, false),
        "file.times.change" => file_times(args, true),
        "file.times.listed_change" => listed_change_time(args),
        "file.open_error" => {
            let path = absolute(field(args, "path")?)?;
            let access = args
                .get("access")
                .and_then(Value::as_u64)
                .context("Missing access mask")?;
            let access: u32 = access.try_into().context("Invalid access mask")?;
            match open(
                &path,
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            ) {
                Ok(_) => Ok(json!(0)),
                Err(error) => Ok(json!(
                    error
                        .downcast_ref::<std::io::Error>()
                        .and_then(std::io::Error::raw_os_error)
                        .context("Open failed without a Windows error")?
                )),
            }
        }
        "file.module.load" => load_module(&absolute(field(args, "path")?)?),
        "file.module.release" => release_module(field(args, "leaseId")?),
        "file.lease.open" => lease_open(args),
        "file.lease.state" => lease_state(args),
        "file.lease.deny_delete" => lease_deny(args, false),
        "file.lease.deny_read" => lease_deny(args, true),
        "file.lease.release" => lease_release(args),
        "file.hold.open" => hold_open(args),
        "file.hold.release" => hold_release(args),
        _ if op.starts_with("file.bin.") || op.starts_with("file.shell.") => {
            file_shell::dispatch(op, args)
        }
        _ => bail!("Unknown file fixture operation: {op}"),
    }
}
