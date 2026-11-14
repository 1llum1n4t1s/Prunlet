#requires -Version 7.0
# ProcessStartInfo.ArgumentList等のPowerShell 7系の挙動に依存するため、7.0未満では開始しない。
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    # 開発者固有の既定値は持たない。検証するPrunlet設定の絶対パスを明示する。
    [Parameter(Mandatory)][string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $ConfigPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw "Absolute path required: $path" }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
# 他のsuiteと同じ外部出力先ガード（リポジトリ・Codex home配下・リンク経由・UNC/デバイスパスを拒否）。
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($OutputDirectory, $ReportPath)) { Assert-ExternalVerificationPath $path @($repo) }
if (![IO.File]::Exists($ExecutablePath)) { throw "Executable not found: $ExecutablePath" }
if ([IO.Directory]::Exists($OutputDirectory) -or [IO.File]::Exists($OutputDirectory)) { throw "Output already exists: $OutputDirectory" }
if ([IO.File]::Exists($ReportPath) -or [IO.Directory]::Exists($ReportPath)) { throw "Report already exists: $ReportPath" }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputDirectory))) { throw 'Output parent does not exist.' }
if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($ReportPath))) { throw 'Report parent does not exist.' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$fixture = Join-Path $OutputDirectory 'hook-sentinel.txt'
[IO.File]::WriteAllText($fixture, 'hook sentinel: never execute fixture commands', [Text.UTF8Encoding]::new($false))
$fixtureHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash

# 検査対象はすべてhookへ送る文字列で、実行しない。
$single = @('$script=@''', '/opt/homebrew/bin/docker --host socket exec sample /bin/sh -ec ''cd /work/src; [ -f /work/src/core ]; rm -- /work/src/core; [ ! -e /work/src/core ]''', '''@; $encoded=Encode($script); & ssh mac $encoded') -join "`n"
$double = @('$script=@"', '/bin/sh -ec ''cd /work/src; rm -- /work/src/core''', '"@', '& ssh mac $script') -join "`n"
$expansion = @('$script=@"', 'literal $(Remove-Item -LiteralPath "<FILE>")', '"@', '& ssh mac $script') -join "`n"
$singleExpansion = @('$script=@''', 'literal $(Remove-Item -LiteralPath "<FILE>")', '''@', '& ssh mac $script') -join "`n"
$startSpace = @('$script=@''  ', '/bin/sh -ec ''cd /work/src; rm -- /work/src/core''', '''@', '& ssh mac $script') -join "`n"
$indentTerminator = @('$script=@''', 'literal', '  ''@', 'rm -- <FILE>') -join "`n"
$afterTerminator = @('$script=@''', '/bin/sh -ec ''cd /work/src; rm -- /work/src/core''', '''@; rm -- <FILE>') -join "`n"
$unterminated = @('$script=@''', 'literal', 'rm -- <FILE>') -join "`n"
$malformed = @('$script=@''', 'literal', '''@ trailing text; rm -- <FILE>') -join "`n"
$cmdBlock = @('$script=@''', 'echo ok & rm -- <FILE>', '''@') -join "`n"
$wrapper = 'pwsh -Command ' + '"' + ($single -replace '"', '`"') + '"'
$cases = @(
    @{ name='single-here-pwsh'; command=$single; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='single-here-powershell-path'; command=$single; shell='C:\Program Files\PowerShell\7\pwsh.exe'; pass=$true; bashPass=$false },
    @{ name='single-here-no-hint'; command=$single; pass=$false },
    @{ name='single-here-unknown'; command=$single; shell='unknown-shell'; pass=$false },
    @{ name='single-here-bash-hint'; command=$single; shell='bash'; pass=$false },
    @{ name='single-here-sh-hint'; command=$single; shell='sh'; pass=$false },
    @{ name='single-here-zsh-hint'; command=$single; shell='zsh'; pass=$false },
    @{ name='single-here-cmd'; command=$cmdBlock; shell='cmd.exe'; pass=$false },
    @{ name='double-here-literal'; command=$double; shell='pwsh'; pass=$true },
    @{ name='double-here-local-expansion'; command=$expansion; shell='pwsh'; pass=$false },
    @{ name='single-here-literal-expansion'; command=$singleExpansion; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='single-here-start-space'; command=$startSpace; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='single-here-indented-terminator'; command=$indentTerminator; shell='pwsh'; pass=$false },
    @{ name='after-terminator-local-delete'; command=$afterTerminator; shell='pwsh'; pass=$false },
    @{ name='before-here-local-delete'; command=('rm -- <FILE>' + "`n" + $single); shell='pwsh'; pass=$false },
    @{ name='after-here-local-delete'; command=($single + "`n" + 'Remove-Item -LiteralPath <FILE>'); shell='pwsh'; pass=$false },
    @{ name='cmd-wrapper-delete'; command='cmd /c "echo ok & rm -- <FILE>"'; shell='pwsh'; pass=$false },
    @{ name='pwsh-wrapper-here'; command=$wrapper; shell='cmd.exe'; pass=$true },
    @{ name='pwsh-wrapper-delete'; command='pwsh -Command "Remove-Item -LiteralPath <FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='unterminated-here'; command=$unterminated; shell='pwsh'; pass=$false },
    @{ name='malformed-here'; command=$malformed; shell='pwsh'; pass=$false },
    @{ name='ssh-quoted-text'; command='ssh mac "echo safe; rm -- /remote/core"'; shell='pwsh'; pass=$true },
    @{ name='ssh-quoted-path-unknown-shell'; command='& ''C:\Program Files\Git\usr\bin\ssh.exe'' mac ''echo safe && rm -- /remote/core'''; pass=$false },
    @{ name='ordinary-non-delete'; command='Write-Output "hello"'; shell='pwsh'; pass=$true },
    @{ name='registry-delete'; command='reg.exe delete HKCU\Software\PrunletHookProbe /f'; pass=$false },
    @{ name='registry-pwsh-wrapper'; command='pwsh -Command "Remove-Item HKCU:\Software\PrunletHookProbe"'; pass=$false },
    @{ name='registry-cmd-wrapper'; command='cmd.exe /d /c reg.exe delete HKCU\Software\PrunletHookProbe /f'; pass=$false },
    @{ name='file-remove-item'; command='Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='powershell-escape'; command='Remove`-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='cmd-escape'; command='d^el "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='posix-escape'; command='r\m -- "<FILE>"'; shell='bash'; pass=$false },
    @{ name='cmd-hash-before-delete'; command='echo # note & del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-hash-without-delete'; command='echo # note'; shell='cmd.exe'; pass=$true },
    @{ name='powershell-hash-comment'; command='Write-Output ok # note & Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='cmd-if-equal'; command='if 1==1 del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-equal-spaced'; command='if 1 == 1 del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-equal-right-spaced'; command='if 1== 1 del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-equal-left-spaced'; command='if 1 ==1 del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-empty-quoted'; command='if ""=="" del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-quoted-operands'; command='if "a==b" == "a==b" del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-quoted-keyword'; command='if "exist" == "exist" del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-escaped-equals'; command='if 1=^=1 del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-exist'; command='if exist "<FILE>" del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-defined'; command='if defined TEMP del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-errorlevel'; command='if not errorlevel 1 del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-cmdextversion'; command='if cmdextversion 1 del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-registry'; command='if /i not a EQU b reg delete HKCU\Software\PrunletHookProbe /f'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-wrapper'; command='cmd /c "if 1==1 del <FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-wrapper-quoted'; command='cmd /c if "a==b"=="a==b" del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-wrapper-empty'; command='cmd /c if ""=="" del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-wrapper-quoted-data'; command='cmd /c if "del"=="del" echo safe'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-if-wrapper-pwsh'; command='cmd /c if "x"=="x" del "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='cmd-if-wrapper-pwsh-data'; command='cmd /c if "del"=="del" echo safe'; shell='pwsh'; pass=$true },
    @{ name='cmd-if-quoted-data'; command='if "del" == "del" echo safe'; shell='cmd.exe'; pass=$true }
)
foreach ($operator in @('EQU', 'NEQ', 'LSS', 'LEQ', 'GTR', 'GEQ')) {
    $cases += @{ name="cmd-if-$operator"; command="if 1 $operator 1 del <FILE>"; shell='cmd.exe'; pass=$false }
}

# cmd.exe wrapperのswitch形。MSYSの二重スラッシュ・/R・連結・直結本文を本文として検査する。
# 未知switchと5段以上の入れ子はfail-closed。正規のPrunlet CLI呼出しは/d /cと//d //cの両形で通過する。
$pathsJson = Join-Path $OutputDirectory 'hook-paths.json'
$cases += @(
    @{ name='cmd-wrapper-double-slash'; command='cmd.exe //c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-double-slash-d'; command='cmd.exe //d //c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-double-slash-pwsh'; command='cmd.exe //d //c del "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='cmd-wrapper-r-switch'; command='cmd /R del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-attached-body'; command='cmd /cdel "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-joined-switches'; command='cmd /d/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-joined-quoted-body'; command='cmd /D/Q/C "del <FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-known-switches'; command='cmd /e:on /v:off /t:0a /s /c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-registry-double-slash'; command='cmd.exe //d //c reg delete HKCU\Software\PrunletHookProbe /f'; pass=$false },
    @{ name='cmd-wrapper-unknown-switch'; command='cmd /z /c echo ok'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-stray-argument'; command='cmd stray /c echo ok'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    # cmd.exeはコマンドライン全体から/Cを探すため、語の途中にある本文switchも拒否する。
    @{ name='cmd-wrapper-mid-word-switch'; command='cmd x/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-mid-word-quoted-switch'; command='cmd "x"/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-mid-word-comma-switch'; command='cmd ,/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-mid-word-after-known-switch'; command='cmd /d x/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    # cmd.exeは`;` `,` `=`を空白相当の区切りとし、実行名も最初の`/ , ; =`で打ち切る。
    # `;`で割れたwrapper・実行名直結の`/c`・実行名や本文先頭の`, =`も本文を実行するため拒否する（Bashは全規則で検査）。
    @{ name='cmd-wrapper-semicolon-switch'; command='cmd;/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-space-semicolon-switch'; command='cmd ;/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-known-switch-semicolon'; command='cmd /d;/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-tab-semicolon-switch'; command=('cmd' + [char]9 + ';/c del "<FILE>"'); shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-nested-semicolon-switch'; command='cmd /c cmd;/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-comma-glued-switch'; command='cmd,/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-equals-glued-switch'; command='cmd=/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-slash-glued-switch'; command='cmd/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-exe-slash-glued-switch'; command='cmd.exe/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-forward-slash-path-glued-switch'; command='C:/Windows/System32/cmd.exe/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-call-slash-glued-switch'; command='call cmd/c del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-wrapper-switch-equals-body'; command='cmd /c=del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-wrapper-switch-comma-body'; command='cmd /c,del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-leading-comma-delete'; command=',del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-leading-equals-delete'; command='=del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-wrapper-space-equals-switch'; command='cmd =/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-known-switch-equals-switch'; command='cmd /d/q=/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-extension-switch-comma'; command='cmd /e:on,/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-switch-semicolon-body'; command='cmd /c;del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-wrapper-tab-separated-switch'; command=('cmd' + [char]9 + '/c del "<FILE>"'); shell='cmd.exe'; pass=$false },
    # 単純名の削除命令に直結した`/ , =`もcmd.exeは実行名の終端として読み、残りを引数にする。
    @{ name='cmd-delete-glued-rd-switches'; command='rd/s/q "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "rd"' },
    @{ name='cmd-delete-glued-rd-upper'; command='RD/S/Q "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "RD"' },
    @{ name='cmd-delete-glued-del-switch'; command='del/q "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-delete-glued-del-comma'; command='del,"<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-delete-glued-rd-equals'; command='rd=/s "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "rd"' },
    @{ name='cmd-delete-glued-erase-switch'; command='erase/f "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "erase"' },
    @{ name='cmd-delete-glued-rmdir-switch'; command='rmdir/s "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "rmdir"' },
    @{ name='cmd-delete-glued-call'; command='call del/q "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-delete-glued-if'; command='if exist "<FILE>" del/q "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-delete-glued-wrapper-body'; command='cmd /c rd/s/q "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "rd"' },
    @{ name='cmd-registry-glued-delete'; command='reg,delete HKCU\Software\PrunletHookProbe /f'; shell='cmd.exe'; pass=$false; reason='registry deletion command' },
    # 経路形式の実行名は`/`を経路区切りとして最後の要素で判定する（`C:/tools/del/x`は外部プログラムxとして通す）。
    @{ name='cmd-path-executable-with-del-directory'; command='C:/tools/del/x'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-relative-path-with-del-directory'; command='tools/del/x'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-echo-glued-delete-data'; command='echo del/q x'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-dir-glued-switch'; command='dir/b'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-reg-glued-help'; command='reg/?'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-wrapper-pwsh-quoted-semicolon-switch'; command='cmd '';/c'' del "<FILE>"'; shell='pwsh'; pass=$false; reason='unsupported CMD wrapper switch' },
    @{ name='cmd-wrapper-mid-word-switch-bash'; command='cmd x/c del "<FILE>"'; pass=$false },
    @{ name='cmd-wrapper-help'; command='cmd /?'; shell='cmd.exe'; pass=$true },
    # 実行名と本文switch以外の`/ , ; =`は通常の文字なので誤拒否しない。
    @{ name='cmd-wrapper-keep-slash-argument'; command='cmd /k echo hi/there'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-wrapper-body-semicolon-data'; command='cmd /c echo a;b'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-semicolon-before-wrapper-data'; command='echo ok;cmd /c echo hi'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-set-assignment'; command='set X=1'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-if-equal-echo'; command='if a==b echo x'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-echo-semicolon'; command='echo a;b'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-echo-slash'; command='echo a/b'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-echo-comma-data'; command='echo ,del x'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-dir-forward-slash-path'; command='dir C:/Windows /b'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-reg-query'; command='reg query HKCU\Software\PrunletHookProbe'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-wrapper-double-slash-query'; command='cmd.exe //d //c reg query HKCU\Software\PrunletHookProbe'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-wrapper-double-slash-echo'; command='cmd.exe //d //c echo del "<FILE>"'; shell='cmd.exe'; pass=$true },
    @{ name='canonical-cli-cmd'; command=('cmd.exe /d /c "' + $ExecutablePath + ' --config ' + $ConfigPath + ' delete --paths-file ' + $pathsJson + '"'); shell='cmd.exe'; pass=$true },
    @{ name='canonical-cli-cmd-no-shell'; command=('cmd.exe /d /c "' + $ExecutablePath + ' --config ' + $ConfigPath + ' delete --paths-file ' + $pathsJson + '"'); pass=$true },
    @{ name='canonical-cli-msys'; command=('cmd.exe //d //c "' + $ExecutablePath + ' --config ' + $ConfigPath + ' delete --paths-file ' + $pathsJson + '"'); pass=$true },
    @{ name='canonical-cli-call'; command=('cmd.exe /d /c call "' + $ExecutablePath + '" --config "' + $ConfigPath + '" delete --paths-file "' + $pathsJson + '"'); shell='cmd.exe'; pass=$true },
    @{ name='canonical-cli-call-msys'; command=('cmd.exe //d //c call "' + $ExecutablePath + '" --config "' + $ConfigPath + '" delete --paths-file "' + $pathsJson + '"'); pass=$true },
    @{ name='cmd-wrapper-depth-four'; command='cmd /c cmd /c cmd /c cmd /c echo ok'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-wrapper-depth-limit'; command='cmd /c cmd /c cmd /c cmd /c cmd /c echo ok'; shell='cmd.exe'; pass=$false; reason='inspection depth limit exceeded' },
    @{ name='pwsh-wrapper-depth-limit'; command='pwsh -c pwsh -c pwsh -c pwsh -c pwsh -c Write-Output ok'; shell='pwsh'; pass=$false; reason='inspection depth limit exceeded' }
)

# CMDの括弧なしfor ... do / ... elseの後続コマンド。POSIX解釈ではfor構文自体を検査不能として拒否する。
$cases += @(
    @{ name='cmd-for-do-delete'; command='for %i in ("<FILE>") do del %i'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-for-do-if-delete'; command='for %i in ("<FILE>") do if exist %i del %i'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-else-delete'; command='if exist "<FILE>" (echo keep) else del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-else-registry'; command='if 1==2 (echo keep) else reg delete HKCU\Software\PrunletHookProbe /f'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-for-do-data'; command='for %i in (a) do echo del %i'; shell='cmd.exe'; pass=$true; bashPass=$false },
    @{ name='cmd-else-data'; command='if 1==1 (echo keep) else echo del'; shell='cmd.exe'; pass=$true }
)

# 制御語（call・do・else）やifの条件に`, =`で直結した実行名もcmd.exeは実行する。
# `=`での打切りはshellがcmdと明示された場合だけ無条件に行い、shell不明（Bash）ではPOSIX代入と区別できないため
# `=`の直後が`/`の場合（rd=/s）に限る。Bashの`do=del`はPOSIX候補のfor構文検査で拒否される。
$cases += @(
    @{ name='cmd-call-comma-delete'; command='call,del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-call-equals-delete'; command='call=del "<FILE>"'; shell='cmd.exe'; pass=$false; bashPass=$true; reason='detected token "del"' },
    @{ name='cmd-call-comma-wrapper'; command='call,cmd/c del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-call-comma-quoted-delete'; command='call,"del" "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-if-exist-comma-delete'; command='if exist "<FILE>",del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-if-exist-single-word-delete'; command='if exist <FILE>,del/q,<FILE>'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-if-not-exist-comma-delete'; command='if not exist "<FILE>.x",del "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-for-do-comma-delete'; command='for %i in ("<FILE>") do,del %i'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-for-do-equals-delete'; command='for %i in ("<FILE>") do=del %i'; shell='cmd.exe'; pass=$false },
    @{ name='cmd-else-comma-delete'; command='if 1==2 (echo no) else,del "<FILE>"'; shell='cmd.exe'; pass=$false; reason='detected token "del"' },
    @{ name='cmd-else-equals-delete'; command='if 1==2 (echo no) else=del "<FILE>"'; shell='cmd.exe'; pass=$false; bashPass=$true },
    @{ name='cmd-wrapper-equals-glued-switch-bash'; command='cmd=/c del "<FILE>"'; pass=$false },
    @{ name='cmd-delete-glued-rd-equals-bash'; command='rd=/s "<FILE>"'; pass=$false },
    # shell不明（Bash）のPOSIX代入は削除命令とみなさない。
    @{ name='posix-assignment-rm-name'; command='rm=1; echo ok'; pass=$true },
    @{ name='posix-assignment-ri-name'; command='ri=0'; pass=$true },
    @{ name='posix-assignment-rd-name'; command='rd=foo'; pass=$true },
    @{ name='posix-assignment-rp-substitution'; command='rp=$(realpath x)'; pass=$true },
    @{ name='posix-assignment-cmd-name'; command='cmd=1; echo ok'; pass=$true },
    # 引用内の`,`、削除命令以外への直結、`,`を含む引数は誤拒否しない。
    @{ name='cmd-if-exist-quoted-comma-data'; command='if exist "a,b.txt" echo ok'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-if-exist-comma-echo'; command='if exist a,b echo ok'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-type-comma-files'; command='type a.txt,b.txt'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-call-comma-echo'; command='call,echo ok'; shell='cmd.exe'; pass=$true },
    @{ name='cmd-for-semicolon-list'; command='for %i in (a;b) do echo %i'; shell='cmd.exe'; pass=$true; bashPass=$false },
    @{ name='cmd-set-path-semicolon'; command='set PATH=C:\x;%PATH%'; shell='cmd.exe'; pass=$true }
)

# 非strictのPowerShell規則でも代入右辺・dot呼出しの後続をコマンドとして検査する。
# 引用・ヒアストリング・検索文字列のdataは誤拒否しない。
$assignmentHereData = @('$script = @''', 'Remove-Item -LiteralPath "<FILE>"', '$y = Remove-Item -LiteralPath "<FILE>"', '''@', 'Write-Output $script') -join "`n"
$cases += @(
    @{ name='pwsh-assignment-delete'; command='$x = Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false; reason='detected token "Remove-Item"' },
    @{ name='pwsh-assignment-compact-delete'; command='$x=Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='pwsh-return-delete'; command='return Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='pwsh-dot-call-delete'; command='. Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false; reason='detected token "Remove-Item"' },
    @{ name='pwsh-command-assignment-delete'; command='pwsh -Command "$x = Remove-Item -LiteralPath <FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='pwsh-assignment-quoted-data'; command='$x = ''Remove-Item -LiteralPath "<FILE>"'''; shell='pwsh'; pass=$true },
    @{ name='pwsh-assignment-here-data'; command=$assignmentHereData; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='pwsh-assignment-search-data'; command='$hits = Select-String -Pattern ''Remove-Item'' -Path "<FILE>"'; shell='pwsh'; pass=$true },
    @{ name='pwsh-search-assignment-text'; command='rg -n ''$x = Remove-Item'' "<FILE>"'; shell='pwsh'; pass=$true },
    @{ name='pwsh-dot-source-script'; command='. .\env.ps1'; shell='pwsh'; pass=$true }
)

# 実ホストの Bash 入力では shell がない。対象文字列は UTF-16LE にして hook へ渡すだけで、実行しない。
function ConvertTo-EncodedHookCommand([string]$scriptText) {
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText.Replace('<FILE>', $fixture)))
}
$encodedSafe = ConvertTo-EncodedHookCommand $single
$encodedDelete = ConvertTo-EncodedHookCommand 'Remove-Item -LiteralPath "<FILE>"'
$encodedRegistry = ConvertTo-EncodedHookCommand 'Remove-Item HKCU:\Software\PrunletHookProbe'
$encodedCases = @(
    @{ name='encoded-mac-single-here'; command="pwsh -NoProfile -EncodedCommand $encodedSafe"; pass=$true },
    @{ name='encoded-delete-before-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ('Remove-Item -LiteralPath "<FILE>"' + "`n" + $single))); pass=$false },
    @{ name='encoded-delete-after-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ($single + "`n" + 'Remove-Item -LiteralPath "<FILE>"'))); pass=$false },
    @{ name='encoded-registry-before-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ('Remove-Item HKCU:\Software\PrunletHookProbe' + "`n" + $single))); pass=$false },
    @{ name='encoded-registry-after-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ($single + "`n" + 'Remove-Item HKCU:\Software\PrunletHookProbe'))); pass=$false },
    @{ name='encoded-double-quoted-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Write-Output "$(Remove-Item -LiteralPath "<FILE>")"')); pass=$false },
    @{ name='encoded-single-quoted-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Write-Output ''$(Remove-Item -LiteralPath "<FILE>")''')); pass=$true },
    @{ name='encoded-double-here-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $expansion)); pass=$false },
    @{ name='encoded-japanese-safe'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Write-Output "日本語の確認"')); pass=$true },
    @{ name='encoded-japanese-delete'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Write-Output "日本語"; Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-invalid-base64'; command='pwsh -NoProfile -EncodedCommand !!!'; pass=$false },
    @{ name='encoded-odd-byte-count'; command='pwsh -NoProfile -EncodedCommand QQ=='; pass=$false },
    @{ name='encoded-unpaired-surrogate'; command='pwsh -NoProfile -EncodedCommand ANg='; pass=$false },
    @{ name='encoded-missing'; command='pwsh -NoProfile -EncodedCommand'; pass=$false },
    @{ name='encoded-dynamic-value'; command='pwsh -NoProfile -EncodedCommand $env:PAYLOAD'; pass=$false },
    @{ name='encoded-cmd-wrapper-safe'; command="cmd.exe /d /c pwsh -NoProfile -EncodedCommand $encodedSafe"; pass=$false },
    @{ name='encoded-cmd-wrapper-delete'; command="cmd.exe /d /c pwsh -NoProfile -EncodedCommand $encodedDelete"; pass=$false },
    @{ name='encoded-pwsh-wrapper-safe'; command="pwsh -NoProfile -Command 'pwsh -NoProfile -EncodedCommand $encodedSafe'"; pass=$false },
    @{ name='encoded-pwsh-wrapper-registry'; command="pwsh -NoProfile -Command 'pwsh -NoProfile -EncodedCommand $encodedRegistry'"; pass=$false }
)
$smartOpen = [string][char]0x201c
$smartClose = [string][char]0x201d
$smartFileExpansion = 'Write-Output ' + $smartOpen + '$(Remove-Item -LiteralPath "<FILE>")' + $smartClose
$smartRegistryExpansion = 'Write-Output ' + $smartOpen + '$(Remove-Item HKCU:\Software\PrunletHookProbe)' + $smartClose
$smartSingleHere = @('$script=@''', ($smartOpen + '$(Remove-Item -LiteralPath "<FILE>")' + $smartClose), '''@', 'Write-Output $script') -join "`n"
$escapedHere = @('$script=@"', 'literal `$(Remove-Item -LiteralPath "<FILE>")', '"@', 'Write-Output $script') -join "`n"
$nulScript = 'Write-Output safe' + [char]0 + '; Remove-Item -LiteralPath "<FILE>"'
$commentLiteral = @('$script=@''', '<# literal #> Remove-Item -LiteralPath "<FILE>"', '''@', 'Write-Output $script') -join "`n"
$unicodeEscapeLiteral = @('$script=@''', 'Remove`u{2d}Item -LiteralPath "<FILE>"', '''@', 'Write-Output $script') -join "`n"
$leadingUnicode = [string][char]0x00ff
$encodedLeadingSlash = ConvertTo-EncodedHookCommand $leadingUnicode
if (!$encodedLeadingSlash.StartsWith('/')) { throw 'Expected slash-prefixed Base64 fixture.' }
$unicodeHere = @('# Unicode data', '$script=@''', $leadingUnicode, '''@', 'Write-Output $script') -join "`n"
$assignmentDeletes = @(
    '$x=Remove-Item -LiteralPath "<FILE>"',
    '$x = Remove-Item -LiteralPath "<FILE>"',
    '$x += Remove-Item -LiteralPath "<FILE>"',
    '[string]$x = Remove-Item -LiteralPath "<FILE>"',
    'return Remove-Item -LiteralPath "<FILE>"',
    'throw Remove-Item -LiteralPath "<FILE>"',
    'exit Remove-Item -LiteralPath "<FILE>"',
    'foreach ($x in Remove-Item -LiteralPath "<FILE>") { Write-Output $x }',
    '$x = reg.exe delete HKCU\Software\PrunletHookProbe /f'
)
$assignmentNames = @('compact', 'spaced', 'append', 'typed', 'return', 'throw', 'exit', 'foreach', 'registry')
$assignmentLiteral = (@('$script=@''') + $assignmentDeletes + @('''@', 'Write-Output $script')) -join "`n"
$hashLiteral = @('$script=@''', '@{key = Remove-Item -LiteralPath "<FILE>"}', '@{key=Remove-Item -LiteralPath "<FILE>"}', '''@', 'Write-Output $script') -join "`n"
$memberAssignmentLiteral = @('$script=@''', '($o).Length = Remove-Item -LiteralPath "<FILE>"', '($a)[0]=Remove-Item -LiteralPath "<FILE>"', '''@', 'Write-Output $script') -join "`n"
$quotedMemberLiteral = @('$script=@''', '$o.''Length''=Remove-Item -LiteralPath "<FILE>"', '($o).''Length''=Remove-Item -LiteralPath "<FILE>"', '''@', 'Write-Output $script') -join "`n"
$equalsLiteral = @('$script=@''', 'Remove-Item ''=''', 'reg delete ''=''', 'Write-Output = Remove-Item', '''@', 'Write-Output $script') -join "`n"
$quotedExecutableLiteral = @('$script=@''', ('"pwsh" -NoProfile -EncodedCommand ' + $encodedDelete), '''@', 'Write-Output $script') -join "`n"
$outerHere = @('$remote = @''', 'pwsh -EncodedCommand example', '''@', 'Write-Output $remote') -join "`n"
$processStarts = @('Start-Process', 'start', 'saps') | ForEach-Object { "$_ -FilePath pwsh -ArgumentList '-NoProfile','-EncodedCommand','$encodedDelete'" }
$processStartsLiteral = (@('$script=@''') + $processStarts + @('''@', 'Write-Output $script')) -join "`n"
$remoteEncoded = @('$remote=@''', '/bin/sh -ec ''rm -- /remote/core''', '''@', '$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote)); & ssh mac $encoded') -join "`n"
$encodedCases += @(
    @{ name='encoded-smart-double-quoted-file-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $smartFileExpansion)); pass=$false },
    @{ name='encoded-smart-double-quoted-registry-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $smartRegistryExpansion)); pass=$false },
    @{ name='encoded-escaped-double-quoted-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Write-Output "literal `$(Remove-Item -LiteralPath <FILE>)"')); pass=$true },
    @{ name='encoded-escaped-double-here-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $escapedHere)); pass=$true },
    @{ name='encoded-escaped-double-quoted-pwsh'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Write-Output "literal `$(pwsh -NoProfile -EncodedCommand invalid)"')); pass=$true },
    @{ name='encoded-smart-quotes-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $smartSingleHere)); pass=$true },
    @{ name='encoded-dynamic-get-command'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& (Get-Command Remove-Item) -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-static-ssh-path'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''C:\Program Files\Git\usr\bin\ssh.exe'' mac ''echo ''''quoted'''' && rm -- /remote/core''')); pass=$true },
    @{ name='encoded-static-ssh-escaped-target'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''C:\Program Files\O''''Brien\ssh.exe'' mac ''rm -- /remote/core''')); pass=$true },
    @{ name='encoded-static-call-registry'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''reg.exe'' delete HKCU\Software\PrunletHookProbe /f')); pass=$false },
    @{ name='encoded-static-call-registry-trailing-space'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''reg.exe '' delete HKCU\Software\PrunletHookProbe /f')); pass=$false },
    @{ name='encoded-static-call-cmd-trailing-dot'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''C:\Windows\System32\cmd.exe.'' /c "del <FILE>"')); pass=$false },
    @{ name='encoded-static-call-registry-stop-parsing'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''reg.exe'' --% delete HKCU\Software\PrunletHookProbe /f')); pass=$false },
    @{ name='encoded-static-call-registry-quoted-stop-parsing'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''reg.exe'' ''--%'' delete HKCU\Software\PrunletHookProbe /f')); pass=$false },
    @{ name='encoded-static-call-registry-here-verb'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand (@('& ''reg.exe'' @''', 'delete', '''@ HKCU\Software\PrunletHookProbe /f') -join "`n"))); pass=$false },
    @{ name='encoded-static-call-registry-dynamic-verb'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''reg.exe'' (''de''+''lete'') HKCU\Software\PrunletHookProbe /f')); pass=$false },
    @{ name='encoded-static-call-registry-query'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''reg.exe'' query HKCU\Software\PrunletHookProbe')); pass=$false },
    @{ name='encoded-static-call-iex'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''iex'' "Remove-Item <FILE>"')); pass=$false },
    @{ name='encoded-static-call-process'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''Start-Process'' rm')); pass=$false },
    @{ name='encoded-static-call-wrapper'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''pwsh'' -Command "Remove-Item <FILE>"')); pass=$false },
    @{ name='encoded-call-partial-literal'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''ssh''.ToString() mac')); pass=$false },
    @{ name='encoded-call-concatenation'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''ssh''+''suffix'' mac')); pass=$false },
    @{ name='encoded-call-dynamic-target'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& $target mac')); pass=$false },
    @{ name='encoded-call-expandable-target'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& "$(Remove-Item <FILE>)" mac')); pass=$false },
    @{ name='encoded-static-call-local-before'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Remove-Item <FILE>; & ''ssh'' mac ''rm /remote''')); pass=$false },
    @{ name='encoded-static-call-local-after'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''ssh'' mac ''rm /remote''; Remove-Item <FILE>')); pass=$false },
    @{ name='encoded-static-call-argument-expansion'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''ssh'' mac "$(Remove-Item <FILE>)"')); pass=$false },
    @{ name='encoded-invalid-prior-option'; command="pwsh -NoProfile -NotARealOption -EncodedCommand $encodedDelete"; pass=$false },
    @{ name='encoded-multiple-arguments'; command="pwsh -NoProfile -EncodedCommand $encodedSafe -EncodedCommand $encodedDelete"; pass=$false },
    @{ name='encoded-cmd-invalid-prior-option'; command="cmd.exe /invalid /c pwsh -NoProfile -EncodedCommand $encodedDelete"; pass=$false },
    @{ name='encoded-nul'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $nulScript)); pass=$false },
    @{ name='encoded-block-comment-before-delete'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '<# comment #> Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-block-comment-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $commentLiteral)); pass=$true },
    @{ name='encoded-unicode-escape-delete'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Remove`u{2d}Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-unicode-escape-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $unicodeEscapeLiteral)); pass=$true },
    @{ name='encoded-quoted-value'; command="pwsh -NoProfile -EncodedCommand '$encodedSafe'"; pass=$false },
    @{ name='encoded-command-before'; command="Write-Output safe; pwsh -NoProfile -EncodedCommand $encodedSafe"; pass=$false },
    @{ name='encoded-command-after'; command="pwsh -NoProfile -EncodedCommand $encodedSafe; Write-Output safe"; pass=$false },
    @{ name='encoded-standard-case-insensitive'; command="pwsh -nOpRoFiLe -eNcOdEdCoMmAnD $encodedSafe"; pass=$true },
    @{ name='encoded-leading-slash'; command="pwsh -NoProfile -EncodedCommand $encodedLeadingSlash"; pass=$false },
    @{ name='encoded-unicode-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $unicodeHere)); pass=$true },
    @{ name='encoded-assignment-text-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $assignmentLiteral)); pass=$true },
    @{ name='encoded-assignment-after-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $single)); pass=$true },
    @{ name='encoded-env-wrapper'; command="env pwsh -NoProfile -EncodedCommand $encodedDelete"; pass=$false },
    @{ name='encoded-environment-assignment-wrapper'; command="FOO=1 pwsh -NoProfile -EncodedCommand $encodedDelete"; pass=$false },
    @{ name='encoded-pwsh-assignment-wrapper'; command=('$x = pwsh -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='encoded-remote-utf8-assignment'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $remoteEncoded)); pass=$true },
    @{ name='encoded-hashtable-spaced-delete'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '@{key = Remove-Item -LiteralPath "<FILE>"}')); pass=$false },
    @{ name='encoded-hashtable-compact-delete'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '@{key=Remove-Item -LiteralPath "<FILE>"}')); pass=$false },
    @{ name='encoded-hashtable-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $hashLiteral)); pass=$true },
    @{ name='encoded-outer-write-output-subexpression'; command=('Write-Output "$(pwsh -NoProfile -EncodedCommand ' + $encodedDelete + ')"'); pass=$false },
    @{ name='encoded-outer-echo-subexpression'; command=('echo "$(pwsh -NoProfile -EncodedCommand ' + $encodedDelete + ')"'); pass=$false },
    @{ name='encoded-outer-single-quoted-data'; command=('Write-Output ''pwsh -NoProfile -EncodedCommand ' + $encodedDelete + ''''); pass=$true },
    @{ name='encoded-member-assignment-spaced'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '($o).Length = Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-member-assignment-compact'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '($o).Length=Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-index-assignment-spaced'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '($a)[0] = Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-index-assignment-compact'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '($a)[0]=Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-assignment-quoted-literal'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '$x = ''Remove-Item -LiteralPath "<FILE>"''')); pass=$true },
    @{ name='encoded-member-assignment-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $memberAssignmentLiteral)); pass=$true },
    @{ name='outer-write-information-quoted-data'; command='Write-Information ''pwsh -EncodedCommand example'''; pass=$true },
    @{ name='outer-git-commit-quoted-data'; command='git commit -m ''pwsh -EncodedCommand example'''; pass=$true },
    @{ name='outer-pwsh-here-quoted-data'; command=$outerHere; shell='pwsh'; pass=$true; bashPass=$false },
    @{ name='encoded-process-start-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $processStartsLiteral)); pass=$true },
    @{ name='outer-quoted-pwsh-env-assignment'; command=('FOO=1 "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-quoted-pwsh-multiple-env-assignments'; command=('FOO=1 BAR=2 "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-quoted-pwsh-env'; command=('env "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-quoted-pwsh-env-assignment-command'; command=('env FOO=1 "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-quoted-pwsh-command-builtin'; command=('FOO=1 command "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-quoted-pwsh-command-builtin-path'; command=('FOO=1 command -p "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-quoted-pwsh-time'; command=('time "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-quoted-pwsh-nice'; command=('nice "pwsh" -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-split-quoted-pwsh-time'; command=('time p''wsh'' -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-split-quoted-pwsh-nice'; command=('nice p''wsh'' -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-time-echo-quoted-data'; command='time echo ''pwsh'' ''-EncodedCommand'''; pass=$true },
    @{ name='outer-nice-echo-quoted-data'; command='nice echo ''pwsh'' ''-EncodedCommand'''; pass=$true },
    @{ name='outer-time-echo-backtick-expansion'; command=('time echo `pwsh -NoProfile -EncodedCommand ' + $encodedDelete + '`'); pass=$false },
    @{ name='outer-nice-echo-backtick-expansion'; command=('nice echo `pwsh -NoProfile -EncodedCommand ' + $encodedDelete + '`'); pass=$false },
    @{ name='outer-escaped-backtick-before-expansion'; command=('time echo \`literal `pwsh -NoProfile -EncodedCommand ' + $encodedDelete + '`'); pass=$false },
    @{ name='outer-escaped-backtick-literal'; command=('time echo \`literal pwsh -EncodedCommand ' + $encodedDelete); pass=$true },
    @{ name='outer-mixed-quotes-subexpression'; command=('time echo ''prefix''"$( "pwsh" -En''coded''Command ' + $encodedDelete + ' )"'); pass=$false },
    @{ name='outer-mixed-quotes-literal'; command='time echo ''prefix''"literal"'; pass=$true },
    @{ name='outer-double-quoted-split-flag-subexpression'; command=('time echo "$( "pwsh" -En''coded''Command ' + $encodedDelete + ' )"'); pass=$false },
    @{ name='outer-double-quoted-split-flag-backtick'; command=('time echo "`pwsh -En''coded''Command ' + $encodedDelete + '`"'); pass=$false },
    @{ name='outer-double-quoted-date-subexpression'; command='time echo "$(Get-Date)"'; pass=$true },
    @{ name='outer-subexpression-backslash-flag'; command=('time echo "$( pwsh -En\codedCommand ' + $encodedDelete + ' )"'); pass=$false },
    @{ name='outer-backtick-backslash-flag'; command=('time echo "`pwsh -En\codedCommand ' + $encodedDelete + '`"'); pass=$false },
    @{ name='outer-join-path-quoted-data'; command='Join-Path ''pwsh'' ''-EncodedCommand'''; pass=$true },
    @{ name='outer-rg-powershell-patterns'; command='rg -e pwsh -e powershell .'; pass=$true },
    @{ name='outer-rg-powershell-patterns-cmd'; command='rg -e pwsh -e powershell .'; shell='cmd.exe'; pass=$true },
    @{ name='outer-rg-powershell-patterns-pwsh'; command='rg -e pwsh -e powershell .'; shell='pwsh'; pass=$true },
    @{ name='outer-time-rg-powershell-patterns'; command='time rg -e pwsh -e powershell .'; pass=$true },
    @{ name='outer-rg-powershell-patterns-quoted-expansion'; command='rg -e pwsh -e powershell "$(pwd)"'; pass=$true },
    @{ name='outer-rg-powershell-patterns-unquoted-expansion'; command='rg -e pwsh -e powershell $(pwd)'; pass=$true },
    @{ name='outer-rg-powershell-patterns-backtick-expansion'; command='rg -e pwsh -e powershell `pwd`'; pass=$true },
    @{ name='outer-rg-printf-e-subexpression'; command='rg -- "$(printf ''%s'' -e)" .'; pass=$true },
    @{ name='outer-rg-printf-e-backtick'; command='rg -- "`printf ''%s'' -e`" .'; pass=$true },
    @{ name='outer-rg-powershell-patterns-printf-e'; command='rg -e pwsh -e powershell "$(printf ''%s'' -e)"'; pass=$true },
    @{ name='outer-rg-printf-pwsh-e-subexpression'; command='rg -- "$(printf ''%s'' pwsh -e)" .'; pass=$true },
    @{ name='outer-rg-powershell-subexpression'; command=('rg $(pwsh -NoProfile -EncodedCommand ' + $encodedDelete + ') .'); pass=$false },
    @{ name='outer-rg-powershell-quoted-subexpression'; command=('rg "$(pwsh -NoProfile -EncodedCommand ' + $encodedDelete + ')" .'); pass=$false },
    @{ name='outer-env-unset-pwsh-encoded'; command=('env -u UNUSED pwsh -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-env-unset-rg-patterns'; command='env -u UNUSED rg -e pwsh -e powershell .'; pass=$true },
    @{ name='outer-nice-adjustment-pwsh-encoded'; command=('nice -n 5 pwsh -NoProfile -EncodedCommand ' + $encodedDelete); pass=$false },
    @{ name='outer-nice-adjustment-rg-patterns'; command='nice -n 5 rg -e pwsh -e powershell .'; pass=$true },
    @{ name='encoded-join-path-quoted-data'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Join-Path ''pwsh'' ''-EncodedCommand''')); pass=$true },
    @{ name='outer-quoted-pwsh-information-data'; command='Write-Information "pwsh"'; pass=$true },
    @{ name='outer-quoted-pwsh-call-subexpression'; command=('Write-Output "$( & ''pwsh'' -NoProfile -EncodedCommand ' + $encodedDelete + ' )"'); pass=$false },
    @{ name='outer-env-single-quoted-data'; command='Write-Output env ''pwsh -EncodedCommand example'''; pass=$true },
    @{ name='encoded-quoted-pwsh-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $quotedExecutableLiteral)); pass=$true },
    @{ name='encoded-quoted-member-assignment'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '$o.''Length''=Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-parenthesized-quoted-member-assignment'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '($o).''Length''=Remove-Item -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-quoted-member-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $quotedMemberLiteral)); pass=$true },
    @{ name='encoded-remove-item-equals-argument'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Remove-Item ''=''')); pass=$false },
    @{ name='encoded-reg-delete-equals-argument'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'reg delete ''=''')); pass=$false },
    @{ name='encoded-write-output-equals-argument'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Write-Output = Remove-Item')); pass=$true },
    @{ name='encoded-standalone-remove-item-string'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '''Remove-Item''')); pass=$true },
    @{ name='encoded-standalone-pwsh-string'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '''pwsh''')); pass=$true },
    @{ name='encoded-invoked-remove-item-string'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '& ''Remove-Item'' -LiteralPath "<FILE>"')); pass=$false },
    @{ name='encoded-equals-text-single-here'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $equalsLiteral)); pass=$true }
)
for ($index = 0; $index -lt $processStarts.Count; $index++) {
    $encodedCases += @{ name="encoded-process-start-$index"; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $processStarts[$index])); pass=$false }
}
# 共通指示の管理者起動: 静的なcmd.exeと単一引用の引数だけを、CMD本文の検査付きで通す。
$adminCli = '""' + $ExecutablePath + '" --config "' + $ConfigPath + '" registry-delete --view 64 --recursive -- HKEY_CURRENT_USER\Software\PrunletHookProbe"'
$encodedCases += @(
    @{ name='encoded-admin-cmd-prunlet-cli'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ("Start-Process -FilePath cmd.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '/d /c " + $adminCli + "'"))); pass=$true },
    @{ name='encoded-admin-cmd-body-delete'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand "Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '/d /c del ""<FILE>""'")); pass=$false },
    @{ name='encoded-admin-cmd-body-nested-shell'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand "Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '/d /c pwsh -Command Remove-Item ""<FILE>""'")); pass=$false },
    @{ name='encoded-admin-cmd-array-arguments'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand "Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '/d','/c','dir'")); pass=$false },
    @{ name='encoded-admin-cmd-expandable-arguments'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList "/d /c $body"')); pass=$false },
    # cmd.exeの解釈と検査器の解釈がずれうる形（文の分割・引用された実行名・位置引数・既定値注入）は固定形の外なので拒否する。
    @{ name='encoded-admin-cmd-ampersand-before-switch'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand "Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '& /d /c del ""<FILE>""'")); pass=$false },
    @{ name='encoded-admin-cmd-quoted-command-name'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand "Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '/d /c ""del"" ""<FILE>""'")); pass=$false },
    @{ name='encoded-admin-cmd-positional-parenthesized'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand "Start-Process cmd.exe ('/d /c del ""<FILE>""') -Verb RunAs")); pass=$false },
    @{ name='encoded-admin-cmd-default-parameter-injection'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand "`$PSDefaultParameterValues.Add('Start-Process:ArgumentList','/d /c del ""<FILE>""'); Start-Process -FilePath cmd.exe -Verb RunAs")); pass=$false },
    @{ name='encoded-admin-cmd-other-prunlet-path'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ("Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '/d /c """"D:\other\prunlet.exe"" --config """ + $ConfigPath + """ delete --paths-file D:\a.json""'"))); pass=$false },
    @{ name='encoded-admin-cmd-non-json-redirect'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ("Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '/d /c " + $adminCli.TrimEnd('"') + " > C:\Windows\System32\drivers\etc\hosts 2>&1""'"))); pass=$false },
    @{ name='encoded-admin-cmd-missing-argument-list'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'Start-Process -FilePath cmd.exe -Verb RunAs')); pass=$false },
    @{ name='encoded-admin-cmd-trailing-statement-in-body'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand ("Start-Process -FilePath cmd.exe -Verb RunAs -ArgumentList '/d /c " + $adminCli.TrimEnd('"') + " & del ""<FILE>""""'"))); pass=$false }
)
for ($index = 0; $index -lt $assignmentDeletes.Count; $index++) {
    $encodedCases += @{ name="encoded-command-$($assignmentNames[$index])"; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $assignmentDeletes[$index])); pass=$false }
}
foreach ($flag in @('-Co', '--Command', '-cOmMaNd', '-CWA')) {
    $encodedCases += @{ name="encoded-command-wrapper-$flag"; command="pwsh $flag 'pwsh -NoProfile -EncodedCommand $encodedDelete'"; pass=$false }
}
foreach ($flag in @('-cl', '-cE', '-Ec')) {
    $encodedCases += @{ name="encoded-bash-wrapper-$flag"; command="bash $flag 'pwsh -NoProfile -EncodedCommand $encodedDelete'"; pass=$false }
}
foreach ($flag in @('-e', '-ec', '-en', '-enc', '-ENCODEDCOMMAND', '--EncodedCommand', '/EncodedCommand', ([string][char]0x2013 + 'EncodedCommand'), ([string][char]0x2014 + 'EncodedCommand'), ([string][char]0x2015 + 'EncodedCommand'))) {
    $encodedCases += @{ name="encoded-flag-safe-$flag"; command="pwsh -NoProfile $flag $encodedSafe"; pass=($flag -ceq '-ENCODEDCOMMAND') }
    $encodedCases += @{ name="encoded-flag-delete-$flag"; command="pwsh -NoProfile $flag $encodedDelete"; pass=$false }
}
$nested = 'Write-Output "safe"'
for ($depth = 0; $depth -lt 10; $depth++) { $nested = 'pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand $nested) }
$encodedCases += @{ name='encoded-excessive-nesting'; command=$nested; pass=$false }
# EncodedCommand内の参照だけの`$(...)`と静的な.ps1の`-File`実行は通し、メソッド呼出し・標準入力・変数のパスは拒否する。
$encodedCases += @(
    @{ name='encoded-property-subexpression'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '$sw = [Diagnostics.Stopwatch]::StartNew(); "sec: $($sw.Elapsed.TotalSeconds)"')); pass=$true },
    @{ name='encoded-method-subexpression'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '"$((Get-Item ''<FILE>'').Delete())"')); pass=$false },
    @{ name='encoded-command-subexpression'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand '"$(Remove-Item -LiteralPath ''<FILE>'')"')); pass=$false },
    @{ name='encoded-pwsh-static-file'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'pwsh -NoProfile -File D:\example\run.ps1 -Label a')); pass=$true },
    @{ name='encoded-pwsh-stdin-file'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'pwsh -NoProfile -File -')); pass=$false },
    @{ name='encoded-pwsh-dynamic-file'; command=('pwsh -NoProfile -EncodedCommand ' + (ConvertTo-EncodedHookCommand 'pwsh -NoProfile -File $script')); pass=$false }
)
$cases += $encodedCases
# 引用終端のヒアドキュメント本文は、ファイルへのcatだけがdataとして受け取る。本文の後ろ・shellへ渡る形の削除は拒否する。
$cases += @(
    @{ name='posix-heredoc-file-sink-body'; command="cat > /d/example/loop.sh <<'EOF'`nwhile true; do echo x; done`nEOF"; pass=$true },
    @{ name='posix-heredoc-delete-after-body'; command="cat > /d/example/a.txt <<'EOF'`nx`nEOF`nrm -f `"<FILE>`""; pass=$false },
    @{ name='posix-heredoc-piped-to-shell'; command="cat <<'EOF' | sh`nrm -f `"<FILE>`"`nEOF"; pass=$false },
    @{ name='posix-loop-assignment-and-test'; command='for f in a b; do n=$(basename $f); if [ -f "$f" ]; then echo $n; fi; done 2>&1'; pass=$true }
)

$results = [Collections.Generic.List[object]]::new()
$cases += @(
    @{ name='quoted-search-ambiguous-shell'; command="rg -n 'item|rmdir|tail' sample.txt"; pass=$false },
    @{ name='quoted-search-powershell'; command="rg -n 'item|rmdir|tail' sample.txt"; shell='pwsh'; pass=$true; bashPass=$false }
)
# POSIX hookケース集（このスクリプトだけが読む）。期待値は`windowsPass ?? pass`で、Windowsでも`pass`を使う
# （`windowsPass`を持つケースは現在1件だけで、残りは`pass`がそのままWindowsの期待値になる）。非Windowsの`pass`は`hook.rs`の単体テスト
# （`hook_posix_json_cases_hold_under_the_posix_rules_alone`）と`Verify-LinuxFiles.ts`がこのJSONを読んで検証し、このスクリプトはWindows上の実プロセスだけを担う。
# 拒否期待のケースはJSONの`reason`（POSIX規則が出す検知理由と検知token）を拒否理由に含むことまで確認する。Windowsのhookは`shell`名`sh`を不明扱いにして
# 候補解釈（CMD→PowerShell→POSIX）で検査するため、先頭規則が先に拒否するケースは`windowsOtherRule`で、`reason`の照合を省き（POSIX規則単独の確認は単体テストが担う）、
# 汎用の拒否理由だけを検査する。
# 以前は専用の弱い実行器だけが読んでいたため、ここで同じ実プロセスhookへ全件流す。shellは/bin/shを明示し、期待値はwindowsPassがあればそれを優先する
# （Windows上のhookはshell不明時の解釈差でこの一部だけ結果が変わる）。Bashツールも同じ期待値で検査する。
$posixCasesPath = Join-Path $repo 'src\rust\protocol\tests\hook-posix.json'
if (![IO.File]::Exists($posixCasesPath)) { throw "POSIX hook cases not found: $posixCasesPath" }
$posixCasesSha256 = (Get-FileHash -LiteralPath $posixCasesPath -Algorithm SHA256).Hash
$posixCases = @([IO.File]::ReadAllText($posixCasesPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
if ($posixCases.Count -eq 0) { throw 'POSIX hook cases are empty.' }
$existingNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($case in $cases) { [void]$existingNames.Add([string]$case.name) }
$posixNames = [Collections.Generic.List[string]]::new()
foreach ($item in $posixCases) {
    if ([string]::IsNullOrEmpty($item.name) -or $null -eq $item.command -or $null -eq $item.pass) { throw "Invalid POSIX hook case: $($item | ConvertTo-Json -Compress)" }
    $caseName = 'hook-posix/' + $item.name
    if (!$existingNames.Add($caseName)) { throw "Duplicate hook case name: $caseName" }
    $expectedPosix = [bool]$item.pass
    if ($null -ne $item.windowsPass) { $expectedPosix = [bool]$item.windowsPass }
    $posixCase = @{ name=$caseName; command=[string]$item.command; shell='/bin/sh'; pass=$expectedPosix; bashPass=$expectedPosix }
    # `windowsPass`だけで拒否になるケース（POSIXでは通過）は、POSIX規則の拒否理由を持たない。
    if (!$expectedPosix -and !$item.pass) {
        # 拒否期待は`reason`を必須にする（検知理由を問わず合格になる状態を許さない）。
        if (!$item.windowsOtherRule) {
            if ([string]::IsNullOrEmpty($item.reason)) { throw "Denied POSIX hook case needs a reason: $($item.name)" }
            $posixCase.reason = [string]$item.reason
        }
    }
    $cases += $posixCase
    $posixNames.Add($caseName)
}

foreach ($case in $cases) {
    foreach ($tool in @('Bash', 'exec_command', 'functions.exec_command')) {
        $inputObject = @{ cwd = $OutputDirectory }
        $inputObject[$(if ($tool -eq 'Bash') { 'command' } else { 'cmd' })] = $case.command.Replace('<FILE>', $fixture)
        if ($case.ContainsKey('shell')) { $inputObject.shell = $case.shell }
        $event = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $inputObject }
        $json = $event | ConvertTo-Json -Depth 8 -Compress
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $ExecutablePath
        $start.ArgumentList.Add('--config')
        $start.ArgumentList.Add($ConfigPath)
        $start.ArgumentList.Add('hook')
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::Start($start)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($json)
        $process.StandardInput.Close()
        # 時間切れはreportを残さず中断せず、そのケースの失敗として記録して全ケース完了後に非0で終了する。
        $timedOut = $false
        if (!$process.WaitForExit(30000)) { $process.Kill($true); $process.WaitForExit(); $timedOut = $true }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $decision = if ($timedOut) { 'timeout' } else { 'invalid' }
        if (!$timedOut) { try {
            $parsed = $stdout | ConvertFrom-Json
            if ($stdout.Trim() -ceq '{}') { $decision = 'pass' }
            elseif ($parsed.hookSpecificOutput.permissionDecision -ceq 'deny' -and !$parsed.hookSpecificOutput.updatedInput -and $parsed.hookSpecificOutput.permissionDecisionReason -match '(?i)prunlet') { $decision = 'deny' }
        } catch { } }
        $fixtureUnchanged = [IO.File]::Exists($fixture) -and (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash -ceq $fixtureHash
        $expectedPass = if ($tool -eq 'Bash' -and $case.ContainsKey('bashPass')) { $case.bashPass } else { $case.pass }
        $expected = if ($expectedPass) { 'pass' } else { 'deny' }
        $reasonValid = $true
        if ($decision -eq 'deny') {
            $reason = $parsed.hookSpecificOutput.permissionDecisionReason
            $reasonValid = $reason -notmatch '^Direct shell deletion is blocked' -and ($reason -match 'detected token .+; interpretation=' -or $reason -match 'could not inspect the hook input: .+')
            if ($case.name -eq 'file-remove-item') { $reasonValid = $reasonValid -and $reason.Contains('detected token "Remove-Item"') }
            if ($case.name -eq 'registry-delete') { $reasonValid = $reasonValid -and $reason.Contains('registry deletion command') -and $reason.Contains('"reg delete"') }
            if ($case.name -in @('quoted-search-ambiguous-shell','ssh-quoted-path-unknown-shell')) { $reasonValid = $reasonValid -and $reason.Contains('Shell metadata is missing or unsupported') -and $reason.Contains('interpretation=CMD') }
            # 回帰ケースが期待する拒否理由（検知命令・検査不能の原因）を含むこと。
            if ($case.ContainsKey('reason')) { $reasonValid = $reasonValid -and $reason.Contains($case.reason) }
            # 単独EncodedCommandを復号して確定検出した場合は、候補注記と変換案内を付けない。
            if ($case.name -in @('encoded-delete-before-here','encoded-japanese-delete','encoded-registry-after-here') -and !$case.ContainsKey('shell')) { $reasonValid = $reasonValid -and !$reason.Contains('candidate interpretation') -and $reason.Contains('interpretation=PowerShell') }
            # 単独形式でない呼出しは、shell不明時に従来どおり候補注記を付ける。
            if ($case.name -eq 'encoded-flag-delete--e' -and !$case.ContainsKey('shell')) { $reasonValid = $reasonValid -and $reason.Contains('candidate interpretation') }
        }
        $results.Add([pscustomobject]@{ name=$case.name; tool=$tool; input=$event; inputJson=$json; expected=$expected; decision=$decision; exitCode=$process.ExitCode; timedOut=$timedOut; stdout=$stdout; stderr=$stderr; fixtureUnchanged=$fixtureUnchanged; reasonValid=$reasonValid; passed=(!$timedOut -and $process.ExitCode -eq 0 -and $decision -ceq $expected -and $fixtureUnchanged -and $reasonValid) })
        $process.Dispose()
    }
}
$failed = @($results | Where-Object { !$_.passed })
$report = [ordered]@{ executable=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash; configPath=$ConfigPath; runner=$PSCommandPath; runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash; fixture=$fixture; fixtureSha256=$fixtureHash; posixCasesPath=$posixCasesPath; posixCasesSha256=$posixCasesSha256; posixCaseCount=$posixNames.Count; posixCaseNames=@($posixNames); passed=$results.Count-$failed.Count; failed=$failed.Count; results=@($results) }
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
Write-Output "passed=$($report.passed) failed=$($report.failed) report=$ReportPath"
foreach ($result in $failed) { Write-Output "FAIL $($result.name) $($result.tool): expected=$($result.expected) actual=$($result.decision) exit=$($result.exitCode) fixtureUnchanged=$($result.fixtureUnchanged)" }
if ($failed.Count) { exit 1 }
