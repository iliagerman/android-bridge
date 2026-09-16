#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="iliagerman/android-bridge"
APP_NAME="AndroidBridge.app"
DMG_NAME="AndroidBridge-latest-macOS-arm64.dmg"
CHECKSUM_NAME="${DMG_NAME}.sha256"
INSTALL_PATH="/Applications/${APP_NAME}"
RELEASE_TAG="latest-build"
EXPECTED_REQUIREMENT='identifier "com.androidbridge.mac" and certificate leaf = H"ef2fb966bb80189b6e12ef4a9111601f4d8466ec"'

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "Android Bridge requires macOS."
[ "$(uname -m)" = "arm64" ] || fail "This release supports Apple Silicon Macs only."

requirement() {
    codesign -dr - "$1" 2>&1 | awk '/^designated =>/{sub(/^designated => /, ""); print}'
}

validate_app() {
    local app="$1"
    [ -d "$app" ] || fail "App bundle is missing: $app"
    codesign --verify --deep --strict --verbose=2 "$app" || fail "App signature verification failed: $app"
    [ "$(requirement "$app")" = "$EXPECTED_REQUIREMENT" ] || fail "App designated requirement does not match the Android Bridge distribution identity: $app"
}

TMP_DIR="$(mktemp -d)"
MOUNT_POINT="$TMP_DIR/mount"
ATTACHED=0
cleanup() {
    local status="$?"
    local cleanup_failed=0
    if [ "$ATTACHED" -eq 1 ]; then
        hdiutil detach "$MOUNT_POINT" >/dev/null || cleanup_failed=1
    fi
    rm -rf "$TMP_DIR" || cleanup_failed=1
    if [ "$cleanup_failed" -ne 0 ]; then
        printf 'Error: Installer cleanup failed.\n' >&2
        [ "$status" -eq 0 ] && exit 1
    fi
    exit "$status"
}
trap cleanup EXIT

ASSET_BASE="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}"
printf 'Downloading the latest Android Bridge build…\n'
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$TMP_DIR/$DMG_NAME" "$ASSET_BASE/$DMG_NAME"
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$TMP_DIR/$CHECKSUM_NAME" "$ASSET_BASE/$CHECKSUM_NAME"
(
    cd "$TMP_DIR"
    shasum -a 256 -c "$CHECKSUM_NAME"
)

mkdir -p "$MOUNT_POINT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$TMP_DIR/$DMG_NAME" >/dev/null
ATTACHED=1
validate_app "$MOUNT_POINT/$APP_NAME"
ditto "$MOUNT_POINT/$APP_NAME" "$TMP_DIR/$APP_NAME"
validate_app "$TMP_DIR/$APP_NAME"
hdiutil detach "$MOUNT_POINT" >/dev/null
ATTACHED=0

printf 'Installing to %s…\n' "$INSTALL_PATH"
if [ -d "$INSTALL_PATH" ]; then
    installed_requirement="$(requirement "$INSTALL_PATH")" || fail "Cannot inspect the existing app signing identity."
    [ "$installed_requirement" = "$EXPECTED_REQUIREMENT" ] || fail "Existing Android Bridge uses a different signing identity. Refusing to replace it; move the existing app aside or reinstall it manually after confirming its origin."
fi
osascript -e 'quit app "AndroidBridge"' >/dev/null 2>&1 || true
if [ -w /Applications ]; then
    rm -rf "$INSTALL_PATH"
    ditto "$TMP_DIR/$APP_NAME" "$INSTALL_PATH"
else
    sudo rm -rf "$INSTALL_PATH"
    sudo ditto "$TMP_DIR/$APP_NAME" "$INSTALL_PATH"
fi
validate_app "$INSTALL_PATH"
open "$INSTALL_PATH"
printf 'Installed the latest rolling Android Bridge build.\n'
