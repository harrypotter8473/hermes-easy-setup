# Hermes Easy Setup

Windows에서 [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent)를 설치하는 한국어 안전 마법사입니다.

이 프로젝트는 Nous Research의 공식 제품이 아닌 비공식 커뮤니티 도구입니다. Hermes 자체의 사용법과 지원 범위는 [공식 문서](https://hermes-agent.nousresearch.com/docs/)를 기준으로 합니다.

## 현재 상태

- 버전 `0.1.1` Windows 네이티브 MVP
- 초기 범위는 Hermes CLI 설치·검증과 공식 설정 화면 연결까지입니다.
- Computer Use 사전 설치와 Hermes Desktop 자동 빌드는 후속 버전으로 미룹니다. GUI는 두 옵션을 고정하며 CLI 설치에는 `-SkipComputerUse`가 필요합니다.
- Windows 10/11 x64에서 로컬 및 CI 검증
- ARM64는 Hermes upstream Tier 1 대상이지만 이 마법사는 아직 실기기 미검증
- Windows PowerShell 5.1과 PowerShell 7 단위 테스트
- 검토된 Hermes 릴리스 `v2026.8.19` 고정
- 실제 설치 전 변경 계획, 계획 지문, 명시적 승인
- 단계별 체크포인트와 attestation이 함께 남은 제한적 비정상 종료만 안전 재개
- 로컬 전용 정제 로그와 진단 ZIP

현재 배포물은 코드 서명이 없는 `.cmd`/PowerShell 소스입니다. 공식 Hermes 설치기나 Nous Research의 서명을 대신하지 않습니다. 제거·초기화 기능도 제공하지 않습니다.

## 빠른 시작

1. 이 저장소의 GitHub Release 또는 소스 저장소에서만 파일을 받습니다.
2. Release가 제공되면 함께 게시되는 `SHA256SUMS`와 다운로드 파일을 대조합니다.
3. 압축을 풀고 `Start-HermesEasySetup.cmd`를 더블클릭합니다.
4. `PC 확인` 결과를 읽습니다.
5. 설치 옵션, 세 경로, tag 객체, peeled commit, 설치기와 manifest 해시를 검토합니다.
6. 동의 체크박스를 직접 선택한 뒤 설치를 시작합니다.
7. 설치가 끝나면 공식 `hermes setup --portal` 또는 `hermes setup` 화면에서 공급자를 설정합니다.

관리자 권한은 기본적으로 필요하지 않습니다. Windows가 미서명 스크립트 경고를 보인다면 출처와 체크섬을 먼저 확인하세요. 경고를 우회하도록 자동 설정을 바꾸지는 마세요.

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

## 예상되는 시스템 변경

승인 뒤 공식 Hermes 설치기는 다음 작업을 할 수 있습니다.

- 기본 `%LOCALAPPDATA%\hermes`에 코드, venv, managed Node/uv, 설정 템플릿과 Hermes 데이터 폴더 생성 또는 업데이트
- `%LOCALAPPDATA%\hermes\hermes-agent\bin`을 사용자 PATH에 추가하고 `HERMES_HOME` 사용자 환경 변수 설정 또는 갱신
- Python, Node, 기본 브라우저 도구와 시스템 도구 등 상류의 기본 CLI 의존성 다운로드
- 임의의 기존 checkout 채택·업데이트는 거부합니다. `-Resume`은 같은 마법사가 만든 동일 계획/manifest checkpoint와 v0.1.1 launcher attestation의 전체 정적 provenance가 함께 남은 경우에만 공식 idempotent 단계를 다시 적용합니다.
- v0.1.1은 Computer Use 사전 설치와 Electron Desktop 빌드를 실행하지 않음

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
9. `configure`와 `gateway`는 자동 실행하지 않고 보이는 공식 설정 프로세스로 넘깁니다.
10. fresh repository 직후 clean proof를 만들고 path 단계가 만든 정확한 PE launcher 두 개만 `.git/info/exclude`에 등록한 뒤, commit·설치기 digest·경로·launcher hash를 RuntimeRoot의 canonical attestation에 묶습니다.
11. repository-aware Git 실행 전 raw `.git/config` 허용 목록, `commondir`, `config.worktree`, active `info/attributes`, alternates를 파일 I/O로 검사하고, hooks/fsmonitor/system·global 설정을 격리합니다.
12. Hermes 코드를 실행하기 전에 attestation과 launcher를 다시 읽고 marker, raw origin, top-level/git-dir, HEAD/index tree, index flags와 clean status를 모두 확인합니다.

실행되는 기본 단계에는 종류에 따라 30분 또는 90분의 상한이 있으며 timeout 시 해당 프로세스 트리를 종료합니다. path snapshot 이후 후속 단계나 최종 Verify가 실패해도 PATH/HERMES_HOME, exact launcher, attestation과 이번 실행의 exclude 변경은 각각 독립적으로 복구를 시도합니다. checkout, 다운로드된 dependencies와 실패 checkpoint까지 되돌리는 제거·트랜잭션 기능은 아닙니다.

## 보존 원칙

마법사는 Hermes 사용자 데이터인 `.env`, `config.yaml`, 인증 정보, skills, sessions, memories, messages를 직접 읽거나 삭제하지 않습니다. 진단 ZIP도 Hermes 홈을 순회하지 않습니다.

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

v0.1.1은 상류 설치기의 경로 표기 변환과 wrapper의 복구 계약이 어긋나지 않도록 DOS 8.3 짧은 경로(`FIRSTL~1` 형태)를 거부합니다. 기본 GUI 경로나 직접 지정하는 긴 절대 경로를 사용하세요.

공식 설치 스크립트가 이후 받는 Python, Node, 시스템 패키지 등 모든 전이 산출물의 완전한 재현성까지 보장하지는 않습니다. 자세한 내용은 [SECURITY.md](SECURITY.md)를 참고하세요.

## CLI 작업

| 작업 | 설명 | 시스템 변경 |
|---|---|---:|
| `Diagnose` | 설치 준비 상태 확인 | 없음 |
| `Plan` | 고정 소스와 변경 계획 표시 | 없음 |
| `Install` | 공식 비대화형 단계 실행 | `-Apply` 필요 |
| `Verify` | 대상 설치와 고정 commit 확인 | 없음 |
| `Setup` | 보이는 공식 설정 프로세스 시작 | 사용자 입력에 따라 변경 |
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
```

상류 tag→commit→blob, base manifest와 Desktop manifest의 drift만 다시 확인하려면 다음을 실행합니다. Hermes 설치 단계는 0개 실행되며 Desktop manifest 확인은 v0.1.1의 Desktop 설치 지원을 의미하지 않습니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-UpstreamContractSmoke.ps1
```

실제 Hermes 설치 E2E는 비용과 시간이 커서 `Windows install E2E` 수동 workflow에서만, 자격증명과 setup 없이 일회성 GitHub runner에 실행합니다. 현재 CI의 ARM64 실기기 검증은 아직 없습니다.

구조는 [docs/architecture.md](docs/architecture.md), pin 갱신은 [docs/updating-the-pin.md](docs/updating-the-pin.md), 기여 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)에 있습니다. 버전은 자동으로 최신 upstream을 따라가지 않으며 검토된 pin 변경과 새 release를 통해서만 갱신됩니다.

## 라이선스

마법사 코드는 [MIT License](LICENSE)로 배포됩니다. Hermes Agent는 별도 프로젝트이며 해당 저장소의 라이선스와 정책을 따릅니다.
