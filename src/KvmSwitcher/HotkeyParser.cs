using System.Globalization;
using System.Numerics;

namespace KvmSwitcher;

internal static class HotkeyParser
{
    internal const uint ModAlt = 0x0001;
    internal const uint ModControl = 0x0002;
    internal const uint ModShift = 0x0004;
    internal const uint ModWin = 0x0008;

    internal static HotkeySpec Parse(string value)
    {
        if (!TryParse(value, out var result))
        {
            throw new HotkeyFormatException();
        }

        return result;
    }

    internal static bool TryParse(string? value, out HotkeySpec result)
    {
        result = default;
        if (string.IsNullOrWhiteSpace(value) || value.Any(char.IsWhiteSpace))
        {
            return false;
        }

        var parts = value.Split('+', StringSplitOptions.None);
        if (parts.Length < 3 || parts.Any(string.IsNullOrWhiteSpace))
        {
            return false;
        }

        uint modifiers = 0;
        for (var index = 0; index < parts.Length - 1; index++)
        {
            var modifier = ParseModifier(parts[index]);
            if (modifier == 0 || (modifiers & modifier) != 0)
            {
                return false;
            }

            modifiers |= modifier;
        }

        if (BitOperations.PopCount(modifiers) < 2 || !TryParseKey(parts[^1], out var key, out var virtualKey))
        {
            return false;
        }

        var displayModifiers = new List<string>(4);
        if ((modifiers & ModControl) != 0) displayModifiers.Add("Ctrl");
        if ((modifiers & ModShift) != 0) displayModifiers.Add("Shift");
        if ((modifiers & ModAlt) != 0) displayModifiers.Add("Alt");
        if ((modifiers & ModWin) != 0) displayModifiers.Add("Win");
        displayModifiers.Add(key);

        result = new HotkeySpec(string.Join('+', displayModifiers), modifiers, virtualKey);
        return true;
    }

    private static uint ParseModifier(string value) => value.ToUpperInvariant() switch
    {
        "CTRL" => ModControl,
        "SHIFT" => ModShift,
        "ALT" => ModAlt,
        "WIN" => ModWin,
        _ => 0
    };

    private static bool TryParseKey(string value, out string display, out uint virtualKey)
    {
        display = string.Empty;
        virtualKey = 0;

        if (value.Length == 1)
        {
            var character = value[0];
            if ((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z'))
            {
                display = char.ToUpperInvariant(character).ToString();
                virtualKey = display[0];
                return true;
            }

            if (character >= '0' && character <= '9')
            {
                display = character.ToString();
                virtualKey = character;
                return true;
            }
        }

        if (value.Length >= 2 && (value[0] == 'f' || value[0] == 'F') &&
            int.TryParse(value.AsSpan(1), NumberStyles.None, CultureInfo.InvariantCulture, out var functionNumber) &&
            functionNumber is >= 1 and <= 24 &&
            string.Equals(value, $"F{functionNumber}", StringComparison.OrdinalIgnoreCase))
        {
            display = $"F{functionNumber}";
            virtualKey = (uint)(0x70 + functionNumber - 1);
            return true;
        }

        return false;
    }
}

internal sealed class HotkeyFormatException : Exception
{
}
