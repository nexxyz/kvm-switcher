using Xunit;

namespace KvmSwitcher.Tests;

public sealed class ProtocolAndProfileTests
{
    public static IEnumerable<object[]> FixedFrames()
    {
        yield return new object[] { (int)FixedCommand.DisplayDp, "01356230303530303030320d" };
        yield return new object[] { (int)FixedCommand.DisplayHdmi1, "01356230303530303030300d" };
        yield return new object[] { (int)FixedCommand.KvmUpstream, "0135623030383e303030310d" };
        yield return new object[] { (int)FixedCommand.KvmTypeC, "0135623030383e303030320d" };
    }

    [Theory]
    [MemberData(nameof(FixedFrames))]
    public void Fixed_commands_create_exact_64_byte_frames(int commandValue, string prefixHex)
    {
        var expected = new byte[ProtocolFrames.ReportLength];
        Convert.FromHexString(prefixHex).CopyTo(expected, 0);

        var actual = ProtocolFrames.Create((FixedCommand)commandValue);

        Assert.Equal(64, actual.Length);
        Assert.Equal(expected, actual);
    }

    [Theory]
    [InlineData((int)TargetInput.Dp, (int)TargetKvm.Upstream, (int)FixedCommand.DisplayDp, (int)FixedCommand.KvmUpstream)]
    [InlineData((int)TargetInput.Hdmi1, (int)TargetKvm.TypeC, (int)FixedCommand.DisplayHdmi1, (int)FixedCommand.KvmTypeC)]
    public void Target_sends_display_then_kvm(int inputValue, int kvmValue, int displayValue, int kvmCommandValue)
    {
        var target = Target("Target", (TargetInput)inputValue, (TargetKvm)kvmValue);
        var transport = new FakeTransport();

        var result = new ProfileSwitcher(transport, _ => false).Switch(target);

        Assert.Equal("Target", result.TargetName);
        Assert.Equal(ComponentOutcome.Completed, result.DisplayOutcome);
        Assert.Equal(ComponentOutcome.Completed, result.KvmOutcome);
        Assert.Equal(
            new[] { (FixedCommand)displayValue, (FixedCommand)kvmCommandValue },
            transport.Commands);
    }

    [Fact]
    public void Display_failure_does_not_send_kvm()
    {
        var transport = new FakeTransport
        {
            Outcome = command => command == FixedCommand.DisplayDp
                ? CommandOutcome.Failed
                : CommandOutcome.Completed
        };

        var result = new ProfileSwitcher(transport, _ => false).Switch(Target("Windows", TargetInput.Dp, TargetKvm.Upstream));

        Assert.Equal(ComponentOutcome.Failed, result.DisplayOutcome);
        Assert.Equal(ComponentOutcome.NotAttempted, result.KvmOutcome);
        Assert.Equal(new[] { FixedCommand.DisplayDp }, transport.Commands);
    }

    [Fact]
    public void Partial_kvm_failure_keeps_both_component_outcomes()
    {
        var transport = new FakeTransport
        {
            Outcome = command => command == FixedCommand.KvmTypeC
                ? CommandOutcome.Failed
                : CommandOutcome.Completed
        };

        var result = new ProfileSwitcher(transport, _ => false).Switch(Target("Raspberry", TargetInput.Hdmi1, TargetKvm.TypeC));

        Assert.Equal("Raspberry", result.TargetName);
        Assert.Equal(ComponentOutcome.Completed, result.DisplayOutcome);
        Assert.Equal(ComponentOutcome.Failed, result.KvmOutcome);
    }

    [Fact]
    public void Kvm_away_disconnect_is_neutral_completion()
    {
        var transport = new FakeTransport
        {
            Outcome = command => command == FixedCommand.KvmTypeC
                ? CommandOutcome.ExpectedDisconnect
                : CommandOutcome.Completed
        };

        var result = new ProfileSwitcher(transport, _ => false).Switch(Target("Raspberry", TargetInput.Hdmi1, TargetKvm.TypeC));

        Assert.Equal(ComponentOutcome.Completed, result.DisplayOutcome);
        Assert.Equal(ComponentOutcome.ExpectedDisconnect, result.KvmOutcome);
    }

    [Theory]
    [InlineData((int)FixedCommand.DisplayDp, 63, (int)CommandOutcome.Failed)]
    [InlineData((int)FixedCommand.KvmUpstream, 0, (int)CommandOutcome.Failed)]
    [InlineData((int)FixedCommand.KvmTypeC, 0, (int)CommandOutcome.ExpectedDisconnect)]
    [InlineData((int)FixedCommand.KvmTypeC, 1, (int)CommandOutcome.Failed)]
    [InlineData((int)FixedCommand.KvmTypeC, 63, (int)CommandOutcome.Failed)]
    [InlineData((int)FixedCommand.KvmTypeC, 64, (int)CommandOutcome.Completed)]
    public void Read_count_requires_exact_64_except_for_kvm_away(int commandValue, int readCount, int outcomeValue)
    {
        Assert.Equal(
            (CommandOutcome)outcomeValue,
            MonitorHidService.ClassifyReadCount((FixedCommand)commandValue, readCount));
    }

    [Fact]
    public void Short_kvm_read_then_dispose_failure_remains_failed()
    {
        var priorOutcome = MonitorHidService.ClassifyReadCount(FixedCommand.KvmTypeC, 63);

        Assert.Equal(
            CommandOutcome.Failed,
            MonitorHidService.ClassifyDisposeOutcome(FixedCommand.KvmTypeC, true, priorOutcome));
    }

    [Fact]
    public void Exact_kvm_read_then_dispose_failure_is_expected_disconnect()
    {
        var priorOutcome = MonitorHidService.ClassifyReadCount(FixedCommand.KvmTypeC, 64);

        Assert.Equal(
            CommandOutcome.ExpectedDisconnect,
            MonitorHidService.ClassifyDisposeOutcome(FixedCommand.KvmTypeC, true, priorOutcome));
    }

    [Fact]
    public void Kvm_read_exception_or_zero_then_dispose_failure_stays_expected_disconnect()
    {
        Assert.Equal(
            CommandOutcome.ExpectedDisconnect,
            MonitorHidService.ClassifyDisposeOutcome(
                FixedCommand.KvmTypeC,
                true,
                CommandOutcome.ExpectedDisconnect));
        Assert.Equal(
            CommandOutcome.ExpectedDisconnect,
            MonitorHidService.ClassifyDisposeOutcome(
                FixedCommand.KvmTypeC,
                true,
                MonitorHidService.ClassifyReadCount(FixedCommand.KvmTypeC, 0)));
    }

    [Fact]
    public void Non_kvm_dispose_failure_is_failed()
    {
        Assert.Equal(
            CommandOutcome.Failed,
            MonitorHidService.ClassifyDisposeOutcome(
                FixedCommand.KvmUpstream,
                true,
                CommandOutcome.Completed));
    }

    [Fact]
    public void Failed_command_is_not_retried()
    {
        var transport = new FakeTransport { Outcome = _ => CommandOutcome.Failed };

        var result = new ProfileSwitcher(transport, _ => false).Switch(Target("Windows", TargetInput.Dp, TargetKvm.Upstream));

        Assert.Equal(ComponentOutcome.Failed, result.DisplayOutcome);
        Assert.Single(transport.Commands);
        Assert.Equal(FixedCommand.DisplayDp, transport.Commands[0]);
    }

    [Theory]
    [InlineData("GamingIntelligence")]
    [InlineData("MonitorMicroKeyDetector")]
    public void Vendor_process_guard_refuses_before_any_command(string blockedProcess)
    {
        var transport = new FakeTransport();
        var switcher = new ProfileSwitcher(
            transport,
            processName => string.Equals(processName, blockedProcess, StringComparison.Ordinal));

        var result = switcher.Switch(Target("Windows", TargetInput.Dp, TargetKvm.Upstream));

        Assert.True(result.ProcessBlocked);
        Assert.Equal(ComponentOutcome.NotAttempted, result.DisplayOutcome);
        Assert.Empty(transport.Commands);
    }

    private static Target Target(string name, TargetInput input, TargetKvm kvm) =>
        ConfigStore.CreateTarget(name, input, kvm, null);

    private sealed class FakeTransport : IHidCommandTransport
    {
        internal List<FixedCommand> Commands { get; } = [];
        internal Func<FixedCommand, CommandOutcome> Outcome { get; init; } = _ => CommandOutcome.Completed;

        public CommandOutcome Send(FixedCommand command)
        {
            Commands.Add(command);
            return Outcome(command);
        }
    }
}
