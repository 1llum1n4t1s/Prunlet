//! Setup（Velopack）版の起動処理・確認と取得・適用・登録（Windows 専用。第1段）。
//!
//! 確定設計は `D:\tmp\prunlet-velopack\design.md`。Prunlet は削除ガードなので、参照実装（Scriptura・Plumivox）より
//! 厳しく、ロック・マーカー・hook を Velopack の root の外（`%LOCALAPPDATA%\Prunlet`）に置く。
//!
//! # 管理外のビルドでは何もしない
//! 従来の導入（`.local\Prunlet\bin`）・開発ビルド・hook 名の exe は Velopack の管理下ではない。
//! [`is_managed_exe`] は、実行ファイルの親が `current` で、その親に `Update.exe` がある場合にだけ真になる。
//! それ以外ではこのモジュールは状態フォルダーを含め**何も読み書きしない**（`bin\prunlet.exe` の挙動を変えない）。
//!
//! # 構成
//! - `lock`: 製品ロック（CLI・MCP・worker・保守が共有、`update-apply` が排他）と適用中マーカー
//! - `processes`: 導入先から動くプロセスの二重確認（パスを読めない `prunlet*.exe` は busy）
//! - [`trust`] / [`authenticode`] / [`release`]: nupkg の信頼検査（署名・製品名・版・エントリ集合・machine・
//!   R2 の署名付きマニフェスト `manifests/<版>/velopack-win-x64.json` の SHA-256 照合）。適用直前・fail-closed
//! - `hook`: root の外への hook 複製
//! - `host`: ホスト設定（Claude Code など）の自動書換え
//! - `logon`: HKCU Run への `update-apply` 登録
//! - `legacy`: 旧導入の検知
//!
//! # 流れ
//! - インストール・更新の直後（Velopack のフック）: hook 複製 → ホスト設定の書換え → Run 登録。必ず終了コード 0。
//!   失敗は記録し、`setup status` と次回の MCP 起動・ログオンで再試行する。
//! - MCP 内: 24時間に1回、確認と取得だけを行う（適用しない）。
//! - ログオン時の `update-apply`: 確認・取得 → 信頼検査 → 排他ロック → 列挙 → 再照合 → マーカー → 引き渡し。
//!   busy でも強制終了しない。適用を引き渡したら保守は続けず直ちに終了する（Update.exe は呼び出し元の終了を待つ）。
pub mod authenticode;
pub mod hook;
pub mod host;
pub mod legacy;
pub mod lock;
pub mod logon;
pub mod paths;
pub mod processes;
pub mod release;
pub mod trust;

use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use velopack::{
    ApplyWaitMode, HttpOptions, UpdateCheck, UpdateManager, VelopackApp, VelopackAsset,
    locator::{self, LocationContext, VelopackLocator},
    sources::UpdateSource,
};

/// 本番の packId（`%LOCALAPPDATA%\Prunlet` は Backups で使用中のため `Prunlet` は使えない）。
/// 実際の処理は manifest の id を使う（E2E のテスト用 packId でも本番名の Run 値などを書かないため）。
pub const PACK_ID: &str = "PrunletApp";
/// 本番のフィード（`releases.win.json` と `*-full.nupkg` をここから配信する）。チャネルは `win`。
pub const FEED_URL: &str = "https://prunlet.kagayoi.com/velopack/";
/// 設定・確認時刻のファイル名（状態フォルダー）。
pub const SETTINGS_FILE: &str = "app-update.json";
/// 確認・取得の重複を防ぐロック（製品ロックとは別。状態フォルダー）。
pub const CYCLE_LOCK: &str = "app-update.lock";
/// 診断ログ（hook やログオン時の起動はコンソールを持たないため、結果はこのファイルで確かめる）。
pub const LOG_FILE: &str = "app-update.log";
/// 導入記録（hook 複製・Run 登録・再試行の要否）。
pub const SETUP_STATE_FILE: &str = "setup-state.json";
/// ホスト設定の書換え記録。
pub const HOST_RECORD_FILE: &str = "host-rewrite.json";
const LOG_LIMIT: u64 = 64 * 1024;
/// 前回の確認（成功・失敗のどちらも）からこの時間が過ぎるまで、ネットワークへ出ない。
pub const CHECK_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

// ───────────────────────── 共通の小さな補助 ─────────────────────────

/// 一時ファイルへ書いてから rename で置き換える（途中で止まっても壊れたファイルを残さない）。
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let directory = path
        .parent()
        .ok_or_else(|| std::io::Error::other("the path has no parent folder"))?;
    fs::create_dir_all(directory)?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = directory.join(format!(".{name}.{}.tmp", uuid::Uuid::new_v4().simple()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// 現在時刻（UNIX 秒）。
pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

/// 診断ログへ1行足す。失敗は無視し、肥大化したら作り直す。管理下と分かった後だけ呼ぶ。
fn log_line(state_dir: &Path, message: &str) {
    let path = state_dir.join(LOG_FILE);
    let _ = fs::create_dir_all(state_dir);
    if fs::metadata(&path).is_ok_and(|meta| meta.len() > LOG_LIMIT) {
        let _ = fs::remove_file(&path);
    }
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "{} {message}", now_unix());
    }
}

/// JSON ファイルを読む（無い・壊れていれば空のオブジェクト）。
fn read_object(path: &Path) -> Value {
    fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

fn write_object(path: &Path, value: &Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    atomic_write(path, &bytes)
}

// ───────────────────────── 設定（auto_update と時刻） ─────────────────────────

/// 自動更新の設定と、前回の確認・失敗時刻。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AutoUpdateSettings {
    /// 確認・取得と、ログオン時の適用を行うか。未設定は `true`。
    pub auto_update: bool,
    pub last_checked_at: Option<u64>,
    pub last_failed_at: Option<u64>,
}

impl Default for AutoUpdateSettings {
    fn default() -> Self {
        Self {
            auto_update: true,
            last_checked_at: None,
            last_failed_at: None,
        }
    }
}

/// JSON から設定を作る。壊れた JSON・型の違う項目は項目ごとに既定値へ戻し、決して失敗しない。
pub fn parse_settings(bytes: &[u8]) -> AutoUpdateSettings {
    let Ok(value) = serde_json::from_slice::<Value>(bytes) else {
        return AutoUpdateSettings::default();
    };
    AutoUpdateSettings {
        auto_update: value
            .get("auto_update")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        last_checked_at: value.get("last_checked_at").and_then(Value::as_u64),
        last_failed_at: value.get("last_failed_at").and_then(Value::as_u64),
    }
}

/// 状態フォルダーから設定を読む。
pub fn load_settings(state_dir: &Path) -> AutoUpdateSettings {
    match fs::read(state_dir.join(SETTINGS_FILE)) {
        Ok(bytes) => parse_settings(&bytes),
        Err(_) => AutoUpdateSettings::default(),
    }
}

fn record_time(state_dir: &Path, key: &str, now: u64) {
    let path = state_dir.join(SETTINGS_FILE);
    let mut current = read_object(&path);
    current[key] = json!(now);
    let _ = write_object(&path, &current);
}

/// 前回の時刻から24時間以上たったか。未記録と未来の時刻（時計の巻き戻し）は「時期」とみなす。
pub fn is_due(last: Option<u64>, now: u64) -> bool {
    match last {
        None => true,
        Some(last) if last > now => true,
        Some(last) => now - last >= CHECK_INTERVAL.as_secs(),
    }
}

/// 自動で確認・取得をするべきか（ON で、成功・失敗の時刻とも24時間より前）。
pub fn should_check(settings: &AutoUpdateSettings, now: u64) -> bool {
    settings.auto_update
        && is_due(settings.last_checked_at, now)
        && is_due(settings.last_failed_at, now)
}

// ───────────────────────── 管理下の判定 ─────────────────────────

/// 実行中の exe が Velopack の管理下（`<root>\current\prunlet.exe` で `<root>\Update.exe` がある）か。
/// パスの文字列と `Update.exe` の存在確認だけで、管理外では何も読まない。
pub fn is_managed_path(exe: &Path) -> bool {
    let Some(current) = exe.parent() else {
        return false;
    };
    current
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("current"))
        && current
            .parent()
            .is_some_and(|root| root.join("Update.exe").is_file())
}

/// 実行中の exe が管理下か。hook 名の exe は常に管理外として扱う（root の外の複製）。
pub fn is_managed_exe() -> bool {
    std::env::current_exe().is_ok_and(|exe| {
        !exe.file_name()
            .is_some_and(|n| n.eq_ignore_ascii_case(paths::HOOK_FILE_NAME))
            && is_managed_path(&exe)
    })
}

/// 管理下の配置情報。
pub struct Managed {
    pub locator: VelopackLocator,
}

impl Managed {
    /// 管理下なら配置情報。管理外では None（Velopack の位置探索もしない）。
    pub fn detect() -> Option<Self> {
        if !is_managed_exe() {
            return None;
        }
        locator::auto_locate_app_manifest(LocationContext::FromCurrentExe)
            .ok()
            .map(|locator| Self { locator })
    }

    pub fn app_id(&self) -> String {
        self.locator.get_manifest_id()
    }

    pub fn version(&self) -> String {
        self.locator.get_manifest_version_full_string()
    }

    pub fn root(&self) -> PathBuf {
        self.locator.get_root_dir()
    }

    /// `current\prunlet.exe`（hook 複製・Run・ホスト設定が指す CLI）。
    pub fn executable(&self) -> PathBuf {
        self.locator.get_main_exe_path()
    }
}

/// 更新元を作る。`velopack-test` ビルドに限り、`PRUNLET_VELOPACK_TEST_FEED_DIR` のローカルフォルダーを更新元にできる。
fn update_source() -> Box<dyn UpdateSource> {
    #[cfg(feature = "velopack-test")]
    if let Some(directory) = std::env::var_os("PRUNLET_VELOPACK_TEST_FEED_DIR") {
        return Box::new(velopack::sources::FileSource::new(PathBuf::from(directory)));
    }
    // 時間制限（接続から転送の終わりまで）。ログオン時の起動や MCP の確認が、ネットワークの不調で止まり続けない。
    Box::new(velopack::sources::HttpSource::new_with_options(
        FEED_URL,
        HttpOptions {
            Headers: Vec::new(),
            TimeoutMilliseconds: FEED_TIMEOUT_MS,
        },
    ))
}

/// フィード・nupkg の取得の時間制限（ミリ秒）。nupkg は十数 MB なので、確認だけの時間より長く取る。
const FEED_TIMEOUT_MS: u64 = 120_000;
/// 取得済みの更新が、この日数を超えて適用されないままのときに警告する（M2）。
const PENDING_WARN_SECS: u64 = 3 * 24 * 60 * 60;

fn manager() -> Result<UpdateManager, String> {
    UpdateManager::new_boxed(update_source(), None, None)
        .map_err(|error| format!("Velopack update manager is unavailable: {error}"))
}

/// ファイルが、期待の署名者の有効な Authenticode（タイムスタンプ付き）で署名されていることを要求する。
/// テスト用機能で署名の省略が明示されたときだけ通す。hook 複製と、引き渡し直前の `<root>\Update.exe` の検査に使う。
fn require_expected_signature(path: &Path, what: &str) -> Result<(), String> {
    if trust::unsigned_allowed_for_test() {
        return Ok(());
    }
    let facts = authenticode::signature_facts(path);
    if facts.valid
        && facts.timestamped
        && facts.common_name.as_deref() == Some(trust::EXPECTED_SIGNER_COMMON_NAME)
    {
        Ok(())
    } else {
        Err(format!("{what} is not signed by the expected publisher."))
    }
}

/// hook 複製が `current\prunlet.exe` と同じ内容か。比較できなければ None。
fn hook_matches_cli(managed: &Managed) -> Option<bool> {
    let hook = paths::hook_executable()?;
    let current = trust::sha256_file(&managed.executable()).ok()?;
    Some(trust::sha256_file(&hook).ok().as_deref() == Some(current.as_str()))
}

/// 導入処理（hook 複製・ホスト設定・Run 登録）のやり直しが要るか。
/// 導入記録が無い・版が現行と違う・要再試行の印がある・hook 複製が CLI と一致しない、のいずれか。
fn install_needed(managed: &Managed, state: &Path) -> bool {
    let record = read_object(&state.join(SETUP_STATE_FILE));
    record.get("updatedAt").is_none()
        || record.get("version").and_then(Value::as_str) != Some(managed.version().as_str())
        || record
            .get("needsRetry")
            .and_then(Value::as_bool)
            .unwrap_or(true)
        || hook_matches_cli(managed) == Some(false)
}

/// 検査・取得の作業用フォルダー（状態フォルダーの下。root の外で、利用者だけが書ける）。
fn work_dir(state_dir: &Path) -> PathBuf {
    state_dir.join("verify")
}

// ───────────────────────── 起動時の Velopack フック ─────────────────────────

/// 引数が Velopack のフック（`--veloapp-*`）か。
pub fn is_velopack_hook(args: &[String]) -> bool {
    args.first()
        .is_some_and(|arg| arg.to_ascii_lowercase().starts_with("--veloapp-"))
}

/// 失敗・panic を飲み込んで実行する（フックは必ず終了コード 0 で終えるため）。
fn guarded(state_dir: Option<&Path>, label: &str, work: impl FnOnce()) {
    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)).is_err()
        && let Some(dir) = state_dir
    {
        log_line(dir, &format!("{label}: unexpected failure"));
    }
}

/// Velopack のフック引数を処理して、終了コード 0 を返す。`cli::run` が引数検査より前に呼ぶ。
/// 管理外（`Managed::detect` が None）でも終了コードは 0 で、何も書かない。
pub fn run_velopack_hook(args: &[String]) -> i32 {
    // フックの処理は Velopack が管理下のときだけ意味を持つ。管理外なら Velopack を初期化しない。
    if Managed::detect().is_none() {
        return 0;
    }
    let state = paths::state_dir();
    let mut app = VelopackApp::build()
        .set_args(args.to_vec())
        .set_auto_apply_on_startup(false);
    app = app
        .on_after_install_fast_callback(|_| {
            guarded(paths::state_dir().as_deref(), "install", || {
                install_steps("install")
            })
        })
        .on_after_update_fast_callback(|_| {
            guarded(paths::state_dir().as_deref(), "updated", || {
                install_steps("updated")
            })
        })
        .on_before_uninstall_fast_callback(|_| {
            guarded(paths::state_dir().as_deref(), "uninstall", uninstall_steps)
        });
    // Velopack 自身の想定外の panic でも、終了コード 0 を守る。run() は通常のフックでは exit(0) で戻らない。
    guarded(state.as_deref(), "velopack-hook", || app.run());
    0
}

/// インストール・更新の直後の処理。順序: hook 複製 → ホスト設定の書換え（hook 複製が検証済みのときだけ）→ Run 登録。
/// 結果は導入記録・書換え記録・診断ログへ残す。失敗は呼び出し元へ返さない（フックは必ず終了コード 0）。
pub fn install_steps(label: &str) {
    let Some(managed) = Managed::detect() else {
        return;
    };
    let (Some(state), Some(hook_dir)) = (paths::state_dir(), paths::hook_dir()) else {
        return;
    };
    let _ = fs::create_dir_all(&state);
    let executable = managed.executable();
    let mut record = read_object(&state.join(SETUP_STATE_FILE));
    let mut retry = false;
    // 途中で止まっても（panic・強制終了・電源断）再試行が残るよう、先に「要再試行」を書き、
    // 全手順が終わった末尾で、実際の結果（成功なら false）に書き直す。
    record["needsRetry"] = json!(true);
    let _ = write_object(&state.join(SETUP_STATE_FILE), &record);

    // 1. hook 複製。複製に署名を要求する（テスト用機能で省略した場合を除く）。
    let verify = |copy: &Path| require_expected_signature(copy, "The hook copy");
    let hook_outcome = hook::install(&executable, &hook_dir, &verify);
    let hook_ok = match &hook_outcome {
        Ok(hook::Outcome::Deferred(reason)) => {
            retry = true;
            record["hook"] = json!({"status":"deferred","detail":reason,"at":now_unix()});
            // 旧 hook が検証済みで残っているので、書換えは続けてよい（旧 hook の内容は以前の版のまま動く）。
            hook_dir.join(paths::HOOK_FILE_NAME).is_file()
        }
        Ok(outcome) => {
            record["hook"] =
                json!({"status":format!("{outcome:?}").to_lowercase(),"at":now_unix()});
            true
        }
        Err(error) => {
            retry = true;
            record["hook"] = json!({"status":"failed","detail":error,"at":now_unix()});
            false
        }
    };
    log_line(
        &state,
        &format!("{label}: hook {}", record["hook"]["status"]),
    );

    // 2. ホスト設定の書換え。hook 複製が検証済みで存在する場合だけ。
    if hook_ok {
        let timestamp = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
        let report = host::rewrite_all(
            &host::HostPaths::resolve(),
            paths::legacy_bin().as_deref(),
            &executable,
            &hook_dir.join(paths::HOOK_FILE_NAME),
            &timestamp,
        );
        if report.skipped_reason.is_some() || report.files.iter().any(|f| f.status == "skipped") {
            retry = true;
        }
        record_host_rewrite(&state, &report);
        log_line(
            &state,
            &format!(
                "{label}: host rewrite {} file(s) changed",
                report
                    .files
                    .iter()
                    .filter(|f| f.status == "rewritten")
                    .count()
            ),
        );
    }

    // 2.5. 新規利用者の config。旧導入の config があればそれを使い、作らない。無ければ作る（既存の init と同じ処理）。
    match ensure_config() {
        Ok(status) => record["config"] = json!({"status":status,"at":now_unix()}),
        Err(error) => {
            retry = true;
            record["config"] = json!({"status":"failed","detail":error,"at":now_unix()});
        }
    }

    // 3. Run 登録。
    match logon::register(&managed.app_id(), &executable) {
        Some(Ok(result)) => {
            record["logon"] =
                json!({"status":format!("{result:?}").to_lowercase(),"at":now_unix()});
        }
        Some(Err(error)) => {
            retry = true;
            record["logon"] = json!({"status":"failed","detail":error.to_string(),"at":now_unix()});
        }
        None => {
            record["logon"] = json!({"status":"skipped","detail":"no registry root in this build"});
        }
    }
    record["needsRetry"] = json!(retry);
    record["label"] = json!(label);
    record["version"] = json!(managed.version());
    record["updatedAt"] = json!(now_unix());
    let _ = write_object(&state.join(SETUP_STATE_FILE), &record);
}

/// 新規利用者の config（`%LOCALAPPDATA%\Prunlet\config.json`）を、無ければ作る。
/// 旧導入の config があればそれを使うので作らない。復元用フォルダーは `%LOCALAPPDATA%\Prunlet\recovery`。
/// 既存の config は上書きしない（`init` と同じ `create_config`）。戻り値は記録用の語。
fn ensure_config() -> Result<&'static str, String> {
    let Some(choice) = paths::resolve_config() else {
        return Ok("skipped");
    };
    if choice.source == "legacy" {
        return Ok("legacy");
    }
    if choice.exists {
        // 以前に作ったがマイグレーションが終わっていない（失敗した）場合の再試行も兼ねる。冪等。
        migrate_new_config(&choice.path)?;
        return Ok("exists");
    }
    let Some(data) = paths::data_dir() else {
        return Ok("skipped");
    };
    let recovery = data.join("recovery");
    fs::create_dir_all(&recovery)
        .map_err(|e| format!("The recovery folder cannot be created: {e}"))?;
    crate::cli::create_config(&choice.path, Vec::new(), &recovery.to_string_lossy())
        .map_err(|e| format!("The config cannot be created: {e}"))?;
    migrate_new_config(&choice.path)?;
    Ok("created")
}

/// 新規 config の復元データの保存先を初期化する（旧インストーラーが `init` の後に行う
/// `migrate --apply --if-needed` と同じ）。これが無いと `maintain` などが
/// `migration_required: Registry storage is not initialized` で失敗する。冪等。
fn migrate_new_config(path: &Path) -> Result<(), String> {
    use crate::service::Backend;
    let config = crate::config::Config::load(path)
        .map_err(|e| format!("The new config cannot be loaded: {e}"))?;
    let value = crate::service::Runtime::new(config)
        .execute(
            "migrate",
            &json!({"apply":true,"ifNeeded":true,"retryLegacyDiscard":false}),
            None,
        )
        .map_err(|e| format!("The recovery storage migration failed: {e}"))?;
    if crate::result_status::has_direct_error(&value)
        || value.get("registryReady").and_then(Value::as_bool) != Some(true)
    {
        return Err("The recovery storage migration did not complete.".into());
    }
    Ok(())
}

/// 書換え記録を更新する。`rewritten` はそのまま残し、2回目以降の `unchanged` では書換えの履歴を消さない。
fn record_host_rewrite(state: &Path, report: &host::RewriteReport) {
    let path = state.join(HOST_RECORD_FILE);
    let mut record = read_object(&path);
    if !record.get("files").is_some_and(Value::is_object) {
        record["files"] = json!({});
    }
    for file in &report.files {
        let key = file.path.to_string_lossy().into_owned();
        let entry = &mut record["files"][&key];
        if !entry.is_object() {
            *entry = json!({});
        }
        entry["lastStatus"] = json!(file.status);
        entry["lastChecked"] = json!(now_unix());
        if let Some(reason) = &file.reason {
            entry["reason"] = json!(reason);
        }
        if file.status == "rewritten" {
            entry["rewrittenAt"] = json!(now_unix());
            entry["replacements"] = json!(file.replacements);
            entry["backup"] = json!(file.backup);
        }
    }
    if let Some(reason) = &report.skipped_reason {
        record["lastSkipped"] = json!(reason);
    } else if let Some(object) = record.as_object_mut() {
        object.remove("lastSkipped");
    }
    let _ = write_object(&path, &record);
}

/// アンインストール前の処理。自分を指す Run 値だけを外す。hook 複製は、ホスト設定から参照されている間は残す。
fn uninstall_steps() {
    let Some(managed) = Managed::detect() else {
        return;
    };
    let state = paths::state_dir();
    let outcome = logon::unregister(&managed.app_id(), &managed.executable());
    if let Some(state) = &state {
        log_line(
            state,
            &format!(
                "uninstall: logon entry removed={:?}",
                outcome.map(|r| r.map_err(|e| e.to_string()))
            ),
        );
    }
    let hosts = host::HostPaths::resolve();
    if let Some(hook) = paths::hook_executable()
        && !host_references(&hosts, &hook)
    {
        let _ = fs::remove_file(&hook);
        if let Some(state) = &state {
            log_line(
                state,
                "uninstall: hook copy removed (no host setting references it)",
            );
        }
    }
}

/// ホスト設定のどれかが hook 複製のパスを参照しているか（参照されている間は複製を残す）。
fn host_references(hosts: &host::HostPaths, hook: &Path) -> bool {
    let plain = hook.to_string_lossy().into_owned();
    let escaped = plain.replace('\\', "\\\\");
    let mut candidates = Vec::new();
    if let Some(claude) = &hosts.claude {
        for name in ["settings.json", "CLAUDE.md", "hooks/powershell-guard.ts"] {
            candidates.push(claude.join(name));
        }
    }
    if let Some(codex) = &hosts.codex {
        candidates.push(codex.join("hooks.json"));
        candidates.push(codex.join("config.toml"));
    }
    candidates.into_iter().any(|path| {
        fs::read_to_string(path).is_ok_and(|text| text.contains(&plain) || text.contains(&escaped))
    })
}

// ───────────────────────── 製品の入口（共有ロックとマーカー） ─────────────────────────

/// 管理下の CLI・MCP・worker・保守の入口。共有ロックを取って保持し、適用中マーカーを確かめる。
/// 管理外では `Ok(None)`（何も読み書きしない）。戻り値はプロセスの終わりまで保持する。
pub fn enter_product() -> Result<Option<lock::ProductGuard>, String> {
    if !is_managed_exe() {
        return Ok(None);
    }
    let Some(state) = paths::state_dir() else {
        return Ok(None);
    };
    let managed = Managed::detect();
    let version = managed
        .as_ref()
        .map_or_else(|| crate::VERSION.to_owned(), |m| m.version());
    // マーカーが新しくても、Update.exe が動いていないまま猶予を過ぎていれば、放棄されたものとして消して続ける。
    let updater_running = || {
        managed
            .as_ref()
            .is_none_or(|m| processes::updater_running(&m.root()))
    };
    match lock::enter(&state, &version, now_unix(), &updater_running) {
        Ok(guard) => {
            if guard.is_none() {
                log_line(
                    &state,
                    "enter: the product lock could not be opened; continuing",
                );
            }
            Ok(guard)
        }
        Err(refusal) => {
            log_line(&state, &format!("enter: refused: {refusal}"));
            Err(refusal.to_string())
        }
    }
}

// ───────────────────────── 確認・取得 ─────────────────────────

/// 確認・取得の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum CheckOutcome {
    Downloaded(String),
    UpToDate,
    RemoteIsEmpty,
}

/// 取得した nupkg を、検証してから `packages` へ置く。
///
/// **velopack の `download_updates` は使わない。** それは取得直後に nupkg 内の `Squirrel.exe` を
/// `<root>\Update.exe` へ上書き展開し、Delta があれば `Update.exe patch` を実行するため、信頼検査より前に
/// 未検証のコードが root に置かれ、実行され得る。ここでは `TargetFullRelease` の Full だけを、root の外
/// （状態フォルダー配下の専用フォルダー）へ自前で取得し、フィードのサイズ・SHA-256 と照合し、
/// [`trust::verify_package`] と R2 の署名付きマニフェストの SHA-256 照合（[`release::fetch`]）を通ったものだけを
/// `packages` へ移す。マニフェストの版は導入済みより厳密に新しいことも確かめる（後退防止）。
/// Update.exe の更新は、適用時に検証済みの nupkg からだけ行われる。Delta は一切使わない。
fn stage_package(managed: &Managed, state: &Path, asset: &VelopackAsset) -> Result<(), String> {
    let id = managed.app_id();
    let expected_name = format!("{id}-{}-full.nupkg", asset.Version);
    if !asset.Type.eq_ignore_ascii_case("full")
        || asset.FileName != expected_name
        || asset.SHA256.len() != 64
        || !asset.SHA256.bytes().all(|b| b.is_ascii_hexdigit())
        || asset.Size == 0
    {
        return Err("The feed asset is not a well-formed full package.".into());
    }
    let packages = managed.locator.get_packages_dir();
    let destination = packages.join(&asset.FileName);
    if destination.is_file() {
        // 取得済み。適用時に改めて検証する。
        return Ok(());
    }
    let incoming = state
        .join("incoming")
        .join(uuid::Uuid::new_v4().simple().to_string());
    fs::create_dir_all(&incoming)
        .map_err(|e| format!("The staging folder cannot be created: {e}"))?;
    let result = (|| -> Result<(), String> {
        let partial = incoming.join(format!("{}.partial", asset.FileName));
        update_source()
            .download_release_entry(asset, &partial, None)
            .map_err(|e| format!("update download failed: {e}"))?;
        let length = fs::metadata(&partial).map_err(|e| e.to_string())?.len();
        if length != asset.Size {
            return Err("The downloaded package size does not match the feed.".into());
        }
        let sha = trust::sha256_file(&partial).map_err(|e| e.to_string())?;
        if !sha.eq_ignore_ascii_case(&asset.SHA256) {
            return Err("The downloaded package does not match the feed SHA-256.".into());
        }
        let policy = trust::policy_for(&id, &asset.Version);
        let facts = trust::verify_package(&partial, &incoming.join("work"), &policy)
            .map_err(|e| format!("The downloaded package was refused: {}", e.reason()))?;
        let release = release::fetch(
            &asset.Version,
            &asset.FileName,
            &id,
            &managed.locator.get_manifest_version_full_string(),
        );
        match trust::compare_release(&facts.sha256, release) {
            trust::Verdict::Trusted => {}
            other => {
                return Err(format!(
                    "The downloaded package was not confirmed: {other:?}"
                ));
            }
        }
        fs::create_dir_all(&packages).map_err(|e| e.to_string())?;
        // 同じボリュームなら rename、違えば packages 内の一時名へ複製してから rename する。
        if fs::rename(&partial, &destination).is_err() {
            let temporary = packages.join(format!(
                ".{}.{}.partial",
                asset.FileName,
                uuid::Uuid::new_v4().simple()
            ));
            fs::copy(&partial, &temporary).map_err(|e| e.to_string())?;
            fs::rename(&temporary, &destination)
                .inspect_err(|_| {
                    let _ = fs::remove_file(&temporary);
                })
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    })();
    let _ = fs::remove_dir_all(&incoming);
    result
}

/// 確認・取得を1回行う。新版があれば、検証してから `packages` へ置くだけで、適用はしない（[`stage_package`]）。
fn check_and_download(managed: &Managed, state: &Path) -> Result<CheckOutcome, String> {
    let manager = manager()?;
    let check = manager
        .check_for_updates()
        .map_err(|error| format!("update check failed: {error}"))?;
    Ok(match check {
        UpdateCheck::UpdateAvailable(info) => {
            if !info.DeltasToTarget.is_empty() {
                log_line(state, "check: delta assets in the feed are ignored");
            }
            // Delta・BaseRelease は使わず、Full だけを取得する。
            stage_package(managed, state, &info.TargetFullRelease)?;
            CheckOutcome::Downloaded(info.TargetFullRelease.Version.clone())
        }
        UpdateCheck::NoUpdateAvailable => CheckOutcome::UpToDate,
        UpdateCheck::RemoteIsEmpty => CheckOutcome::RemoteIsEmpty,
    })
}

/// 確認・取得し、結果の時刻を記録する（成功・失敗のどちらも24時間の間引きに数える）。
fn checked_cycle(managed: &Managed, state_dir: &Path, label: &str) -> Result<CheckOutcome, String> {
    let result = check_and_download(managed, state_dir);
    match &result {
        Ok(outcome) => {
            record_time(state_dir, "last_checked_at", now_unix());
            log_line(state_dir, &format!("{label}: {outcome:?}"));
        }
        Err(error) => {
            record_time(state_dir, "last_failed_at", now_unix());
            log_line(state_dir, &format!("{label} failed: {error}"));
        }
    }
    result
}

/// 時期なら、ロックを取って確認・取得する（MCP とログオン時の `update-apply` が使う。適用はしない）。
fn background_cycle(managed: &Managed, state_dir: &Path, label: &str) {
    if !should_check(&load_settings(state_dir), now_unix()) {
        return;
    }
    let Some(_lock) = lock::try_lock_named(state_dir, CYCLE_LOCK) else {
        return;
    };
    if !should_check(&load_settings(state_dir), now_unix()) {
        return;
    }
    let _ = checked_cycle(managed, state_dir, label);
}

/// 取得済み（保留）の更新と、その経過秒。保留が無ければ None。
fn pending_age(managed: &Managed) -> Option<(String, u64)> {
    let pending = manager().ok()?.get_update_pending_restart()?;
    let modified = fs::metadata(managed.locator.get_packages_dir().join(&pending.FileName))
        .and_then(|meta| meta.modified())
        .ok()?;
    let age = SystemTime::now()
        .duration_since(modified)
        .map_or(0, |d| d.as_secs());
    Some((pending.Version, age))
}

/// MCP の起動後に別スレッドで呼ぶ。導入記録に再試行が残っていれば導入処理をやり直し、24時間に1回確認・取得する。
/// 適用はしない。管理外では何もしない。
pub fn mcp_background() {
    let Some(managed) = Managed::detect() else {
        return;
    };
    let Some(state) = paths::state_dir() else {
        return;
    };
    guarded(Some(&state), "mcp-background", || {
        // 導入処理の再試行（記録が無い・版が違う・要再試行・hook 複製が CLI と不一致）。使用中の hook は延期される。
        if install_needed(&managed, &state) {
            install_steps("mcp-retry");
        }
        background_cycle(&managed, &state, "mcp-check");
        // 取得済みの更新が長く適用されないままなら、MCP の標準エラーへ警告する（標準出力は MCP のプロトコル用）。
        if let Some((version, age)) = pending_age(&managed)
            && age >= PENDING_WARN_SECS
        {
            eprintln!(
                "Prunlet: update {version} has been downloaded for {} days but not applied. It is applied at logon when no Prunlet process is running; run `prunlet update-apply` after closing Prunlet processes.",
                age / 86_400
            );
        }
    });
}

// ───────────────────────── ログオン時の適用 ─────────────────────────

/// busy の理由。
#[derive(Debug, PartialEq, Eq)]
pub enum Busy {
    /// 他の処理が製品ロック（共有）を持っている。
    Locked,
    /// 導入先から動く他のプロセスがある。
    Processes(usize),
    /// パスを読めない `prunlet*.exe` がある。
    UnreadableProcess(usize),
    /// 適用中マーカーが新しい（別の適用が進行中）。
    ApplyInProgress,
    /// 別の更新処理（確認・取得・適用）が動いている。
    UpdateRunning,
}

/// `update-apply` の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum ApplyOutcome {
    Unmanaged,
    Disabled,
    NothingPending,
    Busy(Busy),
    /// 信頼検査に通らず、適用しなかった（終了コード 2）。
    Untrusted(String),
    /// 確かめられず（署名付きマニフェストを取得・検証できないなど）、適用を次回へ延期した。
    Deferred(String),
    /// 適用を更新器へ引き渡した（このプロセスの終了を待って入れ替わる）。
    Applied(String),
    Failed(String),
}

impl ApplyOutcome {
    /// 標準出力へ1行で出す JSON。`status` の語は E2E と利用者の確認に使う安定した契約。
    pub fn to_json(&self) -> Value {
        match self {
            Self::Unmanaged => json!({"status":"unmanaged"}),
            Self::Disabled => json!({"status":"disabled"}),
            Self::NothingPending => json!({"status":"nothingPending"}),
            Self::Busy(reason) => {
                let (name, count) = match reason {
                    Busy::Locked => ("locked", 0),
                    Busy::Processes(n) => ("processes", *n),
                    Busy::UnreadableProcess(n) => ("unreadableProcess", *n),
                    Busy::ApplyInProgress => ("applyInProgress", 0),
                    Busy::UpdateRunning => ("updateRunning", 0),
                };
                json!({"status":"busy","reason":name,"processes":count})
            }
            Self::Untrusted(reason) => json!({"status":"untrusted","reason":reason}),
            Self::Deferred(reason) => json!({"status":"deferred","reason":reason}),
            Self::Applied(version) => json!({"status":"applied","version":version}),
            Self::Failed(reason) => json!({"status":"failed","reason":reason}),
        }
    }

    /// 終了コード。信頼検査に通らなかったときだけ 2、失敗は 1、ほかは正常な判断として 0。
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Untrusted(_) => 2,
            Self::Failed(_) => 1,
            _ => 0,
        }
    }
}

/// 適用に必要な入力と、外界への依存（テストで差し替える）。
pub struct ApplyInputs<'a> {
    pub state_dir: &'a Path,
    /// Velopack の root（導入先）。
    pub root: &'a Path,
    pub own_pid: u32,
    /// 自分（実行中）の版。マーカーの照合に使う。
    pub running_version: &'a str,
    /// 適用する版。
    pub target_version: &'a str,
    /// 信頼検査（Release のハッシュ照合を含む）。通れば nupkg の SHA-256 を返す。
    pub verify: &'a dyn Fn() -> trust::Verdict,
    /// 検査した nupkg の SHA-256（検査時の値）。
    pub verified_sha256: &'a dyn Fn() -> Option<String>,
    /// 適用直前の nupkg の再ハッシュ。
    pub rehash: &'a dyn Fn() -> std::io::Result<String>,
    /// 導入先のプロセス列挙。
    pub scan: &'a dyn Fn(&Path, u32) -> std::io::Result<processes::Scan>,
    /// 更新器への引き渡し。
    pub handoff: &'a dyn Fn() -> Result<(), String>,
    /// 引き渡し直前の `<root>\Update.exe` の検査（Authenticode。テスト用機能で署名を省いたときだけ通す）。
    pub check_updater: &'a dyn Fn() -> Result<(), String>,
    /// root 配下で Update.exe が動いているか（適用中マーカーが放棄されたかの判定に使う）。
    pub updater_running: &'a dyn Fn() -> bool,
}

/// 保留中の更新を、安全な場合だけ適用する。強制終了も再起動もしない。
///
/// 順序: 信頼検査（重い処理は排他の前に済ませる）→ 排他ロックの try-lock（取れなければ busy）→ マーカーの確認 →
/// プロセス列挙（二重確認）→ nupkg の再ハッシュ → 適用中マーカーを書く → 更新器へ引き渡し。
/// 排他の区間は、列挙・再照合・マーカー・引き渡しだけにする。
pub fn apply_pending(inputs: &ApplyInputs<'_>) -> ApplyOutcome {
    match (inputs.verify)() {
        trust::Verdict::Refused(reason) => return ApplyOutcome::Untrusted(reason),
        trust::Verdict::Deferred(reason) => return ApplyOutcome::Deferred(reason),
        trust::Verdict::Failed(reason) => return ApplyOutcome::Failed(reason),
        trust::Verdict::Trusted => {}
    }
    let verified = (inputs.verified_sha256)();
    let _exclusive = match lock::try_exclusive(inputs.state_dir) {
        Ok(Some(guard)) => guard,
        Ok(None) => return ApplyOutcome::Busy(Busy::Locked),
        Err(error) => return ApplyOutcome::Failed(format!("The product lock failed: {error}")),
    };
    // 別の適用が進行中（新しいマーカー）なら、重ねて適用しない。
    let marker = lock::read_marker(inputs.state_dir);
    match lock::marker_action(marker.as_ref(), inputs.running_version, now_unix()) {
        // Update.exe が動いていないまま猶予を過ぎたマーカーは、放棄された（失敗した）ものとして消す。
        lock::MarkerAction::Refuse
            if marker
                .as_ref()
                .is_some_and(|m| lock::abandoned(m, now_unix(), inputs.updater_running)) =>
        {
            lock::clear_marker(inputs.state_dir)
        }
        lock::MarkerAction::Refuse => return ApplyOutcome::Busy(Busy::ApplyInProgress),
        lock::MarkerAction::ClearApplied | lock::MarkerAction::ClearStale => {
            lock::clear_marker(inputs.state_dir)
        }
        lock::MarkerAction::Proceed => {}
    }
    // 二重確認: ロックに参加しない経路や、旧版のプロセスを取りこぼさない。列挙できなければ適用しない。
    match (inputs.scan)(inputs.root, inputs.own_pid) {
        Ok(scan) if scan.is_busy() => {
            return ApplyOutcome::Busy(if scan.others.is_empty() {
                Busy::UnreadableProcess(scan.unreadable.len())
            } else {
                Busy::Processes(scan.others.len())
            });
        }
        Ok(_) => {}
        Err(error) => {
            return ApplyOutcome::Failed(format!("Processes could not be listed: {error}"));
        }
    }
    // 検査から引き渡しまでの間の差し替えを、再ハッシュで確かめる。
    match (inputs.rehash)() {
        Ok(actual) if Some(&actual) == verified.as_ref() => {}
        Ok(_) => {
            return ApplyOutcome::Untrusted(
                "The update package changed after it was verified.".into(),
            );
        }
        Err(error) => {
            return ApplyOutcome::Failed(format!("The package cannot be re-read: {error}"));
        }
    }
    // 更新器（<root>\Update.exe）の署名を、引き渡す直前に確かめる。検証済みの nupkg が展開される前の
    // 現行の Update.exe を実行するので、差し替えられていないことをここで確認する。
    if let Err(reason) = (inputs.check_updater)() {
        return ApplyOutcome::Untrusted(reason);
    }
    let marker = lock::Marker {
        target: inputs.target_version.to_owned(),
        written_at: now_unix(),
        pid: inputs.own_pid,
    };
    if let Err(error) = lock::write_marker(inputs.state_dir, &marker) {
        return ApplyOutcome::Failed(format!("The apply marker cannot be written: {error}"));
    }
    if let Err(error) = (inputs.handoff)() {
        lock::clear_marker(inputs.state_dir);
        return ApplyOutcome::Failed(error);
    }
    ApplyOutcome::Applied(inputs.target_version.to_owned())
}

/// `update-apply` の本体（管理下の実環境）。
pub fn update_apply() -> ApplyOutcome {
    let Some(managed) = Managed::detect() else {
        return ApplyOutcome::Unmanaged;
    };
    let Some(state) = paths::state_dir() else {
        return ApplyOutcome::Disabled;
    };
    if !load_settings(&state).auto_update {
        return ApplyOutcome::Disabled;
    }
    // 同時に走る別の更新処理（MCP の確認・取得など）と重ならないよう、更新用のロックを取る。
    let Some(_cycle) = lock::try_lock_named(&state, CYCLE_LOCK) else {
        return ApplyOutcome::Busy(Busy::UpdateRunning);
    };
    // 導入処理の再試行（hook 複製の延期など）。
    guarded(Some(&state), "logon", || {
        if install_needed(&managed, &state) {
            install_steps("logon-retry");
        }
    });
    let manager = match manager() {
        Ok(manager) => manager,
        Err(error) => return ApplyOutcome::Failed(error),
    };
    // 取得済み（保留）の更新があれば、ネットワークの確認より先に適用の判定をする。確認・取得は保留が無いときだけ
    // （失敗しても現行版のまま続く）。保留があるのに確認が先だと、ネットワークの不調で適用が遅れ続ける。
    let mut pending = manager.get_update_pending_restart();
    if pending.is_none() {
        guarded(Some(&state), "logon-check", || {
            if should_check(&load_settings(&state), now_unix()) {
                let _ = checked_cycle(&managed, &state, "logon-check");
            }
        });
        pending = manager.get_update_pending_restart();
    }
    let Some(pending) = pending else {
        return ApplyOutcome::NothingPending;
    };
    let package = managed.locator.get_packages_dir().join(&pending.FileName);
    if !package.is_file() {
        return ApplyOutcome::Failed("The pending update package is missing.".into());
    }
    let work = work_dir(&state);
    let policy = trust::policy_for(&managed.app_id(), &pending.Version);
    let sha = std::cell::RefCell::new(None::<String>);
    let verify = || -> trust::Verdict {
        let facts = match trust::verify_package(&package, &work, &policy) {
            Ok(facts) => facts,
            Err(error) => {
                log_line(&state, &format!("update-apply: {error:?}"));
                return error.into_verdict();
            }
        };
        // 局所検査に通ってから、R2 の署名付きマニフェストを取りに行く（通らないパッケージのためには通信しない）。
        let release = release::fetch(
            &pending.Version,
            &pending.FileName,
            &managed.app_id(),
            &managed.locator.get_manifest_version_full_string(),
        );
        let verdict = trust::compare_release(&facts.sha256, release);
        if verdict == trust::Verdict::Trusted {
            *sha.borrow_mut() = Some(facts.sha256);
        } else {
            log_line(&state, &format!("update-apply: {verdict:?}"));
        }
        verdict
    };
    let verified = || sha.borrow().clone();
    let rehash = || trust::sha256_file(&package);
    let handoff = || -> Result<(), String> {
        manager
            .unsafe_apply_updates(
                &pending,
                true,
                ApplyWaitMode::WaitPid(std::process::id()),
                false,
                Vec::<String>::new(),
            )
            .map_err(|error| format!("update apply failed: {error}"))
    };
    let root = managed.root();
    let running = managed.version();
    let updater = managed.locator.get_update_path();
    let check_updater = || require_expected_signature(&updater, "Update.exe");
    let updater_running = || processes::updater_running(&root);
    let outcome = apply_pending(&ApplyInputs {
        state_dir: &state,
        root: &root,
        own_pid: std::process::id(),
        running_version: &running,
        target_version: &pending.Version,
        verify: &verify,
        verified_sha256: &verified,
        rehash: &rehash,
        scan: &processes::scan,
        handoff: &handoff,
        check_updater: &check_updater,
        updater_running: &updater_running,
    });
    log_line(&state, &format!("update-apply: {outcome:?}"));
    outcome
}

/// ログオン時の保守（`prunlet-maintenance.exe --config <config> maintain --apply`）を、ウィンドウなしで実行して待つ。
/// 適用を引き渡した場合は呼ばない（保守が root の外へ出ず、Update.exe に強制終了されるため）。
/// config が無い（新規利用者がまだ `init` していない）場合は何もしない。戻り値は診断用の語。
pub fn run_maintenance(managed: &Managed) -> &'static str {
    use std::os::windows::process::CommandExt;
    let Some(choice) = paths::resolve_config() else {
        return "skippedNoConfig";
    };
    if !choice.exists {
        return "skippedNoConfig";
    }
    let exe = managed
        .locator
        .get_current_bin_dir()
        .join("prunlet-maintenance.exe");
    if !exe.is_file() {
        return "skippedMissing";
    }
    // CREATE_NO_WINDOW
    match std::process::Command::new(exe)
        .args(["--config"])
        .arg(&choice.path)
        .args(["maintain", "--apply"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .creation_flags(0x0800_0000)
        .status()
    {
        Ok(status) if status.success() => "ok",
        Ok(_) => "failed",
        Err(_) => "failed",
    }
}

// ───────────────────────── CLI の入口 ─────────────────────────

/// `update-apply`・`update-check`・`setup status|repair` を処理する。該当しなければ None。
/// `--config <絶対パス>` が前置されていても受け付ける（他のコマンドと同じ書式。値は使わず、config は自分で解決する）。
pub fn dispatch(args: &[String]) -> Option<i32> {
    let rest = match args {
        [flag, path, rest @ ..] if flag == "--config" && Path::new(path).is_absolute() => rest,
        other => other,
    };
    let command = rest.first()?.as_str();
    let tail = &rest[1..];
    let value = match (command, tail) {
        ("update-apply", []) | ("update-apply", [_]) => {
            if tail.first().is_some_and(|flag| flag != "--no-maintenance") {
                return Some(usage_error());
            }
            let outcome = update_apply();
            let mut value = outcome.to_json();
            let managed = Managed::detect();
            // 保守は、更新の設定（auto_update 無効）や結果（untrusted・busy・失敗）から切り離して必ず続ける。
            // 例外は、適用を更新器へ引き渡した直後だけ（Update.exe が呼び出し元の終了を待つため、直ちに終了する）。
            // --no-maintenance で省ける。
            if let Some(managed) = managed
                && !matches!(outcome, ApplyOutcome::Applied(_))
                && tail.is_empty()
            {
                value["maintenance"] = json!(run_maintenance(&managed));
            }
            print_json(&value);
            return Some(outcome.exit_code());
        }
        ("update-check", []) => {
            // 取得の失敗だけ終了コード 1（update-apply の failed と同じ）。他は正常な判断として 0。
            let (value, code) = update_check();
            print_json(&value);
            return Some(code);
        }
        ("setup", [sub]) if sub == "status" => setup_status(),
        ("setup", [sub]) if sub == "repair" => setup_repair(),
        ("update-apply", _) | ("update-check", _) | ("setup", _) => return Some(usage_error()),
        _ => return None,
    };
    print_json(&value);
    Some(0)
}

fn usage_error() -> i32 {
    print_json(
        &json!({"error":"Use update-apply [--no-maintenance], update-check, setup status or setup repair.","type":"ArgumentException"}),
    );
    1
}

fn print_json(value: &Value) {
    let _ = writeln!(std::io::stdout().lock(), "{value}");
}

/// `update-check`: 間引きを無視して確認・取得する（適用はしない）。
///
/// 結果の JSON と終了コード。終了コードは failed のときだけ 1、unmanaged・disabled・busy・downloaded・
/// upToDate・remoteEmpty は 0。Velopack のフック（`--veloapp-*`）は別経路で、常に 0 で終わる。
fn update_check() -> (Value, i32) {
    let Some(managed) = Managed::detect() else {
        return (json!({"status":"unmanaged"}), 0);
    };
    let Some(state) = paths::state_dir() else {
        return (json!({"status":"disabled"}), 0);
    };
    let Some(_cycle) = lock::try_lock_named(&state, CYCLE_LOCK) else {
        return (json!({"status":"busy","reason":"updateRunning"}), 0);
    };
    match checked_cycle(&managed, &state, "update-check") {
        Ok(CheckOutcome::Downloaded(version)) => (
            json!({"status":"downloaded","currentVersion":managed.version(),"version":version}),
            0,
        ),
        Ok(CheckOutcome::UpToDate) => (
            json!({"status":"upToDate","currentVersion":managed.version()}),
            0,
        ),
        Ok(CheckOutcome::RemoteIsEmpty) => (
            json!({"status":"remoteEmpty","currentVersion":managed.version()}),
            0,
        ),
        Err(error) => (
            json!({"status":"failed","currentVersion":managed.version(),"error":error}),
            1,
        ),
    }
}

/// `setup repair`: インストール時の処理（hook 複製・ホスト設定の書換え・Run 登録）をやり直す。
fn setup_repair() -> Value {
    if Managed::detect().is_none() {
        return json!({"status":"unmanaged"});
    }
    guarded(paths::state_dir().as_deref(), "repair", || {
        install_steps("repair")
    });
    let mut value = setup_status();
    value["repaired"] = json!(true);
    value
}

/// `setup status`: 導入状態・hook 複製・旧導入・ホスト設定の書換え記録などを表示する。
/// 管理外では `{"managed":false}` だけを返し、何も読まない。
pub fn setup_status() -> Value {
    let Some(managed) = Managed::detect() else {
        return json!({"managed":false});
    };
    let state = paths::state_dir();
    let (settings, setup, hosts, marker) = match &state {
        Some(dir) => (
            load_settings(dir),
            read_object(&dir.join(SETUP_STATE_FILE)),
            read_object(&dir.join(HOST_RECORD_FILE)),
            lock::read_marker(dir),
        ),
        None => (AutoUpdateSettings::default(), json!({}), json!({}), None),
    };
    let executable = managed.executable();
    let hook = paths::hook_executable();
    let hook_matches = match (&hook, trust::sha256_file(&executable)) {
        (Some(hook), Ok(current)) => {
            Some(trust::sha256_file(hook).ok().as_deref() == Some(current.as_str()))
        }
        _ => None,
    };
    let config = paths::resolve_config();
    let legacy = paths::legacy_root().map(|root| legacy::inspect(&root));
    let pending_info = pending_age(&managed);
    let pending = pending_info.as_ref().map(|(version, _)| version.clone());
    let notes = status_notes(&hosts, pending_info.as_ref());
    json!({
        "managed": true,
        "notes": notes,
        "packId": managed.app_id(),
        "version": managed.version(),
        "root": managed.root(),
        "executable": executable,
        "stateDir": state,
        "hook": {"path": hook, "exists": hook.as_ref().is_some_and(|p| p.is_file()), "matchesCli": hook_matches},
        "config": config.map(|c| json!({"path": c.path, "source": c.source, "exists": c.exists})),
        "legacy": legacy,
        "autoUpdate": settings.auto_update,
        "lastCheckedAt": settings.last_checked_at,
        "lastFailedAt": settings.last_failed_at,
        "pendingVersion": pending,
        "applyMarker": marker,
        "setup": setup,
        "hostRewrite": hosts,
    })
}

/// `setup status` の案内（英語。AI・人の両方が読む）。未移行の登録と、書換え後に必要な操作を示す。
fn status_notes(hosts: &Value, pending: Option<&(String, u64)>) -> Vec<String> {
    let mut notes = Vec::new();
    if let Some((version, age)) = pending
        && *age >= PENDING_WARN_SECS
    {
        notes.push(format!(
            "update {version} has been downloaded for {} days but not applied: it is applied at logon only when no Prunlet process is running. Close Prunlet processes and run `prunlet update-apply`.",
            age / 86_400
        ));
    }
    let Some(files) = hosts.get("files").and_then(Value::as_object) else {
        return notes;
    };
    for (path, entry) in files {
        let status = entry.get("lastStatus").and_then(Value::as_str);
        let is_toolport = path.to_ascii_lowercase().contains("toolport");
        match status {
            Some("unmigrated") if path.to_ascii_lowercase().ends_with("hooks.json") => {
                notes.push(format!(
                    "{path}: the Codex hook still points to the legacy Prunlet install and was not rewritten (changing a hook command can reset Codex's trust). Update it with Prunlet's Codex integration and re-trust it in Codex's /hooks if asked."
                ))
            }
            Some("unmigrated")
                if entry
                    .get("reason")
                    .and_then(Value::as_str)
                    .is_some_and(|r| r.contains("legacy-form hook")) =>
            {
                notes.push(format!(
                    "{path}: a hook invocation without --cli-executable (legacy form) was left unchanged. Re-register the Prunlet hook so it uses the hook copy."
                ))
            }
            Some("unmigrated") => notes.push(format!(
                "{path}: an MCP registration still launches the legacy start-prunlet-mcp.ps1 and was not rewritten ({}). Re-register the Prunlet MCP server to run `<current\\prunlet.exe> --config <config> mcp` directly.",
                entry.get("reason").and_then(Value::as_str).unwrap_or("unrecognized shape")
            )),
            Some("skipped") => notes.push(format!(
                "{path}: was not rewritten ({}). `prunlet setup repair` retries.",
                entry.get("reason").and_then(Value::as_str).unwrap_or("unknown reason")
            )),
            _ => {}
        }
        if is_toolport && entry.get("rewrittenAt").is_some() {
            notes.push(format!(
                "{path}: the Prunlet MCP registration was rewritten to start prunlet.exe directly. Restart Toolport (or reconnect its prunlet server) so it re-reads the registry; whether a running Toolport re-reads or overwrites registry.json has not been verified."
            ));
        }
    }
    notes
}

/// 管理下の起動で、旧導入の更新が途中なら拒否する理由を返す（`cli` が config の確定後に呼ぶ）。
pub fn legacy_refusal(config: &Path) -> Option<String> {
    if !is_managed_exe() {
        return None;
    }
    legacy::refuse_if_unfinished(config).err()
}

/// `VelopackAsset` を使う型の参照（未使用警告の抑止ではなく、公開 API として資産を扱えるようにする）。
pub type PendingAsset = VelopackAsset;

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn scratch() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("prunlet-apply-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn idle_scan(_: &Path, _: u32) -> std::io::Result<processes::Scan> {
        Ok(processes::Scan::default())
    }

    /// 全ての外界依存を差し替えた入力で `apply_pending` を実行する。
    fn run(
        state: &Path,
        verdict: trust::Verdict,
        scan: &dyn Fn(&Path, u32) -> std::io::Result<processes::Scan>,
        handoffs: &Cell<u32>,
    ) -> ApplyOutcome {
        apply_pending(&ApplyInputs {
            state_dir: state,
            root: Path::new(r"C:\L\PrunletApp"),
            own_pid: 1,
            running_version: "1.0.0",
            target_version: "1.0.1",
            verify: &|| verdict.clone(),
            verified_sha256: &|| Some("aa".into()),
            rehash: &|| Ok("aa".into()),
            scan,
            handoff: &|| {
                handoffs.set(handoffs.get() + 1);
                Ok(())
            },
            check_updater: &|| Ok(()),
            updater_running: &|| false,
        })
    }

    // 合否基準3: CLI・MCP・worker・保守のどれかが動作中なら busy で延期、強制終了 0 件。マーカー中の新規起動は未実行で拒否。

    #[test]
    fn a_running_product_process_defers_without_handing_off() {
        let state = scratch();
        let handoffs = Cell::new(0);
        // 共有ロックを持つ処理（CLI・MCP・worker・保守のどれでも同じ）が動いている。
        let running = lock::enter(&state, "1.0.0", 1, &|| true).unwrap().unwrap();
        let outcome = run(&state, trust::Verdict::Trusted, &idle_scan, &handoffs);
        assert_eq!(outcome, ApplyOutcome::Busy(Busy::Locked));
        assert_eq!(handoffs.get(), 0, "nothing may be handed to the updater");
        assert!(!lock::marker_path(&state).exists(), "no marker while busy");
        assert_eq!(outcome.exit_code(), 0);
        drop(running);

        // ロックに参加しない経路（旧版・想定外の起動）は、プロセス列挙の二重確認で拾う。
        let busy_scan = |_: &Path, _: u32| {
            Ok(processes::Scan {
                others: vec![10],
                unreadable: vec![],
            })
        };
        assert_eq!(
            run(&state, trust::Verdict::Trusted, &busy_scan, &handoffs),
            ApplyOutcome::Busy(Busy::Processes(1))
        );
        // パスを読めない prunlet*.exe は busy に倒す。
        let unreadable = |_: &Path, _: u32| {
            Ok(processes::Scan {
                others: vec![],
                unreadable: vec![11],
            })
        };
        assert_eq!(
            run(&state, trust::Verdict::Trusted, &unreadable, &handoffs),
            ApplyOutcome::Busy(Busy::UnreadableProcess(1))
        );
        // 列挙そのものが失敗したら、適用しない（fail-closed）。
        let broken = |_: &Path, _: u32| Err(std::io::Error::other("denied"));
        assert!(matches!(
            run(&state, trust::Verdict::Trusted, &broken, &handoffs),
            ApplyOutcome::Failed(_)
        ));
        assert_eq!(handoffs.get(), 0);
        let _ = fs::remove_dir_all(&state);
    }

    #[test]
    fn idle_system_writes_the_marker_and_hands_off_exactly_once() {
        let state = scratch();
        let handoffs = Cell::new(0);
        let outcome = run(&state, trust::Verdict::Trusted, &idle_scan, &handoffs);
        assert_eq!(outcome, ApplyOutcome::Applied("1.0.1".into()));
        assert_eq!(handoffs.get(), 1);
        let marker = lock::read_marker(&state).expect("the marker is written before the hand-off");
        assert_eq!(marker.target, "1.0.1");
        // マーカー中の新規起動（旧版）は、未実行で拒否される。目標版（新版）なら消して通る。
        assert!(matches!(
            lock::enter(&state, "1.0.0", now_unix(), &|| true),
            Err(lock::Refusal::MarkerPending(_))
        ));
        // 新しいマーカーがある間は、重ねて適用しない（二重の引き渡しを避ける）。
        assert_eq!(
            run(&state, trust::Verdict::Trusted, &idle_scan, &handoffs),
            ApplyOutcome::Busy(Busy::ApplyInProgress)
        );
        assert_eq!(handoffs.get(), 1);
        assert!(
            lock::enter(&state, "1.0.1", now_unix(), &|| true)
                .unwrap()
                .is_some()
        );
        assert!(lock::read_marker(&state).is_none());
        let _ = fs::remove_dir_all(&state);
    }

    #[test]
    fn failed_handoff_removes_the_marker() {
        let state = scratch();
        let outcome = apply_pending(&ApplyInputs {
            state_dir: &state,
            root: Path::new(r"C:\L\PrunletApp"),
            own_pid: 1,
            running_version: "1.0.0",
            target_version: "1.0.1",
            verify: &|| trust::Verdict::Trusted,
            verified_sha256: &|| Some("aa".into()),
            rehash: &|| Ok("aa".into()),
            scan: &idle_scan,
            handoff: &|| Err("Update.exe failed".into()),
            check_updater: &|| Ok(()),
            updater_running: &|| false,
        });
        assert!(matches!(outcome, ApplyOutcome::Failed(_)));
        assert!(!lock::marker_path(&state).exists());
        let _ = fs::remove_dir_all(&state);
    }

    #[test]
    fn untrusted_or_unconfirmed_packages_never_reach_the_lock_or_the_updater() {
        let state = scratch();
        let handoffs = Cell::new(0);
        let outcome = run(
            &state,
            trust::Verdict::Refused("bad".into()),
            &idle_scan,
            &handoffs,
        );
        assert_eq!(outcome, ApplyOutcome::Untrusted("bad".into()));
        assert_eq!(outcome.exit_code(), 2);
        let outcome = run(
            &state,
            trust::Verdict::Deferred("offline".into()),
            &idle_scan,
            &handoffs,
        );
        assert_eq!(outcome, ApplyOutcome::Deferred("offline".into()));
        assert_eq!(outcome.exit_code(), 0);
        assert_eq!(handoffs.get(), 0);
        assert!(!lock::marker_path(&state).exists());
        // 検査後に nupkg が差し替わったら拒否する。
        let outcome = apply_pending(&ApplyInputs {
            state_dir: &state,
            root: Path::new(r"C:\L\PrunletApp"),
            own_pid: 1,
            running_version: "1.0.0",
            target_version: "1.0.1",
            verify: &|| trust::Verdict::Trusted,
            verified_sha256: &|| Some("aa".into()),
            rehash: &|| Ok("bb".into()),
            scan: &idle_scan,
            handoff: &|| panic!("must not hand off"),
            check_updater: &|| Ok(()),
            updater_running: &|| false,
        });
        assert!(matches!(outcome, ApplyOutcome::Untrusted(_)));
        // 検査が I/O の失敗で行えなかった場合は、untrusted ではなく failed（適用しない）。
        let outcome = run(
            &state,
            trust::Verdict::Failed("disk".into()),
            &idle_scan,
            &handoffs,
        );
        assert_eq!(outcome, ApplyOutcome::Failed("disk".into()));
        assert_eq!(outcome.exit_code(), 1);
        assert_eq!(handoffs.get(), 0);
        let _ = fs::remove_dir_all(&state);
    }

    #[test]
    fn an_unsigned_update_exe_is_refused_before_the_marker_and_the_hand_off() {
        let state = scratch();
        let handoffs = Cell::new(0);
        let outcome = apply_pending(&ApplyInputs {
            state_dir: &state,
            root: Path::new(r"C:\L\PrunletApp"),
            own_pid: 1,
            running_version: "1.0.0",
            target_version: "1.0.1",
            verify: &|| trust::Verdict::Trusted,
            verified_sha256: &|| Some("aa".into()),
            rehash: &|| Ok("aa".into()),
            scan: &idle_scan,
            handoff: &|| {
                handoffs.set(handoffs.get() + 1);
                Ok(())
            },
            check_updater: &|| Err("Update.exe is not signed by the expected publisher.".into()),
            updater_running: &|| false,
        });
        assert!(matches!(outcome, ApplyOutcome::Untrusted(_)), "{outcome:?}");
        assert_eq!(outcome.exit_code(), 2);
        assert_eq!(handoffs.get(), 0);
        assert!(!lock::marker_path(&state).exists());
        let _ = fs::remove_dir_all(&state);
    }

    #[test]
    fn an_abandoned_apply_marker_does_not_block_a_new_apply() {
        let state = scratch();
        let handoffs = Cell::new(0);
        // 猶予を過ぎ、Update.exe も動いていない（適用が失敗して放棄された）マーカー。TTL（10分）の内でも古いものとして扱う。
        lock::write_marker(
            &state,
            &lock::Marker {
                target: "1.0.1".into(),
                written_at: now_unix() - lock::UPDATER_GRACE_SECS - 1,
                pid: 1,
            },
        )
        .unwrap();
        let outcome = run(&state, trust::Verdict::Trusted, &idle_scan, &handoffs);
        assert_eq!(outcome, ApplyOutcome::Applied("1.0.1".into()));
        assert_eq!(handoffs.get(), 1);
        let _ = fs::remove_dir_all(&state);
    }

    #[test]
    fn settings_and_throttle_behave_like_the_reference_implementations() {
        assert_eq!(parse_settings(b"{ broken"), AutoUpdateSettings::default());
        assert!(!parse_settings(br#"{"auto_update":false}"#).auto_update);
        let day = CHECK_INTERVAL.as_secs();
        assert!(is_due(None, 10));
        assert!(!is_due(Some(1_000), 1_000 + day - 1));
        assert!(is_due(Some(1_000), 1_000 + day));
        assert!(is_due(Some(5_000), 1_000));
        let due = AutoUpdateSettings {
            auto_update: true,
            last_checked_at: Some(0),
            last_failed_at: Some(0),
        };
        assert!(should_check(&due, day));
        assert!(!should_check(
            &AutoUpdateSettings {
                last_failed_at: Some(day - 60),
                ..due
            },
            day
        ));
    }

    #[test]
    fn unmanaged_paths_are_detected_without_reading_anything() {
        // 旧導入・開発ビルドの配置は管理外。
        assert!(!is_managed_path(Path::new(
            r"C:\Users\a\.local\Prunlet\bin\prunlet.exe"
        )));
        assert!(!is_managed_path(Path::new(
            r"D:\Dev\Prunlet\target\debug\prunlet.exe"
        )));
        // `current` でも、親に Update.exe が無ければ管理外。
        assert!(!is_managed_path(Path::new(
            r"D:\nonexistent\current\prunlet.exe"
        )));
        // テストの実行ファイルは Velopack の導入先ではない。
        assert!(!is_managed_exe());
        assert!(Managed::detect().is_none());
        assert_eq!(update_apply(), ApplyOutcome::Unmanaged);
        assert_eq!(setup_status(), json!({"managed":false}));
        assert!(enter_product().unwrap().is_none());
        assert!(!is_velopack_hook(&["--config".into()]));
        assert!(is_velopack_hook(&[
            "--VeloApp-Install".into(),
            "1.0.0".into()
        ]));
    }

    #[test]
    fn dispatch_ignores_unrelated_commands() {
        assert_eq!(dispatch(&[]), None);
        assert_eq!(dispatch(&["delete".into()]), None);
        assert_eq!(
            dispatch(&["--config".into(), r"C:\c.json".into(), "mcp".into()]),
            None
        );
    }
}
