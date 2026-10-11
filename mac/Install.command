#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
package_dir="$PWD"
if [[ "$(uname -s)" != Darwin ]]; then echo 'macOS 전용 설치 파일입니다.'; exit 1; fi
trap 'echo; echo "설치가 중단되었습니다. 위 오류를 확인해 주세요."; read -r -p "Enter를 누르면 닫습니다."' ERR
echo 'AI Usage Bar 맥용 설치'
echo '이 맥에서 앱을 만들어 설치합니다. 계정 정보는 포함되어 있지 않습니다.'
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  echo 'Apple Command Line Tools가 필요합니다. 나타나는 창에서 설치해 주세요.'
  /usr/bin/xcode-select --install || true
  echo 'Apple 도구 설치가 끝나면 Install.command를 다시 실행해 주세요.'
  read -r -p 'Enter를 누르면 닫습니다.'; exit 0
fi
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiusagebar-build.XXXXXX")"
app_dir="$stage_dir/AI Usage Bar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
echo '맥용 앱을 만드는 중입니다. 처음에는 잠시 걸릴 수 있습니다…'
/usr/bin/xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos12.0" \
  -framework Cocoa -framework Security "$package_dir/Sources/main.swift" \
  -o "$app_dir/Contents/MacOS/AIusagebar"
cp "$package_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$package_dir/사용설명서.txt" "$app_dir/Contents/Resources/사용설명서.txt"
/usr/bin/codesign --force --sign - --identifier local.aiusagebar.mac "$app_dir"
echo '사용량 응답 해석 검사 중…'
"$app_dir/Contents/MacOS/AIusagebar" --self-test
install_dir="$HOME/Applications"
target_app="$install_dir/AI Usage Bar.app"
mkdir -p "$install_dir"
if [[ -e "$target_app" ]]; then
  echo '기존 AI Usage Bar를 종료한 뒤 Enter를 눌러 주세요.'; read -r
  backup_app="$install_dir/AI Usage Bar.backup.$(date +%Y%m%d-%H%M%S).app"
  mv "$target_app" "$backup_app"
fi
mv "$app_dir" "$target_app"
rmdir "$stage_dir"
echo '자동 실행을 등록합니다. 맥에 로그인할 때 창이 열립니다.'
/bin/bash "$package_dir/Enable-Autostart.command" --quiet
/usr/bin/open "$target_app"
echo '앱 설치 완료! CLI가 없다면 Setup-Login.command로 설치와 로그인을 진행하세요.'
echo 'CLI가 이미 있다면 앱의 Codex 로그인 / Claude 로그인 버튼을 누르세요.'
read -r -p 'Enter를 누르면 닫습니다.'
