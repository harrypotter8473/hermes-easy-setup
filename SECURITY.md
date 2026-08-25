# 보안 정책

## 지원 버전

| 버전 | 보안 수정 |
|---|---|
| `0.1.x` 최신 release | 지원 |
| 이전 `0.1.x` | 최신 patch로 갱신 권장 |
| unreleased source snapshot | 보장 없음 |

검증된 Hermes pin에 문제가 확인되면 해당 wizard release를 철회하고 새 pin과 체크섬을 배포합니다. 자동 업데이트는 하지 않습니다.

## 보안 문제 제보

토큰, API 키, `.env`, 세션, 전체 로그를 공개 이슈에 올리지 마세요. 공개 후 [GitHub Private Vulnerability Reporting](https://github.com/harrypotter8473/hermes-easy-setup/security/advisories/new)을 활성화해 기본 비공개 신고 채널로 사용합니다. 기능이 아직 열려 있지 않다면 비밀을 제외한 최소 정보만으로 공개 이슈를 만들고 비공개 전달 방법을 요청해 주세요.

진단 ZIP은 자동 업로드되지 않습니다. 공유하기 전 직접 내용을 확인하고, 전달이 끝나면 원본 ZIP을 삭제하세요.

## 신뢰하는 것

- release 체크섬과 일치하는 이 저장소의 PowerShell 코드 및 고정 설정
- 고정된 `NousResearch/hermes-agent` annotated tag 객체와 peeled commit
- 해당 commit tree의 `scripts/install.ps1` Git blob, 크기와 SHA-256
- 검토된 stage protocol v1 manifest
- 유효한 Microsoft Authenticode 서명의 정확한 System32 Windows PowerShell
- 유효한 Johannes Schindelin Authenticode 서명의 Program Files Git for Windows

## 신뢰하지 않고 검증하는 것

- 네트워크 응답과 리디렉션
- 기존 설치기 캐시와 상태 파일
- 기존 설치 디렉터리, Git origin, checkout과 reparse point
- 공식 설치기의 protocol/manifest 및 stage JSON 출력
- PATH의 `hermes`나 `powershell.exe`
- 사용자가 지정한 mutable 경로
- 새 clone의 사용자 global Git 줄바꿈 설정과 command parameter 주입
- 상류 설치기가 다시 읽는 User/Machine registry PATH의 명령 순서, ambient PATHEXT와 사용자 PowerShell module 경로
- 기존 launcher attestation과 RuntimeRoot 상태

검증 실패 시 설치는 계속 진행하지 않습니다. 사용자 승인 계획 지문은 첫 변경 직전에 다시 확인하고, 설치기는 protocol/manifest와 매 stage 실행 직전에 재해시합니다.

새 설치의 `repository` 단계는 RuntimeRoot 아래 예측 불가능한 UTF-8 no-BOM managed global 설정과 빈 attributes/excludes 파일을 `CreateNew`로 만들고 `core.autocrlf=false`를 clone 전에 적용합니다. fresh clone에서는 system Git 설정과 표준 네트워크 환경을 유지하지만 user global은 읽지 않습니다. 기존/재개 checkout의 모든 stage와 정적 검증은 managed global을 별도로 만들고 system 설정도 끕니다. 모든 모드에서 Git redirect/UI/trace 환경을 제거하고 `GIT_CONFIG_COUNT=2`로 `core.hooksPath=NUL`, `core.fsmonitor=false`를 고정하며, PATHEXT는 `.COM;.EXE;.BAT;.CMD`, PSModulePath는 System32 module로 제한합니다.

공식 설치기는 각 stage 시작 시 registry User+Machine PATH로 process PATH를 덮어씁니다. 따라서 설치 시작 전과 매 stage 직전에 그 PATH를 파일 I/O로 순서대로 해석해 첫 `git` 후보가 정확한 서명된 Program Files `git.exe`인지 확인합니다. 경쟁 `git.com/.bat/.cmd/.ps1`, 빈·잘못된 PATH 항목은 실패-폐쇄되며, 이 검사를 통과하지 못하면 상류 프로세스를 시작하지 않습니다.

fresh repository 직후에는 exact HEAD/origin, clean status, 빈 active local exclude와 non-reparse 경로를 in-memory proof로 묶습니다. path 직전에 proof와 launcher 원본을 다시 확인하고, 대응 `venv\Scripts` 파일과 길이·SHA-256이 같고 유효한 bounded PE 헤더를 가진 exact `bin/hermes.exe`/`hermes-acp.exe` 두 개만 `.git/info/exclude`에 CAS 방식으로 등록합니다.

그 직후 RuntimeRoot의 `state\launcher-attestation-v1.json`을 strict UTF-8 canonical JSON으로 한 번만 발행합니다. schema, contract, HermesHome/InstallDir/RuntimeRoot path binding SHA-256, peeled commit, 설치기 SHA-256, 두 launcher 이름·길이·SHA-256을 묶으며 기존 파일은 바이트가 완전히 같은 경우 외에는 교체하지 않습니다. 기존/재개 checkout은 이 attestation과 전체 정적 provenance가 이미 맞는 경우만 읽기 전용으로 허용합니다. 일반 caught failure는 이번 실행이 쓴 attestation을 제거하므로, 재개는 attestation과 동일 checkpoint가 남은 제한적 비정상 종료에만 가능합니다.

repository-aware Git 전에 raw `.git/config`의 exact allowlist(상류의 단일 `windows.appendAtomically=false` 포함)를 적용하고 `commondir`, `config.worktree`, active `.git/info/attributes`, object alternates를 거부합니다. 그 뒤에만 격리된 서명 Git으로 raw origin, top-level/absolute git-dir, expected HEAD/index tree, index flags, gitlink 부재와 clean status를 검사합니다. Hermes 실행 직전 launcher와 attestation을 다시 확인합니다.

path snapshot 뒤 후속 stage 또는 최종 Verify가 실패하면 PATH/HERMES_HOME 복구, launcher exclude CAS 복원, exact fresh launcher 삭제, 이번 실행 attestation 삭제를 서로 독립된 best-effort 작업으로 수행해 한 복구 실패가 나머지를 막지 않게 합니다. 이는 checkout, venv, dependencies와 실패 checkpoint 전체를 되돌리는 트랜잭션이나 제거 기능은 아닙니다.

## 보장 범위 밖

- v0.1.1의 Computer Use 사전 설치와 Hermes Desktop 자동 빌드
- DOS 8.3 짧은 경로 표기 지원(긴 절대 경로를 사용해야 함)
- 공식 설치기가 받는 모든 전이 의존성의 완전한 고정·재현 빌드
- launcher attestation 바깥의 전체 venv·Python/Node 패키지 진위
- 같은 사용자 권한으로 동시에 실행되는 악성 프로세스가 만드는 모든 로컬 TOCTOU 공격
- 같은 사용자 권한으로 RuntimeRoot와 InstallDir을 함께 수정해 launcher와 서명/MAC 없는 attestation을 다시 쓰는 지속적 로컬 위조
- Windows 자체, GitHub, 패키지 registry 또는 upstream Hermes의 compromise
- 코드 서명되지 않은 이 마법사 소스의 publisher identity
- regex/best-effort 정제가 모든 종류의 새 비밀 형식을 제거한다는 보장
- 사용자가 공식 설정 화면에 직접 입력한 공급자 자격증명의 관리
- repository clone 중 user-global에만 정의된 기업 프록시, 사설 CA 또는 credential helper
- Program Files에 공식 Git for Windows가 없는 환경의 자동 Git 부트스트랩

이 프로젝트는 검토된 공식 설치기를 감싸는 안전 장치이지 독립적인 Hermes 배포판이 아닙니다.

## 사용자 데이터

마법사는 `.env`, `config.yaml`, 인증 데이터, skills, sessions, memories, messages와 그 밖의 Hermes 사용자 콘텐츠를 직접 수집하거나 삭제하지 않습니다. 제거 기능이 없는 것도 같은 이유입니다.

진단 번들은 마법사 자체의 사전 점검 요약, 고정 소스 요약, 정제된 상태와 최근 정제 로그만 허용 목록 방식으로 포함합니다. 알려진 사용자 프로필, Hermes, 설치 및 runtime 경로를 placeholder로 바꾸지만 OS 버전과 일반 환경 정보는 남을 수 있습니다.

## 소스 고정 및 대응

릴리스 태그만 바꾸는 변경은 허용하지 않습니다. annotated tag object, peeled commit, commit tree의 Git blob, 정확한 바이트 크기, SHA-256, protocol과 전체 manifest를 함께 검토해야 합니다.

보안 문제가 확인되면 다음 순서로 대응합니다.

1. 영향받은 wizard와 Hermes pin 범위를 판정합니다.
2. 필요하면 release 다운로드와 pin을 철회합니다.
3. 수정 pin/코드와 새 체크섬을 배포합니다.
4. 공개 advisory에 영향, 완화책과 업데이트 버전을 기록합니다.

세부 갱신 절차는 `docs/updating-the-pin.md`에 있습니다.
