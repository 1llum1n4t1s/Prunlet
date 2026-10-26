using System.Text.Json;
using System.Text.RegularExpressions;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    internal static event Action<string, string>? RegistryControlCheckpoint;

    // 呼出元が同じrecordの全証拠から再構成した3種のcontrol専用。snapshot等へ一般化しない。
    private static void PublishRegistryControl<T>(string path, T value, string id, string kind)
    {
        ValidateMoveOperationId(id);
        var suffix = kind switch { "migration" => ".registry-migration.json", "terminal" => ".terminal.json",
            "terminal-cleanup" => ".terminal-cleanup.json", _ => throw new ArgumentException("Unknown registry control kind.") };
        if (Path.GetFileName(path) != id + suffix) throw new InvalidDataException("Registry control name differs from its type.");
        using var parents = PathPolicy.PinRecoveryDirectories(Path.GetDirectoryName(path)!);
        var pending = path + ".pending";
        if (InspectMoveLocation(path) is not null) throw new InvalidDataException("Registry control final already exists; pending was retained.");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, MoveJsonOptions);
        if (bytes.Length is <= 0 or > 16 * 1024 * 1024) throw new InvalidDataException("Registry control size is invalid.");
        using var handle = InspectMoveLocation(pending) is null ? NativeFiles.CreatePrivateRegistryFile(pending) : NativeFiles.OpenLifecyclePendingPublisher(pending);
        NativeFiles.Verify(handle, pending); NativeFiles.VerifyPrivateRegistrySecurity(handle); NativeFiles.VerifySingleLink(handle); NativeFiles.RejectNamedStreams(pending);
        using var stream = new FileStream(handle, FileAccess.ReadWrite);
        if (stream.Length > bytes.Length) throw new InvalidDataException("Registry control pending exceeds the freshly reconstructed body.");
        var prefix = new byte[checked((int)stream.Length)]; stream.Position = 0; stream.ReadExactly(prefix);
        if (!prefix.AsSpan().SequenceEqual(bytes.AsSpan(0, prefix.Length)))
            throw new InvalidDataException("Registry control pending differs from the fresh record proof; it was retained.");
        RegistryControlCheckpoint?.Invoke(kind + ".pending", id);
        var split = Math.Max(prefix.Length, bytes.Length / 2);
        stream.Position = prefix.Length; stream.Write(bytes.AsSpan(prefix.Length, split - prefix.Length)); stream.Flush(true);
        RegistryControlCheckpoint?.Invoke(kind + ".prefix", id);
        stream.Write(bytes.AsSpan(split)); stream.Flush(true);
        _ = ReadLifecycleJson<T>(stream);
        RegistryControlCheckpoint?.Invoke(kind + ".flushed", id);
        NativeFiles.RenameHandle(handle, path); NativeFiles.Verify(handle, path); stream.Flush(true);
        RegistryControlCheckpoint?.Invoke(kind + ".published", id);
    }

    private bool ReconcileRegistryControlPending(string root, bool apply, List<string> warnings)
    {
        var ready = true;
        foreach (var path in Directory.EnumerateFiles(root, "*.pending").ToArray())
        {
            var match = Regex.Match(Path.GetFileName(path), "^([0-9a-f]{32})\\.(terminal|terminal-cleanup)\\.json\\.pending$", RegexOptions.CultureInvariant);
            if (!match.Success) continue;
            var id = match.Groups[1].Value;
            if (apply)
            {
                if (match.Groups[2].Value == "terminal") CaptureRegistryTerminal(id, warnings);
                else ExpireRegistryTerminal(root, id, warnings);
            }
            if (InspectMoveLocation(path) is not null)
            {
                ready = false;
                warnings.Add($"Registry control pending for {id} was retained; explicit migration or maintenance must reconcile its fresh record proof.");
            }
        }
        return ready;
    }
}
