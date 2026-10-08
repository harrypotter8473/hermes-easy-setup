# 보안 정책

## 개인 연구실 초기 버전

- 새 연구실 마법사는 loopback 서버만 지원합니다. 기존 관리자·사용자 마법사 및 기존 Hermes 프로필을 제거하거나 인수하지 않습니다.
- 서로 다른 활성 일반 봇 4개와 채널 멤버십, Hermes 설치 무결성·모델 인증을 검사한 뒤 네 독립 프로필을 생성합니다. 재설정은 현재 Windows 사용자가 이 마법사에서 생성한 프로필·예약 작업에만 허용합니다.
- 입력 전송과 발급 토큰 보관은 DPAPI CurrentUser를 사용합니다. Hermes가 실행할 각 프로필의 `.env`에는 봇 토큰이 평문으로 저장되고 폴더 ACL을 상속합니다. 공유 폴더를 설치 경로로 사용하지 마세요. 해당 폴더를 읽을 수 있는 사용자·프로세스에서 토큰을 격리하는 기능은 아닙니다. 토큰은 명령행·역할 템플릿·팀 상태·마법사 로그에 저장하지 않습니다.
- Docker 준비 확인은 알려진 전체/사용자별 설치 위치를 검사하고 실행 전 공식 배포자 서명을 확인합니다. 미설치 다운로드·설치는 별도 승인 후 고정 공식 HTTPS 파일의 SHA-256과 Authenticode를 검사합니다. 기존 설치의 강제 업데이트·제거·재설치, 약관 자동 동의, Windows 기능·그룹·방화벽·조직 정책 변경, 자동 재부팅은 하지 않습니다. 권한이나 가상화 상태를 확인하지 못하면 단정하지 않고 수동 점검을 안내합니다.
- Gateway는 현재 사용자 권한의 로그인 시 예약 작업입니다. 로그인 전 서버 서비스나 Docker Desktop 자동 실행 보장은 제공하지 않습니다. 성공 표시는 Gateway PID 상태와 예약 작업 실행을 확인한 결과이지 실제 모델 답변 확인은 아닙니다.
- 역할은 수정 가능한 프롬프트 지침입니다. 권한 격리·독립 감사의 강제 거부권·자동 협업 엔진을 뜻하지 않습니다. 실제 설치·모델 응답까지의 종단간 검증은 아직 별도로 필요합니다.

## 관리자 테스트 마법사 (0.8.0)

- Docker Desktop의 고정된 로컬 Linux named pipe와 공식 이미지 digest만 사용합니다. 외부 Docker context는 사용하지 않습니다.
- 웹 포트는 기본 loopback만 허용합니다. 명시적으로 NetBird 공유를 선택하면 공식 로컬 클라이언트 상태와 활성 인터페이스에서 확인한 NetBird IPv4 한 개에만 추가로 바인딩합니다. wildcard/LAN/공인 IP와 DB 포트는 공개하지 않습니다. 공개 가입·플러그인은 초기 비활성화합니다.
- 최초 계정을 생성한 후 서버가 부여한 `system_admin` 역할을 확인합니다. 기존 계정의 권한 승격은 하지 않습니다.
- 입력된 관리자 암호는 DPAPI 임시 전송 후 제거하며, CLI 인수·설정 JSON·로그에는 넣지 않습니다. 세션 토큰은 메모리에서만 사용하고 로그아웃합니다.
- DB 암호는 DPAPI 파일에 보관하지만 실행 중인 컨테이너 환경에는 존재합니다. Docker 관리 권한자는 해당 값과 데이터에 접근할 수 있습니다.
- 재실행은 저장된 배포 identity·입력·이미지 pin·리소스 라벨이 일치해야 합니다. 변경된 compose 파일이나 다른 배포의 데이터를 덮어쓰지 않습니다.
- Bot Control 0.6.2는 동봉 파일의 크기·SHA-256 검증 후 설치합니다. 설치 후 업로드를 닫고 중단된 설정 전환은 기록된 두 상태와 정확히 일치할 때만 복구합니다.
- Bot Control 관리 API는 활성 사람 시스템 관리자만 허용합니다. 봇은 자기 연결 등록만 가능합니다. 익명·일반 사용자·팀 관리자·삭제된 계정·관리자 역할 봇을 중앙 관리에서 거부합니다.
- 봇 발급은 기존 배포·리소스·관리자 ID를 검증한 뒤 수행합니다. 기존 사람/다른 봇을 인수하지 않고, 생성 마커·소유자·일반 역할을 확인합니다. 봇에게 시스템/팀/채널 관리자나 추가 역할을 주지 않습니다. 기본 공개 채널 등 Mattermost의 일반 멤버 접근 범위까지 제거하는 채널 격리 기능은 아닙니다.
- 봇 생성 기능은 요청 중에만 열고 `finally`에서 닫습니다. 강제 종료로 정리가 중단되면 다음 관리자 서버 설정/봇 발급 시 남은 기록을 닫습니다. 재실행 전까지 기능이 열려 있을 수 있으나 서버 권한 검사는 유지됩니다. 확인 대상은 이 마법사가 만든 기본 역할입니다. 임의의 커스텀 권한 체계를 전역 감사·강제 수정하지 않습니다.
- 토큰은 현재 Windows 사용자 DPAPI 파일에 원자적으로 저장하며 JSON 상태·CLI 인수·stdout/stderr·진행 로그에 포함하지 않습니다. 서버 발급 성공 후 저장 전에 중단되면 중복 토큰을 만들지 않고 관리자 확인을 요구합니다. 자동 폐기/재발급은 하지 않습니다.
- 토큰 복사는 사용자가 버튼을 눌러야 하며 원문을 화면에 표시하지 않습니다. 같은 클립보드 값은 60초 후 또는 종료 시 비우지만 OS/서드파티 클립보드 기록·동기화를 삭제하지는 못합니다. PC 사용자 권한을 가진 프로세스로부터 토큰을 격리하는 기능은 아닙니다.
- Dashboard 인증 활성화·로그인 성공·세션을 확인하며 등록된 암호를 다른 연결 대상에 재사용하지 않습니다. 원격 오류 본문은 암호가 반사될 수 있어 반환하지 않습니다.
- Hermes Dashboard 직접 접속은 별도 인증입니다. Mattermost 역할 기반 SSO나 PC 소유자의 로컬 권한 제한을 제공하지 않으며 NetBird ACL/방화벽은 변경하지 않습니다.
- 공유 실패 시 알려진 이전 Compose/공개 범위로 롤백합니다. 중단된 전환은 두 승인된 상태와 일치할 때만 복구하며 NetBird ACL·Windows 방화벽은 변경하지 않습니다. 이 PC의 ping 성공이 다른 PC 접근 성공을 뜻하지 않습니다.
- 사용자용 마법사는 프로필·작업 등록 전에 실제 봇 계정/역할·채널 멤버십과 Bot Control 접근 제한을 검사합니다. 인증 요청은 리디렉션을 따르지 않고 원격 오류 본문을 그대로 로그에 반영하지 않습니다.
- 배포 ZIP은 파일 허용 목록으로 만들며 개인 상태·인증·로그·백업·Git 이력을 포함하지 않습니다. SHA-256은 파일 무결성 확인용이지 코드 서명이나 게시자 인증이 아닙니다.
- 운영 Linux/GB10 배포, TLS 인증서, 자동 DB 백업·데이터 복원·삭제 UI는 이 단계의 제공 범위가 아닙니다. Windows Docker Desktop 버전은 테스트·개발 배포입니다.

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

- v0.1.2의 선택적 Browser/TUI npm 의존성 설치, Computer Use 사전 설치와 Hermes Desktop 자동 빌드
- DOS 8.3 짧은 경로 표기 지원(긴 절대 경로를 사용해야 함)
- 공식 설치기가 받는 모든 전이 의존성의 완전한 고정·재현 빌드
- launcher attestation 바깥의 전체 venv·Python/Node 패키지 진위
- 같은 사용자 권한으로 동시에 실행되는 악성 프로세스가 만드는 모든 로컬 TOCTOU 공격
- 같은 사용자 권한으로 RuntimeRoot와 InstallDir을 함께 수정해 launcher와 서명/MAC 없는 attestation을 다시 쓰는 지속적 로컬 위조
- Windows 자체, GitHub, 패키지 registry 또는 upstream Hermes의 compromise
- 코드 서명되지 않은 이 마법사 소스의 publisher identity
- regex/best-effort 정제가 모든 종류의 새 비밀 형식을 제거한다는 보장
- 사용자가 공식 설정 화면에 직접 입력한 공급자 자격증명의 저장·검증·관리
- 공식 setup 프로세스의 종료 코드 0 또는 창 닫힘만으로 공급자 구성이 완료되었다고 증명하는 것
- repository clone 중 user-global에만 정의된 기업 프록시, 사설 CA 또는 credential helper
- Program Files에 공식 Git for Windows가 없는 환경의 자동 Git 부트스트랩

이 프로젝트는 검토된 공식 설치기를 감싸는 안전 장치이지 독립적인 Hermes 배포판이 아닙니다.

## 사용자 데이터

### Dashboard 공통 초기값

연구실용 마법사는 빠른 연결을 위해 Dashboard 사용자 이름 `admin`과 비밀번호 `12345678`을 미리 채웁니다. 이는 공개되어 누구나 추측할 수 있는 초기값이며, 비밀이나 충분한 접근 보호 수단으로 간주하지 않습니다. 입력칸은 수정 가능하므로 연결 전에 고유한 비밀번호로 바꾸거나, NetBird 정책에서 신뢰하는 사용자와 Mattermost 서버만 Dashboard에 접근하도록 제한해야 합니다.

초기값 추가만으로 실행 중인 Dashboard의 비밀번호를 바꾸지는 않습니다. 사용자가 연구실 연결을 실행하면 현재 화면의 인증값을 Hermes와 Bot Control에 적용하므로, 기존 프로필을 재설정할 때에도 의도한 인증값인지 확인해야 합니다.

마법사는 `.env`, `config.yaml`, 인증 데이터, skills, sessions, memories, messages와 그 밖의 Hermes 사용자 콘텐츠를 직접 수집하거나 삭제하지 않습니다. 제거 기능이 없는 것도 같은 이유입니다.

v0.2.0의 4단계는 검증된 설치 뒤 Portal/Full을 선택한 사용자가 명시적으로 시작한 공식 Hermes setup을 별도의 보이는 콘솔에서 실행합니다. 사용자의 키보드 입력과 provider 자격증명, setup의 stdin/stdout/stderr는 그 공식 창에만 남고 install worker transport, 마법사 로그와 진단 ZIP에는 수집하지 않습니다. 마법사는 setup 프로세스의 시작과 종료만 추적하며, 그 상태를 검증된 CLI 설치 상태와 합치지 않습니다.

6단계 연구실 연결 입력은 별도 경계입니다. GUI는 Mattermost 봇 토큰과 Dashboard 비밀번호를 Windows DPAPI CurrentUser로 암호화한 임시 파일로 worker에 전달하고 명령행·이벤트·로그에는 넣지 않습니다. worker는 토큰을 Mattermost Bearer 인증에만 사용하고 작업 뒤 암호화 임시 파일을 삭제합니다.

## Mattermost Desktop (0.4.0)

4단계는 별도 동의 후 `MattermostSetup -Apply` worker로 실행합니다. 버전·공식 GitHub URL·SHA-256을 고정하고 Authenticode의 유효 상태 및 Mattermost 배포자를 확인한 MSI만 UAC로 실행합니다. GUI와 config 병합은 원래 사용자 권한이며, MSI 실행 동안 파일 교체를 막는 읽기 잠금을 유지합니다. 기존 Desktop은 자동 업그레이드·제거하지 않습니다.

사람 계정의 비밀번호·쿠키·세션 저장소에는 접근하지 않습니다. config v1~v4의 서버 목록만 보존 병합하며 변경 전 사본을 남깁니다. 손상/미지원 형식·실행 중 앱·링크 경로는 거부합니다. 서버 등록, 서버 ping, 사람 로그인은 별개이며 계정 로그인 성공을 주장하지 않습니다. 이 기능은 서버 설치·계정 생성·권한 승격·봇 발급을 하지 않습니다. Store 설치와 알 수 없는 실행 경로는 보존한 채 중단합니다.

운영을 위해 Dashboard 비밀번호는 Hermes의 `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` 값과 Bot Control 플러그인 KV에 저장됩니다. 이는 NetBird 내부에서 Bot Control이 Dashboard에 다시 로그인하기 위한 의도된 저장이며, 봇 토큰은 Bot Control에 저장하지 않습니다. 따라서 Hermes home과 Mattermost 데이터베이스·플러그인 KV에 접근할 수 있는 관리자는 Dashboard 자격증명에도 접근할 수 있다는 위협 모델을 적용해야 합니다.

기존 `Completed` 기록에서 설정만 계속하는 버튼은 진단 Ready, exact official origin·managed command 경로, 현재 pin, 상태 경로와 성공 verification이 모두 일치할 때만 표시됩니다. 버튼과 상태 파일은 실행 허가가 아니며, 공식 setup child는 현재 설치의 전체 provenance와 CLI 실행 검증을 다시 통과한 뒤에만 시작됩니다.

진단 번들은 마법사 자체의 사전 점검 요약, 고정 소스 요약, 정제된 상태와 최근 정제 로그만 허용 목록 방식으로 포함합니다. 알려진 사용자 프로필, Hermes, 설치 및 runtime 경로를 placeholder로 바꾸지만 OS 버전과 일반 환경 정보는 남을 수 있습니다.

## 소스 고정 및 대응

릴리스 태그만 바꾸는 변경은 허용하지 않습니다. annotated tag object, peeled commit, commit tree의 Git blob, 정확한 바이트 크기, SHA-256, protocol과 전체 manifest를 함께 검토해야 합니다.

보안 문제가 확인되면 다음 순서로 대응합니다.

1. 영향받은 wizard와 Hermes pin 범위를 판정합니다.
2. 필요하면 release 다운로드와 pin을 철회합니다.
3. 수정 pin/코드와 새 체크섬을 배포합니다.
4. 공개 advisory에 영향, 완화책과 업데이트 버전을 기록합니다.

세부 갱신 절차는 `docs/updating-the-pin.md`에 있습니다.
