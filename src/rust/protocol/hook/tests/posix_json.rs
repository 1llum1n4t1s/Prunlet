use super::*;

/// `hook-posix.json`の全ケースを、外側の規則に覆われないよう`Mode::Posix`だけで直接検査する。
/// 実プロセスのhook検証（Verify-HookParsing.ps1）はWindowsでshell不明の候補解釈や他の規則が先に拒否する
/// 形を区別できず、非Windowsで`pass`を検証する経路も限られるため、全OSで走るこの表で補う。
/// 拒否期待のケースは、JSONの`reason`（POSIX規則が出す検知理由・検知tokenを含む文言）まで確認する。
/// `windowsOtherRule`は、Windowsの実プロセスhookではshell名`sh`が不明扱いで候補解釈の先頭規則
/// （CMD・PowerShell）が先に拒否するケースの印で、ここでのPOSIX規則単独の検査がその隠れた分を補う。
#[test]
fn hook_posix_json_cases_hold_under_the_posix_rules_alone() {
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("../../tests/hook-posix.json")).expect("hook-posix.json");
    assert!(cases.len() >= 90, "unexpected case count: {}", cases.len());
    let mut names = std::collections::HashSet::new();
    for case in &cases {
        let name = case["name"].as_str().expect("name");
        assert!(names.insert(name.to_owned()), "duplicate case name: {name}");
        let command = case["command"]
            .as_str()
            .expect("command")
            .replace("<FILE>", "/tmp/prunlet-fixture.txt");
        let expect_pass = case["pass"].as_bool().expect("pass");
        let mut inspector = Inspector::default();
        let result = inspector.contains(&command, 0, Some(Mode::Posix), false);
        if expect_pass {
            assert!(
                matches!(result, Ok(false)),
                "{name}: expected pass under POSIX rules: {command:?} -> {result:?}"
            );
        } else {
            // 拒否期待のケースは検知理由`reason`（POSIX規則による固定の文言）を必ず持ち、
            // 検知が別の理由に変わる退行を見逃さない。
            let expected = case["reason"]
                .as_str()
                .unwrap_or_else(|| panic!("{name}: a denied case needs a reason"));
            match result {
                Ok(true) => assert!(
                    inspector
                        .detection
                        .as_deref()
                        .is_some_and(|d| d.contains(expected)),
                    "{name}: expected reason {expected:?}, got {:?}",
                    inspector.detection
                ),
                other => panic!("{name}: POSIX rules alone did not detect: {other:?}"),
            }
        }
    }
}
