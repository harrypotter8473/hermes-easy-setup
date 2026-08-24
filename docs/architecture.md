# 아키텍처

Hermes Easy Setup은 Hermes 설치 로직을 다시 구현하지 않습니다. 한국어 WPF와 안전 경계를 제공하고, 고정·검증된 공식 `scripts/install.ps1`의 stage protocol v1을 단계별로 구동합니다.

```text
사용자
  -> WPF 계획 + 기본 거부 승인
  -> 승인 plan fingerprint
  -> 별도 signed System32 PowerShell worker
  -> tag object -> peeled commit -> installer blob 검증
  -> protocol/manifest 정확 일치 검증
  -> 첫 변경 직전 plan freshness
  -> stage별 재해시 + 제한시간 + JSON frame 검증
  -> 원자적 체크포인트
  -> target launcher/venv/origin/HEAD/marker 검증
  -> 보이는 공식 hermes setup 프로세스
```

## 단일 모듈 경로

| 구성 | 책임 |
|---|---|
| `Start-HermesEasySetup.cmd` | System32 Windows PowerShell 5.1 STA 진입점 |
| `HermesEasySetup.Gui.ps1` | 3단계 WPF, 계획 승인, 격리 worker 이벤트 표시 |
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

v1은 `InstallDir == HermesHome\hermes-agent`를 강제합니다. RuntimeRoot는 두 Hermes 경로와 서로 포함될 수 없습니다. drive root, 사용자 프로필 전체, Windows 폴더, UNC/device, wildcard와 기존 reparse 경로를 거부합니다.

비어 있지 않은 InstallDir은 정확한 공식 HTTPS 또는 SSH origin의 Git checkout이어야 합니다. PATH의 다른 `hermes`는 진단·검증·설정에 사용하지 않습니다.

## 공급망 경계

`config/hermes-source.json`은 annotated tag object SHA와 peeled commit SHA를 구분합니다. 또한 raw URL, API blob URL, Git blob SHA, 정확한 크기, SHA-256과 protocol을 고정합니다. 네트워크 상류 스모크는 tag→commit→tree blob 연결까지 확인합니다.

다운로드 파일과 캐시는 크기·SHA와 PowerShell AST를 검사합니다. 같은 파일을 protocol/manifest 및 각 stage 실행 직전에 다시 검사합니다. 공식 manifest는 단계 순서, category와 `needs_user_input`을 포함해 `config/hermes-manifest.json`과 비교합니다.

## 단계 실행과 재개

각 자동 단계는 새 signed Windows PowerShell 프로세스에서 `-Stage`, `-Commit`, `-HermesHome`, `-InstallDir`, `-SkipSetup`, `-NonInteractive`, `-Json`으로 실행됩니다. stdout/stderr는 stream별 4 MiB로 제한하고 마지막 유효 JSON frame을 스키마 검증합니다.

일반 stage 제한은 30분, dependencies/node-deps/platform-sdks는 90분, Desktop은 180분입니다. timeout이면 정확한 System32 `taskkill.exe /T /F`로 해당 프로세스 트리를 정리합니다.

`-Resume`은 schema, 실행 중/실패 상태, 계획 지문과 manifest가 모두 같은 경우만 허용됩니다. 이전 success 기록의 postcondition을 추측하지 않고 모든 자동 단계를 Pending으로 되돌려 공식 idempotent stage를 다시 적용합니다. `configure`와 `gateway`는 별도 대화형 설정으로 넘깁니다.

## 최종 provenance 검증

성공에는 다음이 모두 필요합니다.

- 대상 `InstallDir\bin\hermes.exe` 또는 `venv\Scripts\hermes.exe`가 실제 실행됨
- `venv\Scripts\python.exe` 존재
- `.git` checkout과 managed Git 존재
- origin이 정확한 공식 HTTPS/SSH 값
- checkout이 clean이고 HEAD가 peeled pin과 정확히 일치
- `.hermes-bootstrap-complete` schema 1과 pinnedCommit 일치

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
