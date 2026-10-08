# 관리자용 마법사 — 0.8.0 테스트 배포

`Start-HermesAdminSetup.cmd`는 **새 Mattermost 서버와 최초 시스템 관리자**를 만드는 별도 마법사입니다. 기존 사용자용 `Start-HermesEasySetup.cmd`는 그대로 유지합니다.

현재 구현 범위는 Windows x64 PC의 Docker Desktop / Linux AMD64 테스트 서버, Bot Control 0.6.2 설치, 봇·토큰 발급, 선택적 NetBird 공유입니다. GB10 운영 배포와 인터넷 공개는 하지 않습니다. 관리자 패키지는 서버용이며 Hermes 설치는 사용자용 패키지에서 진행합니다.

## 준비

1. Windows 10/11 x64에 [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/)을 설치하고 실행합니다. 이번 마법사는 Docker Desktop 자체를 설치하거나 Windows 기능을 변경하지 않습니다.
2. Docker Desktop을 Linux 컨테이너 모드로 실행합니다.
3. 압축을 푼 마법사 폴더에서 `Start-HermesAdminSetup.cmd`를 실행합니다. 일반 사용자로 시작하세요. 이미 Docker 사용 권한이 있다면 마법사 자체에 관리자 승인은 필요하지 않습니다.
4. **Docker 준비 확인**을 누릅니다. 확인과 설치는 숨김 작업으로 실행되어 진행 중에도 화면이 반응합니다.

Mattermost 공식 문서상 Windows/macOS의 Docker 배포는 테스트·개발용입니다. 운영 서버 배포와 Windows 로그인 전 무인 기동까지 완료된 것으로 취급하지 마세요. [공식 컨테이너 배포 안내](https://docs.mattermost.com/deployment-guide/server/deploy-containers)

## 입력과 설치

1. 서버 ID, 표시 이름, 팀 주소 이름·표시 이름, 기본 채널을 입력합니다. ID·주소 이름은 영문 소문자로 시작하는 소문자·숫자·하이픈 3~32자입니다.
2. 기본 포트는 **18065**입니다. 기본은 `127.0.0.1`에만 바인딩하며 기존 Mattermost의 **8065는 허용하지 않습니다**. 다른 PC에서 접속해야 한다면 아래 공개 범위에서 **NetBird로 공유**를 선택하고 서버 PC의 현재 NetBird IPv4를 확인합니다. 포트가 사용 중이면 기존 서버를 끄지 말고 다른 서버 ID와 포트를 선택하세요.
3. 최초 관리자 사용자 이름, 이메일, 비밀번호를 직접 입력합니다. 비밀번호는 12~128자, 대문자·소문자·숫자·특수문자를 포함해야 합니다. 관리자 암호 기본값은 없습니다. 다른 Mattermost 서버의 계정과 공유되는 계정이 아닙니다.
4. **Bot Control 0.6.2 설치**는 기본 선택되어 있습니다. 서버만 만들려면 해제할 수 있습니다. 생성·설치 동의에 체크하고 **서버·관리자 생성**을 누릅니다.
5. 공식 이미지 다운로드 → DB/서버 기동 → 관리자 로그인/권한 확인 → 팀·채널 생성 → 선택한 Bot Control 설치 순서로 진행합니다. 첫 다운로드에는 수 분 걸릴 수 있습니다. 플러그인 설정 적용을 위해 테스트 Mattermost가 몇 차례 재시작됩니다.
6. 완료 후 **서버 열기**로 결과의 서버 URL에 접속해 방금 입력한 계정으로 직접 로그인합니다. 공유하지 않은 기본 주소는 `http://127.0.0.1:18065`이며, 공유했다면 선택한 NetBird 주소가 사용됩니다. **관리 콘솔**과 **Bot Control** 버튼은 서버 PC의 localhost 주소로 관리 화면을 엽니다.

관리자 계정은 Mattermost의 최초 사용자 생성 절차를 사용합니다. 로그인 후 실제 `system_admin` 역할까지 확인하며, 기존 일반 사용자에게 강제로 관리자 권한을 부여하지 않습니다. Bot Control 조회·적용 API도 요청마다 활성 상태의 사람 시스템 관리자인지 검사합니다. 일반 사용자·팀 관리자·봇은 중앙 관리 권한을 받지 않습니다. 버튼만 숨기는 방식이 아닙니다.

공개 가입은 닫혀 있고 팀은 초대 기반입니다. 플러그인 업로드는 동봉 패키지 설치 중에만 허용하고 성공·실패 후 다시 닫습니다. SMTP는 설정하지 않으므로 이메일 알림 미설정 안내가 나타날 수 있습니다. 이메일 비밀번호 복구도 메일 설정 전에는 의존하지 마세요.

## 2단계에서 만든 서버에 추가 적용

1. 기존 서버와 동일한 서버 ID·포트·관리자 계정 등 입력값을 넣고 기존 비밀번호를 입력합니다.
2. **같은 서버를 이어서 설정**과 **Bot Control 설치**를 체크합니다.
3. 실행하면 기존 DB·계정·팀·채널을 유지하면서 플러그인을 추가합니다.

동봉된 `assets/bot-control/com.infonet.bot-control-0.6.2.tar.gz`를 `config/bot-control.json`의 SHA-256·크기로 검증합니다. 인터넷의 임의 최신 플러그인을 다운로드하지 않습니다. 기존 플러그인이 다른 버전이거나 이 마법사에서 설치한 기록이 없으면 자동으로 덮어쓰지 않습니다. 이 패키지는 자체 제작한 미서명 플러그인이므로 해당 테스트 서버의 서명 필수 옵션은 꺼집니다. 해시 검증이 Mattermost 공식 서명을 뜻하지는 않습니다.

설치 완료 후 일반 업로드를 잠그므로 Upload Plugin이 비활성화되어 보이는 것은 정상입니다. 설치된 플러그인의 활성화·비활성화 등은 Mattermost의 관리 권한 검사를 받습니다. 별도 플러그인 추가·업데이트 UI는 아직 없습니다.

## 봇 생성·토큰 발급 (4단계)

1. 서버·관리자 설정 완료 후 화면 아래 **3. 봇 생성·토큰 발급**으로 이동합니다. 마법사를 다시 열었다면 위쪽에 기존 서버와 동일한 정보를 입력하고 **Docker 준비 확인**을 누릅니다. 정보는 `deployment.json`의 `Identity`에서 확인할 수 있습니다.
2. 봇 사용자 이름(예: `harry_bot`), 표시 이름(예: `Harry`), 선택적 설명을 입력합니다. 표시 이름·설명은 Mattermost 봇 프로필용입니다. Hermes의 SOUL/역할·메모리는 이 버튼으로 설정하지 않습니다.
3. 봇 영역의 관리자 비밀번호 칸에 위 관리자 계정의 비밀번호를 다시 입력합니다. 봇 생성 동의에 체크한 뒤 **봇 생성 / 기존 발급 결과 확인**을 누릅니다.
4. 서버가 확인한 사람 `system_admin`으로만 생성합니다. 봇은 `system_user`이며 위에서 만든 팀·기본 채널에 일반 멤버로 추가됩니다. 봇 소유자는 인증한 관리자입니다. 봇 이름이 이미 다른 계정에 사용 중이면 중단합니다.
5. 완료 후 **토큰 복사**, **Home Channel ID 복사**를 눌러 사용자용 마법사의 Mattermost 입력에 붙여 넣습니다. 토큰 원문은 화면·로그에 출력하지 않습니다. 토큰 복사 후 60초 이내에 붙여 넣으세요. 클립보드 기록/동기화를 켜 두었다면 비밀이 기록될 수 있습니다.
6. 다른 봇은 사용자 이름·표시 이름을 바꾸고 다시 실행합니다. 같은 봇 결과를 다시 복사하려면 원래 이름·설명과 관리자 암호로 재실행하세요. 기존 봇·토큰을 재사용합니다. 설명·이름 수정 UI나 토큰 교체 버튼은 아직 없습니다.

**기본 `127.0.0.1` 주소는 다른 PC에서 사용할 수 없습니다.** NetBird 공유 후 완료 화면에 표시된 `http://<서버-NetBird-IP>:<포트>`를 전달하세요. 사용자 PC의 Dashboard는 그 사용자 PC의 다른 NetBird 주소를 사용합니다. [두 PC 체크리스트](two-pc-checklist.ko.md)를 따르고 토큰은 공개 채팅·GitHub·진단 자료에 붙여 넣지 마세요.

## NetBird 공유 변경과 해제

새 서버는 기본적으로 이 PC에서만 접근할 수 있습니다. 기존 서버의 DB·팀·봇을 유지하면서 공유하려면 기존 정보를 입력하고 **같은 서버를 이어서 설정**을 선택한 뒤 공개 범위를 바꿉니다.

- **현재 범위 유지:** 새 서버는 loopback, 기존 서버는 현재 공개 범위 그대로 유지합니다.
- **NetBird로 공유:** 현재 NetBird 클라이언트·인터페이스 주소를 검증하고 `127.0.0.1`과 해당 NetBird IP에만 바인딩합니다. SiteURL도 공유 주소로 바뀝니다. 주소 전환 시 테스트 서버가 잠시 재시작됩니다.
- **공유 해제:** NetBird 바인딩을 제거하고 SiteURL을 loopback으로 복구합니다. 계정·토큰·메시지·volume을 삭제하지 않습니다. 다른 PC는 연결이 끊기므로 작업 중이 아닌 때 실행하세요.

마법사는 Windows 방화벽이나 NetBird 정책을 임의로 열지 않습니다. 공유 성공 메시지는 **서버 PC 자체에서 공유 주소 응답·바인딩·SiteURL을 확인했다**는 의미입니다. 다른 PC 접속 및 서버에서 사용자 Dashboard로 돌아오는 연결은 별도로 확인해야 합니다. 연결 문제를 해결하려고 방화벽 전체를 끄거나 `0.0.0.0`으로 바꾸지 마세요. [Docker 포트 공개](https://docs.docker.com/engine/network/port-publishing/), [NetBird 연결 진단](https://docs.netbird.io/help/troubleshooting-resource-connectivity)

실패 시 이전 공개 범위로 되돌리고 데이터를 보존합니다. 프로세스 강제 종료로 복구가 끝나지 않았다면 NetBird·Docker를 켠 뒤 같은 정보로 이어서 설정하세요. NetBird IP 변경 시 기존 공유 주소가 작동하지 않을 수 있으므로 먼저 관리자 PC에서 복구해야 합니다.

봇 생성 허용 설정은 생성 시에만 켰다가 닫습니다. 강제 종료로 정리가 중단되면 다음 서버 설정/봇 발급에서 복구합니다. 일반 사용자에게 봇 생성 권한을 부여하지 않으며 사람 계정용 Personal Access Token 기능도 켜지 않습니다. 봇 토큰은 Mattermost의 공식 봇/사용자 토큰 API로 발급합니다. [고정 버전 API 구현](https://github.com/mattermost/mattermost/blob/v11.11.0/server/channels/api4/user.go)

토큰 발급 성공 직후 PC 저장에 실패하면 서버에는 토큰이 있지만 로컬에 원문이 없을 수 있습니다. 이 경우 재시도는 새 토큰을 만들지 않고 중단합니다. 관리자 콘솔의 해당 봇에서 `HermesEasySetup/<작업 ID>` 토큰을 확인하세요. 자동 폐기·교체나 로컬 기록 수동 초기화를 권하지 않습니다. 필요한 경우 관리자가 해당 토큰만 명시적으로 폐기하고 새 이름의 봇으로 진행할 수 있습니다(기존 봇은 자동 삭제되지 않습니다).

## Mattermost 관리자 권한과 Hermes 인증의 차이

- **Bot Control 화면·관리 API:** 활성 사람 `system_admin`만 허용. 익명 요청 401, 일반 사용자 403. 화면도 권한 확인 전에는 편집 폼을 표시하지 않습니다.
- **사용자 마법사의 에이전트 등록:** 실제 활성 봇 토큰으로 자기 봇의 연결만 등록합니다. 다른 봇 ID를 지정하거나 중앙 관리 API를 호출할 수 없습니다. Dashboard 비밀번호는 등록 목록 응답에 반환하지 않습니다.
- **Hermes 연결:** 인증 활성화 여부, 로그인 성공 응답, 인증 세션을 모두 확인합니다. 인증이 꺼졌으면 등록·적용하지 않습니다. 저장된 암호를 재사용할 때 주소·계정·프로필을 다른 값으로 바꿀 수 없습니다. 연결 변경은 해당 봇 설치 마법사에서 다시 등록하세요.
- **각 PC의 Hermes Dashboard 직접 접속:** Mattermost 역할과 연동한 SSO가 아닙니다. 그 Dashboard의 자격 증명을 가진 사람은 직접 접근할 수 있습니다. 사용 중인 초기 인증값은 직접 확인하고 개인 비밀번호로 변경하세요. 구체적인 인증값은 공개 안내서에 기재하지 않습니다. 직접 접속까지 관리자 장치로 제한하려면 별도의 NetBird ACL/방화벽·인증 구성이 필요하며 이번 작업은 기존 네트워크 정책이나 개인 Dashboard를 변경하지 않습니다.

이 단계는 중앙 관리 권한을 구현합니다. 설치된 PC 소유자의 로컬 파일 접근 권한이나 Mattermost 기본 봇 소유자 권한을 강제로 제거하는 기능은 아닙니다.

## 저장 위치와 유지

- 설치 기록: `%LOCALAPPDATA%\HermesEasySetup\servers\<서버 ID>`
- `deployment.json`: 서버 정보, 이미지 pin, 생성한 계정·팀·채널 ID, 진행 상태. 관리자 비밀번호는 저장하지 않습니다.
- 플러그인 모드(`disabled`/`upload`/`enabled`), 패키지 해시·버전, 중단된 설정 전환 기록도 같은 파일에 저장합니다. 다음 재실행에서 남은 업로드 모드는 우선 닫습니다.
- `compose.json`: loopback 포트, 서비스, 전용 저장소 정의. DB 비밀번호는 변수 참조만 저장합니다.
- `compose.env`: 외부 환경 설정 유입을 막기 위한 빈 파일입니다.
- `database.bin`: 무작위 DB 비밀번호를 Windows 현재 사용자 DPAPI로 암호화한 파일입니다. 다른 PC나 다른 Windows 사용자로 단순 복사해서 사용할 수 없습니다.
- `bots\<봇 이름>.json`: 봇·토큰 ID, 생성 작업 ID, 소유자, 팀·채널, 재시도 기록. 토큰 원문은 없습니다.
- `bots\<봇 이름>.bin`: 봇 토큰 DPAPI 암호화 파일. 현재 Windows 계정에서만 복호화하며 발급 결과 복사에 사용합니다. 일반 텍스트로 내보내지 않습니다. 관리자 암호는 여기에 저장하지 않습니다.
- 실제 DB·파일: Docker Desktop의 **named volume**에 저장됩니다. 배포 폴더만 백업해서는 데이터 백업이 되지 않습니다. Docker Desktop 초기화나 volume 삭제 시 데이터가 사라집니다.

컨테이너·네트워크·volume에는 `hes-<서버 ID>-<고유값>` 이름과 배포 소유권 라벨을 붙입니다. 기존 로컬/원격 Mattermost를 검색해서 수정하지 않습니다. Docker context나 `DOCKER_HOST`가 원격을 가리켜도 이 마법사는 고정된 로컬 Docker Desktop 파이프에만 연결합니다.

컨테이너 재시작 정책은 `unless-stopped`입니다. Docker Desktop 엔진이 시작되면 다시 기동합니다. 사용자가 직접 중지한 컨테이너는 자동 재기동되지 않을 수 있습니다. Docker Desktop의 Windows 로그인 시 시작 옵션과 **로그인 전 서버 무인 실행**은 서로 다릅니다.

관리자 암호는 GUI → 작업 프로세스 전달 시 일시적으로 DPAPI 암호화하며 작업 종료 시 전달 파일을 제거합니다. DB 암호는 Docker 실행 시 자식 프로세스 환경에 전달되므로 Docker 관리 권한을 가진 사용자는 컨테이너 환경을 볼 수 있습니다. Docker 접근 권한 자체가 강한 관리 권한입니다.

## 실패·재시도

실패해도 데이터를 자동 삭제하거나 기존 암호를 초기화하지 않습니다.

1. 오류를 확인하고 Docker Desktop·디스크·인터넷 상태를 복구합니다.
2. 같은 서버 ID·포트·계정 등 **처음과 동일한 입력**을 유지합니다. 비밀번호는 다시 입력합니다.
3. **같은 서버를 이어서 설정**에 체크하고 실행합니다.

정상 완료한 서버도 동일 입력으로 재검증할 수 있습니다. 계정·팀·채널은 재사용합니다. 변경된 compose 파일, 다른 배포의 컨테이너/volume, 이미지 pin 변경, 비어 있지 않은 다른 설치 폴더는 자동 덮어쓰기하지 않습니다.

입력을 잊었으면 `deployment.json`의 `Identity`에서 비밀번호를 제외한 정보를 확인할 수 있습니다. 관리자 비밀번호를 잊은 경우 마법사는 자동 복구하지 않습니다. 전체 서버 삭제 기능도 이번 단계에는 제공하지 않습니다.

## 개발 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AdminTests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AdminBotTests.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\HermesAdminSetup.Gui.ps1 -SmokeTest
```

실제 Docker 검증은 별도 명시적 승인 옵션이 필요합니다. 기본 18066 포트에 무작위 이름의 임시 서버를 만들고 관리자 권한·공개 가입 차단·메시지 영속성·재실행을 확인한 뒤 **그 테스트의 컨테이너·네트워크·volume만 삭제**합니다. 이미지 캐시는 남깁니다. 실제 사용자 데이터를 넣지 마세요.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AdminDockerE2E.ps1 -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AdminDockerE2E.ps1 -Apply -WithBotControl
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AdminDockerE2E.ps1 -Apply -WithBotControl -WithBots
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AdminDockerE2E.ps1 -Apply -WithBotControl -WithBots -WithNetwork
```

고정 이미지 정보는 `config/mattermost-server.json`에 있습니다. 현재 Mattermost 11.11.0, PostgreSQL 16.14 Alpine 3.24의 공식 Linux/AMD64 digest를 사용합니다. 재시도 과정에서 자동 버전 변경은 하지 않습니다.
