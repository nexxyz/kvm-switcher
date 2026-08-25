using System.Text;

namespace KvmSwitcher;

internal static class ProtocolFrames
{
    internal const int ReportLength = 64;
    internal const byte ReportId = 0x01;

    internal static byte[] Create(FixedCommand command)
    {
        var text = command switch
        {
            FixedCommand.DisplayDp => "5b00500002\r",
            FixedCommand.DisplayHdmi1 => "5b00500000\r",
            FixedCommand.KvmUpstream => "5b008>0001\r",
            FixedCommand.KvmTypeC => "5b008>0002\r",
            _ => throw new ArgumentOutOfRangeException(nameof(command))
        };

        var frame = new byte[ReportLength];
        frame[0] = ReportId;
        Encoding.ASCII.GetBytes(text, frame.AsSpan(1));
        return frame;
    }
}
