# 検証専用Rust DLLを呼出し元のprocessへ固定する。製品CoreやC# compilerは使わない。
function Get-PrunletFixtureProcessBinding { [AppDomain]::CurrentDomain.GetData('Prunlet.Verification.FixtureBridge.v1') }
function Set-PrunletFixtureProcessBinding($Value) { [AppDomain]::CurrentDomain.SetData('Prunlet.Verification.FixtureBridge.v1', $Value) }

function Assert-PrunletFixturePlainPath([string]$Path) {
    if (![IO.Path]::IsPathFullyQualified($Path)) { throw 'Fixture library inputs must be absolute paths.' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'Fixture input must be an ordinary file.' }
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture inputs cannot pass through reparse points.' }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function New-PrunletFixtureDirectoryPins([string]$FilePath) {
    # 祖先をrootから順に、rename/deleteを共有しないhandleで固定する。
    $full = [IO.Path]::GetFullPath($FilePath)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'Fixture DLL must be on a local drive without alternate streams.' }
    $open = New-PrunletNativeDelegate -Library kernel32.dll -Export CreateFileW -ReturnType ([IntPtr]) -ParameterTypes @([string],[uint32],[uint32],[IntPtr],[uint32],[uint32],[IntPtr])
    $info = New-PrunletNativeDelegate -Library kernel32.dll -Export GetFileInformationByHandleEx -ReturnType ([bool]) -ParameterTypes @([IntPtr],[int],[IntPtr],[uint32])
    $paths = [Collections.Generic.List[string]]::new()
    for ($cursor = [IO.Path]::GetDirectoryName($full); $cursor; $cursor = Split-Path -Parent $cursor) { $paths.Add($cursor) }
    $paths.Reverse()
    $pins = [Collections.Generic.List[IDisposable]]::new()
    try {
        foreach ($directory in $paths) {
            $raw = $open.Invoke($directory, [uint32]0x80, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0x02200000, [IntPtr]::Zero)
            if ($raw -eq [IntPtr]::new(-1)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
            $handle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($raw, $true)
            $pins.Add($handle)
            $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
            try {
                if (!$info.Invoke($raw, 9, $buffer, [uint32]8)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
                $attributes = [Runtime.InteropServices.Marshal]::ReadInt32($buffer)
                if (($attributes -band 0x400) -or !($attributes -band 0x10)) { throw 'Fixture DLL ancestor is a reparse point or not a directory.' }
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
        }
        return ,$pins
    } catch { foreach ($pin in $pins) { $pin.Dispose() }; throw }
}

function Get-PrunletFixtureHandleIdentity([IO.FileStream]$Stream) {
    $info = New-PrunletNativeDelegate -Library kernel32.dll -Export GetFileInformationByHandleEx -ReturnType ([bool]) -ParameterTypes @([IntPtr],[int],[IntPtr],[uint32])
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
    try {
        if (!$info.Invoke($Stream.SafeFileHandle.DangerousGetHandle(), 18, $buffer, [uint32]24)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
        $bytes = [byte[]]::new(24); [Runtime.InteropServices.Marshal]::Copy($buffer, $bytes, 0, 24)
        return [Convert]::ToHexString($bytes)
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
}

function Open-PrunletFixtureFilePin([string]$Path) {
    $open = New-PrunletNativeDelegate -Library kernel32.dll -Export CreateFileW -ReturnType ([IntPtr]) -ParameterTypes @([string],[uint32],[uint32],[IntPtr],[uint32],[uint32],[IntPtr])
    $info = New-PrunletNativeDelegate -Library kernel32.dll -Export GetFileInformationByHandleEx -ReturnType ([bool]) -ParameterTypes @([IntPtr],[int],[IntPtr],[uint32])
    $raw = $open.Invoke($Path, [uint32]2147483648, [uint32]1, [IntPtr]::Zero, [uint32]3, [uint32]0x00200000, [IntPtr]::Zero)
    if ($raw -eq [IntPtr]::new(-1)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
    $handle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($raw, $true)
    try {
        $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
        try {
            if (!$info.Invoke($raw, 9, $buffer, [uint32]8)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastPInvokeError()) }
            if ([Runtime.InteropServices.Marshal]::ReadInt32($buffer) -band 0x410) { throw 'Fixture input is a directory or reparse point.' }
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
        return [IO.FileStream]::new($handle, [IO.FileAccess]::Read)
    } catch { $handle.Dispose(); throw }
}

function Import-PrunletFixtureLibrary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LibraryPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256
    )
    $gate = [string]::Intern('Prunlet.Verification.FixtureBridge.Import.v1')
    [Threading.Monitor]::Enter($gate)
    try {
    $binding = Get-PrunletFixtureProcessBinding
    Assert-PrunletFixturePlainPath $LibraryPath
    $LibraryPath = [IO.Path]::GetFullPath($LibraryPath)
    if ($binding) {
        if ($binding.fault) { throw 'Fixture import previously failed; use a new process.' }
        if (!$binding.path.Equals($LibraryPath, [StringComparison]::OrdinalIgnoreCase) -or
            !$binding.sha256.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A different fixture DLL is already fixed in this process. Use a new verification process.'
        }
        return $binding.identity
    }
    if (!(Get-Command New-PrunletNativeDelegate -ErrorAction SilentlyContinue)) {
        # Prepareでコピーされた固定入力を優先し、通常起動はソースの共通OS連携を使う。
        $interop = Join-Path $PSScriptRoot 'configuration-common.ps1'
        if (!(Test-Path -LiteralPath $interop -PathType Leaf)) {
            $interop = Join-Path (Split-Path -Parent $PSScriptRoot) 'integration/configuration-common.ps1'
        }
        Assert-PrunletFixturePlainPath $interop
        . $interop
    }
    $directoryPins = New-PrunletFixtureDirectoryPins $LibraryPath
    $pin = $null
    try {
        # 祖先の固定後にもう一度通常fileを確認し、同一実体のhashとimageを認定する。
        Assert-PrunletFixturePlainPath $LibraryPath
        $pin = Open-PrunletFixtureFilePin $LibraryPath
        $hash = (Get-FileHash -InputStream $pin -Algorithm SHA256).Hash
        $pin.Position = 0
        if (!$hash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture DLL hash differs.' }
        $fixedIdentity = Get-PrunletFixtureHandleIdentity $pin
        $binding = @{ path = $LibraryPath; sha256 = $hash; pin = $pin; directoryPins = $directoryPins; call = $null; free = $null; identity = $null; fault = $false }
        Set-PrunletFixtureProcessBinding $binding
        $module = [Runtime.InteropServices.NativeLibrary]::Load($LibraryPath)
        $binding.module = $module
        $moduleName = New-PrunletNativeDelegate -Library kernel32.dll -Export GetModuleFileNameW -ReturnType ([uint32]) -ParameterTypes @([IntPtr],[Text.StringBuilder],[uint32])
        $modulePath = [Text.StringBuilder]::new(32768)
        $characters = $moduleName.Invoke($module, $modulePath, [uint32]$modulePath.Capacity)
        if (!$characters -or $characters -ge $modulePath.Capacity) { throw 'Cannot identify the loaded fixture image.' }
        Assert-PrunletFixturePlainPath $modulePath.ToString()
        $imagePin = Open-PrunletFixtureFilePin $modulePath.ToString()
        try { if ((Get-PrunletFixtureHandleIdentity $imagePin) -cne $fixedIdentity) { throw 'Loaded fixture image differs from its fixed file.' } } finally { $imagePin.Dispose() }
        $call = New-PrunletNativeDelegate -Library $LibraryPath -Export 'prunlet_fixture_call' -ReturnType ([IntPtr]) -ParameterTypes @([IntPtr], [UIntPtr], [IntPtr])
        $free = New-PrunletNativeDelegate -Library $LibraryPath -Export 'prunlet_fixture_free' -ReturnType ([void]) -ParameterTypes @([IntPtr], [UIntPtr])
        $binding.call = $call; $binding.free = $free
        $identity = Invoke-PrunletFixture -Operation 'bridge.identity' -Arguments @{}
        if ($identity.product -cne 'PrunletVerificationFixtures' -or $identity.schema -ne 1 -or
            $identity.processId -ne $PID -or $identity.pointerBytes -ne [IntPtr]::Size) {
            throw 'Fixture DLL does not identify this process/ABI.'
        }
        $binding.identity = $identity
        return $identity
    } catch {
        # NativeLibraryはdelegateの生存中にunloadしない。pinの失敗だけを閉じる。
        if ($binding) { $binding.fault = $true } else { if ($pin) { $pin.Dispose() }; foreach ($directoryPin in $directoryPins) { $directoryPin.Dispose() } }
        throw
    }
    } finally { [Threading.Monitor]::Exit($gate) }
}

function Invoke-PrunletFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $binding = Get-PrunletFixtureProcessBinding
    if (!$binding) { throw 'Import a hash-fixed fixture DLL before using it.' }
    if ($binding.fault) { throw 'Fixture DLL binding is faulted; use a new process.' }
    $json = @{ operation = $Operation; arguments = $Arguments } | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($json)
    if (!$bytes.Length -or $bytes.Length -gt 67108864) { throw 'Fixture request exceeds its bound.' }
    $inputMemory = [IntPtr]::Zero; $lengthMemory = [IntPtr]::Zero; $outputMemory = [IntPtr]::Zero
    [UInt64]$outputLength = 0
    try {
        $inputMemory = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
        [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $inputMemory, $bytes.Length)
        $lengthMemory = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($lengthMemory, [IntPtr]::Zero)
        # ここが唯一の実行。応答が読めなくても同じ要求を自動再送しない。
        $outputMemory = $binding.call.Invoke($inputMemory, [UIntPtr]$bytes.Length, $lengthMemory)
        $outputLength = [UInt64][Runtime.InteropServices.Marshal]::ReadIntPtr($lengthMemory).ToInt64()
        if ($outputMemory -eq [IntPtr]::Zero -or !$outputLength -or $outputLength -gt 67108864) {
            throw 'Fixture response is unavailable or out of bounds; inspect its state without resending.'
        }
        $responseBytes = [byte[]]::new([int]$outputLength)
        [Runtime.InteropServices.Marshal]::Copy($outputMemory, $responseBytes, 0, $responseBytes.Length)
        $response = [Text.UTF8Encoding]::new($false, $true).GetString($responseBytes) | ConvertFrom-Json -Depth 100
        if ($response.ok -ne $true) {
            $exception = [InvalidOperationException]::new([string]$response.error)
            $exception.Data['FixtureOperation'] = $Operation
            if ($null -ne $response.win32) { $exception.Data['Win32Error'] = [int]$response.win32 }
            throw $exception
        }
        # NoEnumerateはscalarまでListへ包むため使わない。JSON配列だけを1つの値として返す。
        if ($response.value -is [array]) { return ,$response.value }
        return $response.value
    } finally {
        if ($outputMemory -ne [IntPtr]::Zero -and $outputLength -gt 0) {
            $binding.free.Invoke($outputMemory, [UIntPtr]$outputLength)
        }
        if ($lengthMemory -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($lengthMemory) }
        if ($inputMemory -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($inputMemory) }
    }
}

function Initialize-PrunletFixtureBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [string]$BuildManifestPath,
        [string]$ExpectedBuildManifestSha256,
        [string]$SourceRoot
    )
    Assert-PrunletFixturePlainPath $ExecutablePath
    if (!$BuildManifestPath) {
        $BuildManifestPath = Join-Path (Split-Path -Parent (Split-Path -Parent $ExecutablePath)) 'build-manifest.json'
    }
    Assert-PrunletFixturePlainPath $BuildManifestPath
    if (!(Get-Command New-PrunletNativeDelegate -ErrorAction SilentlyContinue)) {
        $interop = Join-Path $PSScriptRoot 'configuration-common.ps1'
        if (!(Test-Path -LiteralPath $interop -PathType Leaf)) { $interop = Join-Path (Split-Path -Parent $PSScriptRoot) 'integration/configuration-common.ps1' }
        Assert-PrunletFixturePlainPath $interop
        . $interop
    }
    $manifestDirectoryPins = New-PrunletFixtureDirectoryPins $BuildManifestPath
    $manifestPin = $null
    try {
        $manifestPin = Open-PrunletFixtureFilePin $BuildManifestPath
        $manifestHash = (Get-FileHash -InputStream $manifestPin -Algorithm SHA256).Hash
        $manifestPin.Position = 0
        if ($ExpectedBuildManifestSha256 -and !$manifestHash.Equals($ExpectedBuildManifestSha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture build manifest hash differs.' }
        $reader = [IO.StreamReader]::new($manifestPin, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -Depth 100 } finally { $reader.Dispose() }
        if ($manifest.schema -ne 1 -or !$manifest.verificationTools -or !$manifest.verificationTools.Contains('prunlet_fixtures.dll')) { throw 'Build with -IncludeVerificationProbe to obtain fixed Rust fixtures.' }
        if (!(Get-FileHash -LiteralPath $ExecutablePath).Hash.Equals([string]$manifest.product.sha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture candidate executable differs from the build manifest.' }
        if (!$SourceRoot) {
            for ($cursor = $PSScriptRoot; $cursor; $cursor = Split-Path -Parent $cursor) {
                if (Test-Path -LiteralPath (Join-Path $cursor 'Cargo.toml') -PathType Leaf) { $SourceRoot = $cursor; break }
            }
        }
        if (!$SourceRoot -or ![IO.Path]::IsPathFullyQualified($SourceRoot)) { throw 'A fixed Rust source root is required for fixture verification.' }
        $snapshotHelper = Join-Path $SourceRoot 'scripts/RustBuildInputs.Common.ps1'
        Assert-PrunletFixturePlainPath $snapshotHelper
        . $snapshotHelper
        $snapshot = Get-PrunletRustInputSnapshot $SourceRoot
        if ($snapshot.fingerprint -cne $manifest.sourceFingerprint) { throw 'Fixture Rust sources differ from this build; rebuild before verification.' }
        $relative = [string]$manifest.verificationTools['prunlet_fixtures.dll'].relativePath
        if ($relative -cne 'publish/prunlet_fixtures.dll') { throw 'Fixture DLL location differs from the build layout.' }
        $library = Join-Path (Split-Path -Parent $BuildManifestPath) $relative
        $identity = Import-PrunletFixtureLibrary -LibraryPath $library -ExpectedSha256 $manifest.verificationTools['prunlet_fixtures.dll'].sha256
        # DLLと同じprocess lifetimeでmanifestも固定する。Prepareのinput pinsも別途維持する。
        $binding = Get-PrunletFixtureProcessBinding
        $manifestGate = [string]::Intern('Prunlet.Verification.FixtureBridge.Import.v1')
        [Threading.Monitor]::Enter($manifestGate)
        try {
        if ($binding.ContainsKey('manifestPin')) {
            if (![IO.Path]::GetFullPath($BuildManifestPath).Equals($binding.manifestPath, [StringComparison]::OrdinalIgnoreCase) -or $manifestHash -cne $binding.manifestHash) { throw 'A different fixture manifest is already fixed in this process.' }
        } else {
            $binding.manifestPath = [IO.Path]::GetFullPath($BuildManifestPath); $binding.manifestHash = $manifestHash
            $binding.manifestPin = $manifestPin; $manifestPin = $null
            $binding.manifestDirectoryPins = $manifestDirectoryPins; $manifestDirectoryPins = $null
        }
        } finally { [Threading.Monitor]::Exit($manifestGate) }
        return $identity
    } finally { if ($manifestPin) { $manifestPin.Dispose() }; if ($manifestDirectoryPins) { foreach ($directoryPin in $manifestDirectoryPins) { $directoryPin.Dispose() } } }
}
