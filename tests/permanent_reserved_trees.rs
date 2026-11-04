#![cfg(windows)]

use anyhow::{Context, Result, ensure};
use prunlet::platform::windows::{self as native, PinnedFile};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, File},
    io::{BufRead, BufReader, Read, Write},
    os::windows::{io::AsRawHandle, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread,
};
use windows::Win32::{
    System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoTaskMemFree, CoUninitialize},
    UI::Shell::{
        BHID_EnumItems, FOLDERID_RecycleBinFolder, IEnumShellItems, IShellItem, KF_FLAG_DEFAULT,
        SHGetKnownFolderItem, SIGDN_FILESYSPATH,
    },
};
use windows_sys::Win32::{
    Foundation::{GENERIC_READ, GENERIC_WRITE, WAIT_OBJECT_0},
    Storage::FileSystem::*,
    System::{IO::DeviceIoControl, Ioctl::FSCTL_SET_REPARSE_POINT, Threading::WaitForSingleObject},
};

const CREATE_NO_WINDOW: u32 = 0x08000000;
const OUTPUT_LIMIT: u64 = 16 * 1024 * 1024;

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn file_hash(path: &Path) -> Result<String> {
    Ok(digest(&fs::read(path)?))
}
fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    write_new(path, &serde_json::to_vec_pretty(value)?)
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let _parents = native::path::pin_directories(path.parent().context("Missing write parent")?)?;
    let mut file = File::options()
        .write(true)
        .create_new(true)
        .open(literal(path)?)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
fn write_new_ads(path: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    ensure!(
        name.chars().all(|c| c.is_ascii_alphanumeric()),
        "Invalid fixture stream name"
    );
    let _parents = native::path::pin_directories(path.parent().context("Missing ADS parent")?)?;
    let fixed = PinnedFile::open(
        path,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
    )?;
    ensure!(
        !fixed.identity()?.is_directory() && !fixed.identity()?.is_reparse(),
        "ADS base is not ordinary"
    );
    fixed.verify_named()?;
    let mut file = File::options()
        .write(true)
        .create_new(true)
        .open(format!("{}:{name}", literal(path)?.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fixed.verify_named()?;
    Ok(())
}
fn literal(path: &Path) -> Result<PathBuf> {
    Ok(PathBuf::from(format!(
        "\\\\?\\{}",
        native::path::file_system_absolute(path)?.display()
    )))
}
fn assert_external(path: &Path) -> Result<PathBuf> {
    let path = native::path::absolute(path)?;
    for forbidden in [
        Some(PathBuf::from(env!("CARGO_MANIFEST_DIR"))),
        std::env::var_os("CODEX_HOME").map(PathBuf::from),
        std::env::var_os("USERPROFILE").map(|p| PathBuf::from(p).join(".codex")),
    ]
    .into_iter()
    .flatten()
    {
        ensure!(
            !native::path::within(&path, &forbidden),
            "Verification output is protected: {}",
            path.display()
        );
    }
    ensure!(
        path.to_string_lossy().len() > 3,
        "A volume root is not an owned fixture"
    );
    let parent = path.parent().context("Missing verification parent")?;
    let _parents = native::path::pin_directories(parent)?;
    let mut ancestor = Some(parent);
    while let Some(directory) = ancestor {
        ensure!(
            !directory.join(".git").exists(),
            "Verification output cannot be in a repository"
        );
        ancestor = directory.parent();
    }
    Ok(path)
}
fn cmd_path(path: &Path) -> Result<String> {
    let text = path.to_str().context("Non-Unicode command path")?;
    ensure!(
        path.is_absolute()
            && !text
                .chars()
                .any(|c| c.is_control() || "%!^&|<>\"".contains(c)),
        "Path cannot be represented literally in CMD"
    );
    Ok(format!("\"{text}\""))
}
fn cli_command(exe: &Path, config: &Path, arguments: &[String], temp: &Path) -> Result<Command> {
    let mut text = format!("{} --config {}", cmd_path(exe)?, cmd_path(config)?);
    for argument in arguments {
        ensure!(
            !argument
                .chars()
                .any(|c| c.is_control() || "%!^&|<>\"".contains(c)),
            "Unsafe CMD argument"
        );
        text.push_str(&format!(" \"{argument}\""));
    }
    let mut command = Command::new(
        std::env::var_os("SystemRoot")
            .map(PathBuf::from)
            .context("SystemRoot missing")?
            .join("System32")
            .join("cmd.exe"),
    );
    command
        .args(["/d", "/v:off", "/s", "/c"])
        .raw_arg(format!("\"{text}\""));
    command
        .creation_flags(CREATE_NO_WINDOW)
        .env("TEMP", temp)
        .env("TMP", temp);
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    Ok(command)
}
fn wait(child: &mut Child, seconds: u32) -> Result<i32> {
    let result =
        unsafe { WaitForSingleObject(child.as_raw_handle(), seconds.saturating_mul(1000)) };
    ensure!(
        result == WAIT_OBJECT_0,
        "UNKNOWN: process {} did not finish; preserve its fixtures and do not resend deletion",
        child.id()
    );
    Ok(child.wait()?.code().unwrap_or(-1))
}
fn drain(reader: impl Read + Send + 'static) -> thread::JoinHandle<Result<String>> {
    thread::spawn(move || {
        let mut bytes = vec![];
        reader.take(OUTPUT_LIMIT + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= OUTPUT_LIMIT,
            "Child output exceeded its verification bound"
        );
        String::from_utf8(bytes).map_err(|error| {
            anyhow::anyhow!(
                "Child output was not UTF-8: {:?}",
                String::from_utf8_lossy(error.as_bytes())
            )
        })
    })
}
fn join_output(handle: thread::JoinHandle<Result<String>>) -> Result<String> {
    handle
        .join()
        .map_err(|_| anyhow::anyhow!("Output reader panicked"))?
}
#[derive(Serialize)]
struct Wire {
    exit_code: i32,
    json: Value,
    stdout: String,
    stderr: String,
}
fn run(mut command: Command) -> Result<Wire> {
    let mut child = command.spawn()?;
    child.stdin.take();
    let stdout = drain(child.stdout.take().context("Missing stdout")?);
    let stderr = drain(child.stderr.take().context("Missing stderr")?);
    let exit_code = wait(&mut child, 240)?;
    let stdout = join_output(stdout)?;
    let stderr = join_output(stderr)?;
    let json = serde_json::from_str(&stdout).unwrap_or(Value::Null);
    Ok(Wire {
        exit_code,
        json,
        stdout,
        stderr,
    })
}

struct Mcp {
    child: Child,
    input: Option<ChildStdin>,
    lines: Receiver<Result<String>>,
    stderr: Option<thread::JoinHandle<Result<String>>>,
}
impl Mcp {
    fn start(command: &mut Command) -> Result<Self> {
        let mut child = command.spawn()?;
        let input = child.stdin.take();
        let stdout = child.stdout.take().context("Missing MCP stdout")?;
        let stderr = Some(drain(child.stderr.take().context("Missing MCP stderr")?));
        let (sender, lines) = mpsc::channel();
        thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut bytes = vec![];
                let result = reader
                    .by_ref()
                    .take(4 * 1024 * 1024 + 1)
                    .read_until(b'\n', &mut bytes);
                match result {
                    Ok(0) => break,
                    Ok(_) if bytes.len() <= 4 * 1024 * 1024 => {
                        if sender
                            .send(String::from_utf8(bytes).map_err(Into::into))
                            .is_err()
                        {
                            break;
                        }
                    }
                    Ok(_) => {
                        let _ = sender.send(Err(anyhow::anyhow!("MCP line exceeded its bound")));
                        break;
                    }
                    Err(error) => {
                        let _ = sender.send(Err(error.into()));
                        break;
                    }
                }
            }
        });
        Ok(Self {
            child,
            input,
            lines,
            stderr,
        })
    }
    fn send(&mut self, request: &Value) -> Result<()> {
        let input = self.input.as_mut().context("MCP input closed")?;
        serde_json::to_writer(&mut *input, request)?;
        input.write_all(b"\n")?;
        input.flush()?;
        Ok(())
    }
    fn rpc(&mut self, id: i64, method: &str, params: Value) -> Result<Value> {
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))?;
        loop {
            let line = self
                .lines
                .recv_timeout(std::time::Duration::from_secs(240))
                .with_context(|| {
                    format!(
                        "UNKNOWN: MCP {} stopped responding; do not resend",
                        self.child.id()
                    )
                })??;
            let response: Value = serde_json::from_str(&line)?;
            if response["id"] == id {
                return Ok(response);
            }
        }
    }
    fn initialize(&mut self) -> Result<()> {
        ensure!(self.rpc(1, "initialize", json!({"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"rust-reserved-tree-e2e","version":"1"}}))?["error"].is_null(), "MCP initialize failed");
        self.send(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}))
    }
    fn call(&mut self, id: i64, arguments: Value) -> Result<Value> {
        self.rpc(
            id,
            "tools/call",
            json!({"name":"delete_files","arguments":arguments}),
        )
    }
    fn finish(&mut self) -> Result<()> {
        self.input.take();
        ensure!(
            wait(&mut self.child, 30)? == 0,
            "MCP failed to exit after EOF"
        );
        if let Some(stderr) = self.stderr.take() {
            let _ = join_output(stderr)?;
        }
        Ok(())
    }
}
impl Drop for Mcp {
    fn drop(&mut self) {
        self.input.take();
    }
}

#[derive(Clone, Serialize, PartialEq, Eq)]
struct Stream {
    name: String,
    size: u64,
    sha256: String,
}
#[derive(Clone, Serialize, PartialEq, Eq)]
struct Node {
    relative: String,
    id: String,
    attributes: u32,
    links: u32,
    size: u64,
    security: String,
    reparse: String,
    streams: Vec<Stream>,
}
fn identity(handle: &PinnedFile) -> Result<String> {
    let id = handle.identity()?;
    Ok(format!("{:016X}:{}", id.volume, hex::encode_upper(id.id)))
}
fn snapshot(root: &Path) -> Result<Vec<Node>> {
    let root = native::path::file_system_absolute(root)?;
    let _parents =
        native::path::pin_directories(root.parent().context("Missing snapshot parent")?)?;
    let mut pending = vec![root.clone()];
    let mut retained = vec![];
    let mut proof = vec![];
    let mut memberships = vec![];
    while let Some(path) = pending.pop() {
        ensure!(proof.len() < 65536, "Owned snapshot entry bound exceeded");
        let fixed = PinnedFile::open(
            &path,
            GENERIC_READ | READ_CONTROL | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ,
        )?;
        let id = fixed.identity()?;
        let security = native::security::read_member_security(fixed.raw())?;
        let mut streams = vec![];
        if !id.is_reparse() {
            if !id.is_directory() {
                let bytes = fs::read(literal(&path)?)?;
                ensure!(
                    bytes.len() <= 1024 * 1024,
                    "Fixture default stream exceeded one MiB"
                );
                streams.push(Stream {
                    name: "::$DATA".into(),
                    size: bytes.len() as u64,
                    sha256: digest(&bytes),
                });
            }
            for stream in native::named_streams_bounded(fixed.raw(), 8192)? {
                ensure!(stream.size <= 1024 * 1024, "Fixture ADS exceeded one MiB");
                let bytes = fs::read(format!("{}:{}", literal(&path)?.display(), stream.name))?;
                ensure!(
                    bytes.len() as u64 == stream.size,
                    "Fixture stream changed while read"
                );
                streams.push(Stream {
                    name: stream.name,
                    size: stream.size,
                    sha256: digest(&bytes),
                });
            }
        }
        streams.sort_by(|a, b| a.name.cmp(&b.name));
        let reparse = if id.is_reparse() {
            native::read_reparse(fixed.raw())?
        } else {
            vec![]
        };
        if id.is_directory() && !id.is_reparse() {
            let entries = native::directory_entries_bounded(fixed.raw(), 65536 - proof.len())?;
            let mut names: Vec<_> = entries.iter().map(|entry| entry.name.clone()).collect();
            names.sort();
            for entry in entries {
                pending.push(path.join(entry.name));
            }
            memberships.push((path.clone(), names));
        }
        proof.push(Node {
            relative: path.strip_prefix(&root)?.to_string_lossy().into(),
            id: identity(&fixed)?,
            attributes: id.attributes,
            links: id.links,
            size: id.size,
            security: hex::encode(&security),
            reparse: hex::encode(&reparse),
            streams,
        });
        retained.push((path, fixed, id, security, reparse));
    }
    for (path, fixed, id, security, reparse) in &retained {
        ensure!(
            fixed.identity()? == *id
                && fixed.final_path()? == *path
                && native::security::read_member_security(fixed.raw())? == *security,
            "Fixture changed during snapshot"
        );
        if id.is_reparse() {
            ensure!(
                native::read_reparse(fixed.raw())? == *reparse,
                "Fixture link changed"
            );
        }
    }
    for (path, names) in memberships {
        let dir = PinnedFile::open(
            &path,
            FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY,
            FILE_SHARE_READ,
        )?;
        let mut current = native::directory_names_bounded(dir.raw(), names.len())?;
        current.sort();
        ensure!(current == names, "Fixture membership changed");
    }
    proof.sort_by(|a, b| a.relative.cmp(&b.relative));
    Ok(proof)
}
fn junction(path: &Path, target: &Path) -> Result<native::path::DirectoryLease> {
    let _parent = native::path::pin_directories(path.parent().context("Missing junction parent")?)?;
    let _target = native::path::pin_directories(target)?;
    fs::create_dir(path)?;
    let lease = native::path::pin_directories(path)?;
    let fixed = PinnedFile::open(
        path,
        GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )?;
    let print: Vec<u16> = target.to_string_lossy().encode_utf16().collect();
    let substitute: Vec<u16> = format!("\\??\\{}", target.display())
        .encode_utf16()
        .collect();
    let mut buffer = vec![];
    buffer.extend_from_slice(&0xA0000003u32.to_le_bytes());
    buffer
        .extend_from_slice(&((8 + (substitute.len() + print.len() + 2) * 2) as u16).to_le_bytes());
    buffer.extend_from_slice(&0u16.to_le_bytes());
    for value in [
        0,
        substitute.len() * 2,
        (substitute.len() + 1) * 2,
        print.len() * 2,
    ] {
        buffer.extend_from_slice(&(value as u16).to_le_bytes());
    }
    for value in substitute.into_iter().chain([0]).chain(print).chain([0]) {
        buffer.extend_from_slice(&value.to_le_bytes());
    }
    let mut returned = 0;
    ensure!(
        unsafe {
            DeviceIoControl(
                fixed.raw(),
                FSCTL_SET_REPARSE_POINT,
                buffer.as_ptr().cast(),
                buffer.len() as u32,
                std::ptr::null_mut(),
                0,
                &mut returned,
                std::ptr::null_mut(),
            )
        } != 0,
        "Cannot create owned junction: {}",
        std::io::Error::last_os_error()
    );
    Ok(lease)
}
fn bin_matches(ids: &[String]) -> Result<Vec<String>> {
    unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()?;
    }
    struct Apartment;
    impl Drop for Apartment {
        fn drop(&mut self) {
            unsafe {
                CoUninitialize();
            }
        }
    }
    let _apartment = Apartment;
    let bin: IShellItem =
        unsafe { SHGetKnownFolderItem(&FOLDERID_RecycleBinFolder, KF_FLAG_DEFAULT, None)? };
    let items: IEnumShellItems = unsafe { bin.BindToHandler(None, &BHID_EnumItems)? };
    let mut found = vec![];
    loop {
        let mut next = [None];
        unsafe {
            items.Next(&mut next, None)?;
        }
        let Some(item) = next[0].take() else {
            break;
        };
        let name = unsafe { item.GetDisplayName(SIGDN_FILESYSPATH)? };
        let path = unsafe { name.to_string() };
        unsafe {
            CoTaskMemFree(Some(name.0.cast()));
        }
        let fixed = PinnedFile::open(Path::new(&path?), FILE_READ_ATTRIBUTES, 7)?;
        let id = identity(&fixed)?;
        if ids.contains(&id) {
            found.push(id);
        }
    }
    Ok(found)
}

struct Binding {
    exe: PathBuf,
    probe: PathBuf,
    manifest: PathBuf,
    manifest_hash: String,
    exe_hash: String,
    probe_hash: String,
    source_hash: String,
    inputs: Vec<(PathBuf, String)>,
    _pins: Vec<PinnedFile>,
    _parents: Vec<native::path::DirectoryLease>,
}
impl Binding {
    fn load() -> Result<Self> {
        let required = |name| {
            std::env::var_os(name)
                .map(PathBuf::from)
                .with_context(|| format!("Required environment variable: {name}"))
        };
        let exe = native::path::absolute(&required("PRUNLET_E2E_EXE")?)?;
        let probe = native::path::absolute(&required("PRUNLET_E2E_PROBE")?)?;
        let manifest = native::path::absolute(&required("PRUNLET_E2E_MANIFEST")?)?;
        let manifest_hash = std::env::var("PRUNLET_E2E_MANIFEST_SHA256")?;
        let mut parents = vec![];
        let mut pins = vec![];
        for path in [&exe, &probe, &manifest] {
            parents.push(native::path::pin_directories(
                path.parent().context("Binding input has no parent")?,
            )?);
            let fixed =
                PinnedFile::open(path, FILE_READ_DATA | FILE_READ_ATTRIBUTES, FILE_SHARE_READ)?;
            let id = fixed.identity()?;
            ensure!(
                !id.is_directory()
                    && !id.is_reparse()
                    && native::ordinal_ignore_case(
                        &fixed.final_path()?.to_string_lossy(),
                        &path.to_string_lossy()
                    ),
                "Binding input is not the exact ordinary file"
            );
            fixed.verify_named()?;
            pins.push(fixed);
        }
        ensure!(
            file_hash(&manifest)?.eq_ignore_ascii_case(&manifest_hash),
            "Fixed build manifest changed"
        );
        let record: Value = prunlet::json::parse_unique(&fs::read(&manifest)?)?;
        ensure!(
            record["schema"] == 1
                && record["sourceFingerprintAlgorithm"]
                    == "sha256-relative-path-tab-content-sha256-v1",
            "Unsupported build provenance"
        );
        let text = |value: &Value| {
            value
                .as_str()
                .map(str::to_owned)
                .context("Missing manifest string")
        };
        let exe_hash = text(&record["product"]["sha256"])?;
        let probe_hash = text(&record["probe"]["sha256"])?;
        let source_hash = text(&record["sourceFingerprint"])?;
        let source = Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut inputs = vec![];
        for entry in record["sources"]
            .as_array()
            .context("Missing source binding")?
        {
            let relative = PathBuf::from(text(&entry["path"])?);
            ensure!(
                !relative.is_absolute()
                    && !relative
                        .components()
                        .any(|part| matches!(part, std::path::Component::ParentDir)),
                "Invalid source binding"
            );
            inputs.push((source.join(relative), text(&entry["sha256"])?));
        }
        let result = Self {
            exe,
            probe,
            manifest,
            manifest_hash,
            exe_hash,
            probe_hash,
            source_hash,
            inputs,
            _pins: pins,
            _parents: parents,
        };
        result.verify()?;
        Ok(result)
    }
    fn verify(&self) -> Result<()> {
        for (fixed, path) in self
            ._pins
            .iter()
            .zip([&self.exe, &self.probe, &self.manifest])
        {
            fixed.require_unchanged()?;
            fixed.verify_named()?;
            ensure!(
                native::ordinal_ignore_case(
                    &fixed.final_path()?.to_string_lossy(),
                    &path.to_string_lossy()
                ),
                "Binding input name changed"
            );
        }
        ensure!(
            file_hash(&self.exe)?.eq_ignore_ascii_case(&self.exe_hash)
                && file_hash(&self.probe)?.eq_ignore_ascii_case(&self.probe_hash)
                && file_hash(&self.manifest)?.eq_ignore_ascii_case(&self.manifest_hash),
            "Product, probe or manifest changed"
        );
        let source = Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut actual = vec![];
        for name in [
            "Cargo.toml",
            "Cargo.lock",
            "build.rs",
            "rust-toolchain.toml",
        ] {
            actual.push(source.join(name));
        }
        let mut pending = vec![source.join("src/rust")];
        if source.join(".cargo").exists() {
            pending.push(source.join(".cargo"));
        }
        while let Some(directory) = pending.pop() {
            let _plain = native::path::pin_directories(&directory)?;
            for entry in fs::read_dir(directory)? {
                let path = entry?.path();
                let fixed = PinnedFile::open(&path, FILE_READ_ATTRIBUTES, 7)?;
                let id = fixed.identity()?;
                ensure!(!id.is_reparse(), "Source input is a link");
                if id.is_directory() {
                    pending.push(path);
                } else {
                    actual.push(path);
                }
            }
        }
        actual.sort();
        let bound: BTreeSet<_> = self.inputs.iter().map(|(path, _)| path.clone()).collect();
        ensure!(
            actual.iter().cloned().collect::<BTreeSet<_>>() == bound,
            "Rust/Cargo source input set changed"
        );
        let mut text = String::new();
        for path in actual {
            let hash = file_hash(&path)?;
            ensure!(
                self.inputs
                    .iter()
                    .any(|(expected, digest)| expected == &path
                        && digest.eq_ignore_ascii_case(&hash)),
                "Bound source changed: {}",
                path.display()
            );
            text.push_str(
                &path
                    .strip_prefix(source)?
                    .to_string_lossy()
                    .replace('\\', "/"),
            );
            text.push('\t');
            text.push_str(&hash);
            text.push('\n');
        }
        ensure!(
            digest(text.as_bytes()) == self.source_hash,
            "Source fingerprint differs from the product/probe build"
        );
        Ok(())
    }
}
struct Scope {
    files: PathBuf,
    metadata: PathBuf,
    config: PathBuf,
    output: PathBuf,
    _config_pin: PinnedFile,
    _parents: Vec<native::path::DirectoryLease>,
}
struct Suite {
    binding: Binding,
    output: PathBuf,
    files: PathBuf,
    temp: PathBuf,
    commands: Vec<Value>,
    observations: Value,
    preparation: Vec<native::path::DirectoryLease>,
    _parents: Vec<native::path::DirectoryLease>,
}
impl Suite {
    fn new() -> Result<Self> {
        let binding = Binding::load()?;
        let output = assert_external(Path::new(&std::env::var("PRUNLET_E2E_OUTPUT")?))?;
        ensure!(
            output.to_string_lossy().to_uppercase().starts_with("D:\\") && !output.exists(),
            "Unused external D output is required"
        );
        let parent =
            native::path::absolute(Path::new(&std::env::var("PRUNLET_E2E_FIXTURE_ROOT")?))?;
        let mut parents = vec![
            native::path::pin_directories(&parent)?,
            native::path::pin_directories(output.parent().context("Output parent missing")?)?,
        ];
        let files = assert_external(&parent.join(format!(
            "rust-reserved-trees-{}",
            uuid::Uuid::new_v4().simple()
        )))?;
        fs::create_dir(&output)?;
        fs::create_dir(&files)?;
        parents.push(native::path::pin_directories(&output)?);
        parents.push(native::path::pin_directories(&files)?);
        let temp = output.join("temp");
        fs::create_dir(&temp)?;
        parents.push(native::path::pin_directories(&temp)?);
        Ok(Self {
            binding,
            output,
            files,
            temp,
            commands: vec![],
            observations: json!({}),
            preparation: vec![],
            _parents: parents,
        })
    }
    fn scope(&mut self, name: &str) -> Result<Scope> {
        let output = self.output.join(name);
        fs::create_dir(&output)?;
        let output_pin = native::path::pin_directories(&output)?;
        let files = self.files.join(name);
        fs::create_dir(&files)?;
        let files_pin = native::path::pin_directories(&files)?;
        let metadata = output.join("metadata");
        fs::create_dir(&metadata)?;
        let metadata_pin = native::path::pin_directories(&metadata)?;
        let config = output.join("config.json");
        let data = prunlet::config::ConfigData {
            backup_directory: metadata.to_string_lossy().into(),
            capacity_default_migration_version: 1,
            volume_recovery_directories: [(
                "D:\\".into(),
                output.join("store").to_string_lossy().into(),
            )]
            .into(),
            ..Default::default()
        };
        write_json(&config, &data)?;
        let pin = PinnedFile::open(
            &config,
            FILE_READ_DATA | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ,
        )?;
        let parents = vec![files_pin, output_pin, metadata_pin];
        Ok(Scope {
            files,
            metadata,
            config,
            output,
            _config_pin: pin,
            _parents: parents,
        })
    }
    fn invoke(&mut self, scope: &Scope, args: &[String]) -> Result<Wire> {
        self.preparation.clear();
        let result = run(cli_command(
            &self.binding.exe,
            &scope.config,
            args,
            &self.temp,
        )?)?;
        self.commands
            .push(json!({"config":scope.config,"arguments":args,"response":result}));
        Ok(result)
    }
    fn delete(
        &mut self,
        scope: &Scope,
        paths: &[PathBuf],
        dry: bool,
        explicit: bool,
    ) -> Result<Wire> {
        let list = scope
            .output
            .join(format!("paths-{}.json", uuid::Uuid::new_v4().simple()));
        write_json(&list, &paths)?;
        let _input = PinnedFile::open(
            &list,
            FILE_READ_DATA | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ,
        )?;
        let mut args = vec!["delete".into(), "--recursive".into()];
        if explicit {
            args.push("--permanent-reserved-tree".into());
        }
        if dry {
            args.push("--dry-run".into());
        }
        args.extend(["--paths-file".into(), list.to_string_lossy().into()]);
        self.invoke(scope, &args)
    }
    fn mcp(&mut self, scope: &Scope) -> Result<Mcp> {
        self.preparation.clear();
        Mcp::start(&mut cli_command(
            &self.binding.exe,
            &scope.config,
            &["mcp".into()],
            &self.temp,
        )?)
    }
    fn no_records(&self, scope: &Scope) -> Result<()> {
        for entry in fs::read_dir(&scope.metadata)? {
            let entry = entry?;
            ensure!(
                entry.file_name() == "maintenance.lock",
                "Recordless deletion created metadata"
            );
            let fixed = PinnedFile::open(&entry.path(), FILE_READ_ATTRIBUTES, 7)?;
            let id = fixed.identity()?;
            ensure!(
                !id.is_directory()
                    && !id.is_reparse()
                    && id.size == 0
                    && native::named_streams_bounded(fixed.raw(), 0)?.is_empty(),
                "Maintenance lock is not an empty ordinary file"
            );
        }
        ensure!(
            fs::symlink_metadata(scope.output.join("store"))
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound),
            "Recordless deletion created a store"
        );
        ensure!(
            fs::symlink_metadata(scope.output.join("store.restore"))
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound),
            "Recordless deletion created a restore store"
        );
        Ok(())
    }
    fn directory(&mut self, path: &Path) -> Result<()> {
        let _parent =
            native::path::pin_directories(path.parent().context("Missing fixture parent")?)?;
        fs::create_dir(literal(path)?)?;
        self.preparation.push(native::path::pin_directories(path)?);
        Ok(())
    }
    fn tree(&mut self, scope: &Scope, name: &str) -> Result<PathBuf> {
        let root = scope.files.join(name);
        self.directory(&root)?;
        write_new(&root.join("NUL"), b"reserved child")?;
        Ok(root)
    }
    fn probe(&mut self, fixture: &Path) -> Result<Value> {
        self.binding.verify()?;
        let root = self.output.join("native-probe");
        fs::create_dir(&root)?;
        let _root_pin = native::path::pin_directories(&root)?;
        let temp = root.join("temp");
        fs::create_dir(&temp)?;
        let _temp_pin = native::path::pin_directories(&temp)?;
        let result_path = root.join("result.json");
        let request = root.join("request.json");
        write_json(
            &request,
            &json!({"schema":1,"rootPath":root,"candidatePath":self.binding.exe,"candidateSha256":self.binding.exe_hash,"expectedProbeSha256":self.binding.probe_hash,"configPath":"","resultPath":result_path,"case":"file-reserved-tree-preflight-races","fixtureRoot":fixture}),
        )?;
        let _pin = PinnedFile::open(
            &request,
            FILE_READ_DATA | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ,
        )?;
        let mut command = Command::new(&self.binding.probe);
        command
            .args([
                "--exact",
                "verification::files_contract",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("PRUNLET_VERIFICATION_REQUEST", &request)
            .env("PRUNLET_VERIFICATION_REQUEST_SHA256", file_hash(&request)?)
            .env("TEMP", &temp)
            .env("TMP", &temp)
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let wire = run(command)?;
        write_new(&root.join("stdout.log"), wire.stdout.as_bytes())?;
        write_new(&root.join("stderr.log"), wire.stderr.as_bytes())?;
        ensure!(
            wire.exit_code == 0 && result_path.exists(),
            "Native boundary probe failed: {}",
            wire.stderr
        );
        let result: Value = serde_json::from_slice(&fs::read(&result_path)?)?;
        ensure!(
            result["runtime"] == "rust-libtest"
                && result["nativeFileProbe"] == true
                && result["result"]["passed"] == true
                && result["candidateSha256"]
                    .as_str()
                    .is_some_and(|hash| hash.eq_ignore_ascii_case(&self.binding.exe_hash))
                && result["probeSha256"]
                    .as_str()
                    .is_some_and(|hash| hash.eq_ignore_ascii_case(&self.binding.probe_hash)),
            "Native probe did not bind the product and original probe"
        );
        self.binding.verify()?;
        Ok(result)
    }
}
fn assert_wire(value: &Value, paths: &[PathBuf], statuses: &[&str], dry: bool) -> Result<()> {
    ensure!(
        value.as_object().is_some_and(|object| object.len() == 3
            && object.contains_key("items")
            && object.contains_key("dryRun")
            && object.contains_key("warnings")),
        "Unexpected result DTO"
    );
    ensure!(
        value["dryRun"] == dry
            && value["warnings"]
                .as_array()
                .is_some_and(|warnings| warnings.iter().all(Value::is_string))
            && value["items"]
                .as_array()
                .is_some_and(|items| items.len() == paths.len()),
        "Unexpected dry-run or item count"
    );
    for (index, path) in paths.iter().enumerate() {
        let item = &value["items"][index];
        ensure!(
            item["status"] != "ambiguous",
            "UNKNOWN: inspect source and Bin, never resend this deletion"
        );
        ensure!(
            item["path"].as_str() == path.to_str() && item["status"] == statuses[index],
            "Path/order/status mismatch: {item}"
        );
        ensure!(
            item["kind"] == "directory",
            "Directory result kind missing or wrong"
        );
        ensure!(
            item.as_object()
                .context("Missing item")?
                .keys()
                .all(|key| ["path", "kind", "status", "error"].contains(&key.as_str())),
            "Result exposed recovery metadata"
        );
    }
    Ok(())
}
fn tool_value(response: &Value) -> Result<Value> {
    ensure!(
        response["error"].is_null() && response["result"]["isError"] != true,
        "MCP request failed: {response}"
    );
    let result = &response["result"];
    ensure!(
        result["content"]
            .as_array()
            .is_some_and(|items| items.len() == 1)
            && result["content"][0]["type"] == "text",
        "Unexpected MCP content"
    );
    let value: Value = serde_json::from_str(
        result["content"][0]["text"]
            .as_str()
            .context("Missing tool text")?,
    )?;
    ensure!(
        result["structuredContent"] == value,
        "MCP structured/text result differs"
    );
    Ok(value)
}
fn rejected(response: &Value) -> bool {
    !response["error"].is_null() || response["result"]["isError"] == true
}

fn cli_nested(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("cli-nested")?;
    let root = suite.tree(&scope, "root")?;
    let nested_parent = root.join("nested");
    suite.directory(&nested_parent)?;
    let nested = nested_parent.join("CON");
    suite.directory(&nested)?;
    write_new(&nested.join("child"), b"nested content")?;
    let outside = scope.files.join("outside");
    suite.directory(&outside)?;
    write_new(&outside.join("target"), b"external target")?;
    suite
        .preparation
        .push(junction(&root.join("AUX"), &outside)?);
    let before = snapshot(&root)?;
    let exterior = snapshot(&outside)?;
    let ids: Vec<_> = before.iter().map(|node| node.id.clone()).collect();
    ensure!(
        bin_matches(&ids)?.is_empty(),
        "New fixture identity already in Bin"
    );
    let dry = suite.delete(&scope, std::slice::from_ref(&root), true, true)?;
    assert_wire(
        &dry.json,
        std::slice::from_ref(&root),
        &["would_permanently_delete"],
        true,
    )?;
    ensure!(
        dry.exit_code == 0 && snapshot(&root)? == before,
        "Dry-run changed its tree"
    );
    let result = suite.delete(&scope, std::slice::from_ref(&root), false, true)?;
    assert_wire(
        &result.json,
        std::slice::from_ref(&root),
        &["permanently_deleted"],
        false,
    )?;
    ensure!(
        result.exit_code == 0
            && !root.exists()
            && snapshot(&outside)? == exterior
            && bin_matches(&ids)?.is_empty(),
        "Root removal, exterior preservation or Bin check failed"
    );
    suite.observations = json!({"rootBefore":before,"outsideBefore":exterior,"outsideAfter":snapshot(&outside)?,"delete":result});
    suite.no_records(&scope)
}
fn mcp_hardlinks(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("mcp-hardlinks")?;
    let first = suite.tree(&scope, "first")?;
    let second = scope.files.join("second");
    suite.directory(&second)?;
    let source = first.join("NUL");
    let alias = second.join("COM1.txt");
    let survivor = scope.files.join("survivor");
    let source_pin = PinnedFile::open(
        &source,
        FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
    )?;
    source_pin.verify_named()?;
    write_new_ads(&source, "proof", b"owned ADS")?;
    fs::hard_link(literal(&source)?, literal(&alias)?)?;
    fs::hard_link(literal(&source)?, &survivor)?;
    let mut permissions = fs::metadata(literal(&source)?)?.permissions();
    permissions.set_readonly(true);
    fs::set_permissions(literal(&source)?, permissions)?;
    source_pin.verify_named()?;
    drop(source_pin);
    let before = snapshot(&survivor)?;
    ensure!(before[0].links == 3, "Hardlink fixture invalid");
    let root_ids = vec![
        snapshot(&first)?[0].id.clone(),
        snapshot(&second)?[0].id.clone(),
    ];
    let paths = vec![first.clone(), second.clone()];
    let mut mcp = suite.mcp(&scope)?;
    mcp.initialize()?;
    let dry = tool_value(&mcp.call(
        2,
        json!({"paths":paths,"recursive":true,"permanentReservedTree":true,"dryRun":true}),
    )?)?;
    assert_wire(
        &dry,
        &paths,
        &["would_permanently_delete", "would_permanently_delete"],
        true,
    )?;
    ensure!(
        snapshot(&survivor)? == before,
        "MCP dry-run changed the shared file"
    );
    let result = tool_value(&mcp.call(
        3,
        json!({"paths":paths,"recursive":true,"permanentReservedTree":true}),
    )?)?;
    assert_wire(
        &result,
        &paths,
        &["permanently_deleted", "permanently_deleted"],
        false,
    )?;
    mcp.finish()?;
    let after = snapshot(&survivor)?;
    let mut expected = before.clone();
    expected[0].links = 1;
    ensure!(
        !first.exists()
            && !second.exists()
            && after == expected
            && bin_matches(&root_ids)?.is_empty(),
        "External alias/ADS/ACL/attributes or Bin state changed"
    );
    suite.observations =
        json!({"survivorBefore":before,"survivorAfter":after,"dryRun":dry,"delete":result});
    suite.no_records(&scope)
}
fn qualifications(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("qualification")?;
    let plain = scope.files.join("plain");
    suite.directory(&plain)?;
    write_new(&plain.join("child"), b"ordinary subtree")?;
    let plain_before = snapshot(&plain)?;
    let root = suite.tree(&scope, "root")?;
    suite.directory(&root.join("AUX"))?;
    let link = scope.files.join("link");
    suite.preparation.push(junction(&link, &root)?);
    let before = snapshot(&root)?;
    let link_before = snapshot(&link)?;
    for path in [
        plain.clone(),
        plain.join("child"),
        link.clone(),
        root.join("AUX"),
        scope.files.join("missing"),
    ] {
        ensure!(
            suite.delete(&scope, &[path], false, true)?.exit_code != 0,
            "Unqualified root was accepted"
        );
    }
    for args in [
        vec![
            "delete".into(),
            "--permanent-reserved-tree".into(),
            "--".into(),
            root.to_string_lossy().into(),
        ],
        vec![
            "delete".into(),
            "--recursive".into(),
            "--permanent-reserved-tree".into(),
            "--permanent-reserved-tree".into(),
            "--".into(),
            root.to_string_lossy().into(),
        ],
        vec![
            "delete-queue".into(),
            "--recursive".into(),
            "--permanent-reserved-tree".into(),
            "--".into(),
            root.to_string_lossy().into(),
        ],
    ] {
        ensure!(
            suite.invoke(&scope, &args)?.exit_code != 0,
            "Invalid CLI options were accepted"
        );
    }
    ensure!(
        suite
            .delete(&scope, &[root.join("AUX")], false, false)?
            .exit_code
            != 0,
        "Default reserved-directory guard changed"
    );
    ensure!(
        snapshot(&root)? == before
            && snapshot(&plain)? == plain_before
            && snapshot(&link)? == link_before,
        "A rejected root changed"
    );
    suite.no_records(&scope)
}
fn locked_batch(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("locked")?;
    let first = suite.tree(&scope, "first")?;
    let second = suite.tree(&scope, "second")?;
    let before_first = snapshot(&first)?;
    let before_second = snapshot(&second)?;
    let held = PinnedFile::open(
        &second.join("NUL"),
        GENERIC_READ | READ_CONTROL | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ,
    )?;
    let result = suite.delete(&scope, &[first.clone(), second.clone()], false, true)?;
    drop(held);
    ensure!(
        result.exit_code != 0
            && result.json["error"]
                .as_str()
                .is_some_and(|error| error.contains("native error 32.")
                    && error.contains(&second.join("NUL").to_string_lossy().to_string())),
        "Locked preflight did not fail with its sharing diagnostic"
    );
    ensure!(
        snapshot(&first)? == before_first && snapshot(&second)? == before_second,
        "Batch preflight partially changed its roots"
    );
    suite.observations = json!({"delete":result});
    suite.no_records(&scope)
}
fn invalid_mcp(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("invalid-mcp")?;
    let root = suite.tree(&scope, "root")?;
    let before = snapshot(&root)?;
    let mut mcp = suite.mcp(&scope)?;
    mcp.initialize()?;
    let tools = mcp.rpc(2, "tools/list", json!({}))?;
    ensure!(
        tools["result"]["tools"]
            .as_array()
            .is_some_and(|tools| tools.len() == 5),
        "MCP tool count changed"
    );
    let tool = tools["result"]["tools"]
        .as_array()
        .context("Missing tools")?
        .iter()
        .find(|tool| tool["name"] == "delete_files")
        .context("Missing delete_files")?;
    ensure!(
        tool["inputSchema"]["properties"]["permanentReservedTree"]["type"] == "boolean",
        "New mode schema missing"
    );
    let mut id = 3;
    for value in [json!("true"), json!(1), Value::Null] {
        ensure!(
            rejected(&mcp.call(
                id,
                json!({"paths":[root],"recursive":true,"permanentReservedTree":value})
            )?),
            "Nonboolean mode was accepted"
        );
        id += 1;
    }
    for args in [
        json!({"paths":[root],"permanentReservedTree":true}),
        json!({"action":"enqueue","paths":[root],"recursive":true,"permanentReservedTree":true}),
        json!({"action":"enqueue","paths":[root],"recursive":true,"permanentReservedTree":false}),
    ] {
        ensure!(
            rejected(&mcp.call(id, args)?),
            "Unsupported mode was accepted"
        );
        id += 1;
    }
    mcp.finish()?;
    ensure!(
        snapshot(&root)? == before,
        "Invalid MCP input changed the root"
    );
    suite.no_records(&scope)
}
fn protected(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("protected")?;
    let root = suite.tree(&scope, "root")?;
    let before = snapshot(&root)?;
    let cache = scope.output.join(".prunlet-mcp-generations");
    suite.directory(&cache)?;
    write_new(&cache.join("NUL"), b"cache fixture")?;
    let metadata_before = snapshot(&scope.metadata)?;
    let cache_before = snapshot(&cache)?;
    for target in [scope.metadata.clone(), cache.clone()] {
        let result = suite.delete(&scope, &[root.clone(), target.clone()], false, true)?;
        let expected = if target == scope.metadata {
            "metadata recovery directory"
        } else {
            "MCP runtime generations are protected"
        };
        ensure!(
            result.exit_code != 0
                && result.json["error"]
                    .as_str()
                    .is_some_and(|error| error.contains(expected)),
            "Protected root did not return its protection diagnostic"
        );
        ensure!(
            snapshot(&root)? == before,
            "Protected batch partially changed its root"
        );
        if target == scope.metadata {
            ensure!(
                snapshot(&scope.metadata)? == metadata_before,
                "Rejected metadata target changed"
            );
        }
    }
    ensure!(snapshot(&cache)? == cache_before, "Protected cache changed");
    suite.no_records(&scope)
}
fn entry_budget(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("budget")?;
    let first = suite.tree(&scope, "first")?;
    let second = suite.tree(&scope, "second")?;
    for index in 0..4092 {
        write_new(
            &second.join(format!("file-{index}")),
            b"bounded owned fixture",
        )?;
    }
    let before_first = snapshot(&first)?;
    let before_second = snapshot(&second)?;
    let result = suite.delete(&scope, &[first.clone(), second.clone()], false, true)?;
    ensure!(
        result.exit_code != 0
            && result.json["error"]
                .as_str()
                .is_some_and(|error| error.contains("entry limit")),
        "Batch entry cap did not return its limit diagnostic"
    );
    ensure!(
        snapshot(&first)? == before_first && snapshot(&second)? == before_second,
        "Entry cap rejection changed the batch"
    );
    suite.observations =
        json!({"delete":result,"firstBefore":before_first,"secondBefore":before_second});
    suite.no_records(&scope)
}
fn native_boundaries(suite: &mut Suite) -> Result<()> {
    let scope = suite.scope("races")?;
    let result = suite.probe(&scope.files)?;
    ensure!(
        result["result"]["allStoppedBeforeDisposition"] == true,
        "Native races did not stop before disposition"
    );
    let proof = &result["result"];
    ensure!(
        proof["cases"].as_array().map(|cases| cases
            .iter()
            .filter_map(Value::as_str)
            .collect::<BTreeSet<_>>())
            == Some(
                ["write", "membership", "replace", "readonly"]
                    .into_iter()
                    .collect()
            ),
        "Native race coverage changed"
    );
    let resources = &proof["resources"];
    ensure!(
        resources["depth65RootRejected"] == true
            && resources["depth65ChildRejected"] == true
            && resources["directoryHandleBudget"] == 8192
            && resources["directoryBudgetBatchRoots"] == 129
            && resources["streamGuardBudget"] == 4095
            && resources["streamCountRetained"] == 4096,
        "Native resource boundary coverage changed"
    );
    suite.observations = json!({"sameSourceNativeProbe":result});
    suite.no_records(&scope)
}

#[test]
#[ignore = "Requires explicit immutable exe/probe/manifest binding and newly owned Windows fixtures"]
fn permanent_reserved_trees_e2e() -> Result<()> {
    let runner_source =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/permanent_reserved_trees.rs");
    let runner_source_hash = digest(include_bytes!("permanent_reserved_trees.rs"));
    ensure!(
        file_hash(&runner_source)? == runner_source_hash,
        "Runner source changed after compilation"
    );
    let mut suite = Suite::new()?;
    let cases: [(&str, fn(&mut Suite) -> Result<()>); 8] = [
        ("cli-nested-reserved-tree-dry-and-permanent", cli_nested),
        (
            "mcp-cross-root-hardlinks-ads-readonly-survivor",
            mcp_hardlinks,
        ),
        (
            "cli-qualification-rejections-preserve-default-guards",
            qualifications,
        ),
        (
            "cli-all-roots-preflight-locked-child-preserved",
            locked_batch,
        ),
        (
            "mcp-malformed-mode-and-queue-rejected-before-acceptance",
            invalid_mcp,
        ),
        (
            "cli-protected-metadata-and-runtime-cache-retain-batch",
            protected,
        ),
        ("cli-global-entry-budget-retains-all-roots", entry_budget),
        (
            "core-preflight-races-and-resource-limits",
            native_boundaries,
        ),
    ];
    let mut results = vec![];
    for (name, case) in cases {
        suite.observations = json!({});
        let outcome = case(&mut suite);
        let error = outcome.as_ref().err().map(|error| format!("{error:#}"));
        results.push(json!({"name":name,"passed":outcome.is_ok(),"error":error,"observed":suite.observations}));
        if error
            .as_ref()
            .is_some_and(|error| error.contains("UNKNOWN:"))
        {
            break;
        }
    }
    let final_binding = suite.binding.verify().and_then(|()| {
        ensure!(
            file_hash(&runner_source)? == runner_source_hash,
            "Runner source changed while verification ran"
        );
        Ok(())
    });
    let failed = results
        .iter()
        .filter(|result| result["passed"] != true)
        .count();
    let report = json!({"suite":"permanent-reserved-tree-rust","runnerSourceSha256":digest(include_bytes!("permanent_reserved_trees.rs")),"expectedCount":8,"executedCount":results.len(),"passed":results.len()-failed,"failed":failed,"skipped":0,"completeVerified":results.len()==8&&failed==0&&final_binding.is_ok(),"bindingVerifiedAfter":final_binding.is_ok(),"executablePath":suite.binding.exe,"executableSha256":suite.binding.exe_hash,"probePath":suite.binding.probe,"probeSha256":suite.binding.probe_hash,"buildManifestPath":suite.binding.manifest,"buildManifestSha256":suite.binding.manifest_hash,"sourceFingerprint":suite.binding.source_hash,"fixtureRoot":suite.files,"retainedOutput":suite.output,"results":results,"commands":suite.commands,"cleanup":"No automatic cleanup or deletion resend. Preserve failed/unknown fixtures; clean only owned exact paths with the installed CLI."});
    write_json(&suite.output.join("report.json"), &report)?;
    println!(
        "{}",
        serde_json::to_string(
            &json!({"report":suite.output.join("report.json"),"passed":report["passed"],"failed":failed,"executedCount":results.len(),"completeVerified":report["completeVerified"]})
        )?
    );
    final_binding?;
    ensure!(
        results.len() == 8 && failed == 0,
        "Rust reserved-tree E2E did not pass all eight cases"
    );
    Ok(())
}
