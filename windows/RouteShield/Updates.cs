using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RouteShield;

internal sealed record Release(string Tag, string Page, Version Version, int Beta)
{
    internal string DisplayVersion => Tag["windows-v".Length..];

    internal static Release? Available(string? tag)
    {
        if (tag is null || !tag.StartsWith("windows-v", StringComparison.Ordinal) ||
            Parse(tag) is not { } version || version.CompareTo(Parse(Updates.Current)!.Value) <= 0) return null;
        return new(tag, Program.Repo + "/releases/tag/" + tag, version.Version, version.Beta);
    }

    internal static (Version Version, int Beta)? Parse(string value)
    {
        var match = Regex.Match(value, @"\A(?:windows-v)?(\d+\.\d+\.\d+)(?:-beta\.(\d+))?\z");
        if (!match.Success || !Version.TryParse(match.Groups[1].Value, out var version)) return null;
        if (!match.Groups[2].Success) return (version, int.MaxValue);
        return int.TryParse(match.Groups[2].Value, out int beta) ? (version, beta) : null;
    }
}

internal sealed class Updates : IDisposable
{
    internal static string Current => typeof(Updates).Assembly
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];

    private readonly HttpClient client = new() { Timeout = TimeSpan.FromSeconds(8) };

    internal Updates() => client.DefaultRequestHeaders.UserAgent.ParseAdd("RouteShield-Windows/" + Current);

    internal async Task<Release?> Check(CancellationToken token)
    {
        for (int page = 1; ; page++)
        {
            var releases = await client.GetFromJsonAsync<JsonElement>(
                $"https://api.github.com/repos/01trisha/route-shield/releases?per_page=30&page={page}", token);
            List<Release> compatible = [];
            foreach (var entry in releases.EnumerateArray())
            {
                string? tag = entry.GetProperty("tag_name").GetString();
                if (entry.GetProperty("draft").GetBoolean() || Release.Available(tag) is not { } release) continue;
                if (!entry.GetProperty("assets").EnumerateArray().Any(asset =>
                    asset.GetProperty("name").GetString() is { } name &&
                    (name.EndsWith("-Windows-x64.zip", StringComparison.OrdinalIgnoreCase) ||
                     name.EndsWith("-Windows-x64-Setup.exe", StringComparison.OrdinalIgnoreCase)))) continue;
                compatible.Add(release);
            }
            var newest = compatible.OrderByDescending(release => release.Version).ThenByDescending(release => release.Beta).FirstOrDefault();
            if (newest is not null || releases.GetArrayLength() < 30) return newest;
        }
    }

    public void Dispose() => client.Dispose();
}
