#!/bin/bash
set -euo pipefail
TASK_ID="local.yuezhiping.subscription-reminder"
launchctl bootout "gui/$(id -u)/$TASK_ID" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$TASK_ID.plist"
rm -rf "$HOME/Applications/申购提醒.app"
printf '%s\n' '应用和登录启动已移除。运行记录保留在 ~/Library/Application Support/SubscriptionReminder。'
