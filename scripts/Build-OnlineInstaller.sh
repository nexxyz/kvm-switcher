#!/bin/sh
set -eu
umask 022
export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
ARTIFACT_ROOT="$REPO_ROOT/artifacts"
DEB_NAME='kvm-switcher_0.8.1-1_all.deb'
DEB_PATH="$ARTIFACT_ROOT/$DEB_NAME"
DEBIAN_SUMS="$ARTIFACT_ROOT/SHA256SUMS-debian.txt"
CONFIG_SOURCE="$REPO_ROOT/packaging/debian/config.json"
BUNDLE_INSTALL="$REPO_ROOT/linux/debian-bundle/install.sh"
BUNDLE_README="$REPO_ROOT/linux/debian-bundle/README.md"
LICENSE_SOURCE="$REPO_ROOT/LICENSE"
TEMPLATE="$SCRIPT_DIR/install-kvm-switcher.sh.in"
BOOTSTRAP_OUTPUT="$ARTIFACT_ROOT/install-kvm-switcher.sh"
BUNDLE_OUTPUT="$ARTIFACT_ROOT/kvm-switcher-debian.zip"
FROZEN_CONFIG_SHA256='10a6c1a52b1a823bcf8b932ccf5f90de4cecf40eb6e18314ef6a91e541d14fdb'
RELEASE_TAG='v0.8.1'
REPOSITORY='nexxyz/kvm-switcher'

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

for command_name in awk chmod cp mktemp rm sed sha256sum zip; do
    need_command "$command_name"
done

[ -d "$ARTIFACT_ROOT" ] || fail 'artifacts directory is missing'
[ -s "$DEB_PATH" ] || fail "Debian package is missing or empty: $DEB_PATH"
[ -s "$DEBIAN_SUMS" ] || fail "Debian checksum manifest is missing or empty: $DEBIAN_SUMS"
[ -s "$CONFIG_SOURCE" ] || fail "frozen Debian config is missing or empty: $CONFIG_SOURCE"
[ -s "$BUNDLE_INSTALL" ] || fail "Debian bundle installer is missing or empty: $BUNDLE_INSTALL"
[ -s "$BUNDLE_README" ] || fail "Debian bundle README is missing or empty: $BUNDLE_README"
[ -s "$LICENSE_SOURCE" ] || fail "project license is missing or empty: $LICENSE_SOURCE"
[ -s "$TEMPLATE" ] || fail "online installer template is missing or empty: $TEMPLATE"

manifest_hash=$(awk -v package_name="$DEB_NAME" '
    NF == 0 { next }
    NF != 2 || $2 != package_name { invalid = 1; next }
    { count++; value = $1 }
    END {
        if (invalid || count != 1) exit 1
        print value
    }
' "$DEBIAN_SUMS") || fail 'SHA256SUMS-debian.txt must contain exactly one package entry'

deb_hash_line=$(sha256sum "$DEB_PATH") || fail 'could not hash the Debian package'
deb_hash=${deb_hash_line%% *}
[ "$deb_hash" = "$manifest_hash" ] || fail 'SHA256SUMS-debian.txt does not match the Debian package'

config_hash_line=$(sha256sum "$CONFIG_SOURCE") || fail 'could not hash the frozen Debian config'
config_hash=${config_hash_line%% *}
[ "$config_hash" = "$FROZEN_CONFIG_SHA256" ] || fail 'frozen Debian config hash does not match the approved pin'

package_url="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$DEB_NAME"
bundle_url="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/kvm-switcher-debian.zip"

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/kvm-switcher-online.XXXXXX")
trap 'rm -rf "$tmp_root"' 0 1 2 3 15
staging="$tmp_root/bundle"
mkdir -p "$staging"

sed \
    -e "s|@PACKAGE_URL@|$package_url|g" \
    -e "s|@BUNDLE_URL@|$bundle_url|g" \
    -e "s|@DEB_SHA256@|$deb_hash|g" \
    "$TEMPLATE" > "$tmp_root/install-kvm-switcher.sh"
chmod 0755 "$tmp_root/install-kvm-switcher.sh"

cp "$DEB_PATH" "$staging/$DEB_NAME"
cp "$CONFIG_SOURCE" "$staging/config.json"
cp "$BUNDLE_INSTALL" "$staging/install.sh"
cp "$BUNDLE_README" "$staging/README.md"
cp "$LICENSE_SOURCE" "$staging/LICENSE"
printf '%s  %s\n%s  %s\n' \
    "$deb_hash" "$DEB_NAME" \
    "$config_hash" 'config.json' > "$staging/SHA256SUMS"

rm -f "$BOOTSTRAP_OUTPUT" "$BUNDLE_OUTPUT"
(
    CDPATH= cd -- "$staging"
    zip -q -X "$BUNDLE_OUTPUT" "$DEB_NAME" config.json install.sh README.md LICENSE SHA256SUMS
)

[ -s "$BUNDLE_OUTPUT" ] || fail 'Debian fallback bundle was not created'
cp "$tmp_root/install-kvm-switcher.sh" "$BOOTSTRAP_OUTPUT"
chmod 0755 "$BOOTSTRAP_OUTPUT"

printf '%s\n' 'PASS: online Debian release assets built'
printf '%s\n' "Bootstrap: $BOOTSTRAP_OUTPUT"
printf '%s\n' "Fallback bundle: $BUNDLE_OUTPUT"
printf '%s\n' "Debian SHA256: $deb_hash"
