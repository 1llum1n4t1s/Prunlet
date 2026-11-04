use crate::{config::Config, service::Progress};
use anyhow::Result;
use serde_json::Value;
#[cfg(windows)]
pub mod coordination;
#[cfg(windows)]
mod queue;
#[cfg(windows)]
mod recordless;
#[cfg(windows)]
pub(crate) use recordless::recycle_owned_mcp_generation;

pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    if let Some(value) = args.get("permanentReservedTree") {
        anyhow::ensure!(value.is_boolean(), "permanentReservedTree must be boolean");
        anyhow::ensure!(
            command == "delete",
            "permanentReservedTree is supported only for synchronous deletion"
        );
        if value == true {
            anyhow::ensure!(
                cfg!(windows),
                "permanentReservedTree is supported only on Windows"
            );
            anyhow::ensure!(
                args["recursive"] == true,
                "permanentReservedTree requires recursive=true"
            );
            anyhow::ensure!(
                args.get("dryRun").is_none_or(Value::is_boolean),
                "dryRun must be boolean"
            );
        }
    }
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
    #[cfg(not(any(windows, target_os = "macos")))]
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
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        anyhow::bail!("This operating system is not supported")
    }
}

#[cfg(all(test, windows))]
pub fn verification_native_contract(case: &str, fixture_root: &str) -> Result<Value> {
    recordless::verification_native_contract(case, fixture_root)
}
