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
                || part
                    .chars()
                    .any(|c| is_forbidden_name_control(c) || "<>\"|".contains(c))
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
/// Win32の名前で禁止される制御文字（NULとU+0001〜U+001F）かを返す。
///
/// `char::is_control`はU+007F(DEL)とC1制御文字(U+0080〜U+009F)も含むが、それらはWin32で
/// 正当な名前の一部になり得る。拒否すると実在する対象を削除できなくなるため、
/// 判定をWin32の禁止範囲に限定する。その他の禁止文字・末尾`.`/空白・予約名は呼出元で扱う。
pub fn is_forbidden_name_control(c: char) -> bool {
    matches!(c, '\0'..='\u{1f}')
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
/// テスト・検証の出力先（TEMPやfixture root）が「外部」かを確認し、正規化したパスを返す。
///
/// 開発者固有のドライブ文字には依存させず、利用者・他の開発者の環境でも同じテストを回せるようにする。
/// 要求するのは次の3点だけで、親の実在・非reparse・volume照合などは呼出元の`pin_directories`等が続けて行う。
/// - 入力そのものが通常のドライブ絶対パス（`X:\`始まり）であること。UNC・`\\?\`等のデバイス構文は拒否する。
/// - ソースリポジトリ（`CARGO_MANIFEST_DIR`）の外であること。
/// - Codex home（`%USERPROFILE%\.codex`と、設定時は`CODEX_HOME`）の外であること。
///   `USERPROFILE`が無い環境ではその除外だけを省き、エラーにはしない。
#[cfg(test)]
pub(crate) fn external_verification_path(path: &Path) -> Result<PathBuf> {
    let raw = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Verification path is not valid Unicode"))?;
    let bytes = raw.as_bytes();
    if bytes.len() < 3 || !bytes[0].is_ascii_alphabetic() || bytes[1] != b':' || bytes[2] != b'\\' {
        bail!(
            "Verification paths must be ordinary drive-absolute paths outside the repository and Codex home; UNC and device paths are unsupported: {raw}"
        );
    }
    let full = absolute(path)?;
    let mut excluded = vec![PathBuf::from(env!("CARGO_MANIFEST_DIR"))];
    if let Some(profile) = std::env::var_os("USERPROFILE") {
        excluded.push(PathBuf::from(profile).join(".codex"));
    }
    if let Some(home) = std::env::var_os("CODEX_HOME") {
        excluded.push(PathBuf::from(home));
    }
    for root in excluded {
        if within(&full, &root) {
            bail!(
                "Verification paths must be external (outside the repository and Codex home): {}",
                full.display()
            );
        }
    }
    Ok(full)
}
/// 環境変数`TEMP`を外部の検証用一時領域として取得する（[`external_verification_path`]で確認する）。
#[cfg(test)]
pub(crate) fn external_test_temp() -> Result<PathBuf> {
    let temp = std::env::var_os("TEMP").ok_or_else(|| anyhow::anyhow!("TEMP is required"))?;
    external_verification_path(Path::new(&temp))
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn name_control_check_matches_win32_forbidden_range() {
        // DEL・C1制御文字はWin32で正当な名前の一部になり得るため受理する。
        for c in ['\u{7f}', '\u{80}', '\u{85}', '\u{9f}'] {
            let input = format!(r"D:\owned\a{c}b\leaf{c}.dat");
            let normalized = absolute(Path::new(&input)).unwrap();
            assert_eq!(normalized, PathBuf::from(&input));
            super::super::validate_stream_name(&format!("stream{c}")).unwrap();
        }
        // NUL・U+0001〜U+001Fは従来どおり拒否する。
        for c in ['\0', '\u{1}', '\u{9}', '\u{1f}'] {
            assert!(absolute(Path::new(&format!(r"D:\owned\a{c}b"))).is_err());
            assert!(super::super::validate_stream_name(&format!("s{c}")).is_err());
        }
        // 禁止記号・末尾の . と空白・祖先の予約名の扱いは変えない。
        for c in ['<', '>', '"', '|', '*', '?', ':'] {
            assert!(absolute(Path::new(&format!(r"D:\owned\a{c}b"))).is_err());
            assert!(super::super::validate_stream_name(&format!("s{c}")).is_err());
        }
        assert!(absolute(Path::new(r"D:\owned\trailing.")).is_err());
        assert!(absolute(Path::new(r"D:\owned\trailing ")).is_err());
        assert!(absolute(Path::new(r"D:\CON\leaf.dat")).is_err());
        assert!(absolute(Path::new(r"D:\owned\CON")).is_err());
        assert!(file_delete_absolute(Path::new(r"D:\owned\CON")).is_ok());
    }
}
