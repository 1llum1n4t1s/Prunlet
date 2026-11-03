//! 永続metadataは最初のbyteを書く前から本人とSYSTEMだけへ公開する。
use super::{OwnedHandle, PinnedFile, path, wide};
use anyhow::{Result, bail};
use std::{
    ffi::c_void,
    mem::{size_of, zeroed},
    path::Path,
    ptr::{null, null_mut},
};
use windows_sys::Win32::{
    Foundation::*, Security::Authorization::*, Security::*, Storage::FileSystem::*,
    System::Threading::*,
};

struct LocalAllocation(*mut c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}
pub fn current_user_sid() -> Result<String> {
    let token = open_effective_token()?;
    user_sid(token.raw())
}
fn open_effective_token() -> Result<OwnedHandle> {
    unsafe {
        let mut raw = null_mut();
        if OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut raw) == 0 {
            let error = GetLastError();
            if error != ERROR_NO_TOKEN {
                return Err(std::io::Error::from_raw_os_error(error as i32).into());
            }
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        OwnedHandle::from_raw(raw)
    }
}
fn user_sid(token: HANDLE) -> Result<String> {
    unsafe {
        let mut length = 0;
        GetTokenInformation(token, TokenUser, null_mut(), 0, &mut length);
        if length == 0 || length > 65536 {
            bail!("Invalid effective token user length");
        }
        let mut buffer = vec![0u8; length as usize];
        if GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            length,
            &mut length,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        sid_string((*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid)
    }
}
#[derive(Debug, Clone)]
pub struct EffectiveIdentity {
    pub sid: String,
    pub authentication_id: u64,
    pub session_id: u32,
    pub has_restrictions: bool,
}
pub fn effective_identity() -> Result<EffectiveIdentity> {
    unsafe {
        let token = open_effective_token()?;
        let mut statistics: TOKEN_STATISTICS = zeroed();
        let mut needed = 0;
        if GetTokenInformation(
            token.raw(),
            TokenStatistics,
            (&mut statistics as *mut TOKEN_STATISTICS).cast(),
            size_of::<TOKEN_STATISTICS>() as u32,
            &mut needed,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let mut session = 0u32;
        let mut restricted = 0u32;
        for (class, output) in [
            (TokenSessionId, &mut session),
            (TokenHasRestrictions, &mut restricted),
        ] {
            if GetTokenInformation(
                token.raw(),
                class,
                (output as *mut u32).cast(),
                4,
                &mut needed,
            ) == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        Ok(EffectiveIdentity {
            sid: user_sid(token.raw())?,
            authentication_id: ((statistics.AuthenticationId.HighPart as u32 as u64) << 32)
                | statistics.AuthenticationId.LowPart as u64,
            session_id: session,
            has_restrictions: restricted != 0,
        })
    }
}
unsafe fn sid_string(sid: PSID) -> Result<String> {
    unsafe {
        if sid.is_null() || IsValidSid(sid) == 0 {
            bail!("Invalid Windows SID");
        }
        let mut value = null_mut();
        if ConvertSidToStringSidW(sid, &mut value) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let _allocation = LocalAllocation(value.cast());
        let mut length = 0;
        while *value.add(length) != 0 {
            length += 1;
        }
        Ok(String::from_utf16(std::slice::from_raw_parts(
            value, length,
        ))?)
    }
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn read_member_security(handle: HANDLE) -> Result<Vec<u8>> {
    unsafe {
        let mut descriptor = null_mut();
        let status = GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            null_mut(),
            null_mut(),
            &mut descriptor,
        );
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
        let _allocation = LocalAllocation(descriptor);
        let length = GetSecurityDescriptorLength(descriptor) as usize;
        if !(20..=65536).contains(&length) || IsValidSecurityDescriptor(descriptor) == 0 {
            bail!("Invalid metadata security descriptor");
        }
        Ok(std::slice::from_raw_parts(descriptor.cast::<u8>(), length).to_vec())
    }
}
pub fn verify_private_member_security(handle: HANDLE, allow_inherited: bool) -> Result<()> {
    verify_private_security(handle, false, allow_inherited)
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn verify_private_security(
    handle: HANDLE,
    directory: bool,
    allow_inherited: bool,
) -> Result<()> {
    unsafe { verify_private_security_core(handle, directory, allow_inherited, false) }
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn verify_private_store_security(handle: HANDLE, restore: bool) -> Result<()> {
    unsafe { verify_private_security_core(handle, true, false, !restore) }
}
unsafe fn verify_private_security_core(
    handle: HANDLE,
    directory: bool,
    allow_inherited: bool,
    administrators: bool,
) -> Result<()> {
    unsafe {
        let bytes = read_member_security(handle)?;
        let descriptor = bytes.as_ptr() as PSECURITY_DESCRIPTOR;
        let mut owner = null_mut();
        let mut defaulted = 0;
        if GetSecurityDescriptorOwner(descriptor, &mut owner, &mut defaulted) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let expected_owner = current_user_sid()?;
        if sid_string(owner)? != expected_owner {
            bail!(
                "Private metadata owner differs from the effective user; permissions were not changed"
            );
        }
        let mut control = 0u16;
        let mut revision = 0;
        if GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        if control & SE_DACL_PRESENT == 0 || (!allow_inherited && control & SE_DACL_PROTECTED == 0)
        {
            bail!("Private metadata has an absent or unprotected DACL");
        }
        let mut present = 0;
        let mut dacl = null_mut();
        if GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted) == 0
            || present == 0
            || dacl.is_null()
        {
            bail!("Private metadata has a null DACL");
        }
        let mut principals = vec![expected_owner, "S-1-5-18".to_owned()];
        if administrators {
            principals.push("S-1-5-32-544".to_owned());
        }
        principals.sort();
        principals.dedup();
        if (*dacl).AceCount as usize != principals.len() {
            bail!("Unexpected ACE count in private metadata");
        }
        let required_flags = if directory {
            (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE) as u8
        } else {
            0
        };
        for index in 0..(*dacl).AceCount {
            let mut ace = null_mut();
            if GetAce(dacl, index as u32, &mut ace) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let allowed = &*(ace.cast::<ACCESS_ALLOWED_ACE>());
            let flags = if allow_inherited {
                allowed.Header.AceFlags & !(INHERITED_ACE as u8)
            } else {
                allowed.Header.AceFlags
            };
            if allowed.Header.AceType != 0
                || flags != required_flags
                || allowed.Mask != FILE_ALL_ACCESS
            {
                bail!("Unexpected ACE permissions in private metadata");
            }
            let principal = sid_string((&allowed.SidStart as *const u32).cast_mut().cast())?;
            let at = principals
                .iter()
                .position(|x| *x == principal)
                .ok_or_else(|| anyhow::anyhow!("Unexpected private metadata principal"))?;
            principals.remove(at);
        }
        Ok(())
    }
}
#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum_length: u16,
    buffer: *mut u16,
}
#[repr(C)]
struct ObjectAttributes {
    length: u32,
    root: HANDLE,
    name: *mut UnicodeString,
    attributes: u32,
    security: PSECURITY_DESCRIPTOR,
    qos: *mut c_void,
}
#[repr(C)]
struct IoStatusBlock {
    status: usize,
    information: usize,
}
#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtCreateFile(
        handle: *mut HANDLE,
        access: u32,
        attributes: *mut ObjectAttributes,
        status: *mut IoStatusBlock,
        allocation: *const i64,
        file_attributes: u32,
        share: u32,
        disposition: u32,
        options: u32,
        ea: *const c_void,
        ea_length: u32,
    ) -> i32;
    fn RtlNtStatusToDosError(status: i32) -> u32;
}
pub fn create_private_file(path: &Path) -> Result<OwnedHandle> {
    create_private(path, false)
}
pub fn create_private_directory(path: &Path) -> Result<OwnedHandle> {
    create_private(path, true)
}
fn create_private(path: &Path, directory: bool) -> Result<OwnedHandle> {
    unsafe {
        let owner = current_user_sid()?;
        let flags = if directory { "OICI" } else { "" };
        let system = if owner == "S-1-5-18" {
            String::new()
        } else {
            format!("(A;{flags};FA;;;SY)")
        };
        let sddl = wide(std::ffi::OsStr::new(&format!(
            "O:{owner}D:P(A;{flags};FA;;;{owner}){system}"
        )))?;
        let mut descriptor = null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            null_mut(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let _allocation = LocalAllocation(descriptor);
        let mut name = wide(std::ffi::OsStr::new(&format!(
            "\\??\\{}",
            path::absolute(path)?.display()
        )))?;
        let mut unicode = UnicodeString {
            length: ((name.len() - 1) * 2).try_into()?,
            maximum_length: (name.len() * 2).try_into()?,
            buffer: name.as_mut_ptr(),
        };
        let mut attributes = ObjectAttributes {
            length: size_of::<ObjectAttributes>() as u32,
            root: null_mut(),
            name: &mut unicode,
            attributes: 0,
            security: descriptor,
            qos: null_mut(),
        };
        let mut handle = null_mut();
        let mut status: IoStatusBlock = zeroed();
        let code = NtCreateFile(
            &mut handle,
            GENERIC_READ | GENERIC_WRITE | if directory { 0 } else { DELETE } | SYNCHRONIZE,
            &mut attributes,
            &mut status,
            null(),
            if directory {
                FILE_ATTRIBUTE_DIRECTORY
            } else {
                FILE_ATTRIBUTE_ARCHIVE
            },
            if directory { 3 } else { 1 },
            2,
            if directory { 0x00200021 } else { 0x00200060 },
            null(),
            0,
        );
        if code < 0 {
            return Err(
                std::io::Error::from_raw_os_error(RtlNtStatusToDosError(code) as i32).into(),
            );
        }
        let handle = OwnedHandle::from_raw(handle)?;
        let fixed = PinnedFile::open(
            path,
            FILE_READ_ATTRIBUTES | READ_CONTROL,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        )?;
        let id = fixed.identity()?;
        if id.is_reparse() || id.is_directory() != directory || id.links > 1 {
            bail!("Private metadata member is not a plain single-link entry");
        }
        if !super::identity(handle.raw())?.same_object(&id)
            || fixed.final_path()? != path::absolute(path)?
        {
            bail!("Private metadata creation name does not match fixed object");
        }
        super::reject_named_streams(path)?;
        verify_private_security(handle.raw(), directory, false)?;
        Ok(handle)
    }
}
pub fn open_private_directory(path: &Path) -> Result<PinnedFile> {
    PinnedFile::open(path, READ_CONTROL | FILE_READ_ATTRIBUTES, 3)
}
pub fn open_lifecycle_metadata(path: &Path) -> Result<PinnedFile> {
    PinnedFile::open(path, GENERIC_READ | READ_CONTROL, 1)
}
pub fn open_lifecycle_delete(path: &Path) -> Result<PinnedFile> {
    PinnedFile::open(path, GENERIC_READ | DELETE | READ_CONTROL, 1)
}
pub fn open_lifecycle_pending_publisher(path: &Path) -> Result<PinnedFile> {
    PinnedFile::open(
        path,
        GENERIC_READ | GENERIC_WRITE | DELETE | READ_CONTROL,
        1,
    )
}
pub fn open_lifecycle_directory_move(path: &Path) -> Result<PinnedFile> {
    PinnedFile::open(path, DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL, 1)
}

#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn delete_fixed(handle: HANDLE, ignore_readonly: bool) -> Result<()> {
    unsafe {
        let mut flags = if ignore_readonly { 0x11u32 } else { 1 };
        let (class, size) = if ignore_readonly {
            (FileDispositionInfoEx, 4)
        } else {
            (FileDispositionInfo, 1)
        };
        if SetFileInformationByHandle(handle, class, (&mut flags as *mut u32).cast(), size) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    }
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn delete_permanent_fixed(handle: HANDLE, ignore_readonly: bool, posix: bool) -> Result<()> {
    if !posix {
        return delete_fixed(handle, ignore_readonly);
    }
    unsafe {
        let flags = 3u32 | if ignore_readonly { 0x10 } else { 0 };
        if SetFileInformationByHandle(
            handle,
            FileDispositionInfoEx,
            (&flags as *const u32).cast(),
            4,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    }
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn rename_fixed(handle: HANDLE, parent: HANDLE, leaf: &str) -> Result<()> {
    if leaf.is_empty() || leaf.contains(['\\', '/', ':', '\0']) || matches!(leaf, "." | "..") {
        bail!("Invalid rename leaf");
    }
    path::absolute(Path::new(&format!("C:\\{leaf}")))?;
    let parent_identity = super::identity(parent)?;
    if !parent_identity.is_directory() || parent_identity.is_reparse() {
        bail!("Rename parent is not an ordinary directory");
    }
    if parent_identity.volume != super::identity(handle)?.volume {
        bail!("Rename source and destination are not on the same volume");
    }
    let parent_path = super::final_path(parent)?;
    let _parents = path::pin_directories(&parent_path)?;
    if parent_identity != super::identity(parent)? || super::final_path(parent)? != parent_path {
        bail!("Rename parent changed while its ancestors were fixed");
    }
    let mut text = super::win32_path(&parent_path.join(leaf))?;
    text.pop();
    let root_offset = if size_of::<HANDLE>() == 8 { 8 } else { 4 };
    let length_offset = root_offset + size_of::<HANDLE>();
    let name_offset = length_offset + 4;
    // Win32 FileRenameInfoはRootDirectory=NULLの絶対名を使い、全祖先pinを保持する。
    let mut buffer = vec![0u8; name_offset + text.len() * 2 + 2];
    unsafe {
        std::ptr::write_unaligned(
            buffer.as_mut_ptr().add(length_offset).cast::<u32>(),
            (text.len() * 2) as u32,
        );
        std::ptr::copy_nonoverlapping(
            text.as_ptr().cast::<u8>(),
            buffer.as_mut_ptr().add(name_offset),
            text.len() * 2,
        );
        if SetFileInformationByHandle(
            handle,
            FileRenameInfo,
            buffer.as_ptr().cast(),
            buffer.len() as u32,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    Ok(())
}
