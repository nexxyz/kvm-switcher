using System.IO.Compression;
using System.Text;
using KvmSwitcher;
using Xunit;

namespace KvmSwitcher.Tests;

public sealed class DefaultTargetTests
{
    [Fact]
    public void WithDefaultTarget_selects_zero_default_and_preserves_order_and_fields()
    {
        var source = new[]
        {
            ConfigStore.CreateTarget("First", TargetInput.Dp, TargetKvm.Upstream, "Ctrl+Shift+A"),
            ConfigStore.CreateTarget("Second", TargetInput.Hdmi1, TargetKvm.TypeC, null)
        };

        var updated = ConfigStore.WithDefaultTarget(source, "Second");

        Assert.Equal(new[] { "First", "Second" }, updated.Select(target => target.Name));
        Assert.False(updated[0].IsDefault);
        Assert.True(updated[1].IsDefault);
        Assert.Equal(source[0].Input, updated[0].Input);
        Assert.Equal(source[0].Kvm, updated[0].Kvm);
        Assert.Equal(source[0].Hotkey, updated[0].Hotkey);
        Assert.Equal(source[1].Input, updated[1].Input);
        Assert.Equal(source[1].Kvm, updated[1].Kvm);
        Assert.Equal(source[1].Hotkey, updated[1].Hotkey);
    }

    [Fact]
    public void WithDefaultTarget_switches_existing_default_and_clears_every_other_target()
    {
        var source = new[]
        {
            ConfigStore.CreateTarget("First", TargetInput.Dp, TargetKvm.Upstream, null, isDefault: true),
            ConfigStore.CreateTarget("Second", TargetInput.Hdmi1, TargetKvm.TypeC, null),
            ConfigStore.CreateTarget("Third", TargetInput.Dp, TargetKvm.TypeC, null)
        };

        var updated = ConfigStore.WithDefaultTarget(source, "Third");

        Assert.Equal(new[] { false, false, true }, updated.Select(target => target.IsDefault));
    }

    [Fact]
    public void WithDefaultTarget_requires_an_existing_target_and_serializes_into_exports()
    {
        var source = new[]
        {
            ConfigStore.CreateTarget("First", TargetInput.Dp, TargetKvm.Upstream, null),
            ConfigStore.CreateTarget("Second", TargetInput.Hdmi1, TargetKvm.TypeC, null)
        };

        Assert.Throws<ConfigException>(() => ConfigStore.WithDefaultTarget(source, "Missing"));

        var updated = ConfigStore.WithDefaultTarget(source, "First");
        var serialized = ConfigStore.Serialize(updated);
        Assert.Contains("\"default\": true", serialized, StringComparison.Ordinal);

        using var output = new MemoryStream();
        PortableExporter.Export(updated, output);
        output.Position = 0;
        using var archive = new ZipArchive(output, ZipArchiveMode.Read);
        using var reader = new StreamReader(archive.GetEntry("config.json")!.Open(), Encoding.UTF8);
        var exportedConfig = reader.ReadToEnd();
        Assert.Contains("\"default\": true", exportedConfig, StringComparison.Ordinal);
    }
}
