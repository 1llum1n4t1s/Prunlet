// 実体識別・パス比較・ACLはOS別に保持し、共通のwire型へ変換しない。
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(windows)]
pub mod windows;

#[cfg(target_os = "macos")]
pub use macos::{path, read_plain_file, write_new_plain_file};
#[cfg(target_os = "linux")]
pub use linux::{path, read_plain_file, write_new_plain_file};
#[cfg(windows)]
pub use windows::path;
#[cfg(windows)]
pub use windows::{read_plain_file, write_new_plain_file};

#[cfg(not(any(
    windows,
    all(target_os = "macos", target_arch = "aarch64"),
    all(target_os = "linux", any(target_arch = "aarch64", target_arch = "x86_64"))
)))]
compile_error!("Prunlet supports Windows, Apple Silicon macOS, and Linux x64 or ARM64.");
