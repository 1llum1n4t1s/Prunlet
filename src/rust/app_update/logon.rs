//! ログオン時に `update-apply` を起動する登録（HKCU の Run キー）。
//!
//! Velopack の適用は root から動く自分以外の全プロセスを強制終了するため、日中には行わず、ログオン時だけに行う。
//! - 値名は `<packId> Update`（packId は manifest から取る。テスト用 packId でも本番名の値を書かない）。
//! - 値は `conhost.exe --headless "<current\prunlet.exe>" update-apply`。prunlet.exe はコンソール版なので、
//!   そのまま起動するとログオンのたびにコンソールが一瞬出る。`--headless` 経由でウィンドウを作らない。
//! - 別の導入先を指す同名の値は上書きも削除もしない。アンインストールでは自分を指す値だけを外す。
//!
//! 本番の根は HKCU。単体テストは `RegLoadAppKeyW` のプロセス専用ハイブ（ファイルに閉じ、実際の Run キーに
//! 触れない）を根にする。`velopack-test` ビルドの結合テストは、環境変数 `PRUNLET_VELOPACK_TEST_RUN_HIVE`
//! （ハイブのファイルパス）で同じ専用ハイブを使う。環境変数が無い `velopack-test` ビルドは登録しない。
use std::{io, path::Path, ptr::null_mut};

use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ,
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegQueryValueExW, RegSetValueExW,
};

/// HKCU の Run キー。
pub const RUN_SUBKEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const ERROR_SUCCESS: u32 = 0;
const ERROR_FILE_NOT_FOUND: u32 = 2;

/// 登録の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum Registration {
    Created,
    Updated,
    Unchanged,
    /// 別の導入先を指す同名の値があるため、触らなかった。
    ForeignKept,
}

/// Run の値名。
pub fn value_name(app_id: &str) -> String {
    format!("{app_id} Update")
}

/// Run に書くコマンド。パスは二重引用符で囲む（空白を含む導入先でも1つの引数になる）。
pub fn run_command(executable: &Path) -> String {
    let conhost = std::env::var_os("SystemRoot")
        .map(|root| Path::new(&root).join("System32").join("conhost.exe"))
        .map_or_else(
            || "conhost.exe".to_owned(),
            |p| p.to_string_lossy().into_owned(),
        );
    format!(
        "\"{conhost}\" --headless \"{}\" update-apply",
        executable.display()
    )
}

/// 既存の値が、この導入先の実行ファイルを指しているか（引用符で囲んだパスを大小無視で含むか）。
pub fn points_at(command: &str, executable: &Path) -> bool {
    let needle = format!("\"{}\"", executable.display()).to_ascii_lowercase();
    command.to_ascii_lowercase().contains(&needle)
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn check(status: u32) -> io::Result<()> {
    if status == ERROR_SUCCESS {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(status as i32))
    }
}

/// 根にするキー。
pub struct RegKey {
    handle: HKEY,
    owned: bool,
}

impl RegKey {
    pub fn current_user() -> Self {
        Self {
            handle: HKEY_CURRENT_USER,
            owned: false,
        }
    }

    /// ファイルに閉じた専用のハイブを開く（RegLoadAppKeyW。このプロセスだけから見える）。
    pub fn load_app_hive(file: &Path) -> io::Result<Self> {
        use windows_sys::Win32::System::Registry::{
            KEY_ALL_ACCESS, REG_PROCESS_APPKEY, RegLoadAppKeyW,
        };
        let path = wide(&file.to_string_lossy());
        let mut handle: HKEY = null_mut();
        // SAFETY: path は NUL 終端、handle は書き込み先の変数。
        check(unsafe {
            RegLoadAppKeyW(
                path.as_ptr(),
                &mut handle,
                KEY_ALL_ACCESS,
                REG_PROCESS_APPKEY,
                0,
            )
        })?;
        Ok(Self {
            handle,
            owned: true,
        })
    }

    pub fn create_subkey(&self, subkey: &str) -> io::Result<Self> {
        let name = wide(subkey);
        let mut handle: HKEY = null_mut();
        // SAFETY: name は NUL 終端、handle は書き込み先の変数。
        check(unsafe {
            RegCreateKeyExW(
                self.handle,
                name.as_ptr(),
                0,
                std::ptr::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_QUERY_VALUE | KEY_SET_VALUE,
                std::ptr::null(),
                &mut handle,
                null_mut(),
            )
        })?;
        Ok(Self {
            handle,
            owned: true,
        })
    }

    /// 文字列の値を読む（無ければ None。文字列型以外は空文字として扱い、上書きしない側へ倒す）。
    pub fn query_string(&self, name: &str) -> io::Result<Option<String>> {
        let name = wide(name);
        let mut kind = 0u32;
        let mut size = 0u32;
        // SAFETY: 大きさだけを問い合わせる（データ領域は null）。
        let status = unsafe {
            RegQueryValueExW(
                self.handle,
                name.as_ptr(),
                std::ptr::null(),
                &mut kind,
                null_mut(),
                &mut size,
            )
        };
        if status == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        check(status)?;
        let mut buffer = vec![0u8; size as usize + 2];
        let mut length = size;
        // SAFETY: buffer は length バイト以上の書き込み可能な領域。
        check(unsafe {
            RegQueryValueExW(
                self.handle,
                name.as_ptr(),
                std::ptr::null(),
                &mut kind,
                buffer.as_mut_ptr(),
                &mut length,
            )
        })?;
        if kind != REG_SZ && kind != 2 {
            return Ok(Some(String::new()));
        }
        let units: Vec<u16> = buffer[..length as usize]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_le_bytes(*pair))
            .take_while(|unit| *unit != 0)
            .collect();
        Ok(Some(String::from_utf16_lossy(&units)))
    }

    pub fn set_string(&self, name: &str, value: &str) -> io::Result<()> {
        let name = wide(name);
        let data: Vec<u8> = wide(value)
            .iter()
            .flat_map(|unit| unit.to_le_bytes())
            .collect();
        // SAFETY: data は NUL 終端を含む UTF-16LE のバイト列。
        check(unsafe {
            RegSetValueExW(
                self.handle,
                name.as_ptr(),
                0,
                REG_SZ,
                data.as_ptr(),
                data.len() as u32,
            )
        })
    }

    fn delete_value(&self, name: &str) -> io::Result<()> {
        let name = wide(name);
        // SAFETY: name は NUL 終端。
        let status = unsafe { RegDeleteValueW(self.handle, name.as_ptr()) };
        if status == ERROR_FILE_NOT_FOUND {
            return Ok(());
        }
        check(status)
    }
}

impl Drop for RegKey {
    fn drop(&mut self) {
        if self.owned {
            // SAFETY: owned は自分が開いたハンドルだけに立つ。
            unsafe { RegCloseKey(self.handle) };
        }
    }
}

/// 登録する。値が無ければ作り、自分を指す値なら更新し、別の場所を指す値は触らない。
pub fn register_in(
    root: &RegKey,
    subkey: &str,
    app_id: &str,
    executable: &Path,
) -> io::Result<Registration> {
    let key = root.create_subkey(subkey)?;
    let name = value_name(app_id);
    let desired = run_command(executable);
    match key.query_string(&name)? {
        None => {
            key.set_string(&name, &desired)?;
            Ok(Registration::Created)
        }
        Some(existing) if existing == desired => Ok(Registration::Unchanged),
        Some(existing) if points_at(&existing, executable) => {
            key.set_string(&name, &desired)?;
            Ok(Registration::Updated)
        }
        Some(_) => Ok(Registration::ForeignKept),
    }
}

/// 解除する。自分の導入先を指す値だけを消し、消したかを返す。
pub fn unregister_in(
    root: &RegKey,
    subkey: &str,
    app_id: &str,
    executable: &Path,
) -> io::Result<bool> {
    let key = root.create_subkey(subkey)?;
    let name = value_name(app_id);
    match key.query_string(&name)? {
        Some(existing) if points_at(&existing, executable) => {
            key.delete_value(&name)?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

/// 本番の根（HKCU）。`velopack-test` ビルドは環境変数のハイブだけを使い、無ければ None（登録しない）。
fn production_root() -> Option<io::Result<RegKey>> {
    #[cfg(feature = "velopack-test")]
    {
        let hive = std::env::var_os("PRUNLET_VELOPACK_TEST_RUN_HIVE")?;
        Some(RegKey::load_app_hive(Path::new(&hive)))
    }
    #[cfg(not(feature = "velopack-test"))]
    {
        Some(Ok(RegKey::current_user()))
    }
}

/// 本番の登録。根が無い（テスト用ビルドで環境変数が無い）場合は None。
pub fn register(app_id: &str, executable: &Path) -> Option<io::Result<Registration>> {
    let root = match production_root()? {
        Ok(root) => root,
        Err(error) => return Some(Err(error)),
    };
    Some(register_in(&root, RUN_SUBKEY, app_id, executable))
}

/// 本番の解除。
pub fn unregister(app_id: &str, executable: &Path) -> Option<io::Result<bool>> {
    let root = match production_root()? {
        Ok(root) => root,
        Err(error) => return Some(Err(error)),
    };
    Some(unregister_in(&root, RUN_SUBKEY, app_id, executable))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_quotes_the_path_and_names_the_subcommand() {
        let exe = Path::new(r"C:\Users\a b\AppData\Local\PrunletApp\current\prunlet.exe");
        let command = run_command(exe);
        assert!(command.contains("--headless"));
        assert!(command.ends_with(&format!("\"{}\" update-apply", exe.display())));
        assert!(points_at(&command, exe));
        assert!(!points_at(&command, Path::new(r"C:\Other\prunlet.exe")));
        assert_eq!(value_name("PrunletApp"), "PrunletApp Update");
    }

    #[test]
    fn run_value_is_created_updated_and_removed_only_for_the_own_install() {
        let dir =
            std::env::temp_dir().join(format!("prunlet-run-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let hive = RegKey::load_app_hive(&dir.join("hive.dat")).unwrap();
        let mine = Path::new(r"C:\Apps\PrunletApp\current\prunlet.exe");
        let other = Path::new(r"D:\Elsewhere\current\prunlet.exe");
        let key = hive.create_subkey(RUN_SUBKEY).unwrap();
        key.set_string("Other", "other.exe").unwrap();
        assert_eq!(
            register_in(&hive, RUN_SUBKEY, "TestApp", mine).unwrap(),
            Registration::Created
        );
        assert_eq!(
            register_in(&hive, RUN_SUBKEY, "TestApp", mine).unwrap(),
            Registration::Unchanged
        );
        // 別の導入先からの登録・解除は、既存の値を変えない。
        assert_eq!(
            register_in(&hive, RUN_SUBKEY, "TestApp", other).unwrap(),
            Registration::ForeignKept
        );
        assert!(!unregister_in(&hive, RUN_SUBKEY, "TestApp", other).unwrap());
        let value = key.query_string("TestApp Update").unwrap().unwrap();
        assert!(points_at(&value, mine) && !points_at(&value, other));
        // 古い定義でも、自分を指していれば張り直す。
        key.set_string(
            "TestApp Update",
            &format!("\"{}\" update-apply", mine.display()),
        )
        .unwrap();
        assert_eq!(
            register_in(&hive, RUN_SUBKEY, "TestApp", mine).unwrap(),
            Registration::Updated
        );
        assert!(unregister_in(&hive, RUN_SUBKEY, "TestApp", mine).unwrap());
        assert!(key.query_string("TestApp Update").unwrap().is_none());
        assert_eq!(
            key.query_string("Other").unwrap().as_deref(),
            Some("other.exe")
        );
        assert!(!unregister_in(&hive, RUN_SUBKEY, "TestApp", mine).unwrap());
        drop(key);
        drop(hive);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
