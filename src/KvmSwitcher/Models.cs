namespace KvmSwitcher;

internal enum TargetInput
{
    Dp,
    Hdmi1
}

internal enum TargetKvm
{
    Upstream,
    TypeC
}

internal enum FixedCommand
{
    DisplayDp,
    DisplayHdmi1,
    KvmUpstream,
    KvmTypeC
}

internal enum CommandOutcome
{
    Completed,
    ExpectedDisconnect,
    DeviceUnavailable,
    Failed
}

internal enum ComponentOutcome
{
    NotAttempted,
    Completed,
    ExpectedDisconnect,
    DeviceUnavailable,
    Failed
}

internal readonly record struct HotkeySpec(string Display, uint Modifiers, uint VirtualKey);

internal sealed record Target
{
    private Target(string name, TargetInput input, TargetKvm kvm, HotkeySpec? hotkey, bool isDefault)
    {
        Name = name;
        Input = input;
        Kvm = kvm;
        Hotkey = hotkey;
        IsDefault = isDefault;
    }

    internal string Name { get; }
    internal TargetInput Input { get; }
    internal TargetKvm Kvm { get; }
    internal HotkeySpec? Hotkey { get; }
    internal bool IsDefault { get; }

    internal static Target FromValidated(string name, TargetInput input, TargetKvm kvm, HotkeySpec? hotkey, bool isDefault) =>
        new(name, input, kvm, hotkey, isDefault);
}

internal sealed record SwitchResult(
    string TargetName,
    ComponentOutcome DisplayOutcome,
    ComponentOutcome KvmOutcome,
    bool ProcessBlocked = false);

internal interface IHidCommandTransport
{
    CommandOutcome Send(FixedCommand command);
}
