Set-StrictMode -Version 2.0

# The broker, not four unrestricted native gateways, owns the research channel.
# Native profile names remain stable for existing wizard data and authentication.
function Assert-HermesResearchPolicyFields {
    param($Value, [string[]]$Required, [string]$Label)
    if ($Value -is [Collections.IDictionary]) { $names = @($Value.Keys) }
    elseif ($Value -is [Management.Automation.PSCustomObject]) { $names = @($Value.PSObject.Properties.Name) }
    else { throw ($Label + ' 형식이 올바르지 않습니다.') }
    if (@($names | Where-Object { $Required -cnotcontains $_ }).Count -gt 0 -or @($Required | Where-Object { $names -cnotcontains $_ }).Count -gt 0) { throw ($Label + ' 필수 필드 또는 허용 필드가 다릅니다.') }
}

function Get-HermesResearchPolicyPath {
    param([string]$RuntimeRoot)
    $path = Join-Path $RuntimeRoot 'research\policy.json'
    if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe) { throw 'ResearchPolicyPathRejected' }
    return $path
}

function New-HermesResearchPolicy {
    param([string]$RuntimeRoot, [AllowNull()][string]$ModelName, $Agents, $Roles)
    $manifest = Get-HermesResearchPersonaManifest
    $bindings = $(if ($null -eq $Agents) { @(New-HermesResearchDefaultAgents) } else { @($Agents) })
    $catalog = $(if ($null -eq $Roles) { @(Get-HermesResearchRoles) } else { @($Roles) })
    $roleConfig = [ordered]@{}
    foreach ($persona in @($manifest.Personas)) {
        $binding = @($bindings | Where-Object { $_.RoleId -ceq $persona.LegacyRoleId })
        $role = @($catalog | Where-Object { $_.Id -ceq $persona.LegacyRoleId })
        if ($binding.Count -ne 1 -or $role.Count -ne 1) { throw 'ResearchPolicyRoleBindingRejected' }
        $roleConfig[$persona.CanonicalName] = [ordered]@{
            profile_name = [string]$binding[0].ProfileName
            prompt_path = (Join-Path $RuntimeRoot ('research\prompts\' + $persona.CanonicalName + '.txt'))
            prompt_sha256 = (ConvertTo-HermesSha256 -Text ([string]$role[0].Instructions)).ToLowerInvariant()
            model = $(if ($ModelName) { $ModelName } else { $null })
            provider = $(if ($ModelName) { 'openai-codex' } else { $null })
            allow_model_egress = $null
            tools = $null; read_roots = $null; write_roots = $null
            call_targets = $null; external_domains = $null
            limits = [ordered]@{
                attempts = $null; revisions = $null; audits = $null; seconds = $null; tokens = $null
                max_output_tokens = $null; per_call_timeout_seconds = $null
            }
        }
    }
    return [pscustomobject][ordered]@{ schema_version = 1; human = @{ allowed_user_ids = @() }; roles = $roleConfig }
}

function Get-HermesResearchPolicy {
    param([string]$RuntimeRoot)
    $path = Get-HermesResearchPolicyPath $RuntimeRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return New-HermesResearchPolicy -RuntimeRoot $RuntimeRoot }
    if ((Get-Item -LiteralPath $path).Length -gt 262144) { throw 'ResearchPolicyTooLarge' }
    try { return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw '운영 설정 JSON을 읽을 수 없습니다. 기존 파일은 보존했습니다.' }
}

function ConvertFrom-HermesResearchPolicyJson {
    param([Parameter(Mandatory = $true)][string]$Json)
    if ($Json.Length -gt 262144) { throw 'ResearchPolicyTooLarge' }
    try { $value = $Json | ConvertFrom-Json -ErrorAction Stop } catch { throw '운영 설정 JSON 문법을 확인하세요.' }
    $topFields = @('schema_version','human','roles')
    if ($value.PSObject.Properties['web']) { $topFields += 'web' }
    Assert-HermesResearchPolicyFields $value $topFields -Label '운영 설정'
    if ($value.schema_version -ne 1) { throw 'ResearchPolicySchemaRejected' }
    Assert-HermesResearchPolicyFields $value.human @('allowed_user_ids') -Label '연구자 설정'
    Assert-HermesResearchPolicyFields $value.roles @('manager','researcher','analyst','auditor') -Label '역할별 운영 설정'
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        Assert-HermesResearchPolicyFields $value.roles.$role @('profile_name','prompt_path','prompt_sha256','model','provider','allow_model_egress','tools','read_roots','write_roots','call_targets','external_domains','limits') -Label '역할 운영 설정'
        Assert-HermesResearchPolicyFields $value.roles.$role.limits @('attempts','revisions','audits','seconds','tokens','max_output_tokens','per_call_timeout_seconds') -Label '실행 한도'
    }
    return $value
}

function Save-HermesResearchPolicy {
    param([string]$RuntimeRoot, [Parameter(Mandatory = $true)][string]$Json)
    $value = ConvertFrom-HermesResearchPolicyJson -Json $Json
    $path = Get-HermesResearchPolicyPath $RuntimeRoot
    Write-HermesResearchAtomicText -LiteralPath $path -Text (($value | ConvertTo-Json -Depth 15) + [Environment]::NewLine)
    return $path
}

function Protect-HermesResearchPrivateDirectory {
    param([string]$LiteralPath, [string]$OwnerSID)
    if (-not (Test-HermesSafeTargetPath -LiteralPath $LiteralPath).Safe) { throw 'ResearchPrivatePathRejected' }
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) { New-Item -ItemType Directory -Path $LiteralPath -Force | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($OwnerSID, 'S-1-5-18')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Replace only the DACL. A brand-new descriptor passed to Set-Acl can
    # request owner/SACL writes and SeSecurityPrivilege on an existing folder.
    # Preserve those sections so a normal current-user install remains possible.
    $section = [Security.AccessControl.AccessControlSections]::Access
    $directory = New-Object IO.DirectoryInfo($LiteralPath)
    $existing = $(if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::GetAccessControl($directory, $section) } else { $directory.GetAccessControl($section) })
    $rules = @($existing.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $correct = $existing.AreAccessRulesProtected -and $rules.Count -eq 2 -and @($rules | Where-Object {
        $_.IdentityReference.Value -cnotin @($OwnerSID,'S-1-5-18') -or $_.AccessControlType -ne 'Allow' -or
        $_.FileSystemRights -ne 'FullControl' -or $_.InheritanceFlags -ne 'ContainerInherit, ObjectInherit' -or $_.PropagationFlags -ne 'None'
    }).Count -eq 0
    if ($correct) { return }
    $existing.SetSecurityDescriptorSddlForm($acl.GetSecurityDescriptorSddlForm($section), $section)
    if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::SetAccessControl($directory,$existing) }
    else { $directory.SetAccessControl($existing) }
}

function Install-HermesResearchBrokerFiles {
    param([string]$ResearchRoot)
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'engine\research_team'
    $files = @('__init__.py','policy.py','broker.py','hermes_worker.py','workflow.py','web_tools.py','native_cutover.py','profile_config.py','report_docx.py')
    foreach ($name in $files) {
        $from = Join-Path $source $name
        $to = Join-Path $ResearchRoot ('engine\research_team\' + $name)
        if (-not (Test-Path -LiteralPath $from -PathType Leaf) -or -not (Test-HermesSafeTargetPath -LiteralPath $to).Safe) { throw 'ResearchBrokerPayloadRejected' }
        Write-HermesResearchAtomicText -LiteralPath $to -Text ([IO.File]::ReadAllText($from, [Text.Encoding]::UTF8))
        if ((ConvertTo-HermesSha256 -LiteralPath $from) -cne (ConvertTo-HermesSha256 -LiteralPath $to)) { throw 'ResearchBrokerPayloadHashMismatch' }
    }
}

function Register-HermesResearchBrokerTask {
    param($Plan, [string]$Python, [string]$ResearchRoot, [bool]$HasOwnership)
    $existing = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
    if ($existing.Count -gt 1) { throw 'ResearchBrokerTaskCollision' }
    if ($existing.Count -eq 1) {
        Assert-HermesResearchOwnedTask -Task $existing[0] -Plan $Plan -HasOwnership $HasOwnership
        if ([string]$existing[0].State -eq 'Running') { throw '실행 중인 연구팀 서비스가 있습니다. 진행 중 작업을 마친 뒤 해당 서비스만 중지하고 재설정하세요.' }
    }
    $quote = { param([string]$Text) "'" + $Text.Replace("'", "''") + "'" }
    $runner = @(
        '$ErrorActionPreference = ''Stop'''
        '$env:PYTHONHOME = $null; $env:PYTHONPATH = $null; $env:PYTHONUSERBASE = $null; $env:PYTHONSTARTUP = $null'
        '$env:PYTHONNOUSERSITE = ''1''; $env:PYTHONDONTWRITEBYTECODE = ''1'''
        ('& {0} -I -S -B {1} serve --root {2}' -f (& $quote $Python), (& $quote (Join-Path $ResearchRoot 'engine\research_team\broker.py')), (& $quote $ResearchRoot))
        'exit $LASTEXITCODE'
    ) -join [Environment]::NewLine
    Write-HermesResearchAtomicText -LiteralPath $Plan.RunnerPath -Text ($runner + [Environment]::NewLine) -ByteOrderMark
    $action = New-ScheduledTaskAction -Execute $Plan.Execute -Argument $Plan.Arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Plan.OwnerSID
    $principal = New-ScheduledTaskPrincipal -UserId $Plan.OwnerSID -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $Plan.Description
    Register-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -InputObject $task -Force:($existing.Count -eq 1) -ErrorAction Stop | Out-Null
}

function Get-HermesResearchPythonProcessPath {
    param([string]$Python)
    # Windows venv python.exe is a launcher. Its child process MainModule is
    # the base interpreter, not the launcher's path. Ask that exact interpreter
    # for its OS module path instead of trusting arbitrary heartbeat metadata.
    $program = 'import ctypes,sys; b=ctypes.create_unicode_buffer(32768); n=ctypes.windll.kernel32.GetModuleFileNameW(None,b,len(b)); print(b.value if n else ""); sys.exit(0 if n else 1)'
    $probe = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-I','-S','-B','-c',$program) -Environment @{ PYTHONHOME=''; PYTHONPATH=''; PYTHONUSERBASE=''; PYTHONSTARTUP='' } -TimeoutSeconds 15
    if (-not $probe.Started -or $probe.TimedOut -or $probe.ExitCode -ne 0) { throw 'ResearchPythonIdentityProbeFailed' }
    $physical = $probe.StdOut.Trim()
    # A verified Hermes venv may use uv's junction-backed base interpreter.
    # This is the OS path returned by the selected process, not an input path
    # to read/write or a value supplied by the heartbeat file.
    if (-not [IO.Path]::IsPathRooted($physical) -or $physical.StartsWith('\\') -or -not (Test-Path -LiteralPath $physical -PathType Leaf)) { throw 'ResearchPythonIdentityRejected' }
    return [IO.Path]::GetFullPath($physical)
}

function Wait-HermesResearchBrokerReady {
    param([string]$ResearchRoot, [string]$Python, [double]$StartedAt, [int]$TimeoutSeconds = 30)
    $path = Join-Path $ResearchRoot 'broker-status.json'
    $processPath = Get-HermesResearchPythonProcessPath -Python $Python
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ((Test-HermesSafeTargetPath -LiteralPath $path).Safe -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            try {
                $status = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($status.prompts_verified -eq $true -and @($status.errors).Count -eq 0 -and [double]$status.updated_at -ge $StartedAt -and [int]$status.pid -gt 0) {
                    $process = [Diagnostics.Process]::GetProcessById([int]$status.pid)
                    if (-not $process.HasExited -and [string]::Equals([string]$process.MainModule.FileName, $processPath, [StringComparison]::OrdinalIgnoreCase)) { return $status }
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'ResearchBrokerHeartbeatNotReady'
}

function Invoke-HermesGovernedResearchSetup {
    param($InputObject, $Paths, $Runtime, [string]$CommandPath, $Identities, [switch]$ReuseExistingProfiles, [switch]$UseExistingHermes, [scriptblock]$ProgressCallback)
    $owner = Get-HermesResearchCurrentUserSID
    $root = Join-Path $Paths.RuntimeRoot 'research'
    $statePath = Join-Path $root 'team.json'
    $runtimeKind = $(if ($UseExistingHermes) { 'Existing' } else { 'Pinned' })
    $prior = $null
    $priorHash = $null
    $options = $(if ($InputObject.PSObject.Properties['WizardOptions']) { $InputObject.WizardOptions } else { $null })
    $migrationConsent = $null -ne $options -and $options.MigrationConsent -eq $true
    $migrationBackup = $null
    if (Test-Path -LiteralPath $statePath) {
        if (-not $ReuseExistingProfiles) { throw '기존 연구팀은 명시적으로 재설정을 선택하세요.' }
        try {
            if (-not (Test-HermesSafeTargetPath -LiteralPath $statePath).Safe) { throw 'Unsafe' }
            $prior = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $priorHash = ConvertTo-HermesSha256 -LiteralPath $statePath
            if ($prior.SchemaVersion -ne 1 -or $prior.Manager -cne 'HermesEasySetup.Research.v1' -or $prior.OwnerSID -cne $owner -or $prior.TeamID -cnotmatch '^[a-f0-9]{32}$' -or ($prior.PSObject.Properties['RuntimeKind'] -and $prior.RuntimeKind -cne $runtimeKind) -or
                $prior.HermesHome -ine $Paths.HermesHome -or $prior.InstallDir -ine $Paths.InstallDir -or $prior.RuntimeRoot -ine $Paths.RuntimeRoot -or
                $prior.ServerURL -cne $InputObject.ServerURL.TrimEnd('/') -or $prior.HomeChannelID -cne $InputObject.HomeChannelID -or @($prior.Profiles).Count -ne 4) { throw 'ForeignTeam' }
        } catch { throw '기존 연구팀 소유권·프로필·봇 연결이 다릅니다. 해당 기록은 변경하지 않았습니다.' }
        if (-not $migrationConsent) { throw '기존 네 봇 전환 동의를 선택하세요. 기록을 유지하고 이 팀의 기존 응답 서비스만 전환합니다.' }
    }
    $manifest = Get-HermesResearchPersonaManifest
    $python = $(if ($UseExistingHermes) { [string]$Runtime.Python } else { Join-Path $Paths.InstallDir 'venv\Scripts\python.exe' })
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'ResearchPythonMissing' }
    $teamID = $(if ($null -eq $prior) { [guid]::NewGuid().ToString('N') } else { [string]$prior.TeamID })
    $plan = Get-HermesResearchTaskPlan -ProfileName 'governed-team' -HermesHome $Paths.HermesHome -RuntimeRoot $Paths.RuntimeRoot -OwnerSID $owner -TeamID $teamID -PowerShellPath (Get-HermesPowerShellExecutable)
    $ownedTask = $null -ne $prior
    $tasks = @(Get-HermesResearchGatewayTask -TaskName $plan.TaskName)
    if ($tasks.Count -gt 1) { throw 'ResearchBrokerTaskCollision' }
    if ($tasks.Count -eq 1) {
        Assert-HermesResearchOwnedTask -Task $tasks[0] -Plan $plan -HasOwnership $ownedTask
        if ([string]$tasks[0].State -eq 'Running' -and -not $migrationConsent) { throw '실행 중인 연구팀 전환 동의가 필요합니다.' }
    }
    $profileOwnership = @{}
    foreach ($agent in @($InputObject.Agents)) {
        $dir = Join-Path $Paths.HermesHome ('profiles\' + $agent.ProfileName)
        $identity = @($Identities | Where-Object { $_.ProfileName -ceq $agent.ProfileName })[0]
        $previous = @($(if ($null -ne $prior) { $prior.Profiles }) | Where-Object { $null -ne $_ -and $_.ProfileName -ceq $agent.ProfileName -and $_.BotUserID -ceq $identity.BotUserID -and $_.OwnsProfile -eq $true })
        $profileOwnership[[string]$agent.ProfileName] = ($previous.Count -eq 1 -and [bool]$ReuseExistingProfiles)
        if ((Test-Path -LiteralPath $dir) -and ($previous.Count -ne 1 -or -not $ReuseExistingProfiles)) { throw '다른 기존 프로필은 변경하지 않습니다.' }
        foreach ($target in @($dir, (Join-Path $dir '.env'), (Join-Path $dir 'SOUL.md'), (Join-Path $dir 'config.yaml'), (Join-Path $dir 'gateway.parked'))) {
            if (-not (Test-HermesSafeTargetPath -LiteralPath $target).Safe) { throw 'ResearchProfilePathRejected' }
        }
    }
    $migrationTasks = @()
    if ($null -ne $prior) { $migrationTasks = @(Get-HermesResearchMigrationTasks -Prior $prior -Paths $Paths -BrokerPlan $plan) }
    $environment = $(if ($UseExistingHermes) { $Runtime.Environment } else { New-HermesResearchEnvironment -HermesHome $Paths.HermesHome -InstallDir $Paths.InstallDir })
    $wizardPolicy = $null
    if ($null -ne $options) {
        $null = Assert-HermesResearchWizardOptions -Options $options -RuntimeRoot $Paths.RuntimeRoot
        $workspace = [IO.Path]::GetFullPath([string]$options.WorkspacePath)
        foreach ($protected in @($Paths.HermesHome,$Paths.InstallDir,$Paths.RuntimeRoot)) {
            if ($workspace -ieq $protected -or (Test-HermesPathContains -ParentPath $protected -ChildPath $workspace) -or (Test-HermesPathContains -ParentPath $workspace -ChildPath $protected)) { throw '작업 폴더는 Hermes 설치·인증·운영 설정 폴더와 분리하세요.' }
        }
        if (-not (Test-HermesSafeTargetPath -LiteralPath (Join-Path $workspace 'inputs')).Safe) { throw 'ResearchWorkspacePathRejected' }
        $humanID = Resolve-HermesResearchHuman -InputObject $InputObject
        $wizardPolicy = New-HermesResearchWizardPolicy -RuntimeRoot $Paths.RuntimeRoot -Options $options -ModelName $InputObject.ModelName -AllowedUserIDs @($humanID) -Agents $InputObject.Agents -Roles $InputObject.Roles
        New-Item -ItemType Directory -Path (Join-Path $workspace 'inputs') -Force | Out-Null
    }
    Protect-HermesResearchPrivateDirectory -LiteralPath $root -OwnerSID $owner
    $lock = $null
    try {
        $lock = [IO.File]::Open((Join-Path $root 'team.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if (($null -eq $prior -and (Test-Path -LiteralPath $statePath)) -or ($null -ne $prior -and (-not (Test-Path -LiteralPath $statePath) -or (ConvertTo-HermesSha256 -LiteralPath $statePath) -cne $priorHash))) { throw '사전 검사 이후 연구팀 상태가 바뀌었습니다. 다시 확인하세요.' }
        if ($null -ne $prior) {
            $brokerIdentity = Enter-HermesResearchMaintenance -ResearchRoot $root -Tasks $migrationTasks -BrokerPlan $plan -Python $python
            Assert-HermesResearchBrokerIdle -ResearchRoot $root -Python $python -Environment $environment
            $migrationBackup = Backup-HermesResearchMigration -Paths $Paths -Prior $prior -Tasks $migrationTasks
            Publish-HermesResearchStage $ProgressCallback 'research-migration' '기존 네 봇 설정을 백업했습니다. 대화·산출물 기록은 보존하고 기존 연구 서비스만 전환합니다.' 12
            Stop-HermesResearchMigrationTasks -Tasks $migrationTasks -BrokerIdentity $brokerIdentity
        }
        Install-HermesResearchBrokerFiles -ResearchRoot $root
        $policyPath = Get-HermesResearchPolicyPath $Paths.RuntimeRoot
        $policy = $(if ($null -ne $wizardPolicy) { $wizardPolicy } elseif (Test-Path -LiteralPath $policyPath) { Get-HermesResearchPolicy -RuntimeRoot $Paths.RuntimeRoot } else { New-HermesResearchPolicy -RuntimeRoot $Paths.RuntimeRoot -ModelName $InputObject.ModelName -Agents $InputObject.Agents -Roles $InputObject.Roles })
        $publicPolicyJson = $policy | ConvertTo-Json -Depth 15
        foreach ($agent in @($InputObject.Agents)) { if ($publicPolicyJson.Contains([string]$agent.BotToken)) { throw '운영 정책에 봇 토큰을 저장할 수 없습니다. 정책 파일을 확인하세요.' } }
        $template = New-HermesResearchPolicy -RuntimeRoot $Paths.RuntimeRoot -ModelName $InputObject.ModelName -Agents $InputObject.Agents -Roles $InputObject.Roles
        $policy = ConvertFrom-HermesResearchPolicyJson -Json ($policy | ConvertTo-Json -Depth 15)
        foreach ($persona in @($manifest.Personas)) {
            $name = [string]$persona.CanonicalName
            $binding = $template.roles[$name]
            $current = $policy.roles.$name
            $role = @($InputObject.Roles | Where-Object { $_.Id -ceq $persona.LegacyRoleId })[0]
            foreach ($key in @('profile_name','prompt_path','prompt_sha256')) { $current.$key = $binding[$key] }
            if ($null -eq $current.model -and $null -eq $current.provider) { $current.model = $InputObject.ModelName; $current.provider = 'openai-codex' }
            Write-HermesResearchAtomicText -LiteralPath $binding.prompt_path -Text ([string]$role.Instructions)
        }
        # Validate the complete candidate policy before native profile mutation.
        # Missing choices are holds; malformed permissions/paths are errors.
        $candidatePath = Join-Path $root ('policy-check-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            Write-HermesResearchAtomicText -LiteralPath $candidatePath -Text ($policy | ConvertTo-Json -Depth 15)
            $environment = $(if ($UseExistingHermes) { $Runtime.Environment } else { New-HermesResearchEnvironment -HermesHome $Paths.HermesHome -InstallDir $Paths.InstallDir })
            $preflight = Invoke-HermesProcess -FilePath $python -ArgumentList @('-I','-S','-B',(Join-Path $root 'engine\research_team\broker.py'),'check','--root',$root,'--config',$candidatePath) -Environment $environment -TimeoutSeconds 30
            if (-not $preflight.Started -or $preflight.TimedOut -or $preflight.ExitCode -ne 0) { throw 'ResearchPolicyPreflightFailed' }
            $status = $preflight.StdOut.Trim() | ConvertFrom-Json
            if ($status.prompts_verified -ne $true -or @($status.errors).Count -gt 0) { throw '운영 정책의 권한·경로·자료 접근 설정이 유효하지 않습니다. 프로필은 변경하지 않았습니다.' }
        } finally { if (Test-Path -LiteralPath $candidatePath -PathType Leaf) { Remove-Item -LiteralPath $candidatePath -Force } }
        foreach ($agent in @($InputObject.Agents)) {
            $profileDir = Join-Path $Paths.HermesHome ('profiles\' + $agent.ProfileName)
            if ((Test-Path -LiteralPath $profileDir) -and -not [bool]$profileOwnership[[string]$agent.ProfileName]) { throw '사전 확인 이후 다른 프로필이 생성되었습니다. 네 프로필 모두 변경하지 않았습니다.' }
            foreach ($target in @($profileDir, (Join-Path $profileDir 'SOUL.md'), (Join-Path $profileDir '.env'))) { if (-not (Test-HermesSafeTargetPath -LiteralPath $target).Safe) { throw 'ResearchProfilePathChanged' } }
        }
        $profiles = New-Object System.Collections.Generic.List[object]
        foreach ($persona in @($manifest.Personas)) {
            $agent = @($InputObject.Agents | Where-Object { $_.RoleId -ceq $persona.LegacyRoleId })[0]
            $identity = @($Identities | Where-Object { $_.ProfileName -ceq $agent.ProfileName })[0]
            $profileDir = Join-Path $Paths.HermesHome ('profiles\' + $agent.ProfileName)
            $binding = $template.roles[[string]$persona.CanonicalName]
            $profiles.Add([pscustomobject]@{ ProfileName = [string]$agent.ProfileName; DisplayName = [string]$agent.DisplayName; RoleId = [string]$agent.RoleId; CanonicalRole = [string]$persona.CanonicalName; BotUserID = [string]$identity.BotUserID; GatewayTask = $plan.TaskName; OwnsProfile = [bool]$profileOwnership[[string]$agent.ProfileName]; Status = 'Pending'; ErrorCode = $null; SystemInstructionsPath = (Join-Path $profileDir 'SOUL.md'); PromptPath = [string]$binding.prompt_path; PromptSha256 = [string]$binding.prompt_sha256 })
        }
        $state = [pscustomobject]@{ SchemaVersion = 1; Manager = 'HermesEasySetup.Research.v1'; ExecutionMode = 'GovernedBroker'; PersonaSourceVersion = $manifest.SourceVersion; RuntimeKind = $runtimeKind; OwnerSID = $owner; TeamID = $teamID; HermesHome = $Paths.HermesHome; InstallDir = $Paths.InstallDir; RuntimeRoot = $Paths.RuntimeRoot; ServerURL = $InputObject.ServerURL.TrimEnd('/'); HomeChannelID = $InputObject.HomeChannelID; ModelName = $InputObject.ModelName; WizardOptions = $options; MigrationBackupPath = $migrationBackup; UpdatedAt = ''; Profiles = $profiles.ToArray() }
        Save-HermesResearchTeamState -State $state -LiteralPath $statePath
        $privateBots = [ordered]@{}
        foreach ($persona in @($manifest.Personas)) {
            $agent = @($InputObject.Agents | Where-Object { $_.RoleId -ceq $persona.LegacyRoleId })[0]
            $identity = @($Identities | Where-Object { $_.ProfileName -ceq $agent.ProfileName })[0]
            $privateBots[[string]$persona.CanonicalName] = @{ token = [string]$agent.BotToken; user_id = [string]$identity.BotUserID; username = [string]$identity.BotUsername; display_name = [string]$agent.DisplayName }
        }
        # Persist all verified connections in the private ACL-protected store
        # before clearing native tokens, so interrupted migration can resume.
        $service = @{ schema_version = 1; hermes_home = $Paths.HermesHome; install_dir = $Paths.InstallDir; python = $python; server_url = $InputObject.ServerURL.TrimEnd('/'); channel_id = $InputObject.HomeChannelID; bots = $privateBots; messaging = @{ reply_in_thread = $true; bot_replies_require_mention = $true; bot_observers = @('manager') } }
        Write-HermesResearchAtomicText -LiteralPath (Join-Path $root 'private.json') -Text ($service | ConvertTo-Json -Depth 8)
        $completedRoleCount = 0
        $environment = $(if ($UseExistingHermes) { $Runtime.Environment } else { New-HermesResearchEnvironment -HermesHome $Paths.HermesHome -InstallDir $Paths.InstallDir })
        foreach ($persona in @($manifest.Personas)) {
            $agent = @($InputObject.Agents | Where-Object { $_.RoleId -ceq $persona.LegacyRoleId })[0]
            $role = @($InputObject.Roles | Where-Object { $_.Id -ceq $persona.LegacyRoleId })[0]
            $identity = @($Identities | Where-Object { $_.ProfileName -ceq $agent.ProfileName })[0]
            $profileDir = Join-Path $Paths.HermesHome ('profiles\' + $agent.ProfileName)
            $record = @($profiles | Where-Object { $_.ProfileName -ceq $agent.ProfileName })[0]
            Publish-HermesResearchStage $ProgressCallback 'research-profile' ("전체 지침·native Gateway 차단 설정: {0} ({1}/4)" -f $record.DisplayName, ($completedRoleCount + 1)) (15 + 18 * $completedRoleCount)
            if ((Test-Path -LiteralPath $profileDir) -and -not $record.OwnsProfile) { throw '사전 확인 이후 다른 프로필이 생성되었습니다. 해당 프로필은 변경하지 않습니다.' }
            if (-not (Test-Path -LiteralPath $profileDir)) { Invoke-HermesResearchCommand -CommandPath $CommandPath -Arguments @('profile','create',$agent.ProfileName,'--no-alias') -Environment $environment -TimeoutSeconds 180 }
            if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) { throw 'ResearchProfileCreateFailed' }
            $record.OwnsProfile = $true
            Save-HermesResearchTeamState -State $state -LiteralPath $statePath
            # The complete supplied text is the identity. No duplicate common block.
            Write-HermesResearchAtomicText -LiteralPath (Join-Path $profileDir 'SOUL.md') -Text ([string]$role.Instructions)
            $name = [string]$persona.CanonicalName
            $binding = $template.roles[$name]
            Write-HermesResearchAtomicText -LiteralPath $binding.prompt_path -Text ([string]$role.Instructions)
            if ($policy.roles -is [Collections.IDictionary]) { $current = $policy.roles[$name] } else { $current = $policy.roles.$name }
            foreach ($key in @('profile_name','prompt_path','prompt_sha256')) { $current.$key = $binding[$key] }
            if ($null -eq $current.model -and $null -eq $current.provider) { $current.model = $InputObject.ModelName; $current.provider = 'openai-codex' }
            # No native messaging token: a running root multiplexer cannot serve
            # these bots outside the policy broker or consume their model budget.
            Set-HermesResearchEnvFile -LiteralPath (Join-Path $profileDir '.env') -Values @{ MATTERMOST_TOKEN = ''; MATTERMOST_URL = '' }
            # Official modern Hermes parking marker keeps the selected profiles
            # out of a live root multiplexer and survives its later restart.
            Write-HermesResearchAtomicText -LiteralPath (Join-Path $profileDir 'gateway.parked') -Text 'Managed by the research workflow broker.'
            # One isolated roundtrip edit preserves unrelated YAML settings and
            # avoids starting the full native runtime once per platform.
            $isolation = Invoke-HermesProcess -FilePath $python -ArgumentList @('-I','-S','-B',(Join-Path $root 'engine\research_team\profile_config.py'),'--source',$Paths.InstallDir,'--profile',$profileDir) -Environment $environment -TimeoutSeconds 30
            if (-not $isolation.Started -or $isolation.TimedOut -or $isolation.ExitCode -ne 0) { throw 'ResearchNativeProfileIsolationFailed' }
            try { $isolated = $isolation.StdOut.Trim() | ConvertFrom-Json } catch { throw 'ResearchNativeProfileIsolationResponseRejected' }
            if ($isolated.isolated -ne $true -or [int]$isolated.platforms_disabled -lt 19) { throw 'ResearchNativeProfileIsolationIncomplete' }
            $record.Status = 'Configured'
            $completedRoleCount++
            Save-HermesResearchTeamState -State $state -LiteralPath $statePath
        }
        $null = Save-HermesResearchPolicy -RuntimeRoot $Paths.RuntimeRoot -Json ($policy | ConvertTo-Json -Depth 15)
        Save-HermesResearchTeamState -State $state -LiteralPath $statePath
        if ($null -ne $prior) { Confirm-HermesResearchNativeDetached -Paths $Paths -Python $python -Environment $environment -ProfileNames @($InputObject.Agents | ForEach-Object { $_.ProfileName }) }
        $check = Invoke-HermesProcess -FilePath $python -ArgumentList @('-I','-S','-B',(Join-Path $root 'engine\research_team\broker.py'),'check','--root',$root) -Environment $environment -TimeoutSeconds 30
        if (-not $check.Started -or $check.TimedOut -or $check.ExitCode -ne 0) { throw 'ResearchPolicyRuntimeCheckFailed' }
        try { $status = $check.StdOut.Trim() | ConvertFrom-Json } catch { throw 'ResearchPolicyCheckResponseRejected' }
        if ($status.prompts_verified -ne $true -or @($status.errors).Count -gt 0) { throw 'ResearchPersonaHashCheckFailed' }
        $workflowTest = [pscustomobject]@{ Passed = $false; Live = $false; RequestID = ''; Roles = @(); AuditPassed = $false; EvidencePath = ''; ErrorCode = 'PolicyNotReady' }
        if ($status.PSObject.Properties['configuration_ready'] -and $status.configuration_ready -eq $true) {
            Publish-HermesResearchStage $ProgressCallback 'research-live-test' '실제 모델·검색·원문 읽기로 총괄→조사→분석→감사→종합을 검증합니다. 몇 분 걸릴 수 있습니다.' 90
            $workflowTest = Invoke-HermesResearchLiveTest -ResearchRoot $root -Python $python -Environment $environment -UserID ([string]$policy.human.allowed_user_ids[0])
        }
        Register-HermesResearchBrokerTask -Plan $plan -Python $python -ResearchRoot $root -HasOwnership $ownedTask
        Publish-HermesResearchStage $ProgressCallback 'research-policy' '분업 테스트 결과와 연구 서비스의 실행 상태를 확인합니다.' 98
        # Incomplete policy installs safely but does not start model work.
        $startedAt = ([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
        Exit-HermesResearchMaintenance -ResearchRoot $root
        Start-HermesResearchGatewayTask -Plan $plan
        $status = Wait-HermesResearchBrokerReady -ResearchRoot $root -Python $python -StartedAt $startedAt
        $ready = [bool]$status.ready -and $workflowTest.Passed -and $workflowTest.Live
        $pending = @($status.pending_reasons)
        if (-not $workflowTest.Passed) { $pending += ('실제 분업 테스트 미통과: ' + $workflowTest.ErrorCode) }
        return [pscustomobject]@{ Succeeded = $ready; PartialSuccess = -not $ready; ExecutionReady = $ready; WorkflowTest = $workflowTest; ExecutionMode = 'GovernedBroker'; PendingSettings = $pending; Profiles = $profiles.ToArray(); StatePath = $statePath; PolicyPath = $policyPath; MigrationBackupPath = $migrationBackup; RuntimeKind = $runtimeKind; ExistingGatewayLifecyclePreserved = [bool]$UseExistingHermes; ServerURL = $InputObject.ServerURL; HomeChannelID = $InputObject.HomeChannelID; ModelName = $InputObject.ModelName }
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}
