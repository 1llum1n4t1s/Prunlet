param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    # 任意。隔離したCodexHomeへ登録した導入だけが明示する。省略時は実効のCodexHome（CODEX_HOME、
    # なければ%USERPROFILE%\.codex）を読取り専用で調べ、Prunletの登録が残っている場合だけ保護・更新する。
    [string]$CodexHome = '',
    # 更新タスク（maintenance-task.ps1のRegister-PrunletUpdateTask）からの起動。MCPは起動せず、
    # 起動時更新と同じ確認・切替だけを行って終わる。Codexを使わないPCでも最新版へ追従させるため。
    [switch]$UpdateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:StartupUpdateReady = $true

. (Join-Path $PSScriptRoot 'configuration-common.ps1')
# job handleをPowerShellプロセスの終了まで保持し、入口終了時に子も終了させる。
function Start-PrunletMcpJob {
    if ([IntPtr]::Size -ne 8) { throw 'Prunlet MCP requires a 64-bit process.' }
    $create = New-PrunletNativeDelegate kernel32.dll CreateJobObjectW ([IntPtr]) @([IntPtr], [string])
    $set = New-PrunletNativeDelegate kernel32.dll SetInformationJobObject ([int]) @([IntPtr], [int], [IntPtr], [uint32])
    $assign = New-PrunletNativeDelegate kernel32.dll AssignProcessToJobObject ([int]) @([IntPtr], [IntPtr])
    $current = New-PrunletNativeDelegate kernel32.dll GetCurrentProcess ([IntPtr]) @()
    $close = New-PrunletNativeDelegate kernel32.dll CloseHandle ([int]) @([IntPtr])
    $name = 'Local\Prunlet.McpLauncher.' + [guid]::NewGuid().ToString('N')
    $job = $create.Invoke([IntPtr]::Zero, $name)
    $createError = [Runtime.InteropServices.Marshal]::GetLastPInvokeError()
    if ($job -eq [IntPtr]::Zero) { throw [ComponentModel.Win32Exception]::new($createError) }
    $limits = [Runtime.InteropServices.Marshal]::AllocHGlobal(144)
    try {
        if ($createError -eq 183) { throw 'Prunlet MCP launcher job name already exists.' }
        [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(144), 0, $limits, 144)
        # 通常の子は終了時に停止する。明示キューworkerだけが作成時に離脱を指定する。
        [Runtime.InteropServices.Marshal]::WriteInt32($limits, 16, (0x2000 -bor 0x0800)) # KILL_ON_JOB_CLOSE | BREAKAWAY_OK
        if (!$set.Invoke($job, 9, $limits, 144)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
        if (!$assign.Invoke($job, $current.Invoke())) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
        $script:PrunletMcpJobHandle = $job
        $script:PrunletMcpJobName = $name
        $job = [IntPtr]::Zero
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($limits)
        if ($job -ne [IntPtr]::Zero) { [void]$close.Invoke($job) }
    }
}

# CLIは失敗時に標準出力へ{"error":...}を書く。その本文を返す（JSONでなければ空）。
# 延期のメッセージへ本文を含め、恒久的な拒否と一時的な延期を利用者が区別できるようにする。
function Get-CliFailureDetail($Output) {
    try {
        $parsed = ($Output | Out-String | ConvertFrom-Json -AsHashtable)
        if ($parsed -is [hashtable] -and $parsed.ContainsKey('error') -and $parsed.error) { return ' ' + [string]$parsed.error }
    } catch { }
    return ''
}

function Read-StartupState([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return @{ product = 'Prunlet'; schema = 1; phase = 'idle' } }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Startup update state is not an ordinary file.' }
    $state = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    if ($state.product -cne 'Prunlet' -or $state.schema -ne 1 -or !$state.ContainsKey('epoch') -or $state.epoch -ne 1 -or $state.phase -notin @('idle', 'switching', 'migrating', 'cleanup')) { throw 'Startup update state is invalid or incomplete.' }
    return $state
}

function Test-CodexRegistrationPresent([string]$Codex) {
    # 起動ごとにCodexHomeの実物から判定する（タスク引数のスイッチにすると、後でCodexへ登録したとき保護を素通りする）。
    # Prunletの痕跡（所有block・hook handler・共通指示）が一つでもあれば、部分的でも従来の登録保護を通す。
    # MCP起動・更新タスクのどちらでも実物の目印で判定する。PrunletはCodexに依存しない単独のアプリで、
    # Toolportなど他のMCPホストからも起動されるため、「MCP起動ならCodex登録あり」とはみなさない。
    # 判定は読取りだけで、登録がなければ~/.codexへは触れない。
    if (!$Codex -or !(Test-Path -LiteralPath $Codex)) { return $false }
    $markers = @{
        'config.toml' = @('# BEGIN PRUNLET MCP', '# BEGIN PRUNLET HOOK-FEATURE')
        'hooks.json' = @('prunlet-hook.exe', 'Prunlet')
        'AGENTS.md' = @('BEGIN PRUNLET AGENT-INSTRUCTIONS')
        'PRUNLET.md' = @('')
    }
    foreach ($name in $markers.Keys) {
        $path = Join-Path $Codex $name
        if (!(Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        # 通常ファイルでない登録先は判定できないため、登録ありとして従来の保護（停止）へ回す。
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $true }
        if ($name -ceq 'PRUNLET.md') { return $true }
        $text = [IO.File]::ReadAllText($path)
        foreach ($marker in $markers[$name]) { if ($text.Contains($marker, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    }
    return $false
}

# 起動時更新で更新タスクを移行するときは、既存タスクの-CodexHomeを引き継ぐ（起動元のMCPホストで変えない）。
# 読み込んだmaintenance-task.ps1が旧版で引数を持たない場合は、従来どおり何も付けない。
function Get-UpdateTaskPreserveSwitch {
    $command = Get-Command Get-PrunletUpdateTaskState -CommandType Function -ErrorAction SilentlyContinue
    if ($command -and $command.Parameters.ContainsKey('PreserveCodexHome')) { return @{ PreserveCodexHome = $true } }
    return @{}
}

function Test-ProductsIdle([string]$Executable) {
    $handles = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        foreach ($path in @($Executable, (Join-Path ([IO.Path]::GetDirectoryName($Executable)) 'prunlet-maintenance.exe'))) {
            $handles.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete)))
        }
        return $true
    } catch [IO.IOException] { return $false }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
}


# 配布物の実行ファイルの署名者。scripts/Install-Prunlet.ps1・Signing.Common.ps1と同じ値で、launcher単体でも照合できるよう直接持つ。
$script:PackageSignerCommonName = 'Open Source Developer Yuichiro Shinozaki'

# 実行ファイルの版リソース（ProductVersion = "<x.y.z>+<40桁commit>"、build.rsが埋め込む）を読む。
# 導入済みの版はこの値を正とし（source-info.jsonには版を持たない）、commit部で取得元情報との対応を確かめる。
function Read-PrunletProductVersion([string]$Path) {
    $value = [string][Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductVersion
    if ($value -cnotmatch '\A((?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8}))\+([0-9a-f]{40})\z') { throw 'A Prunlet executable has no release product version.' }
    return @{ text = $value; versionText = $Matches[1]; version = [version]$Matches[1]; commit = $Matches[2] }
}

function Invoke-CandidateProbe([string]$Executable, [string[]]$Arguments, [int]$ExpectedExit) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'Candidate executable did not start.' }
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) { $process.Kill($true); $process.WaitForExit(); throw 'Candidate startup probe timed out.' }
        if ($process.ExitCode -ne $ExpectedExit) { throw 'Candidate executable did not return the expected startup result.' }
        $null = $errorOutput.GetAwaiter().GetResult()
        return $output.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}

# 候補のstageにある3つの実行ファイルを、実行する前にAuthenticodeで検査する（Valid・署名者CN・タイムスタンプあり）。
# マニフェストの鍵の採否と無関係に必ず行う二重の確認で、新規の切替でも中断からの再開でも同じ条件にする。
# 照合はGet-AuthenticodeSignatureだけで行う（検証スクリプトは未署名のfixtureに対し、このcmdletの結果だけを置換する）。
function Assert-CandidateSignatures([string]$Stage) {
    foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
        $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $Stage $name)
        $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '' }
        if ($signature.Status -ne 'Valid' -or $signer -cne $script:PackageSignerCommonName -or !$signature.TimeStamperCertificate) { throw "Candidate executable is not signed by the Prunlet publisher: $name" }
    }
}

# 新規の切替では、候補の3つの実行ファイルの版リソースが、署名済みマニフェストの "<version>+<commit>" と一致することを求める。
# 中断からの再開ではマニフェストを持たないため呼ばない（再開は記録済みの候補commitとhashの照合で続ける）。
function Assert-CandidateProductVersion([string]$Stage, [string]$Expected) {
    foreach ($name in @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')) {
        $actual = Read-PrunletProductVersion (Join-Path $Stage $name)
        if ($actual.text -cne $Expected) { throw "Candidate executable version does not match the published manifest: $name" }
    }
}

function Test-CandidateExecutables([string]$Stage) {
    $protocol = (Invoke-CandidateProbe (Join-Path $Stage 'prunlet.exe') @('--startup-update-protocol') 0) | ConvertFrom-Json -AsHashtable
    if ($protocol.protocol -ne 1 -or $protocol.storageEpoch -ne 1) { throw 'Published candidate has an incompatible update or storage protocol.' }
    $null = Invoke-CandidateProbe (Join-Path $Stage 'prunlet-maintenance.exe') @('--help') 2
    $hook = (Invoke-CandidateProbe (Join-Path $Stage 'prunlet-hook.exe') @('--help') 0) | ConvertFrom-Json -AsHashtable
    if ($hook.hookSpecificOutput.permissionDecision -cne 'deny') { throw 'Published hook did not return a fail-closed response.' }
}

function Open-CandidateGuards([string]$Stage, [string]$StatePath) {
    $guards = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        $stageFull = [IO.Path]::GetFullPath($Stage)
        $state = Read-StartupState $StatePath
        $files = [ordered]@{
            'prunlet.exe' = 'executableSha256'
            'prunlet-maintenance.exe' = 'maintenanceExecutableSha256'
            'prunlet-hook.exe' = 'hookExecutableSha256'
        }
        $auxiliary = [ordered]@{
            'scripts\Install-Prunlet.ps1' = 'bin\Install-Prunlet.ps1'
            'integration\start-prunlet-mcp.ps1' = 'bin\start-prunlet-mcp.ps1'
            'integration\configuration-common.ps1' = 'bin\configuration-common.ps1'
            'integration\maintenance-task.ps1' = 'bin\maintenance-task.ps1'
            'integration\uninstall-maintenance.ps1' = 'bin\uninstall-maintenance.ps1'
            'integration\install-codex.ps1' = 'bin\install-codex.ps1'
            'integration\uninstall-codex.ps1' = 'bin\uninstall-codex.ps1'
            'integration\install-agent-instructions.ps1' = 'bin\install-agent-instructions.ps1'
            'integration\PRUNLET.md' = 'bin\PRUNLET.md'
        }
        $relativeNames = @('source-info.json', '.prunlet-stage-owner.json') + @($files.Keys) + @($auxiliary.Keys)
        foreach ($relative in $relativeNames) {
            $path = [IO.Path]::GetFullPath((Join-Path $stageFull $relative))
            if (!$path.StartsWith($stageFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate path escaped its stage.' }
            $cursor = $path
            while ($cursor -and $cursor.StartsWith($stageFull, [StringComparison]::OrdinalIgnoreCase)) {
                $item = Get-Item -LiteralPath $cursor -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Candidate paths cannot traverse links.' }
                if ($cursor.Equals($stageFull, [StringComparison]::OrdinalIgnoreCase)) { break }
                $cursor = [IO.Path]::GetDirectoryName($cursor)
            }
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer) { throw 'A candidate product is not a file.' }
            $guards.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        $infoGuard = $guards[0]
        $reader = [IO.StreamReader]::new($infoGuard, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { $info = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
        if (!$state.ContainsKey('candidateCommit') -or $info.commitSha -ine $state.candidateCommit) { throw 'Candidate commit does not match the update state.' }
        if ($state.ContainsKey('candidateSourceInfoSha256') -and $state.candidateSourceInfoSha256) {
            $infoGuard.Position = 0
            if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($infoGuard)) -ine $state.candidateSourceInfoSha256) { throw 'Candidate provenance changed.' }
        }
        $ownerReader = [IO.StreamReader]::new($guards[1], [Text.Encoding]::UTF8, $true, 4096, $true)
        try { $owner = $ownerReader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $ownerReader.Dispose() }
        if ($owner.product -cne 'Prunlet' -or $owner.schema -ne 1 -or $owner.epoch -ne 1 -or $owner.candidateCommit -ine $state.candidateCommit -or $owner.installRoot -ine [IO.Path]::GetDirectoryName($stageFull)) { throw 'Candidate stage ownership is invalid.' }
        $index = 2
        foreach ($relative in $files.Keys) {
            $expected = [string]$info[$files[$relative]]
            if ($expected -cnotmatch '^[A-Fa-f0-9]{64}$' -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($guards[$index])) -ine $expected) { throw "Candidate product changed: $relative" }
            $index++
        }
        foreach ($relative in $auxiliary.Keys) {
            $expected = [string]$info.auxiliarySha256[$auxiliary[$relative]]
            if ($expected -cnotmatch '^[A-Fa-f0-9]{64}$' -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($guards[$index])) -ine $expected) { throw "Candidate integration changed: $relative" }
            $index++
        }
        return ,$guards
    } catch {
        foreach ($guard in $guards) { $guard.Dispose() }
        throw
    }
}

function Open-RegistrationGuards([string]$Executable, [string]$Config, [string]$Codex, [string]$Stage) {
    $guards = [Collections.Generic.List[IO.FileStream]]::new()
    $bin = [IO.Path]::GetDirectoryName($Executable)
    $root = [IO.Path]::GetDirectoryName($bin)
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
    $global = [Threading.Mutex]::new($false, ('Global\Prunlet-Install-' + $key))
    $local = [Threading.Mutex]::new($false, ('Local\Prunlet-Install-' + $key))
    $ownsGlobal = $false; $ownsLocal = $false
    try {
        try { $ownsGlobal = $global.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsGlobal = $true }
        if (!$ownsGlobal) { throw 'Another Prunlet installation is running.' }
        try { $ownsLocal = $local.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsLocal = $true }
        if (!$ownsLocal) { throw 'Another Prunlet installation is running.' }
        # Codexへ登録していないPC（更新タスクだけで追従する）には、守るべき登録がない。
        if (!(Test-CodexRegistrationPresent $Codex)) { return ,$guards }
        foreach ($name in @('hooks.json', 'config.toml', 'AGENTS.md', 'PRUNLET.md')) {
            $path = Join-Path $Codex $name
            if ($name -in @('AGENTS.md', 'PRUNLET.md') -and !(Test-Path -LiteralPath $path)) { continue }
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Codex registration is not an ordinary file.' }
            $guards.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        # ValidateOnlyは保存しないため、導入先の外にある検証用の名前だけを指定する。
        $validationBackup = Join-Path ([IO.Path]::GetTempPath()) 'Prunlet-Registration-Validation'
        $registration = @{ ExecutablePath = $Executable; ConfigPath = $Config; CodexHome = $Codex; BackupDirectory = $validationBackup }
        $preview = & (Join-Path $bin 'install-codex.ps1') @registration -ValidateOnly
        if ($preview.hookChanged -or $preview.mcpChanged) { throw 'Codex registration changed and requires review; its settings were preserved.' }
        return ,$guards
    } catch {
        foreach ($guard in $guards) { $guard.Dispose() }
        throw
    } finally {
        if ($ownsLocal) { $local.ReleaseMutex() }
        if ($ownsGlobal) { $global.ReleaseMutex() }
        $local.Dispose(); $global.Dispose()
    }
}

function Invoke-Integration([string]$Candidate, [string]$Stage, [string]$Config, [string]$Codex, [string]$Executable) {
    $applied = & $Candidate --config $Config __apply-startup-integration
    if ($LASTEXITCODE -ne 0 -or ($applied | ConvertFrom-Json -AsHashtable).status -cne 'integration_applied') { throw 'Prunlet auxiliary products were not updated.' }
    $bin = [IO.Path]::GetDirectoryName($Executable)
    $backup = Join-Path $Stage 'registration-backup'
    if (!(Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup | Out-Null }
    $root = [IO.Path]::GetDirectoryName($bin)
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
    $global = [Threading.Mutex]::new($false, ('Global\Prunlet-Install-' + $key))
    $local = [Threading.Mutex]::new($false, ('Local\Prunlet-Install-' + $key))
    $ownsGlobal = $false; $ownsLocal = $false; $guards = $null
    try {
        try { $ownsGlobal = $global.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsGlobal = $true }
        if (!$ownsGlobal) { throw 'Another Prunlet installation is running.' }
        try { $ownsLocal = $local.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsLocal = $true }
        if (!$ownsLocal) { throw 'Another Prunlet installation is running.' }
        $guards = Open-RegistrationGuards $Executable $Config $Codex $Stage
        if (Test-CodexRegistrationPresent $Codex) {
            $oldInfo = [IO.File]::ReadAllText((Join-Path $Stage 'previous-source-info.json')) | ConvertFrom-Json -AsHashtable
            $oldGuideHash = [string]$oldInfo.auxiliarySha256['bin\PRUNLET.md']
            $agent = @{
                SourceGuidePath = (Join-Path $Stage 'integration\PRUNLET.md')
                PreviousGuideSha256 = $oldGuideHash
                ExecutablePath = $Executable
                ConfigPath = $Config
                CodexHome = $Codex
                BackupDirectory = $backup
                StartupUpdate = $true
            }
            $agentHelper = Join-Path $bin 'install-agent-instructions.ps1'
            $agentState = & $agentHelper @agent -ValidateOnly
            if (!$agentState.ContainsKey('instructionsPresent') -or !$agentState.ContainsKey('agentChanged') -or !$agentState.ContainsKey('guideChanged')) { throw 'Agent instruction validation is incompatible.' }
            if ($agentState.instructionsPresent -and ($agentState.agentChanged -or $agentState.guideChanged)) {
                throw 'Agent instructions require an update; concurrent edits must be preserved.'
            }
        }
        # 所有タスクの設定を維持し、更新途中でも元のXMLを確認できるようにする。
        . (Join-Path $bin 'maintenance-task.ps1')
        $maintenance = Get-PrunletMaintenanceState $Executable $Config
        if ($maintenance.previousXml) {
            $taskBackup = Join-Path $backup 'maintenance-task.xml'
            if (!(Test-Path -LiteralPath $taskBackup)) {
                $xmlBytes = [Text.Encoding]::Unicode.GetBytes($maintenance.previousXml)
                $budget = & $Candidate --config $Config __check-startup-budget ($xmlBytes.Length + [Text.Encoding]::Unicode.GetPreamble().Length)
                if ($LASTEXITCODE -ne 0 -or ($budget | ConvertFrom-Json -AsHashtable).status -cne 'available') { throw 'Maintenance task backup would exceed the update storage budget.' }
                $output = [IO.File]::Open($taskBackup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $output.Write([Text.Encoding]::Unicode.GetPreamble()); $output.Write($xmlBytes); $output.Flush($true) }
                finally { $output.Dispose() }
            }
            Register-PrunletMaintenanceTask $maintenance
        }
        # 更新タスクは導入時だけ作る。自動更新では所有済みの既存タスクの実行先だけを移行し、新規には作らない。
        # 更新後のmaintenance-task.ps1が関数を持たない（旧版へ戻した配布物）場合は触れない。
        if (Get-Command Get-PrunletUpdateTaskState -CommandType Function -ErrorAction SilentlyContinue) {
            $preserve = Get-UpdateTaskPreserveSwitch
            $updateTask = Get-PrunletUpdateTaskState $Executable $Config $Codex @preserve
            if ($updateTask.previousXml) {
                $updateBackup = Join-Path $backup 'update-task.xml'
                if (!(Test-Path -LiteralPath $updateBackup)) {
                    $xmlBytes = [Text.Encoding]::Unicode.GetBytes($updateTask.previousXml)
                    $budget = & $Candidate --config $Config __check-startup-budget ($xmlBytes.Length + [Text.Encoding]::Unicode.GetPreamble().Length)
                    if ($LASTEXITCODE -ne 0 -or ($budget | ConvertFrom-Json -AsHashtable).status -cne 'available') { throw 'Update task backup would exceed the update storage budget.' }
                    $output = [IO.File]::Open($updateBackup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $output.Write([Text.Encoding]::Unicode.GetPreamble()); $output.Write($xmlBytes); $output.Flush($true) }
                    finally { $output.Dispose() }
                }
                Register-PrunletUpdateTask $updateTask
            }
        }
        # coordinatorが同じmutexを取得できるよう、登録の確定後に解放する。
        $local.ReleaseMutex(); $ownsLocal = $false
        $global.ReleaseMutex(); $ownsGlobal = $false
        $confirmed = & $Candidate --config $Config __confirm-startup-integration
        if ($LASTEXITCODE -ne 0 -or ($confirmed | ConvertFrom-Json -AsHashtable).status -cne 'integration_confirmed') { throw 'Prunlet integration could not be confirmed.' }
    } finally {
        if ($guards) { foreach ($guard in $guards) { $guard.Dispose() } }
        if ($ownsLocal) { $local.ReleaseMutex() }
        if ($ownsGlobal) { $global.ReleaseMutex() }
        $local.Dispose(); $global.Dispose()
    }
}

# 署名付きマニフェストの検証はRust（src/rust/update/manifest.rs）の1か所に集め、launcherはその内部コマンドのJSON出力だけで
# 延期・更新を決める（信頼の基点をRustとPowerShellへ二重に持たない）。コマンドは導入済みexeで --config の後に置く。
#   __check-release-manifest <runtime>: R2の latest/<runtime>.json を取得・署名検証し、実行中exeの版より新しいかを返す。
#   __download-release-package <runtime> <version> <commit>: 版付きマニフェストを再検証し、R2の不変URLからリダイレクトなしで
#     取得して長さとSHA-256を照合する（stateへの書込み・容量・ADSの検査もRust側）。
#   __prepare-release-package <runtime> <version> <commit>: 版付きマニフェストを再検証し、署名済みの値で候補を準備する。
# 失敗は終了コード1で、呼出し元は更新状態がidleなら延期して現在版を起動する（fail-closed）。
function Invoke-ReleaseCommand([string]$Executable, [string]$Config, [string]$Failure, [string[]]$Arguments) {
    $output = & $Executable --config $Config @Arguments
    if ($LASTEXITCODE -ne 0) { throw ($Failure + (Get-CliFailureDetail $output)) }
    try { $parsed = $output | Out-String | ConvertFrom-Json -AsHashtable } catch { throw $Failure }
    if ($parsed -isnot [hashtable]) { throw $Failure }
    if ($parsed.ContainsKey('warnings')) { foreach ($warning in $parsed.warnings) { [Console]::Error.WriteLine('Prunlet update: ' + $warning) } }
    return $parsed
}

# 最新ポインタの確認結果を、Rustの出力の形と値の形式で厳密に読む（不明な状態・形式は延期）。
function Get-PublishedRelease([string]$Executable, [string]$Config, [string]$Runtime) {
    if ($Runtime -cnotin @('win-x64', 'win-arm64')) { throw 'Installed runtime is unsupported.' }
    $release = Invoke-ReleaseCommand $Executable $Config 'Release manifest check did not complete.' @('__check-release-manifest', $Runtime)
    if ($release.status -cnotin @('available', 'current') -or [string]$release.runtime -cne $Runtime -or
        [string]$release.version -cnotmatch '\A(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\z' -or
        [string]$release.commit -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Release manifest check returned an unexpected result.' }
    $release.versionValue = [version][string]$release.version
    return $release
}

# 署名済みの版・commitだけを選択子として渡し、開始・取得・準備を行う。値（URL・長さ・SHA-256・既定ブランチ）は
# Rustが検証済みのpayloadから導くので、launcherは渡さない。
function Invoke-PublishedPackageTransfer([string]$Executable, [string]$Config, $SourceInfo, $Release) {
    $runtime = [string]$SourceInfo.runtime
    $begin = Invoke-ReleaseCommand $Executable $Config 'Published update state could not be prepared.' @('__begin-published-update', $Release.commit, $SourceInfo.commitSha)
    if ($begin.status -notin @('ready', 'existing')) { throw 'Published update state could not be prepared.' }
    $received = Invoke-ReleaseCommand $Executable $Config 'Published package download was not confirmed.' @('__download-release-package', $runtime, $Release.version, $Release.commit)
    if ($received.status -cne 'downloaded' -or [string]$received.version -cne $Release.version -or [string]$received.commit -cne $Release.commit) { throw 'Published package download was not confirmed.' }
    return Invoke-ReleaseCommand $Executable $Config 'Published package preparation did not complete.' @('__prepare-release-package', $runtime, $Release.version, $Release.commit)
}

# $ExpectedProductVersion: 新規の切替では署名済みマニフェストの "<version>+<commit>"。中断からの再開では空にする。
function Invoke-UpdateCoordinator([string]$Stage, [string]$Config, [string]$Codex, [string]$Executable, [string]$ExpectedProductVersion = '') {
    if (!$script:StartupUpdateReady) { throw 'Prunlet startup updates are disabled until safe stage reuse is implemented and verified.' }
    $candidate = Join-Path $Stage 'prunlet.exe'
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'The prepared update executable is missing; the update was preserved.' }
    $root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($Executable))
    $candidateGuards = Open-CandidateGuards $Stage (Join-Path $root '.prunlet-update-state.json')
    try {
    # 候補のhashを固定するguardの下で、実行する前に署名と版を確かめる（照合した実体と実行する実体を同じにする）。
    Assert-CandidateSignatures $Stage
    if ($ExpectedProductVersion) { Assert-CandidateProductVersion $Stage $ExpectedProductVersion }
    Test-CandidateExecutables $Stage
    $guards = Open-RegistrationGuards $Executable $Config $Codex $Stage
    try {
        $state = Read-StartupState (Join-Path $root '.prunlet-update-state.json')
        if ($state.phase -ceq 'idle' -and (!$state.ContainsKey('candidateCliSha256') -or !$state.candidateCliSha256)) {
            # 切替後の連携（Invoke-Integration）で更新タスクの所有確認に失敗すると、更新状態がidleへ戻らず
            # 以後の起動もCLIも止まる。候補の判定でidleのうちに確認し、他者・編集済みのタスクなら切り替えずに延期する。
            $candidateTasks = Join-Path $Stage 'integration\maintenance-task.ps1'
            & {
                . $candidateTasks
                if (Get-Command Get-PrunletUpdateTaskState -CommandType Function -ErrorAction SilentlyContinue) { $preserve = Get-UpdateTaskPreserveSwitch; $null = Get-PrunletUpdateTaskState $Executable $Config $Codex @preserve }
            }
        }
        if ($state.phase -ceq 'idle' -and (!$state.ContainsKey('candidateCliSha256') -or !$state.candidateCliSha256) -and (Test-CodexRegistrationPresent $Codex)) {
            # 候補の登録仕様が変更を要する場合は、製品を切り替える前に延期する。
            $candidateHelper = Join-Path $Stage 'integration\install-codex.ps1'
            $validationBackup = Join-Path ([IO.Path]::GetTempPath()) 'Prunlet-Registration-Validation'
            $preview = & $candidateHelper -ExecutablePath $Executable -ConfigPath $Config -CodexHome $Codex -BackupDirectory $validationBackup -ValidateOnly
            if (!$preview.ContainsKey('hookChanged') -or !$preview.ContainsKey('mcpChanged')) { throw 'Candidate Codex validation is incompatible.' }
            if ($preview.hookChanged -or $preview.mcpChanged) { throw 'The candidate changes Codex registration and requires review; the installed products were preserved.' }
            $oldInfo = [IO.File]::ReadAllText((Join-Path $root 'source-info.json')) | ConvertFrom-Json -AsHashtable
            $candidateAgent = Join-Path $Stage 'integration\install-agent-instructions.ps1'
            $agentPreview = & $candidateAgent -SourceGuidePath (Join-Path $Stage 'integration\PRUNLET.md') -PreviousGuideSha256 ([string]$oldInfo.auxiliarySha256['bin\PRUNLET.md']) -ExecutablePath $Executable -ConfigPath $Config -CodexHome $Codex -BackupDirectory $validationBackup -ValidateOnly
            if (!$agentPreview.ContainsKey('instructionsPresent') -or !$agentPreview.ContainsKey('agentChanged') -or !$agentPreview.ContainsKey('guideChanged')) { throw 'Candidate agent instruction validation is incompatible.' }
            if ($agentPreview.instructionsPresent -and ($agentPreview.agentChanged -or $agentPreview.guideChanged)) {
                throw 'The candidate changes agent instructions and requires review; the installed products were preserved.'
            }
        }
        $output = & $candidate --config $Config __apply-startup-update
        $exitCode = $LASTEXITCODE
        $result = $output | ConvertFrom-Json -AsHashtable
        if ($exitCode -eq 0 -and $result.status -ceq 'integration_required') {
            # 最初の確認から連携確定まで、登録内容の同じread guardを保持する。
            Invoke-Integration $candidate $Stage $Config $Codex $Executable
            $output = & $candidate --config $Config __apply-startup-update
            $exitCode = $LASTEXITCODE
            $result = $output | ConvertFrom-Json -AsHashtable
        }
        if ($exitCode -ne 0 -and $result.status -cne 'deferred') { throw 'The startup update did not complete; the update was preserved.' }
        if ($result.status -ceq 'deferred') {
            $reason = if ($result.ContainsKey('error')) { [string]$result.error } elseif ($result.ContainsKey('warnings') -and $result.warnings) { $result.warnings -join '; ' } else { 'The current products could not be safely switched.' }
            [Console]::Error.WriteLine('Prunlet update was deferred: ' + $reason)
        }
        return $result
    } finally { foreach ($guard in $guards) { $guard.Dispose() } }
    } finally { foreach ($guard in $candidateGuards) { $guard.Dispose() } }
}

try {
    # 更新だけの起動ではMCPの子を持たないため、jobへ入れない（呼出し元プロセスを巻き込まない）。
    if (!$UpdateOnly) { Start-PrunletMcpJob }
    foreach ($path in @($ExecutablePath, $ConfigPath) + @($CodexHome | Where-Object { $_ })) {
        if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Prunlet MCP paths must be absolute.' }
    }
    $ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    # 省略時は実効のCodexHomeを判定対象にする（登録の有無は実物の目印で決まり、なければ何もしない）。
    if (!$CodexHome) { $CodexHome = if ($env:CODEX_HOME -and [IO.Path]::IsPathFullyQualified($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' } }
    $CodexHome = [IO.Path]::GetFullPath($CodexHome)
    $bin = [IO.Path]::GetDirectoryName($ExecutablePath)
    $root = [IO.Path]::GetDirectoryName($bin)
    $managed = $root -and [IO.Path]::GetFileName($ExecutablePath).Equals('prunlet.exe', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($bin).Equals('bin', [StringComparison]::OrdinalIgnoreCase) -and $ConfigPath.Equals((Join-Path $root 'config.json'), [StringComparison]::OrdinalIgnoreCase)
    if ($managed) {
        $statePath = Join-Path $root '.prunlet-update-state.json'
        $stage = Join-Path $root '.prunlet-update-stage'
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
        $mutex = [Threading.Mutex]::new($false, ('Global\Prunlet-Startup-' + $key))
        $acquired = $false
        $cleanupTried = $false
        try {
            try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(8)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (!$acquired) { throw 'Another Prunlet startup update did not finish.' }
            $state = Read-StartupState $statePath
            if (@(Get-ChildItem -LiteralPath $root -Filter '.prunlet-update-state.*.pending' -File -Force -ErrorAction Stop).Count) {
                [Console]::Error.WriteLine('Prunlet preserved an unpublished update-state file after an interrupted update; inspect it before cleanup.')
            }
            if ($state.phase -cne 'idle') {
                $result = Invoke-UpdateCoordinator $stage $ConfigPath $CodexHome $ExecutablePath
                if ($result.status -notin @('updated', 'cleanup_pending')) { throw 'The interrupted Prunlet update still requires recovery.' }
                $state = Read-StartupState $statePath
            }
            if ($state.ContainsKey('stageCleanup') -and $state.stageCleanup -ceq 'attempting') {
                [Console]::Error.WriteLine('Prunlet retained an uncertain update stage; automatic cleanup was not retried.')
            } else {
                $sourceInfo = [IO.File]::ReadAllText((Join-Path $root 'source-info.json')) | ConvertFrom-Json -AsHashtable
                if ($sourceInfo.runtime -notin @('win-x64', 'win-arm64')) { throw 'Installed Prunlet runtime is unknown.' }
                if ([string]$sourceInfo.commitSha -cnotmatch '\A[0-9a-fA-F]{40}\z') { throw 'Installed commit is invalid.' }
                # 導入済みの版は、導入済みexeの版リソース（<版>+<commit>）から読む。commit部が取得元情報と一致しなければ
                # 版を確定できないため、更新を判定せずに延期する（取り違えた版で後退・前進の判断をしない）。
                $installedVersion = Read-PrunletProductVersion $ExecutablePath
                if ($installedVersion.commit -cne ([string]$sourceInfo.commitSha).ToLowerInvariant()) { throw 'Installed product version does not match its recorded commit.' }
                # 配信は公式repositoryだけ。取得元情報が別のrepositoryなら、署名済みマニフェストとは一致しないので延期する。
                if (![string]::Equals([string]$sourceInfo.repository, '1llum1n4t1s/Prunlet', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installed repository is not the published Prunlet repository.' }
                # 通信不能・署名不正・不一致はRustが終了コード1で返し、下のcatchで現在版のまま起動する（fail-closed）。
                $release = Get-PublishedRelease $ExecutablePath $ConfigPath ([string]$sourceInfo.runtime)
                # Rustの判定（実行中exeの版との比較）に加え、版リソースから読んだ導入済みの版より厳密に大きい場合だけ進む。
                if ($release.status -cne 'available' -or $release.versionValue -le $installedVersion.version) {
                    # 導入済みより厳密に大きい版だけを適用する（同じ版・古い版へは切り替えない＝後退防止）。
                    # 同じ版で別commitを指すマニフェストは配信側の不整合なので、適用せずに知らせるだけにする。
                    if ($release.versionValue -eq $installedVersion.version -and $release.commit -cne $installedVersion.commit) {
                        [Console]::Error.WriteLine('Prunlet update was deferred: the published manifest names the installed version with a different commit.')
                    }
                } elseif (!(Test-ProductsIdle $ExecutablePath)) {
                    [Console]::Error.WriteLine('Prunlet update was deferred while an existing process is active.')
                } else {
                    if (!$script:StartupUpdateReady) { throw 'Prunlet startup updates are disabled until safe stage reuse is implemented and verified.' }
                    $result = Invoke-PublishedPackageTransfer $ExecutablePath $ConfigPath $sourceInfo $release
                    if ($result.status -ceq 'prepared') {
                        # 版の照合は__prepare成功後・切替前に、Invoke-UpdateCoordinatorの中で候補のguardを開いた後に行う。
                        $result = Invoke-UpdateCoordinator $stage $ConfigPath $CodexHome $ExecutablePath ($release.version + '+' + $release.commit)
                        if ($result.status -notin @('updated', 'cleanup_pending', 'deferred')) { throw 'Prunlet startup update returned an unknown state.' }
                        $state = Read-StartupState $statePath
                        if ($state.phase -cne 'idle') { throw 'Prunlet startup update has not finished.' }
                    } elseif ($result.status -cne 'current') { throw 'Prunlet startup preparation returned an unknown state.' }
                }
            }
        } catch {
            $state = Read-StartupState $statePath
            if ($state.phase -cne 'idle') { throw }
            [Console]::Error.WriteLine('Prunlet startup update was deferred: ' + $_.Exception.Message)
        } finally {
            if ($acquired) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    if ($UpdateOnly) {
        # 最新・延期・通信不能は正常終了とし、次の起動（タスク・MCP）で再確認する。
        # 更新状態をidleへ戻せなかった場合だけ上のthrowで非0になる。
        if (!$managed) { throw 'Update-only startup requires the managed installation layout.' }
        exit 0
    }
    $env:PRUNLET_MCP_LAUNCHER_JOB = $script:PrunletMcpJobName
    & $ExecutablePath --config $ConfigPath mcp
    exit $LASTEXITCODE
} catch {
    $purpose = if ($UpdateOnly) { 'Prunlet update check could not finish safely: ' } else { 'Prunlet MCP could not start safely: ' }
    [Console]::Error.WriteLine($purpose + $_.Exception.Message)
    exit 1
}
