# Hermes Easy Setup

Windows에서 [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent)를 설치하는 한국어 안전 마법사입니다.

이 프로젝트는 Nous Research의 공식 제품이 아닌 비공식 커뮤니티 도구입니다. Hermes 자체의 사용법과 지원 범위는 [공식 문서](https://hermes-agent.nousresearch.com/docs/)를 기준으로 합니다.

## 현재 상태

- 버전 `0.1.1` Windows 네이티브 MVP
- Windows 10/11 x64에서 로컬 및 CI 검증
- ARM64는 Hermes upstream Tier 1 대상이지만 이 마법사는 아직 실기기 미검증
- Windows PowerShell 5.1과 PowerShell 7 단위 테스트
- 검토된 Hermes 릴리스 `v2026.8.19` 고정
- 실제 설치 전 변경 계획, 계획 지문, 명시적 승인
- 단계별 체크포인트와 안전 재적용 방식의 이어하기
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

- 기본 `%LOCALAPPDATA%\hermes`에 코드, venv, managed Git/Node/uv, 설정 템플릿과 Hermes 데이터 폴더 생성 또는 업데이트
- `%LOCALAPPDATA%\hermes\hermes-agent\bin`을 사용자 PATH에 추가하고 `HERMES_HOME` 사용자 환경 변수 설정 또는 갱신
- Python, Node, 브라우저/Computer Use, 시스템 도구 등 상류 의존성 다운로드
- 기존 공식 Hermes checkout 업데이트 및 상류 설치기의 안전 절차에 따른 local change stash/restore
- Desktop 옵션 선택 시 Electron Desktop 빌드와 바로가기 생성

마법사의 캐시, 체크포인트와 로그는 별도 `%LOCALAPPDATA%\HermesEasySetup`에 저장됩니다. 백업·제거·강제 downgrade는 하지 않습니다. 실패 후 `-Resume`은 낡은 성공 기록을 그대로 믿지 않고 모든 자동 단계를 다시 적용합니다.

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
10. 대상 내부 launcher/venv, 공식 origin, 깨끗한 checkout, 정확한 HEAD, bootstrap marker를 모두 확인합니다.

각 단계에는 종류에 따라 30분, 90분, Desktop 180분의 상한이 있으며 timeout 시 해당 프로세스 트리를 종료합니다.

## 보존 원칙

마법사는 Hermes 사용자 데이터인 `.env`, `config.yaml`, 인증 정보, skills, sessions, memories, messages를 직접 읽거나 삭제하지 않습니다. 진단 ZIP도 Hermes 홈을 순회하지 않습니다.

진단 정제는 best-effort입니다. 알려진 토큰과 사용자 경로를 치환하지만 모든 민감정보를 수학적으로 보장할 수는 없습니다. ZIP은 자동 업로드되지 않으며, 공유 전 사용자가 직접 열어 보고 사용 후 삭제해야 합니다.

## 공급망 경계

직접 보장하는 범위는 다음과 같습니다.

- 공식 repository와 annotated tag 객체, peeled commit 연결
- 해당 commit tree의 `scripts/install.ps1` Git blob, 크기, SHA-256
- signed Microsoft System32 Windows PowerShell만 설치기 host로 사용
- stage protocol 및 manifest의 fail-closed 검증
- 승인되지 않은 호스트, 캐시 변조와 예상 밖 단계 거부

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

상류 tag→commit→blob과 base/Desktop manifest만 다시 확인하려면 다음을 실행합니다. Hermes 설치 단계는 0개 실행됩니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-UpstreamContractSmoke.ps1
```

실제 Hermes 설치 E2E는 비용과 시간이 커서 `Windows install E2E` 수동 workflow에서만, 자격증명과 setup 없이 일회성 GitHub runner에 실행합니다. 현재 CI의 ARM64 실기기 검증은 아직 없습니다.

구조는 [docs/architecture.md](docs/architecture.md), pin 갱신은 [docs/updating-the-pin.md](docs/updating-the-pin.md), 기여 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)에 있습니다. 버전은 자동으로 최신 upstream을 따라가지 않으며 검토된 pin 변경과 새 release를 통해서만 갱신됩니다.

## 라이선스

마법사 코드는 [MIT License](LICENSE)로 배포됩니다. Hermes Agent는 별도 프로젝트이며 해당 저장소의 라이선스와 정책을 따릅니다.
