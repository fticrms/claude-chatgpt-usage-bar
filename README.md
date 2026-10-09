# AIusagebar

Windows 작업 표시줄 위에 **Claude**와 **ChatGPT(Codex)**의 주간(7일) 사용량을 막대로 보여주는 작은 위젯입니다.

```
ChatGPT  ■■■□□□□□   29% used / 7d   10-14 14:43
Claude   ■□□□□□□□    8% used / 7d   10-13 18:00
```

- 사용률 막대 + 퍼센트 + 다음 리셋 시각
- 작업 표시줄에 맞춰 크기 자동 조절, 드래그로 위치 이동
- 전체 화면(게임·영상)일 때는 자동으로 숨김
- Windows 로그인 시 자동 실행

## 필요한 것

- Windows 10 / 11 (별도 프로그램 설치 없음 — 기본 PowerShell 5.1 사용)
- **Claude 줄:** Claude Code에 로그인되어 있어야 합니다 (Claude 데스크톱 앱 Code 탭 또는 Claude Code CLI)
- **ChatGPT 줄:** Codex(ChatGPT 데스크톱 앱 / Codex CLI)에 로그인되어 있어야 합니다

둘 중 하나만 써도 됩니다. 안 쓰는 쪽은 `--%`로 표시됩니다.

## 설치

1. 이 페이지 위쪽 **Code → Download ZIP** 으로 받아 압축을 풉니다.
2. `Install.cmd` 더블클릭
   - "Windows의 PC 보호" 창이 뜨면 **추가 정보 → 실행** (서명되지 않은 스크립트라서 뜨는 안내입니다)
3. 작업 표시줄에 위젯이 나타나면 끝.

설치 위치: `%LOCALAPPDATA%\AIusagebar` — 설치 후 압축 푼 폴더는 지워도 됩니다.

## 사용법

| 동작 | 방법 |
|---|---|
| 실행 | 시작 메뉴 → **AIusagebar** |
| 위치 이동 | 위젯 드래그 |
| 새로고침 / 자세히 / 종료 | 위젯 우클릭 → Refresh now / Details / Exit |

## 제거

시작 메뉴 → **AIusagebar 제거**, 또는 `Uninstall.cmd` 더블클릭.
설치 폴더·바로가기·자동 실행·위치 설정·로그를 지우며, Claude / ChatGPT 로그인 정보는 건드리지 않습니다.

## 동작 방식

| 파일 | 역할 |
|---|---|
| `AIusagebar.ps1` | 위젯 본체 (WinForms) |
| `Run-Widget.ps1` | 실행 전 Claude 로그인 갱신 후 위젯 시작 |
| `Start AIusagebar.vbs` / `.cmd` | 콘솔 창 없이 숨겨서 실행 |
| `Install.ps1` / `Uninstall.ps1` | 설치 / 제거 |

- **ChatGPT:** 설치된 Codex의 app-server에 `account/rateLimits/read`를 요청해 주간 사용량을 읽습니다.
- **Claude:** Claude Code 로그인 정보(`~/.claude/.credentials.json`)로 사용량을 조회합니다.

### 해결한 문제: "컴퓨터를 켤 때마다 Claude가 연결 안 됨"

Claude 데스크톱 앱은 로그인을 자체적으로 관리해서 `.credentials.json`을 갱신하지 않습니다. 이 파일의 토큰은 약 8시간이면 만료되기 때문에, 부팅 직후엔 대부분 만료 상태였고 위젯이 직접 갱신을 시도하다 실패 → 대기 상태에 빠졌습니다.

`Run-Widget.ps1`이 위젯을 띄우기 전에 토큰 만료 여부를 확인하고, 만료됐으면 설치된 Claude Code CLI로 한 번 갱신하도록 바꿨습니다 (부팅 직후 네트워크를 고려해 최대 3회 재시도).

## 주의

- Claude 사용량 조회는 **공식 문서에 없는 방식**입니다. Anthropic / OpenAI 쪽이 바뀌면 동작하지 않을 수 있습니다.
- 개인용 비공식 도구이며 Anthropic, OpenAI와 관련이 없습니다.
- 로그인 토큰은 화면이나 로그에 출력하지 않습니다.

## 문제 해결

- Claude 줄에 `Claude login` → Claude Code에서 다시 로그인한 뒤 위젯 우클릭 → Refresh now
- ChatGPT 줄에 `codex login` → Codex / ChatGPT 앱에서 다시 로그인
- 그 외: `%TEMP%\AIusagebar.log` 확인

## License

[MIT](LICENSE)
