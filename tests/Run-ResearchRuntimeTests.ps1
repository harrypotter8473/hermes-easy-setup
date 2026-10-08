[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Research.psm1') -Force
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.ResearchRuntime.psm1') -Force

& (Get-Module HermesEasySetup.ResearchRuntime) {
    $script:passed = 0
    function Assert { param($Ok, $Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject { param([scriptblock]$Block, $Name) $failed = $false; try { & $Block | Out-Null } catch { $failed = $true }; Assert $failed $Name }
    $script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-research-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:fixtureRoot | Out-Null
    $script:tasks = @{}
    $script:commands = New-Object System.Collections.Generic.List[object]
    $script:requests = New-Object System.Collections.Generic.List[object]
    $script:events = New-Object System.Collections.Generic.List[object]
    $script:loggedIn = $true
    $script:verified = $true
    $script:duplicateBot = $false
    $script:failProfile = ''
    $script:rawHTTPFailure = $false
    $script:stoppedProfile = ''
    $script:exitAfterStatusProfile = ''
    $script:ResearchGatewayReadyTimeoutSeconds = 0
    $script:secret = 'a' * 26
    $script:input = [pscustomobject]@{
        SchemaVersion = 1; ServerURL = 'http://127.0.0.1:8065/'; HomeChannelID = 'c' * 26; ModelName = 'gpt-5.6-terra'
        Roles = @(Get-HermesResearchRoles)
        Agents = @(
            [pscustomobject]@{ ProfileName = 'research-lead'; DisplayName = 'Lead'; RoleId = 'planner'; BotToken = 'a' * 26 }
            [pscustomobject]@{ ProfileName = 'research-scout'; DisplayName = 'Scout'; RoleId = 'researcher'; BotToken = 'b' * 26 }
            [pscustomobject]@{ ProfileName = 'research-worker'; DisplayName = 'Worker'; RoleId = 'executor'; BotToken = 'd' * 26 }
            [pscustomobject]@{ ProfileName = 'research-reviewer'; DisplayName = 'Reviewer'; RoleId = 'reviewer'; BotToken = 'e' * 26 }
        )
    }
    # Every external boundary is mocked. No install, provider, REST, or task call
    # can reach the live Windows environment from this suite.
    function script:Test-HermesInstallation {
        param($HermesHome, $InstallDir, $RuntimeRoot, $LogPath)
        return [pscustomobject]@{ Verified = $script:verified; CommandPath = (Join-Path $InstallDir 'bin\hermes.exe') }
    }
    function script:Get-HermesCodexStatus {
        param($HermesHome, $InstallDir, $RuntimeRoot)
        return [pscustomobject]@{ LoggedIn = $script:loggedIn; Models = @('gpt-5.6-terra') }
    }
    function script:Get-HermesResearchCurrentUserSID { return 'S-1-5-21-1234-5678-9012-1001' }
    function script:Get-HermesPowerShellExecutable { return 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    function script:Get-HermesCuratedProcessEnvironment {
        return @{ PATH = 'C:\Windows\System32'; SystemRoot = 'C:\Windows'; TEMP = $script:fixtureRoot; TMP = $script:fixtureRoot; __HERMES_EASY_SETUP_REPLACE_ENVIRONMENT = '1' }
    }
    function script:Invoke-WebRequest {
        param($Uri, $Method, [switch]$UseBasicParsing, $TimeoutSec, $MaximumRedirection, $Headers, $ErrorAction)
        $script:requests.Add([pscustomobject]@{ Uri = $Uri; MaximumRedirection = $MaximumRedirection; Authorization = $Headers.Authorization })
        if ($script:rawHTTPFailure) { throw (New-Object Exception ('request failed ' + $script:secret)) }
        $letter = $Headers.Authorization.Substring(7, 1)
        $botID = ('u' + ($letter * 25))
        if ($script:duplicateBot) { $botID = 'u' + ('a' * 25) }
        if ($Uri -like '*/users/me') { $body = @{ id = $botID; username = 'fixture'; is_bot = $true; roles = 'system_user'; delete_at = 0 } }
        elseif ($Uri -like '*/members/*') { $body = @{ user_id = $botID; channel_id = 'c' * 26 } }
        else { $body = @{ id = 'c' * 26; team_id = 't' * 26; name = 'research'; type = 'O'; delete_at = 0 } }
        return @{ StatusCode = 200; Content = ($body | ConvertTo-Json -Compress) }
    }
    function script:Invoke-HermesProcess {
        param($FilePath, $ArgumentList, $Environment, $TimeoutSeconds)
        $script:commands.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($ArgumentList); Environment = $Environment })
        if ($ArgumentList[0] -ceq 'profile') {
            $profileDir = Join-Path (Join-Path $Environment.HERMES_HOME 'profiles') $ArgumentList[2]
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $profileDir 'SOUL.md'), "Personal instructions to preserve.`n", (New-Object Text.UTF8Encoding($false)))
        }
        if ($ArgumentList.Count -ge 4 -and $ArgumentList[0] -ceq '-p' -and $ArgumentList[1] -ceq $script:failProfile -and $ArgumentList[2] -ceq 'gateway') {
            throw (New-Object Exception ('subprocess reflected ' + $script:secret))
        }
        $stdout = $script:secret
        if ($ArgumentList.Count -ge 4 -and $ArgumentList[2] -ceq 'gateway' -and $ArgumentList[3] -ceq 'status') {
            $stdout = "Gateway is running (PID: 1234)`n" + $script:secret
            if ($ArgumentList[1] -ceq $script:stoppedProfile) { $stdout = 'Gateway is not running' }
            if ($ArgumentList[1] -ceq $script:exitAfterStatusProfile) {
                foreach ($task in @($script:tasks.Values | Where-Object { $_.TaskName.EndsWith($script:exitAfterStatusProfile) })) { $task.State = 'Ready' }
            }
        }
        return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; StdOut = $stdout; StdErr = $script:secret }
    }
    function script:Get-ScheduledTask { param($TaskPath, $ErrorAction) return @($script:tasks.Values) }
    function script:New-ScheduledTaskAction { param($Execute, $Argument) return [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
    function script:New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User) return [pscustomobject]@{ AtLogOn = [bool]$AtLogOn; User = $User } }
    function script:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
    function script:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $RestartCount, $RestartInterval, $ExecutionTimeLimit, $MultipleInstances) return [pscustomobject]@{ MultipleInstances = $MultipleInstances } }
    function script:New-ScheduledTask { param($Action, $Trigger, $Principal, $Settings, $Description) return [pscustomobject]@{ Actions = @($Action); Triggers = @($Trigger); Principal = $Principal; Settings = $Settings; Description = $Description; State = 'Ready'; TaskName = '' } }
    function script:Register-ScheduledTask { param($TaskName, $TaskPath, $InputObject, [switch]$Force, $ErrorAction) $InputObject.TaskName = $TaskName; $script:tasks[$TaskName] = $InputObject }
    function script:Start-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) $script:tasks[$TaskName].State = 'Running' }
    function script:Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) $script:tasks[$TaskName].State = 'Ready' }
    function New-FixturePaths {
        param([string]$Name)
        $root = Join-Path $script:fixtureRoot $Name
        return @{ HermesHome = (Join-Path $root 'home'); InstallDir = (Join-Path $root 'home\hermes-agent'); RuntimeRoot = (Join-Path $root 'runtime') }
    }
    $callback = { param($Event) $script:events.Add($Event) }
    try {
        $paths = New-FixturePaths 'valid 한글 경로'
        $output = @(Invoke-HermesResearchTeamSetup -InputObject $script:input @paths -ProgressCallback $callback)
        Assert ($output.Count -eq 1 -and $output[0].Succeeded -and $output[0].Profiles.Count -eq 4) 'Four profiles complete with one non-secret result'
        $result = $output[0]
        Assert (@($script:commands | Where-Object { $_.Arguments[0] -ceq 'profile' }).Count -eq 4) 'Pinned profile create command applied once per agent'
        $commandEnvironment = $script:commands[0].Environment
        Assert ($commandEnvironment.PATH -ceq 'C:\Windows\System32' -and $commandEnvironment.__HERMES_EASY_SETUP_REPLACE_ENVIRONMENT -ceq '1') 'Runtime preserves the bounded curated environment contract'
        Assert ($commandEnvironment.HERMES_HOME -ceq $paths.HermesHome -and $commandEnvironment.VIRTUAL_ENV -ceq (Join-Path $paths.InstallDir 'venv')) 'Runtime sets explicit Hermes home and virtual environment'
        Assert ($commandEnvironment.PYTHONNOUSERSITE -ceq '1' -and $commandEnvironment.PYTHONSAFEPATH -ceq '1' -and $null -eq $commandEnvironment.PYTHONHOME -and $null -eq $commandEnvironment.PYTHONPATH -and $null -eq $commandEnvironment.PYTHONUSERBASE -and $null -eq $commandEnvironment.PYTHONSTARTUP -and $null -eq $commandEnvironment.PYTHONINSPECT) 'Runtime disables inherited Python configuration'
        Assert ($script:requests.Count -eq 12 -and @($script:requests | Where-Object { $_.Uri -like '*plugins*' }).Count -eq 0) 'Only Mattermost identity, channel and membership endpoints are used'
        Assert (@($script:requests | Where-Object { $_.MaximumRedirection -ne 0 }).Count -eq 0) 'Authenticated REST requests never follow redirects'
        Assert ($script:tasks.Count -eq 4) 'Only four gateway tasks are registered'
        foreach ($task in @($script:tasks.Values)) {
            Assert ($task.Principal.LogonType -ceq 'Interactive' -and $task.Principal.RunLevel -ceq 'Limited' -and $task.Triggers[0].AtLogOn -and $task.Triggers[0].User -ceq $task.Principal.UserId) 'Task runs as current user at logon without elevation'
        }
        $stateText = [IO.File]::ReadAllText($result.StatePath)
        $visible = ($result | ConvertTo-Json -Depth 10) + ($script:events | ConvertTo-Json -Depth 10) + $stateText + ($script:commands | ConvertTo-Json -Depth 10)
        foreach ($agent in $script:input.Agents) {
            Assert (-not $visible.Contains($agent.BotToken)) 'Token absent from result, events, state, subprocess argv and environment'
            $profile = Join-Path (Join-Path $paths.HermesHome 'profiles') $agent.ProfileName
            $envText = [IO.File]::ReadAllText((Join-Path $profile '.env'))
            Assert ($envText.Contains('MATTERMOST_TOKEN=' + $agent.BotToken) -and $envText.Contains('MATTERMOST_REQUIRE_MENTION=true') -and $envText.Contains('MATTERMOST_REPLY_MODE=off')) 'Token stored only in profile env with mention-only channel policy'
            Assert ([IO.File]::ReadAllText((Join-Path $profile 'SOUL.md')).Contains('Personal instructions to preserve.')) 'Existing SOUL content preserved when adding role'
            $runner = Join-Path (Join-Path (Join-Path $paths.RuntimeRoot 'research\services') $agent.ProfileName) 'Start-Gateway.ps1'
            $runnerText = [IO.File]::ReadAllText($runner)
            Assert (-not $runnerText.Contains($agent.BotToken)) 'Gateway runner contains no bot token'
            $expectedCommandLine = "& '" + (Join-Path $paths.InstallDir 'bin\hermes.exe') + "' -p '" + $agent.ProfileName + "' gateway run --replace"
            Assert ($runnerText.Contains($expectedCommandLine) -and $runnerText.Contains("`$env:HERMES_HOME = '" + $paths.HermesHome + "'") -and $runnerText.Contains("`$env:PYTHONNOUSERSITE = '1'")) 'Runner uses the absolute verified command, explicit profile and environment with Korean paths'
            $runnerTokens = $null; $runnerErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$runnerTokens, [ref]$runnerErrors) | Out-Null
            Assert (@($runnerErrors).Count -eq 0) 'Generated gateway runner parses correctly'
            $runnerBytes = [IO.File]::ReadAllBytes($runner)
            Assert ($runnerBytes[0] -eq 0xEF -and $runnerBytes[1] -eq 0xBB -and $runnerBytes[2] -eq 0xBF) 'Gateway runner has UTF-8 BOM for PowerShell 5.1 and Korean paths'
        }
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @paths } 'Existing team requires explicit reuse switch'
        $personalPath = Join-Path $paths.HermesHome 'profiles\research-worker\sessions\keep.txt'
        New-Item -ItemType Directory -Path (Split-Path -Parent $personalPath) | Out-Null
        [IO.File]::WriteAllText($personalPath, 'keep this session')
        $script:input.Roles[2].Instructions += "`nUpdated fixture instruction."
        $beforeCreates = @($script:commands | Where-Object { $_.Arguments[0] -ceq 'profile' }).Count
        $resumed = Invoke-HermesResearchTeamSetup -InputObject $script:input @paths -ReuseExistingProfiles
        Assert ($resumed.Succeeded -and @($script:commands | Where-Object { $_.Arguments[0] -ceq 'profile' }).Count -eq $beforeCreates) 'Owned retry reuses all profiles without recreating them'
        Assert ([IO.File]::ReadAllText($personalPath) -ceq 'keep this session') 'Retry preserves existing sessions'
        $soul = [IO.File]::ReadAllText((Join-Path $paths.HermesHome 'profiles\research-worker\SOUL.md'))
        Assert ($soul.Contains('Updated fixture instruction.') -and [regex]::Matches($soul, [regex]::Escape($script:ResearchSoulStart)).Count -eq 1 -and $soul.Contains('Personal instructions to preserve.')) 'Role edit replaces only one managed SOUL block'

        $script:tasks = @{}
        $partialPaths = New-FixturePaths 'partial'
        $script:failProfile = 'research-worker'
        $partial = Invoke-HermesResearchTeamSetup -InputObject $script:input @partialPaths -ProgressCallback $callback
        Assert (-not $partial.Succeeded -and $partial.PartialSuccess -and @($partial.Profiles | Where-Object { $_.Status -ceq 'Succeeded' }).Count -eq 3) 'One agent failure preserves three successful agents'
        Assert ($partial.Profiles[2].ErrorCode -ceq 'GatewayStatusFailed' -and -not (($partial | ConvertTo-Json -Depth 10) + ($script:events | ConvertTo-Json -Depth 10)).Contains($script:secret)) 'Raw subprocess failure is reduced to a non-secret status code'
        $script:failProfile = ''
        $retried = Invoke-HermesResearchTeamSetup -InputObject $script:input @partialPaths -ReuseExistingProfiles
        Assert $retried.Succeeded 'Explicit retry completes an owned partial team'
        $script:stoppedProfile = 'research-worker'
        $stopped = Invoke-HermesResearchTeamSetup -InputObject $script:input @partialPaths -ReuseExistingProfiles
        Assert (-not $stopped.Succeeded -and $stopped.Profiles[2].ErrorCode -ceq 'GatewayStatusFailed') 'Exit-zero stopped gateway status cannot report completion'
        $script:stoppedProfile = ''; $script:exitAfterStatusProfile = 'research-worker'
        $exited = Invoke-HermesResearchTeamSetup -InputObject $script:input @partialPaths -ReuseExistingProfiles
        Assert (-not $exited.Succeeded -and $exited.Profiles[2].ErrorCode -ceq 'GatewayStatusFailed') 'Gateway task must remain Running after positive CLI status'
        $script:exitAfterStatusProfile = ''
        $taskName = $retried.Profiles[0].GatewayTask
        $managedDescription = $script:tasks[$taskName].Description
        $script:tasks[$taskName].Description = 'Foreign task'
        $before = $script:commands.Count
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @partialPaths -ReuseExistingProfiles } 'Foreign task description is rejected before profile mutation'
        Assert ($script:commands.Count -eq $before) 'Foreign task rejection does not invoke profile commands'
        $script:tasks[$taskName].Description = $managedDescription
        $managedArguments = $script:tasks[$taskName].Actions[0].Arguments
        $script:tasks[$taskName].Actions[0].Arguments += ' -ForeignArgument'
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @partialPaths -ReuseExistingProfiles } 'Task action mismatch is rejected even with managed description'
        $script:tasks[$taskName].Actions[0].Arguments = $managedArguments
        $script:tasks[$taskName].Principal.UserId = 'S-1-5-21-foreign'
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @partialPaths -ReuseExistingProfiles } 'Task principal mismatch is rejected even with managed description'

        $script:tasks = @{}
        $foreignPaths = New-FixturePaths 'foreign-profile'
        New-Item -ItemType Directory -Path (Join-Path $foreignPaths.HermesHome 'profiles\research-lead') -Force | Out-Null
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @foreignPaths -ReuseExistingProfiles } 'Reuse switch cannot claim an unowned existing profile'
        Assert (-not (Test-Path -LiteralPath $foreignPaths.RuntimeRoot)) 'Foreign profile rejection writes no team state'
        $blockedPaths = New-FixturePaths 'blocked'
        $script:loggedIn = $false
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Missing Codex auth blocks before mutation'
        Assert (-not (Test-Path -LiteralPath $blockedPaths.RuntimeRoot)) 'Auth failure creates no runtime state'
        $script:loggedIn = $true; $script:verified = $false
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Unverified install blocks before mutation'
        $script:verified = $true; $script:duplicateBot = $true
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Different tokens resolving to same bot are rejected'
        Assert (-not (Test-Path -LiteralPath $blockedPaths.RuntimeRoot)) 'Duplicate bot rejection writes no runtime state'
        $script:duplicateBot = $false; $script:rawHTTPFailure = $true
        $message = ''
        try { $null = Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } catch { $message = $_.Exception.Message }
        Assert ($message.Length -gt 0 -and -not $message.Contains($script:secret)) 'Raw REST exception never reflects a bot token'
        $script:rawHTTPFailure = $false
        $script:input.ServerURL = 'https://example.invalid'
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Remote HTTPS server is outside local research runtime scope'
        $script:input.ServerURL = 'http://127.0.0.1:8065'
        $script:input.SchemaVersion = 999
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Invalid input schema blocks before mutation'
        Assert (-not (Test-Path -LiteralPath $blockedPaths.RuntimeRoot)) 'Invalid input writes no runtime state'
        Write-Host ('Research runtime tests passed: ' + $script:passed)
    } finally {
        $resolved = [IO.Path]::GetFullPath($script:fixtureRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'hermes-research-tests-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
