# KVM Switcher

KVM Switcher is a small Windows tray application and portable Python CLI for
the currently validated MSI 491CQPX hardware. It switches the monitor display
input and KVM route without requiring the vendor tray application. The product
name is KVM Switcher. The public source is
https://github.com/nexxyz/kvm-switcher and the project is licensed under MIT.

Each request is one fixed display command followed by one fixed KVM command.
The display request is always first; the KVM request is last. The supported
pairs are:

- `dp` + `upstream` — the Windows host example;
- `hdmi1` + `typec` — the Raspberry Pi host example.

There is no automatic retry, rollback, fallback write, or state assertion. A
Type-C KVM-away disconnect after its write is an expected completion boundary.
Keep the monitor OSD available for manual recovery.

## Hardware compatibility

KVM Switcher is currently validated only for the **MSI 491CQPX** USB HID device
with VID/PID `1462:3fa4`. Windows and Linux use that fixed identity and the same
fixed command frames; they do not discover the monitor model or learn its
protocol automatically.

Another Windows 11 or Linux host connected to the same monitor model should
work when it owns the monitor USB path and exposes the same VID/PID. Treat the
first use on another unit or firmware as attended validation. Other monitor
models are not supported out of the box, even if they have a KVM feature; they
require separately verified device IDs, interface selection, and command frames.

The `1462:3fa4` pair is a shared MSI Gaming Controller PID and is not sufficient
proof of monitor compatibility.

### Likely protocol-compatible candidates (untested)

Public profiles suggest these six models should share the four protocol
messages used here, including the `00500` display-input and `008>0` KVM
profiles using the same encoder. Compatibility with this binary, firmware and
interface behavior, and physical switching are unverified:

- MSI MPG 491CQP, from the exact protocol implementation at
  https://github.com/hamishmorgan/msi-mpg-491cqp-control
- MSI MPG273CQR, MSI MAG274QRX, MSI MD272QP, MSI MD342CQP, and MSI MPG 274URDFW
  E16M, from https://github.com/couriersud/msigd
- The MD342CQP and MPG 274URDFW E16M evidence also includes
  https://github.com/couriersud/msigd/pull/71 and
  https://github.com/couriersud/msigd/pull/70

None of these models has been hardware-tested by KVM Switcher. Users must
perform attended validation with the monitor OSD available for recovery.

## Windows installation

Run `KvmSwitcher-Setup.exe`. The installer checks for the **.NET 8 Windows
Desktop Runtime**, installs KVM Switcher for the current user, and can launch
the tray application when setup finishes. A portable Windows ZIP is also
available for users who do not want to install it.

The application creates and uses:

```text
%LOCALAPPDATA%\KvmSwitcher\config.json
```

The initial configuration is:

```json
{
  "targets": [
    {"name":"Raspberry","input":"hdmi1","kvm":"typec","hotkey":"Ctrl+Shift+Alt+P","default":false},
    {"name":"Windows","input":"dp","kvm":"upstream","hotkey":"Ctrl+Shift+Alt+W","default":true}
  ]
}
```

The tray menu is built from the valid target list. It provides target switching,
global hotkeys, target-command copying, the Debian install-command copy action,
portable and Debian bundle exports, `Open configuration`, `Reload
configuration`, `Start with Windows`, and `Exit`. Left and right clicks open
the same menu. Reload is explicit; the application does not watch the file.
Invalid configuration disables switching and export while keeping Open, Reload,
and Exit available. Copying an install command does not install anything or
switch the monitor; it only places the command on the clipboard.

Under `Use on another host` > `Default exported target`, choose the target used
by parameterless `kvm-switch` in exported configurations. This only changes the
`default` flag in the config and future portable or Debian exports; it does not
switch or change default behavior of the Windows tray app.

Hotkeys use at least two distinct modifiers from `Ctrl`, `Shift`, `Alt`, and
`Win`, followed by exactly one `A`–`Z`, `0`–`9`, or `F1`–`F24` key. Modifier and
key spelling is case-insensitive; display order is `Ctrl+Shift+Alt+Win+KEY`.
Duplicate target names and duplicate hotkeys are configuration errors. A
Windows registration conflict disables only that hotkey; the target remains
available from the menu.

The application refuses a request while MSI Gaming Intelligence or
MonitorMicroKeyDetector is running. It reports ordinary request outcomes and
does not claim independently confirmed monitor state.

## Online Debian installer

The tray's **Use on another host > Copy Debian install command** copies this
one-line command for the current online release:

```sh
sh -c 'f=$(mktemp) || exit 1; trap "rm -f \"$f\"" 0; if ! wget --https-only -T 30 -t 1 -O "$f" "https://github.com/nexxyz/kvm-switcher/releases/latest/download/install-kvm-switcher.sh" || [ ! -s "$f" ]; then printf "%s\n" "Download failed or empty; download the Debian bundle instead: https://github.com/nexxyz/kvm-switcher/releases/latest/download/kvm-switcher-debian.zip" >&2; exit 1; fi; sh "$f"'
```

The bootstrap is intended for a normal, non-root account. For release `v0.8.0`
it downloads the immutable package
`https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.0/kvm-switcher_0.8.0-1_all.deb`,
checks its embedded SHA256, and only then uses `sudo apt-get` with the existing
configuration preserved. The matching one-entry checksum file is
`https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.0/SHA256SUMS-debian.txt`;
do not mix assets from different release tags.

If GitHub or the package download is unavailable, use the matching
`kvm-switcher-debian.zip` release asset instead:

```text
https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.0/kvm-switcher-debian.zip
```

Extract it and run `sh ./install.sh`. The bundle avoids GitHub during its
installation, but `apt` may still need to download distro dependencies. It is
not a claim of a fully offline install.

## Portable bundle

The tray can export one ZIP containing the fixed Python CLI, shared
`config.json`, `pyproject.toml`, requirements, installer, README, root
`LICENSE`, udev rule, and one safe shell wrapper per target. After installing
the bundle, use its virtual environment rather than a system Python:

```sh
./.venv/bin/python kvmSwitcher.py --profile Raspberry
./.venv/bin/python kvmSwitcher.py --input hdmi1 --kvm typec
```

`--profile NAME` selects a configured target. Direct mode uses the fixed
`--input dp|hdmi1` and `--kvm upstream|typec` values. No arbitrary HID bytes or
targets are accepted. Bare `kvm-switch` selects the one target marked
`"default": true`; it is a route-changing command, not a probe. Legacy configs
without a default remain usable by profile, but need exactly one explicit true
value before bare mode can be used.

If the package has been installed into the bundle virtual environment, the
equivalent command is `./.venv/bin/kvm-switch --profile Raspberry`. The
`--install-commands` option creates the installed command at
`$HOME/.local/bin/kvm-switch`; invoke that explicit path or use a generated
target wrapper. Wrappers use fixed direct enum arguments and do not depend on a
profile config lookup.

On Debian/Raspberry Pi OS, the primary portable platform:

```sh
sh ./install.sh
sh ./install.sh --install-commands
sh ./install.sh --install-commands --add-path
```

The installer creates a local virtual environment and installs the listed
Python dependency. It does not auto-deploy, use SSH, invoke `sudo`, or edit a
profile unless `--add-path` is selected. Install the udev rule and grant the
appropriate local device permissions according to the bundle README. macOS
and FreeBSD are secondary platforms using the same Python/config interface and
their own HID permission mechanisms. OpenBSD is experimental.

If a KVM-away operation disconnects the controlling USB path, wait for the
monitor to settle and use the physical OSD to restore the desired route. Do
not issue a compensating software write.

## Debian install bundle

The Windows tray can export a Debian install bundle containing the current
configuration, an architecture-independent `.deb`, an installation helper,
instructions, and checksums. Copy and extract the ZIP on Debian or Raspberry Pi
OS, then run:

```sh
sh ./install.sh
```

Fresh installs and upgrades receive or preserve the Debian package conffile;
the helper does not apply the exported configuration implicitly. Existing
configuration is preserved during package updates. Apply the exported config
explicitly when desired:

```sh
sh ./install.sh --apply-config
```

After installation, log in again if group membership changed and unplug and
replug the monitor USB path. The Debian rules grant `kvmswitch` access to both
hidraw and USB/libusb transports. The direct command is `kvm-switch` and the
system config is `/etc/kvm-switcher/config.json`.

The Debian package default under `/etc` is intentionally frozen; portable and
exported example configs may evolve independently. Existing configuration wins
during helper upgrades. After an install or upgrade, reboot or use the attended
`sudo udevadm control --reload-rules` command, then unplug and replug the
monitor USB path. A one-time upgrade from an older package that installed a
postrm may still run that old removal hook, so keep storage stable and
disconnect the HDMI/monitor USB path during that transition. Future package
upgrades have no postrm action.

For a delayed, no-write diagnostic after the USB path has settled:

```sh
sleep 15; kvm-switch --probe-hardware 2>&1 | tee ~/kvm-switcher-probe.log
```

The probe requires exactly one fixed interface, opens and closes it, and
performs no report I/O.
