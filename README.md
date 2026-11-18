# Code Usage

Claude Code와 Codex의 플랜 사용량을 한 번에 보여 주는 개인용 macOS 메뉴 막대 앱입니다 (macOS 14+, AppKit + SwiftUI, 외부 의존성 없음).

- **메뉴 막대 아이콘**: Claude, Codex 각각 하나의 값을 보여 줍니다. 현재 세션(5시간 창)이 진행 중이면 세션 사용률을, 없으면 주간 한도 사용률을 표시합니다.
- **팝오버**: 공급자별 현재 세션 / 주간 한도 / 모델별 주간 한도, 리셋까지 남은 시간, 소모 속도(%/hr), 현재 속도면 한도에 도달하는 시각.
- **기록**: 최근 8일 사용량을 `~/Library/Application Support/CodeUsage/history.json`에 저장하고 차트로 보여 줍니다.

## 데이터를 가져오는 방법

별도 로그인 없이, 이 Mac의 CLI가 이미 가진 로그인 정보를 재사용합니다.

| 공급자 | 자격 증명 | 사용량 API |
|---|---|---|
| Claude | 키체인 항목 `Claude Code-credentials` (`/usr/bin/security`로 읽음), 없으면 `~/.claude/.credentials.json` | `GET https://api.anthropic.com/api/oauth/usage` |
| Codex | `$CODEX_HOME/auth.json` (기본 `~/.codex/auth.json`, ChatGPT 로그인) | `GET https://chatgpt.com/backend-api/wham/usage` |

토큰은 로그·화면·파일 어디에도 출력하지 않습니다. 기본 새로고침 주기는 2분이며 설정에서 바꿀 수 있습니다 (최소 30초). 잠자기에서 깨어나면 바로 새로고침합니다.

## 빌드 · 설치 · 실행

```sh
scripts/build.sh                 # build/CodeUsage.app 생성 (release, ad-hoc 서명)
scripts/build.sh --install       # ~/Applications/CodeUsage.app 에 설치 (실행 중이면 종료 후 교체)
scripts/build.sh --install --run # 설치 후 실행
scripts/build.sh --run           # 설치 없이 build/CodeUsage.app 실행
```

로그인 시 자동 실행은 설정 창의 "로그인 시 실행"에서 켭니다 (`~/Applications`에 설치한 앱에서 사용하세요).

## 토큰 자동 갱신 주의

설정의 **토큰 자동 갱신**(기본 켜짐)은 액세스 토큰이 만료됐을 때 리프레시 토큰으로 새 토큰을 받아 **CLI의 저장소에 다시 기록**합니다 (Claude Code 키체인 항목 / `~/.codex/auth.json`). 리프레시 토큰은 회전될 수 있으므로, CLI가 같은 시점에 직접 갱신하면 어느 한쪽이 무효가 된 토큰을 가질 수 있습니다. 이 경우 터미널에서 `claude` 또는 `codex`를 한 번 실행하면 복구됩니다. CLI 저장소를 건드리고 싶지 않다면 이 옵션을 끄세요. 끄면 토큰이 만료됐을 때 CLI를 한 번 실행하라는 안내만 표시합니다.

## 디버그 플래그

```sh
B=build/CodeUsage.app/Contents/MacOS/CodeUsage

$B --dump                        # 두 공급자를 한 번씩 조회해 스냅샷을 JSON으로 출력 (오류는 텍스트), 종료 코드 0
CODEUSAGE_DEBUG=1 $B --dump      # 원본 사용량 응답 JSON도 stderr로 출력 (헤더·토큰은 출력하지 않음)
$B --render-preview /tmp/cu      # 내장 샘플 데이터로 팝오버/메뉴 막대를 2x PNG로 렌더링 (네트워크 없음)
```

`--render-preview`는 `popover-light.png`, `popover-dark.png`, `menubar-light.png`, `menubar-dark.png`를 만듭니다.

## 표시 방식 / 아이콘

- 메뉴 막대: Claude·Codex 두 값을 위아래 두 줄로 표시합니다. 현재 세션이 진행 중이면 세션 값, 아니면 주간 한도 값이고, 주간 한도 값 옆에는 작은 `w`가 붙습니다.
- 퍼센트 표시는 공급자별로 설정 › 퍼센트 표시에서 "사용량" 또는 "남은 양"으로 고를 수 있습니다. 기본값은 Claude 사용량, Codex 남은 양입니다(각 서비스 자체 화면과 같은 방식).
- 앱 아이콘(`</*>`)은 `swift scripts/make-icon.swift`로 `Resources/AppIcon.icns`에 다시 생성합니다. 파일이 없으면 `build.sh`가 자동으로 생성합니다.
