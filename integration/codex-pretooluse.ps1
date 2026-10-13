param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
function Reply-Deny([string]$Reason) {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Depth 20 -Compress
}
function Quote-PS([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
function Is-Absolute([string]$Value) { $Value -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+(?:\\|$))' }
function Is-DeleteName([string]$Name) { $Name -match '^(?i:Remove-Item|Microsoft\.PowerShell\.Management\\Remove-Item|ri|rm|rmdir|rd|del|erase)$' }
function Read-Literals($Node) {
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return ,@($Node.Value) }
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $values = @()
        foreach ($element in $Node.Elements) {
            if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { throw '配列には定数文字列だけを指定してください。' }
            $values += $element.Value
        }
        return ,$values
    }
    throw '-LiteralPathには定数文字列または定数文字列の配列だけを指定してください。'
}
try {
    $inputObject = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    if ($inputObject -isnot [System.Collections.IDictionary]) { throw 'hook入力がJSONオブジェクトではありません。' }
    if ($inputObject.tool_name -notin @('Bash', 'exec_command', 'functions.exec_command')) { '{}'; exit 0 }
    $toolInput = $inputObject.tool_input
    if ($toolInput -isnot [System.Collections.IDictionary]) { throw 'shell入力がJSONオブジェクトではありません。' }
    $field = if ($toolInput.Contains('command')) { 'command' } elseif ($toolInput.Contains('cmd')) { 'cmd' } else { throw 'shell command/cmdがありません。' }
    if ($toolInput[$field] -isnot [string]) { throw 'shell command/cmdが文字列ではありません。' }
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($toolInput[$field], [ref]$tokens, [ref]$parseErrors)
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $deletes = @($commands | Where-Object { Is-DeleteName $_.GetCommandName() })
    # 文字列で包まれた代表的なshell呼出しも、直接削除名が読み取れる場合は拒否する。
    foreach ($command in $commands) {
        $commandName = $command.GetCommandName()
        if ($commandName -and [IO.Path]::GetFileName($commandName) -match '^(?i:cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh(?:\.exe)?)$') {
            foreach ($element in @($command.CommandElements | Select-Object -Skip 1)) {
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $inner = [System.Management.Automation.Language.Parser]::ParseInput($element.Value, [ref]$null, [ref]$null)
                    if ($inner.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and (Is-DeleteName $node.GetCommandName()) }, $true)) {
                        throw 'shell wrapper内の削除は置換できません。単独のRemove-Item -LiteralPathまたはPrunlet CLIを使用してください。'
                    }
                }
            }
        }
    }
    if (!$deletes.Count) { '{}'; exit 0 }
    if ($parseErrors.Count) { throw '削除を含むPowerShell構文を解析できないため実行を止めました。' }
    if ($ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock -or $ast.ParamBlock -or $ast.EndBlock.Statements.Count -ne 1 -or $commands.Count -ne 1) { throw '削除を含む複数文・式・関数は置換できません。単独のRemove-Item -LiteralPathを使用してください。' }
    $statement = $ast.EndBlock.Statements[0]
    if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1 -or $statement.Background) { throw '削除のパイプ・式・バックグラウンド実行は置換できません。' }
    $delete = $deletes[0]
    if ($statement.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandAst] -or ![object]::ReferenceEquals($statement.PipelineElements[0], $delete)) { throw '削除を含む式や未実行のscriptblockは置換できません。単独のRemove-Item -LiteralPathを使用してください。' }
    if ($delete.Redirections.Count -or $delete.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown) { throw '削除のリダイレクト・呼出し演算子は置換できません。' }
    $paths = @(); $literalSeen = $false; $dryRun = $false
    for ($i = 1; $i -lt $delete.CommandElements.Count; $i++) {
        $element = $delete.CommandElements[$i]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or $element.Argument) { throw '削除には-LiteralPathと対応する限定オプションだけを使用してください。' }
        switch ($element.ParameterName.ToLowerInvariant()) {
            'literalpath' {
                if ($literalSeen -or (++$i) -ge $delete.CommandElements.Count) { throw '-LiteralPathを一度指定してください。' }
                $literalSeen = $true; $paths = Read-Literals $delete.CommandElements[$i]
            }
            'force' { }
            'whatif' { $dryRun = $true }
            'erroraction' {
                if ((++$i) -ge $delete.CommandElements.Count -or $delete.CommandElements[$i] -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $delete.CommandElements[$i].Value -ine 'Stop') { throw '-ErrorActionはStopだけに対応しています。' }
            }
            default { throw ('対応しない削除オプション: -' + $element.ParameterName + '。-Recurse/-Pathは使用せず、Prunlet CLIで対象を明示してください。') }
        }
    }
    if (!$literalSeen -or !$paths.Count) { throw '削除対象の-LiteralPathがありません。' }
    foreach ($path in $paths) { if (!(Is-Absolute $path) -or $path -match '[*?]') { throw '削除対象は*や?を含まない絶対パスにしてください。' } }
    if (!(Is-Absolute $ExecutablePath) -or !(Is-Absolute $ConfigPath) -or !(Test-Path -LiteralPath $ExecutablePath -PathType Leaf) -or !(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'Prunlet exe/configの絶対パスまたは実在を確認できません。' }
    $replacement = '& ' + (Quote-PS $ExecutablePath) + ' --config ' + (Quote-PS $ConfigPath) + ' delete' + $(if ($dryRun) { ' --dry-run' } else { '' }) + ' -- ' + (($paths | ForEach-Object { Quote-PS $_ }) -join ' ')
    $updated = @{}; foreach ($key in $toolInput.Keys) { $updated[$key] = $toolInput[$key] }; $updated[$field] = $replacement
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'allow'; updatedInput = $updated } } | ConvertTo-Json -Depth 50 -Compress
} catch {
    [Console]::Error.WriteLine('Prunlet hook: ' + $_.Exception.Message)
    Reply-Deny ('Prunlet: ' + $_.Exception.Message)
}
