using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Encodings.Web;

namespace KvmSwitcher;

internal sealed class ConfigException : Exception
{
    internal ConfigException(string message) : base(message)
    {
    }
}

internal sealed class ConfigStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    internal static string DefaultPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KvmSwitcher",
        "config.json");

    internal ConfigStore(string? path = null)
    {
        Path = path ?? DefaultPath;
    }

    internal string Path { get; }

    internal IReadOnlyList<Target> LoadOrCreateDefault()
    {
        if (!File.Exists(Path))
        {
            SaveAtomic(DefaultTargets, overwrite: false);
        }

        return Load();
    }

    internal IReadOnlyList<Target> Load()
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path));
            return Parse(document.RootElement);
        }
        catch (ConfigException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new ConfigException("Configuration error");
        }
    }

    internal void Save(IReadOnlyList<Target> targets) => SaveAtomic(targets, overwrite: true);

    internal static IReadOnlyList<Target> WithDefaultTarget(
        IReadOnlyList<Target> targets,
        string targetName)
    {
        if (targets is null || targetName is null)
        {
            throw new ConfigException("Configuration error");
        }

        ValidateTargets(targets);
        var matches = targets.Count(target => string.Equals(target.Name, targetName, StringComparison.Ordinal));
        if (matches != 1)
        {
            throw new ConfigException("Configuration error");
        }

        var updated = targets
            .Select(target => Target.FromValidated(
                target.Name,
                target.Input,
                target.Kvm,
                target.Hotkey,
                string.Equals(target.Name, targetName, StringComparison.Ordinal)))
            .ToArray();
        ValidateTargets(updated);
        return updated;
    }

    internal void EnsureExists()
    {
        if (!File.Exists(Path))
        {
            SaveAtomic(DefaultTargets, overwrite: false);
        }
    }

    internal static string Serialize(IReadOnlyList<Target> targets)
    {
        ValidateTargets(targets);
        var value = new SerializedConfig
        {
            Targets = targets.Select(target => new SerializedTarget
            {
                Name = target.Name,
                Input = target.Input == TargetInput.Dp ? "dp" : "hdmi1",
                Kvm = target.Kvm == TargetKvm.Upstream ? "upstream" : "typec",
                Hotkey = target.Hotkey?.Display,
                IsDefault = target.IsDefault
            }).ToList()
        };
        return JsonSerializer.Serialize(value, SerializerOptions);
    }

    internal static Target CreateTarget(string name, TargetInput input, TargetKvm kvm, string? hotkey, bool isDefault = false)
    {
        var normalizedName = ValidateName(name);
        if (input is not (TargetInput.Dp or TargetInput.Hdmi1) ||
            kvm is not (TargetKvm.Upstream or TargetKvm.TypeC))
        {
            throw new ConfigException("Configuration error");
        }

        HotkeySpec? normalizedHotkey = null;
        if (hotkey is not null)
        {
            try
            {
                normalizedHotkey = HotkeyParser.Parse(hotkey);
            }
            catch (HotkeyFormatException)
            {
                throw new ConfigException("Configuration error");
            }
        }

        return Target.FromValidated(normalizedName, input, kvm, normalizedHotkey, isDefault);
    }

    internal static IReadOnlyList<Target> DefaultTargets =>
    [
        CreateTarget("Raspberry", TargetInput.Hdmi1, TargetKvm.TypeC, "Ctrl+Shift+Alt+P", isDefault: false),
        CreateTarget("Windows", TargetInput.Dp, TargetKvm.Upstream, "Ctrl+Shift+Alt+W", isDefault: true)
    ];

    private void SaveAtomic(IReadOnlyList<Target> targets, bool overwrite)
    {
        var directory = System.IO.Path.GetDirectoryName(Path);
        if (string.IsNullOrEmpty(directory))
        {
            throw new ConfigException("Configuration error");
        }

        Directory.CreateDirectory(directory);
        var temporaryPath = System.IO.Path.Combine(
            directory,
            $".{System.IO.Path.GetFileName(Path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            var json = Serialize(targets);
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
            {
                writer.Write(json);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, Path, overwrite);
        }
        catch (ConfigException)
        {
            TryDelete(temporaryPath);
            throw;
        }
        catch (Exception)
        {
            TryDelete(temporaryPath);
            throw new ConfigException("Configuration error");
        }
    }

    private static IReadOnlyList<Target> Parse(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new ConfigException("Configuration error");
        }

        var rootProperties = root.EnumerateObject().ToArray();
        if (rootProperties.Length != 1 || rootProperties[0].Name != "targets" ||
            rootProperties[0].Value.ValueKind != JsonValueKind.Array)
        {
            throw new ConfigException("Configuration error");
        }

        var targets = rootProperties[0].Value.EnumerateArray().Select(ParseTarget).ToList();
        if (targets.Count == 0)
        {
            throw new ConfigException("Configuration error");
        }

        ValidateTargets(targets);
        return targets;
    }

    private static Target ParseTarget(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new ConfigException("Configuration error");
        }

        var properties = value.EnumerateObject().ToArray();
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in properties)
        {
            if (!names.Add(property.Name) || property.Name is not ("name" or "input" or "kvm" or "hotkey" or "default"))
            {
                throw new ConfigException("Configuration error");
            }
        }

        var name = GetRequiredString(value, "name");
        var input = GetRequiredString(value, "input");
        var kvm = GetRequiredString(value, "kvm");
        string? hotkey = null;
        var isDefault = false;
        if (value.TryGetProperty("hotkey", out var hotkeyElement))
        {
            if (hotkeyElement.ValueKind != JsonValueKind.String)
            {
                throw new ConfigException("Configuration error");
            }

            hotkey = hotkeyElement.GetString();
        }
        if (value.TryGetProperty("default", out var defaultElement))
        {
            if (defaultElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            {
                throw new ConfigException("Configuration error");
            }

            isDefault = defaultElement.GetBoolean();
        }

        var normalizedInput = input.ToUpperInvariant() switch
        {
            "DP" => TargetInput.Dp,
            "HDMI1" => TargetInput.Hdmi1,
            _ => throw new ConfigException("Configuration error")
        };
        var normalizedKvm = kvm.ToUpperInvariant() switch
        {
            "UPSTREAM" => TargetKvm.Upstream,
            "TYPEC" => TargetKvm.TypeC,
            _ => throw new ConfigException("Configuration error")
        };

        return CreateTarget(name, normalizedInput, normalizedKvm, hotkey, isDefault);
    }

    private static string GetRequiredString(JsonElement value, string propertyName)
    {
        if (!value.TryGetProperty(propertyName, out var element) || element.ValueKind != JsonValueKind.String)
        {
            throw new ConfigException("Configuration error");
        }

        return element.GetString() ?? throw new ConfigException("Configuration error");
    }

    private static void ValidateTargets(IReadOnlyList<Target> targets)
    {
        if (targets is null || targets.Count == 0 || targets.Any(target => target is null))
        {
            throw new ConfigException("Configuration error");
        }

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var hotkeys = new HashSet<(uint Modifiers, uint VirtualKey)>();
        var defaultCount = 0;
        foreach (var target in targets)
        {
            var name = ValidateName(target.Name);
            if (!names.Add(name))
            {
                throw new ConfigException("Configuration error");
            }

            if (target.Hotkey is { } hotkey && !hotkeys.Add((hotkey.Modifiers, hotkey.VirtualKey)))
            {
                throw new ConfigException("Configuration error");
            }

            if (target.IsDefault)
            {
                defaultCount++;
                if (defaultCount > 1)
                {
                    throw new ConfigException("Configuration error");
                }
            }
        }
    }

    private static string ValidateName(string value)
    {
        if (value.Any(char.IsControl))
        {
            throw new ConfigException("Configuration error");
        }

        var name = value.Trim();
        if (name.Length == 0 || name.Length > 64)
        {
            throw new ConfigException("Configuration error");
        }

        return name;
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
        }
    }

    private sealed class SerializedConfig
    {
        [JsonPropertyName("targets")]
        public List<SerializedTarget> Targets { get; set; } = [];
    }

    private sealed class SerializedTarget
    {
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        [JsonPropertyName("input")]
        public string Input { get; set; } = string.Empty;

        [JsonPropertyName("kvm")]
        public string Kvm { get; set; } = string.Empty;

        [JsonPropertyName("hotkey")]
        public string? Hotkey { get; set; }

        [JsonPropertyName("default")]
        public bool IsDefault { get; set; }
    }
}
