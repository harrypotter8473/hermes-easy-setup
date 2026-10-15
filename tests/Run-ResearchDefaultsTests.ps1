[CmdletBinding()]
param([string]$PythonPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Research.psm1') -Force -DisableNameChecking
. (Join-Path $projectRoot 'src\HermesEasySetup.ResearchGovernance.ps1')
. (Join-Path $projectRoot 'src\HermesEasySetup.ResearchDefaults.ps1')
$script:passed = 0
function Assert-Defaults {
    param([bool]$Condition,[string]$Name)
    if (-not $Condition) { throw $Name }
    $script:passed++; Write-Host ('PASS ' + $Name)
}
function Assert-Rejected {
    param([scriptblock]$Action,[string]$Name)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Defaults $rejected $Name
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-default-tests-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $fixtureRoot 'runtime'
$workspace = Join-Path $fixtureRoot 'workspace'
New-Item -ItemType Directory -Path (Join-Path $runtime 'research\prompts'),(Join-Path $workspace 'inputs') -Force | Out-Null
try {
    $options = New-HermesResearchWizardOptions -WorkspacePath $workspace -HumanUsername 'researcher'
    Assert-Defaults (-not $options.AllowModelEgress -and -not $options.AllowPublicWeb -and -not $options.MigrationConsent) 'Model, public web and migration choices require explicit user consent'
    Assert-Rejected { Assert-HermesResearchWizardOptions $options $runtime } 'Unconfirmed defaults cannot silently authorize model use'
    $options.AllowModelEgress = $true
    Assert-Rejected { Assert-HermesResearchWizardOptions $options $runtime } 'Automatic web research needs its own user choice'
    $options.AllowPublicWeb = $true
    $validated = Assert-HermesResearchWizardOptions $options $runtime
    Assert-Defaults ($validated.WorkspacePath -ceq $workspace -and $validated.HumanUsername -ceq 'researcher') 'Wizard accepts concrete folder and username without JSON input'
    $policy = New-HermesResearchWizardPolicy -RuntimeRoot $runtime -Options $options -ModelName 'selected-model' -AllowedUserIDs @('h' * 26)
    Assert-Defaults ($policy.human.allowed_user_ids.Count -eq 1 -and $policy.human.allowed_user_ids[0] -ceq ('h' * 26)) 'Policy uses the server-resolved human identity'
    Assert-Defaults ($policy.web.provider -ceq 'duckduckgo_html' -and $policy.web.allow_public_web -and $policy.web.max_response_bytes -eq 2000000) 'Research uses configured bounded real web adapter'
    $manifest = Get-HermesResearchPersonaManifest
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        $value = $policy.roles[$role]
        $source = @($manifest.Personas | Where-Object CanonicalName -CEQ $role)[0]
        Assert-Defaults ($value.model -ceq 'selected-model' -and $value.provider -ceq 'openai-codex' -and $value.allow_model_egress) ($role + ' binds the actually selected model and explicit egress choice')
        Assert-Defaults ($value.prompt_sha256 -ceq $source.Sha256) ($role + ' retains the entire supplied persona with its exact hash')
        Assert-Defaults ($value.read_roots.Count -eq 1 -and $value.read_roots[0] -ceq (Join-Path $workspace 'inputs')) ($role + ' reads only the selected input folder')
        Assert-Defaults ($value.write_roots.Count -eq 1 -and $value.write_roots[0] -ceq (Join-Path $runtime ('research\policy.artifacts\' + $role))) ($role + ' uses isolated immutable artifact storage')
        $expectedAudits = $(if ($role -ceq 'auditor') { 20 } else { 4 })
        Assert-Defaults ($value.limits.attempts -eq 40 -and $value.limits.revisions -eq 2 -and $value.limits.audits -eq $expectedAudits -and $value.limits.tokens -eq 600000) ($role + ' has finite editable attempt revision audit and token limits')
        Assert-Defaults (@($value.tools | Where-Object { $_ -in @('terminal','python','browser','delegate') }).Count -eq 0) ($role + ' has no unrestricted native tool grant')
        [IO.File]::WriteAllBytes($value.prompt_path,[IO.File]::ReadAllBytes($source.Path))
    }
    Assert-Defaults (($policy.roles.manager.call_targets -join ',') -ceq 'researcher,analyst,auditor') 'Only management can assign all three worker roles'
    Assert-Defaults ($policy.roles.auditor.tools -notcontains 'write_artifact' -and $policy.roles.auditor.call_targets.Count -eq 0) 'Auditor cannot modify originals or delegate'
    Assert-Defaults ($policy.roles.researcher.tools -contains 'search_web' -and $policy.roles.researcher.tools -contains 'read_web' -and $policy.roles.researcher.external_domains[0] -ceq '*') 'Researcher has both search and original-page reading with public web permission'
    Assert-Defaults ($policy.roles.manager.external_domains.Count -eq 0 -and $policy.roles.analyst.external_domains.Count -eq 0 -and $policy.roles.auditor.external_domains.Count -eq 0) 'Other roles cannot silently acquire web access'
    $options.Roles.researcher.ReadWorkspace = $false
    $options.Roles.researcher.Limits.revisions = 3
    $changed = New-HermesResearchWizardPolicy -RuntimeRoot $runtime -Options $options -ModelName 'selected-model' -AllowedUserIDs @('h' * 26)
    Assert-Defaults ($changed.roles.researcher.read_roots.Count -eq 0 -and $changed.roles.researcher.limits.revisions -eq 3 -and $changed.roles.analyst.limits.revisions -eq 2) 'Per-role material and limit edits reach the policy without granting peers access'
    $options.Roles.researcher.Limits.revisions = 0
    Assert-Rejected { Assert-HermesResearchWizardOptions $options $runtime } 'Automatic rejection loop cannot be configured with no revision allowance'
    $options.Roles.researcher.Limits.revisions = 2
    $options.Roles.auditor.Limits.audits = 4
    Assert-Rejected { Assert-HermesResearchWizardOptions $options $runtime } 'Audit allowance below the six mandatory version checks cannot pass installation choices'
    $options.Roles.auditor.Limits.audits = 20
    $options.WorkspacePath = $runtime
    Assert-Rejected { Assert-HermesResearchWizardOptions $options $runtime } 'Runtime credentials and policy folder cannot be the material workspace'
    $options.WorkspacePath = $fixtureRoot
    Assert-Rejected { Assert-HermesResearchWizardOptions $options $runtime } 'Workspace ancestor cannot expose the runtime subtree'
    $options.WorkspacePath = $workspace
    Assert-Rejected { New-HermesResearchWizardPolicy -RuntimeRoot $runtime -Options $options -ModelName 'selected-model' -AllowedUserIDs @('researcher') } 'Unresolved username cannot masquerade as a verified Mattermost user ID'
    $options.AllowPublicWeb = 'true'
    Assert-Rejected { Assert-HermesResearchWizardOptions $options $runtime } 'String truthiness cannot provide web consent'
    if ($PythonPath) {
        $policyPath = Join-Path $runtime 'research\policy.json'
        [IO.File]::WriteAllText($policyPath,($policy | ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($false)))
        $output = & $PythonPath -I -S -B (Join-Path $projectRoot 'engine\research_team\broker.py') check --root (Join-Path $runtime 'research') --config $policyPath
        if ($LASTEXITCODE -ne 0) { throw 'Generated wizard policy failed the actual Python runtime validator' }
        $status = ($output -join "`n") | ConvertFrom-Json
        Assert-Defaults ($status.ready -and $status.prompts_verified -and @($status.errors).Count -eq 0 -and @($status.pending_reasons).Count -eq 0) 'Generated form policy passes the real runtime with exact persona files and no pending fields'
    }
    Write-Host ('Research defaults tests passed: ' + $script:passed)
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-default-tests-'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
