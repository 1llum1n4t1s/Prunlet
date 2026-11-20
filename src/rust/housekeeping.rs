//! 自アプリのデータ領域に溜まる「使われなくなった残り」の自動整理（定期保守 `maintain --apply` から呼ぶ）。
//!
//! # 誰がいつ作るか／現行設計で使われているか（消してよい根拠）
//! - `<config のフォルダー>\.prunlet-mcp-generations`
//!   旧設計（managed 入口が検証済み製品を世代ごとに固定して stable proxy から起動する方式。コミット
//!   77c535b で追加、d121fd3 で廃止）が作った実行体の世代キャッシュ。現行のコード・スクリプト・検証は
//!   この名前を作成も参照もしない（HEAD の全ファイルを検索して確認済み）。ゆえに現行では使われない旧設計の残り。
//!   旧設計は直下に所有印 `.prunlet-mcp-owner.json`（product・purpose・schema・installationRoot）を書いたので、
//!   それを厳密に照合できた場合だけ対象にし、さらに配下から動いているプロセスがいない間だけ消す。
//! - `<config のフォルダー>\.prunlet-update-state.<32桁hex>.pending`
//!   `update::coordinator::write_state` が状態ファイルを公開する前に作る一時ファイル。公開できれば
//!   rename で消え、共有違反などで「何も変わっていない」と確定した失敗では自分で回収する。結果不明の
//!   失敗（新しい状態の唯一の写しの可能性）では意図的に残すため、時間が経ち公開済みの状態より古くなった
//!   ものだけを整理する。
//! - `%LOCALAPPDATA%\Prunlet\Backups\install-<guid>` / `integration-<yyyyMMdd-HHmmss>`
//!   導入（`Install-Prunlet.ps1` の `$runId`）と Codex 連携の登録・解除（`install-codex.ps1` /
//!   `uninstall-codex.ps1`）が実行のたびに新しく作る設定の退避。実行ごとに新規作成され、後続の実行は
//!   過去の退避を読まないため、古い世代は復元に不要。ただし直近の退避は手動の復元に使えるよう残す。
//!
//! # 守る制約
//! - 対象は `config` のフォルダー直下・`Backups` 直下で、名前が厳密に一致する通常のファイル・フォルダーだけ。
//!   reparse point（シンボリックリンク・ジャンクション）と、名前の合わない項目は触らない。
//! - 設定の `backupDirectory`（中央metadata）とその祖先・配下は絶対に対象にしない。
//! - Backups は、この config が管理済み導入のもの（導入記録 `source-info.json` がある、または
//!   `%LOCALAPPDATA%\Prunlet` 直下）と確認できた場合だけ整理する。検証用 fixture の config から呼んでも
//!   利用者本人の Backups を巻き込まない。
//! - 実行頻度は `maintain --apply`（毎日の保守タスク・ログオン時）に従い、独自の状態ファイルは作らない。
//!   保持期間・直近件数が実質の間引きになり、対象が無ければ小さな走査だけで終わる。
//! - 削除は Prunlet 自身のCore（`files::execute("delete")`）へ渡し、Windowsのゴミ箱経由・操作記録なしの
//!   既存契約をそのまま使う。独自の永久削除・コピー・退避は実装しない。
//! - 失敗（使用中・拒否・結果不明を含む）は結果に記録するだけで、`maintain` 本体の成否・終了コードに
//!   影響させない（再送もしない）。結果のJSONは `has_operation_errors` が辿るキー（items など）を使わない。
use std::{
    fs,
    path::{Component, Path, PathBuf},
    time::{Duration, SystemTime},
};

use anyhow::Result;
use serde_json::{Value, json};

/// 旧設計の世代キャッシュのフォルダー名（`config` のフォルダー直下）。
pub const LEGACY_GENERATIONS_DIR: &str = ".prunlet-mcp-generations";
/// Backups の install-* / integration-* を、この日数を過ぎるまで残す。
pub const BACKUP_RETENTION_DAYS: u64 = 30;
/// 期間を過ぎていても、種別ごとに新しい方からこの件数は必ず残す（直近の復元用）。
pub const BACKUP_KEEP_LATEST: usize = 3;
/// 公開済みの状態より古い `.pending` を、この日数を過ぎるまで残す。
pub const PENDING_RETENTION_DAYS: u64 = 30;
/// 旧世代キャッシュは、中の最終更新がこの時間以内なら（旧版がまだ使っている恐れがあるため）見送る。
pub const LEGACY_QUIET_HOURS: u64 = 24;
/// 1回の保守で削除する件数の上限（保守が長引かないようにする。残りは次回に回る）。
pub const MAX_REMOVALS_PER_RUN: usize = 64;

use crate::update::state::STATE_NAME;
/// 状態ファイルとして読む上限（`update::coordinator::read_state` と同じ64 KiB）。
const STATE_READ_LIMIT: u64 = 65536;
/// 最終更新の探索で辿る深さ・件数の上限（巨大な木で保守を止めないため）。
const SCAN_DEPTH: usize = 3;
const SCAN_ENTRIES: usize = 2000;

/// 整理対象を探す場所。
#[derive(Debug, Clone)]
pub struct Roots {
    /// `config` のフォルダー（旧設計の世代キャッシュ・状態ファイルの置き場）。
    pub install_root: PathBuf,
    /// `%LOCALAPPDATA%\Prunlet\Backups`。環境から決められない、またはこの config が管理済み導入のものと
    /// 確認できなければ None（Backups は整理しない）。
    pub backups_root: Option<PathBuf>,
    /// 設定の `backupDirectory`（中央metadata）。この祖先・配下は対象外。
    pub protected: PathBuf,
    /// 指定フォルダー配下から動いているプロセスが（いる／判定できない）なら true を返す。
    /// 実環境は `app_update::processes`、テストは差し替える。
    pub in_use: fn(&Path) -> bool,
}

/// 実環境の使用中判定。列挙できない場合も true（使用中扱い）にして保全へ倒す。
fn process_in_use(path: &Path) -> bool {
    match crate::app_update::processes::scan(path, std::process::id()) {
        Ok(scan) => scan.is_busy(),
        Err(_) => true,
    }
}

/// Backups の置き場を決める（純粋関数）。`local_app_data` は `%LOCALAPPDATA%`。
///
/// 検証用 fixture の config など、実環境の導入と無関係な config から `maintain` を呼んでも利用者本人の
/// Backups を巻き込まないよう、次のどちらかで「この config が管理済み導入のもの」と確認できた場合だけ返す。
/// - config のフォルダーが `%LOCALAPPDATA%\Prunlet` そのもの（Setup 版の新規利用者）
/// - config のフォルダーに導入記録 `source-info.json` がある通常ファイル（従来のZIP導入）
pub fn backups_root_for(install_root: &Path, local_app_data: Option<&Path>) -> Option<PathBuf> {
    let data = local_app_data.filter(|p| p.is_absolute())?.join("Prunlet");
    let managed = components(install_root) == components(&data)
        || fs::symlink_metadata(install_root.join("source-info.json"))
            .is_ok_and(|m| is_plain_file(&m));
    managed.then(|| data.join("Backups"))
}

impl Roots {
    /// 実環境の場所を設定から決める。
    pub fn from_config(config: &crate::config::Config) -> Self {
        let install_root = config
            .path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
        Self {
            backups_root: backups_root_for(&install_root, local.as_deref()),
            install_root,
            protected: PathBuf::from(&config.data.backup_directory),
            in_use: process_in_use,
        }
    }
}

/// 整理対象の種別。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    LegacyGenerations,
    StalePending,
    OldInstallBackup,
    OldIntegrationBackup,
}

impl Kind {
    fn label(self) -> &'static str {
        match self {
            Kind::LegacyGenerations => "legacyGenerations",
            Kind::StalePending => "stalePending",
            Kind::OldInstallBackup => "oldInstallBackup",
            Kind::OldIntegrationBackup => "oldIntegrationBackup",
        }
    }
}

/// 削除候補。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub path: PathBuf,
    pub kind: Kind,
    pub directory: bool,
    pub reason: String,
}

/// 走査結果。
#[derive(Debug, Default)]
pub struct Plan {
    pub candidates: Vec<Candidate>,
    /// 対象外・保全した理由（診断用）。
    pub retained: Vec<String>,
}

/// Backups 内の1エントリ（選別の入力。ファイルシステムから切り離してテストできる形）。
#[derive(Debug, Clone)]
pub struct BackupEntry {
    pub path: PathBuf,
    pub name: String,
    pub modified: SystemTime,
}

fn days(n: u64) -> Duration {
    Duration::from_secs(n * 24 * 60 * 60)
}

/// 通常のフォルダー（リンクでない）か。Windowsではreparse pointをすべて除外する。
fn is_plain_dir(meta: &fs::Metadata) -> bool {
    meta.is_dir() && !is_reparse(meta)
}
fn is_plain_file(meta: &fs::Metadata) -> bool {
    meta.is_file() && !is_reparse(meta)
}
fn is_reparse(meta: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    meta.file_type().is_symlink() || meta.file_attributes() & 0x400 != 0
}

/// 大文字小文字を区別しない（Windows）成分比較用の正規化。
fn components(path: &Path) -> Vec<String> {
    // 拡張パス接頭辞（`\\?\`）の有無で別の場所と誤判定しないよう、文字列で先に外す。
    let text = path.to_string_lossy().replace('/', "\\");
    let text = text.strip_prefix(r"\\?\").unwrap_or(&text).to_owned();
    Path::new(&text)
        .components()
        .filter(|c| !matches!(c, Component::CurDir))
        .map(|c| c.as_os_str().to_string_lossy().to_lowercase())
        .collect()
}
fn within(child: &Path, parent: &Path) -> bool {
    let (c, p) = (components(child), components(parent));
    !p.is_empty() && c.starts_with(&p)
}
/// 中央metadata（`backupDirectory`）の配下、またはそれを含む（祖先）か。
fn overlaps_protected(candidate: &Path, protected: &Path) -> bool {
    within(candidate, protected) || within(protected, candidate)
}

/// `path` と、その配下（深さ・件数に上限）の最終更新のうち最も新しいもの。
/// 書き込み中（導入・登録の実行中）のフォルダーを「古い」と誤判定しないために使う。
fn newest_modified(path: &Path) -> Option<SystemTime> {
    fn walk(
        path: &Path,
        depth: usize,
        budget: &mut usize,
        newest: &mut Option<SystemTime>,
    ) -> bool {
        let Ok(meta) = fs::symlink_metadata(path) else {
            return false;
        };
        if let Ok(t) = meta.modified() {
            *newest = Some(newest.map_or(t, |n| n.max(t)));
        }
        if !is_plain_dir(&meta) || depth >= SCAN_DEPTH {
            return true;
        }
        let Ok(entries) = fs::read_dir(path) else {
            return false;
        };
        for entry in entries.flatten() {
            if *budget == 0 {
                return false;
            }
            *budget -= 1;
            if !walk(&entry.path(), depth + 1, budget, newest) {
                return false;
            }
        }
        true
    }
    let mut newest = None;
    let mut budget = SCAN_ENTRIES;
    // 読み取れない・多すぎて打ち切った場合は「判定できない」として None を返し、呼出元は保全する。
    walk(path, 0, &mut budget, &mut newest).then_some(newest)?
}

fn is_hex32(text: &str) -> bool {
    text.len() == 32 && text.bytes().all(|b| b.is_ascii_hexdigit())
}
/// `install-<guid(N形式)>`。
fn is_install_backup(name: &str) -> bool {
    name.strip_prefix("install-").is_some_and(is_hex32)
}
/// `integration-<yyyyMMdd>-<HHmmss>`。
fn is_integration_backup(name: &str) -> bool {
    let Some(rest) = name.strip_prefix("integration-") else {
        return false;
    };
    let Some((date, time)) = rest.split_once('-') else {
        return false;
    };
    date.len() == 8
        && time.len() == 6
        && date.bytes().all(|b| b.is_ascii_digit())
        && time.bytes().all(|b| b.is_ascii_digit())
}
/// `.prunlet-update-state.<32桁hex>.pending`（`update::budget` と同じ厳密な形）。
fn is_pending_name(name: &str) -> bool {
    name.strip_prefix(".prunlet-update-state.")
        .and_then(|rest| rest.strip_suffix(".pending"))
        .is_some_and(is_hex32)
}

/// Backups の1種別について、削除してよいものを選ぶ（純粋関数）。
///
/// 新しい方から [`BACKUP_KEEP_LATEST`] 件は必ず残し、残りのうち [`BACKUP_RETENTION_DAYS`] を
/// 過ぎたものだけを返す。未来の時刻（時計のずれ）は古いと判定せず残す。
pub fn select_old_backups(
    mut entries: Vec<BackupEntry>,
    now: SystemTime,
    keep_latest: usize,
    retention: Duration,
) -> Vec<BackupEntry> {
    // 新しい順。同時刻は名前の降順で決定的にする（integration-* は名前自体が時刻順）。
    entries.sort_by(|a, b| b.modified.cmp(&a.modified).then(b.name.cmp(&a.name)));
    entries
        .into_iter()
        .skip(keep_latest)
        .filter(|e| {
            now.duration_since(e.modified)
                .is_ok_and(|age| age > retention)
        })
        .collect()
}

/// 世代キャッシュ直下の所有印 `.prunlet-mcp-owner.json`（旧設計が作成。77c535b）を厳密に照合する。
/// product・purpose・schema が一致し、`installationRoot` がこの config のフォルダーと同じ場合だけ true。
fn is_owned_generation_cache(dir: &Path, install_root: &Path) -> bool {
    let marker = dir.join(".prunlet-mcp-owner.json");
    let Ok(meta) = fs::symlink_metadata(&marker) else {
        return false;
    };
    if !is_plain_file(&meta) || meta.len() > 4096 {
        return false;
    }
    let Ok(value) = fs::read(&marker)
        .map_err(drop)
        .and_then(|b| serde_json::from_slice::<Value>(&b).map_err(drop))
    else {
        return false;
    };
    value.get("product").and_then(Value::as_str) == Some("Prunlet")
        && value.get("purpose").and_then(Value::as_str) == Some("mcp-generation")
        && value.get("schema").and_then(Value::as_u64) == Some(1)
        && value
            .get("installationRoot")
            .and_then(Value::as_str)
            .is_some_and(|r| components(Path::new(r)) == components(install_root))
}

/// 小さな JSON を読む（通常ファイル・上限4 KiB・読めなければ None）。
fn read_small_json(path: &Path) -> Option<Value> {
    let meta = fs::symlink_metadata(path).ok()?;
    if !is_plain_file(&meta) || meta.len() > 4096 {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

/// `install-<guid>` が、この導入（`install_root`）の `Install-Prunlet.ps1` が作った退避だと照合する。
/// 直下の `backup-info.json` の `purpose`（製品ファイルの退避）と `installDirectory`（この導入先）が一致する場合だけ true。
/// 別の導入先（検証用 fixture など）が同じ Backups に作った退避は、所有を確認できないので触らない。
fn is_owned_install_backup(dir: &Path, install_root: &Path) -> bool {
    read_small_json(&dir.join("backup-info.json")).is_some_and(|v| {
        v.get("purpose")
            .and_then(Value::as_str)
            .is_some_and(|p| p.starts_with("Restore product files after this update"))
            && v.get("installDirectory")
                .and_then(Value::as_str)
                .is_some_and(|d| components(Path::new(d)) == components(install_root))
    })
}

/// `integration-<日時>` が Codex 連携の登録・解除（`configuration-common.ps1` の退避記録）の作ったものだと照合する。
/// 直下が `<32桁hex>.json`（退避記録）と `<名前>.<32桁hex>.bak`（退避した写し）だけで、記録が1件以上あり、
/// 各記録が `target`・`restore`・`retention`（定型文）を持つ場合だけ true。
fn is_owned_integration_backup(dir: &Path) -> bool {
    let Ok(read) = fs::read_dir(dir) else {
        return false;
    };
    let mut records = 0;
    for (index, entry) in read.enumerate() {
        let Ok(entry) = entry else { return false };
        if index >= 256 {
            return false;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if fs::symlink_metadata(entry.path()).is_ok_and(|m| !is_plain_file(&m)) {
            return false;
        }
        if name.strip_suffix(".json").is_some_and(is_hex32) {
            let valid = read_small_json(&entry.path()).is_some_and(|v| {
                v.get("target").and_then(Value::as_str).is_some()
                    && v.get("restore").and_then(Value::as_str).is_some()
                    && v.get("retention")
                        .and_then(Value::as_str)
                        .is_some_and(|r| r.starts_with("Retain until integration is verified"))
            });
            if !valid {
                return false;
            }
            records += 1;
        } else if !name
            .strip_suffix(".bak")
            .and_then(|rest| rest.rsplit_once('.'))
            .is_some_and(|(leaf, id)| !leaf.is_empty() && is_hex32(id))
        {
            return false;
        }
    }
    records > 0
}

fn plan_legacy_generations(roots: &Roots, now: SystemTime, plan: &mut Plan) {
    let path = roots.install_root.join(LEGACY_GENERATIONS_DIR);
    let Ok(meta) = fs::symlink_metadata(&path) else {
        return; // 無ければ何もしない。
    };
    if !is_plain_dir(&meta) {
        plan.retained.push(format!(
            "{} is not a plain directory and was not touched.",
            path.display()
        ));
        return;
    }
    // Prunlet 自身が作った世代キャッシュだと所有印で確かめる（名前だけで消さない）。
    if !is_owned_generation_cache(&path, &roots.install_root) {
        plan.retained.push(format!(
            "{} has no matching Prunlet owner marker; retained.",
            path.display()
        ));
        return;
    }
    // 世代の実行体が（旧版・Toolport 経由などで）まだ動いているなら絶対に消さない。
    if (roots.in_use)(&path) {
        plan.retained.push(format!(
            "{} has running processes or could not be checked; retained.",
            path.display()
        ));
        return;
    }
    // 旧版がまだ世代を使っている恐れがある間（中が直近に更新された）は見送る。
    match newest_modified(&path) {
        Some(newest)
            if now
                .duration_since(newest)
                .is_ok_and(|age| age > Duration::from_secs(LEGACY_QUIET_HOURS * 3600)) =>
        {
            plan.candidates.push(Candidate {
                path,
                kind: Kind::LegacyGenerations,
                directory: true,
                reason:
                    "Legacy MCP generation cache; the current design neither creates nor reads it."
                        .into(),
            });
        }
        _ => plan.retained.push(format!(
            "{} was modified recently or could not be inspected; retained.",
            path.display()
        )),
    }
}

/// 状態ファイルが読めて `phase` が `idle`（更新が途中でない）ならその更新時刻を返す。
fn idle_state_modified(root: &Path) -> Option<SystemTime> {
    let path = root.join(STATE_NAME);
    let meta = fs::symlink_metadata(&path).ok()?;
    if !is_plain_file(&meta) || meta.len() > STATE_READ_LIMIT {
        return None;
    }
    let value: Value = serde_json::from_slice(&fs::read(&path).ok()?).ok()?;
    (value.get("phase").and_then(Value::as_str) == Some("idle"))
        .then(|| meta.modified().ok())
        .flatten()
}

fn plan_stale_pending(roots: &Roots, now: SystemTime, plan: &mut Plan) {
    let Ok(entries) = fs::read_dir(&roots.install_root) else {
        return;
    };
    let pendings: Vec<PathBuf> = entries
        .flatten()
        .filter(|e| is_pending_name(&e.file_name().to_string_lossy()))
        .map(|e| e.path())
        .collect();
    if pendings.is_empty() {
        return;
    }
    // 更新が途中の間、または状態ファイルを確認できない間は、新しい状態の唯一の写しかもしれないので触らない。
    let Some(state_modified) = idle_state_modified(&roots.install_root) else {
        plan.retained.push(
            "Update-state .pending files were retained because the published state is missing, unreadable or not idle.".into(),
        );
        return;
    };
    for path in pendings {
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        let stale = is_plain_file(&meta)
            && meta.modified().is_ok_and(|m| {
                // 公開済みの状態より古く、かつ保持期間を過ぎたものだけ。
                m < state_modified
                    && now
                        .duration_since(m)
                        .is_ok_and(|a| a > days(PENDING_RETENTION_DAYS))
            });
        if stale {
            plan.candidates.push(Candidate {
                path,
                kind: Kind::StalePending,
                directory: false,
                reason: format!(
                    "Unpublished update-state file older than {PENDING_RETENTION_DAYS} days and than the published idle state."
                ),
            });
        } else {
            plan.retained.push(format!(
                "{} was retained (recent or not plain).",
                path.display()
            ));
        }
    }
}

fn plan_backups(roots: &Roots, now: SystemTime, plan: &mut Plan) {
    let Some(backups) = &roots.backups_root else {
        return;
    };
    let Ok(meta) = fs::symlink_metadata(backups) else {
        return;
    };
    if !is_plain_dir(&meta) {
        plan.retained.push(format!(
            "{} is not a plain directory; retained.",
            backups.display()
        ));
        return;
    }
    // Backups が中央metadata（backupDirectory）と重なる構成では、復元記録を守るため一切触らない。
    if overlaps_protected(backups, &roots.protected) {
        plan.retained.push(
            "The Backups directory overlaps the metadata recovery directory; it was not cleaned."
                .into(),
        );
        return;
    }
    let Ok(read) = fs::read_dir(backups) else {
        return;
    };
    let (mut installs, mut integrations) = (vec![], vec![]);
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_install = is_install_backup(&name);
        let target = if is_install {
            &mut installs
        } else if is_integration_backup(&name) {
            &mut integrations
        } else {
            continue;
        };
        let path = entry.path();
        // 名前だけで消さず、中身の所有印も照合する（別の導入・手作業のフォルダーを巻き込まない）。
        let owned = if is_install {
            is_owned_install_backup(&path, &roots.install_root)
        } else {
            is_owned_integration_backup(&path)
        };
        if !owned {
            plan.retained.push(format!(
                "{} has no matching Prunlet backup marker; retained.",
                path.display()
            ));
            continue;
        }
        // リンク・ファイルは対象外。配下も含めた最新更新を「世代の時刻」にする（書込み中を古いと誤判定しない）。
        let plain = fs::symlink_metadata(&path).is_ok_and(|m| is_plain_dir(&m));
        match (plain, newest_modified(&path)) {
            (true, Some(modified)) => target.push(BackupEntry {
                path,
                name,
                modified,
            }),
            _ => plan.retained.push(format!(
                "{} is not a plain inspectable directory; retained.",
                path.display()
            )),
        }
    }
    for (entries, kind) in [
        (installs, Kind::OldInstallBackup),
        (integrations, Kind::OldIntegrationBackup),
    ] {
        for old in select_old_backups(
            entries,
            now,
            BACKUP_KEEP_LATEST,
            days(BACKUP_RETENTION_DAYS),
        ) {
            plan.candidates.push(Candidate {
                path: old.path,
                kind,
                directory: true,
                reason: format!(
                    "Older than {BACKUP_RETENTION_DAYS} days and not among the newest {BACKUP_KEEP_LATEST} backups of its kind."
                ),
            });
        }
    }
}

/// 整理対象を探す（読み取りのみ。何も変更しない）。
pub fn plan(roots: &Roots, now: SystemTime) -> Plan {
    let mut plan = Plan::default();
    if !roots.install_root.as_os_str().is_empty() {
        plan_legacy_generations(roots, now, &mut plan);
        plan_stale_pending(roots, now, &mut plan);
    }
    plan_backups(roots, now, &mut plan);
    // 最後に中央metadataとの重なりを一括で除外する（どの経路でも保護が効く二重の関門）。
    let protected = &roots.protected;
    let mut kept = vec![];
    plan.candidates.retain(|c| {
        let overlap = !protected.as_os_str().is_empty() && overlaps_protected(&c.path, protected);
        if overlap {
            kept.push(format!(
                "{} overlaps the metadata recovery directory; retained.",
                c.path.display()
            ));
        }
        !overlap
    });
    plan.retained.extend(kept);
    plan
}

/// 計画を実行して結果のJSONを返す。`remove(path, directory)` は1件の削除（Coreへの委譲）。
/// 失敗しても残りを続け、呼出元へエラーを返さない（本処理を止めない）。`apply=false` は報告のみ。
pub fn run(
    roots: &Roots,
    now: SystemTime,
    apply: bool,
    remove: &mut dyn FnMut(&Path, bool) -> Result<()>,
) -> Value {
    let plan = plan(roots, now);
    let describe = |c: &Candidate| json!({"path": c.path.to_string_lossy(), "kind": c.kind.label(), "reason": c.reason});
    let (mut removed, mut failures, mut deferred) = (vec![], vec![], 0usize);
    if apply {
        for (index, candidate) in plan.candidates.iter().enumerate() {
            if index >= MAX_REMOVALS_PER_RUN {
                deferred = plan.candidates.len() - index;
                break;
            }
            match remove(&candidate.path, candidate.directory) {
                Ok(()) => removed.push(describe(candidate)),
                Err(error) => failures.push(json!({
                    "path": candidate.path.to_string_lossy(),
                    "kind": candidate.kind.label(),
                    "message": format!("{error:#}"),
                })),
            }
        }
    }
    json!({
        "dryRun": !apply,
        "backupRetentionDays": BACKUP_RETENTION_DAYS,
        "backupKeepLatest": BACKUP_KEEP_LATEST,
        "planned": if apply { Vec::new() } else { plan.candidates.iter().map(describe).collect() },
        "removed": removed,
        "failures": failures,
        "deferred": deferred,
        "retained": plan.retained,
    })
}

/// 実環境の定期保守から呼ぶ入口。Coreの削除（ゴミ箱・操作記録なし）へ委譲し、失敗は結果に残すだけ。
/// `files::execute("delete")` は共通ロックを取るため、レジストリ保守のロックを解放した後に呼ぶこと。
pub fn run_for_config(config: &crate::config::Config, apply: bool) -> Value {
    let roots = Roots::from_config(config);
    run(&roots, SystemTime::now(), apply, &mut |path, directory| {
        core_delete(config, path, directory)
    })
}

fn core_delete(config: &crate::config::Config, path: &Path, directory: bool) -> Result<()> {
    let args = json!({
        "paths": [path.to_string_lossy()],
        "recursive": directory,
        "dryRun": false,
    });
    let result = crate::files::execute(config, "delete", &args, None)?;
    let item = &result["items"][0];
    match item["status"].as_str() {
        // 通常はゴミ箱へ移る。ゴミ箱が使えない場合のCore定義の永久削除、競合で既に無い場合も成功とみなす。
        Some("recycled" | "permanently_deleted" | "already_absent") => Ok(()),
        // failed / ambiguous はここで再送しない。元の場所とゴミ箱を確認する必要がある。
        other => anyhow::bail!(
            "Core deletion reported {}: {}",
            other.unwrap_or("no status"),
            item["error"].as_str().unwrap_or("no detail")
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "prunlet-housekeeping-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
    fn guid() -> String {
        uuid::Uuid::new_v4().simple().to_string()
    }
    /// 中身つきのフォルダーを作る（最終更新の探索が配下も見ることを確かめるため）。
    fn make_backup(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::create_dir_all(&path).unwrap();
        // install-* の退避は bin を持つ（最終更新の探索が配下も見ることの確認用）。integration-* は平らな記録だけ。
        if name.starts_with("install-") {
            fs::create_dir_all(path.join("bin")).unwrap();
            fs::write(path.join("bin").join("x"), b"x").unwrap();
        }
        // 実際の退避と同じ所有印（導入先は roots() の install_root）。
        let root = dir.parent().unwrap().join("root");
        if name.starts_with("install-") {
            fs::write(
                path.join("backup-info.json"),
                json!({"purpose":"Restore product files after this update; config and recovery are excluded.",
                       "installDirectory":root.to_string_lossy()})
                .to_string(),
            )
            .unwrap();
        } else {
            fs::write(
                path.join(format!("{}.json", guid())),
                json!({"target":"x","existed":false,"restore":"r",
                       "retention":"Retain until integration is verified; remove only these backup records."})
                .to_string(),
            )
            .unwrap();
        }
        path
    }
    fn far_future(base: SystemTime) -> SystemTime {
        base + days(BACKUP_RETENTION_DAYS + 10)
    }
    fn roots(base: &Path) -> Roots {
        Roots {
            install_root: base.join("root"),
            backups_root: Some(base.join("Backups")),
            protected: base.join("root").join("recovery"),
            in_use: |_| false,
        }
    }
    fn names(plan: &Plan) -> Vec<String> {
        let mut v: Vec<String> = plan
            .candidates
            .iter()
            .map(|c| c.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    /// 旧設計が作っていた世代キャッシュの所有印（77c535b）と同じ形を書く。
    fn write_owner_marker(dir: &Path, install_root: &Path) {
        fs::write(
            dir.join(".prunlet-mcp-owner.json"),
            json!({"product":"Prunlet","schema":1,"purpose":"mcp-generation",
                   "installationRoot":install_root.to_string_lossy(),"executableSha256":null})
            .to_string(),
        )
        .unwrap();
    }

    #[test]
    fn name_patterns_are_strict() {
        assert!(is_install_backup(&format!("install-{}", guid())));
        assert!(!is_install_backup("install-xyz"));
        assert!(!is_install_backup(&format!("install-{}x", guid())));
        assert!(is_integration_backup("integration-20261114-084703"));
        assert!(!is_integration_backup("integration-2026114-084703"));
        assert!(!is_integration_backup("integration-20261114-08470a"));
        assert!(!is_integration_backup("agent-instructions-20261114-084703"));
        assert!(is_pending_name(&format!(
            ".prunlet-update-state.{}.pending",
            guid()
        )));
        assert!(!is_pending_name(".prunlet-update-state.json"));
        assert!(!is_pending_name(".prunlet-update-state.abc.pending"));
    }

    #[test]
    fn select_keeps_newest_and_recent_and_future() {
        let now = SystemTime::now();
        let entry = |n: &str, age_days: u64| BackupEntry {
            path: PathBuf::from(n),
            name: n.into(),
            modified: now - days(age_days),
        };
        let old = select_old_backups(
            vec![
                entry("a", 100),
                entry("b", 90),
                entry("c", 80),
                entry("d", 70),
                entry("e", 60),
                entry("f", 5), // 期間内は残る
            ],
            now,
            3,
            days(30),
        );
        // 新しい順 f(5) c? ではなく 5,60,70 の3件を残し、80/90/100 が削除対象。
        let mut got: Vec<&str> = old.iter().map(|e| e.name.as_str()).collect();
        got.sort();
        assert_eq!(got, ["a", "b", "c"]);
        // 全件が期間内なら何も消さない。未来の時刻は古いとみなさない。
        let none = select_old_backups(
            vec![entry("a", 1), entry("b", 2), entry("c", 3), entry("d", 4)],
            now,
            1,
            days(30),
        );
        assert!(none.is_empty());
        let future = BackupEntry {
            path: PathBuf::from("z"),
            name: "z".into(),
            modified: now + days(400),
        };
        assert!(select_old_backups(vec![future], now, 0, days(30)).is_empty());
    }

    #[test]
    fn backups_old_ones_planned_but_latest_and_unrelated_kept() {
        let base = scratch();
        let r = roots(&base);
        fs::create_dir_all(&r.install_root).unwrap();
        let backups = r.backups_root.clone().unwrap();
        fs::create_dir_all(&backups).unwrap();
        let installs: Vec<String> = (0..5).map(|_| format!("install-{}", guid())).collect();
        for n in &installs {
            make_backup(&backups, n);
            std::thread::sleep(Duration::from_millis(30));
        }
        let integrations: Vec<String> = (1..=5)
            .map(|i| format!("integration-2026110{i}-010101"))
            .collect();
        for n in &integrations {
            make_backup(&backups, n);
            std::thread::sleep(Duration::from_millis(30));
        }
        // 名前が合わない項目・ファイルは対象外（agent-instructions-* も要件外なので触らない）。
        make_backup(&backups, &format!("agent-instructions-{}", guid()));
        make_backup(&backups, "install-keepme");
        fs::write(backups.join(format!("install-{}", guid())), b"file").unwrap();

        // 今は期間内なので、件数に関わらず何も消さない。
        assert!(plan(&r, SystemTime::now()).candidates.is_empty());
        // 期間を過ぎた時点では、種別ごとに新しい3件を残し、古い2件ずつが対象になる。
        let later = far_future(SystemTime::now());
        let got = plan(&r, later);
        assert_eq!(got.candidates.len(), 4, "{got:?}");
        let planned = names(&got);
        for kept in [&installs[2..], &integrations[2..]].concat() {
            assert!(!planned.contains(&kept), "newest must be kept: {kept}");
        }
        for old in [&installs[..2], &integrations[..2]].concat() {
            assert!(planned.contains(&old), "old must be planned: {old}");
        }
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn protected_metadata_directory_is_never_a_target() {
        let base = scratch();
        let mut r = roots(&base);
        let backups = r.backups_root.clone().unwrap();
        fs::create_dir_all(&r.install_root).unwrap();
        for i in 1..=5 {
            make_backup(&backups, &format!("integration-2026110{i}-010101"));
        }
        let later = far_future(SystemTime::now());
        assert_eq!(plan(&r, later).candidates.len(), 2);
        // backupDirectory が Backups そのもの（または祖先）なら一切触らない。
        for protected in [
            backups.clone(),
            base.clone(),
            backups.join("integration-20261101-010101"),
        ] {
            r.protected = protected;
            let got = plan(&r, later);
            assert!(
                got.candidates
                    .iter()
                    .all(|c| !overlaps_protected(&c.path, &r.protected)),
                "{got:?}"
            );
        }
        r.protected = backups.clone();
        assert!(plan(&r, later).candidates.is_empty());
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn legacy_generations_removed_only_when_quiet_and_plain() {
        let base = scratch();
        let r = roots(&base);
        let generations = r.install_root.join(LEGACY_GENERATIONS_DIR);
        fs::create_dir_all(generations.join("ABCDEF")).unwrap();
        fs::write(generations.join("ABCDEF").join("prunlet.exe"), b"x").unwrap();
        write_owner_marker(&generations, &r.install_root);
        // 直近に更新された間は旧版が使っている恐れがあるので見送る。
        let now = SystemTime::now();
        assert!(plan(&r, now).candidates.is_empty());
        assert!(!plan(&r, now).retained.is_empty());
        // 静穏期間を過ぎたら対象。
        let later = now + Duration::from_secs((LEGACY_QUIET_HOURS + 1) * 3600);
        let got = plan(&r, later);
        assert_eq!(got.candidates.len(), 1);
        assert_eq!(got.candidates[0].kind, Kind::LegacyGenerations);
        // 通常ファイルの同名は対象にしない。
        fs::remove_dir_all(&generations).unwrap();
        fs::write(&generations, b"file").unwrap();
        assert!(plan(&r, later).candidates.is_empty());
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn legacy_generations_need_owner_marker_and_no_running_process() {
        let base = scratch();
        let mut r = roots(&base);
        let generations = r.install_root.join(LEGACY_GENERATIONS_DIR);
        fs::create_dir_all(generations.join("ABCDEF")).unwrap();
        let later = SystemTime::now() + Duration::from_secs((LEGACY_QUIET_HOURS + 1) * 3600);
        // 所有印が無ければ名前が合っていても触らない。
        assert!(plan(&r, later).candidates.is_empty());
        // 別の導入先の印、product・purpose違い、壊れた印も触らない。
        let marker = generations.join(".prunlet-mcp-owner.json");
        for body in [
            json!({"product":"Prunlet","schema":1,"purpose":"mcp-generation","installationRoot":"C:/elsewhere"}).to_string(),
            json!({"product":"Other","schema":1,"purpose":"mcp-generation","installationRoot":r.install_root.to_string_lossy()}).to_string(),
            json!({"product":"Prunlet","schema":1,"purpose":"other","installationRoot":r.install_root.to_string_lossy()}).to_string(),
            "{ broken".to_string(),
        ] {
            fs::write(&marker, body).unwrap();
            assert!(plan(&r, later).candidates.is_empty());
        }
        // 正しい印なら対象。ただし実行体が動いている（または判定できない）間は絶対に対象にしない。
        write_owner_marker(&generations, &r.install_root);
        assert_eq!(plan(&r, later).candidates.len(), 1);
        r.in_use = |_| true;
        let got = plan(&r, later);
        assert!(got.candidates.is_empty());
        assert!(!got.retained.is_empty());
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn backups_need_a_matching_marker() {
        let base = scratch();
        let r = roots(&base);
        fs::create_dir_all(&r.install_root).unwrap();
        let backups = r.backups_root.clone().unwrap();
        fs::create_dir_all(&backups).unwrap();
        let later = far_future(SystemTime::now());
        // 正しい所有印の退避を各種別5件作る（3件残り、古い2件ずつが対象になる）。
        for i in 0..5 {
            make_backup(&backups, &format!("install-{:032x}", i));
            make_backup(&backups, &format!("integration-2026110{}-010101", i + 1));
        }
        assert_eq!(plan(&r, later).candidates.len(), 4);
        // 別の導入先の退避・印なし・壊れた印・余計なファイルを含むものは、名前が合っていても対象外。
        let foreign = make_backup(&backups, &format!("install-{:032x}", 100));
        fs::write(
            foreign.join("backup-info.json"),
            json!({"purpose":"Restore product files after this update; x","installDirectory":"C:/elsewhere"}).to_string(),
        )
        .unwrap();
        let bare = backups.join(format!("install-{:032x}", 101));
        fs::create_dir_all(&bare).unwrap();
        let broken = make_backup(&backups, &format!("install-{:032x}", 102));
        fs::write(broken.join("backup-info.json"), "{ broken").unwrap();
        let stray = make_backup(&backups, "integration-20250101-010101");
        fs::write(stray.join("notes.txt"), b"mine").unwrap();
        let empty = backups.join("integration-20250102-010101");
        fs::create_dir_all(&empty).unwrap();
        let got = plan(&r, later);
        assert_eq!(got.candidates.len(), 4, "{got:?}");
        for kept in [&foreign, &bare, &broken, &stray, &empty] {
            assert!(got.candidates.iter().all(|c| &c.path != kept), "{kept:?}");
        }
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn backups_root_requires_a_managed_installation() {
        let base = scratch();
        let local = base.join("Local");
        let root = base.join("other-root");
        fs::create_dir_all(&root).unwrap();
        // 導入記録が無い config（検証用 fixture など）は Backups を整理しない。
        assert_eq!(backups_root_for(&root, Some(&local)), None);
        assert_eq!(backups_root_for(&root, None), None);
        assert_eq!(backups_root_for(&root, Some(Path::new("relative"))), None);
        // 導入記録があれば整理する。
        fs::write(root.join("source-info.json"), b"{}").unwrap();
        assert_eq!(
            backups_root_for(&root, Some(&local)),
            Some(local.join("Prunlet").join("Backups"))
        );
        // Setup 版の新規利用者（config が %LOCALAPPDATA%Prunlet 直下）も整理する。
        assert_eq!(
            backups_root_for(&local.join("Prunlet"), Some(&local)),
            Some(local.join("Prunlet").join("Backups"))
        );
        let _ = fs::remove_dir_all(&base);
    }

    #[cfg(windows)]
    #[test]
    fn junctions_and_symlinks_are_never_targets() {
        let base = scratch();
        let r = roots(&base);
        fs::create_dir_all(&r.install_root).unwrap();
        let backups = r.backups_root.clone().unwrap();
        fs::create_dir_all(&backups).unwrap();
        // 本物の古い退避のリンク先（リンク経由で消してはならない）。
        let victim = base.join("victim");
        fs::create_dir_all(victim.join("bin")).unwrap();
        fs::write(victim.join("bin").join("x"), b"x").unwrap();
        let junction = |link: &Path| {
            std::process::Command::new("cmd")
                .args(["/C", "mklink", "/J"])
                .arg(link)
                .arg(&victim)
                .output()
                .is_ok_and(|o| o.status.success())
        };
        let linked = [
            backups.join(format!("install-{}", guid())),
            backups.join("integration-20261101-010101"),
        ];
        let made: Vec<bool> = linked.iter().map(|l| junction(l)).collect();
        if made.iter().any(|m| !m) {
            eprintln!("junction creation unavailable; skipped");
            let _ = fs::remove_dir_all(&base);
            return;
        }
        let generations = r.install_root.join(LEGACY_GENERATIONS_DIR);
        assert!(junction(&generations));
        let later = far_future(SystemTime::now());
        let got = plan(&r, later);
        assert!(got.candidates.is_empty(), "{got:?}");
        assert!(victim.join("bin").join("x").exists());
        // 後始末: ジャンクションは中身を辿らずリンクだけ外す。
        for l in linked.iter().chain([&generations]) {
            let _ = fs::remove_dir(l);
        }
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn stale_pending_needs_idle_state_older_pending_and_age() {
        let base = scratch();
        let r = roots(&base);
        fs::create_dir_all(&r.install_root).unwrap();
        let pending = r
            .install_root
            .join(format!(".prunlet-update-state.{}.pending", guid()));
        fs::write(&pending, b"{}").unwrap();
        let later = far_future(SystemTime::now());
        // 状態ファイルが無い間は保全する。
        assert!(plan(&r, later).candidates.is_empty());
        // 途中（idleでない）・壊れた状態でも保全する。
        let state = r.install_root.join(STATE_NAME);
        for body in [&br#"{"phase":"switching"}"#[..], b"{ broken"] {
            fs::write(&state, body).unwrap();
            assert!(plan(&r, later).candidates.is_empty());
        }
        // idle でも、pending が状態より新しい（同時刻を含む）間は保全する。
        fs::write(&state, br#"{"phase":"idle"}"#).unwrap();
        let old = SystemTime::now() - days(60);
        let set = |p: &Path, t: SystemTime| {
            fs::OpenOptions::new()
                .write(true)
                .open(p)
                .unwrap()
                .set_modified(t)
                .unwrap();
        };
        set(&pending, SystemTime::now());
        assert!(plan(&r, later).candidates.is_empty());
        // 状態が新しく、pending が古く、期間も過ぎていれば対象。期間内なら保全する。
        set(&pending, old);
        let got = plan(&r, later);
        assert_eq!(got.candidates.len(), 1);
        assert_eq!(got.candidates[0].kind, Kind::StalePending);
        // 保持期間内（10日前）の pending は、状態より古くても保全する。
        set(&pending, SystemTime::now() - days(10));
        assert!(plan(&r, SystemTime::now()).candidates.is_empty());
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn run_reports_dry_run_and_continues_after_failures() {
        let base = scratch();
        let r = roots(&base);
        fs::create_dir_all(&r.install_root).unwrap();
        let backups = r.backups_root.clone().unwrap();
        for i in 1..=6 {
            make_backup(&backups, &format!("integration-2026110{i}-010101"));
        }
        let later = far_future(SystemTime::now());
        let calls = RefCell::new(vec![]);
        // dry-run は削除を呼ばず、計画だけを返す。
        let dry = run(&r, later, false, &mut |p, _| {
            calls.borrow_mut().push(p.to_path_buf());
            Ok(())
        });
        assert!(calls.borrow().is_empty());
        assert_eq!(dry["planned"].as_array().unwrap().len(), 3);
        assert_eq!(dry["dryRun"], true);
        // 適用: 1件が失敗しても残りを続け、エラーを返さず結果へ記録する。
        let mut first = true;
        let applied = run(&r, later, true, &mut |p, directory| {
            assert!(directory);
            calls.borrow_mut().push(p.to_path_buf());
            if std::mem::take(&mut first) {
                anyhow::bail!("in use");
            }
            Ok(())
        });
        assert_eq!(calls.borrow().len(), 3);
        assert_eq!(applied["failures"].as_array().unwrap().len(), 1);
        assert_eq!(applied["removed"].as_array().unwrap().len(), 2);
        // 結果は maintain 本体の失敗判定が辿るキー（items など）を含まない。
        let wrapped = json!({"housekeeping": applied});
        assert!(!crate::result_status::has_operation_errors(&wrapped));
        // 実際にはファイルを消していない（注入した削除は何もしない）。
        assert!(backups.join("integration-20261101-010101").exists());
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn removal_count_per_run_is_bounded() {
        let base = scratch();
        let r = roots(&base);
        fs::create_dir_all(&r.install_root).unwrap();
        let backups = r.backups_root.clone().unwrap();
        let total = MAX_REMOVALS_PER_RUN + 5 + BACKUP_KEEP_LATEST;
        for i in 0..total {
            make_backup(&backups, &format!("install-{:032x}", i));
        }
        let later = far_future(SystemTime::now());
        let mut count = 0;
        let value = run(&r, later, true, &mut |_, _| {
            count += 1;
            Ok(())
        });
        assert_eq!(count, MAX_REMOVALS_PER_RUN);
        assert_eq!(value["deferred"], 5);
        let _ = fs::remove_dir_all(&base);
    }
}
