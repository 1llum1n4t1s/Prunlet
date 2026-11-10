//! 検証fixture専用のShell識別・非置換移動。製品Coreには依存しない。
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    ffi::{OsStr, c_void},
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::atomic::{AtomicU32, Ordering},
};
use windows_sys::Win32::{
    Foundation::*,
    Security::*,
    Storage::FileSystem::*,
    System::{Com::*, Threading::*},
};

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq)]
struct Guid {
    a: u32,
    b: u16,
    c: u16,
    d: [u8; 8],
}
const fn guid(n: u128) -> Guid {
    Guid {
        a: (n >> 96) as u32,
        b: (n >> 80) as u16,
        c: (n >> 64) as u16,
        d: (n as u64).to_be_bytes(),
    }
}
const BIN: Guid = guid(0xb7534046_3ecb_4c18_be4e_64cd4cb7d6ac);
const ITEM: Guid = guid(0x43826d1e_e718_42ee_bc55_a1e261c37bfe);
const ENUM_HANDLER: Guid = guid(0x94f60519_2850_4924_aa5a_d15e84868039);
const ENUM_ID: Guid = guid(0x70629033_e363_4a28_a567_0db78006e6d7);
const TRANSFER_HANDLER: Guid = guid(0xd5e346a1_f753_4932_b403_4574800e2498);
const TRANSFER_ID: Guid = guid(0x00adb003_bde9_45c6_8e29_d09f9353e108);
const SINK_ID: Guid = guid(0xd594d0d8_8da7_457b_b3b4_ce5dbaac0b88);
const UNKNOWN: Guid = guid(0x00000000_0000_0000_c000_000000000046);
const ABORT: i32 = 0x80004004u32 as i32;
const LIMIT: usize = 1024 * 1024;
#[link(name = "shell32")]
unsafe extern "system" {
    fn SHGetKnownFolderItem(
        folder: *const Guid,
        flags: u32,
        token: HANDLE,
        iid: *const Guid,
        result: *mut *mut c_void,
    ) -> i32;
    fn SHCreateItemFromParsingName(
        path: *const u16,
        ctx: *mut c_void,
        iid: *const Guid,
        result: *mut *mut c_void,
    ) -> i32;
    fn SHGetIDListFromObject(obj: *mut c_void, pidl: *mut *mut c_void) -> i32;
    fn ILIsParent(parent: *const c_void, child: *const c_void, immediate: i32) -> i32;
    fn ILIsEqual(first: *const c_void, second: *const c_void) -> i32;
    fn ILSaveToStream(stream: *mut c_void, pidl: *const c_void) -> i32;
    fn ILLoadFromStreamEx(stream: *mut c_void, pidl: *mut *mut c_void) -> i32;
}
#[link(name = "ole32")]
unsafe extern "system" {
    fn CreateStreamOnHGlobal(global: *mut c_void, delete: i32, stream: *mut *mut c_void) -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CompareStringOrdinal(
        a: *const u16,
        alen: i32,
        b: *const u16,
        blen: i32,
        ignore_case: i32,
    ) -> i32;
}
struct Com(*mut c_void);
impl Drop for Com {
    fn drop(&mut self) {
        unsafe {
            let f: unsafe extern "system" fn(*mut c_void) -> u32 =
                std::mem::transmute(slot(self.0, 2));
            f(self.0);
        }
    }
}
unsafe fn slot(o: *mut c_void, i: usize) -> *const c_void {
    unsafe { *(*(o as *const *const *const c_void)).add(i) }
}
fn ok(v: i32, what: &str) -> Result<()> {
    ensure!(v == 0, "{what} (HRESULT 0x{:08X})", v as u32);
    Ok(())
}
fn com(v: i32, p: *mut c_void, what: &str) -> Result<Com> {
    if v != 0 {
        if !p.is_null() {
            drop(Com(p));
        }
        ok(v, what)?;
    }
    ensure!(!p.is_null(), "{what}: missing object");
    Ok(Com(p))
}
struct Pidl(*mut c_void);
impl Drop for Pidl {
    fn drop(&mut self) {
        unsafe { CoTaskMemFree(self.0) }
    }
}
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn wide(s: &OsStr) -> Result<Vec<u16>> {
    let mut v: Vec<_> = s.encode_wide().collect();
    ensure!(!v.contains(&0), "NUL in path");
    v.push(0);
    Ok(v)
}
fn absolute(s: &str) -> Result<PathBuf> {
    let p = PathBuf::from(s);
    ensure!(p.is_absolute(), "Absolute fixture path required");
    let plain = s.strip_prefix(r"\\?\").unwrap_or(s);
    ensure!(
        !plain.chars().any(|c| matches!(c, '\0' | '*' | '?'))
            && !plain.split(['\\', '/']).any(|x| x == "." || x == ".."),
        "Invalid fixture path"
    );
    Ok(p)
}
fn field<'a>(v: &'a Value, n: &str) -> Result<&'a str> {
    v.get(n)
        .and_then(Value::as_str)
        .with_context(|| format!("Missing {n}"))
}
fn open(p: &Path, access: u32, share: u32) -> Result<Handle> {
    let s = wide(p.as_os_str())?;
    let h = unsafe {
        CreateFileW(
            s.as_ptr(),
            access,
            share,
            null(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
            null_mut(),
        )
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(Handle(h))
}
fn id(h: HANDLE) -> Result<String> {
    let mut b = [0u8; 24];
    if unsafe { GetFileInformationByHandleEx(h, FileIdInfo, b.as_mut_ptr().cast(), 24) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(hex::encode_upper(b))
}
fn identity(p: &Path) -> Result<String> {
    id(open(p, FILE_READ_ATTRIBUTES, 7)?.0)
}
fn validate_id(s: &str) -> Result<()> {
    ensure!(
        s.len() == 48 && s.bytes().all(|b| b.is_ascii_hexdigit()),
        "Exact native ID required"
    );
    Ok(())
}
fn owned(path: &Path, scope: &Path) -> Result<()> {
    // Windowsのordinal比較は文字数が増える大文字変換を行わない。
    let p: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .map(|c| if c == b'/' as u16 { b'\\' as u16 } else { c })
        .collect();
    let mut s: Vec<u16> = scope
        .as_os_str()
        .encode_wide()
        .map(|c| if c == b'/' as u16 { b'\\' as u16 } else { c })
        .collect();
    while s.last() == Some(&(b'\\' as u16)) {
        s.pop();
    }
    ensure!(
        !s.is_empty()
            && s.len() <= i32::MAX as usize
            && p.len() > s.len()
            && p[s.len()] == b'\\' as u16
            && unsafe {
                CompareStringOrdinal(p.as_ptr(), s.len() as i32, s.as_ptr(), s.len() as i32, 1)
            } == 2,
        "Fixture path escaped its owned scope"
    );
    Ok(())
}
fn pin_parents(p: &Path) -> Result<Vec<Handle>> {
    let mut parts: Vec<_> = p.ancestors().collect();
    parts.reverse();
    let mut result = Vec::new();
    for p in parts {
        let h = open(p, 0x20080, FILE_SHARE_READ | FILE_SHARE_WRITE)?;
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        if unsafe { GetFileInformationByHandle(h.0, &mut info) } == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        ensure!(
            info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0
                && info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT == 0,
            "Fixture ancestor is not an ordinary directory"
        );
        result.push(h);
    }
    Ok(result)
}
fn require_missing(p: &Path) -> Result<()> {
    match open(p, FILE_READ_ATTRIBUTES, 7) {
        Ok(_) => bail!("Fixture destination exists"),
        Err(e) => {
            let code = e
                .downcast_ref::<std::io::Error>()
                .and_then(|e| e.raw_os_error());
            ensure!(
                matches!(code, Some(2 | 3)),
                "Cannot confirm fixture name absent: {e:#}"
            );
            Ok(())
        }
    }
}
fn in_sta<F, T>(f: F) -> Result<T>
where
    F: FnOnce() -> Result<T> + Send,
    T: Send,
{
    unsafe {
        let mut raw = null_mut();
        if OpenThreadToken(
            GetCurrentThread(),
            TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_IMPERSONATE,
            1,
            &mut raw,
        ) == 0
        {
            let err = GetLastError();
            if err != ERROR_NO_TOKEN {
                return Err(std::io::Error::from_raw_os_error(err as i32).into());
            }
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &mut raw) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        let original = Handle(raw);
        let mut copy = null_mut();
        if DuplicateTokenEx(
            original.0,
            TOKEN_QUERY | TOKEN_IMPERSONATE,
            null(),
            SecurityImpersonation,
            TokenImpersonation,
            &mut copy,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let copy = copy as usize;
        std::thread::scope(|scope| {
            scope
                .spawn(move || {
                    let token = Handle(copy as HANDLE);
                    if SetThreadToken(null(), token.0) == 0 {
                        return Err(std::io::Error::last_os_error().into());
                    }
                    struct Imp;
                    impl Drop for Imp {
                        fn drop(&mut self) {
                            unsafe {
                                RevertToSelf();
                            }
                        }
                    }
                    let _imp = Imp;
                    let code = CoInitializeEx(null(), 2);
                    if code < 0 {
                        ok(code, "Cannot initialize Shell STA")?;
                    }
                    struct Apartment;
                    impl Drop for Apartment {
                        fn drop(&mut self) {
                            unsafe { CoUninitialize() }
                        }
                    }
                    let _apt = Apartment;
                    f()
                })
                .join()
                .map_err(|_| {
                    anyhow::anyhow!("Shell STA panicked; inspect state before continuing")
                })?
        })
    }
}
unsafe fn bind(o: *mut c_void, handler: &Guid, iid: &Guid) -> Result<Com> {
    unsafe {
        let call: unsafe extern "system" fn(
            *mut c_void,
            *mut c_void,
            *const Guid,
            *const Guid,
            *mut *mut c_void,
        ) -> i32 = std::mem::transmute(slot(o, 3));
        let mut p = null_mut();
        let r = call(o, null_mut(), handler, iid, &mut p);
        com(r, p, "Cannot bind Shell handler")
    }
}
fn bin() -> Result<Com> {
    unsafe {
        let mut p = null_mut();
        let r = SHGetKnownFolderItem(&BIN, 0, null_mut(), &ITEM, &mut p);
        com(r, p, "Cannot open current user's Recycle Bin")
    }
}
fn shell_item(p: &Path) -> Result<Com> {
    unsafe {
        let name = wide(p.as_os_str())?;
        let mut o = null_mut();
        let r = SHCreateItemFromParsingName(name.as_ptr(), null_mut(), &ITEM, &mut o);
        com(r, o, "Cannot resolve Shell item")
    }
}
fn pidl(o: *mut c_void) -> Result<Pidl> {
    unsafe {
        let mut p = null_mut();
        ok(
            SHGetIDListFromObject(o, &mut p),
            "Cannot identify Shell item",
        )?;
        ensure!(!p.is_null(), "Missing Shell PIDL");
        Ok(Pidl(p))
    }
}
fn physical(o: *mut c_void) -> Result<PathBuf> {
    unsafe {
        let call: unsafe extern "system" fn(*mut c_void, u32, *mut *mut u16) -> i32 =
            std::mem::transmute(slot(o, 5));
        let mut p = null_mut();
        ok(
            call(o, 0x80058000, &mut p),
            "Cannot resolve Shell physical path",
        )?;
        ensure!(!p.is_null(), "Missing Shell physical path");
        let mut n = 0;
        while n < 32768 && *p.add(n) != 0 {
            n += 1;
        }
        let text = String::from_utf16(std::slice::from_raw_parts(p, n));
        CoTaskMemFree(p.cast());
        ensure!(n < 32768, "Unterminated Shell path");
        absolute(&text?)
    }
}
fn stream() -> Result<Com> {
    unsafe {
        let mut p = null_mut();
        let r = CreateStreamOnHGlobal(null_mut(), 1, &mut p);
        com(r, p, "Cannot create PIDL stream")
    }
}
unsafe fn seek(s: *mut c_void, offset: i64, origin: u32) -> Result<u64> {
    unsafe {
        let f: unsafe extern "system" fn(*mut c_void, i64, u32, *mut u64) -> i32 =
            std::mem::transmute(slot(s, 5));
        let mut pos = 0;
        ok(f(s, offset, origin, &mut pos), "Cannot seek PIDL stream")?;
        Ok(pos)
    }
}
fn save_pidl(p: *mut c_void) -> Result<String> {
    unsafe {
        let s = stream()?;
        ok(ILSaveToStream(s.0, p), "Cannot save PIDL")?;
        let n = seek(s.0, 0, 2)? as usize;
        ensure!(n > 0 && n <= LIMIT, "Invalid PIDL length");
        seek(s.0, 0, 0)?;
        let f: unsafe extern "system" fn(*mut c_void, *mut c_void, u32, *mut u32) -> i32 =
            std::mem::transmute(slot(s.0, 3));
        let mut b = vec![0u8; n];
        let mut read = 0;
        ok(
            f(s.0, b.as_mut_ptr().cast(), n as u32, &mut read),
            "Cannot read PIDL",
        )?;
        ensure!(read as usize == n, "Truncated PIDL");
        Ok(STANDARD.encode(b))
    }
}
fn load_pidl(text: &str) -> Result<Pidl> {
    unsafe {
        ensure!(
            !text.is_empty() && text.len() <= ((LIMIT + 2) / 3) * 4,
            "Invalid PIDL length"
        );
        let b = STANDARD.decode(text)?;
        ensure!(!b.is_empty() && b.len() <= LIMIT, "Invalid PIDL length");
        let s = stream()?;
        let f: unsafe extern "system" fn(*mut c_void, *const c_void, u32, *mut u32) -> i32 =
            std::mem::transmute(slot(s.0, 4));
        let mut written = 0;
        ok(
            f(s.0, b.as_ptr().cast(), b.len() as u32, &mut written),
            "Cannot write PIDL",
        )?;
        ensure!(written as usize == b.len(), "Short PIDL write");
        seek(s.0, 0, 0)?;
        let mut p = null_mut();
        ok(ILLoadFromStreamEx(s.0, &mut p), "Cannot deserialize PIDL")?;
        ensure!(!p.is_null(), "Missing PIDL");
        Ok(Pidl(p))
    }
}
// 保存済みPIDLを直接bindせず、現在のBinにある直下の項目だけと照合する。
fn enumerate<F>(bin: &Com, mut visit: F) -> Result<()>
where
    F: FnMut(&Com, &Pidl) -> Result<bool>,
{
    unsafe {
        let root = pidl(bin.0)?;
        let en = bind(bin.0, &ENUM_HANDLER, &ENUM_ID)?;
        let next: unsafe extern "system" fn(*mut c_void, u32, *mut *mut c_void, *mut u32) -> i32 =
            std::mem::transmute(slot(en.0, 3));
        loop {
            let mut p = null_mut();
            let mut n = 0;
            let r = next(en.0, 1, &mut p, &mut n);
            if r == 1 && n == 0 {
                if !p.is_null() {
                    drop(Com(p));
                }
                break;
            }
            let item = com(r, p, "Cannot enumerate Recycle Bin")?;
            ensure!(n == 1, "Unexpected Shell enumeration count");
            let child = pidl(item.0)?;
            ensure!(
                ILIsParent(root.0, child.0, 1) != 0,
                "Shell returned item outside Recycle Bin"
            );
            if visit(&item, &child)? {
                break;
            }
        }
        Ok(())
    }
}
fn find(bin: &Com, saved: &str) -> Result<Option<Com>> {
    unsafe {
        let saved = load_pidl(saved)?;
        let root = pidl(bin.0)?;
        ensure!(
            ILIsParent(root.0, saved.0, 1) != 0,
            "Stored PIDL is not a direct Bin child"
        );
        let mut found = None;
        enumerate(bin, |item, child| {
            if ILIsEqual(saved.0, child.0) != 0 {
                let add: unsafe extern "system" fn(*mut c_void) -> u32 =
                    std::mem::transmute(slot(item.0, 1));
                add(item.0);
                found = Some(Com(item.0));
                return Ok(true);
            }
            Ok(false)
        })?;
        Ok(found)
    }
}
fn find_identity(expected: &str) -> Result<Vec<Value>> {
    validate_id(expected)?;
    let b = bin()?;
    let mut found = Vec::new();
    enumerate(&b, |item, p| {
        let path = match physical(item.0) {
            Ok(x) => x,
            Err(_) => return Ok(false),
        };
        let actual = match identity(&path) {
            Ok(x) => x,
            Err(_) => return Ok(false),
        };
        if actual == expected {
            found.push(json!({"Pidl":save_pidl(p.0)?,"PhysicalPath":path,"NativeId":actual}));
        }
        Ok(false)
    })?;
    Ok(found)
}
// ITransferSourceが要求する確認をRustのCOM sinkで処理し、置換・mergeを拒否する。
#[repr(C)]
struct Sink {
    vt: &'static SinkVtable,
    refs: AtomicU32,
}
#[repr(C)]
struct SinkVtable {
    query: unsafe extern "system" fn(*mut Sink, *const Guid, *mut *mut c_void) -> i32,
    add: unsafe extern "system" fn(*mut Sink) -> u32,
    release: unsafe extern "system" fn(*mut Sink) -> u32,
    progress: unsafe extern "system" fn(*mut Sink, u64, u64, i32, i32, i32, i32) -> i32,
    state: unsafe extern "system" fn(*mut Sink, u32) -> i32,
    overwrite: unsafe extern "system" fn(*mut Sink, *mut c_void, *mut c_void, *const u16) -> i32,
    encryption: unsafe extern "system" fn(*mut Sink, *mut c_void) -> i32,
    file:
        unsafe extern "system" fn(*mut Sink, *mut c_void, *const u16, i32, *mut c_void, u32) -> i32,
    stream: unsafe extern "system" fn(*mut Sink, *mut c_void, *const u16, i32) -> i32,
    property: unsafe extern "system" fn(*mut Sink, *mut c_void, *const c_void, i32) -> i32,
}
unsafe extern "system" fn query(s: *mut Sink, i: *const Guid, out: *mut *mut c_void) -> i32 {
    unsafe {
        if i.is_null() || out.is_null() {
            return 0x80004003u32 as i32;
        }
        *out = null_mut();
        if *i == SINK_ID || *i == UNKNOWN {
            *out = s.cast();
            add(s);
            0
        } else {
            0x80004002u32 as i32
        }
    }
}
unsafe extern "system" fn add(s: *mut Sink) -> u32 {
    unsafe { (*s).refs.fetch_add(1, Ordering::Relaxed) + 1 }
}
unsafe extern "system" fn release(s: *mut Sink) -> u32 {
    unsafe {
        let n = (*s).refs.fetch_sub(1, Ordering::AcqRel) - 1;
        if n == 0 {
            drop(Box::from_raw(s));
        }
        n
    }
}
unsafe extern "system" fn progress(
    _: *mut Sink,
    _: u64,
    _: u64,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
) -> i32 {
    0
}
unsafe extern "system" fn state(_: *mut Sink, _: u32) -> i32 {
    0
}
unsafe extern "system" fn overwrite(
    _: *mut Sink,
    _: *mut c_void,
    _: *mut c_void,
    _: *const u16,
) -> i32 {
    0x80070050u32 as i32
}
unsafe extern "system" fn encryption(_: *mut Sink, _: *mut c_void) -> i32 {
    ABORT
}
unsafe extern "system" fn failure(
    _: *mut Sink,
    _: *mut c_void,
    _: *const u16,
    e: i32,
    _: *mut c_void,
    _: u32,
) -> i32 {
    if e < 0 { e } else { ABORT }
}
unsafe extern "system" fn stream_failure(
    _: *mut Sink,
    _: *mut c_void,
    _: *const u16,
    e: i32,
) -> i32 {
    if e < 0 { e } else { ABORT }
}
unsafe extern "system" fn property_failure(
    _: *mut Sink,
    _: *mut c_void,
    _: *const c_void,
    e: i32,
) -> i32 {
    if e < 0 { e } else { ABORT }
}
static VTABLE: SinkVtable = SinkVtable {
    query,
    add,
    release,
    progress,
    state,
    overwrite,
    encryption,
    file: failure,
    stream: stream_failure,
    property: property_failure,
};
struct SinkRef(*mut Sink);
impl Drop for SinkRef {
    fn drop(&mut self) {
        unsafe {
            release(self.0);
        }
    }
}
struct Subscription {
    transfer: *mut c_void,
    cookie: u32,
}
impl Drop for Subscription {
    fn drop(&mut self) {
        unsafe {
            let f: unsafe extern "system" fn(*mut c_void, u32) -> i32 =
                std::mem::transmute(slot(self.transfer, 4));
            f(self.transfer, self.cookie);
        }
    }
}
fn restore_owned(args: &Value) -> Result<Value> {
    unsafe {
        let original = absolute(field(args, "originalPath")?)?;
        let scope = absolute(field(args, "scope")?)?;
        let physical_expected = absolute(field(args, "physicalPath")?)?;
        let expected = field(args, "expectedId")?;
        validate_id(expected)?;
        let saved = field(args, "pidl")?;
        owned(&original, &scope)?;
        let parent = original.parent().context("Missing restore parent")?;
        let leaf = original.file_name().context("Missing restore leaf")?;
        let _pins = pin_parents(parent)?;
        require_missing(&original)?;
        let b = bin()?;
        let source = find(&b, saved)?.context("Created fixture PIDL is not currently in Bin")?;
        let path = physical(source.0)?;
        ensure!(
            path == physical_expected && identity(&path)? == expected,
            "Created fixture Bin identity differs from receipt"
        );
        let dest = shell_item(parent)?;
        let transfer = bind(b.0, &TRANSFER_HANDLER, &TRANSFER_ID)?;
        let sink = SinkRef(Box::into_raw(Box::new(Sink {
            vt: &VTABLE,
            refs: AtomicU32::new(1),
        })));
        let advise: unsafe extern "system" fn(*mut c_void, *mut Sink, *mut u32) -> i32 =
            std::mem::transmute(slot(transfer.0, 3));
        let mut cookie = 0;
        ok(
            advise(transfer.0, sink.0, &mut cookie),
            "Cannot observe restoration",
        )?;
        let _sub = Subscription {
            transfer: transfer.0,
            cookie,
        };
        ensure!(
            physical(source.0)? == physical_expected && identity(&physical_expected)? == expected,
            "External restore source changed"
        );
        require_missing(&original)?;
        let name = wide(leaf)?;
        let mut moved = null_mut();
        let f: unsafe extern "system" fn(
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *const u16,
            u32,
            *mut *mut c_void,
        ) -> i32 = std::mem::transmute(slot(transfer.0, 7));
        let r = f(transfer.0, source.0, dest.0, name.as_ptr(), 0, &mut moved);
        if r != 0 && r != 0x00270008 {
            if !moved.is_null() {
                drop(Com(moved));
            }
            bail!(
                "Shell restoration did not complete without replacing destination (HRESULT 0x{:08X})",
                r as u32
            )
        }
        ensure!(!moved.is_null(), "Shell returned no restored item");
        let moved = Com(moved);
        ensure!(
            physical(moved.0)? == original,
            "Shell returned unexpected restore destination"
        );
        ensure!(
            identity(&original)? == expected,
            "Restored fixture identity changed"
        );
        ensure!(
            find(&b, saved)?.is_none(),
            "Tracked Bin item still present after restore"
        );
        require_missing(&physical_expected)?;
        Ok(json!(original))
    }
}
fn move_owned(args: &Value) -> Result<Value> {
    let source = absolute(field(args, "source")?)?;
    let destination = absolute(field(args, "destination")?)?;
    let scope = absolute(field(args, "scope")?)?;
    let expected = field(args, "expectedId")?;
    validate_id(expected)?;
    owned(&source, &scope)?;
    owned(&destination, &scope)?;
    let src_parent = source.parent().context("Missing source parent")?;
    let dst_parent = destination.parent().context("Missing destination parent")?;
    let _src = pin_parents(src_parent)?;
    let _dst = pin_parents(dst_parent)?;
    require_missing(&destination)?;
    // 元の検証helperと同様に、ツリー全体を観測できることを移動前に確かめる。
    let snapshot = super::dispatch("file.snapshot", &json!({"path": source}))?;
    ensure!(
        snapshot[0]["Id"].as_str() == Some(expected),
        "Fixture snapshot identity changed"
    );
    // DELETE共有を許さないhandleを固定し、その同じhandleをrenameする。
    let fixed = open(&source, 0x10080, FILE_SHARE_READ | FILE_SHARE_WRITE)?;
    ensure!(
        id(fixed.0)? == expected && identity(&source)? == expected,
        "Fixture source identity changed"
    );
    let dst = open(dst_parent, 0x80, 7)?;
    let mut source_id = [0u8; 24];
    let mut dest_id = [0u8; 24];
    unsafe {
        if GetFileInformationByHandleEx(fixed.0, FileIdInfo, source_id.as_mut_ptr().cast(), 24) == 0
            || GetFileInformationByHandleEx(dst.0, FileIdInfo, dest_id.as_mut_ptr().cast(), 24) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    ensure!(
        source_id[..8] == dest_id[..8],
        "Fixture move must remain on original volume"
    );
    let extended_destination = extended(
        destination
            .to_str()
            .context("Fixture path must be Unicode")?,
    )?;
    let name: Vec<u16> = extended_destination.as_os_str().encode_wide().collect();
    let root_offset = if std::mem::size_of::<usize>() == 8 {
        8
    } else {
        4
    };
    let length_offset = root_offset + std::mem::size_of::<usize>();
    let name_offset = length_offset + 4;
    let size = name_offset + name.len() * 2 + 2;
    let mut buffer = vec![0usize; size.div_ceil(std::mem::size_of::<usize>())];
    require_missing(&destination)?;
    ensure!(
        id(fixed.0)? == expected && identity(&source)? == expected,
        "Fixture source name changed before move"
    );
    unsafe {
        let p = buffer.as_mut_ptr().cast::<u8>();
        (p.add(length_offset) as *mut u32).write((name.len() * 2) as u32);
        std::ptr::copy_nonoverlapping(
            name.as_ptr().cast::<u8>(),
            p.add(name_offset),
            name.len() * 2,
        );
        if SetFileInformationByHandle(fixed.0, FileRenameInfo, p.cast(), size as u32) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    ensure!(
        id(fixed.0)? == expected && identity(&destination)? == expected,
        "Fixture move identity changed"
    );
    require_missing(&source)?;
    Ok(Value::Null)
}
fn proof(h: HANDLE) -> Result<(String, u32, Vec<u8>)> {
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(h, &mut info) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut n = 0;
    unsafe { GetKernelObjectSecurity(h, 7, null_mut(), 0, &mut n) };
    ensure!(
        std::io::Error::last_os_error().raw_os_error() == Some(122) && (20..=1048576).contains(&n),
        "Cannot read fixture security length"
    );
    let mut security = vec![0u8; n as usize];
    if unsafe { GetKernelObjectSecurity(h, 7, security.as_mut_ptr().cast(), n, &mut n) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    security.truncate(n as usize);
    Ok((id(h)?, info.dwFileAttributes, security))
}
fn extended(s: &str) -> Result<PathBuf> {
    let path = absolute(s)?;
    if s.starts_with(r"\\?\") {
        Ok(path)
    } else if let Some(unc) = s.strip_prefix(r"\\") {
        Ok(PathBuf::from(format!(r"\\?\UNC\{unc}")))
    } else {
        Ok(PathBuf::from(format!(r"\\?\{s}")))
    }
}
fn normalize_reserved(args: &Value) -> Result<Value> {
    let source_text = field(args, "source")?;
    let plain = source_text.strip_prefix(r"\\?\").unwrap_or(source_text);
    let bytes = plain.as_bytes();
    ensure!(
        bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'\\',
        "Reserved fixture requires absolute drive path"
    );
    let source = extended(plain)?;
    let destination = extended(field(args, "destination")?)?;
    let scope = extended(field(args, "scope")?)?;
    let expected = field(args, "expectedId")?;
    validate_id(expected)?;
    owned(&source, &scope)?;
    owned(&destination, &scope)?;
    let parent = source.parent().context("Missing reserved parent")?;
    ensure!(
        source.file_name() == Some(OsStr::new("NUL"))
            && destination.file_name() == Some(OsStr::new("reserved-directory-fixture"))
            && destination.parent() == Some(parent),
        "Reserved normalization requires fixed sibling names"
    );
    let _pins = pin_parents(parent)?;
    let fixed = open(&source, 0x30080, FILE_SHARE_READ)?;
    let before = proof(fixed.0)?;
    ensure!(
        before.0 == expected
            && before.1 & FILE_ATTRIBUTE_DIRECTORY != 0
            && before.1 & FILE_ATTRIBUTE_REPARSE_POINT == 0,
        "Reserved fixture identity or type differs"
    );
    require_missing(&destination)?;
    ensure!(
        std::fs::read_dir(&source)?.next().transpose()?.is_none(),
        "Reserved fixture is not empty"
    );
    ensure!(
        proof(fixed.0)? == before,
        "Reserved fixture changed before normalization"
    );
    // FILE_RENAME_INFOを正しいアラインメントで作り、既存先への置換を指定しない。
    let name: Vec<u16> = destination.as_os_str().encode_wide().collect();
    let root_offset = if std::mem::size_of::<usize>() == 8 {
        8
    } else {
        4
    };
    let length_offset = root_offset + std::mem::size_of::<usize>();
    let name_offset = length_offset + 4;
    let size = name_offset + name.len() * 2 + 2;
    let mut buffer =
        vec![0usize; (size + std::mem::size_of::<usize>() - 1) / std::mem::size_of::<usize>()];
    unsafe {
        let p = buffer.as_mut_ptr().cast::<u8>();
        (p.add(length_offset) as *mut u32).write((name.len() * 2) as u32);
        std::ptr::copy_nonoverlapping(
            name.as_ptr().cast::<u8>(),
            p.add(name_offset),
            name.len() * 2,
        );
        if SetFileInformationByHandle(fixed.0, FileRenameInfo, p.cast(), size as u32) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    let after = proof(fixed.0)?;
    let named = open(&destination, 0x20080, 7)?;
    ensure!(
        after == before
            && proof(named.0)? == before
            && std::fs::read_dir(&destination)?
                .next()
                .transpose()?
                .is_none(),
        "Normalized fixture identity, attributes, security or emptiness changed"
    );
    require_missing(&source)?;
    Ok(Value::Null)
}

/// JSONのみを返し、Shell操作は同じプロセスの専用STAで一度実行する。
pub fn dispatch(op: &str, args: &Value) -> Result<Value> {
    match op {
        "file.bin.find_identity" => {
            let expected = field(args, "expectedId")?.to_owned();
            in_sta(move || Ok(json!(find_identity(&expected)?)))
        }
        "file.bin.find_new" => {
            let expected = field(args, "expectedId")?.to_owned();
            let prior = args
                .get("priorPidls")
                .and_then(Value::as_array)
                .context("Missing priorPidls")?
                .iter()
                .map(|v| v.as_str().map(str::to_owned).context("Invalid prior PIDL"))
                .collect::<Result<Vec<_>>>()?;
            in_sta(move || {
                let found: Vec<_> = find_identity(&expected)?
                    .into_iter()
                    .filter(|v| !prior.iter().any(|p| v["Pidl"].as_str() == Some(p)))
                    .collect();
                ensure!(
                    found.len() == 1,
                    "Exactly one newly recycled owned native identity required; found {}",
                    found.len()
                );
                Ok(found.into_iter().next().unwrap())
            })
        }
        "file.bin.find_tracked" => {
            let saved = field(args, "pidl")?.to_owned();
            in_sta(move || {
                let b = bin()?;
                match find(&b, &saved)? {
                    Some(item) => Ok(json!(physical(item.0)?)),
                    None => Ok(Value::Null),
                }
            })
        }
        "file.bin.restore_owned" => {
            let args = args.clone();
            in_sta(move || restore_owned(&args))
        }
        "file.shell.move_owned" => move_owned(args),
        "file.shell.normalize_reserved_directory" => normalize_reserved(args),
        _ => bail!("Unknown Shell fixture operation: {op}"),
    }
}

#[cfg(test)]
mod scope_tests {
    use super::*;

    #[test]
    fn windows_ordinal_scope_boundaries() {
        assert!(
            owned(
                Path::new(r"D:\Fixture\Straße\item"),
                Path::new(r"d:\fixture\Straße")
            )
            .is_ok()
        );
        assert!(
            owned(
                Path::new(r"D:\Fixture\Straße\item"),
                Path::new(r"D:\Fixture\STRASSE")
            )
            .is_err()
        );
        assert!(
            owned(
                Path::new(r"D:\Fixture\STRASSE\item"),
                Path::new(r"D:\Fixture\Straße")
            )
            .is_err()
        );
        assert!(
            owned(
                Path::new(r"D:\FixtureSuffix\item"),
                Path::new(r"D:\Fixture")
            )
            .is_err()
        );
        assert!(owned(Path::new(r"D:\Fixture"), Path::new(r"D:\Fixture")).is_err());
        assert!(owned(Path::new(r"D:\item"), Path::new("d:\\")).is_ok());
    }
}
