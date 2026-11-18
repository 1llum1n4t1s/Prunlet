use super::*;

#[test]
fn non_strict_powershell_assignments_and_dot_calls_are_inspected() {
    for command in [
        r#"$x = Remove-Item -LiteralPath "C:\fixture\file.txt""#,
        r"$x=Remove-Item C:\fixture\file.txt",
        r"[string]$x = rm C:\fixture\file.txt",
        r"$x += del C:\fixture\file.txt",
        r"return Remove-Item C:\fixture\file.txt",
        r"foreach ($f in Remove-Item C:\fixture\file.txt) { $f }",
        r"$x = reg.exe delete HKCU\Software\PrunletHookProbe /f",
        r"$o.'Length' = Remove-Item C:\fixture\file.txt",
        r"$x = cmd //c del C:\fixture\file.txt",
        r". Remove-Item C:\fixture\file.txt",
        r". rm C:\fixture\file.txt",
    ] {
        assert!(denied(command, "pwsh"), "{command}");
    }
    assert!(denied(
        r#"pwsh -Command "$x = Remove-Item C:\fixture\file.txt""#,
        "cmd.exe"
    ));
    // 検索文字列・引用・ヒアストリング内のdataは誤拒否しない。
    for command in [
        r"$x = 'Remove-Item C:\fixture\file.txt'",
        r#"$pattern = "rm -rf""#,
        "$script = @'\nRemove-Item C:\\fixture\\file.txt\n$y = rm x\n'@\nWrite-Output $script",
        "$script=@'\n. Remove-Item x\n'@",
        r"rg -n '$x = Remove-Item' .",
        r"$hits = Select-String -Pattern 'Remove-Item' -Path a.txt",
        r". .\env.ps1",
        r"$o.'Length' = 5",
        r"$files = Get-ChildItem; foreach ($f in $files) { $f.Name }",
        r"$x -= 1",
    ] {
        assert!(!denied(command, "pwsh"), "{command}");
    }
    assert!(!denied(
        r#"pwsh -Command "$x = 'Remove-Item C:\fixture\file.txt'""#,
        "cmd.exe"
    ));
}
#[test]
fn standalone_encoded_detection_has_no_candidate_note() {
    if !cfg!(windows) {
        return;
    }
    let data = encode_utf16_base64(r"Remove-Item -LiteralPath C:\fixture\file.txt");
    let confirmed = reason(
        &format!("pwsh -NoProfile -EncodedCommand {data}"),
        "Bash",
        None,
    )
    .expect("standalone encoded delete must be denied");
    assert!(
        confirmed.contains("interpretation=PowerShell"),
        "{confirmed}"
    );
    assert!(
        !confirmed.contains("candidate interpretation"),
        "{confirmed}"
    );
    assert!(!confirmed.contains("UTF-16LE Base64"), "{confirmed}");
    // 単独形式でない呼出しは従来どおり候補注記と変換案内を付ける。
    let candidate = reason(&format!("pwsh -NoProfile -e {data}"), "Bash", None)
        .expect("noncanonical encoded command must be denied");
    assert!(
        candidate.contains("candidate interpretation"),
        "{candidate}"
    );
}
/// 共通指示の管理者起動（名前付きの静的cmd.exe＋固定形の単一引用引数）だけを許可し、
/// 本文の削除・入れ子shell・メタ文字による文の分割・位置引数や既定値による注入は拒否する。
#[test]
fn encoded_admin_cmd_start_process_accepts_only_the_fixed_form() {
    if !cfg!(windows) {
        return;
    }
    let encode = encoded_command;
    // reason()がhookへ渡す配置済みCLI・設定（C:\fixture\…）と同じパスだけが許可される。
    let cli = r#""C:\fixture\prunlet.exe" --config "C:\fixture\config.json""#;
    let admin_registry = format!(
        r#"Start-Process -FilePath cmd.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '/d /c "{cli} registry-delete --view 64 --recursive -- HKEY_CURRENT_USER\Software\PrunletE2E\x > D:\tmp\out.json 2>&1"'"#
    );
    for allowed in [
            admin_registry.clone(),
            format!(
                r#"New-Item -ItemType Directory -Path D:\tmp\x -Force | Out-Null; {admin_registry}"#
            ),
            format!(r#"$p = {admin_registry}"#),
            format!(
                r#"Start-Process -ArgumentList '/d /c "{cli} delete --paths-file D:\tmp\x\list.json"' -Verb RunAs -PassThru -FilePath cmd"#
            ),
            format!(
                r#"saps -FilePath 'C:\Windows\System32\cmd.exe' -ArgumentList '/d /c "{cli} delete --paths-file D:\tmp\x\list.json"' -Verb RunAs"#
            ),
            // CLI・設定パスのASCII大文字小文字の違いは同じ配置として扱う。
            r#"Start-Process -FilePath cmd.exe -ArgumentList '/d /c ""c:\FIXTURE\Prunlet.exe" --config "C:\fixture\CONFIG.json" delete --paths-file D:\a.json"'"#.to_owned(),
        ] {
            assert_eq!(reason(&encode(&allowed), "Bash", None), None, "{allowed}");
        }
    let body = |arguments: &str| {
        format!("Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '{arguments}'")
    };
    let mut denied = vec![
            // 本文の削除・入れ子shell・CMDのstart・実行体の差し替え。
            body(r"/d /c del C:\fixture\file.txt"),
            body(r"/d /c rd /s /q C:\fixture"),
            body(r"/d /c reg delete HKCU\Software\X /f"),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete" & del C:\fixture"#),
            // 配置済みCLI・設定以外の実行体や設定（同名の任意exeを含む）は昇格させない。
            body(r#"/d /c ""C:\x\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\x\config.json" delete --paths-file C:\a.json""#),
            body(r#"/d /c ""C:\fixture\..\x\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json""#),
            // 出力リダイレクト先は.jsonだけ（任意ファイルを管理者権限で切り詰めさせない）。ADS指定も拒否する。
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\Windows\System32\drivers\etc\hosts 2>&1""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\o.json:x.json 2>&1""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\o.json""#),
            // ASCII以外の大文字小文字畳み込み（ケルビン記号・長いs）で許可文字やパスに一致させない。
            body("/d /c \"\"C:\\fixture\\prunlet.exe\" --config \"C:\\fixture\\config.json\" delete --paths-file C:\\a.j\u{17f}on\""),
            body("/d /c \"\"C:\\fixture\\prunlet.exe\" --config \"C:\\fixture\\config.j\u{17f}on\" delete --paths-file C:\\a.json\""),
            // cmd.exeが実際に解釈する区切り・演算子・引用・展開（検査器との解釈のずれ）。
            body(r"& /d /c del C:\x"),
            body(r"| /d /c del C:\x"),
            body(r"( /d /c del C:\x"),
            body(r") /d /c del C:\x"),
            body(r"/d & /c del C:\x"),
            body("x\n/d /c del C:\\x"),
            body("/d\n/c del C:\\x"),
            body(r#"/d /c "reg" delete HKCU\Software\X /f"#),
            body(r#"/d /c "del" C:\x"#),
            body(r#"/d /c "C:\Windows\System32\cmd.exe" /c del C:\x"#),
            body(r#"/d /c "ver" "& del C:\x""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json" & del C:\x"#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file %ComSpec%""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file ^C:\a.json""#),
            body(r#"/d /c ""C:\fixture\prunlet.exe" --config "C:\fixture\config.json" delete --paths-file C:\a.json > C:\o.json 2>&1 & del C:\x""#),
            // 位置引数・括弧式・scriptblock・既定値による注入・ArgumentListの省略。
            r"Start-Process cmd.exe ('/d /c del C:\x') -Verb RunAs".to_owned(),
            r"Start-Process cmd.exe {/d /c del C:\x}".to_owned(),
            r"$a='/c del C:\x'; Start-Process cmd.exe ($a)".to_owned(),
            r"Start-Process cmd.exe '/d /c exit 1' -Verb RunAs".to_owned(),
            r"$PSDefaultParameterValues.Add('Start-Process:ArgumentList','/d /c del C:\x'); Start-Process -FilePath cmd.exe -Verb RunAs".to_owned(),
            r"Start-Process -FilePath cmd.exe -Verb RunAs".to_owned(),
            r"Start-Process cmd -Verb RunAs".to_owned(),
            // 起動先がcmd以外・動的、引数が配列・二重引用・変数・連結・ヒアストリングの形。
            r"Start-Process -FilePath pwsh -ArgumentList '-NoProfile'".to_owned(),
            r"Start-Process -FilePath powershell.exe -Verb RunAs".to_owned(),
            r"Start-Process rm".to_owned(),
            r"Start-Process -FilePath $exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/d','/c','del C:\fixture'".to_owned(),
            r#"Start-Process -FilePath cmd.exe -ArgumentList "/d /c $x""#.to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList $arguments".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/d /c'$tail".to_owned(),
            "Start-Process -FilePath cmd.exe -ArgumentList @'\n/d /c dir\n'@".to_owned(),
            // 省略形・colon形・未知や重複の引数・退避文字は受理しない。
            r"Start-Process -File cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -Args '/c dir' -FilePath cmd.exe".to_owned(),
            r"Start-Process -FilePath:cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/c dir' -Credential $c".to_owned(),
            r"Start-Process -FilePath cmd.exe -FilePath cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.exe -ArgumentList '/c dir' extra".to_owned(),
            r"Start-Process -FilePath cmd.exe. -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath D:\tmp\cmd.exe -ArgumentList '/c dir'".to_owned(),
            r"Start-Process -FilePath cmd.`exe -ArgumentList '/c dir'".to_owned(),
            // 呼出し演算子での名前指定・Invoke-Expressionは従来どおり拒否する。
            r"& 'Start-Process' rm".to_owned(),
            r#"Invoke-Expression "cmd /c dir""#.to_owned(),
        ];
    // 本文が正規形でも、同じ形の拒否理由が`Start-Process`起点であることを確認するための別名・switch重複。
    denied.push(format!(
            r#"Start-Process -FilePath cmd.exe -Wait -Wait -ArgumentList '/d /c "{cli} delete --paths-file D:\a.json"'"#
        ));
    for command in &denied {
        assert!(
            reason(&encode(command), "Bash", None).is_some(),
            "{command}"
        );
    }
}
/// 非strictのPowerShell規則のブロックコメント・スマート引用符・ヒアストリングの境界を言語仕様に合わせる。
/// strict（EncodedCommand）の拒否は従来どおり。
#[test]
fn powershell_lexer_handles_block_comments_smart_quotes_and_here_strings() {
    for command in [
        // ブロックコメントの`#>`を行コメントと誤認して、後ろの文を捨てない。
        "<# c #> Remove-Item y",
        "Get-Date <# c #> ; Remove-Item y",
        "<# a\nb #> Remove-Item y",
        // スマート引用符はASCIIと同じ種類の引用符。
        "& \u{2018}Remove-Item\u{2019} x",
        "echo 'a\u{2019}; Remove-Item x; \u{2019}b'",
        "echo \u{201c}a\"; Remove-Item x; \"b\u{201d}",
        // ヒアストリングの本文は終端直前の改行を含まない。
        "& @'\nRemove-Item\n'@ x",
        "& @'\r\nRemove-Item\r\n'@ x",
    ] {
        assert!(denied(command, "pwsh"), "{command:?}");
        if cfg!(windows) {
            assert!(reason(command, "Bash", None).is_some(), "{command:?}");
        }
    }
    if cfg!(windows) {
        for command in [
            "pwsh -Command \"<# c #> Remove-Item y\"",
            "pwsh -Command \"Get-Date <# c #> ; Remove-Item y\"",
        ] {
            assert!(reason(command, "Bash", None).is_some(), "{command:?}");
        }
    }
    for allowed in [
        "<# Remove-Item y #> Get-Date",
        "Get-Date <# Remove-Item y #>",
        "echo \u{2018}Remove-Item x\u{2019}",
        "$x = @'\n'@",
        "Write-Output @'\nRemove-Item\n'@",
    ] {
        assert!(!denied(allowed, "pwsh"), "{allowed:?}");
    }
    // 語の途中の`@"`・`@'`はヒアストリングではない（shell不明の検査で全体を拒否しない）。
    for allowed in [
        "ssh user@\"host\" ls",
        "npm i pkg@\"1.2.3\"",
        "git clone git@'github.com':o/r.git",
    ] {
        assert!(!denied(allowed, "pwsh"), "{allowed:?}");
        if cfg!(windows) {
            assert_eq!(reason(allowed, "Bash", None), None, "{allowed:?}");
        }
    }
    if cfg!(windows) {
        // strictではスマート引用符・ブロックコメント・不正なヒアストリング見出しを従来どおり拒否する。
        for command in [
            "<# c #> Get-Date",
            "echo \u{2018}x\u{2019}",
            "ssh user@'host' ls",
        ] {
            assert!(
                reason(&encoded_command(command), "Bash", None).is_some(),
                "{command:?}"
            );
        }
    }
}
/// EncodedCommand内の`"$(...)"`は参照だけの形、pwshは静的な`.ps1`の`-File`実行だけを許可する。
#[test]
fn encoded_property_subexpressions_and_static_pwsh_file_are_allowed() {
    if !cfg!(windows) {
        return;
    }
    let encode = encoded_command;
    for allowed in [
        r#"$sw = [Diagnostics.Stopwatch]::StartNew(); "test sec: $($sw.Elapsed.TotalSeconds)""#,
        r#""first: $($r.items[0].Name) of $($r.Count)""#,
        r#""home=$($env:USERPROFILE)""#,
        r"pwsh -NoProfile -File D:\tmp\x\run.ps1 -Label a",
        r"& pwsh -NoProfile -NonInteractive -File 'D:\tmp\x y\run.ps1'; 'exit=' + $LASTEXITCODE",
        r"powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\setup.ps1",
    ] {
        assert_eq!(reason(&encode(allowed), "Bash", None), None, "{allowed}");
    }
    for denied in [
        r#""$(Remove-Item C:\fixture\x)""#,
        r#""$($f.Delete())""#,
        r#""$($x.Prop)$(Remove-Item C:\fixture\x)""#,
        r#""$($x | Remove-Item)""#,
        r#""$($x.Prop; Remove-Item C:\fixture\x)""#,
        r#""$($x[$i])""#,
        r"pwsh -File -",
        r"pwsh -NoProfile -File $s",
        r"pwsh -Command Remove-Item C:\fixture\x",
        r"pwsh -NoProfile -File x.ps1; Remove-Item C:\fixture\x",
        r"pwsh -f x.ps1",
        r"pwsh -File x.txt",
        r"pwsh -ExecutionPolicy $p -File x.ps1",
        r"pwsh -EncodedCommand AAAA -File x.ps1",
        r"cmd /c D:\tmp\x.cmd",
    ] {
        assert!(reason(&encode(denied), "Bash", None).is_some(), "{denied}");
    }
}
/// EncodedCommand内で引数として渡す単独の`.`（カレントディレクトリ）はdot-sourcingとみなさず、
/// コマンド位置の`.`（文頭・区切りやキーワードの直後）は従来どおり拒否する。
#[test]
fn encoded_dot_argument_is_not_dot_sourcing() {
    if !cfg!(windows) {
        return;
    }
    let encode = encoded_command;
    for allowed in [
        r#"rg -n "net8" -g "*.csproj" . ; dotnet build -c Release"#,
        r"Get-ChildItem -Recurse -Force -Filter config.toml -Path . -Depth 3",
        r#"git grep -n "x" -- . ':!RELEASE_NOTES.md' | Select-Object -First 3"#,
        r"dotnet new console -n EtlSplit -o . --force 2>&1 | Select-Object -Last 1",
        r"git add . 2>&1",
        "Set-Location D:\\x\nrg -n \"catalog\" . ; 'done'",
        r"rg -n 'x' .",
    ] {
        assert_eq!(reason(&encode(allowed), "Bash", None), None, "{allowed}");
    }
    for denied in [
        r". ./build/DevelopmentOutput.ps1; Get-X",
        r". 'D:\tmp\x\inventory.ps1'",
        r"Get-Item x; . ./a.ps1",
        r"Get-Item x | . ./a.ps1",
        r"if ($a) { . ./a.ps1 }",
        r"$x = . ./a.ps1",
        r"return . ./a.ps1",
        "Get-Item x\n. ./a.ps1",
        "Get-Item x `\n. ./a.ps1",
        r"Get-Item x .('./a.ps1')",
        r"Get-Item . ; Remove-Item C:\fixture\x",
    ] {
        assert!(reason(&encode(denied), "Bash", None).is_some(), "{denied}");
    }
}
/// Windows PowerShell 5.1の名前なし位置引数は`-Command`として実行されるため本文として検査する。
#[test]
fn windows_powershell_positional_argument_is_inspected_as_command() {
    for command in [
        r#"powershell "Remove-Item C:\fixture\x""#,
        r#"powershell -NoProfile "Remove-Item C:\fixture\x""#,
        r"powershell -ExecutionPolicy Bypass Remove-Item C:\fixture\x",
        r"powershell -NoProfile -WindowStyle Hidden Remove-Item C:\fixture\x",
        r"powershell.exe -ep Bypass Remove-Item C:\fixture\x",
    ] {
        for shell in ["pwsh", "cmd.exe"] {
            assert!(denied(command, shell), "{shell}: {command}");
        }
    }
    // 位置引数の手前に未知のoptionがあれば本文の位置を確定できない。
    let unknown = reason("powershell -Foo x", "exec_command", Some("pwsh")).expect("unknown");
    assert!(
        unknown.contains("unsupported PowerShell wrapper option"),
        "{unknown}"
    );
    for command in [
        "powershell -File x.ps1",
        "powershell x.ps1",
        r#"powershell -NoProfile -Command "echo hi""#,
        r#"powershell -NoProfile "echo hi""#,
        "powershell -ExecutionPolicy Bypass -File x.ps1",
        "powershell -NoProfile",
        "pwsh x.ps1",
        "pwsh -NoProfile -File x.ps1",
    ] {
        for shell in ["pwsh", "cmd.exe"] {
            assert!(!denied(command, shell), "{shell}: {command}");
        }
    }
}
