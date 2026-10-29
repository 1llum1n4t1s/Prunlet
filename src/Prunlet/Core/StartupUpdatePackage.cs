using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

// 公開assetの信頼できるdigest/サイズと、解決済みrelease commitを呼出し元から受け取る。
// ZIP内のcommit記載やhashだけでは配布元・build来歴を証明しない。
internal sealed class StartupUpdatePackage : IDisposable
{
    private const long MaxArchiveBytes = 512L * 1024 * 1024;
    private const long MaxProductBytes = 256L * 1024 * 1024;
    private const long MaxAuxiliaryBytes = 4L * 1024 * 1024;
    private const long MaxMetadataBytes = 64L * 1024;
    private const long MaxExpandedBytes = 1024L * 1024 * 1024;
    private static readonly string[] ProductNames =
    [
        "bin/prunlet.exe", "bin/prunlet-maintenance.exe", "bin/prunlet-hook.exe",
        "bin/Install-Prunlet.ps1", "bin/start-prunlet-mcp.ps1", "bin/configuration-common.ps1",
        "bin/maintenance-task.ps1", "bin/uninstall-maintenance.ps1", "bin/install-codex.ps1",
        "bin/uninstall-codex.ps1", "bin/install-agent-instructions.ps1", "bin/PRUNLET.md"
    ];

    internal sealed record Product(string Name, string Sha256, long Bytes);
    internal IReadOnlyList<Product> Products { get; private set; } = [];
    private readonly string stage;
    private readonly DirectoryLease directories;
    private readonly FileStream stream;
    private readonly ZipArchive archive;
    private readonly Dictionary<string, ZipArchiveEntry> entries;

    private StartupUpdatePackage(string stage, DirectoryLease directories, FileStream stream,
        ZipArchive archive, Dictionary<string, ZipArchiveEntry> entries)
    {
        this.stage = stage;
        this.directories = directories;
        this.stream = stream;
        this.archive = archive;
        this.entries = entries;
    }

    internal static StartupUpdatePackage OpenVerified(string root, string expectedRepository, string expectedBranch,
        string expectedCommit, string expectedRuntime, string expectedAssetSha256, long expectedAssetBytes)
    {
        if (!Hex(expectedCommit, 40) || !Hex(expectedAssetSha256, 64)
            || expectedRuntime is not ("win-x64" or "win-arm64") || expectedAssetBytes is <= 0 or > MaxArchiveBytes
            || string.IsNullOrWhiteSpace(expectedRepository) || string.IsNullOrWhiteSpace(expectedBranch))
            throw new ArgumentException("The authenticated release asset identity is incomplete or unsupported.");
        var stage = Path.Combine(root, ".prunlet-update-stage");
        var directories = PathPolicy.PinDirectories(stage);
        FileStream? input = null;
        ZipArchive? zip = null;
        try
        {
            var state = StartupUpdateCoordinator.ReadState(root)
                ?? throw new InvalidDataException("Package stage has no durable update state.");
            if (state.StageCleanup != "pending" || state.Phase is not ("idle" or "switching" or "migrating")
                || !string.Equals(state.CandidateCommit, expectedCommit, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Package stage does not match the pending update state.");
            StartupUpdateCoordinator.VerifyStageOwner(stage, root, expectedCommit);
            if (!StartupUpdateCoordinator.IsPackageName(state.PackageName))
                throw new InvalidDataException("The package cache name is unsupported.");
            var path = Path.Combine(stage, state.PackageName);
            var handle = NativeFiles.OpenBackup(path);
            try
            {
                NativeFiles.Verify(handle, path);
                NativeFiles.VerifySingleLink(handle);
                input = new FileStream(handle, FileAccess.Read);
            }
            catch { handle.Dispose(); throw; }
            if (input.Length != expectedAssetBytes) throw new InvalidDataException("Release asset size differs from the authenticated value.");
            var digest = Convert.ToHexString(SHA256.HashData(input));
            if (!digest.Equals(expectedAssetSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Release asset digest differs from the authenticated value.");
            input.Position = 0;
            zip = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: true);
            var expectedNames = ProductNames.Append("package.json").ToHashSet(StringComparer.Ordinal);
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.Ordinal);
            if (zip.Entries.Count != expectedNames.Count) throw new InvalidDataException("Release package contains an unexpected number of entries.");
            foreach (var entry in zip.Entries)
            {
                var attrs = unchecked((uint)entry.ExternalAttributes);
                var unixType = (attrs >> 16) & 0xf000;
                if (!expectedNames.Contains(entry.FullName) || !names.Add(entry.FullName)
                    || (attrs & 0x400) != 0 || unixType is not (0 or 0x8000))
                    throw new InvalidDataException("Release package contains an unsupported, duplicate, or linked entry.");
                entries.Add(entry.FullName, entry);
            }
            var result = new StartupUpdatePackage(stage, directories, input, zip, entries);
            result.Products = result.VerifyManifest(expectedRepository, expectedBranch, expectedCommit, expectedRuntime);
            return result;
        }
        catch
        {
            zip?.Dispose();
            input?.Dispose();
            directories.Dispose();
            throw;
        }
    }

    private IReadOnlyList<Product> VerifyManifest(string repository, string branch, string commit, string runtime)
    {
        var metadata = entries["package.json"];
        if (metadata.Length is <= 0 or > MaxMetadataBytes) throw new InvalidDataException("Package metadata is too large or empty.");
        using var metadataData = new MemoryStream();
        using (var reader = metadata.Open()) CopyBounded(reader, metadataData, MaxMetadataBytes, out _);
        metadataData.Position = 0;
        using var document = JsonDocument.Parse(metadataData);
        var root = document.RootElement;
        CheckObject(root, ["product", "schema", "repository", "defaultBranch", "commitSha", "commitVerification", "runtime", "files"]);
        var recordedBranch = root.GetProperty("defaultBranch").GetString();
        if (root.GetProperty("product").GetString() != "Prunlet" || root.GetProperty("schema").GetInt32() != 1
            || !string.Equals(root.GetProperty("repository").GetString(), repository, StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(recordedBranch)
            || recordedBranch.Contains("..", StringComparison.Ordinal) || recordedBranch.StartsWith('/') || recordedBranch.EndsWith('/')
            || recordedBranch.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '_' or '/' or '-'))
            || !string.Equals(root.GetProperty("commitSha").GetString(), commit, StringComparison.OrdinalIgnoreCase)
            || root.GetProperty("runtime").GetString() != runtime
            || root.GetProperty("commitVerification").GetString() != "caller-asserted")
            throw new InvalidDataException("Package metadata does not match the authenticated release identity.");
        var files = root.GetProperty("files");
        CheckObject(files, ProductNames);
        var products = new List<Product>();
        long total = 0;
        foreach (var name in ProductNames)
        {
            var item = files.GetProperty(name);
            CheckObject(item, ["sha256", "bytes"]);
            var hash = item.GetProperty("sha256").GetString();
            var bytes = item.GetProperty("bytes").GetInt64();
            var limit = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? MaxProductBytes : MaxAuxiliaryBytes;
            if (!Hex(hash, 64) || bytes <= 0 || bytes > limit || entries[name].Length != bytes)
                throw new InvalidDataException("Package product has an invalid hash or size: " + name);
            total = checked(total + bytes);
            if (total > MaxExpandedBytes) throw new InvalidDataException("Package expanded size exceeds its limit.");
            using var input = entries[name].Open();
            CopyBounded(input, Stream.Null, limit, out var actualHash, out var actualBytes);
            if (actualBytes != bytes || !actualHash.Equals(hash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Package product contents differ from metadata: " + name);
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) VerifyMachine(entries[name], runtime);
            products.Add(new Product(name, actualHash, bytes));
        }
        if (!products[0].Sha256.Equals(products[2].Sha256, StringComparison.Ordinal))
            throw new InvalidDataException("Hook executable does not match the CLI executable.");
        return products;
    }

    private static void VerifyMachine(ZipArchiveEntry entry, string runtime)
    {
        using var input = entry.Open();
        Span<byte> header = stackalloc byte[64];
        input.ReadExactly(header);
        if (System.Buffers.Binary.BinaryPrimitives.ReadUInt16LittleEndian(header) != 0x5a4d)
            throw new InvalidDataException("Package executable does not have a DOS header: " + entry.FullName);
        var offset = System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(header[60..]);
        if (offset < 64 || offset > 1024 * 1024 || offset > entry.Length - 6)
            throw new InvalidDataException("Package executable has an invalid PE header offset: " + entry.FullName);
        var remaining = offset - 64;
        Span<byte> skip = stackalloc byte[4096];
        while (remaining != 0)
        {
            var take = (int)Math.Min(remaining, (uint)skip.Length);
            input.ReadExactly(skip[..take]);
            remaining -= (uint)take;
        }
        Span<byte> pe = stackalloc byte[6];
        input.ReadExactly(pe);
        var machine = System.Buffers.Binary.BinaryPrimitives.ReadUInt16LittleEndian(pe[4..]);
        var expected = runtime == "win-x64" ? 0x8664 : 0xaa64;
        if (System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(pe) != 0x00004550 || machine != expected)
            throw new InvalidDataException("Package executable architecture differs from its runtime: " + entry.FullName);
    }

    internal Stream OpenProduct(string name)
    {
        if (!ProductNames.Contains(name, StringComparer.Ordinal))
            throw new ArgumentException("Unknown published product.");
        return entries[name].Open();
    }

    // 出力先は所有済みstage内の新規固定directoryだけ。中断時は部分出力を保全する。
    internal void ExtractToNewPayload()
    {
        var payload = Path.Combine(stage, "payload");
        NativeFiles.CreateDirectory(payload);
        using var payloadParents = PathPolicy.PinDirectories(payload);
        var bin = Path.Combine(payload, "bin");
        NativeFiles.CreateDirectory(bin);
        using var binParents = PathPolicy.PinDirectories(bin);
        foreach (var product in Products)
        {
            var destination = Path.Combine(bin, product.Name["bin/".Length..]);
            using var input = entries[product.Name].Open();
            using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                128 * 1024, FileOptions.WriteThrough);
            CopyBounded(input, output, product.Bytes, out var hash, out var bytes);
            output.Flush(flushToDisk: true);
            if (bytes != product.Bytes || !hash.Equals(product.Sha256, StringComparison.Ordinal))
                throw new InvalidDataException("Extracted product does not match verified package metadata: " + product.Name);
        }
    }

    private static bool Hex(string? value, int length) => value is not null && value.Length == length && value.All(Uri.IsHexDigit);

    private static void CheckObject(JsonElement value, IReadOnlyCollection<string> expected)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Package metadata field must be an object.");
        var properties = value.EnumerateObject().ToArray();
        var names = properties.Select(item => item.Name).ToHashSet(StringComparer.Ordinal);
        if (properties.Length != expected.Count || names.Count != expected.Count || !names.SetEquals(expected))
            throw new InvalidDataException("Package metadata has unknown, missing, or duplicate fields.");
    }

    private static void CopyBounded(Stream input, Stream output, long limit, out string hash)
        => CopyBounded(input, output, limit, out hash, out _);

    private static void CopyBounded(Stream input, Stream output, long limit, out string hash, out long bytes)
    {
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[128 * 1024];
        bytes = 0;
        while (true)
        {
            var count = input.Read(buffer, 0, buffer.Length);
            if (count == 0) break;
            bytes = checked(bytes + count);
            if (bytes > limit) throw new InvalidDataException("Package entry exceeds its allowed expanded size.");
            digest.AppendData(buffer, 0, count);
            output.Write(buffer, 0, count);
        }
        hash = Convert.ToHexString(digest.GetHashAndReset());
    }

    public void Dispose()
    {
        archive.Dispose();
        stream.Dispose();
        directories.Dispose();
    }
}
