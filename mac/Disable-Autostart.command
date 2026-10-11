#!/bin/bash
set -euo pipefail
/bin/launchctl bootout "gui/$(id -u)/local.aiusagebar.mac" >/dev/null 2>&1 || true
agent_path="$HOME/Library/LaunchAgents/local.aiusagebar.mac.plist"
if [[ -f "$agent_path" ]]; then /bin/rm "$agent_path"; fi
echo '로그인 시 자동 실행을 껐습니다. 계정 로그인은 유지됩니다.'
read -r -p 'Enter를 누르면 닫습니다.'
