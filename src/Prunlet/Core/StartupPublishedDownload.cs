using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace Prunlet.Core;

// 公開assetの取得先はGitHubの当該repositoryとasset IDだけに固定する。
internal static class StartupPublishedDownload
{
    internal static void Receive(string configPath, string repository, string commit,
        long assetId, string expectedSha256, long expectedBytes)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(repository, @"\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\z")
            || assetId <= 0 || expectedBytes is <= 0 or > 536870912
            || expectedSha256.Length != 64 || !expectedSha256.All(Uri.IsHexDigit))
            throw new ArgumentException("Published asset identity is invalid.");
        var root = StartupUpdateCoordinator.InstallationRoot(configPath);
        var stage = Path.Combine(root, ".prunlet-update-stage");
        using var parents = PathPolicy.PinDirectories(stage);
        using var mutexes = new StartupUpdateCoordinator.InstallationMutexes(root);
        var state = StartupUpdateCoordinator.ReadState(root)
            ?? throw new InvalidDataException("Published download has no prepared state.");
        if (state.Phase != "idle" || state.StageCleanup != "pending"
            || !string.Equals(state.CandidateCommit, commit, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Published download does not match its prepared state.");
        StartupUpdateCoordinator.VerifyStageOwner(stage, root, commit);
        StartupUpdateBudget.Ensure(root, 0);
        using var output = OpenDestination(root, stage, state, expectedSha256, expectedBytes);
        if (output is null) return;
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        using var request = new HttpRequestMessage(HttpMethod.Get,
            $"https://api.github.com/repos/{repository}/releases/assets/{assetId}");
        request.Headers.UserAgent.ParseAdd("Prunlet-Published-Updater");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/octet-stream"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        // Windows mutexはthread所属なので、I/O完了を同じ呼出しthreadで待つ。
        using var response = client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation.Token).GetAwaiter().GetResult();
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is long length && length != expectedBytes)
            throw new InvalidDataException("Published package response length differs from its asset metadata.");
        using var source = response.Content.ReadAsStreamAsync(cancellation.Token).GetAwaiter().GetResult();
        CopyVerified(source, output, expectedSha256, expectedBytes, cancellation.Token);
        NativeFiles.Verify(output.SafeFileHandle, Path.Combine(stage, state.PackageName));
        NativeFiles.RejectNamedStreams(Path.Combine(stage, state.PackageName));
        output.Dispose();
        state.PackageStatus = "ready";
        state.PackagePreviousSha256 = expectedSha256;
        state.PackagePreviousBytes = expectedBytes;
        StartupUpdateCoordinator.WriteState(root, state);
        StartupUpdateBudget.Ensure(root, 0);
    }

    // 書換えるのはstateと主streamが一致した非使用cacheだけ。途中出力・未知のADSは残す。
    internal static FileStream? OpenDestination(string root, string stage, StartupUpdateCoordinator.UpdateState state,
        string expectedSha256, long expectedBytes)
    {
        if (!StartupUpdateCoordinator.IsPackageName(state.PackageName)) throw new InvalidDataException("Invalid package cache name.");
        // 排他handleの取得前に計測し、再利用には増分だけを予約する。
        var used = StartupUpdateBudget.Measure(root);
        var destination = Path.Combine(stage, state.PackageName);
        FileStream? existing = null;
        var reusable = false;
        try
        {
            existing = new FileStream(destination, FileMode.Open, FileAccess.ReadWrite, FileShare.None,
                131072, FileOptions.WriteThrough);
            NativeFiles.Verify(existing.SafeFileHandle, destination);
            NativeFiles.VerifySingleLink(existing.SafeFileHandle);
            NativeFiles.RejectNamedStreams(destination);
            var hash = Convert.ToHexString(SHA256.HashData(existing));
            existing.Position = 0;
            if (existing.Length == expectedBytes && hash.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                existing.Dispose();
                state.PackageStatus = "ready";
                state.PackagePreviousSha256 = expectedSha256;
                state.PackagePreviousBytes = expectedBytes;
                StartupUpdateCoordinator.WriteState(root, state);
                return null;
            }
            if (state.PackageStatus == "ready" && existing.Length == state.PackagePreviousBytes
                && hash.Equals(state.PackagePreviousSha256, StringComparison.OrdinalIgnoreCase))
            {
                reusable = true;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 正体が確認できないcacheは再利用しない。
        }
        if (reusable)
        {
            try
            {
                StartupUpdateBudget.EnsureSnapshot(used, Math.Max(0, expectedBytes - existing!.Length));
                state.PackageStatus = "writing";
                StartupUpdateCoordinator.WriteState(root, state);
                return existing;
            }
            catch { existing!.Dispose(); throw; }
        }
        existing?.Dispose();
        StartupUpdateBudget.EnsureSnapshot(used, expectedBytes);
        state.PackageName = "package-" + Guid.NewGuid().ToString("N") + ".zip";
        state.PackageStatus = "writing";
        StartupUpdateCoordinator.WriteState(root, state);
        return new FileStream(Path.Combine(stage, state.PackageName), FileMode.CreateNew, FileAccess.ReadWrite,
            FileShare.None, 131072, FileOptions.WriteThrough);
    }

    internal static void CopyVerified(Stream source, FileStream output, string expectedSha256, long expectedBytes, CancellationToken cancellation)
    {
        output.Position = 0;
        output.SetLength(0);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[131072];
        long count = 0;
        int read;
        while ((read = source.ReadAsync(buffer.AsMemory(), cancellation).AsTask().GetAwaiter().GetResult()) != 0)
        {
            count = checked(count + read);
            if (count > expectedBytes) throw new InvalidDataException("Published package exceeds its authenticated length.");
            output.Write(buffer, 0, read);
            hash.AppendData(buffer, 0, read);
        }
        output.Flush(true);
        if (count != expectedBytes || !Convert.ToHexString(hash.GetHashAndReset()).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Published package hash or length differs; the partial package was preserved.");
    }
}
