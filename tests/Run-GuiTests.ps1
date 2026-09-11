[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'GUI smoke test must run with powershell.exe -STA.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$xamlPath = Join-Path $projectRoot 'ui\MainWindow.xaml'
$xamlText = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
$xml = [xml]$xamlText
$reader = New-Object System.Xml.XmlNodeReader $xml
$window = $null
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
    foreach ($name in @(
        'StepText', 'WelcomePanel', 'DiagnoseButton', 'DiagnosisText', 'ExistingSetupModeCombo',
        'ExistingSetupButton', 'ToPlanButton',
        'PlanPanel', 'IncludeDesktopCheck', 'SkipComputerUseCheck', 'SetupModeCombo',
        'PlanText', 'ApprovalCheck', 'InstallButton', 'WorkPanel', 'InstallProgress',
        'WorkLog', 'BundleButton', 'FinishButton', 'SetupPanel', 'SetupTitle', 'SetupStatus',
        'SetupDetails', 'SetupModelCombo', 'SetupRefreshButton', 'SetupLaterButton', 'SetupStartButton', 'SetupLabButton', 'SetupFinishButton',
        'LabPanel', 'LabProfileName', 'LabFullName', 'LabRole', 'LabReuseProfile',
        'LabMattermostURL', 'LabBotToken', 'LabAllowedUserIDs', 'LabHomeChannelID',
        'LabRequireMention', 'LabReplyMode', 'LabNetBirdIP', 'LabDetectNetBirdButton',
        'LabDashboardPort', 'LabDashboardUsername', 'LabDashboardPassword',
        'LabProgress', 'LabStatus', 'LabBackButton', 'LabCloseButton', 'LabApplyButton'
    )) {
        if ($null -eq $window.FindName($name)) { throw "XAML control not found: $name" }
    }
    $approval = $window.FindName('ApprovalCheck')
    $installButton = $window.FindName('InstallButton')
    $stepText = $window.FindName('StepText')
    $setupPanel = $window.FindName('SetupPanel')
    $setupStatus = $window.FindName('SetupStatus')
    $setupStartButton = $window.FindName('SetupStartButton')
    $setupLabButton = $window.FindName('SetupLabButton')
    $setupLaterButton = $window.FindName('SetupLaterButton')
    $setupFinishButton = $window.FindName('SetupFinishButton')
    $existingSetupModeCombo = $window.FindName('ExistingSetupModeCombo')
    $existingSetupButton = $window.FindName('ExistingSetupButton')
    $labPanel = $window.FindName('LabPanel')
    if ($approval.IsChecked -eq $true) { throw 'Approval must not be checked by default.' }
    if ($installButton.IsEnabled) { throw 'Install button must be disabled by default.' }
    if ([string]$stepText.Text -cne '1 / 5  PC 확인') { throw 'Wizard must start at step 1 of 5.' }
    if ([string]$setupPanel.Visibility -cne 'Collapsed') { throw 'Setup panel must be hidden by default.' }
    if ([string]$labPanel.Visibility -cne 'Collapsed') { throw 'Lab panel must be hidden by default.' }
    if ($setupStartButton.IsEnabled -or $setupLaterButton.IsEnabled -or $setupLabButton.IsEnabled -or $setupFinishButton.IsEnabled) {
        throw 'Setup actions must be disabled by default.'
    }
    if ([string]$existingSetupModeCombo.Visibility -cne 'Collapsed' -or
        [string]$existingSetupButton.Visibility -cne 'Collapsed' -or
        $existingSetupModeCombo.IsEnabled -or $existingSetupButton.IsEnabled) {
        throw 'Existing-install setup route must be hidden and disabled by default.'
    }
    $existingModes = @($existingSetupModeCombo.Items | ForEach-Object { [string]$_.Tag })
    if ($existingModes.Count -ne 1 -or $existingModes[0] -cne 'Portal') {
        throw 'Existing-install setup route must expose only the fixed OpenAI Codex flow.'
    }
    if ([string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($existingSetupModeCombo)) -or
        [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($existingSetupButton))) {
        throw 'Existing-install setup controls must have accessible names.'
    }

    if ([string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($setupStatus))) {
        throw 'Setup status must have an accessible name.'
    }
    if ([System.Windows.Automation.AutomationProperties]::GetLiveSetting($setupStatus) -ne [System.Windows.Automation.AutomationLiveSetting]::Polite) {
        throw 'Setup status must be a polite accessibility live region.'
    }
    if ([string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($setupStartButton))) {
        throw 'Setup start action must have an accessible name.'
    }
    Write-Host 'PASS WPF XAML load, five-step controls, accessibility, and default-deny actions' -ForegroundColor Green
} finally {
    if ($null -ne $window) { $window.Close() }
    $reader.Close()
}

$guiScriptText = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'HermesEasySetup.Gui.ps1'), [System.Text.Encoding]::UTF8)
if (-not $guiScriptText.Contains('[void]$script:worker.Handle')) { throw 'Install worker must cache its process handle immediately.' }
if (-not $guiScriptText.Contains('Resolve-HermesInstallWorkerOutcome')) { throw 'GUI must use the verified install worker outcome resolver.' }
if (-not $guiScriptText.Contains('Show-InstallStartFailure -Message $_.Exception.Message')) { throw 'Install worker startup failures must remain visible inside the GUI.' }
if (-not $guiScriptText.Contains('Restore-HermesResumablePlanSelection')) { throw 'GUI must restore the exact option selection for a resumable failed checkpoint.' }
if (-not $guiScriptText.Contains("`$arguments += '-Resume'")) { throw 'GUI must pass the explicit resume switch only for a matching failed checkpoint.' }

if (-not $guiScriptText.Contains('$ui.ExistingSetupButton.Add_Click({ Open-ExistingInstallSetupStep })')) { throw 'Existing-install setup button must use the guarded setup-step route.' }
if ($guiScriptText.Contains('Start-HermesOfficialSetup')) { throw 'GUI must never bypass the tracked CLI setup worker.' }
if (-not $guiScriptText.Contains('$ui.SetupStartButton.Add_Click({ Start-SetupWorker })')) { throw 'Only the explicit setup-start action may launch the tracked setup worker.' }
if (-not ($guiScriptText.Contains('$ui.SetupLabButton.Add_Click') -and $guiScriptText.Contains('Show-LabStep'))) { throw 'Setup must expose the authenticated lab integration route.' }
if (-not $guiScriptText.Contains("'-Action', 'CodexAuth', '-Apply', '-JsonEvents'")) { throw 'GUI must launch only the tracked Codex OAuth worker.' }
if (-not ($xamlText -match 'x:Name="SetupOAuthCode"' -and $xamlText -match 'x:Name="SetupOpenOAuthButton"')) { throw 'Codex device flow must expose its one-time code and browser action inside the wizard.' }
if (-not ($guiScriptText.Contains("@('stage', 'oauth', 'complete', 'error')") -and $guiScriptText.Contains("'https://auth.openai.com/codex/device'"))) { throw 'GUI must accept only the fixed Codex device URL and tracked OAuth events.' }
if (-not ($guiScriptText -match 'SetupLabButton\.Add_Click\(\{[\s\S]*?try\s*\{[\s\S]*?Show-LabStep[\s\S]*?catch')) { throw 'Agent settings navigation must catch errors instead of terminating the WPF wizard.' }
if ($xamlText -match 'Nous Portal|OpenRouter|Discord|Slack|Telegram|Spotify') { throw 'Minimal wizard must not expose excluded provider or messaging setup choices.' }
if (-not $guiScriptText.Contains('Protect-HermesLabInput -Value $input')) { throw 'Lab secrets must use the DPAPI-protected worker input transport.' }
if (-not $guiScriptText.Contains('[void]$script:labWorker.Handle')) { throw 'Lab worker must cache its process handle immediately.' }
$probeOut = [System.IO.Path]::GetTempFileName()
$probeErr = [System.IO.Path]::GetTempFileName()
$exitProbe = $null
try {
    $systemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $exitProbe = Start-Process -FilePath $systemPowerShell -ArgumentList '-NoLogo -NoProfile -Command "Start-Sleep -Milliseconds 250; exit 37"' -PassThru -WindowStyle Hidden -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
    [void]$exitProbe.Handle
    $exitProbe.WaitForExit()
    if ($null -eq $exitProbe.ExitCode -or [int]$exitProbe.ExitCode -ne 37) {
        throw "Redirected worker exit code was not retained (actual=$($exitProbe.ExitCode))."
    }
    Write-Host 'PASS Windows PowerShell redirected worker retains its exact nonzero exit code' -ForegroundColor Green
} finally {
    if ($null -ne $exitProbe) { $exitProbe.Dispose() }
    foreach ($probePath in @($probeOut, $probeErr)) {
        if (Test-Path -LiteralPath $probePath -PathType Leaf) { Remove-Item -LiteralPath $probePath -Force }
    }
}
exit 0
