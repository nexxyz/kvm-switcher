using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace KvmSwitcher;

internal static class DebianBundleExporter
{
    internal const string PackageFileName = "kvm-switcher_0.8.2-1_all.deb";
    private const string InstallAsset = "KvmSwitcher.DebianBundle.install.sh";
    private const string ReadmeAsset = "KvmSwitcher.DebianBundle.README.md";

    internal static string PackagePath => Path.Combine(AppContext.BaseDirectory, PackageFileName);

    internal static bool IsPackageAvailable() => IsPackageAvailableAt(PackagePath);

    internal static bool IsPackageAvailableAt(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && !info.Attributes.HasFlag(FileAttributes.Directory) && info.Length > 0;
        }
        catch
        {
            return false;
        }
    }

    internal static void Export(IReadOnlyList<Target> targets, Stream destination)
    {
        if (!IsPackageAvailable())
        {
            throw new InvalidOperationException("Debian package is unavailable");
        }

        try
        {
            using var package = new FileStream(PackagePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            Export(targets, destination, package);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new InvalidOperationException("Debian package is unavailable", exception);
        }
    }

    internal static void Export(IReadOnlyList<Target> targets, Stream destination, Stream packageSource)
    {
        var configBytes = Encoding.UTF8.GetBytes(ConfigStore.Serialize(targets));
        using var packageBytes = new MemoryStream();
        if (packageSource.CanSeek)
        {
            packageSource.Position = 0;
        }
        packageSource.CopyTo(packageBytes);
        if (packageBytes.Length == 0)
        {
            throw new InvalidOperationException("Debian package is empty");
        }

        var packagePayload = packageBytes.ToArray();
        var checksums = string.Concat(
            ToSha256(packagePayload), "  ", PackageFileName, "\n",
            ToSha256(configBytes), "  config.json\n");

        using var archive = new ZipArchive(destination, ZipArchiveMode.Create, leaveOpen: true);
        AddBytes(archive, PackageFileName, packagePayload);
        AddBytes(archive, "config.json", configBytes);
        AddResource(archive, "install.sh", InstallAsset);
        AddResource(archive, "README.md", ReadmeAsset);
        AddResource(archive, "LICENSE", "KvmSwitcher.License");
        AddBytes(archive, "SHA256SUMS", Encoding.ASCII.GetBytes(checksums));
    }

    private static string ToSha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static void AddResource(ZipArchive archive, string entryName, string resourceName)
    {
        var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException("Debian bundle asset is unavailable");
        using (resource)
        using (var buffer = new MemoryStream())
        {
            resource.CopyTo(buffer);
            AddBytes(archive, entryName, buffer.ToArray());
        }
    }

    private static void AddBytes(ZipArchive archive, string entryName, byte[] bytes)
    {
        var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
        using var stream = entry.Open();
        stream.Write(bytes, 0, bytes.Length);
    }
}
