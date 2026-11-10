//! Mac版は署名済み単一実行ファイルを同一ディレクトリ内で置換する。
use super::{Pinned, path, security};
use crate::{config::ConfigData, json::parse_unique, update::package::is_hex};
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    fs::{self, File, OpenOptions, Permissions},
    io::{Cursor, ErrorKind, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

const LOCK: &str = ".prunlet-macos-update.lock";
const NEXT: &str = ".prunlet-next";
const REPO: &str = "1llum1n4t1s/Prunlet";
const ASSET: &str = "prunlet-update-osx-arm64.zip";
const COMMIT: &str = env!("PRUNLET_SOURCE_COMMIT");
const TEAM: Option<&str> = option_env!("PRUNLET_MACOS_TEAM_ID");
const MAX_PACKAGE: u64 = 64 * 1024 * 1024;

pub(crate) fn build_info() -> Value {
    json!({"version": crate::VERSION, "commit": COMMIT, "team": TEAM, "runtime": "osx-arm64", "protocol": 1})
}

pub(crate) fn installation_root() -> Result<Option<PathBuf>> {
    let exe = std::env::current_exe()?;
    let Some(bin) = exe
        .parent()
        .filter(|p| p.file_name().is_some_and(|n| n == "bin"))
    else {
        return Ok(None);
    };
    let root = bin.parent().context("Missing installation directory")?;
    match fs::symlink_metadata(root.join(LOCK)) {
        Ok(_) => Ok(Some(root.to_path_buf())),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

fn private(path: &Path, directory: bool) -> Result<Pinned> {
    let item = Pinned::open(path)?;
    let meta = item.file.metadata()?;
    ensure!(
        (if directory {
            meta.is_dir()
        } else {
            meta.is_file() && meta.nlink() == 1
        }) && meta.uid() == unsafe { libc::geteuid() }
            && meta.mode() & 0o077 == 0,
        "Managed path is not private and owned: {}",
        path.display()
    );
    security::reject_acl(&item.file)?;
    Ok(item)
}

fn valid_team() -> Result<&'static str> {
    TEAM.filter(|team| {
        team.len() == 10
            && team
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    })
    .context("This build has no trusted Developer ID team")
}

fn verify_signature(exe: &Path) -> Result<()> {
    let team = valid_team()?;
    let requirement = format!(
        r#"=anchor apple generic and identifier "com.kagayoi.prunlet" and certificate leaf[subject.OU] = "{team}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized"#
    );
    let output = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "-R", &requirement])
        .arg(exe)
        .output()?;
    ensure!(
        output.status.success(),
        "Developer ID or notarization check failed"
    );
    Ok(())
}

fn copy_executable(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = security::create_file(path)?;
    file.write_all(bytes)?;
    file.set_permissions(Permissions::from_mode(0o700))?;
    file.sync_all()?;
    Ok(())
}

pub(crate) fn install(root: &Path) -> Result<Value> {
    ensure!(is_hex(COMMIT, 40), "Installation requires a release build");
    let current = std::env::current_exe()?;
    verify_signature(&current)?;
    let root = path::resolve(root, true, false)?;
    let parent = root.parent().context("Missing installation parent")?;
    let parents = path::pin_directories(parent)?;
    ensure!(!root.exists(), "Installation directory already exists");
    let recovery = root.join("recovery");
    let data = ConfigData {
        backup_directory: recovery
            .to_str()
            .context("Recovery path must be Unicode")?
            .into(),
        capacity_default_migration_version: 1,
        ..Default::default()
    };
    data.validate_fields()?;
    let stage = parent.join(format!(
        ".prunlet-install-{}",
        uuid::Uuid::new_v4().simple()
    ));
    security::create_dir(&stage)?;
    let result = (|| {
        security::create_dir(&stage.join("bin"))?;
        security::create_dir(&stage.join("recovery"))?;
        security::create_file(&stage.join(LOCK))?.sync_all()?;
        let candidate = stage.join("bin/prunlet");
        copy_executable(
            &candidate,
            &super::read_plain_file(&current, MAX_PACKAGE as usize, true)?,
        )?;
        verify_signature(&candidate)?;
        super::write_new_plain_file(&stage.join("config.json"), &serde_json::to_vec(&data)?)?;
        File::open(stage.join("bin"))?.sync_all()?;
        File::open(&stage)?.sync_all()?;
        parents.verify()?;
        let from = CString::new(stage.as_os_str().as_bytes())?;
        let to = CString::new(root.as_os_str().as_bytes())?;
        // 既存の設定を上書きしない。公開する時点で全配置が揃っている。
        if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        File::open(parent)?.sync_all()?;
        Ok(
            json!({"status":"installed","executable":root.join("bin/prunlet"),"configPath":root.join("config.json")}),
        )
    })();
    if result.is_err() && stage.exists() {
        eprintln!("Unpublished installation retained at {}", stage.display());
    }
    result
}

pub(crate) fn enter(config: &Path, command: &str, args: &[String]) -> Result<Option<File>> {
    let Some(root) = installation_root()? else {
        return Ok(None);
    };
    let bin = root.join("bin");
    let exe = bin.join("prunlet");
    let ancestors = path::pin_directories(&bin)?;
    private(&root, true)?;
    private(&bin, true)?;
    let lock = private(&root.join(LOCK), false)?;
    let file = lock.file.try_clone()?;
    if command == "mcp"
        && config == root.join("config.json")
        && valid_team().is_ok()
        && fs2::FileExt::try_lock_exclusive(&file).is_ok()
    {
        // 旧世代の入口が交換をまたいだ場合は再度更新を試さず現行へ渡す。
        let updated = match current_build(&exe, &build_info()) {
            Ok(true) => match update(&exe, &ancestors, &lock) {
                Ok(updated) => updated,
                Err(error) => {
                    eprintln!("Prunlet macOS startup update deferred: {error}");
                    false
                }
            },
            Ok(false) => true,
            Err(error) => return Err(error),
        };
        if updated {
            drop(file);
            drop(lock);
            return Err(Command::new(exe).args(args).exec().into());
        }
        // 排他を解いてから共用を取得する。別の更新者が交換した場合も下で照合する。
        fs2::FileExt::unlock(&file)?;
    }
    fs2::FileExt::lock_shared(&file)?;
    lock.verify_name()?;
    ancestors.verify()?;
    if !current_build(&exe, &build_info())? {
        drop(file);
        drop(lock);
        return Err(Command::new(exe).args(args).exec().into());
    }
    Ok(Some(file))
}

fn current_build(exe: &Path, expected: &Value) -> Result<bool> {
    let pinned = private(exe, false)?;
    let output = Command::new(exe)
        .arg("--macos-build-info")
        .stdin(Stdio::null())
        .output()?;
    ensure!(
        output.status.success(),
        "Cannot verify current Mac generation"
    );
    pinned.verify()?;
    Ok(parse_unique(&output.stdout)? == *expected)
}

fn request(url: &str, limit: u64, seconds: u32) -> Result<Vec<u8>> {
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    if let Some(root) = std::env::var_os("PRUNLET_MACOS_UPDATE_FIXTURE") {
        let name = hex::encode(Sha256::digest(url.as_bytes()));
        return super::read_plain_file(&PathBuf::from(root).join(name), limit as usize, true);
    }
    // curlrcを読まず、GitHubの認証情報を受け渡さない。転送の時間と実バイト数を両方制限する。
    let mut child = Command::new("/usr/bin/curl")
        .args([
            "--disable",
            "--fail",
            "--silent",
            "--location",
            "--max-redirs",
            "3",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--max-time",
            &seconds.to_string(),
            "--max-filesize",
            &limit.to_string(),
            "--header",
            "User-Agent: Prunlet-macOS",
            "--",
            url,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut bytes = Vec::new();
    let read = child
        .stdout
        .take()
        .context("Missing transfer stream")?
        .take(limit + 1)
        .read_to_end(&mut bytes);
    if read.is_err() || bytes.len() as u64 > limit {
        let _ = child.kill();
    }
    let status = child.wait()?;
    read?;
    ensure!(
        status.success() && bytes.len() as u64 <= limit,
        "GitHub response failed or exceeded its limit"
    );
    Ok(bytes)
}

fn api(endpoint: &str) -> Result<Value> {
    parse_unique(&request(
        &format!("https://api.github.com/repos/{REPO}/{endpoint}"),
        8 * 1024 * 1024,
        5,
    )?)
}

fn version(text: &str) -> Option<[u64; 3]> {
    let mut result = [0; 3];
    let mut parts = text.split('.');
    for value in &mut result {
        let part = parts.next()?;
        if part.is_empty()
            || !part.bytes().all(|b| b.is_ascii_digit())
            || (part.len() > 1 && part.starts_with('0'))
        {
            return None;
        }
        *value = part.parse().ok()?;
    }
    parts.next().is_none().then_some(result)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    protocol: u32,
    version: String,
    commit: String,
    runtime: String,
    bytes: u64,
    sha256: String,
}

fn read_entry(
    archive: &mut ZipArchive<Cursor<&[u8]>>,
    name: &str,
    maximum: u64,
) -> Result<Vec<u8>> {
    let entry = archive.by_name(name)?;
    ensure!(
        entry.is_file()
            && !entry.is_symlink()
            && !entry.encrypted()
            && entry.size() > 0
            && entry.size() <= maximum,
        "Unexpected package entry: {name}"
    );
    let mut bytes = Vec::new();
    let declared = entry.size();
    entry.take(declared + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 == declared,
        "Package entry length differs"
    );
    Ok(bytes)
}

fn executable_bytes(package: &[u8], candidate_version: &str, commit: &str) -> Result<Vec<u8>> {
    let mut archive = ZipArchive::new(Cursor::new(package))?;
    ensure!(archive.len() == 2, "Unexpected Mac package contents");
    let manifest: Manifest = serde_json::from_value(parse_unique(&read_entry(
        &mut archive,
        "manifest.json",
        4096,
    )?)?)?;
    ensure!(
        manifest.protocol == 1
            && manifest.version == candidate_version
            && manifest.commit == commit
            && manifest.runtime == "osx-arm64",
        "Mac package manifest identity differs"
    );
    let bytes = read_entry(&mut archive, "prunlet", MAX_PACKAGE)?;
    ensure!(
        bytes.len() >= 32
            && bytes[..8] == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]
            && bytes[12..16] == [2, 0, 0, 0],
        "Expected a thin arm64 Mach-O executable"
    );
    ensure!(
        manifest.bytes == bytes.len() as u64
            && hex::encode(Sha256::digest(&bytes)) == manifest.sha256,
        "Mac executable hash or length differs"
    );
    Ok(bytes)
}

pub(crate) fn package(output: &Path) -> Result<Value> {
    ensure!(is_hex(COMMIT, 40), "Packaging requires a release build");
    let current = std::env::current_exe()?;
    verify_signature(&current)?;
    let executable = super::read_plain_file(&current, MAX_PACKAGE as usize, true)?;
    let metadata = json!({
        "protocol": 1, "version": crate::VERSION, "commit": COMMIT, "runtime": "osx-arm64",
        "bytes": executable.len(), "sha256": hex::encode(Sha256::digest(&executable))
    });
    let output = path::resolve(output, true, false)?;
    let parent = output.parent().context("Missing package directory")?;
    let parents = path::pin_directories(parent)?;
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    writer.start_file(
        "prunlet",
        SimpleFileOptions::default().unix_permissions(0o700),
    )?;
    writer.write_all(&executable)?;
    writer.start_file(
        "manifest.json",
        SimpleFileOptions::default().unix_permissions(0o600),
    )?;
    writer.write_all(&serde_json::to_vec(&metadata)?)?;
    let package = writer.finish()?.into_inner();
    ensure!(
        package.len() as u64 <= MAX_PACKAGE,
        "Mac ZIP exceeds its capacity limit"
    );
    ensure!(
        executable_bytes(&package, crate::VERSION, COMMIT)? == executable,
        "Mac ZIP verification failed"
    );
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&output)?;
    file.write_all(&package)?;
    file.sync_all()?;
    parents.verify()?;
    ensure!(
        super::read_plain_file(&output, MAX_PACKAGE as usize, true)? == package,
        "Written Mac ZIP differs"
    );
    Ok(json!({
        "path": output, "commit": COMMIT, "version": crate::VERSION, "bytes": package.len(),
        "sha256": hex::encode(Sha256::digest(&package)), "runtime": "osx-arm64"
    }))
}

fn update(exe: &Path, ancestors: &path::DirectoryLease, lock: &Pinned) -> Result<bool> {
    ensure!(is_hex(COMMIT, 40), "Installed Mac commit is unknown");
    let release = api("releases/latest")?;
    let tag = release["tag_name"]
        .as_str()
        .context("Release tag is missing")?;
    let candidate_version = tag.strip_prefix('v').context("Unsupported release tag")?;
    let newer = version(candidate_version).context("Invalid release version")?;
    let installed = version(crate::VERSION).context("Invalid installed version")?;
    if newer <= installed {
        return Ok(false);
    }
    ensure!(
        release["draft"] == false && release["prerelease"] == false,
        "Release is not stable"
    );
    let assets = release["assets"]
        .as_array()
        .context("Release assets missing")?;
    let mut matching = assets.iter().filter(|a| a["name"] == ASSET);
    let Some(asset) = matching.next() else {
        return Ok(false);
    };
    ensure!(
        matching.next().is_none() && asset["state"] == "uploaded",
        "Ambiguous Mac release asset"
    );
    let size = asset["size"]
        .as_u64()
        .filter(|n| *n > 0 && *n <= MAX_PACKAGE)
        .context("Invalid asset size")?;
    let digest = asset["digest"]
        .as_str()
        .and_then(|s| s.strip_prefix("sha256:"))
        .filter(|s| is_hex(s, 64))
        .context("Release asset has no SHA-256")?;
    let expected_url = format!("https://github.com/{REPO}/releases/download/{tag}/{ASSET}");
    ensure!(
        asset["browser_download_url"] == expected_url,
        "Unexpected release asset URL"
    );
    let candidate = api(&format!("commits/{tag}"))?;
    let commit = candidate["sha"]
        .as_str()
        .filter(|s| is_hex(s, 40))
        .context("Invalid release commit")?;
    let relation = api(&format!("compare/{COMMIT}...{commit}?per_page=1"))?;
    let main = api(&format!("compare/{commit}...main?per_page=1"))?;
    ensure!(
        relation["status"] == "ahead"
            && matches!(main["status"].as_str(), Some("ahead" | "identical")),
        "Release is not a newer main descendant"
    );
    let package = request(&expected_url, size, 30)?;
    ensure!(
        package.len() as u64 == size
            && hex::encode(Sha256::digest(&package)).eq_ignore_ascii_case(digest),
        "Release ZIP differs from GitHub metadata"
    );
    let bytes = executable_bytes(&package, candidate_version, commit)?;
    let staged = exe.with_file_name(NEXT);
    match fs::symlink_metadata(&staged) {
        Ok(_) => {
            // 中断で残った固定名だけを片付ける。不明なリンク・所有者は保全して延期する。
            let previous = private(&staged, false)?;
            previous.verify()?;
            ancestors.verify()?;
            fs::remove_file(&staged)?;
        }
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    copy_executable(&staged, &bytes)?;
    let staged_pin = private(&staged, false)?;
    verify_signature(&staged)?;
    ensure!(
        current_build(
            &staged,
            &json!({
                "version":candidate_version,"commit":commit,"team":valid_team()?,"runtime":"osx-arm64","protocol":1
            })
        )?,
        "Signed executable metadata differs"
    );
    staged_pin.verify()?;
    lock.verify_name()?;
    ancestors.verify()?;
    let directory = File::open(exe.parent().context("Missing installation bin")?)?;
    let installed = private(exe, false)?;
    installed.verify()?;
    // 同じinodeへの上書きを避け、すべての確認後に名前だけを原子的に切り替える。
    fs::rename(&staged, exe)?;
    if let Err(error) = directory.sync_all() {
        eprintln!("Prunlet Mac generation was replaced, but directory sync reported: {error}");
    }
    Ok(true)
}
