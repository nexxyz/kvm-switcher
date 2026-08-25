# Debian KVM Switcher bundle

This bundle installs the Debian package for the validated MSI 491CQPX only.
The `1462:3fa4` identity is shared by MSI Gaming Controllers and does not prove
compatibility with another monitor model.

This is the Debian/`apt` bundle, separate from the Windows
`KvmSwitcher-win-x64.zip` and the portable Python `KvmSwitcher-portable.zip`.
It contains `kvm-switcher_0.8.2-1_all.deb`, the root `LICENSE`, and is not a
portable Python bundle. A bundle exported by the Windows tray carries the
current tray configuration. The public `kvm-switcher-debian.zip` release
bundle instead carries the frozen v0.8.2 release configuration; it does not
carry a current tray configuration. The tray-exported form requires
`--apply-config` to apply that current configuration; both contain
`config.json`, but configuration is applied only when explicitly requested.

The release fallback ZIP contains exactly the package, `config.json`,
`install.sh`, this `README.md`, `LICENSE`, and `SHA256SUMS`. The internal
checksum file intentionally covers only the package and config.

Run the helper as the intended normal user. A tray-exported bundle carries the
current configuration and requires:

```sh
sh ./install.sh --apply-config
```

The public release bundle carries frozen release configuration and uses the
no-config fallback:

```sh
sh ./install.sh
```

The helper verifies the fixed package and config checksums, runs
`sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install`
for the local `.deb`, and adds the invoking account to `kvmswitch`. With
`--apply-config`, the tray-exported bundle's current config is deliberately
applied. The package rules grant
that group access to both hidraw and USB/libusb transports. Log in again and
unplug and replug the monitor USB path after the group change. The installed
config is `/etc/kvm-switcher/config.json`.

Fresh package installs receive the frozen Debian default, and existing installs
retain the package-managed/current conffile. The helper never applies the
exported config implicitly. For a tray-exported bundle, use the explicit option
above to carry its current config; the no-config path preserves an existing
system config during package upgrades.

Apt may still need to download distro dependencies.

Examples after installation:

```sh
kvm-switch
kvm-switch --profile Raspberry
kvm-switch --input hdmi1 --kvm typec
kvm-switch --input dp --kvm upstream
```

Bare `kvm-switch` changes the route using the one target marked
`"default": true`; it is not a probe. Legacy configs without a default remain
valid for named profiles, but need exactly one explicit true value for bare mode.

After the USB path has settled, run the delayed no-write diagnostic when needed:

```sh
sleep 15; kvm-switch --probe-hardware 2>&1 | tee ~/kvm-switcher-probe.log
```

The probe enumerates exactly one fixed interface, opens and closes it, and
performs no report I/O.

The helper does not add arbitrary users, trigger udev, retry apt, or roll back
an install. Use `sudo apt remove kvm-switcher` to remove the package while
retaining its registered config, or `sudo apt purge kvm-switcher` when the
package conffile should also be removed. Other candidate models are untested;
keep the monitor OSD available for attended recovery.

The Debian package default under `/etc` is intentionally frozen. Portable and
exported example configs may evolve independently, but an existing system
config always wins during no-config helper upgrades. After an install or
upgrade, reboot or use the attended `sudo udevadm control --reload-rules` command,
then unplug
and replug the monitor USB path. A one-time upgrade from an older package that
installed a postrm may still run that old removal hook; keep storage stable and
disconnect the HDMI/monitor USB path during that transition. Future package
upgrades have no postrm action.
