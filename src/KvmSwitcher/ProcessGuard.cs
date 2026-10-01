using System.Diagnostics;

namespace KvmSwitcher;

internal static class ProcessGuard
{
    internal static bool IsVendorRunning() => IsVendorRunning(Exists);

    internal static bool IsVendorRunning(Func<string, bool> processExists) =>
        processExists("GamingIntelligence") || processExists("MonitorMicroKeyDetector");

    internal static bool Exists(string processName)
    {
        try
        {
            var processes = Process.GetProcessesByName(processName);
            try
            {
                return processes.Length != 0;
            }
            finally
            {
                foreach (var process in processes)
                {
                    process.Dispose();
                }
            }
        }
        catch
        {
            return true;
        }
    }
}
