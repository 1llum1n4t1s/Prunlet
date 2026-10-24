using Microsoft.Win32.SafeHandles;
using System.Security.AccessControl;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    private const int MaximumRecycleSecurityNodes = 65536;

    // 名前はordinalな相対パス。reparse自身を記録し、その配下やリンク先を列挙しない。
    private static Dictionary<string, RecycleSecurityNode> CaptureRecycleSecurity(string root, bool writable, bool rootHasDeleteHandle = false)
    {
        var nodes = new Dictionary<string, RecycleSecurityNode>(StringComparer.Ordinal);
        using var parents = PathPolicy.PinDirectories(Path.GetDirectoryName(root)!);
        using var directories = new DirectoryLease();
        var pending = new Stack<string>();
        pending.Push(string.Empty);
        while (pending.TryPop(out var relative))
        {
            if (nodes.Count >= MaximumRecycleSecurityNodes) throw new IOException("Recycle ACL snapshot contains too many objects.");
            var path = RecycleSecurityPath(root, relative);
            using var handle = NativeFiles.OpenRecycleSecurity(path, writable);
            var identity = NativeFiles.MoveIdentity(handle);
            VerifyMoveHandle(handle, path, identity);
            var descriptor = NativeFiles.ReadRecycleSecurity(handle);
            NativeFiles.ValidateRecycleSecurity(descriptor);
            nodes.Add(relative, new RecycleSecurityNode { Identity = identity, Descriptor = descriptor });
            if (identity.IsDirectory && identity.ReparseTag == 0)
            {
                // 親から順に通常directoryを固定し、列挙後の中間reparse差替えを拒否する。
                // stage rootは呼出元がDELETEハンドルを保持しているため、非共有pinと併用しない。
                if (relative.Length != 0 || !rootHasDeleteHandle)
                {
                    var pin = NativeFiles.OpenDirectory(path);
                    directories.Handles.Add(pin);
                    NativeFiles.Verify(pin, path, directory: true);
                    VerifyMoveHandle(pin, path, identity);
                }
                var children = Directory.GetFileSystemEntries(path);
                Array.Sort(children, StringComparer.Ordinal);
                foreach (var child in children.Reverse()) pending.Push(relative + "\\" + Path.GetFileName(child));
            }
            VerifyMoveHandle(handle, path, identity);
        }
        ValidateRecycleSecurity(nodes, nodes[string.Empty].Identity!);
        return nodes;
    }

    private static string RecycleSecurityPath(string root, string relative) => relative.Length == 0 ? root : root + relative;

    private static void ValidateRecycleSecurity(Dictionary<string, RecycleSecurityNode> nodes, MoveEntryIdentity root)
    {
        if (nodes.Count is 0 or > MaximumRecycleSecurityNodes || !nodes.TryGetValue(string.Empty, out var rootNode)
            || rootNode is null || !ValidMoveIdentity(rootNode.Identity) || !SameMoveObject(root, rootNode.Identity!))
            throw new InvalidDataException("Recycle ACL snapshot has no matching root.");
        var identities = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var (relative, node) in nodes)
        {
            if (node is null || !ValidMoveIdentity(node.Identity) || node.Identity!.VolumeSerialNumber != root.VolumeSerialNumber
                || node.Descriptor is null || node.Descriptor.Length is 0 or > 1024 * 1024)
                throw new InvalidDataException("Recycle ACL snapshot identity or descriptor is invalid.");
            NativeFiles.ValidateRecycleSecurity(node.Descriptor);
            if (relative.Length != 0)
            {
                if (relative[0] != '\\' || relative.Length > 32767 || relative.Contains('/') || relative.Contains(':')
                    || relative.Contains('\0') || relative.Split('\\').Skip(1).Any(part => part.Length == 0 || part is "." or ".."))
                    throw new InvalidDataException("Recycle ACL snapshot contains an unsafe relative path.");
                var parent = relative[..relative.LastIndexOf('\\')];
                if (!nodes.TryGetValue(parent, out var ancestor) || ancestor?.Identity is not { IsDirectory: true, ReparseTag: 0 })
                    throw new InvalidDataException("Recycle ACL snapshot has a missing or reparse parent.");
            }
            var id = node.Identity.VolumeSerialNumber + ":" + node.Identity.FileId;
            if (identities.TryGetValue(id, out var descriptor) && !descriptor.AsSpan().SequenceEqual(node.Descriptor))
                throw new InvalidDataException("Hardlink aliases have inconsistent ACL snapshots.");
            identities[id] = node.Descriptor;
        }
    }

    private static void RequireRecycleSecurityBindings(Dictionary<string, RecycleSecurityNode> original,
        Dictionary<string, RecycleSecurityNode> recycled)
    {
        if (original.Count != recycled.Count) throw new InvalidDataException("Recycle ACL receipt has a different tree membership.");
        foreach (var (relative, node) in original)
            if (!recycled.TryGetValue(relative, out var current) || !SameMoveObject(node.Identity!, current.Identity!))
                throw new InvalidDataException("Recycle ACL receipt has a different tree identity.");
    }

    private static void RequireRecycleSecurity(string path, Dictionary<string, RecycleSecurityNode> expected,
        bool compareSecurity = true, bool writable = false, bool exactAttributes = false, bool rootHasDeleteHandle = false)
    {
        var actual = CaptureRecycleSecurity(path, writable, rootHasDeleteHandle);
        if (actual.Count != expected.Count) throw new IOException("The recycle tree membership changed; objects were retained.");
        foreach (var (relative, node) in expected)
        {
            if (!actual.TryGetValue(relative, out var current) || !SameMoveObject(node.Identity!, current.Identity!)
                || node.Identity!.ReparseTag != current.Identity!.ReparseTag || node.Identity.IsDirectory != current.Identity.IsDirectory
                || compareSecurity && !node.Descriptor.AsSpan().SequenceEqual(current.Descriptor)
                || exactAttributes && NormalizeMoveAttributes(node.Identity.Attributes) != NormalizeMoveAttributes(current.Identity.Attributes))
                throw new IOException("The recycle tree identity, ACL or attributes changed at '" + relative + "'; objects were retained.");
        }
    }

    private static void RestoreRecycleSecurity(string path, Dictionary<string, RecycleSecurityNode> expected)
    {
        RequireRecycleSecurity(path, expected, compareSecurity: false, rootHasDeleteHandle: true);
        var held = new List<(string Relative, SafeFileHandle Handle, RecycleSecurityNode Node)>();
        try
        {
            // 全WRITE_DACハンドルの取得と照合が済むまで、一つもACLを書き換えない。
            foreach (var (relative, node) in expected.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                var handle = NativeFiles.OpenRecycleSecurity(RecycleSecurityPath(path, relative), writable: true);
                held.Add((relative, handle, node));
                VerifyMoveHandle(handle, RecycleSecurityPath(path, relative), node.Identity!);
                var currentSecurity = new RawSecurityDescriptor(NativeFiles.ReadRecycleSecurity(handle), 0);
                var originalSecurity = new RawSecurityDescriptor(node.Descriptor, 0);
                if (!Equals(currentSecurity.Owner, originalSecurity.Owner) || !Equals(currentSecurity.Group, originalSecurity.Group))
                    throw new IOException("A stage object's owner/group differs; no ACL was restored.");
            }
            RequireRecycleSecurity(path, expected, compareSecurity: false, rootHasDeleteHandle: true);
            foreach (var (_, handle, node) in held) NativeFiles.RestoreRecycleDacl(handle, node.Descriptor);
            foreach (var (relative, handle, node) in held)
            {
                VerifyMoveHandle(handle, RecycleSecurityPath(path, relative), node.Identity!);
                if (!NativeFiles.ReadRecycleSecurity(handle).AsSpan().SequenceEqual(node.Descriptor))
                    throw new IOException("The restored ACL does not exactly match its snapshot; stage was retained.");
            }
        }
        finally { foreach (var (_, handle, _) in held) handle.Dispose(); }
        foreach (var (relative, node) in expected) FinishRecycleAttributes(RecycleSecurityPath(path, relative), node.Identity!);
        RequireRecycleSecurity(path, expected, exactAttributes: true, rootHasDeleteHandle: true);
    }
}
