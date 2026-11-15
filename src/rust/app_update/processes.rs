//! 導入先（Velopack の root）から動いている、自分以外のプロセスの列挙（適用前の二重確認）。
//!
//! 主な安全装置は製品ロック（[`super::lock`]）で、これは「ロックを持たない経路」（hook の複製、旧版、
//! 想定外の起動）を取りこぼさないための二重確認である。Velopack の適用（`Update.exe apply`）は root から
//! 動く自分以外の全プロセスを強制終了するため、1つでも見つかれば適用しない（強制終了はしない）。
//!
//! 判定の規則:
//! - 実行ファイルのパスが root の配下 → 他のプロセス（busy）。
//! - パスを読めない（権限不足など）プロセスのうち、名前が `prunlet.exe` / `prunlet-maintenance.exe` のもの →
//!   root から動いているかどうか判定できないので **busy に倒す**。
//! - `prunlet-hook.exe`（root の外の複製）は更新の対象外なので、パスを読めなくても数えない。
use std::path::{Path, PathBuf};

/// 列挙した1プロセス。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessEntry {
    pub pid: u32,
    /// 実行ファイル名（スナップショットの `szExeFile`。パスが読めなくても得られる）。
    pub name: String,
    /// 実行ファイルのフルパス。読めなければ None。
    pub image: Option<PathBuf>,
}

/// 判定結果。
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Scan {
    /// root の配下から動いている他のプロセス。
    pub others: Vec<u32>,
    /// パスを読めず、root 配下かどうか分からない `prunlet*.exe`。
    pub unreadable: Vec<u32>,
}

impl Scan {
    /// 1つでもあれば適用してはならない。
    pub fn is_busy(&self) -> bool {
        !self.others.is_empty() || !self.unreadable.is_empty()
    }
}

/// 比較用の正規化（拡張パスの接頭辞を外し、区切りを `/`、小文字にする。Windows のパスは大小を区別しない）。
fn normalize(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    text.strip_prefix("//?/")
        .unwrap_or(&text)
        .to_ascii_lowercase()
}

/// `candidate` が `root` の配下か（`root` 自身は含めない。`/a/b` と `/a/bc` を取り違えない）。
pub fn is_under(root: &Path, candidate: &Path) -> bool {
    let mut root = normalize(root);
    if !root.ends_with('/') {
        root.push('/');
    }
    normalize(candidate).starts_with(&root)
}

/// 製品の名前（パスを読めない場合に busy に倒す対象）。フック複製は含めない。
fn is_guarded_name(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "prunlet.exe" | "prunlet-maintenance.exe"
    )
}

/// 列挙結果から判定する（純関数。単体テストで規則を確かめる）。
pub fn classify(entries: &[ProcessEntry], root: &Path, own_pid: u32) -> Scan {
    let mut scan = Scan::default();
    for entry in entries {
        if entry.pid == own_pid {
            continue;
        }
        match &entry.image {
            Some(image) if is_under(root, image) => scan.others.push(entry.pid),
            Some(_) => {}
            None if is_guarded_name(&entry.name) => scan.unreadable.push(entry.pid),
            None => {}
        }
    }
    scan
}

/// root 配下で `Update.exe`（Velopack の更新器）が動いているか。列挙できなければ、動いていると
/// みなす（適用中マーカーを放棄扱いにして、入れ替えの最中に起動してしまう側を避ける）。
pub fn updater_running(root: &Path) -> bool {
    match list_processes() {
        Ok(entries) => entries.iter().any(|entry| {
            entry.name.eq_ignore_ascii_case("Update.exe")
                && entry
                    .image
                    .as_deref()
                    .is_none_or(|image| is_under(root, image))
        }),
        Err(_) => true,
    }
}

/// root から動いている他のプロセスを調べる。列挙そのものが失敗したら Err（呼び出し側は適用しない）。
pub fn scan(root: &Path, own_pid: u32) -> std::io::Result<Scan> {
    Ok(classify(&list_processes()?, root, own_pid))
}

fn list_processes() -> std::io::Result<Vec<ProcessEntry>> {
    use std::{ffi::OsString, os::windows::ffi::OsStringExt};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, INVALID_HANDLE_VALUE},
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW,
                TH32CS_SNAPPROCESS,
            },
            Threading::{
                OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
            },
        },
    };
    // SAFETY: Win32 の列挙 API。構造体は dwSize を設定して渡し、ハンドルは必ず閉じる。
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(std::io::Error::last_os_error());
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut found = Vec::new();
        let mut more = Process32FirstW(snapshot, &mut entry) != 0;
        while more {
            let pid = entry.th32ProcessID;
            let name_length = entry
                .szExeFile
                .iter()
                .position(|unit| *unit == 0)
                .unwrap_or(entry.szExeFile.len());
            let name = String::from_utf16_lossy(&entry.szExeFile[..name_length]);
            let mut image = None;
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if !handle.is_null() {
                let mut buffer = vec![0u16; 32 * 1024];
                let mut length = buffer.len() as u32;
                if QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut length) != 0 {
                    image = Some(PathBuf::from(OsString::from_wide(
                        &buffer[..length as usize],
                    )));
                }
                CloseHandle(handle);
            }
            found.push(ProcessEntry { pid, name, image });
            more = Process32NextW(snapshot, &mut entry) != 0;
        }
        CloseHandle(snapshot);
        Ok(found)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(pid: u32, name: &str, image: Option<&str>) -> ProcessEntry {
        ProcessEntry {
            pid,
            name: name.into(),
            image: image.map(PathBuf::from),
        }
    }

    #[test]
    fn root_matching_is_directory_aware_and_case_insensitive() {
        let root = Path::new(r"C:\Users\a\AppData\Local\PrunletApp");
        assert!(is_under(
            root,
            Path::new(r"C:\Users\a\AppData\Local\PrunletApp\current\prunlet.exe")
        ));
        assert!(is_under(
            root,
            Path::new(r"c:\users\A\appdata\local\prunletapp\Update.exe")
        ));
        assert!(is_under(
            root,
            Path::new(r"\\?\C:\Users\a\AppData\Local\PrunletApp\current\x.exe")
        ));
        // 名前が前方一致するだけの別フォルダーと、導入先そのものは対象外。
        assert!(!is_under(
            root,
            Path::new(r"C:\Users\a\AppData\Local\PrunletApp2\x.exe")
        ));
        assert!(!is_under(root, root));
    }

    #[test]
    fn classification_counts_root_processes_and_unreadable_product_processes() {
        let root = Path::new(r"C:\L\PrunletApp");
        let entries = vec![
            entry(
                10,
                "prunlet.exe",
                Some(r"C:\L\PrunletApp\current\prunlet.exe"),
            ),
            entry(11, "prunlet-maintenance.exe", None),
            entry(12, "PRUNLET.EXE", None),
            // フック複製は root の外。読めなくても数えない。
            entry(13, "prunlet-hook.exe", None),
            entry(
                14,
                "prunlet-hook.exe",
                Some(r"C:\L\Prunlet\hook\prunlet-hook.exe"),
            ),
            // 無関係なプロセスは、読めなくても数えない。
            entry(15, "svchost.exe", None),
            entry(16, "notepad.exe", Some(r"C:\Windows\notepad.exe")),
            // 自分自身は除く。
            entry(
                99,
                "prunlet.exe",
                Some(r"C:\L\PrunletApp\current\prunlet.exe"),
            ),
            // 旧導入（bin）の exe は root の外。
            entry(
                17,
                "prunlet.exe",
                Some(r"C:\Users\a\.local\Prunlet\bin\prunlet.exe"),
            ),
        ];
        let scan = classify(&entries, root, 99);
        assert_eq!(scan.others, vec![10]);
        assert_eq!(scan.unreadable, vec![11, 12]);
        assert!(scan.is_busy());
        // 何も居なければ busy ではない。
        assert!(!classify(&entries[3..7], root, 99).is_busy());
    }

    #[test]
    fn a_real_process_started_from_the_root_is_detected() {
        // 導入先に見立てたフォルダーへ、実在する実行ファイルを複製して起動する（終了待ちの長い ping）。
        let base =
            std::env::temp_dir().join(format!("prunlet-procs-{}", uuid::Uuid::new_v4().simple()));
        let current = base.join("current");
        std::fs::create_dir_all(&current).unwrap();
        let system = std::env::var_os("SystemRoot")
            .map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from);
        let ping = system.join("System32").join("ping.exe");
        let copy = current.join("prunlet.exe");
        std::fs::copy(&ping, &copy).unwrap();
        let mut child = std::process::Command::new(&copy)
            .args(["-n", "30", "127.0.0.1"])
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let found = (0..50).find_map(|_| {
            let scan = scan(&base, std::process::id()).unwrap();
            if scan.others.contains(&child.id()) {
                Some(scan)
            } else {
                std::thread::sleep(std::time::Duration::from_millis(100));
                None
            }
        });
        let _ = child.kill();
        let _ = child.wait();
        assert!(found.is_some(), "the child process was not detected");
        // 自分自身（テストの実行ファイル）は数えない。
        let own = scan(&base, child.id()).unwrap();
        assert!(!own.others.contains(&std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
    }
}
