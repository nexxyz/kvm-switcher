#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
NEW_PACKAGE=${1:-}

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: Docker is unavailable; disposable apt lifecycle gate not run" >&2
    exit 2
fi
command -v timeout >/dev/null 2>&1 || {
    echo "FAIL: GNU timeout is required for the Docker apt lifecycle gate" >&2
    exit 1
}
command -v dpkg-deb >/dev/null 2>&1 || {
    echo "FAIL: dpkg-deb is required to derive the candidate package version" >&2
    exit 1
}
[ -s "$NEW_PACKAGE" ] || {
    echo "FAIL: new package is missing or empty" >&2
    exit 1
}

NEW_PACKAGE_NAME=$(basename -- "$NEW_PACKAGE")
NEW_PACKAGE_VERSION=$(dpkg-deb --field "$NEW_PACKAGE" Version) || {
    echo "FAIL: could not read candidate Debian package version" >&2
    exit 1
}
[ -n "$NEW_PACKAGE_VERSION" ] || {
    echo "FAIL: candidate Debian package version is empty" >&2
    exit 1
}
case "$NEW_PACKAGE_NAME" in
    kvm-switcher_*.deb) ;;
    *) echo "FAIL: unexpected Debian package filename" >&2; exit 1 ;;
esac

timeout 180s docker run --rm \
    --platform linux/amd64 \
    --env "NEW_PACKAGE_NAME=$NEW_PACKAGE_NAME" \
    --env "NEW_PACKAGE_VERSION=$NEW_PACKAGE_VERSION" \
    --volume "$REPO_ROOT:/repo:ro" \
    debian:trixie-slim \
    sh -c '
set -eu
apt-get update
apt-get install -y --no-install-recommends adduser dpkg udev

mkdir -p /usr/local/bin /tmp/old/DEBIAN /tmp/old/etc/kvm-switcher
cat > /usr/local/bin/udevadm <<"EOF"
#!/bin/sh
set -eu
printf "%s\n" "$*" >> /tmp/udevadm.log
exit 0
EOF
chmod 0755 /usr/local/bin/udevadm

cat > /tmp/old/DEBIAN/control <<"EOF"
Package: kvm-switcher
Version: 0.2.4-1
Section: utils
Priority: optional
Architecture: all
Maintainer: KVM Switcher Maintainers <noreply@example.invalid>
Description: KVM Switcher historical apt lifecycle fixture
 Historical package used only by the disposable apt test.
EOF
cat > /tmp/old/DEBIAN/conffiles <<"EOF"
/etc/kvm-switcher/config.json
EOF
cat > /tmp/old/DEBIAN/postinst <<"EOF"
#!/bin/sh
set -eu
udevadm control --reload-rules >/dev/null 2>&1 || true
EOF
cat > /tmp/old/DEBIAN/postrm <<"EOF"
#!/bin/sh
set -eu
udevadm control --reload-rules >/dev/null 2>&1 || true
EOF
chmod 0755 /tmp/old/DEBIAN/postinst /tmp/old/DEBIAN/postrm
printf "%s\n" "{\"targets\":[{\"name\":\"Legacy\",\"input\":\"hdmi1\",\"kvm\":\"typec\"}]}" > /tmp/old/etc/kvm-switcher/config.json
dpkg-deb --build --root-owner-group /tmp/old /tmp/kvm-switcher_0.2.4-1_all.deb >/dev/null
dpkg -i /tmp/kvm-switcher_0.2.4-1_all.deb >/tmp/old-install.log 2>&1
printf "%s\n" "{\"targets\":[{\"name\":\"Local\",\"input\":\"hdmi1\",\"kvm\":\"typec\"}]}" > /etc/kvm-switcher/config.json
local_hash=$(sha256sum /etc/kvm-switcher/config.json | awk "{print \$1}")

DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install "/repo/artifacts/$NEW_PACKAGE_NAME" </dev/null >/tmp/apt-upgrade.log 2>&1
! grep -q "What would you like to do" /tmp/apt-upgrade.log
grep -q "control --reload-rules" /tmp/udevadm.log
test "$(sha256sum /etc/kvm-switcher/config.json | awk "{print \$1}")" = "$local_hash"
test "$(dpkg-query -W -f="\${Version}" kvm-switcher)" = "$NEW_PACKAGE_VERSION"
test ! -e /var/lib/dpkg/info/kvm-switcher.postrm
! grep -q "udevadm" /var/lib/dpkg/info/kvm-switcher.postinst
apt-get purge -y kvm-switcher >/tmp/apt-purge.log 2>&1
test ! -e /etc/kvm-switcher/config.json
echo "PASS: disposable Docker apt conffile upgrade lifecycle"
'
