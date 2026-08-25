using Xunit;

namespace KvmSwitcher.Tests;

public sealed class ProbeTests
{
    [Fact]
    public void Probe_argument_is_exact_and_does_not_accept_extra_arguments()
    {
        Assert.True(Program.IsProbeInvocation(new[] { "--probe-hardware" }));
        Assert.False(Program.IsProbeInvocation(Array.Empty<string>()));
        Assert.False(Program.IsProbeInvocation(new[] { "--probe-hardware", "extra" }));
        Assert.False(Program.IsProbeInvocation(new[] { "--PROBE-HARDWARE" }));
    }

    [Fact]
    public void Probe_result_values_are_the_process_exit_codes()
    {
        Assert.Equal(0, (int)HardwareProbeResult.Success);
        Assert.Equal(10, (int)HardwareProbeResult.NoCandidate);
        Assert.Equal(11, (int)HardwareProbeResult.MultipleCandidates);
        Assert.Equal(12, (int)HardwareProbeResult.EnumerationFailure);
        Assert.Equal(13, (int)HardwareProbeResult.OpenFailure);
        Assert.Equal(14, (int)HardwareProbeResult.CloseFailure);
    }
}
