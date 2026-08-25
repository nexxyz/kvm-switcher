using Microsoft.Win32;

namespace KvmSwitcher;

internal static class StartupManager
{
    private const string RunSubKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    private const string ValueName = "KvmSwitcher";

    internal static string ValueDataFor(string executablePath) => $"\"{executablePath}\"";

    internal static bool ValueMatches(string? value, string executablePath) =>
        string.Equals(value, ValueDataFor(executablePath), StringComparison.OrdinalIgnoreCase);

    internal static bool IsEnabled(string executablePath)
    {
        using var runKey = Registry.CurrentUser.OpenSubKey(RunSubKey, writable: false);
        return ValueMatches(runKey?.GetValue(ValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string, executablePath);
    }

    internal static void SetEnabled(bool enabled, string executablePath)
    {
        using var runKey = Registry.CurrentUser.CreateSubKey(RunSubKey, writable: true)
            ?? throw new InvalidOperationException("Unable to open startup settings");

        if (enabled)
        {
            runKey.SetValue(ValueName, ValueDataFor(executablePath), RegistryValueKind.String);
        }
        else
        {
            runKey.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
