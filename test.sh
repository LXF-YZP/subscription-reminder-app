#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TASK_DIR/build"
swiftc -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Tests/CoreTests.swift" -o "$TASK_DIR/build/CoreTests"
"$TASK_DIR/build/CoreTests"
swiftc -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Tests/MarketTests.swift" -o "$TASK_DIR/build/MarketTests"
"$TASK_DIR/build/MarketTests"
swiftc -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Sources/ChartsCore.swift" "$TASK_DIR/Sources/ChartsWindow.swift" "$TASK_DIR/Sources/MarketWindow.swift" "$TASK_DIR/Tests/MarketRefreshTests.swift" -o "$TASK_DIR/build/MarketRefreshTests" -framework AppKit -framework SwiftUI -framework Charts
"$TASK_DIR/build/MarketRefreshTests"
swiftc -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Sources/ChartsCore.swift" "$TASK_DIR/Sources/ChartsWindow.swift" "$TASK_DIR/Sources/MarketWindow.swift" "$TASK_DIR/Tests/FavoriteTests.swift" -o "$TASK_DIR/build/FavoriteTests" -framework AppKit -framework SwiftUI -framework Charts
"$TASK_DIR/build/FavoriteTests"
swiftc -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Sources/ChartsCore.swift" "$TASK_DIR/Sources/ChartsWindow.swift" "$TASK_DIR/Sources/MarketWindow.swift" "$TASK_DIR/Tests/StockDetailTests.swift" -o "$TASK_DIR/build/StockDetailTests" -framework AppKit -framework SwiftUI -framework Charts
"$TASK_DIR/build/StockDetailTests"
swiftc -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Sources/ChartsCore.swift" "$TASK_DIR/Sources/ChartsWindow.swift" "$TASK_DIR/Sources/MarketWindow.swift" "$TASK_DIR/Sources/FeatureWindow.swift" "$TASK_DIR/Tests/FeatureTests.swift" -o "$TASK_DIR/build/FeatureTests" -framework AppKit -framework SwiftUI -framework Charts
"$TASK_DIR/build/FeatureTests"
# 直接从当前应用源码提取委托进行菜单检查，测试目录完全隔离。
python3 - "$TASK_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/App.swift').read_text().split('@main\nstruct SubscriptionReminder')[0]
(root / 'build/AppDelegateUnderTest.swift').write_text(source)
PY
swiftc -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Sources/ChartsCore.swift" "$TASK_DIR/Sources/ChartsWindow.swift" "$TASK_DIR/Sources/MarketWindow.swift" "$TASK_DIR/Sources/FeatureWindow.swift" "$TASK_DIR/Sources/AppFeatures.swift" "$TASK_DIR/build/AppDelegateUnderTest.swift" "$TASK_DIR/Tests/AppFeatureTests.swift" -o "$TASK_DIR/build/AppFeatureTests" -framework AppKit -framework UserNotifications -framework SwiftUI -framework Charts
cd "$TASK_DIR"
"$TASK_DIR/build/AppFeatureTests"
swiftc -O -parse-as-library "$TASK_DIR/Sources/Core.swift" "$TASK_DIR/Sources/MarketCore.swift" "$TASK_DIR/Sources/Features.swift" "$TASK_DIR/Sources/ChartsCore.swift" "$TASK_DIR/Sources/ChartsWindow.swift" "$TASK_DIR/Sources/MarketWindow.swift" "$TASK_DIR/Tests/ChartTests.swift" -o "$TASK_DIR/build/ChartTests" -framework AppKit -framework SwiftUI -framework Charts
"$TASK_DIR/build/ChartTests"
