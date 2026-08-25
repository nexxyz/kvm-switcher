#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
BUILD_SCRIPT="$SCRIPT_DIR/Build-OnlineInstaller.sh"
TEMPLATE="$SCRIPT_DIR/install-kvm-switcher.sh.in"
DEB_NAME='kvm-switcher_0.8.2-1_all.deb'
DEB_PATH="$REPO_ROOT/artifacts/$DEB_NAME"
BOOTSTRAP="$REPO_ROOT/artifacts/install-kvm-switcher.sh"
BUNDLE="$REPO_ROOT/artifacts/kvm-switcher-debian.zip"
CONFIG_SOURCE="$REPO_ROOT/packaging/debian/config.json"
REAL_MKTEMP=$(command -v mktemp)
REAL_SHA256SUM=$(command -v sha256sum)
REAL_MV=$(command -v mv)

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

contains() {
    needle=$1
    file=$2
    grep -F "$needle" "$file" >/dev/null 2>&1 || fail "missing expected text in $file: $needle"
}

not_contains() {
    needle=$1
    file=$2
    if grep -F "$needle" "$file" >/dev/null 2>&1; then
        fail "unexpected text in $file: $needle"
    fi
}

assert_no_log_entry() {
    command_name=$1
    if grep -E "^$command_name " "$FAKE_LOG" >/dev/null 2>&1; then
        fail "unexpected fake command invocation: $command_name"
    fi
}

assert_temp_cleanup() {
    while IFS= read -r temp_path || [ -n "$temp_path" ]; do
        [ -n "$temp_path" ] || continue
        [ ! -e "$temp_path" ] || fail "installer temporary path was not removed: $temp_path"
    done < "$TEMP_PATH_LOG"
}

count_log_entries() {
    command_name=$1
    count=$(grep -c "^$command_name " "$FAKE_LOG" || :)
    printf '%s\n' "$count"
}

TMP_ROOT=$($REAL_MKTEMP -d "${TMPDIR:-/tmp}/kvm-switcher-online-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15
FAKE_BIN="$TMP_ROOT/bin"
FAKE_LOG="$TMP_ROOT/fake.log"
TEMP_PATH_LOG="$TMP_ROOT/temp-paths.log"
FAKE_CONFIG_DIR="$TMP_ROOT/etc/kvm-switcher"
FAKE_CONFIG_TARGET="$FAKE_CONFIG_DIR/config.json"
CONFIG_FILE="$TMP_ROOT/input-config.json"
MALFORMED_CONFIG="$TMP_ROOT/malformed-config.json"
EMPTY_CONFIG="$TMP_ROOT/empty-config.json"
NONREGULAR_CONFIG="$TMP_ROOT/config-directory"
SENTINEL_FILE="$TMP_ROOT/sentinel-config.json"
mkdir -p "$FAKE_BIN"
mkdir -p "$FAKE_CONFIG_DIR"
printf '%s\n' '{"targets":[{"name":"Candidate","input":"hdmi1","kvm":"typec"}]}' > "$CONFIG_FILE"
printf '%s\n' '{"targets":' > "$MALFORMED_CONFIG"
: > "$EMPTY_CONFIG"
mkdir -p "$NONREGULAR_CONFIG"
: > "$FAKE_LOG"
: > "$TEMP_PATH_LOG"
export FAKE_BIN FAKE_LOG TEMP_PATH_LOG TMP_ROOT FAKE_CONFIG_DIR FAKE_CONFIG_TARGET
export CONFIG_FILE MALFORMED_CONFIG EMPTY_CONFIG NONREGULAR_CONFIG SENTINEL_FILE
export REAL_MKTEMP REAL_SHA256SUM REAL_MV
PATH="$FAKE_BIN:$PATH"
export PATH

cat > "$FAKE_BIN/wget" <<'EOF'
#!/bin/sh
printf 'wget %s\n' "$*" >> "$FAKE_LOG"
output_path=${5#--output-document=}
[ -n "$output_path" ] || exit 2
case "$FAKE_MODE" in
    download-failure) exit 8 ;;
    empty) : > "$output_path" ;;
    hash-mismatch) printf '%s\n' 'not the Debian package' > "$output_path" ;;
    success|apt-failure|apt-installs-adduser|config-success|validator-failure|atomic-failure|apt-failure-config) cp "$TEST_PACKAGE" "$output_path" ;;
    config-download-failure) exit 8 ;;
    config-hash-mismatch) printf '%s\n' 'not the Debian package' > "$output_path" ;;
    *) exit 9 ;;
esac
EOF

cat > "$FAKE_BIN/mktemp" <<'EOF'
#!/bin/sh
printf 'mktemp %s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    /etc/kvm-switcher/*)
        path=$("$REAL_MKTEMP" "$FAKE_CONFIG_DIR/${1##*/}") || exit 1
        ;;
    *)
        path=$("$REAL_MKTEMP" "$@") || exit 1
        ;;
esac
printf '%s\n' "$path" >> "$TEMP_PATH_LOG"
printf '%s\n' "$path"
EOF

cat > "$FAKE_BIN/sha256sum" <<'EOF'
#!/bin/sh
printf 'sha256sum %s\n' "$*" >> "$FAKE_LOG"
exec "$REAL_SHA256SUM" "$@"
EOF

cat > "$FAKE_BIN/id" <<'EOF'
#!/bin/sh
printf 'id %s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    -u) printf '%s\n' "$TEST_ID_UID" ;;
    -un) printf '%s\n' "$TEST_ACCOUNT" ;;
    *) exit 2 ;;
esac
EOF

cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$FAKE_LOG"
"$@"
EOF

cat > "$FAKE_BIN/kvm-switch" <<'EOF'
#!/bin/sh
printf 'kvm-switch %s\n' "$*" >> "$FAKE_LOG"
[ "$FAKE_VALIDATOR_MODE" != validator-failure ] || exit 17
EOF

cat > "$FAKE_BIN/env" <<'EOF'
#!/bin/sh
printf 'env %s\n' "$*" >> "$FAKE_LOG"
export "$1"
shift
"$@"
EOF

cat > "$FAKE_BIN/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$FAKE_LOG"
if [ "$FAKE_MODE" = apt-failure ] || [ "$FAKE_MODE" = apt-failure-config ]; then
    exit 12
fi
if [ "$FAKE_MODE" = apt-installs-adduser ]; then
    cat > "$FAKE_BIN/adduser" <<'ADDUSER'
#!/bin/sh
printf 'adduser %s\n' "$*" >> "$FAKE_LOG"
ADDUSER
    chmod 0755 "$FAKE_BIN/adduser"
fi
EOF

cat > "$FAKE_BIN/install" <<'EOF'
#!/bin/sh
printf 'install %s\n' "$*" >> "$FAKE_LOG"
[ "$FAKE_MODE" != atomic-failure ] || exit 19
cp "$7" "$8"
chmod 0644 "$8"
EOF

cat > "$FAKE_BIN/mv" <<'EOF'
#!/bin/sh
printf 'mv %s\n' "$*" >> "$FAKE_LOG"
if [ "$1" = -f ] && [ "$3" = /etc/kvm-switcher/config.json ]; then
    exec "$REAL_MV" -f "$2" "$FAKE_CONFIG_TARGET"
fi
exec "$REAL_MV" "$@"
EOF

cat > "$FAKE_BIN/adduser" <<'EOF'
#!/bin/sh
printf 'adduser %s\n' "$*" >> "$FAKE_LOG"
EOF

chmod 0755 "$FAKE_BIN"/*

[ -s "$DEB_PATH" ] || fail 'the Debian artifact prerequisite is missing'
sh -n "$TEMPLATE" "$SCRIPT_DIR/Test-OnlineInstaller.sh"
(CDPATH= cd "$SCRIPT_DIR" && tr -d '\r' < "$BUILD_SCRIPT" | sh -n)
(CDPATH= cd "$SCRIPT_DIR" && tr -d '\r' < "$BUILD_SCRIPT" | sh) >/dev/null
[ -s "$BOOTSTRAP" ] || fail 'generated bootstrap is missing'
[ -s "$BUNDLE" ] || fail 'generated fallback bundle is missing'
contains '/usr/bin/kvm-switch --validate-config' "$BOOTSTRAP"
CONFIG_BOOTSTRAP="$TMP_ROOT/config-installer.sh"
sed "s|/usr/bin/kvm-switch|$FAKE_BIN/kvm-switch|g" "$BOOTSTRAP" > "$CONFIG_BOOTSTRAP"
chmod 0755 "$CONFIG_BOOTSTRAP"
sh -n "$BOOTSTRAP" "$CONFIG_BOOTSTRAP"

deb_hash_line=$($REAL_SHA256SUM "$DEB_PATH")
deb_hash=${deb_hash_line%% *}
config_hash_line=$($REAL_SHA256SUM "$CONFIG_SOURCE")
config_hash=${config_hash_line%% *}
PACKAGE_URL="https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.2/$DEB_NAME"
BUNDLE_URL='https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.2/kvm-switcher-debian.zip'
contains "$PACKAGE_URL" "$BOOTSTRAP"
contains "$BUNDLE_URL" "$BOOTSTRAP"
contains "$deb_hash" "$BOOTSTRAP"
not_contains '@PACKAGE_URL@' "$BOOTSTRAP"
contains 'Export Debian install bundle...' "$BOOTSTRAP"
contains 'sh ./install.sh --apply-config' "$BOOTSTRAP"

printf '%s\n' "$DEB_NAME" config.json install.sh README.md LICENSE SHA256SUMS > "$TMP_ROOT/expected-entries"
unzip -Z1 "$BUNDLE" > "$TMP_ROOT/actual-entries"
cmp -s "$TMP_ROOT/expected-entries" "$TMP_ROOT/actual-entries" || fail 'fallback bundle entries are not exact'
printf '%s  %s\n%s  config.json\n' "$deb_hash" "$DEB_NAME" "$config_hash" > "$TMP_ROOT/expected-sums"
unzip -p "$BUNDLE" SHA256SUMS > "$TMP_ROOT/actual-sums"
cmp -s "$TMP_ROOT/expected-sums" "$TMP_ROOT/actual-sums" || fail 'fallback bundle checksums are not exact'
unzip -p "$BUNDLE" config.json | cmp -s "$CONFIG_SOURCE" - || fail 'fallback config differs from frozen config'
unzip -p "$BUNDLE" install.sh | cmp -s "$REPO_ROOT/linux/debian-bundle/install.sh" - || fail 'fallback installer differs from existing installer'
unzip -p "$BUNDLE" README.md | cmp -s "$REPO_ROOT/linux/debian-bundle/README.md" - || fail 'fallback README differs from existing README'
unzip -p "$BUNDLE" LICENSE | cmp -s "$REPO_ROOT/LICENSE" - || fail 'fallback license differs from root LICENSE'

TEST_PACKAGE="$DEB_PATH"
TEST_ACCOUNT='online-user'
export TEST_PACKAGE TEST_ACCOUNT

reset_case() {
    FAKE_MODE=$1
    TEST_ID_UID=${2:-1000}
    export FAKE_MODE TEST_ID_UID
    : > "$FAKE_LOG"
    : > "$TEMP_PATH_LOG"
    if [ "$FAKE_MODE" = apt-installs-adduser ]; then
        rm -f "$FAKE_BIN/adduser"
    fi
    if [ "$FAKE_MODE" = validator-failure ]; then
        FAKE_VALIDATOR_MODE=validator-failure
    else
        FAKE_VALIDATOR_MODE=valid
    fi
    export FAKE_VALIDATOR_MODE
}

reset_config_sentinel() {
    printf '%s\n' 'sentinel-existing-config' > "$SENTINEL_FILE"
    cp "$SENTINEL_FILE" "$FAKE_CONFIG_TARGET"
}

assert_config_sentinel() {
    cmp -s "$SENTINEL_FILE" "$FAKE_CONFIG_TARGET" || fail 'existing config sentinel was changed'
}

run_failure_with() {
    bootstrap=$1
    output=$2
    shift 2
    if sh "$bootstrap" "$@" > "$output" 2>&1; then
        fail "installer unexpectedly succeeded: $*"
    fi
}

run_failure() {
    run_failure_with "$BOOTSTRAP" "$@"
}

reset_case success
if ! sh "$BOOTSTRAP" > "$TMP_ROOT/success.out" 2>&1; then
    fail 'installer success case failed'
fi
contains 'KVM Switcher installed successfully.' "$TMP_ROOT/success.out"
[ "$(count_log_entries wget)" -eq 1 ] || fail 'success case did not make exactly one wget call'
[ "$(count_log_entries sudo)" -eq 2 ] || fail 'success case did not make exactly two sudo calls'
contains "adduser $TEST_ACCOUNT kvmswitch" "$FAKE_LOG"
assert_temp_cleanup

reset_case apt-installs-adduser
[ ! -e "$FAKE_BIN/adduser" ] || fail 'regression setup unexpectedly has adduser before apt'
if PATH="$FAKE_BIN:/usr/bin:/bin" command -v adduser >/dev/null 2>&1; then
    fail 'regression PATH unexpectedly has adduser before apt'
fi
if ! PATH="$FAKE_BIN:/usr/bin:/bin" sh "$BOOTSTRAP" > "$TMP_ROOT/apt-installs-adduser.out" 2>&1; then
    fail 'installer did not succeed after apt supplied adduser'
fi
contains 'KVM Switcher installed successfully.' "$TMP_ROOT/apt-installs-adduser.out"
contains "adduser $TEST_ACCOUNT kvmswitch" "$FAKE_LOG"
[ "$(count_log_entries sudo)" -eq 2 ] || fail 'apt-supplied adduser case did not complete both sudo calls'
assert_temp_cleanup

reset_case config-success
reset_config_sentinel
if ! sh "$CONFIG_BOOTSTRAP" --config "$CONFIG_FILE" > "$TMP_ROOT/config-success.out" 2>&1; then
    fail 'config-mode installer success case failed'
fi
cmp -s "$CONFIG_FILE" "$FAKE_CONFIG_TARGET" || fail 'config-mode installer did not apply exact config bytes'
contains 'kvm-switch --validate-config' "$FAKE_LOG"
assert_no_log_entry hid
contains "adduser $TEST_ACCOUNT kvmswitch" "$FAKE_LOG"
[ "$(count_log_entries sudo)" -eq 3 ] || fail 'config-mode success did not complete apt, copy, and adduser'
assert_temp_cleanup

reset_case validator-failure
reset_config_sentinel
run_failure_with "$CONFIG_BOOTSTRAP" "$TMP_ROOT/validator-failure.out" --config "$CONFIG_FILE"
contains 'config validation failed after package installation' "$TMP_ROOT/validator-failure.out"
assert_config_sentinel
assert_no_log_entry install
assert_no_log_entry mv
assert_no_log_entry adduser
[ "$(count_log_entries sudo)" -eq 1 ] || fail 'invalid config did not stop before atomic copy and adduser'
assert_temp_cleanup

reset_case atomic-failure
reset_config_sentinel
run_failure_with "$CONFIG_BOOTSTRAP" "$TMP_ROOT/atomic-failure.out" --config "$CONFIG_FILE"
contains 'config application failed after validation' "$TMP_ROOT/atomic-failure.out"
assert_config_sentinel
assert_no_log_entry adduser
assert_temp_cleanup

reset_case apt-failure-config
reset_config_sentinel
run_failure_with "$CONFIG_BOOTSTRAP" "$TMP_ROOT/apt-failure-config.out" --config "$CONFIG_FILE"
assert_config_sentinel
assert_no_log_entry kvm-switch
assert_no_log_entry install
assert_no_log_entry mv
assert_no_log_entry adduser
[ "$(count_log_entries sudo)" -eq 1 ] || fail 'config apt failure did not stop before validation and copy'
assert_temp_cleanup

reset_case config-download-failure
run_failure_with "$CONFIG_BOOTSTRAP" "$TMP_ROOT/config-download-failure.out" --config "$CONFIG_FILE"
contains 'Export Debian install bundle...' "$TMP_ROOT/config-download-failure.out"
contains 'sh ./install.sh --apply-config' "$TMP_ROOT/config-download-failure.out"
assert_no_log_entry sudo
[ "$(count_log_entries wget)" -eq 1 ] || fail 'config download failure did not make exactly one wget call'
assert_temp_cleanup

reset_case config-hash-mismatch
run_failure_with "$CONFIG_BOOTSTRAP" "$TMP_ROOT/config-hash-mismatch.out" --config "$CONFIG_FILE"
contains 'Export Debian install bundle...' "$TMP_ROOT/config-hash-mismatch.out"
contains 'sh ./install.sh --apply-config' "$TMP_ROOT/config-hash-mismatch.out"
assert_no_log_entry sudo
[ "$(count_log_entries wget)" -eq 1 ] || fail 'config hash failure did not make exactly one wget call'
assert_temp_cleanup

reset_case success
run_failure "$TMP_ROOT/missing-config.out" --config "$TMP_ROOT/missing-config.json"
contains 'regular readable file' "$TMP_ROOT/missing-config.out"
assert_no_log_entry wget
assert_no_log_entry sudo
assert_temp_cleanup

reset_case validator-failure
reset_config_sentinel
run_failure_with "$CONFIG_BOOTSTRAP" "$TMP_ROOT/malformed-config.out" --config "$MALFORMED_CONFIG"
contains 'config validation failed after package installation' "$TMP_ROOT/malformed-config.out"
assert_config_sentinel
assert_no_log_entry install
assert_no_log_entry mv
assert_no_log_entry adduser
[ "$(count_log_entries sudo)" -eq 1 ] || fail 'malformed config did not stop after installed validation'
assert_temp_cleanup

reset_case success
run_failure "$TMP_ROOT/empty-config.out" --config "$EMPTY_CONFIG"
contains 'nonempty regular readable file' "$TMP_ROOT/empty-config.out"
assert_no_log_entry wget
assert_no_log_entry sudo
assert_temp_cleanup

reset_case success
run_failure "$TMP_ROOT/nonregular-config.out" --config "$NONREGULAR_CONFIG"
contains 'nonempty regular readable file' "$TMP_ROOT/nonregular-config.out"
assert_no_log_entry wget
assert_no_log_entry sudo
assert_temp_cleanup

reset_case download-failure
run_failure "$TMP_ROOT/download-failure.out"
contains "$BUNDLE_URL" "$TMP_ROOT/download-failure.out"
contains 'sh ./install.sh' "$TMP_ROOT/download-failure.out"
assert_no_log_entry sudo
assert_no_log_entry apt-get
assert_no_log_entry adduser
[ "$(count_log_entries wget)" -eq 1 ] || fail 'download failure did not make exactly one wget call'
assert_temp_cleanup

reset_case empty
run_failure "$TMP_ROOT/empty.out"
contains "$BUNDLE_URL" "$TMP_ROOT/empty.out"
contains 'sh ./install.sh' "$TMP_ROOT/empty.out"
assert_no_log_entry sudo
[ "$(count_log_entries wget)" -eq 1 ] || fail 'empty download did not make exactly one wget call'
assert_temp_cleanup

reset_case hash-mismatch
run_failure "$TMP_ROOT/hash-mismatch.out"
contains "$BUNDLE_URL" "$TMP_ROOT/hash-mismatch.out"
contains 'sh ./install.sh' "$TMP_ROOT/hash-mismatch.out"
assert_no_log_entry sudo
[ "$(count_log_entries wget)" -eq 1 ] || fail 'hash mismatch did not make exactly one wget call'
assert_temp_cleanup

reset_case apt-failure
run_failure "$TMP_ROOT/apt-failure.out"
assert_no_log_entry adduser
[ "$(count_log_entries sudo)" -eq 1 ] || fail 'apt failure did not stop before adduser'
[ "$(count_log_entries wget)" -eq 1 ] || fail 'apt failure did not make exactly one wget call'
assert_temp_cleanup

reset_case success 0
run_failure "$TMP_ROOT/root.out"
contains 'not root' "$TMP_ROOT/root.out"
assert_no_log_entry wget
assert_no_log_entry sudo

reset_case success 1000
run_failure "$TMP_ROOT/args.out" --unexpected
contains 'does not accept arguments' "$TMP_ROOT/args.out"
assert_no_log_entry wget
assert_no_log_entry sudo

printf '%s\n' 'PASS: online installer behavior and release asset checks passed'
