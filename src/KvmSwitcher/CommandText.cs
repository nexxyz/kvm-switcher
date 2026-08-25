using System.Text;

namespace KvmSwitcher;

internal static class CommandText
{
    private const int MaxConfigBytes = 24 * 1024;
    private const string DebianInstallerUrl =
        "https://github.com/nexxyz/kvm-switcher/releases/latest/download/install-kvm-switcher.sh";
    private const string DebianFallbackGuidance =
        "Use tray Export Debian install bundle... to carry this configuration and run sh ./install.sh --apply-config.";

    internal static string ForTarget(Target target) =>
        "kvm-switch --profile " + ShellQuoting.SingleQuote(target.Name);

    internal static string ForDebianInstall(IReadOnlyList<Target> targets)
    {
        if (targets is null || targets.Count(target => target is not null && target.IsDefault) != 1)
        {
            throw new ConfigException("Exactly one default target is required for the Debian install command.");
        }

        var configBytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)
            .GetBytes(ConfigStore.Serialize(targets));
        if (configBytes.Length > MaxConfigBytes)
        {
            throw new ConfigException("Serialized configuration exceeds the 24 KiB Debian install command limit.");
        }

        var configBase64 = Convert.ToBase64String(configBytes);
        return
            "sh -c 'umask 077; dir=$(mktemp -d) || exit 1; trap \"rm -rf \\\"$dir\\\"\" 0; if ! printf \"%s\" \"$1\" | base64 -d > \"$dir/config.json\" || [ ! -s \"$dir/config.json\" ]; then printf \"%s\\n\" \"" +
            DebianFallbackGuidance +
            "\" >&2; exit 1; fi; if ! wget --https-only -T 30 -t 1 -O \"$dir/install.sh\" \"" +
            DebianInstallerUrl +
            "\" || [ ! -s \"$dir/install.sh\" ]; then printf \"%s\\n\" \"" +
            DebianFallbackGuidance +
            "\" >&2; exit 1; fi; sh \"$dir/install.sh\" --config \"$dir/config.json\"' sh '" +
            configBase64 +
            "'";
    }
}

internal static class ShellQuoting
{
    internal static string SingleQuote(string value) =>
        "'" + value.Replace("'", "'\"'\"'", StringComparison.Ordinal) + "'";
}
