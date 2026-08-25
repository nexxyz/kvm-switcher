using System.Windows.Forms;

namespace KvmSwitcher;

internal static class Program
{
    private const string MutexName = "Local\\KvmSwitcher.SingleInstance";

    [STAThread]
    private static int Main(string[] args)
    {
        if (IsProbeInvocation(args))
        {
            return (int)MonitorHidService.ProbeHardware();
        }

        if (args.Length != 0)
        {
            return 2;
        }

        using var mutex = new Mutex(true, MutexName, out var createdNew);
        if (!createdNew)
        {
            return 0;
        }

        ApplicationConfiguration.Initialize();
        using var trayApp = new TrayApp(new MonitorHidService());
        Application.Run(trayApp);
        return 0;
    }

    internal static bool IsProbeInvocation(IReadOnlyList<string> args) =>
        args.Count == 1 && string.Equals(args[0], "--probe-hardware", StringComparison.Ordinal);
}
