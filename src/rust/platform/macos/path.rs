use super::Pinned;
use anyhow::{Result, bail};
use std::path::{Component, Path, PathBuf};

pub fn absolute(path: &Path) -> Result<PathBuf> {
    let text = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Use a UTF-8 path"))?;
    if !path.is_absolute()
        || text.contains('\0')
        || text.split('/').any(|p| matches!(p, "." | ".."))
    {
        bail!("Use an absolute path without dot components or NUL");
    }
    if path
        .components()
        .any(|p| matches!(p, Component::ParentDir | Component::CurDir))
    {
        bail!("Dot path components are not allowed");
    }
    Ok(path.to_path_buf())
}
pub fn within(path: &Path, root: &Path) -> bool {
    path.starts_with(root)
}
pub struct DirectoryLease {
    handles: Vec<Pinned>,
}
impl DirectoryLease {
    pub(super) fn leaf(&self) -> Result<&Pinned> {
        self.handles
            .last()
            .ok_or_else(|| anyhow::anyhow!("Missing pinned directory"))
    }
    pub fn verify(&self) -> Result<()> {
        for pinned in &self.handles {
            pinned.verify_name()?;
        }
        Ok(())
    }
}
pub fn pin_directories(path: &Path) -> Result<DirectoryLease> {
    let path = absolute(path)?;
    let mut current = PathBuf::from("/");
    let mut handles = Vec::new();
    for part in path.components() {
        if let Component::Normal(part) = part {
            current.push(part);
        }
        let pinned = Pinned::open(&current)?;
        if !pinned.id.is_dir() {
            bail!("Ancestor is not a plain directory: {}", current.display());
        }
        pinned.verify()?;
        handles.push(pinned);
    }
    Ok(DirectoryLease { handles })
}
pub fn reject_reparse_ancestors(path: &Path) -> Result<()> {
    let _lease = pin_directories(path)?;
    Ok(())
}
pub fn resolve(path: &Path, allow_missing: bool, allow_link_leaf: bool) -> Result<PathBuf> {
    let original = absolute(path)?;
    // OSが提供する既知のaliasだけを明示的に解決し、その後は全祖先を検証する。
    let mut resolved = original.clone();
    for alias in ["/tmp", "/var", "/etc"] {
        if original.starts_with(alias) && !(allow_link_leaf && original == Path::new(alias)) {
            let link = std::fs::symlink_metadata(alias)?;
            if link.file_type().is_symlink() {
                let pinned_alias = Pinned::open(Path::new(alias))?;
                let target = std::fs::read_link(alias)?;
                let target = if target.is_absolute() {
                    target
                } else {
                    Path::new("/").join(target)
                };
                let expected = PathBuf::from("/private").join(&alias[1..]);
                if target != expected {
                    bail!("Unexpected system alias target");
                }
                pinned_alias.verify()?;
                resolved = expected.join(original.strip_prefix(alias)?);
            }
            break;
        }
    }
    let mut current = PathBuf::from("/");
    for part in resolved.components() {
        if let Component::Normal(part) = part {
            current.push(part);
        }
        match std::fs::symlink_metadata(&current) {
            Ok(meta)
                if meta.file_type().is_symlink() && !(allow_link_leaf && current == resolved) =>
            {
                bail!(
                    "Symbolic link ancestors are not followed: {}",
                    current.display()
                )
            }
            Ok(_) => {}
            Err(e) if allow_missing && e.kind() == std::io::ErrorKind::NotFound => {
                return Ok(resolved);
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn system_alias_leaf_is_not_expanded_for_deletion() {
        for alias in ["/tmp", "/var", "/etc"] {
            // 解析境界だけを通し、実システムのaliasやリンク先を変更しない。
            assert_eq!(
                resolve(Path::new(alias), false, true).unwrap(),
                PathBuf::from(alias)
            );
            assert_eq!(
                resolve(Path::new(alias), false, false).unwrap(),
                PathBuf::from("/private").join(&alias[1..])
            );
        }
    }
}
