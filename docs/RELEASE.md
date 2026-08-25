# Release gates

KVM Switcher is not published automatically. Release `v0.8.1` is prepared for
the public repository `https://github.com/nexxyz/kvm-switcher` only after all
gates pass.

## Verification gates

1. **Local automated release verification**: run
   `scripts/Run-AutomatedFat.ps1`. This builds/tests the Windows product,
   compiles the local Inno installer, runs the portable and Debian checks, and
   creates these local assets:
   `KvmSwitcher-Setup.exe`, `KvmSwitcher-win-x64.zip`,
   `install-kvm-switcher.sh`, and `kvm-switcher-debian.zip`.
   The Windows publish staging, ZIP, and installed setup directory must each
   contain `LICENSE` and `THIRD-PARTY-NOTICES.txt`. The portable ZIP contains
   the root `LICENSE`. The Debian fallback bundle contains exactly six entries:
   the package, `config.json`, `install.sh`, `README.md`, `LICENSE`, and
   `SHA256SUMS`; its internal checksum scope remains exactly package plus
   config.
   `artifacts/SHA256SUMS.txt` must contain exactly four lowercase entries for
   those four names. `artifacts/SHA256SUMS-debian.txt` must contain exactly one
   lowercase entry for `kvm-switcher_0.8.1-1_all.deb`.
2. **Passive live-hardware FAT**: when the User and monitor are present, run
   `scripts/Run-LiveHardwareFat.ps1 -MonitorAwake`. It verifies all four
   release asset hashes and exact bundle contents, then runs the installed-free
   `--probe-hardware` discovery/open/close check; it performs no report I/O.
3. **Installed-product automated FAT**: when the User explicitly authorizes
   installation, run
   `scripts/Run-InstalledProductFat.ps1 -AllowInstall -MonitorAwake`. It
   verifies the four-entry manifest and exact bundles, installs, probes,
   performs reinstall startup smoke, and uninstalls while preserving any
   pre-existing configuration. It does not run the tray or perform
   route-changing HID writes.
4. **Full installed-product FAT**: complete the attended checklist in
   `MANUAL_FAT.md` against the installed application, including tray,
   configuration, hotkeys, startup, switching, export, online installer copy,
   fallback bundle, and OSD recovery.

No automated script alone is full FAT. The full installed-product gate is
reserved for all three automated gates plus the attended manual checklist.

The Debian package is `kvm-switcher_0.8.1-1_all.deb`. Its release assets use
the immutable URLs below:

```text
https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.1/install-kvm-switcher.sh
https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.1/kvm-switcher_0.8.1-1_all.deb
https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.1/SHA256SUMS-debian.txt
https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.1/kvm-switcher-debian.zip
```

The latest bootstrap convenience URL is:

```text
https://github.com/nexxyz/kvm-switcher/releases/latest/download/install-kvm-switcher.sh
```

The bootstrap embeds the package URL and final package SHA256, verifies the
package before `sudo`, and recommends the immutable bundle plus
`sh ./install.sh` when download or checksum verification fails. The bundle
avoids GitHub during installation, but `apt` may still need distro
dependencies; it is not a fully offline claim.

## Publication procedure

These commands are an attended publication procedure, not an automated CI
step. Do not run them until the artifacts are frozen and the gates above pass.
The release has not been published by this repository workflow.

```sh
gh auth status
gh release create v0.8.1 --repo nexxyz/kvm-switcher \
  --title "KVM Switcher v0.8.1" \
  --notes "See the repository release notes and compatibility guidance." \
  artifacts/KvmSwitcher-Setup.exe \
  artifacts/KvmSwitcher-win-x64.zip \
  artifacts/install-kvm-switcher.sh \
  artifacts/kvm-switcher-debian.zip \
  artifacts/kvm-switcher_0.8.1-1_all.deb \
  artifacts/SHA256SUMS.txt \
  artifacts/SHA256SUMS-debian.txt
```

If the tag already has a release and only the frozen assets need uploading,
use:

```sh
gh release upload v0.8.1 --repo nexxyz/kvm-switcher --clobber \
  artifacts/KvmSwitcher-Setup.exe \
  artifacts/KvmSwitcher-win-x64.zip \
  artifacts/install-kvm-switcher.sh \
  artifacts/kvm-switcher-debian.zip \
  artifacts/kvm-switcher_0.8.1-1_all.deb \
  artifacts/SHA256SUMS.txt \
  artifacts/SHA256SUMS-debian.txt
```

Confirm the release page and all asset names before distributing any command.

## Latest-URL smoke checks

After an attended publication, check redirects and non-empty downloads without
executing the installer:

```sh
for asset in install-kvm-switcher.sh kvm-switcher-debian.zip; do
  wget --spider --https-only --timeout=30 --tries=1 \
    "https://github.com/nexxyz/kvm-switcher/releases/latest/download/$asset"
done
wget --spider --https-only --timeout=30 --tries=1 \
  https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.1/kvm-switcher_0.8.1-1_all.deb
```

Also compare the published package with `SHA256SUMS-debian.txt`; never mix a
bootstrap, package, bundle, or checksum file from different release tags.

`Run-AutomatedFat.ps1` and CI run
`scripts/Test-DebianPackageLifecycle.sh` against a deterministic 0.2.4 fixture
and the candidate `.deb`. Before release, also run
`scripts/Test-DebianAptLifecycle.sh` for the disposable Docker/apt upgrade
gate. Neither test modifies a user host or SD card.

The bundle helper installs or upgrades while preserving the dpkg conffile. It
never applies the exported bundle config implicitly; use
`sh ./install.sh --apply-config` only when deliberately replacing the current
config. The installer is per-user and does not remove
`%LOCALAPPDATA%\KvmSwitcher\config.json`.
