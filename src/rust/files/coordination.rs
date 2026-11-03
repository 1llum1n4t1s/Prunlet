use crate::{
    config::Config,
    platform::windows::{
        self as native, OwnedHandle,
        path::{self, DirectoryLease},
    },
    service::Progress,
};
use anyhow::{Result, bail};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::{Condvar, Mutex},
    time::{Duration, Instant},
};
use windows_sys::Win32::{Foundation::*, Storage::FileSystem::*, System::IO::OVERLAPPED};
pub struct Coordination {
    _parents: DirectoryLease,
    _handle: Option<OwnedHandle>,
}
pub fn acquire(
    config: &Config,
    targets: Option<&[PathBuf]>,
    progress: Option<&Progress>,
) -> Result<Coordination> {
    acquire_core(config, targets, progress, true)
}
pub fn acquire_readonly(config: &Config, progress: Option<&Progress>) -> Result<Coordination> {
    acquire_core(config, None, progress, false)
}
fn acquire_core(
    config: &Config,
    targets: Option<&[PathBuf]>,
    progress: Option<&Progress>,
    create: bool,
) -> Result<Coordination> {
    let root = path::absolute(Path::new(&config.data.backup_directory))?;
    let parents = path::pin_directories(&root)?;
    for fixed in &parents.handles {
        fixed.reject_case_sensitive()?;
    }
    let lock = root.join("maintenance.lock");
    let name = native::win32_path(&lock)?;
    let started = Instant::now();
    let mut next_report = Duration::from_secs(1);
    let mut reported = false;
    let mut report = |done: bool| {
        if done && reported || (!done && started.elapsed() >= next_report) {
            if let Some(progress) = progress {
                let elapsed = started.elapsed().as_secs_f64();
                let message = if done {
                    format!("[prunlet] Recovery lock acquired after {elapsed:.1}s.")
                } else {
                    format!("[prunlet] Waiting for recovery lock ({elapsed:.1}s elapsed).")
                };
                progress(
                    serde_json::json!({"kind":"recoveryLock","elapsedSeconds":elapsed,"completed":done,"acquired":done,"message":message}),
                );
            }
            reported = true;
            next_report = started.elapsed() + Duration::from_secs(5);
        }
    };
    let handle = loop {
        let raw = unsafe {
            CreateFileW(
                name.as_ptr(),
                if targets.is_some() {
                    GENERIC_READ
                } else {
                    GENERIC_READ | GENERIC_WRITE
                },
                if targets.is_some() {
                    FILE_SHARE_READ
                } else {
                    0
                },
                null(),
                if create { OPEN_ALWAYS } else { OPEN_EXISTING },
                FILE_FLAG_OPEN_REPARSE_POINT,
                null_mut(),
            )
        };
        if raw != INVALID_HANDLE_VALUE {
            break unsafe { OwnedHandle::from_raw(raw)? };
        }
        let error = std::io::Error::last_os_error();
        if !create && matches!(error.raw_os_error(), Some(2 | 3)) {
            return Ok(Coordination {
                _parents: parents,
                _handle: None,
            });
        }
        if !matches!(error.raw_os_error(), Some(32 | 33)) {
            return Err(error.into());
        }
        report(false);
        std::thread::sleep(Duration::from_millis(100));
    };
    let identity = native::identity(handle.raw())?;
    let mut length = 0;
    if unsafe { GetFileSizeEx(handle.raw(), &mut length) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if identity.is_directory() || identity.is_reparse() || identity.links != 1 || length != 0 {
        bail!("Recovery coordination lock is not an empty plain single-link file");
    }
    native::reject_named_streams(&lock)?;
    if let Some(targets) = targets {
        let mut claims: BTreeMap<u32, bool> = BTreeMap::new();
        for target in targets {
            let mut current = Some(target.as_path());
            let mut exclusive = true;
            while let Some(path) = current {
                let name =
                    native::invariant_uppercase(path.to_string_lossy().trim_end_matches('\\'))?;
                let hash = Sha256::digest(name.as_bytes());
                let slot = u16::from_le_bytes([hash[0], hash[1]]) as u32;
                claims
                    .entry(slot)
                    .and_modify(|e| *e |= exclusive)
                    .or_insert(exclusive);
                exclusive = false;
                current = path.parent();
            }
        }
        for (slot, exclusive) in claims {
            loop {
                let mut overlap: OVERLAPPED = unsafe { std::mem::zeroed() };
                overlap.Anonymous.Anonymous.Offset = slot + 1;
                if unsafe {
                    LockFileEx(
                        handle.raw(),
                        LOCKFILE_FAIL_IMMEDIATELY
                            | if exclusive {
                                LOCKFILE_EXCLUSIVE_LOCK
                            } else {
                                0
                            },
                        0,
                        1,
                        0,
                        &mut overlap,
                    )
                } != 0
                {
                    break;
                }
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() != Some(33) {
                    return Err(error.into());
                }
                report(false);
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
    report(true);
    Ok(Coordination {
        _parents: parents,
        _handle: Some(handle),
    })
}
static WORKERS: Mutex<usize> = Mutex::new(0);
static AVAILABLE: Condvar = Condvar::new();
pub struct WorkerSlot;
impl WorkerSlot {
    pub fn acquire() -> Self {
        let mut count = WORKERS.lock().unwrap_or_else(|x| x.into_inner());
        while *count >= 4 {
            count = AVAILABLE.wait(count).unwrap_or_else(|x| x.into_inner());
        }
        *count += 1;
        Self
    }
}
impl Drop for WorkerSlot {
    fn drop(&mut self) {
        let mut count = WORKERS.lock().unwrap_or_else(|x| x.into_inner());
        *count -= 1;
        AVAILABLE.notify_one();
    }
}
