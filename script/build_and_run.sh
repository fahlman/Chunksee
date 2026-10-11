#!/usr/bin/env bash
set -euo pipefail

TASK_MODE="${1:-run}"
TASK_CONFIGURATION=Release
case "$TASK_MODE" in
  run|--verify|--logs|--telemetry) ;;
  --debug) TASK_CONFIGURATION=Debug ;;
  *) echo "usage: $0 [--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "usage: $0 [--verify|--logs|--telemetry|--debug]" >&2
  exit 2
fi

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/Chunksee-$TASK_CONFIGURATION"
TASK_APP="$TASK_DERIVED_DATA/Build/Products/$TASK_CONFIGURATION/Chunksee.app"

# Quit through AppKit so the native document and window restoration state is saved.
/usr/bin/swift - <<'SWIFT'
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.fahlsing.Chunksee")
for app in apps {
    guard app.terminate() else {
        fputs("Chunksee declined to quit. Close it before trying again.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(15)
while !NSRunningApplication.runningApplications(withBundleIdentifier: "com.fahlsing.Chunksee").isEmpty {
    guard Date() < deadline else {
        fputs("Chunksee did not finish quitting.\n", stderr)
        exit(1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
SWIFT

xcodebuild -project "$TASK_ROOT/Chunksee.xcodeproj" -scheme Chunksee \
  -configuration "$TASK_CONFIGURATION" -destination 'platform=macOS' \
  -derivedDataPath "$TASK_DERIVED_DATA" -disableAutomaticPackageResolution build

if [[ "$TASK_MODE" == --debug ]]; then
  exec /usr/bin/lldb -- "$TASK_APP/Contents/MacOS/Chunksee"
fi

/usr/bin/open -n "$TASK_APP"
case "$TASK_MODE" in
  --verify)
    /usr/bin/swift - "$TASK_APP" <<'SWIFT'
import AppKit
let expected = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let deadline = Date().addingTimeInterval(15)
while Date() < deadline {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.fahlsing.Chunksee")
        .first(where: { $0.bundleURL?.standardizedFileURL == expected && $0.isFinishedLaunching }) {
        print("Running Chunksee: PID \(app.processIdentifier), \(expected.path)")
        exit(0)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
fputs("The freshly built Chunksee app did not finish launching.\n", stderr)
exit(1)
SWIFT
    ;;
  --logs)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "Chunksee"'
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.fahlsing.Chunksee"'
    ;;
esac
