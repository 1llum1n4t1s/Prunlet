//! 取得失敗・未適用候補・適用済み来歴付き候補の後に次のreleaseが来ても、更新が恒久停止しないことの検証。
//! 実体のあるfixture（TEMP配下の一意なディレクトリ）で、`begin`・`receive_with`・`prepare_from`を
//! 実際に連ねる。fixtureはテスト側では削除しない（作業終了時にPrunletで清掃する）。
use super::manual_install_tests::{
    CANDIDATE, NEXT, applied, fixture_root, sha, state_bytes, write,
};
use super::*;
use crate::update::{
    http::Response,
    package::{PRODUCT_NAMES, Product},
    state::PublishedSlot,
};
use std::io::Cursor;
use std::os::windows::fs::OpenOptionsExt;
use zip::{ZipWriter, write::SimpleFileOptions};

const REPO: &str = "owner/repo";
const E0: &str = "a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0";
const E1: &str = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";
const E2: &str = "c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2";
const E3: &str = "d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3";

/// 配布ZIPと、その内容から決まる来歴・製品表。tagで製品の中身を変える。
struct Rel {
    commit: String,
    zip: Vec<u8>,
    hash: String,
    bodies: BTreeMap<String, Vec<u8>>,
    products: Vec<Product>,
}
fn exe(tag: &str) -> Vec<u8> {
    let mut v = vec![0u8; 70];
    v[..2].copy_from_slice(b"MZ");
    v[60..64].copy_from_slice(&64u32.to_le_bytes());
    v[64..68].copy_from_slice(b"PE\0\0");
    v[68..70].copy_from_slice(&0x8664u16.to_le_bytes());
    v.extend_from_slice(tag.as_bytes());
    v
}
fn release(commit: &str, tag: &str) -> Rel {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    let mut files = serde_json::Map::new();
    let mut bodies = BTreeMap::new();
    let mut products = Vec::new();
    for name in PRODUCT_NAMES {
        let leaf = name.strip_prefix("bin/").unwrap();
        let body = match leaf {
            "prunlet.exe" | "prunlet-hook.exe" => exe(&format!("{tag}-cli")),
            "prunlet-maintenance.exe" => exe(&format!("{tag}-maintenance")),
            _ => format!("{tag}-{leaf}").into_bytes(),
        };
        zip.start_file(name, SimpleFileOptions::default()).unwrap();
        std::io::Write::write_all(&mut zip, &body).unwrap();
        files.insert(
            name.into(),
            json!({"sha256": sha(&body), "bytes": body.len()}),
        );
        products.push(Product {
            name: name.into(),
            sha256: sha(&body),
            bytes: body.len() as u64,
        });
        bodies.insert(leaf.to_string(), body);
    }
    zip.start_file("package.json", SimpleFileOptions::default())
        .unwrap();
    std::io::Write::write_all(
        &mut zip,
        &serde_json::to_vec(&json!({
            "product":"Prunlet","schema":1,"repository":REPO,"defaultBranch":"main",
            "commitSha":commit,"commitVerification":"caller-asserted","runtime":"win-x64","files":files,
        }))
        .unwrap(),
    )
    .unwrap();
    let zip = zip.finish().unwrap().into_inner();
    Rel {
        commit: commit.into(),
        hash: sha(&zip),
        zip,
        bodies,
        products,
    }
}
fn info_bytes(rel: &Rel) -> Vec<u8> {
    source_info(
        &rel.products,
        REPO,
        "main",
        &rel.commit,
        "win-x64",
        &rel.hash,
        "https://api.github.com/repos/owner/repo/releases/assets/1",
    )
    .unwrap()
    .1
}
/// 導入済みの来歴を書く（stateとは無関係。手動導入・通常導入のどちらでも同じ形）。
fn install(root: &Path, rel: &Rel) {
    write(&root.join("source-info.json"), &info_bytes(rel));
}
fn download(root: &Path, rel: &Rel, truncated: bool) -> Result<bool> {
    let zip = rel.zip.clone();
    super::super::download::receive_with(
        root,
        &rel.commit,
        &rel.hash,
        zip.len() as u64,
        "https://example.invalid/package.zip",
        move |_| {
            let body = if truncated {
                zip[..zip.len() / 2].to_vec()
            } else {
                zip.clone()
            };
            Ok(Response {
                length: None,
                body: Box::new(Cursor::new(body)),
            })
        },
    )
}
fn prepare(root: &Path, rel: &Rel) -> Result<Value> {
    prepare_from(
        root,
        REPO,
        "main",
        &rel.commit,
        "win-x64",
        &rel.hash,
        rel.zip.len() as u64,
        1,
    )
}
fn state_of(root: &Path) -> UpdateState {
    read_state(root).unwrap().unwrap()
}
fn zips(root: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(stage_path(root))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("package"))
        .collect();
    names.sort();
    names
}
fn identity_of(path: &Path) -> native::FileIdentity {
    PinnedFile::open(path, FILE_READ_ATTRIBUTES, 7)
        .unwrap()
        .identity()
        .unwrap()
}
/// stage全体の（相対名, bytes）一覧。拒否ケースで「何も変わらない」ことの比較に使う。
fn snapshot(root: &Path) -> BTreeMap<String, Vec<u8>> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeMap<String, Vec<u8>>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(base, &path, out);
            } else {
                out.insert(
                    path.strip_prefix(base)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                    std::fs::read(&path).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(&stage_path(root), &stage_path(root), &mut out);
    out
}
fn stage_matches(root: &Path, rel: &Rel) {
    let stage = stage_path(root);
    for (leaf, body) in &rel.bodies {
        let path = if PRODUCTS.contains(&leaf.as_str()) {
            stage.join(leaf)
        } else {
            stage.join(auxiliary_path(leaf))
        };
        assert_eq!(std::fs::read(&path).unwrap(), *body, "{leaf}");
    }
    assert_eq!(
        std::fs::read(stage.join("source-info.json")).unwrap(),
        info_bytes(rel)
    );
}

// ---- download: 状態が記録した名前の書込み中ZIPの扱い ----

/// 取得失敗（途中書込み）の後の再取得は、記録済みの名前のまま同じ実体を上書きし、孤児を作らない。
#[test]
fn download_resumes_the_recorded_partial_package_in_place() {
    let root = fixture_root("dl-resume");
    let rel = release(E1, "r1");
    install(&root, &release(E0, "r0"));
    begin(&root, E1, E0).unwrap();
    assert!(download(&root, &rel, true).is_err());
    let failed = state_of(&root);
    assert_eq!(failed.package_status, "writing");
    let path = stage_path(&root).join(&failed.package_name);
    let before = identity_of(&path);
    assert!(download(&root, &rel, false).is_ok());
    let state = state_of(&root);
    assert_eq!(state.package_name, failed.package_name);
    assert_eq!(state.package_status, "ready");
    assert_eq!(zips(&root), vec![failed.package_name.clone()]);
    assert!(identity_of(&path).same_object(&before));
    assert_eq!(std::fs::read(&path).unwrap(), rel.zip);
}

/// 記録された名前のファイルが無い書込み中状態は、新しい名前を作らず同じ名前で作り直す。
#[test]
fn download_recreates_a_missing_recorded_partial_under_the_same_name() {
    let root = fixture_root("dl-missing");
    let rel = release(E1, "r1");
    install(&root, &release(E0, "r0"));
    begin(&root, E1, E0).unwrap();
    assert!(download(&root, &rel, true).is_err());
    let name = state_of(&root).package_name;
    // 記録済みの名前の部分ファイルが失われた状態（stateは書込み中のまま）。
    std::fs::remove_file(stage_path(&root).join(&name)).unwrap();
    assert!(download(&root, &rel, false).is_ok());
    assert_eq!(state_of(&root).package_name, name);
    assert_eq!(zips(&root), vec![name]);
}

/// 記録と異なるものは上書きせず、新しい名前へ逃がして保持する（照合は弱めない）。
#[test]
fn download_keeps_changed_unknown_and_stream_bearing_packages() {
    let rel = release(E1, "r1");
    // ready なのに内容が変わっている。
    let root = fixture_root("dl-changed");
    install(&root, &release(E0, "r0"));
    begin(&root, E1, E0).unwrap();
    download(&root, &rel, false).unwrap();
    let name = state_of(&root).package_name;
    write(&stage_path(&root).join(&name), b"changed by someone else");
    // 再取得（hashは同じ）。内容が記録と違うので同名のままでは上書きしない。
    download(&root, &rel, false).unwrap();
    assert_ne!(state_of(&root).package_name, name);
    assert_eq!(
        std::fs::read(stage_path(&root).join(&name)).unwrap(),
        b"changed by someone else"
    );
    // none（記録なし）なのに package.zip がある。
    let root = fixture_root("dl-unknown");
    install(&root, &release(E0, "r0"));
    begin(&root, E1, E0).unwrap();
    write(&stage_path(&root).join("package.zip"), b"unknown bytes");
    download(&root, &rel, false).unwrap();
    assert_ne!(state_of(&root).package_name, "package.zip");
    assert_eq!(
        std::fs::read(stage_path(&root).join("package.zip")).unwrap(),
        b"unknown bytes"
    );
    // writing だが記録名のファイルに代替ストリームがある。
    let root = fixture_root("dl-stream");
    install(&root, &release(E0, "r0"));
    begin(&root, E1, E0).unwrap();
    assert!(download(&root, &rel, true).is_err());
    let name = state_of(&root).package_name;
    let path = stage_path(&root).join(&name);
    let mut stream = path.clone().into_os_string();
    stream.push(":hidden");
    std::fs::write(&stream, b"stream bytes").unwrap();
    let partial = std::fs::read(&path).unwrap();
    download(&root, &rel, false).unwrap();
    assert_ne!(state_of(&root).package_name, name);
    assert_eq!(std::fs::read(&path).unwrap(), partial);
    assert_eq!(std::fs::read(&stream).unwrap(), b"stream bytes");
}

// ---- begin: 未適用のstageから次のreleaseへ ----

/// 取得失敗のあとに次のreleaseが出ても、旧候補の書込み中ZIPを引き継いで更新が進む。
#[test]
fn begin_accepts_the_next_release_after_a_failed_download() {
    let root = fixture_root("chain-failed-download");
    install(&root, &release(E0, "r0"));
    begin(&root, E1, E0).unwrap();
    assert!(download(&root, &release(E1, "r1"), true).is_err());
    let failed = state_of(&root);
    let next = release(E2, "r2");
    let result = begin(&root, E2, E0).expect("next release after a failed download");
    assert_eq!(result["status"], "ready");
    let state = state_of(&root);
    assert!(state.candidate_commit.eq_ignore_ascii_case(E2));
    assert_eq!(state.package_name, failed.package_name);
    assert_eq!(state.package_status, "writing");
    download(&root, &next, false).unwrap();
    prepare(&root, &next).unwrap();
    assert_eq!(zips(&root), vec![failed.package_name]);
    stage_matches(&root, &next);
}

/// 未適用の候補・cache_baseline付きの候補が続いても、毎回次のreleaseへ進める。
#[test]
fn begin_chains_across_unapplied_and_cache_baseline_candidates() {
    let root = fixture_root("chain-unapplied");
    install(&root, &release(E0, "r0"));
    let mut last = None;
    for (commit, tag) in [(E1, "r1"), (E2, "r2"), (E3, "r3")] {
        let rel = release(commit, tag);
        begin(&root, commit, E0).unwrap_or_else(|e| panic!("begin {tag}: {e:#}"));
        download(&root, &rel, false).unwrap();
        prepare(&root, &rel).unwrap();
        stage_matches(&root, &rel);
        last = Some(rel);
    }
    let state = state_of(&root);
    assert!(state.candidate_commit.eq_ignore_ascii_case(E3));
    assert_eq!(state.package_status, "ready");
    // 旧候補のZIPは同じ名前で上書きされ、stageに孤児を残さない。
    assert_eq!(zips(&root), vec![state.package_name.clone()]);
    // 導入済みの来歴には触れない。
    assert_eq!(
        std::fs::read(root.join("source-info.json")).unwrap(),
        info_bytes(&release(E0, "r0"))
    );
    drop(last);
}

/// 適用済みstage（prior_*付き）から作った候補が未適用のまま次のreleaseが来ても進める。
/// prior_*はそのまま引き継ぎ、cache_baselineと共存する。
#[test]
fn begin_chains_after_a_candidate_with_prior_stage_provenance() {
    let f = applied("chain-prior", false);
    assert_eq!(begin(&f.root, NEXT, CANDIDATE).unwrap()["status"], "ready");
    let first = state_of(&f.root);
    assert_eq!(first.prior_stage_commit, CANDIDATE);
    let next = "5555555555555555555555555555555555555555";
    let result = begin(&f.root, next, CANDIDATE).expect("candidate with prior provenance");
    assert_eq!(result["status"], "ready");
    let state = state_of(&f.root);
    assert!(state.candidate_commit.eq_ignore_ascii_case(next));
    assert_eq!(state.prior_stage_commit, first.prior_stage_commit);
    assert_eq!(state.prior_stage_info_sha256, first.prior_stage_info_sha256);
    assert_eq!(
        state.prior_previous_info_sha256,
        first.prior_previous_info_sha256
    );
    assert_eq!(state.prior_owner_sha256, first.prior_owner_sha256);
    assert_eq!(state.auxiliary_backup_sha256, first.auxiliary_backup_sha256);
    assert!(state.cache_baseline.is_some());
    state.validate().unwrap();
    // さらに続けても進める。
    assert_eq!(begin(&f.root, NEXT, CANDIDATE).unwrap()["status"], "ready");
}

/// 未知のファイル・ディレクトリは更新を止めず、byte単位で同一のまま保持され、容量に数えられる。
#[test]
fn begin_keeps_unknown_stage_entries_untouched() {
    let root = fixture_root("chain-unknown");
    install(&root, &release(E0, "r0"));
    let first = release(E1, "r1");
    begin(&root, E1, E0).unwrap();
    download(&root, &first, false).unwrap();
    prepare(&root, &first).unwrap();
    let stage = stage_path(&root);
    write(&stage.join("stray.bin"), b"unknown file");
    write(
        &stage.join("notes").join("memo.txt"),
        b"unknown directory entry",
    );
    write(
        &stage.join("package-0123456789abcdef0123456789abcdef.zip"),
        b"orphan zip",
    );
    let stray = identity_of(&stage.join("stray.bin"));
    let used = budget::measure(&root).unwrap();
    let second = release(E2, "r2");
    begin(&root, E2, E0).expect("unknown entries must not stop the update");
    assert_eq!(
        std::fs::read(stage.join("stray.bin")).unwrap(),
        b"unknown file"
    );
    assert!(identity_of(&stage.join("stray.bin")).same_object(&stray));
    assert_eq!(
        std::fs::read(stage.join("notes").join("memo.txt")).unwrap(),
        b"unknown directory entry"
    );
    assert_eq!(
        std::fs::read(stage.join("package-0123456789abcdef0123456789abcdef.zip")).unwrap(),
        b"orphan zip"
    );
    assert!(budget::measure(&root).unwrap() >= used);
    download(&root, &second, false).unwrap();
    prepare(&root, &second).unwrap();
    stage_matches(&root, &second);
    assert_eq!(
        std::fs::read(stage.join("stray.bin")).unwrap(),
        b"unknown file"
    );
}

/// 書込み対象の固定名の現物が記録と一致しなければ、従来どおり拒否し、stageもstateも変えない。
#[test]
fn begin_still_rejects_changed_fixed_files() {
    type Tamper = fn(&Path);
    let cases: [(&str, Tamper); 6] = [
        ("product", |stage| {
            write(&stage.join("prunlet-maintenance.exe"), b"changed")
        }),
        ("auxiliary", |stage| {
            write(&stage.join(auxiliary_path("PRUNLET.md")), b"changed")
        }),
        ("source-info", |stage| {
            write(&stage.join("source-info.json"), b"{\"changed\":true}")
        }),
        ("owner", |stage| {
            let root = stage.parent().unwrap();
            write(
                &stage.join(STAGE_OWNER_NAME),
                &owner_bytes(root, E3).unwrap(),
            )
        }),
        ("stream", |stage| {
            let mut name = stage.join("prunlet.exe").into_os_string();
            name.push(":hidden");
            std::fs::write(name, b"stream").unwrap()
        }),
        ("hard-link", |stage| {
            std::fs::hard_link(stage.join("prunlet-hook.exe"), stage.join("alias.bin")).unwrap()
        }),
    ];
    for (name, tamper) in cases {
        let root = fixture_root(&format!("reject-{name}"));
        install(&root, &release(E0, "r0"));
        let first = release(E1, "r1");
        begin(&root, E1, E0).unwrap();
        download(&root, &first, false).unwrap();
        prepare(&root, &first).unwrap();
        tamper(&stage_path(&root));
        let state_before = state_bytes(&root);
        let stage_before = snapshot(&root);
        let error = begin(&root, E2, E0).expect_err(&format!("accepted a changed {name}"));
        assert!(
            !format!("{error:#}").is_empty(),
            "{name}: refusal must explain itself"
        );
        assert_eq!(state_bytes(&root), state_before, "state changed: {name}");
        assert_eq!(snapshot(&root), stage_before, "stage changed: {name}");
    }
}

// ---- state: cache_baselineとprior_*の共存 ----

fn baseline(commit: &str) -> StageCacheBaseline {
    StageCacheBaseline {
        commit: commit.into(),
        owner_sha256: "A".repeat(64),
        source_info_sha256: "B".repeat(64),
        cli_sha256: "C".repeat(64),
        maintenance_sha256: "D".repeat(64),
        hook_sha256: "C".repeat(64),
        auxiliary_sha256: AUXILIARY_NAMES
            .iter()
            .map(|n| (format!("bin\\{n}"), "E".repeat(64)))
            .collect(),
    }
}
fn with_prior(mut state: UpdateState) -> UpdateState {
    state.candidate_commit = E2.into();
    state.stage_cleanup = "pending".into();
    state.prepared_installed_source_info_sha256 = "F".repeat(64);
    state.prior_stage_commit = E1.into();
    state.prior_stage_info_sha256 = "1".repeat(64);
    state.prior_previous_info_sha256 = "2".repeat(64);
    state.prior_owner_sha256 = "3".repeat(64);
    state.prior_cli_sha256 = "4".repeat(64);
    state.prior_maintenance_sha256 = "5".repeat(64);
    state.prior_hook_sha256 = "4".repeat(64);
    state.prior_auxiliary_sha256 = Some(
        AUXILIARY_NAMES
            .iter()
            .map(|n| (format!("bin\\{n}"), "6".repeat(64)))
            .collect(),
    );
    state
}
#[test]
fn state_allows_cache_baseline_with_prior_provenance_and_absent_hashes() {
    let mut state = with_prior(UpdateState::default());
    state.cache_baseline = Some(baseline(E0));
    state.validate().expect("coexistence must be allowed");
    // 存在しないパスは空文字で表す。
    let mut empty = baseline(E0);
    empty.source_info_sha256.clear();
    empty
        .auxiliary_sha256
        .insert("bin\\PRUNLET.md".into(), String::new());
    state.cache_baseline = Some(empty);
    state.validate().expect("absent hashes must be allowed");
    // 空でも16進でもない値、補助製品の欠落、commitの不正は従来どおり拒否する。
    for corrupt in [
        |b: &mut StageCacheBaseline| b.owner_sha256 = "xyz".into(),
        |b: &mut StageCacheBaseline| b.cli_sha256 = "A".repeat(63),
        |b: &mut StageCacheBaseline| {
            b.auxiliary_sha256.remove("bin\\PRUNLET.md");
        },
        |b: &mut StageCacheBaseline| b.commit = "short".into(),
    ] {
        let mut broken = state.clone();
        let mut b = baseline(E0);
        corrupt(&mut b);
        broken.cache_baseline = Some(b);
        assert!(broken.validate().is_err());
    }
    // 同じcommitを指しても、来歴のhashが食い違うこと（assetの差し替え）は許す（恒久停止を作らない）。
    let mut replaced = with_prior(UpdateState::default());
    let mut b = baseline(E1);
    b.source_info_sha256 = "9".repeat(64);
    replaced.cache_baseline = Some(b);
    replaced
        .validate()
        .expect("a replaced asset must not stop the update");
    // prior_*が不完全なままの共存も拒否する。
    let mut partial = with_prior(UpdateState::default());
    partial.prior_owner_sha256.clear();
    partial.cache_baseline = Some(baseline(E0));
    assert!(partial.validate().is_err());
}

// ---- write_state: 読取り中の共有違反 ----

fn reader_holding(path: &Path) -> std::fs::File {
    std::fs::OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .open(path)
        .unwrap()
}
fn pending_files(root: &Path) -> Vec<String> {
    std::fs::read_dir(root)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with(".prunlet-update-state.") && n.ends_with(".pending"))
        .collect()
}
/// stateを読取り中のCLI・MCPがいても、短時間なら再試行で公開でき、一時ファイルを残さない。
#[test]
fn write_state_retries_a_sharing_violation_and_leaves_no_pending_file() {
    let root = fixture_root("write-state-retry");
    write_state(&root, &UpdateState::default()).unwrap();
    let held = reader_holding(&root.join(STATE_NAME));
    let releaser = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(150));
        drop(held);
    });
    let next = UpdateState {
        package_status: "writing".into(),
        ..Default::default()
    };
    write_state(&root, &next).expect("a short sharing violation must be retried");
    releaser.join().unwrap();
    assert_eq!(state_of(&root).package_status, "writing");
    assert!(
        pending_files(&root).is_empty(),
        "{:?}",
        pending_files(&root)
    );
}
/// 最後まで公開できなければ失敗を返すが、一時ファイルは削除し、元のstateは変わらない。
#[test]
fn write_state_removes_its_temporary_file_when_every_retry_fails() {
    let root = fixture_root("write-state-fail");
    write_state(&root, &UpdateState::default()).unwrap();
    let before = state_bytes(&root);
    let held = reader_holding(&root.join(STATE_NAME));
    let next = UpdateState {
        package_status: "writing".into(),
        ..Default::default()
    };
    assert!(write_state(&root, &next).is_err());
    drop(held);
    assert_eq!(state_bytes(&root), before);
    assert!(
        pending_files(&root).is_empty(),
        "{:?}",
        pending_files(&root)
    );
}

// ---- slot: 書込み中のslotを記録済みのgenerationのまま再利用する ----

#[test]
fn slot_acquire_reuses_a_recorded_partial_slot_and_keeps_unsafe_ones() {
    let root = fixture_root("slot-partial");
    ensure_slots(&root).unwrap();
    let mut first = super::super::slot::acquire(&root, "cli", None, 100).unwrap();
    std::io::Write::write_all(&mut first.file, b"partial").unwrap();
    let generation = first.generation.clone();
    drop(first);
    let path = root
        .join(SLOTS_NAME)
        .join(format!("slot-cli-{generation}.bin"));
    let before = identity_of(&path);
    let previous = PublishedSlot {
        generation: generation.clone(),
        sha256: sha(b"whatever"),
        bytes: 100,
        status: "writing".into(),
    };
    let lease = super::super::slot::acquire(&root, "cli", Some(&previous), 100).unwrap();
    assert_eq!(lease.generation, generation);
    // 部分書込みは検証済みの再利用ではない。必ず書き直す側に入る。
    assert!(!lease.reused);
    assert!(identity_of(&path).same_object(&before));
    drop(lease);
    // 記録名のファイルが無い場合も、新しいgenerationを作らず同じ名前で作り直す。
    std::fs::remove_file(&path).unwrap();
    let lease = super::super::slot::acquire(&root, "cli", Some(&previous), 100).unwrap();
    assert_eq!(lease.generation, generation);
    assert!(path.exists());
    drop(lease);
    // 代替ストリームがあれば保持して新しいgenerationを使う。
    let mut stream = path.clone().into_os_string();
    stream.push(":hidden");
    std::fs::write(&stream, b"stream").unwrap();
    let lease = super::super::slot::acquire(&root, "cli", Some(&previous), 100).unwrap();
    assert_ne!(lease.generation, generation);
    assert_eq!(std::fs::read(&stream).unwrap(), b"stream");
}

// ---- 導入mutex鍵: PowerShellのToLowerInvariantと一致する ----

fn key_of(text: &str) -> String {
    hex::encode_upper(Sha256::digest(text.as_bytes()))
}
#[test]
fn installation_key_matches_dotnet_to_lower_invariant() {
    // ASCIIの大小・末尾の区切りの違いは従来どおり一致する。
    assert_eq!(
        installation_key(Path::new(r"C:\Users\Alice\.local\Prunlet")),
        key_of(r"c:\users\alice\.local\prunlet")
    );
    // .NETのToLowerInvariantはU+0130を変えず、語末のΣもσにする（Rustのstr::to_lowercaseはi+結合点、ς）。
    assert_eq!(
        installation_key(Path::new("C:\\Users\\\u{130}\\\u{3a3}")),
        key_of("c:\\users\\\u{130}\\\u{3c3}")
    );
    assert_eq!(
        installation_key(Path::new("C:\\Users\\\u{3a3}")),
        key_of("c:\\users\\\u{3c3}")
    );
}

/// 全コードポイント（サロゲートを除く）で、`invariant_lower`が.NETの`ToLowerInvariant()`と一致する。
/// 基準はPowerShellで書き出した「1文字を変えるコードポイント→変換後」の一覧
/// （`scripts/Dump-DotNetLowering.ps1`）で、環境変数`PRUNLET_DOTNET_LOWER_REFERENCE`にその絶対パスを
/// 渡して`--ignored`付きで実行する。基準なしでは成功扱いにせず、通常のテストからは外している。
#[test]
#[ignore = "requires PRUNLET_DOTNET_LOWER_REFERENCE from scripts/Dump-DotNetLowering.ps1"]
fn installation_key_lowering_matches_dotnet_for_every_code_point() {
    let reference = std::env::var("PRUNLET_DOTNET_LOWER_REFERENCE")
        .expect("PRUNLET_DOTNET_LOWER_REFERENCE must name the dumped reference file");
    let mut changed = BTreeMap::<u32, Vec<u32>>::new();
    for line in std::fs::read_to_string(reference).unwrap().lines() {
        let (cp, lowered) = line.split_once(':').unwrap();
        changed.insert(
            u32::from_str_radix(cp, 16).unwrap(),
            lowered
                .split(',')
                .map(|v| u32::from_str_radix(v, 16).unwrap())
                .collect(),
        );
    }
    assert!(changed.len() > 1000, "the reference file looks truncated");
    let mut checked = 0u32;
    let mut mismatches = Vec::new();
    for cp in 0..=0x10FFFFu32 {
        let Some(c) = char::from_u32(cp) else {
            continue;
        };
        let expected = changed.get(&cp).cloned().unwrap_or_else(|| vec![cp]);
        let actual: Vec<u32> = invariant_lower(&c.to_string())
            .chars()
            .map(|c| c as u32)
            .collect();
        checked += 1;
        if actual != expected {
            mismatches.push(format!("U+{cp:04X}: rust {actual:X?} dotnet {expected:X?}"));
        }
    }
    assert!(
        mismatches.is_empty(),
        "{} of {checked} code points differ: {:?}",
        mismatches.len(),
        mismatches
    );
    eprintln!(
        "compared {checked} code points ({} changed by .NET)",
        changed.len()
    );
}

/// 書込み中のslotは、記録済みのsha・bytesが新しい製品と一致していても、検証だけで済ませず必ず書き直す。
#[test]
fn prepare_rewrites_an_interrupted_slot_under_its_recorded_generation() {
    let root = fixture_root("slot-rewrite");
    install(&root, &release(E0, "r0"));
    let rel = release(E1, "r1");
    begin(&root, E1, E0).unwrap();
    download(&root, &rel, false).unwrap();
    prepare(&root, &rel).unwrap();
    let ready = state_of(&root);
    let slot = ready.slot_cli.clone().unwrap();
    let path = root
        .join(SLOTS_NAME)
        .join(format!("slot-cli-{}.bin", slot.generation));
    // 同じ製品のslotが書込み中に中断し、中身が壊れた状態（記録のshaは新しい製品と同じ）。
    let mut interrupted = ready.clone();
    interrupted.slot_cli.as_mut().unwrap().status = "writing".into();
    write_state(&root, &interrupted).unwrap();
    std::fs::write(&path, b"torn").unwrap();
    let before = identity_of(&path);
    let result = prepare(&root, &rel).unwrap();
    assert!(
        result["warnings"]
            .to_string()
            .contains("interrupted product slot was resumed"),
        "{result}"
    );
    let after = state_of(&root);
    assert_eq!(after.slot_cli.as_ref().unwrap().generation, slot.generation);
    assert_eq!(after.slot_cli.as_ref().unwrap().status, "ready");
    assert_eq!(std::fs::read(&path).unwrap(), rel.bodies["prunlet.exe"]);
    assert!(identity_of(&path).same_object(&before));
    assert_eq!(
        std::fs::read_dir(root.join(SLOTS_NAME))
            .unwrap()
            .filter(|e| e
                .as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("slot-cli-"))
            .count(),
        1
    );
}

/// 切替が準備の途中で中断してprevious-source-info.jsonが先に書かれた場合は、その現物のhashを
/// 旧hashとして引き継ぐ。記録済みでも準備時の導入済みhashでもない内容は記録せず、保持するだけ。
#[test]
fn begin_carries_an_interrupted_previous_source_info_only_when_it_is_recognized() {
    let f = applied("previous-info", false);
    begin(&f.root, NEXT, CANDIDATE).unwrap();
    let first = state_of(&f.root);
    let previous = f.stage.join("previous-source-info.json");
    // 準備時の導入済み来歴そのもの（切替の書込みが済んだ後に中断した状態）。
    let installed = std::fs::read(f.root.join("source-info.json")).unwrap();
    write(&previous, &installed);
    let next = "5555555555555555555555555555555555555555";
    begin(&f.root, next, CANDIDATE).unwrap();
    assert_eq!(
        state_of(&f.root).prior_previous_info_sha256,
        sha(&installed)
    );
    assert_ne!(first.prior_previous_info_sha256, sha(&installed));
    // 認識できない内容は旧hashへ取り込まず、そのまま保持して更新は進む。
    write(&previous, b"unrecognized previous provenance");
    let after = state_of(&f.root);
    let third = "6666666666666666666666666666666666666666";
    begin(&f.root, third, CANDIDATE).unwrap();
    assert_eq!(
        state_of(&f.root).prior_previous_info_sha256,
        after.prior_previous_info_sha256
    );
    assert_eq!(
        std::fs::read(&previous).unwrap(),
        b"unrecognized previous provenance"
    );
}

/// 準備の途中で中断した進行中のstage_write記録は、固定名の現物がold/newのどちらかなら基準へ畳み込み、
/// どちらでもない（書込み途中の）現物は記録があっても保持して拒否する。
#[test]
fn begin_resolves_an_interrupted_stage_write_record_or_rejects_a_torn_file() {
    let build = |name: &str, record: &str| {
        let root = fixture_root(name);
        install(&root, &release(E0, "r0"));
        let first = release(E1, "r1");
        begin(&root, E1, E0).unwrap();
        download(&root, &first, false).unwrap();
        prepare(&root, &first).unwrap();
        let mut state = state_of(&root);
        state.stage_write_name = record.into();
        state.stage_write_old_sha256 = sha(b"older bytes");
        state.stage_write_new_sha256 = sha(&first.bodies["prunlet-maintenance.exe"]);
        state.stage_write_bytes = first.bodies["prunlet-maintenance.exe"].len() as i64;
        write_state(&root, &state).unwrap();
        root
    };
    // 書込みは完了していて記録だけが残った状態。基準へ畳み込み、記録は消える。
    let root = build("write-record-complete", "prunlet-maintenance.exe");
    begin(&root, E2, E0).unwrap();
    let state = state_of(&root);
    assert!(state.stage_write_name.is_empty());
    assert_eq!(
        state.cache_baseline.unwrap().maintenance_sha256,
        sha(&release(E1, "r1").bodies["prunlet-maintenance.exe"])
    );
    // 書込み途中で壊れた現物（oldでもnewでもない）は、記録があっても拒否し、何も変えない。
    let root = build("write-record-torn", "prunlet-maintenance.exe");
    write(
        &stage_path(&root).join("prunlet-maintenance.exe"),
        b"torn write",
    );
    let stage_before = snapshot(&root);
    let state_before = state_bytes(&root);
    assert!(begin(&root, E2, E0).is_err());
    assert_eq!(snapshot(&root), stage_before);
    assert_eq!(state_bytes(&root), state_before);
}

/// 切替の準備でprevious-source-info.jsonを書き換える途中に中断した記録は、現物がold/newのどちらかなら
/// 旧hashとして引き継ぎ、書込み途中の現物は保持して拒否する。記録を残したまま先へ進めない。
#[test]
fn begin_resolves_an_interrupted_previous_source_info_write() {
    let build = |name: &str, content: &[u8]| {
        let f = applied(name, false);
        begin(&f.root, NEXT, CANDIDATE).unwrap();
        let mut state = state_of(&f.root);
        let installed = std::fs::read(f.root.join("source-info.json")).unwrap();
        state.stage_write_name = "previous-source-info.json".into();
        state.stage_write_old_sha256 = state.prior_previous_info_sha256.clone();
        state.stage_write_new_sha256 = sha(&installed);
        state.stage_write_bytes = installed.len() as i64;
        write_state(&f.root, &state).unwrap();
        write(&f.stage.join("previous-source-info.json"), content);
        (f, installed)
    };
    let next = "5555555555555555555555555555555555555555";
    let (f, installed) = build("journal-new", b"");
    write(&f.stage.join("previous-source-info.json"), &installed);
    begin(&f.root, next, CANDIDATE).unwrap();
    let state = state_of(&f.root);
    assert!(state.stage_write_name.is_empty());
    assert_eq!(state.prior_previous_info_sha256, sha(&installed));
    // 書込み途中（oldでもnewでもない）の現物は拒否し、stateもstageも変えない。
    let (f, _) = build("journal-torn", b"torn previous provenance");
    let stage_before = snapshot(&f.root);
    let state_before = state_bytes(&f.root);
    assert!(begin(&f.root, next, CANDIDATE).is_err());
    assert_eq!(snapshot(&f.root), stage_before);
    assert_eq!(state_bytes(&f.root), state_before);
}

/// 実ZIP由来の候補E1を適用し終えた状態（stage保持）に、別commitの手動導入を重ねた配置を作る。
fn applied_then_manual(name: &str) -> (PathBuf, Rel) {
    let root = fixture_root(name);
    let release0 = release(E0, "r0");
    install(&root, &release0);
    let first = release(E1, "r1");
    begin(&root, E1, E0).unwrap();
    download(&root, &first, false).unwrap();
    prepare(&root, &first).unwrap();
    // 切替後のstate（適用済み・stage保持）を再現する。
    let stage = stage_path(&root);
    let previous = info_bytes(&release0);
    write(&stage.join("previous-source-info.json"), &previous);
    write(&stage.join("previous-source-info-original.json"), &previous);
    let mut state = state_of(&root);
    state.old_commit = E0.into();
    state.candidate_cli_sha256 = sha(&first.bodies["prunlet.exe"]);
    state.candidate_maintenance_sha256 = sha(&first.bodies["prunlet-maintenance.exe"]);
    state.candidate_source_info_sha256 = sha(&info_bytes(&first));
    state.integration_ready = true;
    state.migration_complete = true;
    state.migration_file_complete = Some(true);
    state.cache_baseline = None;
    write_state(&root, &state).unwrap();
    // 手動導入（別commit）。
    let manual = release("f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0", "manual");
    install(&root, &manual);
    (root, manual)
}

/// 適用済みstage（prior_*付き）から作った候補を準備した後（延期で未適用のまま）、さらに次のreleaseが
/// 来ても、手動導入後でも進める。候補ごとにprior_*は保たれ、cacheBaselineと共存する。
#[test]
fn begin_chain_after_a_prepared_candidate_with_prior_provenance() {
    let (root, manual) = applied_then_manual("chain-prepared-prior");
    let mut previous_candidate = release(E2, "r2");
    begin(&root, E2, &manual.commit).unwrap();
    download(&root, &previous_candidate, false).unwrap();
    prepare(&root, &previous_candidate).unwrap();
    let prior = state_of(&root);
    assert!(prior.prior_stage_commit.eq_ignore_ascii_case(E1) && prior.cache_baseline.is_none());
    for (commit, tag) in [
        (E3, "r3"),
        ("e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4", "r4"),
    ] {
        let next = release(commit, tag);
        begin(&root, commit, &manual.commit)
            .unwrap_or_else(|e| panic!("next release {tag} after a prepared candidate: {e:#}"));
        let state = state_of(&root);
        assert!(state.prior_stage_commit.eq_ignore_ascii_case(E1));
        assert_eq!(
            state.prior_previous_info_sha256,
            prior.prior_previous_info_sha256
        );
        assert!(state.cache_baseline.is_some());
        state.validate().unwrap();
        download(&root, &next, false).unwrap();
        prepare(&root, &next).unwrap();
        stage_matches(&root, &next);
        assert_eq!(zips(&root).len(), 1);
        previous_candidate = next;
    }
    drop(previous_candidate);
}

/// 適用済みstageと同じcommitのreleaseがassetを差し替えて再公開され、prepareした後に、さらに次の
/// releaseが来る経路。prior_stage_commitと候補・cacheBaselineが同じcommitを指し、source-infoのhashだけが
/// 食い違うstateを、書込みの検証が拒否して恒久停止しないこと。
#[test]
fn begin_chain_after_a_same_commit_asset_replacement() {
    let (root, manual) = applied_then_manual("chain-same-commit");
    let replaced = release(E1, "r1-replaced");
    begin(&root, E1, &manual.commit).expect("same-commit begin after a manual install");
    assert!(state_of(&root).prior_stage_commit.eq_ignore_ascii_case(E1));
    download(&root, &replaced, false).unwrap();
    prepare(&root, &replaced).unwrap();
    let next = release(E2, "r2");
    begin(&root, E2, &manual.commit).expect("next release after a same-commit replacement");
    download(&root, &next, false).unwrap();
    prepare(&root, &next).unwrap();
    stage_matches(&root, &next);
}

/// 記録した名前の書込み中ファイルが、これから書く長さより長い場合は上書きせず、保持して別の名前を使う。
#[test]
fn download_and_slot_keep_a_partial_file_longer_than_the_new_content() {
    let root = fixture_root("partial-too-long");
    let rel = release(E1, "r1");
    install(&root, &release(E0, "r0"));
    begin(&root, E1, E0).unwrap();
    assert!(download(&root, &rel, true).is_err());
    let name = state_of(&root).package_name;
    let path = stage_path(&root).join(&name);
    let longer = vec![7u8; rel.zip.len() + 1];
    std::fs::write(&path, &longer).unwrap();
    download(&root, &rel, false).unwrap();
    assert_ne!(state_of(&root).package_name, name);
    assert_eq!(std::fs::read(&path).unwrap(), longer);
    // slotも同じ解釈: 書く長さより長い部分ファイルは保持して新しいgenerationを使う。
    ensure_slots(&root).unwrap();
    let first = super::super::slot::acquire(&root, "cli", None, 100).unwrap();
    let generation = first.generation.clone();
    drop(first);
    let slot = root
        .join(SLOTS_NAME)
        .join(format!("slot-cli-{generation}.bin"));
    std::fs::write(&slot, vec![1u8; 101]).unwrap();
    let previous = PublishedSlot {
        generation: generation.clone(),
        sha256: sha(b"whatever"),
        bytes: 100,
        status: "writing".into(),
    };
    let lease = super::super::slot::acquire(&root, "cli", Some(&previous), 100).unwrap();
    assert_ne!(lease.generation, generation);
    assert_eq!(std::fs::read(&slot).unwrap().len(), 101);
}

/// 補助製品の親ディレクトリ（scripts・integration）の代替ストリームも、従来どおり拒否して不変更。
#[test]
fn begin_rejects_a_named_stream_on_an_auxiliary_directory() {
    for directory in ["scripts", "integration"] {
        let root = fixture_root(&format!("dir-ads-{directory}"));
        install(&root, &release(E0, "r0"));
        let first = release(E1, "r1");
        begin(&root, E1, E0).unwrap();
        download(&root, &first, false).unwrap();
        prepare(&root, &first).unwrap();
        let mut stream = stage_path(&root).join(directory).into_os_string();
        stream.push(":hidden");
        std::fs::write(&stream, b"stream bytes").unwrap();
        let state_before = state_bytes(&root);
        let stage_before = snapshot(&root);
        let error =
            begin(&root, E2, E0).expect_err("a stream on an auxiliary directory was accepted");
        assert!(
            format!("{error:#}").to_lowercase().contains("stream"),
            "{error:#}"
        );
        assert_eq!(state_bytes(&root), state_before);
        assert_eq!(snapshot(&root), stage_before);
        assert_eq!(std::fs::read(&stream).unwrap(), b"stream bytes");
    }
}
