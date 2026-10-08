[CmdletBinding()]
param([switch]$Apply,[switch]$WithBotControl,[switch]$WithBots,[switch]$WithNetwork,[int]$Port = 18066)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $Apply) { throw 'This creates an isolated Docker test fixture. Pass -Apply explicitly.' }
if ($WithNetwork -and (-not $WithBots -or -not $WithBotControl)) { throw 'Network contract test requires -WithBotControl -WithBots.' }
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\HermesEasySetup.Loader.psm1') -Force
$module = Get-Module HermesEasySetup.Admin
& $module {
    param($TestPort,$ProjectRoot,$TestBotControl,$TestBots,$TestNetwork)
    $id = 'e2e-' + [Guid]::NewGuid().ToString('N').Substring(0,12)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('hermes-admin-e2e-' + [Guid]::NewGuid().ToString('N'))
    $data = [pscustomobject]@{ ServerId = $id; SiteName = 'Isolated E2E'; TeamName = 'test-lab'; TeamDisplayName = 'Test Lab'; ChannelName = 'agent'; Port = $TestPort; AdminUsername = 'testadmin'; AdminEmail = 'admin@example.invalid'; AdminPassword = ('A1!' + [Guid]::NewGuid().ToString('N')) }
    $state = $null
    $passed = $false
    $token = $null
    $dashboardFixture = $null
    function Run-CliFixture {
        param([switch]$Resume,[switch]$InstallBotControl,[switch]$Bot)
        $runtime = Join-Path $root 'cli-runtime'
        $inputPath = Join-Path $runtime 'ui-transport\admin.bin'
        $null = Protect-HermesLabInput $data $inputPath
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectRoot 'HermesEasySetup.ps1'),'-Action','AdminSetup','-Apply','-JsonEvents','-RuntimeRoot',$runtime,'-AdminRoot',$root,'-AdminInputPath',$inputPath)
        if ($Bot) { $arguments[$arguments.IndexOf('AdminSetup')] = 'AdminBotSetup' }
        if ($Resume) { $arguments += '-Resume' }
        if ($InstallBotControl) { $arguments += '-InstallBotControl' }
        $worker = Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList $arguments -TimeoutSeconds 1500
        if ($worker.ExitCode -ne 0) { throw ("Admin CLI failed: " + $worker.StdOut) }
        if (Test-Path -LiteralPath $inputPath) { throw 'CLI did not remove encrypted transport.' }
        $events = @($worker.StdOut -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        if ($events[-1].type -cne 'complete') { throw 'CLI complete event absent.' }
        if ($worker.StdOut.Contains($data.AdminPassword) -or $worker.StdErr.Contains($data.AdminPassword)) { throw 'Credential appeared in worker output.' }
        if ($Bot) {
            $credential = Read-HermesAdminBotCredential $events[-1].data
            if ($worker.StdOut.Contains($credential.Token) -or $worker.StdErr.Contains($credential.Token)) { throw 'Bot credential appeared in worker output.' }
        }
        return $events[-1].data
    }
    try {
        Write-Host 'Creating an isolated server through the same encrypted CLI transport used by the GUI...'
        $result = Run-CliFixture
        $state = Get-Content (Join-Path $result.Directory 'deployment.json') -Raw | ConvertFrom-Json
        $login = Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users/login' 'POST' @{ login_id = $data.AdminUsername; password = $data.AdminPassword }
        $token = $login.Token
        $post = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/posts' -Method POST -Token $token -Body @{ channel_id = $state.ChannelId; message = 'Isolated persistence check' }).Data
        $blocked = $false
        try { $null = Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users' 'POST' @{ username = 'uninvited'; email = 'uninvited@example.invalid'; password = $data.AdminPassword } }
        catch { $blocked = ($_.Exception.Data['HttpStatus'] -eq 403) }
        if (-not $blocked) { throw 'Unauthenticated signup must be blocked after bootstrap.' }
        Write-Host 'PASS first administrator, team/channel, closed public signup'
        $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/users' -Method POST -Token $token -Body @{ username = 'testmember'; email = 'member@example.invalid'; password = $data.AdminPassword }
        $memberLogin = Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users/login' 'POST' @{ login_id = 'testmember'; password = $data.AdminPassword }
        $memberDenied = $false
        try {
            try { $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/config' -Token $memberLogin.Token }
            catch { $memberDenied = ($_.Exception.Data['HttpStatus'] -eq 403) }
        } finally { $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/users/logout' -Method POST -Token $memberLogin.Token }
        if (-not $memberDenied) { throw 'A normal account must not read the system administration config API.' }
        Write-Host 'PASS normal user denied administrative config API (HTTP 403)'
        $null = Invoke-HermesAdminCompose $state @('restart')
        Wait-HermesAdminServer $result.ServerURL
        $persisted = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path ("/api/v4/posts/" + $post.id) -Token $token).Data
        if ($persisted.message -cne 'Isolated persistence check') { throw 'Message not retained across restart.' }
        Write-Host 'PASS database persistence across container restart'
        $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/users/logout' -Method POST -Token $token
        $token = $null
        $null = Run-CliFixture -Resume
        $after = Get-Content (Join-Path $result.Directory 'deployment.json') -Raw | ConvertFrom-Json
        if ($after.AdminUserId -cne $state.AdminUserId -or $after.TeamId -cne $state.TeamId -or $after.ChannelId -cne $state.ChannelId) { throw 'Resume duplicated or changed an object.' }
        Write-Host 'PASS idempotent resume preserves admin, team and channel IDs'
        if ($TestBotControl) {
            Write-Host 'Upgrading the existing stage-two fixture with Bot Control...'
            $result = Run-CliFixture -Resume -InstallBotControl
            $state = Get-Content (Join-Path $result.Directory 'deployment.json') -Raw | ConvertFrom-Json
            if (-not $result.BotControlReady -or $state.PluginMode -cne 'enabled') { throw 'Bot Control not ready or uploads left open.' }
            $token = (Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users/login' 'POST' @{ login_id = $data.AdminUsername; password = $data.AdminPassword }).Token
            $memberToken = (Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users/login' 'POST' @{ login_id = 'testmember'; password = $data.AdminPassword }).Token
            try {
                foreach ($request in @(
                    @('/plugins/com.infonet.bot-control/api/v1/access','GET'),
                    @('/plugins/com.infonet.bot-control/api/v1/agents','GET'),
                    @('/plugins/com.infonet.bot-control/api/v1/hermes/apply','POST'),
                    @('/api/v4/plugins/com.infonet.bot-control/disable','POST'),
                    @('/api/v4/plugins/com.infonet.bot-control/enable','POST'),
                    @('/api/v4/plugins/com.infonet.bot-control','DELETE'),
                    @('/api/v4/config/patch','PUT')
                )) {
                    $denied = $false
                    try { $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path $request[0] -Method $request[1] -Token $memberToken -Body $(if ($request[1] -in @('POST','PUT')) { @{} } else { $null }) }
                    catch { $denied = ($_.Exception.Data['HttpStatus'] -eq 403) }
                    if (-not $denied) { throw ("Normal member not denied: " + $request[0]) }
                }
                $anonymousDenied = $false
                try { $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/plugins/com.infonet.bot-control/api/v1/agents' }
                catch { $anonymousDenied = ($_.Exception.Data['HttpStatus'] -eq 401) }
                if (-not $anonymousDenied) { throw 'Anonymous plugin access not denied.' }
                # A caller-supplied identity header must be replaced by Mattermost's authenticated identity.
                $spoofDenied = $false
                try {
                    $null = Invoke-WebRequest -UseBasicParsing -Uri ($result.ServerURL + '/plugins/com.infonet.bot-control/api/v1/access') -Headers @{ Authorization = "Bearer $memberToken"; 'Mattermost-User-Id' = $state.AdminUserId } -TimeoutSec 10
                } catch { $spoofDenied = [int]$_.Exception.Response.StatusCode -eq 403 }
                if (-not $spoofDenied) { throw 'Mattermost identity header spoof was accepted.' }
                Write-Host 'PASS anonymous 401; member 403 for management routes, native plugin changes and settings; forged admin header rejected'
            } finally { $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/users/logout' -Method POST -Token $memberToken }
            $config = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/config' -Token $token).Data
            if ($config.PluginSettings.EnableUploads) { throw 'Uploads not sealed after installation.' }
            $null = Invoke-HermesAdminCompose $state @('restart','mattermost')
            Wait-HermesAdminServer $result.ServerURL
            $access = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/plugins/com.infonet.bot-control/api/v1/access' -Token $token).Data
            if ($access.plugin_version -cne '0.6.2' -or -not $access.system_admin) { throw 'Plugin did not survive restart.' }
            $null = Run-CliFixture -Resume -InstallBotControl
            Write-Host 'PASS plugin installed, active after restart, uploads sealed, and repeated installation idempotent'
        }
        if ($TestBots) {
            Write-Host 'Testing admin bot issuance through encrypted CLI transport...'
            $data | Add-Member BotUsername 'fixture_bot'
            $data | Add-Member BotDisplayName 'Fixture Bot'
            $data | Add-Member BotDescription 'Isolated role and token verification'
            $first = Run-CliFixture -Bot
            $credential = Read-HermesAdminBotCredential $first
            $again = Run-CliFixture -Bot
            if ($again.BotId -cne $first.BotId -or $again.TokenId -cne $first.TokenId) { throw 'Retry created duplicate bot/token.' }
            $state = Get-Content (Join-Path $result.Directory 'deployment.json') -Raw | ConvertFrom-Json
            $token = (Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users/login' 'POST' @{ login_id = $data.AdminUsername; password = $data.AdminPassword }).Token
            $tokens = @(Get-HermesAdminBotTokens $result.ServerURL $token $first.BotId)
            if ($tokens.Count -ne 1 -or $state.BotCreationPending) { throw 'Duplicate tokens or unsealed bot creation journal.' }
            $config = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/config' -Token $token).Data
            if ($config.ServiceSettings.EnableBotAccountCreation -or $config.ServiceSettings.EnableUserAccessTokens) { throw 'Bot creation or human personal tokens left enabled.' }
            $botMe = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/users/me' -Token $credential.Token).Data
            if ($botMe.id -cne $first.BotId -or $botMe.roles -cne 'system_user') { throw 'Unexpected bot privilege.' }
            $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/api/v4/posts' -Method POST -Token $credential.Token -Body @{ channel_id = $first.HomeChannelId; message = 'Fixture bot can speak in assigned channel.' }
            foreach ($path in @('/api/v4/config', '/plugins/com.infonet.bot-control/api/v1/access') | Where-Object { $TestBotControl -or $_ -notlike '/plugins/*' }) {
                $denied = $false
                try { $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path $path -Token $credential.Token } catch { $denied = $_.Exception.Data['HttpStatus'] -eq 403 }
                if (-not $denied) { throw 'Bot gained management access.' }
            }
            # Verify native permissions while creation is temporarily enabled, not merely the closed feature flag.
            $memberToken = (Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users/login' 'POST' @{ login_id = 'testmember'; password = $data.AdminPassword }).Token
            try {
                Enable-HermesAdminBotCreation $state $result.ServerURL $token
                foreach ($request in @(@('/api/v4/bots',@{ username = 'forbidden_bot'; display_name = 'Forbidden' }),@("/api/v4/users/$($first.BotId)/tokens",@{ description = 'forbidden' }))) {
                    $denied = $false
                    try { $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path $request[0] -Method POST -Token $memberToken -Body $request[1] } catch { $denied = $_.Exception.Data['HttpStatus'] -eq 403 }
                    if (-not $denied) { throw 'Member could create a bot or issue another bot token.' }
                }
            } finally { Restore-HermesAdminBotCreation $state $result.ServerURL $token }
            $data.BotUsername = 'fixture_second'; $data.BotDisplayName = 'Second Bot'
            $second = Run-CliFixture -Bot
            if ($second.BotId -ceq $first.BotId -or $second.TokenId -ceq $first.TokenId) { throw 'Separate bots shared identity/token.' }
            $secretText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $first.Directory 'bots\fixture_bot.bin')))
            $metadataText = [IO.File]::ReadAllText((Join-Path $first.Directory 'bots\fixture_bot.json')) + [IO.File]::ReadAllText((Join-Path $first.Directory 'deployment.json'))
            if ($secretText.Contains($credential.Token) -or $metadataText.Contains($credential.Token)) { throw 'Bot token stored in plaintext.' }
            $null = Invoke-HermesAdminCompose $state @('restart','mattermost')
            Wait-HermesAdminServer $result.ServerURL
            $data.BotUsername = 'fixture_bot'; $data.BotDisplayName = 'Fixture Bot'
            $afterRestart = Run-CliFixture -Bot
            if ($afterRestart.TokenId -cne $first.TokenId) { throw 'Restart lost issued token identity.' }
            Write-Host 'PASS two distinct bots; general channel posting; admin/member/bot permission boundaries; one token on retries and restart; no secret in stdout/stderr/metadata'
        }
        if ($TestNetwork) {
            $address = Get-HermesAdminNetBirdAddress
            $data | Add-Member NetworkMode 'Share' -Force
            $data | Add-Member NetworkAddress $address -Force
            $shared = Run-CliFixture -Resume -InstallBotControl
            if ($shared.ServerURL -cne "http://${address}:$TestPort" -or $shared.PeerAccessVerified) { throw 'Shared address or peer verification claim is incorrect.' }
            $state = Get-Content (Join-Path $result.Directory 'deployment.json') -Raw | ConvertFrom-Json
            Assert-HermesAdminPort $state -Exact
            $connection = Test-HermesLabConnection -MattermostURL $shared.ServerURL -BotToken $credential.Token -HomeChannelID $first.HomeChannelId
            if ($connection.BotUserID -cne $first.BotId) { throw 'Shared endpoint authenticated another bot.' }
            Write-Host 'PASS NetBird-specific and loopback bindings, effective SiteURL, and user connection preflight on this PC (not a remote peer test)'
            # Real Mattermost and real Bot Control; deliberately simulated Dashboard, no existing Hermes touched.
            $fixturePassword = [Guid]::NewGuid().ToString('N')
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'nodejs\node.exe'
            $start.Arguments = ConvertTo-WindowsProcessArgument (Join-Path $ProjectRoot 'tests\fixtures\dashboard-contract.cjs')
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $start.EnvironmentVariables['HES_FIXTURE_HOST'] = $address
            $start.EnvironmentVariables['HES_FIXTURE_PASSWORD'] = $fixturePassword
            $dashboardFixture = New-Object Diagnostics.Process
            $dashboardFixture.StartInfo = $start
            if (-not $dashboardFixture.Start()) { throw 'Dashboard fixture failed to start.' }
            $lineTask = $dashboardFixture.StandardOutput.ReadLineAsync()
            if (-not $lineTask.Wait(15000)) { throw 'Dashboard fixture startup timed out.' }
            $dashboardPort = ($lineTask.GetAwaiter().GetResult() | ConvertFrom-Json).port
            $dashboardURL = "http://${address}:$dashboardPort"
            $registration = & (Get-Module HermesEasySetup.Lab) {
                param($MM,$Bot,$Dashboard,$Password,$IP,$Port)
                Register-HermesWithBotControl -MattermostURL $MM -BotToken $Bot -DashboardURL $Dashboard -DashboardUsername 'admin' -DashboardPassword $Password -Profile 'infonet-fixture' -NetBirdIP $IP -DashboardPort $Port -HermesVersion 'contract-fixture-not-Hermes'
            } $shared.ServerURL $credential.Token $dashboardURL $fixturePassword $address $dashboardPort
            if ($registration.bot_user_id -cne $first.BotId) { throw 'Registration identity mismatch.' }
            $token = (Invoke-HermesAdminAPI $result.ServerURL '/api/v4/users/login' 'POST' @{ login_id = $data.AdminUsername; password = $data.AdminPassword }).Token
            $registry = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/plugins/com.infonet.bot-control/api/v1/agents' -Token $token).Data
            if (($registry | ConvertTo-Json -Depth 20).Contains($fixturePassword)) { throw 'Registry response leaked Dashboard password.' }
            $applied = (Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path '/plugins/com.infonet.bot-control/api/v1/hermes/apply' -Method POST -Token $token -Body @{ bot_user_id = $first.BotId; profile = 'infonet-fixture'; full_name = 'Integrated Fixture Agent'; role = 'Summarize research'; require_mention = $true; reply_mode = 'off' }).Data
            $snapshot = Invoke-RestMethod -Uri ($dashboardURL + '/__fixture/state') -Headers @{ Authorization = 'Bearer ' + $fixturePassword } -TimeoutSec 10
            if ($snapshot.soul -notmatch 'Integrated Fixture Agent' -or $snapshot.soul -notmatch 'Summarize research' -or $snapshot.env.MATTERMOST_REQUIRE_MENTION -cne 'true' -or $snapshot.env.MATTERMOST_REPLY_MODE -cne 'off' -or $snapshot.restarts -ne 1 -or @($snapshot.deleted).Count -ne 1 -or $snapshot.deleted[0] -cne 'fixture-open' -or $applied.sessions_reset -ne 1) { throw 'Policy contract was not applied end to end.' }
            Write-Host 'PASS user registration -> real Mattermost plugin -> authenticated Dashboard TEST DOUBLE; profile identity/env/session reset/restart contract verified (not a real Hermes/LLM run)'
            $data.NetworkMode = 'Local'
            $local = Run-CliFixture -Resume -InstallBotControl
            $state = Get-Content (Join-Path $result.Directory 'deployment.json') -Raw | ConvertFrom-Json
            if ($local.ServerURL -cne $result.ServerURL -or (Get-HermesAdminNetworkAddress $state)) { throw 'Unshare did not restore loopback.' }
            Assert-HermesAdminPort $state -Exact
            $null = Invoke-HermesAdminAPI -BaseURL $result.ServerURL -Path "/api/v4/posts/$($post.id)" -Token $credential.Token
            Write-Host 'PASS sharing disabled again; original data and bot token retained'
        }
        $passed = $true
    } finally {
        if ($dashboardFixture) { if (-not $dashboardFixture.HasExited) { $dashboardFixture.Kill(); $dashboardFixture.WaitForExit(5000) | Out-Null }; $dashboardFixture.Dispose() }
        # Re-read journal after a failed transition so fixture cleanup uses the exact current compose.
        if (Test-Path (Join-Path $root "$id\deployment.json")) { $state = Get-Content (Join-Path $root "$id\deployment.json") -Raw | ConvertFrom-Json }
        if (-not $state -and (Test-Path (Join-Path $root "$id\deployment.json"))) { $state = Get-Content (Join-Path $root "$id\deployment.json") -Raw | ConvertFrom-Json }
        if ($state) {
            # Only this exact randomly named fixture may be destroyed; never a user deployment.
            $expected = [IO.Path]::GetFullPath((Join-Path $root $id))
            if ($state.Directory -cne $expected -or $state.Identity.ServerId -cne $id -or $state.Project -cne "hes-$id-$($state.DeploymentId.Substring(0,8))") { throw 'Refusing unsafe fixture cleanup.' }
            Assert-HermesAdminResources $state
            $null = Invoke-HermesAdminCompose $state @('down','--volumes')
            Write-Host 'Removed only isolated E2E fixture containers, network and volumes (cached images retained).'
        }
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-admin-e2e-'
        $resolved = [IO.Path]::GetFullPath($root)
        if ($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
    if (-not $passed) { throw 'Admin Docker E2E did not complete.' }
} $Port (Split-Path -Parent $PSScriptRoot) ([bool]$WithBotControl) ([bool]$WithBots) ([bool]$WithNetwork)
