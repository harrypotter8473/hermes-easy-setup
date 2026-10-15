[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Research.psm1') -Force -DisableNameChecking

$script:passed = 0
function Assert-Persona {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw $Name }
    $script:passed++
    Write-Host "PASS $Name"
}

$expected = @(
    [pscustomobject]@{ Canonical = 'manager'; Legacy = 'planner'; Profile = 'research-lead'; Name = '관리'; File = 'manager.txt'; Length = 9542; Sha256 = 'd8cae97e9d90b1210ff909e025db4a547ff7f8ad2ed45b95d1a4699c84e0c1b7' }
    [pscustomobject]@{ Canonical = 'researcher'; Legacy = 'researcher'; Profile = 'research-scout'; Name = '조사'; File = 'researcher.txt'; Length = 9353; Sha256 = '637045d63eb06ea6f8fe04f8f714059b67b93368c3ac13dd78015ce5a82e7582' }
    [pscustomobject]@{ Canonical = 'analyst'; Legacy = 'executor'; Profile = 'research-worker'; Name = '분석'; File = 'analyst.txt'; Length = 10210; Sha256 = '8dca29efba1a7671db9445122268874dbdafa2c66e03f455aa512f589bc2409b' }
    [pscustomobject]@{ Canonical = 'auditor'; Legacy = 'reviewer'; Profile = 'research-reviewer'; Name = '감사'; File = 'auditor.txt'; Length = 10685; Sha256 = 'ea80c9823ff57d30676f24c71def6f26c40f103f37484a530bc2a86b5a84be3b' }
)
$assetRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'assets\research-prompts'))
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-persona-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    $manifest = Get-HermesResearchPersonaManifest
    Assert-Persona ($manifest.SourceVersion -ceq 'v0.1_20261015') 'Manifest reports the supplied persona source version'
    Assert-Persona (@($manifest.Personas).Count -eq 4) 'Manifest contains exactly four personas'
    Assert-Persona ((@($manifest.Personas.CanonicalName) -join ',') -ceq 'manager,researcher,analyst,auditor') 'Canonical persona order is stable'
    Assert-Persona ((@($manifest.Personas.LegacyRoleId) -join ',') -ceq 'planner,researcher,executor,reviewer') 'Legacy role IDs remain compatible'
    Assert-Persona ((@($manifest.Personas.ProfileName) -join ',') -ceq 'research-lead,research-scout,research-worker,research-reviewer') 'Profile mapping remains compatible'

    for ($index = 0; $index -lt 4; $index++) {
        $persona = $manifest.Personas[$index]
        $spec = $expected[$index]
        $expectedPath = [IO.Path]::GetFullPath((Join-Path $assetRoot $spec.File))
        Assert-Persona ([string]::Equals([string]$persona.Path, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) ("{0} manifest path is canonical" -f $spec.Canonical)
        Assert-Persona ((Get-Item -LiteralPath $persona.Path).Length -eq $spec.Length) ("{0} asset preserves source byte length" -f $spec.Canonical)
        Assert-Persona ($persona.Sha256 -ceq $spec.Sha256 -and (Get-FileHash -LiteralPath $persona.Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $spec.Sha256) ("{0} asset preserves the source SHA-256" -f $spec.Canonical)
        $assetText = (New-Object Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($persona.Path))
        Assert-Persona ($persona.Text -ceq $assetText -and $persona.Text.EndsWith("`r`n")) ("{0} text is full and byte-source faithful without appended rules" -f $spec.Canonical)
    }

    $roles = @(Get-HermesResearchRoles)
    Assert-Persona (($roles.Id -join ',') -ceq 'planner,researcher,executor,reviewer') 'Default role IDs remain stable'
    Assert-Persona (($roles.Name -join ',') -ceq '관리,조사,분석,감사') 'Default role labels use management, research, analysis and audit'
    for ($index = 0; $index -lt 4; $index++) {
        Assert-Persona ($roles[$index].Instructions -ceq $manifest.Personas[$index].Text) ("{0} role uses the complete persona file" -f $expected[$index].Canonical)
    }

    $roundtripRoot = Join-Path $fixtureRoot 'roundtrip'
    $savedPath = Save-HermesResearchRoles -Roles $roles -RuntimeRoot $roundtripRoot
    $roundtrip = @(Get-HermesResearchRoles -RuntimeRoot $roundtripRoot)
    Assert-Persona ((Test-Path -LiteralPath $savedPath -PathType Leaf) -and $roundtrip.Count -eq 4) 'Full persona roles pass catalog validation and persistence'
    for ($index = 0; $index -lt 4; $index++) {
        Assert-Persona ($roundtrip[$index].Instructions -ceq $manifest.Personas[$index].Text) ("{0} full text roundtrips without truncation" -f $expected[$index].Canonical)
    }

    $agents = @(New-HermesResearchDefaultAgents)
    for ($index = 0; $index -lt 4; $index++) { $agents[$index].BotToken = ([string][char](97 + $index)) * 26 }
    $team = [pscustomobject]@{ SchemaVersion = 1; ServerURL = 'http://127.0.0.1:8065/'; HomeChannelID = 'h' * 26; ModelName = 'gpt-5.6-terra'; Agents = $agents }
    $summary = Assert-HermesResearchTeamInput -InputObject $team
    Assert-Persona (@($summary.Roles | Where-Object { $_.Instructions.Length -lt 3900 }).Count -eq 0) 'Team validation accepts all four complete persona instructions'

    $legacyRoles = @(
        [pscustomobject][ordered]@{ Id = 'planner'; Name = '총괄'; Instructions = '연구 목표와 작업 순서를 정리하고 조사·실행·검토 결과를 종합한다. 확인된 근거와 제안을 구분한다.' }
        [pscustomobject][ordered]@{ Id = 'researcher'; Name = '조사'; Instructions = '관련 자료와 출처를 조사하고 확인한 내용과 불확실한 내용을 구분하여 보고한다.' }
        [pscustomobject][ordered]@{ Id = 'executor'; Name = '실행'; Instructions = '합의된 연구 계획에 따라 작업을 수행하고 방법·결과·한계를 기록한다. 추가 권한이 필요한 작업은 요청한다.' }
        [pscustomobject][ordered]@{ Id = 'reviewer'; Name = '검토'; Instructions = '연구 결과의 근거와 재현 가능성을 독립적으로 검토하고 오류·누락·한계를 보고한다.' }
    )
    $legacyRoot = Join-Path $fixtureRoot 'legacy'
    $legacyPath = Join-Path (Join-Path $legacyRoot 'research') 'roles.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPath) -Force | Out-Null
    [IO.File]::WriteAllText($legacyPath, (([pscustomobject][ordered]@{ SchemaVersion = 1; Roles = $legacyRoles } | ConvertTo-Json -Depth 6) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    $legacyHash = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash
    $migrated = @(Get-HermesResearchRoles -RuntimeRoot $legacyRoot)
    Assert-Persona (($migrated.Name -join ',') -ceq '관리,조사,분석,감사') 'Exact former built-in catalog migrates to supplied defaults in memory'
    Assert-Persona ((Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash -ceq $legacyHash) 'Legacy default migration does not edit roles.json'

    $customRoot = Join-Path $fixtureRoot 'custom'
    $customPath = Join-Path (Join-Path $customRoot 'research') 'roles.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $customPath) -Force | Out-Null
    $customRoles = @($legacyRoles | ForEach-Object {
        [pscustomobject][ordered]@{ Id = [string]$_.Id; Name = [string]$_.Name; Instructions = [string]$_.Instructions }
    })
    $customRoles[0].Name = '사용자 정의 총괄'
    [IO.File]::WriteAllText($customPath, (([pscustomobject][ordered]@{ SchemaVersion = 1; Roles = $customRoles } | ConvertTo-Json -Depth 6) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    $customHash = (Get-FileHash -LiteralPath $customPath -Algorithm SHA256).Hash
    $custom = @(Get-HermesResearchRoles -RuntimeRoot $customRoot)
    Assert-Persona ($custom[0].Name -ceq '사용자 정의 총괄' -and $custom[0].Instructions -ceq $legacyRoles[0].Instructions) 'Any user customization prevents legacy-default migration'
    Assert-Persona ((Get-FileHash -LiteralPath $customPath -Algorithm SHA256).Hash -ceq $customHash) 'Custom catalog remains byte-for-byte unchanged'

    $manifest.Personas[0].Text = 'caller mutation'
    Assert-Persona ((Get-HermesResearchPersonaManifest).Personas[0].Text -cne 'caller mutation') 'Manifest returns fresh immutable-by-copy persona data'
    Write-Host ('Research persona tests passed: ' + $script:passed)
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-persona-tests-'
    if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
