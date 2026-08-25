[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Plan', 'Install', 'Verify', 'Setup', 'Bundle')]
    [string]$Action = 'Diagnose',
    [string]$HermesHome,
    [string]$InstallDir,
    [string]$RuntimeRoot,
    [switch]$IncludeDesktop,
    [switch]$SkipComputerUse,
    [ValidateSet('Later', 'Portal', 'Full')][string]$SetupMode = 'Portal',
    [switch]$Apply,
    [switch]$Resume,
    [switch]$ForceDownload,
    [switch]$LaunchSetup,
    [switch]$Json,
    [switch]$JsonEvents,
    [string]$ExpectedPlanFingerprint,
    [string]$DestinationPath,
    [string]$SourceConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($Json -or $JsonEvents) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force
$exitCodes = Get-HermesEasySetupExitCodes

function Write-ResultObject {
    param($Value)
    if ($Json -or $JsonEvents) {
        [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 16 -Compress))
        [Console]::Out.Flush()
    } else {
        $Value | Format-List | Out-Host
    }
}

$eventCallback = {
    param($Event)
    if ($JsonEvents) {
        [Console]::Out.WriteLine(($Event | ConvertTo-Json -Depth 16 -Compress))
        [Console]::Out.Flush()
        return
    }
    if ($Event.type -eq 'log') {
        Write-Host ("  {0}" -f $Event.message) -ForegroundColor DarkGray
    } elseif ($Event.type -eq 'stage') {
        $color = switch ($Event.state) { 'failed' { 'Red' } 'running' { 'Cyan' } 'skipped' { 'Yellow' } default { 'Green' } }
        Write-Host ("[{0,3}%] {1}" -f $Event.percent, $Event.message) -ForegroundColor $color
    } else {
        Write-Host ("[{0,3}%] {1}" -f $Event.percent, $Event.message) -ForegroundColor Cyan
    }
}.GetNewClosure()

try {
    $common = @{ HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot }
    switch ($Action) {
        'Diagnose' {
            $result = Get-HermesPreflight @common -IncludeDesktop:$IncludeDesktop
            Write-ResultObject $result
            if (-not $result.Ready) { exit $exitCodes.PreflightFailed }
        }
        'Plan' {
            $arguments = @{
                HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot
                IncludeDesktop = $IncludeDesktop; SkipComputerUse = $SkipComputerUse; SetupMode = $SetupMode
            }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $arguments.SourceConfigPath = $SourceConfigPath }
            Write-ResultObject (New-HermesInstallPlan @arguments)
        }
        'Install' {
            $planArguments = @{
                HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot
                IncludeDesktop = $IncludeDesktop; SkipComputerUse = $SkipComputerUse; SetupMode = $SetupMode
            }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $planArguments.SourceConfigPath = $SourceConfigPath }
            if (-not $Apply) {
                Write-ResultObject (New-HermesInstallPlan @planArguments)
                throw (New-Object System.InvalidOperationException '설치 변경을 승인하려면 -Apply를 함께 지정하세요.')
            }
            $installArguments = @{
                HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot
                IncludeDesktop = $IncludeDesktop; SkipComputerUse = $SkipComputerUse; SetupMode = $SetupMode
                Resume = $Resume; ForceDownload = $ForceDownload; ProgressCallback = $eventCallback
                ExpectedPlanFingerprint = $ExpectedPlanFingerprint
            }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $installArguments.SourceConfigPath = $SourceConfigPath }
            $result = Invoke-HermesInstall @installArguments
            if ($LaunchSetup -and $SetupMode -ne 'Later') {
                $result | Add-Member -NotePropertyName SetupLaunch -NotePropertyValue (Start-HermesOfficialSetup -HermesHome $result.Plan.HermesHome -InstallDir $result.Plan.InstallDir -RuntimeRoot $result.Plan.RuntimeRoot -Mode $SetupMode)
            }
            if (-not $JsonEvents) { Write-ResultObject $result }
        }
        'Verify' {
            $result = Test-HermesInstallation @common -ProgressCallback $eventCallback
            Write-ResultObject $result
            if (-not $result.Verified) { exit $exitCodes.VerificationFailed }
        }
        'Setup' { Write-ResultObject (Start-HermesOfficialSetup -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot -Mode $SetupMode) }
        'Bundle' {
            $arguments = @{ HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot; DestinationPath = $DestinationPath }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $arguments.SourceConfigPath = $SourceConfigPath }
            Write-ResultObject (Export-HermesDiagnosticBundle @arguments)
        }
    }
    exit $exitCodes.Success
} catch {
    $code = $exitCodes.UnexpectedFailure
    if ($_.Exception -is [System.InvalidOperationException] -and $_.Exception.Message -like '*-Apply*') {
        $code = $exitCodes.InvalidArguments
    } elseif ($_.Exception.Data.Contains('ExitCode')) {
        $code = [int]$_.Exception.Data['ExitCode']
    }
    $errorResult = [pscustomobject]@{
        type = 'error'; timestamp = (Get-Date).ToUniversalTime().ToString('o')
        state = 'failed'; exit_code = $code; message = (Protect-HermesLogText $_.Exception.Message)
    }
    if ($Json -or $JsonEvents) {
        [Console]::Out.WriteLine(($errorResult | ConvertTo-Json -Compress)); [Console]::Out.Flush()
    } else {
        Write-Error $errorResult.message
    }
    exit $code
}
