#!/bin/bash
set -euo pipefail

# Compiles and embeds the privileged fan-control helper into the app bundle.
# Requires a macOS SDK with Swift and codesign when DEVELOPMENT_TEAM is set.

HELPER_ID="com.xs-labs.Hot.fan-control"
HELPER_SRC_ROOT="${SRCROOT}/Hot/Classes/FanControl"
HELPER_MAIN="${SRCROOT}/Hot/FanControlHelper/main.swift"
PLIST_SRC="${SRCROOT}/Hot/Resources/${HELPER_ID}.plist"
LAUNCH_SERVICES="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Library/LaunchServices"
LAUNCH_DAEMONS="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Library/LaunchDaemons"

if [[ ! -f "${HELPER_MAIN}" || ! -f "${PLIST_SRC}" ]]; then
    echo "warning: Fan control helper sources missing; skipping embed"
    exit 0
fi

mkdir -p "${LAUNCH_SERVICES}" "${LAUNCH_DAEMONS}"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_TRIPLE="$(uname -m)-apple-macos13.0"

swiftc -O \
    -target "${TARGET_TRIPLE}" \
    -sdk "${SDK_PATH}" \
    "${HELPER_SRC_ROOT}/FanControlModels.swift" \
    "${HELPER_SRC_ROOT}/FanControlXPC.swift" \
    "${HELPER_SRC_ROOT}/SMCClient.swift" \
    "${HELPER_SRC_ROOT}/TemperatureSensorKeys.swift" \
    "${HELPER_SRC_ROOT}/FanControlHardware.swift" \
    "${HELPER_MAIN}" \
    -o "${LAUNCH_SERVICES}/${HELPER_ID}"

cp "${PLIST_SRC}" "${LAUNCH_DAEMONS}/${HELPER_ID}.plist"

HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "${LAUNCH_SERVICES}/${HELPER_ID}" \
        "${LAUNCH_DAEMONS}/${HELPER_ID}.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"

/usr/libexec/PlistBuddy -c "Add :HotFanControlHelperVersion string ${HELPER_VERSION}" \
    "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :HotFanControlHelperVersion ${HELPER_VERSION}" \
        "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Info.plist"

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --identifier "${HELPER_ID}" \
        "${LAUNCH_SERVICES}/${HELPER_ID}" || true
fi

echo "Embedded fan-control helper ${HELPER_ID}"
