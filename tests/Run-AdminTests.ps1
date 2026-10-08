[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
& (Get-Module HermesEasySetup.Admin) {
    param($ProjectRoot)
    $script:passed = 0
    function Assert { param($Ok,$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject { param([scriptblock]$Block,$Name) $failed = $false; try { & $Block | Out-Null } catch { $failed = $true }; Assert $failed $Name }
    $data = [pscustomobject]@{ ServerId = 'lab-test'; SiteName = 'Lab Test'; TeamName = 'infonet'; TeamDisplayName = 'INFONET'; ChannelName = 'agent'; AdminUsername = 'labadmin'; AdminEmail = 'admin@example.invalid'; AdminPassword = 'Unit-fixture-9274'; Port = 18065 }
    Assert-HermesAdminInput $data
    Assert $true 'Valid admin fields accepted'
    foreach ($case in @(@('ServerId','../escape'),@('TeamName','UPPER'),@('ChannelName','a'),@('AdminUsername','system admin'),@('AdminEmail','Name <a@example.invalid>'),@('SiteName',"Lab`nName"),@('AdminPassword','short'),@('AdminPassword','no-uppercase9274!'),@('AdminPassword','NO-LOWERCASE9274!'),@('AdminPassword','NoDigit-LongEnough'),@('AdminPassword','NoSymbol92749274'),@('Port',8065),@('Port',80),@('Port',65536),@('Port','abc'))) {
        $copy = $data | ConvertTo-Json | ConvertFrom-Json
        $copy.($case[0]) = $case[1]
        Reject { Assert-HermesAdminInput $copy } ("Reject invalid " + $case[0])
    }
    foreach ($badPath in @('C:\','relative\folder','\\remote\share')) { Reject { Assert-HermesAdminPath $badPath } 'Reject broad or non-local deployment path' }
    foreach ($badURL in @('http://100.69.181.62:8065','https://example.invalid','http://localhost:18065','http://127.0.0.1:18065/redirect')) { Reject { Invoke-HermesAdminAPI $badURL '/api/v4/users' } 'Bootstrap refuses non-exact loopback base URL' }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('hermes-admin-unit-' + [Guid]::NewGuid().ToString('N'))
    try {
        $state = New-HermesAdminState $data $root
        $statePath = Join-Path $state.Directory 'deployment.json'
        $secretPath = Join-Path $state.Directory 'database.bin'
        $secret = Unprotect-HermesLabInput $secretPath
        Assert ($secret.Password -cmatch '^[a-f0-9]{64}$') 'Random database password survives DPAPI round-trip'
        $stateText = [IO.File]::ReadAllText($statePath)
        Assert (-not $stateText.Contains($data.AdminPassword) -and -not $stateText.Contains($secret.Password)) 'Deployment metadata contains no passwords'
        Assert (-not [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($secretPath)).Contains($secret.Password)) 'Database secret is not stored as plaintext'
        $acl = Get-Acl -LiteralPath $state.Directory
        Assert $acl.AreAccessRulesProtected 'Deployment directory does not inherit broad permissions'
        Assert (@($acl.Access).Count -eq 2) 'Only current user and SYSTEM have deployment access'
        $again = New-HermesAdminState $data $root -Resume
        Assert ($again.DeploymentId -ceq $state.DeploymentId) 'Resume preserves unique deployment identity'
        Reject { New-HermesAdminState $data $root } 'Existing server requires explicit resume'
        $copy = $data | ConvertTo-Json | ConvertFrom-Json; $copy.Port = 18067
        Reject { New-HermesAdminState $copy $root -Resume } 'Resume cannot silently change server port'
        $compose = New-HermesAdminCompose $state
        Assert ($compose.services.mattermost.ports.Count -eq 1 -and $compose.services.mattermost.ports[0] -ceq '127.0.0.1:18065:8065') 'Only loopback is published'
        Assert (-not $compose.services.database.Contains('ports')) 'Database has no host port'
        Assert ($compose.services.mattermost.restart -ceq 'unless-stopped' -and $compose.services.database.restart -ceq 'unless-stopped') 'Both services restart with Docker'
        Assert ($compose.volumes.Count -eq 7) 'Database and Mattermost files have persistent volumes'
        Assert ($compose.services.mattermost.environment.MM_TEAMSETTINGS_ENABLEOPENSERVER -ceq 'false' -and $compose.services.mattermost.environment.MM_PLUGINSETTINGS_ENABLE -ceq 'false') 'Open signup and plugins remain disabled'
        Assert ($compose.services.mattermost.image -cmatch '@sha256:[a-f0-9]{64}$' -and $compose.services.database.image -cmatch '@sha256:[a-f0-9]{64}$') 'Images use immutable digests'
        Set-HermesAdminComposeFiles $state
        Set-HermesAdminComposeFiles $again
        Assert $true 'Compose serialization is stable after metadata round-trip'
        $composePath = Join-Path $state.Directory 'compose.json'
        Assert (-not [IO.File]::ReadAllText($composePath).Contains($secret.Password)) 'Compose file contains no actual DB password'
        [IO.File]::AppendAllText($composePath,' ')
        Reject { Set-HermesAdminComposeFiles $state } 'Externally changed compose is not overwritten or run'
        [IO.File]::WriteAllText($composePath,(New-HermesAdminCompose $state | ConvertTo-Json -Depth 32))
        [IO.File]::WriteAllText((Join-Path $state.Directory 'compose.env'),'COMPOSE_PROFILES=foreign')
        Reject { Set-HermesAdminComposeFiles $state } 'Nonempty compose env rejected'
        [IO.File]::WriteAllText((Join-Path $state.Directory 'compose.env'),'')
        Set-HermesAdminPluginMode $state 'upload'
        $modeCompose = New-HermesAdminCompose $state
        Assert ($modeCompose.services.mattermost.environment.MM_PLUGINSETTINGS_ENABLE -ceq 'true' -and $modeCompose.services.mattermost.environment.MM_PLUGINSETTINGS_ENABLEUPLOADS -ceq 'true') 'Upload mode enables plugins only during installation'
        Set-HermesAdminPluginMode $state 'enabled'
        Assert ((New-HermesAdminCompose $state).services.mattermost.environment.MM_PLUGINSETTINGS_ENABLEUPLOADS -ceq 'false') 'Completed mode closes plugin uploads'
        # Model termination after journal persistence but before compose replacement.
        $state.PluginTransition = 'enabled'; $state.PluginMode = 'upload'
        Write-HermesAdminJSON $statePath $state
        Set-HermesAdminComposeFiles $state
        Assert ($null -eq $state.PluginTransition -and (Get-Content $composePath -Raw | ConvertFrom-Json).services.mattermost.environment.MM_PLUGINSETTINGS_ENABLEUPLOADS -ceq 'true') 'Interrupted known transition recovers from old compose'
        $state.PluginTransition = 'enabled'
        Set-HermesAdminComposeFiles $state
        Assert ($null -eq $state.PluginTransition) 'Interrupted transition also accepts already written target compose'
        $state.PluginTransition = 'enabled'
        [IO.File]::AppendAllText($composePath,' ')
        Reject { Set-HermesAdminComposeFiles $state } 'Transition journal cannot authorize arbitrary changed compose'
        [IO.File]::WriteAllText($composePath,(New-HermesAdminCompose $state | ConvertTo-Json -Depth 32))
        Set-HermesAdminComposeFiles $state
        Set-HermesAdminPluginMode $state 'disabled'
        Assert ((New-HermesAdminCompose $state).services.mattermost.environment.MM_PLUGINSETTINGS_ENABLE -ceq 'false') 'Legacy stage-two mode remains supported'
        $package = Get-HermesAdminBotControlPackage
        Assert ($package.Pin.version -ceq '0.6.2' -and $package.Pin.size -gt 0) 'Bundled plugin SHA256 and size validated'
        function script:Get-FileHash { return [pscustomobject]@{ Hash = ('0' * 64) } }
        Reject { Get-HermesAdminBotControlPackage } 'Tampered plugin hash rejected before deployment'
        Remove-Item Function:Get-FileHash
        $foreignDir = Join-Path $root 'foreign-test'; New-Item -ItemType Directory -Path $foreignDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $foreignDir 'keep.txt'),'keep')
        $copy = $data | ConvertTo-Json | ConvertFrom-Json; $copy.ServerId = 'foreign-test'
        Reject { New-HermesAdminState $copy $root } 'Nonempty foreign directory preserved'

        # Resource probes are mocked: no Docker daemon or existing container is modified.
        $script:foreignFixture = $true
        function script:Invoke-HermesAdminDocker {
            param($Arguments,[switch]$AllowFailure)
            if ($Arguments[0] -eq 'ps') { return [pscustomobject]@{ StdOut = 'fixture-container'; ExitCode = 0 } }
            if ($Arguments[0] -eq 'inspect') {
                $labelValue = $(if ($script:foreignFixture) { 'foreign-owner' } else { $script:fixtureId })
                return [pscustomobject]@{ StdOut = (@(@{ Config = @{ Labels = @{ 'com.infonet.easy-setup.deployment' = $labelValue } } }) | ConvertTo-Json -Depth 8); ExitCode = 0 }
            }
            if ($Arguments[0] -eq 'volume') { return [pscustomobject]@{ StdOut = '[]'; StdErr = 'no such volume'; ExitCode = 1 } }
            return [pscustomobject]@{ StdOut = '[]'; StdErr = "network $($Arguments[2]) not found"; ExitCode = 1 }
        }
        Reject { Assert-HermesAdminResources $state } 'Foreign container label prevents reuse'
        $script:foreignFixture = $false; $script:fixtureId = $state.DeploymentId
        Assert-HermesAdminResources $state
        Assert $true 'Own container and absent volumes/network accepted'

        $script:created = 0; $script:loggedOut = 0; $script:loginFails = $false; $script:role = 'system_user'; $script:loginFailureCode = 401
        function script:Invoke-HermesAdminAPI {
            param($BaseURL,$Path,$Method='GET',$Body=$null,$Token)
            if ($Path -eq '/api/v4/users/login') {
                if ($script:loginFails) { $e = New-Object Exception('fixture'); $e.Data['HttpStatus'] = $script:loginFailureCode; throw $e }
                return [pscustomobject]@{ Token = 'fixture-token'; Data = $null }
            }
            if ($Path -eq '/api/v4/users') { $script:created++; $script:loginFails = $false; return $null }
            if ($Path -eq '/api/v4/users/logout') { $script:loggedOut++; return $null }
            if ($Path -eq '/api/v4/users/me') { return [pscustomobject]@{ Data = @{ id = 'fixture-user'; roles = $script:role; username = 'labadmin'; email = 'admin@example.invalid'; delete_at = 0 } } }
            if ($Path -eq '/api/v4/config') { return [pscustomobject]@{ Data = @{ TeamSettings = @{ EnableOpenServer = $false }; PluginSettings = @{ Enable = $false } } } }
            if ($Path -like '*/channels/name/*') { return [pscustomobject]@{ Data = @{ id = 'fixture-channel' } } }
            return [pscustomobject]@{ Data = @{ id = 'fixture-team' } }
        }
        Reject { Initialize-HermesAdminAccount $state $data 'http://127.0.0.1:18065' } 'Normal user is never elevated by the installer'
        Assert ($script:loggedOut -eq 1 -and $script:created -eq 0) 'Rejected account session is logged out without creating another account'
        $script:role = 'system_user system_admin'
        $script:loginFails = $true
        $script:loginFailureCode = 503
        Reject { Initialize-HermesAdminAccount $state $data 'http://127.0.0.1:18065' } 'Server/network error is not treated as an absent account'
        Assert ($script:created -eq 0) 'Server errors never trigger account creation'
        $script:loginFailureCode = 401
        Initialize-HermesAdminAccount $state $data 'http://127.0.0.1:18065'
        Assert ($script:created -eq 1 -and $state.AdminUserId -ceq 'fixture-user') 'First account created and system_admin verified'
        Initialize-HermesAdminAccount $state $data 'http://127.0.0.1:18065'
        Assert ($script:created -eq 1 -and $state.ChannelId -ceq 'fixture-channel') 'Resume reuses verified admin and channel'
        $script:loginFails = $true
        Reject { Initialize-HermesAdminAccount $state $data 'http://127.0.0.1:18065' } 'Wrong password for known admin does not reset or replace it'
        Assert ($script:created -eq 1) 'No duplicate account on failed resume login'
        Write-Host "Admin tests passed: $script:passed"
    } finally {
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-admin-unit-'
        $resolved = [IO.Path]::GetFullPath($root)
        if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
} $projectRoot
