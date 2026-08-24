[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $projectRoot 'HermesEasySetup.ps1'
$systemPowerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tempBase = [System.IO.Path]::GetTempPath()
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase ('Hermes 테스트 공간 ' + [guid]::NewGuid().ToString('N'))))
$hermesHome = Join-Path $testRoot 'hermes home'
$installDir = Join-Path $hermesHome 'hermes-agent'
$runtimeRoot = Join-Path $testRoot 'wizard runtime'
$script:passed = 0
$script:failed = 0

function Assert-CliTrue {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS $Name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "FAIL $Name" -ForegroundColor Red; $script:failed++ }
}

try {
    $planOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Plan -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SkipComputerUse -SetupMode Later -Json)
    $planExit = $LASTEXITCODE
    $plan = $planOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($planExit -eq 0 -and [string]$plan.Fingerprint -match '^[0-9A-F]{64}$') 'Plan JSON contract and exit code'
    Assert-CliTrue ([string]$plan.SourceCommit -eq 'fcbd1076a93841fa88855acce810e342a5b78101') 'Plan exposes peeled commit pin'
    Assert-CliTrue ([string]$plan.InstallDir -eq $installDir) 'Unicode and space path round-trips through CLI'

    $diagnoseOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Diagnose -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    $diagnoseExit = $LASTEXITCODE
    $diagnosis = $diagnoseOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($diagnoseExit -eq 0 -and [bool]$diagnosis.Ready) 'Diagnose is read-only and ready on safe temp paths'

    $guardOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Install -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SkipComputerUse -SetupMode Later -Json)
    $guardExit = $LASTEXITCODE
    $guardError = $guardOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($guardExit -eq 2 -and [int]$guardError.exit_code -eq 2 -and [string]$guardError.message -like '*-Apply*') 'Install without Apply is default-deny'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'Apply guard creates no runtime state'

    $mismatchOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Install -Apply -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SkipComputerUse -SetupMode Later -ExpectedPlanFingerprint ('0' * 64) -Json)
    $mismatchExit = $LASTEXITCODE
    $mismatchError = $mismatchOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($mismatchExit -eq 2 -and [string]$mismatchError.message -like '*계획*') 'CLI worker rejects stale approval fingerprint'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'stale approval rejection precedes mutation'

    $verifyOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Verify -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    $verifyExit = $LASTEXITCODE
    $verification = $verifyOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($verifyExit -eq 50 -and -not [bool]$verification.Verified) 'Verify fails closed when target installation is absent'
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $tempPrefix = [System.IO.Path]::GetFullPath($tempBase)
        if ($testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $testRoot) -like 'Hermes 테스트 공간 *') {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}

Write-Host ''
Write-Host "Passed: $script:passed  Failed: $script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
