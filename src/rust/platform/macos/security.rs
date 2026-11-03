use super::*;
use std::{
    ffi::{CString, c_void},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::OsStrExt,
    },
};

unsafe extern "C" {
    fn acl_init(count: i32) -> *mut c_void;
    fn acl_free(value: *mut c_void) -> i32;
    fn acl_get_fd_np(fd: i32, kind: i32) -> *mut c_void;
    fn acl_get_flagset_np(acl: *mut c_void, flags: *mut *mut c_void) -> i32;
    fn acl_add_flag_np(flags: *mut c_void, flag: u32) -> i32;
    fn filesec_init() -> *mut c_void;
    fn filesec_free(value: *mut c_void);
    fn filesec_set_property(value: *mut c_void, property: i32, data: *const c_void) -> i32;
    fn openx_np(path: *const i8, flags: i32, security: *mut c_void) -> i32;
    fn mkdirx_np(path: *const i8, security: *mut c_void) -> i32;
}

pub(super) fn reject_acl(file: &File) -> Result<()> {
    let mut request: libc::attrlist = unsafe { std::mem::zeroed() };
    request.bitmapcount = 5;
    request.commonattr = 0x00400000;
    let mut data = vec![0u8; 8192];
    if unsafe {
        libc::fgetattrlist(
            file.as_raw_fd(),
            (&mut request as *mut libc::attrlist).cast(),
            data.as_mut_ptr().cast(),
            data.len(),
            0,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    let length = u32::from_ne_bytes(data[0..4].try_into()?) as usize;
    if length < 12 || length > data.len() {
        bail!("Unknown extended ACL response");
    }
    let offset = i32::from_ne_bytes(data[4..8].try_into()?);
    let size = u32::from_ne_bytes(data[8..12].try_into()?) as usize;
    if size == 0 {
        // ACL未対応とACL無しを区別し、ENOENTだけを不在の証拠にしない。
        if unsafe { libc::fpathconf(file.as_raw_fd(), libc::_PC_EXTENDED_SECURITY_NP) } != 1 {
            bail!("Extended ACL support cannot be established");
        }
        let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), 0x100) };
        if !acl.is_null() {
            unsafe {
                acl_free(acl);
            }
            bail!("Conflicting extended ACL observations");
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOENT) {
            bail!("Extended ACL absence cannot be established");
        }
        return Ok(());
    }
    let start = (4i64 + i64::from(offset))
        .try_into()
        .ok()
        .filter(|start: &usize| *start >= 12)
        .context("Invalid ACL offset")?;
    if size < 44 || start + size > length {
        bail!("Invalid extended ACL size");
    }
    let acl = &data[start..start + size];
    let magic = u32::from_ne_bytes(acl[0..4].try_into()?);
    let count = u32::from_ne_bytes(acl[36..40].try_into()?);
    let flags = u32::from_ne_bytes(acl[40..44].try_into()?);
    if magic != 0x012cc16d || !matches!(count, 0 | u32::MAX) || flags & !(1 << 17) != 0 {
        bail!("Unknown or nonempty extended ACL; existing ACL was preserved");
    }
    Ok(())
}

struct Creation {
    acl: *mut c_void,
    security: *mut c_void,
}
impl Creation {
    fn new(mode: libc::mode_t) -> Result<Self> {
        let result = Self {
            acl: unsafe { acl_init(0) },
            security: unsafe { filesec_init() },
        };
        if result.acl.is_null() || result.security.is_null() {
            bail!("Cannot allocate private creation ACL");
        }
        let mut flags = std::ptr::null_mut();
        if unsafe { acl_get_flagset_np(result.acl, &mut flags) } != 0
            || unsafe { acl_add_flag_np(flags, 1 << 17) } != 0
            || unsafe {
                filesec_set_property(result.security, 4, (&mode as *const libc::mode_t).cast())
            } != 0
            || unsafe {
                filesec_set_property(
                    result.security,
                    5,
                    (&result.acl as *const *mut c_void).cast(),
                )
            } != 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(result)
    }
}
impl Drop for Creation {
    fn drop(&mut self) {
        unsafe {
            if !self.security.is_null() {
                filesec_free(self.security);
            }
            if !self.acl.is_null() {
                acl_free(self.acl);
            }
        }
    }
}
pub(super) fn create_file(path: &Path) -> Result<File> {
    let security = Creation::new(0o600)?;
    let name = CString::new(path.as_os_str().as_bytes())?;
    let fd = unsafe {
        openx_np(
            name.as_ptr(),
            libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            security.security,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    reject_acl(&file)?;
    Ok(file)
}
pub(super) fn create_dir(path: &Path) -> Result<()> {
    let security = Creation::new(0o700)?;
    let name = CString::new(path.as_os_str().as_bytes())?;
    if unsafe { mkdirx_np(name.as_ptr(), security.security) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    reject_acl(&File::open(path)?)
}
