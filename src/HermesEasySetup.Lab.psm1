Set-StrictMode -Version 2.0

$script:LabManagedSoulStart = '<!-- HERMES EASY SETUP: MANAGED LAB IDENTITY START -->'
$script:LabManagedSoulEnd = '<!-- HERMES EASY SETUP: MANAGED LAB IDENTITY END -->'
$script:LabTaskName = 'Hermes Easy Setup Dashboard'
$script:LabInputEntropy = [System.Text.Encoding]::UTF8.GetBytes('HermesEasySetup.LabInput.v1')

function Test-HermesLabProfileName {
    [CmdletBinding()]
    param([AllowNull()][string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -cmatch '^[a-z][a-z0-9_-]{1,31}$' -and $Name -cne 'default')
}

function Test-HermesNetBirdIPv4 {
    [CmdletBinding()]
    param([AllowNull()][string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
    $bytes = $ip.GetAddressBytes()
    return ($bytes.Count -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127)
}

function Get-HermesNetBirdIPv4 {
    [CmdletBinding()]
    param()
    $addresses = @()
    try {
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.AddressState -eq 'Preferred' -and (Test-HermesNetBirdIPv4 -Address ([string]$_.IPAddress))
        })
    } catch {
        $addresses = @()
    }
    if ($addresses.Count -eq 0) { return $null }
    $preferred = @($addresses | Where-Object {
        ([string]$_.InterfaceAlias -match '(?i)netbird') -or ([string]$_.InterfaceDescription -match '(?i)netbird')
    } | Sort-Object InterfaceIndex | Select-Object -First 1)
    if ($preferred.Count -gt 0) { return [string]$preferred[0].IPAddress }
    return [string](@($addresses | Sort-Object InterfaceIndex | Select-Object -First 1)[0].IPAddress)
}

function Assert-HermesLabTextValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value,
        [int]$MaximumLength = 4096,
        [switch]$AllowEmpty
    )
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value)) { throw "$Name 값을 입력하세요." }
    if ($null -eq $Value) { return }
    if ($Value.Length -gt $MaximumLength -or $Value.IndexOf([char]0) -ge 0) { throw "$Name 값이 허용 범위를 벗어났습니다." }
    if ($Value -match "[\r\n]") { throw "$Name 값에는 줄바꿈을 사용할 수 없습니다." }
}

function Set-HermesLabEnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [string[]]$RemovePrefixes = @()
    )
    foreach ($key in $Values.Keys) {
        if ([string]$key -cnotmatch '^[A-Z][A-Z0-9_]*$') { throw "허용되지 않은 환경 변수 이름입니다: $key" }
        Assert-HermesLabTextValue -Name ([string]$key) -Value ([string]$Values[$key]) -MaximumLength 8192 -AllowEmpty
    }
    $parent = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $existing = @()
    if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) { $existing = @([System.IO.File]::ReadAllLines($LiteralPath, [System.Text.Encoding]::UTF8)) }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in $existing) {
        $drop = $false
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $existingKey = [string]$matches[1]
            if ($Values.ContainsKey($existingKey)) {
                $drop = $true
            } else {
                foreach ($prefix in $RemovePrefixes) {
                    if ($existingKey.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $drop = $true; break }
                }
            }
        }
        if (-not $drop) { $kept.Add([string]$line) }
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
    if ($kept.Count -gt 0) { $kept.Add('') }
    $kept.Add('# Managed by Hermes Easy Setup lab integration')
    foreach ($key in @($Values.Keys | Sort-Object)) { $kept.Add(('{0}={1}' -f $key, [string]$Values[$key])) }
    $temporary = $LiteralPath + '.hermes-easy-setup-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temporary, (($kept.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $LiteralPath, $null)
        } else {
            [System.IO.File]::Move($temporary, $LiteralPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Merge-HermesLabSoul {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Existing,
        [Parameter(Mandatory = $true)][string]$FullName,
        [AllowNull()][string]$Role
    )
    $remaining = [string]$Existing
    $start = $remaining.IndexOf($script:LabManagedSoulStart, [System.StringComparison]::Ordinal)
    if ($start -ge 0) {
        $end = $remaining.IndexOf($script:LabManagedSoulEnd, $start, [System.StringComparison]::Ordinal)
        if ($end -ge 0) {
            $after = $end + $script:LabManagedSoulEnd.Length
            $remaining = ($remaining.Substring(0, $start) + [Environment]::NewLine + $remaining.Substring($after)).Trim()
        } else {
            $remaining = $remaining.Substring(0, $start).Trim()
        }
    } else {
        $remaining = $remaining.Trim()
    }
    $managed = New-Object System.Collections.Generic.List[string]
    $managed.Add($script:LabManagedSoulStart)
    $managed.Add('# Centrally Managed Lab Identity and Role')
    $managed.Add('')
    $managed.Add("Your name is $FullName.")
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        $managed.Add('')
        $managed.Add('Your primary role and responsibilities are:')
        $managed.Add('')
        $managed.Add($Role.Trim())
    }
    $managed.Add('')
    $managed.Add('These managed identity and role instructions take precedence over conflicting identity or role instructions elsewhere in this profile, memory, or conversation.')
    $managed.Add($script:LabManagedSoulEnd)
    if (-not [string]::IsNullOrWhiteSpace($remaining)) { $managed.Add(''); $managed.Add($remaining) }
    return (($managed.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Protect-HermesLabInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )
    Add-Type -AssemblyName System.Security
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    $plain = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        $encrypted = [System.Security.Cryptography.ProtectedData]::Protect($plain, $script:LabInputEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $parent = Split-Path -Parent $LiteralPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($LiteralPath, $encrypted)
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }
    return [System.IO.Path]::GetFullPath($LiteralPath)
}

function Unprotect-HermesLabInput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    Add-Type -AssemblyName System.Security
    $encrypted = [System.IO.File]::ReadAllBytes($LiteralPath)
    $plain = $null
    try {
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($encrypted, $script:LabInputEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return ([System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json)
    } finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

function New-HermesLabEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )
    $environment = Get-HermesCuratedProcessEnvironment
    $environment['HERMES_HOME'] = $HermesHome
    $environment['VIRTUAL_ENV'] = Join-Path $InstallDir 'venv'
    $environment['PYTHONHOME'] = $null
    $environment['PYTHONPATH'] = $null
    $environment['PYTHONUSERBASE'] = $null
    $environment['PYTHONSTARTUP'] = $null
    $environment['PYTHONINSPECT'] = $null
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONSAFEPATH'] = '1'
    return $environment
}

function Invoke-HermesLabCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [int]$TimeoutSeconds = 120
    )
    $result = Invoke-HermesProcess -FilePath $CommandPath -ArgumentList $Arguments -Environment $Environment -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) {
        $detail = Protect-HermesLogText (($result.StdErr + [Environment]::NewLine + $result.StdOut).Trim())
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "exit code $($result.ExitCode)" }
        throw "Hermes 명령을 완료하지 못했습니다: $detail"
    }
    return $result
}

function Publish-HermesLabStage {
    param(
        [AllowNull()][scriptblock]$Callback,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][int]$Percent,
        [ValidateSet('running', 'succeeded', 'failed')][string]$State = 'running'
    )
    if ($null -ne $Callback) { [void](Publish-HermesEvent -Callback $Callback -Type 'stage' -Stage $Stage -State $State -Message $Message -Percent $Percent) }
}

function Register-HermesDashboardTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CommandPath,
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$HostAddress,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port
    )
    $serviceDir = Join-Path $RuntimeRoot 'dashboard-service'
    if (-not (Test-Path -LiteralPath $serviceDir -PathType Container)) { New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null }
    $runnerPath = Join-Path $serviceDir 'Start-HermesDashboard.ps1'
    $quote = { param([string]$Text); return "'" + $Text.Replace("'", "''") + "'" }
    $runnerLines = @(
        '$ErrorActionPreference = ''Stop'''
        ('$env:HERMES_HOME = {0}' -f (& $quote $HermesHome))
        ('& {0} -p default dashboard --port {1} --host {2} --open-profile {3} --no-open' -f (& $quote $CommandPath), $Port, (& $quote $HostAddress), (& $quote $Profile))
        'exit $LASTEXITCODE'
    )
    [System.IO.File]::WriteAllText($runnerPath, (($runnerLines -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    $powerShell = Get-HermesPowerShellExecutable
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File {0}' -f (ConvertTo-WindowsProcessArgument -Argument $runnerPath))
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 20 -RestartInterval ([TimeSpan]::FromMinutes(1)) -ExecutionTimeLimit ([TimeSpan]::Zero)
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Hermes Dashboard for Mattermost Bot Control'
    Register-ScheduledTask -TaskName $script:LabTaskName -InputObject $task -Force | Out-Null
    Start-ScheduledTask -TaskName $script:LabTaskName
    return [pscustomobject]@{ TaskName = $script:LabTaskName; RunnerPath = $runnerPath }
}

function Wait-HermesDashboard {
    param(
        [Parameter(Mandatory = $true)][string]$URL,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $loginBody = @{ provider = 'basic'; username = $Username; password = $Password } | ConvertTo-Json -Compress
            Invoke-WebRequest -Uri ($URL.TrimEnd('/') + '/auth/password-login') -Method Post -ContentType 'application/json' -Body $loginBody -WebSession $session -UseBasicParsing -TimeoutSec 5 | Out-Null
            return Invoke-RestMethod -Uri ($URL.TrimEnd('/') + '/api/status') -Method Get -WebSession $session -TimeoutSec 5
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 750
        }
    }
    throw "Hermes Dashboard가 제한 시간 안에 준비되지 않았습니다: $(Protect-HermesLogText $lastError)"
}

function Register-HermesWithBotControl {
    param(
        [Parameter(Mandatory = $true)][string]$MattermostURL,
        [Parameter(Mandatory = $true)][string]$BotToken,
        [Parameter(Mandatory = $true)][string]$DashboardURL,
        [Parameter(Mandatory = $true)][string]$DashboardUsername,
        [Parameter(Mandatory = $true)][string]$DashboardPassword,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$NetBirdIP,
        [Parameter(Mandatory = $true)][int]$DashboardPort,
        [AllowNull()][string]$HermesVersion
    )
    $endpoint = $MattermostURL.TrimEnd('/') + '/plugins/com.infonet.bot-control/api/v1/agents/register'
    $headers = @{ Authorization = 'Bearer ' + $BotToken }
    $payload = [ordered]@{
        dashboard_url = $DashboardURL
        dashboard_username = $DashboardUsername
        dashboard_password = $DashboardPassword
        profile = $Profile
        hostname = [Environment]::MachineName
        netbird_ip = $NetBirdIP
        dashboard_port = $DashboardPort
        hermes_version = [string]$HermesVersion
    }
    try {
        return Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Compress) -TimeoutSec 30
    } catch {
        $message = $_.Exception.Message
        if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            try {
                $serverError = $_.ErrorDetails.Message | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$serverError.message)) { $message = [string]$serverError.message }
            } catch {
                $message = $_.Exception.Message
            }
        }
        throw "Bot Control 자동 등록 실패: $(Protect-HermesLogText $message)"
    }
}

function Invoke-HermesLabSetup {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$FullName,
        [AllowNull()][string]$Role,
        [Parameter(Mandatory = $true)][string]$MattermostURL,
        [Parameter(Mandatory = $true)][string]$MattermostToken,
        [AllowNull()][string]$AllowedUserIDs,
        [AllowNull()][string]$HomeChannelID,
        [bool]$RequireMention = $true,
        [ValidateSet('off', 'thread')][string]$ReplyMode = 'off',
        [AllowNull()][string]$NetBirdIP,
        [ValidateRange(1024, 65535)][int]$DashboardPort = 9119,
        [Parameter(Mandatory = $true)][string]$DashboardUsername,
        [Parameter(Mandatory = $true)][string]$DashboardPassword,
        [switch]$ReuseExistingProfile,
        [AllowNull()][scriptblock]$ProgressCallback
    )
    Assert-HermesLabTextValue -Name '프로필 이름' -Value $ProfileName -MaximumLength 32
    if (-not (Test-HermesLabProfileName -Name $ProfileName)) { throw '프로필 이름은 소문자로 시작하고 소문자·숫자·-·_만 포함한 2~32자여야 하며 default는 사용할 수 없습니다.' }
    Assert-HermesLabTextValue -Name 'Full name' -Value $FullName -MaximumLength 200
    Assert-HermesLabTextValue -Name 'Mattermost URL' -Value $MattermostURL -MaximumLength 2048
    Assert-HermesLabTextValue -Name 'Mattermost bot token' -Value $MattermostToken -MaximumLength 4096
    Assert-HermesLabTextValue -Name 'Dashboard username' -Value $DashboardUsername -MaximumLength 200
    Assert-HermesLabTextValue -Name 'Dashboard password' -Value $DashboardPassword -MaximumLength 4096
    $Role = [string]$Role
    if ($Role.Length -gt 8000 -or $Role.IndexOf([char]0) -ge 0) { throw '역할은 8,000자 이하여야 합니다.' }
    $mattermostUri = $null
    if (-not [Uri]::TryCreate($MattermostURL, [UriKind]::Absolute, [ref]$mattermostUri) -or @('http', 'https') -cnotcontains $mattermostUri.Scheme) { throw 'Mattermost URL은 http:// 또는 https:// 주소여야 합니다.' }
    if ([string]::IsNullOrWhiteSpace($NetBirdIP)) { $NetBirdIP = Get-HermesNetBirdIPv4 }
    if (-not (Test-HermesNetBirdIPv4 -Address $NetBirdIP)) { throw 'NetBird IPv4를 찾지 못했습니다. NetBird 연결 후 100.64.0.0/10 주소를 입력하세요.' }
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'verify' -Message 'Hermes 설치 무결성을 확인합니다.' -Percent 5
    $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot
    if (-not $verification.Verified -or [string]::IsNullOrWhiteSpace([string]$verification.CommandPath)) { throw "검증된 Hermes 설치가 필요합니다: $(@($verification.FailedChecks) -join ', ')" }
    $command = [string]$verification.CommandPath
    $environment = New-HermesLabEnvironment -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    $profileDir = Join-Path (Join-Path $paths.HermesHome 'profiles') $ProfileName
    $profileAlreadyExisted = Test-Path -LiteralPath $profileDir -PathType Container
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'profile' -Message '새 Hermes 프로필을 준비합니다.' -Percent 15
    if ($profileAlreadyExisted) {
        if (-not $ReuseExistingProfile) { throw "Hermes 프로필 '$ProfileName'이 이미 있습니다. 다른 이름을 사용하거나 기존 프로필 이어서 설정을 선택하세요." }
    } else {
        [void](Invoke-HermesLabCommand -CommandPath $command -Arguments @('profile', 'create', $ProfileName, '--clone') -Environment $environment -TimeoutSeconds 180)
    }
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) { throw 'Hermes 프로필 폴더가 생성되지 않았습니다.' }
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'identity' -Message '에이전트 이름과 역할을 새 프로필에 적용합니다.' -Percent 28
    $soulPath = Join-Path $profileDir 'SOUL.md'
    $existingSoul = ''
    if ($profileAlreadyExisted -and (Test-Path -LiteralPath $soulPath -PathType Leaf)) { $existingSoul = [System.IO.File]::ReadAllText($soulPath, [System.Text.Encoding]::UTF8) }
    [System.IO.File]::WriteAllText($soulPath, (Merge-HermesLabSoul -Existing $existingSoul -FullName $FullName.Trim() -Role $Role), (New-Object System.Text.UTF8Encoding($false)))
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'mattermost' -Message 'Mattermost 연결값과 응답 정책을 프로필에 저장합니다.' -Percent 40
    $profileValues = @{
        MATTERMOST_URL = $MattermostURL.TrimEnd('/')
        MATTERMOST_TOKEN = $MattermostToken
        MATTERMOST_ALLOWED_USERS = [string]$AllowedUserIDs
        MATTERMOST_HOME_CHANNEL = [string]$HomeChannelID
        MATTERMOST_REQUIRE_MENTION = $(if ($RequireMention) { 'true' } else { 'false' })
        MATTERMOST_REPLY_MODE = $ReplyMode
    }
    Set-HermesLabEnvFile -LiteralPath (Join-Path $profileDir '.env') -Values $profileValues -RemovePrefixes @('MATTERMOST_', 'SLACK_', 'DISCORD_', 'TELEGRAM_', 'WHATSAPP_', 'SIGNAL_', 'IMESSAGE_', 'MATRIX_')
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'dashboard-auth' -Message 'Dashboard 인증을 구성합니다.' -Percent 50
    Set-HermesLabEnvFile -LiteralPath (Join-Path $paths.HermesHome '.env') -Values @{
        HERMES_DASHBOARD_BASIC_AUTH_USERNAME = $DashboardUsername
        HERMES_DASHBOARD_BASIC_AUTH_PASSWORD = $DashboardPassword
    }
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'dashboard-service' -Message 'NetBird Dashboard 자동 시작 작업을 등록합니다.' -Percent 62
    try {
        [void](Invoke-HermesLabCommand -CommandPath $command -Arguments @('dashboard', '--stop', '--port', [string]$DashboardPort) -Environment $environment -TimeoutSeconds 30)
    } catch {
    }
    $task = Register-HermesDashboardTask -CommandPath $command -HermesHome $paths.HermesHome -RuntimeRoot $paths.RuntimeRoot -Profile $ProfileName -HostAddress $NetBirdIP -Port $DashboardPort
    $dashboardURL = 'http://{0}:{1}' -f $NetBirdIP, $DashboardPort
    $dashboardStatus = Wait-HermesDashboard -URL $dashboardURL -Username $DashboardUsername -Password $DashboardPassword -TimeoutSeconds 75
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'bot-control' -Message 'Mattermost Bot Control에 이 Hermes 프로필을 등록합니다.' -Percent 76
    $versionResult = Invoke-HermesLabCommand -CommandPath $command -Arguments @('--version') -Environment $environment -TimeoutSeconds 60
    $versionLine = @($versionResult.StdOut -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $versionText = $(if ($versionLine.Count -gt 0) { [string]$versionLine[0] } else { 'Hermes Agent' })
    $registration = Register-HermesWithBotControl -MattermostURL $MattermostURL -BotToken $MattermostToken -DashboardURL $dashboardURL -DashboardUsername $DashboardUsername -DashboardPassword $DashboardPassword -Profile $ProfileName -NetBirdIP $NetBirdIP -DashboardPort $DashboardPort -HermesVersion $versionText
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'gateway' -Message '프로필 Gateway를 로그인 시 자동 시작하도록 설치합니다.' -Percent 88
    [void](Invoke-HermesLabCommand -CommandPath $command -Arguments @('-p', $ProfileName, 'gateway', 'install', '--force', '--start-now', '--start-on-login') -Environment $environment -TimeoutSeconds 180)
    $gatewayStatus = Invoke-HermesLabCommand -CommandPath $command -Arguments @('-p', $ProfileName, 'gateway', 'status') -Environment $environment -TimeoutSeconds 60
    Publish-HermesLabStage -Callback $ProgressCallback -Stage 'complete' -Message '연구실 Hermes 연결과 검증이 완료되었습니다.' -Percent 100 -State 'succeeded'
    return [pscustomobject][ordered]@{
        Profile = $ProfileName
        FullName = $FullName.Trim()
        MattermostURL = $MattermostURL.TrimEnd('/')
        NetBirdIP = $NetBirdIP
        DashboardURL = $dashboardURL
        DashboardTask = $task.TaskName
        DashboardReady = ($null -ne $dashboardStatus)
        BotUserID = [string]$registration.bot_user_id
        BotControlRegistered = (-not [string]::IsNullOrWhiteSpace([string]$registration.bot_user_id))
        GatewayRunning = ($gatewayStatus.StdOut -match '(?i)running')
        GatewayStatus = Protect-HermesLogText ($gatewayStatus.StdOut.Trim())
        HermesVersion = $versionText
    }
}

Export-ModuleMember -Function @(
    'Test-HermesLabProfileName',
    'Test-HermesNetBirdIPv4',
    'Get-HermesNetBirdIPv4',
    'Protect-HermesLabInput',
    'Unprotect-HermesLabInput',
    'Invoke-HermesLabSetup'
)
