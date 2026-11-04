use super::{Args, common::*};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::File,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub path: String,
    pub sha256: String,
}
#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EnvironmentInput {
    path: PathBuf,
    exists: bool,
    sha256: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Provenance {
    pub schema: u32,
    pub source_commit: String,
    pub runtime: String,
    pub version: String,
    pub source_fingerprint: String,
    pub source_fingerprint_algorithm: String,
    pub sources: Vec<Source>,
    pub cargo_environment_inputs: Vec<EnvironmentInput>,
    pub products: BTreeMap<String, String>,
    pub toolchain: String,
    pub cargo_version: String,
    pub target: String,
    pub profile: String,
    pub rustflags: Vec<String>,
    pub profile_overrides: BTreeMap<String, String>,
}

fn walk(source: &Path, path: &Path, names: &mut Vec<String>, pins: &mut Pins) -> Result<()> {
    pins.directory(path)?;
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let metadata = std::fs::symlink_metadata(entry.path())?;
        use std::os::windows::fs::MetadataExt;
        ensure!(
            metadata.file_attributes() & 0x400 == 0,
            "Build inputs cannot be reparse points."
        );
        if metadata.is_dir() {
            walk(source, &entry.path(), names, pins)?;
        } else {
            names.push(
                entry
                    .path()
                    .strip_prefix(source)?
                    .to_str()
                    .context("Build input names must be Unicode.")?
                    .replace('\\', "/"),
            );
        }
    }
    Ok(())
}
pub fn sources(source: &Path, pins: &mut Pins) -> Result<(Vec<Source>, Vec<File>)> {
    let mut names = vec![
        "Cargo.toml".into(),
        "Cargo.lock".into(),
        "build.rs".into(),
        "rust-toolchain.toml".into(),
    ];
    walk(source, &source.join("src/rust"), &mut names, pins)?;
    if source.join(".cargo").try_exists()? {
        walk(source, &source.join(".cargo"), &mut names, pins)?;
    }
    for (name, path) in inputs(source, source) {
        if !name.ends_with(".exe") {
            names.push(
                path.strip_prefix(source)?
                    .to_str()
                    .context("Package input names must be Unicode.")?
                    .replace('\\', "/"),
            );
        }
    }
    names.sort();
    let mut handles = Vec::new();
    let mut records = Vec::new();
    for path in names {
        let mut file = pins.file(&source.join(&path))?;
        records.push(Source {
            path,
            sha256: hash(&mut file)?.to_lowercase(),
        });
        handles.push(file);
    }
    Ok((records, handles))
}
pub fn fingerprint(records: &[Source]) -> String {
    digest(
        records
            .iter()
            .map(|r| format!("{}\t{}\n", r.path, r.sha256))
            .collect::<String>()
            .as_bytes(),
    )
    .to_lowercase()
}
fn environment(source: &Path, pins: &mut Pins) -> Result<Vec<EnvironmentInput>> {
    let mut paths = Vec::new();
    for parent in source.ancestors().skip(1) {
        for name in ["config", "config.toml"] {
            paths.push(parent.join(".cargo").join(name));
        }
    }
    let cargo = std::env::var_os("CARGO_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join(".cargo")))
        .context("Cargo home is unavailable.")?;
    let cargo = absolute(cargo.to_str().context("Cargo home must be Unicode.")?)?;
    for name in ["config", "config.toml"] {
        paths.push(cargo.join(name));
    }
    paths.sort();
    paths.dedup_by(|a, b| {
        a.to_string_lossy()
            .eq_ignore_ascii_case(&b.to_string_lossy())
    });
    let mut result = Vec::new();
    for path in paths {
        for parent in path.ancestors().skip(1) {
            if parent.try_exists()? {
                pins.directory(parent)?;
                break;
            }
        }
        let exists = path.try_exists()?;
        let sha256 = if exists {
            Some(hash(&mut pins.file(&path)?)?.to_lowercase())
        } else {
            None
        };
        result.push(EnvironmentInput {
            path,
            exists,
            sha256,
        });
    }
    Ok(result)
}
fn toolchain(source: &Path, pins: &mut Pins) -> Result<String> {
    let bytes = read(&mut pins.file(&source.join("rust-toolchain.toml"))?, 65536)?;
    let text = std::str::from_utf8(&bytes)?;
    let pattern = regex::Regex::new(r#"(?m)^channel\s*=\s*"([1-9][0-9]*\.[0-9]+\.[0-9]+)"\s*$"#)?;
    let captures: Vec<_> = pattern.captures_iter(text).collect();
    ensure!(
        captures.len() == 1,
        "Toolchain must pin one exact stable version."
    );
    Ok(captures[0][1].to_owned())
}
fn cargo(source: &Path, target: &Path, temp: &Path, channel: &str, commit: &str) -> Command {
    let executable = std::env::var_os("USERPROFILE")
        .map(|p| PathBuf::from(p).join(".cargo/bin/cargo.exe"))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from("cargo"));
    let mut command = Command::new(executable);
    command
        .current_dir(source)
        .env("CARGO_TARGET_DIR", target)
        .env("TEMP", temp)
        .env("TMP", temp)
        .env("RUSTUP_TOOLCHAIN", channel)
        .env(
            "CARGO_ENCODED_RUSTFLAGS",
            "-C\u{1f}target-feature=+crt-static",
        )
        .env("PRUNLET_SOURCE_COMMIT", commit)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    command
}
fn execute(mut command: Command) -> Result<Vec<Value>> {
    let mut child = command.spawn().context("Cannot start pinned Cargo.")?;
    let mut messages = Vec::new();
    for line in BufReader::new(child.stdout.take().context("Cargo output unavailable.")?).lines() {
        let line = line?;
        if let Ok(value) = serde_json::from_str::<Value>(&line) {
            if let Some(rendered) = value["message"]["rendered"].as_str() {
                eprint!("{rendered}");
            }
            messages.push(value);
        } else {
            eprintln!("{line}");
        }
    }
    ensure!(
        child.wait()?.success(),
        "Cargo build failed; outputs were retained."
    );
    Ok(messages)
}
fn product_artifact(messages: &[Value], name: &str, expected: &Path) -> Result<PathBuf> {
    let artifacts: Vec<_> = messages
        .iter()
        .filter(|v| {
            v["reason"] == "compiler-artifact"
                && v["target"]["name"] == name
                && v["profile"]["test"] == false
                && v["target"]["kind"]
                    .as_array()
                    .is_some_and(|k| k.iter().any(|v| v == "bin"))
        })
        .filter_map(|v| v["executable"].as_str())
        .collect();
    ensure!(
        artifacts.len() == 1,
        "Expected exactly one Cargo executable for {name}."
    );
    let artifact = absolute(artifacts[0])?;
    ensure!(
        in_tree(&artifact, expected) && in_tree(expected, &artifact),
        "Cargo executable differs from the expected product path."
    );
    Ok(artifact)
}
struct BuildLock(windows_sys::Win32::Foundation::HANDLE);
impl BuildLock {
    fn acquire(target: &Path) -> Result<Self> {
        use windows_sys::Win32::System::Threading::{CreateMutexW, WaitForSingleObject};
        let name: Vec<u16> = format!(
            "Global\\Prunlet-RustPublish-{}",
            digest(target.to_string_lossy().to_lowercase().as_bytes())
        )
        .encode_utf16()
        .chain(Some(0))
        .collect();
        let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
        ensure!(
            !handle.is_null(),
            "Cannot acquire the Cargo target build mutex."
        );
        match unsafe { WaitForSingleObject(handle, 600000) } {
            0 | 0x80 => Ok(Self(handle)),
            _ => {
                unsafe {
                    windows_sys::Win32::Foundation::CloseHandle(handle);
                }
                anyhow::bail!("Another publisher still owns this Cargo target directory.")
            }
        }
    }
}
impl Drop for BuildLock {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::System::Threading::ReleaseMutex(self.0);
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}
pub fn run(args: &Args) -> Result<()> {
    let source = args.path("source")?;
    let output = args.path("output")?;
    let target_dir = args
        .values
        .get("target-directory")
        .map(|p| absolute(p))
        .transpose()?
        .unwrap_or_else(|| output.join("cargo-target"));
    let temp = output.join("temp");
    let publish = output.join("publish");
    for path in [&output, &target_dir, &temp, &publish] {
        output_path(path, &source)?;
    }
    ensure!(
        !in_tree(&target_dir, &publish) && !in_tree(&publish, &target_dir),
        "Target and publish paths cannot overlap."
    );
    let mut pins = Pins::new();
    pins.directory(&source)?;
    for path in [&output, &target_dir, &temp, &publish] {
        pins.create_directory(path)?;
    }
    let _target_lock = BuildLock::acquire(&target_dir)?;
    let mut lock = pins.new_file(&output.join("release-build.lock"))?;
    lock.write_all(b"Prunlet release build in progress; retained on failure.\n")?;
    for name in ["prunlet.exe", "prunlet-maintenance.exe", "prunlet-hook.exe"] {
        ensure!(
            !publish.join(name).try_exists()?,
            "Publish output is occupied; choose a fresh output directory."
        );
    }
    ensure!(
        !output.join("build-provenance.json").try_exists()?,
        "Build provenance already exists."
    );
    let (before, _source_handles) = sources(&source, &mut pins)?;
    let release_source = args
        .values
        .get("release-source")
        .map(String::as_str)
        .unwrap_or("false");
    ensure!(
        matches!(release_source, "true" | "false"),
        "Release source option must be true or false."
    );
    if release_source == "true" {
        verify_git_source(args, &mut pins)?;
    }
    let environment_before = environment(&source, &mut pins)?;
    let channel = toolchain(&source, &mut pins)?;
    let version = cargo_version(&source, &mut pins)?;
    let runtime = args.get("runtime")?;
    let commit = args.get("commit")?;
    let target = if runtime == "win-x64" {
        "x86_64-pc-windows-msvc"
    } else {
        "aarch64-pc-windows-msvc"
    };
    let version_output = cargo(&source, &target_dir, &temp, &channel, commit)
        .arg("--version")
        .output()?;
    ensure!(
        version_output.status.success(),
        "Pinned Cargo is unavailable."
    );
    let cargo_version = String::from_utf8(version_output.stdout)?.trim().to_owned();
    ensure!(
        cargo_version.starts_with(&format!("cargo {channel} ")),
        "Cargo version differs from the pinned toolchain."
    );
    let mut command = cargo(&source, &target_dir, &temp, &channel, commit);
    command
        .args(["build", "--manifest-path"])
        .arg(source.join("Cargo.toml"))
        .args([
            "--release",
            "--locked",
            "--target",
            target,
            "--bin",
            "prunlet",
            "--bin",
            "prunlet-maintenance",
            "--bin",
            "prunlet-hook",
            "--message-format=json-render-diagnostics",
        ]);
    let messages = execute(command)?;
    let release = target_dir.join(target).join("release");
    let mut artifacts = BTreeMap::new();
    for name in ["prunlet", "prunlet-maintenance", "prunlet-hook"] {
        artifacts.insert(
            name,
            product_artifact(&messages, name, &release.join(format!("{name}.exe")))?,
        );
    }
    let mut products = BTreeMap::new();
    for name in ["prunlet.exe", "prunlet-maintenance.exe", "prunlet-hook.exe"] {
        // hookは現行updaterと同じCLI実体を使う。個別binも明示buildしてcompile契約を保つ。
        let input_name = if name == "prunlet-hook.exe" {
            "prunlet"
        } else {
            name.strip_suffix(".exe").unwrap()
        };
        let mut input = pins.cargo_artifact(&release, &artifacts[input_name])?;
        let input_hash = hash(&mut input)?;
        pe(&read(&mut input, MAX_ZIP)?, runtime, &version, commit)?;
        let mut destination = pins.new_file(&publish.join(name))?;
        std::io::copy(&mut input, &mut destination)?;
        destination.sync_all()?;
        pins.copied_artifact(&destination)?;
        let copied_hash = hash(&mut destination)?;
        ensure!(
            copied_hash == input_hash,
            "Published product bytes differ from the pinned Cargo artifact."
        );
        products.insert(name.to_owned(), copied_hash.to_lowercase());
    }
    let probe = args
        .values
        .get("include-verification-probe")
        .map(String::as_str)
        .unwrap_or("false");
    ensure!(
        matches!(probe, "true" | "false"),
        "Probe option must be true or false."
    );
    if probe == "true" {
        let verification = output.join("verification");
        pins.create_directory(&verification)?;
        let mut command = cargo(&source, &target_dir, &temp, &channel, commit);
        command
            .args(["test", "--manifest-path"])
            .arg(source.join("Cargo.toml"))
            .args([
                "--lib",
                "--no-run",
                "--locked",
                "--release",
                "--target",
                target,
                "--message-format=json-render-diagnostics",
            ]);
        let messages = execute(command)?;
        let artifacts: Vec<_> = messages
            .iter()
            .filter(|v| {
                v["reason"] == "compiler-artifact"
                    && v["profile"]["test"] == true
                    && v["target"]["name"] == "prunlet"
            })
            .filter_map(|v| v["executable"].as_str())
            .collect();
        ensure!(
            artifacts.len() == 1,
            "Expected exactly one libtest verification artifact."
        );
        let artifact = absolute(artifacts[0])?;
        let mut input = pins.cargo_artifact(&release, &artifact)?;
        let input_hash = hash(&mut input)?;
        let mut destination = pins.new_file(&verification.join("prunlet-libtest.exe"))?;
        std::io::copy(&mut input, &mut destination)?;
        destination.sync_all()?;
        pins.copied_artifact(&destination)?;
        ensure!(
            hash(&mut destination)? == input_hash,
            "Verification probe bytes differ from the pinned Cargo artifact."
        );
        // 既存dev検証manifestの入力集合は維持し、release来歴だけ同梱sourceへ拡張する。
        let legacy_before: Vec<_> = before
            .iter()
            .filter(|v| !v.path.starts_with("scripts/") && !v.path.starts_with("integration/"))
            .cloned()
            .collect();
        let record = json!({"schema":1,"sourceCommit":commit,"runtime":runtime,"sourceFingerprint":fingerprint(&legacy_before),"sourceFingerprintAlgorithm":"sha256-relative-path-tab-content-sha256-v1","sources":legacy_before,"build":{"toolchain":channel,"cargoVersion":cargo_version,"target":target,"profile":"release","profileOverrides":profile_overrides(),"rustflags":["-C","target-feature=+crt-static"],"sourceCommit":commit,"cargoEnvironmentInputs":environment_before},"product":{"relativePath":"publish/prunlet.exe","sha256":products["prunlet.exe"]},"probe":{"relativePath":"verification/prunlet-libtest.exe","sha256":hash(&mut destination)?.to_lowercase()}});
        write_json(
            &mut pins.new_file(&output.join("build-manifest.json"))?,
            &record,
        )?;
    }
    ensure!(
        sources(&source, &mut pins)?.0 == before,
        "Source changed during build; outputs are not verified."
    );
    ensure!(
        environment(&source, &mut pins)? == environment_before,
        "Cargo environment configuration changed during build."
    );
    if release_source == "true" {
        verify_git_source(args, &mut pins)?;
    }
    let record = Provenance {
        schema: 1,
        source_commit: commit.into(),
        runtime: runtime.into(),
        version,
        source_fingerprint: fingerprint(&before),
        source_fingerprint_algorithm: "sha256-relative-path-tab-content-sha256-v1".into(),
        sources: before,
        cargo_environment_inputs: environment_before,
        products: products.clone(),
        toolchain: channel,
        cargo_version,
        target: target.into(),
        profile: "release".into(),
        rustflags: vec!["-C".into(), "target-feature=+crt-static".into()],
        profile_overrides: profile_overrides(),
    };
    let provenance_path = output.join("build-provenance.json");
    write_json(&mut pins.new_file(&provenance_path)?, &record)?;
    println!(
        "{}",
        json!({"executable":publish.join("prunlet.exe"),"maintenanceExecutable":publish.join("prunlet-maintenance.exe"),"hookExecutable":publish.join("prunlet-hook.exe"),"runtime":runtime,"sha256":products["prunlet.exe"].to_uppercase(),"maintenanceSha256":products["prunlet-maintenance.exe"].to_uppercase(),"hookSha256":products["prunlet-hook.exe"].to_uppercase(),"bytes":std::fs::metadata(publish.join("prunlet.exe"))?.len(),"provenancePath":provenance_path})
    );
    Ok(())
}
fn profile_overrides() -> BTreeMap<String, String> {
    std::env::vars()
        .filter(|(n, _)| n.starts_with("CARGO_PROFILE_RELEASE_"))
        .collect()
}

pub fn verify_provenance(args: &Args, pins: &mut Pins) -> Result<Provenance> {
    let publish = args.path("publish")?;
    let source = args.path("source")?;
    verify_git_source(args, pins)?;
    let mut file = pins.file(
        &publish
            .parent()
            .context("Publish requires a parent.")?
            .join("build-provenance.json"),
    )?;
    let record: Provenance = serde_json::from_slice(&read(&mut file, 16 * 1024 * 1024)?)?;
    ensure!(
        record.schema == 1
            && record.source_commit == args.get("commit")?
            && record.runtime == args.get("runtime")?
            && record.version == cargo_version(&source, pins)?
            && record.source_fingerprint_algorithm == "sha256-relative-path-tab-content-sha256-v1"
            && record.profile == "release"
            && record.rustflags == ["-C", "target-feature=+crt-static"]
            && record.products.len() == 3,
        "Build provenance identity differs."
    );
    ensure!(
        record.toolchain == toolchain(&source, pins)?
            && record
                .cargo_version
                .starts_with(&format!("cargo {} ", record.toolchain)),
        "Build toolchain provenance differs."
    );
    ensure!(
        record.target
            == if record.runtime == "win-x64" {
                "x86_64-pc-windows-msvc"
            } else {
                "aarch64-pc-windows-msvc"
            },
        "Build target provenance differs."
    );
    let (current, _handles) = sources(&source, pins)?;
    ensure!(
        current == record.sources && fingerprint(&current) == record.source_fingerprint,
        "Build source provenance differs."
    );
    ensure!(
        environment(&source, pins)? == record.cargo_environment_inputs,
        "Cargo environment inputs differ from build provenance."
    );
    Ok(record)
}

// HEADの名前だけでなく、Gitのeol/filter変換後の実入力blobまで照合する。
pub fn verify_git_source(args: &Args, pins: &mut Pins) -> Result<()> {
    let source = args.path("source")?;
    fn command(source: &Path) -> Command {
        let mut value = Command::new("git");
        value
            .arg("--no-optional-locks")
            .arg("-C")
            .arg(source)
            .stderr(Stdio::null())
            .stdout(Stdio::piped());
        value
    }
    fn output(mut value: Command) -> Result<Vec<u8>> {
        let result = value.output().context("Release source requires Git.")?;
        ensure!(
            result.status.success(),
            "Git could not verify release source."
        );
        Ok(result.stdout)
    }
    let mut top = command(&source);
    top.args(["rev-parse", "--show-toplevel"]);
    let top = String::from_utf8(output(top)?)?;
    let root = absolute(top.trim())?;
    ensure!(
        in_tree(&source, &root) && in_tree(&root, &source),
        "Source must be the Git worktree root."
    );
    let mut head = command(&source);
    head.args(["rev-parse", "--verify", "HEAD"]);
    ensure!(
        String::from_utf8(output(head)?)?.trim() == args.get("commit")?,
        "Requested release commit differs from Git HEAD."
    );
    let mut specs: Vec<String> = [
        "Cargo.toml",
        "Cargo.lock",
        "build.rs",
        "rust-toolchain.toml",
        "src/rust",
        ".cargo",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    for (name, path) in inputs(&source, &source) {
        if !name.ends_with(".exe") {
            specs.push(
                path.strip_prefix(&source)?
                    .to_str()
                    .context("Git input names must be Unicode.")?
                    .replace('\\', "/"),
            );
        }
    }
    let mut status = command(&source);
    status
        .args([
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--ignored=matching",
            "--",
        ])
        .args(&specs);
    ensure!(
        output(status)?.is_empty(),
        "Release product inputs have tracked, untracked, or ignored changes."
    );
    let mut flags = command(&source);
    flags.args(["ls-files", "-v", "-z", "--"]).args(&specs);
    ensure!(
        output(flags)?
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .all(|s| s.starts_with(b"H ")),
        "Release input index flags must not hide worktree changes."
    );
    let mut tree = command(&source);
    tree.args(["ls-tree", "--full-tree", "-r", "-z", "HEAD", "--"])
        .args(&specs);
    let tree = output(tree)?;
    let mut blobs = BTreeMap::new();
    for item in tree.split(|b| *b == 0).filter(|s| !s.is_empty()) {
        let item = std::str::from_utf8(item)?;
        let (header, path) = item
            .split_once('\t')
            .context("Malformed Git tree output.")?;
        let fields: Vec<_> = header.split(' ').collect();
        ensure!(
            fields.len() == 3 && matches!(fields[0], "100644" | "100755") && fields[1] == "blob",
            "Release input must be a regular Git blob."
        );
        ensure!(
            blobs
                .insert(path.to_owned(), fields[2].to_owned())
                .is_none(),
            "Duplicate Git input."
        );
    }
    let (records, mut files) = sources(&source, pins)?;
    ensure!(
        records.len() == blobs.len(),
        "Release input set differs from the requested commit."
    );
    for (record, file) in records.iter().zip(&mut files) {
        let expected = blobs
            .get(&record.path)
            .context("Release input is not tracked in the requested commit.")?;
        let mut hash = command(&source);
        hash.args(["hash-object", "--path", &record.path, "--stdin"])
            .stdin(Stdio::piped());
        let mut child = hash.spawn().context("Cannot verify release input blob.")?;
        std::io::copy(
            file,
            &mut child.stdin.take().context("Git input unavailable.")?,
        )?;
        let result = child.wait_with_output()?;
        ensure!(
            result.status.success() && String::from_utf8(result.stdout)?.trim() == expected,
            "Release input bytes differ from the requested commit: {}",
            record.path
        );
    }
    let mut head = command(&source);
    head.args(["rev-parse", "--verify", "HEAD"]);
    ensure!(
        String::from_utf8(output(head)?)?.trim() == args.get("commit")?,
        "Git HEAD changed while release inputs were verified."
    );
    Ok(())
}
