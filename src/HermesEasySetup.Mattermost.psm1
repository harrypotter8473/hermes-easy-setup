Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-HermesMattermostURL {
    param([Parameter(Mandatory = $true)][string]$ServerURL)
    $uri = $null
    if (-not [Uri]::TryCreate($ServerURL.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $ServerURL -match '[\x00-\x20"<>]' -or $uri.AbsolutePath -match '/(?:channels|login|signup_user_complete)(?:/|$)') {
        throw 'Mattermost 서버 기본 주소(http:// 또는 https://)를 입력하세요. 비밀번호·초대 링크·채널 주소는 넣지 않습니다.'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Assert-HermesMattermostPath {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $path = [IO.Path]::GetFullPath($LiteralPath)
    while ($path) {
        if (Test-Path -LiteralPath $path) {
            if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Mattermost 설치·설정 경로의 링크 또는 junction은 지원하지 않습니다.'
            }
        }
        $path = Split-Path -Parent $path
    }
}

function Get-HermesMattermostDesktop {
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\mattermost-desktop\Mattermost.exe'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Mattermost\Mattermost.exe'),
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Mattermost\Mattermost.exe')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Assert-HermesMattermostPath $path
            return [pscustomobject]@{ Installed = $true; Path = $path; Kind = 'Desktop'; Version = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion }
        }
    }
    # Detect Store/custom installs too: never install a second copy over them.
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $store = @(Get-AppxPackage -Name '*Mattermost*' -ErrorAction SilentlyContinue)
        if ($store.Count -gt 0) { return [pscustomobject]@{ Installed = $true; Path = $null; Kind = 'Store'; Version = [string]$store[0].Version } }
    }
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like '*Mattermost*' })) {
            if ($entry.PSObject.Properties['InstallLocation'] -and $entry.InstallLocation) {
                $path = Join-Path $entry.InstallLocation 'Mattermost.exe'
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Assert-HermesMattermostPath $path
                    return [pscustomobject]@{ Installed = $true; Path = $path; Kind = 'Desktop'; Version = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion }
                }
            }
            return [pscustomobject]@{ Installed = $true; Path = $null; Kind = 'Unknown'; Version = $null }
        }
    }
    return [pscustomobject]@{ Installed = $false; Path = $null; Kind = 'Missing'; Version = $null }
}

function Test-HermesMattermostRunning {
    return (@(Get-Process -Name Mattermost -ErrorAction SilentlyContinue).Count -gt 0)
}

function Merge-HermesMattermostServer {
    param([AllowNull()][string]$ConfigText, [string]$ServerURL, [string]$ServerName)
    $url = ConvertTo-HermesMattermostURL $ServerURL
    $name = $ServerName.Trim()
    if (-not $name -or $name.Length -gt 80 -or $name -match '[\x00-\x1f]') { throw '서버 표시 이름은 1~80자로 입력하세요.' }
    if ([string]::IsNullOrWhiteSpace($ConfigText)) {
        $config = [pscustomobject]@{ version = 4; servers = @() }
    } else {
        try { $config = ConvertFrom-Json -InputObject $ConfigText -ErrorAction Stop } catch { throw '기존 Mattermost config.json을 해석할 수 없습니다. 원본은 변경하지 않았습니다.' }
    }
    if ($null -eq $config -or $config -is [array] -or -not $config.PSObject.Properties['version'] -or
        [string]$config.version -notin @('1','2','3','4')) {
        throw '지원하지 않는 Mattermost 설정 형식입니다. 기존 설정을 보존하고 중단합니다.'
    }
    $listKey = $(if ([int]$config.version -eq 4) { 'servers' } else { 'teams' })
    if (-not $config.PSObject.Properties[$listKey] -or $null -eq $config.$listKey -or $config.$listKey -isnot [array]) {
        throw '기존 Mattermost 서버 목록이 올바르지 않습니다. 원본은 변경하지 않았습니다.'
    }
    $servers = @($config.$listKey)
    foreach ($server in $servers) {
        if ($null -eq $server -or -not $server.PSObject.Properties['url']) { throw '기존 Mattermost 서버 항목이 올바르지 않습니다.' }
        try { $existingURL = ConvertTo-HermesMattermostURL ([string]$server.url) } catch { continue }
        if ([string]::Equals($existingURL, $url, [StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Changed = $false; Config = $config; URL = $url }
        }
    }
    $nextOrder = 0
    foreach ($server in $servers) {
        if ($server.PSObject.Properties['order']) { $nextOrder = [Math]::Max($nextOrder, ([int]$server.order + 1)) }
    }
    $newServer = [pscustomobject][ordered]@{ name = $name; url = $url }
    if ([int]$config.version -ge 2) { $newServer | Add-Member -NotePropertyName order -NotePropertyValue $nextOrder }
    if ([int]$config.version -eq 3) { $newServer | Add-Member -NotePropertyName tabs -NotePropertyValue @([pscustomobject]@{ name = 'channels'; order = 0; isOpen = $true }) }
    $config.$listKey = @($servers) + @($newServer)
    return [pscustomobject]@{ Changed = $true; Config = $config; URL = $url }
}

function Set-HermesMattermostServer {
    param([string]$ServerURL, [string]$ServerName, [string]$ConfigPath = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Mattermost\config.json'))
    $configPath = [IO.Path]::GetFullPath($ConfigPath)
    Assert-HermesMattermostPath $configPath
    $exists = Test-Path -LiteralPath $configPath -PathType Leaf
    $original = $(if ($exists) { [IO.File]::ReadAllText($configPath) } else { $null })
    if ($exists -and [string]::IsNullOrWhiteSpace($original)) { throw '기존 Mattermost 설정 파일이 비어 있습니다. 원본을 보존하고 중단합니다.' }
    $merged = Merge-HermesMattermostServer -ConfigText $original -ServerURL $ServerURL -ServerName $ServerName
    if (-not $merged.Changed) { return [pscustomobject]@{ Changed = $false; BackupPath = $null; ConfigPath = $configPath; URL = $merged.URL } }
    if (Test-HermesMattermostRunning) { throw 'Mattermost가 실행 중입니다. 트레이 아이콘에서 완전히 종료한 뒤 다시 시도하세요. 앱을 강제 종료하거나 설정을 덮어쓰지 않았습니다.' }
    $directory = Split-Path -Parent $configPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $id = [Guid]::NewGuid().ToString('N')
    $temporary = Join-Path $directory "config.hermes-$id.tmp"
    $backup = $null
    try {
        [IO.File]::WriteAllText($temporary, ($merged.Config | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
        Assert-HermesMattermostPath $configPath
        if (Test-HermesMattermostRunning) { throw 'Mattermost가 다시 실행되었습니다. 종료 후 다시 시도하세요.' }
        if ($exists) {
            if (-not [IO.File]::Exists($configPath) -or [IO.File]::ReadAllText($configPath) -cne $original) { throw '다른 작업이 Mattermost 설정을 변경했습니다. 다시 시도하세요.' }
            $backup = Join-Path $directory "config.before-hermes-$id.json"
            [IO.File]::Replace($temporary, $configPath, $backup)
        } else { [IO.File]::Move($temporary, $configPath) }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return [pscustomobject]@{ Changed = $true; BackupPath = $backup; ConfigPath = $configPath; URL = $merged.URL }
}

function Get-HermesMattermostPackage {
    $pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config\mattermost-desktop.json') -Raw | ConvertFrom-Json
    if ($pin.version -notmatch '^\d+\.\d+\.\d+$' -or $pin.architecture -cne 'x64' -or $pin.sha256 -notmatch '^[a-f0-9]{64}$' -or
        $pin.url -cne "https://github.com/mattermost/desktop/releases/download/v$($pin.version)/mattermost-desktop-$($pin.version)-win-x64.msi") {
        throw 'Mattermost 공식 설치 파일 고정 정보가 올바르지 않습니다.'
    }
    return $pin
}

function Assert-HermesMattermostPackage {
    param([string]$LiteralPath, $Pin)
    if ((Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pin.sha256) { throw 'Mattermost 설치 파일 SHA-256 검증에 실패했습니다. 실행하지 않습니다.' }
    $signature = Get-HermesAuthenticodeSignature -LiteralPath $LiteralPath
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)(?:CN|O)="?Mattermost(?:,? Inc\.?)?"?(?:,|$)') {
        throw 'Mattermost 설치 파일의 공식 배포자 서명을 확인하지 못했습니다. 실행하지 않습니다.'
    }
}

function Install-HermesMattermostDesktop {
    param([string]$RuntimeRoot)
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw '이번 Mattermost 자동 설치는 Windows x64만 지원합니다.' }
    $pin = Get-HermesMattermostPackage
    $cache = Join-Path $RuntimeRoot 'cache\mattermost-desktop'
    Assert-HermesMattermostPath $cache
    if (-not (Test-Path -LiteralPath $cache)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }
    $msi = Join-Path $cache "mattermost-$($pin.version)-x64.msi"
    Assert-HermesMattermostPath $msi
    if (-not (Test-Path -LiteralPath $msi -PathType Leaf)) {
        $partial = Join-Path $cache (([Guid]::NewGuid().ToString('N')) + '.partial.msi')
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $pin.url -OutFile $partial -TimeoutSec 600 | Out-Null
            Assert-HermesMattermostPackage -LiteralPath $partial -Pin $pin
            [IO.File]::Move($partial, $msi)
        } finally { if (Test-Path -LiteralPath $partial -PathType Leaf) { Remove-Item -LiteralPath $partial -Force } }
    }
    Assert-HermesMattermostPackage -LiteralPath $msi -Pin $pin
    $msiexec = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\msiexec.exe'
    $args = '/i ' + (ConvertTo-WindowsProcessArgument $msi) + ' /qn /norestart'
    $process = $null
    # Hold a read lock across verification and elevated execution to prevent replacement.
    $packageLock = [IO.File]::Open($msi, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-HermesMattermostPackage -LiteralPath $msi -Pin $pin
        try { $process = Start-Process -FilePath $msiexec -ArgumentList $args -Verb RunAs -WindowStyle Hidden -PassThru } catch { throw 'Mattermost 설치 관리자 승인이 취소되었거나 시작하지 못했습니다. 다시 시도할 수 있습니다.' }
        [void]$process.Handle
        $process.WaitForExit()
        $code = $process.ExitCode
        if ($code -notin @(0,3010)) { throw "Mattermost MSI 설치에 실패했습니다 (종료 코드 $code). 1618이면 다른 설치가 끝난 뒤 다시 시도하세요." }
        return ($code -eq 3010)
    } finally { if ($null -ne $process) { $process.Dispose() }; $packageLock.Dispose() }
}

function Invoke-HermesMattermostSetup {
    param([string]$ServerURL, [string]$ServerName, [string]$RuntimeRoot, [scriptblock]$ProgressCallback)
    $url = ConvertTo-HermesMattermostURL $ServerURL
    [void](Merge-HermesMattermostServer -ConfigText $null -ServerURL $url -ServerName $ServerName)
    $mutex = New-Object Threading.Mutex($false, 'Local\HermesEasySetup-MattermostDesktop')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw '다른 Mattermost 설치·연결 작업이 실행 중입니다.' }
        if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'stage'; state = 'running'; percent = 10; message = 'Mattermost Desktop 설치 상태를 확인합니다.' }) }
        $desktop = Get-HermesMattermostDesktop
        $reboot = $false
        if (-not $desktop.Installed) {
            if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'stage'; state = 'running'; percent = 30; message = '공식 MSI를 다운로드·해시·서명 검증 후 설치합니다. Windows 관리자 승인을 허용하세요.' }) }
            $reboot = Install-HermesMattermostDesktop -RuntimeRoot $RuntimeRoot
            $desktop = Get-HermesMattermostDesktop
        }
        if (-not $desktop.Installed -or -not $desktop.Path) { throw 'Mattermost 실행 파일을 확인하지 못했습니다. Store 또는 사용자 지정 설치는 자동 변경하지 않습니다. 기존 앱을 보존했으므로 설치 위치를 확인하세요.' }
        if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'stage'; state = 'running'; percent = 85; message = '기존 설정을 보존하며 연구실 서버를 등록합니다.' }) }
        $registration = Set-HermesMattermostServer -ServerURL $url -ServerName $ServerName
        $reachable = Test-HermesMattermostServer -ServerURL $url
        $result = [pscustomobject]@{ Ready = $true; AppPath = $desktop.Path; ServerURL = $url; ServerName = $ServerName; ConfigPath = $registration.ConfigPath; Changed = $registration.Changed; BackupPath = $registration.BackupPath; RebootRequired = $reboot; ServerReachable = $reachable; LoginVerified = $false }
        if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'complete'; state = 'succeeded'; percent = 100; message = 'Desktop 준비와 서버 등록 완료. 사람 계정 로그인은 앱에서 직접 진행하세요.'; data = $result }) }
        return $result
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Test-HermesMattermostServer {
    param([string]$ServerURL)
    try {
        $url = ConvertTo-HermesMattermostURL $ServerURL
        $response = Invoke-RestMethod -Uri ($url + '/api/v4/system/ping') -Method Get -TimeoutSec 10
        return ($null -ne $response -and $response.PSObject.Properties['status'] -and [string]$response.status -ceq 'OK')
    } catch { return $false }
}

Export-ModuleMember -Function @('ConvertTo-HermesMattermostURL', 'Get-HermesMattermostDesktop', 'Merge-HermesMattermostServer', 'Set-HermesMattermostServer', 'Invoke-HermesMattermostSetup', 'Get-HermesMattermostPackage')
