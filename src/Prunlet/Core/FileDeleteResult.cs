namespace Prunlet.Core;

public sealed class FileDeleteResult
{
    public bool DryRun { get; set; }
    public List<FileDeleteItem> Items { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed class FileDeleteItem
{
    public string Path { get; set; } = "";
    public string Kind { get; set; } = "file";
    public string Status { get; set; } = "";
    public string? Error { get; set; }
}
