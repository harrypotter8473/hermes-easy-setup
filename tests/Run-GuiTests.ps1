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
        'StepText', 'WelcomePanel', 'DiagnoseButton', 'DiagnosisText', 'ToPlanButton',
        'PlanPanel', 'IncludeDesktopCheck', 'SkipComputerUseCheck', 'SetupModeCombo',
        'PlanText', 'ApprovalCheck', 'InstallButton', 'WorkPanel', 'InstallProgress',
        'WorkLog', 'BundleButton', 'SetupButton', 'FinishButton'
    )) {
        if ($null -eq $window.FindName($name)) { throw "XAML control not found: $name" }
    }
    $approval = $window.FindName('ApprovalCheck')
    $installButton = $window.FindName('InstallButton')
    if ($approval.IsChecked -eq $true) { throw 'Approval must not be checked by default.' }
    if ($installButton.IsEnabled) { throw 'Install button must be disabled by default.' }
    Write-Host 'PASS WPF XAML load, controls, and default-deny approval' -ForegroundColor Green
} finally {
    if ($null -ne $window) { $window.Close() }
    $reader.Close()
}
exit 0
