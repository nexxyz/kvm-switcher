#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SOURCE_INSTALL="$REPO_ROOT/linux/debian-bundle/install.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$SOURCE_INSTALL" ] || fail "source Debian bundle install.sh is missing"

FAKE_BIN="$TMP_ROOT/fake-bin"
BUNDLE="$TMP_ROOT/bundle"
SYSTEM_ROOT="$TMP_ROOT/system"
PACKAGE_CONFIG="$TMP_ROOT/package-config.json"
LOG="$TMP_ROOT/commands.log"
mkdir -p "$FAKE_BIN" "$BUNDLE" "$SYSTEM_ROOT"
: > "$LOG"

cp "$SOURCE_INSTALL" "$BUNDLE/install.sh"
printf '%s\n' "private package bytes" > "$BUNDLE/kvm-switcher_0.8.1-1_all.deb"
cp "$REPO_ROOT/linux/config.example.json" "$BUNDLE/config.json"
cp "$REPO_ROOT/packaging/debian/config.json" "$PACKAGE_CONFIG"
(CDPATH= cd -- "$BUNDLE" && sha256sum kvm-switcher_0.8.1-1_all.deb config.json > SHA256SUMS)

cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
set -eu
printf 'sudo %s\n' "$*" >> "$FAKE_LOG"
"$@"
EOF
cat > "$FAKE_BIN/apt-get" <<'EOF'
#!/bin/sh
set -eu
printf 'apt-get %s\n' "$*" >> "$FAKE_LOG"
[ "${FAKE_APT_FAIL:-0}" -eq 0 ] || exit 1
if [ ! -e "$FAKE_SYSTEM_CONFIG" ]; then
    cp "$FAKE_PACKAGE_CONFIG" "$FAKE_SYSTEM_CONFIG"
fi
EOF
cat > "$FAKE_BIN/id" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
    -u) printf '%s\n' "${FAKE_ID_U:-1000}" ;;
    -un) printf '%s\n' fatuser ;;
    *) exit 1 ;;
esac
EOF
cat > "$FAKE_BIN/install" <<'EOF'
#!/bin/sh
set -eu
printf 'install %s\n' "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "-o" ]; then shift 2; fi
if [ "${1:-}" = "-g" ]; then shift 2; fi
exec /usr/bin/install "$@"
EOF
cat > "$FAKE_BIN/adduser" <<'EOF'
#!/bin/sh
set -eu
printf 'adduser %s\n' "$*" >> "$FAKE_LOG"
exit 0
EOF
cat > "$FAKE_BIN/udevadm" <<'EOF'
#!/bin/sh
set -eu
printf 'udevadm %s\n' "$*" >> "$FAKE_LOG"
exit 1
EOF
chmod 0755 "$FAKE_BIN"/* "$BUNDLE/install.sh"

export FAKE_LOG="$LOG"
export FAKE_PACKAGE_CONFIG="$PACKAGE_CONFIG"
export FAKE_SYSTEM_CONFIG="$SYSTEM_ROOT/config.json"
export KVM_SWITCHER_SYSTEM_CONFIG="$SYSTEM_ROOT/config.json"
export PATH="$FAKE_BIN:$PATH"

reset_case() {
    rm -f "$SYSTEM_ROOT/config.json"
    : > "$LOG"
    export FAKE_APT_FAIL=0
    export FAKE_ID_U=1000
}

run_success() {
    sh "$BUNDLE/install.sh" "$@" </dev/null || fail "expected helper success: $*"
}

run_failure() {
    if sh "$BUNDLE/install.sh" "$@" </dev/null; then
        fail "expected helper failure: $*"
    fi
}

assert_apt_and_account() {
    grep -F "sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install $BUNDLE/kvm-switcher_0.8.1-1_all.deb" "$LOG" >/dev/null || fail "apt did not receive the exact noninteractive confold command"
    [ "$(grep -c '^sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install ' "$LOG")" -eq 1 ] || fail "apt was retried or flags changed"
    grep -F "sudo adduser fatuser kvmswitch" "$LOG" >/dev/null || fail "adduser did not receive id -un account"
    ! grep -F "udevadm" "$LOG" >/dev/null || fail "helper invoked udevadm"
}

assert_no_config_install() {
    ! grep -F "install -o root -g root -m 0644" "$LOG" >/dev/null || fail "helper applied config without --apply-config"
}

reset_case
run_success
cmp "$PACKAGE_CONFIG" "$SYSTEM_ROOT/config.json" || fail "fresh package install did not provide frozen config"
assert_apt_and_account
assert_no_config_install

reset_case
printf '%s\n' preserved > "$SYSTEM_ROOT/config.json"
run_success
grep -Fx preserved "$SYSTEM_ROOT/config.json" >/dev/null || fail "installed config was not preserved"
assert_apt_and_account
assert_no_config_install

reset_case
printf '%s\n' retained > "$SYSTEM_ROOT/config.json"
run_success
grep -Fx retained "$SYSTEM_ROOT/config.json" >/dev/null || fail "removed-package config was not preserved"
assert_no_config_install

reset_case
run_success
cmp "$PACKAGE_CONFIG" "$SYSTEM_ROOT/config.json" || fail "missing config did not receive frozen package config"
assert_no_config_install

reset_case
printf '%s\n' replace-me > "$SYSTEM_ROOT/config.json"
run_success --apply-config
cmp "$BUNDLE/config.json" "$SYSTEM_ROOT/config.json" || fail "--apply-config did not replace config"
grep -F "install -o root -g root -m 0644" "$LOG" >/dev/null || fail "--apply-config did not install config"

reset_case
(CDPATH= cd -- "$BUNDLE" && {
    printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000  kvm-switcher_0.8.1-1_all.deb"
    sha256sum config.json
}) > "$BUNDLE/SHA256SUMS"
run_failure
[ ! -s "$LOG" ] || fail "checksum failure invoked sudo"
(CDPATH= cd -- "$BUNDLE" && sha256sum kvm-switcher_0.8.1-1_all.deb config.json > SHA256SUMS)

reset_case
export FAKE_APT_FAIL=1
run_failure
! grep -F "install -o root -g root -m 0644" "$LOG" >/dev/null || fail "apt failure caused config install"
! grep -F "sudo adduser" "$LOG" >/dev/null || fail "apt failure caused group action"

reset_case
export FAKE_ID_U=0
run_failure
[ ! -s "$LOG" ] || fail "root refusal invoked sudo"

reset_case
run_failure --unknown
[ ! -s "$LOG" ] || fail "unknown argument invoked a command"

reset_case
export KVM_SWITCHER_SYSTEM_CONFIG=""
run_failure --apply-config
[ ! -s "$LOG" ] || fail "empty config override invoked a command"

reset_case
export KVM_SWITCHER_SYSTEM_CONFIG="relative/config.json"
run_failure --apply-config
[ ! -s "$LOG" ] || fail "relative config override invoked a command"

echo "PASS: Debian bundle install helper behavior cases"
