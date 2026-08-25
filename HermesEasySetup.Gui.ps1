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
    'StepText', 'WelcomePanel', 'DiagnoseButton', 'DiagnosisText', 'WelcomeCloseButton', 'ToPlanButton',
    'PlanPanel', 'IncludeDesktopCheck', 'SkipComputerUseCheck', 'SetupModeCombo', 'PlanText', 'ApprovalCheck',
    'BackButton', 'InstallButton', 'WorkPanel', 'WorkTitle', 'WorkStatus', 'InstallProgress', 'WorkLog',
    'BundleButton', 'SetupButton', 'FinishButton'
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

function Get-SelectedSetupMode {
    $selected = $ui.SetupModeCombo.SelectedItem
    if ($null -eq $selected) { return 'Portal' }
    return [string]$selected.Tag
}

function Show-WizardPanel {
    param([ValidateSet('Welcome', 'Plan', 'Work')][string]$Name)
    $ui.WelcomePanel.Visibility = $(if ($Name -eq 'Welcome') { 'Visible' } else { 'Collapsed' })
    $ui.PlanPanel.Visibility = $(if ($Name -eq 'Plan') { 'Visible' } else { 'Collapsed' })
    $ui.WorkPanel.Visibility = $(if ($Name -eq 'Work') { 'Visible' } else { 'Collapsed' })
    $ui.StepText.Text = switch ($Name) { 'Welcome' { '1 / 3  PC 확인' } 'Plan' { '2 / 3  설치 계획과 승인' } default { '3 / 3  설치와 결과' } }
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
    $ui.DiagnoseButton.IsEnabled = $false
    $ui.DiagnosisText.Text = '확인 중...'
    try {
        $diagnosis = Get-HermesPreflight
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($check in $diagnosis.Checks) {
            $mark = switch ($check.Status) { 'Pass' { '[통과]' } 'Info' { '[정보]' } 'Warn' { '[주의]' } default { '[실패]' } }
            $lines.Add("$mark $($check.Name) — $($check.Detail)")
        }
        $lines.Add('')
        $lines.Add($(if ($diagnosis.Ready) { '설치 계획을 검토할 준비가 되었습니다.' } else { '필수 점검 실패를 해결한 뒤 다시 시도하세요.' }))
        $ui.DiagnosisText.Text = $lines -join [Environment]::NewLine
        $ui.ToPlanButton.IsEnabled = [bool]$diagnosis.Ready
    } catch {
        $ui.DiagnosisText.Text = "PC 확인 실패: $(Protect-HermesLogText $_.Exception.Message)"
        $ui.ToPlanButton.IsEnabled = $false
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
        'complete' { $script:lastResult = $EventObject.data; $ui.WorkStatus.Text = [string]$EventObject.message; Add-WorkLog ("[완료] $($EventObject.message)") }
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
    Read-TransportFiles
    $script:worker.WaitForExit()
    $exitCode = $script:worker.ExitCode
    $script:timer.Stop()
    if ($exitCode -eq 0) {
        $ui.WorkTitle.Text = 'Hermes 설치가 완료되었습니다.'
        $ui.InstallProgress.Value = 100
        $ui.SetupButton.Visibility = $(if ((Get-SelectedSetupMode) -eq 'Later') { 'Collapsed' } else { 'Visible' })
    } else {
        $ui.WorkTitle.Text = '설치를 완료하지 못했습니다.'
        $ui.WorkStatus.Text = "종료 코드 $exitCode. 같은 계획의 실패 체크포인트가 있으면 안전 재적용 방식으로 이어갈 수 있습니다."
        Add-WorkLog $ui.WorkStatus.Text
    }
    $ui.BundleButton.Visibility = 'Visible'
    $ui.FinishButton.IsEnabled = $true
    $script:worker.Dispose()
    $script:worker = $null
    foreach ($transport in @($script:transportOut, $script:transportErr)) { if ($transport -and (Test-Path -LiteralPath $transport -PathType Leaf)) { Remove-Item -LiteralPath $transport -Force -ErrorAction SilentlyContinue } }
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
    $ui.FinishButton.IsEnabled = $false
    $ui.SetupButton.Visibility = 'Collapsed'
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

    $script:timer = New-Object Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:timer.Add_Tick({ Read-TransportFiles; if ($null -ne $script:worker -and $script:worker.HasExited) { Complete-Worker } })
    $script:timer.Start()
}

$ui.DiagnoseButton.Add_Click({ Invoke-ReadOnlyDiagnosis })
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
$ui.SetupButton.Add_Click({
    try {
        [void](Start-HermesOfficialSetup -HermesHome $script:paths.HermesHome -InstallDir $script:paths.InstallDir -RuntimeRoot $script:paths.RuntimeRoot -Mode (Get-SelectedSetupMode))
        [Windows.MessageBox]::Show('공식 Hermes 설정 창을 열었습니다. 이 마법사를 닫아도 됩니다.', 'Hermes Easy Setup') | Out-Null
    } catch { [Windows.MessageBox]::Show((Protect-HermesLogText $_.Exception.Message), '설정을 열 수 없음', 'OK', 'Error') | Out-Null }
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
    }
})

Show-WizardPanel 'Welcome'
$window.ShowDialog() | Out-Null
