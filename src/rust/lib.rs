pub mod cli;
pub mod config;
pub mod files;
pub mod help;
pub mod json;
pub mod locale;
pub mod migration;
pub mod platform;
pub mod protocol;
pub mod registry;
pub(crate) mod result_status;
pub mod service;
pub mod update;

// 障害注入・native境界probeは検証用test実行ファイルだけへ組み込む。
#[cfg(all(test, windows))]
#[path = "bin/verification.rs"]
mod verification;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
