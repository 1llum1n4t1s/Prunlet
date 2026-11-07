[CmdletBinding()]
param(
    [ValidateSet('Prepare','VerifyDryRun','VerifyDelete')][string]$Phase='Prepare',
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$FixtureRoot='C:\Prunlet-Validation-session-scan-20261107',
    [int]$CliExitCode=0
)
$ErrorActionPreference='Stop'
if($Phase-ne'Prepare'-and!$PSBoundParameters.ContainsKey('CliExitCode')){throw 'CliExitCode must be supplied for verification'}
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
foreach($path in @($OutputDirectory,$FixtureRoot)) {
    if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute paths required'}
}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot)
foreach($path in @($OutputDirectory,$FixtureRoot)) {
    Assert-VerificationDestination $path @($repo,(Join-Path $env:USERPROFILE '.codex'))
}
if(![IO.Path]::GetPathRoot($OutputDirectory).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'External D output required'}
$manifestPath=Join-Path $OutputDirectory 'fixture.json'
function Assert-LongPathCompilationTemp {
    foreach($tempPath in @($env:TEMP,$env:TMP)) {
        if(!$tempPath-or![IO.Path]::IsPathFullyQualified($tempPath)){throw 'Existing external D TEMP/TMP required'}
        $tempPath=[IO.Path]::GetFullPath($tempPath)
        if(![IO.Path]::GetPathRoot($tempPath).Equals('D:\',[StringComparison]::OrdinalIgnoreCase)-or![IO.Directory]::Exists($tempPath)){throw 'Existing external D TEMP/TMP required'}
        Assert-VerificationDestination $tempPath @($repo,(Join-Path $env:USERPROFILE '.codex'))
    }
}
function Initialize-LongPathParentAccess {
    Assert-LongPathCompilationTemp
    if(!('PrunletLongPathParentAccess' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PrunletLongPathParentAccess {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    public static void Verify(string path) {
        using (var handle = CreateFileW(path, 4, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open fixture parent with FILE_ADD_SUBDIRECTORY: " + path);
        }
    }
}
"@
    }
}
function Initialize-LongPathHelpers {
    Assert-LongPathCompilationTemp
    if(!('Prunlet.RecordlessE2E.FixtureNative' -as [type])) {
        Add-Type -CompilerOptions @('/unsafe') -Path @('FixtureNative.cs','NativeShellFixture.cs','OwnedBinLocator.cs'|ForEach-Object {Join-Path (Join-Path $PSScriptRoot 'recordless-e2e') $_})
    }
}
if($Phase-eq'Prepare') {
    if([IO.Directory]::Exists($OutputDirectory)-or[IO.Directory]::Exists($FixtureRoot)){throw 'Unused output and fixture required'}
    Initialize-LongPathParentAccess
    foreach($parent in @([IO.Path]::GetDirectoryName($OutputDirectory),[IO.Path]::GetDirectoryName($FixtureRoot))) {
        if(![IO.Directory]::Exists($parent)){throw 'Parent must exist'}
        # 親ACLの読取りを確認。作成APIの権限拒否は停止して部分作成候補を報告する。
        Assert-VerificationDestination $parent @($repo,(Join-Path $env:USERPROFILE '.codex'))
        $null=Get-Acl -LiteralPath $parent
        [PrunletLongPathParentAccess]::Verify($parent)
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
        Initialize-LongPathHelpers
        $nativeId=[Prunlet.RecordlessE2E.FixtureNative]::Identity($target)
        $manifest=@{nativeId=$nativeId;priorPidls=@([Prunlet.RecordlessE2E.OwnedBinLocator]::FindIdentity($nativeId)|ForEach-Object Pidl);fixtureRoot=$FixtureRoot;target=$target;sibling=$sibling;targetLength=$target.Length;targetHash=(Get-FileHash -LiteralPath $target).Hash;siblingHash=(Get-FileHash -LiteralPath $sibling).Hash;targetAttributes=[int][IO.File]::GetAttributes($target);siblingAttributes=[int][IO.File]::GetAttributes($sibling)}
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 10),$encoding)
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'paths.json'),(ConvertTo-Json -InputObject @($target)),$encoding)
        $manifest|ConvertTo-Json -Depth 10
        return
    } catch {
        throw [IO.IOException]::new("Prepare partially created; retained for inspection, no automatic cleanup. OutputDirectory: $OutputDirectory; FixtureRoot: $FixtureRoot. $($_.Exception.Message)", $_.Exception)
    }
}
$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
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
    Initialize-LongPathHelpers
    $bin=[Prunlet.RecordlessE2E.OwnedBinLocator]::FindNew($manifest.nativeId,@($manifest.priorPidls))
    if((Get-FileHash -LiteralPath $bin.PhysicalPath).Hash-cne$manifest.targetHash){throw 'Recycled content changed'}
}
@{phase=$Phase;passed=$true;exitCode=$CliExitCode;targetLength=$manifest.targetLength;status=$items[0].status;siblingPreserved=$true;binNativeId=$(if($Phase-eq'VerifyDelete'){$bin.NativeId}else{$null});contentHash=$manifest.targetHash}|ConvertTo-Json