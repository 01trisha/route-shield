using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace RouteShield.Tests;

internal static class Screenshots
{
    internal static void Capture(string destination)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Directory.CreateDirectory(destination);
        using var icon = Icon.ExtractAssociatedIcon(typeof(Preferences).Assembly.Location) ?? (Icon)SystemIcons.Application.Clone();
        var settings = new Preferences { Language = "ru", Notify = true, Details = NotificationDetails.Both };
        foreach (var demo in new[] { ("notepad.exe", "Блокнот"), ("mspaint.exe", "Paint"), ("cmd.exe", "Командная строка"), ("regedit.exe", "Редактор реестра") })
        {
            string path = Path.Combine(Environment.SystemDirectory, demo.Item1);
            if (!File.Exists(path)) path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), demo.Item1);
            if (File.Exists(path)) settings.Apps.Add(WindowsApps.Read(path) with { Name = demo.Item2 });
        }
        string os = FileVersionInfo.GetVersionInfo(Path.Combine(Environment.SystemDirectory, "kernel32.dll")).FileVersion ?? Environment.OSVersion.ToString();
        File.WriteAllText(Path.Combine(destination, "system.txt"), os);
        using (var welcome = new WelcomeWindow(settings, icon))
            CaptureWindow(welcome, Path.Combine(destination, "welcome.png"));
        using (var preferences = new SettingsWindow(settings, icon, _ => Task.CompletedTask, () => Task.CompletedTask, _ => { }, _ => { }))
            CaptureWindow(preferences, Path.Combine(destination, "settings.png"));
        using (var apps = new AppsWindow(settings, icon, _ => true, _ => { }))
            CaptureWindow(apps, Path.Combine(destination, "apps.png"));
    }

    private static void CaptureWindow(Form form, string destination)
    {
        Exception? failure = null;
        using var timer = new System.Windows.Forms.Timer { Interval = 500 };
        form.Shown += (_, _) => timer.Start();
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            try
            {
                using var image = new Bitmap(form.Width, form.Height);
                using var graphics = Graphics.FromImage(image);
                IntPtr dc = graphics.GetHdc();
                try
                {
                    if (!PrintWindow(form.Handle, dc, 2))
                        throw new InvalidOperationException("PrintWindow could not capture the form.");
                }
                finally { graphics.ReleaseHdc(dc); }
                image.Save(destination, ImageFormat.Png);
            }
            catch (Exception error) { failure = error; }
            finally { form.Close(); }
        };
        form.ShowDialog();
        if (failure is not null) throw failure;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
}
