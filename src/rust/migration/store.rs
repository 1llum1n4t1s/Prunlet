use crate::{
    config::Config,
    platform::windows::{self as native, FileIdentity, PinnedFile, path, security},
};
use anyhow::{Context, Result, ensure};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};

const INSPECT: u32 = 0x00020081;
const SHARE: u32 = 3;

#[derive(Clone, Debug)]
pub struct Location {
    pub private_base: PathBuf,
    pub root: PathBuf,
    pub metadata: PathBuf,
    pub store_key: String,
    pub volume_name: String,
    pub restore: bool,
}
fn same_path(a: &Path, b: &Path) -> bool {
    a.to_string_lossy()
        .eq_ignore_ascii_case(&b.to_string_lossy())
}
fn missing(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<std::io::Error>()
        .is_some_and(|e| matches!(e.raw_os_error(), Some(2 | 3)))
}

pub fn location(
    config: &Config,
    source: &Path,
    use_default: bool,
    restore: bool,
) -> Result<Location> {
    let source = path::absolute(source)?;
    let mount = path::absolute(&native::volume_mount_root(
        source.parent().unwrap_or(&source),
    )?)?;
    ensure!(
        mount.as_os_str().len() == 3,
        "Recovery stores require a local drive-root volume mount."
    );
    let volume_name = native::volume_name(&mount)?;
    let metadata = path::resolve(Path::new(&config.data.backup_directory), false, false)?;
    let sid = security::current_user_sid()?;
    let mut private_base = mount.join(format!(
        ".Prunlet-{}-{sid}",
        if restore { "Restore" } else { "Recovery" }
    ));
    if !use_default {
        let mut configured = None;
        for (key, value) in &config.data.volume_recovery_directories {
            if !same_path(&path::resolve(Path::new(key), false, false)?, &mount) {
                continue;
            }
            ensure!(
                configured.is_none(),
                "Duplicate recovery directory configuration for the same volume mount root."
            );
            configured = Some(path::absolute(Path::new(value))?);
        }
        if let Some(value) = configured {
            private_base = if restore {
                PathBuf::from(format!("{}.restore", value.display()))
            } else {
                value
            };
        }
    }
    let private_base = path::resolve(&private_base, true, false)?;
    let recovery_mount = path::absolute(&native::volume_mount_root(&private_base)?)?;
    ensure!(
        recovery_mount.as_os_str().len() == 3
            && native::volume_name(&recovery_mount)?.eq_ignore_ascii_case(&volume_name),
        "Recovery directory and source must belong to the same local drive-root volume; copying is not permitted."
    );
    ensure!(
        !path::within(&private_base, &metadata) && !path::within(&metadata, &private_base),
        "The volume recovery directory and central metadata directory must not contain each other."
    );
    let key = format!(
        "{}\n{sid}",
        native::invariant_uppercase(&metadata.to_string_lossy())?
    );
    let store_key = hex::encode_upper(Sha256::digest(key.as_bytes()))[..32].to_owned();
    Ok(Location {
        root: private_base.join(&store_key),
        private_base,
        metadata,
        store_key,
        volume_name,
        restore,
    })
}

fn secure_directory(directory: &Path, restore: bool) -> Result<PinnedFile> {
    let handle = PinnedFile::open(directory, INSPECT, SHARE)?;
    let id = handle.identity()?;
    ensure!(
        id.is_directory() && !id.is_reparse() && id.reparse_tag == 0 && id.links == 1,
        "Recovery storage must be a single-link ordinary directory."
    );
    handle.verify_named()?;
    handle.reject_case_sensitive()?;
    native::reject_named_streams(directory)?;
    security::verify_private_store_security(handle.raw(), restore)?;
    Ok(handle)
}

fn marker(location: &Location, identity: &FileIdentity) -> Result<()> {
    let name = location.root.join("store.json");
    let bytes = native::read_plain_file(&name, 8192, true)?;
    ensure!(!bytes.is_empty(), "Recovery store marker is empty.");
    let value = crate::json::parse_unique(&bytes)?;
    let map = value
        .as_object()
        .context("Recovery store marker must be an object.")?;
    let names = [
        "schema",
        "ownerSid",
        "metadataRoot",
        "storeKey",
        "volumeName",
        "volumeSerial",
        "rootFileId",
    ];
    ensure!(
        map.len() == names.len() && names.iter().all(|n| map.contains_key(*n)),
        "Recovery store marker contains unknown or missing members."
    );
    ensure!(
        value["schema"].as_u64() == Some(1)
            && value["ownerSid"].as_str() == Some(security::current_user_sid()?.as_str())
            && value["metadataRoot"].as_str() == location.metadata.to_str()
            && value["storeKey"].as_str() == Some(location.store_key.as_str())
            && value["volumeName"]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case(&location.volume_name))
            && value["volumeSerial"].as_u64() == Some(identity.volume)
            && value["rootFileId"].as_str() == Some(hex::encode_upper(identity.id).as_str()),
        "Recovery store marker does not match its owner, metadata root, volume, or directory identity."
    );
    Ok(())
}

pub fn validate(location: &Location, expected: Option<&FileIdentity>) -> Result<FileIdentity> {
    let _parents = path::pin_directories(&location.root)?;
    let _base = secure_directory(&location.private_base, location.restore)?;
    let root = secure_directory(&location.root, location.restore)?;
    let identity = root.identity()?;
    if let Some(expected) = expected {
        ensure!(
            expected.same_object(&identity),
            "Legacy recovery root identity changed."
        );
    }
    let mount = native::volume_mount_root(&location.private_base)?;
    let volume = PinnedFile::open(&mount, 0x80, SHARE)?;
    ensure!(
        identity.volume == volume.identity()?.volume
            && native::volume_name(&native::volume_mount_root(&location.root)?)?
                .eq_ignore_ascii_case(&location.volume_name),
        "Recovery directory volume identity changed."
    );
    marker(location, &identity)?;
    Ok(identity)
}

pub fn inspect(
    config: &Config,
    mut found: impl FnMut(Location, FileIdentity),
    mut unavailable: impl FnMut(String, anyhow::Error),
) {
    let mut drives = BTreeSet::new();
    for key in config.data.volume_recovery_directories.keys() {
        match path::absolute(Path::new(key)) {
            Ok(path) => {
                drives.insert(path.to_string_lossy().to_uppercase());
            }
            Err(e) => unavailable(key.clone(), e),
        }
    }
    match native::local_ready_drives() {
        Ok(paths) => {
            for path in paths {
                drives.insert(path.to_string_lossy().to_uppercase());
            }
        }
        Err(e) => unavailable("local volumes".into(), e),
    }
    let mut paths = BTreeSet::new();
    let mut identities = BTreeSet::new();
    for drive in drives {
        for default in [false, true] {
            for restore in [false, true] {
                let loc = match location(config, Path::new(&drive), default, restore) {
                    Ok(loc) => loc,
                    Err(e) => {
                        unavailable(drive.clone(), e);
                        continue;
                    }
                };
                if !paths.insert(loc.root.to_string_lossy().to_uppercase()) {
                    continue;
                }
                match validate(&loc, None) {
                    Ok(id) => {
                        if identities.insert((loc.volume_name.to_uppercase(), id.volume, id.id)) {
                            found(loc, id);
                        }
                    }
                    Err(e) if missing(&e) => {}
                    Err(e) => unavailable(loc.root.display().to_string(), e),
                }
            }
        }
    }
}
