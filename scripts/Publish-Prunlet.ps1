[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64'
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (-not [IO.Path]::IsPathFullyQualified($OutputDirectory)) { throw 'OutputDirectory must be absolute.' }
$codexRoot = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
foreach ($forbiddenRoot in @($repoRoot, $codexRoot, (Join-Path $env:USERPROFILE '.codex'))) {
    if ($outputRoot.Equals($forbiddenRoot, [StringComparison]::OrdinalIgnoreCase) -or $outputRoot.StartsWith($forbiddenRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Build output must be outside the repository and Codex home.'
    }
}
$ancestor = $outputRoot
while (-not (Test-Path -LiteralPath $ancestor)) { $ancestor = Split-Path -Parent $ancestor }
while ($ancestor) {
    if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build output cannot traverse links.' }
    $ancestor = Split-Path -Parent $ancestor
}
$intermediate = Join-Path $outputRoot 'obj'
$publish = Join-Path $outputRoot 'publish'
New-Item -ItemType Directory -Path $intermediate, $publish -Force | Out-Null
& dotnet publish (Join-Path $repoRoot 'src\Prunlet\Prunlet.csproj') -c Release -r $Runtime --self-contained true -o $publish "-p:BaseIntermediateOutputPath=$intermediate\" "-p:BaseOutputPath=$outputRoot\bin\" '-p:PublishSingleFile=true' '-p:IncludeNativeLibrariesForSelfExtract=true' '-p:DebugType=None' '-p:DebugSymbols=false'
if ($LASTEXITCODE -ne 0) { throw "Publish failed: $LASTEXITCODE" }
$exe = Join-Path $publish 'prunlet.exe'
[ordered]@{ executable = $exe; runtime = $Runtime; sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash; bytes = (Get-Item -LiteralPath $exe).Length } | ConvertTo-Json
