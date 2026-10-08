Set-StrictMode -Version 2.0

$script:ResearchRoleIds = @('planner', 'researcher', 'executor', 'reviewer')
$script:ResearchProfiles = @('research-lead', 'research-scout', 'research-worker', 'research-reviewer')

function Assert-HermesResearchFields {
    param($Value, [string[]]$Required, [string[]]$Optional = @(), [string]$Label)
    if ($Value -is [System.Collections.IDictionary]) {
        $names = @($Value.Keys)
    } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Value.PSObject.Properties.Name)
    } else { throw "$Label 형식이 올바르지 않습니다." }
    foreach ($name in $names) {
        if ($name -isnot [string] -or ($Required + $Optional) -cnotcontains $name) {
            throw "$Label 허용 필드 외 값은 저장하거나 처리할 수 없습니다."
        }
    }
    foreach ($name in $Required) {
        if ($names -cnotcontains $name) { throw "$Label 필수 필드가 없습니다." }
    }
}

function Assert-HermesResearchText {
    param($Value, [int]$MaximumLength, [string]$Label, [switch]$Multiline)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength) {
        throw "$Label 문자열이 비어 있거나 허용 길이를 벗어났습니다."
    }
    $controls = $(if ($Multiline) { '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' } else { '[\x00-\x1F\x7F]' })
    if ($Value -match $controls) { throw "$Label 허용되지 않은 제어 문자가 있습니다." }
}

function Get-HermesResearchDefaultRoles {
    return @(
        [pscustomobject][ordered]@{ Id = 'planner'; Name = '총괄'; Instructions = '연구 목표와 작업 순서를 정리하고 조사·실행·검토 결과를 종합한다. 확인된 근거와 제안을 구분한다.' }
        [pscustomobject][ordered]@{ Id = 'researcher'; Name = '조사'; Instructions = '관련 자료와 출처를 조사하고 확인한 내용과 불확실한 내용을 구분하여 보고한다.' }
        [pscustomobject][ordered]@{ Id = 'executor'; Name = '실행'; Instructions = '합의된 연구 계획에 따라 작업을 수행하고 방법·결과·한계를 기록한다. 추가 권한이 필요한 작업은 요청한다.' }
        [pscustomobject][ordered]@{ Id = 'reviewer'; Name = '검토'; Instructions = '연구 결과의 근거와 재현 가능성을 독립적으로 검토하고 오류·누락·한계를 보고한다.' }
    )
}

function ConvertTo-HermesResearchRoles {
    param($Roles)
    if ($Roles -isnot [System.Array] -or $Roles.Count -ne 4) { throw '역할은 정확히 네 개여야 합니다.' }
    $result = New-Object System.Collections.Generic.List[object]
    $seen = @()
    foreach ($role in $Roles) {
        Assert-HermesResearchFields $role @('Id', 'Name', 'Instructions') -Label '역할'
        if ($role.Id -isnot [string] -or $script:ResearchRoleIds -cnotcontains $role.Id -or $seen -ccontains $role.Id) {
            throw '네 가지 고정 역할 ID를 중복 없이 사용하세요.'
        }
        Assert-HermesResearchText $role.Name 100 '역할 표시명'
        Assert-HermesResearchText $role.Instructions 8000 '역할 지침' -Multiline
        $seen += $role.Id
        $result.Add([pscustomobject][ordered]@{ Id = $role.Id; Name = $role.Name.Trim(); Instructions = $role.Instructions })
    }
    foreach ($id in $script:ResearchRoleIds) { $result | Where-Object { $_.Id -ceq $id } }
}

function Assert-HermesResearchSchemaVersion {
    param($Value)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -ne 1) { throw '연구 설정 SchemaVersion은 정수 1이어야 합니다.' }
}

function Get-HermesResearchRolePath {
    param([string]$RuntimeRoot)
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot) -or -not [IO.Path]::IsPathRooted($RuntimeRoot)) {
        throw 'RuntimeRoot 절대 경로가 필요합니다.'
    }
    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    $path = Join-Path (Join-Path $root 'research') 'roles.json'
    foreach ($target in @($root, $path)) {
        $safe = Test-HermesSafeTargetPath -LiteralPath $target -Label '연구 역할 설정'
        if (-not $safe.Safe) { throw $safe.Reason }
    }
    if (-not (Test-HermesPathContains -ParentPath $root -ChildPath $path)) { throw '역할 설정 경로가 RuntimeRoot 밖입니다.' }
    if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'RuntimeRoot는 폴더여야 합니다.'
    }
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '역할 설정 경로는 파일이어야 합니다.'
    }
    return $path
}

function Get-HermesResearchRoles {
    [CmdletBinding()]
    param([string]$RuntimeRoot)
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { return Get-HermesResearchDefaultRoles }
    $path = Get-HermesResearchRolePath $RuntimeRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return Get-HermesResearchDefaultRoles }
    if ((Get-Item -LiteralPath $path -Force).Length -gt 262144) { throw '역할 설정 파일이 허용 크기를 벗어났습니다.' }
    try { $catalog = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw '역할 설정 JSON을 읽을 수 없습니다. 기존 파일을 보존합니다.' }
    Assert-HermesResearchFields $catalog @('SchemaVersion', 'Roles') -Label '역할 카탈로그'
    Assert-HermesResearchSchemaVersion $catalog.SchemaVersion
    return ConvertTo-HermesResearchRoles $catalog.Roles
}

function Save-HermesResearchRoles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Roles, [Parameter(Mandatory = $true)][string]$RuntimeRoot)
    $validated = @(ConvertTo-HermesResearchRoles $Roles)
    $path = Get-HermesResearchRolePath $RuntimeRoot
    # Refuse to overwrite a damaged or future-schema catalog.
    if (Test-Path -LiteralPath $path -PathType Leaf) { $null = @(Get-HermesResearchRoles -RuntimeRoot $RuntimeRoot) }
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $null = Get-HermesResearchRolePath $RuntimeRoot
    $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $json = [pscustomobject][ordered]@{ SchemaVersion = 1; Roles = $validated } | ConvertTo-Json -Depth 6
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + [Environment]::NewLine)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
        $null = Get-HermesResearchRolePath $RuntimeRoot
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [IO.File]::Replace($temporary, $path, [System.Management.Automation.Language.NullString]::Value, $true)
        } else { [IO.File]::Move($temporary, $path) }
    } finally {
        $safe = Test-HermesSafeTargetPath -LiteralPath $temporary -Label '역할 임시 파일'
        if ($safe.Safe -and (Test-Path -LiteralPath $temporary -PathType Leaf)) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $path
}

function New-HermesResearchDefaultAgents {
    [CmdletBinding()]
    param()
    $roles = @(Get-HermesResearchDefaultRoles)
    for ($index = 0; $index -lt 4; $index++) {
        [pscustomobject][ordered]@{
            ProfileName = $script:ResearchProfiles[$index]
            DisplayName = $roles[$index].Name
            RoleId = $roles[$index].Id
            BotToken = ''
        }
    }
}

function ConvertTo-HermesResearchServerURL {
    param($Value)
    Assert-HermesResearchText $Value 2048 '서버 주소'
    $uri = $null
    if ($Value -match '\s' -or -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        @('http', 'https') -cnotcontains $uri.Scheme -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        $uri.Port -lt 1 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/') {
        throw '서버 주소에는 인증정보·쿼리·fragment·하위 경로가 없는 HTTP(S) 기본 주소를 입력하세요.'
    }
    $ip = $null
    $loopback = ($uri.DnsSafeHost -ieq 'localhost')
    if ([Net.IPAddress]::TryParse($uri.DnsSafeHost.Trim('[', ']'), [ref]$ip)) { $loopback = [Net.IPAddress]::IsLoopback($ip) }
    if ($uri.Scheme -ceq 'http' -and -not $loopback) { throw 'HTTP는 loopback 주소에서만 허용합니다. 원격 서버에는 HTTPS를 사용하세요.' }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function Assert-HermesResearchTeamInput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$InputObject, $Roles)
    Assert-HermesResearchFields $InputObject @('SchemaVersion', 'ServerURL', 'HomeChannelID', 'ModelName', 'Agents') @('Roles') '연구 팀 입력'
    Assert-HermesResearchSchemaVersion $InputObject.SchemaVersion
    $server = ConvertTo-HermesResearchServerURL $InputObject.ServerURL
    if ($InputObject.HomeChannelID -isnot [string] -or $InputObject.HomeChannelID -cnotmatch '^[a-z0-9]{26}$') {
        throw 'Home Channel ID는 소문자·숫자 26자리여야 합니다.'
    }
    Assert-HermesResearchText $InputObject.ModelName 128 '모델 이름'
    if ($InputObject.ModelName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$') { throw '모델 이름 형식이 올바르지 않습니다.' }
    if (-not $PSBoundParameters.ContainsKey('Roles')) {
        $inputFields = $(if ($InputObject -is [Collections.IDictionary]) { @($InputObject.Keys) } else { @($InputObject.PSObject.Properties.Name) })
        $Roles = $(if ($inputFields -ccontains 'Roles') { $InputObject.Roles } else { @(Get-HermesResearchDefaultRoles) })
    }
    $catalog = @(ConvertTo-HermesResearchRoles $Roles)
    if ($InputObject.Agents -isnot [System.Array] -or $InputObject.Agents.Count -ne 4) { throw '연구 팀은 정확히 네 에이전트여야 합니다.' }
    $seenProfiles = @(); $seenNames = @(); $seenRoles = @(); $seenTokens = @()
    $agents = New-Object System.Collections.Generic.List[object]
    foreach ($agent in $InputObject.Agents) {
        Assert-HermesResearchFields $agent @('ProfileName', 'DisplayName', 'RoleId', 'BotToken') -Label '에이전트'
        if ($agent.ProfileName -isnot [string] -or $script:ResearchProfiles -cnotcontains $agent.ProfileName -or $seenProfiles -contains $agent.ProfileName) {
            throw '네 가지 연구 프로필을 중복 없이 사용하세요.'
        }
        Assert-HermesResearchText $agent.DisplayName 200 '에이전트 표시명'
        $name = $agent.DisplayName.Trim()
        if ($seenNames -contains $name) { throw '에이전트 표시명은 서로 달라야 합니다.' }
        if ($agent.RoleId -isnot [string] -or $script:ResearchRoleIds -cnotcontains $agent.RoleId -or $seenRoles -ccontains $agent.RoleId) {
            throw '네 가지 역할을 중복 없이 배정하세요.'
        }
        if ($agent.BotToken -isnot [string] -or $agent.BotToken -cnotmatch '^[a-z0-9]{26}$' -or $seenTokens -ccontains $agent.BotToken) {
            throw '에이전트마다 서로 다른 소문자·숫자 26자리 봇 토큰이 필요합니다.'
        }
        $seenProfiles += $agent.ProfileName; $seenNames += $name; $seenRoles += $agent.RoleId; $seenTokens += $agent.BotToken
        $role = @($catalog | Where-Object { $_.Id -ceq $agent.RoleId })[0]
        # Only this allowlisted summary can be serialized; tokens stay in the caller's input.
        $agents.Add([pscustomobject][ordered]@{
            ProfileName = $agent.ProfileName; DisplayName = $name; RoleId = $agent.RoleId
            RoleName = $role.Name; Instructions = $role.Instructions
        })
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1; ServerURL = $server; HomeChannelID = $InputObject.HomeChannelID
        ModelName = $InputObject.ModelName; Roles = $catalog; Agents = $agents.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Get-HermesResearchRoles', 'Save-HermesResearchRoles',
    'New-HermesResearchDefaultAgents', 'Assert-HermesResearchTeamInput'
)
