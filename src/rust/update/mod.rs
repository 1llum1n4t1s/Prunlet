#[cfg(windows)]
pub mod budget;
#[cfg(windows)]
pub mod coordinator;
#[cfg(windows)]
pub mod download;
// Windows ZIP の起動時更新の応答差し替え（通信なしの検証用）。Unix の更新テスト cfg と同じく、
// debug_assertions と専用 cfg を両方指定したテスト用ビルドだけに入り、配布の release ビルドには存在しない。
#[cfg(all(windows, debug_assertions, prunlet_windows_update_tests))]
mod fixture;
pub mod gate;
// WinHTTP/環境 proxy の取得。Setup（Velopack）版のマニフェスト取得（app_update::release）からも使う。
#[cfg(windows)]
pub(crate) mod http;
#[cfg(windows)]
pub mod integration;
pub mod manifest;
pub mod package;
// Unix 版の起動時更新の取得（R2 の署名付きマニフェスト）。旧 github.rs（GitHub Release 照合）を置き換えた。
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(crate) mod r2;
#[cfg(windows)]
pub mod rotation;
#[cfg(windows)]
pub mod slot;
#[cfg(windows)]
mod socks;
pub mod state;

use crate::{config::Config, service::Progress};
use anyhow::Result;
use serde_json::Value;

pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    _progress: Option<Progress>,
) -> Result<Value> {
    #[cfg(windows)]
    {
        coordinator::execute(config, command, args)
    }
    #[cfg(not(windows))]
    {
        let _ = (config, command, args);
        anyhow::bail!("The Windows published update protocol is not supported on this platform.")
    }
}
pub fn ensure_ready(config: &std::path::Path) -> Result<()> {
    gate::ensure_ready(config)
}
