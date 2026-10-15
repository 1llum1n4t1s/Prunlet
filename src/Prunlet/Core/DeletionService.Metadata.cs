using System.Text.Json;

namespace Prunlet.Core;

public sealed partial class DeletionService
{
    // 総件数や総バイト数では制限しない。各値だけを制限して未完の巨大トークンも拒否する。
    private const int MetadataPathCharacters = 32768;
    private const int MetadataMessageCharacters = 1024 * 1024;

    private static T ReadValidatedJson<T>(FileStream stream)
    {
        var shape = typeof(T) == typeof(OperationManifest) ? MetadataShape.Manifest
            : typeof(T) == typeof(PurgeIntent) ? MetadataShape.Intent
            : typeof(T) == typeof(DeleteResult) ? MetadataShape.DeleteResult
            : typeof(T) == typeof(RestoreResult) ? MetadataShape.RestoreResult
            : typeof(T) == typeof(PurgeResult) ? MetadataShape.PurgeResult
            : throw new InvalidDataException("Unsupported operation metadata type.");
        stream.Position = 0;
        try
        {
            ValidateMetadataJson(stream, shape);
            // 同じ固定済みハンドルを読み直す。全文JSONのDOMやバイト列は保持しない。
            stream.Position = 0;
            return JsonSerializer.Deserialize<T>(stream, PrunletConfig.JsonOptions)
                ?? throw new InvalidDataException("Operation metadata is empty.");
        }
        catch (JsonException ex) { throw new InvalidDataException("Operation metadata JSON is invalid.", ex); }
    }

    private static void ValidateMetadataJson(FileStream stream, MetadataShape rootShape)
    {
        // 以前のストリーム読込と同じく、UTF-8 BOM付きの既存記録も受け入れる。
        if (!(stream.ReadByte() == 0xef && stream.ReadByte() == 0xbb && stream.ReadByte() == 0xbf))
            stream.Position = 0;
        var buffer = new byte[16384];
        var buffered = 0;
        var final = false;
        var state = new JsonReaderState(new JsonReaderOptions { MaxDepth = 16 });
        var frames = new Stack<MetadataFrame>();
        var complete = false;
        int? schema = null;
        var schema2Entries = true;
        var schema3Entries = true;
        while (true)
        {
            if (!final)
            {
                var read = stream.Read(buffer, buffered, buffer.Length - buffered);
                buffered += read;
                final = read == 0;
            }
            var reader = new Utf8JsonReader(buffer.AsSpan(0, buffered), final, state);
            while (reader.Read())
            {
                if (complete) throw new InvalidDataException("Operation metadata contains more than one value.");
                if (reader.TokenType == JsonTokenType.PropertyName)
                {
                    if (frames.Count == 0 || IsMetadataArray(frames.Peek().Shape))
                        throw new InvalidDataException("Operation metadata property is misplaced.");
                    var frame = frames.Peek();
                    ValidateMetadataString(ref reader, 128);
                    var name = reader.GetString()!;
                    if (!frame.Properties.Add(name)) throw new InvalidDataException("Operation metadata has duplicated properties.");
                    frame.PendingName = name;
                    frame.Pending = MetadataProperty(frame.Shape, name);
                    continue;
                }
                if (reader.TokenType is JsonTokenType.EndObject or JsonTokenType.EndArray)
                {
                    if (frames.Count == 0) throw new InvalidDataException("Operation metadata container is invalid.");
                    var frame = frames.Pop();
                    if (IsMetadataArray(frame.Shape) != (reader.TokenType == JsonTokenType.EndArray))
                        throw new InvalidDataException("Operation metadata container is invalid.");
                    ValidateMetadataRequired(frame);
                    if (frame.Shape == MetadataShape.Targets && frames.Count != 0
                        && frames.Peek().PendingName == "incompleteTargets")
                        frames.Peek().HasIncompleteTargets = frame.Count != 0;
                    if (frame.Shape == MetadataShape.Entry)
                    {
                        schema2Entries &= HasMetadataFields(frame, ["kind", "treeRoot"]);
                        schema3Entries &= HasMetadataFields(frame,
                            ["kind", "treeRoot", "caseSensitive", "reparseTag", "linkDirectory", "streams", "size", "sha256"]);
                    }
                    if (frames.Count == 0)
                    {
                        if (rootShape == MetadataShape.Manifest
                            && ((schema == 2 && !schema2Entries) || (schema == 3 && !schema3Entries)))
                            throw new InvalidDataException("Operation metadata is missing required entry fields.");
                        if (rootShape == MetadataShape.Intent && schema == 2
                            && (!HasMetadataFields(frame, ["incompleteTargets"]) || !frame.HasIncompleteTargets))
                            throw new InvalidDataException("Incomplete purge targets must be a nonempty array.");
                        complete = true;
                    }
                    continue;
                }
                var value = frames.Count == 0
                    ? new MetadataValue(rootShape)
                    : MetadataNextValue(frames.Peek());
                if (reader.TokenType == JsonTokenType.Null)
                {
                    if (!value.Nullable) throw new InvalidDataException("Operation metadata value cannot be null.");
                }
                else if (value.Shape != MetadataShape.Scalar)
                {
                    var expected = IsMetadataArray(value.Shape) ? JsonTokenType.StartArray : JsonTokenType.StartObject;
                    if (reader.TokenType != expected) throw new InvalidDataException("Operation metadata value has an invalid shape.");
                    frames.Push(new MetadataFrame(value.Shape));
                    continue;
                }
                else
                {
                    if (reader.TokenType != value.Token && !(value.Token == JsonTokenType.True && reader.TokenType == JsonTokenType.False))
                        throw new InvalidDataException("Operation metadata value has an invalid type.");
                    if (value.Token == JsonTokenType.String) ValidateMetadataString(ref reader, value.Characters);
                    else if (reader.ValueSpan.Length > 64) throw new InvalidDataException("Operation metadata number is too long.");
                    if (frames.Count == 1 && frames.Peek().PendingName == "schema")
                    {
                        if (!reader.TryGetInt32(out var valueSchema)) throw new InvalidDataException("Operation metadata schema is invalid.");
                        schema = valueSchema;
                    }
                }
            }
            var consumed = checked((int)reader.BytesConsumed);
            state = reader.CurrentState;
            buffer.AsSpan(consumed, buffered - consumed).CopyTo(buffer);
            buffered -= consumed;
            if (final)
            {
                if (!complete || buffered != 0) throw new InvalidDataException("Operation metadata JSON is incomplete.");
                return;
            }
            var limit = MetadataPendingTokenLimit(frames);
            if (buffered > limit) throw new InvalidDataException("Operation metadata token is too long.");
            if (buffered == buffer.Length)
            {
                if (buffer.Length > limit) throw new InvalidDataException("Operation metadata token is too long.");
                Array.Resize(ref buffer, Math.Min(checked(buffer.Length * 2), limit + 1));
            }
        }
    }

    private static MetadataValue MetadataNextValue(MetadataFrame frame)
    {
        if (IsMetadataArray(frame.Shape))
        {
            frame.Count++;
            return frame.Shape switch
            {
                MetadataShape.Entries => new(MetadataShape.Entry),
                MetadataShape.Targets => new(MetadataShape.Target),
                MetadataShape.Streams => new(MetadataShape.Stream),
                MetadataShape.Results => new(MetadataShape.Result),
                MetadataShape.Warnings => MetadataText(MetadataMessageCharacters),
                _ => throw new InvalidDataException("Unsupported metadata array.")
            };
        }
        var result = frame.Pending ?? throw new InvalidDataException("Operation metadata value has no property.");
        frame.Pending = null;
        return result;
    }

    private static int MetadataPendingTokenLimit(Stack<MetadataFrame> frames)
    {
        if (frames.Count == 0) return 64;
        var frame = frames.Peek();
        if (!IsMetadataArray(frame.Shape) && frame.Pending is null) return 128 * 6 + 2;
        var value = IsMetadataArray(frame.Shape)
            ? frame.Shape == MetadataShape.Warnings ? MetadataText(MetadataMessageCharacters) : new MetadataValue(MetadataShape.Entry)
            : frame.Pending!.Value;
        return value.Shape != MetadataShape.Scalar ? 64 : value.Token == JsonTokenType.String ? value.Characters * 6 + 2 : 64;
    }

    private static void ValidateMetadataString(ref Utf8JsonReader reader, int characters)
    {
        if (reader.ValueSpan.Length > characters * 6 || reader.GetString()!.Length > characters)
            throw new InvalidDataException("Operation metadata string is too long.");
    }

    private static MetadataValue MetadataProperty(MetadataShape shape, string property)
    {
        var name = property.ToLowerInvariant();
        if (shape is MetadataShape.Manifest or MetadataShape.Intent or MetadataShape.DeleteResult or MetadataShape.RestoreResult or MetadataShape.PurgeResult)
        {
            if (name == "operationid") return MetadataText(64, shape == MetadataShape.DeleteResult);
            if (name == "items" && shape != MetadataShape.Intent) return new(shape == MetadataShape.Manifest ? MetadataShape.Entries : MetadataShape.Results);
            if (name == "warnings" && shape is MetadataShape.DeleteResult or MetadataShape.RestoreResult or MetadataShape.PurgeResult) return new(MetadataShape.Warnings);
            if (name == "dryrun" && shape is MetadataShape.DeleteResult or MetadataShape.PurgeResult) return MetadataBoolean();
            if (name == "purgedbytes" && shape == MetadataShape.PurgeResult) return MetadataNumber();
            if (shape is MetadataShape.Manifest or MetadataShape.Intent)
            {
                if (name == "schema") return MetadataNumber();
                if (name == "createdutc") return MetadataText(128);
                if (shape == MetadataShape.Intent)
                {
                    if (name == "manifestsha256") return MetadataText(64);
                    if (name is "targets" or "incompletetargets") return new(MetadataShape.Targets);
                }
            }
        }
        else if (shape is MetadataShape.Entry or MetadataShape.Result)
        {
            if (name == "path" || (name == "backuppath" && shape == MetadataShape.Result))
                return MetadataText(MetadataPathCharacters, name == "backuppath");
            if (name == "kind" || (name == "state" && shape == MetadataShape.Entry) || (name == "status" && shape == MetadataShape.Result))
                return MetadataText(256);
            if (name == "sha256") return MetadataText(64, true);
            if (name == "size") return MetadataNumber(true);
            if (shape == MetadataShape.Result && name == "error") return MetadataText(MetadataMessageCharacters, true);
            if (shape == MetadataShape.Entry)
            {
                if (name == "treeroot") return MetadataText(MetadataPathCharacters, true);
                if (name == "lastwriteutc") return MetadataText(128, true);
                if (name is "casesensitive" or "linkdirectory") return MetadataBoolean();
                if (name == "reparsetag") return MetadataNumber(true);
                if (name == "streams") return new(MetadataShape.Streams, Nullable: true);
            }
        }
        else if (shape is MetadataShape.Target or MetadataShape.Stream)
        {
            if (name == "sha256") return MetadataText(64);
            if (name == "size" || (name == "index" && shape == MetadataShape.Target) || (name == "offset" && shape == MetadataShape.Stream)) return MetadataNumber();
            if (name == "name" && shape == MetadataShape.Stream) return MetadataText(MetadataPathCharacters);
        }
        throw new InvalidDataException("Unknown operation metadata property.");
    }

    private static void ValidateMetadataRequired(MetadataFrame frame)
    {
        string[] fields = frame.Shape switch
        {
            MetadataShape.Manifest => ["schema", "operationId", "createdUtc", "items"],
            MetadataShape.Intent => ["schema", "operationId", "manifestSha256", "createdUtc", "targets"],
            MetadataShape.DeleteResult => ["operationId", "dryRun", "items", "warnings"],
            MetadataShape.RestoreResult => ["operationId", "items", "warnings"],
            MetadataShape.PurgeResult => ["operationId", "dryRun", "purgedBytes", "items", "warnings"],
            MetadataShape.Entry => ["path", "state"],
            MetadataShape.Target => ["index", "sha256", "size"],
            MetadataShape.Stream => ["name", "offset", "size", "sha256"],
            _ => []
        };
        if (!HasMetadataFields(frame, fields)) throw new InvalidDataException("Operation metadata is missing required fields.");
    }

    private static bool HasMetadataFields(MetadataFrame frame, string[] fields) =>
        fields.All(field => frame.Properties.Any(property => property.Equals(field, StringComparison.Ordinal)));

    private static bool IsMetadataArray(MetadataShape shape) =>
        shape is MetadataShape.Entries or MetadataShape.Targets or MetadataShape.Streams or MetadataShape.Results or MetadataShape.Warnings;

    private static MetadataValue MetadataText(int characters, bool nullable = false) => new(MetadataShape.Scalar, JsonTokenType.String, characters, nullable);
    private static MetadataValue MetadataNumber(bool nullable = false) => new(MetadataShape.Scalar, JsonTokenType.Number, Nullable: nullable);
    private static MetadataValue MetadataBoolean() => new(MetadataShape.Scalar, JsonTokenType.True);

    private enum MetadataShape { Scalar, Manifest, Intent, DeleteResult, RestoreResult, PurgeResult, Entry, Target, Stream, Result, Entries, Targets, Streams, Results, Warnings }
    private readonly record struct MetadataValue(MetadataShape Shape, JsonTokenType Token = JsonTokenType.None, int Characters = 0, bool Nullable = false);
    private sealed class MetadataFrame(MetadataShape shape)
    {
        public MetadataShape Shape { get; } = shape;
        public HashSet<string> Properties { get; } = new(StringComparer.OrdinalIgnoreCase);
        public MetadataValue? Pending { get; set; }
        public string? PendingName { get; set; }
        public long Count { get; set; }
        public bool HasIncompleteTargets { get; set; }
    }
}
