[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\HermesEasySetup.Loader.psm1') -Force
$module = Get-Module HermesEasySetup.Mattermost
& $module {
    $script:passed = 0
    function Assert { param($Condition, [string]$Name) if (-not $Condition) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject { param([scriptblock]$Action, [string]$Name) $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Assert $failed $Name }
    $base = 'https://lab.example.invalid'
    Assert ((ConvertTo-HermesMattermostURL 'https://LAB.example.invalid:443/') -ceq $base) 'Normalize host, default port and trailing slash'
    foreach ($bad in @('file:///C:/test', 'javascript:alert(1)', 'https://name:password@example.invalid', 'https://example.invalid/?token=secret', 'https://example.invalid/#hash', 'https://example.invalid/team/channels/agent', 'http://example.invalid/hello world')) {
        Reject { ConvertTo-HermesMattermostURL $bad } 'Reject unsafe URL or non-base address'
    }
    $new = Merge-HermesMattermostServer -ServerURL $base -ServerName '연구실'
    Assert ($new.Changed -and $new.Config.version -eq 4 -and $new.Config.servers.Count -eq 1) 'Fresh v4 server configuration'
    $again = Merge-HermesMattermostServer -ConfigText ($new.Config | ConvertTo-Json -Depth 20) -ServerURL ($base + '/') -ServerName 'Other name'
    Assert (-not $again.Changed -and $again.Config.servers[0].name -ceq '연구실') 'Idempotent server registration preserves existing display name'
    foreach ($version in @(1,2,3,4)) {
        $key = $(if ($version -eq 4) { 'servers' } else { 'teams' })
        $config = [ordered]@{ version = $version; darkMode = $true; lastActiveServer = 3; customField = @{ nested = 'preserve' }; notifications = @{ flashWindow = 7 } }
        $config[$key] = @(@{ name = 'Existing'; url = 'https://old.example.invalid'; order = 5; custom = 'keep' })
        $merged = Merge-HermesMattermostServer -ConfigText ($config | ConvertTo-Json -Depth 20) -ServerURL $base -ServerName '연구실'
        Assert ($merged.Config.version -eq $version -and $merged.Config.$key.Count -eq 2 -and $merged.Config.$key[0].custom -ceq 'keep') "Preserve v$version schema and prior server"
        Assert ($merged.Config.darkMode -and $merged.Config.customField.nested -ceq 'preserve' -and $merged.Config.notifications.flashWindow -eq 7 -and $merged.Config.lastActiveServer -eq 3) "Preserve v$version unknown fields, preferences and selection"
        if ($version -gt 1) { Assert ($merged.Config.$key[1].order -eq 6) "Append after existing v$version order" }
        if ($version -eq 3) { Assert ($merged.Config.teams[1].tabs[0].name -ceq 'channels') 'v3 includes channel tab metadata' }
    }
    foreach ($badConfig in @('{broken', '{}', 'null', '[]', '{"version":99,"servers":[]}', '{"version":4,"servers":null}', '{"version":4,"servers":{}}', '{"version":4,"servers":[null]}')) {
        Reject { Merge-HermesMattermostServer -ConfigText $badConfig -ServerURL $base -ServerName 'Lab' } 'Invalid/future config fails closed'
    }
    Reject { Merge-HermesMattermostServer -ServerURL $base -ServerName ' ' } 'Blank server name rejected'
    function script:Test-HermesMattermostRunning { return $script:runningFixture }
    $script:runningFixture = $false
    $root = Join-Path ([IO.Path]::GetTempPath()) ('hermes-mattermost-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $path = Join-Path $root 'Mattermost\config.json'
        $result = Set-HermesMattermostServer -ServerURL $base -ServerName 'Lab' -ConfigPath $path
        Assert ($result.Changed -and -not $result.BackupPath) 'Fresh file creation in isolated fixture'
        $before = [IO.File]::ReadAllText($path)
        $result = Set-HermesMattermostServer -ServerURL 'https://other.example.invalid' -ServerName 'Second' -ConfigPath $path
        Assert ([IO.File]::ReadAllText($result.BackupPath) -ceq $before) 'Atomic replacement keeps byte-equivalent readable backup'
        $script:runningFixture = $true
        $result = Set-HermesMattermostServer -ServerURL $base -ServerName 'Lab' -ConfigPath $path
        Assert (-not $result.Changed) 'Already registered server does not require closing app'
        $before = [IO.File]::ReadAllText($path)
        Reject { Set-HermesMattermostServer -ServerURL 'https://third.example.invalid' -ServerName 'Third' -ConfigPath $path } 'Running app prevents config mutation'
        Assert ([IO.File]::ReadAllText($path) -ceq $before) 'Running app rejection preserves original content'
        $script:runningFixture = $false
        [IO.File]::WriteAllText($path, '{bad')
        Reject { Set-HermesMattermostServer -ServerURL $base -ServerName 'Lab' -ConfigPath $path } 'Damaged file cannot be overwritten'
        Assert ([IO.File]::ReadAllText($path) -ceq '{bad') 'Damaged file is retained for recovery'
        [IO.File]::WriteAllText($path, '')
        Reject { Set-HermesMattermostServer -ServerURL $base -ServerName 'Lab' -ConfigPath $path } 'Empty existing file cannot be overwritten'
        $pin = Get-HermesMattermostPackage
        Assert ($pin.version -ceq '6.3.0' -and $pin.sha256.Length -eq 64) 'Official pinned x64 MSI metadata'
        $fakePackage = Join-Path $root 'invalid.msi'
        [IO.File]::WriteAllText($fakePackage, 'not an installer')
        Reject { Assert-HermesMattermostPackage -LiteralPath $fakePackage -Pin $pin } 'Untrusted package hash fails before execution'

        # Mock installation and current-user configuration: never install or touch live AppData.
        $script:installCalls = 0
        $script:fixtureInstalled = $true
        $script:fixtureInstallFailure = $false
        function script:Get-HermesMattermostDesktop { return [pscustomobject]@{ Installed = $script:fixtureInstalled; Path = $(if ($script:fixtureInstalled) { 'C:\fixture\Mattermost.exe' } else { $null }) } }
        function script:Install-HermesMattermostDesktop { param($RuntimeRoot) $script:installCalls++; if ($script:fixtureInstallFailure) { throw 'UAC cancelled fixture' }; $script:fixtureInstalled = $true; return $true }
        function script:Set-HermesMattermostServer { param($ServerURL,$ServerName) return [pscustomobject]@{ Changed = $false; ConfigPath = 'fixture'; BackupPath = $null } }
        function script:Test-HermesMattermostServer { param($ServerURL) return $false }
        $script:events = @()
        $result = Invoke-HermesMattermostSetup -ServerURL $base -ServerName 'Lab' -RuntimeRoot $root -ProgressCallback { param($e) $script:events += $e }
        Assert ($script:installCalls -eq 0 -and $result.Ready -and -not $result.LoginVerified -and -not $result.ServerReachable) 'Existing desktop reused; registration does not claim connectivity/login'
        Assert ($script:events[-1].type -eq 'complete') 'Completion event emitted only after registration'
        $script:fixtureInstalled = $false
        $script:fixtureInstallFailure = $true
        Reject { Invoke-HermesMattermostSetup -ServerURL $base -ServerName 'Lab' -RuntimeRoot $root } 'Install/UAC failure surfaces without success'
        $script:fixtureInstallFailure = $false
        $result = Invoke-HermesMattermostSetup -ServerURL $base -ServerName 'Lab' -RuntimeRoot $root
        Assert ($result.Ready -and $result.RebootRequired -and $script:installCalls -eq 2) 'Failed install can retry; reboot code remains visible'
        Write-Host "Mattermost tests passed: $script:passed"
    } finally {
        $resolved = [IO.Path]::GetFullPath($root)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-mattermost-test-'
        if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
