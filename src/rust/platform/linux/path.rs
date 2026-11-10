use anyhow::{Context, Result, ensure};
use std::{
    ffi::{CStr, CString, OsStr},
    fs::{self, File, ReadDir},
    io,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::OsStrExt,
    },
    path::{Component, Path, PathBuf},
};

pub fn absolute(path: &Path) -> Result<PathBuf> {
    let bytes = path.as_os_str().as_bytes();
    ensure!(
        path.is_absolute()
            && !bytes.contains(&0)
            && !bytes
                .split(|&b| b == b'/')
                .any(|part| matches!(part, b"." | b"..")),
        "Use an absolute path without dot components or NUL"
    );
    Ok(path.components().collect())
}

pub fn resolve(path: &Path, allow_missing: bool, allow_link_leaf: bool) -> Result<PathBuf> {
    let path = absolute(path)?;
    if let Some(parent) = path.parent() {
        match Dir::open(parent).and_then(|dir| dir.entry(path.file_name().unwrap())) {
            Ok(entry) => ensure!(
                allow_link_leaf || entry.kind() != libc::S_IFLNK,
                "Symbolic link is not allowed"
            ),
            Err(error) if allow_missing && absent(&error) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(path)
}

pub(super) fn absent(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<io::Error>()
        .is_some_and(|error| error.kind() == io::ErrorKind::NotFound)
}

pub(super) fn name(value: &OsStr) -> Result<CString> {
    let bytes = value.as_bytes();
    ensure!(
        !bytes.is_empty() && !bytes.contains(&b'/') && !matches!(bytes, b"." | b".."),
        "Invalid entry name"
    );
    Ok(CString::new(bytes)?)
}

#[derive(Clone, Copy, Debug)]
pub(super) struct Entry {
    pub(super) device: (u32, u32),
    pub(super) mount: u64,
    pub(super) inode: u64,
    pub(super) mode: u32,
    pub(super) uid: u32,
}

impl Entry {
    pub(super) fn kind(self) -> u32 {
        self.mode & libc::S_IFMT
    }

    pub(super) fn aliases(self, other: Self) -> bool {
        self.device == other.device && self.inode == other.inode
    }

    pub(super) fn matches(self, other: Self) -> bool {
        self.aliases(other) && self.mount == other.mount && self.kind() == other.kind()
    }
}

fn stat(dir: i32, name: &CStr, flags: i32) -> Result<Entry> {
    // マウントIDも確認し、同じデバイス番号のbind mountを区別する。
    let requested = libc::STATX_TYPE
        | libc::STATX_MODE
        | libc::STATX_UID
        | libc::STATX_INO
        | libc::STATX_MNT_ID;
    let mut result = std::mem::MaybeUninit::<libc::statx>::zeroed();
    if unsafe { libc::statx(dir, name.as_ptr(), flags, requested, result.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    let result = unsafe { result.assume_init() };
    ensure!(
        result.stx_mask & requested == requested,
        "File identity or mount information is unavailable"
    );
    Ok(Entry {
        device: (result.stx_dev_major, result.stx_dev_minor),
        mount: result.stx_mnt_id,
        inode: result.stx_ino,
        mode: result.stx_mode.into(),
        uid: result.stx_uid,
    })
}

pub(super) fn file_entry(file: &File) -> Result<Entry> {
    stat(file.as_raw_fd(), c"", libc::AT_EMPTY_PATH)
}

pub(super) struct Dir {
    pub(super) file: File,
    pub(super) identity: Entry,
}

impl Dir {
    // 検査した親のfdから次の階層を開き、名前の途中にあるリンクを辿らない。
    fn walk(path: &Path, create: bool, nearest: bool) -> Result<Self> {
        let path = absolute(path)?;
        let mut dir = Self::from_file(open_at(libc::AT_FDCWD, c"/", directory_flags(), 0)?)?;
        for part in path.components() {
            let Component::Normal(part) = part else {
                continue;
            };
            dir = match dir.child(part) {
                Ok(child) => child,
                Err(error) if absent(&error) && create => dir.create_child(part)?,
                Err(error) if absent(&error) && nearest => return Ok(dir),
                Err(error) => return Err(error),
            };
        }
        Ok(dir)
    }

    fn from_file(file: File) -> Result<Self> {
        let identity = file_entry(&file)?;
        Ok(Self { file, identity })
    }

    pub(super) fn open(path: &Path) -> Result<Self> {
        Self::walk(path, false, false)
    }
    pub(super) fn nearest(path: &Path) -> Result<Self> {
        Self::walk(path, false, true)
    }
    pub(super) fn create_all(path: &Path) -> Result<Self> {
        Self::walk(path, true, false)
    }

    pub(super) fn child(&self, child: &OsStr) -> Result<Self> {
        Self::from_file(open_at(self.fd(), &name(child)?, directory_flags(), 0)?)
    }

    pub(super) fn create_child(&self, child: &OsStr) -> Result<Self> {
        let child_name = name(child)?;
        if unsafe { libc::mkdirat(self.fd(), child_name.as_ptr(), 0o700) } != 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error.into());
            }
        }
        let dir = self.child(child)?;
        dir.private()?;
        Ok(dir)
    }

    pub(super) fn private(&self) -> Result<()> {
        ensure!(
            self.identity.uid == unsafe { libc::geteuid() } && self.identity.mode & 0o077 == 0,
            "Directory must be private and owned by the effective user"
        );
        Ok(())
    }

    pub(super) fn verify(&self, path: &Path) -> Result<()> {
        ensure!(
            self.identity.matches(Self::open(path)?.identity),
            "Directory changed during the request"
        );
        Ok(())
    }

    pub(super) fn fd(&self) -> i32 {
        self.file.as_raw_fd()
    }

    pub(super) fn entry(&self, child: &OsStr) -> Result<Entry> {
        stat(self.fd(), &name(child)?, libc::AT_SYMLINK_NOFOLLOW)
    }

    pub(super) fn entries(&self) -> Result<ReadDir> {
        fs::read_dir(format!("/proc/self/fd/{}", self.fd()))
            .context("Cannot inspect directory entries")
    }

    pub(super) fn open_file(&self, child: &OsStr, flags: i32, mode: u32) -> Result<File> {
        open_at(
            self.fd(),
            &name(child)?,
            flags | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            mode,
        )
    }

    pub(super) fn sync(&self) -> Result<()> {
        self.open_for_io()?.sync_all()?;
        Ok(())
    }

    pub(super) fn open_for_io(&self) -> Result<File> {
        open_at(self.fd(), c".", libc::O_RDONLY | libc::O_DIRECTORY, 0)
    }
}

fn directory_flags() -> i32 {
    libc::O_PATH | libc::O_DIRECTORY | libc::O_NOFOLLOW
}

fn open_at(dir: i32, path: &CStr, flags: i32, mode: u32) -> Result<File> {
    let fd = unsafe { libc::openat(dir, path.as_ptr(), flags | libc::O_CLOEXEC, mode) };
    if fd < 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
