using System.Reflection;

namespace RouteShield;

internal static class ReleaseNotes
{
    internal static bool IsUpgrade(string? previous, string current)
    {
        // Existing Windows beta installations predate the saved version.
        var installed = Release.Parse(previous ?? "1.0.0-beta.1");
        return installed is { } baseline && Release.Parse(current) is { } version && version.CompareTo(baseline) > 0;
    }

    internal static string Read(string language)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RouteShield.ReleaseNotes.md");
        if (stream is null) return "";
        using var reader = new StreamReader(stream);
        string heading = language == "ru" ? "## Русский" : "## English";
        var lines = new List<string>();
        bool collecting = false;
        while (reader.ReadLine() is { } line)
        {
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                if (collecting) break;
                collecting = line == heading;
            }
            else if (collecting && line.StartsWith("- ", StringComparison.Ordinal))
            {
                lines.Add("• " + line[2..].Replace("`", ""));
            }
        }
        return string.Join(Environment.NewLine + Environment.NewLine, lines);
    }
}
