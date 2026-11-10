//! 旧ファイル記録の明示破棄。registry namespaceの移行・完了印はregistry側が管理する。
use crate::{config::Config, service::Progress};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[cfg(windows)]
mod windows;
#[cfg(all(test, windows))]
pub(crate) use windows::verification_set_checkpoint;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationResult {
    pub dry_run: bool,
    pub registry_ready: bool,
    pub complete: bool,
    pub operations: Vec<MigrationOperation>,
    pub warnings: Vec<String>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationOperation {
    pub operation_id: String,
    pub schema: Option<i32>,
    pub status: String,
    pub error: Option<String>,
    pub path: Option<String>,
}

/// 呼出元はmaintenance.lockとregistry namespaceの準備を保持する。
/// policy 2評価済みif-neededだけscan_central=false、online store検査は常に行う。
pub fn files(
    config: &Config,
    apply: bool,
    scan_central: bool,
    retry_legacy_discard: bool,
    result: &mut MigrationResult,
) -> Result<()> {
    ensure!(
        !retry_legacy_discard || apply,
        "Legacy discard acknowledgement requires --apply."
    );
    #[cfg(windows)]
    {
        windows::migrate(config, apply, scan_central, retry_legacy_discard, result)
    }
    #[cfg(not(windows))]
    {
        let _ = (config, apply, scan_central, result);
        anyhow::bail!("Windows legacy recovery stores must be migrated on Windows.")
    }
}

/// registry側結果に統合するfile専用入口。registryReadyを成功と偽装しない。
pub fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    ensure!(command == "migrate", "Unsupported file migration command.");
    let apply = args.get("apply").and_then(Value::as_bool).unwrap_or(false);
    let scan = args
        .get("scanCentral")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let retry = args
        .get("retryLegacyDiscard")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    ensure!(
        !retry
            || !args
                .get("ifNeeded")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        "Legacy discard retry acknowledgement requires explicit migrate --apply without --if-needed."
    );
    let mut result = MigrationResult {
        dry_run: !apply,
        complete: true,
        ..Default::default()
    };
    files(config, apply, scan, retry, &mut result)?;
    if let Some(progress) = progress {
        progress(serde_json::json!({"kind":"legacyFileMigration","complete":result.complete}));
    }
    Ok(serde_json::to_value(result)?)
}
