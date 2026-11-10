# 製品・probe・導入fixtureで同じ入力集合を使う。新規Cargo設定も集合の変化で検知する。
function Get-PrunletRustInputNames([string]$SourceRoot) {
    $names = [Collections.Generic.List[string]]::new()
    foreach ($name in @('Cargo.toml','Cargo.lock','build.rs','rust-toolchain.toml')) { $names.Add($name) }
    foreach ($tree in @('src/rust','tools/prunlet-fixtures','tools/prunlet-support','.cargo')) {
        $root = Join-Path $SourceRoot $tree
        try { $null = Get-Item -LiteralPath $root -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { if ($tree -ne '.cargo') { throw "Rust source directory is absent: $tree" }; continue }
        $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($root)
        while ($pending.Count) {
            $directory = $pending.Pop()
            $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Rust/Cargo input directories must be plain directories.' }
            foreach ($entry in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Rust/Cargo build inputs cannot be links.' }
                if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
                else { $names.Add([IO.Path]::GetRelativePath($SourceRoot,$entry.FullName).Replace('\','/')) }
            }
        }
    }
    $names.Sort([StringComparer]::Ordinal)
    foreach ($name in $names) {
        $item = Get-Item -LiteralPath (Join-Path $SourceRoot $name) -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Rust/Cargo build inputs must be plain files.' }
    }
    return $names.ToArray()
}

function Get-PrunletRustInputSnapshot([string]$SourceRoot) {
    $records = @(Get-PrunletRustInputNames $SourceRoot | ForEach-Object {
        [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    # 相対パスと内容hashの組を明示的なUTF-8形式にして、検証runnerと一致させる。
    $lines = [Text.StringBuilder]::new()
    foreach ($record in $records) { [void]$lines.Append($record.path).Append("`t").Append($record.sha256).Append("`n") }
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($lines.ToString())
    return [ordered]@{ sources = $records; fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
}

function Get-PrunletCargoEnvironmentInputs([string]$SourceRoot) {
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($directory = Split-Path $SourceRoot -Parent; $directory; $directory = Split-Path $directory -Parent) {
        foreach ($name in @('config','config.toml')) { [void]$paths.Add((Join-Path $directory ".cargo/$name")) }
    }
    $cargoConfigurationRoot = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
    if (![IO.Path]::IsPathFullyQualified($cargoConfigurationRoot)) { throw 'CARGO_HOME must be absolute for a verified build.' }
    foreach ($name in @('config','config.toml')) { [void]$paths.Add((Join-Path $cargoConfigurationRoot $name)) }
    $ordered = @($paths); [Array]::Sort($ordered,[StringComparer]::Ordinal)
    $records = @($ordered | ForEach-Object {
        $path = $_
        for ($ancestor = $path; $ancestor; $ancestor = Split-Path $ancestor -Parent) {
            try { $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop }
            catch [System.Management.Automation.ItemNotFoundException] { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($ancestor -ine $path -and !$item.PSIsContainer) -or ($ancestor -ieq $path -and $item.PSIsContainer)) { throw 'Cargo environment configuration must use plain paths.' }
        }
        [ordered]@{ path = $path; exists = (Test-Path -LiteralPath $path -PathType Leaf); sha256 = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null } }
    })
    # 設定本文やproxy資格情報等は記録しない。存在とhashだけを前後固定する。
    return $records
}
function Get-PrunletRustToolchain([string]$SourceRoot) {
    # 正本で使う単一toolchain表と固定stable版の限定形式だけを受け付ける。
    $path = Join-Path $SourceRoot 'rust-toolchain.toml'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Rust toolchain input must be a plain file.' }
    $section = $false
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $channel = $null
    foreach ($raw in [IO.File]::ReadAllLines($path)) {
        $line = ($raw -replace '#.*$', '').Trim()
        if (!$line) { continue }
        if ($line -ceq '[toolchain]' -and !$section) { $section = $true; continue }
        if (!$section -or $line -cnotmatch '^(channel|profile|components|targets)\s*=\s*(.+)$') { throw 'Unsupported rust-toolchain.toml syntax.' }
        $key = $Matches[1]; $value = $Matches[2]
        if (!$keys.Add($key)) { throw 'Duplicate Rust toolchain field.' }
        switch -CaseSensitive ($key) {
            'channel' {
                if ($value -cnotmatch '^"([1-9][0-9]*\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"$') { throw 'Rust channel must be an exact stable version.' }
                $channel = $Matches[1]
            }
            'profile' { if ($value -cnotmatch '^"(?:minimal|default|complete)"$') { throw 'Unsupported Rust toolchain profile.' } }
            default { if ($value -cnotmatch '^\[\s*(?:"[A-Za-z0-9_-]+"\s*(?:,\s*"[A-Za-z0-9_-]+"\s*)*,?\s*)?\]$') { throw 'Unsupported Rust toolchain list.' } }
        }
    }
    if (!$channel) { throw 'Rust toolchain channel is missing.' }
    return $channel
}
