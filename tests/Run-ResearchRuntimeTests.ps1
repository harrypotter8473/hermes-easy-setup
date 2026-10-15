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
    function Assert {
        param($Ok, [string]$Name)
        if (-not $Ok) { throw $Name }
        $script:passed++
        Write-Host "PASS $Name"
    }
    function Reject {
        param([scriptblock]$Block, [string]$Name)
        $failed = $false
        try { & $Block | Out-Null } catch { $failed = $true }
        Assert $failed $Name
    }
    function Read-TextHash {
        param([string]$LiteralPath)
        return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash
    }
    function New-FixturePaths {
        param([string]$Name)
        $root = Join-Path $script:fixtureRoot $Name
        return @{
            HermesHome = Join-Path $root 'home'
            InstallDir = Join-Path $root 'home\hermes-agent'
            RuntimeRoot = Join-Path $root 'runtime'
        }
    }
    function New-MockRuntimeFiles {
        param([string]$InstallDir)
        $command = Join-Path $InstallDir 'bin\hermes.exe'
        $python = Join-Path $InstallDir 'venv\Scripts\python.exe'
        foreach ($file in @($command, $python)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                [IO.File]::WriteAllText($file, 'fixture executable')
            }
        }
        return [pscustomobject]@{ Command = $command; Python = $python }
    }
    function Count-ProfileCommands {
        param([int]$Skip = 0)
        return @($script:processes | Select-Object -Skip $Skip | Where-Object {
            $_.Arguments.Count -ge 1 -and $_.Arguments[0] -ceq 'profile'
        }).Count
    }

    $script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-research-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:fixtureRoot | Out-Null
    $script:tasks = @{}
    $script:processes = New-Object System.Collections.Generic.List[object]
    $script:requests = New-Object System.Collections.Generic.List[object]
    $script:protectedRoots = New-Object System.Collections.Generic.List[string]
    $script:taskStarts = 0
    $script:heartbeatCalls = New-Object System.Collections.Generic.List[object]
    $script:loggedIn = $true
    $script:verified = $true
    $script:duplicateBot = $false
    $script:badMembership = $false
    $script:rawHTTPFailure = $false
    $script:checkExitCode = 0
    $script:checkMalformed = $false
    $script:finalCheckError = $false
    $script:injectForeignProfileName = ''
    $script:checkPayload = [ordered]@{
        ready = $false
        prompts_verified = $true
        pending_reasons = @('config.human.allowed_user_ids: pending')
        errors = @()
        native_tools_enabled = $false
    }
    $script:pinnedPython = ''
    $script:existingPython = ''
    $script:secret = 'a' * 26
    $script:manifest = Get-HermesResearchPersonaManifest
    $script:nativePlatformNames = @(
        'mattermost','telegram','discord','slack','whatsapp','signal','matrix','email','sms','homeassistant',
        'dingtalk','feishu','wecom','wecom_callback','weixin','bluebubbles','qqbot','yuanbao','relay'
    )
    $script:input = [pscustomobject]@{
        SchemaVersion = 1
        ServerURL = 'http://127.0.0.1:8065/'
        HomeChannelID = 'c' * 26
        ModelName = 'gpt-5.6-terra'
        Roles = @(Get-HermesResearchRoles)
        Agents = @(
            [pscustomobject]@{ ProfileName = 'research-lead'; DisplayName = 'Lead'; RoleId = 'planner'; BotToken = 'a' * 26 }
            [pscustomobject]@{ ProfileName = 'research-scout'; DisplayName = 'Scout'; RoleId = 'researcher'; BotToken = 'b' * 26 }
            [pscustomobject]@{ ProfileName = 'research-worker'; DisplayName = 'Worker'; RoleId = 'executor'; BotToken = 'd' * 26 }
            [pscustomobject]@{ ProfileName = 'research-reviewer'; DisplayName = 'Reviewer'; RoleId = 'reviewer'; BotToken = 'e' * 26 }
        )
    }

    # All process, network, ACL and Task Scheduler boundaries are replaced. The
    # suite never starts Hermes, Python, a model, a network request or a task.
    function script:Test-HermesInstallation {
        param($HermesHome, $InstallDir, $RuntimeRoot, $LogPath)
        $files = New-MockRuntimeFiles -InstallDir $InstallDir
        $script:pinnedPython = $files.Python
        return [pscustomobject]@{ Verified = [bool]$script:verified; CommandPath = $files.Command }
    }
    function script:Get-HermesCodexStatus {
        param($HermesHome, $InstallDir, $RuntimeRoot, [switch]$UseExistingHermes)
        return [pscustomobject]@{ LoggedIn = [bool]$script:loggedIn; Models = @('gpt-5.6-terra') }
    }
    function script:Get-HermesExistingRuntime {
        param($HermesHome, $InstallDir, $RuntimeRoot)
        $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
        $files = New-MockRuntimeFiles -InstallDir $paths.InstallDir
        $script:existingPython = $files.Python
        return [pscustomobject]@{
            Paths = [pscustomobject]@{ HermesHome = $paths.HermesHome; InstallDir = $paths.InstallDir; RuntimeRoot = $paths.RuntimeRoot }
            Command = $files.Command
            Python = $files.Python
            Environment = @{
                PATH = 'C:\Windows\System32'; SystemRoot = 'C:\Windows'
                TEMP = $script:fixtureRoot; TMP = $script:fixtureRoot
                HERMES_HOME = $paths.HermesHome; VIRTUAL_ENV = (Join-Path $paths.InstallDir 'venv')
                PYTHONNOUSERSITE = '1'; PYTHONSAFEPATH = '1'
                __HERMES_EASY_SETUP_REPLACE_ENVIRONMENT = '1'
            }
            Version = '2026.10.fixture'; Commit = ('f' * 40); RuntimeKind = 'Existing'
        }
    }
    function script:Get-HermesResearchCurrentUserSID { return 'S-1-5-21-1234-5678-9012-1001' }
    function script:Get-HermesPowerShellExecutable { return 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    function script:Get-HermesCuratedProcessEnvironment {
        return @{
            PATH = 'C:\Windows\System32'; SystemRoot = 'C:\Windows'
            TEMP = $script:fixtureRoot; TMP = $script:fixtureRoot
            __HERMES_EASY_SETUP_REPLACE_ENVIRONMENT = '1'
        }
    }
    function script:Protect-HermesResearchPrivateDirectory {
        param([string]$LiteralPath, [string]$OwnerSID)
        $script:protectedRoots.Add($LiteralPath)
        New-Item -ItemType Directory -Path $LiteralPath -Force | Out-Null
    }
    function script:Invoke-WebRequest {
        param($Uri, $Method, [switch]$UseBasicParsing, $TimeoutSec, $MaximumRedirection, $Headers, $ErrorAction)
        $script:requests.Add([pscustomobject]@{ Uri = $Uri; MaximumRedirection = $MaximumRedirection; Authorization = $Headers.Authorization })
        if ($script:rawHTTPFailure) { throw (New-Object Exception ('request failed ' + $script:secret)) }
        $letter = $Headers.Authorization.Substring(7, 1)
        $botID = 'u' + ($letter * 25)
        if ($script:duplicateBot) { $botID = 'u' + ('a' * 25) }
        if ($Uri -like '*/users/me') {
            # The verified Mattermost username, not the UI display name, is the
            # only valid mention target persisted for broker-to-broker routing.
            $body = @{ id = $botID; username = ('verified_' + $letter); is_bot = $true; roles = 'system_user'; delete_at = 0 }
        } elseif ($Uri -like '*/members/*') {
            $memberID = $(if ($script:badMembership) { 'u' + ('z' * 25) } else { $botID })
            $body = @{ user_id = $memberID; channel_id = 'c' * 26 }
        } else {
            $body = @{ id = 'c' * 26; team_id = 't' * 26; name = 'research'; type = 'O'; delete_at = 0 }
        }
        return [pscustomobject]@{ StatusCode = 200; Content = ($body | ConvertTo-Json -Compress) }
    }
    function script:Invoke-HermesProcess {
        param($FilePath, $ArgumentList, $Environment, $TimeoutSeconds, $WorkingDirectory)
        $call = [pscustomobject]@{ FilePath = [string]$FilePath; Arguments = @($ArgumentList); Environment = $Environment; TimeoutSeconds = $TimeoutSeconds }
        $script:processes.Add($call)
        if ($ArgumentList.Count -eq 4 -and $ArgumentList[0] -ceq 'profile' -and $ArgumentList[1] -ceq 'create' -and $ArgumentList[3] -ceq '--no-alias') {
            $profileDir = Join-Path (Join-Path $Environment.HERMES_HOME 'profiles') $ArgumentList[2]
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $profileDir '.env'), "CUSTOM_KEEP=1`r`nMATTERMOST_TOKEN=stale-native-token`r`n", (New-Object Text.UTF8Encoding($false)))
            return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        if ($ArgumentList.Count -eq 6 -and $ArgumentList[0] -ceq '-p' -and $ArgumentList[2] -ceq 'config' -and
            $ArgumentList[3] -ceq 'set' -and $ArgumentList[4].StartsWith('platforms.', [StringComparison]::Ordinal) -and
            $ArgumentList[4].EndsWith('.enabled', [StringComparison]::Ordinal)) {
            $platform = $ArgumentList[4].Substring(10, $ArgumentList[4].Length - 18)
            if ($script:nativePlatformNames -cnotcontains $platform -or $ArgumentList[5] -cne 'false') {
                throw 'Unexpected native-platform isolation command in research runtime test'
            }
            return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        if ($ArgumentList.Count -in @(7,9) -and $ArgumentList[0] -ceq '-I' -and $ArgumentList[1] -ceq '-S' -and
            $ArgumentList[2] -ceq '-B' -and $ArgumentList[4] -ceq 'check' -and $ArgumentList[5] -ceq '--root') {
            if ($ArgumentList.Count -eq 9 -and -not [string]::IsNullOrWhiteSpace($script:injectForeignProfileName)) {
                $injected = Join-Path (Join-Path $Environment.HERMES_HOME 'profiles') $script:injectForeignProfileName
                New-Item -ItemType Directory -Path $injected -Force | Out-Null
                [IO.File]::WriteAllText((Join-Path $injected 'keep.txt'), 'concurrent foreign profile')
            }
            $payload = $(if ($script:finalCheckError -and $ArgumentList.Count -eq 7) {
                [ordered]@{ ready = $false; prompts_verified = $true; pending_reasons = @('service binding failure'); errors = @('service binding failure'); native_tools_enabled = $false }
            } else { $script:checkPayload })
            $stdout = $(if ($script:checkMalformed) { 'not-json' } else { $payload | ConvertTo-Json -Depth 5 -Compress })
            return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = [int]$script:checkExitCode; StdOut = $stdout; StdErr = '' }
        }
        throw 'Unexpected real-process boundary in research runtime test'
    }
    function script:Get-ScheduledTask { param($TaskPath, $ErrorAction) return @($script:tasks.Values) }
    function script:New-ScheduledTaskAction { param($Execute, $Argument) return [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
    function script:New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User) return [pscustomobject]@{ AtLogOn = [bool]$AtLogOn; User = $User } }
    function script:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
    function script:New-ScheduledTaskSettingsSet {
        param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $MultipleInstances)
        return [pscustomobject]@{ MultipleInstances = $MultipleInstances }
    }
    function script:New-ScheduledTask {
        param($Action, $Trigger, $Principal, $Settings, $Description)
        return [pscustomobject]@{ Actions = @($Action); Triggers = @($Trigger); Principal = $Principal; Settings = $Settings; Description = $Description; State = 'Ready'; TaskName = '' }
    }
    function script:Register-ScheduledTask {
        param($TaskName, $TaskPath, $InputObject, [switch]$Force, $ErrorAction)
        $InputObject.TaskName = $TaskName
        $script:tasks[$TaskName] = $InputObject
    }
    function script:Start-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        $script:taskStarts++
        $script:tasks[$TaskName].State = 'Running'
    }
    function script:Wait-HermesResearchBrokerReady {
        param([string]$ResearchRoot, [string]$Python, [double]$StartedAt, [int]$TimeoutSeconds = 30)
        $script:heartbeatCalls.Add([pscustomobject]@{ ResearchRoot = $ResearchRoot; Python = $Python; StartedAt = $StartedAt })
        return [pscustomobject]$script:checkPayload
    }

    try {
        $templatePaths = New-FixturePaths 'template'
        $template = New-HermesResearchPolicy -RuntimeRoot $templatePaths.RuntimeRoot -ModelName $null -Agents $script:input.Agents -Roles $script:input.Roles
        Assert ($template.schema_version -eq 1 -and @($template.human.allowed_user_ids).Count -eq 0) 'Policy template has schema one and no implicit human authorization'
        $expectedBindings = [ordered]@{ manager = @('planner','research-lead'); researcher = @('researcher','research-scout'); analyst = @('executor','research-worker'); auditor = @('reviewer','research-reviewer') }
        foreach ($canonical in @($expectedBindings.Keys)) {
            $entry = $template.roles[$canonical]
            Assert ($entry.profile_name -ceq $expectedBindings[$canonical][1]) "Policy binds $canonical to its stable native profile"
            Assert ($null -eq $entry.model -and $null -eq $entry.provider -and $null -eq $entry.allow_model_egress -and
                $null -eq $entry.tools -and $null -eq $entry.read_roots -and $null -eq $entry.write_roots -and
                $null -eq $entry.call_targets -and $null -eq $entry.external_domains) "Policy leaves $canonical permissions unset instead of inventing authority"
            $limitNames = @('attempts','revisions','audits','seconds','tokens','max_output_tokens','per_call_timeout_seconds')
            Assert (@($limitNames | Where-Object { $null -ne $entry.limits[$_] }).Count -eq 0) "Policy leaves every $canonical budget unset"
        }

        $paths = New-FixturePaths 'valid 한글 경로'
        $personalFile = Join-Path $paths.HermesHome 'profiles\personal\keep.txt'
        New-Item -ItemType Directory -Path (Split-Path -Parent $personalFile) -Force | Out-Null
        [IO.File]::WriteAllText($personalFile, 'personal profile must remain byte exact', (New-Object Text.UTF8Encoding($false)))
        $personalBefore = Read-TextHash $personalFile
        $output = @(Invoke-HermesResearchTeamSetup -InputObject $script:input @paths)
        Assert ($output.Count -eq 1 -and $output[0].Succeeded -and $output[0].ExecutionMode -ceq 'GovernedBroker' -and $output[0].Profiles.Count -eq 4) 'Governed broker setup returns one four-role result'
        $result = $output[0]
        Assert (-not $result.ExecutionReady -and @($result.PendingSettings).Count -eq 1) 'Unset policy is reported as pending rather than execution-ready'
        Assert ((Read-TextHash $personalFile) -ceq $personalBefore) 'Unrelated personal profile remains byte exact'
        Assert ((Count-ProfileCommands) -eq 4) 'Only four explicit profile-create commands are issued'
        $profileCalls = @($script:processes | Where-Object { $_.Arguments.Count -ge 1 -and $_.Arguments[0] -ceq 'profile' })
        Assert (@($profileCalls | Where-Object { $_.Arguments.Count -ne 4 -or $_.Arguments[3] -cne '--no-alias' }).Count -eq 0) 'Every profile create disables global alias mutation'
        $platformCalls = @($script:processes | Where-Object {
            $_.Arguments.Count -eq 6 -and $_.Arguments[0] -ceq '-p' -and $_.Arguments[2] -ceq 'config' -and $_.Arguments[3] -ceq 'set'
        })
        Assert ($platformCalls.Count -eq (4 * $script:nativePlatformNames.Count)) 'Every research profile receives the complete native-platform isolation set'
        $expectedCommand = Join-Path $paths.InstallDir 'bin\hermes.exe'
        foreach ($agent in @($script:input.Agents)) {
            $agentCalls = @($platformCalls | Where-Object { $_.Arguments[1] -ceq $agent.ProfileName })
            $actualKeys = @($agentCalls | ForEach-Object { [string]$_.Arguments[4] } | Sort-Object)
            $expectedKeys = @($script:nativePlatformNames | ForEach-Object { 'platforms.' + $_ + '.enabled' } | Sort-Object)
            Assert ($agentCalls.Count -eq $script:nativePlatformNames.Count -and
                @($agentCalls | Where-Object { $_.Arguments[5] -cne 'false' }).Count -eq 0 -and
                @($agentCalls | Where-Object { $_.FilePath -cne $expectedCommand -or $_.Environment.HERMES_HOME -cne $paths.HermesHome }).Count -eq 0 -and
                (($actualKeys -join "`n") -ceq ($expectedKeys -join "`n"))) "Profile $($agent.ProfileName) disables every known native platform exactly once"
        }
        Assert ($script:requests.Count -eq 12 -and @($script:requests | Where-Object { $_.MaximumRedirection -ne 0 }).Count -eq 0) 'Four bot identities and channel memberships are checked without redirects'

        $policy = Get-HermesResearchPolicy -RuntimeRoot $paths.RuntimeRoot
        $stateText = [IO.File]::ReadAllText($result.StatePath)
        $privatePath = Join-Path $paths.RuntimeRoot 'research\private.json'
        $privateText = [IO.File]::ReadAllText($privatePath)
        $private = $privateText | ConvertFrom-Json
        foreach ($persona in @($script:manifest.Personas)) {
            $expected = $expectedBindings[[string]$persona.CanonicalName]
            $agent = @($script:input.Agents | Where-Object { $_.RoleId -ceq $expected[0] })[0]
            $profile = @($result.Profiles | Where-Object { $_.CanonicalRole -ceq $persona.CanonicalName })[0]
            $profileDir = Join-Path $paths.HermesHome ('profiles\' + $agent.ProfileName)
            $soulPath = Join-Path $profileDir 'SOUL.md'
            $envText = [IO.File]::ReadAllText((Join-Path $profileDir '.env'))
            $policyEntry = $policy.roles.PSObject.Properties[[string]$persona.CanonicalName].Value
            $privateBot = $private.bots.PSObject.Properties[[string]$persona.CanonicalName].Value
            $nativeCredentialLines = @($envText -split "`r?`n" | Where-Object {
                $_ -match '^\s*(MATTERMOST_|SLACK_|DISCORD_|TELEGRAM_|WHATSAPP_|SIGNAL_|IMESSAGE_|MATRIX_)[A-Za-z0-9_]*\s*='
            })
            Assert ($profile.RoleId -ceq $expected[0] -and $profile.ProfileName -ceq $expected[1]) "Result preserves the known $($persona.CanonicalName) legacy binding"
            Assert ((Read-TextHash $profile.PromptPath).ToLowerInvariant() -ceq $persona.Sha256 -and (Read-TextHash $soulPath).ToLowerInvariant() -ceq $persona.Sha256) "Prompt and SOUL keep the exact $($persona.CanonicalName) persona bytes"
            Assert ([string]$policyEntry.prompt_sha256 -ceq $persona.Sha256.ToLowerInvariant()) "Policy pins the exact $($persona.CanonicalName) prompt digest"
            Assert ($envText.Contains('CUSTOM_KEEP=1') -and $nativeCredentialLines.Count -eq 2 -and
                @($nativeCredentialLines | Where-Object { $_ -cnotin @('MATTERMOST_TOKEN=','MATTERMOST_URL=') }).Count -eq 0) "Profile $($agent.ProfileName) contains only explicit empty native Mattermost bindings"
            $expectedBotUsername = 'verified_' + $agent.BotToken.Substring(0, 1)
            Assert ([string]$privateBot.token -ceq $agent.BotToken) "Private broker service owns the $($persona.CanonicalName) token"
            Assert ([string]$privateBot.username -ceq $expectedBotUsername -and [string]$privateBot.username -cne [string]$agent.DisplayName) "Private broker service persists the REST-verified $($persona.CanonicalName) username, not its display name"
        }
        Assert ($private.messaging.reply_in_thread -is [bool] -and $private.messaging.reply_in_thread -and
            $private.messaging.bot_replies_require_mention -is [bool] -and $private.messaging.bot_replies_require_mention -and
            @($private.messaging.bot_observers).Count -eq 1 -and [string]$private.messaging.bot_observers[0] -ceq 'manager') 'Private broker service persists strict threaded mention routing with manager-only bot observation'

        $publicText = ($result | ConvertTo-Json -Depth 12) + $stateText + ([IO.File]::ReadAllText($result.PolicyPath))
        foreach ($agent in @($script:input.Agents)) {
            Assert (-not $publicText.Contains($agent.BotToken)) 'Tokens stay out of result, public state and policy'
        }
        Assert ($script:protectedRoots.Count -eq 1 -and $script:protectedRoots[0] -ceq (Join-Path $paths.RuntimeRoot 'research')) 'Research private root protection is requested before secret storage'

        $preflightCalls = @($script:processes | Where-Object { $_.Arguments.Count -eq 9 -and $_.Arguments[4] -ceq 'check' })
        $finalCheckCalls = @($script:processes | Where-Object { $_.Arguments.Count -eq 7 -and $_.Arguments[4] -ceq 'check' })
        Assert ($preflightCalls.Count -eq 1 -and $preflightCalls[0].FilePath -ceq $script:pinnedPython -and
            $preflightCalls[0].Arguments[0] -ceq '-I' -and $preflightCalls[0].Arguments[1] -ceq '-S' -and $preflightCalls[0].Arguments[2] -ceq '-B' -and
            $preflightCalls[0].Arguments[7] -ceq '--config') 'Candidate policy is checked in isolated Python before profile mutation'
        Assert ($finalCheckCalls.Count -eq 1 -and $finalCheckCalls[0].FilePath -ceq $script:pinnedPython -and
            $finalCheckCalls[0].Arguments[5] -ceq '--root' -and $finalCheckCalls[0].Arguments[6] -ceq (Join-Path $paths.RuntimeRoot 'research')) 'Final service bindings are checked with the selected Python and research root'
        Assert ($script:tasks.Count -eq 1 -and $script:taskStarts -eq 1 -and $script:heartbeatCalls.Count -eq 1) 'One governed broker service task is registered, started and heartbeat-checked'
        $task = @($script:tasks.Values)[0]
        Assert ($task.Principal.LogonType -ceq 'Interactive' -and $task.Principal.RunLevel -ceq 'Limited' -and $task.Triggers[0].AtLogOn) 'Broker task is current-user limited and logon-triggered'
        $runner = Join-Path $paths.RuntimeRoot 'research\services\governed-team\Start-Gateway.ps1'
        $runnerText = [IO.File]::ReadAllText($runner)
        Assert ($runnerText.Contains('-I -S -B') -and $runnerText.Contains('broker.py') -and $runnerText.Contains('serve --root')) 'Broker task runner starts only the isolated governed service'
        $invocationText = ($script:processes | ConvertTo-Json -Depth 8) + $runnerText
        Assert (-not $invocationText.Contains('--replace') -and -not $invocationText.Contains('gateway run')) 'Setup never invokes or scripts a native gateway replacement'
        foreach ($agent in @($script:input.Agents)) { Assert (-not $runnerText.Contains($agent.BotToken)) 'Broker runner contains no private token' }

        $existingPaths = New-FixturePaths 'existing-preserve'
        $existingPersonal = Join-Path $existingPaths.HermesHome 'profiles\personal\keep.txt'
        New-Item -ItemType Directory -Path (Split-Path -Parent $existingPersonal) -Force | Out-Null
        [IO.File]::WriteAllText($existingPersonal, 'existing personal profile')
        $beforeExisting = $script:processes.Count
        $existingResult = Invoke-HermesResearchTeamSetup -InputObject $script:input @existingPaths -UseExistingHermes
        $existingCalls = @($script:processes | Select-Object -Skip $beforeExisting)
        Assert ($existingResult.Succeeded -and $existingResult.RuntimeKind -ceq 'Existing' -and $existingResult.ExistingGatewayLifecyclePreserved) 'Existing runtime uses the governed broker without taking over its gateway lifecycle'
        Assert ([IO.File]::ReadAllText($existingPersonal) -ceq 'existing personal profile') 'Existing runtime preserves unrelated profiles'
        Assert (@($existingCalls | Where-Object { @($_.Arguments | Where-Object { $_ -ceq '--replace' -or $_ -ceq 'gateway' }).Count -gt 0 }).Count -eq 0) 'Existing runtime issues no gateway lifecycle argument'
        $existingCheck = @($existingCalls | Where-Object { $_.Arguments.Count -eq 7 -and $_.Arguments[4] -ceq 'check' })
        Assert ($existingCheck.Count -eq 1 -and $existingCheck[0].FilePath -ceq $script:existingPython) 'Existing runtime final service check uses its verified Python fixture'

        $foreignPaths = New-FixturePaths 'foreign-task'
        $owner = Get-HermesResearchCurrentUserSID
        $foreignPlan = Get-HermesResearchTaskPlan -ProfileName 'governed-team' -HermesHome $foreignPaths.HermesHome -RuntimeRoot $foreignPaths.RuntimeRoot -OwnerSID $owner -TeamID ('f' * 32) -PowerShellPath (Get-HermesPowerShellExecutable)
        $script:tasks[$foreignPlan.TaskName] = [pscustomobject]@{
            TaskName = $foreignPlan.TaskName; Description = 'Foreign task'; State = 'Ready'
            Actions = @([pscustomobject]@{ Execute = $foreignPlan.Execute; Arguments = $foreignPlan.Arguments })
            Principal = [pscustomobject]@{ UserId = $owner; LogonType = 'Interactive'; RunLevel = 'Limited' }
        }
        $beforeForeignProcesses = $script:processes.Count
        $beforeForeignProtect = $script:protectedRoots.Count
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @foreignPaths } 'Foreign broker task ownership is rejected'
        Assert ((Count-ProfileCommands -Skip $beforeForeignProcesses) -eq 0 -and $script:protectedRoots.Count -eq $beforeForeignProtect) 'Foreign task rejection occurs before profile or private-root mutation'

        $collisionPaths = New-FixturePaths 'foreign-profile'
        $collisionMarker = Join-Path $collisionPaths.HermesHome 'profiles\research-reviewer\keep.txt'
        New-Item -ItemType Directory -Path (Split-Path -Parent $collisionMarker) -Force | Out-Null
        [IO.File]::WriteAllText($collisionMarker, 'foreign research profile')
        $beforeCollision = $script:processes.Count
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @collisionPaths -ReuseExistingProfiles } 'Unowned research profile collision is rejected'
        Assert ((Count-ProfileCommands -Skip $beforeCollision) -eq 0 -and [IO.File]::ReadAllText($collisionMarker) -ceq 'foreign research profile') 'All profile collisions are checked before mutation'

        $racePaths = New-FixturePaths 'profile-race'
        $script:injectForeignProfileName = 'research-worker'
        $beforeRace = $script:processes.Count
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @racePaths } 'Profile created after preflight is never claimed as wizard-owned'
        $raceMarker = Join-Path $racePaths.HermesHome 'profiles\research-worker\keep.txt'
        Assert ((Count-ProfileCommands -Skip $beforeRace) -eq 0 -and (Test-Path -LiteralPath $raceMarker -PathType Leaf) -and [IO.File]::ReadAllText($raceMarker) -ceq 'concurrent foreign profile') 'TOCTOU profile collision is rechecked before any profile mutation'
        $script:injectForeignProfileName = ''

        $blockedPaths = New-FixturePaths 'blocked-auth'
        $script:loggedIn = $false
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Missing Codex auth blocks setup'
        Assert (-not (Test-Path -LiteralPath $blockedPaths.RuntimeRoot)) 'Auth failure creates no runtime state'
        $script:loggedIn = $true
        $script:verified = $false
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Unverified install blocks setup'
        Assert (-not (Test-Path -LiteralPath $blockedPaths.RuntimeRoot)) 'Install verification failure creates no runtime state'
        $script:verified = $true
        $script:duplicateBot = $true
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Duplicate bot identities fail membership preflight'
        Assert (-not (Test-Path -LiteralPath $blockedPaths.RuntimeRoot)) 'Bot identity failure creates no runtime state'
        $script:duplicateBot = $false
        $script:badMembership = $true
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths } 'Missing channel membership fails preflight'
        $script:badMembership = $false
        $script:rawHTTPFailure = $true
        $message = ''
        try { Invoke-HermesResearchTeamSetup -InputObject $script:input @blockedPaths | Out-Null } catch { $message = $_.Exception.Message }
        Assert ($message.Length -gt 0 -and -not $message.Contains($script:secret)) 'REST failures never reflect a bot token'
        $script:rawHTTPFailure = $false

        foreach ($failure in @(
            [pscustomobject]@{ Name = 'nonzero'; Exit = 9; Malformed = $false; Verified = $true; Errors = @() }
            [pscustomobject]@{ Name = 'malformed'; Exit = 0; Malformed = $true; Verified = $true; Errors = @() }
            [pscustomobject]@{ Name = 'hash'; Exit = 0; Malformed = $false; Verified = $false; Errors = @() }
            [pscustomobject]@{ Name = 'policy-error'; Exit = 0; Malformed = $false; Verified = $true; Errors = @('invalid policy') }
        )) {
            $failurePaths = New-FixturePaths ('failed-check-' + $failure.Name)
            $script:checkExitCode = $failure.Exit
            $script:checkMalformed = $failure.Malformed
            $script:checkPayload = [ordered]@{ ready = $false; prompts_verified = [bool]$failure.Verified; pending_reasons = @('failure'); errors = @($failure.Errors); native_tools_enabled = $false }
            $beforeTasks = $script:tasks.Count
            $beforeStarts = $script:taskStarts
            Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @failurePaths } "Failed $($failure.Name) policy check returns no success"
            Assert ($script:tasks.Count -eq $beforeTasks -and $script:taskStarts -eq $beforeStarts) "Failed $($failure.Name) policy check never registers or starts a service"
        }
        $script:checkExitCode = 0
        $script:checkMalformed = $false
        $script:checkPayload = [ordered]@{ ready = $false; prompts_verified = $true; pending_reasons = @('pending'); errors = @(); native_tools_enabled = $false }
        $script:finalCheckError = $true
        $finalFailurePaths = New-FixturePaths 'failed-final-service-check'
        $beforeFinalFailureTasks = $script:tasks.Count
        $beforeFinalFailureStarts = $script:taskStarts
        Reject { Invoke-HermesResearchTeamSetup -InputObject $script:input @finalFailurePaths } 'Failed final service-binding check returns no success'
        Assert ($script:tasks.Count -eq $beforeFinalFailureTasks -and $script:taskStarts -eq $beforeFinalFailureStarts) 'Failed final service-binding check never registers or starts a service'
        $script:finalCheckError = $false

        Write-Host ('Research runtime tests passed: ' + $script:passed)
    } finally {
        $resolved = [IO.Path]::GetFullPath($script:fixtureRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'hermes-research-tests-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
