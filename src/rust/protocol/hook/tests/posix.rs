use super::*;

/// 引用終端のヒアドキュメントは、ファイルへの`cat`・インタプリタが受け取る形に限って本文をdataとして読み、
/// shellへ渡りうる形や本文の後ろの削除命令は従来どおり拒否する。
#[test]
fn quoted_heredoc_bodies_are_data_only_for_file_sinks_and_interpreters() {
    for allowed in [
        "cat > /d/tmp/x.js <<'EOF'\nfor (const f of files) { rm(f) }\nrm -rf /tmp/y\nEOF\necho done",
        "mkdir -p /d/tmp/x && cat > /d/tmp/x/a.py <<'EOF'\nfor f in x:\n    pass\nEOF",
        "cat <<\"EOF\" > out.txt\nwhile true; do rm -rf /tmp/y; done\nEOF",
        "cat >> notes.md <<-'EOF'\n\tcase x in *) rm -rf /tmp/y;; esac\n\tEOF",
        "cat > f <<\\EOF\nrm -rf /tmp/y\nEOF",
        "cat > f 2>/dev/null <<'EOF'\nrm -rf /tmp/y\nEOF",
        "python - <<'EOF'\nfor i in range(3):\n    print(i)\nEOF",
        "PYTHONUTF8=1 python3 -I - <<'EOF'\nimport os\nEOF",
        "node <<'EOF'\nfor (const x of []) {}\nEOF",
        "cat > f <<'EOF'\r\nrm -rf /tmp/y\r\nEOF\r\necho ok",
        // 終端のない本文はbashでも入力の終わりまでがdata。
        "cat > f <<'EOF'\nrm -rf /tmp/y\n",
        // 終端は行全体の完全一致（字下げした終端語は本文の一部。`<<-`は先頭のタブだけを除く）。
        "cat > f <<'EOF'\n  EOF\nrm -rf /tmp/y\nEOF",
        "cat > f <<-'EOF'\n  EOF\nrm -rf /tmp/y\n\t\tEOF",
        // 実行名に直結した出力先・`>|`の出力先も静的なファイルなら読み飛ばす。
        "cat>f <<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat>f<<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat >| f <<'EOF'\nrm -rf /tmp/y\nEOF",
        // 引用しない終端語の本文でも、展開が無害なら通す。
        "cat > f <<EOF\nIt's $(date) and \"ok\" # note\nEOF",
    ] {
        assert!(!posix_denied(allowed), "{allowed:?}");
    }
    for denied in [
        // 本文の後ろの削除命令。
        "cat > /d/tmp/x <<'EOF'\nx\nEOF\nrm -rf /tmp/y",
        "cat > f <<'EOF'\r\nx\r\nEOF\r\nrm -rf /tmp/y",
        // shellへ渡りうる形（パイプ・同じ行の後続文・グループ・/dev出力・動的な出力先・shell自体）。
        "cat <<'EOF' | sh\nrm -rf /tmp/y\nEOF",
        "cat <<'EOF' |\nrm -rf /tmp/y\nEOF",
        "cat > f <<'EOF' && sh f\nrm -rf /tmp/y\nEOF",
        "(\ncat > /tmp/f <<'EOF'\nrm -rf /tmp/y\nEOF\n) | sh",
        "{ cat > /tmp/f <<'EOF'\nrm -rf /tmp/y\nEOF\n} | sh",
        "cat > /dev/stdout <<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat > /proc/self/fd/1 <<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat <<'EOF'\nrm -rf /tmp/y\nEOF",
        "bash <<'EOF'\nrm -rf /tmp/y\nEOF",
        "sh -s <<'EOF'\nrm -rf /tmp/y\nEOF",
        "ssh mac <<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat > f <<'EOF' x\nrm -rf /tmp/y\nEOF",
        "python -c 'import sys' <<'EOF' | sh\nrm -rf /tmp/y\nEOF",
        "python -m pip <<'EOF'\nrm -rf /tmp/y\nEOF",
        // 展開される本文（終端語が引用されていない）は文として検査する。
        "cat > f <<EOF\n$(rm -rf /tmp/y)\nEOF",
        "cat > f <<EOF\nrm -rf /tmp/y\nEOF",
        // 引用しない終端語の本文では`'`・`"`は引用ではなく、`#`もコメントではない（`$(…)`・逆引用は展開される）。
        "cat <<EOF\nDon't $(unlink /tmp/y)\nEOF",
        "cat > f <<EOF\nDon't `unlink /tmp/y`\nEOF",
        "cat <<EOF\nsay \"$(unlink /tmp/y)\nEOF",
        "cat <<EOF\n# $(unlink /tmp/y)\nEOF",
        // `$(…)`の中では引用が有効（`'r''m'`は`rm`）。
        "cat <<EOF\nDon't $('r''m' -rf /tmp/y)\nEOF",
        // shellへ渡る本文は内側のshellが引用を解釈するため、従来の読みでも検査を続ける。
        "bash <<EOF\n'r''m' -rf /tmp/y\nEOF",
        // 1行に引用あり・なしのヒアドキュメントが並ぶ形。
        "cat <<'A' <<B\nx\nA\nDon't $(unlink /tmp/y)\nB",
        // `<<`を算術・`[[`・逆引用・コマンド置換の中で書いた形は読み飛ばさない。
        "echo $((1<<'X'))\nrm -rf /tmp/y\nX",
        "[[ a << 'X' ]]\nrm -rf /tmp/y\nX",
        "x=$(cat > f <<'EOF'\nrm -rf /tmp/y\nEOF\n)",
        "echo `cat > f <<'EOF'`\nrm -rf /tmp/y\nEOF",
        // here-string（`<<<`）はヒアドキュメントではない。
        "cat > f <<<'EOF'\nrm -rf /tmp/y\nEOF",
        // 読み飛ばさない本文の引用状態（孤立した`'`）を終端の後ろへ持ち越さない。
        "cat <<'EOF'\nDon't\nEOF\nunlink /tmp/y\ncat <<'EOF'\nIt's\nEOF",
        "bash <<'EOF'\necho \"\nEOF\nunlink /tmp/y\necho \"",
        // 終端はbashと同じ完全一致。字下げした行で早く終わらず、引用内の空白・退避・`$'…'`の終端語も一致させる。
        "cat > /tmp/f <<'EOF'\n  EOF\nit's\nEOF\nunlink /tmp/y\necho '",
        "cat > /tmp/f <<'EOF '\nnote\nEOF \nunlink /tmp/y",
        "cat > /tmp/f <<\"E\\\"F\"\nx\nE\"F\nunlink /tmp/y",
        "cat > /tmp/f <<$'EOF'\nx\nEOF\nunlink /tmp/y",
        "cat > /tmp/f <<\"E$F\"\nx\nE$F\nunlink /tmp/y",
        // 単純でない終端語の本文は読み飛ばさない。
        "cat > /tmp/f <<'EOF '\nunlink /tmp/y\nEOF ",
        "cat > /tmp/f <<$'EOF'\nunlink /tmp/y\nEOF",
        "cat > /tmp/f <<$'E\\x4fF'\nunlink /tmp/y\nEOF",
        // 前の行で開いた逆引用の中のヒアドキュメントは読み飛ばさない。
        "echo `\ncat > f <<'EOF'\nrm -rf /tmp/y\nEOF\n`",
        "x=`echo a\ncat > f <<'EOF'\nrm -rf /tmp/y\nEOF\n`",
    ] {
        assert!(posix_denied(denied), "{denied:?}");
    }
}
/// `tee`は、静的なパスだけを取り、標準出力（fdが空か`1`）がファイルか`/dev/null`へ向く場合に限り、
/// 本文をdataとして読む。出力先が変数・コマンド置換などの動的な語の`cat >`・`tee`は読み飛ばさない。
#[test]
fn heredoc_data_sinks_accept_static_cat_and_tee_only() {
    for head in [
        "cat > /tmp/x.js <<'EOF'",
        "cat >> /d/x/y.ts <<'EOF'",
        // `tee`は標準出力がファイルか`/dev/null`のときだけ。
        "tee /d/x >/dev/null <<'EOF'",
        "tee -a f > /dev/null <<'EOF'",
        "tee -a /tmp/x /tmp/y >/tmp/out <<'EOF'",
        "tee --append -- /tmp/x 1>/dev/null <<'EOF'",
        "tee -- -a >/dev/null <<'EOF'",
        // 字句上の正規形が`/dev/null`の出力先。
        "tee /tmp/x >//dev/null <<'EOF'",
        "tee /tmp/x >/./dev/null <<'EOF'",
        "cat >| /tmp/x <<'EOF'",
    ] {
        let command = format!("{head}\n{JS_BODY}\nEOF\necho done");
        assert!(!posix_denied(&command), "{command:?}");
    }
    for head in [
        // 出力先が動的（変数・コマンド置換・逆引用符・算術展開・プロセス置換・グロブ）。
        "cat > \"$out\" <<'EOF'",
        "cat > \"$TEMP/x/y.ts\" <<'EOF'",
        "cat > $TEMP/x/y.ts <<'EOF'",
        "cat > ${TEMP}/x/y.ts <<'EOF'",
        "cat >> \"${TEMP}/x_$NAME.ts\" <<'EOF'",
        "cat > \"$(echo x)\" <<'EOF'",
        "cat > $(echo x) <<'EOF'",
        "cat > `echo x` <<'EOF'",
        "cat > \"`echo x`\" <<'EOF'",
        "cat > \"$((1+1))\" <<'EOF'",
        "cat > \"${x:-/tmp/y}\" <<'EOF'",
        "cat > \"$1\" <<'EOF'",
        "cat > \"$@\" <<'EOF'",
        "cat > /tmp/*.x <<'EOF'",
        "cat > >(sh) <<'EOF'",
        "cat > /dev/$x <<'EOF'",
        "cat > /dev/stdout <<'EOF'",
        "cat > $'\\x2fdev/x' <<'EOF'",
        "cat > $_ <<'EOF'",
        "tee \"$TEMP/x\" >/dev/null <<'EOF'",
        "tee -- ${OUT} >/dev/null <<'EOF'",
        "tee /tmp/x >\"$TEMP/out\" <<'EOF'",
        "tee >(sh) <<'EOF'",
        "tee \"$(echo x)\" <<'EOF'",
        "tee `echo x` <<'EOF'",
        "tee \"$_\" >/dev/null <<'EOF'",
        // `tee`の標準出力が`/dev/null`・ファイルに向かない、静的でないoption・書き出し先。
        "tee /dev/stdout <<'EOF'",
        "tee /proc/self/fd/1 <<'EOF'",
        "tee /tmp/x >/dev/stdout <<'EOF'",
        "tee /tmp/x >&2 <<'EOF'",
        "tee /tmp/x 2>/dev/null <<'EOF'",
        "tee /tmp/x <<'EOF'",
        "tee -a /tmp/x <<'EOF'",
        "tee \"-a\" x >/dev/null <<'EOF'",
        "tee -z x >/dev/null <<'EOF'",
        "tee x /dev/null >/dev/null <<'EOF'",
        "tee <<'EOF'",
        "tee -z x <<'EOF'",
        "tee x | sh <<'EOF'",
        "tee x && sh x <<'EOF'",
        "tee x y z; sh <<'EOF'",
        "tee x | cat | sh <<'EOF'",
        // 標準出力ではないfdの出力先は、`tee`・`cat`の標準出力を決めない。
        "tee /tmp/x 3>/dev/null <<'EOF'",
        "tee /tmp/x 3>/tmp/z <<'EOF'",
        "cat 3>/tmp/z <<'EOF'",
        "cat > /tmp/z 4>/tmp/w <<'EOF'",
        // `/dev/`・`/proc/`の判定は字句上の正規形で行い、`..`区間を含む出力先は読み飛ばさない。
        "cat > //dev/stdout <<'EOF'",
        "cat > /./dev/stdout <<'EOF'",
        "cat > /tmp/../dev/stdout <<'EOF'",
        "cat > ///proc/self/fd/1 <<'EOF'",
        "cat > ../x <<'EOF'",
        "tee //dev/stdout >/dev/null <<'EOF'",
        "tee /./dev/stdout >/dev/null <<'EOF'",
        "tee /tmp/../dev/stdout >/dev/null <<'EOF'",
        "tee /tmp/x >//dev/stdout <<'EOF'",
        "tee /tmp/x >/dev/../dev/null <<'EOF'",
        // `>|`の`|`を書き出し先の一部と誤認しない。
        "cat >|/dev/stdout <<'EOF'",
        "cat >| /dev/stdout <<'EOF'",
        "tee /tmp/x >|/dev/stdout <<'EOF'",
        // 実行名に直結したリダイレクトの先がインタプリタ名でも、実行名はshell。
        "sh>python <<'EOF'",
        "bash>/tmp/node <<'EOF'",
    ] {
        let command = format!("{head}\nrm -rf /tmp/y\nEOF");
        assert!(posix_denied(&command), "{command:?}");
    }
    // 本文の外の削除、引用なしの終端語、shellが読む形、動的な出力先（制御構文・`{`・`$(…)`・`bash -c`の中でも）は拒否する。
    for command in [
        "tee /d/x >/dev/null <<'EOF'\nx\nEOF\nrm -rf /tmp/y",
        "tee /d/x >/dev/null <<EOF\nrm -rf /tmp/y\nEOF",
        "tee /d/x >/dev/null <<'EOF' | sh\nrm -rf /tmp/y\nEOF",
        "tee /d/x >/dev/null <<'EOF'; sh x\nrm -rf /tmp/y\nEOF",
        "cat > \"$TEMP/x\" <<'EOF'\nx\nEOF\nrm -rf /tmp/y",
        "cat > \"$TEMP/x\" <<EOF\nrm -rf /tmp/y\nEOF",
        "bash <<'EOF'\nrm -rf /tmp/y\nEOF",
        "sh -s <<'EOF'\nrm -rf /tmp/y\nEOF",
        "ssh host <<'EOF'\nrm -rf /tmp/y\nEOF",
        "$X <<'EOF'\nrm -rf /tmp/y\nEOF",
        "${X} <<'EOF'\nrm -rf /tmp/y\nEOF",
        // `${NAME}`は従来どおり`{`・`}`で割って検査する。
        "${X}rm -rf /tmp/y",
        "${X} rm -rf /tmp/y",
        "A=1 ${X}rm -rf /tmp/y",
        "x${X}rm -rf /tmp/y",
        "if true; then ${X}rm -rf /tmp/y; fi",
        ">\"f\" ${X}unlink /tmp/y",
        ">\"f\" ${X} unlink /tmp/y",
        // 出力先が動的な語（変数）の`cat`・`tee`は、周りに制御構文・`{`・`(`・入れ子があるかを問わず読み飛ばさない。
        "cat >& 2 <<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat >& 1 <<'EOF'\nrm -rf /tmp/y\nEOF",
        "while true\ndo\ntee /tmp/x <<'EOF'\nrm -rf /tmp/y\nEOF\nbreak\ndone | sh",
        "if true\nthen\ntee /tmp/x <<'EOF'\nrm -rf /tmp/y\nEOF\nfi | bash",
        "X=/dev/stdout\nwhile true\ndo\ncat > \"$X\" <<'EOF'\nrm -rf /tmp/y\nEOF\nbreak\ndone | sh",
        "X=/dev/stdout\necho {done}\nwhile true\ndo\ncat > \"$X\" <<'EOF'\nunlink /tmp/y\nEOF\nbreak\ndone | sh",
        "X=/dev/stdout\nwhile true\ndo\necho {done}\ncat > \"$X\" <<'EOF'\nunlink /tmp/y\nEOF\nbreak\ndone | sh",
        "X=/dev/stdout\ncat <<Z\ndone\nZ\nwhile true\ndo\ncat > \"$X\" <<'EOF'\nunlink /tmp/y\nEOF\nbreak\ndone | sh",
        "X=/dev/stdout\necho (x)\ncat > \"$X\" <<'EOF'\nunlink /tmp/y\nEOF",
        "X=/dev/stdout\nfor i in 1; do echo; done\ntee \"$X\" >/dev/null <<'EOF'\nunlink /tmp/y\nEOF",
        "X=/dev/stdout\necho \"$(\ncat > $X <<'EOF'\nunlink /tmp/y\nEOF\n)\" | sh",
        "X=/dev/stdout bash -c 'cat > $X <<\\EOF\nunlink /tmp/y\nEOF' | sh",
        "X=/dev/stdout bash -c \"cat > \\$X <<'EOF'\nunlink /tmp/y\nEOF\" | sh",
        // 標準出力へ戻る出力先の別表記（`//dev/stdout`）と、`echo }`で括弧の深さが負になる形。
        "while true\ndo\ntee //dev/stdout >/dev/null <<'EOF'\nunlink /tmp/y\nEOF\nbreak\ndone | sh",
        "echo }\n{ python - <<'EOF'\nunlink /tmp/y\nEOF\n} | sh",
    ] {
        assert!(posix_denied(command), "{command:?}");
    }
    // 静的な出力先は、制御構文の内側・閉じた後でも従来どおり読み飛ばす（標準出力が他へ流れない）。
    for command in [
        "x=\"$(python - <<'EOF'\nfor i in range(3):\n    print(i)\nEOF\n)\"",
        "x=\"$(cat > /tmp/f <<'EOF'\nfor (const f of files) {\n}\nEOF\n)\"",
        "for i in 1; do echo; done\ncat > f <<'EOF'\nrm -rf /tmp/y\nEOF",
        "if true; then echo; fi\ntee f >/dev/null <<'EOF'\nrm -rf /tmp/y\nEOF",
        "echo {x}\ncat > /tmp/f <<'EOF'\nrm -rf /tmp/y\nEOF",
        "while true\ndo\ntee /tmp/x >/dev/null <<'EOF'\nrm -rf /tmp/y\nEOF\nbreak\ndone | sh",
    ] {
        assert!(!posix_denied(command), "{command:?}");
    }
}
/// shell不明（Claude Codeの`Bash`・Codexの`exec_command`）のWindows検査は、POSIX規則がdataと読む
/// ヒアドキュメント本文も、CMD・PowerShell規則で全文を検査し続ける。PowerShellは`python --% <<'EOF'`や
/// 引用の読み分けで`<<`を構文エラーにしないため、本文の削除が実行されうる。
/// `Bash`をPOSIXと決めない理由はDESIGN.mdの「フックのshell解析境界」を参照する。
#[test]
fn unknown_shell_inspection_still_checks_heredoc_bodies_under_other_rules() {
    if !cfg!(windows) {
        return;
    }
    for command in [
        "python --% <<'EOF'\nRemove-Item y\nEOF",
        "echo \\' \" \\' \"\ntee x <<'EOF'\n\" ; Remove-Item y\nEOF",
        "echo \u{201c}\ntee x <<'EOF'\n\u{201d} ; Remove-Item y\nEOF",
        // POSIX規則だけならdataの形でも、CMD・PowerShell規則が本文の削除を検知する。
        "cat > /tmp/x <<'EOF'\ndel x\nEOF",
        "cat > /tmp/x <<'EOF'\nRemove-Item x\nEOF",
        "tee /tmp/x >/dev/null <<'EOF'\ndel x\nEOF",
        "cat > \"$TEMP/x\" <<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat > \"$TEMP/x\" <<'EOF'\ndel x\nEOF",
        "cat > \"$TEMP/x\" <<'EOF'\nRemove-Item x\nEOF",
        "cat > \"$TEMP/x\" <<'EOF'\nx\nEOF\nrm -rf /tmp/y",
        "cat > \"$TEMP/x\" <<'EOF'\nx\nEOF\ndel x",
        "cat > \"$TEMP/x\" <<'EOF'\nx\nEOF\nRemove-Item x",
        "cat > \"$(echo x)\" <<'EOF'\nrm -rf /tmp/y\nEOF",
        "cat > `echo x` <<'EOF'\ndel x\nEOF",
        "tee >(sh) <<'EOF'\ndel x\nEOF",
        "tee x | sh <<'EOF'\ndel x\nEOF",
        "cat > x <<EOF\ndel x\nEOF",
        "bash <<'EOF'\nrm -rf /tmp/y\nEOF",
        "sh -s <<'EOF'\nrm -rf /tmp/y\nEOF",
        "ssh host <<'EOF'\nrm -rf /tmp/y\nEOF",
        "rm -rf x",
        "del x",
        // 内側のshellの呼び出し（POSIX規則でも対応する規則で再帰検査する）。
        "cmd //c del x",
        "cmd /c del x",
        "cmd.exe /c rd /s /q x",
        "powershell -c Remove-Item x",
        "pwsh -c Remove-Item x",
        "pwsh -Command \"Remove-Item x\"",
    ] {
        assert!(reason(command, "Bash", None).is_some(), "{command:?}");
    }
    let encoded = encoded_command("Remove-Item x");
    assert!(reason(&encoded, "Bash", None).is_some());
    // POSIX規則だけでも、cmd・powershell・pwshの呼び出しは本文を対応する規則で検査して拒否する。
    for command in [
        "cmd //c del x",
        "cmd /c del x",
        "cmd.exe /c rd /s /q x",
        "powershell -c Remove-Item x",
        "pwsh -c Remove-Item x",
        "pwsh -Command \"Remove-Item x\"",
        "pwsh -NoProfile -EncodedCommand AAAA",
        encoded.as_str(),
    ] {
        assert!(posix_denied(command), "{command:?}");
    }
}
/// 先頭のリダイレクトは実行名ではない。対象語を飛ばした次の語を実行名として検査し、削除名を隠せない。
#[test]
fn leading_redirections_do_not_hide_the_command_name() {
    for denied in [
        "2>/dev/null rm -rf /tmp/y",
        ">/tmp/z rm -rf /tmp/y",
        "</dev/null rm x",
        "2>&1 rm x",
        "> /tmp/z rm -rf /tmp/y",
        ">/tmp/a 2>&1 </dev/null rm x",
        ">\"f\" rm x",
        "FOO=1 2>/dev/null rm x",
        // fdを閉じる`&-`は対象語を取らないので、次の語が実行名。
        "2>&- rm -rf /tmp/y",
        ">&- rm -rf /tmp/y",
        "<&- unlink /tmp/y",
        // `<<-`は終端語を取る。
        "<<- EOF rm x\nEOF",
        // `&`と数字・`-`の間に空白がある形、`&-`に名前が直結する形（bash・cmdとも後ろのコマンドを実行する）。
        "2>& 1 unlink /tmp/y",
        ">& 1 rm -rf /tmp/y",
        ">& - rm -rf /tmp/y",
        "2>&-unlink /tmp/y",
        ">&-rm -rf /tmp/y",
        "<&-unlink /tmp/y",
        "2>&\t1 rm x",
        // `>& del x`は名前が続くので、`&`で文を割って`del x`を検査する。
        ">& rm -rf /tmp/y",
        "echo a >& rm x",
        // 名前をリダイレクト対象として読む解釈（bashの`>&word`）でも、後ろの実行名を検査する。
        ">& /tmp/z unlink /tmp/y",
        "2>& /tmp/z unlink /tmp/y",
        ">&/tmp/z unlink /tmp/y",
        ">& /tmp/z >& /tmp/w unlink /tmp/y",
        // `>|`は1つの演算子で、`|`はパイプではない。
        ">| /tmp/z unlink /tmp/y",
        ">|/tmp/z unlink /tmp/y",
        "2>| /tmp/z unlink /tmp/y",
        // 実行名に直結したリダイレクト（`<`・`>`は語を切る）。
        "rm>/dev/null -rf /tmp/y",
        "unlink>/dev/null /tmp/y",
        "unlink</dev/null /tmp/y",
        "unlink 2>/dev/null>/tmp/z /tmp/y",
        // shell wrapper・prefixの名前に直結した形と、wrapperのoptionの間のリダイレクト。
        "bash>/dev/null -c 'unlink /tmp/y'",
        "bash >/dev/null -c 'unlink /tmp/y'",
        "sh 2>&1 -c 'unlink /tmp/y'",
        "bash -c 2>/dev/null 'unlink /tmp/y'",
        "env>/tmp/z unlink /tmp/y",
        "sh>python <<'EOF'\nunlink /tmp/y\nEOF",
        // prefix・代入の後ろのリダイレクトを飛ばした先の実行名も検査する。
        "exec 3>&- unlink /tmp/y",
        "exec >log rm -rf /tmp/y",
        "FOO=1 >out unlink /tmp/y",
        // リダイレクトを前置しても動的な実行名の拒否は外れない。
        "exec >log $cmd /tmp/y",
        "FOO=1 >out $cmd /tmp/y",
        "for f in a; do >out $cmd $f; done",
    ] {
        assert!(posix_denied(denied), "{denied:?}");
        if cfg!(windows) {
            assert!(reason(denied, "Bash", None).is_some(), "{denied:?}");
        }
    }
    // 実行名が`cmd`の呼び出しはwrapperとして扱われ、未知のswitch（`2>/dev/null`）は元から拒否される（今回の変更ではない）。
    assert!(posix_denied("cmd 2>/dev/null"));
    for allowed in [
        "ls 2>/dev/null",
        "ls 2>&1",
        "echo hi >&2",
        "echo hi >& 2",
        "ls 2>& 1 | head",
        "<<- EOF cat\nEOF",
        ">out echo hi",
        "2>/dev/null ls /tmp",
        "</dev/null cat",
        "2>&1 echo ok",
        "> /tmp/z",
        ">",
        // 実行名に直結したリダイレクト・`>|`・`>& 名前`の正常形。
        "echo hi>out",
        "echo hi >| /tmp/out",
        "echo hi>|/tmp/out",
        "ls >& /tmp/log",
        "ls>&/tmp/log",
        "bash 2>/dev/null -c 'echo hi'",
        "sort<in.txt>out.txt",
        // prefix・代入の後ろがリダイレクトだけの形はコマンドを実行しない。
        "exec 3>&-",
        "exec >log 2>&1",
        "exec 2>/dev/null",
        "FOO=1 >out",
        "for f in a; do echo $f; done; 2>/dev/null ls",
    ] {
        assert!(!posix_denied(allowed), "{allowed:?}");
        if cfg!(windows) {
            assert_eq!(reason(allowed, "Bash", None), None, "{allowed:?}");
        }
    }
    if cfg!(windows) {
        for denied in [
            "2>nul del x",
            ">out del x",
            "<nul del x",
            "2>&1 del x",
            "2>& 1 del x",
            ">& 1 del x",
            // CMD規則でも、実行名に直結した`<`・`>`は語を切る。
            "del>nul x",
            "del<nul x",
            "rd>nul /s /q x",
            "cmd>nul /c echo ok",
        ] {
            assert!(
                reason(denied, "exec_command", Some("cmd.exe")).is_some(),
                "{denied:?}"
            );
            assert!(reason(denied, "Bash", None).is_some(), "{denied:?}");
        }
        assert!(reason("2>$null Remove-Item x", "exec_command", Some("pwsh")).is_some());
        assert!(reason(">out Remove-Item x", "exec_command", Some("pwsh")).is_some());
        assert_eq!(
            reason("2>nul echo hi", "exec_command", Some("cmd.exe")),
            None
        );
        assert_eq!(reason("echo hi>nul", "exec_command", Some("cmd.exe")), None);
        // PowerShellは`<`・`>`で一般の語を切らない（`Remove-Item>out.txt`は存在しないコマンド名）。
        assert_eq!(
            reason("Remove-Item>out.txt x", "exec_command", Some("pwsh")),
            None
        );
        // PowerShellのブロックコメント開始`<#`はリダイレクトではなく、本文は実行されない。
        assert_eq!(
            reason("<# del old #>\nGet-Date", "exec_command", Some("pwsh")),
            None
        );
    }
}
/// 制御構文の中の代入・`[`・終端語のリダイレクトは実行名ではないため検査不能にしない。削除命令は拒否する。
#[test]
fn posix_control_flow_assignments_tests_and_redirections_are_inspected() {
    for allowed in [
        "for f in a b; do n=$(basename $f); echo $n; done",
        "for f in *.rs; do if [ -f \"$f\" ]; then echo $f; fi; done 2>&1 | head",
        "while read f; do echo $f; done < list.txt",
        "for f in *; do\n  b=$(basename $f)\n  [ -f \"$f\" ] && echo $b\ndone",
        "if [[ -n \"$x\" ]]; then echo ok; fi >/dev/null",
        "until [ -s out ]; do sleep 1; done",
    ] {
        assert!(!posix_denied(allowed), "{allowed:?}");
    }
    for denied in [
        "for f in a; do rm -rf $f; done",
        "for f in a; do x=1 rm -rf $f; done",
        "for f in a; do n=$(rm -rf $f); done",
        "for f in a; do n=1 $cmd $f; done",
        "[ -f x ] && rm -rf y",
        "if [ -f x ]; then rm -rf y; fi",
        "for f in a; do echo; done rm -rf y",
        "for f in a; do echo; done > out; rm -rf y",
    ] {
        assert!(posix_denied(denied), "{denied:?}");
    }
}
/// コメント・ANSI-C引用・二重引用内の`$(…)`で字句解析の引用状態がshellとずれず、後続の削除を隠さない。
#[test]
fn posix_lexer_tracks_comments_ansi_c_quotes_and_quoted_substitutions() {
    for denied in [
        // `${#x}`・`""#`の`#`は語の一部でコメントではない。
        "if [ ${#x} -gt 0 ]; then unlink /tmp/y; fi",
        "echo ${#x}; unlink /tmp/y",
        "echo \"\"#; unlink /tmp/y",
        "echo ''#; unlink /tmp/y",
        "echo \\#; unlink /tmp/y",
        // ANSI-C引用の`\'`は引用を閉じない。
        "echo $'\\''\nunlink /tmp/y\necho \"'\"",
        "x=$'a\\'b'; unlink /tmp/y",
        // 二重引用内の`$(…)`は独立した引用文脈を持つ。
        "echo \"$(echo '\"')\"; unlink /tmp/y",
        "echo \"$(printf '%s' \"(\")\"; unlink /tmp/y",
        "echo \"$(echo \"$(echo '\"')\")\"; unlink /tmp/y",
        // `$(…)`の本文の削除は従来どおり検査する。
        "echo \"$(unlink /tmp/y)\"",
        // 実行名の位置のブレース展開は、bashが展開してから実行名を決めるため検査不能として拒否する。
        "r{m,} -rf /tmp/y",
        "{unlink,/tmp/y}",
        "un{link,} /tmp/y",
        "A=1 {rm,-rf,/tmp/y}",
        "env {rm,-rf,/tmp/y}",
        "if true; then {unlink,/tmp/y}; fi",
        "echo ok; r{l..m} -rf /tmp/y",
        "{\"rm\",-rf,/tmp/y}",
    ] {
        assert!(posix_denied(denied), "{denied:?}");
        if cfg!(windows) {
            assert!(reason(denied, "Bash", None).is_some(), "{denied:?}");
        }
    }
    for allowed in [
        "echo hi # unlink /tmp/y",
        "# unlink /tmp/y\necho ok",
        "echo ok;# unlink /tmp/y",
        "printf $'a\\n'",
        "printf $'it\\'s\\n'",
        "cd \"$(dirname \"$0\")\"",
        "x=\"$(printf '%s' ')')\"; echo \"$x\"",
        "echo \"$((1 + 2))\"",
        // 引数の位置のブレース展開・空白を伴うグループ・`{}`は従来どおり通す。
        "echo {a,b}",
        "mkdir -p x/{a,b}",
        "cp a.txt{,.bak}",
        "find . -name '*.rs' -exec ls {} \\;",
        "{ echo a; echo b; }",
        "echo {done}",
        "a={x,y}; echo $a",
    ] {
        assert!(!posix_denied(allowed), "{allowed:?}");
        if cfg!(windows) {
            assert_eq!(reason(allowed, "Bash", None), None, "{allowed:?}");
        }
    }
    // 閉じていない`"$(`が大量に並ぶ本文でも、区切りまでを1回で取り込み線形時間で終わる。
    let many = format!("bash <<'EOF'\n\"{}\nEOF\necho ok", "$( ".repeat(200_000));
    let _ = posix_denied(&many);
    let many = format!("echo \"{}", "$( \"".repeat(200_000));
    let _ = posix_denied(&many);
}
/// 新しい読みが従来の解釈を置き換えた箇所（コメント・ANSI-C引用・二重引用内の`$(…)`・ヒアドキュメント本文）で、
/// 従来の読みなら検知できた削除を見逃さない。新しい読み単独でも、終わりを確定できない形は拒否し、
/// 行継続・`$$`・算術の`<<`・`${…}`の読みをbashに合わせる。
#[test]
fn new_and_legacy_readings_both_inspect_the_command() {
    let unterminated = "echo \"$(echo ')'\"";
    for denied in [
        // A-1: 二重引用内の`$(…)`の中の逆引用・ANSI-C引用。
        "echo \"$(basename `pwd`)\"; unlink /tmp/y",
        "echo \"$(echo $'\\'')\"; unlink /tmp/y",
        "echo \"$(echo `echo ')'`)\"; unlink /tmp/y",
        // A-2: 行継続の後の`#`はコメント、`>|`・`>&`・fd番号付きのリダイレクトは行継続の無い形と同じ。
        "echo a \\\n# it's\nunlink /tmp/y\necho 'ok'",
        "\\\n>| /tmp/z unlink /tmp/y",
        "\\\n>& /tmp/z unlink /tmp/y",
        "\\\n2>/dev/null unlink /tmp/y",
        "2\\\n>/dev/null unlink /tmp/y",
        // A-3: `$$`の後の`'`は通常の単一引用。
        "echo $$'\\'\nunlink /tmp/y\necho 'ok'",
        // A-4: 算術・同じ行の逆引用の中の`<<`はヒアドキュメントとして状態を初期化しない。
        "echo $((1<<2))\necho '\n2\n'; unlink /tmp/y; echo '\n'",
        "((a<<2))\necho '\n2\n'; unlink /tmp/y; echo '\n'",
        "echo $[1<<2]\necho '\n2\n'; unlink /tmp/y; echo '\n'",
        "echo `echo <<2`\necho '\n2\n'; unlink /tmp/y; echo '\n'",
        // B-1: 逆引用・`${…}`の中の`#`。
        "echo `echo a # c`; unlink /tmp/y",
        "echo ${x:- #}; unlink /tmp/y",
        // B-2: 終端語を確定できないヒアドキュメントと、`\r`を含む行の完全一致。
        "cat <<$'E\\x4fF'\nit's\nEOF\nunlink /tmp/y\necho 'ok'",
        "cat <<'EOF'\nEOF\r\nit's\nEOF\nunlink /tmp/y\necho 'ok'",
        // 閉じない`"$(`。
        unterminated,
        // `${…}`を1語として読んでも、空に展開されうる実行名の後ろを検査する。
        "echo ${#x}; ${X} rm -rf /tmp/y",
        "${X}rm -rf /tmp/y",
        ">\"f\" ${X} unlink /tmp/y",
        "echo ${x:-$(unlink /tmp/y)}",
        "echo ${x:-`unlink /tmp/y`}",
        // 前の行で開いた逆引用の中のヒアドキュメントは記録し、本文を区切って終端の後ろを検査する。
        "echo `\ncat > /tmp/f <<'EOF'\nit's\nEOF\nunlink /tmp/y",
    ] {
        assert!(posix_denied(denied), "{denied:?}");
        assert!(
            posix_reading_denied(denied, false),
            "new reading: {denied:?}"
        );
        if cfg!(windows) {
            assert!(reason(denied, "Bash", None).is_some(), "{denied:?}");
        }
    }
    let mut inspector = Inspector::default();
    assert!(
        inspector
            .contains(unterminated, 0, Some(Mode::Posix), false)
            .unwrap()
    );
    assert!(
        inspector
            .detection
            .unwrap()
            .contains("unterminated POSIX command substitution cannot be inspected")
    );
    // 従来の読みの検知は、新しい読みが置き換えた解釈の誤りがあっても残る（新しい読み単独の結果に依らない）。
    for denied in [
        "echo a \\\n# it's\nunlink /tmp/y\necho 'ok'",
        "echo $((1<<2))\necho '\n2\n'; unlink /tmp/y; echo '\n'",
        "echo \"$(basename `pwd`)\"; unlink /tmp/y",
        "${X} rm -rf /tmp/y",
        // 従来の読みは従来の判定でデータの本文を読み飛ばす（前の行で開いた逆引用を数えない）。
        "echo `\ncat > /tmp/f <<'EOF'\nit's\nEOF\nunlink /tmp/y",
    ] {
        assert!(
            posix_reading_denied(denied, true),
            "legacy reading: {denied:?}"
        );
    }
    for allowed in [
        // A-6: `${#arr[@]}`の`#`・`[`はパラメーター展開の一部。
        "if [ ${#arr[@]} -eq 0 ]; then echo none; fi",
        "n=${#arr[@]}; echo \"$n\"",
        "echo \"${#arr[@]}\" ${x:-a b}",
        "echo \"$(basename `pwd`)\"",
        "echo $$ $((1<<2))",
        // `$(…)`の中のヒアドキュメントは従来どおり記録する（本文の`'`を後ろへ持ち越さない）。
        "git commit -m \"$(cat <<'EOF'\nIt's fine\nEOF\n)\"",
        "x=$(cat <<'EOF'\nIt's fine\nEOF\n)\necho \"$x\"",
        "cat > f <<'EOF'\r\nx\r\nEOF\r\necho ok",
    ] {
        assert!(!posix_denied(allowed), "{allowed:?}");
        if cfg!(windows) {
            assert_eq!(reason(allowed, "Bash", None), None, "{allowed:?}");
        }
    }
    // C-1: wrapperの本文の後ろのリダイレクトを本文と連結しない。B-4: 前置コマンド・shellのoption値の位置のリダイレクト。
    for denied in [
        "pwsh -Command \"Remove-Item y\" > out.txt",
        "pwsh -Command \"Remove-Item y\" 2>&1",
        "powershell -NoProfile \"Remove-Item y\" 2>&1",
        "env -u >/dev/null FOO unlink /tmp/y",
        "bash -o >/dev/null posix -c 'unlink /tmp/y'",
        // P-5: 添字に空白を含む配列代入は検査不能。
        "a[1 + 1]=5 unlink /tmp/y",
    ] {
        assert!(posix_denied(denied), "{denied:?}");
        if cfg!(windows) {
            assert!(reason(denied, "Bash", None).is_some(), "{denied:?}");
        }
    }
    // 非strictのPowerShell規則: `,`の後のヒアストリング、代入直後のブロックコメント、スマート引用符のヒアストリング。
    // 従来の読み（ASCII引用符・行コメントだけ）で検知できた形も拒否のまま。
    for command in [
        "Write-Output 1,@'\nit's\n'@; Remove-Item y; Write-Output 'ok'",
        "$x=<# c #> Remove-Item y",
        "$a = @\u{2018}\nit's\n\u{2019}@; Remove-Item y; Write-Output 'ok'",
        "Write-Output \u{2018}; Remove-Item y; Write-Output '",
        "Write-Output \u{201c}; Remove-Item y; Write-Output \"",
        "<# note\nRemove-Item y\n#>\nWrite-Output ok",
    ] {
        assert!(denied(command, "pwsh"), "{command:?}");
    }
    for allowed in [
        "Write-Output 1,@'\nit's\n'@",
        "$a = @\u{2018}\nit's\n\u{2019}@",
        "$x=<# c #> Get-Date",
    ] {
        assert!(!denied(allowed, "pwsh"), "{allowed:?}");
    }
    // `${`・`"$(`・`$(`の閉じない形が大量に並んでも線形時間で終わる。
    let many = format!("echo {}", "${ ".repeat(200_000));
    let _ = posix_denied(&many);
    let many = format!("echo \"$(echo {}\"", "${x:-`".repeat(100_000));
    let _ = posix_denied(&many);
}
/// 字句解析の見直しで生じた回帰（main 4ec0b8fでは拒否した削除の見逃し・異常終了・時間超過）と誤拒否を直した形。
#[test]
fn lexer_rework_regressions_and_false_rejections_are_fixed() {
    // R-1: 実行名の位置に引用なしの`${…}`語が大量に並んでも再帰せず、後ろの文を検査する。
    let many = format!("{}; unlink /tmp/y", "${a} ".repeat(100_000));
    assert!(posix_denied(&many));
    let many = format!("{}unlink /tmp/y", "${a} >x ".repeat(50_000));
    assert!(posix_denied(&many));
    let many = format!("{}rm -rf /tmp/y", "${a}".repeat(100_000));
    assert!(posix_denied(&many));
    for denied in [
        // R-2: `>-`・`<-`は`-`という名前のファイルへのリダイレクトで、次の語を対象に取らない。
        "env >- unlink /tmp/y",
        "FOO=1 >- unlink /tmp/y",
        "if true; then >- unlink /tmp/y; fi",
        ">- unlink /tmp/y",
        "env <- unlink /tmp/y",
        "bash >- -c 'unlink /tmp/y'",
        // R-3: 退避・引用した`>`で始まる語はoptionの値で、リダイレクトではない。
        "env -u \\> unlink /tmp/y",
        "env -u \\>x unlink /tmp/y",
        "env -u 2\">\"x unlink /tmp/y",
        "env -u '>' unlink /tmp/y",
        "sudo -p \\> unlink /tmp/y",
        "exec -a \\> unlink /tmp/y",
        "bash -o \\> -c 'unlink /tmp/y'",
        // F-2: ヒアドキュメント本文の中でも、`{`・`}`の後ろに続く削除は従来どおり検査する。
        "cat <<EOF\n{\"a\":1,\"b\":2} unlink /tmp/y\nEOF",
        "bash <<'EOF'\n{\"a\":1,\"b\":2} unlink /tmp/y\nEOF",
        // F-2: 本文の外の実行名の位置のブレース展開は従来どおり検査不能。
        "cat <<'EOF'\nx\nEOF\n{unlink,/tmp/y}",
        // F-3: 置換の中のコメントは行末まで。コメントの後ろの行の削除は検査する。
        "x=\"$(\n# don't )\nunlink /tmp/y\n)\"",
        "x=$(\n# it's\nunlink /tmp/y\n)",
        "x=\"$(echo ${x:- #})\"; unlink /tmp/y",
    ] {
        assert!(posix_denied(denied), "{denied:?}");
        if cfg!(windows) {
            assert!(reason(denied, "Bash", None).is_some(), "{denied:?}");
        }
    }
    // R-3: CMD・PowerShellの行継続の直後の演算子はリダイレクト（退避された文字ではない）。
    assert!(denied("call ^\n>nul del x", "cmd.exe"));
    assert!(denied(
        "pwsh -Command \"Remove-Item y\" `\n> out.txt",
        "pwsh"
    ));
    // 処理時間の上限。修正前の二乗の走査はリリースビルドでも数十秒（デバッグビルドではその数倍）かかり、
    // 線形の走査はデバッグビルドでも数秒で終わる。遅いCIでも誤って失敗しないよう十分な余裕を取る。
    let linear = |command: &str, expected: bool| {
        let started = std::time::Instant::now();
        assert_eq!(posix_denied(command), expected);
        let elapsed = started.elapsed();
        eprintln!("linear-time case: {elapsed:?}");
        assert!(elapsed < std::time::Duration::from_secs(60), "{elapsed:?}");
    };
    // R-4: 閉じない`${…$(`が行ごとに並んでも、行ごとに入力の終わりまで走査しない。
    linear(
        &format!("{}unlink /tmp/y", "echo ${x:-$(\n".repeat(40_000)),
        true,
    );
    // 終端のないヒアドキュメントが行ごとに並んでも（本文を区切らない従来の読みは毎行記録する）、
    // 行ごとに入力の終わりまで終端行を探し直さない。
    for many in [
        "cat <<EOF\n".repeat(40_000) + "echo ok",
        "cat <<'EOF'\n".repeat(40_000) + "echo ok",
        (0..30_000)
            .map(|k| format!("cat <<E{k}\n"))
            .collect::<String>()
            + "echo ok",
    ] {
        linear(&many, false);
    }
    for allowed in [
        // F-1: `<<<`はヒアストリングで、ヒアドキュメントの終端語を読まない。
        "count=\"$(wc -l <<< \"$lines\")\"",
        "echo \"$(cat <<<\"$x\")\" done",
        // F-2: ヒアドキュメント本文のJSON行は、実行名の位置のブレース展開として拒否しない。
        "curl -s -X POST http://localhost/api -d @- <<'EOF'\n{\"name\":\"x\",\"id\":1}\nEOF",
        "kubectl apply -f - <<EOF\n{\"a\":\"b\",\"c\":1}\nEOF",
        // F-3: 置換の中のコメント（`'`・`)`を含む）は行末まで。
        "x=\"$(\n# don't do this\necho hi\n)\"",
        "x=$(\n# it's (fine)\necho hi\n)\necho \"$x\"",
        // F-3: `${…}`の中・退避した空白の後の`#`はコメントではない。
        "x=\"$(echo ${x:- #})\"; echo ok",
        "x=\"$(echo a\\ #b)\"",
    ] {
        assert!(!posix_denied(allowed), "{allowed:?}");
        if cfg!(windows) {
            assert_eq!(reason(allowed, "Bash", None), None, "{allowed:?}");
        }
    }
}
/// POSIX shellの`-c`後のoption・`--`・値付きoptionの結合形でも、静的な本文を再帰検査する。
#[test]
fn posix_shell_command_body_follows_options_after_dash_c() {
    for command in [
        r#"bash -c -- "rm -rf /tmp/owned-fixture""#,
        r#"sh -c -x "rm -rf /tmp/owned-fixture""#,
        r#"bash -oc posix "rm -rf /tmp/owned-fixture""#,
        r#"bash -co posix "rm -rf /tmp/owned-fixture""#,
        r#"bash -O extglob -c "rm -rf /tmp/owned-fixture""#,
        r#"bash -c -o posix -- "rm -rf /tmp/owned-fixture""#,
    ] {
        for (tool, shell) in [("Bash", None), ("exec_command", Some("bash"))] {
            assert!(reason(command, tool, shell).is_some(), "{tool}: {command}");
        }
    }
    for command in [
        r#"bash -c "echo hi""#,
        r#"sh -c -x "echo hi""#,
        r#"bash -c -- "echo hi""#,
        r#"bash -oc posix "echo hi""#,
        r#"bash -lc "echo hi""#,
    ] {
        for (tool, shell) in [("Bash", None), ("exec_command", Some("bash"))] {
            assert_eq!(reason(command, tool, shell), None, "{tool}: {command}");
        }
    }
    // 本文や値が欠落・動的なら検査不能として既存の拒否文言で拒否する。
    for (command, expected) in [
        ("bash -c --", "missing or dynamic POSIX shell command"),
        ("bash -oc posix", "missing or dynamic POSIX shell command"),
        ("bash -oc", "missing or dynamic POSIX shell option"),
    ] {
        let reason = reason(command, "exec_command", Some("bash")).expect(command);
        assert!(reason.contains(expected), "{command}: {reason}");
        assert!(reason.contains("interpretation="), "{command}: {reason}");
    }
    // 動的な本文は別の規則が先に拒否する（理由の文言は問わず、許可されないことだけを確認する）。
    assert!(reason(r#"bash -c -- "$BODY""#, "exec_command", Some("bash")).is_some());
}
/// 外側がPowerShell・CMD規則でも、`sh`・`bash`・`zsh`の結合flagと`-c`後の`--`を検査する。
#[test]
fn posix_shell_wrapper_under_other_rules_inspects_combined_flags() {
    for command in [
        r#"bash -ec "rm -rf /tmp/owned-fixture""#,
        r#"sh -xc "rm -rf /tmp/owned-fixture""#,
        r#"zsh -lic "rm -rf /tmp/owned-fixture""#,
        r#"bash -c -- "rm -rf /tmp/owned-fixture""#,
        r#"bash -oc posix "rm -rf /tmp/owned-fixture""#,
    ] {
        for shell in ["pwsh", "cmd.exe"] {
            assert!(denied(command, shell), "{shell}: {command}");
        }
    }
    for command in [
        r#"bash -ec "echo hi""#,
        r#"sh -xc "echo hi""#,
        r#"bash -c -- "echo hi""#,
        r#"bash script.sh"#,
    ] {
        for shell in ["pwsh", "cmd.exe"] {
            assert!(!denied(command, shell), "{shell}: {command}");
        }
    }
}
