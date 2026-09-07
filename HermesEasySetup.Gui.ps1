[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force

$xamlPath = Join-Path $PSScriptRoot 'ui\MainWindow.xaml'
$reader = New-Object System.Xml.XmlNodeReader ([xml][System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8))
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = @(
    'StepText', 'WelcomePanel', 'DiagnoseButton', 'DiagnosisText', 'ExistingSetupModeCombo',
    'ExistingSetupButton', 'WelcomeCloseButton', 'ToPlanButton',
    'PlanPanel', 'IncludeDesktopCheck', 'SkipComputerUseCheck', 'SetupModeCombo', 'PlanText', 'ApprovalCheck',
    'BackButton', 'InstallButton', 'WorkPanel', 'WorkTitle', 'WorkStatus', 'InstallProgress', 'WorkLog',
    'BundleButton', 'FinishButton', 'SetupPanel', 'SetupTitle', 'SetupStatus', 'SetupDetails',
    'SetupLaterButton', 'SetupStartButton', 'SetupLabButton', 'SetupFinishButton',
    'LabPanel', 'LabProfileName', 'LabFullName', 'LabRole', 'LabReuseProfile',
    'LabMattermostURL', 'LabBotToken', 'LabAllowedUserIDs', 'LabHomeChannelID',
    'LabRequireMention', 'LabReplyMode', 'LabNetBirdIP', 'LabDetectNetBirdButton',
    'LabDashboardPort', 'LabDashboardUsername', 'LabDashboardPassword',
    'LabProgress', 'LabStatus', 'LabBackButton', 'LabCloseButton', 'LabApplyButton'
)
$ui = @{}
foreach ($name in $names) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "필수 UI 컨트롤을 찾지 못했습니다: $name" }
    $ui[$name] = $control
}

$script:worker = $null
$script:timer = $null
$script:stdoutLines = 0
$script:stderrLines = 0
$script:transportOut = $null
$script:transportErr = $null
$script:lastResult = $null
$script:approvedPlanFingerprint = $null
$script:paths = Get-HermesDefaultPaths
$script:setupWorker = $null
$script:setupTimer = $null
$script:setupTransportOut = $null
$script:setupStdoutLines = 0
$script:setupStartedSeen = $false
$script:setupClosedSeen = $false
$script:setupLastError = $null
$script:existingInstallSetupAvailable = $false
$script:existingInstallSetup = $false
$script:labWorker = $null
$script:labTimer = $null
$script:labTransportOut = $null
$script:labTransportErr = $null
$script:labInputPath = $null
$script:labStdoutLines = 0
$script:labStderrLines = 0
$script:labResult = $null

function Get-SelectedSetupMode {
    $selected = $ui.SetupModeCombo.SelectedItem
    if ($null -eq $selected) { return 'Portal' }
    return [string]$selected.Tag
}

function Show-WizardPanel {
    param([ValidateSet('Welcome', 'Plan', 'Work', 'Setup', 'Lab')][string]$Name)
    $ui.WelcomePanel.Visibility = $(if ($Name -eq 'Welcome') { 'Visible' } else { 'Collapsed' })
    $ui.PlanPanel.Visibility = $(if ($Name -eq 'Plan') { 'Visible' } else { 'Collapsed' })
    $ui.WorkPanel.Visibility = $(if ($Name -eq 'Work') { 'Visible' } else { 'Collapsed' })
    $ui.SetupPanel.Visibility = $(if ($Name -eq 'Setup') { 'Visible' } else { 'Collapsed' })
    $ui.LabPanel.Visibility = $(if ($Name -eq 'Lab') { 'Visible' } else { 'Collapsed' })
    $ui.StepText.Text = switch ($Name) {
        'Welcome' { '1 / 5  PC 확인' }
        'Plan' { '2 / 5  설치 계획과 승인' }
        'Work' { '3 / 5  설치와 검증' }
        'Setup' { '4 / 5  공식 설정' }
        default { '5 / 5  연구실 연결' }
    }
}

function Add-WorkLog {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $ui.WorkLog.AppendText((Protect-HermesLogText $Message) + [Environment]::NewLine)
    if ($ui.WorkLog.Text.Length -gt 60000) { $ui.WorkLog.Text = $ui.WorkLog.Text.Substring($ui.WorkLog.Text.Length - 45000) }
    $ui.WorkLog.ScrollToEnd()
}

function Refresh-Plan {
    $script:approvedPlanFingerprint = $null
    $ui.ApprovalCheck.IsChecked = $false
    $ui.InstallButton.IsEnabled = $false
    try {
        $plan = New-HermesInstallPlan -IncludeDesktop:([bool]$ui.IncludeDesktopCheck.IsChecked) `
            -SkipComputerUse:([bool]$ui.SkipComputerUseCheck.IsChecked) -SetupMode (Get-SelectedSetupMode)
        $script:approvedPlanFingerprint = [string]$plan.Fingerprint
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("검증 릴리스: $($plan.SourceTag)")
        $lines.Add("peeled commit: $($plan.SourceCommit)")
        $lines.Add("설치기 SHA-256: $($plan.SourceSha256)")
        $lines.Add("manifest 계약 SHA-256: $($plan.ManifestContractSha256)")
        $lines.Add("계획 지문: $($plan.Fingerprint)")
        $lines.Add("Hermes 데이터: $($plan.HermesHome)")
        $lines.Add("Hermes 코드: $($plan.InstallDir)")
        $lines.Add("마법사 상태/로그: $($plan.RuntimeRoot)")
        $lines.Add("Desktop 포함: $($plan.IncludeDesktop)")
        $lines.Add("Computer Use 사전 설치 건너뜀: $($plan.SkipComputerUse)")
        $lines.Add('')
        foreach ($action in $plan.Actions) { $lines.Add(("{0}. {1} — {2}" -f $action.Order, $action.Name, $action.Detail)) }
        $lines.Add('')
        $lines.Add('보존 원칙: 기존 .env, config.yaml, skills, sessions, memories는 마법사가 직접 읽거나 삭제하지 않습니다.')
        $lines.Add('공급망 범위: 고정 공식 설치 스크립트는 검증하지만 모든 하위 패키지의 재현성까지 보증하지는 않습니다.')
        $ui.PlanText.Text = $lines -join [Environment]::NewLine
    } catch {
        $script:approvedPlanFingerprint = $null
        $ui.PlanText.Text = "계획 생성 실패: $(Protect-HermesLogText $_.Exception.Message)"
    }
}

function Invoke-ReadOnlyDiagnosis {
    $script:existingInstallSetupAvailable = $false
    $script:existingInstallSetup = $false
    $ui.ExistingSetupModeCombo.Visibility = 'Collapsed'
    $ui.ExistingSetupModeCombo.IsEnabled = $false
    $ui.ExistingSetupButton.Visibility = 'Collapsed'
    $ui.ExistingSetupButton.IsEnabled = $false
    $ui.ToPlanButton.Content = '설치 계획 보기'
    $ui.DiagnoseButton.IsEnabled = $false
    $ui.DiagnosisText.Text = '확인 중...'
    try {
        $diagnosis = Get-HermesPreflight
        $completedExistingInstall = $false
        $existingState = Read-HermesInstallState -LiteralPath $script:paths.StateFile
        $sourceConfig = Get-HermesSourceConfig
        $existingEligibility = Test-HermesCompletedInstallForSetup -Diagnosis $diagnosis -State $existingState -Paths $script:paths -ExpectedCommit ([string]$sourceConfig.hermes.commitSha)
        $completedExistingInstall = [bool]$existingEligibility.Eligible

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($check in $diagnosis.Checks) {
            $mark = switch ($check.Status) { 'Pass' { '[통과]' } 'Info' { '[정보]' } 'Warn' { '[주의]' } default { '[실패]' } }
            $lines.Add("$mark $($check.Name) — $($check.Detail)")
        }
        $lines.Add('')
        if ($completedExistingInstall) {
            $lines.Add('이 마법사가 완료한 기존 Hermes 설치를 찾았습니다. 다시 설치하지 않고 공식 설정만 계속할 수 있습니다. 설정 창을 열기 직전에 현재 설치를 다시 검증합니다.')
            $script:existingInstallSetupAvailable = $true
            $ui.ExistingSetupModeCombo.Visibility = 'Visible'
            $ui.ExistingSetupModeCombo.IsEnabled = $true
            $ui.ExistingSetupButton.Visibility = 'Visible'
            $ui.ExistingSetupButton.IsEnabled = $true
        } else {
            $lines.Add($(if ($diagnosis.Ready) { '설치 계획을 검토할 준비가 되었습니다.' } else { '필수 점검 실패를 해결한 뒤 다시 시도하세요.' }))
        }
        $ui.DiagnosisText.Text = $lines -join [Environment]::NewLine
        $ui.ToPlanButton.IsEnabled = ([bool]$diagnosis.Ready -and -not $completedExistingInstall)
        $ui.ToPlanButton.Content = $(if ($completedExistingInstall) { '기존 설치 감지됨' } else { '설치 계획 보기' })
    } catch {
        $ui.DiagnosisText.Text = "PC 확인 실패: $(Protect-HermesLogText $_.Exception.Message)"
        $ui.ToPlanButton.IsEnabled = $false
        $ui.ExistingSetupModeCombo.Visibility = 'Collapsed'
        $ui.ExistingSetupModeCombo.IsEnabled = $false
        $ui.ExistingSetupButton.Visibility = 'Collapsed'
        $ui.ExistingSetupButton.IsEnabled = $false
    } finally {
        $ui.DiagnoseButton.IsEnabled = $true
    }
}

function Handle-WorkerEvent {
    param($EventObject)
    if ($null -eq $EventObject) { return }
    if ($EventObject.PSObject.Properties.Name -contains 'percent' -and [int]$EventObject.percent -ge 0) {
        $ui.InstallProgress.Value = [math]::Min(100, [math]::Max(0, [int]$EventObject.percent))
    }
    switch ([string]$EventObject.type) {
        'log' { Add-WorkLog ("[$($EventObject.stage)] $($EventObject.message)") }
        'stage' { $ui.WorkStatus.Text = [string]$EventObject.message; Add-WorkLog ("[$($EventObject.state)] $($EventObject.stage): $($EventObject.message)") }
        'error' { $ui.WorkStatus.Text = [string]$EventObject.message; Add-WorkLog ("[오류] $($EventObject.message)") }
        'complete' {
            if ([string]$EventObject.state -ceq 'succeeded' -and
                $EventObject.PSObject.Properties.Name -contains 'data' -and
                $null -ne $EventObject.data) {
                $script:lastResult = $EventObject.data
            }
            $ui.WorkStatus.Text = [string]$EventObject.message
            Add-WorkLog ("[완료] $($EventObject.message)")
        }
        default { if (-not [string]::IsNullOrWhiteSpace([string]$EventObject.message)) { Add-WorkLog ([string]$EventObject.message) } }
    }
}

function Read-TransportFiles {
    $outLines = @()
    if ($script:transportOut -and (Test-Path -LiteralPath $script:transportOut -PathType Leaf)) { $outLines = @(Get-Content -LiteralPath $script:transportOut -Encoding UTF8 -ErrorAction SilentlyContinue) }
    for ($index = $script:stdoutLines; $index -lt $outLines.Count; $index++) {
        $line = [string]$outLines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { Handle-WorkerEvent ($line | ConvertFrom-Json) } catch { Add-WorkLog $line }
    }
    $script:stdoutLines = $outLines.Count

    $errLines = @()
    if ($script:transportErr -and (Test-Path -LiteralPath $script:transportErr -PathType Leaf)) { $errLines = @(Get-Content -LiteralPath $script:transportErr -Encoding UTF8 -ErrorAction SilentlyContinue) }
    for ($index = $script:stderrLines; $index -lt $errLines.Count; $index++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$errLines[$index])) { Add-WorkLog ("[worker] " + [string]$errLines[$index]) }
    }
    $script:stderrLines = $errLines.Count
}

function Complete-Worker {
    if ($null -eq $script:worker) { return }
    $localWorker = $script:worker
    if ($null -ne $script:timer) { $script:timer.Stop() }
    $localWorker.WaitForExit()
    Read-TransportFiles

    $exitCode = $null
    $exitCodeAvailable = $false
    try {
        $candidateExitCode = $localWorker.ExitCode
        if ($null -ne $candidateExitCode) {
            $exitCode = [int]$candidateExitCode
            $exitCodeAvailable = $true
        }
    } catch {
        Add-WorkLog '[worker] Windows가 설치 프로세스 종료 코드를 제공하지 않았습니다. 완료 이벤트와 상태 파일을 함께 검증합니다.'
    }
    $state = $null
    try {
        $state = Read-HermesInstallState -LiteralPath $script:paths.StateFile
    } catch {
        Add-WorkLog ("[worker] 설치 상태 파일을 읽지 못했습니다: " + (Protect-HermesLogText $_.Exception.Message))
    }
    $outcome = Resolve-HermesInstallWorkerOutcome -ExitCode $exitCode -ExitCodeAvailable:$exitCodeAvailable -CompletionData $script:lastResult -State $state -ExpectedPlanFingerprint $script:approvedPlanFingerprint
    $verifiedSuccess = ([bool]$outcome.Succeeded -and (-not $exitCodeAvailable -or $exitCode -eq 0))

    if ($verifiedSuccess) {
        $ui.WorkTitle.Text = 'Hermes 설치가 완료되었습니다.'
        $ui.WorkStatus.Text = '설치와 검증이 완료되었습니다. 다음 단계에서 공식 Hermes 설정을 진행할 수 있습니다.'
        $ui.InstallProgress.Value = 100
    } elseif ($exitCodeAvailable -and $exitCode -ne 0) {
        $ui.WorkTitle.Text = '설치를 완료하지 못했습니다.'
        $ui.WorkStatus.Text = "종료 코드 $exitCode. 같은 계획의 실패 체크포인트가 있으면 안전 재적용 방식으로 이어갈 수 있습니다."
        Add-WorkLog $ui.WorkStatus.Text
    } else {
        $ui.WorkTitle.Text = '설치 결과를 확인하지 못했습니다.'
        $ui.WorkStatus.Text = "종료 코드와 검증 증거가 일치하지 않습니다 ($($outcome.Reason)). 진단 ZIP을 확인한 뒤 다시 시도하세요."
        Add-WorkLog $ui.WorkStatus.Text
    }
    $ui.BundleButton.Visibility = 'Visible'
    $ui.FinishButton.IsEnabled = $true
    $localWorker.Dispose()
    $script:worker = $null
    $script:timer = $null
    foreach ($transport in @($script:transportOut, $script:transportErr)) { if ($transport -and (Test-Path -LiteralPath $transport -PathType Leaf)) { Remove-Item -LiteralPath $transport -Force -ErrorAction SilentlyContinue } }
    $script:transportOut = $null
    $script:transportErr = $null
    if ($verifiedSuccess) {
        $script:existingInstallSetup = $false
        Show-SetupStep
    }
}

function Start-InstallWorker {
    if ($ui.ApprovalCheck.IsChecked -ne $true -or [string]::IsNullOrWhiteSpace($script:approvedPlanFingerprint)) {
        [Windows.MessageBox]::Show('현재 계획을 먼저 검토하고 동의 체크박스를 선택하세요.', 'Hermes Easy Setup') | Out-Null
        return
    }
    $ui.WorkTitle.Text = 'Hermes를 설치하고 있습니다.'
    $ui.WorkStatus.Text = '승인 계획과 현재 계획을 다시 대조하는 중...'
    $ui.InstallProgress.Value = 0
    $ui.WorkLog.Clear()
    $script:lastResult = $null
    $script:existingInstallSetup = $false
    $ui.FinishButton.IsEnabled = $false
    $ui.BundleButton.Visibility = 'Collapsed'
    Show-WizardPanel 'Work'

    $transportDir = Join-Path $script:paths.RuntimeRoot 'ui-transport'
    if (-not (Test-Path -LiteralPath $transportDir -PathType Container)) { New-Item -ItemType Directory -Path $transportDir -Force | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $script:transportOut = Join-Path $transportDir "worker-$stamp.out"
    $script:transportErr = Join-Path $transportDir "worker-$stamp.err"
    $script:stdoutLines = 0
    $script:stderrLines = 0

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'HermesEasySetup.ps1'),
        '-Action', 'Install', '-Apply', '-JsonEvents', '-SetupMode', (Get-SelectedSetupMode),
        '-ExpectedPlanFingerprint', $script:approvedPlanFingerprint,
        '-HermesHome', $script:paths.HermesHome, '-InstallDir', $script:paths.InstallDir, '-RuntimeRoot', $script:paths.RuntimeRoot
    )
    if ([bool]$ui.IncludeDesktopCheck.IsChecked) { $arguments += '-IncludeDesktop' }
    if ([bool]$ui.SkipComputerUseCheck.IsChecked) { $arguments += '-SkipComputerUse' }
    $prior = Read-HermesInstallState -LiteralPath $script:paths.StateFile
    if ($null -ne $prior -and @('Running', 'Failed') -contains [string]$prior.status -and [string]$prior.plan_fingerprint -eq $script:approvedPlanFingerprint) { $arguments += '-Resume' }
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument -Argument ([string]$_) }) -join ' '
    $script:worker = Start-Process -FilePath (Get-HermesPowerShellExecutable) -ArgumentList $argumentLine -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $script:transportOut -RedirectStandardError $script:transportErr
    [void]$script:worker.Handle

    $script:timer = New-Object Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:timer.Add_Tick({
        if ($null -ne $script:worker -and $script:worker.HasExited) { Complete-Worker } else { Read-TransportFiles }
    })
    $script:timer.Start()
}

function Open-ExistingInstallSetupStep {
    if (-not $script:existingInstallSetupAvailable) { return }
    $selected = $ui.ExistingSetupModeCombo.SelectedItem
    $selectedMode = $(if ($null -eq $selected) { $null } else { [string]$selected.Tag })
    if (@('Portal', 'Full') -cnotcontains $selectedMode) { return }
    $targetItem = @($ui.SetupModeCombo.Items | Where-Object { [string]$_.Tag -ceq $selectedMode } | Select-Object -First 1)[0]
    if ($null -eq $targetItem) { return }
    $ui.SetupModeCombo.SelectedItem = $targetItem
    if ((Get-SelectedSetupMode) -cne $selectedMode) { return }
    $script:existingInstallSetup = $true
    Show-SetupStep
}

function Set-SetupDeferred {
    $ui.SetupTitle.Text = 'Hermes 설치가 완료되었습니다.'
    $ui.SetupStatus.Text = '공식 설정은 나중에 진행하도록 선택했습니다.'
    $ui.SetupDetails.Text = '설치와 검증은 완료되었습니다. 나중에 새 터미널에서 hermes setup을 실행하면 됩니다. Portal 방식을 원하면 hermes setup --portal을 실행하세요.'
    $ui.SetupLaterButton.Visibility = 'Collapsed'
    $ui.SetupLaterButton.IsEnabled = $false
    $ui.SetupStartButton.Visibility = 'Collapsed'
    $ui.SetupStartButton.IsEnabled = $false
    $ui.SetupLabButton.IsEnabled = $true
    $ui.SetupFinishButton.IsEnabled = $true
    $ui.SetupLabButton.Focus() | Out-Null
}

function Show-SetupStep {
    Show-WizardPanel 'Setup'
    $ui.SetupLaterButton.Visibility = 'Visible'
    $ui.SetupStartButton.Visibility = 'Visible'
    $ui.SetupLaterButton.IsEnabled = $false
    $ui.SetupStartButton.IsEnabled = $false
    $ui.SetupLabButton.IsEnabled = $false
    $ui.SetupFinishButton.IsEnabled = $false
    $ui.SetupStartButton.Content = '공식 설정 시작'

    if ((Get-SelectedSetupMode) -eq 'Later') {
        Set-SetupDeferred
        return
    }

    if ($script:existingInstallSetup) {
        $ui.SetupTitle.Text = '기존 Hermes 완료 기록에서 공식 설정을 계속합니다.'
        $ui.SetupStatus.Text = '설정 시작 시 현재 설치의 무결성과 실행 상태를 다시 검증합니다.'
        $ui.SetupDetails.Text = '검증을 통과한 경우에만 별도의 공식 Hermes 콘솔이 열립니다. 로그인, 모델 선택, API 키 입력은 그 공식 창에서만 진행되며 이 마법사는 콘솔 내용을 읽거나 저장하지 않습니다.'
    } else {
        $ui.SetupTitle.Text = 'Hermes 설치가 완료되었습니다. 이제 공식 설정을 진행하세요.'
        $ui.SetupStatus.Text = '설정 시작을 누르면 별도의 공식 Hermes 콘솔이 열립니다.'
        $ui.SetupDetails.Text = '로그인, 모델 선택, API 키 입력은 Hermes 공식 콘솔에서만 진행됩니다. 이 마법사는 콘솔 내용을 읽거나 저장하지 않으며, 창이 닫혀도 설정 성공 여부를 단정하지 않습니다.'
    }
    $ui.SetupLaterButton.IsEnabled = $true
    $ui.SetupStartButton.IsEnabled = $true
    $ui.SetupLabButton.IsEnabled = $true
    $ui.SetupStartButton.Focus() | Out-Null
}

function Handle-SetupWorkerEvent {
    param($EventObject)
    if ($null -eq $EventObject) { return }
    $type = [string]$EventObject.type
    if ($type -ceq 'setup') {
        $state = [string]$EventObject.state
        if ($state -ceq 'starting') {
            $script:setupStartedSeen = $true
            $ui.SetupStatus.Text = '현재 설치를 검증하고 공식 Hermes 설정 창을 여는 중입니다.'
        } elseif ($state -ceq 'closed') {
            $script:setupClosedSeen = $true
            $ui.SetupStatus.Text = '공식 Hermes 설정 창이 닫혔습니다.'
        }
    } elseif ($type -ceq 'error') {
        $script:setupLastError = Protect-HermesLogText ([string]$EventObject.message)
        $ui.SetupStatus.Text = $script:setupLastError
    }
}

function Read-SetupTransportFile {
    $outLines = @()
    if ($script:setupTransportOut -and (Test-Path -LiteralPath $script:setupTransportOut -PathType Leaf)) {
        $outLines = @(Get-Content -LiteralPath $script:setupTransportOut -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    for ($index = $script:setupStdoutLines; $index -lt $outLines.Count; $index++) {
        $line = [string]$outLines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $eventObject = $line | ConvertFrom-Json
            if ([string]$eventObject.type -ceq 'setup' -or [string]$eventObject.type -ceq 'error') {
                Handle-SetupWorkerEvent $eventObject
            }
        } catch {
            # Raw output is intentionally ignored: official setup content never belongs in the wizard log.
        }
    }
    $script:setupStdoutLines = $outLines.Count
}

function Complete-SetupWorker {
    if ($null -eq $script:setupWorker) { return }
    $localSetupWorker = $script:setupWorker
    if ($null -ne $script:setupTimer) { $script:setupTimer.Stop() }
    $localSetupWorker.WaitForExit()
    Read-SetupTransportFile

    if ($script:setupStartedSeen -and $script:setupClosedSeen) {
        $ui.SetupTitle.Text = '공식 Hermes 설정 창이 닫혔습니다.'
        $ui.SetupStatus.Text = '설정 완료 여부는 이 마법사에서 확인하지 않았습니다.'
        $ui.SetupDetails.Text = 'Hermes 공식 설정은 취소나 일부 오류 뒤에도 창이 닫힐 수 있습니다. 설정이 끝나지 않았다면 “공식 설정 다시 열기”를 누르세요. 설치와 검증 결과에는 영향이 없습니다.'
    } else {
        $ui.SetupTitle.Text = '공식 설정 상태를 확인하지 못했습니다.'
        $ui.SetupStatus.Text = $(if ([string]::IsNullOrWhiteSpace($script:setupLastError)) { '설정 추적 프로세스가 예상보다 일찍 종료되었습니다.' } else { $script:setupLastError })
        $ui.SetupDetails.Text = 'Hermes 설치는 이미 완료되었습니다. 공식 설정을 다시 열거나 나중에 터미널에서 hermes setup을 실행할 수 있습니다.'
    }

    $localSetupWorker.Dispose()
    $script:setupWorker = $null
    $script:setupTimer = $null
    if ($script:setupTransportOut -and (Test-Path -LiteralPath $script:setupTransportOut -PathType Leaf)) {
        Remove-Item -LiteralPath $script:setupTransportOut -Force -ErrorAction SilentlyContinue
    }
    $script:setupTransportOut = $null
    $ui.SetupStartButton.Content = '공식 설정 다시 열기'
    $ui.SetupStartButton.IsEnabled = $true
    $ui.SetupLaterButton.IsEnabled = $true
    $ui.SetupLabButton.IsEnabled = $true
    $ui.SetupFinishButton.IsEnabled = $true
}

function Start-SetupWorker {
    if ($null -ne $script:setupWorker) { return }
    if ((Get-SelectedSetupMode) -eq 'Later') {
        Set-SetupDeferred
        return
    }

    $script:setupStartedSeen = $false
    $script:setupClosedSeen = $false
    $script:setupLastError = $null
    $script:setupStdoutLines = 0
    $ui.SetupTitle.Text = '공식 Hermes 설정을 진행 중입니다.'
    $ui.SetupStatus.Text = '별도의 공식 Hermes 콘솔을 준비하고 있습니다.'
    $ui.SetupDetails.Text = '로그인과 API 키 입력은 새로 열리는 공식 콘솔에서만 진행하세요. 설정 창이 닫힐 때까지 이 마법사는 상태만 기다립니다.'
    $ui.SetupLaterButton.IsEnabled = $false
    $ui.SetupStartButton.IsEnabled = $false
    $ui.SetupLabButton.IsEnabled = $false
    $ui.SetupFinishButton.IsEnabled = $false

    $transportDir = Join-Path $script:paths.RuntimeRoot 'ui-transport'
    if (-not (Test-Path -LiteralPath $transportDir -PathType Container)) { New-Item -ItemType Directory -Path $transportDir -Force | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $script:setupTransportOut = Join-Path $transportDir "setup-worker-$stamp.out"
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'HermesEasySetup.ps1'),
        '-Action', 'Setup', '-WaitForSetup', '-JsonEvents', '-SetupMode', (Get-SelectedSetupMode),
        '-HermesHome', $script:paths.HermesHome, '-InstallDir', $script:paths.InstallDir, '-RuntimeRoot', $script:paths.RuntimeRoot
    )
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument -Argument ([string]$_) }) -join ' '
    try {
        $script:setupWorker = Start-Process -FilePath (Get-HermesPowerShellExecutable) -ArgumentList $argumentLine -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $script:setupTransportOut
        [void]$script:setupWorker.Handle
    } catch {
        if ($null -ne $script:setupWorker) { $script:setupWorker.Dispose() }
        $script:setupWorker = $null
        $script:setupLastError = Protect-HermesLogText $_.Exception.Message
        $ui.SetupTitle.Text = '공식 설정을 열 수 없습니다.'
        $ui.SetupStatus.Text = $script:setupLastError
        $ui.SetupDetails.Text = 'Hermes 설치에는 영향이 없습니다. 공식 설정을 다시 열거나 나중에 hermes setup을 실행하세요.'
        $ui.SetupStartButton.Content = '공식 설정 다시 열기'
        $ui.SetupStartButton.IsEnabled = $true
        $ui.SetupLaterButton.IsEnabled = $true
        $ui.SetupLabButton.IsEnabled = $true
        $ui.SetupFinishButton.IsEnabled = $true
        if ($script:setupTransportOut -and (Test-Path -LiteralPath $script:setupTransportOut -PathType Leaf)) {
            Remove-Item -LiteralPath $script:setupTransportOut -Force -ErrorAction SilentlyContinue
        }
        $script:setupTransportOut = $null
        return
    }

    $script:setupTimer = New-Object Windows.Threading.DispatcherTimer
    $script:setupTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:setupTimer.Add_Tick({
        if ($null -ne $script:setupWorker -and $script:setupWorker.HasExited) { Complete-SetupWorker } else { Read-SetupTransportFile }
    })
    $script:setupTimer.Start()
}

function Get-SelectedLabReplyMode {
    $selected = $ui.LabReplyMode.SelectedItem
    if ($null -eq $selected) { return 'off' }
    return [string]$selected.Tag
}

function Set-LabControlsEnabled {
    param([bool]$Enabled)
    foreach ($name in @(
        'LabProfileName', 'LabFullName', 'LabRole', 'LabReuseProfile',
        'LabMattermostURL', 'LabBotToken', 'LabAllowedUserIDs', 'LabHomeChannelID',
        'LabRequireMention', 'LabReplyMode', 'LabNetBirdIP', 'LabDetectNetBirdButton',
        'LabDashboardPort', 'LabDashboardUsername', 'LabDashboardPassword',
        'LabBackButton', 'LabCloseButton', 'LabApplyButton'
    )) { $ui[$name].IsEnabled = $Enabled }
}

function Show-LabStep {
    Show-WizardPanel 'Lab'
    if ([string]::IsNullOrWhiteSpace($ui.LabNetBirdIP.Text)) {
        $detected = Get-HermesNetBirdIPv4
        if (-not [string]::IsNullOrWhiteSpace($detected)) { $ui.LabNetBirdIP.Text = $detected }
    }
    $ui.LabApplyButton.Focus() | Out-Null
}

function Add-LabStatus {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $safe = Protect-HermesLogText $Message
    if ([string]::IsNullOrWhiteSpace($ui.LabStatus.Text) -or $ui.LabStatus.Text -eq '필수 값을 입력한 뒤 연결 시작을 누르세요.') {
        $ui.LabStatus.Text = $safe
    } else {
        $ui.LabStatus.AppendText([Environment]::NewLine + $safe)
    }
    if ($ui.LabStatus.Text.Length -gt 16000) { $ui.LabStatus.Text = $ui.LabStatus.Text.Substring($ui.LabStatus.Text.Length - 12000) }
    $ui.LabStatus.ScrollToEnd()
}

function New-LabInputFromUI {
    $profileName = $ui.LabProfileName.Text.Trim()
    if (-not (Test-HermesLabProfileName -Name $profileName)) { throw 'Profile name은 소문자로 시작하고 소문자·숫자·-·_만 포함한 2~32자로 입력하세요. default는 사용할 수 없습니다.' }
    if ([string]::IsNullOrWhiteSpace($ui.LabFullName.Text)) { throw 'Full name을 입력하세요.' }
    if ([string]::IsNullOrWhiteSpace($ui.LabMattermostURL.Text)) { throw 'Mattermost Server URL을 입력하세요.' }
    if ([string]::IsNullOrWhiteSpace($ui.LabBotToken.Password)) { throw 'Mattermost Bot token을 입력하세요.' }
    if (-not (Test-HermesNetBirdIPv4 -Address $ui.LabNetBirdIP.Text.Trim())) { throw 'NetBird IPv4를 감지하거나 100.64.0.0/10 주소를 입력하세요.' }
    $dashboardPort = 0
    if (-not [int]::TryParse($ui.LabDashboardPort.Text.Trim(), [ref]$dashboardPort) -or $dashboardPort -lt 1024 -or $dashboardPort -gt 65535) { throw 'Dashboard port는 1024~65535 범위로 입력하세요.' }
    if ([string]::IsNullOrWhiteSpace($ui.LabDashboardUsername.Text)) { throw 'Dashboard username을 입력하세요.' }
    if ([string]::IsNullOrWhiteSpace($ui.LabDashboardPassword.Password)) { throw 'Dashboard password를 입력하세요.' }
    return [pscustomobject][ordered]@{
        ProfileName = $profileName
        FullName = $ui.LabFullName.Text.Trim()
        Role = [string]$ui.LabRole.Text
        ReuseExistingProfile = [bool]$ui.LabReuseProfile.IsChecked
        MattermostURL = $ui.LabMattermostURL.Text.Trim()
        MattermostToken = [string]$ui.LabBotToken.Password
        AllowedUserIDs = $ui.LabAllowedUserIDs.Text.Trim()
        HomeChannelID = $ui.LabHomeChannelID.Text.Trim()
        RequireMention = [bool]$ui.LabRequireMention.IsChecked
        ReplyMode = Get-SelectedLabReplyMode
        NetBirdIP = $ui.LabNetBirdIP.Text.Trim()
        DashboardPort = $dashboardPort
        DashboardUsername = $ui.LabDashboardUsername.Text.Trim()
        DashboardPassword = [string]$ui.LabDashboardPassword.Password
    }
}

function Handle-LabWorkerEvent {
    param($EventObject)
    if ($null -eq $EventObject) { return }
    if ($EventObject.PSObject.Properties.Name -contains 'percent') { $ui.LabProgress.Value = [math]::Min(100, [math]::Max(0, [int]$EventObject.percent)) }
    switch ([string]$EventObject.type) {
        'stage' { Add-LabStatus ([string]$EventObject.message) }
        'error' { Add-LabStatus ("오류: " + [string]$EventObject.message) }
        'complete' { $script:labResult = $EventObject.data; Add-LabStatus ([string]$EventObject.message) }
    }
}

function Read-LabTransportFiles {
    $outLines = @()
    if ($script:labTransportOut -and (Test-Path -LiteralPath $script:labTransportOut -PathType Leaf)) {
        $outLines = @(Get-Content -LiteralPath $script:labTransportOut -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    for ($index = $script:labStdoutLines; $index -lt $outLines.Count; $index++) {
        $line = [string]$outLines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { Handle-LabWorkerEvent ($line | ConvertFrom-Json) } catch { Add-LabStatus $line }
    }
    $script:labStdoutLines = $outLines.Count
    $errLines = @()
    if ($script:labTransportErr -and (Test-Path -LiteralPath $script:labTransportErr -PathType Leaf)) {
        $errLines = @(Get-Content -LiteralPath $script:labTransportErr -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    for ($index = $script:labStderrLines; $index -lt $errLines.Count; $index++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$errLines[$index])) { Add-LabStatus ("worker: " + [string]$errLines[$index]) }
    }
    $script:labStderrLines = $errLines.Count
}

function Complete-LabWorker {
    if ($null -eq $script:labWorker) { return }
    $localWorker = $script:labWorker
    if ($null -ne $script:labTimer) { $script:labTimer.Stop() }
    $localWorker.WaitForExit()
    Read-LabTransportFiles
    $exitCode = [int]$localWorker.ExitCode
    if ($exitCode -eq 0 -and $null -ne $script:labResult) {
        $result = $script:labResult
        $ui.LabProgress.Value = 100
        $ui.LabStatus.Text = @(
            '연구실 연결이 완료되었습니다.'
            "프로필: $($result.Profile)"
            "Dashboard: $($result.DashboardURL)"
            "Bot Control 등록: $($result.BotControlRegistered)"
            "Gateway 실행: $($result.GatewayRunning)"
        ) -join [Environment]::NewLine
        $ui.LabApplyButton.Content = '설정 다시 적용'
        $ui.LabReuseProfile.IsChecked = $true
    } else {
        Add-LabStatus ("연구실 연결을 완료하지 못했습니다. 종료 코드: $exitCode")
    }
    $localWorker.Dispose()
    $script:labWorker = $null
    $script:labTimer = $null
    Set-LabControlsEnabled $true
    foreach ($path in @($script:labTransportOut, $script:labTransportErr, $script:labInputPath)) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    $script:labTransportOut = $null
    $script:labTransportErr = $null
    $script:labInputPath = $null
}

function Start-LabWorker {
    if ($null -ne $script:labWorker) { return }
    try {
        $input = New-LabInputFromUI
    } catch {
        [Windows.MessageBox]::Show((Protect-HermesLogText $_.Exception.Message), '연구실 연결 입력 확인', 'OK', 'Warning') | Out-Null
        return
    }
    $ui.LabStatus.Text = '연구실 연결 작업을 시작합니다.'
    $ui.LabProgress.Value = 0
    $script:labResult = $null
    $script:labStdoutLines = 0
    $script:labStderrLines = 0
    Set-LabControlsEnabled $false
    $transportDir = Join-Path $script:paths.RuntimeRoot 'ui-transport'
    if (-not (Test-Path -LiteralPath $transportDir -PathType Container)) { New-Item -ItemType Directory -Path $transportDir -Force | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $script:labInputPath = Join-Path $transportDir "lab-input-$stamp.bin"
    $script:labTransportOut = Join-Path $transportDir "lab-worker-$stamp.out"
    $script:labTransportErr = Join-Path $transportDir "lab-worker-$stamp.err"
    try {
        Protect-HermesLabInput -Value $input -LiteralPath $script:labInputPath | Out-Null
        $arguments = @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'HermesEasySetup.ps1'),
            '-Action', 'LabSetup', '-Apply', '-JsonEvents', '-LabInputPath', $script:labInputPath,
            '-HermesHome', $script:paths.HermesHome, '-InstallDir', $script:paths.InstallDir, '-RuntimeRoot', $script:paths.RuntimeRoot
        )
        $argumentLine = ($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument -Argument ([string]$_) }) -join ' '
        $script:labWorker = Start-Process -FilePath (Get-HermesPowerShellExecutable) -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:labTransportOut -RedirectStandardError $script:labTransportErr
        [void]$script:labWorker.Handle
    } catch {
        if ($null -ne $script:labWorker) { $script:labWorker.Dispose() }
        $script:labWorker = $null
        Add-LabStatus ("작업을 시작하지 못했습니다: " + (Protect-HermesLogText $_.Exception.Message))
        Set-LabControlsEnabled $true
        foreach ($path in @($script:labTransportOut, $script:labTransportErr, $script:labInputPath)) {
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        return
    }
    $script:labTimer = New-Object Windows.Threading.DispatcherTimer
    $script:labTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:labTimer.Add_Tick({
        if ($null -ne $script:labWorker -and $script:labWorker.HasExited) { Complete-LabWorker } else { Read-LabTransportFiles }
    })
    $script:labTimer.Start()
}

$ui.DiagnoseButton.Add_Click({ Invoke-ReadOnlyDiagnosis })
$ui.ExistingSetupButton.Add_Click({ Open-ExistingInstallSetupStep })
$ui.WelcomeCloseButton.Add_Click({ $window.Close() })
$ui.ToPlanButton.Add_Click({ Show-WizardPanel 'Plan'; Refresh-Plan })
$ui.BackButton.Add_Click({ Show-WizardPanel 'Welcome' })
$ui.ApprovalCheck.Add_Checked({ $ui.InstallButton.IsEnabled = -not [string]::IsNullOrWhiteSpace($script:approvedPlanFingerprint) })
$ui.ApprovalCheck.Add_Unchecked({ $ui.InstallButton.IsEnabled = $false })
$ui.IncludeDesktopCheck.Add_Checked({ if ($ui.PlanPanel.Visibility -eq 'Visible') { Refresh-Plan } })
$ui.IncludeDesktopCheck.Add_Unchecked({ if ($ui.PlanPanel.Visibility -eq 'Visible') { Refresh-Plan } })
$ui.SkipComputerUseCheck.Add_Checked({ if ($ui.PlanPanel.Visibility -eq 'Visible') { Refresh-Plan } })
$ui.SkipComputerUseCheck.Add_Unchecked({ if ($ui.PlanPanel.Visibility -eq 'Visible') { Refresh-Plan } })
$ui.SetupModeCombo.Add_SelectionChanged({ if ($ui.PlanPanel.Visibility -eq 'Visible') { Refresh-Plan } })
$ui.InstallButton.Add_Click({ Start-InstallWorker })
$ui.FinishButton.Add_Click({ $window.Close() })
$ui.SetupLaterButton.Add_Click({ Set-SetupDeferred })
$ui.SetupStartButton.Add_Click({ Start-SetupWorker })
$ui.SetupLabButton.Add_Click({ Show-LabStep })
$ui.SetupFinishButton.Add_Click({ $window.Close() })
$ui.LabBackButton.Add_Click({ Show-WizardPanel 'Setup' })
$ui.LabCloseButton.Add_Click({ $window.Close() })
$ui.LabApplyButton.Add_Click({ Start-LabWorker })
$ui.LabDetectNetBirdButton.Add_Click({
    $detected = Get-HermesNetBirdIPv4
    if ([string]::IsNullOrWhiteSpace($detected)) {
        [Windows.MessageBox]::Show('NetBird IPv4를 찾지 못했습니다. NetBird 연결 상태를 확인하세요.', 'NetBird IP 감지', 'OK', 'Warning') | Out-Null
    } else {
        $ui.LabNetBirdIP.Text = $detected
    }
})
$ui.BundleButton.Add_Click({
    try {
        $bundle = Export-HermesDiagnosticBundle -HermesHome $script:paths.HermesHome -InstallDir $script:paths.InstallDir -RuntimeRoot $script:paths.RuntimeRoot
        [Windows.MessageBox]::Show("진단 ZIP을 만들었습니다.`n$($bundle.Path)`n`n자동 업로드되지 않습니다. 공유 전 내용을 직접 확인하세요.", 'Hermes Easy Setup') | Out-Null
    } catch { [Windows.MessageBox]::Show((Protect-HermesLogText $_.Exception.Message), '진단 ZIP 실패', 'OK', 'Error') | Out-Null }
})
$window.Add_Closing({ param($sender, $eventArgs)
    if ($null -ne $script:worker -and -not $script:worker.HasExited) {
        $eventArgs.Cancel = $true
        [Windows.MessageBox]::Show('설치 단계가 실행 중입니다. 각 단계에는 제한 시간이 있으며, 현재 프로세스 트리를 임의 종료하지 않도록 창을 닫지 않습니다.', 'Hermes Easy Setup') | Out-Null
    } elseif ($null -ne $script:setupWorker -and -not $script:setupWorker.HasExited) {
        $eventArgs.Cancel = $true
        [Windows.MessageBox]::Show('공식 Hermes 설정 창이 실행 중입니다. 입력 내용을 잃지 않도록 그 설정 창을 먼저 닫아 주세요.', 'Hermes Easy Setup') | Out-Null
    } elseif ($null -ne $script:labWorker -and -not $script:labWorker.HasExited) {
        $eventArgs.Cancel = $true
        [Windows.MessageBox]::Show('연구실 연결 작업이 실행 중입니다. 프로필과 서비스 구성이 끝날 때까지 창을 닫지 않습니다.', 'Hermes Easy Setup') | Out-Null
    }
})

Show-WizardPanel 'Welcome'
$window.ShowDialog() | Out-Null
