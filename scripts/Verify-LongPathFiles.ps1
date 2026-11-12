[CmdletBinding()]
param(
    [ValidateSet('Prepare','VerifyDryRun','VerifyDelete')][string]$Phase='Prepare',
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$BuildManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBuildManifestSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    # 開発者固有の既定値は持たない。全Phaseで同じ未使用（Prepare時）の外部絶対パスを明示する。
    [Parameter(Mandatory)][string]$FixtureRoot,
    [int]$CliExitCode=0
)
$ErrorActionPreference='Stop'
if($Phase-ne'Prepare'-and!$PSBoundParameters.ContainsKey('CliExitCode')){throw 'CliExitCode must be supplied for verification'}
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
. (Join-Path $PSScriptRoot 'FileFixtures.Common.ps1')
$null=Initialize-PrunletFixtureBinding -ExecutablePath $ExecutablePath -BuildManifestPath $BuildManifestPath -ExpectedBuildManifestSha256 $ExpectedBuildManifestSha256
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
foreach($path in @($OutputDirectory,$FixtureRoot)) {
    if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}
}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot)
foreach($path in @($OutputDirectory,$FixtureRoot)) {
    Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'))
}
Assert-ExternalVerificationPath $OutputDirectory @($repo)
$manifestPath=Join-Path $OutputDirectory 'fixture.json'
function Assert-LongPathTemp {
    foreach($tempPath in @($env:TEMP,$env:TMP)) {
        if(!$tempPath-or![IO.Path]::IsPathFullyQualified($tempPath)){throw 'Existing external TEMP/TMP required'}
        $tempPath=[IO.Path]::GetFullPath($tempPath)
        Assert-ExternalVerificationPath $tempPath @($repo)
        if(![IO.Directory]::Exists($tempPath)){throw 'Existing external TEMP/TMP required'}
        Assert-VerificationDestination $tempPath @($repo,(Join-Path $env:USERPROFILE '.codex'))
    }
}
Assert-LongPathTemp
if($Phase-eq'Prepare') {
    if([IO.Directory]::Exists($OutputDirectory)-or[IO.Directory]::Exists($FixtureRoot)){throw 'Unused output and fixture required'}

    foreach($parent in @([IO.Path]::GetDirectoryName($OutputDirectory),[IO.Path]::GetDirectoryName($FixtureRoot))) {
        if(![IO.Directory]::Exists($parent)){throw 'Parent must exist'}
        # 親ACLの読取りを確認。作成APIの権限拒否は停止して部分作成候補を報告する。
        Assert-VerificationDestination $parent @($repo,(Join-Path $env:USERPROFILE '.codex'))
        $null=Get-Acl -LiteralPath $parent
        (Assert-FileFixtureParentCanAdd -Path $parent)
    }
    try {
        $null=[IO.Directory]::CreateDirectory($OutputDirectory)
        $null=[IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'temp'))
        $null=[IO.Directory]::CreateDirectory($FixtureRoot)
        $deep=$FixtureRoot
        for($i=0;$i-lt7;$i++){$deep=Join-Path $deep (('長'*79)+$i)}
        $null=[IO.Directory]::CreateDirectory($deep)
        $target=Join-Path $deep '小さなファイル😀.txt'
        $sibling=Join-Path $deep '対象外の隣接ファイル🐈.txt'
        $encoding=[Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($target,'smallUnicodefile1',$encoding)
        [IO.File]::WriteAllText($sibling,'untargeted sibling',$encoding)

        $nativeId=(Get-FileFixtureIdentity -Path $target)
        $manifest=@{nativeId=$nativeId;priorPidls=@((Find-FileFixtureBinIdentity -ExpectedId $nativeId)|ForEach-Object Pidl);fixtureRoot=$FixtureRoot;candidatePath=[IO.Path]::GetFullPath($ExecutablePath);candidateSha256=(Get-FileHash -LiteralPath $ExecutablePath).Hash;buildManifestSha256=$ExpectedBuildManifestSha256;target=$target;sibling=$sibling;targetLength=$target.Length;targetHash=(Get-FileHash -LiteralPath $target).Hash;siblingHash=(Get-FileHash -LiteralPath $sibling).Hash;targetAttributes=[int][IO.File]::GetAttributes($target);siblingAttributes=[int][IO.File]::GetAttributes($sibling)}
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 10),$encoding)
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'paths.json'),(ConvertTo-Json -InputObject @($target)),$encoding)
        $manifest|ConvertTo-Json -Depth 10
        return
    } catch {
        throw [IO.IOException]::new("Prepare partially created; retained for inspection, no automatic cleanup. OutputDirectory: $OutputDirectory; FixtureRoot: $FixtureRoot. $($_.Exception.Message)", $_.Exception)
    }
}
$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
if($manifest.candidatePath-cne[IO.Path]::GetFullPath($ExecutablePath)-or$manifest.candidateSha256-cne(Get-FileHash -LiteralPath $ExecutablePath).Hash-or$manifest.buildManifestSha256-cne$ExpectedBuildManifestSha256){throw 'Prepared candidate binding changed; retained without retry'}
$resultFile=Join-Path $OutputDirectory $(if($Phase-eq'VerifyDryRun'){'dry-run.json'}else{'delete.json'})
$result=[IO.File]::ReadAllText($resultFile)|ConvertFrom-Json
if($CliExitCode-ne0){throw "CLI exit code $CliExitCode; no automatic retry allowed"}
$items=@($result.items)
if($items.Count-ne1-or$items[0].path-cne$manifest.target){throw 'Unexpected result target'}
if((Get-FileHash -LiteralPath $manifest.sibling).Hash-cne$manifest.siblingHash-or[int][IO.File]::GetAttributes($manifest.sibling)-ne$manifest.siblingAttributes){throw 'Sibling changed'}
if($Phase-eq'VerifyDryRun') {
    if($items[0].status-cne'would_recycle'){throw 'Dry-run status mismatch'}
    if((Get-FileHash -LiteralPath $manifest.target).Hash-cne$manifest.targetHash-or[int][IO.File]::GetAttributes($manifest.target)-ne$manifest.targetAttributes){throw 'Dry-run changed target'}
} else {
    if($items[0].status-cne'recycled'-or[IO.File]::Exists($manifest.target)){throw 'Deletion did not recycle target'}

    $bin=(Find-FileFixtureBinNew -ExpectedId $manifest.nativeId -PriorPidls @($manifest.priorPidls))
    if((Get-FileHash -LiteralPath $bin.PhysicalPath).Hash-cne$manifest.targetHash){throw 'Recycled content changed'}
}
@{phase=$Phase;passed=$true;exitCode=$CliExitCode;targetLength=$manifest.targetLength;status=$items[0].status;siblingPreserved=$true;binNativeId=$(if($Phase-eq'VerifyDelete'){$bin.NativeId}else{$null});contentHash=$manifest.targetHash}|ConvertTo-Json
