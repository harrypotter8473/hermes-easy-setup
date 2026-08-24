Set-StrictMode -Version 2.0

function Get-HermesStageArguments {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$SourceConfig
    )

    $arguments = @(
        '-Commit', [string]$SourceConfig.hermes.commitSha,
        '-HermesHome', [string]$Plan.HermesHome,
        '-InstallDir', [string]$Plan.InstallDir,
        '-SkipSetup', '-NonInteractive', '-Json'
    )
    if ([bool]$Plan.IncludeDesktop) { $arguments += '-IncludeDesktop' }
    if ([bool]$Plan.SkipComputerUse) { $arguments += '-SkipComputerUse' }
    return $arguments
}

function Get-HermesStageTimeoutSeconds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Stage)

    switch ($Stage) {
        'dependencies' { return 5400 }
        'node-deps' { return 5400 }
        'platform-sdks' { return 5400 }
        'desktop' { return 10800 }
        default { return 1800 }
    }
}

function Test-HermesStageFrame {
    param(
        [AllowNull()]$Frame,
        [Parameter(Mandatory = $true)][string]$ExpectedStage
    )

    if ($null -eq $Frame) { return [pscustomobject]@{ Valid = $false; Reason = 'JSON 결과 프레임이 없습니다.' } }
    foreach ($property in @('stage', 'ok', 'skipped', 'reason', 'duration_ms')) {
        if ($Frame.PSObject.Properties.Name -notcontains $property) { return [pscustomobject]@{ Valid = $false; Reason = "결과 프레임에 '$property' 필드가 없습니다." } }
    }
    if ([string]$Frame.stage -ne $ExpectedStage) { return [pscustomobject]@{ Valid = $false; Reason = '결과 단계 이름이 요청과 다릅니다.' } }
    if ($Frame.ok -isnot [bool] -or $Frame.skipped -isnot [bool]) { return [pscustomobject]@{ Valid = $false; Reason = 'ok/skipped 필드가 Boolean이 아닙니다.' } }
    try { if ([int64]$Frame.duration_ms -lt 0) { throw 'negative' } } catch { return [pscustomobject]@{ Valid = $false; Reason = 'duration_ms가 올바르지 않습니다.' } }
    return [pscustomobject]@{ Valid = $true; Reason = $null }
}

function Get-HermesManagedGitPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$HermesHome)

    foreach ($candidate in @((Join-Path $HermesHome 'git\cmd\git.exe'), (Join-Path $HermesHome 'git\bin\git.exe'))) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $candidate -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $item.FullName }
    }
    return $null
}

function Read-HermesBootstrapMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $path = Join-Path $InstallDir '.hermes-bootstrap-complete'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ Path = $path; Valid = $false; SchemaVersion = $null; PinnedCommit = $null; Reason = 'marker missing' } }
    try {
        $marker = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $valid = ([int]$marker.schemaVersion -eq 1 -and [string]$marker.pinnedCommit -match '^[0-9a-fA-F]{40}$')
        return [pscustomobject]@{ Path = $path; Valid = $valid; SchemaVersion = [int]$marker.schemaVersion; PinnedCommit = [string]$marker.pinnedCommit; Reason = $(if ($valid) { $null } else { 'marker schema or commit invalid' }) }
    } catch {
        return [pscustomobject]@{ Path = $path; Valid = $false; SchemaVersion = $null; PinnedCommit = $null; Reason = 'marker JSON invalid' }
    }
}

function Test-HermesInstallation {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [string]$ExpectedCommit,
        [string]$LogPath,
        [AllowNull()][scriptblock]$ProgressCallback
    )

    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) { $ExpectedCommit = [string](Get-HermesSourceConfig).hermes.commitSha }
    if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') { Throw-HermesEasySetupError -Message '검증할 peeled commit이 올바르지 않습니다.' -ExitCode 50 -Category 'Verification' }
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        if (-not (Test-Path -LiteralPath $paths.LogDir -PathType Container)) { New-Item -ItemType Directory -Path $paths.LogDir -Force | Out-Null }
        $LogPath = Join-Path $paths.LogDir ("verify-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')).log")
    }

    $commandPath = Get-HermesCommandPath -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    $venvPython = Join-Path $paths.InstallDir 'venv\Scripts\python.exe'
    $marker = Read-HermesBootstrapMarker -InstallDir $paths.InstallDir
    $checkoutPresent = Test-Path -LiteralPath (Join-Path $paths.InstallDir '.git') -PathType Container
    $versionResult = $null
    $versionText = $null
    $commandWorks = $false
    if ($commandPath) {
        $versionResult = Invoke-HermesProcess -FilePath $commandPath -ArgumentList @('--version') -Environment @{ HERMES_HOME = $paths.HermesHome } -TimeoutSeconds 90
        Write-HermesCapturedOutput -ProcessResult $versionResult -LogPath $LogPath -Stage 'verify-version' -Callback $ProgressCallback
        $versionText = (($versionResult.StdOut + "`n" + $versionResult.StdErr).Trim() -split "`r?`n" | Select-Object -First 1)
        $commandWorks = ($versionResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($versionText))
    }

    $head = $null
    $origin = $null
    $clean = $false
    $git = Get-HermesManagedGitPath -HermesHome $paths.HermesHome
    if ($checkoutPresent -and $git) {
        $headResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', $paths.InstallDir, 'rev-parse', 'HEAD') -TimeoutSeconds 30
        if ($headResult.ExitCode -eq 0 -and $headResult.StdOut.Trim() -match '^[0-9a-fA-F]{40}$') { $head = $headResult.StdOut.Trim() }
        $originResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', $paths.InstallDir, 'remote', 'get-url', 'origin') -TimeoutSeconds 30
        if ($originResult.ExitCode -eq 0) { $origin = $originResult.StdOut.Trim() }
        $statusResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', $paths.InstallDir, 'status', '--porcelain', '--untracked-files=normal') -TimeoutSeconds 60
        $clean = ($statusResult.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($statusResult.StdOut))
    }
    $officialOrigins = @('https://github.com/NousResearch/hermes-agent.git', 'git@github.com:NousResearch/hermes-agent.git')
    $originOfficial = ($officialOrigins -contains $origin)
    $headMatches = (-not [string]::IsNullOrWhiteSpace($head) -and $head.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase))
    $markerMatches = ($marker.Valid -and $marker.PinnedCommit.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase))
    $venvPresent = Test-Path -LiteralPath $venvPython -PathType Leaf
    $verified = ($commandWorks -and $venvPresent -and $checkoutPresent -and $headMatches -and $originOfficial -and $clean -and $markerMatches)

    $doctorResult = $null
    if ($commandWorks) {
        $doctorResult = Invoke-HermesProcess -FilePath $commandPath -ArgumentList @('doctor') -Environment @{ HERMES_HOME = $paths.HermesHome } -TimeoutSeconds 240
        Write-HermesCapturedOutput -ProcessResult $doctorResult -LogPath $LogPath -Stage 'verify-doctor' -Callback $ProgressCallback
    }
    $doctorHealthy = ($null -ne $doctorResult -and $doctorResult.ExitCode -eq 0)

    return [pscustomobject]@{
        Installed = $verified
        Verified = $verified
        CommandWorks = $commandWorks
        CommandPath = $commandPath
        Version = Protect-HermesLogText $versionText
        VersionExitCode = $(if ($null -eq $versionResult) { $null } else { $versionResult.ExitCode })
        DoctorHealthy = $doctorHealthy
        DoctorExitCode = $(if ($null -eq $doctorResult) { $null } else { $doctorResult.ExitCode })
        DoctorSummary = $(if ($null -eq $doctorResult) { 'doctor를 실행하지 않았습니다.' } elseif ($doctorHealthy) { 'hermes doctor 통과' } else { '공급자 설정 전에는 doctor 경고가 정상일 수 있습니다.' })
        ExpectedCommit = $ExpectedCommit
        CheckoutHead = $head
        CheckoutHeadMatches = $headMatches
        CheckoutClean = $clean
        Origin = $origin
        OriginOfficial = $originOfficial
        VenvPythonPresent = $venvPresent
        BootstrapMarker = $marker.Valid
        MarkerPinnedCommit = $marker.PinnedCommit
        MarkerMatches = $markerMatches
        LogPath = $LogPath
    }
}

function Invoke-HermesInstall {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [switch]$IncludeDesktop,
        [switch]$SkipComputerUse,
        [ValidateSet('Later', 'Portal', 'Full')][string]$SetupMode = 'Portal',
        [switch]$Resume,
        [switch]$ForceDownload,
        [string]$ExpectedPlanFingerprint,
        [string]$SourceConfigPath,
        [AllowNull()][scriptblock]$Downloader,
        [AllowNull()][scriptblock]$ProgressCallback
    )

    if ([string]::IsNullOrWhiteSpace($SourceConfigPath)) { $SourceConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\hermes-source.json' }
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $sourceConfig = Get-HermesSourceConfig -LiteralPath $SourceConfigPath
    $plan = New-HermesInstallPlan -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -IncludeDesktop:$IncludeDesktop -SkipComputerUse:$SkipComputerUse -SetupMode $SetupMode -SourceConfigPath $SourceConfigPath
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and -not $plan.Fingerprint.Equals($ExpectedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-HermesEasySetupError -Message '승인한 설치 계획과 현재 실행 계획이 다릅니다. 계획을 다시 검토하고 승인하세요.' -ExitCode 2 -Category 'PlanApproval'
    }
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'plan' -State 'ready' -Message "검증 릴리스 $($plan.SourceTag), peeled commit $($plan.SourceCommit.Substring(0, 12))" -Percent 1 -Data $plan)

    $preflight = Get-HermesPreflight -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -IncludeDesktop:$IncludeDesktop
    if (-not $preflight.Ready) {
        $details = @($preflight.BlockingChecks | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; '
        Throw-HermesEasySetupError -Message "사전 점검을 통과하지 못했습니다: $details" -ExitCode 10 -Category 'Preflight'
    }

    foreach ($directory in @($paths.RuntimeRoot, $paths.LogDir, $paths.StateDir)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
    $logPath = Join-Path $paths.LogDir ("install-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')).log")
    Write-HermesEasySetupLog -LiteralPath $logPath -Message "설치 시작: fingerprint=$($plan.Fingerprint), home=$($paths.HermesHome), install=$($paths.InstallDir)"

    $lock = $null
    $state = $null
    try {
        $lock = Enter-HermesInstallLock -RuntimeRoot $paths.RuntimeRoot
        $installer = Get-HermesVerifiedInstaller -SourceConfig $sourceConfig -Paths $paths -ForceDownload:$ForceDownload -Downloader $Downloader -ProgressCallback $ProgressCallback -LogPath $logPath
        $manifest = Get-HermesInstallerManifest -InstallerPath $installer.Path -Plan $plan -SourceConfig $sourceConfig -LogPath $logPath -ProgressCallback $ProgressCallback

        $freshPlan = New-HermesInstallPlan -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -IncludeDesktop:$IncludeDesktop -SkipComputerUse:$SkipComputerUse -SetupMode $SetupMode -SourceConfigPath $SourceConfigPath
        if (-not $freshPlan.Fingerprint.Equals($plan.Fingerprint, [StringComparison]::OrdinalIgnoreCase) -or (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and -not $freshPlan.Fingerprint.Equals($ExpectedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase))) {
            Throw-HermesEasySetupError -Message '첫 변경 직전 계획 freshness 검사에 실패했습니다. 다시 진단하고 승인하세요.' -ExitCode 2 -Category 'PlanApproval'
        }

        $prior = Read-HermesInstallState -LiteralPath $paths.StateFile
        if ($Resume) {
            if (-not (Test-HermesStateCanResume -State $prior -Plan $freshPlan -Manifest $manifest)) {
                Throw-HermesEasySetupError -Message '재개 상태가 없거나 현재 계획·manifest와 다릅니다. -Resume 없이 새 계획으로 시작하세요.' -ExitCode 2 -Category 'Resume'
            }
            $state = Reset-HermesStateForSafeResume -State $prior
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'resume' -State 'accepted' -Message '체크포인트를 확인했습니다. 손상 복구를 위해 자동 단계를 안전하게 다시 적용합니다.' -Percent 11)
        } else {
            $state = New-HermesInstallState -Plan $freshPlan -Manifest $manifest
        }
        [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)

        $powershell = Get-HermesPowerShellExecutable
        $commonArgs = @(Get-HermesStageArguments -Plan $freshPlan -SourceConfig $sourceConfig)
        $environment = @{ HERMES_HOME = $paths.HermesHome }
        $stageList = @($manifest.stages)
        for ($index = 0; $index -lt $stageList.Count; $index++) {
            $stage = $stageList[$index]
            $name = [string]$stage.name
            $percentStart = 12 + [int](($index / [math]::Max(1, $stageList.Count)) * 72)
            $percentEnd = 12 + [int]((($index + 1) / [math]::Max(1, $stageList.Count)) * 72)
            if ([bool]$stage.needs_user_input) {
                $state = Set-HermesStageRecord -State $state -Name $name -Status 'Skipped' -Reason '공식 대화형 설정으로 별도 실행합니다.' -InstallerSha256 $installer.Sha256
                [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'skipped' -Message "$($stage.title): 설치 후 별도 설정" -Percent $percentEnd)
                continue
            }

            Assert-HermesInstallerIntegrity -LiteralPath $installer.Path -SourceConfig $sourceConfig
            $state = Set-HermesStageRecord -State $state -Name $name -Status 'Running' -InstallerSha256 $installer.Sha256
            [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'running' -Message ([string]$stage.title) -Percent $percentStart)
            Write-HermesEasySetupLog -LiteralPath $logPath -Message "단계 시작: $name / $($stage.title)"

            $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer.Path, '-Stage', $name) + $commonArgs
            $timeout = Get-HermesStageTimeoutSeconds -Stage $name
            $result = Invoke-HermesProcess -FilePath $powershell -ArgumentList $arguments -Environment $environment -TimeoutSeconds $timeout
            Write-HermesCapturedOutput -ProcessResult $result -LogPath $logPath -Stage $name -Callback $ProgressCallback
            $frame = ConvertFrom-HermesJsonFrame -Text $result.StdOut -RequiredProperty 'stage'
            $frameValidation = Test-HermesStageFrame -Frame $frame -ExpectedStage $name
            if (-not $frameValidation.Valid -or $result.ExitCode -ne 0 -or -not [bool]$frame.ok) {
                $reason = $(if ($result.TimedOut) { "단계 제한 시간 ${timeout}초를 초과해 프로세스 트리를 종료했습니다." } elseif (-not $frameValidation.Valid) { $frameValidation.Reason } elseif ($null -ne $frame -and -not [string]::IsNullOrWhiteSpace([string]$frame.reason)) { [string]$frame.reason } else { "공식 설치기 종료 코드 $($result.ExitCode)" })
                $duration = $(if ($null -ne $frame -and $frame.PSObject.Properties.Name -contains 'duration_ms') { [int]$frame.duration_ms } else { [int]$result.DurationMs })
                $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -DurationMs $duration -InstallerSha256 $installer.Sha256
                $state.status = 'Failed'
                [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'failed' -Message (Protect-HermesLogText $reason) -Percent $percentStart)
                Throw-HermesEasySetupError -Message "Hermes 설치 단계 '$name' 실패: $(Protect-HermesLogText $reason)" -ExitCode 40 -Category 'InstallStage'
            }
            $stageStatus = $(if ([bool]$frame.skipped) { 'Skipped' } else { 'Succeeded' })
            $state = Set-HermesStageRecord -State $state -Name $name -Status $stageStatus -Reason ([string]$frame.reason) -DurationMs ([int]$frame.duration_ms) -InstallerSha256 $installer.Sha256
            [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State $stageStatus.ToLowerInvariant() -Message ([string]$stage.title) -Percent $percentEnd)
        }

        [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'verify' -State 'running' -Message '대상 launcher, venv, origin, checkout, marker를 검증하는 중입니다.' -Percent 88)
        $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -LogPath $logPath -ProgressCallback $ProgressCallback
        $state.verification = [pscustomobject]@{
            verified = [bool]$verification.Verified
            version = [string]$verification.Version
            doctor_healthy = [bool]$verification.DoctorHealthy
            checkout_head = [string]$verification.CheckoutHead
            origin = [string]$verification.Origin
            marker_commit = [string]$verification.MarkerPinnedCommit
        }
        if (-not $verification.Verified) {
            $state.status = 'Failed'
            [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
            Throw-HermesEasySetupError -Message '공식 단계는 끝났지만 대상 launcher/venv/origin/고정 commit/bootstrap marker 검증에 실패했습니다.' -ExitCode 50 -Category 'Verification'
        }

        $state.status = 'Completed'
        $state.completed_at = (Get-Date).ToUniversalTime().ToString('o')
        $state.updated_at = $state.completed_at
        [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
        [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'complete' -State 'succeeded' -Message "Hermes 설치 완료: $($verification.Version)" -Percent 100 -Data $verification)
        Write-HermesEasySetupLog -LiteralPath $logPath -Message "설치 완료: version=$($verification.Version), commit=$($verification.CheckoutHead), doctor=$($verification.DoctorHealthy)"
        return [pscustomobject]@{ Succeeded = $true; Plan = $freshPlan; Verification = $verification; SetupMode = $SetupMode; StatePath = $paths.StateFile; LogPath = $logPath }
    } catch {
        if ($null -ne $state -and [string]$state.status -ne 'Completed') {
            $state.status = 'Failed'
            $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
            try { [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state) } catch {}
        }
        Write-HermesEasySetupLog -LiteralPath $logPath -Message $_.Exception.Message -Level 'ERROR'
        throw
    } finally {
        Exit-HermesInstallLock -Lock $lock
    }
}

function Start-HermesOfficialSetup {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [ValidateSet('Later', 'Portal', 'Full')][string]$Mode = 'Portal',
        [switch]$Wait
    )

    if ($Mode -eq 'Later') { return [pscustomobject]@{ Started = $false; Reason = 'Later' } }
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir
    $command = Get-HermesCommandPath -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    if (-not $command) { Throw-HermesEasySetupError -Message '대상 설치 경로의 hermes 명령을 찾지 못해 설정을 열 수 없습니다.' -ExitCode 50 -Category 'Setup' }
    $arguments = @('setup')
    if ($Mode -eq 'Portal') { $arguments += '--portal' }
    $previous = $env:HERMES_HOME
    try {
        $env:HERMES_HOME = $paths.HermesHome
        $process = Start-Process -FilePath $command -ArgumentList $arguments -PassThru -Wait:$Wait -WindowStyle Normal
        return [pscustomobject]@{ Started = $true; ProcessId = $process.Id; Mode = $Mode; Command = $command }
    } finally {
        $env:HERMES_HOME = $previous
    }
}

Export-ModuleMember -Function @(
    'Get-HermesStageArguments', 'Get-HermesStageTimeoutSeconds', 'Test-HermesStageFrame',
    'Read-HermesBootstrapMarker', 'Test-HermesInstallation', 'Invoke-HermesInstall',
    'Start-HermesOfficialSetup'
)
