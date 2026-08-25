namespace KvmSwitcher;

internal static class CommandText
{
    private const string DebianInstallerUrl =
        "https://github.com/nexxyz/kvm-switcher/releases/latest/download/install-kvm-switcher.sh";
    private const string DebianBundleUrl =
        "https://github.com/nexxyz/kvm-switcher/releases/latest/download/kvm-switcher-debian.zip";

    internal static string ForTarget(Target target) =>
        "kvm-switch --profile " + ShellQuoting.SingleQuote(target.Name);

    internal static string ForDebianInstall() =>
        "sh -c 'f=$(mktemp) || exit 1; trap \"rm -f \\\"$f\\\"\" 0; if ! wget --https-only -T 30 -t 1 -O \"$f\" \"" +
        DebianInstallerUrl +
        "\" || [ ! -s \"$f\" ]; then printf \"%s\\n\" \"Download failed or empty; download the Debian bundle instead: " +
        DebianBundleUrl +
        "\" >&2; exit 1; fi; sh \"$f\"'";
}

internal static class ShellQuoting
{
    internal static string SingleQuote(string value) =>
        "'" + value.Replace("'", "'\"'\"'", StringComparison.Ordinal) + "'";
}
