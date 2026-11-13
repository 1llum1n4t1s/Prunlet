//! Windows Shellによる記録なしの削除。実装は同一のネイティブCoreに集約する。
use super::{OwnedHandle, path, security, wide};
use anyhow::{Result, bail};
use std::{
    ffi::c_void,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU32, Ordering},
    },
};
use windows_sys::Win32::{
    Foundation::*,
    Security::*,
    Storage::FileSystem::*,
    System::{Com::*, Threading::*},
};

const BIG: i32 = 0x80270037u32 as i32;
const UNAVAILABLE: i32 = 0x80270036u32 as i32;
const ABORT: i32 = 0x80004004u32 as i32;

/// COMのIID/CLSIDとして渡すGUID。Win32の`GUID`と同じ`repr(C)`レイアウトを持つ。
/// `windows`クレートはこの型のためだけに依存していたため、自前定義で依存グラフを縮める。
/// `windows_sys::core::GUID`は`PartialEq`を持たないので、`sink_query`のIID比較用にderiveする。
// Win32 APIの型名に合わせ、宣言側の`*const GUID`をそのまま読めるようにする。
#[allow(clippy::upper_case_acronyms)]
#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq)]
struct GUID {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

impl GUID {
    /// `windows::core::GUID::from_u128`と同じ並び（上位32bit→data1、次の16bit×2→data2/3、下位64bit→data4をbig-endian）。
    const fn from_u128(uuid: u128) -> Self {
        Self {
            data1: (uuid >> 96) as u32,
            data2: (uuid >> 80 & 0xffff) as u16,
            data3: (uuid >> 64 & 0xffff) as u16,
            data4: (uuid as u64).to_be_bytes(),
        }
    }
}

const SHELL: GUID = GUID::from_u128(0x43826d1e_e718_42ee_bc55_a1e261c37bfe);
const BIN: GUID = GUID::from_u128(0xb7534046_3ecb_4c18_be4e_64cd4cb7d6ac);
const HANDLER: GUID = GUID::from_u128(0xd5e346a1_f753_4932_b403_4574800e2498);
const TRANSFER: GUID = GUID::from_u128(0x00adb003_bde9_45c6_8e29_d09f9353e108);
const SINK: GUID = GUID::from_u128(0xd594d0d8_8da7_457b_b3b4_ce5dbaac0b88);
const UNKNOWN: GUID = GUID::from_u128(0x00000000_0000_0000_c000_000000000046);
#[link(name = "shell32")]
unsafe extern "system" {
    fn SHCreateItemFromParsingName(
        path: *const u16,
        context: *mut c_void,
        iid: *const GUID,
        result: *mut *mut c_void,
    ) -> i32;
    fn SHGetKnownFolderItem(
        folder: *const GUID,
        flags: u32,
        token: HANDLE,
        iid: *const GUID,
        result: *mut *mut c_void,
    ) -> i32;
}
struct Com(*mut c_void);
impl Drop for Com {
    fn drop(&mut self) {
        unsafe {
            let release: unsafe extern "system" fn(*mut c_void) -> u32 =
                std::mem::transmute(slot(self.0, 2));
            release(self.0);
        }
    }
}
unsafe fn slot(object: *mut c_void, index: usize) -> *const c_void {
    unsafe { *(*(object.cast::<*const *const c_void>())).add(index) }
}
fn ok(code: i32, context: &str) -> Result<()> {
    if code != 0 {
        bail!(
            "{context} (HRESULT 0x{:08X}); the operation was not retried",
            code as u32
        );
    }
    Ok(())
}
fn com(code: i32, pointer: *mut c_void, context: &str) -> Result<Com> {
    if let Err(error) = ok(code, context) {
        if !pointer.is_null() {
            drop(Com(pointer));
        }
        return Err(error);
    }
    if pointer.is_null() {
        bail!("{context}: Shell returned no object");
    }
    Ok(Com(pointer))
}
fn physical(object: *mut c_void) -> Result<PathBuf> {
    unsafe {
        let call: unsafe extern "system" fn(*mut c_void, u32, *mut *mut u16) -> i32 =
            std::mem::transmute(slot(object, 5));
        let mut text = null_mut();
        ok(
            call(object, 0x80058000, &mut text),
            "Cannot resolve Shell physical path",
        )?;
        if text.is_null() {
            bail!("Shell returned no physical path");
        }
        let mut length = 0;
        while length < 32768 && *text.add(length) != 0 {
            length += 1;
        }
        let result = String::from_utf16(std::slice::from_raw_parts(text, length));
        CoTaskMemFree(text.cast());
        path::file_system_absolute(Path::new(&result?))
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImmediateDeleteSetting {
    sid: String,
    volume: String,
}
impl ImmediateDeleteSetting {
    pub fn sid(&self) -> &str {
        &self.sid
    }
    pub fn volume(&self) -> &str {
        &self.volume
    }
    pub fn capture(path: &Path) -> Option<Self> {
        Self::capture_checked(path).ok().flatten()
    }
    fn capture_checked(path: &Path) -> Result<Option<Self>> {
        unsafe {
            use windows_sys::Win32::System::Registry::*;
            let sid = security::current_user_sid()?;
            let parent = path
                .parent()
                .ok_or_else(|| anyhow::anyhow!("Missing parent"))?;
            let parent = super::win32_path(parent)?;
            let mut mount = vec![0u16; 32768];
            if GetVolumePathNameW(parent.as_ptr(), mount.as_mut_ptr(), mount.len() as u32) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let mut volume = vec![0u16; 128];
            if GetVolumeNameForVolumeMountPointW(
                mount.as_ptr(),
                volume.as_mut_ptr(),
                volume.len() as u32,
            ) == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            let n = volume.iter().position(|&x| x == 0).unwrap_or(volume.len());
            let volume = String::from_utf16(&volume[..n])?;
            if !volume.starts_with("\\\\?\\Volume{") || !volume.ends_with("}\\") {
                return Ok(None);
            }
            let guid = &volume[10..volume.len() - 1];
            uuid::Uuid::parse_str(guid)?;
            let policy = "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer";
            for view in [KEY_WOW64_64KEY, KEY_WOW64_32KEY] {
                for (root, name) in [
                    (HKEY_LOCAL_MACHINE, policy.to_owned()),
                    (HKEY_USERS, format!("{sid}\\{policy}")),
                ] {
                    if query(root, &name, "NoRecycleFiles", view)?.is_some() {
                        return Ok(None);
                    }
                }
            }
            let setting = format!(
                "{sid}\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\BitBucket\\Volume\\{guid}"
            );
            let Some((kind, data)) = query(HKEY_USERS, &setting, "NukeOnDelete", KEY_WOW64_64KEY)?
            else {
                return Ok(None);
            };
            if kind != REG_DWORD || data != 1u32.to_le_bytes() {
                return Ok(None);
            }
            Ok(Some(Self {
                sid,
                volume: volume.to_uppercase(),
            }))
        }
    }
    pub fn revalidate(&self, path: &Path) -> Result<()> {
        if Self::capture(path).as_ref() != Some(self) {
            bail!(
                "Immediate-delete setting, volume or effective user changed; permanent deletion stopped"
            );
        }
        Ok(())
    }
}
unsafe fn query(
    root: windows_sys::Win32::System::Registry::HKEY,
    key: &str,
    name: &str,
    view: u32,
) -> Result<Option<(u32, Vec<u8>)>> {
    unsafe {
        use windows_sys::Win32::System::Registry::*;
        let key = wide(std::ffi::OsStr::new(key))?;
        let name = wide(std::ffi::OsStr::new(name))?;
        let mut handle = null_mut();
        let status = RegOpenKeyExW(root, key.as_ptr(), 0, KEY_QUERY_VALUE | view, &mut handle);
        if status == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        struct Key(HKEY);
        impl Drop for Key {
            fn drop(&mut self) {
                unsafe {
                    RegCloseKey(self.0);
                }
            }
        }
        let key = Key(handle);
        let mut kind = 0;
        let mut length = 0;
        let status = RegQueryValueExW(
            key.0,
            name.as_ptr(),
            null(),
            &mut kind,
            null_mut(),
            &mut length,
        );
        if status == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        if length > 65536 {
            bail!("Unexpected registry setting size");
        }
        let mut data = vec![0; length as usize];
        let status = RegQueryValueExW(
            key.0,
            name.as_ptr(),
            null(),
            &mut kind,
            data.as_mut_ptr(),
            &mut length,
        );
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        data.truncate(length as usize);
        Ok(Some((kind, data)))
    }
}
#[derive(Debug)]
pub enum RecycleOutcome {
    Recycled,
    PermanentAllowed(Option<ImmediateDeleteSetting>),
}
#[derive(Default)]
struct State {
    failure: Option<i32>,
    uncertain: bool,
    had_failure: bool,
    /// 投入直前の`before`が受理したShell物理パスの別名（8.3短縮名など）。
    /// `before`側で非reparseかつ解決後の正規名との完全一致を確認済みの場合だけ設定される。
    /// FileFailure通知の照合では、この受理済み文字列との完全一致だけを追加で認める。
    accepted: Option<PathBuf>,
}
/// FileFailure通知の項目が、投入した固定元そのものかを判定する純関数。
///
/// - 物理パスは正規完全名`expected`か、`before`が受理した別名`accepted`との完全一致だけを認める。
///   IDや大小文字無視で照合を緩めない（Sink内でファイルを開いて解決し直すこともしない）。
/// - `name`が通知された場合は、通知された物理パスの葉名との完全一致を従来どおり要求する。
///   別名と長い名前のように表記が食い違う場合は不一致とし、保守的に結果不明へ倒す。
fn failure_item_matches(
    actual: &Path,
    name: Option<&str>,
    expected: &Path,
    accepted: Option<&Path>,
) -> bool {
    if actual != expected && accepted != Some(actual) {
        return false;
    }
    match name {
        Some(name) => actual.file_name().and_then(|x| x.to_str()) == Some(name),
        None => true,
    }
}
fn permits_permanent_failure(state: &State, code: i32, created: bool) -> bool {
    !created
        && !state.uncertain
        && state.failure.is_none_or(|failure| failure == code)
        && matches!(code, BIG | UNAVAILABLE)
}
#[repr(C)]
struct Sink {
    vtable: &'static SinkVtable,
    refs: AtomicU32,
    state: Arc<Mutex<State>>,
    expected: PathBuf,
    allow_progress: bool,
}
#[repr(C)]
struct SinkVtable {
    query: unsafe extern "system" fn(*mut Sink, *const GUID, *mut *mut c_void) -> i32,
    add: unsafe extern "system" fn(*mut Sink) -> u32,
    release: unsafe extern "system" fn(*mut Sink) -> u32,
    progress: unsafe extern "system" fn(*mut Sink, u64, u64, i32, i32, i32, i32) -> i32,
    state: unsafe extern "system" fn(*mut Sink, u32) -> i32,
    overwrite: unsafe extern "system" fn(*mut Sink, *mut c_void, *mut c_void, *const u16) -> i32,
    encryption: unsafe extern "system" fn(*mut Sink, *mut c_void) -> i32,
    file_failure:
        unsafe extern "system" fn(*mut Sink, *mut c_void, *const u16, i32, *mut c_void, u32) -> i32,
    stream_failure: unsafe extern "system" fn(*mut Sink, *mut c_void, *const u16, i32) -> i32,
    property_failure: unsafe extern "system" fn(*mut Sink, *mut c_void, *const c_void, i32) -> i32,
}
unsafe extern "system" fn sink_query(
    this: *mut Sink,
    iid: *const GUID,
    out: *mut *mut c_void,
) -> i32 {
    unsafe {
        if iid.is_null() || out.is_null() {
            return 0x80004003u32 as i32;
        }
        *out = null_mut();
        if *iid == SINK || *iid == UNKNOWN {
            *out = this.cast();
            sink_add(this);
            0
        } else {
            0x80004002u32 as i32
        }
    }
}
unsafe extern "system" fn sink_add(this: *mut Sink) -> u32 {
    unsafe { (*this).refs.fetch_add(1, Ordering::Relaxed) + 1 }
}
unsafe extern "system" fn sink_release(this: *mut Sink) -> u32 {
    unsafe {
        let count = (*this).refs.fetch_sub(1, Ordering::AcqRel) - 1;
        if count == 0 {
            drop(Box::from_raw(this));
        }
        count
    }
}
unsafe extern "system" fn sink_progress(
    this: *mut Sink,
    b: u64,
    _tb: u64,
    f: i32,
    _tf: i32,
    d: i32,
    _td: i32,
) -> i32 {
    unsafe {
        if !(*this).allow_progress && (b != 0 || f != 0 || d != 0) {
            if let Ok(mut state) = (*this).state.lock() {
                state.uncertain = true;
            }
        }
    }
    0
}
unsafe extern "system" fn sink_state(_this: *mut Sink, _state: u32) -> i32 {
    0
}
unsafe fn failure(this: *mut Sink, error: i32) {
    unsafe {
        if let Ok(mut state) = (*this).state.lock() {
            state.had_failure = true;
            state.uncertain = true;
            state.failure = Some(error);
        }
    }
}
unsafe extern "system" fn sink_overwrite(
    this: *mut Sink,
    _source: *mut c_void,
    _parent: *mut c_void,
    _name: *const u16,
) -> i32 {
    unsafe {
        failure(this, 0x80070050u32 as i32);
    }
    0x80070050u32 as i32
}
unsafe extern "system" fn sink_encryption(this: *mut Sink, _source: *mut c_void) -> i32 {
    unsafe {
        failure(this, ABORT);
    }
    ABORT
}
unsafe extern "system" fn sink_file(
    this: *mut Sink,
    item: *mut c_void,
    name: *const u16,
    error: i32,
    _rename: *mut c_void,
    _length: u32,
) -> i32 {
    unsafe {
        let matches = (|| -> Result<bool> {
            if item.is_null() {
                return Ok(false);
            }
            let actual = physical(item)?;
            let name = if name.is_null() {
                None
            } else {
                let mut n = 0;
                while *name.add(n) != 0 && n < 32768 {
                    n += 1;
                }
                Some(String::from_utf16(std::slice::from_raw_parts(name, n))?)
            };
            // 受理済み別名は投入前に記録されるため、ここではロックを短く取って複製する。
            let accepted = (*this)
                .state
                .lock()
                .map_err(|_| anyhow::anyhow!("Shell observation state is unavailable"))?
                .accepted
                .clone();
            Ok(failure_item_matches(
                &actual,
                name.as_deref(),
                &(*this).expected,
                accepted.as_deref(),
            ))
        })();
        if let Ok(mut state) = (*this).state.lock() {
            state.had_failure = true;
            if state.failure.is_some_and(|x| x != error)
                || !matches!(error, BIG | UNAVAILABLE)
                || !matches!(matches, Ok(true))
            {
                state.uncertain = true;
            }
            state.failure = Some(error);
        }
        if error < 0 { error } else { ABORT }
    }
}
unsafe extern "system" fn sink_stream(
    this: *mut Sink,
    _item: *mut c_void,
    _name: *const u16,
    error: i32,
) -> i32 {
    unsafe {
        failure(this, error);
    }
    if error < 0 { error } else { ABORT }
}
unsafe extern "system" fn sink_property(
    this: *mut Sink,
    _item: *mut c_void,
    _key: *const c_void,
    error: i32,
) -> i32 {
    unsafe {
        failure(this, error);
    }
    if error < 0 { error } else { ABORT }
}
static VTABLE: SinkVtable = SinkVtable {
    query: sink_query,
    add: sink_add,
    release: sink_release,
    progress: sink_progress,
    state: sink_state,
    overwrite: sink_overwrite,
    encryption: sink_encryption,
    file_failure: sink_file,
    stream_failure: sink_stream,
    property_failure: sink_property,
};

/// 呼出元の実効tokenを固定して専用STAへ渡す。Shell実行後の再送は行わない。
///
/// FileFailure通知は正規完全名との完全一致だけを固定元として扱う。
pub fn recycle<F, V>(
    source: &Path,
    allow_folder_progress: bool,
    before: F,
    verify: V,
) -> Result<RecycleOutcome>
where
    F: FnOnce(&Path) -> Result<()> + Send,
    V: FnOnce(&Path) -> Result<()> + Send,
{
    recycle_core(source, allow_folder_progress, false, before, verify)
}
/// [`recycle`]に加え、`before`が受理したShell物理パスの別名（長いパスの8.3表記など）を
/// FileFailure通知の照合にも使う。
///
/// 呼出元の`before`は、別名を受理する条件を「非reparseで、`path::resolve`後に正規名と
/// 完全一致した場合だけ」に限定していなければならない。大小文字無視などで受理する呼出元は
/// [`recycle`]を使い、永久削除へ切り替える条件を広げない。
pub fn recycle_accepting_resolved_alias<F, V>(
    source: &Path,
    allow_folder_progress: bool,
    before: F,
    verify: V,
) -> Result<RecycleOutcome>
where
    F: FnOnce(&Path) -> Result<()> + Send,
    V: FnOnce(&Path) -> Result<()> + Send,
{
    recycle_core(source, allow_folder_progress, true, before, verify)
}
fn recycle_core<F, V>(
    source: &Path,
    allow_folder_progress: bool,
    accept_alias: bool,
    before: F,
    verify: V,
) -> Result<RecycleOutcome>
where
    F: FnOnce(&Path) -> Result<()> + Send,
    V: FnOnce(&Path) -> Result<()> + Send,
{
    let source = path::absolute(source)?;
    let token = unsafe {
        let mut raw = null_mut();
        if OpenThreadToken(
            GetCurrentThread(),
            TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_IMPERSONATE,
            1,
            &mut raw,
        ) == 0
        {
            let error = GetLastError();
            if error != ERROR_NO_TOKEN {
                return Err(std::io::Error::from_raw_os_error(error as i32).into());
            }
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &mut raw) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        let original = OwnedHandle::from_raw(raw)?;
        let mut copy = null_mut();
        if DuplicateTokenEx(
            original.raw(),
            TOKEN_QUERY | TOKEN_IMPERSONATE,
            null(),
            SecurityImpersonation,
            TokenImpersonation,
            &mut copy,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        OwnedHandle::from_raw(copy)?
    };
    std::thread::scope(|scope| {
        super::process::spawn_scoped(scope,"file-shell-sta",move||unsafe{
  if SetThreadToken(null(),token.raw())==0{return Err(std::io::Error::last_os_error().into());}
  struct Impersonation;impl Drop for Impersonation{fn drop(&mut self){unsafe{RevertToSelf();}}}let _impersonation=Impersonation;
  ok(CoInitializeEx(null(),2),"Cannot initialize Shell STA")?;struct Apartment;impl Drop for Apartment{fn drop(&mut self){unsafe{CoUninitialize();}}}let _apartment=Apartment;
  let name=wide(source.as_os_str())?;let mut raw=null_mut();let code=SHCreateItemFromParsingName(name.as_ptr(),null_mut(),&SHELL,&mut raw);let item=com(code,raw,"Cannot resolve Shell source")?;
  let parent_call:unsafe extern "system" fn(*mut c_void,*mut *mut c_void)->i32=std::mem::transmute(slot(item.0,4));raw=null_mut();let code=parent_call(item.0,&mut raw);let parent=com(code,raw,"Cannot resolve Shell parent")?;
  raw=null_mut();let code=SHGetKnownFolderItem(&BIN,0,null_mut(),&SHELL,&mut raw);let bin=com(code,raw,"Cannot open effective user's Recycle Bin")?;
  let bind:unsafe extern "system" fn(*mut c_void,*mut c_void,*const GUID,*const GUID,*mut *mut c_void)->i32=std::mem::transmute(slot(parent.0,3));raw=null_mut();let code=bind(parent.0,null_mut(),&HANDLER,&TRANSFER,&mut raw);let transfer=com(code,raw,"Cannot bind Shell transfer")?;
  let state=Arc::new(Mutex::new(State::default()));let sink=Box::into_raw(Box::new(Sink{vtable:&VTABLE,refs:AtomicU32::new(1),state:state.clone(),expected:source.clone(),allow_progress:allow_folder_progress}));struct SinkRef(*mut Sink);impl Drop for SinkRef{fn drop(&mut self){unsafe{sink_release(self.0);}}}let _sink=SinkRef(sink);
  let advise:unsafe extern "system" fn(*mut c_void,*mut Sink,*mut u32)->i32=std::mem::transmute(slot(transfer.0,3));let mut cookie=0;ok(advise(transfer.0,sink,&mut cookie),"Cannot observe Shell transfer")?;
  struct Subscription{transfer:*mut c_void,cookie:u32}impl Drop for Subscription{fn drop(&mut self){unsafe{let call:unsafe extern "system" fn(*mut c_void,u32)->i32=std::mem::transmute(slot(self.transfer,4));call(self.transfer,self.cookie);}}}let _subscription=Subscription{transfer:transfer.0,cookie};
  // beforeが受理した物理パスだけを、FileFailure照合用の別名としてRecycleItem前に記録する。
  let shell_physical=physical(item.0)?;before(&shell_physical)?;
  if accept_alias&&shell_physical!=source{state.lock().map_err(|_|anyhow::anyhow!("Shell observation state is unavailable"))?.accepted=Some(shell_physical);}
  let immediate=ImmediateDeleteSetting::capture(&source);
  let call:unsafe extern "system" fn(*mut c_void,*mut c_void,*mut c_void,u32,*mut *mut c_void)->i32=std::mem::transmute(slot(transfer.0,8));let mut created=null_mut();let code=call(transfer.0,item.0,bin.0,0,&mut created);
  #[cfg(test)]
  eprintln!("Native Shell RecycleItem: HRESULT=0x{:08X}, created={}, immediateSetting={:?}",code as u32,!created.is_null(),immediate);
  let created=if created.is_null(){None}else{Some(Com(created))};
  let state=state.lock().map_err(|_|anyhow::anyhow!("Shell observation state is unavailable"))?;
  if permits_permanent_failure(&state,code,created.is_some()){if code==BIG{return Ok(RecycleOutcome::PermanentAllowed(None));}if code==UNAVAILABLE{if let Some(setting)=immediate{setting.revalidate(&source)?;return Ok(RecycleOutcome::PermanentAllowed(Some(setting)));}}}
  if code!=0&&code!=0x00270008{ok(code,"Windows did not confirm recycling")?;}if state.had_failure{bail!("Windows reported failure during recycling; completion is unknown");}
  let created=created.ok_or_else(||anyhow::anyhow!("Windows returned no recycled item; completion is unknown"))?;verify(&physical(created.0)?)?;Ok(RecycleOutcome::Recycled)
 })?.join().map_err(|_|anyhow::anyhow!("Shell STA terminated unexpectedly; inspect source and Recycle Bin before further action"))?
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    /// 自前GUIDがWin32のGUIDと同じレイアウト・値になることを確認する。
    /// ずれるとShell COMへ誤ったIID/CLSIDを渡し、Recycleが失敗する。
    #[test]
    fn local_guid_matches_win32_layout_and_values() {
        assert_eq!(size_of::<GUID>(), size_of::<windows_sys::core::GUID>());
        assert_eq!(align_of::<GUID>(), align_of::<windows_sys::core::GUID>());
        for value in [
            0x43826d1e_e718_42ee_bc55_a1e261c37bfe_u128,
            0xb7534046_3ecb_4c18_be4e_64cd4cb7d6ac,
            0xd5e346a1_f753_4932_b403_4574800e2498,
            0x00adb003_bde9_45c6_8e29_d09f9353e108,
            0xd594d0d8_8da7_457b_b3b4_ce5dbaac0b88,
            0x00000000_0000_0000_c000_000000000046,
        ] {
            let local = GUID::from_u128(value);
            let win32 = windows_sys::core::GUID::from_u128(value);
            assert_eq!(
                (local.data1, local.data2, local.data3, local.data4),
                (win32.data1, win32.data2, win32.data3, win32.data4)
            );
        }
        // IUnknownの既知表現で並びを固定する。
        assert_eq!(UNKNOWN.data4, [0xc0, 0, 0, 0, 0, 0, 0, 0x46]);
        assert!(SINK != UNKNOWN);
    }
    #[test]
    fn file_progress_prevents_permanent_fallback() {
        let state = Arc::new(Mutex::new(State::default()));
        let mut sink = Sink {
            vtable: &VTABLE,
            refs: AtomicU32::new(1),
            state: state.clone(),
            expected: PathBuf::from("D:\\fixture.dat"),
            allow_progress: false,
        };
        assert!(permits_permanent_failure(
            &state.lock().unwrap(),
            BIG,
            false
        ));
        unsafe {
            sink_progress(&mut sink, 1, 1, 1, 1, 0, 0);
        }
        assert!(!permits_permanent_failure(
            &state.lock().unwrap(),
            BIG,
            false
        ));
        assert!(!permits_permanent_failure(
            &state.lock().unwrap(),
            UNAVAILABLE,
            false
        ));
    }
    #[test]
    fn failure_item_accepts_only_fixed_name_or_accepted_alias() {
        let expected = Path::new(r"D:\long\very-long-directory-name\oversized.dat");
        let alias = Path::new(r"D:\long\VERY-L~1\oversized.dat");
        // 正規完全名は従来どおり一致する。
        assert!(failure_item_matches(expected, None, expected, None));
        assert!(failure_item_matches(
            expected,
            Some("oversized.dat"),
            expected,
            None
        ));
        // beforeが受理した8.3別名だけを追加で認める。
        assert!(failure_item_matches(alias, None, expected, Some(alias)));
        assert!(failure_item_matches(
            alias,
            Some("oversized.dat"),
            expected,
            Some(alias)
        ));
        // 未受理の別名、大小文字だけ違う表記、別の受理済み別名は一致しない。
        assert!(!failure_item_matches(alias, None, expected, None));
        let upper = Path::new(r"D:\LONG\VERY-LONG-DIRECTORY-NAME\OVERSIZED.DAT");
        assert!(!failure_item_matches(upper, None, expected, None));
        let other = Path::new(r"D:\long\OTHER~1\oversized.dat");
        assert!(!failure_item_matches(other, None, expected, Some(alias)));
        // name引数は通知された物理パスの葉名と完全一致を要求し続ける。
        assert!(!failure_item_matches(
            expected,
            Some("OVERSIZED.DAT"),
            expected,
            None
        ));
        let short_leaf = Path::new(r"D:\long\VERY-L~1\OVERSI~1.DAT");
        assert!(!failure_item_matches(
            short_leaf,
            Some("oversized.dat"),
            expected,
            Some(short_leaf)
        ));
    }
    #[test]
    fn created_object_or_conflicting_failure_prevents_fallback() {
        let mut state = State::default();
        assert!(!permits_permanent_failure(&state, BIG, true));
        state.failure = Some(ABORT);
        assert!(!permits_permanent_failure(&state, BIG, false));
        state.failure = Some(BIG);
        assert!(permits_permanent_failure(&state, BIG, false));
        assert!(!permits_permanent_failure(&state, UNAVAILABLE, false));
    }
}
