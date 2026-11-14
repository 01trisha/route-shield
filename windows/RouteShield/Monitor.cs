using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Timer = System.Windows.Forms.Timer;

namespace RouteShield;

internal sealed class Monitor : IDisposable
{
    private readonly Connection connection;
    private readonly Preferences preferences;
    private readonly SynchronizationContext ui;
    private readonly AddressBaseline baseline = new();
    private readonly Timer periodic = new() { Interval = 15000 };
    private readonly Timer debounce = new() { Interval = 200 };
    private readonly Timer retry = new() { Interval = 750 };
    private readonly RouteCallback routeCallback;
    private readonly IntPtr routeHandle;
    private CancellationTokenSource? active;
    private long lastProbe;
    private bool disposed, checkingProcesses;

    internal event Action<Addresses>? Refreshed;
    internal event Func<Addresses, Task<string[]>, Task>? Changed;

    internal Monitor(Connection connection, Preferences preferences, SynchronizationContext ui)
    {
        this.connection = connection;
        this.preferences = preferences;
        this.ui = ui;
        periodic.Tick += Periodic;
        debounce.Tick += (_, _) => { debounce.Stop(); _ = Check(networkEvent: true); };
        retry.Tick += (_, _) => { retry.Stop(); _ = Check(networkEvent: false); };
        routeCallback = (_, _, _) => PostChange();
        try { NotifyRouteChange2(0, routeCallback, IntPtr.Zero, false, out routeHandle); }
        catch (EntryPointNotFoundException) { }
        NetworkChange.NetworkAddressChanged += AddressChanged;
        SystemEvents.PowerModeChanged += PowerChanged;
    }

    internal void Apply(bool refresh = false)
    {
        bool enabled = preferences.WelcomeCompleted && (preferences.Notify || preferences.ForceClose);
        bool wasEnabled = periodic.Enabled;
        periodic.Enabled = enabled;
        if (!enabled)
        {
            debounce.Stop();
            retry.Stop();
            active?.Cancel();
            baseline.Reset();
        }
        else if (!wasEnabled || refresh) _ = Check(networkEvent: false);
    }

    private async void Periodic(object? sender, EventArgs args)
    {
        if (active is not null || debounce.Enabled || checkingProcesses) return;
        var elapsed = Environment.TickCount64 - lastProbe;
        if (elapsed >= 120000)
        {
            await Check(networkEvent: false);
            return;
        }
        if (elapsed < 15000 || !preferences.ForceClose || preferences.Apps.Count == 0) return;
        var apps = preferences.Apps.ToArray();
        checkingProcesses = true;
        try
        {
            if (await Task.Run(() => WindowsApps.IsAnyRunning(apps)) && preferences.ForceClose &&
                Environment.TickCount64 - lastProbe >= 15000)
                await Check(networkEvent: false);
        }
        finally { checkingProcesses = false; }
    }

    private void AddressChanged(object? sender, EventArgs args) => PostChange();
    private void PowerChanged(object sender, PowerModeChangedEventArgs args)
    {
        if (args.Mode == PowerModes.Resume) PostChange();
    }

    private void PostChange() => ui.Post(_ =>
    {
        if (disposed || !periodic.Enabled || debounce.Enabled) return;
        active?.Cancel();
        active = null;
        retry.Stop();
        debounce.Interval = (int)Math.Max(200, 500 - (Environment.TickCount64 - lastProbe));
        debounce.Start();
    }, null);

    private async Task Check(bool networkEvent)
    {
        if (disposed || !periodic.Enabled || active is not null || debounce.Enabled) return;

        using var source = new CancellationTokenSource();
        active = source;
        lastProbe = Environment.TickCount64;
        Task<string[]>? close = null;
        IPAddress? changed4 = null, changed6 = null;
        try
        {
            async Task<IPAddress?> Sample(AddressFamily family)
            {
                var address = await connection.Probe(family, source.Token);
                source.Token.ThrowIfCancellationRequested();
                if (!baseline.Changed(address)) return address;
                if (family == AddressFamily.InterNetwork) changed4 = address;
                else changed6 = address;
                if (close is null)
                {
                    var apps = preferences.ForceClose ? preferences.Apps.ToArray() : [];
                    close = apps.Length > 0 ? Task.Run(() => WindowsApps.Close(apps)) : Task.FromResult(Array.Empty<string>());
                }
                return address;
            }

            var four = Sample(AddressFamily.InterNetwork);
            var six = Sample(AddressFamily.InterNetworkV6);
            await Task.WhenAll(four, six);
            source.Token.ThrowIfCancellationRequested();
            Refreshed?.Invoke(new(await four, await six));
            if (close is null && networkEvent) retry.Start();
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(active, source)) active = null;
        }

        if (!disposed && close is not null && Changed is not null)
            await Changed(new(changed4, changed6), close);
    }

    public void Dispose()
    {
        disposed = true;
        NetworkChange.NetworkAddressChanged -= AddressChanged;
        SystemEvents.PowerModeChanged -= PowerChanged;
        if (routeHandle != IntPtr.Zero) CancelMibChangeNotify2(routeHandle);
        active?.Cancel();
        periodic.Dispose();
        debounce.Dispose();
        retry.Dispose();
    }

    private delegate void RouteCallback(IntPtr context, IntPtr row, uint type);
    [DllImport("iphlpapi.dll")]
    private static extern uint NotifyRouteChange2(ushort family, RouteCallback callback, IntPtr context,
        [MarshalAs(UnmanagedType.U1)] bool initial, out IntPtr handle);
    [DllImport("iphlpapi.dll")]
    private static extern uint CancelMibChangeNotify2(IntPtr handle);
}
