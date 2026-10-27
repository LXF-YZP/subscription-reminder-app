#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_BUILD="$TASK_DIR/build"
TASK_APP="$TASK_BUILD/申购提醒.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" \
  "$TASK_DIR/Sources/ChartsCore.swift" "$TASK_DIR/Sources/ChartsWindow.swift" "$TASK_DIR/Sources/MarketWindow.swift" "$TASK_DIR/Sources/FeatureWindow.swift" "$TASK_DIR/Sources/AppFeatures.swift" "$TASK_DIR/Sources/App.swift" \
  -o "$TASK_APP/Contents/MacOS/SubscriptionReminder" -framework AppKit -framework UserNotifications -framework SwiftUI -framework Charts
cp "$TASK_DIR/Info.plist" "$TASK_APP/Contents/Info.plist"
if [ -f "$TASK_DIR/AppIcon.icns" ]; then cp "$TASK_DIR/AppIcon.icns" "$TASK_APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - --identifier local.yuezhiping.subscription-reminder "$TASK_APP"
printf '%s\n' "$TASK_APP"
