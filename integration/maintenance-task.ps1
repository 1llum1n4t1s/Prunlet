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
