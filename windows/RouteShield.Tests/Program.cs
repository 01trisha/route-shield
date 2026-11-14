using System.Diagnostics;
using System.Net;
using RouteShield;

namespace RouteShield.Tests;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        CheckBaseline();
        CheckVersions();
        CheckWindows();
        CheckTermination().GetAwaiter().GetResult();
    }

    private static void CheckBaseline()
    {
        AddressBaseline baseline = new();
        var original = IPAddress.Parse("192.0.2.5");
        var ipv6 = IPAddress.Parse("2001:db8::5");
        Require(!baseline.Changed(original) && !baseline.Changed(ipv6), "First samples establish independent baselines");
        Require(!baseline.Changed(null), "A failed request does not change the baseline");
        Require(!baseline.Changed(IPAddress.Parse("2001:db8:0:0::5")), "Equivalent IPv6 formats compare equal");
        Require(baseline.Changed(IPAddress.Parse("198.51.100.5")), "A confirmed IPv4 change is detected");
        Require(baseline.Changed(IPAddress.Parse("2001:db8::6")), "A confirmed IPv6 change is detected");
        baseline.Reset();
        Require(!baseline.Changed(original), "Reenabling monitoring establishes a new baseline");
    }

    private static void CheckVersions()
    {
        var beta = Release.Parse("windows-v1.0.0-beta.2")!.Value;
        Require(Release.Parse("windows-v1.0.0-beta.10")!.Value.CompareTo(beta) > 0, "Beta numbers compare numerically");
        Require(Release.Parse("windows-v1.0.0")!.Value.CompareTo(beta) > 0, "Stable sorts after beta");
        Require(Release.Parse("v1.4.1") is null, "macOS tags are ignored");
        Require(Release.Parse("windows-v1.0.0-beta.2147483648") is null, "Out-of-range beta numbers are rejected");
    }

    private static void CheckWindows()
    {
        ApplicationConfiguration.Initialize();
        using var icon = (Icon)SystemIcons.Application.Clone();
        Preferences preferences = new() { Language = "en" };
        using var window = new WelcomeWindow(preferences, icon);
        Exception? failure = null;
        window.Shown += async (_, _) =>
        {
            try
            {
                Find<ComboBox>(window).SelectedIndex = 1;
                await Task.Yield();
                Require(window.Text == "Добро пожаловать в Route Shield", "Switching language refreshes the wizard");
                ((Button)window.AcceptButton!).PerformClick();
                await Task.Yield();
                var notify = Find<CheckBox>(window);
                notify.Checked = true;
                Find<ComboBox>(window).SelectedIndex = (int)NotificationDetails.Both;
                ((Button)window.AcceptButton!).PerformClick();
                await Task.Yield();
                Find<CheckBox>(window).Checked = true;
                ((Button)window.AcceptButton!).PerformClick();
            }
            catch (Exception error) { failure = error; window.Close(); }
        };
        var result = window.ShowDialog();
        if (failure is not null) throw failure;
        Require(result == DialogResult.OK && window.Choice.Item1 == "ru" && window.Choice.Item2 && window.Choice.Item3 == NotificationDetails.Both &&
                window.Choice.Item4, "All welcome steps retain the notification and force-quit choices");
        Require(!preferences.WelcomeCompleted && !preferences.ForceClose, "The welcome window stages changes");
    }

    private static T Find<T>(Control control) where T : Control =>
        control.Controls.OfType<FlowLayoutPanel>().SelectMany(panel => panel.Controls.OfType<T>()).Single();

    private static async Task CheckTermination()
    {
        string directory = Path.Combine(Path.GetTempPath(), "route-shield-test-" + Guid.NewGuid().ToString("N"));
        string trackedPath = Path.Combine(directory, "tracked", "ping.exe");
        string otherPath = Path.Combine(directory, "other", "ping.exe");
        try
        {
            foreach (string path in new[] { trackedPath, otherPath })
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.Copy(Path.Combine(Environment.SystemDirectory, "ping.exe"), path);
            }
            var tracked = WindowsApps.Read(trackedPath) with { Name = "Tracked test app" };
            using var first = StartProbe(trackedPath);
            using var second = StartProbe(trackedPath);
            using var other = StartProbe(otherPath);
            try
            {
                Require(!new[] { first, second, other }.Any(process => process.HasExited), "Test processes launched");
                Require(WindowsApps.IsAnyRunning([tracked]), "Tracked app opened directly is found");
                var closed = await WindowsApps.Close([tracked]);
                Require(closed.SequenceEqual(["Tracked test app"]), "Confirmed instances are grouped by app");
                Require(first.HasExited && second.HasExited && !other.HasExited, "Only processes matching the full path are closed");
            }
            finally
            {
                foreach (var process in new[] { first, second, other })
                {
                    if (!process.HasExited) process.Kill();
                    process.WaitForExit(5000);
                }
            }
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static Process StartProbe(string path) => Process.Start(new ProcessStartInfo(path, "-t 127.0.0.1")
    {
        UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true
    })!;

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
        Console.WriteLine("pass: " + message);
    }
}
