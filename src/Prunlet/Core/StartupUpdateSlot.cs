using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Prunlet.Core;

// stateが参照する3つの製品枠のみ。正規のmain streamだけを保持したhandleで再利用する。
// 呼出し元は共通更新mutexを保持し、非使用枠を選択し、返された世代を使用前にdurable記録する。
internal static class StartupUpdateSlot
{
    private const long MaxSlotBytes = 512L * 1024 * 1024;
    private const long MaxCacheBytes = 2L * 1024 * 1024 * 1024;
    internal enum Product { Cli, Maintenance, Hook }

    internal sealed class Lease : IDisposable
    {
        private readonly DirectoryLease parents;
        internal Guid Generation { get; }
        internal FileStream Stream { get; }
        internal bool Reused { get; }
        internal string PreviousStatus { get; }
        private readonly string path;

        internal Lease(DirectoryLease parents, Guid generation, FileStream stream, string path, bool reused, string previousStatus)
        {
            this.parents = parents;
            Generation = generation;
            Stream = stream;
            this.path = path;
            Reused = reused;
            PreviousStatus = previousStatus;
        }

        public void Dispose() { Stream.Dispose(); parents.Dispose(); }

        // 呼出し元がwriting stateを先にdurable化してから無名streamだけを書き換える。
        internal void WriteVerified(Stream input, long expectedBytes, string expectedSha256)
        {
            if (expectedBytes is <= 0 or > MaxSlotBytes || !IsHash(expectedSha256))
                throw new ArgumentException("Candidate slot size or hash is invalid.");
            Stream.Position = 0;
            Stream.SetLength(0);
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[128 * 1024];
            long count = 0;
            while (true)
            {
                var read = input.Read(buffer, 0, buffer.Length);
                if (read == 0) break;
                count = checked(count + read);
                if (count > expectedBytes) throw new InvalidDataException("Candidate exceeds its confirmed size.");
                digest.AppendData(buffer, 0, read);
                Stream.Write(buffer, 0, read);
            }
            Stream.Flush(flushToDisk: true);
            if (count != expectedBytes || !Convert.ToHexString(digest.GetHashAndReset()).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Candidate contents differ from the confirmed product.");
            VerifyBeforeUse(expectedBytes, expectedSha256);
        }

        internal void VerifyBeforeUse(long expectedBytes, string expectedSha256)
        {
            NativeFiles.Verify(Stream.SafeFileHandle, path);
            NativeFiles.VerifySingleLink(Stream.SafeFileHandle);
            NativeFiles.RejectNamedStreams(path);
            Stream.Position = 0;
            var hash = Convert.ToHexString(SHA256.HashData(Stream));
            Stream.Position = 0;
            if (Stream.Length != expectedBytes || !hash.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Slot contents differ from the confirmed product.");
            NativeFiles.RejectNamedStreams(path);
        }
    }

    internal static Lease Acquire(string root, Product product, Guid? previousGeneration, string? previousSha256, long? previousBytes,
        long candidateBytes)
    {
        if (!Enum.IsDefined(product)) throw new ArgumentException("Unknown update product slot.");
        if (candidateBytes is <= 0 or > MaxSlotBytes) throw new ArgumentException("Candidate slot size is invalid.");
        var hasPrevious = previousGeneration.HasValue || previousSha256 is not null || previousBytes.HasValue;
        if (hasPrevious && (!previousGeneration.HasValue || previousGeneration.Value == Guid.Empty
            || previousSha256 is null || previousSha256.Length != 64 || !previousSha256.All(Uri.IsHexDigit)
            || previousBytes is null or <= 0 or > MaxSlotBytes))
            throw new InvalidDataException("The prior product slot identity is incomplete.");
        var directory = Path.Combine(root, ".prunlet-update-slots");
        var parents = PathPolicy.PinDirectories(directory);
        try
        {
            var used = MeasureCache(directory);
            var reason = "no_previous_generation";
            if (hasPrevious)
            {
                var path = Path.Combine(directory, Name(product, previousGeneration!.Value));
                try
                {
                    var handle = CreateFileW(@"\\?\" + PathPolicy.FileSystemAbsolute(path), 0xc0000000, 0,
                        IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
                    if (handle.IsInvalid)
                    {
                        var error = Marshal.GetLastWin32Error();
                        handle.Dispose();
                        reason = error == 2 ? "previous_missing" : "previous_unavailable";
                    }
                    else
                    {
                        FileStream? stream = null;
                        var transferred = false;
                        try
                        {
                            NativeFiles.Verify(handle, path);
                            NativeFiles.VerifySingleLink(handle);
                            NativeFiles.RejectNamedStreams(path);
                            stream = new FileStream(handle, FileAccess.ReadWrite);
                            if (stream.Length == previousBytes)
                            {
                                var hash = Convert.ToHexString(SHA256.HashData(stream));
                                stream.Position = 0;
                                NativeFiles.RejectNamedStreams(path);
                                if (hash.Equals(previousSha256, StringComparison.OrdinalIgnoreCase))
                                {
                                    Reserve(used, Math.Max(0, candidateBytes - previousBytes!.Value));
                                    transferred = true;
                                    return new Lease(parents, previousGeneration.Value, stream, path, true, "verified");
                                }
                            }
                            reason = "previous_contents_changed";
                        }
                        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
                        {
                            reason = "previous_not_verifiable";
                        }
                        finally { if (!transferred) { if (stream is not null) stream.Dispose(); else handle.Dispose(); } }
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
                {
                    reason = "previous_not_verifiable";
                }
            }
            Reserve(used, candidateBytes);
            var generation = Guid.NewGuid();
            var destination = Path.Combine(directory, Name(product, generation));
            var created = new FileStream(destination, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
                128 * 1024, FileOptions.WriteThrough);
            return new Lease(parents, generation, created, destination, false, reason);
        }
        catch { parents.Dispose(); throw; }
    }

    private static string Name(Product product, Guid generation) =>
        "slot-" + product.ToString().ToLowerInvariant() + "-" + generation.ToString("N") + ".bin";

    private static bool IsHash(string? value) => value is not null && value.Length == 64 && value.All(Uri.IsHexDigit);

    private static void Reserve(long used, long incoming)
    {
        if (used < 0 || incoming < 0 || used > MaxCacheBytes - incoming)
            throw new IOException("The update cache capacity is exhausted; retained slots were not changed.");
    }

    internal static long MeasureCache(string directory)
    {
        long total = MeasureDirectory(directory);
        if (total > MaxCacheBytes) throw new IOException("The update cache capacity is exhausted; retained slots were not changed.");
        foreach (var path in Directory.EnumerateFileSystemEntries(directory))
        {
            total = checked(total + MeasureFile(path));
            if (total > MaxCacheBytes) throw new IOException("The update cache capacity is exhausted; retained slots were not changed.");
        }
        return total;
    }

    internal static long MeasureFile(string path)
    {
        // 不明なfileも容量へ含める。directory/reparseや読取不能は走査せず停止する。
        using var handle = NativeFiles.OpenShellInspection(path);
        return MeasureFile(path, handle);
    }

    internal static long MeasureFile(string path, SafeFileHandle handle)
    {
        return MeasureStreams(path, handle, directory: false);
    }

    internal static long MeasureDirectory(string path)
    {
        using var handle = NativeFiles.OpenDirectory(path);
        return MeasureStreams(path, handle, directory: true);
    }

    private static long MeasureStreams(string path, SafeFileHandle handle, bool directory)
    {
        NativeFiles.Verify(handle, path, directory: directory);
        var identity = NativeFiles.MoveIdentity(handle);
        var search = FindFirstStreamW(@"\\?\" + PathPolicy.FileSystemAbsolute(path), 0, out var data, 0);
        if (search == new IntPtr(-1))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == 38)
            {
                NativeFiles.Verify(handle, path, directory: directory);
                return 0;
            }
            throw new IOException($"Cannot inspect update cache streams (Win32 {error}).");
        }
        try
        {
            long total = 0;
            do
            {
                if (data.Size < 0) throw new IOException("An update cache stream has an invalid size.");
                total = checked(total + data.Size);
            } while (FindNextStreamW(search, out data));
            var error = Marshal.GetLastWin32Error();
            if (error != 38) throw new IOException($"Cannot complete update cache stream inspection (Win32 {error}).");
            NativeFiles.Verify(handle, path, directory: directory);
            var after = NativeFiles.MoveIdentity(handle);
            if (identity.VolumeSerialNumber != after.VolumeSerialNumber || identity.FileId != after.FileId)
                throw new IOException("Update storage identity changed while measuring streams.");
            return total;
        }
        finally { FindClose(search); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StreamInformation
    {
        public long Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)] public string Name;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstStreamW(string path, int infoLevel, out StreamInformation data, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindNextStreamW(IntPtr search, out StreamInformation data);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindClose(IntPtr search);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint desiredAccess, uint shareMode,
        IntPtr securityAttributes, uint creationDisposition, uint flags, IntPtr template);
}
