using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace RouteShield;

internal static class Program
{
    private const string InstanceName = "RouteShield.Windows";
    internal const string Repo = "https://github.com/01trisha/route-shield";

    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        string command = args.Length == 2 && args[0] == "--launch" && Guid.TryParse(args[1], out Guid id)
            ? id.ToString("D")
            : args is ["--background"] ? "background" : "show";
        using var mutex = new Mutex(true, @"Local\" + InstanceName, out bool first);
        if (!first)
        {
            if (command == "background") return;
            try
            {
                using var pipe = new NamedPipeClientStream(".", InstanceName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
                pipe.Connect(3000);
                pipe.Write(Encoding.ASCII.GetBytes(command));
            }
            catch (IOException) { MessageBox.Show("Could not contact Route Shield.", "Route Shield"); }
            catch (TimeoutException) { MessageBox.Show("Could not contact Route Shield.", "Route Shield"); }
            return;
        }

        Preferences settings;
        try { settings = Preferences.Load(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            MessageBox.Show($"Could not read the configuration file.\n\n{Preferences.FilePath}\n\n{error.Message}",
                "Route Shield", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        using var context = new TrayApplication(settings, SynchronizationContext.Current!);
        using var cancellation = new CancellationTokenSource();
        _ = Listen(SynchronizationContext.Current!, context.HandleCommand, cancellation.Token);
        context.Initialize(command);
        Application.Run(context);
        cancellation.Cancel();
    }

    private static async Task Listen(SynchronizationContext ui, Action<string> dispatch, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(InstanceName, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(token).ConfigureAwait(false);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(2000);
                byte[] buffer = new byte[37];
                int size = await pipe.ReadAtLeastAsync(buffer, buffer.Length, false, timeout.Token).ConfigureAwait(false);
                string command = Encoding.ASCII.GetString(buffer, 0, size);
                if (command == "show" || Guid.TryParseExact(command, "D", out _))
                    ui.Post(_ => { if (!token.IsCancellationRequested) dispatch(command); }, null);
            }
            catch (OperationCanceledException) { }
            catch (IOException) { await Task.Delay(250).ConfigureAwait(false); }
            catch (PlatformNotSupportedException) { return; }
        }
    }
}
