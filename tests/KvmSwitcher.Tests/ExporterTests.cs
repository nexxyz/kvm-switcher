using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
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
    public void Debian_install_command_availability_requires_one_default_and_idle_state()
    {
        var noDefault = new[]
        {
            ConfigStore.CreateTarget("One", TargetInput.Hdmi1, TargetKvm.TypeC, null)
        };
        var oneDefault = new[]
        {
            ConfigStore.CreateTarget("One", TargetInput.Hdmi1, TargetKvm.TypeC, null, isDefault: true)
        };
        var twoDefaults = new[]
        {
            ConfigStore.CreateTarget("One", TargetInput.Hdmi1, TargetKvm.TypeC, null, isDefault: true),
            ConfigStore.CreateTarget("Two", TargetInput.Dp, TargetKvm.Upstream, null, isDefault: true)
        };

        Assert.False(TrayApp.CanCopyDebianInstallCommand(false, null));
        Assert.False(TrayApp.CanCopyDebianInstallCommand(false, noDefault));
        Assert.False(TrayApp.CanCopyDebianInstallCommand(false, twoDefaults));
        Assert.True(TrayApp.CanCopyDebianInstallCommand(false, oneDefault));
        Assert.False(TrayApp.CanCopyDebianInstallCommand(true, oneDefault));
    }

    [Fact]
    public void Debian_install_command_is_one_line_and_carries_exact_utf8_config()
    {
        var targets = new[]
        {
            ConfigStore.CreateTarget("O'Reilly 日本", TargetInput.Hdmi1, TargetKvm.TypeC, "Ctrl+Shift+Alt+P", isDefault: false),
            ConfigStore.CreateTarget("Windows Δ", TargetInput.Dp, TargetKvm.Upstream, "Ctrl+Shift+Alt+W", isDefault: true)
        };
        var serialized = ConfigStore.Serialize(targets);
        var command = CommandText.ForDebianInstall(targets);
        var payload = ExtractPayload(command);

        Assert.StartsWith("sh -c 'umask 077; dir=$(mktemp -d)", command, StringComparison.Ordinal);
        Assert.DoesNotContain("\n", command, StringComparison.Ordinal);
        Assert.DoesNotContain("\r", command, StringComparison.Ordinal);
        Assert.Contains("trap \"rm -rf \\\"$dir\\\"\" 0", command, StringComparison.Ordinal);
        Assert.Contains("base64 -d", command, StringComparison.Ordinal);
        Assert.Contains("[ ! -s \"$dir/config.json\" ]", command, StringComparison.Ordinal);
        Assert.Contains("wget --https-only -T 30 -t 1 -O \"$dir/install.sh\" \"https://github.com/nexxyz/kvm-switcher/releases/latest/download/install-kvm-switcher.sh\"", command, StringComparison.Ordinal);
        Assert.Contains("sh \"$dir/install.sh\" --config \"$dir/config.json\"", command, StringComparison.Ordinal);
        Assert.Contains("Export Debian install bundle...", command, StringComparison.Ordinal);
        Assert.Contains("sh ./install.sh --apply-config", command, StringComparison.Ordinal);
        Assert.Contains("/releases/latest/download/", command, StringComparison.Ordinal);
        Assert.DoesNotMatch(@"/releases/download/|(?<![A-Za-z])v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?(?![A-Za-z])", command);
        Assert.DoesNotContain(serialized, command, StringComparison.Ordinal);
        Assert.DoesNotContain("O'Reilly", command, StringComparison.Ordinal);
        Assert.DoesNotContain("日本", command, StringComparison.Ordinal);
        Assert.DoesNotContain("Windows Δ", command, StringComparison.Ordinal);
        Assert.DoesNotContain("kvm-switch --profile", command, StringComparison.Ordinal);
        Assert.Equal(
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(serialized),
            Convert.FromBase64String(payload));
    }

    [Fact]
    public void Debian_install_command_payload_changes_after_config_save_and_reload()
    {
        var targets = new[]
        {
            ConfigStore.CreateTarget("One", TargetInput.Hdmi1, TargetKvm.TypeC, null, isDefault: false),
            ConfigStore.CreateTarget("Two", TargetInput.Dp, TargetKvm.Upstream, null, isDefault: true)
        };
        using var directory = new TemporaryDirectory();
        var store = new ConfigStore(Path.Combine(directory.Path, "config.json"));
        store.Save(targets);
        var initial = store.Load();
        var changed = ConfigStore.WithDefaultTarget(initial, "One");
        store.Save(changed);
        var reloaded = store.Load();

        Assert.NotEqual(
            ExtractPayload(CommandText.ForDebianInstall(initial)),
            ExtractPayload(CommandText.ForDebianInstall(reloaded)));
    }

    [Fact]
    public void Debian_install_command_rejects_zero_defaults()
    {
        var targets = new[]
        {
            ConfigStore.CreateTarget("One", TargetInput.Hdmi1, TargetKvm.TypeC, null)
        };

        var exception = Assert.Throws<ConfigException>(() => CommandText.ForDebianInstall(targets));

        Assert.Contains("exactly one default", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Debian_install_command_rejects_config_over_24_kibibytes()
    {
        var targets = Enumerable.Range(0, 400)
            .Select(index => ConfigStore.CreateTarget(
                "Target " + index,
                TargetInput.Hdmi1,
                TargetKvm.TypeC,
                null,
                isDefault: index == 0))
            .ToArray();

        var exception = Assert.Throws<ConfigException>(() => CommandText.ForDebianInstall(targets));

        Assert.Contains("24 KiB", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Debian_install_command_runs_through_real_posix_shell_without_network()
    {
        using var fixture = new ShellFixture();
        var targets = new[]
        {
            ConfigStore.CreateTarget("O'Reilly 日本", TargetInput.Hdmi1, TargetKvm.TypeC, "Ctrl+Shift+Alt+P", isDefault: false),
            ConfigStore.CreateTarget("Windows Δ", TargetInput.Dp, TargetKvm.Upstream, "Ctrl+Shift+Alt+W", isDefault: true)
        };
        var expectedBytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)
            .GetBytes(ConfigStore.Serialize(targets));
        var command = CommandText.ForDebianInstall(targets);

        fixture.WriteFakeWget();
        fixture.MakeExecutable(fixture.FakeWgetPath);
        var result = fixture.Run(command);

        Assert.True(
            result.ExitCode == 0,
            $"POSIX command failed with exit code {result.ExitCode}. stdout: {result.Stdout} stderr: {result.Stderr}");
        Assert.Equal(expectedBytes, File.ReadAllBytes(fixture.ConfigBytesEvidencePath));
        var handedConfigPath = File.ReadAllText(fixture.ConfigPathEvidencePath);
        Assert.EndsWith("/config.json", handedConfigPath.Replace('\\', '/'), StringComparison.Ordinal);
        var cleanup = fixture.CheckPathDoesNotExist(handedConfigPath);
        Assert.True(
            cleanup.ExitCode == 0,
            $"The command temp directory was not cleaned up. stdout: {cleanup.Stdout} stderr: {cleanup.Stderr}");
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

    private static string ExtractPayload(string command)
    {
        var match = Regex.Match(command, @"' sh '([A-Za-z0-9+/=]+)'$");
        Assert.True(match.Success, "The Debian install command did not contain a positional base64 payload.");
        return match.Groups[1].Value;
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        internal TemporaryDirectory()
        {
            Path = Directory.CreateTempSubdirectory("KvmSwitcherCommandTests").FullName;
        }

        internal string Path { get; }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, recursive: true);
            }
            catch
            {
            }
        }
    }

    private sealed class ShellFixture : IDisposable
    {
        private const string FakeWgetRelativePath = "fake-bin/wget";
        private const string ConfigPathEvidenceFile = "config-path.txt";
        private const string ConfigBytesEvidenceFile = "config-bytes.bin";
        private readonly TemporaryDirectory _directory = new();
        private readonly string _shellPath;

        internal ShellFixture()
        {
            _shellPath = LocatePosixShell();
            Directory.CreateDirectory(System.IO.Path.Combine(_directory.Path, "fake-bin"));
        }

        internal string FakeWgetPath => System.IO.Path.Combine(_directory.Path, FakeWgetRelativePath.Replace('/', System.IO.Path.DirectorySeparatorChar));

        internal string ConfigPathEvidencePath => System.IO.Path.Combine(_directory.Path, ConfigPathEvidenceFile);

        internal string ConfigBytesEvidencePath => System.IO.Path.Combine(_directory.Path, ConfigBytesEvidenceFile);

        internal void WriteFakeWget()
        {
            var script = string.Join("\n", new[]
            {
                "#!/bin/sh",
                "out=",
                "while [ \"$#\" -gt 0 ]; do",
                "    case \"$1\" in",
                "        -O) [ \"$#\" -ge 2 ] || exit 2; out=$2; shift 2 ;;",
                "        *) shift ;;",
                "    esac",
                "done",
                "[ -n \"$out\" ] || exit 2",
                "cat > \"$out\" <<'BOOTSTRAP'",
                "#!/bin/sh",
                "[ \"$#\" -eq 2 ] || exit 31",
                "[ \"$1\" = \"--config\" ] || exit 31",
                "config=$2",
                "case \"$config\" in */config.json) ;; *) exit 32 ;; esac",
                "[ -s \"$config\" ] || exit 33",
                "printf \"%s\" \"$config\" > config-path.txt",
                "cat \"$config\" > config-bytes.bin",
                "exit 0",
                "BOOTSTRAP",
                "exit 0",
                ""
            });
            File.WriteAllText(FakeWgetPath, script, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }

        internal void MakeExecutable(string path)
        {
            var result = Run("chmod +x \"$1\"", "sh", ToRelativePath(path));
            Assert.True(result.ExitCode == 0, $"Could not make shell fixture executable: {result.Stderr}");
        }

        internal ShellResult Run(string command)
        {
            return Run(command, "sh");
        }

        internal ShellResult CheckPathDoesNotExist(string path)
        {
            return Run("[ ! -e \"$1\" ]", "sh", path);
        }

        public void Dispose() => _directory.Dispose();

        private ShellResult Run(string command, params string[] arguments)
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = _shellPath,
                    WorkingDirectory = _directory.Path,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                }
            };
            process.StartInfo.ArgumentList.Add("-c");
            process.StartInfo.ArgumentList.Add(command);
            foreach (var argument in arguments)
            {
                process.StartInfo.ArgumentList.Add(argument);
            }

            var existingPath = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            process.StartInfo.Environment["PATH"] = "fake-bin" + System.IO.Path.PathSeparator + existingPath;
            Assert.True(process.Start(), "Could not start the POSIX shell integration fixture.");
            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();
            return new ShellResult(process.ExitCode, stdout, stderr);
        }

        private string ToRelativePath(string path) => System.IO.Path.GetRelativePath(_directory.Path, path).Replace('\\', '/');

        private static string LocatePosixShell()
        {
            if (!OperatingSystem.IsWindows())
            {
                const string unixShell = "/bin/sh";
                Assert.True(File.Exists(unixShell), "POSIX shell integration coverage requires /bin/sh.");
                return unixShell;
            }

            var roots = new[]
            {
                Environment.GetEnvironmentVariable("ProgramFiles"),
                Environment.GetEnvironmentVariable("ProgramW6432"),
                Environment.GetEnvironmentVariable("ProgramFiles(x86)")
            };
            foreach (var root in roots.Where(value => !string.IsNullOrWhiteSpace(value)))
            {
                foreach (var relativePath in new[] { "Git\\bin\\sh.exe", "Git\\usr\\bin\\sh.exe" })
                {
                    var candidate = System.IO.Path.Combine(root!, relativePath);
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }
            }

            var where = new ProcessStartInfo
            {
                FileName = "where.exe",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            where.ArgumentList.Add("sh.exe");
            using var process = Process.Start(where);
            if (process is not null)
            {
                var output = process.StandardOutput.ReadToEnd();
                process.WaitForExit();
                var candidate = output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                    .FirstOrDefault(File.Exists);
                if (candidate is not null)
                {
                    return candidate;
                }
            }

            Assert.Fail("POSIX shell integration coverage requires Git for Windows sh.exe.");
            return string.Empty;
        }

        internal readonly record struct ShellResult(int ExitCode, string Stdout, string Stderr);
    }
}
