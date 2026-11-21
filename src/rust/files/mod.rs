use crate::{config::Config, service::Progress};
use anyhow::Result;
use serde_json::Value;
#[cfg(windows)]
pub mod coordination;
#[cfg(windows)]
mod queue;
#[cfg(windows)]
mod recordless;

/// 同期削除（CLIの`delete`・`delete --dry-run`）が1回で受け付ける対象数の上限。
/// Windowsだけ引き上げ（4096件はdry-runが72.7秒で30秒の条件を超えたため、実測から1024件）、macOS・Linuxの`--paths-file`は従来の256のまま
/// （`-- <paths>`は入口で絞らず、Coreの4096件まで通る）。MCPとキューには適用しない。
#[cfg(windows)]
pub const SYNC_PATH_LIMIT: usize = 1024;
#[cfg(not(windows))]
pub const SYNC_PATH_LIMIT: usize = 256;
/// MCP `delete_files`（同期・enqueueとも）の対象数の上限。全OS共通。
pub const MCP_PATH_LIMIT: usize = 256;
/// 待機キュー（Windows・macOS）の対象数の上限。
pub const QUEUE_PATH_LIMIT: usize = 256;
/// `--paths-file`の最大バイト数。Windowsは同期上限の件数が長いパスでも収まる値にする。
#[cfg(windows)]
pub const PATHS_FILE_MAX_BYTES: usize = 4 * 1024 * 1024;
#[cfg(not(windows))]
pub const PATHS_FILE_MAX_BYTES: usize = 1024 * 1024;
/// 待機キューのフレーム上限（1 MiB）に合わせた`--paths-file`のバイト上限。
pub const QUEUE_PATHS_FILE_MAX_BYTES: usize = 1024 * 1024;

/// 対象数の上限の種別。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PathLimit {
    Sync,
    Queue,
}

impl PathLimit {
    pub fn count(self) -> usize {
        match self {
            PathLimit::Sync => SYNC_PATH_LIMIT,
            PathLimit::Queue => QUEUE_PATH_LIMIT,
        }
    }

    /// この上限種別の`--paths-file`のバイト上限。
    pub fn file_bytes(self) -> usize {
        match self {
            PathLimit::Sync => PATHS_FILE_MAX_BYTES,
            PathLimit::Queue => QUEUE_PATHS_FILE_MAX_BYTES,
        }
    }
}

/// `--paths-file`の件数超過の文言（A）。
pub fn paths_file_count_error(limit: PathLimit) -> String {
    let n = limit.count();
    format!(
        "Paths file must contain between 1 and {n} path strings; no targets were changed. This is an input limit, not a policy refusal: split larger lists into paths files of at most {n} entries and run the same command once per file. Pass a parent folder once with --recursive only when the whole folder is authorized for deletion."
    )
}

/// `--paths-file`のバイト超過の文言（B）。
pub fn paths_file_bytes_error(limit: PathLimit) -> String {
    let size = format!("{} MiB", limit.file_bytes() / (1024 * 1024));
    format!(
        "Paths file exceeds {size}; no targets were changed. Split the paths into smaller paths files and run the same command once per file."
    )
}

/// 同期削除の入口の件数超過の文言（C）。`n`は該当する入口の上限。
pub fn sync_count_error(n: usize) -> String {
    format!(
        "Specify between 1 and {n} paths; no targets were changed. This is an input limit, not a policy refusal: split larger lists into requests of at most {n} paths. Pass a parent folder once with recursive deletion only when the whole folder is authorized for deletion."
    )
}

/// 待機キューの件数超過の文言（D）。
pub fn queue_count_error() -> String {
    format!(
        "Specify between 1 and {QUEUE_PATH_LIMIT} paths for a queued deletion; no targets were changed. This is an input limit, not a policy refusal: split larger lists into queued jobs of at most {QUEUE_PATH_LIMIT} paths."
    )
}

/// MCPの件数超過の文言（G）。
pub fn mcp_count_error() -> String {
    format!(
        "Paths must contain 1 to {MCP_PATH_LIMIT} strings; no targets were changed. This is an input limit, not a policy refusal: call delete_files again with batches of at most {MCP_PATH_LIMIT} paths. Pass a parent folder once with recursive=true only when the whole folder is authorized for deletion."
    )
}

pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    #[cfg(windows)]
    {
        match command {
            "delete" => recordless::execute(config, args, progress),
            "delete-queue" => queue::enqueue(config, args),
            "delete-queue-status" => queue::contact(args, false),
            "delete-queue-cancel" => queue::contact(args, true),
            "__delete-queue-worker" => queue::worker(config),
            _ => anyhow::bail!("Unknown file command: {command}"),
        }
    }
    #[cfg(target_os = "macos")]
    {
        crate::platform::macos::execute(config, command, args, progress)
    }
    #[cfg(target_os = "linux")]
    {
        crate::platform::linux::execute(config, command, args, progress)
    }
    #[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
    {
        anyhow::bail!("This operating system is not supported")
    }
}
pub fn validate_config(config: &Config) -> Result<()> {
    #[cfg(windows)]
    {
        recordless::validate_config(config)
    }
    #[cfg(target_os = "macos")]
    {
        crate::platform::macos::validate_config(config)
    }
    #[cfg(target_os = "linux")]
    {
        crate::platform::linux::validate_config(config)
    }
    #[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
    {
        anyhow::bail!("This operating system is not supported")
    }
}

#[cfg(all(test, windows))]
pub fn verification_native_contract(case: &str, fixture_root: &str) -> Result<Value> {
    recordless::verification_native_contract(case, fixture_root)
}

#[cfg(all(test, windows))]
pub fn verification_independence(case: &str, fixture_root: &str, config: &Config) -> Result<Value> {
    recordless::verification_independence(case, fixture_root, config)
}
