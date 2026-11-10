use crate::{config::Config, service::Progress};
use anyhow::Result;
use serde_json::Value;
#[cfg(windows)]
pub mod coordination;
#[cfg(windows)]
mod queue;
#[cfg(windows)]
mod recordless;

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
