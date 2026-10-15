Set-StrictMode -Version 2.0

$script:ResearchManager = 'HermesEasySetup.Research.v1'
$script:ResearchSoulStart = '<!-- HERMES EASY SETUP: MANAGED RESEARCH ROLE START -->'
$script:ResearchSoulEnd = '<!-- HERMES EASY SETUP: MANAGED RESEARCH ROLE END -->'
$script:ResearchGatewayReadyTimeoutSeconds = 60
$script:ResearchExistingGatewayReadyTimeoutSeconds = 75

. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchGovernance.ps1')
. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchDefaults.ps1')
. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchMigration.ps1')

function Publish-HermesResearchStage {
    param([AllowNull()][scriptblock]$Callback, [string]$Stage, [string]$Message, [int]$Percent, [string]$State = 'running')
    if ($null -ne $Callback) { [void](Publish-HermesEvent -Callback $Callback -Type 'stage' -Stage $Stage -State $State -Message $Message -Percent $Percent) }
}

function Invoke-HermesResearchMattermostAPI {
    param([string]$ServerURL, [string]$Path, [string]$Token)
    if ($Path -cnotmatch '^/api/v4/(users/me|users/username/[a-z0-9][a-z0-9._-]{0,63}|channels/[a-z0-9]{26}(/members/[a-z0-9]{26})?)$') { throw 'ResearchApiPathRejected' }
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
    $seenNames = @{}
    foreach ($agent in @($InputObject.Agents)) {
        try {
            $me = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path '/api/v4/users/me' -Token $agent.BotToken
            if ($me.is_bot -isnot [bool] -or -not $me.is_bot -or $me.delete_at -ne 0 -or $me.roles -cne 'system_user' -or $me.id -cnotmatch '^[a-z0-9]{26}$') { throw 'InvalidBot' }
            if ($me.username -isnot [string] -or $me.username -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { throw 'InvalidBotUsername' }
            if ($seen.ContainsKey([string]$me.id)) { throw 'DuplicateBot' }
            if ($seenNames.ContainsKey([string]$me.username)) { throw 'DuplicateBotUsername' }
            $channel = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ("/api/v4/channels/$($InputObject.HomeChannelID)") -Token $agent.BotToken
            if ($channel.id -cne $InputObject.HomeChannelID -or $channel.delete_at -ne 0 -or $channel.type -cnotin @('O', 'P') -or $channel.team_id -cnotmatch '^[a-z0-9]{26}$') { throw 'InvalidChannel' }
            $member = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ("/api/v4/channels/$($InputObject.HomeChannelID)/members/$($me.id)") -Token $agent.BotToken
            if ($member.user_id -cne $me.id -or $member.channel_id -cne $InputObject.HomeChannelID) { throw 'InvalidMembership' }
            $seen[[string]$me.id] = $true
            $seenNames[[string]$me.username] = $true
            $identities.Add([pscustomobject]@{ ProfileName = [string]$agent.ProfileName; BotUserID = [string]$me.id; BotUsername = [string]$me.username })
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

function Get-HermesExistingResearchGatewaySnapshot {
    param(
        [Parameter(Mandatory = $true)]$Runtime,
        [string[]]$ProfileNames = @()
    )
    $requested = @($ProfileNames | ForEach-Object { [string]$_ })
    if (@($requested | Where-Object { $_ -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$' }).Count -gt 0 -or
        @($requested | Select-Object -Unique).Count -ne $requested.Count) { throw 'ExistingGatewayProfileSetRejected' }
    $environment = @{}
    foreach ($entry in $Runtime.Environment.GetEnumerator()) { $environment[[string]$entry.Key] = $entry.Value }
    $environment['HERMES_HOME'] = [string]$Runtime.Paths.HermesHome
    $environment['PYTHONDONTWRITEBYTECODE'] = '1'
    $program = @'
import os, sys
sys.dont_write_bytecode = True

def readonly_audit(event, args):
    if event == "open":
        mode = args[1] if len(args) > 1 else None
        flags = args[2] if len(args) > 2 else 0
        if ((isinstance(mode, str) and any(c in mode for c in "wax+")) or
                (isinstance(flags, int) and flags &
                 (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND))):
            raise PermissionError("HermesExistingGatewayReadOnlyProbe")
    if (event.startswith(("winreg.", "os.spawn", "os.exec", "os.startfile", "subprocess.")) or
            event in ("os.mkdir", "os.remove", "os.rename", "os.rmdir", "os.link", "os.symlink",
                      "os.truncate", "os.chmod", "os.utime", "os.chown", "os.system", "os.posix_spawn",
                      "socket.__new__", "socket.connect", "socket.bind", "socket.getaddrinfo")):
        raise PermissionError("HermesExistingGatewayReadOnlyProbe")

sys.addaudithook(readonly_audit)
import contextlib, io, json, stat
from pathlib import Path
source_root = os.path.realpath(sys.argv[1])
site_packages = os.path.join(source_root, "venv", "Lib", "site-packages")
sys.path.insert(0, site_packages)
sys.path.insert(0, source_root)
names = [name for name in sys.argv[2].split(",") if name]
answer = {"HostLive": False, "Multiplex": False, "Ambiguous": False,
          "GatewayState": "", "Profiles": [
              {"Name": name, "Served": False, "MattermostState": "",
               "Connected": False, "NeedsAttention": False}
              for name in names]}
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from gateway.status import get_runtime_status_running_pid, read_runtime_status, runtime_status_is_stale
    root = Path(os.environ["HERMES_HOME"])
    candidates = [root]
    profiles_root = root / "profiles"
    if profiles_root.is_dir():
        for entry in profiles_root.iterdir():
            try:
                attributes = getattr(entry.lstat(), "st_file_attributes", 0)
                if entry.is_dir() and not entry.is_symlink() and not (
                        attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)):
                    candidates.append(entry)
            except OSError:
                continue
    live = []
    for home in candidates:
        runtime = read_runtime_status(home / "gateway_state.json")
        if not isinstance(runtime, dict) or not isinstance(runtime.get("served_profiles"), list):
            continue
        if runtime.get("gateway_state") not in ("running", "degraded") or runtime_status_is_stale(runtime):
            continue
        recorded_home = runtime.get("hermes_home")
        if not isinstance(recorded_home, str) or not recorded_home:
            continue
        try:
            if os.path.normcase(os.path.realpath(recorded_home)) != os.path.normcase(os.path.realpath(str(home))):
                continue
            pid = get_runtime_status_running_pid(runtime, expected_home=home)
        except Exception:
            pid = None
        if pid is not None:
            live.append((home, runtime, int(pid)))
    if len(live) == 1:
        _home, runtime, _pid = live[0]
        served = {str(item).lower() for item in runtime.get("served_profiles", []) if isinstance(item, str)}
        platforms = runtime.get("platforms") if isinstance(runtime.get("platforms"), dict) else {}
        answer["HostLive"] = True
        # A standalone gateway explicitly publishes an empty served_profiles list;
        # a real multiplexer always includes at least its active/default profile.
        answer["Multiplex"] = bool(served)
        answer["GatewayState"] = str(runtime.get("gateway_state") or "")
        for profile_answer in answer["Profiles"]:
            name = profile_answer["Name"]
            platform = platforms.get(name + ":mattermost")
            platform = platform if isinstance(platform, dict) else {}
            state = str(platform.get("state") or "").lower()
            attention = platform.get("needs_attention") is True
            profile_answer.update({"Served": name.lower() in served,
                                   "MattermostState": state,
                                   "Connected": state == "connected" and not attention,
                                   "NeedsAttention": attention})
    elif len(live) > 1:
        answer["Ambiguous"] = True
print(json.dumps(answer, separators=(",", ":")))
'@
    $result = Invoke-HermesProcess -FilePath ([string]$Runtime.Python) -ArgumentList @('-I', '-S', '-B', '-c', $program, ([string]$Runtime.Paths.InstallDir), ($requested -join ',')) -WorkingDirectory ([string]$Runtime.Paths.InstallDir) -Environment $environment -TimeoutSeconds 30
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'ExistingGatewayStatusProbeFailed' }
    try {
        $snapshot = $result.StdOut.Trim() | ConvertFrom-Json
        if ($snapshot.HostLive -isnot [bool] -or $snapshot.Multiplex -isnot [bool] -or $snapshot.Ambiguous -isnot [bool] -or
            [string]$snapshot.GatewayState -cnotmatch '^[a-z0-9_-]{0,64}$' -or @($snapshot.Profiles).Count -ne $requested.Count) { throw 'InvalidSnapshot' }
        $seen = @{}
        foreach ($profile in @($snapshot.Profiles)) {
            if ([string]$profile.Name -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$' -or $seen.ContainsKey([string]$profile.Name) -or
                $profile.Served -isnot [bool] -or $profile.Connected -isnot [bool] -or $profile.NeedsAttention -isnot [bool] -or
                [string]$profile.MattermostState -cnotmatch '^[a-z0-9_-]{0,64}$') { throw 'InvalidProfileSnapshot' }
            $seen[[string]$profile.Name] = $true
        }
        foreach ($name in $requested) { if (-not $seen.ContainsKey($name)) { throw 'MissingProfileSnapshot' } }
    } catch { throw 'ExistingGatewayStatusResponseRejected' }
    return $snapshot
}

function Wait-HermesExistingResearchGatewayReady {
    param(
        [Parameter(Mandatory = $true)]$Runtime,
        [string[]]$ProfileNames,
        [int]$TimeoutSeconds = 75
    )
    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
    $snapshot = $null
    do {
        $snapshot = Get-HermesExistingResearchGatewaySnapshot -Runtime $Runtime -ProfileNames $ProfileNames
        $ready = ($snapshot.HostLive -and $snapshot.Multiplex -and -not $snapshot.Ambiguous -and
            @($snapshot.Profiles | Where-Object { -not $_.Served -or -not $_.Connected }).Count -eq 0)
        if ($ready -or (Get-Date) -ge $deadline) { return $snapshot }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $snapshot
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

function ConvertTo-HermesResearchPrincipalSID {
    param([AllowNull()][string]$Identity)
    if ([string]::IsNullOrWhiteSpace($Identity) -or $Identity -cne $Identity.Trim() -or $Identity -match '[\x00-\x1f]') { throw 'ResearchPrincipalIdentityRejected' }
    try {
        if ($Identity -match '^S-') { return (New-Object System.Security.Principal.SecurityIdentifier($Identity)).Value }
        # Task Scheduler may return a resolved account name even when registered with a SID.
        $account = New-Object System.Security.Principal.NTAccount($Identity)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { throw 'ResearchPrincipalIdentityUnresolved' }
}

function Assert-HermesResearchOwnedTask {
    param($Task, [Parameter(Mandatory = $true)]$Plan, [bool]$HasOwnership)
    if ($null -eq $Task) { return }
    try {
        $actions = @($Task.Actions)
        $actualOwnerSID = ConvertTo-HermesResearchPrincipalSID -Identity ([string]$Task.Principal.UserId)
        $expectedOwnerSID = (New-Object System.Security.Principal.SecurityIdentifier([string]$Plan.OwnerSID)).Value
        if (-not $HasOwnership -or $Task.Description -cne $Plan.Description -or $actions.Count -ne 1 -or
            -not [string]::Equals([string]$actions[0].Execute, [string]$Plan.Execute, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$actions[0].Arguments -cne $Plan.Arguments -or $actualOwnerSID -cne $expectedOwnerSID -or
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
        [switch]$ReuseExistingProfiles,
        [switch]$UseExistingHermes
    )
    try { $summary = Assert-HermesResearchTeamInput -InputObject $InputObject } catch { throw '연구팀 입력 형식이 올바르지 않습니다. 역할·프로필·봇 토큰·로컬 서버 주소를 확인하세요.' }
    $normalizedAgents = @($summary.Agents | ForEach-Object {
        $safeAgent = $_
        $sourceAgent = @($InputObject.Agents | Where-Object { $_.ProfileName -ceq $safeAgent.ProfileName })[0]
        [pscustomobject]@{ ProfileName = $safeAgent.ProfileName; DisplayName = $safeAgent.DisplayName; RoleId = $safeAgent.RoleId; BotToken = [string]$sourceAgent.BotToken }
    })
    $wizardOptions = $(if ($InputObject.PSObject.Properties['WizardOptions']) { $InputObject.WizardOptions } else { $null })
    $InputObject = [pscustomobject]@{ SchemaVersion = 1; ServerURL = $summary.ServerURL; HomeChannelID = $summary.HomeChannelID; ModelName = $summary.ModelName; Roles = $summary.Roles; Agents = $normalizedAgents; WizardOptions = $wizardOptions }
    $serverUri = [Uri]$InputObject.ServerURL
    $loopbackIP = $null
    $isLoopback = ($serverUri.DnsSafeHost -ieq 'localhost')
    if ([Net.IPAddress]::TryParse($serverUri.DnsSafeHost.Trim('[', ']'), [ref]$loopbackIP)) { $isLoopback = [Net.IPAddress]::IsLoopback($loopbackIP) }
    if (-not $isLoopback) { throw '1인 연구팀은 로컬 loopback Mattermost 서버만 사용할 수 있습니다.' }
    $runtime = $null
    if ($UseExistingHermes) {
        try { $runtime = Get-HermesExistingRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot } catch { throw '기존 Hermes 실행 환경을 안전하게 확인하지 못했습니다. 기존 설치는 변경하지 않았습니다.' }
        try {
            if ([string]$runtime.RuntimeKind -cne 'Existing' -or $null -eq $runtime.Paths -or $null -eq $runtime.Environment) { throw 'InvalidExistingRuntime' }
            $paths = $runtime.Paths
            $expectedCommand = [IO.Path]::GetFullPath([string]$runtime.Command)
            $existingPython = [IO.Path]::GetFullPath([string]$runtime.Python)
            if (-not (Test-Path -LiteralPath $expectedCommand -PathType Leaf) -or -not (Test-Path -LiteralPath $existingPython -PathType Leaf) -or
                -not (Test-HermesPathContains -ParentPath ([string]$paths.InstallDir) -ChildPath $expectedCommand) -or
                -not (Test-HermesPathContains -ParentPath ([string]$paths.InstallDir) -ChildPath $existingPython)) { throw 'InvalidExistingRuntimePath' }
        } catch { throw '기존 Hermes 실행 파일 구성을 안전하게 확인하지 못했습니다. 기존 설치는 변경하지 않았습니다.' }
    } else {
        $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    }
    if ($null -ne $wizardOptions) { $null = Assert-HermesResearchWizardOptions -Options $wizardOptions -RuntimeRoot $paths.RuntimeRoot }
    # Disallow accidentally copying a known token into public metadata or argv.
    $publicText = (@($paths.HermesHome, $paths.InstallDir, $paths.RuntimeRoot, $InputObject.ServerURL, $InputObject.HomeChannelID, $InputObject.ModelName) + @($InputObject.Agents | ForEach-Object { $_.ProfileName; $_.DisplayName; $_.RoleId }) + @($InputObject.Roles | ForEach-Object { $_.Id; $_.Name; $_.Instructions })) -join "`n"
    foreach ($agent in @($InputObject.Agents)) { if ($publicText.Contains([string]$agent.BotToken)) { throw '봇 토큰을 이름·역할·경로·기타 공개 설정에 넣을 수 없습니다.' } }
    foreach ($path in @($paths.HermesHome, $paths.InstallDir, $paths.RuntimeRoot)) { if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe) { throw '연구팀 경로가 안전하지 않습니다.' } }
    if ((Test-HermesPathContains -ParentPath $paths.HermesHome -ChildPath $paths.RuntimeRoot) -or (Test-HermesPathContains -ParentPath $paths.RuntimeRoot -ChildPath $paths.HermesHome) -or (Test-HermesPathContains -ParentPath $paths.InstallDir -ChildPath $paths.RuntimeRoot) -or (Test-HermesPathContains -ParentPath $paths.RuntimeRoot -ChildPath $paths.InstallDir)) { throw 'RuntimeRoot는 Hermes 데이터·설치 경로와 분리되어야 합니다.' }
    Publish-HermesResearchStage $ProgressCallback 'research-verify' 'Hermes 설치와 기존 OpenAI Codex 인증을 확인합니다.' 5
    if (-not $UseExistingHermes) {
        $verificationLog = Join-Path ([System.IO.Path]::GetTempPath()) ('hermes-research-verify-' + [guid]::NewGuid().ToString('N') + '.log')
        try {
            $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -LogPath $verificationLog
        } catch { throw '검증된 Hermes 설치가 필요합니다.' }
        finally { if (Test-Path -LiteralPath $verificationLog -PathType Leaf) { Remove-Item -LiteralPath $verificationLog -Force -ErrorAction SilentlyContinue } }
        $expectedCommand = [IO.Path]::GetFullPath((Join-Path $paths.InstallDir 'bin\hermes.exe'))
        if ($verification.Verified -isnot [bool] -or -not $verification.Verified -or -not [string]::Equals([string]$verification.CommandPath, $expectedCommand, [StringComparison]::OrdinalIgnoreCase)) { throw '검증된 Hermes 설치가 필요합니다.' }
    }
    try { $codex = Get-HermesCodexStatus -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -UseExistingHermes:$UseExistingHermes } catch { throw 'OpenAI Codex 인증 확인에 실패했습니다.' }
    if ($codex.LoggedIn -isnot [bool] -or -not $codex.LoggedIn) { throw 'OpenAI Codex 로그인을 먼저 완료하세요.' }
    if (@($codex.Models) -cnotcontains [string]$InputObject.ModelName) { throw '선택한 OpenAI Codex 모델을 기존 인증에서 확인할 수 없습니다.' }
    Publish-HermesResearchStage $ProgressCallback 'research-connection' '서로 다른 봇 4개와 홈 채널 멤버십을 변경 전에 확인합니다.' 10
    $identities = @(Test-HermesResearchTeamConnection -InputObject $InputObject)
    return Invoke-HermesGovernedResearchSetup -InputObject $InputObject -Paths $paths -Runtime $runtime -CommandPath $expectedCommand -Identities $identities -ReuseExistingProfiles:$ReuseExistingProfiles -UseExistingHermes:$UseExistingHermes -ProgressCallback $ProgressCallback
}

Export-ModuleMember -Function @('Invoke-HermesResearchTeamSetup','New-HermesResearchPolicy','Get-HermesResearchPolicy','Save-HermesResearchPolicy','New-HermesResearchWizardOptions','Assert-HermesResearchWizardOptions','New-HermesResearchWizardPolicy')
