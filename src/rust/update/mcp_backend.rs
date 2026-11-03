//! managed MCPの各要求を、proxy消失後もbackend自身の読取handleで固定する。
use super::{coordinator as core, mcp_generation};
use crate::platform::windows::{self as native, OwnedHandle, PinnedFile, path};
use anyhow::{Context as _, Result, ensure};
use std::{ffi::c_void, path::Path, process::Command, sync::Mutex};
use windows_sys::Win32::{
    Foundation::{FILETIME, GENERIC_READ, HANDLE, WAIT_TIMEOUT},
    Storage::FileSystem::FILE_SHARE_READ,
    System::Threading::{
        GetCurrentProcess, GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        WaitForSingleObject,
    },
};

const PROXY_PID: &str = "PRUNLET_MCP_PROXY_PID";
const PROXY_CREATED: &str = "PRUNLET_MCP_PROXY_CREATED";
const SOURCE_HASH: &str = "PRUNLET_MCP_SOURCE_SHA256";
const PROCESS_SYNCHRONIZE: u32 = 0x00100000;

#[repr(C)]
struct ProcessBasicInformation {
    exit_status: i32,
    peb_base_address: *mut c_void,
    affinity_mask: usize,
    base_priority: i32,
    unique_process_id: usize,
    inherited_from_unique_process_id: usize,
}
#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtQueryInformationProcess(
        process: HANDLE,
        class: u32,
        information: *mut c_void,
        length: u32,
        returned: *mut u32,
    ) -> i32;
}

fn creation(process: HANDLE) -> Result<u64> {
    let mut created: FILETIME = unsafe { std::mem::zeroed() };
    let mut exited = created;
    let mut kernel = created;
    let mut user = created;
    ensure!(
        unsafe { GetProcessTimes(process, &mut created, &mut exited, &mut kernel, &mut user) } != 0,
        "Cannot query MCP proxy process creation: {}",
        std::io::Error::last_os_error()
    );
    Ok((u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime))
}
fn actual_parent() -> Result<u32> {
    let mut basic: ProcessBasicInformation = unsafe { std::mem::zeroed() };
    let mut returned = 0;
    let status = unsafe {
        NtQueryInformationProcess(
            GetCurrentProcess(),
            0,
            &mut basic as *mut _ as *mut c_void,
            std::mem::size_of_val(&basic) as u32,
            &mut returned,
        )
    };
    ensure!(
        status >= 0 && returned as usize == std::mem::size_of_val(&basic),
        "Cannot verify actual MCP backend parent process: NTSTATUS {status:#x}"
    );
    Ok(u32::try_from(basic.inherited_from_unique_process_id)?)
}
fn hex64(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}
fn identity_source(identity: &str) -> Result<&str> {
    let (product, source) = identity
        .split_once(':')
        .context("Missing MCP generation source identity")?;
    ensure!(
        hex64(product) && hex64(source),
        "Invalid MCP generation identity"
    );
    Ok(source)
}
fn required(name: &str) -> Result<String> {
    std::env::var(name).with_context(|| format!("Managed MCP backend requires {name}"))
}

/// Commandの環境だけを設定し、他の接続やqueue workerの環境を書き換えない。
pub fn configure_child(command: &mut Command, identity: &str) -> Result<()> {
    require_protocol(command.get_program())?;
    let source = identity_source(identity)?;
    command
        .env(PROXY_PID, std::process::id().to_string())
        .env(
            PROXY_CREATED,
            creation(unsafe { GetCurrentProcess() })?.to_string(),
        )
        .env(SOURCE_HASH, source);
    Ok(())
}

fn require_protocol(executable: &std::ffi::OsStr) -> Result<()> {
    use std::os::windows::process::CommandExt;
    use std::{
        io::Read,
        process::Stdio,
        thread,
        time::{Duration, Instant},
    };
    let mut probe = Command::new(executable)
        .arg("--startup-update-protocol")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(0x08000000)
        .spawn()
        .context("Cannot inspect managed MCP backend protocol")?;
    let output = probe
        .stdout
        .take()
        .context("Missing backend protocol output")?;
    let reader = thread::spawn(move || -> std::io::Result<Vec<u8>> {
        let mut bytes = Vec::new();
        output.take(65537).read_to_end(&mut bytes)?;
        Ok(bytes)
    });
    let until = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = probe.try_wait()? {
            break status;
        }
        if Instant::now() >= until {
            // 未送信のprotocol照会だけを終了する。実処理要求を再送・強制終了しない。
            let _ = probe.kill();
            let _ = probe.wait();
            let _ = reader.join();
            anyhow::bail!(
                "Managed MCP backend protocol inspection timed out; no request was sent."
            );
        }
        thread::sleep(Duration::from_millis(20));
    };
    let bytes = reader
        .join()
        .map_err(|_| anyhow::anyhow!("Backend protocol reader failed"))??;
    ensure!(
        status.success() && bytes.len() <= 65536,
        "Managed MCP backend protocol inspection failed; no request was sent."
    );
    let protocol = crate::json::parse_unique(&bytes)?;
    ensure!(
        protocol["protocol"] == 1
            && protocol["storageEpoch"] == 1
            && protocol["mcpProxy"] == 2
            && protocol["mcpBackendLease"] == 1,
        "Backend does not support per-request managed MCP leases; no request was sent."
    );
    Ok(())
}

pub struct Context {
    parent: OwnedHandle,
    product_hash: String,
    source_hash: String,
    // pin_proxyのopaque Send型を共有Runtimeから安全に保持する。
    _code: Mutex<Box<dyn Send>>,
}
pub struct Scope {
    _parents: path::DirectoryLease,
    _product: PinnedFile,
    _source: PinnedFile,
}
impl Context {
    pub fn from_proxy(config: &Path) -> Result<Option<Self>> {
        let current = path::resolve(&std::env::current_exe()?, false, false)?;
        let private = current.ancestors().any(|part| {
            part.file_name()
                .is_some_and(|name| name.eq_ignore_ascii_case(mcp_generation::CACHE))
        });
        let supplied = [PROXY_PID, PROXY_CREATED, SOURCE_HASH]
            .iter()
            .any(|name| std::env::var_os(name).is_some());
        if !private && !supplied {
            return Ok(None);
        }
        ensure!(
            private,
            "Managed MCP backend must run from its private generation"
        );
        let pid: u32 = required(PROXY_PID)?
            .parse()
            .context("Invalid MCP proxy process id")?;
        let created: u64 = required(PROXY_CREATED)?
            .parse()
            .context("Invalid MCP proxy creation time")?;
        let source_hash = required(SOURCE_HASH)?;
        ensure!(
            pid != 0 && created != 0 && hex64(&source_hash),
            "Invalid MCP backend parent identity"
        );
        ensure!(
            actual_parent()? == pid,
            "MCP proxy identity does not match the actual parent process"
        );
        let parent = unsafe {
            OwnedHandle::from_raw(OpenProcess(
                PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                0,
                pid,
            ))?
        };
        ensure!(
            creation(parent.raw())? == created,
            "MCP proxy process identity was replaced"
        );
        let code = mcp_generation::pin_proxy(config)?;
        let product_hash = current
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .context("Invalid MCP backend generation hash")?
            .to_ascii_uppercase();
        ensure!(hex64(&product_hash), "Invalid MCP backend generation hash");
        let context = Self {
            parent,
            product_hash,
            source_hash: source_hash.to_ascii_uppercase(),
            _code: Mutex::new(Box::new(code)),
        };
        context.parent_alive()?;
        Ok(Some(context))
    }
    fn parent_alive(&self) -> Result<()> {
        ensure!(
            unsafe { WaitForSingleObject(self.parent.raw(), 0) } == WAIT_TIMEOUT,
            "MCP proxy is no longer alive; the request was not executed"
        );
        Ok(())
    }
    pub fn acquire(&self, config: &Path) -> Result<Scope> {
        self.parent_alive()?;
        let root = core::installation_root(config)?;
        // installer mutexは取らない。proxyが既に持つ要求leaseとの二重待機を避ける。
        let parents = path::pin_directories(&root.join("bin"))?;
        let source_path = root.join("source-info.json");
        let source = core::plain(&source_path, GENERIC_READ, FILE_SHARE_READ)?;
        native::reject_named_streams(&source_path)?;
        let canonical = root.join("bin/prunlet.exe");
        let product = core::plain(&canonical, GENERIC_READ, FILE_SHARE_READ)?;
        native::reject_named_streams(&canonical)?;
        ensure!(
            core::hash_stream(&mut core::stream(&source)?)? == self.source_hash,
            "MCP source provenance changed; the request was not executed"
        );
        ensure!(
            core::hash_stream(&mut core::stream(&product)?)? == self.product_hash,
            "MCP product generation changed; the request was not executed"
        );
        ensure!(
            core::read_provenance(&source_path)?.cli_hash == self.product_hash,
            "MCP product provenance differs; the request was not executed"
        );
        ensure!(
            core::read_state(&root)?.is_none_or(|state| state.phase == "idle"),
            "MCP update is not idle; the request was not executed"
        );
        product.verify_named()?;
        source.verify_named()?;
        // ここまで親が生きていればproxy leaseとの重なりがある。
        // 直後に親が消失しても、以後はこのScopeが実処理終了まで固定する。
        self.parent_alive()?;
        Ok(Scope {
            _parents: parents,
            _product: product,
            _source: source,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generation_identity_requires_both_full_hashes() {
        let valid = format!("{}:{}", "A".repeat(64), "b".repeat(64));
        assert_eq!(identity_source(&valid).unwrap(), "b".repeat(64));
        for invalid in [
            "",
            "abc:def",
            &format!("{}:{}:extra", "A".repeat(64), "B".repeat(64)),
        ] {
            assert!(identity_source(invalid).is_err());
        }
    }
    #[test]
    fn actual_parent_and_creation_are_queryable() {
        assert_ne!(actual_parent().unwrap(), 0);
        assert_ne!(creation(unsafe { GetCurrentProcess() }).unwrap(), 0);
    }
}
