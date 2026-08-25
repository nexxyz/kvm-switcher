using System.Text.Json;
using Xunit;

namespace KvmSwitcher.Tests;

public sealed class ConfigAndHotkeyTests
{
    [Fact]
    public void Missing_config_creates_the_canonical_default()
    {
        using var directory = new TemporaryDirectory();
        var path = System.IO.Path.Combine(directory.Path, "config.json");

        var targets = new ConfigStore(path).LoadOrCreateDefault();

        Assert.True(File.Exists(path));
        Assert.Equal(new[] { "Raspberry", "Windows" }, targets.Select(target => target.Name));
        Assert.Equal("Ctrl+Shift+Alt+P", targets[0].Hotkey?.Display);
        Assert.False(targets[0].IsDefault);
        Assert.True(targets[1].IsDefault);
        var json = File.ReadAllText(path);
        Assert.Contains("Ctrl+Shift+Alt+P", json, StringComparison.Ordinal);
        Assert.Contains("\"default\": false", json, StringComparison.Ordinal);
        Assert.Contains("\"default\": true", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\\u002B", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Config_round_trips_normalized_targets_and_optional_hotkey()
    {
        using var directory = new TemporaryDirectory();
        var path = System.IO.Path.Combine(directory.Path, "config.json");
        var original = new[]
        {
            ConfigStore.CreateTarget(" Laptop ", TargetInput.Dp, TargetKvm.Upstream, "alt+ctrl+shift+w"),
            ConfigStore.CreateTarget("Quote \" and \\ path", TargetInput.Hdmi1, TargetKvm.TypeC, null)
        };
        var store = new ConfigStore(path);

        store.Save(original);
        var loaded = store.Load();

        Assert.Equal("Laptop", loaded[0].Name);
        Assert.Equal(TargetInput.Dp, loaded[0].Input);
        Assert.Equal(TargetKvm.Upstream, loaded[0].Kvm);
        Assert.Equal("Ctrl+Shift+Alt+W", loaded[0].Hotkey?.Display);
        Assert.Equal("Quote \" and \\ path", loaded[1].Name);
        Assert.False(loaded[0].IsDefault);
        Assert.False(loaded[1].IsDefault);
        var json = File.ReadAllText(path);
        Assert.Contains("Ctrl+Shift+Alt+W", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\\u002B", json, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("\\\"", json, StringComparison.Ordinal);
        Assert.Contains("\\\\", json, StringComparison.Ordinal);
        using var document = JsonDocument.Parse(json);
        Assert.Equal("dp", document.RootElement.GetProperty("targets")[0].GetProperty("input").GetString());
        Assert.False(document.RootElement.GetProperty("targets")[0].GetProperty("default").GetBoolean());
    }

    [Fact]
    public void Explicit_default_flags_round_trip_and_missing_flag_is_false()
    {
        using var directory = new TemporaryDirectory();
        var path = System.IO.Path.Combine(directory.Path, "config.json");
        var store = new ConfigStore(path);
        var json = "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\",\"default\":true},{\"name\":\"B\",\"input\":\"hdmi1\",\"kvm\":\"typec\",\"default\":false}]}";

        var loaded = WriteAndLoad(store, json);

        Assert.True(loaded[0].IsDefault);
        Assert.False(loaded[1].IsDefault);
        var serialized = ConfigStore.Serialize(loaded);
        Assert.Contains("\"default\": true", serialized, StringComparison.Ordinal);
        Assert.Contains("\"default\": false", serialized, StringComparison.Ordinal);

        var legacy = WriteAndLoad(store, "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\"}]}");
        Assert.False(legacy[0].IsDefault);
    }

    [Fact]
    public void Invalid_default_values_multiple_defaults_and_duplicate_properties_are_rejected()
    {
        using var directory = new TemporaryDirectory();
        var store = new ConfigStore(System.IO.Path.Combine(directory.Path, "config.json"));
        var invalidDefaults = new[] { "null", "\"yes\"", "1", "{}", "[]" };

        foreach (var value in invalidDefaults)
        {
            Assert.Throws<ConfigException>(() => WriteAndLoad(
                store,
                $"{{\"targets\":[{{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\",\"default\":{value}}}]}}"));
        }

        Assert.Throws<ConfigException>(() => WriteAndLoad(
            store,
            "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\",\"default\":true},{\"name\":\"B\",\"input\":\"hdmi1\",\"kvm\":\"typec\",\"default\":true}]}"));
        Assert.Throws<ConfigException>(() => WriteAndLoad(
            store,
            "{\"targets\":[{\"name\":\"A\",\"name\":\"B\",\"input\":\"dp\",\"kvm\":\"upstream\"}]}"));
        Assert.Throws<ConfigException>(() => WriteAndLoad(
            store,
            "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\",\"default\":false,\"default\":true}]}"));
    }

    [Fact]
    public void Unknown_root_and_target_properties_are_rejected()
    {
        using var directory = new TemporaryDirectory();
        var store = new ConfigStore(System.IO.Path.Combine(directory.Path, "config.json"));

        Assert.Throws<ConfigException>(() => WriteAndLoad(store, "{\"targets\":[],\"extra\":true}"));
        Assert.Throws<ConfigException>(() => WriteAndLoad(store, "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\",\"extra\":1}]}"));
    }

    [Theory]
    [InlineData("", "dp", "upstream")]
    [InlineData("A", "vga", "upstream")]
    [InlineData("A", "dp", "usb")]
    public void Invalid_required_values_are_rejected(string name, string input, string kvm)
    {
        using var directory = new TemporaryDirectory();
        var store = new ConfigStore(System.IO.Path.Combine(directory.Path, "config.json"));
        var json = $"{{\"targets\":[{{\"name\":{JsonSerializer.Serialize(name)},\"input\":{JsonSerializer.Serialize(input)},\"kvm\":{JsonSerializer.Serialize(kvm)}}}]}}";

        Assert.Throws<ConfigException>(() => WriteAndLoad(store, json));
    }

    [Fact]
    public void Duplicate_names_and_hotkeys_are_rejected_case_insensitively()
    {
        using var directory = new TemporaryDirectory();
        var store = new ConfigStore(System.IO.Path.Combine(directory.Path, "config.json"));
        var duplicateNames = "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\"},{\"name\":\" a \",\"input\":\"dp\",\"kvm\":\"typec\"}]}";
        var duplicateHotkeys = "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\",\"kvm\":\"upstream\",\"hotkey\":\"Ctrl+Shift+A\"},{\"name\":\"B\",\"input\":\"dp\",\"kvm\":\"typec\",\"hotkey\":\"shift+ctrl+a\"}]}";

        Assert.Throws<ConfigException>(() => WriteAndLoad(store, duplicateNames));
        Assert.Throws<ConfigException>(() => WriteAndLoad(store, duplicateHotkeys));
    }

    [Fact]
    public void Names_with_controls_and_missing_required_properties_are_rejected()
    {
        using var directory = new TemporaryDirectory();
        var store = new ConfigStore(System.IO.Path.Combine(directory.Path, "config.json"));

        Assert.Throws<ConfigException>(() => WriteAndLoad(store, "{\"targets\":[]}"));
        Assert.Throws<ConfigException>(() => WriteAndLoad(store, "{\"targets\":[{\"name\":\"A\\nB\",\"input\":\"dp\",\"kvm\":\"upstream\"}]}"));
        var longName = new string('A', 65);
        Assert.Throws<ConfigException>(() => WriteAndLoad(store, $"{{\"targets\":[{{\"name\":{JsonSerializer.Serialize(longName)},\"input\":\"dp\",\"kvm\":\"upstream\"}}]}}"));
        Assert.Throws<ConfigException>(() => WriteAndLoad(store, "{\"targets\":[{\"name\":\"A\",\"input\":\"dp\"}]}"));
    }

    [Theory]
    [InlineData("alt+ctrl+shift+p", "Ctrl+Shift+Alt+P")]
    [InlineData("WIN+CTRL+F24", "Ctrl+Win+F24")]
    [InlineData("ctrl+shift+7", "Ctrl+Shift+7")]
    public void Hotkeys_parse_and_normalize(string value, string display)
    {
        Assert.True(HotkeyParser.TryParse(value, out var result));
        Assert.Equal(display, result.Display);
    }

    [Theory]
    [InlineData("Ctrl+P")]
    [InlineData("Ctrl+Shift+Ctrl+P")]
    [InlineData("Ctrl+Shift+Alt+F25")]
    [InlineData("Ctrl+Shift+Home")]
    [InlineData("Ctrl+Shift+")]
    [InlineData("Ctrl + Shift + A")]
    public void Invalid_hotkey_grammar_is_rejected(string value)
    {
        Assert.False(HotkeyParser.TryParse(value, out _));
    }

    private static IReadOnlyList<Target> WriteAndLoad(ConfigStore store, string json)
    {
        File.WriteAllText(store.Path, json);
        return store.Load();
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        internal TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "KvmSwitcherTests", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        internal string Path { get; }

        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
