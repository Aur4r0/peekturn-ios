#!/bin/zsh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/peekturn-ios.xcodeproj"
SCHEME="${SCHEME:-peekturn-ios}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}peekturn-ios-deriveddata}"
PARALLEL_TESTING_ENABLED="${PARALLEL_TESTING_ENABLED:-NO}"

if [[ "$PARALLEL_TESTING_ENABLED" != "YES" && "$PARALLEL_TESTING_ENABLED" != "NO" ]]; then
    echo "PARALLEL_TESTING_ENABLED 必须是 YES 或 NO。" >&2
    exit 2
fi

STARTED_BY_SCRIPT=0
SELECTED_DEVICE_ID=""
SELECTED_DEVICE_NAME=""
SELECTED_DEVICE_RUNTIME=""

cleanup() {
    local original_status=$?
    trap - EXIT

    if [[ "$STARTED_BY_SCRIPT" == "1" && -n "$SELECTED_DEVICE_ID" ]]; then
        if xcrun simctl shutdown "$SELECTED_DEVICE_ID" >/tmp/peekturn-sim-shutdown.log 2>&1; then
            echo "脚本启动的模拟器已关闭: $SELECTED_DEVICE_ID"
        else
            echo "警告：关闭脚本启动的模拟器失败，未覆盖原始测试结果。" >&2
            cat /tmp/peekturn-sim-shutdown.log >&2 || true
        fi
    elif [[ -n "$SELECTED_DEVICE_ID" ]]; then
        echo "模拟器原本已启动，测试结束后保持运行: $SELECTED_DEVICE_ID"
    fi

    exit "$original_status"
}

print_core_simulator_recovery() {
    echo "可执行的人工恢复命令：" >&2
    echo "xcrun simctl shutdown all || true" >&2
    echo "killall -9 com.apple.CoreSimulator.CoreSimulatorService || true" >&2
    echo "open -a Simulator" >&2
}

trap cleanup EXIT

echo "Checking CoreSimulatorService availability"
if ! SIMULATOR_LIST_JSON="$(xcrun simctl list devices available --json 2>&1)"; then
    if [[ "$SIMULATOR_LIST_JSON" == *CoreSimulatorService* ||
          "$SIMULATOR_LIST_JSON" == *"Connection refused"* ||
          "$SIMULATOR_LIST_JSON" == *"connection became invalid"* ||
          "$SIMULATOR_LIST_JSON" == *"Unable to locate device set"* ]]; then
        echo "CoreSimulatorService 不可用，未执行运行时测试。" >&2
        print_core_simulator_recovery
    else
        echo "无法读取可用模拟器列表，未执行运行时测试。" >&2
    fi
    echo "$SIMULATOR_LIST_JSON" >&2
    exit 1
fi

if [[ -z "${DESTINATION+x}" ]]; then
    SELECTED_DEVICE_RECORD="$(printf '%s' "$SIMULATOR_LIST_JSON" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
devices = []
for runtime, runtime_devices in data.get("devices", {}).items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    runtime_name = runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")
    for device in runtime_devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        device_type = device.get("deviceTypeIdentifier", "").lower()
        if "iphone" not in device_type and not name.lower().startswith("iphone "):
            continue
        udid = device.get("udid") or device.get("identifier")
        if not udid:
            continue
        devices.append({
            "name": name,
            "udid": udid,
            "runtime": runtime_name,
            "state": device.get("state", "Unknown"),
        })

def sort_key(device):
    return (device["name"], device["runtime"], device["udid"])

booted = sorted((d for d in devices if d["state"] == "Booted"), key=sort_key)
if booted:
    selected = booted[0]
else:
    preferred = sorted((d for d in devices if d["name"] == "iPhone 17 Pro"), key=sort_key)
    selected = preferred[0] if preferred else (sorted(devices, key=sort_key)[0] if devices else None)

if selected:
    print("\t".join((selected["name"], selected["udid"], selected["runtime"], selected["state"])))
')"

    if [[ -z "$SELECTED_DEVICE_RECORD" ]]; then
        echo "没有可用的 iPhone Simulator，未执行运行时测试。" >&2
        exit 1
    fi

    IFS=$'\t' read -r SELECTED_DEVICE_NAME SELECTED_DEVICE_ID SELECTED_DEVICE_RUNTIME SELECTED_DEVICE_STATE <<< "$SELECTED_DEVICE_RECORD"
    DESTINATION="id=$SELECTED_DEVICE_ID"
    echo "自动选择模拟器: name=$SELECTED_DEVICE_NAME runtime=$SELECTED_DEVICE_RUNTIME id=$SELECTED_DEVICE_ID state=$SELECTED_DEVICE_STATE"

    if [[ "$SELECTED_DEVICE_STATE" != "Booted" ]]; then
        STARTED_BY_SCRIPT=1
        echo "启动模拟器: $SELECTED_DEVICE_ID"
        if ! xcrun simctl boot "$SELECTED_DEVICE_ID"; then
            echo "无法启动模拟器 $SELECTED_DEVICE_ID，未执行运行时测试。" >&2
            exit 1
        fi
    else
        echo "模拟器已经处于 Booted 状态: $SELECTED_DEVICE_ID"
    fi

    echo "等待模拟器启动完成: $SELECTED_DEVICE_ID"
    if ! xcrun simctl bootstatus "$SELECTED_DEVICE_ID" -b; then
        echo "模拟器 bootstatus 失败，未执行运行时测试。" >&2
        exit 1
    fi
    echo "bootstatus succeeded: $SELECTED_DEVICE_ID"
else
    echo "使用外部指定 DESTINATION: $DESTINATION"

    if [[ "$DESTINATION" =~ '(^|,)id=([[:alnum:]-]+)' ]]; then
        SELECTED_DEVICE_ID="${match[2]}"
        SELECTED_DEVICE_RECORD="$(printf '%s' "$SIMULATOR_LIST_JSON" | DEVICE_ID="$SELECTED_DEVICE_ID" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
target = os.environ["DEVICE_ID"]
for runtime, runtime_devices in data.get("devices", {}).items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    runtime_name = runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")
    for device in runtime_devices:
        udid = device.get("udid") or device.get("identifier")
        if udid == target:
            print("\t".join((
                device.get("name", "Unknown"),
                udid,
                runtime_name,
                device.get("state", "Unknown"),
            )))
            raise SystemExit(0)
')"

        if [[ -n "$SELECTED_DEVICE_RECORD" ]]; then
            IFS=$'\t' read -r SELECTED_DEVICE_NAME SELECTED_DEVICE_ID SELECTED_DEVICE_RUNTIME SELECTED_DEVICE_STATE <<< "$SELECTED_DEVICE_RECORD"
            echo "指定模拟器: name=$SELECTED_DEVICE_NAME runtime=$SELECTED_DEVICE_RUNTIME id=$SELECTED_DEVICE_ID state=$SELECTED_DEVICE_STATE"
            if [[ "$SELECTED_DEVICE_STATE" != "Booted" ]]; then
                STARTED_BY_SCRIPT=1
                echo "启动指定模拟器: $SELECTED_DEVICE_ID"
                if ! xcrun simctl boot "$SELECTED_DEVICE_ID"; then
                    echo "无法启动指定模拟器 $SELECTED_DEVICE_ID，未执行运行时测试。" >&2
                    exit 1
                fi
            fi
            echo "等待指定模拟器启动完成: $SELECTED_DEVICE_ID"
            if ! xcrun simctl bootstatus "$SELECTED_DEVICE_ID" -b; then
                echo "指定模拟器 bootstatus 失败，未执行运行时测试。" >&2
                exit 1
            fi
            echo "bootstatus succeeded: $SELECTED_DEVICE_ID"
        else
            echo "指定 DESTINATION 中的模拟器不可用，未执行运行时测试。" >&2
            exit 1
        fi
    fi
fi

run_xcodebuild() {
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -parallel-testing-enabled "$PARALLEL_TESTING_ENABLED" \
        "$@"
}

echo "Checking patch formatting"
if ! git -C "$ROOT_DIR" diff --check; then
    echo "Patch formatting check failed。" >&2
    exit 1
fi

echo "Building for testing"
if run_xcodebuild build-for-testing; then
    echo "TEST BUILD SUCCEEDED"
else
    build_result=$?
    echo "TEST BUILD FAILED" >&2
    exit "$build_result"
fi

echo "Running unit and UI tests"
if run_xcodebuild test-without-building; then
    echo "TEST EXECUTE SUCCEEDED"
else
    test_result=$?
    echo "TEST EXECUTE FAILED" >&2
    exit "$test_result"
fi

echo "Verification passed"
