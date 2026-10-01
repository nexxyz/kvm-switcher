using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Encodings.Web;

namespace KvmSwitcher;

internal sealed class ConfigException : Exception
{
    internal ConfigException(string message) : base(message)
    {
    }

    internal static ConfigException Invalid(string detail) => new("Configuration error: " + detail);
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
        EnsureExists();
        return Load();
    }

    internal IReadOnlyList<Target> Load()
    {
        string json;
        try
        {
            json = File.ReadAllText(Path);
        }
        catch (Exception exception)
        {
            throw ConfigException.Invalid("cannot read file (" + exception.Message + ")");
        }

        try
        {
            using var document = JsonDocument.Parse(json);
            return Parse(document.RootElement);
        }
        catch (JsonException exception)
        {
            throw ConfigException.Invalid("invalid JSON (" + exception.Message + ")");
        }
    }

    internal void Save(IReadOnlyList<Target> targets) => SaveAtomic(targets, overwrite: true);

    internal static IReadOnlyList<Target> WithDefaultTarget(
        IReadOnlyList<Target> targets,
        string targetName)
    {
        if (targets is null || targetName is null)
        {
            throw ConfigException.Invalid("no targets loaded");
        }

        ValidateTargets(targets);
        var matches = targets.Count(target => string.Equals(target.Name, targetName, StringComparison.Ordinal));
        if (matches != 1)
        {
            throw ConfigException.Invalid($"target '{targetName}' was not found");
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
            throw ConfigException.Invalid($"target '{normalizedName}' has an unsupported input or kvm");
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
                throw ConfigException.Invalid(
                    $"target '{normalizedName}' hotkey '{hotkey}' is invalid; use at least two of Ctrl, Shift, Alt, Win plus one A-Z, 0-9 or F1-F24 key");
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
            throw ConfigException.Invalid("invalid configuration path");
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
        catch (Exception exception)
        {
            TryDelete(temporaryPath);
            throw ConfigException.Invalid("cannot write file (" + exception.Message + ")");
        }
    }

    private static IReadOnlyList<Target> Parse(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw ConfigException.Invalid("root must be a JSON object");
        }

        var rootProperties = root.EnumerateObject().ToArray();
        if (rootProperties.Length != 1 || rootProperties[0].Name != "targets" ||
            rootProperties[0].Value.ValueKind != JsonValueKind.Array)
        {
            throw ConfigException.Invalid("root must contain only a \"targets\" array");
        }

        var targets = rootProperties[0].Value.EnumerateArray().Select(ParseTarget).ToList();
        if (targets.Count == 0)
        {
            throw ConfigException.Invalid("targets must not be empty");
        }

        ValidateTargets(targets);
        return targets;
    }

    private static Target ParseTarget(JsonElement value, int index)
    {
        var label = $"target {index + 1}";
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw ConfigException.Invalid(label + " must be a JSON object");
        }

        var properties = value.EnumerateObject().ToArray();
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in properties)
        {
            if (!names.Add(property.Name))
            {
                throw ConfigException.Invalid($"{label} has duplicate property \"{property.Name}\"");
            }

            if (property.Name is not ("name" or "input" or "kvm" or "hotkey" or "default"))
            {
                throw ConfigException.Invalid($"{label} has unknown property \"{property.Name}\"");
            }
        }

        var name = GetRequiredString(value, "name", label);
        var input = GetRequiredString(value, "input", label);
        var kvm = GetRequiredString(value, "kvm", label);
        string? hotkey = null;
        var isDefault = false;
        if (value.TryGetProperty("hotkey", out var hotkeyElement))
        {
            if (hotkeyElement.ValueKind != JsonValueKind.String)
            {
                throw ConfigException.Invalid(label + " hotkey must be a string");
            }

            hotkey = hotkeyElement.GetString();
        }
        if (value.TryGetProperty("default", out var defaultElement))
        {
            if (defaultElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            {
                throw ConfigException.Invalid(label + " default must be true or false");
            }

            isDefault = defaultElement.GetBoolean();
        }

        var normalizedInput = input.ToUpperInvariant() switch
        {
            "DP" => TargetInput.Dp,
            "HDMI1" => TargetInput.Hdmi1,
            _ => throw ConfigException.Invalid(label + " input must be \"dp\" or \"hdmi1\"")
        };
        var normalizedKvm = kvm.ToUpperInvariant() switch
        {
            "UPSTREAM" => TargetKvm.Upstream,
            "TYPEC" => TargetKvm.TypeC,
            _ => throw ConfigException.Invalid(label + " kvm must be \"upstream\" or \"typec\"")
        };

        return CreateTarget(name, normalizedInput, normalizedKvm, hotkey, isDefault);
    }

    private static string GetRequiredString(JsonElement value, string propertyName, string label)
    {
        if (!value.TryGetProperty(propertyName, out var element) || element.ValueKind != JsonValueKind.String)
        {
            throw ConfigException.Invalid($"{label} requires a string \"{propertyName}\"");
        }

        return element.GetString()!;
    }

    private static void ValidateTargets(IReadOnlyList<Target> targets)
    {
        if (targets is null || targets.Count == 0 || targets.Any(target => target is null))
        {
            throw ConfigException.Invalid("targets must not be empty");
        }

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var hotkeys = new HashSet<(uint Modifiers, uint VirtualKey)>();
        var defaultCount = 0;
        foreach (var target in targets)
        {
            var name = ValidateName(target.Name);
            if (!names.Add(name))
            {
                throw ConfigException.Invalid($"target name '{name}' is used more than once");
            }

            if (target.Hotkey is { } hotkey && !hotkeys.Add((hotkey.Modifiers, hotkey.VirtualKey)))
            {
                throw ConfigException.Invalid($"hotkey {hotkey.Display} is used more than once");
            }

            if (target.IsDefault)
            {
                defaultCount++;
                if (defaultCount > 1)
                {
                    throw ConfigException.Invalid("only one target may have \"default\": true");
                }
            }
        }
    }

    private static string ValidateName(string value)
    {
        if (value.Any(char.IsControl))
        {
            throw ConfigException.Invalid("target names must not contain control characters");
        }

        var name = value.Trim();
        if (name.Length == 0 || name.Length > 64)
        {
            throw ConfigException.Invalid("target names must be 1 to 64 characters");
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
