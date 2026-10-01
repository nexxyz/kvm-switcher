using System.IO;
using HidSharp;

namespace KvmSwitcher;

internal enum HardwareProbeResult
{
    Success = 0,
    NoCandidate = 10,
    MultipleCandidates = 11,
    EnumerationFailure = 12,
    OpenFailure = 13,
    CloseFailure = 14
}

internal sealed class MonitorHidService : IHidCommandTransport
{
    private const int VendorId = 0x1462;
    private const int ProductId = 0x3FA4;
    private const int IoTimeoutMilliseconds = 1500;

    internal bool IsDeviceAvailable() => DiscoverDevice().Outcome == DiscoveryOutcome.Found;

    public CommandOutcome Send(FixedCommand command)
    {
        var discovery = DiscoverDevice();
        if (discovery.Outcome != DiscoveryOutcome.Found || discovery.Device is null)
        {
            return CommandOutcome.DeviceUnavailable;
        }
        var device = discovery.Device;

        HidStream? stream = null;
        var writeCompleted = false;
        var outcome = CommandOutcome.Failed;

        try
        {
            if (!device.TryOpen(out stream) || stream is null)
            {
                return CommandOutcome.DeviceUnavailable;
            }

            stream.WriteTimeout = IoTimeoutMilliseconds;
            stream.ReadTimeout = IoTimeoutMilliseconds;

            var frame = ProtocolFrames.Create(command);
            stream.Write(frame, 0, frame.Length);
            writeCompleted = true;

            var response = new byte[ProtocolFrames.ReportLength];
            try
            {
                var readCount = stream.Read(response, 0, response.Length);
                outcome = ClassifyReadCount(command, readCount);
            }
            catch (IOException) when (writeCompleted && command == FixedCommand.KvmTypeC)
            {
                outcome = CommandOutcome.ExpectedDisconnect;
            }
            catch (TimeoutException) when (writeCompleted && command == FixedCommand.KvmTypeC)
            {
                outcome = CommandOutcome.ExpectedDisconnect;
            }
        }
        catch (Exception)
        {
            outcome = CommandOutcome.Failed;
        }
        finally
        {
            try
            {
                stream?.Dispose();
            }
            catch (Exception)
            {
                outcome = ClassifyDisposeOutcome(command, writeCompleted, outcome);
            }
        }

        return outcome;
    }

    internal static HardwareProbeResult ProbeHardware()
    {
        var discovery = DiscoverDevice();
        var discoveryResult = discovery.Outcome switch
        {
            DiscoveryOutcome.Found => (HardwareProbeResult?)null,
            DiscoveryOutcome.NoCandidate => HardwareProbeResult.NoCandidate,
            DiscoveryOutcome.MultipleCandidates => HardwareProbeResult.MultipleCandidates,
            _ => HardwareProbeResult.EnumerationFailure
        };
        if (discoveryResult is { } failure)
        {
            return failure;
        }

        HidStream? stream = null;
        try
        {
            if (discovery.Device is null || !discovery.Device.TryOpen(out stream) || stream is null)
            {
                return HardwareProbeResult.OpenFailure;
            }
        }
        catch
        {
            return HardwareProbeResult.OpenFailure;
        }

        try
        {
            stream.Dispose();
            return HardwareProbeResult.Success;
        }
        catch
        {
            return HardwareProbeResult.CloseFailure;
        }
    }

    internal static CommandOutcome ClassifyReadCount(FixedCommand command, int readCount) =>
        readCount == ProtocolFrames.ReportLength
            ? CommandOutcome.Completed
            : command == FixedCommand.KvmTypeC && readCount == 0
                ? CommandOutcome.ExpectedDisconnect
                : CommandOutcome.Failed;

    internal static CommandOutcome ClassifyDisposeOutcome(
        FixedCommand command,
        bool exactWriteCompleted,
        CommandOutcome priorOutcome) =>
        command == FixedCommand.KvmTypeC &&
        exactWriteCompleted &&
        priorOutcome is CommandOutcome.Completed or CommandOutcome.ExpectedDisconnect
            ? CommandOutcome.ExpectedDisconnect
            : CommandOutcome.Failed;

    private static DeviceDiscovery DiscoverDevice()
    {
        try
        {
            var devices = DeviceList.Local.GetHidDevices(VendorId, ProductId).ToArray();
            if (devices.Length == 0)
            {
                return new DeviceDiscovery(DiscoveryOutcome.NoCandidate, null);
            }

            var devicePaths = devices.Select(device => device.DevicePath).ToArray();
            return HasSingleVidPidCandidate(devicePaths)
                ? new DeviceDiscovery(DiscoveryOutcome.Found, devices[0])
                : new DeviceDiscovery(DiscoveryOutcome.MultipleCandidates, null);
        }
        catch (Exception)
        {
            return new DeviceDiscovery(DiscoveryOutcome.EnumerationFailure, null);
        }
    }

    internal static bool HasSingleVidPidCandidate(IReadOnlyList<string> devicePaths) =>
        devicePaths.Count == 1;

    private enum DiscoveryOutcome
    {
        Found,
        NoCandidate,
        MultipleCandidates,
        EnumerationFailure
    }

    private readonly record struct DeviceDiscovery(DiscoveryOutcome Outcome, HidDevice? Device);
}
