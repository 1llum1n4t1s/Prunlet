#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (![IO.Path]::IsPathFullyQualified($OutputDirectory) -or (Test-Path -LiteralPath $OutputDirectory)) { throw 'OutputDirectory must be an unused absolute path.' }
$cursor = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($OutputDirectory))
while ($null -ne $cursor) { if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Output ancestor is a reparse point.' }; $cursor = $cursor.Parent }
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$oldTemp = $env:TEMP; $oldTmp = $env:TMP
$env:TEMP = Join-Path $OutputDirectory 'temp'; $env:TMP = $env:TEMP
$null = [IO.Directory]::CreateDirectory($env:TEMP)
. (Join-Path $PSScriptRoot 'R2Distribution.Common.ps1')
$originalAccess = $env:PRUNLET_R2_ACCESS_KEY_ID; $originalSecret = $env:PRUNLET_R2_SECRET_ACCESS_KEY
# 以下はAWS公開テスト用の非秘密credentialだけを使う。
$env:PRUNLET_R2_ACCESS_KEY_ID = 'AKIDEXAMPLE'
$env:PRUNLET_R2_SECRET_ACCESS_KEY = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY'
$results = [Collections.Generic.List[object]]::new()
function Assert-R2Test($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Test-R2Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{name = $Name; passed = $true}) }
    catch { $results.Add(@{name = $Name; passed = $false; error = $_.Exception.Message}) }
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
public sealed class R2FixtureContent : HttpContent {
    readonly byte[] body; readonly long? size;
    public R2FixtureContent(byte[] b, long? length) { body=b; size=length; }
    protected override bool TryComputeLength(out long length) { length=size ?? 0; return size.HasValue; }
    protected override Task SerializeToStreamAsync(Stream stream, TransportContext context) { return stream.WriteAsync(body,0,body.Length); }
    protected override Task<Stream> CreateContentReadStreamAsync() { return Task.FromResult<Stream>(new MemoryStream(body,false)); }
}
public sealed class R2PublisherFixture : HttpMessageHandler {
    public readonly List<string> Calls = new List<string>();
    public readonly List<string> Problems = new List<string>();
    public readonly byte[] Body; public readonly string Mode, Path;
    public bool Stored; public int Puts; public bool PinWriteDenied, PinRenameDenied;
    public R2PublisherFixture(byte[] body,string mode,string path) { Body=body;Mode=mode;Path=path;Stored=mode.StartsWith("existing"); }
    HttpResponseMessage Reply(int code, byte[] body=null, long? size=null) {
        var r=new HttpResponseMessage((HttpStatusCode)code);
        if(body!=null) r.Content=new R2FixtureContent(body,size);
        return r;
    }
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellationToken) {
        bool pub=request.RequestUri.Host=="prunlet.kagayoi.com";
        string method=request.Method.Method;Calls.Add(method+" "+(pub?"public":"s3"));
        if(request.RequestUri.Scheme!="https" || (!pub && request.RequestUri.Host!="0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")) Problems.Add("destination");
        if(pub && request.Headers.Contains("Authorization")) Problems.Add("public credential leak");
        if(!pub && (!request.Headers.Contains("Authorization") || !request.Headers.Contains("x-amz-date") || !request.Headers.Contains("x-amz-content-sha256"))) Problems.Add("missing signature");
        if(!pub) {
            string expectedHash=method=="PUT" ? Convert.ToHexString(SHA256.HashData(Body)).ToLowerInvariant() : "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
            if(string.Join("",request.Headers.GetValues("x-amz-content-sha256"))!=expectedHash)Problems.Add("signed payload hash");
            string auth=string.Join("",request.Headers.GetValues("Authorization"));
            string signed=method=="PUT"?"host;if-none-match;x-amz-content-sha256;x-amz-date":"host;x-amz-content-sha256;x-amz-date";
            if(!auth.Contains("/auto/s3/aws4_request, SignedHeaders="+signed+", Signature="))Problems.Add("signed scope or conditions");
        }
        if(method=="HEAD") {
            if(Mode=="pin") {
                try { using(var f=File.Open(Path,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete)){} } catch(IOException ex) {PinWriteDenied=(ex.HResult&65535)==32;}
                try { File.Move(Path,Path+".replaced"); } catch(IOException ex) {PinRenameDenied=(ex.HResult&65535)==32;}
            }
            if(Mode=="head401")return Reply(401);
            if(Mode=="head500")return Reply(500);
            if(Mode=="headredirect")return Reply(302);
            return Reply(Stored?200:404);
        }
        if(method=="PUT") {
            Puts++;
            if(!request.Headers.IfNoneMatch.ToString().Contains("*"))Problems.Add("missing create-only condition");
            if(request.Content.Headers.ContentLength!=Body.LongLength)Problems.Add("upload size");
            // HttpContent所有のstreamはrequestが最後に解放する。
            var stream=await request.Content.ReadAsStreamAsync();
            string actual=Convert.ToHexString(SHA256.HashData(stream));
            if(actual!=Convert.ToHexString(SHA256.HashData(Body)))Problems.Add("upload bytes");
            if(Mode=="unknown")throw new HttpRequestException("fixture-sensitive-transport-detail");
            if(Mode=="putredirect")return Reply(307);
            if(Mode=="put401")return Reply(401);
            if(Mode=="put503")return Reply(503);
            if(Mode=="put204")return Reply(204);
            Stored=true;
            return Reply(Mode.StartsWith("race412")?412:200);
        }
        if(method!="GET") {Problems.Add("unexpected method");return Reply(405);}
        if((Mode=="get404"&&!pub)||(Mode=="public404"&&pub))return Reply(404);
        if((Mode=="getredirect"&&!pub)||(Mode=="publicredirect"&&pub))return Reply(302);
        if((Mode=="get401"&&!pub)||(Mode=="public401"&&pub))return Reply(401);
        byte[] data=Body;
        if((Mode=="existingdifferent"&&!pub)||Mode=="race412different"||(Mode=="publichash"&&pub)) {data=(byte[])Body.Clone();data[data.Length-1]^=1;}
        if((Mode=="overrun"&&!pub)||(Mode=="publicoverrun"&&pub)){data=new byte[Body.Length+1];Buffer.BlockCopy(Body,0,data,0,Body.Length);}
        if((Mode=="truncated"&&!pub)||(Mode=="publictruncated"&&pub)){data=new byte[Body.Length-1];Buffer.BlockCopy(Body,0,data,0,data.Length);}
        return Reply(200,data,Mode=="wronglength"?Body.LongLength+1:Body.LongLength);
    }
}
'@
    Test-R2Case 'AWS-official-get-vanilla-signature-vector' {
        # AWS CRTの独立既知値。https://github.com/awslabs/aws-c-auth/tree/main/tests/aws-signing-test-suite/v4/get-vanilla
        $headers = @{host = 'example.amazonaws.com'; 'x-amz-date' = '20150830T123600Z'}
        $auth = Get-PrunletR2Authorization 'GET' ([uri]'https://example.amazonaws.com/') $headers 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' '20150830T123600Z' 'AKIDEXAMPLE' 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' 'us-east-1' 'service'
        Assert-R2Test ($auth.EndsWith('Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31')) 'AWS known signature differs'
    }
    $bytes = [IO.File]::ReadAllBytes($PackagePath)
    $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $baseArguments = @{ExpectedHash = $expected; Repository = '1llum1n4t1s/Prunlet'; CommitSha = ('a' * 40); Runtime = 'win-x64'; AccountId = '0123456789abcdef0123456789abcdef'; Bucket = 'prunlet-updates'}
    foreach ($mode in @('upload','existing','race412','pin','existingdifferent','race412different','overrun','truncated','wronglength','publichash','publicoverrun','publictruncated','head401','head500','headredirect','put401','putredirect','put503','put204','get401','get404','getredirect','public401','public404','publicredirect','unknown')) {
        Test-R2Case $mode {
            $path = Join-Path $OutputDirectory ($mode + '.zip'); [IO.File]::WriteAllBytes($path, $bytes)
            $fixture = [R2PublisherFixture]::new($bytes, $mode, $path)
            $client = [Net.Http.HttpClient]::new($fixture, $true)
            $package = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $failure = $null; $fullFailure = $null; $result = $null
            try { try { $result = Invoke-PrunletR2Distribution @baseArguments -Package $package -Client $client } catch { $failure = $_.Exception.Message; $fullFailure = $_.Exception.ToString() } }
            finally { $package.Dispose(); $client.Dispose() }
            Assert-R2Test ($fixture.Problems.Count -eq 0) ('Actual HTTP request differs: ' + ($fixture.Problems -join ','))
            if ($mode -in @('upload','existing','race412','pin')) {
                Assert-R2Test (!$failure -and $result.verified -and $result.sha256 -ceq $expected -and $result.bytes -eq $bytes.Length) 'Expected verified result'
                Assert-R2Test ($result.objectKey -ceq "releases/1llum1n4t1s/prunlet/$('a'*40)/win-x64/$expected.zip") 'Content-addressed key differs'
                Assert-R2Test ($fixture.Calls.Contains('GET s3') -and $fixture.Calls.Contains('GET public')) 'Both bodies must be verified'
                Assert-R2Test ($result.publicUrl -ceq ('https://prunlet.kagayoi.com/' + $result.objectKey)) 'Public URL differs'
                Assert-R2Test ($fixture.Puts -eq $(if($mode-eq'existing'){0}else{1})) 'PUT count differs'
                if ($mode-eq'pin') { Assert-R2Test ($fixture.PinWriteDenied -and $fixture.PinRenameDenied) 'Read-only package pin did not block replacement' }
            } else {
                Assert-R2Test ($null-ne$failure -and $null-eq$result) 'Unverified operation returned success'
                Assert-R2Test (!$fullFailure.Contains('fixture-sensitive-transport-detail') -and !$fullFailure.Contains($env:PRUNLET_R2_SECRET_ACCESS_KEY) -and !$fullFailure.Contains($env:PRUNLET_R2_ACCESS_KEY_ID)) 'Exception disclosed transport or credential details'
                $expectedPhase = if($mode.StartsWith('head')){'s3-head'}elseif($mode.StartsWith('put')-or$mode-eq'unknown'){'s3-put'}elseif($mode.StartsWith('public')){'public-get'}else{'s3-existing'}
                Assert-R2Test ($failure.StartsWith("R2 publisher stopped: phase=$expectedPhase code=")) 'Safe error phase differs'
                if($mode-eq'unknown'){Assert-R2Test ($failure-ceq'R2 publisher stopped: phase=s3-put code=unknown-no-resend') 'Unknown PUT must explicitly stop resends'}
                if($mode-in@('put503','put204','putredirect')){
                    $expectedStatus=@{put503=503;put204=204;putredirect=307}[$mode]
                    Assert-R2Test ($failure-ceq"R2 publisher stopped: phase=s3-put code=unknown-no-resend httpStatus=$expectedStatus") 'Uncertain PUT response was classified as a definite rejection'
                    Assert-R2Test ($fixture.Puts-eq1-and$fixture.Calls.Count-eq2) 'Uncertain PUT response continued to GET or another PUT'
                }
                if($mode-eq'head401'){Assert-R2Test ($failure-ceq'R2 publisher stopped: phase=s3-head code=http-rejected httpStatus=401') 'HEAD status diagnostic differs'}
                if($mode-eq'publichash'){Assert-R2Test ($failure-ceq'R2 publisher stopped: phase=public-get code=body-mismatch httpStatus=200') 'Public body diagnostic differs'}
                Assert-R2Test ($fixture.Puts -le 1) 'An uncertain PUT was resent'
                if ($mode.StartsWith('head')) { Assert-R2Test ($fixture.Puts-eq0) 'HEAD failure attempted an upload' }
                if ($mode-eq'unknown') { Assert-R2Test ($fixture.Calls.Count-eq2) 'Unknown PUT continued to another request' }
            }
        }.GetNewClosure()
    }
    Test-R2Case 'same-object-second-publication-reuses-without-PUT' {
        $fixture = [R2PublisherFixture]::new($bytes, 'upload', '')
        $client = [Net.Http.HttpClient]::new($fixture, $true)
        try {
            foreach ($iteration in 1..2) {
                $stream = [IO.File]::Open($PackagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try { $result = Invoke-PrunletR2Distribution @baseArguments -Package $stream -Client $client; Assert-R2Test ($result.reused -eq ($iteration-eq2)) 'Reuse flag differs' }
                finally { $stream.Dispose() }
            }
            Assert-R2Test ($fixture.Puts-eq1 -and $fixture.Calls.Count-eq7 -and $fixture.Problems.Count-eq0) 'Identical retry did not fully reverify without overwrite'
        } finally { $client.Dispose() }
    }
    Test-R2Case 'invalid-destination-and-local-hash-block-before-HTTP' {
        foreach ($override in @(@{Repository='other/repo'},@{AccountId='https://evil.example'},@{Bucket='../other'},@{ExpectedHash=('0'*64)},@{Runtime='linux-x64'})) {
            $arguments = $baseArguments.Clone(); foreach($key in $override.Keys){$arguments[$key]=$override[$key]}
            $fixture=[R2PublisherFixture]::new($bytes,'upload','');$client=[Net.Http.HttpClient]::new($fixture,$true);$stream=[IO.File]::OpenRead($PackagePath);$rejected=$false
            try { try { $null=Invoke-PrunletR2Distribution @arguments -Package $stream -Client $client } catch { $rejected=$true }; Assert-R2Test ($rejected-and$fixture.Calls.Count-eq0) 'Invalid input reached HTTP' }
            finally { $stream.Dispose();$client.Dispose() }
        }
    }
    Test-R2Case 'missing-credential-blocks-before-HTTP' {
        $fixture=[R2PublisherFixture]::new($bytes,'upload','');$client=[Net.Http.HttpClient]::new($fixture,$true);$stream=[IO.File]::OpenRead($PackagePath)
        $saved=$env:PRUNLET_R2_SECRET_ACCESS_KEY;$env:PRUNLET_R2_SECRET_ACCESS_KEY=$null;$rejected=$false
        try { try { $null=Invoke-PrunletR2Distribution @baseArguments -Package $stream -Client $client } catch { $rejected=$true;Assert-R2Test ($_.Exception.Message-ceq'R2 publisher stopped: phase=credentials code=unavailable-before-http') 'Credential phase does not identify pre-HTTP failure' };Assert-R2Test ($rejected-and$fixture.Calls.Count-eq0) 'Missing credential reached HTTP' }
        finally {$env:PRUNLET_R2_SECRET_ACCESS_KEY=$saved;$stream.Dispose();$client.Dispose()}
    }
    Test-R2Case 'public-script-catch-preserves-safe-phase-and-removes-raw-inner-errors' {
        $tokens=$null;$parseErrors=$null;$publisherAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Publish-PrunletR2.ps1'),[ref]$tokens,[ref]$parseErrors)
        Assert-R2Test (!$parseErrors.Count) 'Publisher syntax failed'
        $tryAst=$publisherAst.Find({param($node)$node-is[Management.Automation.Language.TryStatementAst]},$false)
        $body=$tryAst.CatchClauses[0].Body.Extent.Text
        $actualCatch=[scriptblock]::Create($body.Substring(1,$body.Length-2))
        foreach($case in @(@{phase='s3-put';code='unknown-no-resend';status=0},@{phase='s3-head';code='http-rejected';status=401},@{phase='public-get';code='body-mismatch';status=200})) {
            $expected="R2 publisher stopped: phase=$($case.phase) code=$($case.code)";if($case.status){$expected+=" httpStatus=$($case.status)"}
            $caught=$null;$phase='package-pin'
            try { try { Stop-PrunletR2 $case.phase $case.code $case.status } catch { . $actualCatch } } catch { $caught=$_.Exception.Message }
            Assert-R2Test ($caught-ceq$expected) 'Public script hid a safe Common phase'
        }
        $caught=$null;$phase='package-verification'
        try { try { throw [InvalidOperationException]::new('unsafe '+$env:PRUNLET_R2_SECRET_ACCESS_KEY) } catch { . $actualCatch } } catch { $caught=$_.Exception.ToString() }
        Assert-R2Test ($caught.Contains('phase=package-verification code=verification-failed')-and!$caught.Contains($env:PRUNLET_R2_SECRET_ACCESS_KEY)) 'Public script leaked a raw verification exception'
    }
} finally {
    $env:PRUNLET_R2_ACCESS_KEY_ID=$originalAccess; $env:PRUNLET_R2_SECRET_ACCESS_KEY=$originalSecret
    $env:TEMP=$oldTemp; $env:TMP=$oldTmp
    $failed=@($results|Where-Object {!$_.passed}).Count
    @{runtime='powershell-dotnet-mock-http';liveApiWrites=0;passed=$results.Count-$failed;failed=$failed;packagePath=$PackagePath;results=@($results)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputDirectory 'report.json') -Encoding utf8
}
if($failed){throw 'R2 publisher verification failed; inspect report.json.'}
