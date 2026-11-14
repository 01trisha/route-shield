using System.Text.Json;

namespace RouteShield;

internal enum NotificationDetails { Address, Country, Both }

internal sealed record TrackedApp(Guid Id, string Name, string Path, string Arguments, string WorkingDirectory, string IconPath, int IconIndex);

internal sealed class Preferences
{
    internal static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Route Shield");
    internal static string FilePath => Path.Combine(Folder, "settings.json");

    public bool WelcomeCompleted { get; set; }
    public string Language { get; set; } = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru" ? "ru" : "en";
    public bool ShowIPv4 { get; set; } = true;
    public bool ShowIPv6 { get; set; } = true;
    public bool ShowCountry { get; set; } = true;
    public bool Notify { get; set; }
    public bool ForceClose { get; set; }
    public NotificationDetails Details { get; set; }
    public DateTimeOffset LastUpdateCheck { get; set; }
    public string? LastNotifiedTag { get; set; }
    public List<TrackedApp> Apps { get; set; } = [];

    internal static Preferences Load()
    {
        if (!File.Exists(FilePath)) return new();
        var settings = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath))
            ?? throw new JsonException("Missing settings object.");
        if (settings.Apps is null || settings.Apps.Any(app => app is null || string.IsNullOrWhiteSpace(app.Path)))
            throw new JsonException("Invalid application list.");
        if (!Enum.IsDefined(settings.Details)) settings.Details = NotificationDetails.Address;
        return settings;
    }

    internal void Save()
    {
        Directory.CreateDirectory(Folder);
        string pending = FilePath + ".tmp";
        File.WriteAllText(pending, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(pending, FilePath, overwrite: true);
    }

    internal string T(string english, string russian) => Language == "ru" ? russian : english;
}
