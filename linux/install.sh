#!/bin/sh
set -eu

BUNDLE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
VENV_DIR=$BUNDLE_DIR/.venv
INSTALL_COMMANDS=0
ADD_PATH=0

usage() {
    printf '%s\n' "Usage: ./install.sh [--install-commands] [--add-path]"
}

for argument in "$@"; do
    case "$argument" in
        --install-commands) INSTALL_COMMANDS=1 ;;
        --add-path) ADD_PATH=1 ;;
        --help|-h) usage; exit 0 ;;
        *)
            printf '%s\n' "error: unknown flag: $argument" >&2
            usage >&2
            exit 2
            ;;
    esac
done

setup_guidance() {
    platform=$(uname -s 2>/dev/null || printf '%s' unknown)
    printf '%s\n' "Setup failed; install the platform prerequisites and rerun this script:" >&2
    case "$platform" in
        Linux)
            printf '%s\n' "  Debian/RPi OS: python3-venv python3-dev build-essential libhidapi-dev" >&2
            ;;
        Darwin)
            printf '%s\n' "  macOS: brew install python hidapi" >&2
            ;;
        FreeBSD)
            printf '%s\n' "  FreeBSD: pkg install python311 py311-hidapi" >&2
            ;;
        OpenBSD)
            printf '%s\n' "  OpenBSD is experimental; check its USB HID driver and Python support." >&2
            ;;
        *)
            printf '%s\n' "  provide Python 3 with venv support and hidapi development support." >&2
            ;;
    esac
}

PYTHON_BIN=${PYTHON_BIN:-python3}
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    printf '%s\n' "error: python3 was not found" >&2
    setup_guidance
    exit 1
fi

if ! "$PYTHON_BIN" -m venv "$VENV_DIR"; then
    setup_guidance
    exit 1
fi
if ! "$VENV_DIR/bin/python" -m pip install -r "$BUNDLE_DIR/requirements.txt"; then
    setup_guidance
    exit 1
fi
if ! "$VENV_DIR/bin/python" -m pip install --no-deps -e "$BUNDLE_DIR"; then
    setup_guidance
    exit 1
fi
if ! "$VENV_DIR/bin/python" -c 'import hid'; then
    printf '%s\n' "error: hidapi import verification failed" >&2
    setup_guidance
    exit 1
fi
if ! "$VENV_DIR/bin/kvm-switch" --help >/dev/null; then
    printf '%s\n' "error: kvm-switch help verification failed" >&2
    setup_guidance
    exit 1
fi

if [ "$INSTALL_COMMANDS" -eq 1 ]; then
    LOCAL_BIN=${HOME}/.local/bin
    mkdir -p "$LOCAL_BIN"
    if [ ! -f "$BUNDLE_DIR/config.json" ]; then
        cp "$BUNDLE_DIR/config.example.json" "$BUNDLE_DIR/config.json"
        printf '%s\n' "Created $BUNDLE_DIR/config.json from config.example.json; edit it before profile use."
    fi

    LAUNCHER=$LOCAL_BIN/kvm-switch
    if ln -sf "$VENV_DIR/bin/kvm-switch" "$LAUNCHER" 2>/dev/null; then
        printf '%s\n' "Linked $LAUNCHER to $VENV_DIR/bin/kvm-switch"
    else
        cp "$VENV_DIR/bin/kvm-switch" "$LAUNCHER"
        chmod 755 "$LAUNCHER"
        printf '%s\n' "Copied $LAUNCHER from $VENV_DIR/bin/kvm-switch"
    fi

    TARGET_DIR=$BUNDLE_DIR/targets
    if [ -d "$TARGET_DIR" ]; then
        for target_wrapper in "$TARGET_DIR"/*.sh; do
            if [ -f "$target_wrapper" ]; then
                target_name=$(basename "$target_wrapper")
                cp "$target_wrapper" "$LOCAL_BIN/$target_name"
                chmod 755 "$LOCAL_BIN/$target_name"
                printf '%s\n' "Installed $LOCAL_BIN/$target_name"
            fi
        done
    fi
fi

if [ "$ADD_PATH" -eq 1 ]; then
    PROFILE_FILE=${HOME}/.profile
    MARKER="# kvm-switcher: local command path"
    if [ ! -f "$PROFILE_FILE" ] || ! grep -F "$MARKER" "$PROFILE_FILE" >/dev/null 2>&1; then
        {
            printf '\n%s\n' "$MARKER"
            printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"'
        } >> "$PROFILE_FILE"
        printf '%s\n' "Added the marked ~/.local/bin PATH line to $PROFILE_FILE"
    else
        printf '%s\n' "The marked ~/.local/bin PATH line is already present in $PROFILE_FILE"
    fi
fi

printf '%s\n' "Ready: use the bundle with $VENV_DIR/bin/python $BUNDLE_DIR/kvmSwitcher.py"
