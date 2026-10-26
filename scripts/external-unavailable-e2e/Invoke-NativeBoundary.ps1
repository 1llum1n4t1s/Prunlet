# productionのmanaged assemblyを直接呼ぶOS境界host。Prunlet本体のbuildやCLI実行は行わない。
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$AssemblyPath,
 [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedAssemblySha256,
 [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedNativeSourceSha256,
 [Parameter(Mandatory)][string]$OutputDirectory,
 [switch]$CompileOnly
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot)))
. (Join-Path $repo 'scripts/Verification-Common.ps1')
foreach($path in @($AssemblyPath,$OutputDirectory)){if(![IO.Path]::IsPathFullyQualified($path)){throw 'Absolute assembly/output paths required'}}
if([IO.Path]::GetPathRoot($OutputDirectory)-cne'D:\'){throw 'External D output required'}
Assert-VerificationDestination $OutputDirectory @($repo,(Join-Path $env:USERPROFILE '.codex'))
if(Test-Path -LiteralPath $OutputDirectory){throw 'Unused external output directory required'}
if(![IO.Directory]::Exists((Split-Path $OutputDirectory))){throw 'Create output parent first'}
if((Get-FileHash -LiteralPath $AssemblyPath).Hash-cne$ExpectedAssemblySha256.ToUpperInvariant()){throw 'Official managed assembly SHA mismatch'}
$nativeSource=Join-Path $repo 'src/Prunlet/Core/NativeFiles.ExternalUnavailable.cs'
$storeSource=Join-Path $repo 'src/Prunlet/Core/VolumeRecoveryStore.cs'
if((Get-FileHash -LiteralPath $nativeSource).Hash-cne$ExpectedNativeSourceSha256.ToUpperInvariant()){throw 'Frozen production native source SHA mismatch'}
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$utf8=[Text.UTF8Encoding]::new($false)
$project=Join-Path $OutputDirectory 'project';$null=[IO.Directory]::CreateDirectory($project)
$temp=Join-Path $OutputDirectory 'temp';$null=[IO.Directory]::CreateDirectory($temp);$env:TEMP=$temp;$env:TMP=$temp
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=Join-Path $OutputDirectory 'runtime-cache'
$env:DOTNET_CLI_HOME=Join-Path $OutputDirectory 'dotnet-home';$env:NUGET_PACKAGES=Join-Path $OutputDirectory 'nuget-cache'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
$canonicalSource=Join-Path $PSScriptRoot 'NativeBoundaryHost.cs';$source=Join-Path $project 'Program.cs';$sourceSha=(Get-FileHash -LiteralPath $canonicalSource).Hash
[IO.File]::Copy($canonicalSource,$source,$false)
if((Get-FileHash -LiteralPath $source).Hash-cne$sourceSha){throw 'External host source copy differs from canonical source'}
$projectPath=Join-Path $project 'NativeBoundaryHost.csproj'
$projectXml='<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0-windows</TargetFramework><AssemblyName>NativeBoundaryHost</AssemblyName><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><TreatWarningsAsErrors>true</TreatWarningsAsErrors><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup><Compile Include="Program.cs" /></ItemGroup></Project>'
[IO.File]::WriteAllText($projectPath,$projectXml,$utf8)
$hostOutput=Join-Path $OutputDirectory 'host';$intermediate=Join-Path $OutputDirectory 'obj';$bin=Join-Path $OutputDirectory 'bin';$buildLog=Join-Path $OutputDirectory 'compile.log'
$buildOutput=& dotnet build $projectPath -c Release -o $hostOutput ('-p:BaseIntermediateOutputPath='+$intermediate+'\') ('-p:BaseOutputPath='+$bin+'\') '-p:UseSharedCompilation=false' 2>&1
$buildExit=$LASTEXITCODE;[IO.File]::WriteAllText($buildLog,($buildOutput-join"`n"),$utf8)
if($buildExit-ne0){$buildOutput|Select-Object -Last 35;throw ('Native boundary host compilation failed; see '+$buildLog)}
$hostAssembly=Join-Path $hostOutput 'NativeBoundaryHost.dll'
$manifest=@{canonicalHostSource=$canonicalSource;hostSourceSha256=$sourceSha;copiedHostSource=$source;hostAssembly=$hostAssembly;hostAssemblySha256=(Get-FileHash -LiteralPath $hostAssembly).Hash;officialAssembly=$AssemblyPath;officialAssemblySha256=(Get-FileHash -LiteralPath $AssemblyPath).Hash;nativeSource=$nativeSource;nativeSourceSha256=(Get-FileHash -LiteralPath $nativeSource).Hash;volumeStoreSource=$storeSource;volumeStoreSourceSha256=(Get-FileHash -LiteralPath $storeSource).Hash;compileLog=$buildLog;compileExitCode=$buildExit;compileOnly=[bool]$CompileOnly}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'compile-binding.json'),($manifest|ConvertTo-Json -Depth 10),$utf8)
if($CompileOnly){$manifest|ConvertTo-Json -Depth 10;exit 0}
$report=Join-Path $OutputDirectory 'native-boundary-report.json';$fixtureRoot=Join-Path $OutputDirectory 'fixtures'
& dotnet $hostAssembly '--assembly' $AssemblyPath '--assembly-sha' $ExpectedAssemblySha256 '--output' $fixtureRoot '--report' $report '--native-source' $nativeSource '--native-source-sha' $ExpectedNativeSourceSha256 '--store-source' $storeSource '--store-source-sha' $manifest.volumeStoreSourceSha256 '--host-source' $source '--host-source-sha' $sourceSha
if($LASTEXITCODE-ne0){throw ('Actual native production boundary verification failed; see '+$report)}
