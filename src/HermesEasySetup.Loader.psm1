Set-StrictMode -Version 2.0

$modules = @(
    'HermesEasySetup.Core.psm1',
    'HermesEasySetup.Preflight.psm1',
    'HermesEasySetup.StateStore.psm1',
    'HermesEasySetup.Execution.psm1',
    'HermesEasySetup.Protocol.psm1',
    'HermesEasySetup.InstallEngine.psm1',
    'HermesEasySetup.Bundle.psm1'
)
foreach ($module in $modules) {
    Import-Module (Join-Path $PSScriptRoot $module) -Force -Global -DisableNameChecking
}

Export-ModuleMember -Function @()
