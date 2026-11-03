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
    // registry privilege要求とfile workerの並走を防ぎ、file要求間は並列を許す。
    gate: RwLock<()>,
    #[cfg(windows)]
    mcp_context: Option<crate::update::mcp_backend::Context>,
}

impl Runtime {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            gate: RwLock::new(()),
            #[cfg(windows)]
            mcp_context: None,
        }
    }
    pub fn for_mcp(config: Config) -> Result<Self> {
        #[cfg(windows)]
        let context = crate::update::mcp_backend::Context::from_proxy(&config.path)?;
        let runtime = Self::new(config);
        #[cfg(windows)]
        let runtime = Self {
            mcp_context: context,
            ..runtime
        };
        Ok(runtime)
    }
}

impl Backend for Runtime {
    fn execute(&self, command: &str, args: &Value, progress: Option<Progress>) -> Result<Value> {
        #[cfg(windows)]
        let _mcp_scope = self
            .mcp_context
            .as_ref()
            .map(|context| context.acquire(&self.config.path))
            .transpose()?;
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
                | "__delete-queue-contact"
        ) {
            let _gate = self
                .gate
                .read()
                .map_err(|_| anyhow::anyhow!("Execution gate is unavailable."))?;
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
