//! Windows公開パッケージ。呼出元が認証したZIP全体のhash・長さを信頼境界にする。
use std::io::{Read, Seek, SeekFrom};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use zip::ZipArchive;

pub const MAX_ARCHIVE_BYTES: u64 = 512 * 1024 * 1024;
pub const PRODUCT_NAMES: [&str; 12] = [
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

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Product {
    pub name: String,
    pub sha256: String,
    pub bytes: u64,
}

pub struct VerifiedPackage<R: Read + Seek> {
    archive: ZipArchive<R>,
    pub products: Vec<Product>,
}

pub fn is_hex(value: &str, count: usize) -> bool {
    value.len() == count && value.bytes().all(|c| c.is_ascii_hexdigit())
}

fn exact_object<'a>(
    value: &'a Value,
    names: &[&str],
) -> Result<&'a serde_json::Map<String, Value>> {
    let object = value
        .as_object()
        .context("Package metadata field must be an object.")?;
    ensure!(
        object.len() == names.len() && names.iter().all(|n| object.contains_key(*n)),
        "Package metadata has unknown or missing fields."
    );
    Ok(object)
}

fn hash_reader(mut reader: impl Read, limit: u64) -> Result<(String, u64)> {
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 128 * 1024];
    let mut bytes = 0u64;
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        bytes = bytes
            .checked_add(n as u64)
            .context("Package byte count overflow.")?;
        ensure!(
            bytes <= limit,
            "Package entry exceeds its allowed expanded size."
        );
        digest.update(&buffer[..n]);
    }
    Ok((hex::encode_upper(digest.finalize()), bytes))
}

impl<R: Read + Seek> VerifiedPackage<R> {
    /// readerは呼出元が親directory・単一link・named streamを検査して保持した実体。
    pub fn open(
        mut reader: R,
        repository: &str,
        _branch: &str,
        commit: &str,
        runtime: &str,
        sha256: &str,
        bytes: u64,
    ) -> Result<Self> {
        ensure!(
            is_hex(commit, 40) && is_hex(sha256, 64) && bytes > 0 && bytes <= MAX_ARCHIVE_BYTES,
            "Authenticated package identity is invalid."
        );
        ensure!(
            matches!(runtime, "win-x64" | "win-arm64"),
            "Unsupported Windows package runtime."
        );
        ensure!(
            reader.seek(SeekFrom::End(0))? == bytes,
            "Package byte length differs from the authenticated value."
        );
        reader.rewind()?;
        let (actual, count) = hash_reader(&mut reader, bytes)?;
        ensure!(
            count == bytes && actual.eq_ignore_ascii_case(sha256),
            "Package hash differs from the authenticated value."
        );
        reader.rewind()?;
        let archive = ZipArchive::new(reader)?;
        // zip crateのunix_modeはWindows属性を正規化するため、rawのreparse bitも検査する。
        let central = archive.central_directory_start();
        let count = archive.len();
        let mut reader = archive.into_inner();
        verify_raw_attributes(&mut reader, central, count)?;
        reader.rewind()?;
        let mut archive = ZipArchive::new(reader)?;
        ensure!(
            archive.len() == PRODUCT_NAMES.len() + 1,
            "Release package contains an unexpected number of entries."
        );
        let mut names = std::collections::HashSet::new();
        for index in 0..archive.len() {
            let entry = archive.by_index(index)?;
            let entry_name = entry.name()?;
            ensure!(
                (PRODUCT_NAMES.contains(&entry_name.as_ref()) || entry_name == "package.json")
                    && names.insert(entry_name.to_ascii_lowercase()),
                "Release package contains an unsupported or duplicate entry."
            );
            // ZIP外部属性のWindows reparse flagもunix symlinkも受け入れない。
            let mode = entry.unix_mode().unwrap_or(0);
            ensure!(
                matches!(mode & 0xf000, 0 | 0x8000) && !entry.is_dir() && !entry.is_symlink(),
                "Release package contains a linked or non-file entry."
            );
        }
        let metadata = {
            let mut entry = archive.by_name("package.json")?;
            ensure!(
                entry.size() > 0 && entry.size() <= 65536,
                "Package metadata is too large or empty."
            );
            let mut buffer = Vec::new();
            (&mut entry).take(65537).read_to_end(&mut buffer)?;
            ensure!(
                buffer.len() <= 65536,
                "Package metadata exceeds its allowed size."
            );
            crate::json::parse_unique(&buffer)?
        };
        exact_object(
            &metadata,
            &[
                "product",
                "schema",
                "repository",
                "defaultBranch",
                "commitSha",
                "commitVerification",
                "runtime",
                "files",
            ],
        )?;
        let recorded_branch = metadata["defaultBranch"].as_str().unwrap_or("");
        ensure!(
            metadata["product"] == "Prunlet"
                && metadata["schema"].as_u64() == Some(1)
                && metadata["repository"]
                    .as_str()
                    .is_some_and(|v| v.eq_ignore_ascii_case(repository))
                && !recorded_branch.is_empty()
                && !recorded_branch.contains("..")
                && !recorded_branch.starts_with('/')
                && !recorded_branch.ends_with('/')
                && recorded_branch
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"._/-".contains(&c))
                && metadata["commitSha"]
                    .as_str()
                    .is_some_and(|v| v.eq_ignore_ascii_case(commit))
                && metadata["runtime"] == runtime
                && metadata["commitVerification"] == "caller-asserted",
            "Package metadata does not match the authenticated release identity."
        );
        exact_object(&metadata["files"], &PRODUCT_NAMES)?;
        let mut products = Vec::new();
        let mut total = 0u64;
        for name in PRODUCT_NAMES {
            let item = &metadata["files"][name];
            exact_object(item, &["sha256", "bytes"])?;
            let hash = item["sha256"]
                .as_str()
                .context("Package product hash is invalid.")?;
            let bytes = item["bytes"]
                .as_u64()
                .context("Package product size is invalid.")?;
            let limit = if name.ends_with(".exe") {
                256 * 1024 * 1024
            } else {
                4 * 1024 * 1024
            };
            ensure!(
                is_hex(hash, 64) && bytes > 0 && bytes <= limit,
                "Package product has an invalid hash or size: {name}"
            );
            total = total
                .checked_add(bytes)
                .context("Package expanded size overflow.")?;
            ensure!(
                total <= 1024 * 1024 * 1024,
                "Package expanded size exceeds its limit."
            );
            let mut entry = archive.by_name(name)?;
            ensure!(
                entry.size() == bytes,
                "Package entry size differs from metadata: {name}"
            );
            let (actual, count) = hash_reader(&mut entry, limit)?;
            ensure!(
                count == bytes && actual.eq_ignore_ascii_case(hash),
                "Package product contents differ from metadata: {name}"
            );
            drop(entry);
            if name.ends_with(".exe") {
                verify_machine(archive.by_name(name)?, bytes, runtime)?;
            }
            products.push(Product {
                name: name.into(),
                sha256: actual,
                bytes,
            });
        }
        ensure!(
            products[0].sha256 == products[2].sha256,
            "Hook executable does not match the CLI executable."
        );
        Ok(Self { archive, products })
    }

    pub fn open_product(&mut self, name: &str) -> Result<impl Read + '_> {
        ensure!(PRODUCT_NAMES.contains(&name), "Unknown published product.");
        Ok(self.archive.by_name(name)?)
    }
}

fn verify_raw_attributes(reader: &mut (impl Read + Seek), offset: u64, count: usize) -> Result<()> {
    ensure!(
        count == PRODUCT_NAMES.len() + 1,
        "Unexpected package entry count."
    );
    reader.seek(SeekFrom::Start(offset))?;
    for _ in 0..count {
        let mut header = [0u8; 46];
        reader.read_exact(&mut header)?;
        ensure!(
            &header[..4] == b"PK\x01\x02",
            "Invalid ZIP central directory."
        );
        let attrs = u32::from_le_bytes(header[38..42].try_into().unwrap());
        ensure!(
            attrs & 0x400 == 0 && matches!((attrs >> 16) & 0xf000, 0 | 0x8000),
            "Release package contains a linked or non-file entry."
        );
        let skip = [28usize, 30, 32]
            .into_iter()
            .map(|n| u16::from_le_bytes([header[n], header[n + 1]]) as u64)
            .sum::<u64>();
        reader.seek(SeekFrom::Current(skip as i64))?;
    }
    Ok(())
}

fn verify_machine(mut input: impl Read, bytes: u64, runtime: &str) -> Result<()> {
    ensure!(bytes >= 64, "Package executable has no DOS header.");
    let mut header = [0u8; 64];
    input.read_exact(&mut header)?;
    ensure!(
        &header[..2] == b"MZ",
        "Package executable has no DOS header."
    );
    let offset = u32::from_le_bytes(header[60..64].try_into().unwrap()) as u64;
    ensure!(
        (64..=1024 * 1024).contains(&offset) && offset <= bytes.saturating_sub(6),
        "Package executable PE offset is invalid."
    );
    let skipped = std::io::copy(&mut input.by_ref().take(offset - 64), &mut std::io::sink())?;
    ensure!(
        skipped == offset - 64,
        "Package executable PE offset exceeds entry contents."
    );
    let mut pe = [0u8; 6];
    input.read_exact(&mut pe)?;
    let expected = match runtime {
        "win-x64" => 0x8664,
        "win-arm64" => 0xaa64,
        _ => bail!("Unsupported runtime."),
    };
    ensure!(
        &pe[..4] == b"PE\0\0" && u16::from_le_bytes([pe[4], pe[5]]) == expected,
        "Package executable architecture differs from its runtime."
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};
    use zip::{ZipWriter, write::SimpleFileOptions};
    const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";
    fn package(machine: u16) -> Vec<u8> {
        let mut executable = vec![0u8; 70];
        executable[..2].copy_from_slice(b"MZ");
        executable[60..64].copy_from_slice(&64u32.to_le_bytes());
        executable[64..68].copy_from_slice(b"PE\0\0");
        executable[68..70].copy_from_slice(&machine.to_le_bytes());
        let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
        let mut files = serde_json::Map::new();
        for name in PRODUCT_NAMES {
            let bytes = if name.ends_with(".exe") {
                executable.as_slice()
            } else {
                b"fixture auxiliary"
            };
            zip.start_file(name, SimpleFileOptions::default()).unwrap();
            zip.write_all(bytes).unwrap();
            files.insert(name.into(), serde_json::json!({"sha256":hex::encode_upper(Sha256::digest(bytes)),"bytes":bytes.len()}));
        }
        zip.start_file("package.json", SimpleFileOptions::default())
            .unwrap();
        zip.write_all(&serde_json::to_vec(&serde_json::json!({
            "product":"Prunlet","schema":1,"repository":"owner/Prunlet","defaultBranch":"main",
            "commitSha":COMMIT,"commitVerification":"caller-asserted","runtime":"win-x64","files":files,
        })).unwrap()).unwrap();
        zip.finish().unwrap().into_inner()
    }
    fn verify(bytes: Vec<u8>) -> Result<VerifiedPackage<Cursor<Vec<u8>>>> {
        let hash = hex::encode_upper(Sha256::digest(&bytes));
        let size = bytes.len() as u64;
        VerifiedPackage::open(
            Cursor::new(bytes),
            "owner/Prunlet",
            "main",
            COMMIT,
            "win-x64",
            &hash,
            size,
        )
    }
    #[test]
    fn real_zip_validates_all_products_and_authenticated_identity() {
        let bytes = package(0x8664);
        let mut package = verify(bytes.clone()).unwrap();
        assert_eq!(package.products.len(), 12);
        let mut product = Vec::new();
        package
            .open_product("bin/prunlet.exe")
            .unwrap()
            .read_to_end(&mut product)
            .unwrap();
        assert_eq!(product.len(), 70);
        // 既存形式はbranch名の形式だけを検証する。改名後も過去ZIPを受け入れる。
        assert!(
            VerifiedPackage::open(
                Cursor::new(bytes.clone()),
                "owner/Prunlet",
                "renamed-branch",
                COMMIT,
                "win-x64",
                &hex::encode(Sha256::digest(&bytes)),
                bytes.len() as u64
            )
            .is_ok()
        );
        assert!(
            VerifiedPackage::open(
                Cursor::new(bytes.clone()),
                "owner/Prunlet",
                "main",
                COMMIT,
                "win-x64",
                &"0".repeat(64),
                bytes.len() as u64
            )
            .is_err()
        );
        assert!(
            VerifiedPackage::open(
                Cursor::new(bytes.clone()),
                "owner/Prunlet",
                "main",
                COMMIT,
                "osx-arm64",
                &hex::encode(Sha256::digest(&bytes)),
                bytes.len() as u64
            )
            .is_err()
        );
    }
    #[test]
    fn windows_reparse_attribute_and_wrong_architecture_are_rejected() {
        assert!(verify(package(0xaa64)).is_err());
        let mut bytes = package(0x8664);
        let central = ZipArchive::new(Cursor::new(&bytes))
            .unwrap()
            .central_directory_start() as usize;
        let attrs =
            u32::from_le_bytes(bytes[central + 38..central + 42].try_into().unwrap()) | 0x400;
        bytes[central + 38..central + 42].copy_from_slice(&attrs.to_le_bytes());
        assert!(verify(bytes).is_err());
    }
}
