mod mach;
pub mod path;
mod queue;
#[allow(unexpected_cfgs)]
#[cfg(all(debug_assertions, prunlet_macos_race_tests))]
mod race_tests;
mod security;

use crate::{config::Config, service::Progress};
use anyhow::{Context, Result, bail};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Identity {
    dev: u64,
    ino: u64,
    mode: u32,
    links: u64,
    len: u64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
impl Identity {
    fn from(meta: &fs::Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
            mode: meta.mode(),
            links: meta.nlink(),
            len: meta.len(),
            mtime: meta.mtime(),
            mtime_ns: meta.mtime_nsec(),
            ctime: meta.ctime(),
            ctime_ns: meta.ctime_nsec(),
        }
    }
    fn same_object(&self, other: &Self) -> bool {
        self.dev == other.dev && self.ino == other.ino && self.mode == other.mode
    }
    fn is_dir(&self) -> bool {
        self.mode & u32::from(libc::S_IFMT) == u32::from(libc::S_IFDIR)
    }
}
#[derive(Clone)]
pub(crate) struct Pinned {
    file: Arc<File>,
    name: PathBuf,
    id: Identity,
}
impl Pinned {
    fn open_at(parent: &Pinned, path: &Path) -> Result<Self> {
        parent.verify_name()?;
        if !parent.id.is_dir() {
            bail!("Parent is not a plain directory");
        }
        let name =
            std::ffi::CString::new(path.file_name().context("Missing leaf name")?.as_bytes())?;
        let mut before: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe {
            libc::fstatat(
                parent.file.as_raw_fd(),
                name.as_ptr(),
                &mut before,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let kind = before.st_mode & libc::S_IFMT;
        if !matches!(kind, libc::S_IFREG | libc::S_IFDIR | libc::S_IFLNK) {
            bail!("Unsupported filesystem entry");
        }
        let flags = if kind == libc::S_IFLNK {
            libc::O_SYMLINK
        } else {
            libc::O_NOFOLLOW
        };
        let fd = unsafe {
            libc::openat(
                parent.file.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NONBLOCK | flags,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let id = Identity::from(&file.metadata()?);
        if id.dev != before.st_dev as u64
            || id.ino != before.st_ino
            || id.mode != u32::from(before.st_mode)
        {
            bail!("Entry changed during descriptor-relative open");
        }
        let result = Self {
            file: Arc::new(file),
            name: path.to_path_buf(),
            id,
        };
        parent.verify_name()?;
        result.verify()?;
        Ok(result)
    }
    fn open(path: &Path) -> Result<Self> {
        let before = fs::symlink_metadata(path)?;
        if !(before.is_file() || before.is_dir() || before.file_type().is_symlink()) {
            bail!("Only files, directories, and symbolic link entries are supported");
        }
        let flags = if before.file_type().is_symlink() {
            libc::O_SYMLINK
        } else {
            libc::O_NOFOLLOW
        };
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(flags | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)?;
        let id = Identity::from(&file.metadata()?);
        if !id.same_object(&Identity::from(&before)) {
            bail!("Object changed while opening");
        }
        let result = Self {
            file: Arc::new(file),
            name: path.into(),
            id,
        };
        result.verify()?;
        Ok(result)
    }
    fn verify(&self) -> Result<()> {
        let current = Identity::from(&fs::symlink_metadata(&self.name)?);
        let fd = Identity::from(&self.file.metadata()?);
        if current != self.id || fd != self.id {
            bail!("Pinned object or name changed: {}", self.name.display());
        }
        Ok(())
    }
    fn verify_name(&self) -> Result<()> {
        if !self.id.same_object(&Identity::from(&self.file.metadata()?))
            || !self
                .id
                .same_object(&Identity::from(&fs::symlink_metadata(&self.name)?))
        {
            bail!("Pinned name or parent changed: {}", self.name.display());
        }
        Ok(())
    }
}

pub fn validate_config(config: &Config) -> Result<()> {
    config.data.validate_fields()?;
    path::resolve(&config.path, true, false)?;
    let root = path::resolve(Path::new(&config.data.backup_directory), true, false)?;
    if root.exists() {
        let pinned = Pinned::open(&root)?;
        let meta = pinned.file.metadata()?;
        if !pinned.id.is_dir()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.mode() & 0o077 != 0
        {
            bail!("Metadata root must be private and owned by the effective user");
        }
        security::reject_acl(pinned.file.as_ref())?;
    }
    for root in config.data.volume_recovery_directories.values() {
        path::resolve(Path::new(root), true, false)?;
    }
    Ok(())
}

pub fn read_plain_file(path: &Path, max_bytes: usize, _reject_streams: bool) -> Result<Vec<u8>> {
    let path = path::resolve(path, false, false)?;
    let parents = path::pin_directories(path.parent().context("Missing parent")?)?;
    let pinned = Pinned::open_at(parents.leaf()?, &path)?;
    if pinned.id.is_dir() || pinned.id.links != 1 || pinned.id.len > max_bytes as u64 {
        bail!("Expected a bounded single-link plain file");
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut pinned.file.as_ref())
        .take((max_bytes as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    pinned.verify()?;
    parents.verify()?;
    if bytes.len() > max_bytes {
        bail!("File exceeds size limit");
    }
    Ok(bytes)
}

pub fn write_new_plain_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let path = path::resolve(path, true, false)?;
    let parent = path.parent().context("Missing parent")?;
    let parents = path::pin_directories(parent)?;
    let meta = fs::metadata(parent)?;
    if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        bail!("Parent must be private and owned by effective user");
    }
    security::reject_acl(&File::open(parent)?)?;
    let mut file = security::create_file(&path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    let id = Identity::from(&file.metadata()?);
    if !id.same_object(&Identity::from(&fs::symlink_metadata(&path)?)) {
        bail!("New file name changed");
    }
    parents.verify()?;
    Ok(())
}

pub(crate) fn private_root(config: &Config) -> Result<PathBuf> {
    let root = path::resolve(Path::new(&config.data.backup_directory), true, false)?;
    if !root.exists() {
        let parent = root.parent().context("Missing parent")?;
        path::reject_reparse_ancestors(parent)?;
        security::reject_acl(&File::open(parent)?)?;
        security::create_dir(&root)?;
    }
    let meta = fs::symlink_metadata(&root)?;
    if !meta.is_dir()
        || meta.file_type().is_symlink()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
    {
        bail!("Metadata root is not private and owned");
    }
    path::reject_reparse_ancestors(&root)?;
    security::reject_acl(&File::open(&root)?)?;
    Ok(root)
}
fn lock(config: &Config, progress: Option<&Progress>) -> Result<File> {
    let name = private_root(config)?.join("maintenance.lock");
    let file = match security::create_file(&name) {
        Ok(file) => file,
        Err(e)
            if e.downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::AlreadyExists) =>
        {
            OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&name)?
        }
        Err(e) => return Err(e),
    };
    security::reject_acl(&file)?;
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.nlink() != 1
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
    {
        bail!("Invalid maintenance lock");
    }
    let mut reported = std::time::Instant::now() - std::time::Duration::from_secs(1);
    loop {
        match FileExt::try_lock_exclusive(&file) {
            Ok(()) => break,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if reported.elapsed() >= std::time::Duration::from_secs(1) {
                    if let Some(progress) = progress {
                        progress(json!({"message":"Waiting for the metadata coordination lock"}));
                    }
                    reported = std::time::Instant::now();
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            Err(error) => return Err(error.into()),
        }
    }
    if !Identity::from(&meta).same_object(&Identity::from(&fs::symlink_metadata(name)?)) {
        bail!("Lock name changed");
    }
    Ok(file)
}

struct Tree {
    nodes: Vec<Pinned>,
    parents: Vec<Pinned>,
}
struct FdBudget {
    capacity: usize,
    queue: bool,
    cache: std::collections::BTreeMap<PathBuf, Pinned>,
}
impl FdBudget {
    fn new(queue: bool) -> Result<Self> {
        let mut limits: libc::rlimit = unsafe { std::mem::zeroed() };
        if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limits) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let used = fs::read_dir("/dev/fd")?.count();
        let available = (limits.rlim_cur as usize).saturating_sub(used + 64);
        let capacity = if queue {
            available.min(4096)
        } else {
            available
        };
        Ok(Self {
            capacity,
            queue,
            cache: std::collections::BTreeMap::new(),
        })
    }
    fn pin(&mut self, path: &Path) -> Result<Pinned> {
        if let Some(pinned) = self.cache.get(path) {
            pinned.verify_name()?;
            return Ok(pinned.clone());
        }
        if self.cache.len() >= self.capacity {
            if !self.queue || self.capacity < 4096 {
                bail!("RLIMIT_NOFILE cannot safely retain this request; no targets were changed");
            }
            bail!("At most 4096 nodes and ancestors may be retained");
        }
        let pinned = Pinned::open(path)?;
        self.cache.insert(path.to_path_buf(), pinned.clone());
        Ok(pinned)
    }
    fn pin_at(&mut self, parent: &Pinned, path: &Path) -> Result<Pinned> {
        if let Some(pinned) = self.cache.get(path) {
            parent.verify_name()?;
            pinned.verify()?;
            return Ok(pinned.clone());
        }
        if self.cache.len() >= self.capacity {
            if !self.queue || self.capacity < 4096 {
                bail!("RLIMIT_NOFILE cannot safely retain this request; no targets were changed");
            }
            bail!("At most 4096 nodes and ancestors may be retained");
        }
        let pinned = Pinned::open_at(parent, path)?;
        self.cache.insert(path.to_path_buf(), pinned.clone());
        Ok(pinned)
    }
}
fn scan_directory(directory: &Pinned, mut observe: impl FnMut(&std::ffi::OsStr)) -> Result<()> {
    directory.verify_name()?;
    let fd = unsafe { libc::fcntl(directory.file.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        unsafe {
            libc::close(fd);
        };
        return Err(std::io::Error::last_os_error().into());
    }
    struct DirectoryStream(*mut libc::DIR);
    impl Drop for DirectoryStream {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let stream = DirectoryStream(stream);
    loop {
        unsafe {
            *libc::__error() = 0;
        }
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(0) {
                return Err(error.into());
            }
            break;
        }
        let name = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name != b"." && name != b".." {
            observe(std::ffi::OsStr::from_bytes(name));
        }
    }
    directory.verify_name()?;
    Ok(())
}
fn directory_names(directory: &Pinned) -> Result<Vec<std::ffi::OsString>> {
    let mut names = Vec::new();
    scan_directory(directory, |name| names.push(name.to_os_string()))?;
    Ok(names)
}
fn directory_is_empty(directory: &Pinned) -> Result<bool> {
    let mut empty = true;
    // 空判定でも最後まで読み、後続readdir失敗と前後の名前変更を検出する。
    scan_directory(directory, |_| empty = false)?;
    Ok(empty)
}
#[cfg(test)]
mod directory_scan_tests {
    use super::*;
    use std::os::unix::fs::DirBuilderExt;

    fn fixture() -> PathBuf {
        let root = PathBuf::from(
            std::env::var_os("PRUNLET_MACOS_UNIT_TEST_ROOT").expect("isolated fixture root"),
        );
        let root = path::resolve(&root, false, false).unwrap();
        let parent = Pinned::open(&root).unwrap();
        let meta = parent.file.metadata().unwrap();
        assert!(
            meta.is_dir() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o077 == 0
        );
        let directory = root.join(uuid::Uuid::new_v4().simple().to_string());
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        parent.verify_name().unwrap();
        directory
    }
    #[test]
    fn empty_check_and_names_preserve_entries_and_close_failed_stream_fd() {
        let directory = fixture();
        assert!(directory_is_empty(&Pinned::open(&directory).unwrap()).unwrap());
        for index in 0..64 {
            fs::write(directory.join(index.to_string()), b"fixture").unwrap();
        }
        let unicode = std::ffi::OsString::from("空白 α.txt");
        fs::write(directory.join(&unicode), b"fixture").unwrap();
        assert!(!directory_is_empty(&Pinned::open(&directory).unwrap()).unwrap());
        let names = directory_names(&Pinned::open(&directory).unwrap()).unwrap();
        assert_eq!(names.len(), 65);
        assert!(names.contains(&unicode));
        let file = Pinned::open(&directory.join("0")).unwrap();
        let before = fs::read_dir("/dev/fd").unwrap().count();
        assert!(directory_is_empty(&file).is_err());
        assert_eq!(fs::read_dir("/dev/fd").unwrap().count(), before);
    }
    #[test]
    fn scan_finishes_all_entries_before_rejecting_changed_name_and_closes_fd() {
        let directory = fixture();
        fs::write(directory.join("first"), b"fixture").unwrap();
        fs::write(directory.join("second"), b"fixture").unwrap();
        let pinned = Pinned::open(&directory).unwrap();
        let parked = directory.with_extension("parked");
        let before = fs::read_dir("/dev/fd").unwrap().count();
        let mut observed = 0;
        let result = scan_directory(&pinned, |_| {
            observed += 1;
            if observed == 1 {
                fs::rename(&directory, &parked).unwrap();
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(&directory)
                    .unwrap();
            }
        });
        assert!(result.is_err());
        assert_eq!(observed, 2);
        assert_eq!(fs::read_dir("/dev/fd").unwrap().count(), before);
        assert!(parked.join("first").exists() && parked.join("second").exists());
    }
}
fn snapshot(path: &Path, recursive: bool, queue: bool, budget: &mut FdBudget) -> Result<Tree> {
    fn visit(
        path: &Path,
        parent: &Pinned,
        recursive: bool,
        nodes: &mut Vec<Pinned>,
        budget: &mut FdBudget,
    ) -> Result<()> {
        let pinned = budget.pin_at(parent, path)?;
        if pinned.id.is_dir() {
            if recursive {
                for child in directory_names(&pinned)? {
                    visit(&path.join(child), &pinned, recursive, nodes, budget)?;
                }
            } else if !directory_is_empty(&pinned)? {
                bail!("Nonempty directory requires recursive=true");
            }
        }
        nodes.push(pinned);
        Ok(())
    }
    let mut tree = Tree {
        nodes: Vec::new(),
        parents: Vec::new(),
    };
    let mut parent = path.parent();
    while let Some(p) = parent {
        let pinned = budget.pin(p)?;
        if !pinned.id.is_dir() {
            bail!("Ancestor is not a plain directory");
        }
        tree.parents.push(pinned);
        parent = p.parent();
    }
    let parent = tree
        .parents
        .first()
        .context("Missing pinned parent")?
        .clone();
    if queue {
        visit(path, &parent, recursive, &mut tree.nodes, budget)?;
    } else {
        // 同期Trashはroot entryだけを移す。子を操作・追跡せず、待機予約だけが
        // 全子の変更検知を必要とする。大きなtreeの子FDを保持しない。
        let pinned = budget.pin_at(&parent, path)?;
        if pinned.id.is_dir() && !recursive && !directory_is_empty(&pinned)? {
            bail!("Nonempty directory requires recursive=true");
        }
        tree.nodes.push(pinned);
    }
    verify_tree(&tree)?;
    Ok(tree)
}
fn verify_tree(tree: &Tree) -> Result<()> {
    verify_tree_after_moves(tree, &std::collections::BTreeMap::new())
}
fn verify_tree_after_moves(
    tree: &Tree,
    moved: &std::collections::BTreeMap<(u64, u64), Identity>,
) -> Result<()> {
    for pinned in &tree.parents {
        if !pinned.id.is_dir()
            || !pinned
                .id
                .same_object(&Identity::from(&pinned.file.metadata()?))
            || !pinned
                .id
                .same_object(&Identity::from(&fs::symlink_metadata(&pinned.name)?))
        {
            bail!("Parent identity changed");
        }
    }
    for pinned in &tree.nodes {
        let mut expected = pinned.id.clone();
        // 自分がTrashへ移した別hardlinkで変化したctimeだけを引き継ぐ。
        // 内容・mode・link数の変化は引き続き拒否する。
        if let Some(own_move) = moved.get(&(expected.dev, expected.ino)) {
            expected.ctime = own_move.ctime;
            expected.ctime_ns = own_move.ctime_ns;
        }
        if Identity::from(&pinned.file.metadata()?) != expected
            || Identity::from(&fs::symlink_metadata(&pinned.name)?) != expected
        {
            bail!("Pinned object or name changed: {}", pinned.name.display());
        }
    }
    Ok(())
}

#[allow(unexpected_cfgs)]
fn trash(path: &Path, expected: &Identity) -> Result<()> {
    use objc2_foundation::{NSFileManager, NSString, NSURL};
    objc2::rc::autoreleasepool(|_| {
        let text = NSString::from_str(path.to_str().context("Path is not UTF-8")?);
        let url = NSURL::fileURLWithPath(&text);
        let mut result = None;
        NSFileManager::defaultManager()
            .trashItemAtURL_resultingItemURL_error(&url, Some(&mut result))
            .map_err(|e| anyhow::anyhow!("Native Trash error: {e}"))?;
        let result = result.context("ambiguous: Trash did not return resulting URL")?;
        let returned = result
            .path()
            .context("ambiguous: Trash URL has no filesystem path")?;
        let returned = PathBuf::from(returned.to_string());
        #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
        race_tests::barrier(
            "trash-before-result-pin",
            json!({"resultPath":returned,"expected":expected}),
        )
        .context("ambiguous: Race test boundary failed after native Trash")?;
        let returned = path::resolve(&returned, false, true)
            .context("ambiguous: Cannot validate Trash ancestors")?;
        let target = Pinned::open(&returned)
            .context("ambiguous: Cannot open Trash result without following links")?;
        if !expected.same_object(&target.id) {
            bail!("ambiguous: Trash result identity mismatch");
        }
        match fs::symlink_metadata(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            _ => bail!(
                "ambiguous: Original name is still present or its absence cannot be established"
            ),
        }
        Ok(())
    })
}

pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    validate_config(config)?;
    if command != "delete" {
        return queue::execute(config, command, args, progress);
    }
    execute_delete(config, args, progress, None)
}

pub(super) struct Reservation {
    prepared: Vec<(PathBuf, Tree)>,
}

pub(super) fn prepare_queue(config: &Config, args: &Value) -> Result<Reservation> {
    let mut dry = args.clone();
    dry["dryRun"] = json!(true);
    let mut capture = None;
    execute_delete_inner(config, &dry, None, None, Some(&mut capture))?;
    capture.context("Queue preflight did not produce a reservation")
}

pub(super) fn execute_delete(
    config: &Config,
    args: &Value,
    progress: Option<Progress>,
    reservation: Option<Reservation>,
) -> Result<Value> {
    execute_delete_inner(config, args, progress, reservation, None)
}
#[allow(unexpected_cfgs)]
pub(super) fn execute_delete_inner(
    config: &Config,
    args: &Value,
    progress: Option<Progress>,
    mut reservation: Option<Reservation>,
    capture: Option<&mut Option<Reservation>>,
) -> Result<Value> {
    let dry_run = args.get("dryRun").and_then(Value::as_bool).unwrap_or(false);
    let recursive = args
        .get("recursive")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let raw = args
        .get("paths")
        .and_then(Value::as_array)
        .context("paths must be an array")?;
    if raw.is_empty() || raw.len() > 4096 {
        bail!("paths must contain 1..4096 entries");
    }
    let _lock = lock(config, progress.as_ref())?;
    let metadata = path::resolve(Path::new(&config.data.backup_directory), true, false)?;
    let config_path = path::resolve(&config.path, true, false)?;
    let mut protected_roots = vec![
        metadata.clone(),
        config_path.clone(),
        queue::reserved_namespace_path()?,
    ];
    for root in config.data.volume_recovery_directories.values() {
        protected_roots.push(path::resolve(Path::new(root), true, false)?);
    }
    let mut prepared = Vec::new();
    let mut errors = Vec::new();
    let reserved = reservation.is_some();
    let queue_capture = capture.is_some();
    let mut budget = FdBudget::new(queue_capture)?;
    for value in raw {
        let input = value.as_str().context("path must be a string")?;
        let prepare = (|| -> Result<(PathBuf, Option<Tree>)> {
            let p = path::resolve(Path::new(input), true, true)?;
            if p == Path::new("/")
                || protected_roots
                    .iter()
                    .any(|root| path::within(root, &p) || path::within(&p, root))
            {
                bail!("Protected metadata/configuration path");
            }
            if prepared.iter().any(|(other, _): &(PathBuf, Option<Tree>)| {
                path::within(&p, other) || path::within(other, &p)
            }) {
                bail!("Overlapping targets are not permitted");
            }
            #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
            race_tests::barrier("delete-before-snapshot", json!({"path":p}))?;
            let tree = if let Some(held) = reservation.as_mut() {
                let index = held
                    .prepared
                    .iter()
                    .position(|(name, _)| name == &p)
                    .context("Path differs from the registered target")?;
                let (_, tree) = held.prepared.remove(index);
                verify_tree(&tree)?;
                Some(tree)
            } else {
                match fs::symlink_metadata(&p) {
                    Ok(_) => Some(snapshot(&p, recursive, queue_capture, &mut budget)?),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                    Err(e) => return Err(e.into()),
                }
            };
            if let Some(tree) = &tree {
                let root = &tree.nodes.last().context("Empty snapshot")?.id;
                for (other_path, other_tree) in &prepared {
                    if let Some(other_tree) = other_tree {
                        let other_root =
                            &other_tree.nodes.last().context("Empty prior snapshot")?.id;
                        if (root.is_dir()
                            && other_tree.parents.iter().any(|p| root.same_object(&p.id)))
                            || (other_root.is_dir()
                                && tree.parents.iter().any(|p| other_root.same_object(&p.id)))
                            || (root.is_dir() && root.same_object(other_root))
                            || (root.same_object(other_root)
                                && fs::canonicalize(&p)? == fs::canonicalize(other_path)?)
                        {
                            bail!("Targets overlap by native filesystem identity");
                        }
                    }
                }
                // 大文字小文字の規則を模倣せず、実際のvolume上の同一実体を照合する。
                for protected in &protected_roots {
                    let mut ancestor = Some(protected.as_path());
                    while let Some(name) = ancestor {
                        if let Ok(meta) = fs::symlink_metadata(name)
                            && root.same_object(&Identity::from(&meta))
                        {
                            bail!("Target contains a protected object");
                        }
                        ancestor = name.parent();
                    }
                    if let Ok(meta) = fs::symlink_metadata(protected) {
                        let id = Identity::from(&meta);
                        if tree
                            .nodes
                            .iter()
                            .chain(tree.parents.iter())
                            .any(|node| node.id.same_object(&id))
                        {
                            bail!("Target aliases protected metadata");
                        }
                    }
                }
            }
            Ok((p, tree))
        })();
        match prepare {
            Ok(p) => {
                errors.push(None);
                prepared.push(p);
            }
            Err(e) => {
                errors.push(Some(e.to_string()));
                prepared.push((PathBuf::from(input), None));
            }
        }
    }
    if reservation.as_ref().is_some_and(|r| !r.prepared.is_empty()) {
        bail!("Registered target set changed; targets were preserved");
    }
    if let Some(capture) = capture {
        if errors.iter().any(Option::is_some) || prepared.iter().any(|(_, tree)| tree.is_none()) {
            bail!(
                "Queue preflight failed; targets were preserved: {:?}",
                errors
            );
        }
        *capture = Some(Reservation {
            prepared: prepared
                .into_iter()
                .map(|(path, tree)| (path, tree.unwrap()))
                .collect(),
        });
        return Ok(json!({"dryRun":true,"items":[],"warnings":[]}));
    }
    if !dry_run && !errors.iter().any(Option::is_some) {
        let mut identities = std::collections::BTreeSet::new();
        for (index, (_, tree)) in prepared.iter().enumerate() {
            if let Some(tree) = tree {
                for node in &tree.nodes {
                    let already_locked = reserved;
                    if !already_locked
                        && node.id.mode & u32::from(libc::S_IFMT) != u32::from(libc::S_IFLNK)
                        && identities.insert((node.id.dev, node.id.ino))
                        && let Err(e) = FileExt::try_lock_exclusive(node.file.as_ref())
                    {
                        errors[index] =
                            Some(format!("Target is held by a cooperating request: {e}"));
                        break;
                    }
                }
            }
        }
    }
    let failed = errors.iter().any(Option::is_some);
    let mut items = Vec::new();
    let mut stopped = false;
    let mut moved = std::collections::BTreeMap::new();
    for (index, ((p, tree), error)) in prepared.iter().zip(errors.iter()).enumerate() {
        let kind = tree
            .as_ref()
            .and_then(|t| t.nodes.last())
            .map(|n| {
                if n.id.is_dir() {
                    "directory"
                } else if n.id.mode & u32::from(libc::S_IFMT) == u32::from(libc::S_IFLNK) {
                    "symlink"
                } else {
                    "file"
                }
            })
            .unwrap_or("unknown");
        let mut item = json!({"path":p,"kind":kind,"status":"failed"});
        if stopped {
            item["error"] = json!("Preserved because an earlier result was ambiguous");
        } else if failed {
            item["error"] = json!(
                error
                    .as_deref()
                    .unwrap_or("All targets were preserved because preflight failed")
            );
        } else if let Some(tree) = tree {
            if dry_run {
                item["status"] = json!("would_recycle");
            } else {
                let result = verify_tree_after_moves(tree, &moved)
                    .and_then(|_| trash(p, &tree.nodes.last().unwrap().id));
                match result {
                    Ok(()) => {
                        item["status"] = json!("recycled");
                        let root = tree.nodes.last().unwrap();
                        match root.file.metadata() {
                            Ok(meta) => {
                                moved.insert((root.id.dev, root.id.ino), Identity::from(&meta));
                            }
                            Err(e) => {
                                stopped = true;
                                item["status"] = json!("ambiguous");
                                item["error"] = json!(format!(
                                    "Cannot inspect retained identity after Trash: {e}"
                                ));
                            }
                        }
                    }
                    Err(e) => {
                        stopped = e.to_string().contains("ambiguous:");
                        item["status"] = json!(if stopped { "ambiguous" } else { "failed" });
                        item["error"] = json!(e.to_string());
                    }
                }
            }
        } else {
            item["status"] = json!("already_absent");
        }
        items.push(item);
        if let Some(progress) = &progress {
            progress(json!({"completed":index+1,"total":prepared.len()}));
        }
    }
    Ok(json!({"dryRun":dry_run,"items":items,"warnings":[]}))
}
