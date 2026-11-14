# Windows fixture観測は候補Coreと独立した、同一PowerShell processの検証DLLで行う。
if (-not (Get-Command Invoke-PrunletFixture -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')
}
. (Join-Path $PSScriptRoot 'SparseFixtures.Common.ps1')

function Get-FileFixtureIdentity {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-PrunletFixture -Operation 'file.identity' -Arguments @{path=$Path}
}
function Get-FileFixtureLegacyIdentity {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-PrunletFixture -Operation 'file.legacy_identity' -Arguments @{path=$Path}
}
function Get-FileFixtureSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    # 1要素の場合も配列のまま呼出元へ渡す。
    $snapshot = Invoke-PrunletFixture -Operation 'file.snapshot' -Arguments @{path=$Path}
    return ,$snapshot
}
function Get-FileFixtureSecurity {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [Convert]::FromBase64String((Invoke-PrunletFixture -Operation 'file.security' -Arguments @{path=$Path}))
    return ,$bytes
}
function Get-FileFixtureNode {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-PrunletFixture -Operation 'file.node' -Arguments @{path=$Path}
}
function Set-FileFixtureDaclOwned {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope,[Parameter(Mandatory)][string]$ExpectedId,[Parameter(Mandatory)][string]$ExpectedCurrentSecurityBase64,[Parameter(Mandatory)][string]$SecurityBase64)
    $null = Invoke-PrunletFixture -Operation 'file.acl.set_owned' -Arguments @{path=$Path;scope=$Scope;expectedId=$ExpectedId;expectedCurrentSecurityBase64=$ExpectedCurrentSecurityBase64;securityBase64=$SecurityBase64}
}
function Get-FileFixtureOpenError {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][uint32]$Access)
    Invoke-PrunletFixture -Operation 'file.open_error' -Arguments @{path=$Path;access=$Access}
}
function Assert-FileFixtureParentCanAdd {
    param([Parameter(Mandatory)][string]$Path)
    $null=Invoke-PrunletFixture -Operation 'file.parent.can_add' -Arguments @{path=$Path}
}
function Get-FileFixtureHandleNode {
    param([Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    if($Handle.IsInvalid-or$Handle.IsClosed){throw 'Fixture handle is closed or invalid.'}
    $added=$false
    try{$Handle.DangerousAddRef([ref]$added);$raw=$Handle.DangerousGetHandle();if($raw-eq[IntPtr]::Zero-or$raw-eq[IntPtr]::new(-1)){throw 'Fixture handle is invalid.'};Invoke-PrunletFixture -Operation 'file.node.borrowed' -Arguments @{handle=[uint64]$raw.ToInt64()}}
    finally{if($added){$Handle.DangerousRelease()}}
}
function Get-FileFixtureTokenElevation {
    param([Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeAccessTokenHandle]$Handle)
    if($Handle.IsInvalid-or$Handle.IsClosed){throw 'Token handle is closed or invalid.'}
    $added=$false
    try{$Handle.DangerousAddRef([ref]$added);$raw=$Handle.DangerousGetHandle();Invoke-PrunletFixture -Operation 'file.token.elevated' -Arguments @{handle=[uint64]$raw.ToInt64()}}
    finally{if($added){$Handle.DangerousRelease()}}
}
function New-FileFixtureHardlink {
    param([Parameter(Mandatory)][string]$Link,[Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Scope)
    $id = Get-FileFixtureIdentity -Path $Source
    $null = Invoke-PrunletFixture -Operation 'file.create_hardlink' -Arguments @{source=$Source;link=$Link;scope=$Scope;expectedId=$id}
}
function Get-FileFixtureCaseSensitive {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-PrunletFixture -Operation 'file.case_sensitive.query' -Arguments @{path=$Path}
}
function New-FileFixtureCaseSensitiveFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope,[Parameter(Mandatory)][string]$ExpectedParentId,[Parameter(Mandatory)][byte[]]$Content)
    $null=Invoke-PrunletFixture -Operation 'file.case_sensitive.create' -Arguments @{path=$Path;scope=$Scope;expectedParentId=$ExpectedParentId;contentBase64=[Convert]::ToBase64String($Content)}
}
function Get-FileFixtureTimes {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope)
    $id=Get-FileFixtureIdentity -Path $Path
    Invoke-PrunletFixture -Operation 'file.times.read' -Arguments @{path=$Path;scope=$Scope;expectedId=$id}
}
function Set-FileFixtureChangeTime {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope)
    $id=Get-FileFixtureIdentity -Path $Path
    $null=Invoke-PrunletFixture -Operation 'file.times.change' -Arguments @{path=$Path;scope=$Scope;expectedId=$id}
}
function Get-FileFixtureListedChangeTime {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope,[Parameter(Mandatory)][string]$Name)
    $id=Get-FileFixtureIdentity -Path $Path
    Invoke-PrunletFixture -Operation 'file.times.listed_change' -Arguments @{path=$Path;scope=$Scope;expectedId=$id;name=$Name}
}
function Find-FileFixtureBinIdentity {
    param([Parameter(Mandatory)][string]$ExpectedId)
    $items = Invoke-PrunletFixture -Operation 'file.bin.find_identity' -Arguments @{expectedId=$ExpectedId}
    return $items
}
function Find-FileFixtureBinNew {
    param([Parameter(Mandatory)][string]$ExpectedId,[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PriorPidls)
    Invoke-PrunletFixture -Operation 'file.bin.find_new' -Arguments @{expectedId=$ExpectedId;priorPidls=@($PriorPidls)}
}
function Restore-FileFixtureOwned {
    param([Parameter(Mandatory)][string]$Pidl,[Parameter(Mandatory)][string]$PhysicalPath,[Parameter(Mandatory)][string]$ExpectedId,[Parameter(Mandatory)][string]$OriginalPath,[Parameter(Mandatory)][string]$Scope)
    Invoke-PrunletFixture -Operation 'file.bin.restore_owned' -Arguments @{pidl=$Pidl;physicalPath=$PhysicalPath;expectedId=$ExpectedId;originalPath=$OriginalPath;scope=$Scope}
}
function Move-FileFixtureOwned {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$ExpectedId,[Parameter(Mandatory)][string]$Scope)
    $null = Invoke-PrunletFixture -Operation 'file.shell.move_owned' -Arguments @{source=$Source;destination=$Destination;expectedId=$ExpectedId;scope=$Scope}
}
function Normalize-FileFixtureReservedDirectory {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$ExpectedId,[Parameter(Mandatory)][string]$Scope)
    $null = Invoke-PrunletFixture -Operation 'file.shell.normalize_reserved_directory' -Arguments @{source=$Source;destination=$Destination;expectedId=$ExpectedId;scope=$Scope}
}

# DELETE拒否・pending観測は同じnative handleを要求の間保持する。
class PrunletFileFixtureAccessLease : System.IDisposable {
    [string]$LeaseId
    [string]$LastLeaseId
    [string]$FileId
    [string]$BaselineSecurityBase64
    [string]$ReleaseState = 'open'
    PrunletFileFixtureAccessLease([string]$path, [string]$scope, [bool]$writableAcl, [string]$expectedId, [string]$expectedSecurityBase64) {
        $id = if ($expectedId) { $expectedId } else { Get-FileFixtureIdentity -Path $path }
        $args = @{path=$path;scope=$scope;expectedId=$id;writableAcl=$writableAcl}
        if ($expectedSecurityBase64) { $args.expectedSecurityBase64 = $expectedSecurityBase64 }
        $lease = Invoke-PrunletFixture -Operation 'file.lease.open' -Arguments $args
        $this.LeaseId = $lease.leaseId
        $this.FileId = $lease.id
        $this.BaselineSecurityBase64 = $lease.baselineSecurityBase64
    }
    [object] State() {
        if (!$this.LeaseId) { throw 'Fixture lease has already been released.' }
        return Invoke-PrunletFixture -Operation 'file.lease.state' -Arguments @{leaseId=$this.LeaseId}
    }
    [void] DenyDelete([bool]$directory) {
        if (!$this.LeaseId) { throw 'Fixture lease has already been released.' }
        $null = Invoke-PrunletFixture -Operation 'file.lease.deny_delete' -Arguments @{leaseId=$this.LeaseId;directory=$directory}
    }
    [void] DenyRead() {
        if (!$this.LeaseId) { throw 'Fixture lease has already been released.' }
        $null = Invoke-PrunletFixture -Operation 'file.lease.deny_read' -Arguments @{leaseId=$this.LeaseId}
    }
    [void] Dispose() {
        if ($this.ReleaseState -ne 'open' -or !$this.LeaseId) { return }
        $id = $this.LeaseId; $this.LastLeaseId = $id; $this.LeaseId = ''; $this.ReleaseState = 'inflight'
        try { $null = Invoke-PrunletFixture -Operation 'file.lease.release' -Arguments @{leaseId=$id}; $this.ReleaseState = 'closed' }
        catch { $this.ReleaseState = 'unknown'; throw }
    }
}
function New-FileFixtureAccessLease {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope,[switch]$WritableAcl,[string]$ExpectedId,[string]$ExpectedSecurityBase64)
    [PrunletFileFixtureAccessLease]::new($Path,$Scope,[bool]$WritableAcl,$ExpectedId,$ExpectedSecurityBase64)
}

class PrunletFileFixtureHold : System.IDisposable {
    [string]$LeaseId
    [string]$LastLeaseId
    [string]$ReleaseState = 'open'
    PrunletFileFixtureHold([string]$path, [string]$scope, [string]$mode) {
        $id = Get-FileFixtureIdentity -Path $path
        $lease = Invoke-PrunletFixture -Operation 'file.hold.open' -Arguments @{path=$path;scope=$scope;mode=$mode;expectedId=$id}
        $this.LeaseId = $lease.leaseId
    }
    [void] Dispose() {
        if ($this.ReleaseState -ne 'open' -or !$this.LeaseId) { return }
        $id = $this.LeaseId; $this.LastLeaseId = $id; $this.LeaseId = ''; $this.ReleaseState = 'inflight'
        try { $null = Invoke-PrunletFixture -Operation 'file.hold.release' -Arguments @{leaseId=$id}; $this.ReleaseState = 'closed' }
        catch { $this.ReleaseState = 'unknown'; throw }
    }
}
function New-FileFixtureHold {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope,[ValidateSet('no-delete','parent','report-parent')][string]$Mode='no-delete')
    [PrunletFileFixtureHold]::new($Path,$Scope,$Mode)
}

# module leaseの所有者はDLL。不明なreleaseは再送せず、local状態とIDを保全する。
class PrunletFileFixtureModuleLease : System.IDisposable {
    [string]$LeaseId
    [string]$LastLeaseId
    [string]$ReleaseState = 'open'
    [uint32]$ProcessId
    [string]$FileId
    PrunletFileFixtureModuleLease([string]$path) {
        $lease = Invoke-PrunletFixture -Operation 'file.module.load' -Arguments @{path=$path}
        $this.LeaseId = $lease.leaseId
        $this.ProcessId = $lease.processId
        $this.FileId = $lease.fileId
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try { if ($this.ProcessId -ne $process.Id) { throw 'Fixture module loaded in a different process.' } }
        finally { $process.Dispose() }
    }
    [void] Dispose() {
        if ($this.ReleaseState -ne 'open' -or !$this.LeaseId) { return }
        $id = $this.LeaseId; $this.LastLeaseId = $id; $this.LeaseId = ''; $this.ReleaseState = 'inflight'
        try { $null = Invoke-PrunletFixture -Operation 'file.module.release' -Arguments @{leaseId=$id}; $this.ReleaseState = 'closed' }
        catch { $this.ReleaseState = 'unknown'; throw }
    }
}
function New-FileFixtureModuleLease {
    param([Parameter(Mandatory)][string]$Path)
    [PrunletFileFixtureModuleLease]::new($Path)
}

# Jobは同じPowerShell process内で保持し、応答不明時の解放を再送しない。
class PrunletFileFixtureJob : System.IDisposable {
    [string]$LeaseId
    [string]$LastLeaseId
    [string]$ReleaseState='open'
    PrunletFileFixtureJob([Diagnostics.Process]$process) {
        $handle=$process.SafeHandle;$added=$false
        try{$handle.DangerousAddRef([ref]$added);$raw=$handle.DangerousGetHandle();$job=Invoke-PrunletFixture -Operation 'file.job.open' -Arguments @{processHandle=[uint64]$raw.ToInt64()};$this.LeaseId=$job.leaseId}
        finally{if($added){$handle.DangerousRelease()}}
    }
    [double] CpuMilliseconds() {
        if(!$this.LeaseId){throw 'Job fixture has already been released.'}
        return Invoke-PrunletFixture -Operation 'file.job.cpu' -Arguments @{leaseId=$this.LeaseId}
    }
    [void] Dispose() {
        if($this.ReleaseState-ne'open'-or!$this.LeaseId){return}
        $id=$this.LeaseId;$this.LastLeaseId=$id;$this.LeaseId='';$this.ReleaseState='inflight'
        try{$null=Invoke-PrunletFixture -Operation 'file.job.release' -Arguments @{leaseId=$id};$this.ReleaseState='closed'}catch{$this.ReleaseState='unknown';throw}
    }
}
function New-FileFixtureJob {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    [PrunletFileFixtureJob]::new($Process)
}
function Find-FileFixtureChildProcess {
    param([Parameter(Mandatory)][uint32]$ParentId,[Parameter(Mandatory)][string]$ExecutablePath)
    $ids=Invoke-PrunletFixture -Operation 'file.process.children' -Arguments @{parentPid=$ParentId}
    foreach($id in $ids){
        $child=$null;$matched=$false
        try{$child=[Diagnostics.Process]::GetProcessById([int]$id);if([string]::Equals($child.MainModule.FileName,$ExecutablePath,[StringComparison]::OrdinalIgnoreCase)){$null=$child.SafeHandle;$matched=$true}}
        catch{$cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException};if($cause-isnot[System.InvalidOperationException]-and$cause-isnot[System.ArgumentException]-and$cause-isnot[System.ComponentModel.Win32Exception]){if($child){$child.Dispose()};throw}}
        if($matched){return $child}
        if($child){$child.Dispose()}
    }
}
