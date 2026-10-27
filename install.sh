#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_ID="local.yuezhiping.subscription-reminder"
TASK_APP="$HOME/Applications/申购提醒.app"
TASK_AGENT="$HOME/Library/LaunchAgents/$TASK_ID.plist"
TASK_DOMAIN="gui/$(id -u)"
"$TASK_DIR/build.sh"
launchctl bootout "$TASK_DOMAIN/$TASK_ID" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/SubscriptionReminder"
if [ -e "$TASK_APP" ]; then
  printf '%s\n' '更新已有的申购提醒应用'
fi
ditto "$TASK_DIR/build/申购提醒.app" "$TASK_APP"
/usr/bin/python3 - "$TASK_APP" "$TASK_AGENT" <<'PY'
import pathlib, plistlib, sys
app, agent = sys.argv[1:]
data = {
    'Label': 'local.yuezhiping.subscription-reminder',
    'ProgramArguments': [app + '/Contents/MacOS/SubscriptionReminder'],
    'RunAtLoad': True,
    'KeepAlive': {'SuccessfulExit': False},
    'ProcessType': 'Interactive',
    'ThrottleInterval': 30,
    'StandardOutPath': str(pathlib.Path.home() / 'Library/Application Support/SubscriptionReminder/launch.out.log'),
    'StandardErrorPath': str(pathlib.Path.home() / 'Library/Application Support/SubscriptionReminder/launch.err.log'),
}
with open(agent, 'wb') as stream:
    plistlib.dump(data, stream)
PY
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TASK_APP"
launchctl bootstrap "$TASK_DOMAIN" "$TASK_AGENT"
printf '已安装并启动：%s\n' "$TASK_APP"
