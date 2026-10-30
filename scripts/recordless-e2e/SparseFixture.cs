using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class PrunletSparseE2E {
    // shellapi.h applies pshpack1 only when !_WIN64.
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct SHQUERYRBINFO32 { public uint cbSize; public long i64Size; public long i64NumItems; }
    [StructLayout(LayoutKind.Sequential)]
    struct SHQUERYRBINFO64 { public uint cbSize; public long i64Size; public long i64NumItems; }
    [DllImport("shell32.dll", EntryPoint = "SHQueryRecycleBinW", CharSet = CharSet.Unicode)]
    static extern int SHQueryRecycleBinW(string rootPath, ref SHQUERYRBINFO32 info);
    [DllImport("shell32.dll", EntryPoint = "SHQueryRecycleBinW", CharSet = CharSet.Unicode)]
    static extern int SHQueryRecycleBinW(string rootPath, ref SHQUERYRBINFO64 info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle file, uint code, IntPtr input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetCompressedFileSizeW(string path, out uint high);
    [DllImport("kernel32.dll")]
    static extern void SetLastError(uint error);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int field, byte[] bytes, uint length);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetKernelObjectSecurity(SafeFileHandle file, uint information, byte[] bytes, uint length, out uint needed);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder name, uint length, uint flags);
    public sealed class SparseProof {
        public string Id { get; set; }
        public string SecurityBase64 { get; set; }
        public int Attributes { get; set; }
        public long Length { get; set; }
        public long AllocationSize { get; set; }
        public long CompressedSize { get; set; }
        public uint NumberOfLinks { get; set; }
        public string FinalPath { get; set; }
        public string[] Streams { get; set; }
    }
    public sealed class AllocatedRange {
        public long Offset { get; set; }
        public long Length { get; set; }
    }
    public sealed class SparseFinalizationResult {
        public bool Success { get; set; }
        public string Error { get; set; }
        public string Path { get; set; }
        public long ExpectedLogicalLength { get; set; }
        public string PrefixBase64 { get; set; }
        public bool MutationStarted { get; set; }
        public bool AlreadyTiny { get; set; }
        public bool TailWasZero { get; set; }
        public long BytesChecked { get; set; }
        public SparseProof Before { get; set; }
        public SparseProof After { get; set; }
        public SparseProof PostClose { get; set; }
        public AllocatedRange[] AllocatedRangesBefore { get; set; }
        public AllocatedRange[] AllocatedRangesAfter { get; set; }
    }
    static byte[] Info(SafeFileHandle file, int field, int size) {
        var bytes = new byte[size];
        if (!GetFileInformationByHandleEx(file, field, bytes, (uint)bytes.Length)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return bytes;
    }
    static string FinalPath(SafeFileHandle file) {
        var buffer = new StringBuilder(32768);
        uint count = GetFinalPathNameByHandleW(file, buffer, (uint)buffer.Capacity, 0);
        if (count == 0 || count >= buffer.Capacity) throw new IOException("Cannot bind the sparse handle to its complete DOS path.");
        var path = buffer.ToString();
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) path = path.Substring(4);
        return System.IO.Path.GetFullPath(path);
    }
    static List<SafeFileHandle> PinParents(string path) {
        var parents = new Stack<string>();
        for (var directory = System.IO.Path.GetDirectoryName(path); !string.IsNullOrEmpty(directory); directory = System.IO.Path.GetDirectoryName(directory)) parents.Push(directory);
        var pins = new List<SafeFileHandle>();
        try {
            while (parents.Count != 0) {
                var directory = parents.Pop();
                var handle = CreateFileW(directory, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
                pins.Add(handle);
                var attributes = BitConverter.ToUInt32(Info(handle, 0, 40), 32);
                if ((attributes & 0x10) == 0 || (attributes & 0x400) != 0) throw new IOException("Sparse fixture parent is not an ordinary pinned directory.");
            }
            return pins;
        } catch { foreach (var pin in pins) pin.Dispose(); throw; }
    }
    static SafeFileHandle OpenExclusive(string path, bool writable) {
        var handle = CreateFileW(path, writable ? 0xC0020000u : 0x80020000u, 0, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
        return handle;
    }
    static SparseProof ReadProof(SafeFileHandle handle, string path) {
        var basic = Info(handle, 0, 40); var standard = Info(handle, 1, 24); var compression = Info(handle, 8, 16);
        if (standard[20] != 0 || standard[21] != 0 || BitConverter.ToInt64(standard, 0) < 0 || BitConverter.ToInt64(standard, 8) < 0 || BitConverter.ToInt64(compression, 0) < 0 || BitConverter.ToUInt16(compression, 8) != 0)
            throw new IOException("Sparse fixture has an unknown directory/delete/compression state.");
        GetKernelObjectSecurity(handle, 7, null, 0, out uint needed);
        if (needed == 0 || needed > 1048576) throw new IOException("Sparse security descriptor length is unknown.");
        var security = new byte[needed];
        if (!GetKernelObjectSecurity(handle, 7, security, needed, out uint used) || used != needed) throw new Win32Exception(Marshal.GetLastWin32Error());
        var streamBytes = Info(handle, 7, 65536); var streams = new List<string>(); int offset = 0;
        while (true) {
            if (offset < 0 || offset > streamBytes.Length - 24) throw new IOException("Sparse stream inventory is incomplete.");
            uint next = BitConverter.ToUInt32(streamBytes, offset); uint length = BitConverter.ToUInt32(streamBytes, offset + 4);
            if (length == 0 || (length & 1) != 0 || length > streamBytes.Length - offset - 24) throw new IOException("Sparse stream inventory is malformed.");
            var name = Encoding.Unicode.GetString(streamBytes, offset + 24, (int)length); streams.Add(name);
            if (name != "::" + (char)36 + "DATA" || BitConverter.ToInt64(streamBytes, offset + 8) != BitConverter.ToInt64(standard, 8)) throw new IOException("Sparse fixture has an unknown named stream or stream length.");
            if (next == 0) break;
            if (next < 24 || next > streamBytes.Length - offset || streams.Count >= 64) throw new IOException("Sparse stream inventory did not advance.");
            offset += (int)next;
        }
        if (streams.Count != 1) throw new IOException("Sparse fixture is not a single unnamed data stream.");
        var final = FinalPath(handle);
        if (!string.Equals(final, path, StringComparison.OrdinalIgnoreCase)) throw new IOException("Sparse fixture handle no longer names its recorded path.");
        return new SparseProof { Id = Convert.ToHexString(Info(handle, 18, 24)), SecurityBase64 = Convert.ToBase64String(security), Attributes = (int)BitConverter.ToUInt32(basic, 32),
            Length = BitConverter.ToInt64(standard, 8), AllocationSize = BitConverter.ToInt64(standard, 0), CompressedSize = BitConverter.ToInt64(compression, 0), NumberOfLinks = BitConverter.ToUInt32(standard, 16), FinalPath = final, Streams = streams.ToArray() };
    }
    public static SparseProof CaptureProof(string path) {
        path = System.IO.Path.GetFullPath(path);
        var pins = PinParents(path);
        try { using var handle = OpenExclusive(path, false); return ReadProof(handle, path); }
        finally { foreach (var pin in pins) pin.Dispose(); }
    }
    static void MatchProof(SparseProof proof, string id, string security, int attributes, long length, ulong maximum) {
        if (proof.Id != id || proof.SecurityBase64 != security || proof.Attributes != attributes || proof.Length != length || proof.NumberOfLinks != 1)
            throw new IOException("Sparse fixture identity, complete O/G/D, attributes, length or link count differs from its recorded proof.");
        const int forbidden = 0x10 | 0x40 | 0x400 | 0x800 | 0x1000 | 0x4000 | 0x40000 | 0x400000;
        if ((proof.Attributes & 0x200) == 0 || (proof.Attributes & forbidden) != 0 || (ulong)proof.AllocationSize > maximum || (ulong)proof.CompressedSize > maximum)
            throw new IOException("Sparse fixture allocation or file state is not understood; it was retained.");
    }
    // winioctl.h: FSCTL_QUERY_ALLOCATED_RANGES = CTL_CODE(9,51,METHOD_NEITHER,FILE_READ_DATA),
    // FILE_ALLOCATED_RANGE_BUFFER はFileOffset/Lengthのsigned LARGE_INTEGER二つ。返却範囲以外はsparse hole。
    static AllocatedRange[] QueryRanges(SafeFileHandle file, long queryLength, ulong maximum) {
        if (queryLength <= 0) throw new IOException("Sparse allocation query length is invalid.");
        var ranges = new List<AllocatedRange>(); long cursor = 0; ulong total = 0;
        IntPtr input = Marshal.AllocHGlobal(16), output = Marshal.AllocHGlobal(65536);
        try {
            while (cursor < queryLength) {
                Marshal.WriteInt64(input, 0, cursor); Marshal.WriteInt64(input, 8, queryLength - cursor);
                bool complete = DeviceIoControl(file, 0x000940CF, input, 16, output, 65536, out uint returned, IntPtr.Zero);
                int error = complete ? 0 : Marshal.GetLastWin32Error();
                if ((!complete && error != 234) || returned > 65536 || (returned & 15) != 0) throw new IOException("Sparse allocated-range query failed or returned an incomplete record (Win32 " + error + ").");
                long previous = cursor;
                for (int index = 0; index < returned; index += 16) {
                    long start = Marshal.ReadInt64(output, index), length = Marshal.ReadInt64(output, index + 8);
                    if (start < previous || length <= 0 || start > queryLength || length > queryLength - start || ranges.Count >= 4096) throw new IOException("Sparse allocated ranges are overlapping, unbounded or malformed.");
                    total = checked(total + (ulong)length); if (total > maximum) throw new IOException("Sparse allocated ranges exceed the bounded verification budget.");
                    ranges.Add(new AllocatedRange { Offset = start, Length = length }); previous = checked(start + length);
                }
                if (complete) return ranges.ToArray();
                if (returned == 0 || previous <= cursor || previous >= queryLength) throw new IOException("Sparse allocated-range pagination did not make bounded progress.");
                cursor = previous;
            }
            throw new IOException("Sparse allocated-range query did not certify completion.");
        } finally { Marshal.FreeHGlobal(input); Marshal.FreeHGlobal(output); }
    }
    static void CheckPrefix(FileStream stream, byte[] prefix) {
        stream.Position = 0; var actual = new byte[prefix.Length]; stream.ReadExactly(actual);
        if (!actual.AsSpan().SequenceEqual(prefix)) throw new IOException("Sparse ordinary-stream prefix differs from its recorded bytes.");
    }
    public static SparseFinalizationResult RestoreTiny(string path, string expectedId, string expectedSecurityBase64, int expectedAttributes, long expectedLogicalLength, byte[] prefix, ulong maximumAllocation) {
        var result = new SparseFinalizationResult { Path = path, ExpectedLogicalLength = expectedLogicalLength, PrefixBase64 = prefix == null ? null : Convert.ToBase64String(prefix) };
        List<SafeFileHandle> parents = null;
        try {
            if (!System.IO.Path.IsPathFullyQualified(path) || prefix == null || prefix.Length == 0 || expectedLogicalLength < prefix.Length || maximumAllocation == 0 || maximumAllocation > 1048576 || string.IsNullOrEmpty(expectedId) || string.IsNullOrEmpty(expectedSecurityBase64)) throw new IOException("Sparse finalization requires complete original evidence and a bounded allocation budget.");
            path = System.IO.Path.GetFullPath(path); result.Path = path; parents = PinParents(path);
            using (var handle = OpenExclusive(path, true))
            using (var stream = new FileStream(handle, FileAccess.ReadWrite, 1, false)) {
                result.Before = ReadProof(handle, path);
                result.AlreadyTiny = result.Before.Length == prefix.Length;
                MatchProof(result.Before, expectedId, expectedSecurityBase64, expectedAttributes, result.AlreadyTiny ? prefix.Length : expectedLogicalLength, maximumAllocation);
                CheckPrefix(stream, prefix);
                result.AllocatedRangesBefore = QueryRanges(handle, expectedLogicalLength, maximumAllocation);
                var buffer = new byte[65536];
                foreach (var range in result.AllocatedRangesBefore) {
                    long position = Math.Max(range.Offset, prefix.Length), end = Math.Min(checked(range.Offset + range.Length), result.Before.Length);
                    stream.Position = position;
                    while (position < end) {
                        int length = (int)Math.Min(buffer.Length, end - position); stream.ReadExactly(buffer.AsSpan(0, length)); result.BytesChecked = checked(result.BytesChecked + length);
                        if ((ulong)result.BytesChecked > maximumAllocation) throw new IOException("Sparse tail verification exceeded its allocation budget.");
                        for (int index = 0; index < length; index++) if (buffer[index] != 0) throw new IOException("Unknown nonzero sparse tail at offset " + (position + index) + "; the file was retained.");
                        position += length;
                    }
                }
                result.TailWasZero = true;
                // 割当範囲を読み終えるまではサイズを変えない。同じexclusive handleで直前証拠も再照合する。
                MatchProof(ReadProof(handle, path), expectedId, expectedSecurityBase64, expectedAttributes, result.Before.Length, maximumAllocation); CheckPrefix(stream, prefix);
                if (!result.AlreadyTiny) { result.MutationStarted = true; stream.SetLength(prefix.Length); stream.Flush(true); }
                result.After = ReadProof(handle, path); MatchProof(result.After, expectedId, expectedSecurityBase64, expectedAttributes, prefix.Length, maximumAllocation); CheckPrefix(stream, prefix);
                result.AllocatedRangesAfter = QueryRanges(handle, expectedLogicalLength, maximumAllocation);
            }
            // close後も別のexclusive handleで同一ID/OGD/属性/prefix/長さを再検証する。
            using (var handle = OpenExclusive(path, false))
            using (var stream = new FileStream(handle, FileAccess.Read, 1, false)) { result.PostClose = ReadProof(handle, path); MatchProof(result.PostClose, expectedId, expectedSecurityBase64, expectedAttributes, prefix.Length, maximumAllocation); CheckPrefix(stream, prefix); }
            result.Success = true;
        } catch (Exception error) { result.Error = error.ToString(); }
        finally { if (parents != null) foreach (var parent in parents) parent.Dispose(); }
        return result;
    }
    public static void MakeSparse(SafeFileHandle file) {
        if (!DeviceIoControl(file, 0x000900C4, IntPtr.Zero, 0, IntPtr.Zero, 0, out uint returned, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static ulong Allocation(string path) {
        SetLastError(0);
        uint low = GetCompressedFileSizeW(path, out uint high);
        int error = Marshal.GetLastWin32Error();
        if (low == uint.MaxValue && error != 0) throw new Win32Exception(error);
        return ((ulong)high << 32) | low;
    }
    public static long[] BinTotals(string rootPath) {
        int hr; long count; long bytes;
        if (IntPtr.Size == 8) {
            var info = new SHQUERYRBINFO64 { cbSize = (uint)Marshal.SizeOf<SHQUERYRBINFO64>() };
            if (info.cbSize != 24) throw new InvalidOperationException("x64 SHQUERYRBINFO packing or size changed.");
            hr = SHQueryRecycleBinW(rootPath, ref info); count = info.i64NumItems; bytes = info.i64Size;
        } else if (IntPtr.Size == 4) {
            var info = new SHQUERYRBINFO32 { cbSize = (uint)Marshal.SizeOf<SHQUERYRBINFO32>() };
            if (info.cbSize != 20) throw new InvalidOperationException("x86 SHQUERYRBINFO packing or size changed.");
            hr = SHQueryRecycleBinW(rootPath, ref info); count = info.i64NumItems; bytes = info.i64Size;
        } else throw new PlatformNotSupportedException("Unexpected process pointer width.");
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        if (count < 0 || bytes < 0) throw new InvalidOperationException("SHQueryRecycleBinW returned negative totals.");
        return new long[] { count, bytes };
    }
}
