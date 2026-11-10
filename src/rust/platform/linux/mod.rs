pub mod path;
mod package;
pub(crate) mod startup;

use crate::{config::Config, service::Progress};
use anyhow::{Context, Result, bail, ensure};
use path::{Dir, Entry, absent, file_entry};
use serde_json::{Value, json};
use std::{
    env,
    ffi::{OsStr, OsString},
    fs::{File, Metadata},
    io::{self, Read, Write},
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
};

fn parent_and_leaf(path: &Path) -> Result<(Dir, &OsStr)> {
    let parent = path.parent().context("Root has no parent")?;
    Ok((
        Dir::open(parent)?,
        path.file_name().context("Missing entry name")?,
    ))
}

pub fn read_plain_file(path: &Path, limit: usize, _reject_streams: bool) -> Result<Vec<u8>> {
    let path = path::absolute(path)?;
    let (parent, leaf) = parent_and_leaf(&path)?;
    let entry = parent.entry(leaf)?;
    ensure!(entry.kind() == libc::S_IFREG, "Expected a plain file");
    let mut file = parent.open_file(leaf, libc::O_RDONLY, 0)?;
    ensure!(
        entry.matches(file_entry(&file)?),
        "File changed while opening"
    );
    let before = file.metadata()?;
    ensure!(
        before.nlink() == 1 && before.len() <= limit as u64,
        "Expected a bounded single-link plain file"
    );
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take((limit as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 == before.len()
            && same_contents(&before, &file.metadata()?)
            && entry.matches(parent.entry(leaf)?),
        "File changed while reading"
    );
    parent.verify(path.parent().unwrap())?;
    Ok(bytes)
}

fn same_contents(before: &Metadata, after: &Metadata) -> bool {
    before.len() == after.len()
        && before.nlink() == after.nlink()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}

pub fn write_new_plain_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let path = path::absolute(path)?;
    let (parent, leaf) = parent_and_leaf(&path)?;
    parent.private()?;
    let mut file = create_file(&parent, leaf)?;
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        parent.verify(path.parent().unwrap())?;
        ensure!(
            file_entry(&file)?.matches(parent.entry(leaf)?),
            "Created file changed"
        );
        parent.sync()
    })();
    if result.is_err() {
        let _ = remove_created_file(&parent, leaf, &file);
    }
    result
}

fn create_file(parent: &Dir, leaf: &OsStr) -> Result<File> {
    parent.open_file(leaf, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600)
}

fn remove_created_file(parent: &Dir, leaf: &OsStr, file: &File) -> Result<()> {
    ensure!(
        file_entry(file)?.matches(parent.entry(leaf)?),
        "Created file no longer owns its name"
    );
    let leaf = path::name(leaf)?;
    if unsafe { libc::unlinkat(parent.fd(), leaf.as_ptr(), 0) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    parent.sync()
}

pub fn validate_config(config: &Config) -> Result<()> {
    config.data.validate_fields()?;
    let backup = Dir::open(Path::new(&config.data.backup_directory))?;
    backup.private()?;
    for root in config.data.volume_recovery_directories.values() {
        path::resolve(Path::new(root), true, false)?;
    }
    Ok(())
}

fn home_trash() -> Result<PathBuf> {
    let data = match env::var_os("XDG_DATA_HOME").filter(|value| Path::new(value).is_absolute()) {
        Some(data) => PathBuf::from(data),
        None => PathBuf::from(env::var_os("HOME").context("HOME is not set")?).join(".local/share"),
    };
    path::absolute(&data.join("Trash"))
}

struct Trash {
    root: PathBuf,
    info: Dir,
    files: Dir,
    _lease: File,
}

impl Trash {
    fn open(root: &Path) -> Result<Self> {
        let dir = Dir::create_all(root)?;
        dir.private()?;
        // 設定が異なる要求も、同じTrashへ移す間はディレクトリfdのflockで直列化する。
        let lease = dir.open_for_io()?;
        fs2::FileExt::lock_exclusive(&lease)?;
        dir.verify(root)?;
        let child = |name: &str| -> Result<Dir> {
            let child = dir.create_child(OsStr::new(name))?;
            Self::check_child(&dir, &child)?;
            Ok(child)
        };
        Ok(Self {
            root: root.into(),
            info: child("info")?,
            files: child("files")?,
            _lease: lease,
        })
    }

    fn check_child(parent: &Dir, child: &Dir) -> Result<()> {
        child.private()?;
        ensure!(
            child.identity.mount == parent.identity.mount,
            "Trash children must share its mount"
        );
        Ok(())
    }

    fn inspect(root: &Path) -> Result<()> {
        let dir = match Dir::open(root) {
            Ok(dir) => dir,
            Err(error) if absent(&error) => return Ok(()),
            Err(error) => return Err(error),
        };
        dir.private()?;
        for name in ["info", "files"] {
            match dir.child(OsStr::new(name)) {
                Ok(child) => Self::check_child(&dir, &child)?,
                Err(error) if absent(&error) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }

    fn verify(&self) -> Result<()> {
        self.info.verify(&self.root.join("info"))?;
        self.files.verify(&self.root.join("files"))
    }
}

struct Protected {
    paths: Vec<PathBuf>,
    identities: Vec<Entry>,
}

impl Protected {
    fn new(config: &Config, trash: &Path) -> Result<Self> {
        let mut paths = vec![
            config.path.clone(),
            PathBuf::from(&config.data.backup_directory),
            trash.to_owned(),
            env::current_exe()?,
        ];
        if let Some(root) = startup::installation_root()? {
            paths.push(root);
        }
        for root in config.data.volume_recovery_directories.values() {
            paths.push(path::absolute(Path::new(root))?);
        }
        let mut identities = Vec::new();
        for path in &paths {
            match parent_and_leaf(path).and_then(|(dir, leaf)| dir.entry(leaf)) {
                Ok(entry) => identities.push(entry),
                Err(error) if absent(&error) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(Self { paths, identities })
    }

    fn ensure_entry(&self, entry: Entry) -> Result<()> {
        ensure!(
            !self.identities.iter().any(|id| id.aliases(entry)),
            "Target aliases protected data"
        );
        Ok(())
    }
}

struct Target {
    path: PathBuf,
    parent: Dir,
    leaf: OsString,
    held: File,
    entry: Entry,
}

impl Target {
    fn inspect(
        path: &Path,
        recursive: bool,
        protected: &Protected,
        mount: u64,
    ) -> Result<Option<Self>> {
        ensure!(
            !protected
                .paths
                .iter()
                .any(|root| path.starts_with(root) || root.starts_with(path)),
            "Target overlaps protected configuration, metadata, or Trash"
        );
        let (parent, leaf) = match parent_and_leaf(path) {
            Ok(parts) => parts,
            Err(error) if absent(&error) => return Ok(None),
            Err(error) => return Err(error),
        };
        let entry = match parent.entry(leaf) {
            Ok(entry) => entry,
            Err(error) if absent(&error) => return Ok(None),
            Err(error) => return Err(error),
        };
        ensure!(
            entry.mount == mount && parent.identity.mount == mount,
            "Target is not on the home Trash mount"
        );
        protected.ensure_entry(entry)?;
        ensure!(
            matches!(entry.kind(), libc::S_IFREG | libc::S_IFDIR | libc::S_IFLNK),
            "Unsupported target type"
        );
        let held = parent.open_file(leaf, libc::O_PATH, 0)?;
        ensure!(
            entry.matches(file_entry(&held)?),
            "Target changed while opening"
        );
        let target = Self {
            path: path.into(),
            parent,
            leaf: leaf.into(),
            held,
            entry,
        };
        target.check(recursive, protected)?;
        Ok(Some(target))
    }

    fn check(&self, recursive: bool, protected: &Protected) -> Result<()> {
        self.parent.verify(self.path.parent().unwrap())?;
        ensure!(
            self.entry.matches(file_entry(&self.held)?)
                && self.entry.matches(self.parent.entry(&self.leaf)?),
            "Target changed after preflight"
        );
        if self.entry.kind() == libc::S_IFDIR {
            let directory = self.parent.child(&self.leaf)?;
            ensure!(
                self.entry.matches(directory.identity),
                "Target directory changed"
            );
            if recursive {
                scan(&directory, self.entry.mount, protected, 0)?;
            } else {
                ensure!(
                    directory.entries()?.next().transpose()?.is_none(),
                    "Nonempty directory requires --recursive"
                );
            }
        }
        Ok(())
    }
}

fn scan(dir: &Dir, mount: u64, protected: &Protected, depth: usize) -> Result<()> {
    ensure!(
        depth < 128,
        "Directory nesting exceeds the verification limit"
    );
    for entry in dir.entries()? {
        let name = entry?.file_name();
        let child = dir.entry(&name)?;
        ensure!(
            child.mount == mount,
            "A mounted subtree cannot be moved to Trash"
        );
        protected.ensure_entry(child)?;
        if child.kind() == libc::S_IFDIR {
            let nested = dir.child(&name)?;
            ensure!(
                child.matches(nested.identity),
                "Directory entry changed during preflight"
            );
            scan(&nested, mount, protected, depth + 1)?;
        }
    }
    Ok(())
}

fn trash_info(path: &Path) -> String {
    let mut escaped = String::new();
    for &byte in path.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte) {
            escaped.push(byte as char);
        } else {
            use std::fmt::Write as _;
            write!(&mut escaped, "%{byte:02X}").expect("writing to String");
        }
    }
    format!(
        "[Trash Info]\nPath={escaped}\nDeletionDate={}\n",
        chrono::Local::now().format("%Y-%m-%dT%H:%M:%S")
    )
}

fn move_to_trash(
    target: &Target,
    trash: &Trash,
    recursive: bool,
    protected: &Protected,
) -> std::result::Result<(), (bool, anyhow::Error)> {
    let mut stem = String::new();
    for ch in target.leaf.to_string_lossy().chars() {
        if stem.len() + ch.len_utf8() > 100 {
            break;
        }
        stem.push(ch);
    }
    let name = format!("{stem}-{}", uuid::Uuid::new_v4().simple());
    let info_name = OsString::from(format!("{name}.trashinfo"));
    let info = OsStr::new(&info_name);
    let (source, destination) = (path::name(&target.leaf), path::name(OsStr::new(&name)));
    let source = source.map_err(|error| (false, error))?;
    let destination = destination.map_err(|error| (false, error))?;
    let mut receipt = create_file(&trash.info, info).map_err(|error| (false, error))?;
    let mut attempted = false;
    let move_result = (|| {
        receipt.write_all(trash_info(&target.path).as_bytes())?;
        receipt.sync_all()?;
        trash.info.sync()?;
        target.check(recursive, protected)?;
        trash.verify()?;
        ensure!(
            file_entry(&receipt)?.matches(trash.info.entry(info)?),
            "Trash info changed"
        );
        // 新しい名前への単一renameだけを行い、別マウントや衝突でコピーに切り替えない。
        attempted = true;
        if unsafe {
            libc::renameat2(
                target.parent.fd(),
                source.as_ptr(),
                trash.files.fd(),
                destination.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        Ok(())
    })();
    if let Err(error) = move_result {
        if attempted {
            // サーバー側でrenameが成立してからエラーが返る場合も、元と先を確認する。
            let source_unchanged = target.parent.verify(target.path.parent().unwrap()).is_ok()
                && target
                    .parent
                    .entry(&target.leaf)
                    .is_ok_and(|entry| target.entry.matches(entry));
            let destination_excludes_target = match trash.files.entry(OsStr::new(&name)) {
                Ok(entry) => !target.entry.aliases(entry),
                Err(error) => absent(&error),
            };
            if !source_unchanged || !destination_excludes_target || trash.verify().is_err() {
                return Err((
                    true,
                    error.context("Could not confirm that rename left the source unchanged"),
                ));
            }
        }
        return match remove_created_file(&trash.info, info, &receipt) {
            Ok(()) => Err((false, error)),
            Err(cleanup) => Err((
                true,
                error.context(format!("Could not confirm Trash info cleanup: {cleanup}")),
            )),
        };
    }
    let confirm = (|| {
        trash.verify()?;
        target.parent.verify(target.path.parent().unwrap())?;
        ensure!(
            target.entry.matches(trash.files.entry(OsStr::new(&name))?),
            "Moved entry identity is uncertain"
        );
        ensure!(
            file_entry(&receipt)?.matches(trash.info.entry(info)?),
            "Trash info identity is uncertain"
        );
        ensure!(
            target
                .parent
                .entry(&target.leaf)
                .is_err_and(|error| absent(&error)),
            "The original name is no longer absent"
        );
        trash.files.sync()?;
        target.parent.sync()
    })();
    confirm.map_err(|error| (true, error))
}

pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    ensure!(
        command == "delete",
        "Linux supports synchronous Trash operations"
    );
    let dry_run = args["dryRun"].as_bool().unwrap_or(false);
    let recursive = args["recursive"].as_bool().unwrap_or(false);
    let paths = args["paths"].as_array().context("paths must be an array")?;
    ensure!(
        !paths.is_empty() && paths.len() <= 4096,
        "paths must contain 1..4096 entries"
    );
    let root = home_trash()?;
    let mount = Dir::nearest(&root)?.identity.mount;
    let protected = Protected::new(config, &root)?;
    let mut prepared = Vec::with_capacity(paths.len());
    let mut previous: Vec<PathBuf> = Vec::new();
    for path in paths {
        let input = path.as_str().context("Path must be a string")?;
        let target = (|| {
            let path = path::absolute(Path::new(input))?;
            if previous
                .iter()
                .any(|other| path.starts_with(other) || other.starts_with(&path))
            {
                bail!("Overlapping targets are not permitted");
            }
            let result = Target::inspect(&path, recursive, &protected, mount);
            previous.push(path);
            result
        })();
        prepared.push((input, target));
    }
    let invalid = prepared.iter().any(|(_, target)| target.is_err());
    let trash = if !invalid
        && prepared
            .iter()
            .any(|(_, target)| matches!(target, Ok(Some(_))))
    {
        if dry_run {
            Trash::inspect(&root).err().map(Err)
        } else {
            Some(Trash::open(&root))
        }
    } else {
        None
    };
    let mut stopped = false;
    let mut items = Vec::with_capacity(prepared.len());
    for (input, target) in prepared {
        let item = match target {
            Err(error) => {
                json!({"path":input,"kind":"unknown","status":"failed","error":error.to_string()})
            }
            Ok(None) => json!({"path":input,"kind":"unknown","status":"already_absent"}),
            Ok(Some(target)) => {
                let kind = match target.entry.kind() {
                    libc::S_IFDIR => "directory",
                    libc::S_IFLNK => "symlink",
                    _ => "file",
                };
                let mut item = json!({"path":target.path,"kind":kind,"status":"failed"});
                if let Some(callback) = &progress {
                    callback(json!({"message":format!("Checking {}", target.path.display())}));
                }
                if invalid || stopped {
                    item["error"] = json!("Preserved after preflight failure or ambiguous outcome");
                } else if let Some(Err(error)) = &trash {
                    item["error"] = json!(error.to_string());
                } else if dry_run {
                    item["status"] = json!("would_recycle");
                } else if let Some(Ok(trash)) = &trash {
                    match move_to_trash(&target, trash, recursive, &protected) {
                        Ok(()) => item["status"] = json!("recycled"),
                        Err((ambiguous, error)) => {
                            stopped = ambiguous;
                            if ambiguous {
                                item["status"] = json!("ambiguous");
                            }
                            item["error"] = json!(error.to_string());
                        }
                    }
                }
                item
            }
        };
        items.push(item);
    }
    Ok(json!({"dryRun":dry_run,"items":items,"warnings":[]}))
}
