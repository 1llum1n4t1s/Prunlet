//! 配布tar.gzの2ファイルを検査し、パスへの展開は行わない。
use crate::json::parse_unique;
use anyhow::{Context, Result, ensure};
use flate2::bufread::GzDecoder;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::io::Read;

pub(super) const MAX_PACKAGE: u64 = 64 * 1024 * 1024;
const BLOCK: usize = 512;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: String,
    commit: String,
    runtime: String,
    bytes: u64,
    sha256: String,
}

pub(super) fn executable(
    package: &[u8],
    version: &str,
    commit: &str,
    runtime: &str,
) -> Result<Vec<u8>> {
    ensure!(
        package.len() as u64 <= MAX_PACKAGE,
        "Linux archive exceeds its capacity limit"
    );
    let mut gzip = GzDecoder::new(package);
    // GNU tarのゼロpaddingと2個のheader分を含め、展開量も制限する。
    let limit = MAX_PACKAGE + 32 * 1024;
    let mut bytes = Vec::new();
    gzip.by_ref().take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= limit && gzip.into_inner().is_empty(),
        "Invalid Linux gzip stream"
    );
    let mut archive = bytes.as_slice();
    let exe = entry(&mut archive, b"prunlet", MAX_PACKAGE as usize)?;
    let manifest: Manifest =
        serde_json::from_value(parse_unique(entry(&mut archive, b"manifest.json", 4096)?)?)?;
    ensure!(
        archive.len() >= 2 * BLOCK
            && archive.len() % BLOCK == 0
            && archive.iter().all(|&byte| byte == 0),
        "Unexpected entries or trailer in Linux archive"
    );
    ensure!(
        manifest.version == version && manifest.commit == commit && manifest.runtime == runtime,
        "Linux package manifest identity differs"
    );
    ensure!(
        manifest.bytes == exe.len() as u64 && manifest.sha256 == hex::encode(Sha256::digest(exe)),
        "Linux executable hash or length differs"
    );
    let machine = if cfg!(target_arch = "x86_64") {
        [62, 0]
    } else {
        [183, 0]
    };
    ensure!(
        exe.len() >= 64
            && exe[..7] == [0x7f, b'E', b'L', b'F', 2, 1, 1]
            && matches!(exe[16..18], [2, 0] | [3, 0])
            && exe[18..20] == machine
            && exe[20..24] == [1, 0, 0, 0],
        "Linux executable has the wrong ELF format or CPU"
    );
    Ok(exe.to_vec())
}

fn entry<'a>(archive: &mut &'a [u8], name: &[u8], maximum: usize) -> Result<&'a [u8]> {
    let (header, rest) = archive
        .split_at_checked(BLOCK)
        .context("Missing tar header")?;
    ensure!(
        header[..100]
            .strip_prefix(name)
            .is_some_and(|suffix| suffix.iter().all(|&byte| byte == 0))
            && header[257..265] == *b"ustar\x0000"
            && matches!(header[156], 0 | b'0')
            && header[157..257]
                .iter()
                .chain(&header[345..])
                .all(|&byte| byte == 0),
        "Unexpected Linux tar entry"
    );
    let checksum = header
        .iter()
        .enumerate()
        .map(|(index, &byte)| {
            usize::from(if (148..156).contains(&index) {
                b' '
            } else {
                byte
            })
        })
        .sum::<usize>();
    ensure!(
        number(&header[148..156])? == checksum,
        "Invalid Linux tar checksum"
    );
    let size = number(&header[124..136])?;
    ensure!(
        (1..=maximum).contains(&size),
        "Linux tar entry exceeds its capacity limit"
    );
    let (data, tail) = rest
        .split_at_checked(size)
        .context("Truncated Linux tar entry")?;
    let padding = (BLOCK - size % BLOCK) % BLOCK;
    let (padding, remainder) = tail
        .split_at_checked(padding)
        .context("Truncated Linux tar padding")?;
    ensure!(
        padding.iter().all(|&byte| byte == 0),
        "Invalid Linux tar padding"
    );
    *archive = remainder;
    Ok(data)
}

fn number(field: &[u8]) -> Result<usize> {
    let text = std::str::from_utf8(field)?.trim_matches(['\0', ' ']);
    ensure!(
        !text.is_empty() && text.bytes().all(|byte| matches!(byte, b'0'..=b'7')),
        "Invalid Linux tar number"
    );
    Ok(usize::from_str_radix(text, 8)?)
}
