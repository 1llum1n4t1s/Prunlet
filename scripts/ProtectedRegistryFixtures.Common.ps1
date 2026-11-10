# 保持するnative token・KTM・keyはRust DLLのleaseに置く。同一要求を再送しない。
function New-ProtectedFixtureLease([string]$Kind,[string]$Id) {
 $lease=[pscustomobject]@{Kind=$Kind;Id=$Id;State='active';After=$null;Restored=$false;RestoreErrors=[Collections.Generic.List[int]]::new()}
 $lease | Add-Member ScriptMethod Dispose {
  if($this.State-ne'active'){return}
  $id=$this.Id;$this.Id=$null;$this.State='inflight'
  try {
   $operation=switch($this.Kind){'key'{'registry.protected.keyClose'} 'transaction'{'registry.protected.transactionClose'} 'privilege'{'registry.protected.privilegeClose'} default{throw 'Unknown protected lease kind'}}
   $result=Invoke-PrunletFixture -Operation $operation -Arguments @{id=$id}
   if($this.Kind-eq'privilege'){$this.After=Convert-ProtectedFixtureRecord $result.after;$this.Restored=[bool]$result.restored;foreach($errorCode in $result.restoreErrors){$this.RestoreErrors.Add([int]$errorCode)}}
   $this.State='closed'
  } catch { $this.State='unknown';throw }
 }
 return $lease
}
function Convert-ProtectedFixtureRecord($Record) { $result=@{};foreach($property in $Record.PSObject.Properties){$result[$property.Name]=$property.Value};return $result }
function Start-ProtectedFixturePrivileges {
 $result=Invoke-PrunletFixture -Operation 'registry.protected.privilegeBegin' -Arguments @{}
 $lease=New-ProtectedFixtureLease 'privilege' $result.id
 $lease | Add-Member NoteProperty Before (Convert-ProtectedFixtureRecord $result.before)
 $lease | Add-Member NoteProperty Enabled (Convert-ProtectedFixtureRecord $result.enabled)
 return $lease
}
function Get-ProtectedFixtureProcessPrivileges([uint32]$ProcessId) {
 Convert-ProtectedFixtureRecord (Invoke-PrunletFixture -Operation 'registry.protected.processPrivileges' -Arguments @{pid=$ProcessId})
}
function Invoke-ProtectedFixtureKey($Key,[string]$Operation,[hashtable]$Arguments=@{}) {
 $request=@{}+$Arguments;$safe=$null;$held=$false
 try {
  if($Key -is [Microsoft.Win32.RegistryKey]){$safe=$Key.Handle}
  elseif($Key -is [Microsoft.Win32.SafeHandles.SafeRegistryHandle]){$safe=$Key}
  elseif($Key.Kind-eq'key' -and $Key.State-eq'active'){$request.keyLease=$Key.Id}
  else {throw 'Invalid or unavailable protected key.'}
  if($safe){$safe.DangerousAddRef([ref]$held);if($safe.IsInvalid-or$safe.IsClosed){throw 'Key handle is unavailable.'};$request.handle=[uint64]$safe.DangerousGetHandle().ToInt64()}
  Invoke-PrunletFixture -Operation $Operation -Arguments $request
 } finally {if($held){$safe.DangerousRelease()}}
}
function Open-ProtectedFixtureKey($Transaction,$Parent,[string]$Name,[uint32]$Options,[bool]$Raw,[uint32]$Access) {
 $request=@{name=$Name;options=$Options;raw=$Raw;access=$Access};$safe=$null;$held=$false
 try {
  if($Transaction){if($Transaction.Kind-ne'transaction'-or$Transaction.State-ne'active'){throw 'Transaction lease unavailable.'};$request.transaction=$Transaction.Id}
  if($Parent -is [Microsoft.Win32.SafeHandles.SafeRegistryHandle]){$safe=$Parent}
  elseif($Parent -is [Microsoft.Win32.RegistryKey]){$safe=$Parent.Handle}
  elseif($Parent){if($Parent.Kind-ne'key'-or$Parent.State-ne'active'){throw 'Parent key lease unavailable.'};$request.parentLease=$Parent.Id}
  if($safe){$safe.DangerousAddRef([ref]$held);if($safe.IsInvalid-or$safe.IsClosed){throw 'Parent handle is unavailable.'};$request.parentHandle=[uint64]$safe.DangerousGetHandle().ToInt64()}
  $result=Invoke-PrunletFixture -Operation 'registry.protected.open' -Arguments $request
  $key=if($result.keyLease){New-ProtectedFixtureLease 'key' $result.keyLease}else{$null}
  $open=[pscustomobject]@{Handle=$key;Error=[int]$result.error;Status=[string]$result.status;GrantedAccess=[uint32]$result.grantedAccess}
  $open | Add-Member ScriptMethod Dispose {if($this.Handle){$this.Handle.Dispose()}}
  return $open
 } finally {if($held){$safe.DangerousRelease()}}
}
function Start-ProtectedFixtureTransaction { New-ProtectedFixtureLease 'transaction' (Invoke-PrunletFixture -Operation 'registry.protected.transactionBegin' -Arguments @{}) }
function Complete-ProtectedFixtureTransaction($Transaction,[bool]$Commit) {
 if($Transaction.Kind-ne'transaction'-or$Transaction.State-ne'active'){throw 'Transaction lease unavailable.'}
 $operation=if($Commit){'registry.protected.transactionCommit'}else{'registry.protected.transactionRollback'}
 # commit/rollbackは一度だけ。応答不明時はcloseだけを許し再送しない。
 if($Transaction.PSObject.Properties['Completed']){throw 'Transaction completion already attempted.'}
 $Transaction | Add-Member NoteProperty Completed 'inflight'
 try{$result=Invoke-PrunletFixture -Operation $operation -Arguments @{id=$Transaction.Id};$Transaction.Completed='done';return $result}catch{$Transaction.Completed='unknown';throw}
}
function Get-ProtectedFixtureName($Key) {Invoke-ProtectedFixtureKey $Key 'registry.protected.name'}
function Get-ProtectedFixtureClass($Key) {Invoke-ProtectedFixtureKey $Key 'registry.protected.class'}
function Get-ProtectedFixtureSecurity($Key) { ,[Convert]::FromBase64String((Invoke-ProtectedFixtureKey $Key 'registry.protected.security')) }
function Get-ProtectedFixtureRead($Key) { ,[Convert]::FromBase64String((Invoke-ProtectedFixtureKey $Key 'registry.protected.read')) }
function Get-ProtectedFixtureValue($Key,[string]$Name) {Invoke-ProtectedFixtureKey $Key 'registry.protected.value' @{name=$Name}}
function Set-ProtectedFixtureValue($Key,[byte[]]$Data) {Invoke-ProtectedFixtureKey $Key 'registry.protected.set' @{base64=[Convert]::ToBase64String($Data)}}
function Set-ProtectedFixtureRestriction($Key) {$null=Invoke-ProtectedFixtureKey $Key 'registry.protected.restrict'}
function Restore-ProtectedFixtureDacl {
 param([Parameter(Mandatory)]$Lease,[Parameter(Mandatory)][string]$Relative,[Parameter(Mandatory)][byte[]]$Security)
 if($Lease.Kind-ne'key'-or$Lease.State-ne'active'){throw 'Protected key lease unavailable.'}
 Assert-RegistryFixturePath $Relative
 # native側でもGUID範囲・実効SID・保持keyの名前を照合し、DACLと保護flagだけを復元する。
 $null=Invoke-PrunletFixture -Operation 'registry.protected.restoreDacl' -Arguments @{
  keyLease=$Lease.Id;machine=$script:RegistryFixtureMachine;prefix=$script:RegistryFixturePrefix
  path=$Relative;base64=[Convert]::ToBase64String($Security)
 }
}
