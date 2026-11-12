//! 明示的に開始したnative Windowsセッションだけへ接続する。接続後の切断を再送しない。
use super::model::Scope;
use crate::{config::Config, service::Progress};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{cell::RefCell, sync::Arc};

thread_local! { static CONTEXT:RefCell<Option<Scope>>=const {RefCell::new(None)}; }
pub fn current_scope() -> Option<Scope> {
    CONTEXT.with(|v| v.borrow().clone())
}
pub fn is_server_context() -> bool {
    current_scope().is_some()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Descriptor {
    schema: u32,
    pipe_name: String,
    capability: String,
    expires_utc: String,
    server_process_id: u32,
    server_creation_time: i64,
    windows_session_id: u32,
    authentication_id: String,
    executable_sha256: String,
    configuration_sha256: String,
    scope: Scope,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Delete {
    path: String,
    view: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    value_name: Option<String>,
    recursive: bool,
    access_mode: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    operation: String,
    operation_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    delete: Option<Delete>,
    dry_run: bool,
    access_mode: String,
    configuration_sha256: String,
}
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
struct Frame {
    kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    challenge: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scope: Option<Scope>,
    #[serde(skip_serializing_if = "Option::is_none")]
    authentication: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    request: Option<Request>,
    #[serde(skip_serializing_if = "Option::is_none")]
    operation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    elapsed_seconds: f64,
    acquired: bool,
}

// System.Text.JsonのWeb既定encoderと2空白indentを、HMACとfingerprintの境界で保持する。
pub(super) fn dotnet_serialize(value: &impl Serialize) -> Result<Vec<u8>> {
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
    #[cfg(windows)]
    let out = out.replace('\n', "\r\n");
    Ok(out.into_bytes())
}
fn validate(request: &Request, fingerprint: &str) -> Result<()> {
    ensure!(
        request.configuration_sha256 == fingerprint,
        "Registry session configuration or operation identity differs."
    );
    ensure!(
        uuid::Uuid::parse_str(&request.operation_id)
            .is_ok_and(|id| id.simple().to_string() == request.operation_id),
        "Registry session operation identity is invalid."
    );
    ensure!(
        matches!(request.access_mode.as_str(), "normal" | "backupRestore"),
        "Invalid registry accessMode."
    );
    match request.operation.as_str() {
        "delete" => {
            let d = request
                .delete
                .as_ref()
                .context("Missing registry session delete request")?;
            ensure!(
                request.access_mode == "normal",
                "Registry delete has misplaced accessMode."
            );
            super::model::Target::new(&d.path, &d.view, d.value_name.clone(), &d.access_mode)?;
            ensure!(
                !(d.value_name.is_some() && d.recursive),
                "Recursive cannot be combined with valueName."
            );
        }
        "restore" | "reconcile" => {
            ensure!(
                request.delete.is_none() && !request.dry_run,
                "Invalid registry recovery request."
            );
            ensure!(
                request.operation != "reconcile" || request.access_mode == "normal",
                "Reconciliation cannot request backupRestore."
            );
        }
        _ => bail!("Unknown registry session operation."),
    };
    Ok(())
}
fn authenticate(capability: &[u8], challenge: &str, request: &Request) -> Result<String> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use sha2::{Digest, Sha256};
    let nonce = STANDARD.decode(challenge)?;
    ensure!(
        nonce.len() == 32 && capability.len() == 32,
        "Invalid registry session challenge or capability."
    );
    let mut inner = [0x36u8; 64];
    let mut outer = [0x5cu8; 64];
    for (i, b) in capability.iter().enumerate() {
        inner[i] ^= *b;
        outer[i] ^= *b;
    }
    let mut hash = Sha256::new();
    hash.update(inner);
    hash.update(nonce);
    hash.update(dotnet_serialize(request)?);
    let first = hash.finalize();
    let mut hash = Sha256::new();
    hash.update(outer);
    hash.update(first);
    Ok(hex::encode(hash.finalize()))
}

pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    _progress: Option<Progress>,
) -> Result<Value> {
    #[cfg(windows)]
    {
        ensure!(
            command == "registry-session",
            "Unknown registry session command."
        );
        return windows::serve(config, args);
    }
    #[cfg(not(windows))]
    {
        let _ = (config, command, args);
        bail!("Native registry sessions are supported only on Windows.")
    }
}
pub fn route(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    #[cfg(windows)]
    {
        windows::route(config, command, args, progress)
    }
    #[cfg(not(windows))]
    {
        let _ = (config, command, args, progress);
        bail!("Native registry sessions are supported only on Windows.")
    }
}

#[cfg(windows)]
mod windows {
    use super::*;
    use crate::platform::windows::{OwnedHandle, PinnedFile, path, security, wide};
    use base64::{Engine, engine::general_purpose::STANDARD};
    use chrono::{DateTime, Duration, Utc};
    use sha2::{Digest, Sha256};
    use std::{
        ffi::{OsStr, c_void},
        mem::{size_of, zeroed},
        path::Path,
        ptr::{null, null_mut},
        sync::{
            Mutex,
            atomic::{AtomicPtr, Ordering},
        },
        time::Instant,
    };
    use windows_sys::Win32::{
        Foundation::*,
        Security::Authorization::*,
        Security::Cryptography::*,
        Security::*,
        Storage::FileSystem::*,
        System::{Console::*, IO::*, Pipes::*, Threading::*},
    };
    static SERVER: Mutex<()> = Mutex::new(());
    static STOP: AtomicPtr<c_void> = AtomicPtr::new(null_mut());
    const FRAME_LIMIT: usize = 1_048_576;
    struct Capability(Vec<u8>);
    impl Drop for Capability {
        fn drop(&mut self) {
            for byte in &mut self.0 {
                // エラー経路でも最適化で除去されない形で一時秘密値を消す。
                unsafe {
                    std::ptr::write_volatile(byte, 0);
                }
            }
        }
    }
    fn last() -> anyhow::Error {
        std::io::Error::last_os_error().into()
    }
    struct Local(*mut c_void);
    impl Drop for Local {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }
    unsafe fn sid(sid: PSID) -> Result<String> {
        unsafe {
            ensure!(
                !sid.is_null() && IsValidSid(sid) != 0,
                "Invalid session peer SID"
            );
            let mut s = null_mut();
            if ConvertSidToStringSidW(sid, &mut s) == 0 {
                return Err(last());
            }
            let _owner = Local(s.cast());
            let mut n = 0;
            while *s.add(n) != 0 {
                n += 1;
            }
            Ok(String::from_utf16(std::slice::from_raw_parts(s, n))?)
        }
    }
    fn token_info(token: HANDLE, kind: TOKEN_INFORMATION_CLASS) -> Result<Vec<u8>> {
        unsafe {
            let mut n = 0;
            GetTokenInformation(token, kind, null_mut(), 0, &mut n);
            ensure!(
                n > 0 && n <= 65536,
                "Invalid registry session token information"
            );
            let mut b = vec![0; n as usize];
            if GetTokenInformation(token, kind, b.as_mut_ptr().cast(), n, &mut n) == 0 {
                return Err(last());
            }
            Ok(b)
        }
    }
    fn token_identity(token: HANDLE) -> Result<(String, String, u32)> {
        unsafe {
            let b = token_info(token, TokenUser)?;
            let user = std::ptr::read_unaligned(b.as_ptr().cast::<TOKEN_USER>());
            let sid = sid(user.User.Sid)?;
            let b = token_info(token, TokenStatistics)?;
            let stats = std::ptr::read_unaligned(b.as_ptr().cast::<TOKEN_STATISTICS>());
            let auth = format!(
                "{:08X}:{:08X}",
                stats.AuthenticationId.HighPart as u32, stats.AuthenticationId.LowPart
            );
            let session = u32::from_le_bytes(token_info(token, TokenSessionId)?[..4].try_into()?);
            ensure!(
                u32::from_le_bytes(token_info(token, TokenIsAppContainer)?[..4].try_into()?) == 0,
                "AppContainer peers cannot use a native registry session."
            );
            Ok((sid, auth, session))
        }
    }
    struct Peer {
        process: OwnedHandle,
        pid: u32,
        created: i64,
        sid: String,
        auth: String,
        session: u32,
        path: String,
        image: PinnedFile,
        hash: String,
    }
    impl Peer {
        fn new(pid: u32) -> Result<Self> {
            unsafe {
                let process = OwnedHandle::from_raw(OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                    0,
                    pid,
                ))?;
                ensure!(
                    WaitForSingleObject(process.raw(), 0) == WAIT_TIMEOUT,
                    "Session peer exited."
                );
                let (mut created, mut exit, mut kernel, mut user) =
                    (zeroed(), zeroed(), zeroed(), zeroed());
                if GetProcessTimes(
                    process.raw(),
                    &mut created,
                    &mut exit,
                    &mut kernel,
                    &mut user,
                ) == 0
                {
                    return Err(last());
                }
                let created =
                    ((created.dwHighDateTime as i64) << 32) | created.dwLowDateTime as i64;
                let mut text = vec![0; 32768];
                let mut length = text.len() as u32;
                if QueryFullProcessImageNameW(process.raw(), 0, text.as_mut_ptr(), &mut length) == 0
                {
                    return Err(last());
                }
                let image_path =
                    path::absolute(Path::new(&String::from_utf16(&text[..length as usize])?))?;
                let image = PinnedFile::open(&image_path, GENERIC_READ, FILE_SHARE_READ)?;
                ensure!(
                    !image.identity()?.is_reparse() && !image.identity()?.is_directory(),
                    "Session peer executable is not a plain file."
                );
                image.verify_named()?;
                let mut hash = Sha256::new();
                let mut buffer = vec![0u8; 65536];
                loop {
                    let mut count = 0;
                    if ReadFile(
                        image.raw(),
                        buffer.as_mut_ptr(),
                        buffer.len() as u32,
                        &mut count,
                        null_mut(),
                    ) == 0
                    {
                        return Err(last());
                    }
                    if count == 0 {
                        break;
                    }
                    hash.update(&buffer[..count as usize]);
                }
                image.require_unchanged()?;
                let mut token = null_mut();
                if OpenProcessToken(process.raw(), TOKEN_QUERY, &mut token) == 0 {
                    return Err(last());
                }
                let token = OwnedHandle::from_raw(token)?;
                let (sid, auth, session) = token_identity(token.raw())?;
                let result = Self {
                    process,
                    pid,
                    created,
                    sid,
                    auth,
                    session,
                    path: image_path.to_string_lossy().into_owned(),
                    image,
                    hash: hex::encode(hash.finalize()),
                };
                result.alive()?;
                Ok(result)
            }
        }
        fn alive(&self) -> Result<()> {
            ensure!(
                unsafe { WaitForSingleObject(self.process.raw(), 0) } == WAIT_TIMEOUT,
                "Session peer exited or its process identity is unavailable."
            );
            self.image.require_unchanged()?;
            Ok(())
        }
        fn require_same(&self, other: &Self) -> Result<()> {
            self.alive()?;
            other.alive()?;
            ensure!(
                self.sid == other.sid
                    && self.auth == other.auth
                    && self.session == other.session
                    && self.path.eq_ignore_ascii_case(&other.path)
                    && self.hash == other.hash,
                "Registry session requires the same executable and Windows logon."
            );
            Ok(())
        }
    }
    fn peer(pipe: HANDLE, server: bool) -> Result<Peer> {
        unsafe {
            let mut pid = 0;
            let ok = if server {
                GetNamedPipeClientProcessId(pipe, &mut pid)
            } else {
                GetNamedPipeServerProcessId(pipe, &mut pid)
            };
            if ok == 0 || pid == 0 {
                return Err(last());
            }
            Peer::new(pid)
        }
    }
    fn random() -> Result<[u8; 32]> {
        let mut b = [0u8; 32];
        let code = unsafe {
            BCryptGenRandom(
                null_mut(),
                b.as_mut_ptr(),
                32,
                BCRYPT_USE_SYSTEM_PREFERRED_RNG,
            )
        };
        ensure!(
            code >= 0,
            "Cannot create registry session nonce (NTSTATUS {code:#x})"
        );
        Ok(b)
    }
    fn event() -> Result<OwnedHandle> {
        unsafe { OwnedHandle::from_raw(CreateEventW(null(), 1, 0, null())) }
    }
    fn io(handle: HANDLE, buffer: *mut u8, length: u32, write: bool, timeout: u32) -> Result<u32> {
        unsafe {
            let event = event()?;
            let mut ov: OVERLAPPED = zeroed();
            ov.hEvent = event.raw();
            let mut count = 0;
            let ok = if write {
                WriteFile(handle, buffer, length, &mut count, &mut ov)
            } else {
                ReadFile(handle, buffer, length, &mut count, &mut ov)
            };
            if ok != 0 {
                return Ok(count);
            }
            if GetLastError() != ERROR_IO_PENDING {
                return Err(last());
            }
            let wait = WaitForSingleObject(event.raw(), timeout);
            if wait != WAIT_OBJECT_0 {
                CancelIoEx(handle, &ov);
                GetOverlappedResult(handle, &ov, &mut count, 1);
                bail!("Registry session pipe I/O timed out or failed.");
            }
            if GetOverlappedResult(handle, &ov, &mut count, 0) == 0 {
                return Err(last());
            }
            Ok(count)
        }
    }
    fn transfer(handle: HANDLE, bytes: &mut [u8], write: bool, timeout: u32) -> Result<()> {
        let start = Instant::now();
        let mut offset = 0;
        while offset < bytes.len() {
            let remaining = if timeout == INFINITE {
                INFINITE
            } else {
                timeout.saturating_sub(start.elapsed().as_millis().min(u32::MAX as u128) as u32)
            };
            ensure!(remaining > 0, "Registry session pipe timed out.");
            let n = io(
                handle,
                unsafe { bytes.as_mut_ptr().add(offset) },
                (bytes.len() - offset).min(u32::MAX as usize) as u32,
                write,
                remaining,
            )? as usize;
            ensure!(n > 0, "Registry session pipe disconnected.");
            offset += n;
        }
        Ok(())
    }
    fn send(pipe: HANDLE, frame: &Frame) -> Result<()> {
        send_bytes(pipe, &mut encode(frame)?)
    }
    fn encode(frame: &Frame) -> Result<Vec<u8>> {
        let bytes = dotnet_serialize(frame)?;
        ensure!(
            bytes.len() <= FRAME_LIMIT,
            "Registry session response is too large."
        );
        Ok(bytes)
    }
    fn send_bytes(pipe: HANDLE, bytes: &mut [u8]) -> Result<()> {
        let mut header = (bytes.len() as u32).to_le_bytes();
        transfer(pipe, &mut header, true, 15000)?;
        transfer(pipe, bytes, true, 15000)
    }
    fn read(pipe: HANDLE, limit: usize, timeout: u32) -> Result<Frame> {
        let started = Instant::now();
        let mut header = [0u8; 4];
        transfer(pipe, &mut header, false, timeout)?;
        let size = u32::from_le_bytes(header) as usize;
        ensure!(
            size > 0 && size <= limit,
            "Registry session frame exceeds its limit."
        );
        let mut bytes = vec![0; size];
        let remaining = if timeout == INFINITE {
            INFINITE
        } else {
            timeout.saturating_sub(started.elapsed().as_millis().min(u32::MAX as u128) as u32)
        };
        transfer(pipe, &mut bytes, false, remaining)?;
        let value = crate::json::parse_unique(&bytes)?;
        fn depth(v: &Value, n: usize) -> bool {
            n <= 12
                && match v {
                    Value::Object(o) => o.values().all(|v| depth(v, n + 1)),
                    Value::Array(a) => a.iter().all(|v| depth(v, n + 1)),
                    _ => true,
                }
        }
        ensure!(
            depth(&value, 0),
            "Registry session frame exceeds its depth limit."
        );
        Ok(serde_json::from_value(value)?)
    }
    fn verify_pipe(pipe: HANDLE, owner: &str) -> Result<()> {
        unsafe {
            let mut descriptor = null_mut();
            let status = GetSecurityInfo(
                pipe,
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                &mut descriptor,
            );
            ensure!(
                status == 0,
                "Cannot inspect registry session pipe ACL (Win32 {status})."
            );
            let _allocation = Local(descriptor);
            let mut sid_owner = null_mut();
            let mut defaulted = 0;
            ensure!(
                GetSecurityDescriptorOwner(descriptor, &mut sid_owner, &mut defaulted) != 0,
                "Invalid pipe owner"
            );
            ensure!(
                sid(sid_owner)? == owner,
                "Registry session pipe owner differs."
            );
            let mut control = 0;
            let mut revision = 0;
            ensure!(
                GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) != 0
                    && control & SE_DACL_PROTECTED != 0,
                "Registry session pipe DACL is not protected."
            );
            let mut acl = null_mut();
            let mut present = 0;
            ensure!(
                GetSecurityDescriptorDacl(descriptor, &mut present, &mut acl, &mut defaulted) != 0
                    && present != 0
                    && !acl.is_null()
                    && (*acl).AceCount == 1,
                "Registry session pipe must have one private ACE."
            );
            let mut ace = null_mut();
            ensure!(GetAce(acl, 0, &mut ace) != 0, "Invalid pipe ACE");
            let ace = &*ace.cast::<ACCESS_ALLOWED_ACE>();
            ensure!(
                ace.Header.AceType == 0
                    && ace.Header.AceFlags == 0
                    && ace.Mask == FILE_ALL_ACCESS
                    && sid((&ace.SidStart as *const u32).cast_mut().cast())? == owner,
                "Registry session pipe has unexpected permissions."
            );
            Ok(())
        }
    }
    fn create_pipe(name: &str, owner: &str) -> Result<OwnedHandle> {
        unsafe {
            let sddl = wide(OsStr::new(&format!("O:{owner}D:P(A;;FA;;;{owner})")))?;
            let mut descriptor = null_mut();
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut descriptor,
                null_mut(),
            ) == 0
            {
                return Err(last());
            }
            let _allocation = Local(descriptor);
            let attributes = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor,
                bInheritHandle: 0,
            };
            let name = wide(OsStr::new(&format!("\\\\.\\pipe\\{name}")))?;
            let pipe = OwnedHandle::from_raw(CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
                PIPE_REJECT_REMOTE_CLIENTS,
                1,
                65536,
                65536,
                1000,
                &attributes,
            ))?;
            verify_pipe(pipe.raw(), owner)?;
            Ok(pipe)
        }
    }
    fn accept(pipe: HANDLE, stop: HANDLE, timeout: u32) -> Result<bool> {
        unsafe {
            let ready = event()?;
            let mut ov: OVERLAPPED = zeroed();
            ov.hEvent = ready.raw();
            if ConnectNamedPipe(pipe, &mut ov) != 0 {
                return Ok(true);
            }
            let code = GetLastError();
            if code == ERROR_PIPE_CONNECTED {
                return Ok(true);
            }
            ensure!(
                code == ERROR_IO_PENDING,
                "Cannot accept native registry session pipe (Win32 {code})."
            );
            let handles = [ready.raw(), stop];
            let wait = WaitForMultipleObjects(2, handles.as_ptr(), 0, timeout);
            if wait != WAIT_OBJECT_0 {
                CancelIoEx(pipe, &ov);
                let mut count = 0;
                GetOverlappedResult(pipe, &ov, &mut count, 1);
                if wait == WAIT_TIMEOUT || wait == WAIT_OBJECT_0 + 1 {
                    return Ok(false);
                }
                return Err(last());
            }
            let mut count = 0;
            if GetOverlappedResult(pipe, &ov, &mut count, 0) == 0 {
                return Err(last());
            }
            Ok(true)
        }
    }
    fn fingerprint(config: &Config) -> Result<String> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Pair {
            key: String,
            value: String,
        }
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Fingerprint<'a> {
            schema: u32,
            allowed_roots: &'a [String],
            backup_directory: String,
            retention_days: u32,
            max_recovery_bytes: u64,
            registry_scope: &'a str,
            registry_session_file: &'a Option<String>,
            volumes: Vec<Pair>,
        }
        let backup = path::absolute(Path::new(&config.data.backup_directory))?;
        let lease = path::pin_directories(&backup)?;
        let fixed = lease.handles.last().context("Missing backup directory")?;
        let backup = fixed.final_path()?.to_string_lossy().into_owned();
        let mut volumes = Vec::new();
        for (k, v) in &config.data.volume_recovery_directories {
            volumes.push(Pair {
                key: path::absolute(Path::new(k))?.to_string_lossy().into_owned(),
                value: path::absolute(Path::new(v))?.to_string_lossy().into_owned(),
            });
        }
        volumes.sort_by_key(|v| v.key.to_uppercase());
        Ok(hex::encode(Sha256::digest(dotnet_serialize(
            &Fingerprint {
                schema: config.data.schema,
                allowed_roots: &config.data.allowed_roots,
                backup_directory: backup,
                retention_days: config.data.retention_days,
                max_recovery_bytes: config.data.max_recovery_bytes,
                registry_scope: &config.data.registry_scope,
                registry_session_file: &config.data.registry_session_file,
                volumes,
            },
        )?)))
    }
    struct Impersonation;
    impl Drop for Impersonation {
        fn drop(&mut self) {
            unsafe {
                if RevertToSelf() == 0 {
                    std::process::abort();
                }
            }
            CONTEXT.with(|c| *c.borrow_mut() = None);
        }
    }
    fn impersonate(pipe: HANDLE, client: &Peer) -> Result<(Impersonation, OwnedHandle)> {
        unsafe {
            if ImpersonateNamedPipeClient(pipe) == 0 {
                return Err(last());
            }
            let guard = Impersonation;
            let mut raw = null_mut();
            if OpenThreadToken(
                GetCurrentThread(),
                TOKEN_QUERY | TOKEN_DUPLICATE,
                1,
                &mut raw,
            ) == 0
            {
                return Err(last());
            }
            let token = OwnedHandle::from_raw(raw)?;
            let (sid, auth, session) = token_identity(token.raw())?;
            ensure!(
                sid == client.sid && auth == client.auth && session == client.session,
                "Effective client token differs from authenticated Windows logon."
            );
            let level = u32::from_le_bytes(
                token_info(token.raw(), TokenImpersonationLevel)?[..4].try_into()?,
            );
            ensure!(
                level >= SecurityImpersonation as u32,
                "Registry session requires client impersonation."
            );
            let mut raw = null_mut();
            if DuplicateTokenEx(
                token.raw(),
                0x2e,
                null(),
                SecurityImpersonation,
                TokenImpersonation,
                &mut raw,
            ) == 0
            {
                return Err(last());
            }
            let duplicate = OwnedHandle::from_raw(raw)?;
            if SetThreadToken(null(), duplicate.raw()) == 0 {
                return Err(last());
            }
            Ok((guard, duplicate))
        }
    }
    unsafe extern "system" fn cancel(event: u32) -> i32 {
        if matches!(event, CTRL_C_EVENT | CTRL_BREAK_EVENT) {
            let handle = STOP.load(Ordering::Acquire);
            if !handle.is_null() {
                unsafe {
                    SetEvent(handle);
                }
                return 1;
            }
        }
        0
    }
    struct CancelGuard;
    impl Drop for CancelGuard {
        fn drop(&mut self) {
            STOP.store(null_mut(), Ordering::Release);
            unsafe {
                SetConsoleCtrlHandler(Some(cancel), 0);
            }
        }
    }
    pub(super) fn serve(config: &Config, args: &Value) -> Result<Value> {
        let _server = SERVER
            .lock()
            .map_err(|_| anyhow::anyhow!("Registry session server poisoned"))?;
        ensure!(
            config.data.registry_scope == "nativeWindows",
            "registry-session requires nativeWindows configuration."
        );
        ensure!(
            args.get("assertNativeWindows") == Some(&Value::Bool(true)),
            "Explicit --assert-native-windows is required when manually starting the session from a normal Windows desktop."
        );
        let minutes = args
            .get("minutes")
            .and_then(Value::as_i64)
            .context("Session minutes are required")?;
        ensure!(
            (1..=60).contains(&minutes),
            "Session minutes must be between 1 and 60."
        );
        let scope = super::super::native::verify_native_session_context()?;
        scope.validate()?;
        let me = Peer::new(std::process::id())?;
        ensure!(
            scope.owner_sid == me.sid,
            "Native session owner differs from process identity."
        );
        let path = path::absolute(Path::new(
            config
                .data
                .registry_session_file
                .as_deref()
                .context("registrySessionFile is required")?,
        ))?;
        let _directories =
            path::pin_directories(path.parent().context("Session path has no parent")?)?;
        let expires = Utc::now() + Duration::minutes(minutes);
        let capability = Capability(random()?.to_vec());
        let descriptor = Descriptor {
            schema: 1,
            pipe_name: format!("prunlet-registry-{}", uuid::Uuid::new_v4().simple()),
            capability: STANDARD.encode(&capability.0),
            expires_utc: expires.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true),
            server_process_id: me.pid,
            server_creation_time: me.created,
            windows_session_id: me.session,
            authentication_id: me.auth.clone(),
            executable_sha256: me.hash.clone(),
            configuration_sha256: fingerprint(config)?,
            scope: scope.clone(),
        };
        let mut next_pipe = create_pipe(&descriptor.pipe_name, &me.sid)?;
        let file = security::create_private_file(&path)?;
        let fixed = PinnedFile::open(
            &path,
            FILE_READ_ATTRIBUTES | READ_CONTROL,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        )?;
        ensure!(
            fixed.identity()?.links == 1 && !fixed.identity()?.is_reparse(),
            "Session descriptor must be a plain single-link file."
        );
        fixed.verify_named()?;
        security::verify_private_security(file.raw(), false, false)?;
        crate::platform::windows::reject_named_streams(&path)?;
        crate::platform::windows::write_handle(file.raw(), &dotnet_serialize(&descriptor)?)?;
        let stop = event()?;
        STOP.store(stop.raw(), Ordering::Release);
        if unsafe { SetConsoleCtrlHandler(Some(cancel), 1) } == 0 {
            STOP.store(null_mut(), Ordering::Release);
            return Err(last());
        }
        let _cancel = CancelGuard;
        println!(
            "{}",
            serde_json::json!({"status":"registry_session_ready","sessionFile":path,"expiresUtc":descriptor.expires_utc,"scope":scope})
        );
        use std::io::Write;
        std::io::stdout().flush()?;
        while Utc::now() < expires {
            let remaining = (expires - Utc::now())
                .num_milliseconds()
                .max(0)
                .min(u32::MAX as i64) as u32;
            if !accept(next_pipe.raw(), stop.raw(), remaining)? {
                break;
            }
            let pipe = Arc::new(next_pipe);
            let result = (|| -> Result<()> {
                let client = peer(pipe.raw(), true)?;
                me.require_same(&client)?;
                let challenge = STANDARD.encode(random()?);
                send(
                    pipe.raw(),
                    &Frame {
                        kind: "challenge".into(),
                        challenge: Some(challenge.clone()),
                        scope: Some(scope.clone()),
                        ..Default::default()
                    },
                )?;
                let timeout = 15000.min((expires - Utc::now()).num_milliseconds().max(0) as u32);
                let frame = read(pipe.raw(), 65536, timeout)?;
                ensure!(
                    frame.kind == "request",
                    "Expected registry session request frame."
                );
                let request = frame.request.context("Missing registry session request")?;
                validate(&request, &descriptor.configuration_sha256)?;
                let expected = authenticate(&capability.0, &challenge, &request)?;
                let actual = frame
                    .authentication
                    .context("Missing registry session authentication")?;
                ensure!(
                    expected.len() == actual.len()
                        && expected
                            .bytes()
                            .zip(actual.bytes())
                            .fold(0u8, |a, (x, y)| a | (x ^ y))
                            == 0,
                    "Registry session capability authentication failed."
                );
                ensure!(
                    Utc::now() < expires
                        && unsafe { WaitForSingleObject(stop.raw(), 0) } == WAIT_TIMEOUT,
                    "Registry session has expired."
                );
                client.alive()?;
                send(
                    pipe.raw(),
                    &Frame {
                        kind: "accepted".into(),
                        operation_id: Some(request.operation_id.clone()),
                        ..Default::default()
                    },
                )?;
                let value = {
                    let (_impersonation, _token) = impersonate(pipe.raw(), &client)?;
                    let execution_scope = super::super::native::verify_native_session_context()?;
                    ensure!(
                        scope == execution_scope,
                        "Registry execution scope differs from native session scope."
                    );
                    CONTEXT.with(|c| *c.borrow_mut() = Some(scope.clone()));
                    let (command, args) = local_request(&request)?;
                    let progress_pipe = pipe.clone();
                    let progress: Progress = Arc::new(move |value| {
                        let _ = send(
                            progress_pipe.raw(),
                            &Frame {
                                kind: "progress".into(),
                                elapsed_seconds: value
                                    .get("elapsedSeconds")
                                    .and_then(Value::as_f64)
                                    .unwrap_or(0.0),
                                acquired: value
                                    .get("acquired")
                                    .or_else(|| value.get("completed"))
                                    .and_then(Value::as_bool)
                                    .unwrap_or(false),
                                ..Default::default()
                            },
                        );
                    });
                    super::super::execute_local(
                        config,
                        command,
                        &args,
                        Some(progress),
                        Some(scope.clone()),
                    )?
                };
                send(
                    pipe.raw(),
                    &Frame {
                        kind: "result".into(),
                        result: Some(value),
                        ..Default::default()
                    },
                )?;
                Ok(())
            })();
            if let Err(e) = result {
                let _ = send(
                    pipe.raw(),
                    &Frame {
                        kind: "error".into(),
                        error: Some(e.to_string()),
                        ..Default::default()
                    },
                );
            }
            // DisconnectNamedPipeは未読の最終frameを破棄するため使わない。
            // 所有handleのcloseで、既に送った応答をclientが読み終えられるようにする。
            drop(pipe);
            if Utc::now() >= expires
                || unsafe { WaitForSingleObject(stop.raw(), 0) } != WAIT_TIMEOUT
            {
                break;
            }
            next_pipe = create_pipe(&descriptor.pipe_name, &me.sid)?;
        }
        drop(file);
        Ok(serde_json::json!({"status":"registry_session_closed","sessionFile":path}))
    }
    fn local_request(r: &Request) -> Result<(&'static str, Value)> {
        Ok(match r.operation.as_str() {
            "delete" => {
                let d = r.delete.as_ref().context("Missing delete")?;
                let mut v = serde_json::to_value(d)?;
                v["dryRun"] = Value::Bool(r.dry_run);
                v["operationId"] = Value::String(r.operation_id.clone());
                ("registry-delete", v)
            }
            "restore" => (
                "registry-restore",
                serde_json::json!({"operationId":r.operation_id,"accessMode":r.access_mode}),
            ),
            "reconcile" => (
                "registry-reconcile",
                serde_json::json!({"operationId":r.operation_id}),
            ),
            _ => bail!("Unknown native registry operation"),
        })
    }
    pub(super) fn route(
        config: &Config,
        command: &str,
        args: &Value,
        progress: Option<Progress>,
    ) -> Result<Value> {
        for name in ["dryRun", "recursive"] {
            ensure!(
                args.get(name).is_none_or(Value::is_boolean),
                "{name} must be boolean."
            );
        }
        ensure!(
            args.get("accessMode").is_none_or(Value::is_string),
            "accessMode must be a string."
        );
        ensure!(
            !is_server_context(),
            "Native registry session forwarding cannot recurse."
        );
        let operation = match command {
            "registry-delete" => "delete",
            "registry-restore" => "restore",
            "registry-reconcile" => "reconcile",
            _ => bail!("Unsupported native registry session command"),
        };
        let operation_id = if operation == "delete" {
            uuid::Uuid::new_v4().simple().to_string()
        } else {
            args.get("operationId")
                .and_then(Value::as_str)
                .context("operationId is required")?
                .to_owned()
        };
        let delete = if operation == "delete" {
            Some(Delete {
                path: args
                    .get("path")
                    .and_then(Value::as_str)
                    .context("Registry path is required")?
                    .into(),
                view: args
                    .get("view")
                    .and_then(Value::as_str)
                    .context("Registry view is required")?
                    .into(),
                value_name: args
                    .get("valueName")
                    .map(|v| {
                        v.as_str()
                            .map(str::to_owned)
                            .context("valueName must be a string")
                    })
                    .transpose()?,
                recursive: args
                    .get("recursive")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                access_mode: args
                    .get("accessMode")
                    .and_then(Value::as_str)
                    .unwrap_or("normal")
                    .into(),
            })
        } else {
            None
        };
        let request = Request {
            operation: operation.into(),
            operation_id,
            delete,
            dry_run: args.get("dryRun").and_then(Value::as_bool).unwrap_or(false),
            access_mode: if operation == "restore" {
                args.get("accessMode")
                    .and_then(Value::as_str)
                    .unwrap_or("normal")
                    .into()
            } else {
                "normal".into()
            },
            configuration_sha256: fingerprint(config)?,
        };
        let path = path::absolute(Path::new(
            config
                .data
                .registry_session_file
                .as_deref()
                .context("registrySessionFile is required")?,
        ))?;
        let _directories =
            path::pin_directories(path.parent().context("Session path has no parent")?)?;
        // 読取openだけがserverのshare-read handleと共存する。descriptorは接続中も固定する。
        let fixed = PinnedFile::open(
            &path,
            GENERIC_READ | READ_CONTROL,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        )?;
        let identity = fixed.identity()?;
        let mut size = 0i64;
        if unsafe { GetFileSizeEx(fixed.raw(), &mut size) } == 0 {
            return Err(last());
        }
        ensure!(
            !identity.is_reparse()
                && !identity.is_directory()
                && identity.links == 1
                && size > 0
                && size <= 16384,
            "Registry session descriptor must be a plain single-link file of valid size."
        );
        fixed.verify_named()?;
        security::verify_private_security(fixed.raw(), false, false)?;
        crate::platform::windows::reject_named_streams(&path)?;
        let mut bytes = vec![0u8; size as usize];
        let mut offset = 0;
        while offset < bytes.len() {
            let mut count = 0;
            if unsafe {
                ReadFile(
                    fixed.raw(),
                    bytes[offset..].as_mut_ptr(),
                    (bytes.len() - offset) as u32,
                    &mut count,
                    null_mut(),
                )
            } == 0
            {
                return Err(last());
            }
            ensure!(count > 0, "Truncated native registry descriptor");
            offset += count as usize;
        }
        fixed.require_unchanged()?;
        let value = crate::json::parse_unique(&bytes)?;
        let descriptor: Descriptor = serde_json::from_value(value)?;
        descriptor.scope.validate()?;
        validate(&request, &descriptor.configuration_sha256)?;
        let me = Peer::new(std::process::id())?;
        let expiry = DateTime::parse_from_rfc3339(&descriptor.expires_utc)?.with_timezone(&Utc);
        ensure!(
            descriptor.schema == 1
                && descriptor.scope.owner_sid == me.sid
                && descriptor.authentication_id == me.auth
                && descriptor.windows_session_id == me.session
                && descriptor.executable_sha256 == me.hash
                && descriptor.server_process_id > 0
                && descriptor.server_creation_time > 0
                && regex::Regex::new(r"\Aprunlet-registry-[0-9a-f]{32}\z")?
                    .is_match(&descriptor.pipe_name)
                && expiry > Utc::now()
                && expiry <= Utc::now() + Duration::minutes(61),
            "Registry session is expired or its scope, executable, or Windows logon differs."
        );
        let capability = Capability(STANDARD.decode(&descriptor.capability)?);
        ensure!(
            capability.0.len() == 32,
            "Registry session capability has an invalid size."
        );
        let pipe = connect(&descriptor.pipe_name)?;
        exchange(
            pipe.raw(),
            &me,
            &descriptor,
            &capability.0,
            &request,
            progress,
        )
    }

    #[derive(Debug)]
    struct Rejected(String);
    impl std::fmt::Display for Rejected {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(&self.0)
        }
    }
    impl std::error::Error for Rejected {}

    fn safe_cause(
        error: &anyhow::Error,
        capability: Option<&[u8]>,
        challenge: Option<&str>,
    ) -> String {
        let mut cause = format!("{error:#}");
        if let Some(capability) = capability {
            cause = cause.replace(&STANDARD.encode(capability), "[redacted capability]");
        }
        if let Some(challenge) = challenge.filter(|s| !s.is_empty()) {
            cause = cause.replace(challenge, "[redacted challenge]");
        }
        cause.chars().take(2048).collect()
    }
    fn communication_failure(
        error: anyhow::Error,
        operation_id: Option<&str>,
        capability: Option<&[u8]>,
        challenge: Option<&str>,
    ) -> anyhow::Error {
        let cause = safe_cause(&error, capability, challenge);
        let message = match operation_id {
            Some(id) => format!(
                "Native registry session communication failed. Operation ID: {id}. Outcome may be unknown; do not repeat deletion. Use registry-reconcile with this ID. {cause}"
            ),
            None => format!(
                "Native registry session communication failed before operation transmission; no registry operation was sent. {cause}"
            ),
        };
        // CLI/MCPの通常rendererは外側の文だけを表示するため、原因も同じ文へ保持する。
        error.context(message)
    }

    fn connect(pipe_name: &str) -> Result<OwnedHandle> {
        (|| -> Result<OwnedHandle> {
            let name = wide(OsStr::new(&format!("\\\\.\\pipe\\{}", pipe_name)))?;
            let start = Instant::now();
            loop {
                let handle = unsafe {
                    CreateFileW(
                        name.as_ptr(),
                        GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
                        0,
                        null(),
                        OPEN_EXISTING,
                        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IMPERSONATION,
                        null_mut(),
                    )
                };
                if handle != INVALID_HANDLE_VALUE {
                    return unsafe { OwnedHandle::from_raw(handle) };
                }
                let code = unsafe { GetLastError() };
                if code != ERROR_PIPE_BUSY && code != ERROR_FILE_NOT_FOUND {
                    return Err(last());
                }
                let remaining = 5000u32
                    .saturating_sub(start.elapsed().as_millis().min(u32::MAX as u128) as u32);
                ensure!(
                    remaining > 0,
                    "Timed out connecting native registry session"
                );
                if unsafe { WaitNamedPipeW(name.as_ptr(), remaining) } == 0 {
                    return Err(last());
                }
            }
        })()
        .map_err(|error| communication_failure(error, None, None, None))
    }

    fn exchange(
        pipe: HANDLE,
        me: &Peer,
        descriptor: &Descriptor,
        capability: &[u8],
        request: &Request,
        progress: Option<Progress>,
    ) -> Result<Value> {
        verify_pipe(pipe, &me.sid)?;
        let server = peer(pipe, false)?;
        me.require_same(&server)?;
        ensure!(
            server.pid == descriptor.server_process_id
                && server.created == descriptor.server_creation_time,
            "Registry session server process differs from the capability owner."
        );
        let challenge = read(pipe, FRAME_LIMIT, 15000)
            .map_err(|error| communication_failure(error, None, Some(capability), None))?;
        ensure!(
            challenge.kind == "challenge"
                && challenge.challenge.is_some()
                && challenge.scope.as_ref() == Some(&descriptor.scope),
            "Registry session challenge or execution scope differs from the capability file."
        );
        let authentication = authenticate(
            capability,
            challenge
                .challenge
                .as_deref()
                .context("Missing registry session challenge")?,
            request,
        )?;
        let mut bytes = encode(&Frame {
            kind: "request".into(),
            request: Some(request.clone()),
            authentication: Some(authentication),
            ..Default::default()
        })?;
        // 先頭のrequest byteを書き始める境界から、応答喪失は結果不明として扱う。
        let result = (|| -> Result<Value> {
            send_bytes(pipe, &mut bytes)?;
            let mut accepted = false;
            loop {
                let frame = read(pipe, FRAME_LIMIT, INFINITE)?;
                match frame.kind.as_str() {
                    "accepted"
                        if !accepted
                            && frame.operation_id.as_deref() == Some(&request.operation_id) =>
                    {
                        accepted = true
                    }
                    "progress" if accepted => {
                        ensure!(
                            frame.elapsed_seconds.is_finite() && frame.elapsed_seconds >= 0.0,
                            "Invalid native registry progress"
                        );
                        if let Some(progress) = &progress {
                            progress(
                                serde_json::json!({"elapsedSeconds":frame.elapsed_seconds,"acquired":frame.acquired,"message":if frame.acquired{"Recovery lock acquired."}else{"Waiting for recovery lock."}}),
                            );
                        }
                    }
                    "result" if accepted => {
                        return frame.result.context("Empty registry session result");
                    }
                    "error" if !accepted => {
                        let rejection = anyhow::anyhow!(frame.error.unwrap_or_else(|| {
                            "Registry session rejected the request.".into()
                        }),);
                        return Err(Rejected(safe_cause(
                            &rejection,
                            Some(capability),
                            challenge.challenge.as_deref(),
                        ))
                        .into());
                    }
                    "error" => bail!(
                        "{}",
                        frame
                            .error
                            .as_deref()
                            .unwrap_or("Registry session failed after acceptance.")
                    ),
                    _ => bail!("Unexpected registry session response"),
                }
            }
        })();
        if result
            .as_ref()
            .err()
            .is_some_and(|error| error.is::<Rejected>())
        {
            return result;
        }
        result.map_err(|error| {
            communication_failure(
                error,
                Some(&request.operation_id),
                Some(capability),
                challenge.challenge.as_deref(),
            )
        })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        const CLI_CHILD: &str = "registry::session::windows::tests::session_cli_error_child";
        #[test]
        #[ignore = "Only the owned session CLI error-type test supplies its private configuration"]
        fn session_cli_error_child() -> Result<()> {
            let path =
                std::path::PathBuf::from(std::env::var("PRUNLET_SESSION_ERROR_CHILD_CONFIG")?);
            // 親テストが外部TEMPへ作った設定だけを受け付ける（親側と同じ外部判定を使う）。
            let path = crate::platform::windows::path::external_verification_path(&path)
                .context("Private external CLI fixture required")?;
            let parent = path.parent().context("Missing CLI fixture parent")?;
            ensure!(
                parent
                    .file_name()
                    .and_then(|s| s.to_str())
                    .is_some_and(
                        |s| regex::Regex::new(r"\Asession-cli-errors-[0-9a-f]{32}\z")
                            .unwrap()
                            .is_match(s)
                    ),
                "Invalid owned CLI fixture"
            );
            let config = Config::load(&path)?;
            ensure!(
                config.data.registry_scope == "nativeWindows",
                "CLI error probe must route exclusively to the session boundary"
            );
            let args = [
                "--config",
                path.to_str().context("Invalid config path")?,
                "registry-delete",
                "--dry-run",
                "--view",
                "64",
                "--value-name=sentinel",
                "--",
                "HKEY_CURRENT_USER\\Software\\PrunletE2E\\00000000000000000000000000000000\\not-executed",
            ];
            std::process::exit(crate::cli::run(
                args.into_iter().map(Into::into).collect(),
                crate::cli::Host::Cli,
            ));
        }

        fn pipe_fixture(name: &str, owner: &str, allow_dacl_write: bool) -> Result<OwnedHandle> {
            if !allow_dacl_write {
                return create_pipe(name, owner);
            }
            unsafe {
                let sddl = wide(OsStr::new(&format!("O:{owner}D:P(A;;FA;;;{owner})")))?;
                let mut sd = null_mut();
                ensure!(
                    ConvertStringSecurityDescriptorToSecurityDescriptorW(
                        sddl.as_ptr(),
                        1,
                        &mut sd,
                        null_mut()
                    ) != 0,
                    "Cannot construct private pipe fixture"
                );
                let _sd = Local(sd);
                let attributes = SECURITY_ATTRIBUTES {
                    nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                    lpSecurityDescriptor: sd,
                    bInheritHandle: 0,
                };
                let name = wide(OsStr::new(&format!("\\\\.\\pipe\\{name}")))?;
                OwnedHandle::from_raw(CreateNamedPipeW(
                    name.as_ptr(),
                    PIPE_ACCESS_DUPLEX
                        | FILE_FLAG_FIRST_PIPE_INSTANCE
                        | FILE_FLAG_OVERLAPPED
                        | WRITE_DAC,
                    PIPE_REJECT_REMOTE_CLIENTS,
                    1,
                    65536,
                    65536,
                    1000,
                    &attributes,
                ))
            }
        }

        #[test]
        fn session_cli_json_error_types_preserve_causes() -> Result<()> {
            use std::process::{Command, Stdio};
            let me = Peer::new(std::process::id())?;
            // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
            let temp = path::external_verification_path(&std::env::temp_dir())?;
            let _pins = path::pin_directories(&temp)?;
            let root = temp.join(format!(
                "session-cli-errors-{}",
                uuid::Uuid::new_v4().simple()
            ));
            drop(crate::platform::windows::security::create_private_directory(&root)?);
            let metadata = root.join("metadata");
            drop(crate::platform::windows::security::create_private_directory(&metadata)?);
            let mut data = crate::config::ConfigData::default();
            data.backup_directory = metadata.to_string_lossy().into();
            data.registry_scope = "nativeWindows".into();
            data.registry_session_file =
                Some(root.join("descriptor.json").to_string_lossy().into());
            let config = Config {
                path: root.join("config.json"),
                data,
            };
            let config_handle =
                crate::platform::windows::security::create_private_file(&config.path)?;
            crate::platform::windows::write_handle(
                config_handle.raw(),
                &serde_json::to_vec(&config.data)?,
            )?;
            drop(config_handle);
            let mut evidence = vec![];
            for case in ["offline", "access-denied", "broken-pipe", "malformed-json"] {
                let ship = std::env::var_os("PRUNLET_SESSION_CANDIDATE")
                    .filter(|_| matches!(case, "offline" | "access-denied"));
                let executable = ship
                    .clone()
                    .map(std::path::PathBuf::from)
                    .unwrap_or(std::env::current_exe()?);
                let hash = hex::encode(Sha256::digest(crate::platform::windows::read_plain_file(
                    &executable,
                    512 * 1024 * 1024,
                    false,
                )?));
                let name = format!("prunlet-registry-{}", uuid::Uuid::new_v4().simple());
                let descriptor = Descriptor {
                    schema: 1,
                    pipe_name: name.clone(),
                    capability: STANDARD.encode([41u8; 32]),
                    expires_utc: (Utc::now() + Duration::minutes(1)).to_rfc3339(),
                    server_process_id: me.pid,
                    server_creation_time: me.created,
                    windows_session_id: me.session,
                    authentication_id: me.auth.clone(),
                    executable_sha256: hash.clone(),
                    configuration_sha256: fingerprint(&config)?,
                    scope: Scope {
                        kind: "nativeWindows".into(),
                        machine_id: "a".repeat(64),
                        owner_sid: me.sid.clone(),
                    },
                };
                let descriptor_path =
                    Path::new(config.data.registry_session_file.as_ref().unwrap());
                // 各要求ごとに別のprivate descriptorへ固定する。
                let descriptor_path =
                    descriptor_path.with_file_name(format!("descriptor-{case}.json"));
                let mut selected = config.clone();
                selected.data.registry_session_file =
                    Some(descriptor_path.to_string_lossy().into());
                let selected_path = root.join(format!("config-{case}.json"));
                selected.path = selected_path.clone();
                let mut descriptor = descriptor;
                descriptor.configuration_sha256 = fingerprint(&selected)?;
                for (path, bytes) in [
                    (&selected_path, serde_json::to_vec(&selected.data)?),
                    (&descriptor_path, dotnet_serialize(&descriptor)?),
                ] {
                    let handle = crate::platform::windows::security::create_private_file(path)?;
                    crate::platform::windows::write_handle(handle.raw(), &bytes)?;
                }
                let (finished, finish) = std::sync::mpsc::sync_channel(1);
                let server = if case != "offline" {
                    let sid = me.sid.clone();
                    let (ready, listening) = std::sync::mpsc::sync_channel(1);
                    let server = std::thread::spawn(move || -> Result<()> {
                        let pipe = pipe_fixture(&name, &sid, case == "access-denied")?;
                        if case == "access-denied" {
                            unsafe {
                                let sddl = wide(OsStr::new(&format!(
                                    "O:{sid}D:P(D;;GRGW;;;{sid})(A;;RC;;;{sid})"
                                )))?;
                                let mut sd = null_mut();
                                ensure!(
                                    ConvertStringSecurityDescriptorToSecurityDescriptorW(
                                        sddl.as_ptr(),
                                        1,
                                        &mut sd,
                                        null_mut()
                                    ) != 0,
                                    "Cannot construct private pipe denial"
                                );
                                let _sd = Local(sd);
                                ensure!(
                                    SetKernelObjectSecurity(
                                        pipe.raw(),
                                        DACL_SECURITY_INFORMATION,
                                        sd
                                    ) != 0,
                                    "Cannot set private pipe denial (Win32 {})",
                                    GetLastError()
                                );
                            }
                            ready
                                .send(())
                                .map_err(|_| anyhow::anyhow!("CLI fixture receiver exited"))?;
                            // open自体の拒否なのでacceptせず、client終了までprivate pipeだけを保持する。
                            finish.recv_timeout(std::time::Duration::from_secs(15))?;
                            return Ok(());
                        }
                        ready
                            .send(())
                            .map_err(|_| anyhow::anyhow!("CLI fixture receiver exited"))?;
                        let stop = event()?;
                        ensure!(
                            accept(pipe.raw(), stop.raw(), 5000)?,
                            "CLI fixture accept timed out"
                        );
                        if case == "malformed-json" {
                            send_bytes(pipe.raw(), &mut [b'{'])?;
                            let mut byte = 0;
                            let count = io(pipe.raw(), &mut byte, 1, false, 5000).unwrap_or(0);
                            ensure!(
                                count == 0,
                                "Malformed challenge unexpectedly received operation bytes"
                            );
                        } else {
                            send(
                                pipe.raw(),
                                &Frame {
                                    kind: "challenge".into(),
                                    challenge: Some(STANDARD.encode([7u8; 32])),
                                    scope: Some(Scope {
                                        kind: "nativeWindows".into(),
                                        machine_id: "a".repeat(64),
                                        owner_sid: sid,
                                    }),
                                    ..Default::default()
                                },
                            )?;
                            let frame = read(pipe.raw(), FRAME_LIMIT, 5000)?;
                            ensure!(frame.kind == "request", "CLI did not transmit request");
                        }
                        Ok(())
                    });
                    if let Err(error) = listening.recv_timeout(std::time::Duration::from_secs(5)) {
                        server.join().map_err(|_| {
                            anyhow::anyhow!("CLI fixture server panicked before readiness")
                        })??;
                        return Err(error.into());
                    }
                    Some(server)
                } else {
                    None
                };
                let mut command = Command::new(&executable);
                if ship.is_some() {
                    command.args(["--config",selected_path.to_str().unwrap(),"registry-delete","--dry-run","--view","64","--value-name=sentinel","--","HKEY_CURRENT_USER\\Software\\PrunletE2E\\00000000000000000000000000000000\\not-executed"]);
                } else {
                    command
                        .args([
                            "--exact",
                            CLI_CHILD,
                            "--ignored",
                            "--nocapture",
                            "--test-threads=1",
                        ])
                        .env("PRUNLET_SESSION_ERROR_CHILD_CONFIG", &selected_path);
                }
                let output = command
                    .stdin(Stdio::null())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .output()?;
                let _ = finished.send(());
                if let Some(server) = server {
                    server
                        .join()
                        .map_err(|_| anyhow::anyhow!("CLI pipe fixture panicked"))??;
                }
                let stdout = String::from_utf8(output.stdout)?;
                let value: Value = stdout
                    .lines()
                    .filter_map(|line| {
                        line.find('{')
                            .and_then(|start| serde_json::from_str::<Value>(&line[start..]).ok())
                    })
                    .find(|v| v.get("error").is_some())
                    .context(format!("CLI JSON error missing: {stdout}"))?;
                let expected = match case {
                    "access-denied" => "UnauthorizedAccessException",
                    "malformed-json" => "JsonException",
                    _ => "IOException",
                };
                ensure!(
                    output.status.code() == Some(1) && value["type"] == expected,
                    "{case}: {value}"
                );
                let error = value["error"].as_str().unwrap();
                ensure!(
                    error.contains(if case == "malformed-json" {
                        "EOF"
                    } else {
                        "os error"
                    }),
                    "CLI source cause missing: {value}"
                );
                ensure!(
                    error.contains("Outcome may be unknown") == (case == "broken-pipe"),
                    "CLI transmission boundary differs: {value}"
                );
                evidence.push(serde_json::json!({"case":case,"shippingCli":ship.is_some(),"executable":executable,"sha256":hash,"json":value,"exitCode":output.status.code(),"registryExecuted":false}));
            }
            eprintln!(
                "{}",
                serde_json::json!({"actualChildCliEntryPoint":true,"retainedPrivateFixture":root,"cases":evidence})
            );
            Ok(())
        }

        // 実pipeで境界ごとに切断する。レジストリ操作やnative scopeの成功は代替しない。
        #[test]
        fn session_handshake_guards_and_transmitted_disconnect_are_distinct() -> Result<()> {
            let me = Peer::new(std::process::id())?;
            let mut evidence = vec![];
            for case in [
                "peer",
                "scope",
                "header-close",
                "sent-close",
                "accepted-close",
                "rejected",
                "accepted-error",
                "effect-error",
                "result-write-fail",
                "bad-challenge",
            ] {
                let name = format!("prunlet-registry-{}", uuid::Uuid::new_v4().simple());
                let scope = Scope {
                    kind: "nativeWindows".into(),
                    machine_id: "a".repeat(64),
                    owner_sid: me.sid.clone(),
                };
                let mut descriptor = Descriptor {
                    schema: 1,
                    pipe_name: name.clone(),
                    capability: STANDARD.encode([42u8; 32]),
                    expires_utc: (Utc::now() + Duration::minutes(1)).to_rfc3339(),
                    server_process_id: me.pid,
                    server_creation_time: me.created,
                    windows_session_id: me.session,
                    authentication_id: me.auth.clone(),
                    executable_sha256: me.hash.clone(),
                    configuration_sha256: "c".repeat(64),
                    scope: scope.clone(),
                };
                if case == "peer" {
                    descriptor.server_creation_time += 1;
                }
                let request = Request {
                    operation: "delete".into(),
                    operation_id: uuid::Uuid::new_v4().simple().to_string(),
                    delete: Some(Delete {
                        path: "HKEY_CURRENT_USER\\Software\\PrunletE2E\\not-executed".into(),
                        view: "64".into(),
                        value_name: Some("sentinel".into()),
                        recursive: false,
                        access_mode: "normal".into(),
                    }),
                    dry_run: false,
                    access_mode: "normal".into(),
                    configuration_sha256: descriptor.configuration_sha256.clone(),
                };
                let expected_id = request.operation_id.clone();
                let (ready, listening) = std::sync::mpsc::sync_channel(1);
                let server = std::thread::spawn(
                    move || -> Result<(usize, bool, Option<std::path::PathBuf>)> {
                        let pipe = create_pipe(&name, &scope.owner_sid)?;
                        ready
                            .send(())
                            .map_err(|_| anyhow::anyhow!("Test client exited"))?;
                        let stop = event()?;
                        ensure!(
                            accept(pipe.raw(), stop.raw(), 5000)?,
                            "Test pipe accept timed out"
                        );
                        if case == "bad-challenge" {
                            send_bytes(pipe.raw(), &mut [b'{'])?;
                        } else if case != "peer" {
                            let mut challenge_scope = scope;
                            if case == "scope" {
                                challenge_scope.machine_id = "b".repeat(64);
                            }
                            send(
                                pipe.raw(),
                                &Frame {
                                    kind: "challenge".into(),
                                    challenge: Some(STANDARD.encode([7u8; 32])),
                                    scope: Some(challenge_scope),
                                    ..Default::default()
                                },
                            )?;
                        }
                        if matches!(case, "peer" | "scope" | "bad-challenge") {
                            let mut byte = 0;
                            let count = io(pipe.raw(), &mut byte, 1, false, 5000).unwrap_or(0);
                            ensure!(
                                count == 0,
                                "Pre-transmission rejection sent operation bytes"
                            );
                            return Ok((0, false, None));
                        }
                        if case == "header-close" {
                            let mut header = [0u8; 4];
                            transfer(pipe.raw(), &mut header, false, 5000)?;
                            ensure!(u32::from_le_bytes(header) > 0, "Empty transmitted request");
                            return Ok((4, false, None));
                        }
                        let frame = read(pipe.raw(), FRAME_LIMIT, 5000)?;
                        let received = frame.request.context("Test server received no request")?;
                        ensure!(
                            frame.kind == "request" && received.operation_id == expected_id,
                            "Test request identity differs"
                        );
                        ensure!(
                            frame.authentication
                                == Some(authenticate(
                                    &[42u8; 32],
                                    &STANDARD.encode([7u8; 32]),
                                    &received
                                )?),
                            "Test request was not authenticated"
                        );
                        let accepted = matches!(
                            case,
                            "accepted-close"
                                | "accepted-error"
                                | "effect-error"
                                | "result-write-fail"
                        );
                        if accepted {
                            send(
                                pipe.raw(),
                                &Frame {
                                    kind: "accepted".into(),
                                    operation_id: Some(received.operation_id),
                                    ..Default::default()
                                },
                            )?;
                        }
                        let marker = if matches!(case, "effect-error" | "result-write-fail") {
                            // 外部（リポジトリとCodex homeの外）のTEMPだけをmarker置き場に使う。
                            let temp = path::external_verification_path(&std::env::temp_dir())?;
                            let _pins = path::pin_directories(&temp)?;
                            let marker = temp.join(format!(
                                "session-effect-{}.marker",
                                uuid::Uuid::new_v4().simple()
                            ));
                            let handle =
                                crate::platform::windows::security::create_private_file(&marker)?;
                            crate::platform::windows::write_handle(
                                handle.raw(),
                                b"effect-sentinel",
                            )?;
                            ensure!(
                                unsafe { FlushFileBuffers(handle.raw()) } != 0,
                                "Cannot flush effect marker"
                            );
                            Some(marker)
                        } else {
                            None
                        };
                        if matches!(case, "rejected" | "accepted-error" | "effect-error") {
                            send(
                                pipe.raw(),
                                &Frame {
                                    kind: "error".into(),
                                    error: Some(if case == "effect-error" {
                                        format!(
                                            "Native worker fault after effect marker; capability={} challenge={}",
                                            STANDARD.encode([42u8; 32]),
                                            STANDARD.encode([7u8; 32])
                                        )
                                    } else {
                                        "SeSecurityPrivilege test-only explicit rejection".into()
                                    }),
                                    ..Default::default()
                                },
                            )?;
                        }
                        if case == "result-write-fail" {
                            let bytes = encode(&Frame {
                                kind: "result".into(),
                                result: Some(
                                    serde_json::json!({"operationId":expected_id,"marker":marker}),
                                ),
                                ..Default::default()
                            })?;
                            let mut header = (bytes.len() as u32).to_le_bytes();
                            transfer(pipe.raw(), &mut header, true, 5000)?;
                            let mut prefix = bytes[..bytes.len() / 2].to_vec();
                            transfer(pipe.raw(), &mut prefix, true, 5000)?;
                        }
                        Ok((1, accepted, marker))
                    },
                );
                listening.recv_timeout(std::time::Duration::from_secs(5))?;
                let client = connect(&descriptor.pipe_name)?;
                let result = exchange(client.raw(), &me, &descriptor, &[42u8; 32], &request, None);
                drop(client);
                let (observed, accepted, marker) = server
                    .join()
                    .map_err(|_| anyhow::anyhow!("Test pipe server panicked"))??;
                let error = result
                    .expect_err("Fault injection unexpectedly succeeded")
                    .to_string();
                let unknown = error.contains("Outcome may be unknown");
                if case == "peer" {
                    assert_eq!(
                        error,
                        "Registry session server process differs from the capability owner."
                    );
                } else if case == "scope" {
                    assert_eq!(
                        error,
                        "Registry session challenge or execution scope differs from the capability file."
                    );
                } else if case == "bad-challenge" {
                    assert!(
                        error.contains("before operation transmission") && error.contains("EOF"),
                        "{error}"
                    );
                } else if case == "rejected" {
                    assert_eq!(error, "SeSecurityPrivilege test-only explicit rejection");
                } else {
                    assert!(
                        unknown
                            && error.contains(&request.operation_id)
                            && error.contains("do not repeat deletion")
                            && error.contains("registry-reconcile"),
                        "{case}: {error}"
                    );
                }
                assert_eq!(
                    unknown,
                    matches!(
                        case,
                        "header-close"
                            | "sent-close"
                            | "accepted-close"
                            | "accepted-error"
                            | "effect-error"
                            | "result-write-fail"
                    )
                );
                if case == "effect-error" {
                    assert!(
                        error.contains("Native worker fault after effect marker")
                            && error.contains("[redacted capability]")
                            && error.contains("[redacted challenge]")
                    );
                    assert!(
                        !error.contains(&STANDARD.encode([42u8; 32]))
                            && !error.contains(&STANDARD.encode([7u8; 32]))
                    );
                }
                if let Some(marker) = &marker {
                    assert_eq!(std::fs::read(marker)?, b"effect-sentinel");
                }
                evidence.push(serde_json::json!({"case":case,"operationBytesObservedAtLeast":observed,"acceptedFrameSent":accepted,"unknown":unknown,"diagnostic":error,"registryExecuted":false,"retainedEffectMarker":marker}));
            }
            let offline = connect(&format!(
                "prunlet-registry-{}",
                uuid::Uuid::new_v4().simple()
            ))
            .err()
            .context("Missing test pipe unexpectedly connected")?
            .to_string();
            assert!(
                offline.contains("before operation transmission")
                    && offline.contains("os error")
                    && !offline.contains("Operation ID:"),
                "{offline}"
            );
            evidence.push(serde_json::json!({"case":"offline-connect","operationBytesObservedAtLeast":0,"unknown":false,"diagnostic":offline,"registryExecuted":false}));
            eprintln!(
                "{}",
                serde_json::json!({"realWindowsNamedPipes":true,"realPeerTokenAndExecutableChecked":true,"cases":evidence})
            );
            Ok(())
        }
    }
}
