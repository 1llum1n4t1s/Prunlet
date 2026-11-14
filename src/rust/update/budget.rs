use super::{
    coordinator::{SLOTS_NAME, STAGE, exists},
    state::{AUXILIARY_NAMES, STATE_NAME},
};
use crate::platform::windows::{self as native, PinnedFile, path};
use anyhow::{Context, Result, ensure};
use std::{
    cell::RefCell,
    path::{Path, PathBuf},
};
use windows_sys::Win32::{
    Foundation::HANDLE,
    Storage::FileSystem::{FILE_LIST_DIRECTORY, FILE_READ_ATTRIBUTES},
};
pub const LIMIT: u64 = 2 * 1024 * 1024 * 1024;
thread_local! {static GUARDS:RefCell<Vec<(PathBuf,HANDLE)>>=const{RefCell::new(Vec::new())};}
pub struct GuardScope {
    previous: Vec<(PathBuf, HANDLE)>,
}
pub fn with_guards(pins: &[&PinnedFile]) -> Result<GuardScope> {
    let mut added = Vec::new();
    for p in pins {
        added.push((p.final_path()?, p.raw()));
    }
    let previous = GUARDS.with(|g| {
        let previous = g.borrow().clone();
        g.borrow_mut().extend(added);
        previous
    });
    Ok(GuardScope { previous })
}
impl Drop for GuardScope {
    fn drop(&mut self) {
        GUARDS.with(|g| *g.borrow_mut() = std::mem::take(&mut self.previous));
    }
}
pub fn ensure_snapshot(used: u64, additional: u64) -> Result<()> {
    ensure!(
        additional <= LIMIT && used <= LIMIT - additional,
        "The update storage budget is exhausted; existing and unknown data were retained."
    );
    Ok(())
}
pub fn ensure(root: &Path, additional: u64) -> Result<()> {
    ensure_snapshot(measure(root)?, additional)
}
pub fn measure_file(path: &Path) -> Result<u64> {
    if let Some(handle) = GUARDS.with(|g| {
        g.borrow()
            .iter()
            .rev()
            .find(|(p, _)| p == path)
            .map(|(_, h)| *h)
    }) {
        return measure_handle(handle);
    }
    let pin = PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7)?;
    let id = pin.identity()?;
    ensure!(
        !id.is_reparse() && id.reparse_tag == 0,
        "An update storage reparse point was preserved"
    );
    pin.verify_named()?;
    let bytes = measure_handle(pin.raw())?;
    pin.verify_named()?;
    Ok(bytes)
}
fn measure_handle(handle: HANDLE) -> Result<u64> {
    let id = native::identity(handle)?;
    let bytes = (if id.is_directory() {
        0
    } else {
        native::file_size(handle)?
    })
    .checked_add(native::named_stream_bytes(handle)?)
    .context("Update size overflow")?;
    ensure!(
        native::identity(handle)? == id,
        "Update storage changed while measuring streams"
    );
    Ok(bytes)
}
fn add(total: &mut u64, n: u64) -> Result<()> {
    *total = total.checked_add(n).context("Update capacity overflow")?;
    ensure_snapshot(*total, 0)
}
fn tree(path: &Path, depth: usize, total: &mut u64, count: &mut usize) -> Result<()> {
    ensure!(
        depth <= 64,
        "Update storage is too deeply nested to measure safely."
    );
    let _parents = path::pin_directories(path)?;
    let pin = PinnedFile::open(path, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, 7)?;
    let id = pin.identity()?;
    ensure!(
        id.is_directory() && !id.is_reparse(),
        "Update storage is not a plain directory"
    );
    add(total, measure_handle(pin.raw())?)?;
    for name in native::directory_names(pin.raw())? {
        *count += 1;
        ensure!(*count <= 100000, "Update storage contains too many entries");
        let child = path.join(name);
        let pin = PinnedFile::open(&child, FILE_READ_ATTRIBUTES, 7)?;
        let id = pin.identity()?;
        ensure!(
            !id.is_reparse() && id.reparse_tag == 0,
            "An update storage reparse point was preserved"
        );
        if id.is_directory() {
            tree(&child, depth + 1, total, count)?
        } else {
            add(total, measure_file(&child)?)?;
        }
    }
    pin.verify_named()?;
    Ok(())
}
pub fn measure(root: &Path) -> Result<u64> {
    let _parents = path::pin_directories(root)?;
    let mut total = 0;
    let mut count = 0;
    for name in [STAGE, SLOTS_NAME] {
        let target = root.join(name);
        if exists(&target)? {
            tree(&target, 0, &mut total, &mut count)?;
        }
    }
    let bin = root.join("bin");
    let _binparents = path::pin_directories(&bin)?;
    let generated = regex::Regex::new(
        r"\Aprunlet(?:-maintenance|-hook)?\.(?:previous|candidate)(?:-[0-9a-f]{32})?\.exe\z",
    )?;
    let pending = regex::Regex::new(r"\A\.prunlet-update-state\.[0-9a-f]{32}\.pending\z")?;
    for entry in std::fs::read_dir(&bin)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if generated.is_match(&name)
            || AUXILIARY_NAMES
                .iter()
                .any(|n| name == format!(".prunlet-candidate-{n}"))
        {
            count += 1;
            add(&mut total, measure_file(&entry.path())?)?;
        }
    }
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name == STATE_NAME || name == "source-info.candidate.json" || pending.is_match(&name) {
            count += 1;
            add(&mut total, measure_file(&entry.path())?)?;
        }
    }
    ensure!(count <= 100000, "Update storage contains too many entries");
    Ok(total)
}
