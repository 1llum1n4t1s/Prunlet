//! 削除拒否後だけ保持元の現在値を観測する。終了・再削除・リンク先走査は行わない。
use super::{OwnedHandle, PinnedFile, path, wide};
use anyhow::{Result, bail};
use std::{
    path::Path,
    ptr::{null, null_mut},
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::*,
    Storage::FileSystem::*,
    System::{ProcessStatus::*, RestartManager::*, Threading::*},
};

pub fn observe_users(target: &Path) -> Result<String> {
    let started = Instant::now();
    let mut observations = vec![];
    let mut notes = vec![];
    let original = PinnedFile::open(target, FILE_READ_ATTRIBUTES, 7)?;
    let identity = original.identity()?;
    if identity.is_reparse() {
        return Ok(
            " Lock diagnostics: link targets were not inspected; no owner was identified.".into(),
        );
    }
    if !identity.is_directory() {
        if restart_manager(target, &mut observations).is_err() {
            notes.push("Restart Manager unavailable");
        }
    } else {
        notes.push("file-handle owners inside directories are not enumerated");
    }
    let mut pids = vec![0u32; 16384];
    let mut bytes = 0;
    if unsafe { K32EnumProcesses(pids.as_mut_ptr(), (pids.len() * 4) as u32, &mut bytes) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if bytes as usize >= pids.len() * 4 {
        notes.push("process enumeration limit reached");
    }
    pids.truncate((bytes as usize / 4).min(pids.len()));
    let mut inaccessible = false;
    for pid in pids {
        if pid == 0 || pid == std::process::id() {
            continue;
        }
        if started.elapsed() >= Duration::from_secs(10) || observations.len() >= 8 {
            notes.push("diagnostic time/result limit reached");
            break;
        }
        let process = match unsafe {
            OwnedHandle::from_raw(OpenProcess(
                PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                0,
                pid,
            ))
        } {
            Ok(p) => p,
            Err(_) => {
                inaccessible = true;
                continue;
            }
        };
        let mut modules = vec![null_mut(); 4096];
        let mut required = 0;
        if unsafe {
            K32EnumProcessModulesEx(
                process.raw(),
                modules.as_mut_ptr(),
                (modules.len() * std::mem::size_of::<HMODULE>()) as u32,
                &mut required,
                3,
            )
        } == 0
        {
            inaccessible = true;
            continue;
        }
        if required as usize > modules.len() * std::mem::size_of::<HMODULE>() {
            inaccessible = true;
        }
        modules.truncate((required as usize / std::mem::size_of::<HMODULE>()).min(modules.len()));
        let mut image = vec![0u16; 32768];
        let mut image_length = image.len() as u32;
        let name = if unsafe {
            QueryFullProcessImageNameW(process.raw(), 0, image.as_mut_ptr(), &mut image_length)
        } != 0
        {
            String::from_utf16(&image[..image_length as usize]).unwrap_or_else(|_| "unknown".into())
        } else {
            "unknown".into()
        };
        for module in modules {
            if started.elapsed() >= Duration::from_secs(10) || observations.len() >= 8 {
                break;
            }
            let mut buffer = vec![0u16; 32768];
            let n = unsafe {
                K32GetModuleFileNameExW(
                    process.raw(),
                    module,
                    buffer.as_mut_ptr(),
                    buffer.len() as u32,
                )
            } as usize;
            if n == 0 || n >= buffer.len() {
                inaccessible = true;
                continue;
            }
            let Ok(module_path) = String::from_utf16(&buffer[..n]) else {
                inaccessible = true;
                continue;
            };
            let module = Path::new(&module_path);
            if super::ordinal_ignore_case(&module_path, &target.to_string_lossy())
                || (identity.is_directory() && path::within(module, target))
            {
                let process_name = Path::new(&name)
                    .file_stem()
                    .map(|x| x.to_string_lossy().into_owned())
                    .unwrap_or(name.clone());
                observations.push(format!(
                    "PID {pid} ({}), loaded module {}",
                    serde_json::to_string(&process_name)?,
                    serde_json::to_string(&module_path)?
                ));
            }
        }
    }
    if inaccessible {
        notes.push("some process/module information was inaccessible");
    }
    let mut result = if observations.is_empty() {
        " Lock diagnostics: no current file or loaded-module user was identified".to_owned()
    } else {
        format!(" Lock diagnostics observed: {}", observations.join("; "))
    };
    if !notes.is_empty() {
        result.push_str(&format!("; {}", notes.join("; ")));
    }
    result.push_str(". This is a current, non-exhaustive observation; it does not prove the cause of the original deletion failure.");
    Ok(result)
}
fn restart_manager(target: &Path, observations: &mut Vec<String>) -> Result<()> {
    unsafe {
        let mut session = 0;
        let mut key = [0u16; 33];
        let status = RmStartSession(&mut session, 0, key.as_mut_ptr());
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        struct Session(u32);
        impl Drop for Session {
            fn drop(&mut self) {
                unsafe {
                    RmEndSession(self.0);
                }
            }
        }
        let session = Session(session);
        let name = wide(target.as_os_str())?;
        let paths = [name.as_ptr()];
        let status = RmRegisterResources(session.0, 1, paths.as_ptr(), 0, null(), 0, null());
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        let mut needed = 0;
        let mut count = 0;
        let mut reasons = 0;
        let status = RmGetList(session.0, &mut needed, &mut count, null_mut(), &mut reasons);
        if status == 0 {
            return Ok(());
        }
        if status != ERROR_MORE_DATA {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        if needed == 0 || needed > 4096 {
            bail!("Restart Manager process list exceeds its limit");
        }
        let mut entries: Vec<RM_PROCESS_INFO> = vec![std::mem::zeroed(); needed as usize];
        count = needed;
        let status = RmGetList(
            session.0,
            &mut needed,
            &mut count,
            entries.as_mut_ptr(),
            &mut reasons,
        );
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        for entry in entries.iter().take(count as usize) {
            if entry.Process.dwProcessId == std::process::id() {
                continue;
            }
            let n = entry
                .strAppName
                .iter()
                .position(|&x| x == 0)
                .unwrap_or(entry.strAppName.len());
            let name = String::from_utf16(&entry.strAppName[..n])?;
            observations.push(format!(
                "PID {} ({}), Restart Manager file user {}",
                entry.Process.dwProcessId,
                serde_json::to_string(&name)?,
                serde_json::to_string(&target.to_string_lossy())?
            ));
            if observations.len() >= 8 {
                break;
            }
        }
        Ok(())
    }
}
