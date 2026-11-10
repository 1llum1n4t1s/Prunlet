// 実体識別・パス比較・ACLはOS別に保持し、共通のwire型へ変換しない。
#[cfg(windows)]
pub mod windows;

#[cfg(windows)]
pub use windows::path;
#[cfg(windows)]
pub use windows::{read_plain_file, write_new_plain_file};

#[cfg(not(windows))]
compile_error!("Prunlet requires Windows.");
