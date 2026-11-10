use super::PinnedFile;
use anyhow::{Result, bail};
use std::path::{Path, PathBuf};
use windows_sys::Win32::Storage::FileSystem::*;

pub fn absolute(path: &Path) -> Result<PathBuf> {
    normalize(path, false, false)
}
pub fn file_delete_absolute(path: &Path) -> Result<PathBuf> {
    normalize(path, false, true)
}
pub fn file_system_absolute(path: &Path) -> Result<PathBuf> {
    normalize(path, true, false)
}
pub fn validate_local_path(path: &Path) -> Result<PathBuf> {
    absolute(path)
}
fn normalize(path: &Path, allow_reserved: bool, allow_leaf: bool) -> Result<PathBuf> {
    let input = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Path is not valid Unicode"))?;
    let text = input
        .strip_prefix("\\\\?\\")
        .unwrap_or(input)
        .replace('/', "\\");
    let bytes = text.as_bytes();
    if bytes.len() < 3
        || !bytes[0].is_ascii_alphabetic()
        || bytes[1] != b':'
        || bytes[2] != b'\\'
        || text[2..].contains([':', '*', '?', '\0'])
    {
        bail!("Use an absolute local drive path without wildcards, ADS, UNC, or device syntax");
    }
    let trimmed = text.trim_end_matches('\\');
    let text = if trimmed.len() == 2 {
        format!("{trimmed}\\")
    } else {
        trimmed.to_owned()
    };
    if text.len() > 3 {
        let components: Vec<_> = text[3..].split('\\').collect();
        for (i, part) in components.iter().enumerate() {
            if part.is_empty()
                || matches!(*part, "." | "..")
                || part.ends_with(['.', ' '])
                || part.chars().any(|c| c.is_control() || "<>\"|".contains(c))
            {
                bail!("Invalid path component");
            }
            if !allow_reserved
                && !(allow_leaf && i + 1 == components.len())
                && is_reserved_name(part)
            {
                bail!("Device names are not permitted in ancestor paths");
            }
        }
    }
    if text.encode_utf16().count() > 32760 {
        bail!("Path is too long");
    }
    Ok(PathBuf::from(text))
}
pub fn is_reserved_name(component: &str) -> bool {
    let stem = component.split('.').next().unwrap_or("").to_uppercase();
    matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || ((stem.starts_with("COM") || stem.starts_with("LPT"))
        && stem.chars().count() == 4
        && stem
            .chars()
            .nth(3)
            .is_some_and(|c| "123456789¹²³".contains(c)))
}
pub fn within(path: &Path, root: &Path) -> bool {
    let path = super::upper(&path.to_string_lossy().replace('/', "\\"));
    let root = super::upper(
        root.to_string_lossy()
            .replace('/', "\\")
            .trim_end_matches('\\'),
    );
    path == root || path.starts_with(&(root + "\\"))
}
pub fn components(path: &Path) -> Result<Vec<PathBuf>> {
    let path = file_system_absolute(path)?;
    let text = path.to_str().unwrap();
    let mut result = vec![PathBuf::from(&text[..3])];
    let mut current = text[..3].to_owned();
    for part in text[3..].split('\\').filter(|x| !x.is_empty()) {
        if !current.ends_with('\\') {
            current.push('\\');
        }
        current.push_str(part);
        result.push(PathBuf::from(&current));
    }
    Ok(result)
}
#[derive(Debug)]
pub struct DirectoryLease {
    pub handles: Vec<PinnedFile>,
}
pub fn pin_directories(path: &Path) -> Result<DirectoryLease> {
    let mut lease = DirectoryLease { handles: vec![] };
    for part in components(path)? {
        let handle = PinnedFile::open(
            &part,
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
        )?;
        let id = handle.identity()?;
        if !id.is_directory() || id.is_reparse() {
            bail!("Ancestor is not a plain directory: {}", part.display());
        }
        let actual = handle.final_path()?;
        if !super::ordinal_ignore_case(&actual.to_string_lossy(), &part.to_string_lossy()) {
            bail!(
                "Ancestor resolution changed the fixed name: {}",
                part.display()
            );
        }
        lease.handles.push(handle);
    }
    Ok(lease)
}
pub fn reject_reparse_ancestors(path: &Path) -> Result<()> {
    let _lease = pin_directories(path)?;
    Ok(())
}
/// 正規名の祖先と解決先の祖先を両方固定する。leaseの寿命が名前の固定期間になる。
pub fn resolve(path: &Path, allow_missing: bool, allow_reserved_leaf: bool) -> Result<PathBuf> {
    let path = if allow_reserved_leaf {
        file_delete_absolute(path)?
    } else {
        absolute(path)?
    };
    let mut retained = Vec::new();
    let mut input_handles = Vec::new();
    let mut actual = PathBuf::new();
    let parts = components(&path)?;
    for (index, part) in parts.iter().enumerate() {
        match PinnedFile::open(
            part,
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
        ) {
            Ok(handle) => {
                let id = handle.identity()?;
                if id.is_reparse() || (index + 1 < parts.len() && !id.is_directory()) {
                    bail!("Reparse or non-directory ancestor is not permitted");
                }
                actual = handle.final_path()?;
                let parent = if id.is_directory() {
                    actual.as_path()
                } else {
                    actual
                        .parent()
                        .ok_or_else(|| anyhow::anyhow!("Missing parent"))?
                };
                retained.push(pin_directories(parent)?);
                input_handles.push(handle);
            }
            Err(error)
                if allow_missing
                    && index > 0
                    && error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|e| matches!(e.raw_os_error(), Some(2 | 3))) =>
            {
                for missing in &parts[index..] {
                    actual.push(
                        missing
                            .file_name()
                            .ok_or_else(|| anyhow::anyhow!("Invalid missing suffix"))?,
                    );
                }
                return Ok(actual);
            }
            Err(error) => return Err(error),
        }
    }
    Ok(actual)
}
