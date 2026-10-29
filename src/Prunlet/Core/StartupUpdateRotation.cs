using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

// 共通更新mutexとcurrentのguardは呼出し元が保持する。
internal static class StartupUpdateRotation
{
    internal static void Rotate(string root, string currentLeaf, string candidateLeaf, string previousLeaf,
        string stagedLeaf, string currentHash, string candidateHash, string? priorPreviousHash,
        SafeFileHandle currentGuard, StartupUpdateCoordinator.UpdateState state)
    {
        if (currentLeaf is not ("prunlet.exe" or "prunlet-maintenance.exe" or "prunlet-hook.exe")
            || stagedLeaf != currentLeaf || candidateLeaf != currentLeaf[..^4] + ".candidate.exe"
            || previousLeaf != currentLeaf[..^4] + ".previous.exe"
            || !IsHash(currentHash) || !IsHash(candidateHash)
            || (priorPreviousHash is not null && !IsHash(priorPreviousHash)))
            throw new InvalidDataException("Invalid update rotation inputs.");
        var bin = Path.Combine(root, "bin");
        var stage = Path.Combine(root, ".prunlet-update-stage");
        using var binParents = PathPolicy.PinDirectories(bin);
        using var stageParents = PathPolicy.PinDirectories(stage);
        var current = Path.Combine(bin, currentLeaf);
        var previous = Path.Combine(bin, previousLeaf);
        var staged = Path.Combine(stage, stagedLeaf);
        var stem = currentLeaf[..^4];

        if (state.RotationName != currentLeaf)
        {
            if (state.RotationStatus.Length != 0)
                throw new IOException("Another product rotation is still recorded; its state was retained.");
            state.RotationName = currentLeaf;
            state.RotationStatus = "";
            state.RotationPriorSha256 = priorPreviousHash ?? "";
            state.RotationCandidateSha256 = candidateHash;
            state.RotationBackupName = "";
        }
        if (state.RotationCandidateSha256 != candidateHash || state.RotationPriorSha256 != (priorPreviousHash ?? ""))
            throw new InvalidDataException("Rotation state does not match the confirmed product.");

        var backup = state.RotationBackupName.Length == 0 ? previousLeaf : state.RotationBackupName;
        if (backup != previousLeaf && !IsUniqueName(backup, stem + ".previous-"))
            throw new InvalidDataException("Invalid rotation backup name.");
        var candidate = backup == previousLeaf ? candidateLeaf : stem + ".candidate-" + backup[(stem.Length + ".previous-".Length)..];
        var backupPath = Path.Combine(bin, backup);
        var candidatePath = Path.Combine(bin, candidate);

        if (state.RotationStatus is "replacing" or "ambiguous")
            throw new IOException("Interrupted or ambiguous product replacement requires inspection; all files were retained.");

        var guardedPath = NativeFiles.ResolveVerified(currentGuard);
        if (guardedPath.Equals(backupPath, StringComparison.Ordinal))
        {
            NativeFiles.Verify(currentGuard, backupPath);
            NativeFiles.VerifySingleLink(currentGuard);
            VerifyHandleHash(currentGuard, currentHash);
            VerifyPathHash(current, candidateHash);
            state.RotationStatus = "switched";
            StartupUpdateCoordinator.WriteState(root, state);
            return;
        }
        NativeFiles.Verify(currentGuard, current);
        NativeFiles.VerifySingleLink(currentGuard);
        VerifyHandleHash(currentGuard, currentHash);
        VerifyPathHash(staged, candidateHash);

        // writingで中断した対象は内容が不明なので、再利用せず別名へ進める。
        if (state.RotationStatus == "writing")
        {
            SelectFallback();
        }
        if (state.RotationStatus == "")
        {
            var reused = false;
            var fixedCandidateAbsent = false;
            try { using var existing = NativeFiles.OpenAny(Path.Combine(bin, candidateLeaf)); }
            catch (FileNotFoundException) { fixedCandidateAbsent = true; }
            StartupUpdateBudget.Ensure(root, Math.Max(new FileInfo(staged).Length, new FileInfo(current).Length));
            if (priorPreviousHash is not null && fixedCandidateAbsent)
            {
                try
                {
                    using var handle = OpenRotation(previous);
                    NativeFiles.Verify(handle, previous);
                    NativeFiles.VerifySingleLink(handle);
                    NativeFiles.RejectNamedStreams(previous);
                    VerifyHandleHash(handle, priorPreviousHash);
                    state.RotationBackupName = previousLeaf;
                    state.RotationStatus = "writing";
                    StartupUpdateCoordinator.WriteState(root, state);
                    using var target = new FileStream(handle, FileAccess.ReadWrite);
                    WriteCandidate(target, staged, candidateHash);
                    NativeFiles.Verify(target.SafeFileHandle, previous);
                    NativeFiles.VerifySingleLink(target.SafeFileHandle);
                    NativeFiles.RejectNamedStreams(previous);
                    state.RotationStatus = "candidate_ready";
                    StartupUpdateCoordinator.WriteState(root, state);
                    NativeFiles.RenameHandle(target.SafeFileHandle, candidatePath);
                    NativeFiles.Verify(target.SafeFileHandle, candidatePath);
                    state.RotationStatus = "candidate_named";
                    StartupUpdateCoordinator.WriteState(root, state);
                    reused = true;
                }
                catch (Exception ex) when (state.RotationStatus == "" && ex is (IOException or UnauthorizedAccessException or InvalidDataException))
                {
                    // 不明・使用中・ADS付きのpreviousはそのまま残す。
                }
            }
            if (!reused)
            {
                var previousAbsent = false;
                try { using var existing = NativeFiles.OpenAny(previous); }
                catch (FileNotFoundException) { previousAbsent = true; }
                if (previousAbsent && fixedCandidateAbsent) SelectFreshFixed();
                else SelectFallback();
            }
        }

        if (state.RotationStatus == "candidate_ready")
        {
            // rename完了直後の中断も、candidateの内容が一致する場合だけ継続する。
            try { VerifyPathHash(candidatePath, candidateHash); }
            catch (FileNotFoundException)
            {
                using var handle = OpenRotation(previous);
                NativeFiles.Verify(handle, previous);
                NativeFiles.VerifySingleLink(handle);
                NativeFiles.RejectNamedStreams(previous);
                VerifyHandleHash(handle, candidateHash);
                NativeFiles.RenameHandle(handle, candidatePath);
                NativeFiles.Verify(handle, candidatePath);
            }
            state.RotationStatus = "candidate_named";
            StartupUpdateCoordinator.WriteState(root, state);
        }
        if (state.RotationStatus != "candidate_named") throw new IOException("Update rotation requires inspection.");
        StartupUpdateBudget.Ensure(root, Math.Max(0, new FileInfo(current).Length - new FileInfo(candidatePath).Length));
        MoveEntryIdentity candidateIdentity;
        using var inspection = NativeFiles.OpenShellInspection(candidatePath);
        using (var candidateGuard = NativeFiles.OpenHardlinkReadGuard(candidatePath))
        {
            NativeFiles.Verify(inspection, candidatePath);
            NativeFiles.Verify(candidateGuard, candidatePath);
            NativeFiles.VerifySingleLink(candidateGuard);
            NativeFiles.RejectNamedStreams(candidatePath);
            VerifyHandleHash(candidateGuard, candidateHash);
            candidateIdentity = NativeFiles.MoveIdentity(candidateGuard);
            var inspectedIdentity = NativeFiles.MoveIdentity(inspection);
            if (candidateIdentity.VolumeSerialNumber != inspectedIdentity.VolumeSerialNumber
                || !candidateIdentity.FileId.Equals(inspectedIdentity.FileId, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Candidate inspection does not refer to the verified file.");
        }
        NativeFiles.Verify(currentGuard, current);
        VerifyHandleHash(currentGuard, currentHash);
        NativeFiles.RejectNamedStreams(current);
        try
        {
            using var unexpected = NativeFiles.OpenAny(backupPath);
            throw new IOException("Rotation backup name is occupied; the existing file was retained: " + backupPath);
        }
        catch (FileNotFoundException) { }
        state.RotationStatus = "replacing";
        StartupUpdateCoordinator.WriteState(root, state);
        try
        {
            File.Replace(candidatePath, current, backupPath);
            NativeFiles.Verify(inspection, current);
            NativeFiles.VerifySingleLink(inspection);
            using var installed = NativeFiles.OpenHardlinkReadGuard(current);
            NativeFiles.Verify(installed, current);
            NativeFiles.VerifySingleLink(installed);
            NativeFiles.RejectNamedStreams(current);
            var installedIdentity = NativeFiles.MoveIdentity(installed);
            if (candidateIdentity.VolumeSerialNumber != installedIdentity.VolumeSerialNumber
                || !candidateIdentity.FileId.Equals(installedIdentity.FileId, StringComparison.OrdinalIgnoreCase))
                throw new IOException("The installed candidate is not the verified file.");
            VerifyHandleHash(installed, candidateHash);
            NativeFiles.Verify(currentGuard, backupPath);
            NativeFiles.VerifySingleLink(currentGuard);
            VerifyHandleHash(currentGuard, currentHash);
            state.RotationStatus = "switched";
            StartupUpdateCoordinator.WriteState(root, state);
        }
        catch (Exception ex)
        {
            state.RotationStatus = "ambiguous";
            try { StartupUpdateCoordinator.WriteState(root, state); }
            catch (Exception recordError)
            {
                throw new IOException("Product replacement could not be verified and its ambiguous state could not be recorded; all files were retained.",
                    new AggregateException(ex, recordError));
            }
            throw new IOException("Product replacement could not be verified; all files were retained for inspection.", ex);
        }
        return;

        void SelectFallback()
        {
            StartupUpdateBudget.Ensure(root, Math.Max(new FileInfo(staged).Length, new FileInfo(current).Length));
            var id = Guid.NewGuid().ToString("N");
            backup = stem + ".previous-" + id + ".exe";
            candidate = stem + ".candidate-" + id + ".exe";
            backupPath = Path.Combine(bin, backup);
            candidatePath = Path.Combine(bin, candidate);
            state.RotationBackupName = backup;
            state.RotationStatus = "writing";
            StartupUpdateCoordinator.WriteState(root, state);
            using (var target = new FileStream(candidatePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
                128 * 1024, FileOptions.WriteThrough))
                WriteCandidate(target, staged, candidateHash);
            state.RotationStatus = "candidate_named";
            StartupUpdateCoordinator.WriteState(root, state);
        }

        void SelectFreshFixed()
        {
            backup = previousLeaf;
            candidate = candidateLeaf;
            backupPath = previous;
            candidatePath = Path.Combine(bin, candidate);
            state.RotationBackupName = backup;
            state.RotationStatus = "writing";
            StartupUpdateCoordinator.WriteState(root, state);
            using (var target = new FileStream(candidatePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
                128 * 1024, FileOptions.WriteThrough))
                WriteCandidate(target, staged, candidateHash);
            state.RotationStatus = "candidate_named";
            StartupUpdateCoordinator.WriteState(root, state);
        }
    }

    private static void WriteCandidate(FileStream target, string sourcePath, string expectedHash)
    {
        using var sourceHandle = NativeFiles.OpenBackup(sourcePath);
        NativeFiles.Verify(sourceHandle, sourcePath);
        NativeFiles.VerifySingleLink(sourceHandle);
        NativeFiles.RejectNamedStreams(sourcePath);
        using var source = new FileStream(sourceHandle, FileAccess.Read);
        target.Position = 0;
        target.SetLength(0);
        source.CopyTo(target);
        target.Flush(true);
        target.Position = 0;
        if (!Convert.ToHexString(SHA256.HashData(target)).Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Rotation candidate hash differs from the verified package.");
    }

    private static void VerifyPathHash(string path, string hash)
    {
        using var handle = NativeFiles.OpenBackup(path);
        NativeFiles.Verify(handle, path);
        NativeFiles.VerifySingleLink(handle);
        NativeFiles.RejectNamedStreams(path);
        VerifyHandleHash(handle, hash);
    }

    private static void VerifyHandleHash(SafeFileHandle handle, string hash)
    {
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[128 * 1024];
        long offset = 0;
        int count;
        while ((count = RandomAccess.Read(handle, buffer, offset)) != 0)
        {
            digest.AppendData(buffer, 0, count);
            offset += count;
        }
        if (!Convert.ToHexString(digest.GetHashAndReset()).Equals(hash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Rotation file hash differs from its recorded identity.");
    }

    private static bool IsHash(string hash) => hash.Length == 64 && hash.All(Uri.IsHexDigit);
    private static bool IsUniqueName(string name, string prefix) => name.StartsWith(prefix, StringComparison.Ordinal)
        && name.EndsWith(".exe", StringComparison.Ordinal) && name.Length == prefix.Length + 32 + 4
        && Guid.TryParseExact(name.Substring(prefix.Length, 32), "N", out var id) && id != Guid.Empty;

    private static SafeFileHandle OpenRotation(string path)
    {
        var handle = CreateFileW(@"\\?\" + PathPolicy.FileSystemAbsolute(path), 0xC0010000, 5,
            IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        if (error is 2 or 3) throw new FileNotFoundException("Rotation file is absent.", path);
        throw new IOException("Cannot hold rotation file for writing and rename.", new Win32Exception(error));
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);
}
