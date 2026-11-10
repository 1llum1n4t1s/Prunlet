//! セッションE2E用の独立したOS観測。製品Coreの計算を期待値に使わない。
use anyhow::{Context, Result, bail, ensure};
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{IgnoredAny, MapAccess, Visitor},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{ffi::c_void, ptr};

type Handle = *mut c_void;
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn GetCurrentThread() -> Handle;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn CloseHandle(handle: Handle) -> i32;
    fn QueryFullProcessImageNameW(
        process: Handle,
        flags: u32,
        path: *mut u16,
        length: *mut u32,
    ) -> i32;
    fn GetProcessTimes(
        process: Handle,
        created: *mut i64,
        exited: *mut i64,
        kernel: *mut i64,
        user: *mut i64,
    ) -> i32;
    fn GetCurrentPackageFullName(length: *mut u32, name: *mut u16) -> i32;
    fn GetPackageFullName(process: Handle, length: *mut u32, name: *mut u16) -> i32;
    fn GetFullPathNameW(
        path: *const u16,
        length: u32,
        buffer: *mut u16,
        file_part: *mut *mut u16,
    ) -> u32;
    fn CompareStringOrdinal(
        first: *const u16,
        first_len: i32,
        second: *const u16,
        second_len: i32,
        ignore_case: i32,
    ) -> i32;
    fn LocalFree(memory: Handle) -> Handle;
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn OpenThreadToken(thread: Handle, access: u32, open_as_self: i32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: u32,
        buffer: *mut c_void,
        length: u32,
        needed: *mut u32,
    ) -> i32;
    fn ConvertSidToStringSidW(sid: *const c_void, string: *mut *mut u16) -> i32;
    fn CreateWellKnownSid(
        kind: u32,
        domain: *const c_void,
        sid: *mut c_void,
        length: *mut u32,
    ) -> i32;
    fn DuplicateToken(token: Handle, level: u32, duplicate: *mut Handle) -> i32;
    fn CheckTokenMembership(token: Handle, sid: *const c_void, member: *mut i32) -> i32;
    fn RegOpenKeyExW(
        root: Handle,
        path: *const u16,
        options: u32,
        access: u32,
        key: *mut Handle,
    ) -> i32;
    fn RegQueryValueExW(
        key: Handle,
        name: *const u16,
        reserved: *mut u32,
        kind: *mut u32,
        data: *mut u8,
        length: *mut u32,
    ) -> i32;
    fn RegCreateKeyExW(
        root: Handle,
        path: *const u16,
        reserved: u32,
        class: *const u16,
        options: u32,
        access: u32,
        security: *const c_void,
        key: *mut Handle,
        disposition: *mut u32,
    ) -> i32;
    fn RegCloseKey(key: Handle) -> i32;
}
#[link(name = "user32")]
unsafe extern "system" {
    fn GetShellWindow() -> Handle;
    fn GetWindowThreadProcessId(window: Handle, pid: *mut u32) -> u32;
}

struct Owned(Handle);
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
struct Key(Handle);
impl Drop for Key {
    fn drop(&mut self) {
        unsafe {
            RegCloseKey(self.0);
        }
    }
}
fn last() -> anyhow::Error {
    std::io::Error::last_os_error().into()
}
fn wide(s: &str) -> Result<Vec<u16>> {
    ensure!(!s.contains('\0'), "Embedded NUL");
    Ok(s.encode_utf16().chain(Some(0)).collect())
}
fn win(error: i32) -> Result<()> {
    if error != 0 {
        return Err(std::io::Error::from_raw_os_error(error).into());
    }
    Ok(())
}
fn process(pid: u32) -> Result<Owned> {
    let h = unsafe { OpenProcess(0x1000, 0, pid) };
    ensure!(!h.is_null(), "OpenProcess: {}", last());
    Ok(Owned(h))
}
fn token(process: Handle) -> Result<Owned> {
    let mut h = ptr::null_mut();
    if unsafe { OpenProcessToken(process, 8, &mut h) } == 0 {
        return Err(last());
    }
    Ok(Owned(h))
}
fn effective_token() -> Result<Owned> {
    let mut h = ptr::null_mut();
    if unsafe { OpenThreadToken(GetCurrentThread(), 0x000a, 1, &mut h) } != 0 {
        return Ok(Owned(h));
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() != Some(1008) {
        return Err(error.into());
    }
    if unsafe { OpenProcessToken(GetCurrentProcess(), 0x000a, &mut h) } == 0 {
        return Err(last());
    }
    Ok(Owned(h))
}
// usize配列でTOKEN_USER内のpointerに必要なalignmentを保証する。
fn field(token: Handle, class: u32) -> Result<Vec<usize>> {
    let mut needed = 0u32;
    unsafe {
        GetTokenInformation(token, class, ptr::null_mut(), 0, &mut needed);
    }
    ensure!(
        needed > 0 && needed <= 1024 * 1024,
        "Invalid token field size"
    );
    let mut buffer = vec![0usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
    if unsafe {
        GetTokenInformation(
            token,
            class,
            buffer.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    } == 0
    {
        return Err(last());
    }
    Ok(buffer)
}
fn bytes(data: &[usize]) -> &[u8] {
    unsafe { std::slice::from_raw_parts(data.as_ptr().cast(), std::mem::size_of_val(data)) }
}
fn u32_at(data: &[usize], offset: usize) -> Result<u32> {
    Ok(u32::from_ne_bytes(
        bytes(data)
            .get(offset..offset + 4)
            .context("Short token field")?
            .try_into()?,
    ))
}
fn owner(token: Handle) -> Result<String> {
    let data = field(token, 1)?;
    let sid = data[0] as *const c_void;
    ensure!(!sid.is_null(), "Missing token SID");
    let mut out = ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut out) } == 0 {
        return Err(last());
    }
    let mut length = 0;
    unsafe {
        while *out.add(length) != 0 {
            length += 1;
        }
    };
    let result = String::from_utf16(unsafe { std::slice::from_raw_parts(out, length) });
    unsafe {
        LocalFree(out.cast());
    }
    Ok(result?)
}
fn admin(token: Handle) -> Result<bool> {
    let mut sid = [0u64; 16];
    let mut length = std::mem::size_of_val(&sid) as u32;
    if unsafe { CreateWellKnownSid(26, ptr::null(), sid.as_mut_ptr().cast(), &mut length) } == 0 {
        return Err(last());
    }
    let mut impersonation = ptr::null_mut();
    if unsafe { DuplicateToken(token, 2, &mut impersonation) } == 0 {
        return Err(last());
    }
    let impersonation = Owned(impersonation);
    let mut member = 0;
    if unsafe { CheckTokenMembership(impersonation.0, sid.as_ptr().cast(), &mut member) } == 0 {
        return Err(last());
    }
    Ok(member != 0)
}
fn token_values(token: Handle) -> Result<(String, String, u32, bool)> {
    let statistics = field(token, 10)?;
    Ok((
        owner(token)?,
        format!(
            "{:08X}:{:08X}",
            u32_at(&statistics, 12)?,
            u32_at(&statistics, 8)?
        ),
        u32_at(&field(token, 12)?, 0)?,
        u32_at(&field(token, 29)?, 0)? != 0,
    ))
}
fn packaged_current() -> bool {
    let mut n = 0;
    unsafe { GetCurrentPackageFullName(&mut n, ptr::null_mut()) != 15700 }
}
fn token_info() -> Result<Value> {
    let t = effective_token()?;
    let (sid, auth, session, app) = token_values(t.0)?;
    Ok(
        json!({"authenticationId":auth,"ownerSid":sid,"windowsSessionId":session,"isAdministrator":admin(t.0)?,"isAppContainer":app,"packaged":packaged_current(),"processId":std::process::id()}),
    )
}
fn process_info(pid: u32) -> Result<Value> {
    let process = process(pid)?;
    let token = token(process.0)?;
    let (sid, auth, session, app) = token_values(token.0)?;
    let mut path = vec![0u16; 32768];
    let mut length = path.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process.0, 0, path.as_mut_ptr(), &mut length) } == 0 {
        return Err(last());
    }
    let mut creation = 0i64;
    let mut exit = 0i64;
    let mut kernel = 0i64;
    let mut user = 0i64;
    if unsafe { GetProcessTimes(process.0, &mut creation, &mut exit, &mut kernel, &mut user) } == 0
    {
        return Err(last());
    }
    let mut n = 0;
    let packaged = unsafe { GetPackageFullName(process.0, &mut n, ptr::null_mut()) != 15700 };
    Ok(
        json!({"ownerSid":sid,"authenticationId":auth,"windowsSessionId":session,"isAdministrator":u32_at(&field(token.0,20)?,0)?!=0,"isAppContainer":app,"packaged":packaged,"path":String::from_utf16(&path[..length as usize])?,"creationFileTime":creation,"creationTicks":creation.checked_add(504_911_232_000_000_000i64).context("Creation time overflow")?,"pid":pid}),
    )
}
fn desktop() -> Result<Value> {
    let hwnd = unsafe { GetShellWindow() };
    ensure!(!hwnd.is_null(), "Desktop shell missing");
    let mut pid = 0;
    ensure!(
        unsafe { GetWindowThreadProcessId(hwnd, &mut pid) } != 0 && pid != 0,
        "Desktop process missing"
    );
    let mut info = process_info(pid)?;
    info["hwnd"] = json!(hwnd as isize as i64);
    Ok(info)
}
fn software_digest() -> Result<Value> {
    let mut key = ptr::null_mut();
    let path = wide("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer")?;
    win(unsafe {
        RegOpenKeyExW(
            0x80000001u32 as i32 as isize as Handle,
            path.as_ptr(),
            0,
            0x20019,
            &mut key,
        )
    })?;
    let key = Key(key);
    let name = wide("ShellState")?;
    let mut kind = 0;
    let mut length = 0;
    win(unsafe {
        RegQueryValueExW(
            key.0,
            name.as_ptr(),
            ptr::null_mut(),
            &mut kind,
            ptr::null_mut(),
            &mut length,
        )
    })?;
    ensure!(length <= 1024 * 1024, "Probe value unexpectedly large");
    let mut data = vec![0u8; length as usize];
    win(unsafe {
        RegQueryValueExW(
            key.0,
            name.as_ptr(),
            ptr::null_mut(),
            &mut kind,
            data.as_mut_ptr(),
            &mut length,
        )
    })?;
    // C# fixtureは最初に確保した配列全体をhashし、返却lengthは別に記録する。
    Ok(json!(format!(
        "{kind}:{length}:{}",
        hex::encode(Sha256::digest(&data))
    )))
}
fn create_key(path: &str, class: &str, run_root: bool) -> Result<Value> {
    const PREFIX: &str = "Software\\PrunletE2E\\";
    ensure!(path.starts_with(PREFIX), "Unsafe fixture scope");
    if run_root {
        let rest = &path[PREFIX.len()..];
        ensure!(
            rest.len() == 32 && uuid::Uuid::parse_str(rest).is_ok(),
            "Unsafe fixture run root"
        );
    } else {
        ensure!(path.split('\\').count() >= 4, "Unsafe fixture scope");
    }
    let path = wide(path)?;
    let class = wide(class)?;
    let mut key = ptr::null_mut();
    let mut disposition = 0;
    win(unsafe {
        RegCreateKeyExW(
            0x80000001u32 as i32 as isize as Handle,
            path.as_ptr(),
            0,
            class.as_ptr(),
            0,
            0xF013F,
            ptr::null(),
            &mut key,
            &mut disposition,
        )
    })?;
    let _key = Key(key);
    ensure!(
        disposition == 1,
        "Fixture collision; existing key was preserved"
    );
    Ok(Value::Null)
}

fn absolute(path: &str) -> Result<String> {
    let mut path = path.replace('/', "\\").trim_end_matches('\\').to_owned();
    if path.len() == 2 {
        path.push('\\');
    }
    let input = wide(&path)?;
    let needed = unsafe { GetFullPathNameW(input.as_ptr(), 0, ptr::null_mut(), ptr::null_mut()) };
    ensure!(needed > 0, "GetFullPathNameW failed: {}", last());
    let mut output = vec![0u16; needed as usize];
    let length =
        unsafe { GetFullPathNameW(input.as_ptr(), needed, output.as_mut_ptr(), ptr::null_mut()) };
    ensure!(
        length > 0 && length < needed,
        "GetFullPathNameW failed: {}",
        last()
    );
    Ok(String::from_utf16(&output[..length as usize])?)
}
// System.Text.JsonのWeb encoder、property順とindentを再現して独立したfingerprintを算出する。
fn dotnet_json(value: &impl Serialize) -> Result<Vec<u8>> {
    let text = serde_json::to_string_pretty(value)?;
    let bytes = text.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'"' {
            out.push(bytes[i] as char);
            i += 1;
            continue;
        }
        let start = i;
        i += 1;
        while i < bytes.len() {
            if bytes[i] == b'\\' {
                i += 2;
                continue;
            }
            if bytes[i] == b'"' {
                break;
            }
            i += 1;
        }
        ensure!(i < bytes.len(), "Malformed serialized JSON");
        let decoded: String = serde_json::from_str(&text[start..=i])?;
        out.push('"');
        for c in decoded.chars() {
            match c {
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                '\u{8}' => out.push_str("\\b"),
                '\u{c}' => out.push_str("\\f"),
                c if (' '..='~').contains(&c)
                    && !matches!(c, '"' | '\'' | '+' | '&' | '<' | '>' | '`') =>
                {
                    out.push(c)
                }
                c => {
                    let mut units = [0; 2];
                    for unit in c.encode_utf16(&mut units) {
                        out.push_str(&format!("\\u{unit:04X}"));
                    }
                }
            }
        }
        out.push('"');
        i += 1;
    }
    Ok(out.replace('\n', "\r\n").into_bytes())
}
#[derive(Serialize)]
struct Pair {
    key: String,
    value: String,
}

// .NETの安定sortは大小文字だけが異なるキーの元順を保持する。
// serde_json::Valueのmap順を用いず、元JSONの列挙順を別途読み取る。
struct OrderedVolumes(Vec<(String, String)>);
impl<'de> Deserialize<'de> for OrderedVolumes {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = OrderedVolumes;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("volume directory object")
            }
            fn visit_map<M: MapAccess<'de>>(
                self,
                mut map: M,
            ) -> std::result::Result<Self::Value, M::Error> {
                let mut items = Vec::new();
                while let Some((key, value)) = map.next_entry::<String, String>()? {
                    items.push((key, value));
                }
                Ok(OrderedVolumes(items))
            }
        }
        d.deserialize_map(V)
    }
}
struct VolumeInput(OrderedVolumes);
impl<'de> Deserialize<'de> for VolumeInput {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = VolumeInput;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("configuration object")
            }
            fn visit_map<M: MapAccess<'de>>(
                self,
                mut map: M,
            ) -> std::result::Result<Self::Value, M::Error> {
                let mut volumes = None;
                while let Some(key) = map.next_key::<String>()? {
                    if key == "volumeRecoveryDirectories" {
                        volumes = Some(map.next_value()?);
                    } else {
                        map.next_value::<IgnoredAny>()?;
                    }
                }
                volumes
                    .map(VolumeInput)
                    .ok_or_else(|| serde::de::Error::missing_field("volumeRecoveryDirectories"))
            }
        }
        d.deserialize_map(V)
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Fingerprint<'a> {
    schema: i32,
    allowed_roots: Vec<Option<&'a str>>,
    backup_directory: String,
    retention_days: i32,
    max_recovery_bytes: i64,
    registry_scope: Option<&'a str>,
    registry_session_file: Option<&'a str>,
    volumes: Vec<Pair>,
}
fn fingerprint(input: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(input)?;
    let string = |key: &str| -> Result<&str> {
        value
            .get(key)
            .and_then(Value::as_str)
            .with_context(|| format!("Missing {key}"))
    };
    let number = |key: &str| -> Result<i64> {
        value
            .get(key)
            .and_then(Value::as_i64)
            .with_context(|| format!("Missing {key}"))
    };
    let allowed_roots = match value.get("allowedRoots") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => a
            .iter()
            .map(|v| match v {
                Value::Null => Ok(None),
                Value::String(s) => Ok(Some(s.as_str())),
                _ => bail!("Invalid allowed root"),
            })
            .collect::<Result<Vec<_>>>()?,
        _ => bail!("Invalid allowed roots"),
    };
    let map: VolumeInput = serde_json::from_str(input)?;
    let mut volumes = Vec::new();
    for (key, value) in map.0.0 {
        volumes.push(Pair {
            key: absolute(&key)?,
            value: absolute(&value)?,
        });
    }
    volumes.sort_by(|a, b| {
        let a: Vec<u16> = a.key.encode_utf16().collect();
        let b: Vec<u16> = b.key.encode_utf16().collect();
        match unsafe {
            CompareStringOrdinal(a.as_ptr(), a.len() as i32, b.as_ptr(), b.len() as i32, 1)
        } {
            1 => std::cmp::Ordering::Less,
            3 => std::cmp::Ordering::Greater,
            _ => std::cmp::Ordering::Equal,
        }
    });
    let registry_session_file = match value
        .get("registrySessionFile")
        .context("Missing registrySessionFile")?
    {
        Value::Null => None,
        Value::String(s) => Some(s.as_str()),
        _ => bail!("Invalid registrySessionFile"),
    };
    let fingerprint = Fingerprint {
        schema: i32::try_from(number("schema")?)?,
        allowed_roots,
        backup_directory: absolute(string("backupDirectory")?)?,
        retention_days: i32::try_from(number("retentionDays")?)?,
        max_recovery_bytes: number("maxRecoveryBytes")?,
        registry_scope: match value
            .get("registryScope")
            .context("Missing registryScope")?
        {
            Value::Null => None,
            Value::String(s) => Some(s),
            _ => bail!("Invalid registryScope"),
        },
        registry_session_file,
        volumes,
    };
    Ok(json!(hex::encode(Sha256::digest(dotnet_json(
        &fingerprint
    )?))))
}

pub fn dispatch(op: &str, args: &Value) -> Result<Value> {
    let string = |name: &str| -> Result<&str> {
        args.get(name)
            .and_then(Value::as_str)
            .with_context(|| format!("Missing {name}"))
    };
    match op {
        "session.tokenInfo" => token_info(),
        "session.packaged" => Ok(json!(packaged_current())),
        "session.softwareDigest" => software_digest(),
        "session.fingerprint" => fingerprint(string("json")?),
        "session.createClass" => create_key(string("path")?, string("class")?, false),
        "session.createRunRoot" => create_key(string("path")?, "Prunlet E2E owned run", true),
        "session.processInfo" => process_info(u32::try_from(
            args.get("pid")
                .and_then(Value::as_u64)
                .context("Missing pid")?,
        )?),
        "session.desktopInfo" => desktop(),
        "session.shellWindow" => Ok(json!(unsafe { GetShellWindow() } as isize as i64)),
        _ => bail!("Unknown session fixture operation"),
    }
}
