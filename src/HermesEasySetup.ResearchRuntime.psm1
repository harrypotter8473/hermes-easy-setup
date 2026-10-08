Set-StrictMode -Version 2.0

$script:ResearchManager = 'HermesEasySetup.Research.v1'
$script:ResearchSoulStart = '<!-- HERMES EASY SETUP: MANAGED RESEARCH ROLE START -->'
$script:ResearchSoulEnd = '<!-- HERMES EASY SETUP: MANAGED RESEARCH ROLE END -->'
$script:ResearchGatewayReadyTimeoutSeconds = 60

function Publish-HermesResearchStage {
    param([AllowNull()][scriptblock]$Callback, [string]$Stage, [string]$Message, [int]$Percent, [string]$State = 'running')
    if ($null -ne $Callback) { [void](Publish-HermesEvent -Callback $Callback -Type 'stage' -Stage $Stage -State $State -Message $Message -Percent $Percent) }
}

function Invoke-HermesResearchMattermostAPI {
    param([string]$ServerURL, [string]$Path, [string]$Token)
    if ($Path -cnotmatch '^/api/v4/(users/me|channels/[a-z0-9]{26}(/members/[a-z0-9]{26})?)$') { throw 'ResearchApiPathRejected' }
    try {
        $response = Invoke-WebRequest -Uri ($ServerURL.TrimEnd('/') + $Path) -Method GET -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0 -Headers @{ Authorization = 'Bearer ' + $Token } -ErrorAction Stop
        if ([int]$response.StatusCode -ne 200) { throw 'UnexpectedStatus' }
        return ($response.Content | ConvertFrom-Json)
    } catch {
        # Remote errors and response bodies can reflect Authorization headers.
        throw '로컬 Mattermost 연결 검사에 실패했습니다. 서버·봇 토큰·채널 권한을 확인하세요.'
    }
}

function Test-HermesResearchTeamConnection {
    param([Parameter(Mandatory = $true)]$InputObject)
    $identities = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($agent in @($InputObject.Agents)) {
        try {
            $me = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path '/api/v4/users/me' -Token $agent.BotToken
            if ($me.is_bot -isnot [bool] -or -not $me.is_bot -or $me.delete_at -ne 0 -or $me.roles -cne 'system_user' -or $me.id -cnotmatch '^[a-z0-9]{26}$') { throw 'InvalidBot' }
            if ($seen.ContainsKey([string]$me.id)) { throw 'DuplicateBot' }
            $channel = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ("/api/v4/channels/$($InputObject.HomeChannelID)") -Token $agent.BotToken
            if ($channel.id -cne $InputObject.HomeChannelID -or $channel.delete_at -ne 0 -or $channel.type -cnotin @('O', 'P') -or $channel.team_id -cnotmatch '^[a-z0-9]{26}$') { throw 'InvalidChannel' }
            $member = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ("/api/v4/channels/$($InputObject.HomeChannelID)/members/$($me.id)") -Token $agent.BotToken
            if ($member.user_id -cne $me.id -or $member.channel_id -cne $InputObject.HomeChannelID) { throw 'InvalidMembership' }
            $seen[[string]$me.id] = $true
            $identities.Add([pscustomobject]@{ ProfileName = [string]$agent.ProfileName; BotUserID = [string]$me.id })
        } catch {
            throw '서로 다른 활성 일반 봇 4개와 홈 채널 접근·멤버십을 모두 확인해야 합니다.'
        }
    }
    return $identities.ToArray()
}

function Merge-HermesResearchSoul {
    param([AllowNull()][string]$Existing, [string]$DisplayName, [Parameter(Mandatory = $true)]$Role)
    $managed = @($script:ResearchSoulStart, '# Research team identity and role', '', ('Your name is {0}.' -f $DisplayName), ('Assigned role: {0} ({1})' -f $Role.Name, $Role.Id), '', [string]$Role.Instructions, '', 'Follow these managed identity and role instructions while preserving the existing profile memory and conversation history.', $script:ResearchSoulEnd) -join [Environment]::NewLine
    $remaining = [string]$Existing
    $starts = [regex]::Matches($remaining, [regex]::Escape($script:ResearchSoulStart))
    $ends = [regex]::Matches($remaining, [regex]::Escape($script:ResearchSoulEnd))
    if ($starts.Count -ne $ends.Count -or $starts.Count -gt 1 -or ($starts.Count -eq 1 -and $ends[0].Index -lt $starts[0].Index)) { throw 'ResearchSoulManagedBlockMalformed' }
    if ($starts.Count -eq 1) {
        $after = $ends[0].Index + $script:ResearchSoulEnd.Length
        return $remaining.Substring(0, $starts[0].Index) + $managed + $remaining.Substring($after)
    }
    if ($remaining.Length -gt 0 -and -not $remaining.EndsWith("`n")) { $remaining += [Environment]::NewLine }
    return $remaining + $managed + [Environment]::NewLine
}

function Write-HermesResearchAtomicText {
    param([string]$LiteralPath, [AllowEmptyString()][string]$Text, [switch]$ByteOrderMark)
    $safe = Test-HermesSafeTargetPath -LiteralPath $LiteralPath -Label 'research file'
    if (-not $safe.Safe) { throw 'ResearchUnsafeFilePath' }
    $parent = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    $temporary = $LiteralPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding([bool]$ByteOrderMark)))
        if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) { [System.IO.File]::Replace($temporary, $LiteralPath, [System.Management.Automation.Language.NullString]::Value, $true) }
        else { [System.IO.File]::Move($temporary, $LiteralPath) }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Set-HermesResearchEnvFile {
    param([string]$LiteralPath, [hashtable]$Values)
    $kept = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadAllLines($LiteralPath, [Text.Encoding]::UTF8)) {
            if ($line -match '^\s*(MATTERMOST_|SLACK_|DISCORD_|TELEGRAM_|WHATSAPP_|SIGNAL_|IMESSAGE_|MATRIX_)[A-Za-z0-9_]*\s*=') { continue }
            if ($line -ceq '# Managed by Hermes Easy Setup research integration') { continue }
            $kept.Add($line)
        }
    }
    $kept.Add('# Managed by Hermes Easy Setup research integration')
    foreach ($key in @($Values.Keys | Sort-Object)) { $kept.Add(('{0}={1}' -f $key, [string]$Values[$key])) }
    Write-HermesResearchAtomicText -LiteralPath $LiteralPath -Text (($kept.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)
}

function New-HermesResearchEnvironment {
    param([string]$HermesHome, [string]$InstallDir)
    $environment = Get-HermesCuratedProcessEnvironment
    $environment['HERMES_HOME'] = $HermesHome
    $environment['VIRTUAL_ENV'] = Join-Path $InstallDir 'venv'
    foreach ($key in @('PYTHONHOME', 'PYTHONPATH', 'PYTHONUSERBASE', 'PYTHONSTARTUP', 'PYTHONINSPECT')) { $environment[$key] = $null }
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONSAFEPATH'] = '1'
    return $environment
}

function Invoke-HermesResearchCommand {
    param([string]$CommandPath, [string[]]$Arguments, [hashtable]$Environment, [int]$TimeoutSeconds = 90)
    try {
        $result = Invoke-HermesProcess -FilePath $CommandPath -ArgumentList $Arguments -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'CommandFailed' }
    } catch { throw 'ResearchHermesCommandFailed' }
    # Never return subprocess output: profile commands may expose local secrets.
}

function Get-HermesResearchCurrentUserSID { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Get-HermesResearchGatewayTask {
    param([string]$TaskName)
    # Listing with Stop distinguishes access failures from a missing task.
    return @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -ceq $TaskName })
}

function Get-HermesResearchTaskPlan {
    param([string]$ProfileName, [string]$HermesHome, [string]$RuntimeRoot, [string]$OwnerSID, [string]$TeamID, [string]$PowerShellPath)
    $suffix = (ConvertTo-HermesSha256 -Text ($OwnerSID + '|' + $HermesHome.ToLowerInvariant())).Substring(0, 12)
    $runner = Join-Path (Join-Path (Join-Path $RuntimeRoot 'research\services') $ProfileName) 'Start-Gateway.ps1'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (ConvertTo-WindowsProcessArgument -Argument $runner)
    return [pscustomobject]@{ TaskName = "Hermes Research $suffix - $ProfileName"; RunnerPath = $runner; Execute = $PowerShellPath; Arguments = $arguments; OwnerSID = $OwnerSID; Description = "$($script:ResearchManager); owner=$TeamID; profile=$ProfileName" }
}

function Assert-HermesResearchOwnedTask {
    param($Task, [Parameter(Mandatory = $true)]$Plan, [bool]$HasOwnership)
    if ($null -eq $Task) { return }
    try {
        $actions = @($Task.Actions)
        if (-not $HasOwnership -or $Task.Description -cne $Plan.Description -or $actions.Count -ne 1 -or
            -not [string]::Equals([string]$actions[0].Execute, [string]$Plan.Execute, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$actions[0].Arguments -cne $Plan.Arguments -or $Task.Principal.UserId -cne $Plan.OwnerSID -or
            [string]$Task.Principal.LogonType -cnotin @('Interactive', 'InteractiveToken', '3') -or [string]$Task.Principal.RunLevel -cnotin @('Limited', '0')) { throw 'ForeignTask' }
    } catch { throw '기존 예약 작업의 소유권을 확인할 수 없습니다. 다른 작업은 덮어쓰지 않습니다.' }
}

function Register-HermesResearchGatewayTask {
    param($Plan, [string]$CommandPath, [string]$HermesHome, [string]$InstallDir, [string]$ProfileName, [bool]$HasOwnership)
    $existing = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
    if ($existing.Count -gt 1) { throw 'ResearchTaskCollision' }
    if ($existing.Count -eq 1) {
        Assert-HermesResearchOwnedTask -Task $existing[0] -Plan $Plan -HasOwnership $HasOwnership
        if ([string]$existing[0].State -eq 'Running') {
            Stop-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop
            $deadline = (Get-Date).AddSeconds(20)
            do {
                $task = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
                if ($task.Count -eq 1 -and [string]$task[0].State -ne 'Running') { break }
                Start-Sleep -Milliseconds 250
            } while ((Get-Date) -lt $deadline)
            if ($task.Count -ne 1 -or [string]$task[0].State -eq 'Running') { throw 'ResearchTaskStopTimeout' }
        }
    }
    $quote = { param([string]$Text) return "'" + $Text.Replace("'", "''") + "'" }
    $runner = @(
        '$ErrorActionPreference = ''Stop'''
        ('$env:HERMES_HOME = {0}' -f (& $quote $HermesHome))
        ('$env:VIRTUAL_ENV = {0}' -f (& $quote (Join-Path $InstallDir 'venv')))
        '$env:PYTHONHOME = $null; $env:PYTHONPATH = $null; $env:PYTHONUSERBASE = $null; $env:PYTHONSTARTUP = $null; $env:PYTHONINSPECT = $null'
        '$env:PYTHONNOUSERSITE = ''1''; $env:PYTHONSAFEPATH = ''1'''
        '$env:GIT_CONFIG_COUNT = ''1''; $env:GIT_CONFIG_KEY_0 = ''safe.directory'''
        ('$env:GIT_CONFIG_VALUE_0 = {0}' -f (& $quote $InstallDir))
        ('& {0} -p {1} gateway run --replace' -f (& $quote $CommandPath), (& $quote $ProfileName))
        'exit $LASTEXITCODE'
    ) -join [Environment]::NewLine
    Write-HermesResearchAtomicText -LiteralPath $Plan.RunnerPath -Text ($runner + [Environment]::NewLine) -ByteOrderMark
    $action = New-ScheduledTaskAction -Execute $Plan.Execute -Argument $Plan.Arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Plan.OwnerSID
    $principal = New-ScheduledTaskPrincipal -UserId $Plan.OwnerSID -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1)) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $Plan.Description
    Register-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -InputObject $task -Force:($existing.Count -eq 1) -ErrorAction Stop | Out-Null
}

function Start-HermesResearchGatewayTask {
    param($Plan)
    Start-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $tasks = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
        if ($tasks.Count -eq 1 -and [string]$tasks[0].State -eq 'Running') { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'ResearchGatewayStartTimeout'
}

function Wait-HermesResearchGatewayReady {
    param([string]$CommandPath, [string]$ProfileName, [hashtable]$Environment, $Plan, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $result = Invoke-HermesProcess -FilePath $CommandPath -ArgumentList @('-p', $ProfileName, 'gateway', 'status') -Environment $Environment -TimeoutSeconds 15
            if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'GatewayStatusCommandFailed' }
            $text = [regex]::Replace([string]$result.StdOut, '\x1B\[[0-?]*[ -/]*[@-~]', '')
            # Pinned fcbd107 gateway.py/gateway_windows.py report PID-bearing
            # positive lines; stopped status also exits 0 and is insufficient.
            $positive = ($text -match '(?m)^\s*[\u2713\u2714]?\s*Gateway (?:is running|process running) \(PID: [1-9][0-9]*(?:,\s*[1-9][0-9]*)*\)\s*$')
            $negative = ($text -match '(?i)Gateway is not running|No gateway process detected')
            $tasks = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
            if ($positive -and -not $negative -and $tasks.Count -eq 1 -and [string]$tasks[0].State -eq 'Running') {
                Assert-HermesResearchOwnedTask -Task $tasks[0] -Plan $Plan -HasOwnership $true
                return
            }
        } catch { throw 'ResearchGatewayStatusFailed' }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw 'ResearchGatewayNotRunning'
}

function Save-HermesResearchTeamState {
    param($State, [string]$LiteralPath)
    $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-HermesResearchAtomicText -LiteralPath $LiteralPath -Text (($State | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Invoke-HermesResearchTeamSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [AllowNull()][scriptblock]$ProgressCallback,
        [switch]$ReuseExistingProfiles
    )
    try { $summary = Assert-HermesResearchTeamInput -InputObject $InputObject } catch { throw '연구팀 입력 형식이 올바르지 않습니다. 역할·프로필·봇 토큰·로컬 서버 주소를 확인하세요.' }
    $normalizedAgents = @($summary.Agents | ForEach-Object {
        $safeAgent = $_
        $sourceAgent = @($InputObject.Agents | Where-Object { $_.ProfileName -ceq $safeAgent.ProfileName })[0]
        [pscustomobject]@{ ProfileName = $safeAgent.ProfileName; DisplayName = $safeAgent.DisplayName; RoleId = $safeAgent.RoleId; BotToken = [string]$sourceAgent.BotToken }
    })
    $InputObject = [pscustomobject]@{ SchemaVersion = 1; ServerURL = $summary.ServerURL; HomeChannelID = $summary.HomeChannelID; ModelName = $summary.ModelName; Roles = $summary.Roles; Agents = $normalizedAgents }
    $serverUri = [Uri]$InputObject.ServerURL
    $loopbackIP = $null
    $isLoopback = ($serverUri.DnsSafeHost -ieq 'localhost')
    if ([Net.IPAddress]::TryParse($serverUri.DnsSafeHost.Trim('[', ']'), [ref]$loopbackIP)) { $isLoopback = [Net.IPAddress]::IsLoopback($loopbackIP) }
    if (-not $isLoopback) { throw '1인 연구팀은 로컬 loopback Mattermost 서버만 사용할 수 있습니다.' }
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    # Disallow accidentally copying a known token into public metadata or argv.
    $publicText = (@($paths.HermesHome, $paths.InstallDir, $paths.RuntimeRoot, $InputObject.ServerURL, $InputObject.HomeChannelID, $InputObject.ModelName) + @($InputObject.Agents | ForEach-Object { $_.ProfileName; $_.DisplayName; $_.RoleId }) + @($InputObject.Roles | ForEach-Object { $_.Id; $_.Name; $_.Instructions })) -join "`n"
    foreach ($agent in @($InputObject.Agents)) { if ($publicText.Contains([string]$agent.BotToken)) { throw '봇 토큰을 이름·역할·경로·기타 공개 설정에 넣을 수 없습니다.' } }
    foreach ($path in @($paths.HermesHome, $paths.InstallDir, $paths.RuntimeRoot)) { if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe) { throw '연구팀 경로가 안전하지 않습니다.' } }
    if ((Test-HermesPathContains -ParentPath $paths.HermesHome -ChildPath $paths.RuntimeRoot) -or (Test-HermesPathContains -ParentPath $paths.RuntimeRoot -ChildPath $paths.HermesHome) -or (Test-HermesPathContains -ParentPath $paths.InstallDir -ChildPath $paths.RuntimeRoot) -or (Test-HermesPathContains -ParentPath $paths.RuntimeRoot -ChildPath $paths.InstallDir)) { throw 'RuntimeRoot는 Hermes 데이터·설치 경로와 분리되어야 합니다.' }
    Publish-HermesResearchStage $ProgressCallback 'research-verify' 'Hermes 설치와 기존 OpenAI Codex 인증을 확인합니다.' 5
    $verificationLog = Join-Path ([System.IO.Path]::GetTempPath()) ('hermes-research-verify-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -LogPath $verificationLog
    } catch { throw '검증된 Hermes 설치가 필요합니다.' }
    finally { if (Test-Path -LiteralPath $verificationLog -PathType Leaf) { Remove-Item -LiteralPath $verificationLog -Force -ErrorAction SilentlyContinue } }
    $expectedCommand = [IO.Path]::GetFullPath((Join-Path $paths.InstallDir 'bin\hermes.exe'))
    if ($verification.Verified -isnot [bool] -or -not $verification.Verified -or -not [string]::Equals([string]$verification.CommandPath, $expectedCommand, [StringComparison]::OrdinalIgnoreCase)) { throw '검증된 Hermes 설치가 필요합니다.' }
    try { $codex = Get-HermesCodexStatus -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot } catch { throw 'OpenAI Codex 인증 확인에 실패했습니다.' }
    if ($codex.LoggedIn -isnot [bool] -or -not $codex.LoggedIn) { throw 'OpenAI Codex 로그인을 먼저 완료하세요.' }
    if (@($codex.Models) -cnotcontains [string]$InputObject.ModelName) { throw '선택한 OpenAI Codex 모델을 기존 인증에서 확인할 수 없습니다.' }
    Publish-HermesResearchStage $ProgressCallback 'research-connection' '서로 다른 봇 4개와 홈 채널 멤버십을 변경 전에 확인합니다.' 10
    $identities = @(Test-HermesResearchTeamConnection -InputObject $InputObject)
    $ownerSID = Get-HermesResearchCurrentUserSID
    $powerShell = Get-HermesPowerShellExecutable
    $statePath = Join-Path $paths.RuntimeRoot 'research\team.json'
    if (-not (Test-HermesSafeTargetPath -LiteralPath $statePath).Safe) { throw '연구팀 상태 파일 경로가 안전하지 않습니다.' }
    $prior = $null
    $priorStateHash = $null
    if (Test-Path -LiteralPath $statePath) {
        if (-not $ReuseExistingProfiles) { throw '기존 연구팀 상태가 있습니다. 명시적으로 기존 프로필 재사용을 선택하세요.' }
        try {
            $priorStateHash = ConvertTo-HermesSha256 -LiteralPath $statePath
            $prior = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($prior.Manager -cne $script:ResearchManager -or $prior.SchemaVersion -ne 1 -or $prior.OwnerSID -cne $ownerSID -or $prior.TeamID -cnotmatch '^[a-f0-9]{32}$' -or
                -not [string]::Equals([string]$prior.HermesHome, [string]$paths.HermesHome, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$prior.InstallDir, [string]$paths.InstallDir, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$prior.RuntimeRoot, [string]$paths.RuntimeRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $prior.ServerURL -cne $InputObject.ServerURL.TrimEnd('/') -or $prior.HomeChannelID -cne $InputObject.HomeChannelID -or @($prior.Profiles).Count -ne 4) { throw 'InvalidOwnership' }
            $priorNames = @($prior.Profiles | ForEach-Object {
                if ($_.OwnsProfile -isnot [bool] -or $_.BotUserID -cnotmatch '^[a-z0-9]{26}$') { throw 'InvalidProfileOwnership' }
                [string]$_.ProfileName
            })
            if (@($priorNames | Select-Object -Unique).Count -ne 4 -or @($priorNames | Where-Object { @($InputObject.Agents.ProfileName) -cnotcontains $_ }).Count -gt 0) { throw 'InvalidProfileOwnership' }
        } catch { throw '기존 연구팀 상태의 소유권을 확인할 수 없습니다.' }
    }
    $teamID = $(if ($null -ne $prior) { [string]$prior.TeamID } else { [guid]::NewGuid().ToString('N') })
    $records = New-Object System.Collections.Generic.List[object]
    $plans = @{}
    foreach ($agent in @($InputObject.Agents)) {
        $profileDir = Join-Path (Join-Path $paths.HermesHome 'profiles') $agent.ProfileName
        $identity = @($identities | Where-Object { $_.ProfileName -ceq $agent.ProfileName })[0]
        $old = @($(if ($null -ne $prior) { $prior.Profiles }) | Where-Object { $null -ne $_ -and $_.ProfileName -ceq $agent.ProfileName })
        $owned = ($old.Count -eq 1 -and $old[0].OwnsProfile -is [bool] -and $old[0].OwnsProfile -and $old[0].BotUserID -ceq $identity.BotUserID)
        if ($old.Count -gt 1 -or ($old.Count -eq 1 -and $old[0].BotUserID -cne $identity.BotUserID)) { throw '기존 프로필의 봇 소유권이 다릅니다.' }
        if ((Test-Path -LiteralPath $profileDir) -and (-not $ReuseExistingProfiles -or -not $owned -or -not (Test-Path -LiteralPath $profileDir -PathType Container))) { throw '기존 프로필은 이 연구팀에서 생성한 프로필만 명시적으로 재사용할 수 있습니다.' }
        $plan = Get-HermesResearchTaskPlan -ProfileName $agent.ProfileName -HermesHome $paths.HermesHome -RuntimeRoot $paths.RuntimeRoot -OwnerSID $ownerSID -TeamID $teamID -PowerShellPath $powerShell
        $plans[[string]$agent.ProfileName] = $plan
        foreach ($target in @($profileDir, (Join-Path $profileDir '.env'), (Join-Path $profileDir 'SOUL.md'), $plan.RunnerPath)) { if (-not (Test-HermesSafeTargetPath -LiteralPath $target).Safe) { throw '연구팀 프로필·서비스 파일 경로가 안전하지 않습니다.' } }
        $task = @(Get-HermesResearchGatewayTask -TaskName $plan.TaskName)
        if ($task.Count -gt 1) { throw '연구팀 예약 작업 이름이 충돌합니다.' }
        if ($task.Count -eq 1) { Assert-HermesResearchOwnedTask -Task $task[0] -Plan $plan -HasOwnership $owned }
        $role = @($InputObject.Roles | Where-Object { $_.Id -ceq $agent.RoleId })[0]
        if ([string]$role.Instructions -match 'HERMES EASY SETUP: MANAGED RESEARCH ROLE (START|END)') { throw '역할 지시문에 관리 블록 표식을 사용할 수 없습니다.' }
        $soulPath = Join-Path $profileDir 'SOUL.md'
        $existingSoul = $(if (Test-Path -LiteralPath $soulPath -PathType Leaf) { [IO.File]::ReadAllText($soulPath, [Text.Encoding]::UTF8) } else { '' })
        $null = Merge-HermesResearchSoul -Existing $existingSoul -DisplayName $agent.DisplayName -Role $role
        $records.Add([pscustomobject][ordered]@{ ProfileName = [string]$agent.ProfileName; DisplayName = [string]$agent.DisplayName; RoleId = [string]$agent.RoleId; BotUserID = [string]$identity.BotUserID; GatewayTask = [string]$plan.TaskName; OwnsProfile = [bool]$owned; Status = 'Pending'; ErrorCode = $null })
    }
    $state = [pscustomobject][ordered]@{ SchemaVersion = 1; Manager = $script:ResearchManager; OwnerSID = $ownerSID; TeamID = $teamID; HermesHome = $paths.HermesHome; InstallDir = $paths.InstallDir; RuntimeRoot = $paths.RuntimeRoot; ServerURL = $InputObject.ServerURL.TrimEnd('/'); HomeChannelID = [string]$InputObject.HomeChannelID; ModelName = [string]$InputObject.ModelName; UpdatedAt = ''; Profiles = $records.ToArray() }
    $environment = New-HermesResearchEnvironment -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    # A per-team lock serializes state commits and profile mutation. It is acquired
    # only after all auth, remote membership, and foreign ownership checks pass.
    $lockDir = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $lockDir -PathType Container)) { New-Item -ItemType Directory -Path $lockDir -Force -ErrorAction Stop | Out-Null }
    $lockPath = Join-Path $lockDir 'team.lock'
    $lock = $null
    try {
        try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { throw '연구팀 설정이 이미 실행 중이거나 잠금 파일에 접근할 수 없습니다.' }
        if (($null -eq $prior -and (Test-Path -LiteralPath $statePath)) -or
            ($null -ne $prior -and (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -or (ConvertTo-HermesSha256 -LiteralPath $statePath) -cne $priorStateHash))) { throw '사전 검사 이후 연구팀 상태가 바뀌었습니다. 다시 검증하세요.' }
        Save-HermesResearchTeamState -State $state -LiteralPath $statePath
        for ($index = 0; $index -lt $records.Count; $index++) {
            $record = $records[$index]
            $agent = @($InputObject.Agents | Where-Object { $_.ProfileName -ceq $record.ProfileName })[0]
            $role = @($InputObject.Roles | Where-Object { $_.Id -ceq $agent.RoleId })[0]
            $profileDir = Join-Path (Join-Path $paths.HermesHome 'profiles') $record.ProfileName
            $code = 'ProfileCreateFailed'
            Publish-HermesResearchStage $ProgressCallback 'research-profile' ("프로필 {0}/4 설정: {1}" -f ($index + 1), $record.ProfileName) (15 + 20 * $index)
            try {
                if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
                    Invoke-HermesResearchCommand -CommandPath $expectedCommand -Arguments @('profile', 'create', $record.ProfileName) -Environment $environment -TimeoutSeconds 180
                    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) { throw 'ProfileMissing' }
                    $record.OwnsProfile = $true
                    Save-HermesResearchTeamState -State $state -LiteralPath $statePath
                } elseif (-not $record.OwnsProfile) { throw 'ProfileAppearedAfterPreflight' }
                $code = 'RoleApplyFailed'
                $soulPath = Join-Path $profileDir 'SOUL.md'
                $existingSoul = $(if (Test-Path -LiteralPath $soulPath -PathType Leaf) { [IO.File]::ReadAllText($soulPath, [Text.Encoding]::UTF8) } else { '' })
                Write-HermesResearchAtomicText -LiteralPath $soulPath -Text (Merge-HermesResearchSoul -Existing $existingSoul -DisplayName $record.DisplayName -Role $role)
                $code = 'ModelConfigureFailed'
                foreach ($setting in @(@('model.provider', 'openai-codex'), @('model.default', [string]$InputObject.ModelName), @('terminal.backend', 'local'), @('display.tool_progress', 'log'), @('compression.threshold', '0.85'), @('session_reset.mode', 'none'))) {
                    Invoke-HermesResearchCommand -CommandPath $expectedCommand -Arguments @('-p', $record.ProfileName, 'config', 'set', [string]$setting[0], [string]$setting[1]) -Environment $environment
                }
                $code = 'MattermostConfigureFailed'
                Set-HermesResearchEnvFile -LiteralPath (Join-Path $profileDir '.env') -Values @{ MATTERMOST_URL = $state.ServerURL; MATTERMOST_TOKEN = [string]$agent.BotToken; MATTERMOST_HOME_CHANNEL = $state.HomeChannelID; MATTERMOST_ALLOWED_USERS = ''; MATTERMOST_ALLOW_ALL_USERS = 'true'; MATTERMOST_REQUIRE_MENTION = 'true'; MATTERMOST_FREE_RESPONSE_CHANNELS = ''; MATTERMOST_REPLY_MODE = 'off' }
                $code = 'GatewayRegisterFailed'
                Register-HermesResearchGatewayTask -Plan $plans[$record.ProfileName] -CommandPath $expectedCommand -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -ProfileName $record.ProfileName -HasOwnership $record.OwnsProfile
                $code = 'GatewayStartFailed'
                Start-HermesResearchGatewayTask -Plan $plans[$record.ProfileName]
                $code = 'GatewayStatusFailed'
                Wait-HermesResearchGatewayReady -CommandPath $expectedCommand -ProfileName $record.ProfileName -Environment $environment -Plan $plans[$record.ProfileName] -TimeoutSeconds $script:ResearchGatewayReadyTimeoutSeconds
                $record.Status = 'Succeeded'
                $record.ErrorCode = $null
            } catch {
                $record.Status = 'Failed'
                $record.ErrorCode = $code
                Publish-HermesResearchStage $ProgressCallback 'research-profile' ("프로필 설정 실패: {0} ({1})" -f $record.ProfileName, $code) (30 + 20 * $index) 'failed'
            }
            Save-HermesResearchTeamState -State $state -LiteralPath $statePath
        }
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
    $successes = @($records | Where-Object { $_.Status -ceq 'Succeeded' }).Count
    $resultProfiles = @($records | Select-Object ProfileName, DisplayName, RoleId, BotUserID, GatewayTask, Status, ErrorCode)
    return [pscustomobject][ordered]@{ Succeeded = ($successes -eq 4); PartialSuccess = ($successes -gt 0 -and $successes -lt 4); Profiles = $resultProfiles; StatePath = $statePath; ServerURL = $state.ServerURL; HomeChannelID = $state.HomeChannelID; ModelName = $state.ModelName }
}

Export-ModuleMember -Function @('Invoke-HermesResearchTeamSetup')
