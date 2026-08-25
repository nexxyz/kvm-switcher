using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace KvmSwitcher;

internal sealed class NativeHotkeys : IDisposable
{
    private const int HwndMessage = -3;
    private const int WmHotkey = 0x0312;
    private const uint ModNoRepeat = 0x4000;

    private readonly Dictionary<int, Target> _targets = [];
    private HotkeyWindow? _window;
    private bool _disposed;
    private Action<Target>? _callback;

    internal int Register(IReadOnlyList<Target> targets, Action<Target> callback)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(NativeHotkeys));
        }

        UnregisterAll();
        _callback = callback;
        _window ??= new HotkeyWindow(HandleHotkey);

        var unavailable = 0;
        var id = 1;
        foreach (var target in targets)
        {
            if (target.Hotkey is not { } hotkey)
            {
                continue;
            }

            if (RegisterHotKey(_window.Handle, id, hotkey.Modifiers | ModNoRepeat, hotkey.VirtualKey))
            {
                _targets[id] = target;
            }
            else
            {
                unavailable++;
            }

            id++;
        }

        return unavailable;
    }

    internal void UnregisterAll()
    {
        if (_window is null)
        {
            _targets.Clear();
            return;
        }

        foreach (var id in _targets.Keys.ToArray())
        {
            UnregisterHotKey(_window.Handle, id);
        }

        _targets.Clear();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        UnregisterAll();
        _window?.DestroyHandle();
        _window = null;
        _callback = null;
    }

    private void HandleHotkey(int id)
    {
        if (_targets.TryGetValue(id, out var target))
        {
            _callback?.Invoke(target);
        }
    }

    private sealed class HotkeyWindow : NativeWindow
    {
        private readonly Action<int> _callback;

        internal HotkeyWindow(Action<int> callback)
        {
            _callback = callback;
            CreateHandle(new CreateParams { Parent = new IntPtr(HwndMessage) });
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmHotkey)
            {
                _callback(message.WParam.ToInt32());
            }

            base.WndProc(ref message);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
