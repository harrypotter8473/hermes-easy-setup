# 아키텍처

Hermes Easy Setup은 Hermes 설치 로직을 다시 구현하지 않습니다. 한국어 WPF와 안전 경계를 제공하고, 고정·검증된 공식 `scripts/install.ps1`의 stage protocol v1을 단계별로 구동합니다.

```text
사용자
  -> 5단계 WPF: PC 확인 -> 계획/승인 -> CLI 설치/검증 -> 공식 설정 -> 연구실 연결
  -> 기본 거부 승인 + plan fingerprint
  -> 별도 signed System32 PowerShell worker
  -> tag object -> peeled commit -> installer blob 검증
  -> protocol/manifest 정확 일치 검증
  -> 첫 변경 직전 plan freshness
  -> stage별 재해시 + 제한시간 + JSON frame 검증
  -> 원자적 체크포인트
  -> fresh-only launcher 정상화 + no-exec Git/index/launcher 정적 검증
  -> 검증된 설치 상태 확정
  -> Portal/Full 선택 시 별도 보이는 공식 hermes setup 프로세스(입출력 비수집)
  -> 설치와 구분된 설정 프로세스 종료 상태
```

## 단일 모듈 경로

| 구성 | 책임 |
|---|---|
| `Start-HermesEasySetup.cmd` | System32 Windows PowerShell 5.1 STA 진입점 |
| `HermesEasySetup.Gui.ps1` | 5단계 WPF, 계획 승인, 격리 install worker, 보이는 공식 setup, DPAPI Lab worker 추적 |
| `src/HermesEasySetup.Lab.psm1` | 새 프로필 격리, Mattermost 설정, NetBird Dashboard Task, Gateway Task, Bot Control 자동 등록·검증 |
| `HermesEasySetup.ps1` | `Diagnose/Plan/Install/Verify/Setup/Bundle` CLI와 종료 코드 |
| `src/HermesEasySetup.Core.psm1` | 경로, pin 설정, 해시, 오류 코드, 로그 정제 |
| `src/HermesEasySetup.Preflight.psm1` | target-bound command, preflight, 계획 지문 |
| `src/HermesEasySetup.StateStore.psm1` | 설치 잠금, 원자적 checkpoint, fail-closed resume |
| `src/HermesEasySetup.Execution.psm1` | signed PowerShell, argv, process-tree timeout, JSON/event |
| `src/HermesEasySetup.Protocol.psm1` | installer와 protocol/manifest 검증 |
| `src/HermesEasySetup.InstallEngine.psm1` | 공식 stage 조정과 provenance 최종 검증 |
| `src/HermesEasySetup.Bundle.psm1` | 허용 목록 기반 로컬 진단 ZIP과 경로 정제 |

`Loader.psm1`은 이 순서의 7개 모듈만 import합니다. compat/initial 구현이나 이름 충돌 override는 배포에 포함하지 않습니다.

## 승인과 freshness

`Plan`은 읽기 전용입니다. 지문에는 tag object, peeled commit, raw/API URL, blob과 SHA-256, protocol, manifest 파일 SHA-256, 세 mutable 경로와 모든 옵션이 들어갑니다.

CLI `Install`은 `-Apply`가 없으면 종료 코드 2로 중단됩니다. GUI는 기본 해제된 승인 체크박스를 사용하며 승인 지문을 worker에 전달합니다. worker는 첫 runtime mutation 전 지문을 확인하고, protocol/manifest를 읽은 뒤 첫 Hermes 변경 직전에 다시 계산합니다.

## 경로와 기존 설치

v1은 `InstallDir == HermesHome\hermes-agent`를 강제합니다. RuntimeRoot는 두 Hermes 경로와 서로 포함될 수 없습니다. drive root, 사용자 프로필 전체, Windows 폴더, UNC/device, wildcard, DOS 8.3 짧은 경로와 기존 reparse 경로를 거부합니다.

비어 있지 않은 InstallDir은 임의로 채택하지 않습니다. 오직 `-Resume`, 동일 계획/manifest의 resumable checkpoint, launcher attestation v1과 전체 `StaticProvenanceValid`가 모두 맞는 동일 wizard 실행 경계만 읽기 전용으로 받아들입니다. 그 밖의 legacy/foreign checkout은 공식 origin이어도 새 빈 InstallDir을 요구합니다. PATH의 다른 `hermes`는 진단·검증·설정에 사용하지 않습니다.

## 공급망 경계

`config/hermes-source.json`은 annotated tag object SHA와 peeled commit SHA를 구분합니다. 또한 raw URL, API blob URL, Git blob SHA, 정확한 크기, SHA-256과 protocol을 고정합니다. 네트워크 상류 스모크는 tag→commit→tree blob 연결까지 확인합니다.

다운로드 파일과 캐시는 크기·SHA와 PowerShell AST를 검사합니다. 같은 파일을 protocol/manifest 및 각 stage 실행 직전에 다시 검사합니다. 공식 manifest는 단계 순서, category와 `needs_user_input`을 포함해 `config/hermes-manifest.json`과 비교합니다.

## 단계 실행과 재개

각 자동 단계는 새 signed Windows PowerShell 프로세스에서 `-Stage`, `-Commit`, `-HermesHome`, `-InstallDir`, `-SkipSetup`, `-NonInteractive`, `-Json`으로 실행됩니다. stdout/stderr는 stream별 4 MiB로 제한하고 마지막 유효 JSON frame을 스키마 검증합니다.

설치 시작 전과 매 stage 직전에 registry User PATH 다음 Machine PATH를 순서대로 해석해 첫 `git` 명령이 서명된 Program Files `git.exe`와 정확히 일치하는지 확인합니다. 상류 `Sync-EnvPath`가 child process PATH prefix를 덮어쓰기 때문에 이 registry 검사가 필요합니다. child에는 `PATHEXT=.COM;.EXE;.BAT;.CMD`, System32-only PSModulePath, `core.hooksPath=NUL`, `core.fsmonitor=false`를 전달하고 Git redirect/UI/trace 환경을 제거합니다.

fresh `repository`는 RuntimeRoot의 예측 불가능한 managed global 설정과 빈 attributes/excludes를 `CreateNew`로 만들고 LF checkout을 선행합니다. fresh mode는 system Git 설정을 유지합니다. 기존/재개 stage와 정적 verification은 별도 managed global을 쓰고 system 설정까지 끕니다. 세 모드 모두 user global 파일을 읽거나 수정하지 않으며 일회성 파일은 stage 뒤 제거합니다.

v0.1.2는 core CLI stage만 실행하고 `-SkipComputerUse`를 강제합니다. 선택적 Browser/TUI npm 설치인 `node-deps`는 child process를 만들기 전에 정책상 `Skipped`로 기록하며, Computer Use 사전 설치와 Desktop stage는 후속 버전까지 설치 진입 전에 거부합니다. 실행되는 일반 stage 제한은 30분, dependencies/platform-sdks는 90분입니다. timeout이면 정확한 System32 `taskkill.exe /T /F`로 해당 프로세스 트리를 정리합니다. path snapshot 이후 caught failure는 PATH/HERMES_HOME, 이번 exclude write, exact launcher와 attestation을 독립적으로 compare/CAS 복구하지만 checkout·venv·dependencies·실패 state 전체를 원복하지는 않습니다.

`-Resume`은 schema, Running/Failed 상태, 계획 지문, manifest와 launcher attestation v1의 전체 정적 provenance가 모두 같은 경우만 허용됩니다. 이전 success 기록은 재개하지 않습니다. fresh in-memory proof는 상태 파일에 저장하지 않고 정상 caught failure는 새 attestation도 제거하므로, attestation 발급 뒤 비정상 종료로 두 기록이 함께 남은 제한된 경우만 모든 자동 단계를 Pending으로 되돌려 공식 idempotent stage를 다시 적용합니다. `configure`와 `gateway`는 별도 대화형 설정으로 넘깁니다.

## 설치와 공식 설정의 분리

4단계 WPF는 install worker가 종료하고 최종 provenance·CLI 검증이 성공한 뒤 Portal/Full을 선택한 경우에만 사용자의 명시적 버튼 입력으로 공식 `hermes setup --portal` 또는 `hermes setup`을 새 보이는 콘솔에서 시작합니다. setup은 install worker의 stdout/stderr 리디렉션을 재사용하지 않습니다. 키보드 입력, 공급자 자격증명과 setup의 stdin/stdout/stderr는 공식 Hermes 콘솔에만 머물며 마법사 이벤트·로그·진단 번들에 복사하지 않습니다.

5단계 Lab worker는 provider setup과 분리됩니다. GUI는 Mattermost 봇 토큰과 Dashboard 비밀번호가 포함된 JSON을 Windows DPAPI CurrentUser로 암호화한 뒤 RuntimeRoot의 ui-transport 아래 임시 파일로 전달합니다. CLI 인수와 JSON 이벤트에는 비밀값을 넣지 않으며 worker는 파일을 복호화해 사용한 뒤 삭제합니다.

Lab worker는 기본 프로필을 clone한 새 프로필에서 메시징 환경 변수만 정리하고 Mattermost 연결과 관리 정체성을 기록합니다. Dashboard는 NetBird IP에 바인딩된 사용자 Scheduled Task로, Gateway는 해당 프로필의 공식 Hermes gateway install 명령으로 자동 시작합니다. 마지막으로 봇 토큰으로 Bot Control 등록 API를 호출하며 Mattermost 플러그인이 호출자의 봇 계정 여부와 Dashboard 로그인·상태를 검증한 뒤 연결 정보를 저장합니다.

기존 설치의 setup-only 진입은 진단 Ready, exact official origin, `InstallDir\bin\hermes.exe`, 현재 peeled pin, schema 2의 case-exact `Completed`, 성공 verification과 HermesHome/InstallDir/RuntimeRoot 일치를 모두 요구합니다. 이 조건은 버튼 표시 자격일 뿐 실행 신뢰의 대체물이 아닙니다. 사용자가 설정 시작을 누르면 `Start-HermesOfficialSetup`이 현재 launcher attestation·Git/index·managed launcher와 CLI 실행을 다시 전체 검증하고, 실패하면 공식 setup child를 시작하지 않습니다.

마법사는 설치 상태와 setup 프로세스 상태를 별도로 유지합니다. setup 프로세스의 종료 코드 0 또는 사용자가 창을 닫은 사실은 프로세스 종료 신호일 뿐, 모든 공급자 설정이 저장·검증되었다는 증거가 아닙니다. 따라서 설치 성공을 setup 결과 때문에 실패로 바꾸지 않고, setup 종료도 자동으로 `구성 완료`라고 표시하지 않습니다.

## 최종 provenance 검증

성공에는 다음이 모두 필요합니다.

- `bin`에 exact `hermes.exe`/`hermes-acp.exe` 두 파일만 있고 대응 `venv\Scripts` launcher와 길이·SHA-256이 일치하며 DOS/PE 헤더가 구조적으로 유효
- `.git/info/exclude`의 active 패턴이 exact 두 launcher뿐이며 예상 밖 `bin` 파일은 숨기지 않음
- canonical `state\launcher-attestation-v1.json`의 path binding, peeled commit, installer digest와 두 launcher record가 현재 파일과 일치
- `venv\Scripts\python.exe`가 non-reparse 일반 PE 파일로 존재
- `.git` checkout과 서명된 Program Files Git 존재
- repository-aware Git 전에 raw `.git/config` exact allowlist, redirect 파일, active info attributes와 alternates 검사를 통과
- raw local origin이 정확히 하나의 공식 HTTPS/SSH 값이며 top-level과 absolute git-dir가 예상 경로와 일치
- HEAD와 index tree가 peeled pin tree와 일치하고 assume-unchanged/skip-worktree/gitlink가 없음
- 격리된 Git status가 clean
- bounded strict UTF-8 `.hermes-bootstrap-complete` schema 1과 pinnedCommit 일치
- 위 정적 조건과 launcher/attestation 즉시 재검사를 모두 통과한 뒤에만 절대경로 `bin\hermes.exe --version` 실행

attestation은 fresh same-run proof가 만든 연속성 기록이지만 서명/MAC은 아닙니다. 같은 사용자 권한이 RuntimeRoot와 InstallDir을 함께 수정하는 위조와 전체 venv·전이 dependency 진위는 이 모델 밖입니다.

`hermes doctor`는 공급자 설정 전 경고가 날 수 있어 기록하되, 위 provenance 검증과 분리합니다.

## 데이터와 진단

```text
%LOCALAPPDATA%\hermes                       Hermes 데이터와 설치
%LOCALAPPDATA%\HermesEasySetup\cache        검증된 설치기
%LOCALAPPDATA%\HermesEasySetup\logs         정제 로그
%LOCALAPPDATA%\HermesEasySetup\state        체크포인트
%LOCALAPPDATA%\HermesEasySetup\diagnostics  로컬 ZIP
```

진단 ZIP은 Hermes 홈을 순회하지 않습니다. 마법사가 생성한 허용 목록 파일만 복사하고 토큰과 알려진 로컬 경로를 다시 정제합니다.
