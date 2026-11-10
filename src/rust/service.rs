use std::{io::Write, sync::Arc};

use anyhow::Result;
use serde_json::Value;
use std::sync::RwLock;

use crate::config::Config;

/// CLIとMCPは同じ実行境界を使い、削除方式を持たない。
pub type Progress = Arc<dyn Fn(Value) + Send + Sync>;

pub trait Backend: Send + Sync {
    fn execute(&self, command: &str, args: &Value, progress: Option<Progress>) -> Result<Value>;
}

pub struct Runtime {
    pub config: Config,
    #[cfg(windows)]
    mcp: bool,
    // registry privilege要求とfile workerの並走を防ぎ、file要求間は並列を許す。
    gate: RwLock<()>,
}

impl Runtime {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            #[cfg(windows)]
            mcp: false,
            gate: RwLock::new(()),
        }
    }
    pub fn for_mcp(config: Config) -> Result<Self> {
        #[cfg(windows)]
        return Ok(Self {
            mcp: true,
            ..Self::new(config)
        });
        #[cfg(not(windows))]
        Ok(Self::new(config))
    }
}

impl Backend for Runtime {
    fn execute(&self, command: &str, args: &Value, progress: Option<Progress>) -> Result<Value> {
        let progress: Option<Progress> = Some(Arc::new(move |value: Value| {
            if let Some(message) = value.get("message").and_then(Value::as_str) {
                // 通知先の切断で処理結果や照合IDを失わない。
                let _ = writeln!(std::io::stderr().lock(), "{message}");
            }
            if let Some(callback) = progress.as_ref() {
                callback(value);
            }
        }));
        if matches!(
            command,
            "delete"
                | "delete-queue"
                | "delete-queue-status"
                | "delete-queue-cancel"
                | "__delete-queue-worker"
        ) {
            let _gate = self
                .gate
                .read()
                .map_err(|_| anyhow::anyhow!("Execution gate is unavailable."))?;
            #[cfg(windows)]
            if self.mcp && command == "delete-queue" {
                crate::platform::windows::process::ensure_mcp_queue_lifetime(&self.config.path)?;
            }
            crate::files::execute(&self.config, command, args, progress)
        } else if command.starts_with("__") {
            let _gate = self
                .gate
                .write()
                .map_err(|_| anyhow::anyhow!("Execution gate is unavailable."))?;
            crate::update::execute(&self.config, command, args, progress)
        } else {
            let _gate = self
                .gate
                .write()
                .map_err(|_| anyhow::anyhow!("Execution gate is unavailable."))?;
            crate::registry::execute(&self.config, command, args, progress)
        }
    }
}
