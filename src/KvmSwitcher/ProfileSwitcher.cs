namespace KvmSwitcher;

internal sealed class ProfileSwitcher
{
    private readonly IHidCommandTransport _transport;
    private readonly Func<string, bool> _processExists;

    internal ProfileSwitcher(IHidCommandTransport transport, Func<string, bool> processExists)
    {
        _transport = transport;
        _processExists = processExists;
    }

    internal SwitchResult Switch(Target target)
    {
        if (_processExists("GamingIntelligence") || _processExists("MonitorMicroKeyDetector"))
        {
            return new SwitchResult(
                target.Name,
                ComponentOutcome.NotAttempted,
                ComponentOutcome.NotAttempted,
                ProcessBlocked: true);
        }

        var displayCommand = target.Input == TargetInput.Dp
            ? FixedCommand.DisplayDp
            : FixedCommand.DisplayHdmi1;
        var kvmCommand = target.Kvm == TargetKvm.Upstream
            ? FixedCommand.KvmUpstream
            : FixedCommand.KvmTypeC;

        ComponentOutcome displayOutcome;
        try
        {
            displayOutcome = MapOutcome(_transport.Send(displayCommand));
        }
        catch
        {
            displayOutcome = ComponentOutcome.Failed;
        }

        if (displayOutcome != ComponentOutcome.Completed)
        {
            return new SwitchResult(target.Name, displayOutcome, ComponentOutcome.NotAttempted);
        }

        ComponentOutcome kvmOutcome;
        try
        {
            kvmOutcome = MapOutcome(_transport.Send(kvmCommand));
        }
        catch
        {
            kvmOutcome = ComponentOutcome.Failed;
        }

        return new SwitchResult(target.Name, displayOutcome, kvmOutcome);
    }

    private static ComponentOutcome MapOutcome(CommandOutcome outcome) => outcome switch
    {
        CommandOutcome.Completed => ComponentOutcome.Completed,
        CommandOutcome.ExpectedDisconnect => ComponentOutcome.ExpectedDisconnect,
        CommandOutcome.DeviceUnavailable => ComponentOutcome.DeviceUnavailable,
        _ => ComponentOutcome.Failed
    };
}
