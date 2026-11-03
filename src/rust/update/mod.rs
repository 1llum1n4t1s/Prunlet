#[cfg(windows)]
pub mod budget;
#[cfg(windows)]
pub mod coordinator;
pub mod distribution;
#[cfg(windows)]
pub mod download;
pub mod gate;
#[cfg(windows)]
mod http;
#[cfg(windows)]
pub mod integration;
#[cfg(windows)]
pub mod mcp_backend;
#[cfg(windows)]
pub mod mcp_generation;
pub mod package;
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
