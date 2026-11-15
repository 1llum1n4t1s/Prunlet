// Setup（Velopack）版の結合テスト（Windows）。実際にビルドした prunlet.exe を子プロセスとして動かす。
//
// - `unmanaged_*`: 管理外（従来の導入・開発ビルド）の実行では、新しいコードが何も読み書きしないこと（合否基準1）。
//   通常の `cargo test` で動く。
// - `managed_*`: `velopack-test` 機能付きのビルドでだけ動く。偽の Velopack 配置
//   （`<root>\Update.exe` と `<root>\current\{prunlet.exe,sq.version}`）を隔離フォルダーに作り、
//   フック（`--veloapp-install` / `--veloapp-updated`）・ホスト設定の自動書換え（合否基準7）・
//   共有ロックと適用中マーカー（合否基準3）を実プロセスで確かめる。
//   実機の `~/.claude`・`%LOCALAPPDATA%`・HKCU には一切触れない（環境変数で全て隔離し、Run はプロセス専用ハイブ）。
//   実行: `cargo test --features velopack-test --test velopack_setup`
#![cfg(windows)]

use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};

fn exe() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_prunlet"))
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "prunlet-vp-{name}-{}",
        uuid::Uuid::new_v4().simple()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// フォルダー配下の全パス（相対）。
fn tree(root: &Path) -> BTreeSet<String> {
    fn walk(dir: &Path, root: &Path, out: &mut BTreeSet<String>) {
        for entry in fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            out.insert(
                path.strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
            );
            if path.is_dir() {
                walk(&path, root, out);
            }
        }
    }
    let mut out = BTreeSet::new();
    walk(root, root, &mut out);
    out
}

/// 実環境の場所へ一切向かないよう、環境を全て隔離した子プロセスのコマンド。
fn isolated(program: &Path, sandbox: &Path) -> Command {
    let mut command = Command::new(program);
    command
        .env("LOCALAPPDATA", sandbox.join("localappdata"))
        .env("APPDATA", sandbox.join("appdata"))
        .env("USERPROFILE", sandbox.join("home"))
        .env("TEMP", sandbox.join("temp"))
        .env("TMP", sandbox.join("temp"))
        .env("PRUNLET_LANGUAGE", "en")
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("CODEX_HOME")
        .env_remove("PRUNLET_MCP_LAUNCHER_JOB")
        .stdin(Stdio::null());
    for sub in ["localappdata", "appdata", "home", "temp"] {
        fs::create_dir_all(sandbox.join(sub)).unwrap();
    }
    command
}

fn run(mut command: Command) -> Output {
    command.output().unwrap()
}

fn stdout_json(output: &Output) -> serde_json::Value {
    serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|e| panic!("{e}: {}", String::from_utf8_lossy(&output.stdout)))
}

fn init_config(sandbox: &Path, program: &Path) -> PathBuf {
    let config = sandbox.join("cfg").join("config.json");
    fs::create_dir_all(sandbox.join("backup")).unwrap();
    fs::create_dir_all(sandbox.join("cfg")).unwrap();
    let output = run({
        let mut c = isolated(program, sandbox);
        c.args(["--config"])
            .arg(&config)
            .args(["init", "--backup-directory"])
            .arg(sandbox.join("backup"));
        c
    });
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    config
}

// 合否基準1（のうち、新コードが何も読み書きしない部分）。

#[test]
fn unmanaged_runs_read_and_write_nothing_new() {
    let sandbox = scratch("unmanaged");
    let config = init_config(&sandbox, &exe());
    let before = tree(&sandbox);

    // 管理外の exe（target\debug）は、Velopack のフック・update-apply・setup status・通常のコマンドの
    // どれでも、状態フォルダー・ロック・マーカー・hook 複製を作らない。
    let outputs = [
        run({
            let mut c = isolated(&exe(), &sandbox);
            c.args(["--veloapp-install", "1.0.0"]);
            c
        }),
        run({
            let mut c = isolated(&exe(), &sandbox);
            c.args(["--veloapp-uninstall", "1.0.0"]);
            c
        }),
        run({
            let mut c = isolated(&exe(), &sandbox);
            c.arg("update-apply");
            c
        }),
        run({
            let mut c = isolated(&exe(), &sandbox);
            c.args(["setup", "status"]);
            c
        }),
        run({
            let mut c = isolated(&exe(), &sandbox);
            c.arg("--config").arg(&config).arg("validate-config");
            c
        }),
    ];
    // フックは必ず終了コード 0。update-apply / setup status は管理外と答えるだけ。
    assert_eq!(outputs[0].status.code(), Some(0));
    assert_eq!(outputs[1].status.code(), Some(0));
    assert_eq!(
        stdout_json(&outputs[2]),
        serde_json::json!({"status":"unmanaged"})
    );
    assert_eq!(
        stdout_json(&outputs[3]),
        serde_json::json!({"managed":false})
    );
    assert_eq!(stdout_json(&outputs[4]), serde_json::json!({"valid":true}));
    assert_eq!(
        tree(&sandbox),
        before,
        "an unmanaged run must not create anything"
    );
    let _ = fs::remove_dir_all(&sandbox);
}

#[test]
fn unmanaged_hook_named_copy_ignores_velopack_arguments() {
    // root 外の hook 複製（prunlet-hook.exe）は Velopack を初期化しない。引数不正は deny・終了コード 0。
    let sandbox = scratch("hook-name");
    let hook = sandbox.join("hook").join("prunlet-hook.exe");
    fs::create_dir_all(hook.parent().unwrap()).unwrap();
    fs::copy(exe(), &hook).unwrap();
    let before = tree(&sandbox);
    let output = run({
        let mut c = isolated(&hook, &sandbox);
        c.args(["--veloapp-install", "1.0.0"]);
        c
    });
    assert_eq!(output.status.code(), Some(0));
    let value = stdout_json(&output);
    assert_eq!(value["hookSpecificOutput"]["permissionDecision"], "deny");
    let after: BTreeSet<String> = tree(&sandbox)
        .difference(&before)
        .filter(|p| {
            !p.starts_with("localappdata")
                && !p.starts_with("appdata")
                && !p.starts_with("home")
                && !p.starts_with("temp")
        })
        .cloned()
        .collect();
    assert!(after.is_empty(), "{after:?}");
    let _ = fs::remove_dir_all(&sandbox);
}

#[cfg(feature = "velopack-test")]
mod managed {
    use super::*;
    use std::io::Write;

    const OLD_BIN_SUFFIX: &str = r".local\Prunlet\bin";

    /// 偽の Velopack 配置と、隔離した利用者環境。
    struct Fixture {
        sandbox: PathBuf,
        root: PathBuf,
        current_exe: PathBuf,
        data: PathBuf,
        home: PathBuf,
        claude: PathBuf,
        hive: PathBuf,
    }

    fn fixture(version: &str) -> Fixture {
        let sandbox = scratch("managed");
        let root = sandbox.join("PrunletVelopackTest");
        let current = root.join("current");
        fs::create_dir_all(&current).unwrap();
        fs::write(root.join("Update.exe"), b"dummy updater").unwrap();
        fs::write(
            current.join("sq.version"),
            format!(
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<package xmlns=\"http://schemas.microsoft.com/packaging/2010/07/nuspec.xsd\"><metadata><id>PrunletVelopackTest</id><title>t</title><description>t</description><authors>t</authors><version>{version}</version><channel>win</channel><mainExe>prunlet.exe</mainExe><os>win</os><rid>win-x64</rid><machineArchitecture>x64</machineArchitecture></metadata></package>"
            ),
        )
        .unwrap();
        let current_exe = current.join("prunlet.exe");
        fs::copy(exe(), &current_exe).unwrap();
        let home = sandbox.join("home");
        let claude = home.join(".claude");
        fs::create_dir_all(claude.join("hooks")).unwrap();
        Fixture {
            data: sandbox.join("data"),
            hive: sandbox.join("run-hive.dat"),
            sandbox,
            root,
            current_exe,
            home,
            claude,
        }
    }

    impl Fixture {
        fn command(&self) -> Command {
            let mut c = isolated(&self.current_exe, &self.sandbox);
            c.env("PRUNLET_VELOPACK_TEST_DATA_DIR", &self.data)
                .env("PRUNLET_VELOPACK_TEST_HOME", &self.home)
                .env(
                    "PRUNLET_VELOPACK_TEST_APPDATA",
                    self.sandbox.join("appdata"),
                )
                .env("PRUNLET_VELOPACK_TEST_ALLOW_UNSIGNED", "1")
                .env("PRUNLET_VELOPACK_TEST_RUN_HIVE", &self.hive)
                .env("PRUNLET_VELOPACK_TEST_FEED_DIR", self.sandbox.join("feed"))
                .env("CLAUDE_CONFIG_DIR", &self.claude)
                .env("CODEX_HOME", self.sandbox.join("codex"));
            c
        }

        fn state(&self) -> PathBuf {
            self.data.join("state")
        }

        fn legacy_bin(&self) -> String {
            self.home
                .join(OLD_BIN_SUFFIX)
                .to_string_lossy()
                .into_owned()
        }

        fn hook_copy(&self) -> PathBuf {
            self.data.join("hook").join("prunlet-hook.exe")
        }
    }

    fn escaped(text: &str) -> String {
        text.replace('\\', "\\\\")
    }

    /// 旧導入を指す、キー順がばらばらの settings.json（実機と同じ形の hook 行と、別のフック・別の項目）。
    fn write_host_files(f: &Fixture) -> (String, String, String) {
        let old_bin = f.legacy_bin();
        let settings = format!(
            "{{\n  \"zeta\": true,\n  \"hooks\": {{\"PreToolUse\": [{{\"matcher\": \"Bash\", \"hooks\": [{{\"type\": \"command\", \"command\": \"\\\"{hook}\\\" --config \\\"C:\\\\c\\\\config.json\\\" hook --cli-executable \\\"{cli}\\\"\"}}, {{\"type\": \"command\", \"command\": \"rtk hook claude\"}}]}}]}},\n  \"alpha\": 1\n}}\n",
            hook = escaped(&format!(r"{old_bin}\prunlet-hook.exe")),
            cli = escaped(&format!(r"{old_bin}\prunlet.exe")),
        );
        let claude_md = format!(
            "# rules\n- Prunlet CLI: `{old_bin}\\prunlet.exe --config C:\\c\\config.json delete`\n"
        );
        let guard = format!(
            "const HOOK = \"{}\";\n",
            escaped(&format!(r"{old_bin}\prunlet-hook.exe"))
        );
        fs::write(f.claude.join("settings.json"), &settings).unwrap();
        fs::write(f.claude.join("CLAUDE.md"), &claude_md).unwrap();
        fs::write(f.claude.join("hooks").join("powershell-guard.ts"), &guard).unwrap();
        // 実機と同じく、旧パスを含まない PRUNLET.md。
        fs::write(
            f.claude.join("PRUNLET.md"),
            "<!-- Prunlet managed agent instructions -->\n",
        )
        .unwrap();
        (settings, claude_md, guard)
    }

    // 合否基準7（実プロセス）: フックの実行で、旧パスだけが新パスへ置換される。

    #[test]
    fn install_hook_copies_the_hook_and_rewrites_only_owned_host_lines() {
        let f = fixture("1.0.0");
        let (settings, claude_md, guard) = write_host_files(&f);
        let output = run({
            let mut c = f.command();
            c.args(["--veloapp-install", "1.0.0"]);
            c
        });
        assert_eq!(
            output.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );

        // hook 複製は current\prunlet.exe と同じ内容で、root の外にある。
        assert_eq!(
            fs::read(f.hook_copy()).unwrap(),
            fs::read(&f.current_exe).unwrap()
        );
        assert!(!f.hook_copy().starts_with(&f.root));

        let cli = f.current_exe.to_string_lossy().into_owned();
        let hook = f.hook_copy().to_string_lossy().into_owned();
        let new_settings = fs::read_to_string(f.claude.join("settings.json")).unwrap();
        serde_json::from_str::<serde_json::Value>(&new_settings).unwrap();
        assert!(new_settings.contains(&escaped(&hook)) && new_settings.contains(&escaped(&cli)));
        // 置換部分以外は1バイトも変わらない（キー順・他のフックを含む）。
        let restored = new_settings
            .replace(
                &escaped(&hook),
                &escaped(&format!(r"{}\prunlet-hook.exe", f.legacy_bin())),
            )
            .replace(
                &escaped(&cli),
                &escaped(&format!(r"{}\prunlet.exe", f.legacy_bin())),
            );
        assert_eq!(restored, settings);
        let new_md = fs::read_to_string(f.claude.join("CLAUDE.md")).unwrap();
        assert!(new_md.contains(&format!("`{cli} --config")));
        assert_eq!(
            new_md.replace(&cli, &format!(r"{}\prunlet.exe", f.legacy_bin())),
            claude_md
        );
        let new_guard =
            fs::read_to_string(f.claude.join("hooks").join("powershell-guard.ts")).unwrap();
        assert!(new_guard.contains(&escaped(&hook)));
        assert_ne!(new_guard, guard);
        // バックアップ（元のバイト列）が同じフォルダーにあり、PRUNLET.md のように変更の無いものには作らない。
        let backups: Vec<String> = fs::read_dir(&f.claude)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains("prunlet-backup"))
            .collect();
        assert_eq!(backups.len(), 2, "{backups:?}");
        assert!(
            backups
                .iter()
                .all(|n| n.starts_with(".settings.json.") || n.starts_with(".CLAUDE.md."))
        );
        let backup = backups
            .iter()
            .find(|n| n.starts_with(".settings.json."))
            .unwrap();
        assert_eq!(fs::read_to_string(f.claude.join(backup)).unwrap(), settings);

        // 記録と status。
        let record: serde_json::Value =
            serde_json::from_slice(&fs::read(f.state().join("host-rewrite.json")).unwrap())
                .unwrap();
        let key = f
            .claude
            .join("settings.json")
            .to_string_lossy()
            .into_owned();
        assert_eq!(record["files"][&key]["lastStatus"], "rewritten");
        let status = stdout_json(&run({
            let mut c = f.command();
            c.args(["setup", "status"]);
            c
        }));
        assert_eq!(status["managed"], true);
        assert_eq!(status["packId"], "PrunletVelopackTest");
        assert_eq!(status["hook"]["matchesCli"], true);
        assert_eq!(status["setup"]["logon"]["status"], "created");
        assert!(status["hostRewrite"]["files"][&key]["rewrittenAt"].is_number());

        // 冪等: 更新フックを2回実行しても、書換え済みの設定は変わらず、バックアップも増えない。
        for _ in 0..2 {
            let output = run({
                let mut c = f.command();
                c.args(["--veloapp-updated", "1.0.0"]);
                c
            });
            assert_eq!(output.status.code(), Some(0));
        }
        assert_eq!(
            fs::read_to_string(f.claude.join("settings.json")).unwrap(),
            new_settings
        );
        let count = fs::read_dir(&f.claude)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains("prunlet-backup"))
            .count();
        assert_eq!(count, 2);
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    // MCP 登録（Toolport・Codex）の構造ごとの書換えと、新規 config の自動作成（実プロセス）。

    #[test]
    fn install_hook_migrates_mcp_registrations_and_creates_the_config_for_new_users() {
        let f = fixture("1.0.0");
        write_host_files(&f);
        let old_bin = f.legacy_bin();
        let legacy_config = format!(r"{}\config.json", old_bin.trim_end_matches(r"\bin"));
        let registry_path = f
            .sandbox
            .join("appdata")
            .join("Toolport")
            .join("registry.json");
        fs::create_dir_all(registry_path.parent().unwrap()).unwrap();
        let registry = format!(
            "{{\n  \"servers\": [\n    {{\n      \"args\": [\"--stdio\"],\n      \"command\": \"C:\\\\x.exe\",\n      \"id\": \"other\"\n    }},\n    {{\n      \"args\": [\n        \"-NoProfile\",\n        \"-NonInteractive\",\n        \"-File\",\n        \"{ps1}\",\n        \"-ExecutablePath\",\n        \"{exe}\",\n        \"-ConfigPath\",\n        \"{config}\"\n      ],\n      \"command\": \"C:\\\\pwsh.exe\",\n      \"id\": \"prunlet\",\n      \"transport\": \"stdio\"\n    }}\n  ]\n}}\n",
            ps1 = escaped(&format!(r"{old_bin}\start-prunlet-mcp.ps1")),
            exe = escaped(&format!(r"{old_bin}\prunlet.exe")),
            config = escaped(&legacy_config),
        );
        fs::write(&registry_path, &registry).unwrap();
        let codex = f.sandbox.join("codex");
        fs::create_dir_all(&codex).unwrap();
        let toml = format!(
            "model = \"x\"\n# BEGIN PRUNLET MCP\n[mcp_servers.prunlet]\ncommand = \"pwsh\"\nargs = [\"-NoProfile\", \"-NonInteractive\", \"-File\", \"{}\", \"-ExecutablePath\", \"{}\", \"-ConfigPath\", \"{}\", \"-CodexHome\", \"C:\\\\h\"]\nstartup_timeout_sec = 600\n# END PRUNLET MCP\n",
            escaped(&format!(r"{old_bin}\start-prunlet-mcp.ps1")),
            escaped(&format!(r"{old_bin}\prunlet.exe")),
            escaped(&legacy_config),
        );
        fs::write(codex.join("config.toml"), &toml).unwrap();

        let output = run({
            let mut c = f.command();
            c.args(["--veloapp-install", "1.0.0"]);
            c
        });
        assert_eq!(output.status.code(), Some(0));
        let cli = f.current_exe.to_string_lossy().into_owned();

        let updated: serde_json::Value =
            serde_json::from_slice(&fs::read(&registry_path).unwrap()).unwrap();
        assert_eq!(updated["servers"][1]["command"], cli.as_str());
        assert_eq!(
            updated["servers"][1]["args"],
            serde_json::json!(["--config", legacy_config, "mcp"])
        );
        assert_eq!(
            updated["servers"][0],
            serde_json::from_str::<serde_json::Value>(&registry).unwrap()["servers"][0]
        );
        let new_toml = fs::read_to_string(codex.join("config.toml")).unwrap();
        assert!(new_toml.contains(&format!("command = \"{}\"", escaped(&cli))));
        assert!(new_toml.contains(&format!(
            "args = [\"--config\", \"{}\", \"mcp\"]",
            escaped(&legacy_config)
        )));
        assert!(
            new_toml.starts_with("model = \"x\"\n")
                && new_toml.contains("startup_timeout_sec = 600\n# END PRUNLET MCP\n")
        );
        assert!(!new_toml.contains("start-prunlet-mcp.ps1"));
        // バックアップ（元のバイト列）。
        let backup = |dir: &Path, prefix: &str| -> String {
            let name = fs::read_dir(dir)
                .unwrap()
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .find(|n| n.starts_with(prefix))
                .unwrap();
            fs::read_to_string(dir.join(name)).unwrap()
        };
        assert_eq!(
            backup(
                registry_path.parent().unwrap(),
                ".registry.json.prunlet-backup-"
            ),
            registry
        );
        assert_eq!(backup(&codex, ".config.toml.prunlet-backup-"), toml);

        // 旧導入の config は無いので、新規利用者の config がインストール時に作られる（recovery も）。
        let created = f.data.join("config.json");
        assert!(created.is_file());
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(&created).unwrap()).unwrap();
        assert_eq!(
            value["backupDirectory"],
            f.data.join("recovery").to_string_lossy().as_ref()
        );
        let status = stdout_json(&run({
            let mut c = f.command();
            c.args(["setup", "status"]);
            c
        }));
        assert_eq!(status["setup"]["config"]["status"], "created");
        assert_eq!(status["config"]["source"], "new");
        // 復元データの保存先も初期化されている（旧インストーラーの init + migrate と同じ）。
        // 未初期化だと maintain が migration_required で失敗する。
        let maintain = run({
            let mut c = f.command();
            c.arg("--config")
                .arg(&created)
                .args(["maintain", "--apply"]);
            c
        });
        assert_eq!(
            maintain.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&maintain.stdout)
        );
        // ログオン時の保守（update-apply が続けて起動する prunlet-maintenance.exe）も成功する。
        fs::copy(
            env!("CARGO_BIN_EXE_prunlet-maintenance"),
            f.root.join("current").join("prunlet-maintenance.exe"),
        )
        .unwrap();
        let apply = run({
            let mut c = f.command();
            c.arg("update-apply");
            c
        });
        assert_eq!(apply.status.code(), Some(0));
        assert_eq!(stdout_json(&apply)["maintenance"], "ok");
        let notes = status["notes"].to_string();
        assert!(notes.contains("Restart Toolport"), "{notes}");
        // 冪等: 2回目は何も変わらず、config も作り直さない。
        let before = fs::read(&created).unwrap();
        run({
            let mut c = f.command();
            c.args(["--veloapp-updated", "1.0.0"]);
            c
        });
        assert_eq!(fs::read(&created).unwrap(), before);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&fs::read(&registry_path).unwrap())
                .unwrap(),
            updated
        );
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    #[test]
    fn install_hook_uses_the_legacy_config_and_does_not_create_one() {
        let f = fixture("1.0.0");
        let legacy_root = f.home.join(".local").join("Prunlet");
        fs::create_dir_all(&legacy_root).unwrap();
        fs::write(legacy_root.join("config.json"), b"{}").unwrap();
        let output = run({
            let mut c = f.command();
            c.args(["--veloapp-install", "1.0.0"]);
            c
        });
        assert_eq!(output.status.code(), Some(0));
        assert!(!f.data.join("config.json").exists());
        let status = stdout_json(&run({
            let mut c = f.command();
            c.args(["setup", "status"]);
            c
        }));
        assert_eq!(status["setup"]["config"]["status"], "legacy");
        assert_eq!(status["config"]["source"], "legacy");
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    // H1: 信頼検査より前に、未検証の Squirrel.exe が <root>\Update.exe へ展開・実行されない。

    const TEST_PACK_VERSION: &str = "1.0.47";

    fn nuspec(version: &str) -> String {
        format!(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<package xmlns=\"http://schemas.microsoft.com/packaging/2010/07/nuspec.xsd\"><metadata><id>PrunletVelopackTest</id><title>t</title><description>t</description><authors>t</authors><version>{version}</version><channel>win</channel><mainExe>prunlet.exe</mainExe><os>win</os><rid>win-x64</rid><machineArchitecture>x64</machineArchitecture></metadata></package>"
        )
    }

    /// 製品の exe（版 1.0.47・製品名 Prunlet・machine 一致）と、指定の中身の Squirrel.exe を持つ nupkg を作る。
    fn build_nupkg(path: &Path, squirrel: &[u8]) {
        let exe_bytes = fs::read(exe()).unwrap();
        let file = fs::File::create(path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        let spec = nuspec(TEST_PACK_VERSION);
        let entries: [(&str, &[u8]); 7] = [
            ("[Content_Types].xml", b"x"),
            ("_rels/.rels", b"x"),
            ("PrunletVelopackTest.nuspec", spec.as_bytes()),
            ("lib/app/prunlet.exe", &exe_bytes),
            ("lib/app/prunlet-maintenance.exe", &exe_bytes),
            ("lib/app/Squirrel.exe", squirrel),
            ("lib/app/sq.version", spec.as_bytes()),
        ];
        for (name, bytes) in entries {
            writer.start_file(name, options).unwrap();
            writer.write_all(bytes).unwrap();
        }
        writer.finish().unwrap();
    }

    fn sha256_of(path: &Path) -> String {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(fs::read(path).unwrap()))
    }

    /// R2 の版付きマニフェスト（`manifests/<版>/velopack-win-x64.json`）と同じ形の封筒を、テスト鍵で署名して作る。
    /// テスト鍵（`prunlet-release-test-1`）は `velopack-test` 機能付きのビルドでだけ受理される。
    fn signed_manifest(version: &str, name: &str, sha256: &str, bytes: u64) -> String {
        use base64::{Engine, engine::general_purpose::STANDARD};
        use p256::ecdsa::{DerSignature, SigningKey, signature::Signer};
        use p256::pkcs8::DecodePrivateKey;
        let payload = format!(
            "{{\"schema\":1,\"product\":\"Prunlet\",\"repository\":\"1llum1n4t1s/Prunlet\",\"runtime\":\"velopack-win-x64\",\"version\":\"{version}\",\"commit\":\"{}\",\"defaultBranch\":\"main\",\"asset\":{{\"name\":\"{name}\",\"key\":\"velopack/{name}\",\"bytes\":{bytes},\"sha256\":\"{sha256}\"}}}}",
            "0".repeat(40)
        );
        let key = SigningKey::from_pkcs8_pem(include_str!(
            "../scripts/release-test-fixtures/test-signing-private.pem"
        ))
        .unwrap();
        let signature: DerSignature = key.sign(payload.as_bytes());
        format!(
            "{{\"schema\":1,\"keyId\":\"prunlet-release-test-1\",\"payload\":\"{}\",\"signature\":\"{}\"}}",
            STANDARD.encode(payload.as_bytes()),
            STANDARD.encode(signature.as_bytes())
        )
    }

    /// ローカルフィード（Full と、使われてはならない Delta の資産）と、署名付きマニフェストを置く。
    /// `release` フォルダーは R2 のベースに見立てる（`PRUNLET_VELOPACK_TEST_RELEASE_DIR`）。
    /// `release_hash_of` を渡すと、マニフェストの SHA-256 をその中身のものにする（nupkg と一致しない正規の署名）。
    /// 戻り値は nupkg の名前。
    fn publish_feed(
        f: &Fixture,
        squirrel: &[u8],
        release_hash_of: Option<&[u8]>,
        feed_sha_override: Option<&str>,
    ) -> String {
        let feed = f.sandbox.join("feed");
        let release = f.sandbox.join("release");
        fs::create_dir_all(&feed).unwrap();
        fs::create_dir_all(&release).unwrap();
        let name = format!("PrunletVelopackTest-{TEST_PACK_VERSION}-full.nupkg");
        let package = feed.join(&name);
        build_nupkg(&package, squirrel);
        let sha = sha256_of(&package);
        let size = fs::metadata(&package).unwrap().len();
        let delta = format!("PrunletVelopackTest-{TEST_PACK_VERSION}-delta.nupkg");
        fs::write(feed.join(&delta), b"delta that must never be applied").unwrap();
        let assets = serde_json::json!({"Assets":[
            {"PackageId":"PrunletVelopackTest","Version":TEST_PACK_VERSION,"Type":"Full","FileName":name,
             "SHA1":"","SHA256":feed_sha_override.unwrap_or(&sha),"Size":size,"NotesMarkdown":"","NotesHtml":""},
            {"PackageId":"PrunletVelopackTest","Version":TEST_PACK_VERSION,"Type":"Delta","FileName":delta,
             "SHA1":"","SHA256":"00","Size":32,"NotesMarkdown":"","NotesHtml":""}
        ]});
        fs::write(feed.join("releases.win.json"), assets.to_string()).unwrap();
        let release_sha = match release_hash_of {
            Some(bytes) => {
                use sha2::{Digest, Sha256};
                hex::encode(Sha256::digest(bytes))
            }
            None => sha.clone(),
        };
        let manifests = release.join("manifests").join(TEST_PACK_VERSION);
        fs::create_dir_all(&manifests).unwrap();
        fs::write(
            manifests.join("velopack-win-x64.json"),
            signed_manifest(TEST_PACK_VERSION, &name, &release_sha, size),
        )
        .unwrap();
        name
    }

    fn command_with_release(f: &Fixture) -> Command {
        let mut c = f.command();
        c.env(
            "PRUNLET_VELOPACK_TEST_RELEASE_DIR",
            f.sandbox.join("release"),
        );
        c
    }

    #[test]
    fn a_malicious_feed_never_changes_update_exe_and_is_never_placed_in_packages() {
        let f = fixture("1.0.0");
        let update_exe = f.root.join("Update.exe");
        let original = fs::read(&update_exe).unwrap();
        let packages = f.root.join("packages");
        // PE として正しい（machine・構造は通る）が、中身が正規と違う Squirrel.exe。
        let mut evil_bytes = fs::read(exe()).unwrap();
        evil_bytes.extend_from_slice(b"EVIL-SQUIRREL-REPLACEMENT");
        let evil = evil_bytes.as_slice();

        // 1. Squirrel.exe を差し替えた nupkg。署名付きマニフェストのハッシュは正規のパッケージのもの → 照合に通らず、packages へ置かない。
        let legit_bytes = fs::read(exe()).unwrap();
        publish_feed(&f, evil, Some(&legit_bytes), None);
        let output = run({
            let mut c = command_with_release(&f);
            c.arg("update-check");
            c
        });
        // 取得の失敗は終了コード 1（update-apply の failed と同じ）。
        assert_eq!(output.status.code(), Some(1));
        let value = stdout_json(&output);
        assert_eq!(value["status"], "failed", "{value}");
        assert!(
            value["error"]
                .as_str()
                .unwrap()
                .contains("was not confirmed"),
            "{value}"
        );
        assert_eq!(
            fs::read(&update_exe).unwrap(),
            original,
            "Update.exe must be untouched"
        );
        assert!(!packages.exists() || fs::read_dir(&packages).unwrap().count() == 0);
        // 取得用の一時フォルダーも残さない。
        let incoming = f.state().join("incoming");
        assert!(!incoming.exists() || fs::read_dir(&incoming).unwrap().count() == 0);
        // Delta in the feed is never fetched or applied (no delta package appears in packages).
        assert!(
            !packages
                .join("PrunletVelopackTest-1.0.47-delta.nupkg")
                .exists()
        );

        // 2. フィードの SHA-256 と違う内容（取得後の改ざん）も、packages へ置かない。
        publish_feed(&f, evil, None, Some(&"ab".repeat(32)));
        let value = stdout_json(&run({
            let mut c = command_with_release(&f);
            c.arg("update-check");
            c
        }));
        assert_eq!(value["status"], "failed", "{value}");
        assert!(
            value["error"].as_str().unwrap().contains("feed SHA-256"),
            "{value}"
        );
        assert_eq!(fs::read(&update_exe).unwrap(), original);

        // 3. 正規のハッシュなら packages へ置かれる。それでも <root>\Update.exe は不変
        //    （velopack の download_updates なら、ここで Squirrel.exe が Update.exe を上書きしていた）。
        let name = publish_feed(&f, evil, None, None);
        let output = run({
            let mut c = command_with_release(&f);
            c.arg("update-check");
            c
        });
        assert_eq!(output.status.code(), Some(0));
        let value = stdout_json(&output);
        assert_eq!(value["status"], "downloaded", "{value}");
        assert!(packages.join(&name).is_file());
        assert_eq!(
            fs::read(&update_exe).unwrap(),
            original,
            "Update.exe must stay untouched until applied"
        );
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    #[test]
    fn update_apply_refuses_a_package_whose_release_hash_does_not_match() {
        let f = fixture("1.0.0");
        let update_exe = f.root.join("Update.exe");
        let original = fs::read(&update_exe).unwrap();
        // 取得経路を通らず packages へ直接置かれた、署名付きマニフェストのハッシュと一致しない nupkg。
        let name = publish_feed(&f, b"EVIL", Some(b"other"), None);
        let packages = f.root.join("packages");
        fs::create_dir_all(&packages).unwrap();
        fs::copy(f.sandbox.join("feed").join(&name), packages.join(&name)).unwrap();
        let output = run({
            let mut c = command_with_release(&f);
            c.args(["update-apply", "--no-maintenance"]);
            c
        });
        assert_eq!(
            output.status.code(),
            Some(2),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
        let value = stdout_json(&output);
        assert_eq!(value["status"], "untrusted", "{value}");
        assert_eq!(fs::read(&update_exe).unwrap(), original);
        assert!(!f.state().join("update-apply.marker.json").exists());
        // M2: 保留があるので、ネットワーク（フィード）の確認より先に適用の判定を行った。
        let log = fs::read_to_string(f.state().join("app-update.log")).unwrap();
        assert!(!log.contains("logon-check"), "{log}");
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    // L3: ログオン時の保守は、更新の設定・結果から切り離して続ける。

    #[test]
    fn maintenance_continues_even_when_auto_update_is_off() {
        let f = fixture("1.0.0");
        fs::create_dir_all(f.state()).unwrap();
        fs::write(
            f.state().join("app-update.json"),
            br#"{"auto_update":false}"#,
        )
        .unwrap();
        // 保守の実行ファイルが無い配置でも、保守の段階まで進む（skippedMissing）ことで切り離しを確かめる。
        let config = init_config(&f.sandbox, &f.current_exe);
        fs::create_dir_all(f.data.clone()).unwrap();
        fs::copy(&config, f.data.join("config.json")).unwrap();
        let output = run({
            let mut c = command_with_release(&f);
            c.arg("update-apply");
            c
        });
        assert_eq!(output.status.code(), Some(0));
        let value = stdout_json(&output);
        assert_eq!(value["status"], "disabled");
        assert_eq!(value["maintenance"], "skippedMissing", "{value}");
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    // M1: MCP の起動で、hook 複製が CLI と一致しなければ再配置される（使用中なら延期）。

    #[test]
    fn mcp_start_restores_a_hook_copy_that_no_longer_matches_the_cli() {
        let f = fixture("1.0.0");
        let config = init_config(&f.sandbox, &f.current_exe);
        let output = run({
            let mut c = f.command();
            c.args(["--veloapp-install", "1.0.0"]);
            c
        });
        assert_eq!(output.status.code(), Some(0));
        let record: serde_json::Value =
            serde_json::from_slice(&fs::read(f.state().join("setup-state.json")).unwrap()).unwrap();
        // 全手順が成功したので、要再試行ではない。
        assert_eq!(record["needsRetry"], false, "{record}");
        // hook 複製を壊す（古い版・欠けた内容の想定）。
        fs::write(f.hook_copy(), b"stale hook").unwrap();
        fs::write(
            f.state().join("app-update.json"),
            br#"{"auto_update":false}"#,
        )
        .unwrap();
        let mut mcp = f.command();
        mcp.arg("--config")
            .arg(&config)
            .arg("mcp")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = mcp.spawn().unwrap();
        let expected = fs::read(&f.current_exe).unwrap();
        let mut restored = false;
        for _ in 0..100 {
            if fs::read(f.hook_copy()).ok().as_deref() == Some(expected.as_slice()) {
                restored = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        drop(child.stdin.take());
        let _ = child.wait();
        assert!(
            restored,
            "the MCP start must re-place the mismatching hook copy"
        );
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    // M4・L2: Codex の hooks.json は書き換えず、--cli-executable の無い旧形式の hook 呼び出しは置換しない。

    #[test]
    fn codex_hooks_json_and_legacy_form_hooks_are_reported_not_rewritten() {
        let f = fixture("1.0.0");
        let old_bin = f.legacy_bin();
        let codex = f.sandbox.join("codex");
        fs::create_dir_all(&codex).unwrap();
        let hooks = format!(
            "{{\"hooks\":{{\"PreToolUse\":[{{\"hooks\":[{{\"command\":\"cmd /d /c call {hook} --config C:\\\\c\\\\config.json hook --cli-executable {cli}\"}}]}}]}}}}",
            hook = escaped(&format!(r"{old_bin}\prunlet-hook.exe")),
            cli = escaped(&format!(r"{old_bin}\prunlet.exe")),
        );
        fs::write(codex.join("hooks.json"), &hooks).unwrap();
        // 旧形式: CLI 自身が hook として呼ばれる（--cli-executable 無し）。
        let legacy_form = format!(
            "{{\"hooks\":[{{\"command\":\"call {cli} --config C:\\\\c\\\\config.json hook\"}}]}}\n",
            cli = escaped(&format!(r"{old_bin}\prunlet.exe")),
        );
        fs::write(f.claude.join("settings.json"), &legacy_form).unwrap();
        let output = run({
            let mut c = f.command();
            c.args(["--veloapp-install", "1.0.0"]);
            c
        });
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(fs::read_to_string(codex.join("hooks.json")).unwrap(), hooks);
        assert_eq!(
            fs::read_to_string(f.claude.join("settings.json")).unwrap(),
            legacy_form
        );
        let status = stdout_json(&run({
            let mut c = f.command();
            c.args(["setup", "status"]);
            c
        }));
        let notes = status["notes"].to_string();
        assert!(notes.contains("Codex hook"), "{notes}");
        assert!(notes.contains("legacy form"), "{notes}");
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    #[test]
    fn install_hook_does_not_touch_host_files_when_the_hook_copy_cannot_be_made() {
        let f = fixture("1.0.0");
        let (settings, _, _) = write_host_files(&f);
        // hook 複製の置き場がファイルで塞がれていて作れない（失敗しても終了コードは0で、ホスト設定は書き換えない）。
        fs::create_dir_all(&f.data).unwrap();
        fs::write(f.data.join("hook"), b"blocker").unwrap();
        let output = run({
            let mut c = f.command();
            c.args(["--veloapp-install", "1.0.0"]);
            c
        });
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            fs::read_to_string(f.claude.join("settings.json")).unwrap(),
            settings
        );
        assert!(
            fs::read_dir(&f.claude)
                .unwrap()
                .flatten()
                .all(|e| !e.file_name().to_string_lossy().contains("prunlet-backup"))
        );
        // 失敗は記録され、再試行が要る印が残る。
        let record: serde_json::Value =
            serde_json::from_slice(&fs::read(f.state().join("setup-state.json")).unwrap()).unwrap();
        assert_eq!(record["hook"]["status"], "failed");
        assert_eq!(record["needsRetry"], true);
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    // 合否基準3（実プロセス）: マーカー中の新規起動は未実行で拒否される。MCP などが動作中は排他ロックを取れない。

    #[test]
    fn a_fresh_marker_refuses_new_starts_until_the_target_version_clears_it() {
        let f = fixture("1.0.0");
        let config = init_config(&f.sandbox, &f.current_exe);
        let validate = |f: &Fixture| {
            run({
                let mut c = f.command();
                c.arg("--config").arg(&config).arg("validate-config");
                c
            })
        };
        let marker = f.state().join("update-apply.marker.json");
        let write_marker = |target: &str, at: u64| {
            fs::create_dir_all(f.state()).unwrap();
            fs::write(
                &marker,
                format!("{{\"target\":\"{target}\",\"writtenAt\":{at},\"pid\":1}}"),
            )
            .unwrap();
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        // 目標版でなく新しい: 未実行で拒否（exit 1、削除ツールの本処理は動かない）。マーカーは残る。
        write_marker("9.9.9", now);
        let output = validate(&f);
        assert_eq!(output.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&output.stdout).contains("switching to version 9.9.9"));
        assert!(marker.exists());
        // 目標版（この exe の版）: 適用が終わったものとして消して通る。
        write_marker("1.0.0", now);
        assert_eq!(
            stdout_json(&validate(&f)),
            serde_json::json!({"valid":true})
        );
        assert!(!marker.exists());
        // 古いマーカー: 失敗の残骸として消して通る。
        write_marker("9.9.9", 1);
        assert_eq!(
            stdout_json(&validate(&f)),
            serde_json::json!({"valid":true})
        );
        assert!(!marker.exists());
        // hook の入口（--config X hook）はロックにもマーカーにも参加しない（常に deny/allow の JSON・exit 0）。
        write_marker("9.9.9", now);
        let mut hook = f.command();
        hook.arg("--config")
            .arg(&config)
            .arg("hook")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        let mut child = hook.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"tool_name":"Bash","tool_input":{"command":"echo hi"}}"#)
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert!(
            marker.exists(),
            "the hook must not clear or read the marker"
        );
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    /// 1行ずつ JSON-RPC の応答を読む（別スレッドで読み、時間切れを検出する）。
    fn read_response(receiver: &std::sync::mpsc::Receiver<String>, id: u64) -> serde_json::Value {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            let wait = deadline.saturating_duration_since(std::time::Instant::now());
            let line = receiver
                .recv_timeout(wait)
                .expect("the MCP did not respond in time; never resend the request");
            let message: serde_json::Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                return message;
            }
        }
    }

    /// プロセスが生きているか（PID で開けて、終了していないこと）。
    fn alive(pid: u32) -> bool {
        use windows_sys::Win32::{
            Foundation::{CloseHandle, STILL_ACTIVE},
            System::Threading::{
                GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        };
        // SAFETY: 照会だけの限定権限でハンドルを開き、必ず閉じる。
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code = 0u32;
            let ok = GetExitCodeProcess(handle, &mut code) != 0 && code == STILL_ACTIVE as u32;
            CloseHandle(handle);
            ok
        }
    }

    // 合否基準5（`current\` から直接起動したMCP）: 切断後も明示キューの worker が生き残り、解放後に削除を完了する。
    // 通常の子は MCP の終了で止まり、worker だけが作成時の離脱で残る。worker は製品ロックの共有ロックも持つ。

    #[test]
    fn a_directly_started_mcp_keeps_its_queue_worker_after_disconnect() {
        let f = fixture("1.0.0");
        let config = init_config(&f.sandbox, &f.current_exe);
        fs::create_dir_all(f.state()).unwrap();
        fs::write(
            f.state().join("app-update.json"),
            br#"{"auto_update":false}"#,
        )
        .unwrap();
        let target = f.sandbox.join("queued");
        fs::create_dir_all(&target).unwrap();
        let child_file = target.join("locked.txt");
        fs::write(&child_file, b"x").unwrap();
        // 読み取り共有だけで開いておく（削除は共有違反になり、worker は待機する）。
        let held = {
            use std::os::windows::fs::OpenOptionsExt;
            fs::OpenOptions::new()
                .read(true)
                .share_mode(1)
                .open(&child_file)
                .unwrap()
        };
        let mut mcp = f.command();
        mcp.arg("--config")
            .arg(&config)
            .arg("mcp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = mcp.spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            use std::io::BufRead;
            for line in std::io::BufReader::new(stdout)
                .lines()
                .map_while(Result::ok)
            {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        let mut send = |value: serde_json::Value| {
            writeln!(stdin, "{value}").unwrap();
            stdin.flush().unwrap();
        };
        send(
            serde_json::json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"vp-test","version":"1"}}}),
        );
        read_response(&receiver, 1);
        send(serde_json::json!({"jsonrpc":"2.0","method":"notifications/initialized"}));
        send(
            serde_json::json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_files","arguments":{"action":"enqueue","paths":[target],"recursive":true}}}),
        );
        let accepted = read_response(&receiver, 2);
        let job = &accepted["result"]["structuredContent"];
        assert_eq!(job["status"], "pending", "{accepted}");
        let worker = job["workerProcessId"].as_u64().expect("worker pid") as u32;
        assert!(alive(worker));
        // 稼働中の MCP と worker が共有ロックを持つ間は、適用側の排他ロックを取れない。
        assert!(
            prunlet::app_update::lock::try_exclusive(&f.state())
                .unwrap()
                .is_none()
        );

        // 切断（標準入力を閉じる）。MCP は正常終了し、worker だけが残る。
        drop(send);
        drop(stdin);
        assert_eq!(child.wait().unwrap().code(), Some(0));
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert!(
            alive(worker),
            "the queue worker must survive the MCP disconnect"
        );
        assert!(child_file.exists());
        // MCP が止まっても worker が共有ロックを持ち続けるので、適用は busy のまま。
        assert!(
            prunlet::app_update::lock::try_exclusive(&f.state())
                .unwrap()
                .is_none()
        );

        // ロックを解放すると、worker が（切断後でも）削除を完了する。結果は1時間保持されるため worker は
        // その間生き続ける。確認後、テストが作った worker だけを止める。
        drop(held);
        let mut removed = false;
        for _ in 0..200 {
            if !target.exists() {
                removed = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        let _ = Command::new("taskkill")
            .args(["/PID", &worker.to_string(), "/F"])
            .output();
        assert!(
            removed,
            "the queued target was not removed after the lock was released"
        );
        for _ in 0..100 {
            if !alive(worker) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert!(
            prunlet::app_update::lock::try_exclusive(&f.state())
                .unwrap()
                .is_some()
        );
        let _ = fs::remove_dir_all(&f.sandbox);
    }

    #[test]
    fn a_running_mcp_holds_the_shared_lock_so_update_apply_cannot_take_the_exclusive_one() {
        let f = fixture("1.0.0");
        let config = init_config(&f.sandbox, &f.current_exe);
        // 更新の自動確認は止める（ネットワークにも出ない）。
        fs::create_dir_all(f.state()).unwrap();
        fs::write(
            f.state().join("app-update.json"),
            br#"{"auto_update":false}"#,
        )
        .unwrap();
        let mut mcp = f.command();
        mcp.arg("--config")
            .arg(&config)
            .arg("mcp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = mcp.spawn().unwrap();
        let lock_dir = f.state();
        // 起動直後に共有ロックを取るので、排他は取れない（busy）。
        let mut busy = false;
        for _ in 0..100 {
            if prunlet::app_update::lock::try_exclusive(&lock_dir)
                .unwrap()
                .is_none()
            {
                busy = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert!(busy, "the MCP did not take the shared product lock");
        // 標準入力を閉じると MCP は正常に終了し、ロックが外れる。強制終了は不要。
        drop(child.stdin.take());
        let status = child.wait().unwrap();
        assert_eq!(status.code(), Some(0));
        assert!(
            prunlet::app_update::lock::try_exclusive(&lock_dir)
                .unwrap()
                .is_some()
        );
        let _ = fs::remove_dir_all(&f.sandbox);
    }
}
