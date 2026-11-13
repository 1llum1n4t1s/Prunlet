# 日時と所有者を検証し、コンソールを持たない保守専用入口へ同じCoreのコマンドを渡す。
function Get-PrunletMaintenanceState([string]$ExecutablePath, [string]$ConfigPath) {
    foreach ($path in @($ExecutablePath, $ConfigPath)) {
        if (![IO.Path]::IsPathFullyQualified($path) -or $path.Contains('"') -or $path.Contains("`r") -or $path.Contains("`n")) { throw 'Maintenance task paths must be absolute paths without quotes or line breaks.' }
    }
    $ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $identity = $sid + "`n" + $ExecutablePath.ToLowerInvariant() + "`n" + $ConfigPath.ToLowerInvariant()
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
    $maintenanceExecutable = Join-Path ([IO.Path]::GetDirectoryName($ExecutablePath)) 'prunlet-maintenance.exe'
    $state = [ordered]@{ name = ('Prunlet-Maintenance-' + $key.Substring(0, 24)); sid = $sid; executable = $ExecutablePath; maintenanceExecutable = $maintenanceExecutable; config = $ConfigPath; arguments = ('--config "' + $ConfigPath + '" maintain --apply'); marker = ('Prunlet managed maintenance v1:' + $key); previousXml = $null; attempted = $false }
    # 存在しないタスクとアクセス拒否を混同しないよう、ルートの列挙失敗は伝播させる。
    $task = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName.Equals($state.name, [StringComparison]::OrdinalIgnoreCase) })
    if ($task.Count -gt 1) { throw 'Maintenance task identity is ambiguous.' }
    if ($task.Count) {
        $state.previousXml = Export-ScheduledTask -TaskPath '\' -TaskName $state.name -ErrorAction Stop
        Assert-PrunletMaintenanceOwned $state $state.previousXml
    }
    return $state
}

function Assert-PrunletMaintenanceOwned($State, [string]$Xml) {
    $document = [xml]$Xml
    $namespace = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $description = $document.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Description', $namespace)
    $principal = $document.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId', $namespace)
    $actions = $document.SelectNodes('/t:Task/t:Actions/*', $namespace)
    if (!$description -or $description.InnerText -cne $State.marker -or !$principal -or $principal.InnerText -cne $State.sid -or $actions.Count -ne 1 -or $actions[0].LocalName -cne 'Exec') { throw 'Existing maintenance task is not owned by this installation; it was preserved.' }
    $command = $actions[0].SelectSingleNode('t:Command', $namespace)
    $arguments = $actions[0].SelectSingleNode('t:Arguments', $namespace)
    if (!$command -or !$arguments -or $command.InnerText -cnotin @($State.executable, $State.maintenanceExecutable) -or $arguments.InnerText -cne $State.arguments) { throw 'Existing maintenance task action was changed; it was preserved.' }
}

function Register-PrunletMaintenanceTask($State) {
    $current = Get-PrunletMaintenanceState $State.executable $State.config
    if ($current.previousXml -cne $State.previousXml) { throw 'Maintenance task changed during installation; it was preserved.' }
    if (![IO.File]::Exists($State.maintenanceExecutable)) { throw 'The maintenance executable must be installed before task registration.' }
    # 正確な旧CLI登録は実行先だけを変更し、時刻・無効化・権限などを保持する。
    if ($State.previousXml) {
        $document = [xml]$State.previousXml
        $namespace = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        $commandNode = $document.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Command', $namespace)
        if ($commandNode.InnerText -ceq $State.maintenanceExecutable) { return }
        $commandNode.InnerText = $State.maintenanceExecutable
        $State.attempted = $true
        Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $document.OuterXml -Force -ErrorAction Stop | Out-Null
        $registered = Export-ScheduledTask -TaskPath '\' -TaskName $State.name -ErrorAction Stop
        Assert-PrunletMaintenanceOwned $State $registered
        if (([xml]$registered).Task.Actions.Exec.Command -cne $State.maintenanceExecutable) { throw 'Maintenance task migration did not select the console-free executable.' }
        return
    }
    $escape = { param($value) [Security.SecurityElement]::Escape([string]$value) }
    $sid = & $escape $State.sid
    $marker = & $escape $State.marker
    $command = & $escape $State.maintenanceExecutable
    $arguments = & $escape $State.arguments
    $start = [DateTime]::Today.AddHours(3).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    # パスをshellへ渡さず、XMLのCommandとArgumentsへ別々に保存する。
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$marker</Description></RegistrationInfo>
  <Triggers><CalendarTrigger><StartBoundary>$start</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger><LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId></LogonTrigger></Triggers>
  <Principals><Principal id="Owner"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled><Hidden>true</Hidden><ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings>
  <Actions Context="Owner"><Exec><Command>$command</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
    $State.attempted = $true
    Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $xml -Force:([bool]$State.previousXml) -ErrorAction Stop | Out-Null
    $registered = Export-ScheduledTask -TaskPath '\' -TaskName $State.name -ErrorAction Stop
    Assert-PrunletMaintenanceOwned $State $registered
}

function Restore-PrunletMaintenanceTask($State) {
    if (!$State.attempted) { return }
    $current = Get-PrunletMaintenanceState $State.executable $State.config
    if (!$current.previousXml) {
        if ($State.previousXml) { Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $State.previousXml -ErrorAction Stop | Out-Null }
        return
    }
    if ($State.previousXml) { Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $State.previousXml -Force -ErrorAction Stop | Out-Null }
    else { Unregister-ScheduledTask -TaskPath '\' -TaskName $State.name -Confirm:$false -ErrorAction Stop }
}

function Unregister-PrunletMaintenanceTask([string]$ExecutablePath, [string]$ConfigPath) {
    $state = Get-PrunletMaintenanceState $ExecutablePath $ConfigPath
    if ($state.previousXml) { Unregister-ScheduledTask -TaskPath '\' -TaskName $state.name -Confirm:$false -ErrorAction Stop }
    return $state.name
}

# ---- 更新タスク ----
# CodexがMCPを起動しないPCでも、起動時更新と同じ確認・切替をログオン後と1日1回行う。
# 実行は start-prunlet-mcp.ps1 -UpdateOnly で、MCPは起動しない。
# conhost.exe --headless からpwshを起動し、コンソール窓を出さない（保守exeのようなGUI入口はPowerShellにない）。
# pwshはCodexのMCP登録と同じくPATHから解決し、PowerShellの更新で絶対パスが変わっても所有判定を崩さない。
# 保守タスク（03:00・ログオン直後）と同時に走ると、更新側が製品exeの使用中を検出して毎回延期するため、
# 時刻とログオン後の遅延をずらす。
function Get-PrunletUpdateTaskState([string]$ExecutablePath, [string]$ConfigPath, [string]$CodexHome, [switch]$PreserveCodexHome) {
    # CodexHomeは任意。空ならCodexへ登録していない導入として、タスク引数に-CodexHomeを付けない。
    # 起動スクリプト側はCodexHomeがなければCodex登録の保護・更新を行わない。
    # PreserveCodexHomeは起動時更新用。どのMCPホストから起動されたかでタスクの-CodexHomeが付いたり
    # 外れたりしないよう、既存タスクの値をそのまま引き継ぐ（導入時はインストーラーが明示的に決める）。
    foreach ($path in @($ExecutablePath, $ConfigPath) + @($CodexHome | Where-Object { $_ })) {
        if (![IO.Path]::IsPathFullyQualified($path) -or $path.Contains('"') -or $path.Contains("`r") -or $path.Contains("`n")) { throw 'Update task paths must be absolute paths without quotes or line breaks.' }
    }
    $ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $CodexHome = if ($CodexHome) { [IO.Path]::GetFullPath($CodexHome).TrimEnd('\') } else { '' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # 保守タスクと同じ識別（利用者・CLI・設定）から、別の名前と所有印を作る。CodexHomeは引数側だけに置き、
    # 再導入でCodexHomeを変えても同じタスクとして実行先を移行できるようにする。
    $identity = 'update' + "`n" + $sid + "`n" + $ExecutablePath.ToLowerInvariant() + "`n" + $ConfigPath.ToLowerInvariant()
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
    $launcher = Join-Path ([IO.Path]::GetDirectoryName($ExecutablePath)) 'start-prunlet-mcp.ps1'
    $command = Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
    $arguments = '--headless pwsh -NoProfile -NonInteractive -File "' + $launcher + '" -UpdateOnly -ExecutablePath "' + $ExecutablePath + '" -ConfigPath "' + $ConfigPath + '"' + $(if ($CodexHome) { ' -CodexHome "' + $CodexHome + '"' } else { '' })
    $state = [ordered]@{ name = ('Prunlet-Update-' + $key.Substring(0, 24)); sid = $sid; executable = $ExecutablePath; config = $ConfigPath; codexHome = $CodexHome; launcher = $launcher; command = $command; arguments = $arguments; marker = ('Prunlet managed update v1:' + $key); previousXml = $null; attempted = $false }
    $task = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName.Equals($state.name, [StringComparison]::OrdinalIgnoreCase) })
    if ($task.Count -gt 1) { throw 'Update task identity is ambiguous.' }
    if ($task.Count) {
        $state.previousXml = Export-ScheduledTask -TaskPath '\' -TaskName $state.name -ErrorAction Stop
        Assert-PrunletUpdateTaskOwned $state $state.previousXml
        if ($PreserveCodexHome) {
            $namespace = [Xml.XmlNamespaceManager]::new(([xml]$state.previousXml).NameTable)
            $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
            $previousArguments = ([xml]$state.previousXml).SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments', $namespace)
            $match = if ($previousArguments) { [regex]::Match($previousArguments.InnerText, ' -CodexHome "([^"\r\n]+)"') } else { $null }
            $kept = if ($match -and $match.Success -and [IO.Path]::IsPathFullyQualified($match.Groups[1].Value)) { [IO.Path]::GetFullPath($match.Groups[1].Value).TrimEnd('\') } else { '' }
            $state.codexHome = $kept
            $state.arguments = '--headless pwsh -NoProfile -NonInteractive -File "' + $launcher + '" -UpdateOnly -ExecutablePath "' + $ExecutablePath + '" -ConfigPath "' + $ConfigPath + '"' + $(if ($kept) { ' -CodexHome "' + $kept + '"' } else { '' })
        }
    }
    return $state
}

function Assert-PrunletUpdateTaskOwned($State, [string]$Xml) {
    # 所有印・利用者・単一のExecでconhostを起動することを確認する。引数は実行先の移行対象なので、ここでは照合しない。
    $document = [xml]$Xml
    $namespace = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $description = $document.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Description', $namespace)
    $principal = $document.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId', $namespace)
    $actions = $document.SelectNodes('/t:Task/t:Actions/*', $namespace)
    if (!$description -or $description.InnerText -cne $State.marker -or !$principal -or $principal.InnerText -cne $State.sid -or $actions.Count -ne 1 -or $actions[0].LocalName -cne 'Exec') { throw 'Existing update task is not owned by this installation; it was preserved.' }
    $command = $actions[0].SelectSingleNode('t:Command', $namespace)
    if (!$command -or !$command.InnerText.Equals($State.command, [StringComparison]::OrdinalIgnoreCase)) { throw 'Existing update task action was changed; it was preserved.' }
}

function Register-PrunletUpdateTask($State) {
    $current = Get-PrunletUpdateTaskState $State.executable $State.config $State.codexHome
    if ($current.previousXml -cne $State.previousXml) { throw 'Update task changed during installation; it was preserved.' }
    if (![IO.File]::Exists($State.launcher)) { throw 'The startup launcher must be installed before update task registration.' }
    if ($State.previousXml) {
        # 所有済みタスクは実行先（引数）だけを揃え、時刻・無効化などの利用者設定を保持する。
        $document = [xml]$State.previousXml
        $namespace = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        $exec = $document.SelectSingleNode('/t:Task/t:Actions/t:Exec', $namespace)
        $argumentsNode = $exec.SelectSingleNode('t:Arguments', $namespace)
        if ($argumentsNode -and $argumentsNode.InnerText -ceq $State.arguments) { return }
        if (!$argumentsNode) {
            $argumentsNode = $document.CreateElement('Arguments', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
            [void]$exec.AppendChild($argumentsNode)
        }
        $argumentsNode.InnerText = $State.arguments
        $State.attempted = $true
        Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $document.OuterXml -Force -ErrorAction Stop | Out-Null
        $registered = Export-ScheduledTask -TaskPath '\' -TaskName $State.name -ErrorAction Stop
        Assert-PrunletUpdateTaskOwned $State $registered
        if (([xml]$registered).Task.Actions.Exec.Arguments -cne $State.arguments) { throw 'Update task migration did not select the installed launcher.' }
        return
    }
    $escape = { param($value) [Security.SecurityElement]::Escape([string]$value) }
    $sid = & $escape $State.sid
    $marker = & $escape $State.marker
    $command = & $escape $State.command
    $arguments = & $escape $State.arguments
    $start = [DateTime]::Today.AddHours(12).AddMinutes(30).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$marker</Description></RegistrationInfo>
  <Triggers><CalendarTrigger><StartBoundary>$start</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger><LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId><Delay>PT10M</Delay></LogonTrigger></Triggers>
  <Principals><Principal id="Owner"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled><Hidden>true</Hidden><ExecutionTimeLimit>PT30M</ExecutionTimeLimit></Settings>
  <Actions Context="Owner"><Exec><Command>$command</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
    $State.attempted = $true
    Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $xml -ErrorAction Stop | Out-Null
    $registered = Export-ScheduledTask -TaskPath '\' -TaskName $State.name -ErrorAction Stop
    Assert-PrunletUpdateTaskOwned $State $registered
}

function Restore-PrunletUpdateTask($State) {
    if (!$State.attempted) { return }
    $current = Get-PrunletUpdateTaskState $State.executable $State.config $State.codexHome
    if (!$current.previousXml) {
        if ($State.previousXml) { Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $State.previousXml -ErrorAction Stop | Out-Null }
        return
    }
    if ($State.previousXml) { Register-ScheduledTask -TaskPath '\' -TaskName $State.name -Xml $State.previousXml -Force -ErrorAction Stop | Out-Null }
    else { Unregister-ScheduledTask -TaskPath '\' -TaskName $State.name -Confirm:$false -ErrorAction Stop }
}

function Unregister-PrunletUpdateTask([string]$ExecutablePath, [string]$ConfigPath, [string]$CodexHome) {
    $state = Get-PrunletUpdateTaskState $ExecutablePath $ConfigPath $CodexHome
    if ($state.previousXml) { Unregister-ScheduledTask -TaskPath '\' -TaskName $state.name -Confirm:$false -ErrorAction Stop }
    return $state.name
}
