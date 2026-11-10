# RegistryKey の SafeHandle は要求の間だけ借用し、DLLには閉じさせない。
# caller は key を取得した view と生存期間を自分で管理する。
function Initialize-RegistryFixture([bool]$Machine, [string]$Prefix) {
    $allowed = if ($Machine) { 'SYSTEM\PrunletE2E\' } else { 'Software\PrunletE2E\' }
    if (!$Prefix.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture namespace.' }
    $suffix = $Prefix.Substring($allowed.Length)
    $guid = [guid]::Empty
    if ($suffix.Length -ne 32 -or ![guid]::TryParseExact($suffix,'N',[ref]$guid)) { throw 'Unsafe fixture namespace.' }
    $script:RegistryFixtureMachine = $Machine
    $script:RegistryFixturePrefix = $Prefix
    $script:RegistryFixtureLinkPrefix = $Prefix + '-link-probes'
    $script:RegistryFixtureClassesPrefix = 'Software\Classes\PrunletE2E_' + $suffix
}
function Assert-RegistryFixturePath([string]$Relative) {
    foreach ($prefix in @($script:RegistryFixturePrefix,$script:RegistryFixtureLinkPrefix,$script:RegistryFixtureClassesPrefix)) {
        if ($prefix -and ($Relative.Equals($prefix,[StringComparison]::OrdinalIgnoreCase) -or $Relative.StartsWith($prefix + '\',[StringComparison]::OrdinalIgnoreCase))) { return }
    }
    throw 'Registry fixture escaped its unique run root.'
}
function Get-RegistryFixtureBase([string]$Relative, [int]$View) {
    Assert-RegistryFixturePath $Relative
    if ($View -notin @(32,64)) { throw 'Registry fixture view must be 32 or 64.' }
    $classes = $Relative.Equals($script:RegistryFixtureClassesPrefix,[StringComparison]::OrdinalIgnoreCase) -or $Relative.StartsWith($script:RegistryFixtureClassesPrefix + '\',[StringComparison]::OrdinalIgnoreCase)
    $hive = if ($script:RegistryFixtureMachine -and !$classes) { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    $registryView = if ($View -eq 32) { [Microsoft.Win32.RegistryView]::Registry32 } else { [Microsoft.Win32.RegistryView]::Registry64 }
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$registryView)
}
function Open-RegistryFixtureKey([string]$Relative, [int]$View, [bool]$Security = $false) {
    Assert-RegistryFixturePath $Relative
    $raw = Invoke-PrunletFixture -Operation 'registry.openOwned' -Arguments @{machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix;path=$Relative;view=$View;security=$Security}
    if ($null -eq $raw) { return $null }
    ConvertTo-RegistryFixtureKey $raw $View
}
function New-RegistryFixtureKey([string]$Relative, [int]$View) {
    $root = Get-RegistryFixtureBase $Relative $View
    try { $root.CreateSubKey($Relative,$true) } finally { $root.Dispose() }
}
function New-RegistryFixtureNativeKey([string]$Relative, [bool]$Volatile, [bool]$Link = $false, [string]$Class = $null) {
    Assert-RegistryFixturePath $Relative
    # 応答不明の場合は再送しない。成功したhandleの所有権を直ちにSafeHandleへ移す。
    $raw = Invoke-PrunletFixture -Operation 'registry.createOwned' -Arguments @{
        machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix
        path=$Relative;volatile=$Volatile;link=$Link;class=$Class
    }
    ConvertTo-RegistryFixtureKey $raw 64
}
function New-RegistryFixtureVolatile([string]$Relative, [bool]$Link = $false, [string]$Class = $null) {
    New-RegistryFixtureNativeKey $Relative $true $Link $Class
}
function New-RegistryFixtureWithClass([string]$Relative, [string]$Class) {
    New-RegistryFixtureNativeKey $Relative $false $false $Class
}
function ConvertTo-RegistryFixtureKey([uint64]$Raw, [int]$View) {
    $safe = [Microsoft.Win32.SafeHandles.SafeRegistryHandle]::new([IntPtr]([int64]$Raw),$true)
    $transferred = $false
    try {
        $registryView = if ($View -eq 32) { [Microsoft.Win32.RegistryView]::Registry32 } else { [Microsoft.Win32.RegistryView]::Registry64 }
        $key = [Microsoft.Win32.RegistryKey]::FromHandle($safe,$registryView)
        $transferred = $true
        return $key
    } finally { if (!$transferred) { $safe.Dispose() } }
}
function Invoke-RegistryFixtureKey {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Key,
          [Parameter(Mandatory)][string]$Operation,
          [hashtable]$Arguments = @{})
    $handle = $Key.Handle
    $held = $false
    try {
        $handle.DangerousAddRef([ref]$held)
        $request = @{} + $Arguments
        $request.handle = [uint64]$handle.DangerousGetHandle().ToInt64()
        Invoke-PrunletFixture -Operation $Operation -Arguments $request
    } finally {
        if ($held) { $handle.DangerousRelease() }
    }
}
function Get-RegistryFixtureClass([Microsoft.Win32.RegistryKey]$Key) {
    Invoke-RegistryFixtureKey $Key 'registry.class'
}
function Get-RegistryFixtureName([Microsoft.Win32.RegistryKey]$Key) {
    Invoke-RegistryFixtureKey $Key 'registry.name'
}
function Get-RegistryFixtureLastWrite([Microsoft.Win32.RegistryKey]$Key) {
    Invoke-RegistryFixtureKey $Key 'registry.lastWrite'
}
function Get-RegistryFixtureValue([Microsoft.Win32.RegistryKey]$Key, [string]$Name) {
    Invoke-RegistryFixtureKey $Key 'registry.value' @{name=$Name}
}
function Try-SetRegistryFixtureValue([Microsoft.Win32.RegistryKey]$Key, [string]$Name, [uint32]$Type, [byte[]]$Data) {
    Invoke-RegistryFixtureKey $Key 'registry.set' @{name=$Name;type=$Type;base64=[Convert]::ToBase64String($Data)}
}
function Set-RegistryFixtureValue([Microsoft.Win32.RegistryKey]$Key, [string]$Name, [uint32]$Type, [byte[]]$Data) {
    $errorCode = Try-SetRegistryFixtureValue $Key $Name $Type $Data
    if ($errorCode -ne 0) { throw [ComponentModel.Win32Exception]::new([int]$errorCode) }
}
function Get-RegistryFixtureSecurity([Microsoft.Win32.RegistryKey]$Key) {
    Invoke-RegistryFixtureKey $Key 'registry.securityReopen'
}
function Get-RegistryFixtureProcessPrivileges([uint32]$ProcessId) {
    Invoke-PrunletFixture -Operation 'registry.processPrivileges' -Arguments @{processId=$ProcessId}
}
function Test-RegistryFixtureKtm([int]$View, [bool]$Machine = $script:RegistryFixtureMachine) {
    Invoke-PrunletFixture -Operation 'registry.preflightKtm' -Arguments @{view=$View;machine=$Machine}
}
function Enable-RegistryFixtureSecurity {
    Invoke-PrunletFixture -Operation 'registry.enableSecurity' -Arguments @{}
}
function Set-RegistryFixtureLowIntegrity([string]$Relative, [int]$View) {
    Assert-RegistryFixturePath $Relative
    $null = Invoke-PrunletFixture -Operation 'registry.lowIntegrity' -Arguments @{machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix;path=$Relative;view=$View}
}
function Rename-RegistryFixtureLink([string]$Relative, [Microsoft.Win32.RegistryKey]$Key, [string]$NewName) {
    Assert-RegistryFixturePath $Relative
    Invoke-RegistryFixtureKey $Key 'registry.renameLink' @{machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix;path=$Relative;name=$NewName}
}
function New-RegistryFixtureLink([string]$Relative, [string]$Target) {
    Assert-RegistryFixturePath $Target
    if (!$Target.StartsWith($script:RegistryFixtureLinkPrefix + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Link target escaped volatile probe root.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $native = if ($script:RegistryFixtureMachine) { '\Registry\Machine\' } else { '\Registry\User\' + $identity.User.Value + '\' } }
    finally { $identity.Dispose() }
    $key = New-RegistryFixtureNativeKey $Relative $true $true
    try { Set-RegistryFixtureValue $key 'SymbolicLinkValue' 6 ([Text.Encoding]::Unicode.GetBytes($native + $Target)) }
    finally { $key.Dispose() }
}
function Get-RegistryFixtureDacl([string]$Relative, [Microsoft.Win32.RegistryKey]$Key) {
    Assert-RegistryFixturePath $Relative
    $encoded = Invoke-RegistryFixtureKey $Key 'registry.fixtureDacl' @{machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix;path=$Relative}
    return ,([Convert]::FromBase64String($encoded))
}
function Set-RegistryFixtureDacl([string]$Relative, [Microsoft.Win32.RegistryKey]$Key, [byte[]]$Bytes, [uint32]$Information) {
    Assert-RegistryFixturePath $Relative
    $null = Invoke-RegistryFixtureKey $Key 'registry.setFixtureDacl' @{machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix;path=$Relative;base64=[Convert]::ToBase64String($Bytes);information=$Information}
}
function Deny-RegistryFixtureSetValue([string]$Relative, [Microsoft.Win32.RegistryKey]$Key) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid = $identity.User.Value } finally { $identity.Dispose() }
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new("D:P(D;;0x2;;;$sid)(A;;KA;;;$sid)(A;;KA;;;SY)")
    $bytes = [byte[]]::new($descriptor.BinaryLength); $descriptor.GetBinaryForm($bytes,0)
    Set-RegistryFixtureDacl $Relative $Key $bytes 4
}
function Restore-RegistryFixtureDacl([string]$Relative, [Microsoft.Win32.RegistryKey]$Key, [byte[]]$Bytes) {
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Bytes,0)
    $information = if (($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0) { [uint32]2147483652 } else { [uint32]536870916 }
    Set-RegistryFixtureDacl $Relative $Key $Bytes $information
}
function Get-RegistryFixtureSnapshot([string]$Relative, [int]$View) {
    $rows = [Collections.Generic.List[string]]::new()
    function Visit-RegistryFixture([string]$Path, [string]$Label) {
        $key = Open-RegistryFixtureKey $Path $View $true
        if (!$key) { throw "Snapshot key missing: $Path" }
        try {
            $rows.Add('K:' + $Label + ':' + (Get-RegistryFixtureSecurity $key))
            foreach ($name in $key.GetValueNames()) {
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($name))
                $rows.Add('V:' + $Label + ':' + $encoded + ':' + (Get-RegistryFixtureValue $key $name))
            }
            foreach ($child in $key.GetSubKeyNames()) { Visit-RegistryFixture ($Path + '\' + $child) ($Label + '\' + $child) }
        } finally { $key.Dispose() }
    }
    Visit-RegistryFixture $Relative ''
    $rows.Sort([StringComparer]::Ordinal)
    $rows.ToArray()
}
function Get-RegistryFixtureClassesAliasState {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { Invoke-PrunletFixture -Operation 'registry.classesAliasState' -Arguments @{sid=$identity.User.Value} }
    finally { $identity.Dispose() }
}
function Get-RegistryFixtureClassesBackingSnapshot([string]$Relative, [int]$View) {
    Assert-RegistryFixturePath $Relative
    if (!$Relative.Equals($script:RegistryFixtureClassesPrefix,[StringComparison]::OrdinalIgnoreCase) -and !$Relative.StartsWith($script:RegistryFixtureClassesPrefix + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Not a Classes fixture.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid = $identity.User.Value } finally { $identity.Dispose() }
    $rows = [Collections.Generic.List[string]]::new()
    function Visit-RegistryBacking([string]$Path, [string]$Label) {
        $raw = Invoke-PrunletFixture -Operation 'registry.openOwned' -Arguments @{machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix;path=$Path;view=$View;security=$true;backingSid=$sid}
        if ($null -eq $raw) { throw "Classes backing key missing: $Path" }
        $key = ConvertTo-RegistryFixtureKey $raw $View
        try {
            $rows.Add('K:' + $Label + ':' + (Get-RegistryFixtureSecurity $key))
            foreach ($name in $key.GetValueNames()) {
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($name))
                $rows.Add('V:' + $Label + ':' + $encoded + ':' + (Get-RegistryFixtureValue $key $name))
            }
            foreach ($child in $key.GetSubKeyNames()) { Visit-RegistryBacking ($Path + '\' + $child) ($Label + '\' + $child) }
        } finally { $key.Dispose() }
    }
    Visit-RegistryBacking $Relative ''
    $rows.Sort([StringComparer]::Ordinal)
    $rows.ToArray()
}
