# Hermes Easy Setup

Windows에서 [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent)를 설치하는 한국어 안전 마법사입니다.

이 프로젝트는 Nous Research의 공식 제품이 아닌 비공식 커뮤니티 도구입니다. Hermes 자체의 사용법과 지원 범위는 [공식 문서](https://hermes-agent.nousresearch.com/docs/)를 기준으로 합니다.

## 설치 설명서

처음 설치한다면 [단계별 설치 설명서](docs/installation-guide.ko.md)를 먼저 읽어 주세요. 준비물, 화면별 입력 예시, Codex 인증, Mattermost 연결, 완료 테스트와 오류 해결 방법을 정리했습니다.

공개용 설명서에는 실제 내부 주소나 인증값을 넣지 않았습니다. 서버 주소·봇 토큰·홈 채널 ID는 관리자에게 별도로 받고, NetBird IPv4에는 설치하는 PC의 주소를 사용하세요.

## 현재 상태

- 버전 `0.3.0` Windows 네이티브 연구실 통합 MVP
- 5단계 마법사 안에서 Hermes 설치·검증, OpenAI Codex OAuth와 모델 선택, 독립 프로필, Mattermost, NetBird Dashboard, 부팅 Gateway, Bot Control 등록과 매주 업데이트까지 구성합니다.
- Nous Portal·OpenRouter·일반 provider 목록·Discord·Slack·Telegram·Spotify·클라우드 터미널·미디어 provider·전체 도구 설정 화면은 이 연구실용 흐름에서 노출하지 않습니다.
- 이전 마법사가 남긴 exact `Completed` 설치 기록이 안전 조건을 충족하면 재설치 없이 Codex 인증과 연구실 연결을 계속할 수 있습니다.
- 선택적 Browser/TUI npm 의존성, Computer Use 사전 설치와 Hermes Desktop 자동 빌드는 후속 버전으로 미룹니다. v0.1.2 GUI는 Computer Use/Desktop 옵션을 고정하며 CLI 설치에는 `-SkipComputerUse`가 필요합니다.
- Windows 10/11 x64에서 로컬 및 CI 검증
- ARM64는 Hermes upstream Tier 1 대상이지만 이 마법사는 아직 실기기 미검증
- Windows PowerShell 5.1과 PowerShell 7 단위 테스트
- 검토된 Hermes 릴리스 `v2026.8.19` 고정
- 실제 설치 전 변경 계획, 계획 지문, 명시적 승인
- 단계별 체크포인트와 attestation이 함께 남은 제한적 비정상 종료만 안전 재개
- 로컬 전용 정제 로그와 진단 ZIP

현재 배포물은 코드 서명이 없는 `.cmd`/PowerShell 소스입니다. 공식 Hermes 설치기나 Nous Research의 서명을 대신하지 않습니다. 제거·초기화 기능도 제공하지 않습니다.

## 빠른 시작

다른 Windows PC에서 테스트할 때는 GitHub의 **Code → Download ZIP**으로 `main`의 최신 코드를 받으세요. 기존 Release에는 최근 수정사항이 아직 포함되지 않을 수 있습니다. 압축을 푼 폴더에서 실행해야 합니다.

미리 준비할 항목:

- Windows 10/11 x64와 Program Files에 설치한 [Git for Windows](https://gitforwindows.org/)
- 연구실 NetBird 연결 및 Mattermost 서버 접근
- 사용할 ChatGPT/Codex 계정, 해당 봇의 Mattermost 토큰과 홈 채널 ID
- Dashboard에서 사용할 사용자 이름과 비밀번호

1. 이 저장소의 GitHub Release 또는 소스 저장소에서만 파일을 받습니다.
2. Release가 제공되면 함께 게시되는 `SHA256SUMS`와 다운로드 파일을 대조합니다.
3. 압축을 풀고 `Start-HermesEasySetup.cmd`를 더블클릭합니다.
4. `PC 확인` 결과를 읽습니다.
5. 설치 옵션, 세 경로, tag 객체, peeled commit, 설치기와 manifest 해시를 검토합니다.
6. 동의 체크박스를 직접 선택한 뒤 설치를 시작합니다.
7. 4단계에서 OpenAI Codex 인증 상태를 확인합니다. 로그인이 필요하면 버튼을 누르고 열린 브라우저에서 OAuth만 승인합니다.
8. 설치된 Hermes가 제공하는 Codex 모델 목록에서 기본 모델을 선택합니다. 기본 선택은 `gpt-5.6-terra`입니다.
9. 5단계에서 프로필 이름·Full name·역할, Mattermost URL·봇 토큰·홈 채널, NetBird IP와 Dashboard 인증값을 입력합니다.
10. UAC를 승인하면 Gateway와 Dashboard가 숨김 S4U 작업으로 Windows 부팅 시 시작되고, 매주 일요일 04:00 업데이트 작업이 등록됩니다.
11. v0.1.1 화면에서 설치 검증 로그는 성공했지만 마지막에 실패로 표시된 PC라면 `PC 확인`을 다시 실행하세요. 완료 기록·official origin·pin·경로가 모두 맞으면 `기존 설치 설정 계속`이 나타납니다.

Hermes 설치와 Codex 인증에는 관리자 권한이 필요하지 않습니다. Windows 부팅 작업을 등록하는 시점에는 UAC 승인이 한 번 필요합니다. 작업은 관리자나 SYSTEM이 아니라 현재 사용자 권한의 S4U 방식으로 실행되며 Windows 암호를 저장하지 않습니다.

CLI로 계획만 확인할 수도 있습니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HermesEasySetup.ps1 `
  -Action Plan -SkipComputerUse -Json
```

실제 설치는 `-Apply`를 명시해야 시작됩니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HermesEasySetup.ps1 `
  -Action Install -Apply -SkipComputerUse
```

## 연구실 연결 단계

- 새 프로필은 기본 프로필을 복제하지 않고 생성하므로 SOUL, 메모리, 세션과 대화 기록이 분리됩니다. Codex 인증 저장소만 Hermes의 정상 동작대로 공유됩니다.
- 선택한 모델에 `openai-codex`를 고정하고 로컬 터미널, `display.tool_progress=log`, 압축 임계값 `0.85`, 자동 세션 초기화 없음이 적용됩니다.
- 기존 Mattermost·Slack·Discord 등 메시징 연결값을 제거하고 입력한 Mattermost 값만 저장합니다.
- Mattermost는 연구실 사용자 전체 허용, 채널 @멘션 시에만 응답, DM은 멘션 없이 응답, 새 채널 답변은 일반 대화, 기존 스레드 요청은 해당 스레드 응답으로 고정됩니다.
- Dashboard와 Gateway는 감지된 NetBird IPv4에 맞춰 현재 사용자 권한의 숨김 S4U Scheduled Task로 Windows 부팅 시 시작합니다.
- 매주 일요일 04:00 `hermes update --yes`를 실행하고 성공한 경우에만 프로필 Gateway와 Dashboard를 재시작합니다.
- Mattermost 봇 토큰은 Bot Control 등록 요청의 Bearer 인증에만 사용하고 마법사 로그·명령행·등록 데이터에 저장하지 않습니다.
- GUI에서 worker로 넘기는 봇 토큰과 Dashboard 비밀번호는 Windows DPAPI CurrentUser로 암호화한 임시 파일을 사용하며 작업 종료 시 삭제합니다.
- Bot Control 0.6.0 이상이 설치되어 있어야 자동 등록이 성공합니다. Mattermost 서버에서 해당 NetBird Dashboard URL에 접근할 수 없으면 등록 단계에서 중단합니다.
- Dashboard 시작은 최대 240초 기다린 다음 로그인과 실제 인증 세션까지 검증합니다. 시작 지연과 로그인 실패는 별도로 표시합니다.
- 재시도 시 이 프로필의 관리 대상 Gateway·Dashboard 예약 작업만 재시작합니다. 실패한 뒤 같은 창에서 입력값을 유지하고 기존 프로필로 다시 시도할 수 있습니다.

다른 컴퓨터에서의 설치 및 Bot Control 자동 등록 전체 흐름은 실제 테스트가 필요합니다. 단위·GUI 테스트 통과만으로 모든 PC의 연결 성공을 보장하지는 않습니다.

## 예상되는 시스템 변경

승인 뒤 공식 Hermes 설치기는 다음 작업을 할 수 있습니다.

- 기본 `%LOCALAPPDATA%\hermes`에 코드, venv, managed Node/uv, 설정 템플릿과 Hermes 데이터 폴더 생성 또는 업데이트
- `%LOCALAPPDATA%\hermes\hermes-agent\bin`을 사용자 PATH에 추가하고 `HERMES_HOME` 사용자 환경 변수 설정 또는 갱신
- Python, managed uv와 후속 도구 설정을 위한 managed Node 등 core CLI 실행 기반 다운로드
- 임의의 기존 checkout 채택·업데이트는 거부합니다. `-Resume`은 같은 마법사가 만든 동일 계획/manifest checkpoint와 launcher attestation v1의 전체 정적 provenance가 함께 남은 경우에만 공식 idempotent 단계를 다시 적용합니다.
- v0.1.2는 선택적 Browser/TUI npm 의존성 설치, Computer Use 사전 설치와 Electron Desktop 빌드를 실행하지 않음

마법사의 캐시, 체크포인트와 로그는 별도 `%LOCALAPPDATA%\HermesEasySetup`에 저장됩니다. 백업·제거·강제 downgrade는 하지 않습니다. 처리된 실패는 새 PATH/HERMES_HOME 노출, exact fresh launcher, 이번 실행의 attestation과 launcher exclude 변경을 compare/CAS 방식으로 되돌리므로 보통 다음 `-Resume`에 필요한 attestation도 남지 않습니다. `-Resume`은 attestation 발급 뒤 프로세스가 비정상 종료되어 동일 계획/manifest의 Running 또는 Failed checkpoint와 attestation이 모두 살아남은 제한된 경우에만 허용됩니다. 그 밖의 기존 경로는 새 빈 InstallDir에서 다시 시작해야 하며, 기존 설치 경로를 직접 삭제하거나 초기화하기 전에는 진단 로그를 검토하세요.

## 안전 흐름

1. Windows 버전, PowerShell, CPU 아키텍처, 대상 경로와 여유 공간을 읽기 전용으로 확인합니다.
2. `InstallDir == HermesHome\hermes-agent`와 별도 RuntimeRoot를 강제하고 foreign checkout/reparse 경로를 거부합니다.
3. annotated release tag와 실제 peeled commit을 구분해 기록합니다.
4. 정확한 commit raw URL 또는 정확한 Git blob API 경로에서 설치기를 받습니다.
5. 바이트 크기, SHA-256, PowerShell AST를 검증합니다.
6. 공식 stage protocol과 전체 manifest를 검토된 계약과 대조합니다.
7. 승인 지문을 첫 변경 직전에 다시 계산합니다.
8. `needs_user_input=false` 단계만 별도 프로세스로 실행하고 매 단계 직전 설치기를 재해시합니다.
9. 상류 설치기의 `configure`와 `gateway` 대화형 단계는 실행하지 않고, 검증 후 마법사의 제한된 Codex·Mattermost 설정만 비대화형으로 적용합니다.
10. fresh repository 직후 clean proof를 만들고 path 단계가 만든 정확한 PE launcher 두 개만 `.git/info/exclude`에 등록한 뒤, commit·설치기 digest·경로·launcher hash를 RuntimeRoot의 canonical attestation에 묶습니다.
11. repository-aware Git 실행 전 raw `.git/config` 허용 목록, `commondir`, `config.worktree`, active `info/attributes`, alternates를 파일 I/O로 검사하고, hooks/fsmonitor/system·global 설정을 격리합니다.
12. Hermes 코드를 실행하기 전에 attestation과 launcher를 다시 읽고 marker, raw origin, top-level/git-dir, HEAD/index tree, index flags와 clean status를 모두 확인합니다.
13. 검증된 CLI 설치 상태를 확정한 뒤 Codex OAuth 브라우저 승인만 외부에서 진행하며, 모델과 나머지 설정은 모두 마법사 화면에서 선택·검증합니다.

실행되는 기본 단계에는 종류에 따라 30분 또는 90분의 상한이 있으며 timeout 시 해당 프로세스 트리를 종료합니다. path snapshot 이후 후속 단계나 최종 Verify가 실패해도 PATH/HERMES_HOME, exact launcher, attestation과 이번 실행의 exclude 변경은 각각 독립적으로 복구를 시도합니다. checkout, 다운로드된 dependencies와 실패 checkpoint까지 되돌리는 제거·트랜잭션 기능은 아닙니다.

설치 상태와 설정 상태는 별도로 검증합니다. Codex 단계는 `hermes auth status openai-codex`, 마지막 단계는 Dashboard HTTP 상태와 Gateway 상태를 확인합니다. OAuth 토큰, 봇 토큰과 Dashboard 비밀번호는 작업 로그나 진단 ZIP에 넣지 않습니다.

## 보존 원칙

진단 ZIP은 Hermes 홈을 순회하거나 인증 정보·메모리·대화를 수집하지 않습니다. 사용자가 연구실 연결을 실행하면 선택한 프로필의 `.env`, `config.yaml`, `SOUL.md` 및 공용 Dashboard 인증 설정을 읽거나 갱신합니다. Codex 인증은 Hermes 명령을 통해 처리합니다.

진단 정제는 best-effort입니다. 알려진 토큰과 사용자 경로를 치환하지만 모든 민감정보를 수학적으로 보장할 수는 없습니다. ZIP은 자동 업로드되지 않으며, 공유 전 사용자가 직접 열어 보고 사용 후 삭제해야 합니다.

## 공급망 경계

직접 보장하는 범위는 다음과 같습니다.

- 공식 repository와 annotated tag 객체, peeled commit 연결
- 해당 commit tree의 `scripts/install.ps1` Git blob, 크기, SHA-256
- signed Microsoft System32 Windows PowerShell만 설치기 host로 사용
- Program Files의 서명된 Git for Windows를 필수로 확인하고, 상류가 매 stage 다시 읽는 User+Machine PATH에서도 그 파일이 첫 `git` 후보인지 실행 직전마다 검사하며 PATHEXT와 PowerShell module 경로를 축소
- 새 repository clone에는 일회성 Git global/attributes 설정으로 LF checkout을 선행 적용하고, 기존/검증 checkout에는 system·user global·hook·fsmonitor 격리를 적용
- stage protocol 및 manifest의 fail-closed 검증
- fresh checkout in-memory proof 뒤에만 발급되는 write-once canonical launcher attestation과 exact launcher exclude 두 패턴
- repository-aware Git 이전의 raw metadata gate, 실행 전 raw origin, Git layout/index 및 launcher·attestation 정적 검증
- 승인되지 않은 호스트, 캐시 변조와 예상 밖 단계 거부

fresh clone은 RuntimeRoot의 빈 global attributes/excludes와 `core.autocrlf=false`를 사용하되 system Git 설정과 표준 프록시 환경 변수는 유지합니다. 기존/재개 checkout의 모든 stage와 정적 검증은 별도 managed global 설정을 쓰고 system 설정까지 끕니다. 어떤 모드도 사용자의 `~/.gitconfig`를 읽거나 수정하지 않으므로 user-global에만 둔 프록시, 사설 CA, credential helper는 적용되지 않습니다.

`state\launcher-attestation-v1.json`은 same-run fresh proof가 확인한 연속성과 우발적 변조를 탐지하는 기록이며 서명이나 MAC이 아닙니다. 같은 사용자 권한으로 RuntimeRoot와 InstallDir을 함께 바꾸고 attestation까지 다시 쓰는 공격에 대한 암호학적 진위를 보장하지 않으며, 전체 venv와 전이 의존성도 attestation 범위 밖입니다.

현재 안전 경계에서는 [공식 Git for Windows](https://gitforwindows.org/)가 Program Files에 미리 설치되어 있어야 합니다. 공식 Hermes 설치기의 해시 미고정 portable Git 다운로드 경로는 실행하지 않습니다.

v0.1.x는 상류 설치기의 경로 표기 변환과 wrapper의 복구 계약이 어긋나지 않도록 DOS 8.3 짧은 경로(`FIRSTL~1` 형태)를 거부합니다. 기본 GUI 경로나 직접 지정하는 긴 절대 경로를 사용하세요.

공식 설치 스크립트가 이후 받는 Python, Node, 시스템 패키지 등 모든 전이 산출물의 완전한 재현성까지 보장하지는 않습니다. 자세한 내용은 [SECURITY.md](SECURITY.md)를 참고하세요.

## CLI 작업

| 작업 | 설명 | 시스템 변경 |
|---|---|---:|
| `Diagnose` | 설치 준비 상태 확인 | 없음 |
| `Plan` | 고정 소스와 변경 계획 표시 | 없음 |
| `Install` | 공식 비대화형 단계 실행 | `-Apply` 필요 |
| `Verify` | 대상 설치와 고정 commit 확인 | 없음 |
| `Setup` | 보이는 공식 설정 프로세스 시작·종료 추적(구성 완료 판정 아님) | 사용자 입력에 따라 변경 |
| `CodexStatus` | OpenAI Codex 인증 상태와 Hermes 모델 카탈로그 확인 | 없음 |
| `CodexAuth` | 브라우저 OAuth 후 Hermes 인증 상태 확인 | `-Apply` 필요 |
| `LabSetup` | 암호화된 GUI 입력으로 프로필·Mattermost·Dashboard·Gateway·Bot Control 등록 구성 | `-Apply` 필요 |
| `Bundle` | 정제된 로컬 진단 ZIP 생성 | 마법사 진단 폴더만 |

주요 종료 코드는 `0` 성공, `2` 승인/인수/재개 오류, `10` 사전 점검 실패, `20` 소스 검증 실패, `30` protocol 불일치, `40` 설치 단계 실패, `50` 최종 검증 실패입니다.

## 개발 및 검증

네트워크나 Hermes 설치 없이 로컬 검증을 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-RepositoryHygiene.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PowerShellSyntax.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-SecurityTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-GuiTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-LabDashboardTests.ps1
```

상류 tag→commit→blob, base manifest와 Desktop manifest의 drift만 다시 확인하려면 다음을 실행합니다. Hermes 설치 단계는 0개 실행되며 Desktop manifest 확인은 v0.1.2의 Desktop 설치 지원을 의미하지 않습니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-UpstreamContractSmoke.ps1
```

실제 Hermes 설치 E2E는 비용과 시간이 커서 `Windows install E2E` 수동 workflow에서만, 자격증명과 setup 없이 일회성 GitHub runner에 실행합니다. 현재 CI의 ARM64 실기기 검증은 아직 없습니다.

구조는 [docs/architecture.md](docs/architecture.md), pin 갱신은 [docs/updating-the-pin.md](docs/updating-the-pin.md), 기여 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)에 있습니다. 버전은 자동으로 최신 upstream을 따라가지 않으며 검토된 pin 변경과 새 release를 통해서만 갱신됩니다.

## 라이선스

마법사 코드는 [MIT License](LICENSE)로 배포됩니다. Hermes Agent는 별도 프로젝트이며 해당 저장소의 라이선스와 정책을 따릅니다.
