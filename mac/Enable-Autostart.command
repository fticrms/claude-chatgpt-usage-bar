#!/bin/bash
set -euo pipefail
agent_path="$HOME/Library/LaunchAgents/local.aiusagebar.mac.plist"
target_app="$HOME/Applications/AI Usage Bar.app"
if [[ ! -d "$target_app" ]]; then echo 'Install.command로 앱부터 설치해 주세요.'; exit 1; fi
mkdir -p "$HOME/Library/LaunchAgents"
# Build structured plist values: paths with spaces or XML characters remain valid.
agent_stage="$(mktemp "${TMPDIR:-/tmp}/aiusagebar-agent.XXXXXX")"
/usr/bin/plutil -create xml1 "$agent_stage"
/usr/bin/plutil -insert Label -string local.aiusagebar.mac "$agent_stage"
/usr/bin/plutil -insert ProgramArguments -array "$agent_stage"
/usr/bin/plutil -insert ProgramArguments.0 -string /usr/bin/open "$agent_stage"
/usr/bin/plutil -insert ProgramArguments.1 -string "$target_app" "$agent_stage"
/usr/bin/plutil -insert RunAtLoad -bool YES "$agent_stage"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$agent_stage"
/usr/bin/plutil -lint "$agent_stage"
chmod 600 "$agent_stage"
/bin/launchctl bootout "gui/$(id -u)/local.aiusagebar.mac" >/dev/null 2>&1 || true
mv "$agent_stage" "$agent_path"
/bin/launchctl bootstrap "gui/$(id -u)" "$agent_path"
if [[ "${1:-}" != --quiet ]]; then echo '로그인 시 자동 실행이 켜졌습니다.'; read -r -p 'Enter를 누르면 닫습니다.'; fi
