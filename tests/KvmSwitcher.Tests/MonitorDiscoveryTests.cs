using Xunit;

namespace KvmSwitcher.Tests;

public sealed class MonitorDiscoveryTests
{
    [Fact]
    public void Sole_live_vid_pid_path_is_accepted_without_interface_token()
    {
        var livePath = @"HID\VID_1462&PID_3FA4\9&31B27B46&0&0000";

        Assert.DoesNotContain("MI_00", livePath, StringComparison.OrdinalIgnoreCase);
        Assert.True(MonitorHidService.HasSingleVidPidCandidate(new[] { livePath }));
    }

    [Fact]
    public void Multiple_vid_pid_candidates_are_fail_closed()
    {
        var liveHidPath = @"HID\VID_1462&PID_3FA4\9&31B27B46&0&0000";
        var secondCandidatePath = @"HID\VID_1462&PID_3FA4\9&31B27B46&0&0001";

        Assert.False(MonitorHidService.HasSingleVidPidCandidate(new[] { liveHidPath, secondCandidatePath }));
        Assert.False(MonitorHidService.HasSingleVidPidCandidate(Array.Empty<string>()));
    }
}
