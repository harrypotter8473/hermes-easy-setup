[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
Import-Module (Join-Path $source 'HermesEasySetup.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $source 'HermesEasySetup.Research.psm1') -Force -DisableNameChecking
$script:passed = 0
function Assert { param($Ok, [string]$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
function Reject {
    param([scriptblock]$Action, [string]$Name, [string]$Secret = '')
    $failed = $false
    try { & $Action | Out-Null } catch {
        $failed = $true
        if ($Secret -and $_.Exception.Message.Contains($Secret)) { throw 'Validation reflected a fixture secret.' }
    }
    Assert $failed $Name
}
function New-TeamFixture {
    $agents = @(New-HermesResearchDefaultAgents)
    for ($i = 0; $i -lt 4; $i++) { $agents[$i].BotToken = ([string][char](97 + $i)) * 26 }
    return [pscustomobject]@{ SchemaVersion = 1; ServerURL = 'http://localhost:8065/'; HomeChannelID = 'h' * 26; ModelName = 'gpt-5.4'; Agents = $agents }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('hermes-research-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $roles = @(Get-HermesResearchRoles -RuntimeRoot $root)
    Assert (($roles.Id -join ',') -ceq 'planner,researcher,executor,reviewer') 'Four fixed role IDs in stable order'
    Assert (($roles.Name -join ',') -ceq '총괄,조사,실행,검토') 'Korean default role names'
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'research'))) 'Reading defaults does not write files'
    $roles[0].Name = '연구 총괄'; $roles[0].Instructions = "첫 줄`n근거를 확인한다."
    $path = Save-HermesResearchRoles -Roles $roles -RuntimeRoot $root
    $loaded = @(Get-HermesResearchRoles -RuntimeRoot $root)
    Assert ($loaded[0].Name -ceq $roles[0].Name -and $loaded[0].Instructions -ceq $roles[0].Instructions) 'UTF-8 names and multiline instructions roundtrip'
    $roles[1].Name = '자료 조사'
    $null = Save-HermesResearchRoles -Roles $roles -RuntimeRoot $root
    Assert (@(Get-HermesResearchRoles -RuntimeRoot $root)[1].Name -ceq '자료 조사') 'Existing catalog atomically updates'
    $catalog = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    Assert ($catalog.SchemaVersion -eq 1 -and @($catalog.PSObject.Properties).Count -eq 2) 'Only schema and roles are persisted'
    $before = [IO.File]::ReadAllText($path)
    foreach ($kind in @('duplicate', 'unknown-id', 'unknown-field', 'token', 'blank', 'long-name', 'long-instructions', 'control', 'wrong-type')) {
        $bad = $roles | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        switch ($kind) {
            'duplicate' { $bad[1].Id = $bad[0].Id }
            'unknown-id' { $bad[0].Id = 'other' }
            'unknown-field' { $bad[0] | Add-Member NoteProperty ProfileName 'research-lead' }
            'token' { $bad[0] | Add-Member NoteProperty BotToken ('z' * 26) }
            'blank' { $bad[0].Name = ' ' }
            'long-name' { $bad[0].Name = 'n' * 101 }
            'long-instructions' { $bad[0].Instructions = 'i' * 8001 }
            'control' { $bad[0].Instructions = 'x' + [char]0 }
            'wrong-type' { $bad[0].Name = 12 }
        }
        Reject { Save-HermesResearchRoles -Roles $bad -RuntimeRoot $root } "Catalog rejects $kind"
    }
    Assert ([IO.File]::ReadAllText($path) -ceq $before) 'Rejected edits preserve catalog bytes'
    foreach ($json in @('{broken', '', '{"SchemaVersion":2,"Roles":[]}', '{"SchemaVersion":1,"Roles":[],"Token":"fixture"}')) {
        [IO.File]::WriteAllText($path, $json)
        Reject { Get-HermesResearchRoles -RuntimeRoot $root } 'Invalid stored catalog fails closed'
        Reject { Save-HermesResearchRoles -Roles $roles -RuntimeRoot $root } 'Invalid stored catalog cannot be overwritten'
        Assert ([IO.File]::ReadAllText($path) -ceq $json) 'Invalid stored bytes retained'
    }
    [IO.File]::WriteAllText($path, $before)
    Reject { Save-HermesResearchRoles -Roles $roles -RuntimeRoot 'relative' } 'Relative runtime root rejected'

    $input = New-TeamFixture
    $summary = Assert-HermesResearchTeamInput -InputObject $input -Roles $roles
    Assert ($summary.ServerURL -ceq 'http://localhost:8065' -and $summary.Agents.Count -eq 4 -and $summary.ModelName -ceq $input.ModelName) 'Valid offline team normalized'
    $serialized = $summary | ConvertTo-Json -Depth 8
    foreach ($agent in $input.Agents) { Assert (-not $serialized.Contains($agent.BotToken)) 'Serializable summary contains no bot token' }
    $input.Agents[0].RoleId = 'researcher'; $input.Agents[1].RoleId = 'planner'
    Assert ((Assert-HermesResearchTeamInput $input -Roles $roles).Agents[0].RoleName -ceq '자료 조사') 'Role assignment can swap across fixed profiles'
    foreach ($url in @('http://127.0.0.1:8065', 'http://[::1]:8065', 'https://lab.example.invalid/')) {
        $input = New-TeamFixture; $input.ServerURL = $url
        Assert ([bool](Assert-HermesResearchTeamInput $input)) 'Loopback HTTP or remote HTTPS accepted without network'
    }
    foreach ($url in @('http://lab.example.invalid', 'http://100.69.1.2:8065', 'https://user:pass@lab.example.invalid', 'https://lab.example.invalid/?token=fixture', 'https://lab.example.invalid/#x', 'https://lab.example.invalid/channel', 'file:///C:/test')) {
        $input = New-TeamFixture; $input.ServerURL = $url
        Reject { Assert-HermesResearchTeamInput $input } 'Unsafe base URL rejected'
    }
    foreach ($kind in @('schema', 'unknown-field', 'three', 'five', 'profile', 'name', 'role', 'token', 'uppercase-token', 'short-token', 'channel', 'model', 'agent-extra')) {
        $input = New-TeamFixture
        switch ($kind) {
            'schema' { $input.SchemaVersion = '1' }
            'unknown-field' { $input | Add-Member NoteProperty Password 'fixture-secret' }
            'three' { $input.Agents = @($input.Agents[0..2]) }
            'five' { $input.Agents = @($input.Agents) + @($input.Agents[0]) }
            'profile' { $input.Agents[1].ProfileName = $input.Agents[0].ProfileName }
            'name' { $input.Agents[1].DisplayName = ' ' + $input.Agents[0].DisplayName + ' ' }
            'role' { $input.Agents[1].RoleId = $input.Agents[0].RoleId }
            'token' { $input.Agents[1].BotToken = $input.Agents[0].BotToken }
            'uppercase-token' { $input.Agents[0].BotToken = 'A' * 26 }
            'short-token' { $input.Agents[0].BotToken = 'fixture-secret' }
            'channel' { $input.HomeChannelID = 'home-channel' }
            'model' { $input.ModelName = "model`nunsafe" }
            'agent-extra' { $input.Agents[0] | Add-Member NoteProperty Password 'fixture-secret' }
        }
        Reject { Assert-HermesResearchTeamInput $input } "Team rejects $kind" 'fixture-secret'
    }
    $input = New-TeamFixture; $input | Add-Member NoteProperty Roles $roles
    Assert ((Assert-HermesResearchTeamInput $input).Roles[0].Name -ceq '연구 총괄') 'Embedded custom roles used when override is absent'
    $junctionRoot = Join-Path $root 'junction-root'
    $outside = Join-Path $root 'outside'
    New-Item -ItemType Directory -Path $junctionRoot, $outside | Out-Null
    $link = Join-Path $junctionRoot 'research'
    New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
    try {
        Reject { Get-HermesResearchRoles -RuntimeRoot $junctionRoot } 'Read rejects reparse parent'
        Reject { Save-HermesResearchRoles -Roles $roles -RuntimeRoot $junctionRoot } 'Save rejects reparse parent'
        Assert (-not (Test-Path -LiteralPath (Join-Path $outside 'roles.json'))) 'Reparse rejection writes no destination file'
    } finally { [IO.Directory]::Delete($link) }
    Write-Host ('Research tests passed: ' + $script:passed)
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-research-test-'
    if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
