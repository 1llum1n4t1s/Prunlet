//! workerへは専用のstdin/stdout/stderrだけを継承する。呼出元ホストのpipeを持ち越さない。
use super::{OwnedHandle, path, wide};
use anyhow::{Result, bail};
use std::{
    ffi::OsStr,
    io::{Read, Write},
    mem::{size_of, zeroed},
    os::windows::io::{AsRawHandle, FromRawHandle},
    path::Path,
    ptr::{null, null_mut},
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::*,
    Security::SECURITY_ATTRIBUTES,
    Storage::FileSystem::*,
    System::{
        IO::CancelSynchronousIo,
        JobObjects::{
            IsProcessInJob, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            OpenJobObjectW, QueryInformationJobObject,
        },
        Pipes::*,
        SystemServices::JOB_OBJECT_QUERY,
        Threading::*,
    },
};

const MCP_LAUNCHER_JOB: &str = "PRUNLET_MCP_LAUNCHER_JOB";

pub struct WorkerProcess {
    process: OwnedHandle,
    pub id: u32,
    pub input: Option<std::fs::File>,
    pub output: std::fs::File,
}
impl WorkerProcess {
    pub fn has_exited(&self) -> Result<bool> {
        match unsafe { WaitForSingleObject(self.process.raw(), 0) } {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => Err(std::io::Error::last_os_error().into()),
        }
    }
}
fn anonymous_pipe() -> Result<(OwnedHandle, OwnedHandle)> {
    unsafe {
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: null_mut(),
            bInheritHandle: 1,
        };
        let mut read = null_mut();
        let mut write = null_mut();
        if CreatePipe(&mut read, &mut write, &attributes, 0) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok((OwnedHandle::from_raw(read)?, OwnedHandle::from_raw(write)?))
    }
}
pub fn quote_argument(value: &str) -> String {
    let mut result = String::from("\"");
    let mut slashes = 0;
    for character in value.chars() {
        if character == '\\' {
            slashes += 1;
            continue;
        }
        result.extend(std::iter::repeat_n(
            '\\',
            if character == '"' {
                slashes * 2 + 1
            } else {
                slashes
            },
        ));
        result.push(character);
        slashes = 0;
    }
    result.extend(std::iter::repeat_n('\\', slashes * 2));
    result.push('"');
    result
}
fn belongs_to_job(process: HANDLE, job: &OwnedHandle) -> Result<bool> {
    let mut member = 0;
    if unsafe { IsProcessInJob(process, job.raw(), &mut member) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(member != 0)
}

fn mcp_launcher_job() -> Result<Option<OwnedHandle>> {
    let Some(name) = std::env::var_os(MCP_LAUNCHER_JOB) else {
        return Ok(None);
    };
    let valid = name
        .to_str()
        .and_then(|name| name.strip_prefix(r"Local\Prunlet.McpLauncher."))
        .is_some_and(|id| id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit()));
    if !valid {
        bail!("Invalid Prunlet MCP launcher job name; deletion was not started");
    }
    let name = wide(&name)?;
    let job = unsafe { OwnedHandle::from_raw(OpenJobObjectW(JOB_OBJECT_QUERY, 0, name.as_ptr()))? };
    if !belongs_to_job(unsafe { GetCurrentProcess() }, &job)? {
        bail!("Current process is outside its Prunlet MCP launcher job; deletion was not started");
    }
    Ok(Some(job))
}

pub fn ensure_mcp_queue_lifetime(config: &Path) -> Result<()> {
    if std::env::var_os(MCP_LAUNCHER_JOB).is_some() {
        return Ok(()); // 起動時に名前と親子の所属を照合する。
    }
    let executable = std::env::current_exe()?;
    let Some(bin) = executable.parent() else {
        return Ok(());
    };
    if !executable
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("prunlet.exe"))
        || !bin
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("bin"))
        || !config
            .file_name()
            .is_some_and(|name| name.eq_ignore_ascii_case("config.json"))
        || path::resolve(&executable, false, false)?
            .parent()
            .and_then(Path::parent)
            != config.parent()
    {
        return Ok(());
    }
    // 更新を開始した旧launcherは新しいexeを旧job内で起動する。次回接続まで受付を確定しない。
    let mut member = 0;
    if unsafe { IsProcessInJob(GetCurrentProcess(), null_mut(), &mut member) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if member == 0 {
        return Ok(());
    }
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    if unsafe {
        QueryInformationJobObject(
            null_mut(),
            JobObjectExtendedLimitInformation,
            (&mut limits as *mut JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            null_mut(),
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    if limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE != 0 {
        bail!(
            "Reconnect to the installed Prunlet MCP launcher before enqueuing; deletion was not started"
        );
    }
    Ok(())
}

pub fn spawn_worker(executable: &Path, args: &[String]) -> Result<WorkerProcess> {
    let launcher_job = mcp_launcher_job()?;
    unsafe {
        let executable = path::absolute(executable)?;
        let application = wide(executable.as_os_str())?;
        let mut parts =
            vec![quote_argument(executable.to_str().ok_or_else(|| {
                anyhow::anyhow!("Executable path must be valid Unicode")
            })?)];
        parts.extend(args.iter().map(|a| quote_argument(a)));
        let mut command = wide(OsStr::new(&parts.join(" ")))?;
        if command.len() > 32767 {
            bail!("Worker command line exceeds the Windows limit");
        }
        let (child_input, parent_input) = anonymous_pipe()?;
        let (parent_output, child_output) = anonymous_pipe()?;
        for handle in [&parent_input, &parent_output] {
            if SetHandleInformation(handle.raw(), HANDLE_FLAG_INHERIT, 0) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: null_mut(),
            bInheritHandle: 1,
        };
        let null_name = wide(OsStr::new("NUL"))?;
        let error = OwnedHandle::from_raw(CreateFileW(
            null_name.as_ptr(),
            GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            &attributes,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        ))?;
        let mut bytes = 0;
        InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut bytes);
        if bytes == 0 {
            bail!("Cannot determine the worker handle-list allocation size");
        }
        let mut allocation = vec![0usize; bytes.div_ceil(size_of::<usize>())];
        let list = allocation.as_mut_ptr().cast();
        if InitializeProcThreadAttributeList(list, 1, 0, &mut bytes) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        struct Attributes(*mut std::ffi::c_void);
        impl Drop for Attributes {
            fn drop(&mut self) {
                unsafe {
                    DeleteProcThreadAttributeList(self.0.cast());
                }
            }
        }
        let _attributes = Attributes(list.cast());
        let mut handles = [child_input.raw(), child_output.raw(), error.raw()];
        if UpdateProcThreadAttribute(
            list,
            0,
            PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
            handles.as_mut_ptr().cast(),
            size_of::<HANDLE>() * handles.len(),
            null_mut(),
            null(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let mut startup: STARTUPINFOEXW = zeroed();
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = child_input.raw();
        startup.StartupInfo.hStdOutput = child_output.raw();
        startup.StartupInfo.hStdError = error.raw();
        startup.lpAttributeList = list;
        let mut info: PROCESS_INFORMATION = zeroed();
        let mut flags =
            EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
        // 通常CLIは従来の起動条件を使う。所属を確認したMCPからだけ明示的に離脱し、OSの外側job制約に従う。
        if launcher_job.is_some() {
            flags |= CREATE_BREAKAWAY_FROM_JOB;
        }
        if CreateProcessW(
            application.as_ptr(),
            command.as_mut_ptr(),
            null(),
            null(),
            1,
            flags,
            null(),
            null(),
            &startup.StartupInfo,
            &mut info,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let process = OwnedHandle::from_raw(info.hProcess)?;
        let _thread = OwnedHandle::from_raw(info.hThread)?;
        // 要求を渡す前に確認する。失敗時はpipeを閉じ、workerに削除を受け付けさせない。
        if let Some(job) = launcher_job.as_ref()
            && belongs_to_job(process.raw(), job)?
        {
            bail!(
                "Queue worker remained in the Prunlet MCP launcher job; deletion was not started"
            );
        }
        Ok(WorkerProcess {
            process,
            id: info.dwProcessId,
            input: Some(std::fs::File::from_raw_handle(parent_input.into_raw())),
            output: std::fs::File::from_raw_handle(parent_output.into_raw()),
        })
    }
}
pub fn read_exact_pipe(
    file: &mut std::fs::File,
    bytes: &mut [u8],
    deadline: Instant,
) -> Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        let mut available = 0;
        if unsafe {
            PeekNamedPipe(
                file.as_raw_handle(),
                null_mut(),
                0,
                null_mut(),
                &mut available,
                null_mut(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        if available != 0 {
            let count = (available as usize).min(bytes.len() - offset);
            file.read_exact(&mut bytes[offset..offset + count])?;
            offset += count;
            continue;
        }
        if Instant::now() >= deadline {
            bail!("Worker pipe read timed out");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn duplicate_file(handle: HANDLE) -> Result<std::fs::File> {
    unsafe {
        let current = GetCurrentProcess();
        let mut copy = null_mut();
        if DuplicateHandle(
            current,
            handle,
            current,
            &mut copy,
            0,
            0,
            DUPLICATE_SAME_ACCESS,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let copy = OwnedHandle::from_raw(copy)?;
        Ok(std::fs::File::from_raw_handle(copy.into_raw()))
    }
}
// 起動失敗は通常のResultにし、起動済みworkerをscopeのpanicで失わない。
pub(crate) fn spawn_scoped<'scope, 'env, F, T>(
    scope: &'scope std::thread::Scope<'scope, 'env>,
    name: &str,
    run: F,
) -> std::io::Result<std::thread::ScopedJoinHandle<'scope, T>>
where
    F: FnOnce() -> T + Send + 'scope,
    T: Send + 'scope,
{
    #[cfg(test)]
    test_faults::before_spawn(name)?;
    std::thread::Builder::new()
        .name(name.into())
        .spawn_scoped(scope, run)
}
#[derive(Debug)]
pub(crate) struct IoHelperInfrastructureFailure;
impl std::fmt::Display for IoHelperInfrastructureFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("I/O helper infrastructure failed")
    }
}
impl std::error::Error for IoHelperInfrastructureFailure {}
pub(crate) fn cancellable_io<F>(name: &str, timeout: Duration, operation: F) -> Result<()>
where
    F: FnOnce() -> std::io::Result<()> + Send,
{
    #[cfg(test)]
    let fail_handle = test_faults::take_handle_failure(name);
    std::thread::scope(|scope| {
        let (thread_sender, thread_receiver) = std::sync::mpsc::channel();
        let (permit_sender, permit_receiver) = std::sync::mpsc::channel();
        let (result_sender, result_receiver) = std::sync::mpsc::channel();
        let task = spawn_scoped(scope, name, move || {
            #[cfg(test)]
            if fail_handle {
                let _ = thread_sender.send(Err(anyhow::anyhow!("Injected OpenThread failure")));
                return;
            }
            let thread = match unsafe {
                OwnedHandle::from_raw(OpenThread(THREAD_TERMINATE, 0, GetCurrentThreadId()))
            } {
                Ok(thread) => thread,
                Err(error) => {
                    let _ = thread_sender.send(Err(error));
                    return;
                }
            };
            if thread_sender.send(Ok(thread)).is_err() {
                return;
            }
            // 親が取消handleを実際に受領する前には、blocking I/Oを開始しない。
            if permit_receiver
                .recv_timeout(Duration::from_secs(1))
                .is_err()
            {
                return;
            }
            let _ = result_sender.send(operation());
        })
        .map_err(|error| anyhow::Error::new(error).context(IoHelperInfrastructureFailure))?;
        let thread = match thread_receiver.recv_timeout(Duration::from_secs(1)) {
            Ok(Ok(thread)) => thread,
            failure => {
                drop(permit_sender);
                let _ = task.join();
                return Err((match failure {
                    Ok(Err(error)) => error,
                    Err(error) => {
                        anyhow::anyhow!("I/O cancellation handle handshake failed: {error}")
                    }
                    _ => unreachable!(),
                })
                .context(IoHelperInfrastructureFailure));
            }
        };
        if permit_sender.send(()).is_err() {
            let _ = task.join();
            return Err(anyhow::anyhow!(
                "I/O helper stopped before its cancellation handle was acknowledged"
            )
            .context(IoHelperInfrastructureFailure));
        }
        let result = match result_receiver.recv_timeout(timeout) {
            Ok(result) => result.map_err(anyhow::Error::from),
            Err(error) => {
                // 期限とI/O開始が競合しても、取消を発行する前後でhelperを取り逃がさない。
                let mut cancellation_failure = None;
                while !task.is_finished() {
                    unsafe {
                        if CancelSynchronousIo(thread.raw()) == 0 {
                            let code = GetLastError();
                            if code != ERROR_NOT_FOUND {
                                cancellation_failure =
                                    Some(std::io::Error::from_raw_os_error(code as i32));
                            }
                        }
                    }
                    let _ = result_receiver.recv_timeout(Duration::from_millis(20));
                }
                Err(match cancellation_failure {
                    Some(failure) => {
                        anyhow::Error::new(failure).context(IoHelperInfrastructureFailure)
                    }
                    None => anyhow::anyhow!("Cancellable I/O timed out: {error}"),
                })
            }
        };
        task.join().map_err(|_| {
            anyhow::anyhow!("I/O helper stopped unexpectedly")
                .context(IoHelperInfrastructureFailure)
        })?;
        result
    })
}
pub fn write_pipe_deadline(
    mut file: std::fs::File,
    bytes: Vec<u8>,
    timeout: Duration,
) -> Result<()> {
    cancellable_io("worker-pipe-writer", timeout, move || {
        file.write_all(&bytes).and_then(|_| file.flush())
    })
}
#[cfg(test)]
pub(crate) mod test_faults {
    use std::cell::RefCell;
    struct Fault {
        name: String,
        nth: usize,
        before: Option<Box<dyn FnOnce()>>,
    }
    thread_local! {static SPAWN:RefCell<Option<Fault>>=const{RefCell::new(None)};static HANDLE:RefCell<Option<String>>=const{RefCell::new(None)};}
    pub struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            SPAWN.with(|value| value.borrow_mut().take());
            HANDLE.with(|value| value.borrow_mut().take());
        }
    }
    pub fn fail_spawn(name: &str, nth: usize, before: Option<Box<dyn FnOnce()>>) -> Reset {
        SPAWN.with(|value| {
            *value.borrow_mut() = Some(Fault {
                name: name.into(),
                nth,
                before,
            })
        });
        Reset
    }
    pub fn fail_handle(name: &str) -> Reset {
        HANDLE.with(|value| *value.borrow_mut() = Some(name.into()));
        Reset
    }
    pub(super) fn before_spawn(name: &str) -> std::io::Result<()> {
        let fault = SPAWN.with(|value| {
            let mut value = value.borrow_mut();
            if let Some(fault) = value.as_mut() {
                if fault.name == name {
                    fault.nth -= 1;
                    if fault.nth == 0 {
                        return value.take();
                    }
                }
            }
            None
        });
        if let Some(mut fault) = fault {
            if let Some(before) = fault.before.take() {
                before();
            }
            return Err(std::io::Error::other(format!(
                "Injected thread creation failure: {name}"
            )));
        }
        Ok(())
    }
    pub(super) fn take_handle_failure(name: &str) -> bool {
        HANDLE.with(|value| {
            let mut value = value.borrow_mut();
            if value.as_deref() == Some(name) {
                value.take();
                true
            } else {
                false
            }
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn writer_setup_failures_never_start_blocking_io() -> Result<()> {
        for handle_failure in [false, true] {
            let (read, write) = anonymous_pipe()?;
            let file = unsafe { std::fs::File::from_raw_handle(write.into_raw()) };
            let _fault = if handle_failure {
                test_faults::fail_handle("worker-pipe-writer")
            } else {
                test_faults::fail_spawn("worker-pipe-writer", 1, None)
            };
            let started = Instant::now();
            let error =
                write_pipe_deadline(file, vec![7; 2 * 1024 * 1024], Duration::from_millis(100))
                    .unwrap_err();
            assert!(
                started.elapsed() < Duration::from_secs(3),
                "Setup failure waited for an unread pipe: {error:#}"
            );
            let mut available = 0;
            let ok = unsafe {
                PeekNamedPipe(
                    read.raw(),
                    null_mut(),
                    0,
                    null_mut(),
                    &mut available,
                    null_mut(),
                )
            };
            assert_eq!(
                available, 0,
                "Writer entered I/O without an acknowledged cancellation handle"
            );
            if ok == 0 {
                assert_eq!(unsafe { GetLastError() }, ERROR_BROKEN_PIPE);
            }
        }
        Ok(())
    }
    #[test]
    fn writer_deadline_cancels_an_actual_unread_pipe() -> Result<()> {
        let (_read, write) = anonymous_pipe()?;
        let file = unsafe { std::fs::File::from_raw_handle(write.into_raw()) };
        let started = Instant::now();
        let error = write_pipe_deadline(file, vec![7; 2 * 1024 * 1024], Duration::from_millis(100))
            .unwrap_err();
        assert!(error.to_string().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(3));
        Ok(())
    }
    #[test]
    fn quoting_preserves_quotes_and_trailing_slashes() {
        assert_eq!(
            quote_argument("C:\\path with spaces\\"),
            "\"C:\\path with spaces\\\\\""
        );
        assert_eq!(quote_argument("a\"b"), "\"a\\\"b\"");
    }
}
