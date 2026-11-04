use super::{Args, build, common::*};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

#[derive(Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Item {
    sha256: String,
    bytes: u64,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    product: String,
    schema: u32,
    repository: String,
    default_branch: String,
    commit_sha: String,
    commit_verification: String,
    runtime: String,
    files: BTreeMap<String, Item>,
}
pub struct Verified {
    pub file: File,
    pub sha256: String,
    pub bytes: u64,
    pub _pins: Pins,
}

fn expected(args: &Args, pins: &mut Pins) -> Result<(Manifest, Vec<(String, File)>)> {
    let source = args.path("source")?;
    let publish = args.path("publish")?;
    output_path(&publish, &source)?;
    let provenance = build::verify_provenance(args, pins)?;
    let mut files = BTreeMap::new();
    let mut handles = Vec::new();
    for (name, path) in inputs(&source, &publish) {
        let mut file = pins.file(&path)?;
        let sha256 = hash(&mut file)?;
        if name.ends_with(".exe") {
            pe(
                &read(&mut file, MAX_ZIP)?,
                args.get("runtime")?,
                &provenance.version,
                args.get("commit")?,
            )?;
            let signature = authenticode(&mut file, &path)?;
            eprintln!("Authenticode {name}: {signature}");
            ensure!(
                provenance.products.get(name.strip_prefix("bin/").unwrap())
                    == Some(&sha256.to_lowercase()),
                "Product differs from build provenance."
            );
        }
        files.insert(
            name.clone(),
            Item {
                sha256,
                bytes: file.metadata()?.len(),
            },
        );
        handles.push((name, file));
    }
    ensure!(
        files["bin/prunlet.exe"].sha256 == files["bin/prunlet-hook.exe"].sha256,
        "Hook must match the CLI bytes."
    );
    Ok((
        Manifest {
            product: "Prunlet".into(),
            schema: 1,
            repository: args.get("repository")?.into(),
            default_branch: args.get("branch")?.into(),
            commit_sha: args.get("commit")?.into(),
            commit_verification: "caller-asserted".into(),
            runtime: args.get("runtime")?.into(),
            files,
        },
        handles,
    ))
}
fn package_path(args: &Args) -> Result<std::path::PathBuf> {
    let path = args.path("package")?;
    output_path(&path, &args.path("source")?)?;
    ensure!(
        !in_tree(&path, &args.path("publish")?),
        "ZIP must be outside the publish tree."
    );
    ensure!(
        path.extension()
            .is_some_and(|v| v.eq_ignore_ascii_case("zip")),
        "Package path must use .zip."
    );
    Ok(path)
}
pub fn create(args: &Args) -> Result<()> {
    let path = package_path(args)?;
    let mut pins = Pins::new();
    let (manifest, mut handles) = expected(args, &mut pins)?;
    let mut file = pins.new_file(&path)?;
    {
        let mut zip = ZipWriter::new(&mut file);
        let options = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .unix_permissions(0o644);
        zip.start_file("package.json", options)?;
        zip.write_all(&serde_json::to_vec(&manifest)?)?;
        for (name, input) in &mut handles {
            zip.start_file(name.as_str(), options)?;
            std::io::copy(input, &mut zip)?;
        }
        zip.finish()?;
    }
    file.sync_all()?;
    ensure!(
        file.metadata()?.len() <= MAX_ZIP,
        "ZIP exceeds the updater limit; incomplete output retained."
    );
    let sha256 = hash(&mut file)?;
    drop(file);
    // 同じ製品経路で最終ZIP全体と各memberを再照合する。
    let verified = verify(args)?;
    ensure!(verified.sha256 == sha256, "Package changed after creation.");
    println!(
        "{}",
        json!({"status":"created","path":path,"sha256":sha256,"commitSha":args.get("commit")?,"commitVerification":"caller-asserted","runtime":args.get("runtime")?,"verified":true})
    );
    Ok(())
}
pub fn verify(args: &Args) -> Result<Verified> {
    let path = package_path(args)?;
    let mut pins = Pins::new();
    let (expected, _handles) = expected(args, &mut pins)?;
    let mut file = pins.file(&path)?;
    let bytes = file.metadata()?.len();
    ensure!(bytes > 0 && bytes <= MAX_ZIP, "Invalid package size.");
    let sha256 = hash(&mut file)?;
    // updaterと同じraw属性・展開上限・重複JSONの検証も通す。
    drop(super::update_package::VerifiedPackage::open(
        &mut file,
        args.get("repository")?,
        args.get("branch")?,
        args.get("commit")?,
        args.get("runtime")?,
        &sha256,
        bytes,
    )?);
    file.seek(SeekFrom::Start(0))?;
    {
        let mut zip = ZipArchive::new(&mut file)?;
        ensure!(
            zip.len() == NAMES.len() + 1,
            "Package must contain exactly 12 payloads and package.json."
        );
        let mut names = BTreeSet::new();
        for index in 0..zip.len() {
            let entry = zip.by_index(index)?;
            let name = entry.name()?;
            ensure!(
                (name == "package.json" || NAMES.contains(&name.as_ref()))
                    && names.insert(name.to_lowercase())
                    && !entry.is_dir()
                    && !entry.encrypted(),
                "Invalid or duplicate package entry."
            );
        }
        let manifest: Manifest = {
            let mut entry = zip.by_name("package.json")?;
            ensure!(
                entry.size() > 0 && entry.size() <= 65536,
                "Invalid package metadata size."
            );
            let mut raw = Vec::new();
            entry.read_to_end(&mut raw)?;
            serde_json::from_slice(&raw).context("Invalid package metadata.")?
        };
        ensure!(
            manifest.product == expected.product
                && manifest.schema == expected.schema
                && manifest.repository == expected.repository
                && manifest.default_branch == expected.default_branch
                && manifest.commit_sha == expected.commit_sha
                && manifest.commit_verification == expected.commit_verification
                && manifest.runtime == expected.runtime
                && manifest.files == expected.files,
            "Package metadata differs from release inputs."
        );
        for (name, item) in expected.files {
            let mut entry = zip.by_name(&name)?;
            ensure!(
                entry.size() == item.bytes && item.bytes <= MAX_ZIP,
                "Package member size differs."
            );
            use sha2::{Digest, Sha256};
            let mut hash = Sha256::new();
            let mut total = 0u64;
            let mut buffer = [0u8; 65536];
            loop {
                let n = entry.read(&mut buffer)?;
                if n == 0 {
                    break;
                }
                total += n as u64;
                ensure!(
                    total <= item.bytes,
                    "Expanded member exceeds expected size."
                );
                hash.update(&buffer[..n]);
            }
            ensure!(
                total == item.bytes && hex::encode_upper(hash.finalize()) == item.sha256,
                "Package member hash differs."
            );
        }
    }
    file.seek(SeekFrom::Start(0))?;
    build::verify_git_source(args, &mut pins)?;
    Ok(Verified {
        file,
        sha256,
        bytes,
        _pins: pins,
    })
}
