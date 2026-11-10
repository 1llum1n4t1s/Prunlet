//! Linuxの管理済み単一実行体を、同じbin内の新inodeで原子的に更新する。
use super::{
    create_file, package,
    path::{self, Dir, absent, file_entry},
    remove_created_file,
};
use crate::{
    config::Config,
    json::parse_unique,
    update::{github, package::is_hex},
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{
    env,
    ffi::OsStr,
    fs::{self, File, Permissions},
    io::{self, ErrorKind, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{MetadataExt, PermissionsExt},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const COMMIT: &str = env!("PRUNLET_SOURCE_COMMIT");
const RUNTIME: &str = if cfg!(target_arch = "x86_64") {
    "linux-x64"
} else {
    "linux-arm64"
};
const LOCK: &str = ".prunlet-linux-update.lock";
const NEXT: &str = ".prunlet-next";

pub(crate) fn build_info() -> Value {
    metadata(crate::VERSION, COMMIT)
}

fn metadata(version: &str, commit: &str) -> Value {
    json!({"version": version, "commit": commit, "runtime": RUNTIME})
}

fn executable_root() -> Result<Option<PathBuf>> {
    let path = env::current_exe()?;
    let leaf = path.file_name();
    // rename後に旧inodeで既に起動した入口を、Linuxのdeleted表記でも識別する。
    let stale = leaf == Some(OsStr::new("prunlet (deleted)")) && !path.try_exists()?;
    if leaf != Some(OsStr::new("prunlet")) && !stale {
        return Ok(None);
    }
    let Some(bin) = path
        .parent()
        .filter(|dir| dir.file_name() == Some(OsStr::new("bin")))
    else {
        return Ok(None);
    };
    Ok(bin.parent().map(Path::to_path_buf))
}

pub(super) fn installation_root() -> Result<Option<PathBuf>> {
    let Some(root) = executable_root()? else {
        return Ok(None);
    };
    match Dir::open(&root)?.entry(OsStr::new(LOCK)) {
        Ok(_) => Ok(Some(root)),
        Err(error) if absent(&error) => Ok(None),
        Err(error) => Err(error),
    }
}

fn private_file(dir: &Dir, leaf: &OsStr, flags: i32) -> Result<File> {
    let entry = dir.entry(leaf)?;
    ensure!(
        entry.kind() == libc::S_IFREG,
        "Expected a plain managed Linux file"
    );
    let file = dir.open_file(leaf, flags, 0)?;
    let meta = file.metadata()?;
    ensure!(
        entry.matches(file_entry(&file)?)
            && meta.nlink() == 1
            && meta.uid() == unsafe { libc::geteuid() }
            && meta.mode() & 0o7077 == 0,
        "Managed Linux file is not private and owned"
    );
    Ok(file)
}

fn verify_name(dir: &Dir, name: &OsStr, file: &File) -> Result<()> {
    ensure!(
        file_entry(file)?.matches(dir.entry(name)?),
        "Managed Linux file name changed"
    );
    Ok(())
}

fn program(file: &File) -> Command {
    Command::new(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

pub(crate) fn enter(config: &Path, command: &str, args: &[String]) -> Result<Option<File>> {
    let Some(root_path) = executable_root()? else {
        return Ok(None);
    };
    let root = Dir::open(&root_path)?;
    let bin_path = root_path.join("bin");
    let bin = root.child(OsStr::new("bin"))?;
    let lock_name = OsStr::new(LOCK);
    let marked = match root.entry(lock_name) {
        Ok(_) => true,
        Err(error) if absent(&error) => false,
        Err(error) => return Err(error),
    };
    let official = is_hex(COMMIT, 40);
    if !marked
        && (!official || command == "init" || root.private().is_err() || bin.private().is_err())
    {
        return Ok(None);
    }
    if !marked {
        match root.entry(OsStr::new("config.json")) {
            Ok(entry) if entry.kind() == libc::S_IFREG => {}
            Ok(_) => return Ok(None),
            Err(error) if absent(&error) => return Ok(None),
            Err(error) => return Err(error),
        }
    }
    root.private()?;
    bin.private()?;
    ensure!(
        bin.identity.mount == root.identity.mount,
        "Managed Linux bin is on a separate mount"
    );
    if !marked {
        match create_file(&root, lock_name) {
            Ok(_) => {}
            Err(error)
                if error
                    .downcast_ref::<io::Error>()
                    .is_some_and(|err| err.kind() == ErrorKind::AlreadyExists) => {}
            Err(error) => return Err(error),
        }
    }
    let lock = private_file(&root, lock_name, libc::O_RDWR)?;
    ensure!(
        file_entry(&lock)?.mount == root.identity.mount,
        "Update lock is on a separate mount"
    );
    let exe_name = OsStr::new("prunlet");
    let running = file_entry(&File::open("/proc/self/exe")?)?;
    let should_check =
        official && command == "mcp" && args.len() == 3 && config == root_path.join("config.json");
    if should_check {
        match fs2::FileExt::try_lock_exclusive(&lock) {
            Ok(()) => {
                root.verify(&root_path)?;
                bin.verify(&bin_path)?;
                verify_name(&root, lock_name, &lock)?;
                let current = private_file(&bin, exe_name, libc::O_RDONLY)?;
                if running.matches(file_entry(&current)?) {
                    // 既存設定を読めない場合も、通常のMCP初期化に判断を委ねる。
                    let result = Config::load(config)
                        .and_then(|_| update(&root_path, &root, &bin, &lock, &current));
                    if let Err(error) = result {
                        eprintln!("Prunlet Linux startup update deferred: {error}");
                    }
                }
                fs2::FileExt::unlock(&lock)?;
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.into()),
        }
    }
    fs2::FileExt::lock_shared(&lock)?;
    root.verify(&root_path)?;
    bin.verify(&bin_path)?;
    verify_name(&root, lock_name, &lock)?;
    let current = private_file(&bin, exe_name, libc::O_RDONLY)?;
    if !running.matches(file_entry(&current)?) {
        drop(lock);
        return Err(program(&current).args(args).exec().into());
    }
    Ok(Some(lock))
}

fn request(url: &str, limit: u64, seconds: u32) -> Result<Vec<u8>> {
    #[cfg(all(debug_assertions, prunlet_linux_update_tests))]
    if let Some(root) = env::var_os("PRUNLET_LINUX_UPDATE_FIXTURE") {
        use sha2::{Digest, Sha256};
        let name = hex::encode(Sha256::digest(url.as_bytes()));
        return super::read_plain_file(&PathBuf::from(root).join(name), limit as usize, true);
    }
    github::request(url, limit, seconds)
}

fn update(root_path: &Path, root: &Dir, bin: &Dir, lock: &File, current: &File) -> Result<()> {
    let asset = format!("prunlet-{RUNTIME}.tar.gz");
    let Some(candidate) = github::newer(request, COMMIT, &asset, package::MAX_PACKAGE)? else {
        return Ok(());
    };
    let bytes = package::executable(
        &candidate.bytes,
        &candidate.version,
        &candidate.commit,
        RUNTIME,
    )?;
    let stage = OsStr::new(NEXT);
    let exe = OsStr::new("prunlet");
    let bin_path = root_path.join("bin");
    root.verify(root_path)?;
    bin.verify(&bin_path)?;
    verify_name(root, OsStr::new(LOCK), lock)?;
    match private_file(bin, stage, libc::O_RDONLY) {
        Ok(previous) => {
            ensure!(
                file_entry(&previous)?.mount == bin.identity.mount,
                "Update stage is on a separate mount"
            );
            // 中断で残ったこの管理名のファイルだけを回収する。リンクや別実体は拒否する。
            remove_created_file(bin, stage, &previous)?;
        }
        Err(error) if absent(&error) => {}
        Err(error) => return Err(error),
    }
    let mut staged = create_file(bin, stage)?;
    staged.write_all(&bytes)?;
    staged.set_permissions(Permissions::from_mode(0o700))?;
    staged.sync_all()?;
    // Linuxは書込みfdが開いた実行体のexecを拒否する。名前とinodeを照合して読取fdへ切り替える。
    let read = private_file(bin, stage, libc::O_RDONLY)?;
    ensure!(
        file_entry(&staged)?.matches(file_entry(&read)?),
        "Staged executable changed"
    );
    drop(staged);
    let info = program(&read)
        .arg("--linux-build-info")
        .stdin(Stdio::null())
        .output()?;
    ensure!(
        info.status.success()
            && parse_unique(&info.stdout)? == metadata(&candidate.version, &candidate.commit),
        "Staged Linux executable metadata differs"
    );
    let directory = bin.open_for_io()?;
    root.verify(root_path)?;
    bin.verify(&bin_path)?;
    verify_name(root, OsStr::new(LOCK), lock)?;
    verify_name(bin, stage, &read)?;
    verify_name(bin, exe, current)?;
    // 設定と復元領域には触れず、検証済みの実行体だけを同一ディレクトリで交換する。
    if unsafe {
        libc::renameat(
            bin.fd(),
            c".prunlet-next".as_ptr(),
            bin.fd(),
            c"prunlet".as_ptr(),
        )
    } != 0
    {
        return Err(io::Error::last_os_error().into());
    }
    directory.sync_all()?;
    Ok(())
}
