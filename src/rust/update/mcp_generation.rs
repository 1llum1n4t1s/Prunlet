//! MCP接続の寿命を配置先exeから切り離し、要求ごとに検証済み世代を固定する。
use super::{budget, coordinator as core};
use crate::{
    config::Config,
    platform::windows::{self as native, PinnedFile, path},
    protocol::mcp_proxy::{Generation, RetryLater},
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::Path,
};
use windows_sys::Win32::{
    Foundation::{GENERIC_READ, GENERIC_WRITE},
    Storage::FileSystem::{
        DELETE, ExtendedFileIdType, FILE_ADD_SUBDIRECTORY, FILE_FLAG_BACKUP_SEMANTICS,
        FILE_FLAG_OPEN_REPARSE_POINT, FILE_ID_DESCRIPTOR, FILE_LIST_DIRECTORY,
        FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, OpenFileById, READ_CONTROL,
    },
};

pub const CACHE: &str = ".prunlet-mcp-generations";
pub const PENDING_PREFIX: &str = ".prunlet-mcp-pending-";
pub const RETIRED_PREFIX: &str = ".prunlet-mcp-retired-";
const OWNER: &str = ".prunlet-mcp-owner.json";
const CLEANUP_GATE: &str = ".prunlet-mcp-cleanup-in-progress";
const CLEANUP_UNCERTAIN: &str = "MCP generation cleanup is uncertain. The cleanup gate was retained and automatic retry is prohibited. Manually inspect the original generation paths and Windows Recycle Bin, then explicitly acknowledge with mcp-cache-maintain --ack-interrupted-cleanup. A separate --apply request is required for further cleanup.";

struct Lease {
    _parents: path::DirectoryLease,
    _source: PinnedFile,
    _product: PinnedFile,
    _shadow: PinnedFile,
}

struct OwnedGeneration {
    directory: PinnedFile,
    executable: PinnedFile,
    marker: PinnedFile,
}

fn private_directory(directory: &Path) -> Result<PinnedFile> {
    let pin = PinnedFile::open(directory, FILE_READ_ATTRIBUTES | READ_CONTROL, 3)?;
    let id = pin.identity()?;
    ensure!(
        id.is_directory() && !id.is_reparse(),
        "MCP generation directory is not a plain directory."
    );
    native::security::verify_private_security(pin.raw(), true, false)?;
    native::reject_named_streams(directory)?;
    pin.verify_named()?;
    Ok(pin)
}

fn owner(root: &Path, hash: Option<&str>) -> Value {
    json!({"product":"Prunlet","schema":1,"purpose":"mcp-generation","installationRoot":root.to_string_lossy(),"executableSha256":hash})
}

fn new_private_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let handle = native::security::create_private_file(path)?;
    let pin = PinnedFile::from_handle(path.to_path_buf(), handle)?;
    let mut output = core::stream(&pin)?;
    output.write_all(bytes)?;
    output.sync_all()?;
    pin.verify_named()?;
    Ok(())
}

fn check_owner(directory: &Path, expected: &Value) -> Result<()> {
    let file = directory.join(OWNER);
    let pin = core::plain(&file, GENERIC_READ | READ_CONTROL, FILE_SHARE_READ)?;
    native::security::verify_private_member_security(pin.raw(), false)?;
    native::reject_named_streams(&file)?;
    let mut bytes = Vec::new();
    core::stream(&pin)?.take(65537).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 65536,
        "MCP generation ownership record is too large."
    );
    let actual = crate::json::parse_unique(&bytes)?;
    ensure!(
        &actual == expected,
        "MCP generation ownership differs; existing data was retained."
    );
    pin.verify_named()?;
    Ok(())
}

fn reopen_directory(pin: &PinnedFile, name: &Path, access: u32, share: u32) -> Result<PinnedFile> {
    // パスを追わず、保持中handleと128bit File IDから同じ実体だけを開く。
    // ReOpenFileへエラー時にfallbackする経路は設けない。
    let expected = pin.identity()?;
    let mut descriptor: FILE_ID_DESCRIPTOR = unsafe { std::mem::zeroed() };
    descriptor.dwSize = std::mem::size_of::<FILE_ID_DESCRIPTOR>() as u32;
    descriptor.Type = ExtendedFileIdType;
    descriptor.Anonymous.ExtendedFileId.Identifier = expected.id;
    let handle = unsafe {
        native::OwnedHandle::from_raw(OpenFileById(
            pin.raw(),
            &descriptor,
            access,
            share,
            std::ptr::null(),
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        ))?
    };
    let reopened = PinnedFile::from_handle(name.to_path_buf(), handle)?;
    let actual = reopened.identity()?;
    ensure!(
        expected.same_object(&actual) && expected.attributes == actual.attributes,
        "MCP generation directory changed while reopening its handle."
    );
    Ok(reopened)
}

fn published_members(directory: &PinnedFile, executable: bool) -> Result<()> {
    let names = native::directory_names(directory.raw())?;
    ensure!(
        names.len() == if executable { 2 } else { 1 }
            && names.iter().any(|name| name == OWNER)
            && (!executable || names.iter().any(|name| name == "prunlet.exe")),
        "Unknown MCP generation members were retained."
    );
    Ok(())
}

fn publish_directory(
    root: &Path,
    directory: &Path,
    expected: &Value,
    product: Option<(&PinnedFile, &str)>,
) -> Result<()> {
    // 中断した作成物は別名で保持する。最終名には完成・照合済みの世代だけを公開する。
    let pending = root.join(format!("{PENDING_PREFIX}{}", uuid::Uuid::new_v4().simple()));
    let created = PinnedFile::from_handle(
        pending.clone(),
        native::security::create_private_fixed_directory(&pending)?,
    )?;
    let initial = created.identity()?;
    new_private_file(&pending.join(OWNER), &serde_json::to_vec(expected)?)?;
    if let Some((product, hash)) = product {
        let executable = pending.join("prunlet.exe");
        let handle = native::security::create_private_file(&executable)?;
        let pin = PinnedFile::from_handle(executable, handle)?;
        let mut input = core::stream(product)?;
        let length = input.metadata()?.len();
        core::copy_verified(&mut input, &mut core::stream(&pin)?, length, hash)?;
        pin.verify_named()?;
        drop(pin);
        drop(open_shadow(&pending.join("prunlet.exe"), hash)?);
    }
    drop(private_directory(&pending)?);
    check_owner(&pending, expected)?;
    published_members(&created, product.is_some())?;
    created.verify_named()?;
    // 作成handleのDELETE共有禁止を解除する間も元実体への参照を保つ。
    let retained = reopen_directory(&created, &pending, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
    drop(created);
    let source = PinnedFile::open(
        &pending,
        DELETE | FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | READ_CONTROL,
        FILE_SHARE_READ,
    )?;
    let identity = source.identity()?;
    ensure!(
        initial.same_object(&identity)
            && initial.attributes == identity.attributes
            && identity.is_directory()
            && !identity.is_reparse(),
        "Pending generation directory changed before publication."
    );
    retained.verify_named()?;
    native::security::verify_private_security(source.raw(), true, false)?;
    ensure!(
        native::named_streams(source.raw())?.is_empty(),
        "Pending generation has named streams."
    );
    published_members(&source, product.is_some())?;
    check_owner(&pending, expected)?;
    if let Some((_, hash)) = product {
        drop(open_shadow(&pending.join("prunlet.exe"), hash)?);
    }
    let parent_path = directory.parent().context("Missing generation parent")?;
    let _parents = path::pin_directories(parent_path)?;
    let parent = PinnedFile::open(parent_path, FILE_ADD_SUBDIRECTORY | FILE_READ_ATTRIBUTES, 3)?;
    source.verify_named()?;
    native::security::rename_fixed(
        source.raw(),
        parent.raw(),
        directory
            .file_name()
            .and_then(|s| s.to_str())
            .context("Invalid generation leaf")?,
    )?;
    Ok(())
}

fn open_shadow(path: &Path, hash: &str) -> Result<PinnedFile> {
    let pin = core::plain(path, GENERIC_READ | READ_CONTROL, FILE_SHARE_READ)?;
    native::security::verify_private_member_security(pin.raw(), false)?;
    native::reject_named_streams(path)?;
    ensure!(
        core::hash_stream(&mut core::stream(&pin)?)?.eq_ignore_ascii_case(hash),
        "MCP generation executable hash differs; existing data was retained."
    );
    pin.verify_named()?;
    Ok(pin)
}

pub fn resolve(config: &Path) -> Result<Generation> {
    let root = core::installation_root(config)?;
    // installerはmigrationと登録の完了までこの排他を保持する。要求間でだけ取得する。
    let _installation = match core::InstallationMutexes::acquire(&root) {
        Ok(value) => value,
        Err(error) => {
            // 権限・不正handleは待機と混同しない。
            if error.to_string() == "Another Prunlet installation or update is in progress." {
                return Err(RetryLater(
                    "Prunlet installation is in progress; the request has not been sent.".into(),
                )
                .into());
            }
            return Err(error);
        }
    };
    if core::read_state(&root)?.is_some_and(|s| s.phase != "idle") {
        return Err(RetryLater(
            "Prunlet update has not finished; the request has not been sent.".into(),
        )
        .into());
    }
    let parents = path::pin_directories(&root.join("bin"))?;
    let source_path = root.join("source-info.json");
    let source = core::plain(&source_path, GENERIC_READ, FILE_SHARE_READ)?;
    native::reject_named_streams(&source_path)?;
    let provenance = core::read_provenance(&source_path)?;
    let canonical = root.join("bin/prunlet.exe");
    let product = core::plain(
        &canonical,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_DELETE,
    )?;
    native::reject_named_streams(&canonical)?;
    ensure!(
        core::hash_stream(&mut core::stream(&product)?)? == provenance.cli_hash,
        "Installed MCP product differs from its provenance."
    );
    let source_hash = core::hash_stream(&mut core::stream(&source)?)?;
    let cache = root.join(CACHE);
    if !core::exists(&cache)? {
        budget::ensure(&root, 65536)?;
        publish_directory(&root, &cache, &owner(&root, None), None)?;
    }
    let _cache = private_directory(&cache)?;
    check_owner(&cache, &owner(&root, None))?;
    let generation = cache.join(&provenance.cli_hash);
    let new_generation = !core::exists(&generation)?;
    if new_generation {
        let bytes = core::stream(&product)?.metadata()?.len();
        budget::ensure(&root, bytes + 65536)?;
        publish_directory(
            &root,
            &generation,
            &owner(&root, Some(&provenance.cli_hash)),
            Some((&product, &provenance.cli_hash)),
        )?;
    }
    let _generation = private_directory(&generation)?;
    check_owner(&generation, &owner(&root, Some(&provenance.cli_hash)))?;
    let executable = generation.join("prunlet.exe");
    let shadow = open_shadow(&executable, &provenance.cli_hash)?;
    source.verify_named()?;
    product.verify_named()?;
    ensure!(
        core::read_state(&root)?.is_none_or(|s| s.phase == "idle"),
        "Update began while fixing the MCP generation."
    );
    Ok(Generation {
        executable,
        identity: format!("{}:{source_hash}", provenance.cli_hash),
        lease: Box::new(Lease {
            _parents: parents,
            _source: source,
            _product: product,
            _shadow: shadow,
        }),
    })
}

pub fn prepare(config: &Path) -> Result<Value> {
    let generation = resolve(config)?;
    Ok(
        json!({"protocol":1,"status":"prepared","executablePath":generation.executable,"identity":generation.identity}),
    )
}

fn generation_hash(name: &str) -> bool {
    name.len() == 64 && name.bytes().all(|v| v.is_ascii_hexdigit())
}

fn known_members(directory: &PinnedFile) -> Result<()> {
    published_members(directory, true)
}

fn verify_cleanup_gate(gate: &PinnedFile) -> Result<()> {
    let id = gate.identity()?;
    ensure!(
        !id.is_directory()
            && !id.is_reparse()
            && id.reparse_tag == 0
            && id.links == 1
            && native::file_size(gate.raw())? == 0,
        "MCP cleanup gate is not an empty ordinary single-link file."
    );
    native::security::verify_private_security(gate.raw(), false, false)?;
    native::reject_named_streams(&gate.path)?;
    gate.verify_named()
}

fn create_cleanup_gate(cache: &Path) -> Result<PinnedFile> {
    let name = cache.join(CLEANUP_GATE);
    // create-newと作成時private ACLを既存のmetadata APIに委ねる。
    // 空file・ADSなしなので、既存budget treeに含めても追加使用量は0。
    let handle = native::security::create_private_file(&name)?;
    native::write_handle(handle.raw(), &[])?;
    let gate = PinnedFile::from_handle(name, handle)?;
    verify_cleanup_gate(&gate)?;
    Ok(gate)
}

fn clear_cleanup_gate(gate: PinnedFile) -> Result<()> {
    verify_cleanup_gate(&gate)?;
    let name = gate.path.clone();
    native::security::delete_fixed(gate.raw(), false)?;
    drop(gate);
    ensure!(
        !core::exists(&name)?,
        "MCP cleanup gate removal was not confirmed."
    );
    Ok(())
}

fn cleanup_confirmed(result: &Value, target: &Path) -> bool {
    result.get("dryRun") == Some(&Value::Bool(false))
        && result
            .get("items")
            .and_then(Value::as_array)
            .is_some_and(|items| {
                items.len() == 1
                    && items[0].get("path") == Some(&json!(target))
                    && matches!(
                        items[0].get("status").and_then(Value::as_str),
                        Some("recycled" | "permanently_deleted")
                    )
                    && items[0].get("error").is_none_or(Value::is_null)
            })
}

/// 明示ackはgateだけを解除する。同じ要求で世代の回収へ進まない。
pub fn acknowledge_cleanup(config: &Config) -> Result<Value> {
    let root = core::installation_root(&config.path)?;
    let _installation = core::InstallationMutexes::acquire(&root)?;
    ensure!(
        core::read_state(&root)?.is_none_or(|state| state.phase == "idle"),
        "Prunlet update has not finished."
    );
    let _parents = path::pin_directories(&root)?;
    let cache_path = root.join(CACHE);
    let gate_path = cache_path.join(CLEANUP_GATE);
    let response = |status: &str| {
        json!({
            "dryRun":false,"status":status,"gatePath":gate_path,
            "cleanupBlocked":false,"items":[]
        })
    };
    if !core::exists(&cache_path)? {
        return Ok(response("already_absent"));
    }
    let _cache_parents = path::pin_directories(&cache_path)?;
    let _cache = private_directory(&cache_path)?;
    let owner_pin = core::plain(
        &cache_path.join(OWNER),
        GENERIC_READ | READ_CONTROL,
        FILE_SHARE_READ,
    )?;
    check_owner(&cache_path, &owner(&root, None))?;
    if !core::exists(&gate_path)? {
        return Ok(response("already_absent"));
    }
    // 既存gateを開いた同じhandleでempty/private/single-link/noADS/nameを照合し、
    // metadataだけを解除する。未知の実体や置換先には触れない。
    let gate = native::security::open_lifecycle_delete(&gate_path)?;
    owner_pin.verify_named()?;
    clear_cleanup_gate(gate)?;
    Ok(response("acknowledged"))
}

/// 明示適用だけで未使用の正当な世代を回収する。pending/retiredは再送しない。
pub fn maintain(config: &Config, apply: bool) -> Result<Value> {
    let root = core::installation_root(&config.path)?;
    let _installation = core::InstallationMutexes::acquire(&root)?;
    ensure!(
        core::read_state(&root)?.is_none_or(|s| s.phase == "idle"),
        "Prunlet update has not finished."
    );
    let _parents = path::pin_directories(&root)?;
    let source_path = root.join("source-info.json");
    let source = core::plain(&source_path, GENERIC_READ, FILE_SHARE_READ)?;
    native::reject_named_streams(&source_path)?;
    let provenance = core::read_provenance(&source_path)?;
    let canonical = root.join("bin/prunlet.exe");
    let product = core::plain(&canonical, GENERIC_READ, FILE_SHARE_READ)?;
    native::reject_named_streams(&canonical)?;
    ensure!(
        core::hash_stream(&mut core::stream(&product)?)? == provenance.cli_hash,
        "Installed MCP product differs from its provenance."
    );
    let current = path::resolve(&std::env::current_exe()?, false, false)?;
    let cache_path = root.join(CACHE);
    let mut items = Vec::new();
    let mut cleanup_blocked = false;
    let listing = PinnedFile::open(&root, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, 3)?;
    for name in native::directory_names(listing.raw())? {
        if name.starts_with(PENDING_PREFIX) || name.starts_with(RETIRED_PREFIX) {
            items.push(json!({"path":root.join(name),"status":"retained","reason":"interrupted or previously attempted generation; automatic resend is prohibited"}));
        }
    }
    if core::exists(&cache_path)? {
        let _cache = private_directory(&cache_path)?;
        check_owner(&cache_path, &owner(&root, None))?;
        let gate_path = cache_path.join(CLEANUP_GATE);
        cleanup_blocked = core::exists(&gate_path)?;
        ensure!(
            !apply || !cleanup_blocked,
            "{CLEANUP_UNCERTAIN} Gate: {}",
            gate_path.display()
        );
        let cache = PinnedFile::open(&cache_path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, 3)?;
        for name in native::directory_names(cache.raw())? {
            if name == OWNER {
                continue;
            }
            if name == CLEANUP_GATE {
                items
                    .push(json!({"path":gate_path,"status":"retained","reason":CLEANUP_UNCERTAIN}));
                continue;
            }
            let Some(hash) = Some(name.as_str()).filter(|s| generation_hash(s)) else {
                items.push(json!({"path":cache_path.join(&name),"status":"retained","reason":"unknown generation name"}));
                continue;
            };
            let generation = cache_path.join(&name);
            let executable = generation.join("prunlet.exe");
            if hash.eq_ignore_ascii_case(&provenance.cli_hash) || current == executable {
                items.push(
                    json!({"path":generation,"status":"retained","reason":"current generation"}),
                );
                continue;
            }
            let inspection = (|| -> Result<Option<OwnedGeneration>> {
                // 所有を検証した当該要求だけCoreの限定permitへ引き渡す。
                // 元の名前のまま、snapshot捕捉まで外部のwrite/deleteを禁止する。
                let directory = PinnedFile::open(
                    &generation,
                    FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | READ_CONTROL,
                    FILE_SHARE_READ,
                )?;
                let identity = directory.identity()?;
                ensure!(
                    identity.is_directory() && !identity.is_reparse(),
                    "Generation is not a plain directory."
                );
                native::security::verify_private_security(directory.raw(), true, false)?;
                ensure!(
                    native::named_streams(directory.raw())?.is_empty(),
                    "Generation directory has named streams."
                );
                directory.verify_named()?;
                // WRITE権限を保持して実行image・queue worker・proxy leaseと競合させる。
                // READ/DELETE共有はCoreのsnapshot捕捉に必要。
                let image = core::plain(
                    &executable,
                    GENERIC_READ | GENERIC_WRITE | DELETE | READ_CONTROL,
                    FILE_SHARE_READ | FILE_SHARE_DELETE,
                )?;
                native::security::verify_private_member_security(image.raw(), false)?;
                ensure!(
                    native::named_streams(image.raw())?.is_empty(),
                    "Generation executable has named streams."
                );
                ensure!(
                    core::hash_stream(&mut core::stream(&image)?)?.eq_ignore_ascii_case(hash),
                    "Generation executable hash differs."
                );
                let marker_path = generation.join(OWNER);
                let marker = core::plain(
                    &marker_path,
                    GENERIC_READ | READ_CONTROL,
                    FILE_SHARE_READ | FILE_SHARE_DELETE,
                )?;
                native::security::verify_private_member_security(marker.raw(), false)?;
                ensure!(
                    native::named_streams(marker.raw())?.is_empty(),
                    "Generation marker has named streams."
                );
                let mut bytes = Vec::new();
                core::stream(&marker)?.take(65537).read_to_end(&mut bytes)?;
                ensure!(
                    bytes.len() <= 65536
                        && crate::json::parse_unique(&bytes)? == owner(&root, Some(hash)),
                    "Generation ownership differs."
                );
                known_members(&directory)?;
                image.verify_named()?;
                marker.verify_named()?;
                directory.verify_named()?;
                if !apply {
                    return Ok(None);
                }
                Ok(Some(OwnedGeneration {
                    directory,
                    executable: image,
                    marker,
                }))
            })();
            match inspection {
                Err(error) => items.push(
                    json!({"path":generation,"status":"retained","reason":error.to_string()}),
                ),
                Ok(None) => items.push(json!({"path":generation,"status":"would_recycle"})),
                Ok(Some(fixed)) => {
                    // 不明結果・中断後に元hash名へ再送しない。Core呼出し前に
                    // 固定gateを永続化し、確認済み終端だけがこのhandleを除去する。
                    let gate = create_cleanup_gate(&cache_path)?;
                    // 検証済みhandleからCore snapshotへ引き渡し、この要求で一度だけ実行する。
                    let result = crate::files::recycle_owned_mcp_generation(
                        config,
                        fixed.directory,
                        fixed.executable,
                        fixed.marker,
                    );
                    match result {
                        Ok(result) if cleanup_confirmed(&result, &generation) => {
                            items.push(json!({"path":generation,"result":result}));
                            if let Err(error) = clear_cleanup_gate(gate) {
                                cleanup_blocked = true;
                                items.push(json!({"path":gate_path,"status":"retained","reason":format!("{CLEANUP_UNCERTAIN} {error}")}));
                            }
                        }
                        Ok(result) => {
                            cleanup_blocked = true;
                            items.push(json!({"path":generation,"result":result,"gatePath":gate_path,"reason":CLEANUP_UNCERTAIN}));
                        }
                        Err(error) => {
                            // Coreは送信開始のtyped情報を返さないため、Errを未送信と推測しない。
                            cleanup_blocked = true;
                            items.push(json!({"path":generation,"status":"retained","gatePath":gate_path,"reason":format!("{CLEANUP_UNCERTAIN} {error}")}));
                        }
                    }
                    if cleanup_blocked {
                        break;
                    }
                }
            }
        }
    }
    source.verify_named()?;
    product.verify_named()?;
    Ok(json!({"dryRun":!apply,"items":items,"cleanupBlocked":cleanup_blocked}))
}

/// 旧proxy世代も所有とhashで照合する。現在のcanonical世代である必要はない。
pub fn pin_proxy(config: &Path) -> Result<impl Send + 'static> {
    let root = core::installation_root(config)?;
    let current = path::resolve(&std::env::current_exe()?, false, false)?;
    let generation = current
        .parent()
        .context("Missing MCP generation directory")?;
    let hash = generation
        .file_name()
        .and_then(|v| v.to_str())
        .context("Invalid MCP generation name")?;
    ensure!(
        hash.len() == 64 && hash.bytes().all(|v| v.is_ascii_hexdigit()),
        "Proxy must run from a verified MCP generation."
    );
    ensure!(
        current.file_name().is_some_and(|v| v == "prunlet.exe")
            && generation.parent() == Some(root.join(CACHE).as_path()),
        "Proxy executable is outside its private generation."
    );
    let parents = path::pin_directories(generation)?;
    let cache = private_directory(&root.join(CACHE))?;
    check_owner(&root.join(CACHE), &owner(&root, None))?;
    let directory = private_directory(generation)?;
    check_owner(generation, &owner(&root, Some(hash)))?;
    let executable = open_shadow(&current, hash)?;
    Ok((parents, cache, directory, executable))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cleanup_gate_can_clear_only_for_one_confirmed_original_target() {
        let target = Path::new(r"D:\fixture\generation");
        for status in ["recycled", "permanently_deleted"] {
            assert!(cleanup_confirmed(
                &json!({"dryRun":false,"items":[{"path":target,"status":status}]}),
                target
            ));
        }
        for status in [
            "failed",
            "ambiguous",
            "already_absent",
            "would_recycle",
            "unknown",
        ] {
            assert!(!cleanup_confirmed(
                &json!({"dryRun":false,"items":[{"path":target,"status":status}]}),
                target
            ));
        }
        for result in [
            json!({"dryRun":true,"items":[{"path":target,"status":"recycled"}]}),
            json!({"dryRun":false,"items":[{"path":"another","status":"recycled"}]}),
            json!({"dryRun":false,"items":[]}),
            json!({"dryRun":false,"items":[{"path":target,"status":"recycled","error":"uncertain"}]}),
        ] {
            assert!(!cleanup_confirmed(&result, target));
        }
    }
}
