//! 製品ロックと適用中マーカー（削除ガードなので、更新の適用と実行中の処理を厳密に分ける）。
//!
//! # 製品ロック（`product.lock`）
//! `%LOCALAPPDATA%\Prunlet\state\product.lock`（Velopack の root の外）を、次のように使う。
//! - **共有ロック**: 管理下（`current\`）から動く CLI（管理者 CMD を含む）・MCP・待機キューの worker・保守が、
//!   起動直後に取り、プロセスの寿命いっぱい保持する（`ProductGuard` を破棄しない）。
//! - **排他ロック**: `update-apply` だけが try-lock で取る。取れなければ誰かが動いているので、
//!   強制終了せず busy で延期する。
//! - hook は root の外の複製から動き、ロックに参加しない（更新中も deny 以外を返さないため、取れずに
//!   待たされたり拒否されたりする余地を作らない）。
//!
//! Windows のファイルロックはハンドル単位なので、同じプロセスが共有ロックを持ったまま排他を取ることはできない。
//! `update-apply`・Velopack のフック・`setup` は、共有ロックの対象から外している（呼び出し側）。
//!
//! # 適用中マーカー（`update-apply.marker.json`）
//! `update-apply` は排他ロックを持ったまま「目標版・時刻」を書いてから Update.exe に引き渡す。
//! その後、排他ロックは `update-apply` の終了で外れるが、入れ替えは非同期に続く。
//! 新しく起動した処理は、共有ロックを取った後にマーカーを読み、次のように扱う。
//! - 目標版が自分の版と同じ: 適用が終わった新しい版なので、マーカーを消して続ける。
//! - 目標版が違い、書かれてから [`MARKER_TTL_SECS`] 以内: 入れ替えの最中の可能性があるため、
//!   **何も実行せず拒否**する（旧版の exe が消えかけている状態で削除を始めない）。
//! - 目標版が違い、古い: 適用が失敗して残ったものとみなして消し、続ける。
use std::{
    fs::{self, File, OpenOptions, TryLockError},
    io,
    path::{Path, PathBuf},
    time::Duration,
};

use serde::{Deserialize, Serialize};

/// 共有ロックの対象ファイル名。
pub const PRODUCT_LOCK: &str = "product.lock";
/// 適用中マーカーのファイル名。
pub const MARKER_FILE: &str = "update-apply.marker.json";
/// マーカーの有効期間（秒）。Velopack の Update.exe は呼び出し元の終了を最大60秒待つため、
/// それより十分長く、しかし失敗の残骸で永久に拒否し続けない長さにする。
pub const MARKER_TTL_SECS: u64 = 600;
/// マーカーを書いてから、Update.exe が起動するまでの猶予（秒）。マーカーは引き渡しの前に書くので、
/// 書いた直後は Update.exe がまだ動いていない。この猶予を過ぎても root 配下で Update.exe が動いていなければ、
/// 適用は失敗して放棄されたとみなし、TTL を待たずにマーカーを古いものとして扱う。
pub const UPDATER_GRACE_SECS: u64 = 20;
/// 共有ロックを待つ上限。`update-apply` の排他区間は短い（列挙・再照合・マーカー・引き渡しだけ）ので、
/// この時間を超えて取れないなら、適用が長引いているとみなして拒否する。
const SHARED_WAIT: Duration = Duration::from_secs(5);

/// 適用中マーカーの内容。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Marker {
    /// 適用する版（nupkg の版）。
    pub target: String,
    /// 書いた時刻（UNIX 秒）。
    pub written_at: u64,
    /// 書いた `update-apply` の PID（診断用）。
    pub pid: u32,
}

/// 共有ロックの保持者。破棄するとロックが外れるため、プロセスの終わりまで保持する。
#[derive(Debug)]
pub struct ProductGuard {
    _file: File,
}

/// 排他ロックの保持者（`update-apply`）。
#[derive(Debug)]
pub struct ExclusiveGuard {
    _file: File,
}

/// 起動を拒否する理由。
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    /// `update-apply` が排他ロックを持っている。
    UpdateInProgress,
    /// 適用中マーカーが新しく、目標版が自分の版ではない。
    MarkerPending(String),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::UpdateInProgress => f.write_str(
                "Prunlet is being updated right now; the command was not run. Retry in a minute.",
            ),
            Refusal::MarkerPending(target) => write!(
                f,
                "Prunlet is switching to version {target}; the command was not run. Retry in a minute."
            ),
        }
    }
}

impl std::error::Error for Refusal {}

/// マーカーを見た結果の処置（純関数。単体テストで全分岐を確かめる）。
#[derive(Debug, PartialEq, Eq)]
pub enum MarkerAction {
    /// マーカーが無い。
    Proceed,
    /// 目標版が自分の版。適用が終わったのでマーカーを消して続ける。
    ClearApplied,
    /// 古い。適用の失敗が残ったものとして消して続ける。
    ClearStale,
    /// 新しく、目標版でもない。入れ替えの最中の可能性があるので何も実行しない。
    Refuse,
}

/// マーカーと自分の版・現在時刻から処置を決める。
pub fn marker_action(marker: Option<&Marker>, running_version: &str, now: u64) -> MarkerAction {
    let Some(marker) = marker else {
        return MarkerAction::Proceed;
    };
    if marker.target == running_version {
        return MarkerAction::ClearApplied;
    }
    // 時計が戻って書き込み時刻が未来になっても、永久に拒否しない（古い扱いにはせず、TTL 分だけ待たせる）。
    let age = now.saturating_sub(marker.written_at);
    if marker.written_at > now || age < MARKER_TTL_SECS {
        MarkerAction::Refuse
    } else {
        MarkerAction::ClearStale
    }
}

/// 新しい（TTL 内の）マーカーでも、書かれてから猶予を過ぎ、Update.exe が動いていなければ放棄されたものか。
/// 時計の巻き戻しで未来の時刻になっているものは、判定できないので放棄とみなさない。
pub fn abandoned(marker: &Marker, now: u64, updater_running: &dyn Fn() -> bool) -> bool {
    marker.written_at <= now && now - marker.written_at >= UPDATER_GRACE_SECS && !updater_running()
}

fn open_lock_file(state_dir: &Path) -> io::Result<File> {
    fs::create_dir_all(state_dir)?;
    OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(state_dir.join(PRODUCT_LOCK))
}

/// マーカーを読む。無ければ None。壊れていれば、ファイルの更新時刻を書き込み時刻とみなして読む
/// （壊れたマーカーで永久に拒否せず、かつ新しい間は拒否する）。
pub fn read_marker(state_dir: &Path) -> Option<Marker> {
    let path = state_dir.join(MARKER_FILE);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(_) => return None,
    };
    if let Ok(marker) = serde_json::from_slice::<Marker>(&bytes) {
        return Some(marker);
    }
    let modified = fs::metadata(&path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |elapsed| elapsed.as_secs());
    Some(Marker {
        target: String::new(),
        written_at: modified,
        pid: 0,
    })
}

/// マーカーを書く（排他ロックを持った `update-apply` だけが呼ぶ）。
pub fn write_marker(state_dir: &Path, marker: &Marker) -> io::Result<()> {
    let bytes = serde_json::to_vec_pretty(marker).map_err(io::Error::other)?;
    super::atomic_write(&state_dir.join(MARKER_FILE), &bytes)
}

/// マーカーを消す（無ければ何もしない）。
pub fn clear_marker(state_dir: &Path) {
    let _ = fs::remove_file(state_dir.join(MARKER_FILE));
}

/// 管理下の処理の入口。共有ロックを取り（排他が持たれていれば短く待つ）、マーカーを確かめる。
///
/// ロックファイルを作れない・開けないなど I/O の失敗は拒否にせず `Ok(None)` で続行する
/// （状態フォルダーの不調で削除ツールが使えなくなるより、プロセス列挙の二重確認に任せる方を選ぶ。
/// 呼び出し側は失敗を診断ログへ残す）。
pub fn enter(
    state_dir: &Path,
    running_version: &str,
    now: u64,
    updater_running: &dyn Fn() -> bool,
) -> Result<Option<ProductGuard>, Refusal> {
    let Ok(file) = open_lock_file(state_dir) else {
        return Ok(None);
    };
    let deadline = std::time::Instant::now() + SHARED_WAIT;
    loop {
        match file.try_lock_shared() {
            Ok(()) => break,
            Err(TryLockError::WouldBlock) => {
                if std::time::Instant::now() >= deadline {
                    return Err(Refusal::UpdateInProgress);
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(TryLockError::Error(_)) => return Ok(None),
        }
    }
    let guard = ProductGuard { _file: file };
    // 共有ロックを持ってからマーカーを読む（読んだ後に update-apply が排他を取って書く競合を避ける。
    // 排他は共有が全て外れないと取れないため、ここで読んだ内容は共有ロックの保持中は変わらない）。
    let marker = read_marker(state_dir);
    match marker_action(marker.as_ref(), running_version, now) {
        MarkerAction::Proceed => {}
        MarkerAction::ClearApplied | MarkerAction::ClearStale => clear_marker(state_dir),
        // Update.exe が動いていないまま猶予を過ぎたマーカーは、放棄された（失敗した）ものとして消して続ける。
        MarkerAction::Refuse
            if marker
                .as_ref()
                .is_some_and(|m| abandoned(m, now, updater_running)) =>
        {
            clear_marker(state_dir)
        }
        MarkerAction::Refuse => {
            return Err(Refusal::MarkerPending(
                marker.map(|m| m.target).unwrap_or_default(),
            ));
        }
    }
    Ok(Some(guard))
}

/// 排他ロックの try-lock（`update-apply`）。誰かが共有ロックを持っていれば None（busy）。
pub fn try_exclusive(state_dir: &Path) -> io::Result<Option<ExclusiveGuard>> {
    let file = open_lock_file(state_dir)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(ExclusiveGuard { _file: file })),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error),
    }
}

/// 状態フォルダー直下の指定名のロックファイルの try-lock（更新の確認・取得の重複防止用）。
/// 保持はファイルを閉じるまで（プロセスの終了を含む）。取れなければ None。
pub fn try_lock_named(state_dir: &Path, name: &str) -> Option<File> {
    fs::create_dir_all(state_dir).ok()?;
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state_dir.join(name))
        .ok()?;
    file.try_lock().ok()?;
    Some(file)
}

/// テストと診断用: マーカーのパス。
pub fn marker_path(state_dir: &Path) -> PathBuf {
    state_dir.join(MARKER_FILE)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("prunlet-lock-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn marker(target: &str, written_at: u64) -> Marker {
        Marker {
            target: target.into(),
            written_at,
            pid: 1,
        }
    }

    #[test]
    fn marker_actions_cover_every_branch() {
        let now = 10_000;
        assert_eq!(marker_action(None, "1.0.0", now), MarkerAction::Proceed);
        // 目標版なら、時刻にかかわらず「適用が終わった」として消す。
        assert_eq!(
            marker_action(Some(&marker("1.0.1", now)), "1.0.1", now),
            MarkerAction::ClearApplied
        );
        assert_eq!(
            marker_action(Some(&marker("1.0.1", 1)), "1.0.1", now),
            MarkerAction::ClearApplied
        );
        // 目標版でなく新しい: 未実行で拒否する。
        assert_eq!(
            marker_action(Some(&marker("1.0.1", now - 5)), "1.0.0", now),
            MarkerAction::Refuse
        );
        assert_eq!(
            marker_action(
                Some(&marker("1.0.1", now - (MARKER_TTL_SECS - 1))),
                "1.0.0",
                now
            ),
            MarkerAction::Refuse
        );
        // 古い: 失敗の残骸として消す。
        assert_eq!(
            marker_action(Some(&marker("1.0.1", now - MARKER_TTL_SECS)), "1.0.0", now),
            MarkerAction::ClearStale
        );
        // 時計の巻き戻しで未来の時刻になっていても、拒否のまま（古い扱いで素通りさせない）。
        assert_eq!(
            marker_action(Some(&marker("1.0.1", now + 100)), "1.0.0", now),
            MarkerAction::Refuse
        );
        // 自分より新しい版が目標でなく、旧版が起動した場合も同じ規則（目標版でなければ拒否または消去）。
        assert_eq!(
            marker_action(Some(&marker("1.0.1", now - 5)), "1.0.2", now),
            MarkerAction::Refuse
        );
    }

    #[test]
    fn enter_refuses_while_marker_is_fresh_and_clears_it_for_the_target() {
        let dir = scratch();
        // マーカー無し: 通る。ロックを保持している間、排他は取れない。
        let guard = enter(&dir, "1.0.0", 1_000, &|| true).unwrap();
        assert!(guard.is_some());
        assert!(
            try_exclusive(&dir).unwrap().is_none(),
            "shared must block exclusive"
        );
        drop(guard);
        assert!(try_exclusive(&dir).unwrap().is_some());

        // 新しいマーカー（目標版でない）: 未実行で拒否し、マーカーは消さない。
        write_marker(&dir, &marker("2.0.0", 1_000)).unwrap();
        assert_eq!(
            enter(&dir, "1.0.0", 1_010, &|| true).unwrap_err(),
            Refusal::MarkerPending("2.0.0".into())
        );
        assert!(marker_path(&dir).exists());
        // 目標版: 消して通る。
        assert!(enter(&dir, "2.0.0", 1_020, &|| true).unwrap().is_some());
        assert!(!marker_path(&dir).exists());
        // 古いマーカー: 失敗として消して通る。
        write_marker(&dir, &marker("3.0.0", 1)).unwrap();
        assert!(enter(&dir, "2.0.0", 1_000_000, &|| true).unwrap().is_some());
        assert!(!marker_path(&dir).exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn exclusive_holder_makes_new_starts_wait_and_then_refuse() {
        let dir = scratch();
        let exclusive = try_exclusive(&dir).unwrap().expect("first exclusive");
        // 排他の保持中は、別の排他も共有も取れない（共有は待った末に拒否される）。
        assert!(try_exclusive(&dir).unwrap().is_none());
        let started = std::time::Instant::now();
        assert_eq!(
            enter(&dir, "1.0.0", 1, &|| true).unwrap_err(),
            Refusal::UpdateInProgress
        );
        assert!(started.elapsed() >= SHARED_WAIT);
        drop(exclusive);
        assert!(enter(&dir, "1.0.0", 1, &|| true).unwrap().is_some());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn broken_marker_is_judged_by_its_modification_time() {
        let dir = scratch();
        fs::write(marker_path(&dir), b"{ not json").unwrap();
        let broken = read_marker(&dir).expect("a broken marker is still a marker");
        assert_eq!(broken.target, "");
        // 書いたばかり（更新時刻が新しい）なので、今は拒否される。
        let now = super::super::now_unix();
        assert_eq!(
            marker_action(Some(&broken), "1.0.0", now),
            MarkerAction::Refuse
        );
        // 十分に時間が過ぎれば消される。
        assert_eq!(
            marker_action(Some(&broken), "1.0.0", now + MARKER_TTL_SECS + 5),
            MarkerAction::ClearStale
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_marker_whose_updater_never_started_is_abandoned_after_the_grace_period() {
        let dir = scratch();
        write_marker(&dir, &marker("2.0.0", 1_000)).unwrap();
        // 書いた直後（猶予内）は、Update.exe が動いていなくても拒否する（引き渡しの前後で起動が遅れる）。
        assert_eq!(
            enter(&dir, "1.0.0", 1_000 + UPDATER_GRACE_SECS - 1, &|| false).unwrap_err(),
            Refusal::MarkerPending("2.0.0".into())
        );
        // 猶予を過ぎても Update.exe が動いていれば、入れ替えの最中なので拒否する。
        assert!(enter(&dir, "1.0.0", 1_000 + UPDATER_GRACE_SECS, &|| true).is_err());
        assert!(marker_path(&dir).exists());
        // 猶予を過ぎ、Update.exe が動いていなければ放棄とみなして消し、TTL（10分）を待たずに通す。
        assert!(
            enter(&dir, "1.0.0", 1_000 + UPDATER_GRACE_SECS, &|| false)
                .unwrap()
                .is_some()
        );
        assert!(!marker_path(&dir).exists());
        // 未来の時刻（時計の巻き戻し）のマーカーは放棄とみなさない。
        write_marker(&dir, &marker("2.0.0", 5_000)).unwrap();
        assert!(enter(&dir, "1.0.0", 1_000, &|| false).is_err());
        let _ = fs::remove_dir_all(&dir);
    }
}
