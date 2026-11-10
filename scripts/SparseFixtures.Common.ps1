# sparse helperは同じprocessのRust DLLへ委譲する。scopeと証拠を明示してfixtureを固定する。
if (-not (Get-Command Invoke-PrunletFixture -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FixtureBridge.Common.ps1')
}
function Set-FileFixtureSparse {
    param([Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    if ($Handle.IsInvalid -or $Handle.IsClosed) { throw 'Sparse fixture handle is closed or invalid.' }
    $added = $false
    try {
        # FileStream所有のhandleを借りる間だけ寿命を延長する。Rust側は閉じない。
        $Handle.DangerousAddRef([ref]$added)
        $raw = $Handle.DangerousGetHandle()
        if ($raw -eq [IntPtr]::Zero -or $raw -eq [IntPtr]::new(-1)) { throw 'Sparse fixture handle is invalid.' }
        $null = Invoke-PrunletFixture -Operation 'file.sparse.make' -Arguments @{handle=[uint64]$raw.ToInt64()}
    } finally { if ($added) { $Handle.DangerousRelease() } }
}
function Get-FileFixtureSparseProof {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope)
    Invoke-PrunletFixture -Operation 'file.sparse.proof' -Arguments @{path=$Path;scope=$Scope}
}
function Get-FileFixtureSparseRanges {
    param([Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
          [Parameter(Mandatory)][long]$Length,[Parameter(Mandatory)][uint64]$MaximumAllocation)
    if ($Handle.IsInvalid -or $Handle.IsClosed) { throw 'Sparse fixture handle is closed or invalid.' }
    $added = $false
    try {
        # 呼出元のexclusive FileStreamを借用し、範囲照会後も同じhandleで内容を検証できる。
        $Handle.DangerousAddRef([ref]$added)
        $raw = $Handle.DangerousGetHandle()
        if ($raw -eq [IntPtr]::Zero -or $raw -eq [IntPtr]::new(-1)) { throw 'Sparse fixture handle is invalid.' }
        $result = Invoke-PrunletFixture -Operation 'file.sparse.ranges' -Arguments @{handle=[uint64]$raw.ToInt64();length=$Length;maximumAllocation=$MaximumAllocation}
        return ,$result
    } finally { if ($added) { $Handle.DangerousRelease() } }
}
function Restore-FileFixtureSparseTiny {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Scope,
          [Parameter(Mandatory)][string]$ExpectedId,[Parameter(Mandatory)][string]$ExpectedSecurityBase64,
          [Parameter(Mandatory)][uint32]$ExpectedAttributes,[Parameter(Mandatory)][long]$ExpectedLogicalLength,
          [Parameter(Mandatory)][byte[]]$Prefix,[Parameter(Mandatory)][uint64]$MaximumAllocation)
    Invoke-PrunletFixture -Operation 'file.sparse.restore_tiny' -Arguments @{
        path=$Path;scope=$Scope;expectedId=$ExpectedId;expectedSecurityBase64=$ExpectedSecurityBase64
        expectedAttributes=$ExpectedAttributes;expectedLogicalLength=$ExpectedLogicalLength
        prefixBase64=[Convert]::ToBase64String($Prefix);maximumAllocation=$MaximumAllocation
    }
}
function Get-FileFixtureSparseAllocation {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-PrunletFixture -Operation 'file.sparse.allocation' -Arguments @{path=$Path}
}
function Get-FileFixtureBinTotals {
    param([Parameter(Mandatory)][string]$RootPath)
    $totals = Invoke-PrunletFixture -Operation 'file.sparse.bin_totals' -Arguments @{rootPath=$RootPath}
    return ,$totals
}
