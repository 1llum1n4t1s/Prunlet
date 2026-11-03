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
use windows::core::GUID;
use windows_sys::Win32::{
    Foundation::*,
    Security::*,
    Storage::FileSystem::*,
    System::{Com::*, Threading::*},
};

const BIG: i32 = 0x80270037u32 as i32;
const UNAVAILABLE: i32 = 0x80270036u32 as i32;
const ABORT: i32 = 0x80004004u32 as i32;
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
            if actual != (*this).expected {
                return Ok(false);
            }
            if !name.is_null() {
                let mut n = 0;
                while *name.add(n) != 0 && n < 32768 {
                    n += 1;
                }
                let name = String::from_utf16(std::slice::from_raw_parts(name, n))?;
                if actual.file_name().and_then(|x| x.to_str()) != Some(&name) {
                    return Ok(false);
                }
            }
            Ok(true)
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
  before(&physical(item.0)?)?;let immediate=ImmediateDeleteSetting::capture(&source);
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
