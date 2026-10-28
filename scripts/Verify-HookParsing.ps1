param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$ConfigPath = 'C:\Users\IMT\.local\Prunlet\config.json'
)

$ErrorActionPreference = 'Stop'
foreach ($path in @($ExecutablePath, $OutputDirectory, $ReportPath, $ConfigPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw "Absolute path required: $path" }
}
$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
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
    @{ name='ordinary-non-delete'; command='Write-Output "hello"'; shell='pwsh'; pass=$true },
    @{ name='registry-delete'; command='reg.exe delete HKCU\Software\PrunletHookProbe /f'; pass=$false },
    @{ name='registry-pwsh-wrapper'; command='pwsh -Command "Remove-Item HKCU:\Software\PrunletHookProbe"'; pass=$false },
    @{ name='registry-cmd-wrapper'; command='cmd.exe /d /c reg.exe delete HKCU\Software\PrunletHookProbe /f'; pass=$false },
    @{ name='file-remove-item'; command='Remove-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='powershell-escape'; command='Remove`-Item -LiteralPath "<FILE>"'; shell='pwsh'; pass=$false },
    @{ name='cmd-escape'; command='d^el "<FILE>"'; shell='cmd.exe'; pass=$false },
    @{ name='posix-escape'; command='r\m -- "<FILE>"'; shell='bash'; pass=$false }
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
$cases += $encodedCases

$results = [Collections.Generic.List[object]]::new()
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
        if (!$process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw "Hook timed out: $($case.name) / $tool" }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $decision = 'invalid'
        try {
            $parsed = $stdout | ConvertFrom-Json
            if ($stdout.Trim() -ceq '{}') { $decision = 'pass' }
            elseif ($parsed.hookSpecificOutput.permissionDecision -ceq 'deny' -and !$parsed.hookSpecificOutput.updatedInput -and $parsed.hookSpecificOutput.permissionDecisionReason -match '(?i)prunlet') { $decision = 'deny' }
        } catch { }
        $fixtureUnchanged = [IO.File]::Exists($fixture) -and (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash -ceq $fixtureHash
        $expectedPass = if ($tool -eq 'Bash' -and $case.ContainsKey('bashPass')) { $case.bashPass } else { $case.pass }
        $expected = if ($expectedPass) { 'pass' } else { 'deny' }
        $results.Add([pscustomobject]@{ name=$case.name; tool=$tool; input=$event; inputJson=$json; expected=$expected; decision=$decision; exitCode=$process.ExitCode; stdout=$stdout; stderr=$stderr; fixtureUnchanged=$fixtureUnchanged; passed=($process.ExitCode -eq 0 -and $decision -ceq $expected -and $fixtureUnchanged) })
        $process.Dispose()
    }
}
$failed = @($results | Where-Object { !$_.passed })
$report = [ordered]@{ executable=$ExecutablePath; executableSha256=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash; configPath=$ConfigPath; runner=$PSCommandPath; runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash; fixture=$fixture; fixtureSha256=$fixtureHash; passed=$results.Count-$failed.Count; failed=$failed.Count; results=@($results) }
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
Write-Output "passed=$($report.passed) failed=$($report.failed) report=$ReportPath"
foreach ($result in $failed) { Write-Output "FAIL $($result.name) $($result.tool): expected=$($result.expected) actual=$($result.decision) exit=$($result.exitCode) fixtureUnchanged=$($result.fixtureUnchanged)" }
if ($failed.Count) { exit 1 }
