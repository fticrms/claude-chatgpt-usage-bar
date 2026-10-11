#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then echo 'macOS 전용입니다. / macOS only.'; exit 1; fi
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
unset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
trap 'echo "진행이 중단되었습니다. 위 오류를 확인해 주세요. / Stopped — see the error above."; read -r -p "Enter를 누르면 닫습니다. / Press Enter to close."' ERR
cd "$HOME"
echo 'AI Usage Bar — 공식 CLI 설치 및 본인 계정 로그인 / Install official CLIs and sign in with your own accounts'
echo '설치되지 않은 CLI만 공식 사이트에서 내려받습니다. / Only missing CLIs are downloaded from the official sites.'
echo '이미 로그인했다면 이 파일 대신 앱에서 새로고침만 누르셔도 됩니다. / Already signed in? Just click Refresh in the app.'
if ! command -v codex >/dev/null 2>&1; then
  echo 'OpenAI 공식 설치 파일로 Codex CLI를 설치합니다… / Installing Codex CLI with the official OpenAI installer…'
  installer="$(mktemp "${TMPDIR:-/tmp}/aiusagebar-codex.XXXXXX")"
  /usr/bin/curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    https://chatgpt.com/codex/install.sh -o "$installer"
  /bin/sh "$installer"
  /bin/rm -f "$installer"
fi
if ! command -v claude >/dev/null 2>&1; then
  echo 'Anthropic 공식 설치 파일로 Claude Code를 설치합니다… / Installing Claude Code with the official Anthropic installer…'
  installer="$(mktemp "${TMPDIR:-/tmp}/aiusagebar-claude.XXXXXX")"
  /usr/bin/curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    https://claude.ai/install.sh -o "$installer"
  /bin/bash "$installer"
  /bin/rm -f "$installer"
fi
hash -r
if ! command -v codex >/dev/null 2>&1 || ! command -v claude >/dev/null 2>&1; then
  echo 'CLI를 찾지 못했습니다. 터미널을 다시 열어 공식 설치 안내의 PATH 설정을 확인하세요. / CLI not found — reopen Terminal and check the PATH step in the official install guide.'
  read -r -p 'Enter를 누르면 닫습니다. / Press Enter to close.'; exit 1
fi
echo '1/2: 브라우저에서 본인 ChatGPT 계정으로 로그인하세요. / Sign in with your ChatGPT account in the browser.'
codex login
echo '2/2: 브라우저에서 본인 Claude 구독 계정으로 로그인하세요. / Sign in with your Claude subscription account in the browser.'
claude auth login
echo '로그인 완료! AI Usage Bar 창의 새로고침을 눌러 주세요. / Done! Click Refresh in the AI Usage Bar window.'
read -r -p 'Enter를 누르면 닫습니다. / Press Enter to close.'
