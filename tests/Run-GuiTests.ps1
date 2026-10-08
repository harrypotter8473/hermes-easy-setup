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
$ui = @{}
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
        'MattermostPanel', 'MattermostServerURL', 'MattermostServerName', 'MattermostApproval', 'MattermostApplyButton',
        'MattermostProgress', 'MattermostStatus', 'MattermostOpenButton', 'MattermostBrowserButton', 'MattermostNextButton', 'MattermostCloseButton',
        'LabMattermostURL', 'LabBotToken', 'LabAllowedUserIDs', 'LabHomeChannelID',
        'LabRequireMention', 'LabReplyMode', 'LabNetBirdIP', 'LabDetectNetBirdButton',
        'LabDashboardPort', 'LabDashboardUsername', 'LabDashboardPassword', 'LabDashboardDefaultsNote',
        'LabProgress', 'LabStatus', 'LabBackButton', 'LabCloseButton', 'LabApplyButton'
    )) {
        if ($null -eq $window.FindName($name)) { throw "XAML control not found: $name" }
        $ui[$name] = $window.FindName($name)
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
    if ([string]$stepText.Text -cne '1 / 6  PC 확인') { throw 'Wizard must start at step 1 of 6.' }
    if ([string]$ui.MattermostPanel.Visibility -cne 'Collapsed' -or $ui.MattermostApproval.IsChecked -eq $true -or
        $ui.MattermostApplyButton.IsEnabled -or $ui.MattermostNextButton.IsEnabled -or $ui.MattermostOpenButton.IsEnabled) {
        throw 'Mattermost actions must remain hidden/default-deny before explicit approval and successful registration.'
    }
    if ([string]$setupPanel.Visibility -cne 'Collapsed') { throw 'Setup panel must be hidden by default.' }
    if ([string]$labPanel.Visibility -cne 'Collapsed') { throw 'Lab panel must be hidden by default.' }
    if (-not [string]::IsNullOrWhiteSpace($ui.LabMattermostURL.Text)) { throw 'Do not default to a real lab server; use the explicitly registered server.' }
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
    Write-Host 'PASS WPF XAML load, six-step controls, accessibility, and default-deny actions' -ForegroundColor Green

    $dashboardUsername = $ui.LabDashboardUsername
    $dashboardPassword = $ui.LabDashboardPassword
    if ($dashboardUsername.Text -cne 'admin' -or $dashboardPassword.Password -cne '12345678') {
        throw 'Dashboard initial credentials must be prefilled.'
    }
    if ($dashboardPassword -isnot [Windows.Controls.PasswordBox] -or [int]$dashboardPassword.PasswordChar -eq 0) {
        throw 'Dashboard password must remain in a masked PasswordBox.'
    }
    if ($dashboardUsername.IsReadOnly -or -not $dashboardUsername.IsEnabled -or -not $dashboardPassword.IsEnabled) {
        throw 'Dashboard initial credentials must remain editable.'
    }
    if (-not $ui.LabDashboardDefaultsNote.Text.Contains('공통 비밀번호')) { throw 'Shared default password warning is required.' }
    Write-Host 'PASS Dashboard initial credentials are prefilled, masked, editable, and explained' -ForegroundColor Green

    # Load only the pure input builder, never the real GUI event loop or workers.
    Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Lab.psm1') -Force -DisableNameChecking
    $guiTokens = $null
    $guiParseErrors = $null
    $guiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'HermesEasySetup.Gui.ps1'), [ref]$guiTokens, [ref]$guiParseErrors)
    if ($guiParseErrors.Count -gt 0) { throw 'GUI input builder source has parse errors.' }
    $inputFunction = $guiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-LabInputFromUI' }, $true)
    if ($null -eq $inputFunction) { throw 'GUI input builder was not found.' }
    foreach ($functionName in @('Show-WizardPanel','Set-MattermostControls')) {
        $functionNode = $guiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
        . ([scriptblock]::Create($functionNode.Extent.Text))
    }
    $script:mattermostResult = $null
    Show-WizardPanel 'Mattermost'
    if ($ui.MattermostPanel.Visibility -ne 'Visible' -or $ui.SetupPanel.Visibility -ne 'Collapsed' -or $ui.StepText.Text -notlike '4 / 6*') { throw 'Mattermost step navigation is broken.' }
    Set-MattermostControls $false
    if ($ui.MattermostApplyButton.IsEnabled -or $ui.MattermostNextButton.IsEnabled) { throw 'Mattermost consent/result guards failed.' }
    $ui.MattermostApproval.IsChecked = $true
    Set-MattermostControls $false
    if (-not $ui.MattermostApplyButton.IsEnabled -or $ui.MattermostNextButton.IsEnabled) { throw 'Consent must enable setup only, not Next.' }
    $script:mattermostResult = [pscustomobject]@{ Ready = $true }
    Set-MattermostControls $true
    if ($ui.MattermostNextButton.IsEnabled -or $ui.MattermostServerURL.IsEnabled) { throw 'Mattermost worker must lock actions and inputs.' }
    Set-MattermostControls $false
    if (-not $ui.MattermostNextButton.IsEnabled -or -not $ui.MattermostOpenButton.IsEnabled) { throw 'Successful registration must enable app/login and Next.' }
    Show-WizardPanel 'Setup'
    if ($ui.MattermostPanel.Visibility -ne 'Collapsed' -or $ui.StepText.Text -notlike '5 / 6*') { throw 'Codex navigation after Mattermost is broken.' }
    Write-Host 'PASS Mattermost screen transitions, approval gate, busy state, and completion actions'
    . ([scriptblock]::Create($inputFunction.Extent.Text))
    $ui.LabFullName.Text = 'Fixture Agent'
    $ui.LabMattermostURL.Text = 'http://mattermost.example.invalid:8065'
    $ui.LabBotToken.Password = 'fixture-bot-value'
    $ui.LabNetBirdIP.Text = '100.64.10.20'
    [void]$ui.SetupModelCombo.Items.Add('fixture-model')
    $ui.SetupModelCombo.SelectedIndex = 0
    $script:setupAuthenticated = $true
    $defaultInput = New-LabInputFromUI
    if ($defaultInput.DashboardUsername -cne 'admin' -or $defaultInput.DashboardPassword -cne '12345678') {
        throw 'Connection input must carry the prefilled Dashboard credentials.'
    }
    Write-Host 'PASS Default Dashboard credentials reach the connection input without user edits' -ForegroundColor Green

    $dashboardUsername.Text = 'fixture-operator'
    $dashboardPassword.Password = 'fixture-custom-password'
    $ui.LabReuseProfile.IsChecked = $true
    $customInput = New-LabInputFromUI
    if ($customInput.DashboardUsername -cne 'fixture-operator' -or $customInput.DashboardPassword -cne 'fixture-custom-password' -or -not $customInput.ReuseExistingProfile) {
        throw 'Custom Dashboard credentials must survive an existing-profile retry.'
    }
    Write-Host 'PASS Custom Dashboard credentials are preserved for existing-profile retries' -ForegroundColor Green

    $dashboardPassword.Clear()
    $emptyPasswordRejected = $false
    try { [void](New-LabInputFromUI) } catch { $emptyPasswordRejected = $_.Exception.Message.Contains('Dashboard password') }
    if (-not $emptyPasswordRejected) { throw 'Clearing the password must not silently restore the shared default.' }
    Write-Host 'PASS Empty Dashboard password still requires explicit correction' -ForegroundColor Green
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
if (-not $guiScriptText.Contains('[void]$script:mattermostWorker.Handle')) { throw 'Mattermost worker must cache its process handle.' }
if (-not $guiScriptText.Contains("'-Action','MattermostSetup','-Apply','-JsonEvents'")) { throw 'Mattermost must use its tracked approved CLI action.' }
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
