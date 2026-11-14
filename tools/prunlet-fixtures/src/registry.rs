use anyhow::{Context, Result, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{ffi::c_void, ptr};

type Handle = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct Luid {
    low: u32,
    high: i32,
}

#[repr(C)]
struct Privileges {
    count: u32,
    luid: Luid,
    attributes: u32,
}
#[repr(C)]
struct PrivilegeSet {
    count: u32,
    control: u32,
    luid: Luid,
    attributes: u32,
}

#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum_length: u16,
    buffer: *const u16,
}
#[repr(C)]
struct ObjectAttributes {
    length: u32,
    root: Handle,
    name: *const UnicodeString,
    attributes: u32,
    security: *mut c_void,
    qos: *mut c_void,
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn CloseHandle(handle: Handle) -> i32;
    fn GetCurrentProcess() -> Handle;
    fn SetLastError(error: u32);
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
}

#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn LookupPrivilegeValueW(system: *const u16, name: *const u16, luid: *mut c_void) -> i32;
    fn AdjustTokenPrivileges(
        token: Handle,
        disable: i32,
        requested: *const c_void,
        length: u32,
        previous: *mut c_void,
        returned: *mut u32,
    ) -> i32;
    fn PrivilegeCheck(token: Handle, privileges: *const PrivilegeSet, enabled: *mut i32) -> i32;
    fn RegQueryValueExW(
        key: Handle,
        name: *const u16,
        reserved: *mut u32,
        kind: *mut u32,
        data: *mut u8,
        size: *mut u32,
    ) -> i32;
    fn RegSetValueExW(
        key: Handle,
        name: *const u16,
        reserved: u32,
        kind: u32,
        data: *const u8,
        size: u32,
    ) -> i32;
    fn RegGetKeySecurity(key: Handle, information: u32, data: *mut u8, size: *mut u32) -> i32;
    fn RegSetKeySecurity(key: Handle, information: u32, data: *const u8) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut *mut c_void,
        size: *mut u32,
    ) -> i32;
    fn RegOpenKeyExW(
        key: Handle,
        path: *const u16,
        options: u32,
        access: u32,
        result: *mut Handle,
    ) -> i32;
    fn RegCloseKey(key: Handle) -> i32;
    fn RegCreateKeyExW(
        key: Handle,
        path: *const u16,
        reserved: u32,
        class: *const u16,
        options: u32,
        access: u32,
        security: *const c_void,
        result: *mut Handle,
        disposition: *mut u32,
    ) -> i32;
    fn RegOpenKeyTransactedW(
        key: Handle,
        path: *const u16,
        options: u32,
        access: u32,
        result: *mut Handle,
        transaction: Handle,
        extended: *mut c_void,
    ) -> i32;
    fn RegQueryInfoKeyW(
        key: Handle,
        class: *mut u16,
        class_size: *mut u32,
        reserved: *mut u32,
        subkeys: *mut u32,
        max_subkey: *mut u32,
        max_class: *mut u32,
        values: *mut u32,
        max_value_name: *mut u32,
        max_value_data: *mut u32,
        security: *mut u32,
        last_write: *mut i64,
    ) -> i32;
}

fn enable_security() -> Result<Value> {
    // 既存fixture同様、この検証プロセスの SeSecurityPrivilege だけを有効化する。
    unsafe {
        let mut token = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), 0x28, &mut token) == 0 {
            return Ok(json!(false));
        }
        let token = OwnedHandle(token);
        let name = wide("SeSecurityPrivilege")?;
        let mut luid = Luid { low: 0, high: 0 };
        if LookupPrivilegeValueW(ptr::null(), name.as_ptr(), (&mut luid as *mut Luid).cast()) == 0 {
            return Ok(json!(false));
        }
        let requested = Privileges {
            count: 1,
            luid,
            attributes: 2,
        };
        SetLastError(0);
        if AdjustTokenPrivileges(
            token.0,
            0,
            (&requested as *const Privileges).cast(),
            0,
            ptr::null_mut(),
            ptr::null_mut(),
        ) == 0
            || std::io::Error::last_os_error().raw_os_error().unwrap_or(0) != 0
        {
            return Ok(json!(false));
        }
        let required = PrivilegeSet {
            count: 1,
            control: 1,
            luid,
            attributes: 2,
        };
        let mut enabled = 0;
        Ok(json!(
            PrivilegeCheck(token.0, &required, &mut enabled) != 0 && enabled != 0
        ))
    }
}

#[link(name = "KtmW32")]
unsafe extern "system" {
    fn CreateTransaction(
        security: *mut c_void,
        unit: *mut c_void,
        options: u32,
        isolation: u32,
        flags: u32,
        timeout: u32,
        description: *const u16,
    ) -> Handle;
    fn RollbackTransaction(transaction: Handle) -> i32;
}

#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtQueryKey(key: Handle, class: u32, data: *mut c_void, size: u32, returned: *mut u32)
    -> i32;
    fn RtlNtStatusToDosError(status: i32) -> u32;
    fn NtOpenKeyEx(key: *mut Handle, access: u32, attributes: *const c_void, options: u32) -> i32;
}

fn valid_sid(sid: &str) -> bool {
    sid.starts_with("S-1-")
        && sid.len() <= 184
        && sid
            .bytes()
            .all(|b| b.is_ascii_digit() || b == b'-' || b == b'S')
}

fn classes_alias_state(args: &Value) -> Result<Value> {
    let sid = args
        .get("sid")
        .and_then(Value::as_str)
        .context("sid required")?;
    if !valid_sid(sid) {
        bail!("Invalid SID");
    }
    let path = wide(&format!("\\Registry\\User\\{sid}\\Software\\Classes"))?;
    let name = UnicodeString {
        length: u16::try_from((path.len() - 1) * 2)?,
        maximum_length: u16::try_from(path.len() * 2)?,
        buffer: path.as_ptr(),
    };
    let attributes = ObjectAttributes {
        length: std::mem::size_of::<ObjectAttributes>() as u32,
        root: ptr::null_mut(),
        name: &name,
        attributes: 0x140,
        security: ptr::null_mut(),
        qos: ptr::null_mut(),
    };
    let mut key = ptr::null_mut();
    let status = unsafe {
        NtOpenKeyEx(
            &mut key,
            0x01020119,
            (&attributes as *const ObjectAttributes).cast(),
            8,
        )
    };
    if status < 0 {
        win32(
            unsafe { RtlNtStatusToDosError(status) } as i32,
            "NtOpenKeyEx Classes alias",
        )?;
    }
    let result = (|| -> Result<Value> {
        let value = key_value(key, "SymbolicLinkValue")?;
        let security = key_security(key)?;
        let time = key_last_write(key)?;
        Ok(json!(format!(
            "{}|security:{}|lastwrite:{}",
            value.as_str().unwrap_or(""),
            security.as_str().context("security encoding")?,
            time.as_i64().context("last write")?
        )))
    })();
    unsafe {
        RegCloseKey(key);
    }
    result
}

fn borrowed_key(args: &Value) -> Result<Handle> {
    // RegistryKeyの寿命は呼出し元が保持し、この関数はhandleを所有・closeしない。
    let raw = args
        .get("handle")
        .and_then(Value::as_u64)
        .context("handle required")?;
    let raw = usize::try_from(raw).context("handle out of range")?;
    if raw == 0 {
        bail!("Null registry handle");
    }
    Ok(raw as Handle)
}

fn win32(error: i32, operation: &str) -> Result<()> {
    if error != 0 {
        return Err(std::io::Error::from_raw_os_error(error)).with_context(|| operation.to_owned());
    }
    Ok(())
}

fn wide(value: &str) -> Result<Vec<u16>> {
    if value.contains('\0') {
        bail!("Embedded NUL");
    }
    Ok(value.encode_utf16().chain(Some(0)).collect())
}

fn key_class(handle: Handle) -> Result<Value> {
    let mut buffer = vec![0u16; 4096];
    let mut length = buffer.len() as u32;
    let error = unsafe {
        RegQueryInfoKeyW(
            handle,
            buffer.as_mut_ptr(),
            &mut length,
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
    };
    win32(error, "RegQueryInfoKeyW")?;
    Ok(json!(String::from_utf16(&buffer[..length as usize])?))
}

fn key_name(handle: Handle) -> Result<Value> {
    unsafe {
        let mut size = 0;
        NtQueryKey(handle, 3, ptr::null_mut(), 0, &mut size);
        if !(4..=131072).contains(&size) {
            bail!("Invalid native key name size");
        }
        let mut buffer = vec![0u8; size as usize];
        let status = NtQueryKey(handle, 3, buffer.as_mut_ptr().cast(), size, &mut size);
        if status < 0 {
            win32(RtlNtStatusToDosError(status) as i32, "NtQueryKey")?;
        }
        let length = u32::from_ne_bytes(buffer[..4].try_into()?) as usize;
        if length % 2 != 0 || length > buffer.len() - 4 {
            bail!("Invalid native key name");
        }
        let chars: Vec<u16> = buffer[4..4 + length]
            .chunks_exact(2)
            .map(|c| u16::from_ne_bytes([c[0], c[1]]))
            .collect();
        Ok(json!(String::from_utf16(&chars)?))
    }
}

fn key_last_write(handle: Handle) -> Result<Value> {
    unsafe {
        let mut basic = [0u8; 4096];
        let mut length = 0;
        let status = NtQueryKey(
            handle,
            0,
            basic.as_mut_ptr().cast(),
            basic.len() as u32,
            &mut length,
        );
        if status < 0 {
            win32(RtlNtStatusToDosError(status) as i32, "NtQueryKey basic")?;
        }
        if length < 8 {
            bail!("Truncated native key information");
        }
        Ok(json!(i64::from_ne_bytes(basic[..8].try_into()?)))
    }
}

fn key_value(handle: Handle, name: &str) -> Result<Value> {
    let name = wide(name)?;
    unsafe {
        let (mut size, mut kind) = (0, 0);
        let error = RegQueryValueExW(
            handle,
            name.as_ptr(),
            ptr::null_mut(),
            &mut kind,
            ptr::null_mut(),
            &mut size,
        );
        if error == 2 {
            return Ok(Value::Null);
        }
        win32(error, "RegQueryValueExW")?;
        if size > 64 * 1024 * 1024 {
            bail!("Registry value exceeds fixture limit");
        }
        let mut bytes = vec![0u8; size as usize];
        win32(
            RegQueryValueExW(
                handle,
                name.as_ptr(),
                ptr::null_mut(),
                &mut kind,
                bytes.as_mut_ptr(),
                &mut size,
            ),
            "RegQueryValueExW",
        )?;
        bytes.truncate(size as usize);
        Ok(json!(format!("{kind}:{}", STANDARD.encode(bytes))))
    }
}

fn key_security_by(handle: Handle, information: u32) -> Result<Value> {
    unsafe {
        let mut size = 0;
        let error = RegGetKeySecurity(handle, information, ptr::null_mut(), &mut size);
        if error != 0 && error != 122 {
            win32(error, "RegGetKeySecurity")?;
        }
        if size > 16 * 1024 * 1024 {
            bail!("Registry security exceeds fixture limit");
        }
        let mut bytes = vec![0u8; size as usize];
        win32(
            RegGetKeySecurity(handle, information, bytes.as_mut_ptr(), &mut size),
            "RegGetKeySecurity",
        )?;
        bytes.truncate(size as usize);
        Ok(json!(STANDARD.encode(bytes)))
    }
}

fn key_security(handle: Handle) -> Result<Value> {
    key_security_by(handle, 0x10000)
}

fn permission_scope(args: &Value) -> Result<()> {
    let machine = args
        .get("machine")
        .and_then(Value::as_bool)
        .context("machine required")?;
    let prefix = args
        .get("prefix")
        .and_then(Value::as_str)
        .context("prefix required")?;
    let path = args
        .get("path")
        .and_then(Value::as_str)
        .context("path required")?;
    let allowed = if machine {
        "SYSTEM\\PrunletE2E\\"
    } else {
        "Software\\PrunletE2E\\"
    };
    if prefix.len() != allowed.len() + 32
        || !prefix
            .get(..allowed.len())
            .is_some_and(|p| p.eq_ignore_ascii_case(allowed))
        || !prefix
            .get(allowed.len()..)
            .is_some_and(|s| uuid::Uuid::parse_str(s).is_ok())
    {
        bail!("Unsafe fixture namespace");
    }
    let path = path.to_lowercase();
    let prefix = prefix.to_lowercase();
    if !path.starts_with(&(prefix.clone() + "-link-probes\\"))
        && !path.starts_with(&(prefix + "\\backup-restore-protected-cli-mcp-key-value-roundtrip\\"))
    {
        bail!("Permission probe escaped dedicated fixture subtree");
    }
    Ok(())
}

fn key_security_reopen(handle: Handle) -> Result<Value> {
    // 元のRegistryKeyのアクセス権とは別に、完全security読取権で開き直す。
    let mut security_handle = ptr::null_mut();
    let empty = [0u16];
    win32(
        unsafe { RegOpenKeyExW(handle, empty.as_ptr(), 0, 0x01020000, &mut security_handle) },
        "RegOpenKeyExW security",
    )?;
    let result = key_security(security_handle);
    unsafe {
        RegCloseKey(security_handle);
    }
    result
}

fn preflight_ktm(view: u32, machine: bool) -> Result<Value> {
    if view != 32 && view != 64 {
        bail!("view must be 32 or 64");
    }
    let parent = if machine { "SYSTEM" } else { "Software" };
    let root = (if machine {
        0x80000002u32
    } else {
        0x80000001u32
    } as i32 as isize) as Handle;
    let description = wide("Prunlet E2E read-only KTM preflight")?;
    let path = wide(parent)?;
    unsafe {
        let transaction = CreateTransaction(
            ptr::null_mut(),
            ptr::null_mut(),
            0,
            0,
            0,
            30000,
            description.as_ptr(),
        );
        if transaction as isize == -1 || transaction.is_null() {
            let error = std::io::Error::last_os_error().raw_os_error().unwrap_or(1);
            return Ok(
                json!({"View":view,"Parent":parent,"Stage":"CreateTransaction","NativeError":error,"RollbackError":0,"Available":false}),
            );
        }
        let transaction = OwnedHandle(transaction);
        let mut key = ptr::null_mut();
        let error = RegOpenKeyTransactedW(
            root,
            path.as_ptr(),
            0,
            0x20019 | if view == 32 { 0x200 } else { 0x100 },
            &mut key,
            transaction.0,
            ptr::null_mut(),
        );
        if !key.is_null() {
            RegCloseKey(key);
        }
        let rollback_error = if RollbackTransaction(transaction.0) == 0 {
            std::io::Error::last_os_error().raw_os_error().unwrap_or(1)
        } else {
            0
        };
        let stage = if error != 0 {
            "RegOpenKeyTransactedW(KEY_READ)"
        } else if rollback_error != 0 {
            "RollbackTransaction"
        } else {
            "complete"
        };
        Ok(
            json!({"View":view,"Parent":parent,"Stage":stage,"NativeError":error,"RollbackError":rollback_error,"Available":error == 0 && rollback_error == 0}),
        )
    }
}

fn create_owned(args: &Value) -> Result<Value> {
    let machine = args
        .get("machine")
        .and_then(Value::as_bool)
        .context("machine required")?;
    let prefix = args
        .get("prefix")
        .and_then(Value::as_str)
        .context("prefix required")?;
    let path = args
        .get("path")
        .and_then(Value::as_str)
        .context("path required")?;
    let allowed = if machine {
        "SYSTEM\\PrunletE2E\\"
    } else {
        "Software\\PrunletE2E\\"
    };
    if prefix.len() != allowed.len() + 32
        || !prefix
            .get(..allowed.len())
            .is_some_and(|p| p.eq_ignore_ascii_case(allowed))
        || !prefix
            .get(allowed.len()..)
            .is_some_and(|s| uuid::Uuid::parse_str(s).is_ok())
    {
        bail!("Unsafe fixture namespace");
    }
    let volatile = args
        .get("volatile")
        .and_then(Value::as_bool)
        .context("volatile required")?;
    let link = args
        .get("link")
        .and_then(Value::as_bool)
        .context("link required")?;
    let allowed_prefix = if volatile {
        format!("{prefix}-link-probes")
    } else {
        format!("{prefix}\\backup-restore-protected-cli-mcp-key-value-roundtrip")
    };
    let lower = path.to_lowercase();
    let base = allowed_prefix.to_lowercase();
    if !(lower == base && volatile || lower.starts_with(&(base + "\\"))) || (!volatile && link) {
        bail!("Key creation escaped dedicated fixture subtree");
    }
    let root = (if machine {
        0x80000002u32
    } else {
        0x80000001u32
    } as i32 as isize) as Handle;
    let path = wide(path)?;
    let class = args
        .get("class")
        .and_then(Value::as_str)
        .map(wide)
        .transpose()?;
    let mut handle = ptr::null_mut();
    let mut disposition = 0;
    let options = if volatile {
        if link { 3 } else { 1 }
    } else {
        0
    };
    let error = unsafe {
        RegCreateKeyExW(
            root,
            path.as_ptr(),
            0,
            class.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            options,
            0xF013F,
            ptr::null(),
            &mut handle,
            &mut disposition,
        )
    };
    win32(error, "RegCreateKeyExW")?;
    if disposition != 1 {
        unsafe {
            RegCloseKey(handle);
        }
        bail!("Fixture collision");
    }
    // 所有権を一度だけPSに渡す。JSON受領失敗時は再送せずprocess終了を待つ。
    Ok(json!(handle as usize as u64))
}

fn open_owned(args: &Value) -> Result<Value> {
    let machine = args
        .get("machine")
        .and_then(Value::as_bool)
        .context("machine required")?;
    let prefix = args
        .get("prefix")
        .and_then(Value::as_str)
        .context("prefix required")?;
    let path = args
        .get("path")
        .and_then(Value::as_str)
        .context("path required")?;
    let view = args
        .get("view")
        .and_then(Value::as_u64)
        .context("view required")?;
    let security = args
        .get("security")
        .and_then(Value::as_bool)
        .context("security required")?;
    let expected = if machine {
        "SYSTEM\\PrunletE2E\\"
    } else {
        "Software\\PrunletE2E\\"
    };
    let suffix = prefix
        .get(expected.len()..)
        .context("Unsafe fixture namespace")?;
    if prefix.len() != expected.len() + 32
        || !prefix
            .get(..expected.len())
            .is_some_and(|p| p.eq_ignore_ascii_case(expected))
        || uuid::Uuid::parse_str(suffix).is_err()
        || (view != 32 && view != 64)
    {
        bail!("Unsafe fixture namespace or view");
    }
    let classes = format!("Software\\Classes\\PrunletE2E_{suffix}");
    let links = format!("{prefix}-link-probes");
    let is_beneath = |base: &str| {
        path.eq_ignore_ascii_case(base)
            || path
                .to_lowercase()
                .starts_with(&(base.to_lowercase() + "\\"))
    };
    if !is_beneath(prefix) && !is_beneath(&links) && !is_beneath(&classes) {
        bail!("Registry open escaped fixture namespace");
    }
    let backing = args.get("backingSid").and_then(Value::as_str);
    let (root_value, actual_path) = if let Some(sid) = backing {
        if !valid_sid(sid) || !is_beneath(&classes) {
            bail!("Invalid Classes backing fixture");
        }
        let rest = path
            .get("Software\\Classes\\".len()..)
            .context("Invalid Classes path")?;
        (0x80000003u32, format!("{sid}_Classes\\{rest}"))
    } else {
        (
            if machine && !is_beneath(&classes) {
                0x80000002u32
            } else {
                0x80000001u32
            },
            path.to_owned(),
        )
    };
    let root = (root_value as i32 as isize) as Handle;
    let wide_path = wide(&actual_path)?;
    let access =
        0x20019 | (if view == 32 { 0x200 } else { 0x100 }) | (if security { 0x1000000 } else { 0 });
    let mut handle = ptr::null_mut();
    let error = unsafe { RegOpenKeyExW(root, wide_path.as_ptr(), 0, access, &mut handle) };
    if error == 2 {
        return Ok(Value::Null);
    }
    win32(error, "RegOpenKeyExW fixture")?;
    // 呼出し元が直ちにSafeRegistryHandleへ所有権を移す。
    Ok(json!(handle as usize as u64))
}

fn low_integrity(args: &Value) -> Result<Value> {
    let machine = args
        .get("machine")
        .and_then(Value::as_bool)
        .context("machine required")?;
    let prefix = args
        .get("prefix")
        .and_then(Value::as_str)
        .context("prefix required")?;
    let path = args
        .get("path")
        .and_then(Value::as_str)
        .context("path required")?;
    let view = args
        .get("view")
        .and_then(Value::as_u64)
        .context("view required")?;
    if view != 32 && view != 64 {
        bail!("Invalid view");
    }
    let expected = if machine {
        "SYSTEM\\PrunletE2E\\"
    } else {
        "Software\\PrunletE2E\\"
    };
    if prefix.len() != expected.len() + 32
        || !prefix
            .get(..expected.len())
            .is_some_and(|p| p.eq_ignore_ascii_case(expected))
        || !prefix
            .get(expected.len()..)
            .is_some_and(|s| uuid::Uuid::parse_str(s).is_ok())
        || !(path.eq_ignore_ascii_case(prefix)
            || path
                .to_lowercase()
                .starts_with(&(prefix.to_lowercase() + "\\")))
    {
        bail!("Low integrity fixture escaped run root");
    }
    let root = (if machine {
        0x80000002u32
    } else {
        0x80000001u32
    } as i32 as isize) as Handle;
    let path = wide(path)?;
    let sddl = wide("S:(ML;;NW;;;LW)")?;
    unsafe {
        let mut descriptor = ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error())
                .context("ConvertStringSecurityDescriptorToSecurityDescriptorW");
        }
        let mut key = ptr::null_mut();
        let error = RegOpenKeyExW(
            root,
            path.as_ptr(),
            0,
            0x80000 | if view == 32 { 0x200 } else { 0x100 },
            &mut key,
        );
        if error != 0 {
            LocalFree(descriptor);
            win32(error, "RegOpenKeyExW low integrity")?;
        }
        let result = RegSetKeySecurity(key, 0x10, descriptor.cast());
        RegCloseKey(key);
        LocalFree(descriptor);
        win32(result, "RegSetKeySecurity low integrity")?;
        Ok(Value::Null)
    }
}

// この probe の所有ハンドルだけを閉じる。借用した RegistryKey は扱わない。
struct OwnedHandle(Handle);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

pub fn dispatch(op: &str, args: &Value) -> Result<Value> {
    match op {
        "registry.class" => key_class(borrowed_key(args)?),
        "registry.name" => key_name(borrowed_key(args)?),
        "registry.lastWrite" => key_last_write(borrowed_key(args)?),
        "registry.enableSecurity" => enable_security(),
        "registry.createOwned" => create_owned(args),
        "registry.openOwned" => open_owned(args),
        "registry.lowIntegrity" => low_integrity(args),
        "registry.classesAliasState" => classes_alias_state(args),
        "registry.value" => key_value(
            borrowed_key(args)?,
            args.get("name")
                .and_then(Value::as_str)
                .context("name required")?,
        ),
        "registry.security" => key_security(borrowed_key(args)?),
        "registry.fixtureDacl" => {
            permission_scope(args)?;
            key_security_by(borrowed_key(args)?, 4)
        }
        "registry.setFixtureDacl" => {
            permission_scope(args)?;
            let handle = borrowed_key(args)?;
            let bytes = STANDARD.decode(
                args.get("base64")
                    .and_then(Value::as_str)
                    .context("base64 required")?,
            )?;
            if bytes.len() < 20 {
                bail!("Truncated fixture security descriptor");
            }
            let information = u32::try_from(
                args.get("information")
                    .and_then(Value::as_u64)
                    .context("information required")?,
            )?;
            if ![4, 0x80000004, 0x20000004].contains(&information) {
                bail!("Invalid fixture DACL information");
            }
            win32(
                unsafe { RegSetKeySecurity(handle, information, bytes.as_ptr()) },
                "RegSetKeySecurity fixture DACL",
            )?;
            Ok(Value::Null)
        }
        "registry.securityReopen" => key_security_reopen(borrowed_key(args)?),
        "registry.preflightKtm" => preflight_ktm(
            u32::try_from(
                args.get("view")
                    .and_then(Value::as_u64)
                    .context("view required")?,
            )?,
            args.get("machine")
                .and_then(Value::as_bool)
                .context("machine required")?,
        ),
        "registry.set" => {
            let handle = borrowed_key(args)?;
            let name = wide(
                args.get("name")
                    .and_then(Value::as_str)
                    .context("name required")?,
            )?;
            let kind = u32::try_from(
                args.get("type")
                    .and_then(Value::as_u64)
                    .context("type required")?,
            )?;
            let data = STANDARD.decode(
                args.get("base64")
                    .and_then(Value::as_str)
                    .context("base64 required")?,
            )?;
            let size = u32::try_from(data.len())?;
            let error =
                unsafe { RegSetValueExW(handle, name.as_ptr(), 0, kind, data.as_ptr(), size) };
            Ok(json!(error))
        }
        _ => bail!("Unknown registry fixture operation: {op}"),
    }
}
