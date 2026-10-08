[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\HermesEasySetup.Loader.psm1') -Force
& (Get-Module HermesEasySetup.Lab) {
    $script:passed = 0
    function Assert { param($Ok,$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject { param([scriptblock]$Block,$Name) $failed = $false; try { & $Block | Out-Null } catch { $failed = $true }; Assert $failed $Name }
    $secret = 'fixture-secret-must-not-be-reflected'
    $script:request = $null; $script:rawFailure = $false
    function script:Invoke-WebRequest {
        param($Uri,$Method,$UseBasicParsing,$TimeoutSec,$MaximumRedirection,$ErrorAction,$Headers,$ContentType,$Body)
        $script:request = $PSBoundParameters
        if ($script:rawFailure) { throw (New-Object Exception $secret) }
        return @{ StatusCode = 200; Content = '{"ok":true}' }
    }
    $null = Invoke-HermesLabMattermostAPI 'http://100.69.1.2:18065' '/api/v4/users/me' $secret
    Assert ($script:request.MaximumRedirection -eq 0) 'Authenticated requests do not follow redirects'
    Assert ($script:request.Headers.Authorization -ceq ('Bearer ' + $secret)) 'Token remains in header, not URL'
    Assert (-not $script:request.Uri.Contains($secret)) 'URL contains no token'
    $script:rawFailure = $true
    $message = ''
    try { $null = Invoke-HermesLabMattermostAPI 'http://100.69.1.2:18065' '/api/v4/users/me' $secret } catch { $message = $_.Exception.Message }
    Assert ($message -and -not $message.Contains($secret)) 'Raw remote/transport error never echoed'
    foreach ($url in @('http://user:pass@100.69.1.2','http://100.69.1.2/?token=secret','file:///C:/data')) { Reject { Test-HermesLabConnection $url ('s'*26) ('c'*26) } 'Reject unsafe base URL before authentication' }
    foreach ($value in @('short','http://server/channel',('s'*25))) { Reject { Test-HermesLabConnection 'http://100.69.1.2' $value ('c'*26) } 'Reject malformed bot token' }
    Reject { Test-HermesLabConnection 'http://100.69.1.2' ('s'*26) 'agent' } 'Require actual channel ID'
    $script:me = [pscustomobject]@{ id = 'b'*26; username = 'unit_bot'; is_bot = $true; roles = 'system_user'; delete_at = 0 }
    $script:channel = [pscustomobject]@{ id = 'c'*26; name = 'agent'; team_id = 't'*26; type = 'O'; delete_at = 0 }
    $script:pluginStatus = 403; $script:member = 'b'*26
    function script:Invoke-HermesLabMattermostAPI {
        param($MattermostURL,$Path,$Token,$Method='GET',$Body=$null)
        if ($Path -eq '/api/v4/users/me') { return $script:me }
        if ($Path -like '*/members/*') { return @{ user_id = $script:member } }
        if ($Path -like '/api/v4/channels/*') { return $script:channel }
        if ($script:pluginStatus -ne 200) { $e = New-Object Exception 'Fixture status'; $e.Data['HttpStatus'] = $script:pluginStatus; throw $e }
        return @{}
    }
    $result = Test-HermesLabConnection 'http://100.69.1.2:18065' ('s'*26) ('c'*26)
    Assert ($result.Ready -and $result.BotUserID -ceq $script:me.id -and $result.BotControlReachable) 'Valid bot, channel membership and plugin permission gate accepted'
    Assert (-not ($result | ConvertTo-Json).Contains(('s'*26))) 'Preflight result never contains token'
    foreach ($role in @('system_admin','system_user system_admin','custom','')) { $script:me.roles = $role; Reject { Test-HermesLabConnection 'http://100.69.1.2' ('s'*26) ('c'*26) } 'Reject privileged or unknown bot role' }
    $script:me.roles = 'system_user'; $script:me.is_bot = $false
    Reject { Test-HermesLabConnection 'http://100.69.1.2' ('s'*26) ('c'*26) } 'Reject human token'
    $script:me.is_bot = $true; $script:me.delete_at = 1
    Reject { Test-HermesLabConnection 'http://100.69.1.2' ('s'*26) ('c'*26) } 'Reject inactive bot'
    $script:me.delete_at = 0; $script:channel.type = 'D'
    Reject { Test-HermesLabConnection 'http://100.69.1.2' ('s'*26) ('c'*26) } 'Reject direct-message home channel'
    $script:channel.type = 'O'; $script:member = 'x'*26
    Reject { Test-HermesLabConnection 'http://100.69.1.2' ('s'*26) ('c'*26) } 'Reject incorrect channel membership'
    $script:member = 'b'*26
    foreach ($code in @(404,502,200)) { $script:pluginStatus = $code; Reject { Test-HermesLabConnection 'http://100.69.1.2' ('s'*26) ('c'*26) } 'Reject missing, unavailable or unsafe management endpoint' }
    Write-Host ('Lab connection tests passed: ' + $script:passed)
}
