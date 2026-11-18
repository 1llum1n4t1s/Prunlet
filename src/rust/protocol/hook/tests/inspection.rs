use super::*;

#[test]
fn assignments_and_redirections_keep_command_detection() {
    for command in [
        "A=1 rm -- /tmp/owned-fixture",
        "env A=1 rm -- /tmp/owned-fixture",
        "if true; then 2>/tmp/owned-output rm -- /tmp/owned-fixture; fi",
        // 追記代入（`+=`）と添字付き代入（`a[0]=`・動的な添字）も代入として剥がし、後続の実行名を検査する。
        "a+=1 rm -rf /tmp/y",
        "a[0]=1 unlink /tmp/y",
        "a[$i]+=x rm -rf /tmp/y",
        "for f in a; do a[$f]=1 unlink /tmp/y; done",
    ] {
        let result = Inspector::default().contains(command, 0, Some(Mode::Posix), false);
        assert!(result.is_err() || result.unwrap(), "{command}");
        if cfg!(windows) {
            assert!(reason(command, "Bash", None).is_some(), "{command}");
        }
    }
    for command in [
        "A=1 printf '%s' rm",
        "env A=1 printf '%s' safe",
        "a+=1; echo ok",
        "a[0]=1",
        "for f in a b; do a[$f]=1; done",
    ] {
        assert!(
            !Inspector::default()
                .contains(command, 0, Some(Mode::Posix), false)
                .unwrap(),
            "{command}"
        );
    }
}
#[test]
fn depth_limit_is_fail_closed_for_every_shell() {
    let chain = |prefix: &str, count: usize, tail: &str| format!("{}{tail}", prefix.repeat(count));
    for (prefix, shell) in [
        ("cmd /c ", "cmd.exe"),
        ("pwsh -c ", "pwsh"),
        ("cmd /c ", "pwsh"),
    ] {
        assert!(
            !denied(&chain(prefix, 4, "echo ok"), shell),
            "{shell}: 4 levels"
        );
        let reason = reason(&chain(prefix, 5, "echo ok"), "exec_command", Some(shell))
            .expect("5 levels must be denied");
        assert!(
            reason.contains("inspection depth limit exceeded"),
            "{reason}"
        );
    }
}
#[test]
fn noncanonical_scan_is_linear_and_reports_the_first_match() {
    let detection = |command: &str| {
        let mut inspector = Inspector::default();
        let found = inspector
            .contains(command, 0, Some(Mode::Posix), false)
            .unwrap();
        found.then(|| inspector.detection.unwrap())
    };
    // 最初のpwshは-Fileで停止し、2つ目のpwshの直後の-encを検出する。
    let found = detection("time pwsh -File x pwsh -enc AAAA").unwrap();
    assert!(found.contains(r#"detected token "-enc""#), "{found}");
    // 複数該当時は最も前の実行名に対応するtokenを報告する（従来の前方走査と同じ）。
    let found = detection("time pwsh -enc AAAA pwsh -ec BBBB").unwrap();
    assert!(found.contains(r#"detected token "-enc""#), "{found}");
    // -Commandより後ろのencoded optionは本文側の語として扱い、ここでは検出しない。
    assert!(detection("time pwsh -Command Write-Output -enc").is_none());
    // 実行名が大量に並ぶ入力でも1回の走査で完了する。
    let many = format!("time {}-enc AAAA", "pwsh ".repeat(20_000));
    let found = detection(&many).unwrap();
    assert!(found.contains(r#"detected token "-enc""#), "{found}");
}
/// `command`と`cmd`が併存する入力は、どちらを実行するかを決めずに全てを検査する。
/// 片方だけの入力の挙動は変えない。
#[test]
fn command_and_cmd_together_are_both_inspected() {
    let run = |tool_input: Value| {
        let input = json!({"tool_name":"exec_command","tool_input":tool_input});
        inspect(
            &input,
            Path::new("/fixture/config.json"),
            Path::new("/fixture/prunlet"),
        )
    };
    let denied = |tool_input: Value| {
        run(tool_input).map_or(true, |v| {
            v["hookSpecificOutput"]["permissionDecision"] == "deny"
        })
    };
    let safe = "echo ok";
    let bad = "rm -rf /tmp/fixture";
    // 片方だけ（従来どおり）。
    assert!(!denied(json!({"command":safe,"shell":"sh"})));
    assert!(!denied(json!({"cmd":safe,"shell":"sh"})));
    assert!(denied(json!({"command":bad,"shell":"sh"})));
    assert!(denied(json!({"cmd":bad,"shell":"sh"})));
    // 併存: どちらか一方でも拒否対象なら拒否する（従来は`command`だけを検査していた）。
    assert!(denied(json!({"command":safe,"cmd":bad,"shell":"sh"})));
    assert!(denied(json!({"command":bad,"cmd":safe,"shell":"sh"})));
    assert!(!denied(json!({"command":safe,"cmd":safe,"shell":"sh"})));
    // 併存でどちらかが文字列でなければ検査不能として拒否する。
    assert!(denied(json!({"command":safe,"cmd":1,"shell":"sh"})));
}
/// 削除命令の拒否は従来どおりCLIの完全な案内を付け、検査不能による拒否は短い案内だけを返す。
#[test]
fn inspection_limit_rejections_use_a_short_reason() {
    let deletion = reason(
        r"Remove-Item -LiteralPath C:\fixture\x",
        "exec_command",
        Some("pwsh"),
    )
    .expect("deletion must be denied");
    assert!(
        deletion.contains("detected token \"Remove-Item\""),
        "{deletion}"
    );
    assert!(deletion.contains("delete --paths-file"), "{deletion}");
    let limit = reason("case x in a) echo;; esac", "exec_command", Some("bash"))
        .expect("unsupported syntax must be denied");
    assert!(limit.contains("interpretation="), "{limit}");
    assert!(
        limit.contains("inspection limit, not a detected deletion"),
        "{limit}"
    );
    assert!(limit.contains("delete --paths-file"), "{limit}");
    assert!(limit.len() < 700, "{} chars: {limit}", limit.len());
    if cfg!(windows) {
        assert!(deletion.len() > limit.len() * 2, "{deletion}");
        let candidate = reason("case x in a) echo;; esac", "Bash", None)
            .expect("unsupported syntax must be denied");
        assert!(
            candidate.contains("candidate interpretation"),
            "{candidate}"
        );
        assert!(
            candidate.len() < 800,
            "{} chars: {candidate}",
            candidate.len()
        );
    }
}
#[test]
#[expect(
    clippy::invalid_regex,
    reason = "意図的な不正patternでcompile失敗がpanicせず検査errorになることを確認する"
)]
fn invalid_cached_pattern_remains_a_fallible_inspection_error() {
    static INVALID: LazyLock<std::result::Result<Regex, regex::Error>> =
        LazyLock::new(|| Regex::new("["));
    assert!(compiled(&INVALID).is_err());
}
