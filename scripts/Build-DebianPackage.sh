#!/bin/sh
set -eu
umask 022
export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SOURCE_ROOT="$REPO_ROOT/packaging/debian"
PYPROJECT="$REPO_ROOT/linux/pyproject.toml"
ARTIFACT_ROOT="$REPO_ROOT/artifacts"
SUMS="$ARTIFACT_ROOT/SHA256SUMS-debian.txt"
FROZEN_CONFIG_SHA256=10a6c1a52b1a823bcf8b932ccf5f90de4cecf40eb6e18314ef6a91e541d14fdb

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

need_command awk
need_command cmp
need_command dpkg-deb
need_command find
need_command gzip
need_command install
need_command mktemp
need_command sha256sum
need_command sort
need_command sed
need_command stat
need_command touch

[ -f "$PYPROJECT" ] || fail "linux/pyproject.toml is missing"
[ -d "$SOURCE_ROOT/DEBIAN" ] || fail "packaging/debian/DEBIAN is missing"
[ -f "$SOURCE_ROOT/control" ] || fail "packaging/debian/control is missing"
[ -f "$SOURCE_ROOT/config.json" ] || fail "frozen Debian config input is missing"
[ -f "$SOURCE_ROOT/DEBIAN/conffiles" ] || fail "Debian conffiles input is missing"
[ -f "$SOURCE_ROOT/DEBIAN/postinst" ] || fail "Debian postinst input is missing"
[ -f "$SOURCE_ROOT/changelog" ] || fail "Debian changelog input is missing"
[ -f "$SOURCE_ROOT/usr/bin/kvm-switch" ] || fail "Debian launcher input is missing"
[ -f "$SOURCE_ROOT/usr/lib/udev/rules.d/60-kvm-switcher.rules" ] || fail "Debian udev input is missing"
[ -f "$SOURCE_ROOT/README.Debian" ] || fail "Debian README input is missing"
[ -f "$SOURCE_ROOT/usr/share/doc/kvm-switcher/copyright" ] || fail "Debian copyright input is missing"
source_config_hash=$(sha256sum "$SOURCE_ROOT/config.json" | awk '{print $1}')
[ "$source_config_hash" = "$FROZEN_CONFIG_SHA256" ] || fail "frozen Debian config hash does not match the approved pin"

upstream_version=$(sed -n 's/^version = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' "$PYPROJECT" | sed -n '1p')
[ "$upstream_version" = "0.8.1" ] || fail "expected linux/pyproject.toml version 0.8.1"
debian_version="$upstream_version-1"
OUTPUT="$ARTIFACT_ROOT/kvm-switcher_${debian_version}_all.deb"

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
case "$SOURCE_DATE_EPOCH" in
    ''|*[!0-9]*) fail "SOURCE_DATE_EPOCH must be an integer" ;;
esac
export SOURCE_DATE_EPOCH

mkdir -p "$ARTIFACT_ROOT"
TMP_ROOT=$(mktemp -d)
PACKAGE_ROOT="$TMP_ROOT/package"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

mkdir -p \
    "$PACKAGE_ROOT/DEBIAN" \
    "$PACKAGE_ROOT/etc/kvm-switcher" \
    "$PACKAGE_ROOT/usr/bin" \
    "$PACKAGE_ROOT/usr/lib/kvm-switcher" \
    "$PACKAGE_ROOT/usr/lib/udev/rules.d" \
    "$PACKAGE_ROOT/usr/share/doc/kvm-switcher"

sed "s/@VERSION@/$debian_version/g" "$SOURCE_ROOT/control" > "$PACKAGE_ROOT/DEBIAN/control"
install -m 0644 "$SOURCE_ROOT/DEBIAN/conffiles" "$PACKAGE_ROOT/DEBIAN/conffiles"
install -m 0755 "$SOURCE_ROOT/DEBIAN/postinst" "$PACKAGE_ROOT/DEBIAN/postinst"
install -m 0755 "$SOURCE_ROOT/usr/bin/kvm-switch" "$PACKAGE_ROOT/usr/bin/kvm-switch"
install -m 0644 "$SOURCE_ROOT/usr/lib/udev/rules.d/60-kvm-switcher.rules" "$PACKAGE_ROOT/usr/lib/udev/rules.d/60-kvm-switcher.rules"
install -m 0644 "$SOURCE_ROOT/README.Debian" "$PACKAGE_ROOT/usr/share/doc/kvm-switcher/README.Debian"
install -m 0644 "$SOURCE_ROOT/usr/share/doc/kvm-switcher/copyright" "$PACKAGE_ROOT/usr/share/doc/kvm-switcher/copyright"
install -m 0644 "$REPO_ROOT/linux/kvmSwitcher.py" "$PACKAGE_ROOT/usr/lib/kvm-switcher/kvmSwitcher.py"
install -m 0644 "$SOURCE_ROOT/config.json" "$PACKAGE_ROOT/etc/kvm-switcher/config.json"
gzip -n -9 -c "$SOURCE_ROOT/changelog" > "$PACKAGE_ROOT/usr/share/doc/kvm-switcher/changelog.Debian.gz"
chmod 0644 "$PACKAGE_ROOT/usr/share/doc/kvm-switcher/changelog.Debian.gz"

package_config_hash=$(sha256sum "$PACKAGE_ROOT/etc/kvm-switcher/config.json" | awk '{print $1}')
[ "$source_config_hash" = "$package_config_hash" ] || fail "Debian config hash differs from frozen source"
cmp -s "$SOURCE_ROOT/config.json" "$PACKAGE_ROOT/etc/kvm-switcher/config.json" || fail "Debian config differs from frozen source"
! grep -q "udevadm" "$SOURCE_ROOT/DEBIAN/postinst" || fail "postinst must not invoke udevadm"

expected_files=$(cat <<'EOF'
DEBIAN/control
DEBIAN/conffiles
DEBIAN/postinst
etc/kvm-switcher/config.json
usr/bin/kvm-switch
usr/lib/kvm-switcher/kvmSwitcher.py
usr/lib/udev/rules.d/60-kvm-switcher.rules
usr/share/doc/kvm-switcher/README.Debian
usr/share/doc/kvm-switcher/changelog.Debian.gz
usr/share/doc/kvm-switcher/copyright
EOF
)
actual_files=$(find "$PACKAGE_ROOT" -type f -printf '%P\n' | sort)
[ "$actual_files" = "$(printf '%s\n' "$expected_files" | sort)" ] || fail "package root contains unexpected or missing files"

for directory in $(find "$PACKAGE_ROOT" -type d -print); do
    [ "$(stat -c '%a' "$directory")" = "755" ] || fail "directory mode is not 0755: $directory"
done
for file in $(find "$PACKAGE_ROOT" -type f -print); do
    case "$file" in
        "$PACKAGE_ROOT/DEBIAN/postinst"|"$PACKAGE_ROOT/usr/bin/kvm-switch")
            [ "$(stat -c '%a' "$file")" = "755" ] || fail "executable mode is not 0755: $file" ;;
        *)
            [ "$(stat -c '%a' "$file")" = "644" ] || fail "metadata mode is not 0644: $file" ;;
    esac
done

sh -n "$PACKAGE_ROOT/usr/bin/kvm-switch"
sh -n "$PACKAGE_ROOT/DEBIAN/postinst"

touch -h -d "@$SOURCE_DATE_EPOCH" $(find "$PACKAGE_ROOT" -print)
rm -f "$OUTPUT" "$SUMS"
dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$OUTPUT" >/dev/null

[ -s "$OUTPUT" ] || fail "Debian package was not created"
[ "$(dpkg-deb --field "$OUTPUT" Package)" = "kvm-switcher" ] || fail "unexpected Debian package name"
[ "$(dpkg-deb --field "$OUTPUT" Version)" = "$debian_version" ] || fail "unexpected Debian package version"
[ "$(dpkg-deb --field "$OUTPUT" Architecture)" = "all" ] || fail "unexpected Debian package architecture"
depends=$(dpkg-deb --field "$OUTPUT" Depends)
case "$depends" in
    *"python3 (>= 3.11)"*"python3-hid (>= 0.9.0.post3)"*"udev"*"adduser"*) ;;
    *) fail "Debian package dependencies are incomplete" ;;
esac

contents=$(dpkg-deb --contents "$OUTPUT" | awk '$NF !~ /\/$/ { print $NF }' | sort)
expected_contents=$(printf '%s\n' \
    "./etc/kvm-switcher/config.json" \
    "./usr/bin/kvm-switch" \
    "./usr/lib/kvm-switcher/kvmSwitcher.py" \
    "./usr/lib/udev/rules.d/60-kvm-switcher.rules" \
    "./usr/share/doc/kvm-switcher/README.Debian" \
    "./usr/share/doc/kvm-switcher/changelog.Debian.gz" \
    "./usr/share/doc/kvm-switcher/copyright" | sort)
[ "$contents" = "$expected_contents" ] || fail "Debian package contents are not exact"

dpkg-deb --control "$OUTPUT" "$TMP_ROOT/control"
[ "$(cat "$TMP_ROOT/control/conffiles")" = "/etc/kvm-switcher/config.json" ] || fail "Debian conffile metadata is incorrect"

if command -v lintian >/dev/null 2>&1; then
    lintian --pedantic "$OUTPUT" || fail "lintian reported actionable package issues"
else
    echo "NOTICE: lintian is not available in WSL; lintian check skipped"
fi

hash=$(sha256sum "$OUTPUT" | awk '{print $1}')
printf '%s  %s\n' "$hash" "${OUTPUT##*/}" > "$SUMS"

echo "PASS: Debian package built"
echo "Version: $debian_version"
echo "Package: $OUTPUT"
echo "SHA256: $hash"
