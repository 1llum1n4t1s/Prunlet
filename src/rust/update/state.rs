use super::package::is_hex;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const STATE_NAME: &str = ".prunlet-update-state.json";
pub const AUXILIARY_NAMES: [&str; 9] = [
    "Install-Prunlet.ps1",
    "start-prunlet-mcp.ps1",
    "configuration-common.ps1",
    "maintenance-task.ps1",
    "uninstall-maintenance.ps1",
    "install-codex.ps1",
    "uninstall-codex.ps1",
    "install-agent-instructions.ps1",
    "PRUNLET.md",
];

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct PublishedSlot {
    pub generation: String,
    pub sha256: String,
    pub bytes: i64,
    pub status: String,
}
impl Default for PublishedSlot {
    fn default() -> Self {
        Self {
            generation: String::new(),
            sha256: String::new(),
            bytes: 0,
            status: "writing".into(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct StageCacheBaseline {
    pub commit: String,
    pub owner_sha256: String,
    pub source_info_sha256: String,
    pub cli_sha256: String,
    pub maintenance_sha256: String,
    pub hook_sha256: String,
    pub auxiliary_sha256: BTreeMap<String, String>,
}

pub fn package_name(name: &str) -> bool {
    name == "package.zip" || unique_name(name, "package-", ".zip")
}
fn unique_name(name: &str, prefix: &str, suffix: &str) -> bool {
    name.strip_prefix(prefix)
        .and_then(|s| s.strip_suffix(suffix))
        .is_some_and(|s| {
            s.len() == 32
                && s.bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        })
}
pub fn rotation_backup(product: &str, name: &str) -> bool {
    product.strip_suffix(".exe").is_some_and(|stem| {
        name == format!("{stem}.previous.exe")
            || unique_name(name, &format!("{stem}.previous-"), ".exe")
    })
}
fn stage_write_name(name: &str) -> bool {
    matches!(
        name,
        "owner"
            | "source-info.json"
            | "previous-source-info.json"
            | "previous-source-info-original.json"
            | "prunlet.exe"
            | "prunlet-maintenance.exe"
            | "prunlet-hook.exe"
    ) || AUXILIARY_NAMES.iter().any(|n| {
        name == format!("previous-auxiliary/{n}")
            || name
                == if *n == "Install-Prunlet.ps1" {
                    format!("scripts\\{n}")
                } else {
                    format!("integration\\{n}")
                }
    })
}

impl UpdateState {
    /// bytesは保持した単一linkのstate handleから取得し、未知状態を推測・修復しない。
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        ensure!(
            bytes.len() <= 65536,
            "Update state exceeds the supported size."
        );
        let value = crate::json::parse_unique(bytes)?;
        let object = value
            .as_object()
            .context("Update state must be an object.")?;
        ensure!(
            ["product", "schema", "phase", "epoch"]
                .iter()
                .all(|n| object.contains_key(*n)),
            "Update state is missing its identity or phase."
        );
        let state: Self = serde_json::from_value(value)?;
        state.validate()?;
        Ok(state)
    }
    pub fn bytes(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let bytes = serde_json::to_vec(self)?;
        ensure!(
            bytes.len() <= 65536,
            "Update state exceeds the supported size."
        );
        Ok(bytes)
    }
    pub fn validate(&self) -> Result<()> {
        if let Some(cache) = &self.cache_baseline {
            ensure!(
                self.prior_stage_commit.is_empty()
                    && self.prior_stage_info_sha256.is_empty()
                    && self.prior_previous_info_sha256.is_empty()
                    && self.prior_owner_sha256.is_empty()
                    && self.prior_cli_sha256.is_empty()
                    && self.prior_maintenance_sha256.is_empty()
                    && self.prior_hook_sha256.is_empty()
                    && self.prior_auxiliary_sha256.is_none(),
                "Update state mixes unapplied cache and completed stage provenance."
            );
            ensure!(
                is_hex(&cache.commit, 40)
                    && [
                        &cache.owner_sha256,
                        &cache.source_info_sha256,
                        &cache.cli_sha256,
                        &cache.maintenance_sha256,
                        &cache.hook_sha256
                    ]
                    .iter()
                    .all(|s| is_hex(s, 64))
                    && cache.auxiliary_sha256.len() == AUXILIARY_NAMES.len()
                    && AUXILIARY_NAMES.iter().all(|n| cache
                        .auxiliary_sha256
                        .get(&format!("bin\\{n}"))
                        .is_some_and(|s| is_hex(s, 64))),
                "Update state has incomplete staged cache provenance."
            );
        }
        ensure!(
            self.product == "Prunlet"
                && self.schema == 1
                && self.epoch == 1
                && matches!(
                    self.phase.as_str(),
                    "idle" | "switching" | "migrating" | "cleanup"
                )
                && [
                    &self.cleanup_cli,
                    &self.cleanup_maintenance,
                    &self.cleanup_hook
                ]
                .iter()
                .all(|s| matches!(s.as_str(), "pending" | "attempting" | "done"))
                && matches!(
                    self.stage_cleanup.as_str(),
                    "none" | "pending" | "attempting" | "done"
                )
                && matches!(self.package_status.as_str(), "none" | "writing" | "ready")
                && package_name(&self.package_name),
            "Update state is unsupported or malformed."
        );
        if !self.package_previous_sha256.is_empty() || self.package_previous_bytes != 0 {
            ensure!(
                is_hex(&self.package_previous_sha256, 64)
                    && (1..=536870912).contains(&self.package_previous_bytes),
                "Invalid prior package identity."
            );
        }
        if self.stage_cleanup != "none" {
            ensure!(
                is_hex(&self.candidate_commit, 40),
                "Invalid stage identity."
            );
        }
        if self.stage_cleanup == "pending" {
            ensure!(
                is_hex(&self.prepared_installed_source_info_sha256, 64),
                "Missing prepared installed provenance identity."
            );
        }
        ensure!(
            self.migration_complete == self.migration_file_complete.is_some()
                && !(self.migration_complete && self.phase == "switching")
                && !(self.phase == "idle"
                    && !self.candidate_cli_sha256.is_empty()
                    && !self.migration_complete),
            "Inconsistent migration completion record."
        );
        if !self.prior_stage_commit.is_empty() {
            ensure!(
                is_hex(&self.prior_stage_commit, 40)
                    && [
                        &self.prior_stage_info_sha256,
                        &self.prior_previous_info_sha256,
                        &self.prior_owner_sha256,
                        &self.prior_cli_sha256,
                        &self.prior_maintenance_sha256,
                        &self.prior_hook_sha256
                    ]
                    .iter()
                    .all(|s| is_hex(s, 64)),
                "Incomplete prior stage provenance."
            );
            let aux = self
                .prior_auxiliary_sha256
                .as_ref()
                .context("Missing prior auxiliary provenance.")?;
            ensure!(
                aux.len() == AUXILIARY_NAMES.len()
                    && AUXILIARY_NAMES
                        .iter()
                        .all(|n| aux.get(&format!("bin\\{n}")).is_some_and(|s| is_hex(s, 64))),
                "Invalid prior auxiliary provenance."
            );
        }
        if !self.stage_write_name.is_empty() {
            ensure!(
                stage_write_name(&self.stage_write_name)
                    && is_hex(&self.stage_write_old_sha256, 64)
                    && is_hex(&self.stage_write_new_sha256, 64)
                    && (1..=536870912).contains(&self.stage_write_bytes),
                "Invalid staged write record."
            );
        } else {
            ensure!(
                self.stage_write_old_sha256.is_empty()
                    && self.stage_write_new_sha256.is_empty()
                    && self.stage_write_bytes == 0,
                "Incomplete staged write record."
            );
        }
        if !self.rotation_status.is_empty() {
            ensure!(
                matches!(
                    self.rotation_status.as_str(),
                    "writing"
                        | "candidate_ready"
                        | "candidate_named"
                        | "replacing"
                        | "ambiguous"
                        | "switched"
                ) && matches!(
                    self.rotation_name.as_str(),
                    "prunlet.exe" | "prunlet-maintenance.exe" | "prunlet-hook.exe"
                ) && (self.rotation_prior_sha256.is_empty()
                    || is_hex(&self.rotation_prior_sha256, 64))
                    && is_hex(&self.rotation_candidate_sha256, 64)
                    && rotation_backup(&self.rotation_name, &self.rotation_backup_name),
                "Invalid product rotation record."
            );
        }
        for (product, name) in [
            ("prunlet.exe", &self.rotation_cli_backup),
            ("prunlet-maintenance.exe", &self.rotation_maintenance_backup),
            ("prunlet-hook.exe", &self.rotation_hook_backup),
        ] {
            ensure!(
                name.is_empty() || rotation_backup(product, name),
                "Invalid retained product backup name."
            );
        }
        if !self.auxiliary_rotation_status.is_empty() {
            ensure!(
                matches!(
                    self.auxiliary_rotation_status.as_str(),
                    "replacing" | "ambiguous"
                ) && AUXILIARY_NAMES.contains(&self.auxiliary_rotation_name.as_str())
                    && is_hex(&self.auxiliary_rotation_old_sha256, 64)
                    && is_hex(&self.auxiliary_rotation_new_sha256, 64),
                "Invalid auxiliary replacement record."
            );
        } else {
            ensure!(
                self.auxiliary_rotation_name.is_empty()
                    && self.auxiliary_rotation_old_sha256.is_empty()
                    && self.auxiliary_rotation_new_sha256.is_empty(),
                "Incomplete auxiliary replacement record."
            );
        }
        for slot in [&self.slot_cli, &self.slot_maintenance, &self.slot_hook]
            .into_iter()
            .flatten()
        {
            let generation = uuid::Uuid::parse_str(&slot.generation)?;
            ensure!(
                slot.generation.len() == 32
                    && !generation.is_nil()
                    && is_hex(&slot.sha256, 64)
                    && (1..=268435456).contains(&slot.bytes)
                    && matches!(slot.status.as_str(), "writing" | "ready"),
                "Invalid product slot record."
            );
        }
        if self.phase != "idle" || !self.candidate_cli_sha256.is_empty() {
            ensure!(
                is_hex(&self.old_commit, 40)
                    && is_hex(&self.candidate_commit, 40)
                    && [
                        &self.candidate_cli_sha256,
                        &self.candidate_maintenance_sha256,
                        &self.candidate_source_info_sha256
                    ]
                    .iter()
                    .all(|s| is_hex(s, 64)),
                "Invalid candidate identity."
            );
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateState {
    pub product: String,
    pub schema: i32,
    pub phase: String,
    pub epoch: i32,
    pub old_commit: String,
    pub prepared_installed_source_info_sha256: String,
    pub candidate_commit: String,
    pub candidate_cli_sha256: String,
    pub candidate_maintenance_sha256: String,
    pub candidate_source_info_sha256: String,
    pub cleanup_cli: String,
    pub cleanup_maintenance: String,
    pub cleanup_hook: String,
    pub stage_cleanup: String,
    pub integration_ready: bool,
    pub migration_complete: bool,
    pub migration_file_complete: Option<bool>,
    pub slot_cli: Option<PublishedSlot>,
    pub slot_maintenance: Option<PublishedSlot>,
    pub slot_hook: Option<PublishedSlot>,
    pub package_name: String,
    pub package_status: String,
    pub package_previous_sha256: String,
    pub package_previous_bytes: i64,
    pub prior_stage_commit: String,
    pub prior_stage_info_sha256: String,
    pub prior_previous_info_sha256: String,
    pub prior_owner_sha256: String,
    pub prior_cli_sha256: String,
    pub prior_maintenance_sha256: String,
    pub prior_hook_sha256: String,
    pub prior_auxiliary_sha256: Option<BTreeMap<String, String>>,
    pub cache_baseline: Option<StageCacheBaseline>,
    pub stage_write_name: String,
    pub stage_write_old_sha256: String,
    pub stage_write_new_sha256: String,
    pub stage_write_bytes: i64,
    pub rotation_name: String,
    pub rotation_status: String,
    pub rotation_prior_sha256: String,
    pub rotation_candidate_sha256: String,
    pub rotation_backup_name: String,
    pub rotation_cli_backup: String,
    pub rotation_maintenance_backup: String,
    pub rotation_hook_backup: String,
    pub auxiliary_backup_sha256: BTreeMap<String, String>,
    pub auxiliary_rotation_name: String,
    pub auxiliary_rotation_status: String,
    pub auxiliary_rotation_old_sha256: String,
    pub auxiliary_rotation_new_sha256: String,
}
impl Default for UpdateState {
    fn default() -> Self {
        Self {
            product: "Prunlet".into(),
            schema: 1,
            phase: "idle".into(),
            epoch: 1,
            old_commit: "".into(),
            prepared_installed_source_info_sha256: "".into(),
            candidate_commit: "".into(),
            candidate_cli_sha256: "".into(),
            candidate_maintenance_sha256: "".into(),
            candidate_source_info_sha256: "".into(),
            cleanup_cli: "pending".into(),
            cleanup_maintenance: "pending".into(),
            cleanup_hook: "pending".into(),
            stage_cleanup: "none".into(),
            integration_ready: Default::default(),
            migration_complete: Default::default(),
            migration_file_complete: Default::default(),
            slot_cli: Default::default(),
            slot_maintenance: Default::default(),
            slot_hook: Default::default(),
            package_name: "package.zip".into(),
            package_status: "none".into(),
            package_previous_sha256: "".into(),
            package_previous_bytes: Default::default(),
            prior_stage_commit: "".into(),
            prior_stage_info_sha256: "".into(),
            prior_previous_info_sha256: "".into(),
            prior_owner_sha256: "".into(),
            prior_cli_sha256: "".into(),
            prior_maintenance_sha256: "".into(),
            prior_hook_sha256: "".into(),
            prior_auxiliary_sha256: Default::default(),
            cache_baseline: None,
            stage_write_name: "".into(),
            stage_write_old_sha256: "".into(),
            stage_write_new_sha256: "".into(),
            stage_write_bytes: Default::default(),
            rotation_name: "".into(),
            rotation_status: "".into(),
            rotation_prior_sha256: "".into(),
            rotation_candidate_sha256: "".into(),
            rotation_backup_name: "".into(),
            rotation_cli_backup: "".into(),
            rotation_maintenance_backup: "".into(),
            rotation_hook_backup: "".into(),
            auxiliary_backup_sha256: Default::default(),
            auxiliary_rotation_name: "".into(),
            auxiliary_rotation_status: "".into(),
            auxiliary_rotation_old_sha256: "".into(),
            auxiliary_rotation_new_sha256: "".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn state_rejects_ambiguous_schema_and_completion() {
        assert!(
            UpdateState::parse(
                br#"{"product":"Prunlet","schema":1,"schema":1,"phase":"idle","epoch":1}"#
            )
            .is_err()
        );
        assert!(
            UpdateState::parse(
                br#"{"product":"Prunlet","schema":1,"phase":"idle","epoch":1,"unknown":1}"#
            )
            .is_err()
        );
        let mut state = UpdateState::default();
        state.migration_complete = true;
        assert!(state.validate().is_err());
        state.migration_file_complete = Some(false);
        assert!(state.validate().is_ok());
        state.phase = "switching".into();
        assert!(state.validate().is_err());
    }
    #[test]
    fn prior_state_and_unique_names_remain_compatible() {
        let state =
            UpdateState::parse(br#"{"product":"Prunlet","schema":1,"phase":"idle","epoch":1}"#)
                .unwrap();
        assert!(UpdateState::parse(&state.bytes().unwrap()).is_ok());
        assert!(package_name("package.zip"));
        assert!(package_name("package-0123456789abcdef0123456789abcdef.zip"));
        assert!(!package_name("../package.zip"));
        assert!(!package_name(
            "package-0123456789ABCDEF0123456789abcdef.zip"
        ));
        assert!(rotation_backup(
            "prunlet-hook.exe",
            "prunlet-hook.previous.exe"
        ));
        assert!(!rotation_backup("prunlet-hook.exe", "prunlet.previous.exe"));
    }
}
