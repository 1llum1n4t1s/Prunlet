use std::{env, fs, path::PathBuf, process::Command};

fn git_output(arguments: &[&str]) -> Option<String> {
    Command::new("git")
        .current_dir(env::var_os("CARGO_MANIFEST_DIR")?)
        .args(arguments)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|text| text.trim().to_owned())
}

fn watch_git_input(name: &str) {
    if let Some(path) = git_output(&["rev-parse", "--git-path", name]) {
        let path = PathBuf::from(path);
        let path = if path.is_absolute() {
            path
        } else {
            PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join(path)
        };
        if path.is_file() {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}

fn main() {
    println!("cargo:rustc-check-cfg=cfg(prunlet_macos_race_tests)");
    println!("cargo:rerun-if-env-changed=PRUNLET_SOURCE_COMMIT");
    println!("cargo:rerun-if-changed=build.rs");
    let commit = env::var("PRUNLET_SOURCE_COMMIT")
        .ok()
        .or_else(|| {
            // archiveには.gitがない。存在しない入力をwatchして毎回buildしない。
            watch_git_input("HEAD");
            watch_git_input("packed-refs");
            if let Some(reference) = git_output(&["symbolic-ref", "--quiet", "HEAD"]) {
                watch_git_input(&reference);
            }
            git_output(&["rev-parse", "HEAD"])
        })
        .filter(|s| s.len() == 40 && s.bytes().all(|c| c.is_ascii_hexdigit()))
        .unwrap_or_else(|| "development".into());
    println!("cargo:rustc-env=PRUNLET_SOURCE_COMMIT={commit}");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let version = env::var("CARGO_PKG_VERSION").unwrap();
    let parts: Vec<_> = version.split('.').collect();
    let numeric = format!("{},{},{},0", parts[0], parts[1], parts[2]);
    let resource = format!(
        r#"#include <windows.h>
1 VERSIONINFO
FILEVERSION {numeric}
PRODUCTVERSION {numeric}
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904B0"
  BEGIN
   VALUE "CompanyName", "Kagayoi\0"
   VALUE "FileDescription", "Prunlet\0"
   VALUE "FileVersion", "{version}.0\0"
   VALUE "ProductName", "Prunlet\0"
   VALUE "ProductVersion", "{version}+{commit}\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x0409, 1200
 END
END
"#
    );
    let path = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("prunlet-version.rc");
    fs::write(&path, resource).expect("Cannot write Windows version resource");
    embed_resource::compile_for(
        path,
        ["prunlet", "prunlet-maintenance"],
        embed_resource::NONE,
    )
    .manifest_optional()
    .expect("Cannot compile Windows version resource");
}
