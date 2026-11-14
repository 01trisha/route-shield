using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace RouteShield;

internal static class WindowsApps
{
    private static readonly int Session = Process.GetCurrentProcess().SessionId;

    internal static TrackedApp Read(string file)
    {
        string path = Path.GetFullPath(file);
        string name = Path.GetFileNameWithoutExtension(path);
        string arguments = "", workDir = "", icon = "";
        int iconIndex = 0;
        if (Path.GetExtension(path).Equals(".lnk", StringComparison.OrdinalIgnoreCase))
        {
            WithShortcut(path, link =>
            {
                path = Environment.ExpandEnvironmentVariables((string)link.TargetPath);
                arguments = link.Arguments;
                workDir = Environment.ExpandEnvironmentVariables((string)link.WorkingDirectory);
                string location = link.IconLocation;
                int comma = location.LastIndexOf(',');
                if (comma >= 0 && int.TryParse(location[(comma + 1)..], out iconIndex))
                    icon = Environment.ExpandEnvironmentVariables(location[..comma].Trim().Trim('"'));
            });
        }
        if (!Path.IsPathFullyQualified(path) || !Path.GetExtension(path).Equals(".exe", StringComparison.OrdinalIgnoreCase)
            || !File.Exists(path) || string.Equals(path, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Select an existing desktop executable or a shortcut to one.");
        return new(Guid.NewGuid(), name, Path.GetFullPath(path), arguments, workDir, icon, iconIndex);
    }

    internal static void Launch(TrackedApp app) => Process.Start(new ProcessStartInfo(app.Path)
    {
        Arguments = app.Arguments,
        WorkingDirectory = Directory.Exists(app.WorkingDirectory) ? app.WorkingDirectory : Path.GetDirectoryName(app.Path)!,
        UseShellExecute = true
    })?.Dispose();

    internal static string CreateShortcut(TrackedApp app)
    {
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        string name = string.Concat(app.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)).Trim();
        string prefix = Path.Combine(desktop, $"{name} (Route Shield)");
        string file = prefix + ".lnk";
        for (int i = 2; File.Exists(file); i++)
        {
            bool same = false;
            WithShortcut(file, link => same = (string)link.Arguments == $"--launch {app.Id:D}" &&
                string.Equals((string)link.TargetPath, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase));
            if (same) return file;
            file = $"{prefix} {i}.lnk";
        }
        WriteShortcut(file, $"--launch {app.Id:D}", app.IconPath.Length == 0 ? app.Path : app.IconPath, app.IconIndex);
        return file;
    }

    internal static bool StartsAtLogin
    {
        get
        {
            string file = StartupShortcut;
            if (!File.Exists(file)) return false;
            bool enabled = false;
            WithShortcut(file, link => enabled = string.Equals((string)link.TargetPath, Environment.ProcessPath,
                StringComparison.OrdinalIgnoreCase));
            return enabled;
        }
        set
        {
            if (value) WriteShortcut(StartupShortcut, "--background", Environment.ProcessPath!, 0);
            else File.Delete(StartupShortcut);
        }
    }

    private static string StartupShortcut => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Route Shield.lnk");

    private static void WriteShortcut(string file, string args, string icon, int index)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        WithShortcut(file, link =>
        {
            link.TargetPath = Environment.ProcessPath;
            link.Arguments = args;
            link.WorkingDirectory = AppContext.BaseDirectory;
            link.IconLocation = $"{icon},{index}";
            link.Save();
        });
    }

    private static void WithShortcut(string file, Action<dynamic> action)
    {
        Type type = Type.GetTypeFromProgID("WScript.Shell", throwOnError: true)!;
        dynamic shell = Activator.CreateInstance(type)!;
        try
        {
            dynamic link = shell.CreateShortcut(file);
            try { action(link); }
            finally { Marshal.FinalReleaseComObject(link); }
        }
        finally { Marshal.FinalReleaseComObject(shell); }
    }

    internal static Icon IconFor(TrackedApp app)
    {
        try
        {
            if (app.IconPath.Length > 0)
            {
                uint count = ExtractIconEx(app.IconPath, app.IconIndex, out IntPtr handle, IntPtr.Zero, 1);
                if (count == 1 && handle != IntPtr.Zero)
                {
                    try { return (Icon)Icon.FromHandle(handle).Clone(); }
                    finally { DestroyIcon(handle); }
                }
            }
            return Icon.ExtractAssociatedIcon(app.Path) ?? (Icon)SystemIcons.Application.Clone();
        }
        catch (Exception error) when (error is ArgumentException or IOException or Win32Exception)
        {
            return (Icon)SystemIcons.Application.Clone();
        }
    }

    private static List<(TrackedApp App, SafeProcessHandle Handle, int Pid)> Running(IReadOnlyList<TrackedApp> apps, uint access)
    {
        var result = new List<(TrackedApp, SafeProcessHandle, int)>();
        if (apps.Count == 0) return result;
        var path = new StringBuilder(32768);
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.Id == Environment.ProcessId || process.SessionId != Session) continue;
                    SafeProcessHandle handle = OpenProcess(Query | access, false, process.Id);
                    path.Clear();
                    int length = path.Capacity;
                    if (!handle.IsInvalid && QueryFullProcessImageName(handle, 0, path, ref length))
                    {
                        string executable = path.ToString();
                        var matched = apps.FirstOrDefault(app => string.Equals(app.Path, executable, StringComparison.OrdinalIgnoreCase));
                        if (matched is not null)
                        {
                            result.Add((matched, handle, process.Id));
                            continue;
                        }
                    }
                    handle.Dispose();
                }
                catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
            }
        }
        return result;
    }

    internal static bool IsAnyRunning(IReadOnlyList<TrackedApp> apps)
    {
        var running = Running(apps, 0);
        foreach (var item in running) item.Handle.Dispose();
        return running.Count > 0;
    }

    internal static Task<string[]> Close(IReadOnlyList<TrackedApp> apps, CloseMode mode, bool confirm = true)
    {
        bool safe = mode == CloseMode.Safe;
        uint access = (safe ? 0 : Terminate) | (confirm ? Synchronize : 0);
        var terminated = new List<Task<string?>>();
        foreach (var (app, handle, pid) in Running(apps, access))
        {
            bool requested = safe ? RequestClose(pid) : TerminateProcess(handle, 1);
            if (requested && confirm)
                terminated.Add(Task.Run(() =>
                {
                    using (handle)
                        return WaitForSingleObject(handle, safe ? 60000u : 5000u) == 0 ? app.Name : null;
                }));
            else handle.Dispose();
        }
        return Confirm(terminated);
    }

    private static bool RequestClose(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.CloseMainWindow();
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return false;
        }
    }

    private static async Task<string[]> Confirm(List<Task<string?>> tasks) =>
        (await Task.WhenAll(tasks)).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

    private const uint Query = 0x1000;
    private const uint Terminate = 0x0001;
    private const uint Synchronize = 0x00100000;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageName(SafeProcessHandle process, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(SafeProcessHandle process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconEx(string file, int index, out IntPtr large, IntPtr small, uint count);
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);
}
