#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
NEW_PACKAGE=${1:-}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -n "$NEW_PACKAGE" ] || fail "usage: $0 NEW_DEB"
[ -s "$NEW_PACKAGE" ] || fail "new package is missing or empty"

for command_name in awk cmp dpkg dpkg-deb grep mktemp sha256sum sed tar; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
OLD_PACKAGE="$TMP_ROOT/kvm-switcher_0.2.4-1_all.deb"
OLD_ROOT="$TMP_ROOT/old-package"
FRESH_ROOT="$TMP_ROOT/fresh-root"
ROOT="$TMP_ROOT/upgrade-root"
FAKE_BIN="$TMP_ROOT/fake-bin"
LOG="$TMP_ROOT/maintainer.log"
mkdir -p \
    "$OLD_ROOT/DEBIAN" \
    "$OLD_ROOT/etc/kvm-switcher" \
    "$FRESH_ROOT/var/lib/dpkg" \
    "$ROOT/var/lib/dpkg" \
    "$FAKE_BIN"
: > "$FRESH_ROOT/var/lib/dpkg/status"
: > "$ROOT/var/lib/dpkg/status"
: > "$LOG"

cat > "$OLD_ROOT/DEBIAN/control" <<'EOF'
Package: kvm-switcher
Version: 0.2.4-1
Section: utils
Priority: optional
Architecture: all
Maintainer: KVM Switcher Maintainers <noreply@example.invalid>
Description: KVM Switcher historical lifecycle fixture
 Historical package used only by the disposable upgrade test.
EOF
cat > "$OLD_ROOT/DEBIAN/conffiles" <<'EOF'
/etc/kvm-switcher/config.json
EOF
cat > "$OLD_ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -eu
reload_udev() {
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules >/dev/null 2>&1 || true
    fi
}
action=${1:-}
case "$action" in
    configure) reload_udev ;;
    abort-upgrade|abort-remove|abort-deconfigure) reload_udev ;;
    *) exit 1 ;;
esac
EOF
cat > "$OLD_ROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -eu
reload_udev() {
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules >/dev/null 2>&1 || true
    fi
}
action=${1:-}
case "$action" in
    remove|purge|upgrade|failed-upgrade|abort-install|abort-upgrade|disappear) reload_udev ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$OLD_ROOT/DEBIAN/postinst" "$OLD_ROOT/DEBIAN/postrm"
printf '%s\n' '{"targets":[{"name":"Legacy","input":"hdmi1","kvm":"typec"}]}' > "$OLD_ROOT/etc/kvm-switcher/config.json"
dpkg-deb --build --root-owner-group "$OLD_ROOT" "$OLD_PACKAGE" >/dev/null
[ "$(dpkg-deb --field "$OLD_PACKAGE" Package)" = "kvm-switcher" ] || fail "historical fixture package name is incorrect"
[ "$(dpkg-deb --field "$OLD_PACKAGE" Version)" = "0.2.4-1" ] || fail "historical fixture version is incorrect"
[ -e "$OLD_ROOT/DEBIAN/postrm" ] || fail "historical fixture postrm is missing"
! grep -q '"default"' "$OLD_ROOT/etc/kvm-switcher/config.json" || fail "historical fixture unexpectedly has a default flag"

cat > "$FAKE_BIN/getent" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = group ] && exit 0
exit 1
EOF
cat > "$FAKE_BIN/addgroup" <<'EOF'
#!/bin/sh
set -eu
printf 'addgroup %s\n' "$*" >> "$FAKE_LOG"
exit 0
EOF
cat > "$FAKE_BIN/udevadm" <<'EOF'
#!/bin/sh
set -eu
printf 'udevadm %s\n' "$*" >> "$FAKE_LOG"
exit 0
EOF
chmod 0755 "$FAKE_BIN"/*
export FAKE_LOG="$LOG"
export PATH="$FAKE_BIN:$PATH"

NEW_CONTROL="$TMP_ROOT/new-control"
dpkg-deb --control "$NEW_PACKAGE" "$NEW_CONTROL"
[ ! -e "$NEW_CONTROL/postrm" ] || fail "new package contains postrm"
! grep -q "udevadm" "$NEW_CONTROL/postinst" || fail "new postinst invokes udevadm"
! grep -Eq '(^|[[:space:]/])kvm-switch([[:space:]]|$)' "$NEW_CONTROL/postinst" || fail "new postinst invokes KVM CLI"
NEW_CONFIG="$TMP_ROOT/new-config.json"
dpkg-deb --fsys-tarfile "$NEW_PACKAGE" | tar -xOf - ./etc/kvm-switcher/config.json > "$NEW_CONFIG"
SOURCE_CONFIG="$REPO_ROOT/packaging/debian/config.json"
cmp -s "$SOURCE_CONFIG" "$NEW_CONFIG" || fail "new package config differs from frozen source"

for action in configure abort-upgrade abort-remove abort-deconfigure; do
    "$NEW_CONTROL/postinst" "$action"
done
if "$NEW_CONTROL/postinst" >/dev/null 2>&1; then
    fail "postinst accepted a missing action"
fi
if "$NEW_CONTROL/postinst" unsupported-action >/dev/null 2>&1; then
    fail "postinst accepted an unknown action"
fi
! grep -q "udevadm" "$LOG" || fail "new postinst invoked udevadm"

run_dpkg_at() {
    root=$1
    shift
    dpkg --force-not-root --force-script-chrootless --root="$root" \
        --admindir="$root/var/lib/dpkg" --instdir="$root" "$@"
}

if ! run_dpkg_at "$FRESH_ROOT" --unpack "$NEW_PACKAGE" > "$TMP_ROOT/fresh-unpack.log" 2>&1; then
    cat "$TMP_ROOT/fresh-unpack.log" >&2
    fail "fresh package unpack failed"
fi
if ! run_dpkg_at "$FRESH_ROOT" --force-depends --configure kvm-switcher > "$TMP_ROOT/fresh-configure.log" 2>&1; then
    cat "$TMP_ROOT/fresh-configure.log" >&2
    fail "fresh package configure failed"
fi
cmp -s "$SOURCE_CONFIG" "$FRESH_ROOT/etc/kvm-switcher/config.json" || fail "fresh install did not receive frozen config"
! grep -q "udevadm" "$TMP_ROOT/fresh-configure.log" || fail "fresh new postinst invoked udevadm"

if ! run_dpkg_at "$ROOT" --unpack "$OLD_PACKAGE" > "$TMP_ROOT/old-unpack.log" 2>&1; then
    cat "$TMP_ROOT/old-unpack.log" >&2
    fail "historical fixture unpack failed"
fi
: > "$LOG"
if ! run_dpkg_at "$ROOT" --force-depends --configure kvm-switcher > "$TMP_ROOT/old-configure.log" 2>&1; then
    cat "$TMP_ROOT/old-configure.log" >&2
    fail "historical fixture configure failed"
fi
grep -q "udevadm" "$LOG" || fail "historical postinst udev reload was not observed"

LOCAL_CONFIG="$ROOT/etc/kvm-switcher/config.json"
[ -f "$LOCAL_CONFIG" ] || fail "historical fixture did not install its conffile"
printf '%s\n' '{"targets":[{"name":"Local","input":"hdmi1","kvm":"typec"}]}' > "$LOCAL_CONFIG"
LOCAL_HASH=$(sha256sum "$LOCAL_CONFIG" | awk '{print $1}')

: > "$LOG"
if ! run_dpkg_at "$ROOT" --force-confold --unpack "$NEW_PACKAGE" < /dev/null > "$TMP_ROOT/upgrade-unpack.log" 2>&1; then
    cat "$TMP_ROOT/upgrade-unpack.log" >&2
    fail "new package upgrade unpack failed"
fi
grep -q "udevadm" "$LOG" || fail "historical postrm udev reload was not observed"
if grep -q "Configuration file" "$TMP_ROOT/upgrade-unpack.log"; then
    fail "upgrade prompted for a conffile"
fi
: > "$LOG"
if ! run_dpkg_at "$ROOT" --force-confold --force-depends --configure kvm-switcher > "$TMP_ROOT/new-configure.log" 2>&1; then
    cat "$TMP_ROOT/new-configure.log" >&2
    fail "new package configure failed"
fi
! grep -q "udevadm" "$LOG" || fail "new postinst invoked udevadm"
UPGRADED_HASH=$(sha256sum "$LOCAL_CONFIG" | awk '{print $1}')
[ "$UPGRADED_HASH" = "$LOCAL_HASH" ] || fail "upgrade changed the locally modified conffile"

VERSION=$(dpkg-query --admindir="$ROOT/var/lib/dpkg" -W -f='${Version}' kvm-switcher)
EXPECTED_VERSION=$(sed -n 's/^version = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' "$REPO_ROOT/linux/pyproject.toml" | sed -n '1p')-1
[ "$VERSION" = "$EXPECTED_VERSION" ] || fail "fixture package version is incorrect"
[ "$(dpkg-deb --field "$NEW_PACKAGE" Version)" = "$EXPECTED_VERSION" ] || fail "new package version is incorrect"

run_dpkg_at "$ROOT" --remove kvm-switcher > "$TMP_ROOT/remove.log" 2>&1
[ -f "$LOCAL_CONFIG" ] || fail "remove did not preserve the conffile"
[ "$(sha256sum "$LOCAL_CONFIG" | awk '{print $1}')" = "$LOCAL_HASH" ] || fail "remove changed the conffile"
run_dpkg_at "$ROOT" --purge kvm-switcher > "$TMP_ROOT/purge.log" 2>&1
[ ! -e "$LOCAL_CONFIG" ] || fail "purge did not remove the registered conffile"

sh "$REPO_ROOT/scripts/Test-DebianBundleInstall.sh"
echo "PASS: Debian 0.2.4 to candidate dpkg lifecycle preserved config, observed old postrm, and retained purge semantics"
