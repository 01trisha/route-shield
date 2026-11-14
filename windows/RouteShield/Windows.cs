using System.Drawing.Drawing2D;

namespace RouteShield;

internal abstract class ShieldWindow : Form
{
    protected readonly Preferences settings;
    protected static readonly Color Muted = Color.FromArgb(98, 107, 120);

    protected ShieldWindow(Preferences settings, Icon artwork)
    {
        this.settings = settings;
        Text = "Route Shield";
        Icon = artwork;
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = SystemColors.Window;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = false;
        MinimizeBox = false;
        Padding = new Padding(16);
    }

    protected string T(string english, string russian) => settings.T(english, russian);

    protected static Label Caption(string text) => new() { Text = text, AutoSize = true, Margin = new Padding(3, 6, 3, 6) };

    protected static Button Button(string text, EventHandler action)
    {
        var button = new Button { Text = text, AutoSize = true, MinimumSize = new Size(88, 30), UseVisualStyleBackColor = true };
        button.Click += action;
        return button;
    }

    protected static FlowLayoutPanel Column() => new()
    {
        Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true
    };

    protected static FlowLayoutPanel Footer() => new()
    {
        Dock = DockStyle.Bottom, Height = 40, FlowDirection = FlowDirection.RightToLeft, WrapContents = false
    };

    protected static ComboBox Picker(string[] options, int selected)
    {
        var combo = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 255 };
        combo.Items.AddRange(options);
        combo.SelectedIndex = selected;
        return combo;
    }

    protected static CheckBox Check(string text, bool selected) => new()
    {
        Text = text, Checked = selected, AutoSize = true, Margin = new Padding(3, 6, 3, 6)
    };

    protected string[] DetailOptions() =>
        [T("IP address", "IP-адрес"), T("Country", "Страна"), T("IP address and country", "IP-адрес и страна")];
}

internal sealed class WelcomeWindow : ShieldWindow
{
    private readonly Preferences draft;
    private int step = 1;
    internal (string, bool, NotificationDetails, bool) Choice =>
        (draft.Language, draft.Notify, draft.Details, draft.ForceClose);

    internal WelcomeWindow(Preferences settings, Icon artwork) : base(new Preferences
    {
        Language = settings.Language, Notify = settings.Notify, Details = settings.Details, ForceClose = settings.ForceClose
    }, artwork)
    {
        draft = base.settings;
        ClientSize = new Size(495, 325);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        Render();
    }

    private void Render()
    {
        SuspendLayout();
        AcceptButton = null;
        ActiveControl = null;
        foreach (Control child in Controls.Cast<Control>().ToArray()) child.Dispose();
        Text = T("Welcome to Route Shield", "Добро пожаловать в Route Shield");
        var body = Column();
        body.Controls.Add(Caption(T($"Step {step} of 3", $"Шаг {step} из 3")));
        string title, description;
        switch (step)
        {
            case 1:
                title = T("Check your connection", "Проверьте своё соединение");
                description = T("Route Shield shows your public IP addresses and their countries before you open an app. Choose the interface language to get started.",
                    "Route Shield показывает внешние IP-адреса и их страны перед запуском приложения. Выберите язык интерфейса.");
                break;
            case 2:
                title = T("IP change notifications", "Уведомления о смене IP");
                description = T("Get notified when your public address changes, for example when a VPN connects or disconnects.",
                    "Получайте уведомление, когда внешний адрес меняется, например при подключении или отключении VPN.");
                break;
            default:
                title = T("Close tracked apps", "Завершение приложений из списка");
                description = T("Route Shield can force-quit apps on your list on a confirmed IP change. This may discard unsaved changes.",
                    "Route Shield может принудительно закрыть приложения из списка при подтверждённой смене IP. Несохранённые данные могут потеряться.");
                break;
        }
        var heading = Caption(title);
        heading.Font = new Font(Font.FontFamily, 16, FontStyle.Bold);
        body.Controls.Add(heading);
        var explanation = Caption(description);
        explanation.MaximumSize = new Size(425, 0);
        body.Controls.Add(explanation);
        if (step == 1)
        {
            body.Controls.Add(Caption(T("Interface language", "Язык интерфейса")));
            var language = Picker(["English", "Русский"], draft.Language == "ru" ? 1 : 0);
            language.SelectedIndexChanged += (_, _) =>
            {
                draft.Language = language.SelectedIndex == 1 ? "ru" : "en";
                BeginInvoke(Render);
            };
            body.Controls.Add(language);
        }
        else if (step == 2)
        {
            var notify = Check(T("Notify when the IP changes", "Уведомлять о смене IP"), draft.Notify);
            var details = Picker(DetailOptions(), (int)draft.Details);
            details.Enabled = draft.Notify;
            notify.CheckedChanged += (_, _) => details.Enabled = draft.Notify = notify.Checked;
            details.SelectedIndexChanged += (_, _) => draft.Details = (NotificationDetails)details.SelectedIndex;
            body.Controls.Add(notify);
            body.Controls.Add(Caption(T("Notification details", "Содержимое уведомлений")));
            body.Controls.Add(details);
        }
        else
        {
            var close = Check(T("Force-quit apps on IP changes", "Принудительно завершать приложения при смене IP"), draft.ForceClose);
            close.CheckedChanged += (_, _) => draft.ForceClose = close.Checked;
            body.Controls.Add(close);
        }
        var footer = Footer();
        var next = Button(step == 3 ? T("Done", "Готово") : T("Continue", "Продолжить"), (_, _) =>
        {
            if (step == 3) { DialogResult = DialogResult.OK; return; }
            step++;
            Render();
        });
        footer.Controls.Add(next);
        if (step > 1) footer.Controls.Add(Button(T("Back", "Назад"), (_, _) => { step--; Render(); }));
        Controls.Add(body);
        Controls.Add(footer);
        AcceptButton = next;
        ResumeLayout();
    }
}

internal sealed class SettingsWindow : ShieldWindow
{
    private readonly CheckBox four, six, country, notify, close, startup;
    private readonly ComboBox language, details;

    internal bool Startup => startup.Checked;
    internal (string, bool, bool, bool, bool, NotificationDetails, bool) Choice =>
        (language.SelectedIndex == 1 ? "ru" : "en", four.Checked, six.Checked, country.Checked,
         notify.Checked, (NotificationDetails)details.SelectedIndex, close.Checked);

    internal SettingsWindow(Preferences settings, Icon artwork, Func<NotificationDetails, Task> test,
        Func<Task> update, Action<string> open, Action<string> error) : base(settings, artwork)
    {
        Text = T("Route Shield Settings", "Настройки Route Shield");
        ClientSize = new Size(520, 390);
        MinimumSize = new Size(505, 400);
        var tabs = new TabControl { Dock = DockStyle.Fill };
        var general = AddTab(T("General", "Основные"));
        var notifications = AddTab(T("Notifications", "Уведомления"));
        var about = AddTab(T("About Us", "О нас"));

        general.Controls.Add(Button(T("Check for Updates…", "Проверить обновления…"),
            async (sender, _) => await RunButton((Button)sender!, update)));
        general.Controls.Add(Caption(T("Show connection details", "Показывать информацию о соединении")));
        four = Check("IPv4", settings.ShowIPv4);
        six = Check("IPv6", settings.ShowIPv6);
        country = Check(T("Connection country", "Страна соединения"), settings.ShowCountry);
        general.Controls.AddRange([four, six, country]);
        general.Controls.Add(Caption(T("Interface language", "Язык интерфейса")));
        language = Picker(["English", "Русский"], settings.Language == "ru" ? 1 : 0);
        general.Controls.Add(language);
        startup = Check(T("Launch at sign-in", "Запускать при входе в Windows"), false);
        try { startup.Checked = WindowsApps.StartsAtLogin; }
        catch (Exception problem) when (TrayApplication.IsFileError(problem)) { startup.Enabled = false; }
        close = Check(T("Force-quit apps on IP changes", "Принудительно завершать приложения при смене IP"), settings.ForceClose);
        general.Controls.AddRange([startup, close]);
        general.Controls.Add(Button(T("Open Configuration File…", "Открыть конфигурационный файл…"), (_, _) =>
        {
            if (File.Exists(Preferences.FilePath)) open(Preferences.FilePath);
            else error(T("The settings file has not been saved yet.", "Файл настроек ещё не сохранён."));
        }));

        notify = Check(T("Notify when the IP changes", "Уведомлять о смене IP"), settings.Notify);
        details = Picker(DetailOptions(), (int)settings.Details);
        var testButton = Button(T("Test Notification", "Проверить уведомление"),
            async (sender, _) => await RunButton((Button)sender!, () => test((NotificationDetails)details.SelectedIndex)));
        void SetNotificationControls() => details.Enabled = testButton.Enabled = notify.Checked;
        notify.CheckedChanged += (_, _) => SetNotificationControls();
        SetNotificationControls();
        notifications.Controls.AddRange([notify, Caption(T("Notification details", "Содержимое уведомлений")), details, testButton]);
        notifications.Controls.Add(Button(T("Open Windows Notifications Settings", "Открыть параметры уведомлений Windows"),
            (_, _) => open("ms-settings:notifications")));

        about.Controls.Add(Caption("Route Shield " + Updates.Current));
        about.Controls.Add(Caption(T("Public IP monitoring and app launch checks.", "Мониторинг внешнего IP и проверка перед запуском приложений.")));
        var link = new LinkLabel { Text = T("GitHub repository", "Репозиторий на GitHub"), AutoSize = true };
        link.LinkClicked += (_, _) => open(Program.Repo);
        about.Controls.Add(link);

        var footer = Footer();
        var save = Button(T("Save", "Сохранить"), (_, _) =>
        {
            if (!close.Checked || settings.ForceClose || MessageBox.Show(this,
                T("Tracked apps may lose unsaved changes. Enable force-quit?", "Несохранённые данные могут потеряться. Включить принудительное завершение?"),
                "Route Shield", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                DialogResult = DialogResult.OK;
        });
        var cancel = Button(T("Cancel", "Отмена"), (_, _) => DialogResult = DialogResult.Cancel);
        footer.Controls.AddRange([save, cancel]);
        Controls.Add(tabs);
        Controls.Add(footer);
        AcceptButton = save;
        CancelButton = cancel;

        FlowLayoutPanel AddTab(string title)
        {
            var page = new TabPage(title) { Padding = new Padding(10) };
            var column = Column();
            page.Controls.Add(column);
            tabs.TabPages.Add(page);
            return column;
        }
    }

    private static async Task RunButton(Button button, Func<Task> action)
    {
        button.Enabled = false;
        try { await action(); }
        finally { if (!button.IsDisposed) button.Enabled = true; }
    }
}

internal sealed class AppsWindow : ShieldWindow
{
    private readonly FlowLayoutPanel grid = new()
    {
        Dock = DockStyle.Fill, AutoScroll = true, WrapContents = true, Padding = new Padding(2),
        BorderStyle = BorderStyle.FixedSingle
    };
    private readonly Func<List<TrackedApp>, bool> save;
    private readonly Action<string> error;

    internal AppsWindow(Preferences settings, Icon artwork, Func<List<TrackedApp>, bool> save, Action<string> error)
        : base(settings, artwork)
    {
        this.save = save;
        this.error = error;
        Text = T("Add Apps", "Добавить приложения");
        ClientSize = new Size(545, 380);
        MinimumSize = new Size(365, 260);
        MaximizeBox = true;
        var header = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 55, WrapContents = false };
        var instructions = Caption(T("Drag .exe files or shortcuts here.\nYou can select several in File Explorer.",
            "Перетащите сюда .exe или ярлыки.\nВ Проводнике можно выбрать несколько."));
        header.Controls.Add(instructions);
        var footer = Footer();
        footer.Controls.Add(Button(T("Browse…", "Выбрать…"), (_, _) => Browse()));
        Controls.Add(grid);
        Controls.Add(header);
        Controls.Add(footer);
        WireDrop(this);
        WireDrop(grid);
        WireDrop(header);
        WireDrop(instructions);
        Render();
    }

    private void Browse()
    {
        using var picker = new OpenFileDialog
        {
            Multiselect = true, DereferenceLinks = false,
            Filter = T("Applications and shortcuts|*.exe;*.lnk", "Приложения и ярлыки|*.exe;*.lnk")
        };
        if (picker.ShowDialog(this) == DialogResult.OK) AddFiles(picker.FileNames);
    }

    private void WireDrop(Control target)
    {
        target.AllowDrop = true;
        target.DragEnter += (_, args) => args.Effect = args.Data?.GetDataPresent(DataFormats.FileDrop) == true
            ? DragDropEffects.Copy : DragDropEffects.None;
        target.DragDrop += (_, args) =>
        {
            if (args.Data?.GetData(DataFormats.FileDrop) is string[] files) AddFiles(files);
        };
    }

    private void AddFiles(string[] files)
    {
        List<TrackedApp> next = [.. settings.Apps];
        List<string> rejected = [];
        foreach (string file in files)
        {
            try
            {
                var entry = WindowsApps.Read(file);
                if (!next.Any(app => string.Equals(app.Path, entry.Path, StringComparison.OrdinalIgnoreCase))) next.Add(entry);
            }
            catch (Exception problem) when (TrayApplication.IsFileError(problem)) { rejected.Add(Path.GetFileName(file)); }
        }
        if (next.Count > settings.Apps.Count && save(next)) Render();
        if (rejected.Count > 0) error(T("Could not add:", "Не удалось добавить:") + "\n" + string.Join("\n", rejected));
    }

    private void Render()
    {
        grid.SuspendLayout();
        foreach (Control child in grid.Controls.Cast<Control>().ToArray()) child.Dispose();
        foreach (var app in settings.Apps)
        {
            var tile = new Panel { Width = 108, Height = 125, Margin = new Padding(5) };
            var frame = new Panel { Location = new Point(11, 2), Size = new Size(86, 86) };
            frame.Paint += (_, args) =>
            {
                args.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                int radius = Math.Max(1, frame.ClientSize.Width * 9 / 86);
                using var outline = new GraphicsPath();
                outline.AddRoundedRectangle(new Rectangle(1, 1, frame.ClientSize.Width - 3, frame.ClientSize.Height - 3),
                    new Size(radius * 2, radius * 2));
                using var border = new Pen(SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(214, 220, 227));
                args.Graphics.DrawPath(border, outline);
            };
            using var appIcon = WindowsApps.IconFor(app);
            var image = new PictureBox
            {
                Location = new Point(18, 22), Size = new Size(50, 50), Image = appIcon.ToBitmap(),
                SizeMode = PictureBoxSizeMode.Zoom
            };
            image.Disposed += (_, _) => image.Image?.Dispose();
            var name = new Label
            {
                Text = app.Name, Location = new Point(0, 94), Size = new Size(108, 30),
                TextAlign = ContentAlignment.TopCenter, AutoEllipsis = true
            };
            var remove = new Button
            {
                ForeColor = Color.White, BackColor = Color.FromArgb(177, 32, 50), FlatStyle = FlatStyle.Flat,
                Size = new Size(23, 23), Location = new Point(56, 7), TabStop = true,
                AccessibleName = T($"Remove {app.Name}", $"Удалить {app.Name}")
            };
            remove.FlatAppearance.BorderSize = 0;
            remove.Paint += (_, args) =>
            {
                var bounds = remove.ClientRectangle;
                float centerX = (bounds.Width - 1) / 2f;
                float centerY = (bounds.Height - 1) / 2f;
                float halfLength = bounds.Width * 3.5f / 23f;
                args.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using var stroke = new Pen(remove.ForeColor, bounds.Width * 1.5f / 23f)
                {
                    StartCap = LineCap.Round, EndCap = LineCap.Round
                };
                args.Graphics.DrawLine(stroke, centerX - halfLength, centerY - halfLength, centerX + halfLength, centerY + halfLength);
                args.Graphics.DrawLine(stroke, centerX + halfLength, centerY - halfLength, centerX - halfLength, centerY + halfLength);
            };
            void ShapeRemoveButton()
            {
                using var shape = new GraphicsPath();
                int diameter = Math.Max(2, remove.ClientSize.Width * 10 / 23);
                shape.AddRoundedRectangle(remove.ClientRectangle, new Size(diameter, diameter));
                var previous = remove.Region;
                remove.Region = new Region(shape);
                previous?.Dispose();
            }
            remove.SizeChanged += (_, _) => ShapeRemoveButton();
            ShapeRemoveButton();
            remove.Click += (_, _) =>
            {
                if (save(settings.Apps.Where(entry => entry.Id != app.Id).ToList())) Render();
            };
            frame.Controls.AddRange([image, remove]);
            remove.BringToFront();
            tile.Controls.AddRange([frame, name]);
            foreach (var control in new Control[] { tile, frame, image, name, remove }) WireDrop(control);
            grid.Controls.Add(tile);
        }
        grid.ResumeLayout();
    }
}

internal sealed class LaunchWindow : ShieldWindow
{
    internal LaunchWindow(Preferences settings, Icon artwork, TrackedApp app, Connection connection,
        Func<Addresses, (string?, string?), string> format) : base(settings, artwork)
    {
        Text = T($"Open {app.Name}", $"Открыть {app.Name}");
        ClientSize = new Size(500, 255);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        var body = Column();
        body.Controls.Add(Caption(T("Check the connection before opening the app.", "Проверьте соединение перед запуском приложения.")));
        var result = Caption(T("Checking public IP…", "Проверка внешнего IP…"));
        result.ForeColor = Muted;
        body.Controls.Add(result);
        var footer = Footer();
        var open = Button(T("Open", "Открыть"), (_, _) => DialogResult = DialogResult.OK);
        open.Enabled = false;
        var cancel = Button(T("Cancel", "Отмена"), (_, _) => DialogResult = DialogResult.Cancel);
        footer.Controls.AddRange([open, cancel]);
        Controls.Add(body);
        Controls.Add(footer);
        AcceptButton = open;
        CancelButton = cancel;
        var source = new CancellationTokenSource();
        var token = source.Token;
        Disposed += (_, _) => { source.Cancel(); source.Dispose(); };
        Shown += async (_, _) =>
        {
            try
            {
                var samples = await connection.Read(token);
                token.ThrowIfCancellationRequested();
                result.Text = format(samples, default);
                open.Enabled = true;
                if (settings.ShowCountry)
                {
                    var countries = await connection.Countries(samples, token);
                    token.ThrowIfCancellationRequested();
                    result.Text = format(samples, countries);
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        };
    }
}
