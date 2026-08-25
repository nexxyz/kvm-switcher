using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Xunit;

namespace KvmSwitcher.Tests;

public sealed class ExporterTests
{
    [Fact]
    public void Export_contains_exact_canonical_entries_and_serialized_config()
    {
        var targets = new[]
        {
            ConfigStore.CreateTarget("Raspberry", TargetInput.Hdmi1, TargetKvm.TypeC, "Ctrl+Shift+Alt+P", isDefault: false),
            ConfigStore.CreateTarget("Windows", TargetInput.Dp, TargetKvm.Upstream, "Ctrl+Shift+Alt+W", isDefault: true)
        };

        using var output = Export(targets);
        using var archive = new ZipArchive(output, ZipArchiveMode.Read);
        var names = archive.Entries.Select(entry => entry.FullName).ToArray();

        Assert.Equal(
            new[]
            {
                "kvmSwitcher.py",
                "pyproject.toml",
                "config.json",
                "requirements.txt",
                "install.sh",
                "README.md",
                "LICENSE",
                "udev/99-kvm-switcher.rules",
                "targets/01-raspberry.sh",
                "targets/02-windows.sh"
            },
            names);

        var configJson = ReadEntry(archive, "config.json");
        Assert.Contains("Ctrl+Shift+Alt+P", configJson, StringComparison.Ordinal);
        Assert.DoesNotContain("\\u002B", configJson, StringComparison.OrdinalIgnoreCase);
        var config = JsonDocument.Parse(configJson);
        Assert.Equal("Ctrl+Shift+Alt+P", config.RootElement.GetProperty("targets")[0].GetProperty("hotkey").GetString());
        Assert.False(config.RootElement.GetProperty("targets")[0].GetProperty("default").GetBoolean());
        Assert.True(config.RootElement.GetProperty("targets")[1].GetProperty("default").GetBoolean());
        Assert.Contains("hid", ReadEntry(archive, "kvmSwitcher.py"), StringComparison.OrdinalIgnoreCase);
        Assert.Contains("MIT License", ReadEntry(archive, "LICENSE"), StringComparison.Ordinal);
    }

    [Fact]
    public void Export_uses_safe_slugs_and_fixed_direct_wrappers()
    {
        var targets = new[]
        {
            ConfigStore.CreateTarget("A/B", TargetInput.Dp, TargetKvm.Upstream, null),
            ConfigStore.CreateTarget("A B", TargetInput.Dp, TargetKvm.Upstream, null),
            ConfigStore.CreateTarget("O'Reilly / 日本", TargetInput.Hdmi1, TargetKvm.TypeC, null)
        };

        using var output = Export(targets);
        using var archive = new ZipArchive(output, ZipArchiveMode.Read);
        var names = archive.Entries.Select(entry => entry.FullName).ToArray();

        Assert.Contains("targets/01-a-b.sh", names);
        Assert.Contains("targets/02-a-b.sh", names);
        Assert.Contains("targets/03-o-reilly.sh", names);
        var wrapper = ReadEntry(archive, "targets/03-o-reilly.sh");
        Assert.Contains(".venv/bin/kvm-switch\" --input hdmi1 --kvm typec", wrapper, StringComparison.Ordinal);
        Assert.Contains("$HOME/.local/bin/kvm-switch\" --input hdmi1 --kvm typec", wrapper, StringComparison.Ordinal);
        Assert.DoesNotContain("command -v", wrapper, StringComparison.Ordinal);
        Assert.DoesNotContain("--profile", wrapper, StringComparison.Ordinal);
        Assert.DoesNotContain("config.json", wrapper, StringComparison.Ordinal);
        Assert.DoesNotContain("export PATH", wrapper, StringComparison.Ordinal);
        Assert.DoesNotContain("PATH=\"$HOME", wrapper, StringComparison.Ordinal);
        Assert.Contains("$(dirname -- \"$0\")/..", wrapper, StringComparison.Ordinal);
        Assert.DoesNotContain("O'Reilly", wrapper, StringComparison.Ordinal);
    }

    [Fact]
    public void Command_text_uses_safe_single_quote_shell_escaping()
    {
        var target = ConfigStore.CreateTarget("O'Reilly", TargetInput.Dp, TargetKvm.Upstream, null);

        Assert.Equal("'O'\"'\"'Reilly'", ShellQuoting.SingleQuote(target.Name));
        Assert.Equal("kvm-switch --profile 'O'\"'\"'Reilly'", CommandText.ForTarget(target));
    }

    [Fact]
    public void Debian_install_command_is_static_and_uses_failure_guidance()
    {
        var command = CommandText.ForDebianInstall();

        Assert.Equal(
            "sh -c 'f=$(mktemp) || exit 1; trap \"rm -f \\\"$f\\\"\" 0; if ! wget --https-only -T 30 -t 1 -O \"$f\" \"https://github.com/nexxyz/kvm-switcher/releases/latest/download/install-kvm-switcher.sh\" || [ ! -s \"$f\" ]; then printf \"%s\\n\" \"Download failed or empty; download the Debian bundle instead: https://github.com/nexxyz/kvm-switcher/releases/latest/download/kvm-switcher-debian.zip\" >&2; exit 1; fi; sh \"$f\"'",
            command);
        Assert.DoesNotContain("\n", command, StringComparison.Ordinal);
        Assert.DoesNotContain("\r", command, StringComparison.Ordinal);
        Assert.DoesNotContain("config.json", command, StringComparison.Ordinal);
        Assert.DoesNotContain("--profile", command, StringComparison.Ordinal);
        Assert.Contains("/releases/latest/download/", command, StringComparison.Ordinal);
        Assert.DoesNotMatch(@"/releases/download/|(?<![A-Za-z])v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?(?![A-Za-z])", command);
    }

    [Theory]
    [InlineData("日本", "target")]
    [InlineData("  -- /  ", "target")]
    [InlineData("A---B", "a-b")]
    public void Slugs_are_ascii_safe_and_bounded(string input, string expected)
    {
        Assert.Equal(expected, PortableExporter.Slug(input));
    }

    private static MemoryStream Export(IReadOnlyList<Target> targets)
    {
        var output = new MemoryStream();
        PortableExporter.Export(targets, output);
        output.Position = 0;
        return output;
    }

    private static string ReadEntry(ZipArchive archive, string name)
    {
        var entry = archive.GetEntry(name) ?? throw new InvalidOperationException(name);
        using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
        return reader.ReadToEnd();
    }
}
