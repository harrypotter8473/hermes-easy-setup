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

## 신뢰하지 않고 검증하는 것

- 네트워크 응답과 리디렉션
- 기존 설치기 캐시와 상태 파일
- 기존 설치 디렉터리, Git origin, checkout과 reparse point
- 공식 설치기의 protocol/manifest 및 stage JSON 출력
- PATH의 `hermes`나 `powershell.exe`
- 사용자가 지정한 mutable 경로

검증 실패 시 설치는 계속 진행하지 않습니다. 사용자 승인 계획 지문은 첫 변경 직전에 다시 확인하고, 설치기는 protocol/manifest와 매 stage 실행 직전에 재해시합니다.

## 보장 범위 밖

- 공식 설치기가 받는 모든 전이 의존성의 완전한 고정·재현 빌드
- 같은 사용자 권한으로 동시에 실행되는 악성 프로세스가 만드는 모든 로컬 TOCTOU 공격
- Windows 자체, GitHub, 패키지 registry 또는 upstream Hermes의 compromise
- 코드 서명되지 않은 이 마법사 소스의 publisher identity
- regex/best-effort 정제가 모든 종류의 새 비밀 형식을 제거한다는 보장
- 사용자가 공식 설정 화면에 직접 입력한 공급자 자격증명의 관리

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
