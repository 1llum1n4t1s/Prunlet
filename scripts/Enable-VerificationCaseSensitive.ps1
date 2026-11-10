[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FixturePath,
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$BuildManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBuildManifestSha256,
    [Parameter(Mandatory)][string]$ExpectedId,
    [Parameter(Mandatory)][string]$ExpectedSecurityBase64,
    [Parameter(Mandatory)][string]$ExpectedUserSid,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$TempDirectory
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$null=Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256
foreach($path in @($FixturePath,$ReportPath,$TempDirectory)) {
    if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}
    Assert-VerificationDestination ([IO.Path]::GetFullPath($path)) @($repo,(Join-Path $env:USERPROFILE '.codex'))
}
$FixturePath=[IO.Path]::GetFullPath($FixturePath)
$ReportPath=[IO.Path]::GetFullPath($ReportPath)
$TempDirectory=[IO.Path]::GetFullPath($TempDirectory)
if($FixturePath-notmatch'\\recordless-[a-f0-9]{32}\\case-sensitive\\files\\case-sensitive$'){throw 'Only an isolated recordless case-sensitive fixture is supported'}
foreach($path in @($ReportPath,$TempDirectory)) {if([IO.Path]::GetPathRoot($path)-ine'D:\'){throw 'External D output required'}}
if([IO.File]::Exists($ReportPath)-or[IO.Directory]::Exists($ReportPath)){throw 'Unused report required'}
if(![IO.Directory]::Exists($TempDirectory)-or![IO.Directory]::Exists([IO.Path]::GetDirectoryName($ReportPath))){throw 'Existing output parents required'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.User.Value-cne$ExpectedUserSid){throw 'Effective user differs from the fixture owner request'}
$oldTemp=$env:TEMP;$oldTmp=$env:TMP
$env:TEMP=$TempDirectory;$env:TMP=$TempDirectory
$pins=[Collections.Generic.List[IDisposable]]::new()
try {
    # report親と対象祖先を同一processのnative leaseで固定する。
    $reportParent=[IO.Path]::GetDirectoryName($ReportPath)
    $pins.Add((New-FileFixtureHold -Path $reportParent -Scope $reportParent -Mode report-parent))
    for($parent=[IO.Path]::GetDirectoryName($FixturePath);$parent;$parent=[IO.Path]::GetDirectoryName($parent)) {
        $pins.Add((New-FileFixtureHold -Path $parent -Scope $parent -Mode parent))
    }
    $pins.Add((New-FileFixtureHold -Path $FixturePath -Scope $FixturePath -Mode parent))
    $result=@{fixturePath=$FixturePath;exitCode=1;error=$null;token=@{userSid=$identity.User.Value;isAdministrator=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);isElevated=(Get-FileFixtureTokenElevation -Handle $identity.AccessToken)}}
    try {
        if(!$result.token.isAdministrator-or!$result.token.isElevated){throw 'Administrator elevation is required for this fixture preparation'}
        $before=Get-FileFixtureSnapshot -Path $FixturePath
        if($before.Count-ne1-or!$before[0].Directory-or$before[0].ReparseTag-ne0){throw 'One empty ordinary fixture directory required'}
        $result.beforeNativeId=$before[0].Id;$result.beforeSecurityBase64=$before[0].SecurityBase64
        $result.beforeCaseSensitive=Get-FileFixtureCaseSensitive -Path $FixturePath
        if($result.beforeNativeId-cne$ExpectedId-or$result.beforeSecurityBase64-cne$ExpectedSecurityBase64-or$result.beforeCaseSensitive){throw 'Prepared fixture identity/security/flag differs from the request'}
        # 管理者操作はこの空ディレクトリ1個のcase flag設定だけ。削除は通常tokenのrunnerに任せる。
        $result.fsutilOutput=@(& (Join-Path $env:SystemRoot 'System32/fsutil.exe') file SetCaseSensitiveInfo $FixturePath enable 2>&1|ForEach-Object {"$_"})
        $result.fsutilExitCode=$LASTEXITCODE
        $after=Get-FileFixtureSnapshot -Path $FixturePath
        $result.afterNativeId=$after[0].Id;$result.afterSecurityBase64=$after[0].SecurityBase64
        $result.afterCaseSensitive=Get-FileFixtureCaseSensitive -Path $FixturePath
        if($after.Count-ne1-or$result.afterNativeId-cne$ExpectedId-or$result.afterSecurityBase64-cne$ExpectedSecurityBase64-or$after[0].Attributes-ne$before[0].Attributes-or!$result.afterCaseSensitive-or$result.fsutilExitCode-ne0){throw 'Native case flag or fixture preservation check failed'}
        $result.exitCode=0
    } catch {$result.error=$_.Exception.Message}
    $stream=[IO.FileStream]::new($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 8));$stream.Write($bytes);$stream.Flush($true)} finally {$stream.Dispose()}
    if($result.exitCode-ne0){throw $result.error}
} finally {
    for($i=$pins.Count-1;$i-ge0;$i--){$pins[$i].Dispose()}
    $env:TEMP=$oldTemp;$env:TMP=$oldTmp;$identity.Dispose()
}
