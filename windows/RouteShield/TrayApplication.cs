using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Timer = System.Windows.Forms.Timer;

namespace RouteShield;

internal sealed class TrayApplication : ApplicationContext
{
    private readonly Preferences settings;
    private readonly Connection connection = new();
    private readonly Updates updates = new();
    private readonly CancellationTokenSource shutdown = new();
    private readonly NotifyIcon icon;
    private readonly Icon artwork;
    private readonly ContextMenuStrip menu = new() { ShowImageMargin = true };
    private readonly Timer updateTimer = new() { Interval = 60000 };
    private readonly Timer alertTimer = new() { Interval = 10000 };
    private readonly Queue<(string Title, string Body)> alerts = new();
    private readonly Monitor monitor;
    private readonly Dictionary<Guid, Bitmap> menuImages = [];
    private readonly Dictionary<string, string[]> countryNames;
    private Form? dialog;
    private Addresses? addresses;
    private (string? IPv4, string? IPv6) codes;
    private Release? newer;
    private bool checkingUpdates, alertActive, refreshing;
    private int connectionRevision;

    internal TrayApplication(Preferences settings, SynchronizationContext ui)
    {
        this.settings = settings;
        using var countryData = Assembly.GetExecutingAssembly().GetManifestResourceStream("RouteShield.CountryNames.json")!;
        countryNames = JsonSerializer.Deserialize<Dictionary<string, string[]>>(countryData)!;
        artwork = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? (Icon)SystemIcons.Application.Clone();
        icon = new NotifyIcon { Icon = artwork, Text = "Route Shield", Visible = true, ContextMenuStrip = menu };
        icon.MouseClick += (_, args) =>
        {
            if (args.Button == MouseButtons.Left) ShowMenu(Cursor.Position);
        };
        icon.BalloonTipClosed += (_, _) => AdvanceAlert();
        icon.BalloonTipClicked += (_, _) => AdvanceAlert();
        alertTimer.Tick += (_, _) => AdvanceAlert();
        menu.Opening += (_, _) => { if (dialog is null) _ = Refresh(); };
        monitor = new(connection, settings, ui);
        monitor.Refreshed += samples => _ = SetConnection(samples);
        monitor.Changed += NotifyChange;
        updateTimer.Tick += (_, _) => _ = CheckUpdates(manual: false);
        RenderMenu();
    }

    internal void Initialize(string command)
    {
        updateTimer.Start();
        // Start after the WinForms message loop is running.
        SynchronizationContext.Current!.Post(_ => HandleCommand(command), null);
    }

    internal void HandleCommand(string command)
    {
        if (dialog is not null) { dialog.Activate(); return; }
        if (!settings.WelcomeCompleted)
        {
            using var welcome = new WelcomeWindow(settings, artwork);
            if (Show(welcome) != DialogResult.OK) { ExitThread(); return; }
            var previous = (settings.Language, settings.Notify, settings.Details, settings.ForceClose, settings.ClosingMode);
            (settings.Language, settings.Notify, settings.Details, settings.ForceClose, settings.ClosingMode) = welcome.Choice;
            settings.WelcomeCompleted = true;
            if (!Save())
            {
                (settings.Language, settings.Notify, settings.Details, settings.ForceClose, settings.ClosingMode) = previous;
                settings.WelcomeCompleted = false;
                ExitThread();
                return;
            }
            RenderMenu();
        }
        monitor.Apply();
        _ = CheckUpdates(manual: false);
        if (Guid.TryParse(command, out Guid id))
        {
            var app = settings.Apps.Find(entry => entry.Id == id);
            if (app is null) Error(T("This shortcut refers to an app that was removed.", "Приложение этого ярлыка удалено из списка."));
            else OpenApp(app);
        }
        else if (command == "show") ShowMenu(TrayPosition());
    }

    private Point TrayPosition()
    {
        // Locate the tray after first run without depending on the last pointer position.
        var screen = Screen.PrimaryScreen!;
        Rectangle work = screen.WorkingArea, bounds = screen.Bounds;
        if (work.Bottom < bounds.Bottom) return new(work.Right - 12, work.Bottom - 4);
        if (work.Top > bounds.Top) return new(work.Right - 12, work.Top + 4);
        if (work.Right < bounds.Right) return new(work.Right - 4, work.Bottom - 12);
        if (work.Left > bounds.Left) return new(work.Left + 4, work.Bottom - 12);
        return new(work.Right - 12, work.Bottom - 12);
    }

    private void ShowMenu(Point point)
    {
        if (dialog is not null) { dialog.Activate(); return; }
        if (menu.Visible) { menu.Close(); return; }
        Rectangle work = Screen.FromPoint(point).WorkingArea;
        menu.Show(point, point.Y > work.Top + work.Height / 2
            ? ToolStripDropDownDirection.AboveLeft : ToolStripDropDownDirection.BelowLeft);
    }

    private void RenderMenu()
    {
        var oldItems = menu.Items.Cast<ToolStripItem>().ToArray();
        menu.Items.Clear();
        foreach (var item in oldItems) item.Dispose();
        if (settings.ShowIPv4 || settings.ShowIPv6 || settings.ShowCountry)
        {
            string details = addresses is null
                ? T("Checking connection…", "Проверка соединения…")
                : Format(addresses, codes, settings.ShowIPv4, settings.ShowIPv6, settings.ShowCountry);
            foreach (string line in details.Split('\n')) menu.Items.Add(new ToolStripMenuItem(line) { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
        }
        foreach (var app in settings.Apps)
        {
            var item = Item(app.Name, () => OpenApp(app));
            item.Image = menuImages.GetValueOrDefault(app.Id) ?? (menuImages[app.Id] = AppBitmap(app));
        }
        Item(T("Add Apps…", "Добавить приложения…"), ShowApps);
        if (settings.Apps.Count > 0)
            Item(T("Create Desktop Shortcuts", "Создать ярлыки на рабочем столе"), CreateShortcuts);
        menu.Items.Add(new ToolStripSeparator());
        if (newer is { } release)
            Item(T($"Update available · {release.Version}", $"Доступно обновление · {release.Version}"), () => OpenUrl(release.Page));
        Item(T("Settings…", "Настройки…"), ShowSettings);
        Item(T("Quit Route Shield", "Выйти из Route Shield"), ExitThread);
        icon.Text = newer is null ? "Route Shield" : "Route Shield • " + T("Update available", "Доступно обновление");
    }

    private static Bitmap AppBitmap(TrackedApp app)
    {
        using var image = WindowsApps.IconFor(app);
        return image.ToBitmap();
    }

    private ToolStripMenuItem Item(string title, Action action)
    {
        var item = new ToolStripMenuItem(title) { Text = title.Replace("&", "&&") };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
        return item;
    }

    private async Task Refresh()
    {
        if (refreshing) return;
        refreshing = true;
        int revision = connectionRevision;
        try
        {
            var samples = await connection.Read(shutdown.Token);
            if (revision == connectionRevision) await SetConnection(samples);
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
        finally { refreshing = false; }
    }

    private async Task SetConnection(Addresses samples)
    {
        if (shutdown.IsCancellationRequested) return;
        int revision = ++connectionRevision;
        if (addresses != samples)
        {
            codes = default;
            addresses = samples;
            RenderMenu();
        }
        if (!settings.ShowCountry) return;
        try
        {
            var result = await connection.Countries(samples, shutdown.Token);
            if (revision != connectionRevision || shutdown.IsCancellationRequested || codes == result) return;
            codes = result;
            RenderMenu();
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
    }

    private string CountryName(string? code) => code is null ? T("Unavailable", "Недоступно") :
        countryNames.TryGetValue(code, out var names) ? names[settings.Language == "ru" ? 1 : 0] : code;

    private string Format(Addresses samples, (string? IPv4, string? IPv6) country, bool four, bool six, bool showCountry,
        bool changedOnly = false)
    {
        List<string> lines = [];
        if (four && (!changedOnly || samples.IPv4 is not null))
            lines.Add("IPv4: " + (samples.IPv4?.ToString() ?? T("Unavailable", "Недоступен")));
        if (six && (!changedOnly || samples.IPv6 is not null))
            lines.Add("IPv6: " + (samples.IPv6?.ToString() ?? T("Unavailable", "Недоступен")));
        if (showCountry)
        {
            lines.Add(T("Connection country:", "Страна соединения:"));
            if (!changedOnly || samples.IPv4 is not null) lines.Add($"  IPv4: {CountryName(country.IPv4)}");
            if (!changedOnly || samples.IPv6 is not null) lines.Add($"  IPv6: {CountryName(country.IPv6)}");
        }
        return string.Join('\n', lines);
    }

    private async Task NotifyChange(Addresses samples, Task<string[]> closing)
    {
        try
        {
            if (!settings.Notify || shutdown.IsCancellationRequested) return;
            string body = await NotificationBody(samples, changedOnly: true);
            if (!settings.Notify || shutdown.IsCancellationRequested) return;
            Notify(T("Public IP changed", "Внешний IP изменился"), body);
            string[] apps = await closing;
            if (apps.Length > 0 && settings.Notify && !shutdown.IsCancellationRequested)
                Notify(T("Apps were closed", "Приложения закрыты"), string.Join(", ", apps));
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
    }

    private async Task<string> NotificationBody(Addresses samples, bool changedOnly, NotificationDetails? selection = null)
    {
        var details = selection ?? settings.Details;
        bool country = details != NotificationDetails.Address;
        bool ip = details != NotificationDetails.Country;
        var resolved = country ? await connection.Countries(samples, shutdown.Token) : default;
        return Format(samples, resolved, ip, ip, country, changedOnly);
    }

    private async Task TestNotification(NotificationDetails details)
    {
        try
        {
            var samples = await connection.Read(shutdown.Token);
            if (samples.Empty) { Error(T("Could not determine your current IP.", "Не удалось определить текущий IP.")); return; }
            Notify(T("Test notification", "Проверка уведомлений"), await NotificationBody(samples, changedOnly: false, details));
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
    }

    private void Notify(string title, string body)
    {
        alerts.Enqueue((title, body));
        if (!alertActive) AdvanceAlert();
    }

    private void AdvanceAlert()
    {
        alertTimer.Stop();
        alertActive = alerts.TryDequeue(out var next);
        if (!alertActive || shutdown.IsCancellationRequested) return;
        string body = next.Body.Length <= 255 ? next.Body : next.Body[..252] + "…";
        icon.ShowBalloonTip(8000, next.Title, body, ToolTipIcon.Info);
        alertTimer.Start();
    }

    private async Task CheckUpdates(bool manual)
    {
        if (checkingUpdates || (!manual && (!settings.WelcomeCompleted ||
            DateTimeOffset.UtcNow - settings.LastUpdateCheck < TimeSpan.FromDays(1)))) return;
        checkingUpdates = true;
        settings.LastUpdateCheck = DateTimeOffset.UtcNow;
        Save(showError: manual);
        try
        {
            newer = await updates.Check(shutdown.Token);
            if (shutdown.IsCancellationRequested) return;
            RenderMenu();
            if (manual)
            {
                if (newer is { } release && MessageBox.Show(T("A Windows update is available. Open its release page?",
                    "Доступно обновление для Windows. Открыть страницу релиза?"), "Route Shield",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes) OpenUrl(release.Page);
                else if (newer is null) MessageBox.Show(T("You have the latest Windows version.", "У вас последняя версия для Windows."), "Route Shield");
            }
            else if (newer is { } available && settings.Notify && settings.LastNotifiedTag != available.Tag)
            {
                settings.LastNotifiedTag = available.Tag;
                Save(showError: false);
                Notify(T("Update available", "Доступно обновление"), available.Tag);
            }
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException or InvalidOperationException or KeyNotFoundException)
        {
            if (manual && !shutdown.IsCancellationRequested)
                Error(T("Could not check for updates.", "Не удалось проверить обновления."));
        }
        finally { checkingUpdates = false; }
    }

    private void ShowSettings()
    {
        using var window = new SettingsWindow(settings, artwork, TestNotification, () => CheckUpdates(manual: true), OpenUrl, Error);
        if (Show(window) != DialogResult.OK) return;
        var previous = (settings.Language, settings.ShowIPv4, settings.ShowIPv6, settings.ShowCountry,
            settings.Notify, settings.Details, settings.ForceClose, settings.CloseOnSleep, settings.ClosingMode, settings.SleepClosingMode);
        bool startup;
        try
        {
            startup = WindowsApps.StartsAtLogin;
            if (startup != window.Startup) WindowsApps.StartsAtLogin = window.Startup;
        }
        catch (Exception error) when (IsFileError(error)) { Error(error.Message); return; }
        (settings.Language, settings.ShowIPv4, settings.ShowIPv6, settings.ShowCountry,
            settings.Notify, settings.Details, settings.ForceClose, settings.CloseOnSleep, settings.ClosingMode, settings.SleepClosingMode) = window.Choice;
        if (!Save())
        {
            (settings.Language, settings.ShowIPv4, settings.ShowIPv6, settings.ShowCountry,
                settings.Notify, settings.Details, settings.ForceClose, settings.CloseOnSleep, settings.ClosingMode, settings.SleepClosingMode) = previous;
            if (startup != window.Startup)
            {
                try { WindowsApps.StartsAtLogin = startup; }
                catch (Exception error) when (IsFileError(error)) { Error(error.Message); }
            }
            return;
        }
        monitor.Apply(refresh: true);
        RenderMenu();
    }

    private void ShowApps()
    {
        using var window = new AppsWindow(settings, artwork, ReplaceApps, Error);
        Show(window);
    }

    private bool ReplaceApps(List<TrackedApp> apps)
    {
        var previous = settings.Apps;
        settings.Apps = apps;
        if (!Save()) { settings.Apps = previous; return false; }
        foreach (var id in menuImages.Keys.Except(apps.Select(app => app.Id)).ToArray())
        {
            menuImages[id].Dispose();
            menuImages.Remove(id);
        }
        RenderMenu();
        return true;
    }

    private void CreateShortcuts()
    {
        try
        {
            foreach (var app in settings.Apps) WindowsApps.CreateShortcut(app);
            MessageBox.Show(T("Shortcuts are on the desktop.", "Ярлыки созданы на рабочем столе."), "Route Shield");
        }
        catch (Exception error) when (IsFileError(error)) { Error(error.Message); }
    }

    private void OpenApp(TrackedApp app)
    {
        using var window = new LaunchWindow(settings, artwork, app, connection,
            (sample, countries) => Format(sample, countries, settings.ShowIPv4, settings.ShowIPv6, settings.ShowCountry));
        if (Show(window) != DialogResult.OK) return;
        try { WindowsApps.Launch(app); }
        catch (Exception error) when (IsFileError(error)) { Error(error.Message); }
    }

    private DialogResult Show(Form form)
    {
        if (dialog is not null) return DialogResult.Cancel;
        dialog = form;
        try { return form.ShowDialog(); }
        finally { dialog = null; }
    }

    private bool Save(bool showError = true)
    {
        try { settings.Save(); return true; }
        catch (Exception error) when (IsFileError(error))
        {
            if (showError) Error(T("Could not save settings.", "Не удалось сохранить настройки.") + "\n" + error.Message);
            return false;
        }
    }

    private void OpenUrl(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true })?.Dispose(); }
        catch (Exception error) when (IsFileError(error)) { Error(error.Message); }
    }

    internal static bool IsFileError(Exception error) => error is IOException or Win32Exception or UnauthorizedAccessException
        or ArgumentException or InvalidOperationException or COMException;

    private void Error(string message) => MessageBox.Show(dialog, message, "Route Shield", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    private string T(string english, string russian) => settings.T(english, russian);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            shutdown.Cancel();
            monitor.Dispose();
            icon.Dispose();
            menu.Dispose();
            artwork.Dispose();
            foreach (var image in menuImages.Values) image.Dispose();
            updateTimer.Dispose();
            alertTimer.Dispose();
            connection.Dispose();
            updates.Dispose();
            shutdown.Dispose();
        }
        base.Dispose(disposing);
    }
}
