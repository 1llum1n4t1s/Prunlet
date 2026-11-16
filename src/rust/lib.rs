// Setup（Velopack）版の起動処理・更新・登録。Windows専用で、管理外の実行では何も読み書きしない。
#[cfg(windows)]
pub mod app_update;
pub mod cli;
pub mod config;
pub mod files;
pub mod help;
// 更新・導入後に残る自アプリの一時物の自動整理（`maintain`から呼ぶ）。レジストリ保守と同じくWindows専用。
#[cfg(windows)]
pub mod housekeeping;
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
