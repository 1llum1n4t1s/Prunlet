[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FixturePath,
    [Parameter(Mandatory)][string]$ExpectedId,
    [Parameter(Mandatory)][string]$ExpectedSecurityBase64,
    [Parameter(Mandatory)][string]$ExpectedUserSid,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$TempDirectory
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
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
    # 権限・実体の確認だけに使い、削除・ACL変更・機能の有効化は行わない。
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VerificationCaseAccess {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool GetTokenInformation(IntPtr token,int kind,out int value,int size,out int returned);
    public static bool Elevated(IntPtr token) {
        if(!GetTokenInformation(token,20,out int value,4,out _))throw new Win32Exception(Marshal.GetLastWin32Error());
        return value!=0;
    }
    public static SafeFileHandle HoldReportParent(string path) {
        var handle=CreateFileW(path,0x82,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        if(handle.IsInvalid){int code=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(code);}
        return handle;
    }
}
'@
    $pins.Add([VerificationCaseAccess]::HoldReportParent([IO.Path]::GetDirectoryName($ReportPath)))
    $helperFiles=@('FixtureNative.cs','NativeShellFixture.cs','OwnedBinLocator.cs')|ForEach-Object {Join-Path $PSScriptRoot "recordless-e2e/$_"}
    Add-Type -CompilerOptions @('/unsafe') -Path $helperFiles
    for($parent=[IO.Path]::GetDirectoryName($FixturePath);$parent;$parent=[IO.Path]::GetDirectoryName($parent)) {
        $pins.Add([Prunlet.RecordlessE2E.FixtureNative]::HoldParent($parent))
    }
    $pins.Add([Prunlet.RecordlessE2E.FixtureNative]::HoldParent($FixturePath))
    $result=@{fixturePath=$FixturePath;exitCode=1;error=$null;token=@{userSid=$identity.User.Value;isAdministrator=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);isElevated=[VerificationCaseAccess]::Elevated($identity.Token)}}
    try {
        if(!$result.token.isAdministrator-or!$result.token.isElevated){throw 'Administrator elevation is required for this fixture preparation'}
        $before=@([Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($FixturePath))
        if($before.Count-ne1-or!$before[0].Directory-or$before[0].ReparseTag-ne0){throw 'One empty ordinary fixture directory required'}
        $result.beforeNativeId=$before[0].Id;$result.beforeSecurityBase64=$before[0].SecurityBase64
        $result.beforeCaseSensitive=[Prunlet.RecordlessE2E.FixtureNative]::IsCaseSensitive($FixturePath)
        if($result.beforeNativeId-cne$ExpectedId-or$result.beforeSecurityBase64-cne$ExpectedSecurityBase64-or$result.beforeCaseSensitive){throw 'Prepared fixture identity/security/flag differs from the request'}
        # 管理者操作はこの空ディレクトリ1個のcase flag設定だけ。削除は通常tokenのrunnerに任せる。
        $result.fsutilOutput=@(& (Join-Path $env:SystemRoot 'System32/fsutil.exe') file SetCaseSensitiveInfo $FixturePath enable 2>&1|ForEach-Object {"$_"})
        $result.fsutilExitCode=$LASTEXITCODE
        $after=@([Prunlet.RecordlessE2E.FixtureNative]::SnapshotTree($FixturePath))
        $result.afterNativeId=$after[0].Id;$result.afterSecurityBase64=$after[0].SecurityBase64
        $result.afterCaseSensitive=[Prunlet.RecordlessE2E.FixtureNative]::IsCaseSensitive($FixturePath)
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
