#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
BUILD_SCRIPT="$SCRIPT_DIR/Build-OnlineInstaller.sh"
TEMPLATE="$SCRIPT_DIR/install-kvm-switcher.sh.in"
DEB_NAME='kvm-switcher_0.8.0-1_all.deb'
DEB_PATH="$REPO_ROOT/artifacts/$DEB_NAME"
BOOTSTRAP="$REPO_ROOT/artifacts/install-kvm-switcher.sh"
BUNDLE="$REPO_ROOT/artifacts/kvm-switcher-debian.zip"
CONFIG_SOURCE="$REPO_ROOT/packaging/debian/config.json"
REAL_MKTEMP=$(command -v mktemp)
REAL_SHA256SUM=$(command -v sha256sum)

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
    if grep -F "$command_name " "$FAKE_LOG" >/dev/null 2>&1; then
        fail "unexpected fake command invocation: $command_name"
    fi
}

assert_temp_cleanup() {
    temp_path=$(tr -d '\n' < "$TEMP_PATH_LOG")
    [ -z "$temp_path" ] || [ ! -e "$temp_path" ] || fail "installer temporary directory was not removed: $temp_path"
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
mkdir -p "$FAKE_BIN"
: > "$FAKE_LOG"
: > "$TEMP_PATH_LOG"
export FAKE_BIN FAKE_LOG TEMP_PATH_LOG TMP_ROOT
export REAL_MKTEMP REAL_SHA256SUM
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
    success|apt-failure) cp "$TEST_PACKAGE" "$output_path" ;;
    *) exit 9 ;;
esac
EOF

cat > "$FAKE_BIN/mktemp" <<'EOF'
#!/bin/sh
printf 'mktemp %s\n' "$*" >> "$FAKE_LOG"
path=$("$REAL_MKTEMP" "$@") || exit 1
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
[ "$FAKE_MODE" != apt-failure ] || exit 12
EOF

cat > "$FAKE_BIN/adduser" <<'EOF'
#!/bin/sh
printf 'adduser %s\n' "$*" >> "$FAKE_LOG"
EOF

chmod 0755 "$FAKE_BIN"/*

[ -s "$DEB_PATH" ] || fail 'the Debian artifact prerequisite is missing'
sh -n "$TEMPLATE" "$BUILD_SCRIPT" "$SCRIPT_DIR/Test-OnlineInstaller.sh"
sh "$BUILD_SCRIPT" >/dev/null
[ -s "$BOOTSTRAP" ] || fail 'generated bootstrap is missing'
[ -s "$BUNDLE" ] || fail 'generated fallback bundle is missing'
sh -n "$BOOTSTRAP"

deb_hash_line=$($REAL_SHA256SUM "$DEB_PATH")
deb_hash=${deb_hash_line%% *}
config_hash_line=$($REAL_SHA256SUM "$CONFIG_SOURCE")
config_hash=${config_hash_line%% *}
PACKAGE_URL="https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.0/$DEB_NAME"
BUNDLE_URL='https://github.com/nexxyz/kvm-switcher/releases/download/v0.8.0/kvm-switcher-debian.zip'
contains "$PACKAGE_URL" "$BOOTSTRAP"
contains "$BUNDLE_URL" "$BOOTSTRAP"
contains "$deb_hash" "$BOOTSTRAP"
not_contains '@PACKAGE_URL@' "$BOOTSTRAP"
not_contains 'apply-config' "$BOOTSTRAP"
not_contains 'config.json' "$BOOTSTRAP"

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
}

run_failure() {
    output=$1
    shift
    if sh "$BOOTSTRAP" "$@" > "$output" 2>&1; then
        fail "installer unexpectedly succeeded: $*"
    fi
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
