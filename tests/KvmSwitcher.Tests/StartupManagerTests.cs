using KvmSwitcher;
using Xunit;

namespace KvmSwitcher.Tests;

public sealed class StartupManagerTests
{
    [Fact]
    public void ValueDataForQuotesTheFullExecutablePath()
    {
        Assert.Equal("\"C:\\Users\\me\\KVM Switcher\\KvmSwitcher.exe\"", StartupManager.ValueDataFor("C:\\Users\\me\\KVM Switcher\\KvmSwitcher.exe"));
    }

    [Fact]
    public void ValueMatchesOnlyTheOwnedExecutableValue()
    {
        const string path = "C:\\KvmSwitcher\\KvmSwitcher.exe";

        Assert.True(StartupManager.ValueMatches("\"C:\\KvmSwitcher\\KvmSwitcher.exe\"", path));
        Assert.True(StartupManager.ValueMatches("\"c:\\kvmswitcher\\kvmswitcher.exe\"", path));
        Assert.False(StartupManager.ValueMatches("C:\\KvmSwitcher\\KvmSwitcher.exe", path));
        Assert.False(StartupManager.ValueMatches("\"C:\\Other\\KvmSwitcher.exe\"", path));
        Assert.False(StartupManager.ValueMatches(null, path));
    }
}
