use anyhow::{Context, Result, ensure};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    os::windows::{ffi::OsStrExt, fs::OpenOptionsExt, io::AsRawHandle},
    path::{Component, Path, PathBuf},
};
use windows_sys::Win32::Storage::FileSystem::{
    BY_HANDLE_FILE_INFORMATION, FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS,
    FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ, FILE_SHARE_WRITE, GetFileInformationByHandle,
};

pub const NAMES: [&str; 12] = [
    "bin/prunlet.exe",
    "bin/prunlet-maintenance.exe",
    "bin/prunlet-hook.exe",
    "bin/Install-Prunlet.ps1",
    "bin/start-prunlet-mcp.ps1",
    "bin/configuration-common.ps1",
    "bin/maintenance-task.ps1",
    "bin/uninstall-maintenance.ps1",
    "bin/install-codex.ps1",
    "bin/uninstall-codex.ps1",
    "bin/install-agent-instructions.ps1",
    "bin/PRUNLET.md",
];
pub const MAX_ZIP: u64 = 512 * 1024 * 1024;

pub fn absolute(value: &str) -> Result<PathBuf> {
    let bytes = value.as_bytes();
    ensure!(
        bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'\\' | b'/')
            && !value[2..].contains(':'),
        "Expected an absolute local-drive path without alternate streams."
    );
    let path = PathBuf::from(value);
    ensure!(
        !path
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir)),
        "Path cannot contain relative components."
    );
    Ok(path)
}

pub fn in_tree(path: &Path, root: &Path) -> bool {
    let path = path.to_string_lossy().replace('/', "\\").to_lowercase();
    let root = root
        .to_string_lossy()
        .replace('/', "\\")
        .trim_end_matches('\\')
        .to_lowercase();
    path == root || path.starts_with(&(root + "\\"))
}

pub fn output_path(path: &Path, source: &Path) -> Result<()> {
    ensure!(
        !in_tree(path, source),
        "Outputs must be outside the source tree."
    );
    for home in [
        std::env::var_os("CODEX_HOME").map(PathBuf::from),
        std::env::var_os("USERPROFILE").map(|v| PathBuf::from(v).join(".codex")),
    ]
    .into_iter()
    .flatten()
    {
        ensure!(!in_tree(path, &home), "Outputs must be outside Codex home.");
    }
    Ok(())
}

#[derive(Default)]
pub struct Pins {
    directories: BTreeMap<PathBuf, File>,
    retained: Vec<File>,
}
impl Pins {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn directory(&mut self, path: &Path) -> Result<()> {
        if self.directories.contains_key(path) {
            return Ok(());
        }
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            self.directory(parent)?;
        }
        let handle = OpenOptions::new()
            .access_mode(0x80)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)
            .with_context(|| format!("Cannot pin directory: {}", path.display()))?;
        let info = info(&handle)?;
        ensure!(
            info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT == 0
                && info.dwFileAttributes & 0x10 != 0,
            "Directory cannot be a reparse point or wrong type."
        );
        self.directories.insert(path.to_owned(), handle);
        Ok(())
    }
    pub fn create_directory(&mut self, path: &Path) -> Result<()> {
        if path.exists() {
            return self.directory(path);
        }
        self.create_directory(path.parent().context("Directory requires a parent.")?)?;
        std::fs::create_dir(path)?;
        self.directory(path)
    }
    pub fn file(&mut self, path: &Path) -> Result<File> {
        self.directory(path.parent().context("Input requires a parent.")?)?;
        let handle = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)
            .with_context(|| format!("Cannot pin input: {}", path.display()))?;
        let info = info(&handle)?;
        ensure!(
            info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | 0x10) == 0
                && info.nNumberOfLinks == 1,
            "Input must be a plain, singly linked file."
        );
        self.retained.push(handle.try_clone()?);
        Ok(handle)
    }
    pub fn new_file(&mut self, path: &Path) -> Result<File> {
        self.directory(path.parent().context("Output requires a parent.")?)?;
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .context("Output filename must be Unicode.")?;
        ensure!(
            !regex::Regex::new(r"(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)")?.is_match(name),
            "Output cannot use a Windows device name."
        );
        Ok(OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .share_mode(0)
            .open(path)?)
    }
}

fn info(file: &File) -> Result<BY_HANDLE_FILE_INFORMATION> {
    let mut value = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { GetFileInformationByHandle(file.as_raw_handle().cast(), &mut value) } != 0,
        "Cannot inspect pinned input."
    );
    Ok(value)
}

pub fn digest(bytes: &[u8]) -> String {
    hex::encode_upper(Sha256::digest(bytes))
}
pub fn hash(file: &mut File) -> Result<String> {
    file.seek(SeekFrom::Start(0))?;
    let mut state = Sha256::new();
    let mut block = [0u8; 65536];
    loop {
        let n = file.read(&mut block)?;
        if n == 0 {
            break;
        }
        state.update(&block[..n]);
    }
    file.seek(SeekFrom::Start(0))?;
    Ok(hex::encode_upper(state.finalize()))
}
pub fn read(file: &mut File, limit: u64) -> Result<Vec<u8>> {
    ensure!(
        file.metadata()?.len() <= limit,
        "Input exceeds its size limit."
    );
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "Input exceeds its size limit.");
    file.seek(SeekFrom::Start(0))?;
    Ok(bytes)
}
pub fn write_json(file: &mut File, value: &impl serde::Serialize) -> Result<()> {
    serde_json::to_writer_pretty(&mut *file, value)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}
pub fn inputs(source: &Path, publish: &Path) -> Vec<(String, PathBuf)> {
    NAMES
        .iter()
        .map(|name| {
            let leaf = name.strip_prefix("bin/").unwrap();
            let path = if leaf.ends_with(".exe") {
                publish.join(leaf)
            } else if leaf == "Install-Prunlet.ps1" {
                source.join("scripts").join(leaf)
            } else {
                source.join("integration").join(leaf)
            };
            ((*name).to_owned(), path)
        })
        .collect()
}

pub fn cargo_version(source: &Path, pins: &mut Pins) -> Result<String> {
    let bytes = read(&mut pins.file(&source.join("Cargo.toml"))?, 1024 * 1024)?;
    let text = std::str::from_utf8(&bytes)?;
    let section = text
        .split("[package]")
        .nth(1)
        .context("Missing Cargo package.")?
        .split("\n[")
        .next()
        .unwrap();
    Ok(
        regex::Regex::new(r#"(?m)^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$"#)?
            .captures(section)
            .context("Unsupported Cargo version.")?[1]
            .to_owned(),
    )
}

// VERSIONINFOは固定したPEのresource treeから読む。別のpath openや実行に頼らない。
pub fn pe(bytes: &[u8], runtime: &str, version: &str, commit: &str) -> Result<()> {
    fn u16_at(b: &[u8], n: usize) -> Result<u16> {
        Ok(u16::from_le_bytes(
            b.get(n..n + 2).context("Truncated PE.")?.try_into()?,
        ))
    }
    fn u32_at(b: &[u8], n: usize) -> Result<u32> {
        Ok(u32::from_le_bytes(
            b.get(n..n + 4).context("Truncated PE.")?.try_into()?,
        ))
    }
    ensure!(bytes.get(..2) == Some(b"MZ"), "Not a PE image.");
    let header = u32_at(bytes, 0x3c)? as usize;
    ensure!(
        bytes.get(header..header + 4) == Some(b"PE\0\0"),
        "Invalid PE signature."
    );
    ensure!(
        u16_at(bytes, header + 4)? == if runtime == "win-x64" { 0x8664 } else { 0xaa64 },
        "PE architecture differs."
    );
    let optional = header + 24;
    ensure!(u16_at(bytes, optional)? == 0x20b, "Expected PE32+.");
    let resource_rva = u32_at(bytes, optional + 128)? as usize;
    let sections = optional + u16_at(bytes, header + 20)? as usize;
    let mut root = None;
    for n in 0..u16_at(bytes, header + 6)? as usize {
        let section = sections + n * 40;
        let va = u32_at(bytes, section + 12)? as usize;
        let size = u32_at(bytes, section + 16)? as usize;
        if resource_rva >= va && resource_rva - va < size {
            root = Some((
                u32_at(bytes, section + 20)? as usize + resource_rva - va,
                va,
                u32_at(bytes, section + 20)? as usize,
            ));
            break;
        }
    }
    let (base, section_va, section_raw) = root.context("Missing PE resource section.")?;
    let mut directory = base;
    for level in 0..3 {
        let named = u16_at(bytes, directory + 12)? as usize;
        let count = named + u16_at(bytes, directory + 14)? as usize;
        let mut selected = None;
        for n in 0..count {
            let entry = directory + 16 + n * 8;
            if (level == 0 && u32_at(bytes, entry)? != 16) || (level != 0 && n != 0) {
                continue;
            }
            selected = Some(u32_at(bytes, entry + 4)?);
            break;
        }
        let target = selected.context("Missing PE VERSIONINFO.")?;
        ensure!(
            (target & 0x80000000 != 0) == (level < 2),
            "Invalid PE resource hierarchy."
        );
        directory = base + (target & 0x7fffffff) as usize;
    }
    let data_rva = u32_at(bytes, directory)? as usize;
    let size = u32_at(bytes, directory + 4)? as usize;
    let offset = section_raw
        .checked_add(
            data_rva
                .checked_sub(section_va)
                .context("Invalid VERSIONINFO RVA.")?,
        )
        .context("Invalid VERSIONINFO offset.")?;
    let resource = bytes
        .get(offset..offset.checked_add(size).context("VERSIONINFO overflow.")?)
        .context("Truncated VERSIONINFO.")?;
    let key: Vec<u8> = "ProductVersion\0"
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    let mut matches = Vec::new();
    for index in (6..resource.len().saturating_sub(key.len())).step_by(2) {
        if resource.get(index..index + key.len()) != Some(&key) {
            continue;
        }
        let start = (index + key.len() + 3) & !3;
        let length = u16_at(resource, index - 4)? as usize;
        ensure!(
            u16_at(resource, index - 2)? == 1,
            "Invalid ProductVersion type."
        );
        let raw = resource
            .get(start..start + length * 2)
            .context("Truncated ProductVersion.")?;
        let value = String::from_utf16(
            &raw.chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect::<Vec<_>>(),
        )?;
        matches.push(value.trim_end_matches('\0').to_owned());
    }
    ensure!(
        matches.len() == 1 && matches[0] == format!("{version}+{commit}"),
        "PE ProductVersion or source commit differs."
    );
    Ok(())
}

// WinTrustへ同じ固定handleを渡し、未署名と署名破損を証明書tableでも区別する。
pub fn authenticode(file: &mut File, path: &Path) -> Result<&'static str> {
    #[repr(C)]
    struct Guid {
        a: u32,
        b: u16,
        c: u16,
        d: [u8; 8],
    }
    #[repr(C)]
    struct FileInfo {
        size: u32,
        path: *const u16,
        file: *mut std::ffi::c_void,
        subject: *const Guid,
    }
    #[repr(C)]
    struct TrustData {
        size: u32,
        policy: *mut std::ffi::c_void,
        sip: *mut std::ffi::c_void,
        ui: u32,
        revocation: u32,
        choice: u32,
        file: *mut FileInfo,
        action: u32,
        state: *mut std::ffi::c_void,
        url: *const u16,
        flags: u32,
        context: u32,
        signatures: *mut std::ffi::c_void,
    }
    #[link(name = "wintrust")]
    unsafe extern "system" {
        fn WinVerifyTrust(
            window: *mut std::ffi::c_void,
            action: *const Guid,
            data: *mut TrustData,
        ) -> i32;
    }
    let bytes = read(file, MAX_ZIP)?;
    let header = bytes.get(0x3c..0x40).context("Missing PE header.")?;
    let offset = u32::from_le_bytes(header.try_into()?) as usize + 24 + 144;
    let certificate = bytes
        .get(offset..offset + 8)
        .context("Missing PE certificate directory.")?;
    let has_certificate = certificate.iter().any(|v| *v != 0);
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut file_info = FileInfo {
        size: std::mem::size_of::<FileInfo>() as u32,
        path: wide.as_ptr(),
        file: file.as_raw_handle().cast(),
        subject: std::ptr::null(),
    };
    let mut data = TrustData {
        size: std::mem::size_of::<TrustData>() as u32,
        policy: std::ptr::null_mut(),
        sip: std::ptr::null_mut(),
        ui: 2,
        revocation: 1,
        choice: 1,
        file: &mut file_info,
        action: 1,
        state: std::ptr::null_mut(),
        url: std::ptr::null(),
        flags: 0x80,
        context: 0,
        signatures: std::ptr::null_mut(),
    };
    let action = Guid {
        a: 0x00aac56b,
        b: 0xcd44,
        c: 0x11d0,
        d: [0x8c, 0xc2, 0x00, 0xc0, 0x4f, 0xc2, 0x95, 0xee],
    };
    let status = unsafe { WinVerifyTrust((-1isize) as *mut _, &action, &mut data) };
    data.action = 2;
    unsafe {
        WinVerifyTrust((-1isize) as *mut _, &action, &mut data);
    }
    file.seek(SeekFrom::Start(0))?;
    match status as u32 {
        0 => Ok("Valid"),
        0x800b0100 if !has_certificate => Ok("NotSigned"),
        value => anyhow::bail!(
            "Authenticode validation rejected {} (status=0x{value:08X}).",
            path.display()
        ),
    }
}
