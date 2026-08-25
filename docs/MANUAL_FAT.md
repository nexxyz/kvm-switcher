# KVM Switcher attended FAT

This is the final attended gate. Run it only after these automated gates pass:

1. `scripts/Run-AutomatedFat.ps1`
2. `scripts/Run-LiveHardwareFat.ps1 -MonitorAwake`
3. `scripts/Run-InstalledProductFat.ps1 -AllowInstall -MonitorAwake`

The monitor must be awake and manual OSD recovery must remain available.

## Install and launch

- Run `artifacts/KvmSwitcher-Setup.exe` interactively and leave startup unchecked.
- Confirm the per-user destination, Start Menu entry, post-install tray launch, and
  `Ready` status.
- Launch it again and confirm there is still only one tray instance.

## Configuration and controls

- Confirm the existing configuration is preserved and valid changes reload.
- Confirm generated targets contain explicit `default` booleans with Windows true
  and Raspberry false; legacy configs without a default remain profile-only.
- In `Use on another host` > `Default exported target`, select a target and
  confirm the `default` flag is preserved in future portable and Debian exports
  for parameterless `kvm-switch`; confirm it does not affect Windows tray behavior.
- Confirm invalid configuration disables switching without retaining stale targets.
- Confirm hotkeys work, conflicts are reported, and Exit is unavailable while busy.
- Confirm MSI Gaming Intelligence blocks switching until it is closed.

## Hardware switching

From a known state, use both the tray menu and hotkey for:

- Windows: `DP` and KVM `Upstream`.
- Raspberry: `HDMI 1` and KVM `Type-C`.

Confirm display is requested before KVM, Type-C disconnect is handled as expected,
and there is no retry, rollback, or extra write. Restore a known route with the OSD
before each separate test.

## Export, startup, and uninstall

- Confirm copied commands, the portable ZIP, and the Debian install bundle match the current config.
- Confirm the tray's `Use on another host > Copy command` copies the selected
  target command without switching the monitor, and `Copy Debian install
  command` copies the one-line latest-bootstrap command without installing it.
  Confirm the copied Debian command uses
  `https://github.com/nexxyz/kvm-switcher/releases/latest/download/install-kvm-switcher.sh`
  and names the latest bundle fallback URL.
- Confirm the Debian bundle contains exactly
  `kvm-switcher_0.8.0-1_all.deb`, `config.json`, `install.sh`, `README.md`,
  `LICENSE`, and `SHA256SUMS`, with the internal manifest containing only the
  package and config hashes.
- Confirm the release asset directory contains exactly the four entries in
  `SHA256SUMS.txt`: `KvmSwitcher-Setup.exe`, `KvmSwitcher-win-x64.zip`,
  `install-kvm-switcher.sh`, and `kvm-switcher-debian.zip`, all with lowercase
  SHA256 values. Confirm `SHA256SUMS-debian.txt` contains exactly one lowercase
  hash for `kvm-switcher_0.8.0-1_all.deb`.
- Confirm the Windows ZIP and installed setup directory each contain the root
  `LICENSE` and `THIRD-PARTY-NOTICES.txt` files, and the portable ZIP contains
  the root `LICENSE`.
- With GitHub/download access available, perform the attended latest-bootstrap
  copy-command smoke check without running it as root. With GitHub unavailable,
  use the extracted `kvm-switcher-debian.zip` and confirm `sh ./install.sh` is
  the fallback command. The bundle avoids GitHub during installation, but apt
  may still need distro dependencies. For the frozen release, the immutable
  package and bundle use the `v0.8.0` tag; do not mix release tags.
- Confirm `sh ./install.sh` preserves the package/current conffile and
  `sh ./install.sh --apply-config` is the only deliberate exported-config replacement.
- Re-run setup with startup selected and confirm KVM Switcher starts after the next
  Windows sign-in.
- In the tray menu, confirm `Start with Windows` reflects the current startup state,
  and toggle it on and off successfully.
- Uninstall interactively and confirm application files, shortcuts, and startup entry
  are removed while `%LOCALAPPDATA%\KvmSwitcher\config.json` remains.

## Result

Record each section as **pass**, **fail**, or **not run**. Stop immediately if routing
is uncertain, an unexpected USB disconnect occurs, a second write is observed, or OSD
recovery cannot be confirmed.
