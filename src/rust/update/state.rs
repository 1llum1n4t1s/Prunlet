use super::package::{MAX_ARCHIVE_BYTES, is_hex};
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
            // 適用済みstage由来のprior_*は、未適用候補が続く間もそのまま引き継ぐため、
            // cache_baselineと共存できる。ただし不完全なprior_*（orphan）は従来どおり拒否する。
            // prior_*の完全性は、下のprior_stage_commit用の検証が行う。
            if self.prior_stage_commit.is_empty() {
                ensure!(
                    self.prior_stage_info_sha256.is_empty()
                        && self.prior_previous_info_sha256.is_empty()
                        && self.prior_owner_sha256.is_empty()
                        && self.prior_cli_sha256.is_empty()
                        && self.prior_maintenance_sha256.is_empty()
                        && self.prior_hook_sha256.is_empty()
                        && self.prior_auxiliary_sha256.is_none(),
                    "Update state mixes unapplied cache and completed stage provenance."
                );
            }
            // 同じcommitを指していても、来歴のhashは一致を求めない。適用済みstageと同じcommitのreleaseが
            // assetを差し替えて再公開されると、候補（cache側）のsource-info.jsonだけが書き換わる。
            // 一致を求めると、その次のreleaseでstateの書込みが毎回失敗して恒久停止する。
            // 空文字は「そのパスが存在しなかった」ことを表す（未知の旧実体を上書きしない印）。
            let identity = |s: &String| s.is_empty() || is_hex(s, 64);
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
                    .all(|s| identity(s))
                    && cache.auxiliary_sha256.len() == AUXILIARY_NAMES.len()
                    && AUXILIARY_NAMES.iter().all(|n| cache
                        .auxiliary_sha256
                        .get(&format!("bin\\{n}"))
                        .is_some_and(identity)),
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
                    && (1..=MAX_ARCHIVE_BYTES as i64).contains(&self.package_previous_bytes),
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
    /// 出荷済みの版が実際に書いた適用済みstage（prior_*付き・cacheBaselineなし）のstate。
    /// 新しい版がそのまま読め、書き戻した形も同じ内容で読める。
    const SHIPPED_APPLIED_STATE: &str = r#"{"product":"Prunlet","schema":1,"phase":"idle","epoch":1,"oldCommit":"11AA605D2574560AF0CD76E478C07402ED81B4DA","preparedInstalledSourceInfoSha256":"6D0E774CC444C3D1988660550FC4C1BB905E98A0EAEBAF2F6DA004B528581F4C","candidateCommit":"EAE367C96E1718BB0C927A9C073437346FECB760","candidateCliSha256":"D8111CAAC5C94CF4DC64EAE58726F1EB3E5D1F93E9380331C57850E9E63EF932","candidateMaintenanceSha256":"3215C6788BFCF88B1BEC02F128A46ABCAEA4EF5538642A8A55F3FD34AA01CF02","candidateSourceInfoSha256":"7D1C4DAB8453A932A5BB31588091E6856FDC5D8F63B65939AC8136D1442D6282","cleanupCli":"pending","cleanupMaintenance":"pending","cleanupHook":"pending","stageCleanup":"pending","integrationReady":true,"migrationComplete":true,"migrationFileComplete":true,"slotCli":{"generation":"b77650fe82fd42ee8ceb534b639a4951","sha256":"D8111CAAC5C94CF4DC64EAE58726F1EB3E5D1F93E9380331C57850E9E63EF932","bytes":6276608,"status":"ready"},"slotMaintenance":{"generation":"ba57d3b62c3d49b0acfad96800b2ce01","sha256":"3215C6788BFCF88B1BEC02F128A46ABCAEA4EF5538642A8A55F3FD34AA01CF02","bytes":6276608,"status":"ready"},"slotHook":{"generation":"33936aff13bd451980bfcb3c7281b976","sha256":"D8111CAAC5C94CF4DC64EAE58726F1EB3E5D1F93E9380331C57850E9E63EF932","bytes":6276608,"status":"ready"},"packageName":"package-4b3c06db6b084347b9cb8e700336818b.zip","packageStatus":"ready","packagePreviousSha256":"b249093e281359d46cf46ec83394a4b148d48d248ee4ce5b0652760757048b48","packagePreviousBytes":7438459,"priorStageCommit":"11AA605D2574560AF0CD76E478C07402ED81B4DA","priorStageInfoSha256":"6D0E774CC444C3D1988660550FC4C1BB905E98A0EAEBAF2F6DA004B528581F4C","priorPreviousInfoSha256":"895C861872D68E4A399309AD2D3367774BFCEA0582B6B51538C5C9CA25DCA180","priorOwnerSha256":"E965FF53FAF55E354D76F0C989DA85971D1F0F72E055AAE1A6655473769ED160","priorCliSha256":"B9F85719F6529CD58473C53214153FC13B4DC85458CDB0D2B930650580FFD885","priorMaintenanceSha256":"CDEEB4B0E45E3485579688F0F04AD421532DE05C03FF63FDA8FDED7D0F6AAA40","priorHookSha256":"B9F85719F6529CD58473C53214153FC13B4DC85458CDB0D2B930650580FFD885","priorAuxiliarySha256":{"bin\\Install-Prunlet.ps1":"76F6FC69B0BBF211BE8262D31B0C053CB17D5A2CF34133D99BC27E08DA7A0FDC","bin\\PRUNLET.md":"2E7701941C4F72C697C24F0173EA055C2742F7219E27B63C7C073036B63211EC","bin\\configuration-common.ps1":"FA59756F39DC7E1A01B017ECFE83AE336F0822353C0E1002879F408BA8AC692F","bin\\install-agent-instructions.ps1":"731BA772470E96FFF345EF28E44156FF91A7F8690D243B9789271DCDEF1638CA","bin\\install-codex.ps1":"CE02BE63682984862B91F17BA43F6DC1E37DBA3E82191BD319126A25B4D40FE5","bin\\maintenance-task.ps1":"A05A3B4AE319FBA6AEB5EE99E393B384F36B5E07010A20AB7C9FC7015884D6E3","bin\\start-prunlet-mcp.ps1":"55A9A8D95BE5B898B8F8916F12CD9176ABA96E71372929AEF5B7D83C6584EFD7","bin\\uninstall-codex.ps1":"6027DA012B8677B55CDB68813EDBA9DA9E261467473C7B709B74BE443BCCFE8E","bin\\uninstall-maintenance.ps1":"F280222AD8A66A200D622F92578173B98AE832436A6BC5374E4C8B9F785A191B"},"cacheBaseline":null,"stageWriteName":"","stageWriteOldSha256":"","stageWriteNewSha256":"","stageWriteBytes":0,"rotationName":"","rotationStatus":"","rotationPriorSha256":"","rotationCandidateSha256":"","rotationBackupName":"","rotationCliBackup":"prunlet.previous.exe","rotationMaintenanceBackup":"prunlet-maintenance.previous.exe","rotationHookBackup":"prunlet-hook.previous.exe","auxiliaryBackupSha256":{"bin\\Install-Prunlet.ps1":"449FB0E6DC8EA2981E664C3E171D10D292C34E17C9A4B84BB6B2D1E327EE2343","bin\\PRUNLET.md":"2E7701941C4F72C697C24F0173EA055C2742F7219E27B63C7C073036B63211EC","bin\\configuration-common.ps1":"FA59756F39DC7E1A01B017ECFE83AE336F0822353C0E1002879F408BA8AC692F","bin\\install-agent-instructions.ps1":"817FB59E7765D39B2C63509B06843F60B4E693C588137987780CD4E8490B4BD7","bin\\install-codex.ps1":"CE02BE63682984862B91F17BA43F6DC1E37DBA3E82191BD319126A25B4D40FE5","bin\\maintenance-task.ps1":"A05A3B4AE319FBA6AEB5EE99E393B384F36B5E07010A20AB7C9FC7015884D6E3","bin\\start-prunlet-mcp.ps1":"55A9A8D95BE5B898B8F8916F12CD9176ABA96E71372929AEF5B7D83C6584EFD7","bin\\uninstall-codex.ps1":"6027DA012B8677B55CDB68813EDBA9DA9E261467473C7B709B74BE443BCCFE8E","bin\\uninstall-maintenance.ps1":"F280222AD8A66A200D622F92578173B98AE832436A6BC5374E4C8B9F785A191B"},"auxiliaryRotationName":"","auxiliaryRotationStatus":"","auxiliaryRotationOldSha256":"","auxiliaryRotationNewSha256":""}"#;
    #[test]
    fn state_written_by_the_shipped_version_remains_readable() {
        let state = UpdateState::parse(SHIPPED_APPLIED_STATE.as_bytes()).unwrap();
        assert!(state.cache_baseline.is_none() && !state.prior_stage_commit.is_empty());
        let rewritten = UpdateState::parse(&state.bytes().unwrap()).unwrap();
        assert_eq!(
            serde_json::to_value(&state).unwrap(),
            serde_json::to_value(&rewritten).unwrap()
        );
        // 旧形式のcacheBaseline（全hashが16進、prior_*なし）も従来どおり読める。
        let mut cached = UpdateState {
            candidate_commit: "A".repeat(40),
            stage_cleanup: "pending".into(),
            prepared_installed_source_info_sha256: "B".repeat(64),
            cache_baseline: Some(StageCacheBaseline {
                commit: "C".repeat(40),
                owner_sha256: "D".repeat(64),
                source_info_sha256: "E".repeat(64),
                cli_sha256: "F".repeat(64),
                maintenance_sha256: "1".repeat(64),
                hook_sha256: "F".repeat(64),
                auxiliary_sha256: AUXILIARY_NAMES
                    .iter()
                    .map(|n| (format!("bin\\{n}"), "2".repeat(64)))
                    .collect(),
            }),
            ..Default::default()
        };
        UpdateState::parse(&cached.bytes().unwrap()).unwrap();
        // 旧版が書いたことのない形（空hash・prior_*との共存）は、新しい版だけが書く。
        cached
            .cache_baseline
            .as_mut()
            .unwrap()
            .source_info_sha256
            .clear();
        assert!(UpdateState::parse(&cached.bytes().unwrap()).is_ok());
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
