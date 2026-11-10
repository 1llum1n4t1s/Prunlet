//! 専用cfgとdebugビルドだけに存在する実プロセス競合検証用の停止点。
use super::*;
use std::time::{Duration, Instant};

pub(super) fn barrier(point: &str, details: Value) -> Result<()> {
    if std::env::var("PRUNLET_MACOS_RACE_POINT").ok().as_deref() != Some(point) {
        return Ok(());
    }
    let root = PathBuf::from(
        std::env::var_os("PRUNLET_MACOS_RACE_ROOT").context("Missing isolated race root")?,
    );
    let root = path::resolve(&root, false, false)?;
    let directory = Pinned::open(&root)?;
    let meta = directory.file.metadata()?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        bail!("Race control root must be private and owned");
    }
    write_new_plain_file(
        &root.join("ready.json"),
        &serde_json::to_vec(&json!({"point":point,"details":details}))?,
    )?;
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        directory.verify_name()?;
        match fs::symlink_metadata(root.join("release")) {
            Ok(_) => {
                read_plain_file(&root.join("release"), 16, true)?;
                return Ok(());
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(e) => return Err(e.into()),
        }
    }
}
