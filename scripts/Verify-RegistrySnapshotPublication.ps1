[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AssemblyPath,
    [Parameter(Mandatory)][string]$ExpectedAssemblySha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'Verification-Common.ps1')
foreach ($path in @($AssemblyPath, $OutputDirectory, $ReportPath)) {
    if (![IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute paths are required.' }
}
if (![IO.File]::Exists($AssemblyPath) -or (Get-FileHash -LiteralPath $AssemblyPath).Hash -cne $ExpectedAssemblySha256) { throw 'Candidate assembly missing or changed.' }
foreach ($path in @($OutputDirectory, $ReportPath)) {
    Assert-VerificationDestination $path @($repo, (Join-Path $env:USERPROFILE '.codex'))
    if (![IO.Path]::GetPathRoot($path).Equals('D:\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $path) -or ![IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { throw 'Unused external D: output with an existing parent is required.' }
}
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$metadata = Join-Path $OutputDirectory 'metadata'
$null = [IO.Directory]::CreateDirectory($metadata)
$temp = Join-Path $OutputDirectory 'temp'
$null = [IO.Directory]::CreateDirectory($temp)
$previousTemp = $env:TEMP; $previousTmp = $env:TMP
$env:TEMP = $temp; $env:TMP = $temp
try {
    Add-Type -TypeDefinition @'
#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

public static class RegistrySnapshotPublicationProbe
{
    private const BindingFlags StaticPrivate = BindingFlags.Static | BindingFlags.NonPublic;
    private const BindingFlags InstancePrivate = BindingFlags.Instance | BindingFlags.NonPublic;
    private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static string Digest(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static object Call(MethodInfo method, object? instance, params object?[] args)
    {
        try { return method.Invoke(instance, args)!; }
        catch (TargetInvocationException error) when (error.InnerException is not null) { throw error.InnerException; }
    }
    private static void Set(object instance, string name, object value) => instance.GetType().GetProperty(name)!.SetValue(instance, value);

    public static object[] Run(string assemblyPath, string metadata)
    {
        var assembly = Assembly.LoadFrom(assemblyPath);
        var configType = assembly.GetType("Prunlet.Core.PrunletConfig", true)!;
        var serviceType = assembly.GetType("Prunlet.Core.DeletionService", true)!;
        var snapshotType = assembly.GetType("Prunlet.Core.RegistrySnapshot", true)!;
        var valueType = assembly.GetType("Prunlet.Core.RegistryValueSnapshot", true)!;
        var manifestType = assembly.GetType("Prunlet.Core.RegistryManifest", true)!;
        var nativeType = assembly.GetType("Prunlet.Core.NativeFiles", true)!;
        var leaseType = serviceType.GetNestedType("NewOperationLease", BindingFlags.NonPublic)!;
        var config = Activator.CreateInstance(configType)!; Set(config, "BackupDirectory", metadata);
        var service = Activator.CreateInstance(serviceType, config)!;
        var coordination = (IDisposable)Call(serviceType.GetMethod("AcquireRecoveryCoordination", InstancePrivate)!, service, true, null);
        var results = new List<object>();
        try
        {
            foreach (var mode in new[] { "owner.durable", "body.prefix", "corrupt-prefix" })
            {
                var lease = (IDisposable)Call(leaseType.GetMethod("Create", BindingFlags.Static | BindingFlags.NonPublic)!, null, metadata, null);
                try
                {
                    var id = (string)leaseType.GetProperty("OperationId", InstancePrivate)!.GetValue(lease)!;
                    var directory = (string)leaseType.GetProperty("Directory", InstancePrivate)!.GetValue(lease)!;
                    var snapshot = Activator.CreateInstance(snapshotType, nonPublic: true)!;
                    Set(snapshot, "Path", @"HKEY_CURRENT_USER\Software\PrunletE2E\Publication"); Set(snapshot, "View", "64"); Set(snapshot, "ValueName", "payload");
                    var value = Activator.CreateInstance(valueType, nonPublic: true)!; Set(value, "Name", "payload"); Set(value, "Type", 3u);
                    Set(value, "Data", Enumerable.Range(0, 65536).Select(i => (byte)(i % 251)).ToArray()); Set(snapshot, "Value", value);
                    var security = new RawSecurityDescriptor("O:SYG:SYD:(A;;KA;;;SY)S:(ML;;NW;;;ME)");
                    var securityBytes = new byte[security.BinaryLength]; security.GetBinaryForm(securityBytes, 0); Set(snapshot, "ContextSecurity", securityBytes);
                    var manifest = Activator.CreateInstance(manifestType, nonPublic: true)!;
                    Set(manifest, "Path", @"HKEY_CURRENT_USER\Software\PrunletE2E\Publication"); Set(manifest, "View", "64"); Set(manifest, "ValueName", "payload");
                    Call(serviceType.GetMethod("ValidateRegistrySnapshot", StaticPrivate)!, null, manifest, snapshot);
                    var options = (JsonSerializerOptions)serviceType.GetField("RegistryJsonOptions", StaticPrivate)!.GetValue(null)!;
                    var expected = JsonSerializer.SerializeToUtf8Bytes(snapshot, snapshotType, options);
                    var final = Path.Combine(directory, "registry-snapshot.json");
                    var pending = Path.Combine(directory, ".registry-pending-registry-snapshot.json");
                    var ownerPath = Path.Combine(directory, ".registry-publication-registry-snapshot.json.json");
                    var publish = serviceType.GetMethod("PublishRegistrySnapshot", InstancePrivate)!;
                    var held = new List<FileStream>(); var warnings = new List<string>();
                    var checkpointEvent = serviceType.GetEvent("RegistryPublicationCheckpoint", StaticPrivate)!;
                    var phase = mode == "owner.durable" ? "owner.durable" : "body.prefix";
                    Action<string, string> checkpoint = (name, operation) => { if (operation == id && name == "registry-snapshot.json." + phase) throw new IOException("Injected publication boundary"); };
                    checkpointEvent.GetAddMethod(true)!.Invoke(null, new object[] { checkpoint });
                    try
                    {
                        try { Call(publish, service, final, id, snapshot, expected, held, warnings); throw new InvalidOperationException("Publication did not stop at its boundary."); }
                        catch (IOException error) when (error.Message == "Injected publication boundary") { }
                    }
                    finally { checkpointEvent.GetRemoveMethod(true)!.Invoke(null, new object[] { checkpoint }); }
                    Assert(File.Exists(ownerPath) && File.Exists(pending) && !File.Exists(final), "Interrupted publication was not preserved.");
                    using var owner = JsonDocument.Parse(File.ReadAllBytes(ownerPath));
                    Assert(owner.RootElement.GetProperty("length").GetInt64() == expected.LongLength && owner.RootElement.GetProperty("sha256").GetString() == Digest(expected), "Owner did not bind the initial bytes.");
                    var prefix = File.ReadAllBytes(pending); var expectedLength = phase == "owner.durable" ? 0 : expected.Length / 2;
                    Assert(prefix.Length == expectedLength && prefix.AsSpan().SequenceEqual(expected.AsSpan(0, expectedLength)), "Pending prefix differs from initial bytes.");
                    using (var handle = (SafeFileHandle)Call(nativeType.GetMethod("OpenLifecyclePendingPublisher", StaticPrivate)!, null, pending))
                        Call(nativeType.GetMethod("VerifyPrivateRegistrySecurity", StaticPrivate)!, null, handle, false, false);
                    if (mode == "corrupt-prefix")
                    {
                        prefix[0] ^= 1; File.WriteAllBytes(pending, prefix);
                        try { Call(publish, service, final, id, snapshot, expected, held, warnings); throw new InvalidOperationException("Corrupt prefix was accepted."); }
                        catch (InvalidDataException error) when (error.Message.Contains("partial body differs")) { }
                        Assert(!File.Exists(final) && File.Exists(ownerPath) && File.ReadAllBytes(pending).SequenceEqual(prefix), "Rejected prefix was not preserved.");
                    }
                    else
                    {
                        var stream = (FileStream)Call(publish, service, final, id, snapshot, expected, held, warnings);
                        stream.Position = 0; var actual = new byte[checked((int)stream.Length)]; stream.ReadExactly(actual);
                        Assert(actual.SequenceEqual(expected) && !File.Exists(ownerPath), "Published snapshot differs from initial bytes or owner remains.");
                        Call(nativeType.GetMethod("VerifyPrivateRegistrySecurity", StaticPrivate)!, null, stream.SafeFileHandle, false, false);
                    }
                    foreach (var stream in held) stream.Dispose();
                    results.Add(new { mode, passed = true, operationId = id, length = expected.Length, sha256 = Digest(expected), prefixLength = expectedLength });
                }
                finally { lease.Dispose(); }
            }
        }
        finally { coordination.Dispose(); }
        return results.ToArray();
    }
}
'@
    $cases = [RegistrySnapshotPublicationProbe]::Run($AssemblyPath, $metadata)
    $report = @{ suite='registry-snapshot-publication-boundary'; assemblyPath=$AssemblyPath; assemblySha256=$ExpectedAssemblySha256; passed=@($cases).Count; failed=0; cases=@($cases); metadata=$metadata; scope='Synthetic metadata only; no registry transaction or native-session E2E.' }
    [IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $report | Select-Object passed,failed,scope | ConvertTo-Json
} catch {
    $report = @{ suite='registry-snapshot-publication-boundary'; assemblyPath=$AssemblyPath; assemblySha256=$ExpectedAssemblySha256; passed=0; failed=1; error=$_.Exception.ToString(); metadata=$metadata }
    [IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    throw
} finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
