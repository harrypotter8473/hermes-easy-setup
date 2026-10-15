Set-StrictMode -Version 2.0

# These are visible, editable installation proposals, not hidden unlimited grants.
function New-HermesResearchWizardOptions {
    param([string]$WorkspacePath, [string]$HumanUsername = 'researcher')
    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
        $WorkspacePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Hermes Research Workspace'
    }
    $roles = [ordered]@{}
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        $roles[$role] = [ordered]@{
            ReadWorkspace = $true
            Limits = [ordered]@{
                attempts = 40; revisions = 2; audits = $(if ($role -ceq 'auditor') { 20 } else { 4 }); seconds = 1800; tokens = 600000
                max_output_tokens = 4000; per_call_timeout_seconds = 120
            }
        }
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1; WorkspacePath = $WorkspacePath; HumanUsername = $HumanUsername
        AllowModelEgress = $false; AllowPublicWeb = $false; MigrationConsent = $false
        Roles = $roles
    }
}

function Assert-HermesResearchWizardOptions {
    param([Parameter(Mandatory = $true)]$Options, [Parameter(Mandatory = $true)][string]$RuntimeRoot)
    # Normalize dictionaries and PSCustomObject consistently for PS 5.1 callers.
    $value = ($Options | ConvertTo-Json -Depth 12) | ConvertFrom-Json
    Assert-HermesResearchPolicyFields $value @('SchemaVersion','WorkspacePath','HumanUsername','AllowModelEgress','AllowPublicWeb','MigrationConsent','Roles') '설치 선택'
    if ($value.SchemaVersion -ne 1) { throw 'ResearchWizardOptionsSchemaRejected' }
    if ($value.HumanUsername -isnot [string] -or $value.HumanUsername -cnotmatch '^[a-z0-9][a-z0-9._-]{1,63}$') { throw '연구를 요청할 실제 Mattermost 사용자 이름을 입력하세요. 표시 이름이나 봇 이름은 사용할 수 없습니다.' }
    if ($value.WorkspacePath -isnot [string] -or $value.WorkspacePath -cnotmatch '^[A-Za-z]:[\\/]' -or $value.WorkspacePath -match '[\x00-\x1f]') { throw '작업 폴더는 이 PC의 절대 경로로 선택하세요.' }
    $workspace = [IO.Path]::GetFullPath($value.WorkspacePath).TrimEnd('\','/')
    $runtime = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')
    if ($workspace.Length -le 3 -or $workspace -ieq $runtime -or $workspace.StartsWith($runtime + '\',[StringComparison]::OrdinalIgnoreCase) -or $runtime.StartsWith($workspace + '\',[StringComparison]::OrdinalIgnoreCase)) { throw '작업 폴더는 드라이브 전체나 Hermes 설치·운영 폴더가 아닌 별도 연구 폴더로 선택하세요.' }
    foreach ($path in @($workspace,(Join-Path $workspace 'inputs'))) {
        if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe) { throw 'ResearchWorkspacePathRejected' }
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Container)) { throw '작업 폴더와 inputs는 폴더여야 합니다.' }
    }
    $value.WorkspacePath = $workspace
    foreach ($flag in @('AllowModelEgress','AllowPublicWeb','MigrationConsent')) {
        if ($value.$flag -isnot [bool]) { throw 'ResearchWizardConsentTypeRejected' }
    }
    if (-not $value.AllowModelEgress) { throw '외부 모델에 요청·허용 자료를 전송하는 선택을 확인하세요.' }
    if (-not $value.AllowPublicWeb) { throw '자동 조사에 필요한 공개 웹 검색·원문 읽기 선택을 확인하세요.' }
    Assert-HermesResearchPolicyFields $value.Roles @('manager','researcher','analyst','auditor') '역할별 설치 선택'
    $ranges = @{
        attempts = @(8,200); revisions = @(1,10); audits = @(2,20); seconds = @(120,14400)
        tokens = @(100000,10000000); max_output_tokens = @(512,16000); per_call_timeout_seconds = @(15,600)
    }
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        $selected = $value.Roles.$role
        Assert-HermesResearchPolicyFields $selected @('ReadWorkspace','Limits') '역할 선택'
        if ($selected.ReadWorkspace -isnot [bool]) { throw 'ResearchWorkspacePermissionRejected' }
        Assert-HermesResearchPolicyFields $selected.Limits @('attempts','revisions','audits','seconds','tokens','max_output_tokens','per_call_timeout_seconds') '역할 실행 한도'
        foreach ($key in $ranges.Keys) {
            $amount = $selected.Limits.$key
            if (($amount -isnot [int] -and $amount -isnot [long]) -or $amount -lt $ranges[$key][0] -or $amount -gt $ranges[$key][1]) { throw ("{0}: {1} 한도는 {2}~{3} 사이의 정수로 입력하세요." -f $role,$key,$ranges[$key][0],$ranges[$key][1]) }
        }
        if ($role -ceq 'auditor' -and $selected.Limits.audits -lt 6) { throw '자동 분업의 기본 검수에는 감사 기록이 최소 6회 필요합니다. 수정·재검수를 위해 권장값 20회를 제안합니다.' }
        if ($selected.Limits.per_call_timeout_seconds -gt $selected.Limits.seconds) { throw '한 번의 응답 대기 시간은 역할의 전체 실행 시간을 넘을 수 없습니다.' }
    }
    return $value
}

function New-HermesResearchWizardPolicy {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)]$Options,
        [Parameter(Mandatory = $true)][string]$ModelName, [Parameter(Mandatory = $true)][string[]]$AllowedUserIDs, $Agents, $Roles)
    $selected = Assert-HermesResearchWizardOptions -Options $Options -RuntimeRoot $RuntimeRoot
    if ([string]::IsNullOrWhiteSpace($ModelName)) { throw '설치 중 인증된 모델을 선택하세요.' }
    if ($AllowedUserIDs.Count -eq 0 -or @($AllowedUserIDs | Where-Object { $_ -cnotmatch '^[a-z0-9]{26}$' }).Count -gt 0 -or @($AllowedUserIDs | Select-Object -Unique).Count -ne $AllowedUserIDs.Count) { throw 'ResearchHumanIdentityNotVerified' }
    $policy = New-HermesResearchPolicy -RuntimeRoot $RuntimeRoot -ModelName $ModelName -Agents $Agents -Roles $Roles
    $policy.human.allowed_user_ids = @($AllowedUserIDs)
    $toolMap = @{
        manager = @('read_text','write_artifact','dispatch','complete')
        researcher = @('read_text','search_web','read_web','write_artifact','complete')
        analyst = @('read_text','write_artifact','complete')
        auditor = @('read_text','audit','complete')
    }
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        $binding = $policy.roles[$role]
        $binding.allow_model_egress = $selected.AllowModelEgress
        $binding.tools = @($toolMap[$role])
        $binding.read_roots = @($(if ($selected.Roles.$role.ReadWorkspace) { Join-Path $selected.WorkspacePath 'inputs' }))
        $binding.write_roots = @((Join-Path $RuntimeRoot ('research\policy.artifacts\' + $role)))
        $binding.call_targets = @($(if ($role -ceq 'manager') { 'researcher'; 'analyst'; 'auditor' }))
        $binding.external_domains = @($(if ($role -ceq 'researcher') { '*' }))
        $binding.limits = $selected.Roles.$role.Limits
    }
    $policy | Add-Member NoteProperty web ([ordered]@{
        provider = 'duckduckgo_html'; allow_public_web = $selected.AllowPublicWeb
        timeout_seconds = 20; max_response_bytes = 2000000; max_text_chars = 50000; max_results = 5; max_redirects = 3
    })
    return $policy
}
