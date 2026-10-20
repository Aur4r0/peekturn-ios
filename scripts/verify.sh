#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/peekturn-ios.xcodeproj"
SCHEME="${SCHEME:-peekturn-ios}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}peekturn-ios-deriveddata}"

run_xcodebuild() {
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        "$@"
}

echo "Checking patch formatting"
git -C "$ROOT_DIR" diff --check

echo "Building for testing"
run_xcodebuild build-for-testing

echo "Running unit and UI tests"
run_xcodebuild test-without-building

echo "Verification passed"
