using System.IO.Compression;
using System.Reflection;
using System.Text;

namespace KvmSwitcher;

internal static class PortableExporter
{
    private const int MaxSlugLength = 48;
    private const string ResourcePrefix = "KvmSwitcher.Linux.";

    internal static void Export(IReadOnlyList<Target> targets, Stream destination)
    {
        var configJson = ConfigStore.Serialize(targets);
        using var archive = new ZipArchive(destination, ZipArchiveMode.Create, leaveOpen: true);

        AddResource(archive, "kvmSwitcher.py", "kvmSwitcher.py");
        AddResource(archive, "pyproject.toml", "pyproject.toml");
        AddText(archive, "config.json", configJson);
        AddResource(archive, "requirements.txt", "requirements.txt");
        AddResource(archive, "install.sh", "install.sh");
        AddResource(archive, "README.md", "README.md");
        AddResource(archive, "LICENSE", "LICENSE");
        AddResource(archive, "udev/99-kvm-switcher.rules", "udev.99-kvm-switcher.rules");

        for (var index = 0; index < targets.Count; index++)
        {
            var target = targets[index];
            var fileName = CreateTargetFileName(target.Name, index);
            AddText(archive, "targets/" + fileName, BuildWrapper(target));
        }
    }

    internal static string Slug(string value)
    {
        var builder = new StringBuilder();
        var pendingDash = false;
        foreach (var character in value)
        {
            if ((character >= 'A' && character <= 'Z') ||
                (character >= 'a' && character <= 'z') ||
                (character >= '0' && character <= '9'))
            {
                if (pendingDash && builder.Length != 0)
                {
                    builder.Append('-');
                }

                builder.Append(char.ToLowerInvariant(character));
                pendingDash = false;
            }
            else
            {
                pendingDash = builder.Length != 0;
            }
        }

        var slug = builder.ToString().Trim('-');
        if (slug.Length > MaxSlugLength)
        {
            slug = slug[..MaxSlugLength].TrimEnd('-');
        }

        return slug.Length == 0 ? "target" : slug;
    }

    internal static string BuildWrapper(Target target)
    {
        var input = target.Input == TargetInput.Dp ? "dp" : "hdmi1";
        var kvm = target.Kvm == TargetKvm.Upstream ? "upstream" : "typec";
        return $"#!/bin/sh\nset -eu\n\nBUNDLE_DIR=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd -P)\nif [ -x \"$BUNDLE_DIR/.venv/bin/kvm-switch\" ]; then\n    exec \"$BUNDLE_DIR/.venv/bin/kvm-switch\" --input {input} --kvm {kvm}\nfi\nexec \"$HOME/.local/bin/kvm-switch\" --input {input} --kvm {kvm}\n";
    }

    private static string CreateTargetFileName(string name, int index)
    {
        var prefix = (index + 1).ToString("D2", System.Globalization.CultureInfo.InvariantCulture);
        return prefix + "-" + Slug(name) + ".sh";
    }

    private static void AddResource(ZipArchive archive, string entryName, string resourceName)
    {
        var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(
            resourceName == "LICENSE" ? "KvmSwitcher.License" : ResourcePrefix + resourceName)
            ?? throw new InvalidOperationException("Portable resource unavailable");
        using (resource)
        {
            var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
            using var stream = entry.Open();
            resource.CopyTo(stream);
        }
    }

    private static void AddText(ZipArchive archive, string entryName, string value)
    {
        var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
        using var stream = entry.Open();
        using var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        writer.Write(value);
    }
}
