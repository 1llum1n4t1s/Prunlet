//! Windowsの実体固定。ハンドルとIDは要求中だけ保持し、永続化しない。
pub mod diagnostics;
mod invariant_case_table;
pub mod path;
pub mod process;
pub mod recycle;
pub mod security;

use anyhow::{Context, Result, bail};
use std::{
    ffi::OsStr,
    mem::{size_of, zeroed},
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
};
use windows_sys::Win32::{Foundation::*, Storage::FileSystem::*};

pub fn wide(value: &OsStr) -> Result<Vec<u16>> {
    let mut result: Vec<u16> = value.encode_wide().collect();
    if result.contains(&0) {
        bail!("NUL is not permitted in Windows names");
    }
    result.push(0);
    Ok(result)
}
pub fn invariant_uppercase(value: &str) -> Result<String> {
    Ok(upper(value))
}
fn upper(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            let value = ch as u32;
            match invariant_case_table::UPPER.binary_search_by_key(&value, |&(lower, _)| lower) {
                Ok(i) => char::from_u32(invariant_case_table::UPPER[i].1).unwrap(),
                Err(_) => ch,
            }
        })
        .collect()
}
pub fn ordinal_ignore_case(left: &str, right: &str) -> bool {
    upper(left) == upper(right)
}
pub fn win32_path(path: &Path) -> Result<Vec<u16>> {
    let value = path::file_system_absolute(path)?;
    wide(OsStr::new(&format!("\\\\?\\{}", value.display())))
}

#[derive(Debug)]
pub struct OwnedHandle(HANDLE);
unsafe impl Send for OwnedHandle {}
unsafe impl Sync for OwnedHandle {}
impl OwnedHandle {
    /// 呼出側は、有効な所有済みHANDLEだけを渡す。
    pub unsafe fn from_raw(raw: HANDLE) -> Result<Self> {
        if raw.is_null() || raw == INVALID_HANDLE_VALUE {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self(raw))
    }
    pub fn raw(&self) -> HANDLE {
        self.0
    }
    pub fn into_raw(self) -> HANDLE {
        let owned = std::mem::ManuallyDrop::new(self);
        owned.0
    }
}
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileIdentity {
    pub volume: u64,
    pub id: [u8; 16],
    pub attributes: u32,
    pub reparse_tag: u32,
    pub links: u32,
    pub size: u64,
    pub creation_time: i64,
    pub last_write_time: i64,
    pub change_time: i64,
}
impl FileIdentity {
    pub fn same_object(&self, other: &Self) -> bool {
        self.volume == other.volume
            && self.id == other.id
            && self.is_directory() == other.is_directory()
            && self.reparse_tag == other.reparse_tag
    }
    pub fn is_directory(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_DIRECTORY != 0
    }
    pub fn is_reparse(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
}
#[derive(Debug)]
pub struct PinnedFile {
    handle: OwnedHandle,
    pub path: PathBuf,
    initial: FileIdentity,
}
impl PinnedFile {
    pub fn open(path: &Path, access: u32, share: u32) -> Result<Self> {
        let name = win32_path(path)?;
        let handle = unsafe {
            OwnedHandle::from_raw(CreateFileW(
                name.as_ptr(),
                access,
                share,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
                std::ptr::null_mut(),
            ))
        }
        .with_context(|| format!("Cannot open fixed filesystem entry {}", path.display()))?;
        Self::from_handle(path.to_path_buf(), handle)
    }
    pub fn from_handle(path: PathBuf, handle: OwnedHandle) -> Result<Self> {
        let initial = identity(handle.raw())?;
        Ok(Self {
            handle,
            path,
            initial,
        })
    }
    pub fn raw(&self) -> HANDLE {
        self.handle.raw()
    }
    pub fn identity(&self) -> Result<FileIdentity> {
        identity(self.raw())
    }
    pub fn initial_identity(&self) -> &FileIdentity {
        &self.initial
    }
    pub fn require_unchanged(&self) -> Result<()> {
        if self.identity()? != self.initial {
            bail!("Fixed filesystem entry changed: {}", self.path.display());
        }
        Ok(())
    }
    pub fn final_path(&self) -> Result<PathBuf> {
        final_path(self.raw())
    }
    pub fn verify_named(&self) -> Result<()> {
        let current = Self::open(
            &self.path,
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        )?;
        if !self.initial.same_object(current.initial_identity()) {
            bail!(
                "Fixed name no longer identifies the original entry: {}",
                self.path.display()
            );
        }
        Ok(())
    }
    pub fn reject_case_sensitive(&self) -> Result<()> {
        let mut flags = 0u32;
        let ok = unsafe {
            GetFileInformationByHandleEx(
                self.raw(),
                FileCaseSensitiveInfo,
                (&mut flags as *mut u32).cast(),
                4,
            )
        };
        if ok == 0 {
            let error = std::io::Error::last_os_error();
            if !matches!(error.raw_os_error(), Some(1 | 50 | 87)) {
                return Err(error.into());
            }
        } else if flags & 1 != 0 {
            bail!("Case-sensitive directory is not supported for protected storage");
        }
        Ok(())
    }
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn identity(handle: HANDLE) -> Result<FileIdentity> {
    unsafe {
        let mut id: FILE_ID_INFO = zeroed();
        let mut basic: FILE_BASIC_INFO = zeroed();
        let mut standard: FILE_STANDARD_INFO = zeroed();
        let mut tag: FILE_ATTRIBUTE_TAG_INFO = zeroed();
        for (class, buffer, length) in [
            (
                FileIdInfo,
                (&mut id as *mut FILE_ID_INFO).cast(),
                size_of::<FILE_ID_INFO>(),
            ),
            (
                FileBasicInfo,
                (&mut basic as *mut FILE_BASIC_INFO).cast(),
                size_of::<FILE_BASIC_INFO>(),
            ),
            (
                FileStandardInfo,
                (&mut standard as *mut FILE_STANDARD_INFO).cast(),
                size_of::<FILE_STANDARD_INFO>(),
            ),
            (
                FileAttributeTagInfo,
                (&mut tag as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
                size_of::<FILE_ATTRIBUTE_TAG_INFO>(),
            ),
        ] {
            if GetFileInformationByHandleEx(handle, class, buffer, length as u32) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        if id.VolumeSerialNumber == 0
            || id.FileId.Identifier.iter().all(|&x| x == 0)
            || id.FileId.Identifier.iter().all(|&x| x == 255)
        {
            bail!("Filesystem returned an unusable file identity");
        }
        if standard.EndOfFile < 0 {
            bail!("Invalid filesystem entry length");
        }
        Ok(FileIdentity {
            volume: id.VolumeSerialNumber,
            id: id.FileId.Identifier,
            attributes: basic.FileAttributes,
            reparse_tag: if basic.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                tag.ReparseTag
            } else {
                0
            },
            links: standard.NumberOfLinks,
            size: standard.EndOfFile as u64,
            creation_time: basic.CreationTime,
            last_write_time: basic.LastWriteTime,
            change_time: basic.ChangeTime,
        })
    }
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn final_path(handle: HANDLE) -> Result<PathBuf> {
    let mut buffer = vec![0u16; 32768];
    let length =
        unsafe { GetFinalPathNameByHandleW(handle, buffer.as_mut_ptr(), buffer.len() as u32, 0) }
            as usize;
    if length == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if length >= buffer.len() {
        bail!("Filesystem path exceeds supported length");
    }
    path::file_system_absolute(Path::new(&String::from_utf16(&buffer[..length])?))
}

fn scan_directory_names(handle: HANDLE, mut visit: impl FnMut(String)) -> Result<()> {
    let mut first = true;
    let mut buffer = vec![0u8; 65536];
    loop {
        unsafe {
            buffer.fill(0);
            if GetFileInformationByHandleEx(
                handle,
                if first {
                    FileFullDirectoryRestartInfo
                } else {
                    FileFullDirectoryInfo
                },
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
            ) == 0
            {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() == Some(18) {
                    return Ok(());
                }
                return Err(error.into());
            }
            first = false;
            let mut offset = 0;
            loop {
                if offset > buffer.len() - 68 {
                    bail!("Invalid fixed-directory enumeration offset");
                }
                let next = u32::from_le_bytes(buffer[offset..offset + 4].try_into()?) as usize;
                let length =
                    u32::from_le_bytes(buffer[offset + 60..offset + 64].try_into()?) as usize;
                if length == 0 || length % 2 != 0 || length > buffer.len() - offset - 68 {
                    bail!("Invalid fixed-directory name length");
                }
                let text: Vec<u16> = buffer[offset + 68..offset + 68 + length]
                    .chunks_exact(2)
                    .map(|x| u16::from_le_bytes([x[0], x[1]]))
                    .collect();
                let name = String::from_utf16(&text)?;
                if name != "." && name != ".." {
                    if name.contains(['\\', '/', ':', '\0']) {
                        bail!("Invalid fixed-directory name");
                    }
                    visit(name);
                }
                if next == 0 {
                    break;
                }
                if next < 68 + length || next % 8 != 0 || next > buffer.len() - offset {
                    bail!("Invalid fixed-directory record");
                }
                offset += next;
            }
        }
    }
}
pub fn directory_names(handle: HANDLE) -> Result<Vec<String>> {
    let mut names = Vec::new();
    scan_directory_names(handle, |name| names.push(name))?;
    Ok(names)
}
/// 空でなくても最後まで走査し、後続の列挙失敗と不正名を見逃さない。
pub fn directory_is_empty(handle: HANDLE) -> Result<bool> {
    let mut empty = true;
    scan_directory_names(handle, |_| empty = false)?;
    Ok(empty)
}
pub fn any_pinned_directory_name(
    handle: HANDLE,
    mut predicate: impl FnMut(&str) -> bool,
) -> Result<bool> {
    Ok(directory_names(handle)?.iter().any(|name| predicate(name)))
}
#[derive(Debug, Clone)]
pub struct DirectoryEntry {
    pub name: String,
    pub id: [u8; 16],
    pub attributes: u32,
    pub reparse_tag: u32,
    pub creation_time: i64,
    pub last_write_time: i64,
    pub change_time: i64,
}
pub fn directory_entries(handle: HANDLE) -> Result<Vec<DirectoryEntry>> {
    directory_entries_bounded(handle, usize::MAX)
}
pub fn directory_names_bounded(handle: HANDLE, maximum: usize) -> Result<Vec<String>> {
    Ok(directory_entries_bounded(handle, maximum)?
        .into_iter()
        .map(|entry| entry.name)
        .collect())
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn directory_entries_bounded(handle: HANDLE, maximum: usize) -> Result<Vec<DirectoryEntry>> {
    let mut result = vec![];
    let mut first = true;
    let mut buffer = vec![0u8; 65536];
    loop {
        if unsafe {
            GetFileInformationByHandleEx(
                handle,
                if first {
                    FileIdExtdDirectoryRestartInfo
                } else {
                    FileIdExtdDirectoryInfo
                },
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
            )
        } == 0
        {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(18) {
                return Ok(result);
            }
            return Err(error.into());
        }
        first = false;
        let mut offset = 0;
        loop {
            if offset > buffer.len() - 88 {
                bail!("Invalid directory identity offset");
            }
            let b = &buffer[offset..];
            let u32at = |i| u32::from_le_bytes(b[i..i + 4].try_into().unwrap());
            let i64at = |i| i64::from_le_bytes(b[i..i + 8].try_into().unwrap());
            let next = u32at(0) as usize;
            let n = u32at(60) as usize;
            if n == 0 || n % 2 != 0 || n > b.len() - 88 {
                bail!("Invalid directory identity name");
            }
            let name = String::from_utf16(
                &b[88..88 + n]
                    .chunks_exact(2)
                    .map(|x| u16::from_le_bytes([x[0], x[1]]))
                    .collect::<Vec<_>>(),
            )?;
            if name != "." && name != ".." {
                anyhow::ensure!(
                    result.len() < maximum,
                    "Directory enumeration exceeds the reserved-tree entry limit"
                );
                if name.contains(['\\', '/', ':', '\0']) {
                    bail!("Invalid directory identity component");
                }
                result.push(DirectoryEntry {
                    name,
                    id: b[72..88].try_into()?,
                    attributes: u32at(56),
                    reparse_tag: if u32at(56) & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                        u32at(68)
                    } else {
                        0
                    },
                    creation_time: i64at(8),
                    last_write_time: i64at(24),
                    change_time: i64at(32),
                });
            }
            if next == 0 {
                break;
            }
            if next < 88 + n || next % 8 != 0 || next > b.len() {
                bail!("Invalid directory identity record");
            }
            offset += next;
        }
    }
}
pub fn reject_named_streams(path: &Path) -> Result<()> {
    unsafe {
        let name = win32_path(path)?;
        let mut data: WIN32_FIND_STREAM_DATA = zeroed();
        let handle = FindFirstStreamW(
            name.as_ptr(),
            FindStreamInfoStandard,
            (&mut data as *mut WIN32_FIND_STREAM_DATA).cast(),
            0,
        );
        if handle == INVALID_HANDLE_VALUE {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(38) {
                return Ok(());
            }
            return Err(error.into());
        }
        struct Find(HANDLE);
        impl Drop for Find {
            fn drop(&mut self) {
                unsafe {
                    FindClose(self.0);
                }
            }
        }
        let handle = Find(handle);
        loop {
            let length = data
                .cStreamName
                .iter()
                .position(|&x| x == 0)
                .unwrap_or(data.cStreamName.len());
            let stream = String::from_utf16(&data.cStreamName[..length])?;
            if stream != "::$DATA" {
                bail!("Metadata with alternate data streams is not supported");
            }
            if FindNextStreamW(handle.0, (&mut data as *mut WIN32_FIND_STREAM_DATA).cast()) == 0 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() == Some(38) {
                    break;
                }
                return Err(error.into());
            }
        }
        Ok(())
    }
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn read_reparse(handle: HANDLE) -> Result<Vec<u8>> {
    unsafe {
        let mut bytes = vec![0u8; 16384];
        let mut count = 0;
        if windows_sys::Win32::System::IO::DeviceIoControl(
            handle,
            0x900A8,
            std::ptr::null(),
            0,
            bytes.as_mut_ptr().cast(),
            bytes.len() as u32,
            &mut count,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        bytes.truncate(count as usize);
        if bytes.len() < 8 {
            bail!("Invalid reparse metadata");
        }
        let tag = u32::from_le_bytes(bytes[..4].try_into()?);
        let length = u16::from_le_bytes(bytes[4..6].try_into()?) as usize;
        if !matches!(tag, 0xA0000003 | 0xA000000C) || length + 8 != bytes.len() {
            bail!("Unsupported or malformed reparse metadata");
        }
        Ok(bytes)
    }
}
pub fn volume_mount_root(path: &Path) -> Result<PathBuf> {
    let name = win32_path(path)?;
    let mut buffer = vec![0u16; 32768];
    if unsafe { GetVolumePathNameW(name.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let n = buffer.iter().position(|&x| x == 0).unwrap_or(buffer.len());
    Ok(PathBuf::from(String::from_utf16(&buffer[..n])?))
}
pub fn volume_name(root: &Path) -> Result<String> {
    let name = wide(root.as_os_str())?;
    let mut buffer = vec![0u16; 128];
    if unsafe {
        GetVolumeNameForVolumeMountPointW(name.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32)
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    let n = buffer.iter().position(|&x| x == 0).unwrap_or(buffer.len());
    Ok(String::from_utf16(&buffer[..n])?)
}
pub fn logical_drives() -> Result<Vec<PathBuf>> {
    let mask = unsafe { GetLogicalDrives() };
    if mask == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok((0..26)
        .filter(|i| mask & (1 << i) != 0)
        .map(|i| PathBuf::from(format!("{}:\\", (b'A' + i) as char)))
        .collect())
}
pub fn ready_local_drives() -> Result<Vec<PathBuf>> {
    let mut result = vec![];
    for root in logical_drives()? {
        let name = wide(root.as_os_str())?;
        let kind = unsafe { GetDriveTypeW(name.as_ptr()) };
        if !matches!(kind, 2 | 3 | 6) {
            continue;
        }
        let mut serial = 0;
        if unsafe {
            GetVolumeInformationW(
                name.as_ptr(),
                std::ptr::null_mut(),
                0,
                &mut serial,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            result.push(root);
        }
    }
    Ok(result)
}
pub fn local_ready_drives() -> Result<Vec<PathBuf>> {
    ready_local_drives()
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn file_size(handle: HANDLE) -> Result<u64> {
    let mut size = 0i64;
    if unsafe { GetFileSizeEx(handle, &mut size) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if size < 0 {
        bail!("Invalid file length");
    }
    Ok(size as u64)
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn legacy_identity(handle: HANDLE) -> Result<String> {
    unsafe {
        let mut info: BY_HANDLE_FILE_INFORMATION = zeroed();
        if GetFileInformationByHandle(handle, &mut info) == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(format!(
            "{:08x}:{:08x}{:08x}",
            info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow
        ))
    }
}
pub fn machine_name() -> Result<String> {
    unsafe {
        let mut length = 256;
        let mut buffer = vec![0u16; length as usize];
        if windows_sys::Win32::System::WindowsProgramming::GetComputerNameW(
            buffer.as_mut_ptr(),
            &mut length,
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(String::from_utf16(&buffer[..length as usize])?)
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NamedStream {
    pub name: String,
    pub size: u64,
}
pub fn named_stream_bytes(handle: HANDLE) -> Result<u64> {
    named_streams(handle)?
        .iter()
        .try_fold(0u64, |total, stream| {
            total
                .checked_add(stream.size)
                .ok_or_else(|| anyhow::anyhow!("Stream size overflow"))
        })
}
pub fn named_streams(handle: HANDLE) -> Result<Vec<NamedStream>> {
    named_streams_bounded(handle, usize::MAX)
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn named_streams_bounded(handle: HANDLE, maximum: usize) -> Result<Vec<NamedStream>> {
    let mut size = 1024usize;
    loop {
        let mut buffer = vec![0u8; size];
        if unsafe {
            GetFileInformationByHandleEx(
                handle,
                FileStreamInfo,
                buffer.as_mut_ptr().cast(),
                size as u32,
            )
        } == 0
        {
            let error = std::io::Error::last_os_error();
            if matches!(error.raw_os_error(), Some(122 | 234)) && size < 8 * 1024 * 1024 {
                size *= 2;
                continue;
            }
            if error.raw_os_error() == Some(38) {
                return Ok(vec![]);
            }
            return Err(error.into());
        }
        let mut offset = 0;
        let mut streams = Vec::new();
        loop {
            if offset > size - 24 {
                bail!("Invalid stream information");
            }
            let next = u32::from_le_bytes(buffer[offset..offset + 4].try_into()?) as usize;
            let length = u32::from_le_bytes(buffer[offset + 4..offset + 8].try_into()?) as usize;
            let bytes = i64::from_le_bytes(buffer[offset + 8..offset + 16].try_into()?);
            if length % 2 != 0 || length > size - offset - 24 || bytes < 0 {
                bail!("Invalid stream information record");
            }
            let name = String::from_utf16(
                &buffer[offset + 24..offset + 24 + length]
                    .chunks_exact(2)
                    .map(|x| u16::from_le_bytes([x[0], x[1]]))
                    .collect::<Vec<_>>(),
            )?;
            if name != "::$DATA" {
                anyhow::ensure!(
                    streams.len() < maximum,
                    "Named-stream enumeration exceeds the reserved-tree stream-guard limit"
                );
                let name = name
                    .strip_prefix(':')
                    .and_then(|x| x.strip_suffix(":$DATA"))
                    .ok_or_else(|| anyhow::anyhow!("Unsupported named stream type"))?
                    .to_owned();
                validate_stream_name(&name)?;
                streams.push(NamedStream {
                    name,
                    size: bytes as u64,
                });
            }
            if next == 0 {
                streams.sort_by(|a, b| a.name.cmp(&b.name));
                return Ok(streams);
            }
            if next < 24 || next > size - offset {
                bail!("Invalid stream information offset");
            }
            offset += next;
        }
    }
}
pub fn validate_stream_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.encode_utf16().count() > 255
        || name
            .chars()
            // 制御文字はパス部品と同じくWin32の禁止範囲（NUL・U+0001〜U+001F）だけを拒否する。
            .any(|c| path::is_forbidden_name_control(c) || ":\\/*?\"<>|".contains(c))
    {
        bail!("Invalid named stream name");
    }
    Ok(())
}
pub fn open_hardlink_stream_guard(path: &Path, name: &str, execute: bool) -> Result<OwnedHandle> {
    validate_stream_name(name)?;
    let path = path::file_system_absolute(path)?;
    let name = wide(OsStr::new(&format!(
        "\\\\?\\{}:{name}:$DATA",
        path.display()
    )))?;
    unsafe {
        OwnedHandle::from_raw(CreateFileW(
            name.as_ptr(),
            if execute {
                FILE_READ_ATTRIBUTES | FILE_EXECUTE
            } else {
                FILE_READ_ATTRIBUTES | FILE_READ_DATA
            },
            FILE_SHARE_READ | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
            std::ptr::null_mut(),
        ))
    }
}
pub struct NamedMutex {
    handle: OwnedHandle,
    owner: bool,
}
impl Drop for NamedMutex {
    fn drop(&mut self) {
        if self.owner {
            unsafe {
                windows_sys::Win32::System::Threading::ReleaseMutex(self.handle.raw());
            }
        }
    }
}
pub fn acquire_named_mutex(name: &str, timeout_ms: u32) -> Result<NamedMutex> {
    unsafe {
        use windows_sys::Win32::System::Threading::*;
        let name = wide(OsStr::new(name))?;
        let handle = OwnedHandle::from_raw(CreateMutexW(std::ptr::null(), 0, name.as_ptr()))?;
        let result = WaitForSingleObject(handle.raw(), timeout_ms);
        if result != WAIT_OBJECT_0 && result != WAIT_ABANDONED {
            bail!("Cannot acquire named mutex (wait {result})");
        }
        Ok(NamedMutex {
            handle,
            owner: true,
        })
    }
}
pub struct EffectiveToken(OwnedHandle);
impl EffectiveToken {
    pub fn capture() -> Result<Self> {
        unsafe {
            use windows_sys::Win32::{Security::*, System::Threading::*};
            let mut raw = std::ptr::null_mut();
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
                if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &mut raw)
                    == 0
                {
                    return Err(std::io::Error::last_os_error().into());
                }
            }
            let original = OwnedHandle::from_raw(raw)?;
            let mut copy = std::ptr::null_mut();
            if DuplicateTokenEx(
                original.raw(),
                TOKEN_QUERY | TOKEN_IMPERSONATE,
                std::ptr::null(),
                SecurityImpersonation,
                TokenImpersonation,
                &mut copy,
            ) == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            Ok(Self(OwnedHandle::from_raw(copy)?))
        }
    }
    pub fn run<T>(&self, action: impl FnOnce() -> Result<T>) -> Result<T> {
        unsafe {
            use windows_sys::Win32::{Security::*, System::Threading::*};
            let mut previous = std::ptr::null_mut();
            let previous = if OpenThreadToken(
                GetCurrentThread(),
                TOKEN_IMPERSONATE | TOKEN_QUERY,
                1,
                &mut previous,
            ) != 0
            {
                Some(OwnedHandle::from_raw(previous)?)
            } else {
                let error = GetLastError();
                if error != ERROR_NO_TOKEN {
                    return Err(std::io::Error::from_raw_os_error(error as i32).into());
                }
                None
            };
            if SetThreadToken(std::ptr::null(), self.0.raw()) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            struct Restore(Option<OwnedHandle>);
            impl Drop for Restore {
                fn drop(&mut self) {
                    unsafe {
                        windows_sys::Win32::System::Threading::SetThreadToken(
                            std::ptr::null(),
                            self.0.as_ref().map_or(std::ptr::null_mut(), |x| x.raw()),
                        );
                    }
                }
            }
            let _restore = Restore(previous);
            action()
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixed_directory_empty_scan_keeps_validation_and_predicate_order() -> Result<()> {
        // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
        let temp = path::external_test_temp()?;
        let _parents = path::pin_directories(&temp)?;
        let root = temp.join(format!("directory-scan-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&root)?;
        let fixed = PinnedFile::open(&root, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, 3)?;
        assert!(directory_is_empty(fixed.raw())?);
        assert!(directory_names(fixed.raw())?.is_empty());
        for name in ["first.txt", "日本語😀.txt", "last.txt"] {
            std::fs::write(root.join(name), name.as_bytes())?;
        }
        assert!(!directory_is_empty(fixed.raw())?);
        let names = directory_names(fixed.raw())?;
        assert_eq!(names.len(), 3);
        let mut observed = Vec::new();
        assert!(!any_pinned_directory_name(fixed.raw(), |name| {
            observed.push(name.to_owned());
            false
        })?);
        assert_eq!(observed, names);
        let mut calls = 0;
        assert!(directory_is_empty(INVALID_HANDLE_VALUE).is_err());
        assert!(
            any_pinned_directory_name(INVALID_HANDLE_VALUE, |_| {
                calls += 1;
                true
            })
            .is_err()
        );
        assert_eq!(calls, 0);
        eprintln!("Retained directory enumeration fixture: {}", root.display());
        Ok(())
    }
    #[test]
    fn invariant_contract() {
        for (source, expected) in [
            ("ß", "ß"),
            ("ı", "ı"),
            ("ſ", "S"),
            ("ﬀ", "ﬀ"),
            ("ς", "Σ"),
            ("և", "և"),
            ("ᾀ", "ᾈ"),
            ("𐐨", "𐐀"),
        ] {
            assert_eq!(invariant_uppercase(source).unwrap(), expected);
        }
        assert!(ordinal_ignore_case("C:\\ſ\\ς", "c:\\S\\Σ"));
        assert!(!ordinal_ignore_case("ı", "I"));
    }
    #[test]
    fn local_path_contract() {
        for invalid in [
            "\\\\server\\share\\a",
            "C:\\a:stream",
            "C:\\a\\..\\b",
            "C:\\CON\\x",
            "C:\\a.\\x",
            "C:\\a\\\\b",
        ] {
            assert!(path::absolute(Path::new(invalid)).is_err(), "{invalid}");
        }
        assert!(path::file_delete_absolute(Path::new("C:\\a\\NUL.txt")).is_ok());
        assert!(!path::within(Path::new("C:\\abc"), Path::new("C:\\ab")));
        assert!(path::within(Path::new("C:\\ſ\\child"), Path::new("c:\\S")));
    }
}
pub fn read_plain_file(path: &Path, max_bytes: usize, reject_streams: bool) -> Result<Vec<u8>> {
    let actual = path::resolve(path, false, false)?;
    let parent = actual
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Missing input parent"))?;
    let _parents = path::pin_directories(parent)?;
    let fixed = PinnedFile::open(&actual, GENERIC_READ, FILE_SHARE_READ)?;
    let id = fixed.identity()?;
    if id.is_directory() || id.is_reparse() || id.links != 1 {
        bail!("Input must be a plain single-link file");
    }
    if reject_streams {
        reject_named_streams(&actual)?;
    }
    let mut bytes = Vec::new();
    let mut chunk = vec![0u8; 65536];
    loop {
        let mut count = 0;
        let ok = unsafe {
            windows_sys::Win32::Storage::FileSystem::ReadFile(
                fixed.raw(),
                chunk.as_mut_ptr(),
                chunk.len() as u32,
                &mut count,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        if count == 0 {
            break;
        }
        if bytes.len().saturating_add(count as usize) > max_bytes {
            bail!("Input file exceeds its byte limit");
        }
        bytes.extend_from_slice(&chunk[..count as usize]);
    }
    fixed.require_unchanged()?;
    fixed.verify_named()?;
    Ok(bytes)
}
pub fn write_new_plain_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let path = path::absolute(path)?;
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Missing output parent"))?;
    let _parents = path::pin_directories(parent)?;
    let handle = security::create_private_file(&path)?;
    write_handle(handle.raw(), bytes)?;
    Ok(())
}
#[expect(
    clippy::not_unsafe_ptr_arg_deref,
    reason = "HANDLEはOSが検証するopaque値であり、呼出元メモリを参照しない"
)]
pub fn write_handle(handle: HANDLE, bytes: &[u8]) -> Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        let mut count = 0;
        let n = (bytes.len() - offset).min(u32::MAX as usize);
        if unsafe {
            WriteFile(
                handle,
                bytes[offset..].as_ptr(),
                n as u32,
                &mut count,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        if count == 0 {
            bail!("Windows wrote no bytes");
        }
        offset += count as usize;
    }
    if unsafe { FlushFileBuffers(handle) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

#[cfg(test)]
mod shell_tests {
    use super::*;
    #[test]
    fn native_recycle_contract() -> Result<()> {
        // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
        let temp = path::external_test_temp()?;
        let _parents = path::pin_directories(&temp)?;
        let root = temp.join(format!("shell-recycle-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir(&root)?;
        let source = root.join("one-byte.dat");
        std::fs::write(&source, b"x")?;
        eprintln!("Native Shell fixture: {}", source.display());
        let original = PinnedFile::open(&source, FILE_READ_ATTRIBUTES, 7)?;
        let expected = original.identity()?;
        let result = recycle::recycle(
            &source,
            false,
            |physical| {
                if physical != source {
                    bail!("Unexpected physical source");
                }
                Ok(())
            },
            |destination| {
                let target = PinnedFile::open(destination, FILE_READ_ATTRIBUTES, 7)?;
                if !expected.same_object(&target.identity()?) {
                    bail!("Returned Shell identity mismatch");
                }
                Ok(())
            },
        )?;
        match result {
            recycle::RecycleOutcome::Recycled => {}
            recycle::RecycleOutcome::PermanentAllowed(Some(setting)) => {
                setting.revalidate(&source)?;
                assert!(source.exists());
                eprintln!(
                    "Native Shell confirmed unavailable recycling with immediate-delete setting; source retained, ordinary Bin roundtrip needs a recyclable fixture volume."
                );
            }
            recycle::RecycleOutcome::PermanentAllowed(None) => {
                assert!(source.exists());
                eprintln!(
                    "Native Shell confirmed size limitation; source retained, ordinary Bin roundtrip needs a recyclable fixture volume."
                );
            }
        }
        Ok(())
    }
}
