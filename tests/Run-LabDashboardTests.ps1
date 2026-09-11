[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\HermesEasySetup.Loader.psm1') -Force
$lab = Get-Module HermesEasySetup.Lab
& $lab {
    $script:probeStatusCalls = 0
    $script:probeLoginCalls = 0
    $script:probeMode = 'cold-start'
    $script:probeSession = $null
    function script:Start-Sleep { param($Milliseconds) }
    function script:Invoke-RestMethod {
        param($Uri, $Method, $TimeoutSec, $ContentType, $Body, $WebSession)
        if ($Uri.EndsWith('/api/status')) {
            $script:probeStatusCalls++
            if ($script:probeMode -eq 'cold-start' -and $script:probeStatusCalls -eq 1) { throw 'Connection refused during startup' }
            return [pscustomobject]@{ auth_required = ($script:probeMode -ne 'auth-disabled'); version = 'fixture' }
        }
        if ($Uri.EndsWith('/auth/password-login')) {
            $script:probeLoginCalls++
            $script:probeSession = $WebSession
            if ($script:probeMode -eq 'bad-password') { throw 'HTTP 401' }
            return [pscustomobject]@{ ok = $true }
        }
        if ($Uri.EndsWith('/api/auth/me')) {
            if (-not [object]::ReferenceEquals($script:probeSession, $WebSession)) { throw 'Login cookie session was not reused' }
            if ($script:probeMode -eq 'lost-session') { throw 'HTTP 401' }
            return [pscustomobject]@{ user_id = 'fixture-user' }
        }
        throw 'Unexpected endpoint'
    }
    $params = @{ URL = 'http://127.0.0.1:19119'; Username = 'fixture'; Password = 'fake-test-value'; TimeoutSeconds = 3 }
    $result = Wait-HermesDashboard @params
    if ($result.version -ne 'fixture' -or $script:probeStatusCalls -ne 2 -or $script:probeLoginCalls -ne 1) { throw 'Cold start did not wait before a single login' }
    Write-Host 'PASS delayed Dashboard startup followed by one login and authenticated session verification'
    foreach ($mode in @('bad-password', 'lost-session', 'auth-disabled')) {
        $script:probeMode = $mode
        $script:probeLoginCalls = 0
        $failed = $false
        try { [void](Wait-HermesDashboard @params) } catch { $failed = $true }
        $expectedLogins = $(if ($mode -eq 'auth-disabled') { 0 } else { 1 })
        if (-not $failed -or $script:probeLoginCalls -ne $expectedLogins) { throw "Invalid auth state accepted or retried: $mode" }
        Write-Host "PASS $mode fails without repeated password attempts"
    }
}
exit 0
