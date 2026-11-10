# session fixture DLLはこのPowerShellプロセスの実token・ハンドルを観測する。
function Convert-SessionFixtureRecord($Record) {
 # 従来のDictionaryは名前による添字アクセスも利用される。
 $result=@{}; foreach($property in $Record.PSObject.Properties){$result[$property.Name]=$property.Value}; return $result
}
function Get-SessionFixtureTokenInfo { Convert-SessionFixtureRecord (Invoke-PrunletFixture -Operation 'session.tokenInfo' -Arguments @{}) }
function Test-SessionFixturePackaged { Invoke-PrunletFixture -Operation 'session.packaged' -Arguments @{} }
function Get-SessionFixtureSoftwareDigest { Invoke-PrunletFixture -Operation 'session.softwareDigest' -Arguments @{} }
function Get-SessionFixtureFingerprint([string]$Json) { Invoke-PrunletFixture -Operation 'session.fingerprint' -Arguments @{json=$Json} }
function New-SessionFixtureClass([string]$Path,[string]$Class) { $null=Invoke-PrunletFixture -Operation 'session.createClass' -Arguments @{path=$Path;class=$Class} }
function New-SessionFixtureRunRoot([string]$Path) { $null=Invoke-PrunletFixture -Operation 'session.createRunRoot' -Arguments @{path=$Path} }
function Get-SessionFixtureProcessInfo([int]$ProcessId) { Convert-SessionFixtureRecord (Invoke-PrunletFixture -Operation 'session.processInfo' -Arguments @{pid=$ProcessId}) }
function Get-SessionFixtureDesktopInfo { Convert-SessionFixtureRecord (Invoke-PrunletFixture -Operation 'session.desktopInfo' -Arguments @{}) }
function Get-SessionFixtureShellWindow { [IntPtr][long](Invoke-PrunletFixture -Operation 'session.shellWindow' -Arguments @{}) }
function Invoke-SessionFixtureKey([Microsoft.Win32.RegistryKey]$Key,[string]$Operation) {
 if($null-eq$Key){throw 'Registry key is required.'}
 # 実KeyのSafeHandleを借用し、DLL呼出し中だけ寿命を固定する。所有・closeは移さない。
 $handle=$Key.Handle; $held=$false
 try {
  $handle.DangerousAddRef([ref]$held)
  if($handle.IsInvalid-or$handle.IsClosed){throw 'Registry handle is unavailable.'}
  Invoke-PrunletFixture -Operation $Operation -Arguments @{handle=[uint64]$handle.DangerousGetHandle().ToInt64()}
 } finally { if($held){$handle.DangerousRelease()} }
}
function Get-SessionFixtureClass([Microsoft.Win32.RegistryKey]$Key) { Invoke-SessionFixtureKey $Key 'registry.class' }
function Get-SessionFixtureName([Microsoft.Win32.RegistryKey]$Key) { Invoke-SessionFixtureKey $Key 'registry.name' }
