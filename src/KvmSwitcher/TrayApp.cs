using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace KvmSwitcher;

internal sealed class TrayApp : ApplicationContext
{
    private const string ReadyStatus = "Ready";
    private const string ConfigErrorStatus = "Configuration error";
    private const string ProcessBlockedStatus = "Close MSI Gaming Intelligence first";
    private const string DeviceUnavailableStatus = "KVM device unavailable";
    private const string BusyStatus = "Switching…";
    private const string FailedSuffix = " — use monitor OSD";

    private readonly MonitorHidService _hidService;
    private readonly ProfileSwitcher _switcher;
    private readonly ConfigStore _configStore;
    private readonly NativeHotkeys _hotkeys;
    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _menu;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _switchMenu;
    private readonly ToolStripMenuItem _useMenu;
    private readonly ToolStripMenuItem _copyCommandMenu;
    private readonly ToolStripMenuItem _debianInstallCommandItem;
    private readonly ToolStripMenuItem _defaultTargetMenu;
    private readonly ToolStripMenuItem _exportItem;
    private readonly ToolStripMenuItem _debianExportItem;
    private readonly ToolStripMenuItem _openItem;
    private readonly ToolStripMenuItem _reloadItem;
    private readonly ToolStripMenuItem _startupItem;
    private readonly ToolStripMenuItem _exitItem;
    private readonly SynchronizationContext _uiContext;
    private readonly Icon? _ownedNotifyIcon;
    private Target[]? _targets;
    private bool _busy;
    private bool _disposed;
    private int _unavailableHotkeys;

    internal TrayApp(MonitorHidService hidService)
        : this(hidService, new ConfigStore())
    {
    }

    internal TrayApp(MonitorHidService hidService, ConfigStore configStore)
    {
        _uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _hidService = hidService;
        _switcher = new ProfileSwitcher(hidService, ProcessGuard.Exists);
        _configStore = configStore;
        _hotkeys = new NativeHotkeys();

        _statusItem = new ToolStripMenuItem(ReadyStatus)
        {
            Enabled = false
        };
        _switchMenu = new ToolStripMenuItem("Switch to");
        _useMenu = new ToolStripMenuItem("Use on another host");
        _copyCommandMenu = new ToolStripMenuItem("Copy command")
        {
            ToolTipText = "Copy a target-specific kvm-switch command"
        };
        _debianInstallCommandItem = new ToolStripMenuItem("Copy Debian install command")
        {
            ToolTipText = "Copy a Debian install command including the current configuration and default target"
        };
        _defaultTargetMenu = new ToolStripMenuItem("Default exported target")
        {
            ToolTipText = "Used by parameterless kvm-switch in exported configurations"
        };
        _exportItem = new ToolStripMenuItem("Export portable ZIP...");
        _debianExportItem = new ToolStripMenuItem("Export Debian install bundle...")
        {
            ToolTipText = "Debian package unavailable in this build"
        };
        _openItem = new ToolStripMenuItem("Open configuration");
        _reloadItem = new ToolStripMenuItem("Reload configuration");
        _startupItem = new ToolStripMenuItem("Start with Windows")
        {
            CheckOnClick = false
        };

        _exportItem.Click += (_, _) => ExportPortableZip();
        _debianExportItem.Click += (_, _) => ExportDebianBundle();
        _debianInstallCommandItem.Click += (_, _) => CopyDebianInstallCommand();
        _openItem.Click += (_, _) => OpenConfiguration();
        _reloadItem.Click += (_, _) => ReloadConfiguration();
        _startupItem.Click += (_, _) => ToggleStartup();

        _menu = new ContextMenuStrip
        {
            ShowImageMargin = false,
            ShowCheckMargin = true,
            AutoSize = true
        };
        _menu.Items.Add(_statusItem);
        _menu.Items.Add(_switchMenu);
        _menu.Items.Add(_useMenu);
        _useMenu.DropDownItems.Add(_debianInstallCommandItem);
        _useMenu.DropDownItems.Add(_copyCommandMenu);
        _useMenu.DropDownItems.Add(_defaultTargetMenu);
        _useMenu.DropDownItems.Add(_exportItem);
        _useMenu.DropDownItems.Add(_debianExportItem);
        _useMenu.DropDown.ShowItemToolTips = true;
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_openItem);
        _menu.Items.Add(_reloadItem);
        _menu.Items.Add(_startupItem);

        _exitItem = new ToolStripMenuItem("Exit");
        _exitItem.Click += (_, _) => ExitThreadIfIdle();
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_exitItem);
        _menu.Opening += (_, _) => RefreshMenuState(updateStatus: true);

        var icon = LoadApplicationIcon(out _ownedNotifyIcon);
        _notifyIcon = new NotifyIcon
        {
            Icon = icon,
            Visible = true,
            Text = "KVM Switcher — Ready",
            ContextMenuStrip = _menu
        };
        _notifyIcon.MouseClick += NotifyIconMouseClick;

        LoadConfiguration(showNotice: true);
    }

    private void NotifyIconMouseClick(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left && !_menu.Visible)
        {
            _menu.Show(Cursor.Position);
        }
    }

    private void LoadConfiguration(bool showNotice)
    {
        _hotkeys.UnregisterAll();
        _targets = null;
        ClearTargetMenus();

        try
        {
            _targets = _configStore.LoadOrCreateDefault().ToArray();
            BuildTargetMenus(_targets);
            var unavailable = _hotkeys.Register(_targets, StartSwitch);
            _unavailableHotkeys = unavailable;
            SetStatus(unavailable == 0
                ? ReadyStatus
                : $"Ready — {unavailable} hotkey(s) unavailable");
        }
        catch (Exception)
        {
            _targets = null;
            _unavailableHotkeys = 0;
            _hotkeys.UnregisterAll();
            ClearTargetMenus();
            SetStatus(ConfigErrorStatus);
            if (showNotice)
            {
                ShowNotice(ConfigErrorStatus);
            }
        }

        RefreshMenuState(updateStatus: true);
    }

    private void BuildTargetMenus(IReadOnlyList<Target> targets)
    {
        foreach (var target in targets)
        {
            var switchItem = new ToolStripMenuItem(EscapeMenuText(target.Name));
            if (target.Hotkey is { } hotkey)
            {
                switchItem.ShortcutKeyDisplayString = hotkey.Display;
            }

            switchItem.Click += (_, _) => StartSwitch(target);
            _switchMenu.DropDownItems.Add(switchItem);

            var copyItem = new ToolStripMenuItem(EscapeMenuText(target.Name));
            copyItem.Click += (_, _) => CopyCommand(target);
            _copyCommandMenu.DropDownItems.Add(copyItem);

            var defaultItem = new ToolStripMenuItem(EscapeMenuText(target.Name))
            {
                Checked = target.IsDefault,
                CheckOnClick = false
            };
            defaultItem.Click += (_, _) => SetDefaultTarget(target.Name);
            _defaultTargetMenu.DropDownItems.Add(defaultItem);
        }
    }

    private void ClearTargetMenus()
    {
        _switchMenu.DropDownItems.Clear();
        _copyCommandMenu.DropDownItems.Clear();
        _defaultTargetMenu.DropDownItems.Clear();
    }

    private void RefreshMenuState(bool updateStatus)
    {
        var vendorRunning = ProcessGuard.IsVendorRunning();
        var deviceAvailable = _hidService.IsDeviceAvailable();
        var debianPackageAvailable = DebianBundleExporter.IsPackageAvailable();
        var canSwitch = _targets is not null && !_busy && !vendorRunning && deviceAvailable;
        var hasConfiguration = _targets is not null;
        var canCopyDebianInstallCommand = CanCopyDebianInstallCommand(_busy, _targets);

        _switchMenu.Enabled = canSwitch;
        _useMenu.Enabled = !_busy;
        _debianInstallCommandItem.Enabled = canCopyDebianInstallCommand;
        _copyCommandMenu.Enabled = hasConfiguration && !_busy;
        _exportItem.Enabled = hasConfiguration && !_busy;
        _debianExportItem.Enabled = hasConfiguration && !_busy && debianPackageAvailable;
        _debianExportItem.ToolTipText = debianPackageAvailable
            ? string.Empty
            : "Debian package unavailable in this build";
        _reloadItem.Enabled = !_busy;
        _startupItem.Enabled = !_busy;
        _exitItem.Enabled = !_busy;
        _openItem.Enabled = true;
        _defaultTargetMenu.Enabled = hasConfiguration && !_busy;
        foreach (ToolStripMenuItem item in _defaultTargetMenu.DropDownItems)
        {
            item.Enabled = hasConfiguration && !_busy;
        }

        try
        {
            _startupItem.Checked = StartupManager.IsEnabled(Application.ExecutablePath);
        }
        catch
        {
            _startupItem.Checked = false;
        }

        if (updateStatus)
        {
            SetStatus(_busy
                ? BusyStatus
                : _targets is null
                    ? ConfigErrorStatus
                    : vendorRunning
                        ? ProcessBlockedStatus
                        : !deviceAvailable
                            ? DeviceUnavailableStatus
                            : _unavailableHotkeys == 0
                                ? ReadyStatus
                                : $"Ready — {_unavailableHotkeys} hotkey(s) unavailable");
        }
    }

    private void StartSwitch(Target target)
    {
        if (_busy || _targets is null)
        {
            return;
        }

        _busy = true;
        SetStatus(BusyStatus);
        RefreshMenuState(updateStatus: false);
        _ = Task.Run(() => _switcher.Switch(target))
            .ContinueWith(
                task => PostResult(task.Status == TaskStatus.RanToCompletion
                    ? task.Result
                    : new SwitchResult(target.Name, ComponentOutcome.Failed, ComponentOutcome.NotAttempted)),
                TaskScheduler.Default);
    }

    private void PostResult(SwitchResult result)
    {
        if (_disposed)
        {
            return;
        }

        try
        {
            _uiContext.Post(_ => CompleteSwitch(result), null);
        }
        catch (InvalidOperationException)
        {
            // The UI may be closing while the bounded background operation finishes.
        }
    }

    private void CompleteSwitch(SwitchResult result)
    {
        if (_disposed)
        {
            return;
        }

        _busy = false;
        var status = FormatResult(result);
        SetStatus(status);
        ShowNotice(status);
        RefreshMenuState(updateStatus: false);
    }

    private static string FormatResult(SwitchResult result)
    {
        if (result.ProcessBlocked)
        {
            return ProcessBlockedStatus;
        }

        if (result.DisplayOutcome == ComponentOutcome.Completed &&
            result.KvmOutcome is ComponentOutcome.Completed or ComponentOutcome.ExpectedDisconnect)
        {
            return "Request completed: " + result.TargetName;
        }

        if (result.DisplayOutcome == ComponentOutcome.DeviceUnavailable)
        {
            return "Device unavailable";
        }

        var stage = result.DisplayOutcome == ComponentOutcome.Completed
            ? "display completed; KVM " + FormatOutcome(result.KvmOutcome)
            : "display " + FormatOutcome(result.DisplayOutcome);
        return $"Request partial: {result.TargetName} ({stage}){FailedSuffix}";
    }

    private static string FormatOutcome(ComponentOutcome outcome) => outcome switch
    {
        ComponentOutcome.Completed => "completed",
        ComponentOutcome.ExpectedDisconnect => "expected disconnect",
        ComponentOutcome.DeviceUnavailable => "unavailable",
        ComponentOutcome.NotAttempted => "not attempted",
        _ => "failed"
    };

    private void CopyCommand(Target target)
    {
        if (_busy)
        {
            return;
        }

        try
        {
            Clipboard.SetText(CommandText.ForTarget(target));
            SetStatus("Command copied");
        }
        catch
        {
            SetStatus("Copy failed");
        }
    }

    private void CopyDebianInstallCommand()
    {
        if (!CanCopyDebianInstallCommand(_busy, _targets))
        {
            return;
        }

        try
        {
            Clipboard.SetText(CommandText.ForDebianInstall(_targets!));
            SetStatus("Debian install command copied with current configuration/default");
        }
        catch (ConfigException exception)
        {
            SetStatus(exception.Message);
            ShowNotice(exception.Message);
        }
        catch
        {
            SetStatus("Copy failed");
        }
    }

    internal static bool CanCopyDebianInstallCommand(bool busy, IReadOnlyList<Target>? targets) =>
        !busy && targets is not null && targets.Count(target => target is not null && target.IsDefault) == 1;

    private void OpenConfiguration()
    {
        try
        {
            _configStore.EnsureExists();
            Process.Start(new ProcessStartInfo
            {
                FileName = _configStore.Path,
                UseShellExecute = true
            });
        }
        catch
        {
            SetStatus(ConfigErrorStatus);
            ShowNotice(ConfigErrorStatus);
        }
    }

    private void ReloadConfiguration()
    {
        if (!_busy)
        {
            LoadConfiguration(showNotice: true);
        }
    }

    private void ToggleStartup()
    {
        if (_busy)
        {
            return;
        }

        var enable = !_startupItem.Checked;
        try
        {
            StartupManager.SetEnabled(enable, Application.ExecutablePath);
            _startupItem.Checked = enable;
            SetStatus(enable ? "Startup enabled" : "Startup disabled");
        }
        catch
        {
            try
            {
                _startupItem.Checked = StartupManager.IsEnabled(Application.ExecutablePath);
            }
            catch
            {
                _startupItem.Checked = !enable;
            }

            SetStatus("Startup update failed");
            ShowNotice("Could not update startup");
        }
    }

    private void SetDefaultTarget(string targetName)
    {
        if (_busy || _targets is null)
        {
            return;
        }

        try
        {
            var updated = ConfigStore.WithDefaultTarget(_targets, targetName);
            _configStore.Save(updated);
            LoadConfiguration(showNotice: false);
            SetStatus("Export default: " + targetName);
        }
        catch
        {
            LoadConfiguration(showNotice: false);
            SetStatus("Export default update failed");
            ShowNotice("Export default update failed");
        }
    }

    private void ExitThreadIfIdle()
    {
        if (!_busy)
        {
            ExitThread();
        }
    }

    private void ExportPortableZip()
    {
        if (_busy || _targets is null)
        {
            return;
        }

        using var dialog = new SaveFileDialog
        {
            AddExtension = true,
            DefaultExt = "zip",
            FileName = "kvm-switcher.zip",
            Filter = "ZIP archive (*.zip)|*.zip"
        };
        if (dialog.ShowDialog() != DialogResult.OK)
        {
            return;
        }

        try
        {
            using var stream = new FileStream(dialog.FileName, FileMode.Create, FileAccess.Write, FileShare.None);
            PortableExporter.Export(_targets, stream);
            SetStatus("Exported portable ZIP");
            ShowNotice("Exported portable ZIP");
        }
        catch
        {
            SetStatus("Export failed");
            ShowNotice("Export failed");
        }
    }

    private void ExportDebianBundle()
    {
        if (_busy || _targets is null || !DebianBundleExporter.IsPackageAvailable())
        {
            return;
        }

        using var dialog = new SaveFileDialog
        {
            AddExtension = true,
            DefaultExt = "zip",
            FileName = "kvm-switcher-debian.zip",
            Filter = "ZIP archive (*.zip)|*.zip"
        };
        if (dialog.ShowDialog() != DialogResult.OK)
        {
            return;
        }

        if (string.Equals(
                Path.GetFullPath(dialog.FileName),
                Path.GetFullPath(DebianBundleExporter.PackagePath),
                StringComparison.OrdinalIgnoreCase))
        {
            SetStatus("Debian bundle export failed");
            ShowNotice("Choose a different export file");
            return;
        }

        try
        {
            using var stream = new FileStream(dialog.FileName, FileMode.Create, FileAccess.Write, FileShare.None);
            DebianBundleExporter.Export(_targets, stream);
            SetStatus("Exported Debian install bundle");
            ShowNotice("Exported Debian install bundle");
        }
        catch
        {
            SetStatus("Debian bundle export failed");
            ShowNotice("Export failed");
        }
    }

    private void ShowNotice(string text)
    {
        _notifyIcon.BalloonTipTitle = "KVM Switcher";
        _notifyIcon.BalloonTipText = text;
        _notifyIcon.ShowBalloonTip(2500);
    }

    private void SetStatus(string status)
    {
        _statusItem.Text = status;
        var tooltip = "KVM Switcher — " + status;
        _notifyIcon.Text = tooltip.Length <= 63 ? tooltip : tooltip[..60] + "...";
    }

    private static string EscapeMenuText(string value) => value.Replace("&", "&&", StringComparison.Ordinal);

    private static Icon LoadApplicationIcon(out Icon? ownedIcon)
    {
        ownedIcon = null;
        try
        {
            var resource = typeof(TrayApp).Assembly.GetManifestResourceStream("KvmSwitcher.Icon.ico");
            if (resource is null)
            {
                return SystemIcons.Application;
            }

            using (resource)
            using (var source = new Icon(resource))
            {
                ownedIcon = (Icon)source.Clone();
                return ownedIcon;
            }
        }
        catch (Exception)
        {
            ownedIcon?.Dispose();
            ownedIcon = null;
            return SystemIcons.Application;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (disposing)
        {
            _hotkeys.Dispose();
            _notifyIcon.MouseClick -= NotifyIconMouseClick;
            _notifyIcon.Visible = false;
            _notifyIcon.ContextMenuStrip = null;
            _notifyIcon.Dispose();
            _ownedNotifyIcon?.Dispose();
            _menu.Dispose();
        }

        base.Dispose(disposing);
    }
}
