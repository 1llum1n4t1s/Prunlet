//! Shell・sparse fixtureで共有するWindowsの厳密な子パス判定。
use std::{os::windows::ffi::OsStrExt, path::Path};

#[link(name = "kernel32")]
unsafe extern "system" {
    fn CompareStringOrdinal(
        a: *const u16,
        alen: i32,
        b: *const u16,
        blen: i32,
        ignore_case: i32,
    ) -> i32;
}

pub(crate) fn is_strict_child(path: &Path, scope: &Path) -> bool {
    // Windowsのordinal比較は文字数が増える大文字変換を行わない。
    let p: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .map(|c| if c == b'/' as u16 { b'\\' as u16 } else { c })
        .collect();
    let mut s: Vec<u16> = scope
        .as_os_str()
        .encode_wide()
        .map(|c| if c == b'/' as u16 { b'\\' as u16 } else { c })
        .collect();
    while s.last() == Some(&(b'\\' as u16)) {
        s.pop();
    }
    !s.is_empty()
        && s.len() <= i32::MAX as usize
        && p.len() > s.len()
        && p[s.len()] == b'\\' as u16
        && unsafe {
            CompareStringOrdinal(p.as_ptr(), s.len() as i32, s.as_ptr(), s.len() as i32, 1)
        } == 2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_ordinal_scope_boundaries() {
        for (path, scope, expected) in [
            (r"D:\Fixture\Straße\item", r"d:\fixture\Straße", true),
            (r"D:\Fixture\Straße\item", r"D:\Fixture\STRASSE", false),
            (r"D:\Fixture\STRASSE\item", r"D:\Fixture\Straße", false),
            (r"D:\FixtureSuffix\item", r"D:\Fixture", false),
            (r"D:\Fixture", r"D:\Fixture", false),
            (r"D:\item", "d:\\", true),
        ] {
            assert_eq!(
                is_strict_child(Path::new(path), Path::new(scope)),
                expected,
                "{path:?} within {scope:?}"
            );
        }
    }
}
