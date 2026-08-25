using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace KvmSwitcher.Tests;

public sealed class DebianBundleTests
{
    [Fact]
    public void Export_has_exact_six_entries()
    {
        var targets = Targets();
        var package = Encoding.ASCII.GetBytes("private deb payload");
        using var output = new MemoryStream();

        DebianBundleExporter.Export(targets, output, new MemoryStream(package));
        output.Position = 0;
        using var archive = new ZipArchive(output, ZipArchiveMode.Read);

        Assert.Equal(
            new[]
            {
                "kvm-switcher_0.8.2-1_all.deb",
                "config.json",
                "install.sh",
                "README.md",
                "LICENSE",
                "SHA256SUMS"
            },
            archive.Entries.Select(entry => entry.FullName));
        Assert.DoesNotContain(archive.Entries, entry => entry.FullName.Contains("target", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(archive.Entries, entry => entry.FullName.Contains("venv", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(archive.Entries, entry => entry.FullName.Contains("kvmSwitcher.py", StringComparison.Ordinal));
    }

    [Fact]
    public void Export_contains_readable_config_and_matching_hash_manifest()
    {
        var targets = Targets();
        var package = Encoding.ASCII.GetBytes("private deb payload");
        var config = Encoding.UTF8.GetBytes(ConfigStore.Serialize(targets));
        using var output = new MemoryStream();

        DebianBundleExporter.Export(targets, output, new MemoryStream(package));
        output.Position = 0;
        using var archive = new ZipArchive(output, ZipArchiveMode.Read);
        var configText = ReadEntry(archive, "config.json");
        var manifest = ReadEntry(archive, "SHA256SUMS");
        using var configDocument = System.Text.Json.JsonDocument.Parse(configText);

        Assert.Contains("Ctrl+Shift+Alt+P", configText, StringComparison.Ordinal);
        Assert.DoesNotContain("\\u002B", configText, StringComparison.OrdinalIgnoreCase);
        Assert.False(configDocument.RootElement.GetProperty("targets")[0].GetProperty("default").GetBoolean());
        Assert.True(configDocument.RootElement.GetProperty("targets")[1].GetProperty("default").GetBoolean());
        Assert.Equal(
            string.Concat(
                Convert.ToHexString(SHA256.HashData(package)).ToLowerInvariant(),
                "  kvm-switcher_0.8.2-1_all.deb\n",
                Convert.ToHexString(SHA256.HashData(config)).ToLowerInvariant(),
                "  config.json\n"),
            manifest);
        Assert.StartsWith("#!/bin/sh", ReadEntry(archive, "install.sh"), StringComparison.Ordinal);
        Assert.Contains("Debian", ReadEntry(archive, "README.md"), StringComparison.Ordinal);
        Assert.Contains("MIT License", ReadEntry(archive, "LICENSE"), StringComparison.Ordinal);
    }

    [Fact]
    public void Missing_or_empty_package_is_unavailable_and_export_fails_closed()
    {
        using var directory = new TemporaryDirectory();
        var missing = System.IO.Path.Combine(directory.Path, "missing.deb");
        var empty = System.IO.Path.Combine(directory.Path, "empty.deb");
        File.WriteAllBytes(empty, Array.Empty<byte>());

        Assert.False(DebianBundleExporter.IsPackageAvailableAt(missing));
        Assert.False(DebianBundleExporter.IsPackageAvailableAt(empty));
        using var output = new MemoryStream();
        Assert.Throws<InvalidOperationException>(() =>
            DebianBundleExporter.Export(Targets(), output, new MemoryStream()));
    }

    private static IReadOnlyList<Target> Targets() =>
    [
        ConfigStore.CreateTarget("Raspberry", TargetInput.Hdmi1, TargetKvm.TypeC, "Ctrl+Shift+Alt+P", isDefault: false),
        ConfigStore.CreateTarget("Windows", TargetInput.Dp, TargetKvm.Upstream, "Ctrl+Shift+Alt+W", isDefault: true)
    ];

    private static string ReadEntry(ZipArchive archive, string name)
    {
        var entry = archive.GetEntry(name) ?? throw new InvalidOperationException(name);
        using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        internal TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "KvmSwitcherDebianBundleTests", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        internal string Path { get; }

        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
