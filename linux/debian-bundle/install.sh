#!/bin/sh
set -eu

DEB_NAME=kvm-switcher_0.8.1-1_all.deb
CONFIG_NAME=config.json
MANIFEST_NAME=SHA256SUMS

fail() {
    echo "error: $*" >&2
    exit 1
}

apply_config=0
case "$#" in
    0) ;;
    1)
        [ "$1" = "--apply-config" ] || fail "unsupported argument"
        apply_config=1
        ;;
    *) fail "unsupported arguments" ;;
esac

[ "$(id -u)" -ne 0 ] || fail "run as a normal user, not root"
account=$(id -un)
[ -n "$account" ] || fail "could not determine the invoking account"

for command_name in sudo env apt-get sha256sum id; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
absolute_deb="$bundle_dir/$DEB_NAME"
config_source="$bundle_dir/$CONFIG_NAME"
manifest="$bundle_dir/$MANIFEST_NAME"
[ -f "$absolute_deb" ] && [ -s "$absolute_deb" ] || fail "package file is missing or empty"
[ -f "$config_source" ] && [ -s "$config_source" ] || fail "config.json is missing or empty"
[ -f "$manifest" ] && [ -s "$manifest" ] || fail "SHA256SUMS is missing or empty"

deb_seen=0
config_seen=0
line_count=0
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || fail "SHA256SUMS contains an empty line"
    case "$line" in
        *"  $DEB_NAME")
            [ "$deb_seen" -eq 0 ] || fail "SHA256SUMS contains a duplicate package entry"
            deb_seen=1
            ;;
        *"  $CONFIG_NAME")
            [ "$config_seen" -eq 0 ] || fail "SHA256SUMS contains a duplicate config entry"
            config_seen=1
            ;;
        *) fail "SHA256SUMS contains an unknown entry" ;;
    esac
    line_count=$((line_count + 1))
done < "$manifest"
[ "$line_count" -eq 2 ] && [ "$deb_seen" -eq 1 ] && [ "$config_seen" -eq 1 ] || fail "SHA256SUMS must contain exactly the package and config entries"

(CDPATH= cd -- "$bundle_dir" && sha256sum -c "$MANIFEST_NAME") || fail "bundle checksum verification failed"

if [ "$apply_config" -eq 1 ]; then
    if [ "${KVM_SWITCHER_SYSTEM_CONFIG+x}" = x ]; then
        system_config=$KVM_SWITCHER_SYSTEM_CONFIG
    else
        system_config=/etc/kvm-switcher/config.json
    fi
    [ -n "$system_config" ] || fail "KVM_SWITCHER_SYSTEM_CONFIG must be nonempty"
    case "$system_config" in
        /*) ;;
        *) fail "KVM_SWITCHER_SYSTEM_CONFIG must be an absolute path" ;;
    esac
fi

sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install "$absolute_deb"

if [ "$apply_config" -eq 1 ]; then
    sudo install -o root -g root -m 0644 "$config_source" "$system_config"
fi

sudo adduser "$account" kvmswitch

if [ "$apply_config" -eq 1 ]; then
    echo "Configuration applied to $system_config"
else
    echo "Configuration preserved by dpkg/conffile policy"
    echo "Use --apply-config to replace it deliberately on a future run"
fi
echo "Log in again after the kvmswitch group change, then unplug and replug the monitor USB path."
