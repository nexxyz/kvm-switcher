# Portable Linux KVM Switcher

This standalone bundle sends one fixed display report followed by one fixed
KVM report. It has no daemon, hotkeys, network, arbitrary bytes, or retry.
Run it from the host currently owning the KVM USB path. Keep the physical OSD
fallback available; GI is irrelevant on Linux.

This variant is also model-specific. It selects VID/PID `1462:3fa4`, requires
HID interface `0`, and sends the MSI 491CQPX command frames. It does not detect
or configure arbitrary monitor models. Another Linux host should work with the
same validated monitor when it owns the USB route and has the udev permission;
other monitor models need separate protocol validation.

The `1462:3fa4` identity is a shared MSI Gaming Controller PID and is not proof
that another monitor is compatible. Only MSI 491CQPX is hardware-validated by
this project; other models are experimental and untested.

## Debian package

On Debian or Raspberry Pi OS, install the locally built package without pip or
a bundled wheel:

```sh
sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install ./kvm-switcher_0.8.0-1_all.deb
sudo adduser "$USER" kvmswitch
```

The package rules grant `kvmswitch` access to both hidraw and USB/libusb
transports. Log in again after the group change, then unplug and replug the
monitor USB path. The package uses the distro `python3-hid` module and reads:

```text
/etc/kvm-switcher/config.json
```

Use `kvm-switch` to select the one target marked `"default": true`, or use
`kvm-switch --profile Raspberry` or direct fixed values such as
`kvm-switch --input hdmi1 --kvm typec`. A caller-supplied
`KVM_SWITCHER_CONFIG` overrides the package path. Keep the physical OSD
available and perform attended validation before relying on another model.

Legacy configs without a default remain valid for named profiles; add exactly
one explicit `"default": true` before using bare `kvm-switch`. Bare mode changes
the route and is not a probe.

After the USB path has settled, run the delayed no-write diagnostic when needed:

```sh
sleep 15; kvm-switch --probe-hardware 2>&1 | tee ~/kvm-switcher-probe.log
```

The probe enumerates exactly one fixed interface, opens and closes it, and
performs no report I/O.

The Debian package default under `/etc` is intentionally frozen. Portable and
exported example configs may evolve independently, but an existing system
config always wins during helper upgrades. The helper does not apply the
exported config implicitly; use `sh ./install.sh --apply-config` deliberately.
After an install or upgrade, reboot
or use the attended `sudo udevadm control --reload-rules` command, then unplug
and replug the monitor USB path. A one-time upgrade from an older package that
installed a postrm may still run that old removal hook; keep storage stable and
disconnect the HDMI/monitor USB path during that transition. Future package
upgrades have no postrm action.

Remove with `sudo apt remove kvm-switcher`; use `sudo apt purge
kvm-switcher` only when the registered configuration should also be
removed.

## Bundle setup and use

The source checkout contains `config.example.json`; an exported ZIP already
contains a ready `config.json`. If `config.json` is absent, copy the example
before using profile mode. Then install the bundle and use either a named
profile or direct enum literals:

```sh
if [ ! -f config.json ]; then cp config.example.json config.json; fi
sh ./install.sh
.venv/bin/kvm-switch --profile "Raspberry"
.venv/bin/kvm-switch --profile "Raspberry" --config config.json
.venv/bin/kvm-switch
.venv/bin/kvm-switch --input hdmi1 --kvm typec
```

The profile mode reads `config.json` beside `kvmSwitcher.py` by default. The
optional `hotkey` field is validated but ignored on Linux. `windows` is the
DP/upstream pair; `typec` is the HDMI1/Type-C pair in the shared example.

The canonical `pyproject.toml` is also exported for optional pip installation:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m pip install --no-deps -e .
.venv/bin/kvm-switch --input hdmi1 --kvm typec
```

The local installer creates `.venv`, installs `requirements.txt`, installs the
local package editable without re-resolving dependencies, and verifies both
`hidapi` and CLI help without invoking a package manager or sudo:

```sh
sh ./install.sh
sh ./install.sh --install-commands
sh ./install.sh --install-commands --add-path
```

After installation, use `.venv/bin/kvm-switch` or the installed
`~/.local/bin/kvm-switch`; do not use system Python and expect it to see the
venv dependency. `--install-commands` links the exact venv command into
`~/.local/bin` and copies `targets/*.sh` wrappers when present. `--add-path` is
the only option that edits `~/.profile`, adding one marked `~/.local/bin` line.
Edit the bundle `config.json` before using installed profile commands.

## Permissions and platforms

On Debian/RPi OS, use the distro runtime/build fallback when a wheel or venv
prerequisite is unavailable:

```sh
sudo apt update
sudo apt install python3 python3-venv python3-dev build-essential libhidapi-dev
```

Create the dedicated group, add the user, install the rule, and reload udev:

```sh
sudo groupadd --system kvmswitch
sudo usermod -aG kvmswitch "$USER"
sudo install -m 0644 udev/99-kvm-switcher.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

If `kvmswitch` already exists, skip the `groupadd` command. Log in again after
changing group membership. The rule uses VID/PID, `kvmswitch`, mode 0660, and
`uaccess`; it is never world-writable.

On macOS, install Python and the HID library with Homebrew (`brew install
python hidapi`), then use a venv and `pip install -r requirements.txt`. macOS
has no udev rule; use its device permissions and run on the USB-owning host.

On FreeBSD, `pkg install python311 py311-hidapi`, use a venv or the packaged
module, and grant the invoking user the required USB/device permissions. OpenBSD
is experimental because of USB HID driver constraints.
