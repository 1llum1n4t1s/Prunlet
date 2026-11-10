//! 保護レジストリ検証専用。native handleとtoken変更を同じPowerShellプロセスに保持する。
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    ffi::c_void,
    ptr,
    sync::{Mutex, OnceLock},
};

type Handle = *mut c_void;
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Luid {
    low: u32,
    high: i32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Privileges {
    count: u32,
    luid: Luid,
    attributes: u32,
}
#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum: u16,
    buffer: *mut u16,
}
#[repr(C)]
struct ObjectAttributes {
    length: u32,
    root: Handle,
    name: *mut UnicodeString,
    attributes: u32,
    security: Handle,
    quality: Handle,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn CloseHandle(handle: Handle) -> i32;
    fn SetLastError(error: u32);
    fn LocalFree(handle: Handle) -> Handle;
    fn CompareStringOrdinal(
        first: *const u16,
        first_len: i32,
        second: *const u16,
        second_len: i32,
        ignore_case: i32,
    ) -> i32;
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: u32,
        data: *mut c_void,
        length: u32,
        needed: *mut u32,
    ) -> i32;
    fn LookupPrivilegeValueW(system: *const u16, name: *const u16, luid: *mut c_void) -> i32;
    fn AdjustTokenPrivileges(
        token: Handle,
        disable: i32,
        new: *const c_void,
        size: u32,
        old: *mut c_void,
        returned: *mut u32,
    ) -> i32;
    fn RegCloseKey(key: Handle) -> i32;
    fn RegGetKeySecurity(key: Handle, info: u32, data: *mut u8, length: *mut u32) -> i32;
    fn RegSetKeySecurity(key: Handle, info: u32, data: *const u8) -> i32;
    fn RegQueryValueExW(
        key: Handle,
        name: *const u16,
        reserved: *mut u32,
        kind: *mut u32,
        data: *mut u8,
        length: *mut u32,
    ) -> i32;
    fn RegSetValueExW(
        key: Handle,
        name: *const u16,
        reserved: u32,
        kind: u32,
        data: *const u8,
        length: u32,
    ) -> i32;
    fn RegQueryInfoKeyW(
        key: Handle,
        class: *mut u16,
        class_len: *mut u32,
        reserved: *mut u32,
        children: *mut u32,
        max_name: *mut u32,
        max_class: *mut u32,
        values: *mut u32,
        max_val_name: *mut u32,
        max_val_data: *mut u32,
        security: *mut u32,
        last_write: *mut i64,
    ) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl: *const u16,
        revision: u32,
        descriptor: *mut Handle,
        size: *mut u32,
    ) -> i32;
}
#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtOpenKeyEx(key: *mut Handle, access: u32, attributes: *const c_void, options: u32) -> i32;
    fn NtOpenKeyTransactedEx(
        key: *mut Handle,
        access: u32,
        attributes: *const c_void,
        options: u32,
        transaction: Handle,
    ) -> i32;
    fn NtQueryKey(key: Handle, class: u32, data: *mut c_void, length: u32, needed: *mut u32)
    -> i32;
    fn NtQueryObject(
        handle: Handle,
        class: u32,
        data: *mut c_void,
        length: u32,
        needed: *mut u32,
    ) -> i32;
    fn RtlNtStatusToDosError(status: i32) -> u32;
}
#[link(name = "KtmW32")]
unsafe extern "system" {
    fn CreateTransaction(
        security: Handle,
        unit: Handle,
        options: u32,
        isolation: u32,
        flags: u32,
        timeout: u32,
        description: *const u16,
    ) -> Handle;
    fn RollbackTransaction(transaction: Handle) -> i32;
    fn CommitTransaction(transaction: Handle) -> i32;
}

#[derive(Default)]
struct Leases {
    keys: HashMap<String, isize>,
    transactions: HashMap<String, isize>,
    privileges: HashMap<String, PrivilegeLease>,
}
#[derive(Clone)]
struct PrivilegeLease {
    token: isize,
    previous: Vec<Privileges>,
    before: BTreeMap<String, String>,
    enabled: BTreeMap<String, String>,
}
static LEASES: OnceLock<Mutex<Leases>> = OnceLock::new();
fn leases() -> Result<std::sync::MutexGuard<'static, Leases>> {
    LEASES
        .get_or_init(|| Mutex::new(Leases::default()))
        .lock()
        .map_err(|_| anyhow::anyhow!("Fixture lease table poisoned"))
}
fn id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}
fn last() -> anyhow::Error {
    std::io::Error::last_os_error().into()
}
fn win(error: i32) -> Result<()> {
    if error != 0 {
        return Err(std::io::Error::from_raw_os_error(error).into());
    }
    Ok(())
}
fn status(error: i32) -> Result<()> {
    if error < 0 {
        return Err(std::io::Error::from_raw_os_error(
            unsafe { RtlNtStatusToDosError(error) } as i32
        )
        .into());
    }
    Ok(())
}
fn wide(text: &str) -> Result<Vec<u16>> {
    ensure!(!text.contains('\0'), "Embedded NUL");
    Ok(text.encode_utf16().chain(Some(0)).collect())
}
fn string<'a>(args: &'a Value, name: &str) -> Result<&'a str> {
    args.get(name)
        .and_then(Value::as_str)
        .with_context(|| format!("Missing {name}"))
}
fn number(args: &Value, name: &str) -> Result<u32> {
    Ok(u32::try_from(
        args.get(name)
            .and_then(Value::as_u64)
            .with_context(|| format!("Missing {name}"))?,
    )?)
}
fn native_key(args: &Value, table: &Leases) -> Result<Handle> {
    if let Some(id) = args.get("keyLease").and_then(Value::as_str) {
        return Ok(*table.keys.get(id).context("Unknown key lease")? as Handle);
    }
    let value = args
        .get("handle")
        .and_then(Value::as_u64)
        .context("Missing borrowed handle")?;
    ensure!(value != 0, "Null registry handle");
    Ok(usize::try_from(value)? as Handle)
}
fn privilege_snapshot(token: Handle) -> Result<BTreeMap<String, String>> {
    let mut size = 0;
    unsafe {
        GetTokenInformation(token, 3, ptr::null_mut(), 0, &mut size);
    }
    ensure!(
        (4..=65536).contains(&size),
        "Invalid token privilege information size"
    );
    let mut data = vec![0u8; size as usize];
    if unsafe { GetTokenInformation(token, 3, data.as_mut_ptr().cast(), size, &mut size) } == 0 {
        return Err(last());
    }
    let count = u32::from_ne_bytes(data[0..4].try_into()?) as usize;
    ensure!(count <= (data.len() - 4) / 12, "Malformed token privileges");
    let mut result = BTreeMap::new();
    for name in [
        "SeBackupPrivilege",
        "SeRestorePrivilege",
        "SeSecurityPrivilege",
    ] {
        let mut luid = Luid::default();
        if unsafe {
            LookupPrivilegeValueW(
                ptr::null(),
                wide(name)?.as_ptr(),
                (&mut luid as *mut Luid).cast(),
            )
        } == 0
        {
            return Err(last());
        }
        let mut found = "absent".to_string();
        for i in 0..count {
            let offset = 4 + i * 12;
            let low = u32::from_ne_bytes(data[offset..offset + 4].try_into()?);
            let high = i32::from_ne_bytes(data[offset + 4..offset + 8].try_into()?);
            if low == luid.low && high == luid.high {
                found = format!(
                    "0x{:08X}",
                    u32::from_ne_bytes(data[offset + 8..offset + 12].try_into()?)
                );
            }
        }
        result.insert(name.into(), found);
    }
    Ok(result)
}
fn process_privileges(pid: u32) -> Result<Value> {
    let process = unsafe { OpenProcess(0x1000, 0, pid) };
    if process.is_null() {
        return Err(last());
    }
    let mut token = ptr::null_mut();
    if unsafe { OpenProcessToken(process, 8, &mut token) } == 0 {
        let error = last();
        unsafe {
            CloseHandle(process);
        };
        return Err(error);
    }
    let result = privilege_snapshot(token);
    unsafe {
        CloseHandle(token);
        CloseHandle(process);
    };
    Ok(json!(result?))
}
fn restore(lease: &mut PrivilegeLease) -> Result<Value> {
    let token = lease.token as Handle;
    let mut errors = Vec::new();
    for prior in lease.previous.iter().rev() {
        let mut ignored = Privileges::default();
        let mut returned = 0;
        unsafe {
            SetLastError(0);
        }
        let ok = unsafe {
            AdjustTokenPrivileges(
                token,
                0,
                (prior as *const Privileges).cast(),
                std::mem::size_of::<Privileges>() as u32,
                (&mut ignored as *mut Privileges).cast(),
                &mut returned,
            )
        };
        let error = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
        if ok == 0 || error != 0 {
            errors.push(error);
        }
    }
    let after = privilege_snapshot(token)?;
    let restored = errors.is_empty() && lease.before.iter().all(|(k, v)| after.get(k) == Some(v));
    ensure!(
        restored,
        "Privilege restoration did not preserve original token attributes; errors={errors:?}, before={:?}, after={after:?}",
        lease.before
    );
    lease.previous.clear();
    unsafe {
        CloseHandle(token);
    };
    lease.token = 0;
    Ok(json!({"after":after,"restored":true,"restoreErrors":errors}))
}
fn begin_privileges() -> Result<Value> {
    let mut token = ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), 0x28, &mut token) } == 0 {
        return Err(last());
    }
    let before = match privilege_snapshot(token) {
        Ok(v) => v,
        Err(e) => {
            unsafe {
                CloseHandle(token);
            };
            return Err(e);
        }
    };
    let mut lease = PrivilegeLease {
        token: token as isize,
        previous: Vec::new(),
        before,
        enabled: BTreeMap::new(),
    };
    let result = (|| -> Result<()> {
        for name in [
            "SeBackupPrivilege",
            "SeRestorePrivilege",
            "SeSecurityPrivilege",
        ] {
            let mut luid = Luid::default();
            if unsafe {
                LookupPrivilegeValueW(
                    ptr::null(),
                    wide(name)?.as_ptr(),
                    (&mut luid as *mut Luid).cast(),
                )
            } == 0
            {
                return Err(last());
            }
            let request = Privileges {
                count: 1,
                luid,
                attributes: 2,
            };
            let mut old = Privileges::default();
            let mut size = 0;
            unsafe {
                SetLastError(0);
            }
            let ok = unsafe {
                AdjustTokenPrivileges(
                    token,
                    0,
                    (&request as *const Privileges).cast(),
                    std::mem::size_of::<Privileges>() as u32,
                    (&mut old as *mut Privileges).cast(),
                    &mut size,
                )
            };
            let error = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if ok == 0 || error != 0 {
                return Err(std::io::Error::from_raw_os_error(error).into());
            }
            lease.previous.push(old);
        }
        lease.enabled = privilege_snapshot(token)?;
        Ok(())
    })();
    if let Err(error) = result {
        return match restore(&mut lease) {
            Ok(_) => Err(error),
            Err(restore_error) => {
                let id = id();
                leases()?.privileges.insert(id.clone(), lease);
                bail!(
                    "Privilege enable failed: {error:#}; restoration failed and lease {id} retained: {restore_error:#}"
                )
            }
        };
    }
    let id = id();
    let out = json!({"id":id,"before":lease.before,"enabled":lease.enabled});
    leases()?.privileges.insert(id, lease);
    Ok(out)
}
fn open(args: &Value, table: &mut Leases) -> Result<Value> {
    let mut name = wide(string(args, "name")?)?;
    let length = (name.len() - 1)
        .checked_mul(2)
        .context("Name length overflow")?;
    ensure!(length <= u16::MAX as usize - 2, "Native name too long");
    let mut unicode = UnicodeString {
        length: length as u16,
        maximum: (length + 2) as u16,
        buffer: name.as_mut_ptr(),
    };
    let parent = if args.get("parentLease").and_then(Value::as_str).is_some() {
        *table
            .keys
            .get(string(args, "parentLease")?)
            .context("Unknown parent lease")? as Handle
    } else if let Some(handle) = args.get("parentHandle").and_then(Value::as_u64) {
        usize::try_from(handle)? as Handle
    } else {
        ptr::null_mut()
    };
    let raw = args
        .get("raw")
        .and_then(Value::as_bool)
        .context("Missing raw")?;
    let mut attributes = ObjectAttributes {
        length: std::mem::size_of::<ObjectAttributes>() as u32,
        root: parent,
        name: &mut unicode,
        attributes: 0x40 | 0x1000 | if raw { 0x100 } else { 0 },
        security: ptr::null_mut(),
        quality: ptr::null_mut(),
    };
    let mut key = ptr::null_mut();
    let access = number(args, "access")?;
    let options = number(args, "options")?;
    let result = if let Some(tx) = args.get("transaction").and_then(Value::as_str) {
        let tx = *table
            .transactions
            .get(tx)
            .context("Unknown transaction lease")? as Handle;
        unsafe {
            NtOpenKeyTransactedEx(
                &mut key,
                access,
                (&mut attributes as *mut ObjectAttributes).cast(),
                options,
                tx,
            )
        }
    } else {
        unsafe {
            NtOpenKeyEx(
                &mut key,
                access,
                (&mut attributes as *mut ObjectAttributes).cast(),
                options,
            )
        }
    };
    let mut granted = 0u32;
    let mut lease = None;
    if result >= 0 {
        ensure!(!key.is_null(), "Native open returned null handle");
        let mut basic = [0u32; 14];
        let mut needed = 0;
        let query = unsafe {
            NtQueryObject(
                key,
                0,
                basic.as_mut_ptr().cast(),
                std::mem::size_of_val(&basic) as u32,
                &mut needed,
            )
        };
        if let Err(error) = status(query) {
            unsafe {
                RegCloseKey(key);
            };
            return Err(error);
        }
        granted = basic[1];
        let key_id = id();
        table.keys.insert(key_id.clone(), key as isize);
        lease = Some(key_id);
    }
    Ok(
        json!({"keyLease":lease,"error":if result<0 {unsafe{RtlNtStatusToDosError(result)}}else{0},"status":format!("{:08X}",result as u32),"grantedAccess":granted}),
    )
}
fn query_name(key: Handle) -> Result<Value> {
    let mut size = 0;
    unsafe {
        NtQueryKey(key, 3, ptr::null_mut(), 0, &mut size);
    };
    ensure!((4..=131072).contains(&size), "Invalid native key name size");
    let mut data = vec![0u8; size as usize];
    status(unsafe { NtQueryKey(key, 3, data.as_mut_ptr().cast(), size, &mut size) })?;
    let bytes = u32::from_ne_bytes(data[0..4].try_into()?) as usize;
    ensure!(
        bytes % 2 == 0 && bytes <= data.len() - 4,
        "Invalid native key name"
    );
    let utf16 = data[4..4 + bytes]
        .chunks_exact(2)
        .map(|x| u16::from_ne_bytes([x[0], x[1]]))
        .collect::<Vec<_>>();
    Ok(json!(String::from_utf16(&utf16)?))
}
fn security(key: Handle, info: u32) -> Result<Vec<u8>> {
    let mut size = 0;
    let error = unsafe { RegGetKeySecurity(key, info, ptr::null_mut(), &mut size) };
    if error != 0 && error != 122 {
        win(error)?;
    }
    ensure!(
        size > 0 && size <= 16 * 1024 * 1024,
        "Invalid security descriptor size"
    );
    let mut data = vec![0u8; size as usize];
    win(unsafe { RegGetKeySecurity(key, info, data.as_mut_ptr(), &mut size) })?;
    Ok(data)
}
fn value(key: Handle, name: &str) -> Result<(u32, Vec<u8>)> {
    let name = wide(name)?;
    let mut kind = 0;
    let mut length = 0;
    win(unsafe {
        RegQueryValueExW(
            key,
            name.as_ptr(),
            ptr::null_mut(),
            &mut kind,
            ptr::null_mut(),
            &mut length,
        )
    })?;
    ensure!(length <= 64 * 1024 * 1024, "Registry value too large");
    let mut data = vec![0u8; length as usize];
    win(unsafe {
        RegQueryValueExW(
            key,
            name.as_ptr(),
            ptr::null_mut(),
            &mut kind,
            data.as_mut_ptr(),
            &mut length,
        )
    })?;
    Ok((kind, data))
}
fn class(key: Handle) -> Result<Value> {
    let mut data = vec![0u16; 1024];
    let mut size = data.len() as u32;
    win(unsafe {
        RegQueryInfoKeyW(
            key,
            data.as_mut_ptr(),
            &mut size,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
        )
    })?;
    Ok(json!(String::from_utf16(&data[..size as usize])?))
}

// 保持したkeyのnative名とGUID専用領域を照合し、渡されたdescriptorのDACLだけを復元する。
fn restore_scoped_dacl(args: &Value, table: &Leases) -> Result<Value> {
    let id = string(args, "keyLease")?;
    let key = *table.keys.get(id).context("Unknown protected key lease")? as Handle;
    let machine = args
        .get("machine")
        .and_then(Value::as_bool)
        .context("Missing machine")?;
    let prefix = string(args, "prefix")?;
    let path = string(args, "path")?;
    let root = if machine {
        "SYSTEM\\PrunletE2E\\"
    } else {
        "Software\\PrunletE2E\\"
    };
    ensure!(
        prefix.len() == root.len() + 32
            && prefix
                .get(..root.len())
                .is_some_and(|p| p.eq_ignore_ascii_case(root))
            && prefix
                .get(root.len()..)
                .is_some_and(|s| uuid::Uuid::parse_str(s).is_ok()),
        "Unsafe fixture namespace"
    );
    let lower = path.to_lowercase();
    let prefix_lower = prefix.to_lowercase();
    ensure!(
        lower.starts_with(&(prefix_lower.clone() + "-link-probes\\"))
            || lower.starts_with(
                &(prefix_lower + "\\backup-restore-protected-cli-mcp-key-value-roundtrip\\")
            ),
        "DACL restoration escaped its dedicated fixture subtree"
    );
    let base = if machine {
        "\\Registry\\Machine\\".to_string()
    } else {
        let identity = crate::session::dispatch("session.tokenInfo", &json!({}))?;
        format!(
            "\\Registry\\User\\{}\\",
            identity["ownerSid"]
                .as_str()
                .context("Missing effective token SID")?
        )
    };
    let expected = format!("{base}{path}");
    let actual = query_name(key)?;
    let actual = actual.as_str().context("Missing native key name")?;
    let expected_w = wide(&expected)?;
    let actual_w = wide(actual)?;
    ensure!(
        unsafe { CompareStringOrdinal(expected_w.as_ptr(), -1, actual_w.as_ptr(), -1, 1) } == 2,
        "Held key identity differs from the dedicated fixture path"
    );
    let data = STANDARD.decode(string(args, "base64")?)?;
    ensure!(
        data.len() >= 20 && data[0] == 1,
        "Invalid saved security descriptor"
    );
    let control = u16::from_le_bytes([data[2], data[3]]);
    ensure!(
        control & 0x8000 != 0 && control & 0x0004 != 0,
        "Saved descriptor lacks a self-relative DACL"
    );
    let information = if control & 0x1000 != 0 {
        0x80000004
    } else {
        0x20000004
    };
    win(unsafe { RegSetKeySecurity(key, information, data.as_ptr()) })?;
    Ok(Value::Null)
}
pub fn dispatch(op: &str, args: &Value) -> Result<Value> {
    if op == "registry.protected.processPrivileges" {
        return process_privileges(number(args, "pid")?);
    }
    if op == "registry.protected.privilegeBegin" {
        return begin_privileges();
    }
    let mut table = leases()?;
    match op {
        "registry.protected.privilegeClose" => {
            let id = string(args, "id")?;
            let result = restore(
                table
                    .privileges
                    .get_mut(id)
                    .context("Unknown privilege lease")?,
            )?;
            table.privileges.remove(id);
            Ok(result)
        }
        "registry.protected.open" => open(args, &mut table),
        "registry.protected.keyClose" => {
            let id = string(args, "id")?;
            let key = *table.keys.get(id).context("Unknown key lease")? as Handle;
            win(unsafe { RegCloseKey(key) })?;
            table.keys.remove(id);
            Ok(Value::Null)
        }
        "registry.protected.transactionBegin" => {
            let description = wide("Prunlet isolated backup/restore open probe")?;
            let tx = unsafe {
                CreateTransaction(
                    ptr::null_mut(),
                    ptr::null_mut(),
                    0,
                    0,
                    0,
                    30000,
                    description.as_ptr(),
                )
            };
            if tx.is_null() || tx as isize == -1 {
                return Err(last());
            }
            let id = id();
            table.transactions.insert(id.clone(), tx as isize);
            Ok(json!(id))
        }
        "registry.protected.transactionRollback" | "registry.protected.transactionCommit" => {
            let tx = *table
                .transactions
                .get(string(args, "id")?)
                .context("Unknown transaction")? as Handle;
            let ok = if op.ends_with("Rollback") {
                unsafe { RollbackTransaction(tx) }
            } else {
                unsafe { CommitTransaction(tx) }
            };
            Ok(json!(if ok != 0 {
                0
            } else {
                std::io::Error::last_os_error().raw_os_error().unwrap_or(-1)
            }))
        }
        "registry.protected.transactionClose" => {
            let id = string(args, "id")?;
            let tx = *table.transactions.get(id).context("Unknown transaction")? as Handle;
            if unsafe { CloseHandle(tx) } == 0 {
                return Err(last());
            }
            table.transactions.remove(id);
            Ok(Value::Null)
        }
        "registry.protected.name" => query_name(native_key(args, &table)?),
        "registry.protected.class" => class(native_key(args, &table)?),
        "registry.protected.security" => Ok(json!(
            STANDARD.encode(security(native_key(args, &table)?, 0x10000)?)
        )),
        "registry.protected.daclGet" => Ok(json!(
            STANDARD.encode(security(native_key(args, &table)?, 4)?)
        )),
        "registry.protected.daclSet" => {
            let data = STANDARD.decode(string(args, "base64")?)?;
            ensure!(!data.is_empty(), "Empty DACL descriptor");
            win(unsafe { RegSetKeySecurity(native_key(args, &table)?, 4, data.as_ptr()) })?;
            Ok(Value::Null)
        }
        "registry.protected.restoreDacl" => restore_scoped_dacl(args, &table),
        "registry.protected.restrict" => {
            let key = native_key(args, &table)?;
            let sddl = wide("D:P(D;;KA;;;WD)")?;
            let mut descriptor = ptr::null_mut();
            if unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    1,
                    &mut descriptor,
                    ptr::null_mut(),
                )
            } == 0
            {
                return Err(last());
            }
            let error = unsafe { RegSetKeySecurity(key, 4, descriptor.cast()) };
            unsafe {
                LocalFree(descriptor);
            };
            win(error)?;
            Ok(Value::Null)
        }
        "registry.protected.read" => {
            let (kind, data) = value(native_key(args, &table)?, "sentinel")?;
            ensure!(kind == 3, "Raw type changed");
            Ok(json!(STANDARD.encode(data)))
        }
        "registry.protected.value" => {
            let (kind, data) = value(native_key(args, &table)?, string(args, "name")?)?;
            Ok(json!(format!("{kind}:{}", STANDARD.encode(data))))
        }
        "registry.protected.set" => {
            let data = STANDARD.decode(string(args, "base64")?)?;
            let name = wide("sentinel")?;
            let error = unsafe {
                RegSetValueExW(
                    native_key(args, &table)?,
                    name.as_ptr(),
                    0,
                    3,
                    data.as_ptr(),
                    u32::try_from(data.len())?,
                )
            };
            Ok(json!(error))
        }
        _ => bail!("Unknown protected registry fixture operation"),
    }
}
