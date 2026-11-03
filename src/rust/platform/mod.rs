// 実体識別・パス比較・ACLはOS別に保持し、共通のwire型へ変換しない。
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(windows)]
pub mod windows;

#[cfg(target_os = "macos")]
pub use macos::{path, read_plain_file, write_new_plain_file};
#[cfg(windows)]
pub use windows::path;
#[cfg(windows)]
pub use windows::{read_plain_file, write_new_plain_file};

#[cfg(not(any(windows, target_os = "macos")))]
compile_error!("Prunlet supports Windows and macOS; other platforms have no deletion backend.");
