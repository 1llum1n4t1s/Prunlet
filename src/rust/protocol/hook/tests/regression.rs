use super::*;

/// scripts/Verify-HookParsing.ps1 に追加した回帰ケースと同じ文字列・期待値。
/// E2EではBashはshellを無視して全規則で検査されるため、Bash側の期待値もここで確かめる。
#[test]
fn verify_script_regression_cases_match_expectations() {
    let file = r"D:\fixture\hook-sentinel.txt";
    // 文字列としてhookへ渡すだけの架空パス。特定の開発環境のパスに依存させない。
    let exe = r"D:\example\build\publish\prunlet.exe";
    let config = r"C:\Users\example\.local\Prunlet\config.json";
    let json = r"D:\example\hook\hook-paths.json";
    let here = "$script = @'\nRemove-Item -LiteralPath \"<FILE>\"\n$y = Remove-Item -LiteralPath \"<FILE>\"\n'@\nWrite-Output $script";
    let canonical =
        format!(r#"cmd.exe /d /c "{exe} --config {config} delete --paths-file {json}""#);
    let canonical_msys =
        format!(r#"cmd.exe //d //c "{exe} --config {config} delete --paths-file {json}""#);
    let call =
        format!(r#"cmd.exe /d /c call "{exe}" --config "{config}" delete --paths-file "{json}""#);
    let call_msys =
        format!(r#"cmd.exe //d //c call "{exe}" --config "{config}" delete --paths-file "{json}""#);
    // (コマンド, shell, exec_commandでの通過, Bashでの通過)
    let cases: Vec<(&str, Option<&str>, bool, bool)> = vec![
        (r#"cmd.exe //c del "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"cmd.exe //d //c del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"cmd.exe //d //c del "<FILE>""#,
            Some("pwsh"),
            false,
            false,
        ),
        (r#"cmd /R del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /cdel "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /d/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /D/Q/C "del <FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"cmd /e:on /v:off /t:0a /s /c del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r"cmd.exe //d //c reg delete HKCU\Software\PrunletHookProbe /f",
            None,
            false,
            false,
        ),
        ("cmd /z /c echo ok", Some("cmd.exe"), false, false),
        ("cmd stray /c echo ok", Some("cmd.exe"), false, false),
        ("cmd /?", Some("cmd.exe"), true, true),
        (
            r"cmd.exe //d //c reg query HKCU\Software\PrunletHookProbe",
            Some("cmd.exe"),
            true,
            true,
        ),
        (
            r#"cmd.exe //d //c echo del "<FILE>""#,
            Some("cmd.exe"),
            true,
            true,
        ),
        (&canonical, Some("cmd.exe"), true, true),
        (&canonical, None, true, true),
        (&canonical_msys, None, true, true),
        (&call, Some("cmd.exe"), true, true),
        (&call_msys, None, true, true),
        (
            "cmd /c cmd /c cmd /c cmd /c echo ok",
            Some("cmd.exe"),
            true,
            true,
        ),
        (
            "cmd /c cmd /c cmd /c cmd /c cmd /c echo ok",
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            "pwsh -c pwsh -c pwsh -c pwsh -c pwsh -c Write-Output ok",
            Some("pwsh"),
            false,
            false,
        ),
        (
            r#"for %i in ("<FILE>") do del %i"#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"for %i in ("<FILE>") do if exist %i del %i"#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"if exist "<FILE>" (echo keep) else del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r"if 1==2 (echo keep) else reg delete HKCU\Software\PrunletHookProbe /f",
            Some("cmd.exe"),
            false,
            false,
        ),
        ("for %i in (a) do echo del %i", Some("cmd.exe"), true, false),
        (
            "if 1==1 (echo keep) else echo del",
            Some("cmd.exe"),
            true,
            true,
        ),
        (
            r#"$x = Remove-Item -LiteralPath "<FILE>""#,
            Some("pwsh"),
            false,
            false,
        ),
        (
            r#"$x=Remove-Item -LiteralPath "<FILE>""#,
            Some("pwsh"),
            false,
            false,
        ),
        (
            r#"return Remove-Item -LiteralPath "<FILE>""#,
            Some("pwsh"),
            false,
            false,
        ),
        (
            r#". Remove-Item -LiteralPath "<FILE>""#,
            Some("pwsh"),
            false,
            false,
        ),
        (
            r#"pwsh -Command "$x = Remove-Item -LiteralPath <FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"$x = 'Remove-Item -LiteralPath "<FILE>"'"#,
            Some("pwsh"),
            true,
            true,
        ),
        (here, Some("pwsh"), true, false),
        (
            r#"$hits = Select-String -Pattern 'Remove-Item' -Path "<FILE>""#,
            Some("pwsh"),
            true,
            true,
        ),
        (
            r#"rg -n '$x = Remove-Item' "<FILE>""#,
            Some("pwsh"),
            true,
            true,
        ),
        (r". .\env.ps1", Some("pwsh"), true, true),
        // 語の途中の本文switch（cmd.exeはコマンドライン全体から/Cを探す）。
        (r#"cmd x/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd "x"/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd ,/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /d x/c del "<FILE>""#, Some("cmd.exe"), false, false),
        // cmd.exeは`;` `,` `=`を空白相当の区切りとして扱い、実行名も最初の`/ , ; =`で打ち切る。
        // `;`で割れた`cmd`wrapper、実行名直結の`/c`、実行名・本文先頭の`, =`はいずれも本文を実行する。
        (r#"cmd;/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd ;/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /d;/c del "<FILE>""#, Some("cmd.exe"), false, false),
        ("cmd\t;/c del \"<FILE>\"", Some("cmd.exe"), false, false),
        (r#"cmd,/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd=/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd.exe/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"C:/Windows/System32/cmd.exe/c del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"C:\Windows\System32\cmd.exe/c del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (r#"call cmd/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"cmd /c cmd;/c del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (r#"cmd /c=del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /c,del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#",del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"=del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /c ,del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd =/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"cmd /d/q=/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"cmd /e:on,/c del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (r#"cmd /c;del "<FILE>""#, Some("cmd.exe"), false, false),
        ("cmd\t/c del \"<FILE>\"", Some("cmd.exe"), false, false),
        (r#"cmd ';/c' del "<FILE>""#, Some("pwsh"), false, false),
        // 単純名の削除命令に直結した`/ , =`も、cmd.exeは実行名の終端として読む。
        (r#"rd/s/q "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"RD/S/Q "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"del/q "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"del,"<FILE>""#, Some("cmd.exe"), false, false),
        (r#"rd=/s "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"erase/f "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"rmdir/s "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"call del/q "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"if exist "<FILE>" del/q "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (r#"cmd /c rd/s/q "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r"reg,delete HKCU\Software\PrunletHookProbe /f",
            Some("cmd.exe"),
            false,
            false,
        ),
        // 経路形式（`:` `\`を含む・`.` `/`始まり）の実行名は`/`を経路区切りとして読み、
        // 最後の要素で判定する。`C:/tools/del/x`は外部プログラム`x`の実行とみなして通す。
        (r"C:/tools/del/x", Some("cmd.exe"), true, true),
        ("tools/del/x", Some("cmd.exe"), true, true),
        ("echo del/q x", Some("cmd.exe"), true, true),
        ("dir/b", Some("cmd.exe"), true, true),
        ("reg/?", Some("cmd.exe"), true, true),
        // 誤拒否してはいけない形。`=` `,` `;` `/`は実行名とcmdのswitch位置以外では通常の文字として扱う。
        (r#"cmd /k echo hi/there"#, Some("cmd.exe"), true, true),
        ("cmd /c echo a;b", Some("cmd.exe"), true, true),
        ("echo ok;cmd /c echo hi", Some("cmd.exe"), true, true),
        ("set X=1", Some("cmd.exe"), true, true),
        ("if a==b echo x", Some("cmd.exe"), true, true),
        ("echo a;b", Some("cmd.exe"), true, true),
        ("echo a/b", Some("cmd.exe"), true, true),
        ("echo ,del x", Some("cmd.exe"), true, true),
        (r"dir C:/Windows /b", Some("cmd.exe"), true, true),
        (
            r"reg query HKCU\Software\PrunletHookProbe",
            Some("cmd.exe"),
            true,
            true,
        ),
        // 制御語（call・do・else）や`if`の条件に`, =`で直結した実行名も、cmd.exeは実行する。
        // `=`での打切りはshellがcmdと明示された場合だけ無条件に行い、shell不明（Bash）では
        // POSIX代入と区別できないため`=`の直後が`/`の場合に限る（`call=del`はBashでは通す）。
        (r#"call,del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"call=del "<FILE>""#, Some("cmd.exe"), false, true),
        (r#"call,cmd/c del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"call,"del" "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"if exist "<FILE>",del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r"if exist <FILE>,del/q,<FILE>",
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"if not exist "<FILE>.x",del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"for %i in ("<FILE>") do,del %i"#,
            Some("cmd.exe"),
            false,
            false,
        ),
        // Bashでは`do=del`をCMD候補では通すが、POSIX候補の`for`構文検査で拒否される。
        (
            r#"for %i in ("<FILE>") do=del %i"#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"if 1==2 (echo no) else,del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"if 1==2 (echo no) else=del "<FILE>""#,
            Some("cmd.exe"),
            false,
            true,
        ),
        // shell不明（Bash）でのPOSIX代入は削除命令とみなさない。
        ("rm=1; echo ok", None, true, true),
        ("ri=0", None, true, true),
        ("rd=foo", None, true, true),
        ("rp=$(realpath x)", None, true, true),
        ("cmd=1; echo ok", None, true, true),
        // 引用内の`,`や、削除命令以外への直結は通す。
        (r#"if exist "a,b.txt" echo ok"#, Some("cmd.exe"), true, true),
        ("if exist a,b echo ok", Some("cmd.exe"), true, true),
        ("type a.txt,b.txt", Some("cmd.exe"), true, true),
        ("call,echo ok", Some("cmd.exe"), true, true),
        ("for %i in (a;b) do echo %i", Some("cmd.exe"), true, false),
        ("set PATH=C:\\x;%PATH%", Some("cmd.exe"), true, true),
        // 制御語・callを外した後や接頭辞だけの語の後のリダイレクト、`for /f`のコマンド集合、
        // 本文が`"`で始まる`cmd /c "…" 引数`も実行名を隠さない。
        (r#"call >nul del "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"for %i in ("<FILE>") do >nul del %i"#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (
            r#"if exist "<FILE>" (echo keep) else >nul del "<FILE>""#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (r#"@>nul del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"@ del "<FILE>""#, Some("cmd.exe"), false, false),
        (r#"call call del "<FILE>""#, Some("cmd.exe"), false, false),
        (
            r#"for /f %i in ('del "<FILE>"') do rem"#,
            Some("cmd.exe"),
            false,
            false,
        ),
        (r#"cmd /d /c "del <FILE>" x"#, Some("cmd.exe"), false, false),
        (r#"cmd //d //c "del <FILE>" x"#, None, false, false),
        ("@echo off", Some("cmd.exe"), true, true),
        (
            "for /f %i in ('dir /b') do echo %i",
            Some("cmd.exe"),
            true,
            false,
        ),
        (
            r#"cmd /d /c "C:\Program Files\Tool\tool.exe" --flag value"#,
            Some("cmd.exe"),
            true,
            true,
        ),
    ];
    for (command, shell, pass, bash_pass) in cases {
        let command = command.replace("<FILE>", file);
        let actual = reason(&command, "exec_command", shell);
        assert_eq!(
            actual.is_none(),
            pass,
            "exec_command {shell:?}: {command}: {actual:?}"
        );
        if cfg!(windows) {
            let actual = reason(&command, "Bash", None);
            assert_eq!(actual.is_none(), bash_pass, "Bash: {command}: {actual:?}");
        }
    }
}
