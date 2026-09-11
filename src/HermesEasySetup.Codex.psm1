Set-StrictMode -Version 2.0

function New-HermesCodexEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )
    $environment = Get-HermesCuratedProcessEnvironment
    $environment['HERMES_HOME'] = $HermesHome
    $environment['VIRTUAL_ENV'] = Join-Path $InstallDir 'venv'
    $environment['PYTHONHOME'] = $null
    $environment['PYTHONPATH'] = $null
    $environment['PYTHONUSERBASE'] = $null
    $environment['PYTHONSTARTUP'] = $null
    $environment['PYTHONINSPECT'] = $null
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONSAFEPATH'] = '1'
    return $environment
}

function Get-HermesCodexRuntime {
    [CmdletBinding()]
    param([string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot)
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $verificationLog = Join-Path ([System.IO.Path]::GetTempPath()) ('hermes-easy-setup-codex-verify-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        # OAuth status refresh runs repeatedly inside the GUI. A full installation
        # verification also launches `hermes doctor`, which can take several
        # minutes and makes a completed device login look frozen. Static
        # provenance already verifies the pinned checkout, launchers, marker,
        # exclusions, and launcher attestation; the auth command itself is the
        # bounded runtime check for this flow.
        $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -StaticOnly -LogPath $verificationLog
    } finally {
        if (Test-Path -LiteralPath $verificationLog -PathType Leaf) { Remove-Item -LiteralPath $verificationLog -Force -ErrorAction SilentlyContinue }
    }
    if (-not $verification.StaticProvenanceValid) {
        throw "검증된 Hermes 설치가 필요합니다: $(@($verification.FailedChecks) -join ', ')"
    }
    $command = Join-Path $paths.InstallDir 'bin\hermes.exe'
    if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw 'Hermes 실행 파일을 찾지 못했습니다.' }
    $python = Join-Path $paths.InstallDir 'venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Hermes Python 실행 파일을 찾지 못했습니다.' }
    return [pscustomobject]@{
        Paths = $paths
        Command = $command
        Python = $python
        Environment = New-HermesCodexEnvironment -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    }
}

function Get-HermesCodexModels {
    [CmdletBinding()]
    param([string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot)
    $runtime = Get-HermesCodexRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $program = 'import json; from hermes_cli.auth import get_codex_auth_status; from hermes_cli.codex_models import get_codex_model_ids; s=get_codex_auth_status(); print(json.dumps(get_codex_model_ids(access_token=s.get("api_key") if s.get("logged_in") else None)))'
    $result = Invoke-HermesProcess -FilePath $runtime.Python -ArgumentList @('-c', $program) -WorkingDirectory $runtime.Paths.InstallDir -Environment $runtime.Environment -TimeoutSeconds 45
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'Hermes Codex 모델 목록을 읽지 못했습니다.' }
    try { $models = @($result.StdOut.Trim() | ConvertFrom-Json) } catch { throw 'Hermes Codex 모델 목록 형식이 올바르지 않습니다.' }
    $safeModels = @($models | ForEach-Object { [string]$_ } | Where-Object { $_ -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$' } | Select-Object -Unique)
    if ($safeModels.Count -eq 0) { throw '선택 가능한 OpenAI Codex 모델이 없습니다.' }
    return $safeModels
}

function Get-HermesCodexStatus {
    [CmdletBinding()]
    param([string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot)
    $runtime = Get-HermesCodexRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $result = Invoke-HermesProcess -FilePath $runtime.Command -ArgumentList @('auth', 'status', 'openai-codex') -WorkingDirectory $runtime.Paths.InstallDir -Environment $runtime.Environment -TimeoutSeconds 45
    $text = (($result.StdOut + [Environment]::NewLine + $result.StdErr).Trim())
    $loggedIn = ($result.Started -and -not $result.TimedOut -and $result.ExitCode -eq 0 -and $text -match '(?i)logged in|authenticated|credentials:\s*[✓✔]')
    $models = @()
    try { $models = @(Get-HermesCodexModels -HermesHome $runtime.Paths.HermesHome -InstallDir $runtime.Paths.InstallDir -RuntimeRoot $runtime.Paths.RuntimeRoot) } catch { $models = @('gpt-5.6-terra') }
    return [pscustomobject][ordered]@{
        LoggedIn = $loggedIn
        Provider = 'openai-codex'
        Models = $models
        Summary = $(if ($loggedIn) { 'OpenAI Codex 인증됨' } else { 'OpenAI Codex 로그인이 필요함' })
    }
}

function Invoke-HermesCodexAuthentication {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [AllowNull()][scriptblock]$ProgressCallback
    )
    $runtime = Get-HermesCodexRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage 'codex-auth' -State 'running' -Message 'OpenAI Codex 일회용 인증 코드를 요청하고 있습니다.' -Percent 20)
    $runtime.Environment['PYTHONUNBUFFERED'] = '1'
    $oauthState = @{
        URL = 'https://auth.openai.com/codex/device'
        ExpectCode = $false
        UserCode = $null
        Published = $false
    }
    $lineCallback = {
        param([string]$StreamName, [AllowNull()][string]$Line)
        if ($StreamName -cne 'StdOut' -or [string]::IsNullOrWhiteSpace($Line) -or [bool]$oauthState.Published) { return }
        $clean = [regex]::Replace($Line, '\x1B\[[0-?]*[ -/]*[@-~]', '').Trim()
        if ($clean -match '(?i)^2\.\s+Enter this code:') {
            $oauthState.ExpectCode = $true
            return
        }
        if ([bool]$oauthState.ExpectCode -and $clean -cmatch '^[A-Z0-9][A-Z0-9-]{3,63}$') {
            $oauthState.UserCode = $clean
            $oauthState.Published = $true
            $data = [pscustomobject][ordered]@{ URL = [string]$oauthState.URL; UserCode = [string]$oauthState.UserCode }
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'oauth' -Stage 'codex-auth' -State 'awaiting-user' -Message '브라우저에서 로그인한 뒤 아래 일회용 코드를 입력하세요.' -Percent 45 -Data $data)
        }
    }.GetNewClosure()
    $result = Invoke-HermesProcess -FilePath $runtime.Command -ArgumentList @('auth', 'add', 'openai-codex', '--type', 'oauth', '--label', 'Hermes Easy Setup') -WorkingDirectory $runtime.Paths.InstallDir -Environment $runtime.Environment -TimeoutSeconds 900 -OutputLineCallback $lineCallback
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) {
        $detail = Protect-HermesLogText ([string]$result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '로그인이 취소되었거나 제한 시간을 초과했습니다.' }
        throw "OpenAI Codex 인증을 완료하지 못했습니다: $detail"
    }
    $status = Get-HermesCodexStatus -HermesHome $runtime.Paths.HermesHome -InstallDir $runtime.Paths.InstallDir -RuntimeRoot $runtime.Paths.RuntimeRoot
    if (-not $status.LoggedIn) { throw 'OAuth 절차가 끝났지만 Hermes에서 OpenAI Codex 인증을 확인하지 못했습니다.' }
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'complete' -Stage 'codex-auth' -State 'succeeded' -Message 'OpenAI Codex 인증을 확인했습니다.' -Percent 100 -Data $status)
    return $status
}

Export-ModuleMember -Function @(
    'Get-HermesCodexModels',
    'Get-HermesCodexStatus',
    'Invoke-HermesCodexAuthentication'
)
