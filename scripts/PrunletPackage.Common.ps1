#requires -Version 7.2
# Linux・mac の配布物（tar.gz・ZIP）の中身を、配信側で独立に検査する。
# 検査内容は現クライアント（src/rust/platform/linux/package.rs・platform/macos/startup.rs）の要件と同じ:
#   Linux: ustar の tar.gz で `prunlet`、`manifest.json` の 2 つだけ。manifest は bytes,commit,runtime,sha256,version の 5 キーだけ。
#   mac:   ZIP で `prunlet` と `manifest.json` の 2 項目だけ。manifest は protocol,version,commit,runtime,bytes,sha256。
#   どちらも実行体の長さ・SHA-256 が manifest と一致し、版・commit・runtime が配信の入力と一致し、各上限は 64 MiB 以下。
# Apple の署名・公証の検証はここでは行わない（クライアント側の責任）。
Set-StrictMode -Version Latest

$script:PrunletUnixMaxBytes = 64MB

function Read-PrunletStrictJsonObject {
    # 重複キー・非オブジェクト・不正な UTF-8 を拒否して、トップレベルのプロパティを返す（値は JsonElement のまま）。
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string[]]$ExpectedKeys)
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false, $true).GetString($Bytes))
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'not an object' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $map = @{}
        foreach ($property in $document.RootElement.EnumerateObject()) {
            if (!$names.Add($property.Name)) { throw 'duplicate key' }
            # JsonElement は Dispose 後も使えるよう、文字列と数値だけをコピーする。
            $map[$property.Name] = switch ($property.Value.ValueKind) {
                ([Text.Json.JsonValueKind]::String) { $property.Value.GetString(); break }
                ([Text.Json.JsonValueKind]::Number) { $property.Value.GetInt64(); break }
                default { throw 'unsupported value' }
            }
        }
        if (!$names.SetEquals($ExpectedKeys)) { throw 'unexpected keys' }
        return $map
    } catch { Stop-PrunletRelease 'package' 'invalid-manifest' } finally { if ($null -ne $document) { $document.Dispose() } }
}

function Assert-PrunletUnixManifest {
    # 実行体と manifest（bytes・sha256・版・commit・runtime）の一致を確認する。
    param([Parameter(Mandatory)][hashtable]$Manifest, [Parameter(Mandatory)][byte[]]$Executable,
        [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$CommitSha, [Parameter(Mandatory)][string]$Runtime)
    if ($Manifest['version'] -cne $Version -or $Manifest['commit'] -cne $CommitSha -or $Manifest['runtime'] -cne $Runtime) { Stop-PrunletRelease 'package' 'identity-mismatch' }
    if ($Executable.Length -lt 32 -or $Executable.Length -gt $script:PrunletUnixMaxBytes) { Stop-PrunletRelease 'package' 'invalid-executable' }
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Executable)).ToLowerInvariant()
    if ($Manifest['bytes'] -ne $Executable.Length -or $Manifest['sha256'] -cne $sha) { Stop-PrunletRelease 'package' 'executable-mismatch' }
}

function Assert-PrunletLinuxPackage {
    # tar.gz（ustar）を読み、エントリの順序・種類・長さ・manifest・実行体を検査する。展開はしない。
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Runtime, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$CommitSha)
    $info = [IO.FileInfo]::new($Path)
    if (!$info.Exists -or $info.Length -le 0 -or $info.Length -gt $script:PrunletUnixMaxBytes) { Stop-PrunletRelease 'package' 'invalid-size' }
    $file = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $gzip = $null; $reader = $null
    try {
        $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress, $true)
        $reader = [Formats.Tar.TarReader]::new($gzip, $true)
        $names = @(); $data = @{}
        while ($null -ne ($entry = $reader.GetNextEntry($false))) {
            if ($entry.EntryType -ne [Formats.Tar.TarEntryType]::RegularFile -or $entry.Format -ne [Formats.Tar.TarEntryFormat]::Ustar -or $entry.Length -gt $script:PrunletUnixMaxBytes) { throw 'entry' }
            $names += $entry.Name
            $memory = [IO.MemoryStream]::new()
            try { $entry.DataStream.CopyTo($memory); $data[$entry.Name] = $memory.ToArray() } finally { $memory.Dispose() }
        }
        if (($names -join '|') -cne 'prunlet|manifest.json') { throw 'entries' }
    } catch { Stop-PrunletRelease 'package' 'invalid-archive' } finally {
        if ($null -ne $reader) { $reader.Dispose() }; if ($null -ne $gzip) { $gzip.Dispose() }; $file.Dispose()
    }
    if ($data['manifest.json'].Length -gt 4096) { Stop-PrunletRelease 'package' 'invalid-manifest' }
    $manifest = Read-PrunletStrictJsonObject -Bytes $data['manifest.json'] -ExpectedKeys @('bytes', 'commit', 'runtime', 'sha256', 'version')
    Assert-PrunletUnixManifest -Manifest $manifest -Executable $data['prunlet'] -Version $Version -CommitSha $CommitSha -Runtime $Runtime
}

function Assert-PrunletMacPackage {
    # mac の ZIP（`prunlet` と `manifest.json` の 2 項目）を検査する。-Bytes はメモリ上の ZIP 全体。
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$CommitSha)
    if ($Bytes.Length -le 0 -or $Bytes.Length -gt $script:PrunletUnixMaxBytes) { Stop-PrunletRelease 'package' 'invalid-size' }
    $stream = [IO.MemoryStream]::new($Bytes, $false)
    $archive = $null; $data = @{}
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        if ($archive.Entries.Count -ne 2) { throw 'entry count' }
        foreach ($entry in $archive.Entries) {
            if (($entry.FullName -cne 'prunlet' -and $entry.FullName -cne 'manifest.json') -or $data.ContainsKey($entry.FullName) -or $entry.Length -gt $script:PrunletUnixMaxBytes) { throw 'entry' }
            $memory = [IO.MemoryStream]::new(); $source = $entry.Open()
            try { $source.CopyTo($memory); $data[$entry.FullName] = $memory.ToArray() } finally { $source.Dispose(); $memory.Dispose() }
        }
    } catch { Stop-PrunletRelease 'package' 'invalid-archive' } finally { if ($null -ne $archive) { $archive.Dispose() }; $stream.Dispose() }
    if ($data['manifest.json'].Length -gt 4096) { Stop-PrunletRelease 'package' 'invalid-manifest' }
    $manifest = Read-PrunletStrictJsonObject -Bytes $data['manifest.json'] -ExpectedKeys @('protocol', 'version', 'commit', 'runtime', 'bytes', 'sha256')
    if ($manifest['protocol'] -ne 1) { Stop-PrunletRelease 'package' 'identity-mismatch' }
    Assert-PrunletUnixManifest -Manifest $manifest -Executable $data['prunlet'] -Version $Version -CommitSha $CommitSha -Runtime 'osx-arm64'
    # クライアントと同じ最小の形（薄い arm64 Mach-O の先頭 8 バイト）。署名・公証の検証はクライアントの責任。
    $magic = [byte[]]@(0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1)
    if (!(Test-PrunletReleaseBytesEqual ([byte[]]$data['prunlet'][0..7]) $magic)) { Stop-PrunletRelease 'package' 'not-arm64-macho' }
}
