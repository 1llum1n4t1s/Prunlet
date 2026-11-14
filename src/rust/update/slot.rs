use super::{budget, coordinator::*, state::PublishedSlot};
use crate::platform::windows::{self as native, PinnedFile, path};
use anyhow::{Result, ensure};
use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
};
use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE};
use windows_sys::Win32::Storage::FileSystem::*;

pub struct Lease {
    pub generation: String,
    pub reused: bool,
    pub previous_status: String,
    pub pin: PinnedFile,
    pub file: File,
    path: PathBuf,
    _parents: path::DirectoryLease,
}
impl Lease {
    pub fn verify(&mut self, bytes: u64, hash: &str) -> Result<()> {
        self.pin.verify_named()?;
        ensure!(
            self.pin.identity()?.links == 1,
            "Product slot acquired another link"
        );
        native::reject_named_streams(&self.path)?;
        ensure!(
            self.file.metadata()?.len() == bytes
                && hash_stream(&mut self.file)?.eq_ignore_ascii_case(hash),
            "Slot contents differ from the confirmed product."
        );
        native::reject_named_streams(&self.path)?;
        Ok(())
    }
    pub fn write(&mut self, input: &mut dyn Read, bytes: u64, hash: &str) -> Result<()> {
        copy_verified(input, &mut self.file, bytes, hash)?;
        self.verify(bytes, hash)
    }
}
pub fn acquire(
    root: &Path,
    product: &str,
    previous: Option<&PublishedSlot>,
    bytes: u64,
) -> Result<Lease> {
    ensure!(
        matches!(product, "cli" | "maintenance" | "hook") && (1..=536870912).contains(&bytes),
        "Invalid product slot"
    );
    let directory = root.join(SLOTS_NAME);
    let parents = path::pin_directories(&directory)?;
    let used = measure(&directory)?;
    let mut reason = "none";
    if let Some(previous) = previous {
        ensure!(
            matches!(previous.status.as_str(), "ready" | "writing")
                && super::package::is_hex(&previous.sha256, 64)
                && previous.bytes > 0
                && previous.bytes <= 536870912
                && uuid::Uuid::parse_str(&previous.generation).is_ok_and(|id| !id.is_nil()),
            "Prior product slot identity is incomplete"
        );
        let location = directory.join(format!("slot-{product}-{}.bin", previous.generation));
        if previous.status == "writing" {
            // stateが書込み前に記録したgenerationの部分ファイルは、記録済みの部分書込みとして
            // 同じ名前のまま上書きする（新しいgenerationを作ると旧ファイルがstateから見えない孤児になる）。
            // 内容は未確定なので検証済みの再利用（reused）にはせず、呼出し側は必ず書き直す。
            // 実体はあるが上書きできない（link・代替ストリーム・書く長さより長い）場合は保持して別のgenerationを使う。
            let resumed = (|| -> Result<Lease> {
                let (pin, file, status) = if exists(&location)? {
                    native::reject_named_streams(&location)?;
                    let pin = plain(&location, GENERIC_READ | GENERIC_WRITE, 0)?;
                    let file = stream(&pin)?;
                    let length = file.metadata()?.len();
                    ensure!(
                        length <= bytes,
                        "Partial product slot is longer than the product"
                    );
                    budget::ensure_snapshot(used, bytes.saturating_sub(length))?;
                    (pin, file, "resumed_partial")
                } else {
                    budget::ensure_snapshot(used, bytes)?;
                    let (pin, file) = create_plain(&location)?;
                    (pin, file, "recreated_partial")
                };
                Ok(Lease {
                    generation: previous.generation.clone(),
                    reused: false,
                    previous_status: status.into(),
                    pin,
                    file,
                    path: location.clone(),
                    _parents: path::pin_directories(&directory)?,
                })
            })();
            match resumed {
                Ok(lease) => return Ok(lease),
                Err(_) => reason = "previous_unavailable",
            }
        } else {
            match plain(&location, GENERIC_READ | GENERIC_WRITE, 0) {
                Ok(pin) => {
                    let mut lease = Lease {
                        generation: previous.generation.clone(),
                        reused: true,
                        previous_status: "verified".into(),
                        file: stream(&pin)?,
                        pin,
                        path: location,
                        _parents: parents,
                    };
                    if lease
                        .verify(previous.bytes as u64, &previous.sha256)
                        .is_ok()
                    {
                        budget::ensure_snapshot(used, bytes.saturating_sub(previous.bytes as u64))?;
                        return Ok(lease);
                    }
                    drop(lease);
                    reason = "previous_contents_changed";
                }
                Err(_) => {
                    reason = "previous_unavailable";
                }
            }
        }
    }
    budget::ensure_snapshot(used, bytes)?;
    let generation = uuid::Uuid::new_v4().simple().to_string();
    let location = directory.join(format!("slot-{product}-{generation}.bin"));
    let (pin, file) = create_plain(&location)?;
    Ok(Lease {
        generation,
        reused: false,
        previous_status: reason.into(),
        pin,
        file,
        path: location,
        _parents: path::pin_directories(&directory)?,
    })
}
pub fn measure(directory: &Path) -> Result<u64> {
    let pin = PinnedFile::open(directory, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, 7)?;
    ensure!(
        pin.identity()?.is_directory() && !pin.identity()?.is_reparse(),
        "Slot storage is not a plain directory"
    );
    let mut used = native::named_stream_bytes(pin.raw())?;
    for name in native::directory_names(pin.raw())? {
        let path = directory.join(name);
        let p = PinnedFile::open(&path, FILE_READ_ATTRIBUTES, 7)?;
        ensure!(
            !p.identity()?.is_directory() && !p.identity()?.is_reparse(),
            "Slot cache contains an unsupported entry"
        );
        used = used
            .checked_add(budget::measure_file(&path)?)
            .ok_or_else(|| anyhow::anyhow!("Slot cache size overflow"))?;
        budget::ensure_snapshot(used, 0)?;
    }
    Ok(used)
}
