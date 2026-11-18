use super::*;

#[test]
fn cmd_wrapper_switch_forms_inspect_the_body() {
    for command in [
        r"cmd.exe //c del C:\fixture\file.txt",
        r"cmd.exe //d //c del C:\fixture\file.txt",
        r"cmd /R del C:\fixture\file.txt",
        r"cmd /r del C:\fixture\file.txt",
        r"cmd /K del C:\fixture\file.txt",
        r"cmd /cdel C:\fixture\file.txt",
        r"cmd /d/c del C:\fixture\file.txt",
        r"cmd //d//c del C:\fixture\file.txt",
        r#"cmd /D/Q/C "del C:\fixture\file.txt""#,
        r#"cmd /c"rd /s /q C:\fixture\dir""#,
        r"cmd /e:on /v:off /f:ON /t:0a /s /a /u /c del C:\fixture\file.txt",
        r"cmd /d /c reg delete HKCU\Software\PrunletHookProbe /f",
        r#"cmd /c "echo ok & del C:\fixture\file.txt""#,
        r"cmd -c del C:\fixture\file.txt",
        // 本文が`"`で始まると、cmd.exeは最初と最後の`"`を外して実行する（`del x y`）。
        r#"cmd /c "del C:\fixture\file.txt" y"#,
        r#"cmd /d /c "del" C:\fixture\file.txt"#,
    ] {
        for shell in ["cmd.exe", "pwsh"] {
            assert!(denied(command, shell), "{shell}: {command}");
        }
    }
    // 退避した`^"`もCMD規則では外側の引用として剥がされる。
    assert!(denied(r#"cmd /c ^"del C:\fixture\file.txt^""#, "cmd.exe"));
    if cfg!(windows) {
        assert!(reason(r#"cmd //c "del C:\fixture\file.txt" y"#, "Bash", None).is_some());
    }
    // 空白を含む実行ファイルのパスを引用して引数を続ける形は通す。
    for command in [
        r#"cmd /c "C:\Program Files\Tool\tool.exe" --flag value"#,
        r#"cmd /d /c "C:\Program Files\Tool\tool.exe" "C:\work\a b.txt""#,
    ] {
        for shell in ["cmd.exe", "pwsh"] {
            assert!(!denied(command, shell), "{shell}: {command}");
        }
        if cfg!(windows) {
            assert_eq!(reason(command, "Bash", None), None, "Bash: {command}");
        }
    }
    // 未知switch・本文前の未知引数は本文を確定できないためfail-closedにする。
    for command in [
        "cmd /z /c echo ok",
        "cmd /dq /c echo ok",
        "cmd /t:zz /c echo ok",
        "cmd / /c echo ok",
        "cmd stray /c echo ok",
    ] {
        let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
        assert!(
            reason.contains("unsupported CMD wrapper switch"),
            "{command}: {reason}"
        );
    }
    for command in CANONICAL_CLI.into_iter().chain([
        "cmd /?",
        "cmd",
        "cmd /d",
        "cmd /c",
        r"cmd /c reg query HKCU\Software\PrunletHookProbe",
        r"cmd /c echo del C:\fixture\file.txt",
        r"cmd //c echo rd /s /q",
    ]) {
        for shell in ["cmd.exe", "pwsh"] {
            assert!(!denied(command, shell), "{shell}: {command}");
        }
    }
    if cfg!(windows) {
        for command in CANONICAL_CLI {
            assert_eq!(reason(command, "Bash", None), None, "{command}");
        }
        assert!(reason(r"cmd.exe //d //c del C:\fixture\file.txt", "Bash", None).is_some());
    }
}
#[test]
fn cmd_switch_parser_separates_switches_and_attached_body() {
    let words = |s: &str| tokens(s, Mode::Cmd, false).unwrap();
    assert_eq!(
        cmd_switches(&words("cmd /d/cdel x"), 1),
        CmdSwitches::Body {
            token: 1,
            attached: "del".into()
        }
    );
    assert_eq!(
        cmd_switches(&words("cmd //D //Q //E:OFF //K"), 1),
        CmdSwitches::Body {
            token: 4,
            attached: String::new()
        }
    );
    assert_eq!(cmd_switches(&words("cmd /d /q"), 1), CmdSwitches::NoBody);
    assert_eq!(
        cmd_switches(&words("cmd /w /c x"), 1),
        CmdSwitches::Unknown("/w".into())
    );
    assert_eq!(
        cmd_switches(&words("cmd x /c y"), 1),
        CmdSwitches::Unknown("x".into())
    );
    // 語の途中にある本文switchもcmd.exeは解釈するため、解析せず拒否側へ倒す。
    for command in ["cmd x/c y", "cmd ,/c y", "cmd /d x/c y"] {
        assert!(
            matches!(cmd_switches(&words(command), 1), CmdSwitches::Unknown(_)),
            "{command}"
        );
    }
}
#[test]
fn cmd_executable_name_is_cut_at_the_first_delimiter() {
    // 実行名が`cmd`/`cmd.exe`で直後に区切りが直結した形だけを分解し、区切り以降を返す。
    for (text, tail) in [
        ("cmd/c", "/c"),
        ("cmd.exe/c", "/c"),
        ("CMD.EXE/C", "/C"),
        ("cmd,/c", ",/c"),
        ("cmd=/c", "=/c"),
        ("cmd;/c", ";/c"),
        ("cmd/cdel", "/cdel"),
        (r"C:\Windows\System32\cmd.exe/c", "/c"),
        ("C:/Windows/System32/cmd.exe/c", "/c"),
    ] {
        assert_eq!(cmd_glued_tail(text, true), Some(tail), "{text}");
    }
    // 直結のない通常の実行名・経路・他のコマンド名は分解しない。
    for text in [
        "cmd",
        "cmd.exe",
        r"C:\Windows\System32\cmd.exe",
        "C:/Windows/System32/cmd.exe",
        "/c/Windows/System32/cmd.exe",
        "echo",
        "echo/c",
        "x/cmd",
        "cmdx/c",
        "C:/Windows",
        "",
    ] {
        assert_eq!(cmd_glued_tail(text, true), None, "{text}");
    }
    // 先頭の`@ , ; =`はCMD規則だけで落とす。POSIX・PowerShell規則の判定は変えない。
    assert_eq!(exec_name(",del", Some(Mode::Cmd)).name, "del");
    assert_eq!(exec_name("@=,del", Some(Mode::Cmd)).name, "del");
    assert_eq!(exec_name("cmd/c", Some(Mode::Cmd)).name, "cmd");
    assert_eq!(exec_name("cmd.exe/c", Some(Mode::Cmd)).glued, Some("/c"));
    assert_eq!(exec_name(",del", Some(Mode::Posix)).name, ",del");
    assert_eq!(exec_name("=del", Some(Mode::PowerShell)).name, "=del");
    assert_eq!(exec_name("@del", Some(Mode::Posix)).name, "del");
    assert_eq!(exec_name("cmd/c", Some(Mode::Posix)).glued, None);
    // 単純名の削除命令・regは最初の`/ , ; =`で切る。表示名も切った名前にする。
    for (text, name, shown, glued) in [
        ("rd/s/q", "rd", "rd", "/s/q"),
        ("RD/S/Q", "rd", "RD", "/S/Q"),
        ("del,x", "del", "del", ",x"),
        ("rd=/s", "rd", "rd", "=/s"),
        ("erase/f", "erase", "erase", "/f"),
        ("rmdir/s", "rmdir", "rmdir", "/s"),
        ("@,del/q", "del", "del", "/q"),
        ("reg,delete", "reg", "reg", ",delete"),
    ] {
        let found = exec_name(text, Some(Mode::Cmd));
        assert_eq!(
            (found.name.as_str(), found.shown, found.glued),
            (name, shown, Some(glued)),
            "{text}"
        );
    }
    // 経路形式と、削除命令以外の単純名は従来の`leaf()`判定のまま（`x/del`の既存拒否も保つ）。
    for (text, name) in [
        ("C:/tools/del/x", "x"),
        (r"C:\tools\del/x", "x"),
        ("./del", "del"),
        ("/c/bin/rd/x", "x"),
        ("tools/del/x", "x"),
        ("x/del", "del"),
        ("dir/b", "b"),
    ] {
        let found = exec_name(text, Some(Mode::Cmd));
        assert_eq!((found.name.as_str(), found.glued), (name, None), "{text}");
    }
    // 制御語（call・do・else）も切った名前と直結した残りを返す。
    for (text, name, glued) in [
        ("call,del", "call", ",del"),
        ("call=del", "call", "=del"),
        ("DO,del", "do", ",del"),
        ("else=del", "else", "=del"),
    ] {
        let found = exec_name(text, Some(Mode::Cmd));
        assert_eq!(
            (found.name.as_str(), found.glued),
            (name, Some(glued)),
            "{text}"
        );
    }
    // shell不明の候補判定では、`=`は直後（`, ; =`を除く）が`/`の場合だけ打ち切る。
    for (text, name, glued) in [
        ("rm=1", "rm=1", None),
        ("rd=foo", "rd=foo", None),
        ("call=del", "call=del", None),
        ("rd=/s", "rd", Some("=/s")),
        ("rd=,/s", "rd", Some("=,/s")),
        ("del,x", "del", Some(",x")),
    ] {
        let found = exec_name_in(text, Some(Mode::Cmd), false);
        assert_eq!((found.name.as_str(), found.glued), (name, glued), "{text}");
    }
    assert_eq!(cmd_glued_tail("cmd=1", false), None);
    assert_eq!(cmd_glued_tail("cmd=/c", false), Some("=/c"));
    assert_eq!(cmd_glued_tail("cmd=1", true), Some("=1"));
    // POSIX・PowerShell規則では切らない。
    assert_eq!(exec_name("rd/s/q", Some(Mode::Posix)).name, "q");
    assert_eq!(exec_name("del,x", Some(Mode::PowerShell)).name, "del,x");
}
#[test]
fn cmd_semicolon_boundary_is_marked_only_in_cmd_rules() {
    let marks = |mode: Mode, s: &str| -> Vec<String> {
        tokens(s, mode, false)
            .unwrap()
            .into_iter()
            .filter(|t| t.boundary)
            .map(|t| t.text)
            .collect()
    };
    assert_eq!(marks(Mode::Cmd, "cmd;/c x & y"), [";", ""]);
    assert_eq!(marks(Mode::Posix, "cmd;/c x"), [""]);
    assert_eq!(marks(Mode::PowerShell, "cmd;/c x"), [""]);
    // 引用された`;`は境界ではない。
    assert!(marks(Mode::Cmd, r#"cmd "a;b""#).is_empty());
}
#[test]
fn cmd_wrapper_split_by_semicolon_is_rejected_only_without_a_body() {
    // 本文switchを持たない`cmd`の直後の`;`は拒否する。理由はswitch解析不能と同じ。
    for command in [
        "cmd;/c del x",
        "cmd /d;/c del x",
        "cmd ;/c echo ok",
        "cmd;",
        "cmd /?;",
    ] {
        let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
        assert!(
            reason.contains("unsupported CMD wrapper switch"),
            "{command}: {reason}"
        );
    }
    // 本文switchが`;`より前にあれば従来どおり本文を検査し、無害な本文は通す。
    for command in [
        "cmd /c echo a;b",
        "cmd /d /c echo a;b",
        "echo a; cmd",
        "echo a;cmd /c echo b",
    ] {
        assert!(!denied(command, "cmd.exe"), "{command}");
    }
    // 先頭の`,`や`=`を付けた削除命令は、記号を落とした名前で報告する。
    for command in [",del x", "=del x", "cmd /c,del x", "cmd /c=del x"] {
        let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
        assert!(
            reason.contains(r#"detected token "del""#),
            "{command}: {reason}"
        );
    }
    for (command, token) in [
        ("rd/s/q x", "rd"),
        ("RD/S/Q x", "RD"),
        ("erase/f x", "erase"),
        ("del,x", "del"),
    ] {
        let reason = reason(command, "exec_command", Some("cmd.exe")).expect(command);
        assert!(
            reason.contains(&format!(r#"detected token "{token}""#)),
            "{command}: {reason}"
        );
    }
    let reason_reg =
        reason(r"reg/delete HKCU\x /f", "exec_command", Some("cmd.exe")).expect("reg/delete");
    assert!(
        reason_reg.contains("registry deletion command"),
        "{reason_reg}"
    );
    // CMD以外のshell規則では`;`は通常の文境界で、判定を変えない。
    assert!(!denied("cmd;/c echo ok", "pwsh"));
    if cfg!(windows) {
        // shell不明（Bash）ではCMD規則でも検査するため拒否される。
        assert!(reason("cmd;/c echo ok", "Bash", None).is_some());
    }
}
#[test]
fn cmd_do_and_else_bodies_are_inspected() {
    for command in [
        r"for %i in (a b) do del %i",
        r"for /f %i in ('dir /b') do del %i",
        r"for %i in (a) do if exist %i del %i",
        r"for %i in (a) do DO call del %i",
        r"if exist x (echo a) else del x",
        r"if exist x (echo a) ELSE reg delete HKCU\Software\PrunletHookProbe /f",
        r#"cmd /c "for %i in (a) do del %i""#,
        // `, =`で直結した形と、`do,`のように残りが空の形（次の語が実行名）。
        r"for %i in (a) do,del %i",
        r"for %i in (a) do=del %i",
        r"for %i in (a) do, del %i",
        r"for %i in (a) do,do,call,del %i",
        r"if exist x (echo a) else,del x",
        r"if exist x (echo a) ELSE=reg delete HKCU\Software\PrunletHookProbe /f",
        r"if exist x,del x",
        r"if /i not exist x,del x",
        r"call,cmd/c del x",
        // 制御語・`call`を外した後や接頭辞だけの語の後にも、リダイレクトと接頭辞の読み飛ばしを繰り返す。
        r"call >out del x",
        r"for %i in (a) do >nul del %i",
        r"if exist x (echo a) else >nul del x",
        r"@>nul del x",
        r"@ del x",
        r", del x",
        r"call call del x",
        r"for %i in (a) do,@ del %i",
        // `for /f`のコマンド集合（`'…'`・usebackqの`` `…` ``）の先頭語は実行名。
        r"for /f %i in ('del x') do rem",
        r"for /f %i in ('>nul del x') do rem",
        r"for /f %i in (' del x') do rem",
        r#"for /f "usebackq" %i in (`del x`) do rem"#,
    ] {
        assert!(denied(command, "cmd.exe"), "{command}");
        if cfg!(windows) {
            let wrapped = format!(r#"cmd /c "{command}""#);
            assert!(reason(&wrapped, "Bash", None).is_some(), "{wrapped}");
        }
    }
    for command in [
        r"for %i in (a) do echo del %i",
        r"if 1==1 (echo a) else echo del",
        "do",
        "else",
        "do,",
        "call,echo ok",
        "@echo off",
        "call x.bat",
        "call -x",
        "do echo del",
        "2>nul echo hi",
        "@ echo hi",
        r"for /f %i in ('dir /b') do echo %i",
        r#"for /f "usebackq" %i in (`dir /b`) do echo %i"#,
    ] {
        assert!(!denied(command, "cmd.exe"), "{command}");
    }
    // 語が分かれた制御語とリダイレクトの大量の反復も、再帰せず線形時間で終わる。
    let spaced = format!("{}echo x", "do >a ".repeat(100_000));
    assert!(!denied(&spaced, "cmd.exe"));
    let spaced = format!("{}del x", "do >a ".repeat(100_000));
    assert!(denied(&spaced, "cmd.exe"));
    // 上限以内の直結連鎖は削除命令として報告し、上限を超える連鎖は検査不能として拒否する。
    let within = format!("{}del x", "do,".repeat(CMD_GLUED_PREFIX_LIMIT));
    let found = reason(&within, "exec_command", Some("cmd.exe")).expect("within");
    assert!(found.contains(r#"detected token "del""#), "{found}");
    // 入力上限に近い1語の連鎖でも、評価し直す回数を抑えて線形時間で終わる。
    let long = format!("{}echo x", "do,".repeat(300_000));
    let found = reason(&long, "exec_command", Some("cmd.exe")).expect("long");
    assert!(
        found.contains("too many CMD control words joined by delimiters"),
        "{found}"
    );
    // shell不明時の`=`判定も、`x=,=,=,…`のような語で`=`ごとに前方走査しない。
    let equals = format!("x{}", "=,".repeat(400_000));
    assert!(cmd_glued_tail(&equals, false).is_none());
    assert_eq!(exec_name_in(&equals, Some(Mode::Cmd), false).glued, None);
    let equals_cmd = format!("cmd{}", "=,".repeat(400_000));
    assert!(cmd_glued_tail(&equals_cmd, false).is_none());
}
/// CMD規則では、`>&`の後に数字でも`-`でもない語が続く形（`>&del x`）は、従来どおり`&`で文を割って`del x`を検査する。
#[test]
fn cmd_redirect_ampersand_followed_by_a_name_is_still_inspected() {
    if !cfg!(windows) {
        return;
    }
    for command in [
        "echo a >&del x",
        ">&del x",
        "echo a 2>&del x",
        "echo a >& del x",
        "echo a 2>& del x",
        "echo a >&\"del\" x",
        ">&\"del\" x",
        "echo a 2>&\"del\" x",
    ] {
        assert!(
            reason(command, "exec_command", Some("cmd.exe")).is_some(),
            "{command:?}"
        );
        assert!(reason(command, "Bash", None).is_some(), "{command:?}");
    }
}
