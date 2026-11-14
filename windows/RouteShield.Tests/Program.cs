using System.Diagnostics;
using System.Net;
using RouteShield;

namespace RouteShield.Tests;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args is ["--wait"])
        {
            Console.WriteLine("ready");
            Console.ReadLine();
            return 0;
        }
        try
        {
            CheckBaseline();
            CheckVersions();
            CheckWindows();
            CheckTermination().GetAwaiter().GetResult();
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
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
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var icon = (Icon)SystemIcons.Application.Clone();
        Preferences preferences = new() { Language = "en" };
        using var window = new WelcomeWindow(preferences, icon);
        Exception? failure = null;
        using var timer = new System.Windows.Forms.Timer { Interval = 100 };
        int action = 0;
        window.Shown += (_, _) => timer.Start();
        timer.Tick += (_, _) =>
        {
            try
            {
                switch (action++)
                {
                    case 0:
                        Find<ComboBox>(window).SelectedIndex = 1;
                        break;
                    case 1:
                        Require(window.Text == "Добро пожаловать в Route Shield", "Switching language refreshes the wizard");
                        ClickNext(window);
                        break;
                    case 2:
                        Find<CheckBox>(window).Checked = true;
                        Find<ComboBox>(window).SelectedIndex = (int)NotificationDetails.Both;
                        ClickNext(window);
                        break;
                    case 3:
                        Find<CheckBox>(window).Checked = true;
                        ClickNext(window);
                        break;
                    default:
                        throw new InvalidOperationException("The welcome window did not close after Done.");
                }
            }
            catch (Exception error) { failure = error; window.Close(); }
        };
        var result = window.ShowDialog();
        timer.Stop();
        if (failure is not null) throw new InvalidOperationException($"Welcome action {action} failed.", failure);
        Require(result == DialogResult.OK && window.Choice.Item1 == "ru" && window.Choice.Item2 && window.Choice.Item3 == NotificationDetails.Both &&
                window.Choice.Item4, "All welcome steps retain the notification and force-quit choices");
        Require(!preferences.WelcomeCompleted && !preferences.ForceClose, "The welcome window stages changes");
    }

    private static void ClickNext(WelcomeWindow window)
    {
        var next = (Button)window.AcceptButton!;
        Require(next.CanSelect, "The next button accepts input");
        next.PerformClick();
    }

    private static T Find<T>(Control control) where T : Control =>
        control.Controls.OfType<FlowLayoutPanel>().SelectMany(panel => panel.Controls.OfType<T>()).Single();

    private static async Task CheckTermination()
    {
        string directory = Path.Combine(Path.GetTempPath(), "route-shield-test-" + Guid.NewGuid().ToString("N"));
        string executable = Path.GetFileName(Environment.ProcessPath)!;
        string trackedPath = Path.Combine(directory, "tracked", executable);
        string otherPath = Path.Combine(directory, "other", executable);
        try
        {
            foreach (string path in new[] { trackedPath, otherPath })
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                foreach (string file in Directory.EnumerateFiles(AppContext.BaseDirectory))
                    File.Copy(file, Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileName(file)));
            }
            var tracked = WindowsApps.Read(trackedPath) with { Name = "Tracked test app" };
            using var first = StartChild(trackedPath);
            using var second = StartChild(trackedPath);
            using var other = StartChild(otherPath);
            try
            {
                foreach (var process in new[] { first, second, other })
                    Require(await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)) == "ready",
                        "Test process launched");
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

    private static Process StartChild(string path) => Process.Start(new ProcessStartInfo(path, "--wait")
    {
        UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardInput = true
    })!;

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
        Console.WriteLine("pass: " + message);
    }
}
