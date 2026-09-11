[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Plan', 'Install', 'Verify', 'Setup', 'CodexStatus', 'CodexAuth', 'LabSetup', 'Bundle')]
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
    [switch]$WaitForSetup,
    [switch]$Json,
    [switch]$JsonEvents,
    [string]$ExpectedPlanFingerprint,
    [string]$DestinationPath,
    [string]$SourceConfigPath,
    [string]$LabInputPath
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

function Write-SetupEvent {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('starting', 'closed')][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][AllowNull()]$Data
    )

    if (-not $JsonEvents) { return }
    $event = [ordered]@{
        type = 'setup'
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        state = $State
        message = $Message
        data = $Data
    }
    Write-ResultObject ([pscustomobject]$event)
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
                $result | Add-Member -NotePropertyName SetupLaunch -NotePropertyValue (Start-HermesOfficialSetup -HermesHome $result.Plan.HermesHome -InstallDir $result.Plan.InstallDir -RuntimeRoot $result.Plan.RuntimeRoot -Mode $SetupMode -Wait:$WaitForSetup)
            }
            if (-not $JsonEvents) { Write-ResultObject $result }
        }
        'Verify' {
            $result = Test-HermesInstallation @common -ProgressCallback $eventCallback
            Write-ResultObject $result
            if (-not $result.Verified) { exit $exitCodes.VerificationFailed }
        }
        'Setup' {
            Write-SetupEvent -State 'starting' -Message '현재 Hermes 설치를 검증하고 공식 설정 창을 여는 중입니다.' -Data $null
            $setupResult = Start-HermesOfficialSetup -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot -Mode $SetupMode -Wait:$WaitForSetup
            if ($JsonEvents) {
                if ($WaitForSetup) {
                    $setupEventData = [pscustomobject][ordered]@{
                        Started = [bool]$setupResult.Started
                        Exited = [bool]$setupResult.Exited
                        ExitCode = $setupResult.ExitCode
                        Mode = [string]$setupResult.Mode
                        ProcessId = $setupResult.ProcessId
                    }
                    Write-SetupEvent -State 'closed' -Message '공식 Hermes 설정 창이 닫혔습니다. 설정 완료 여부는 이 마법사에서 확인하지 않았습니다.' -Data $setupEventData
                }
            } else {
                Write-ResultObject $setupResult
            }
        }
        'CodexStatus' {
            Write-ResultObject (Get-HermesCodexStatus @common)
        }
        'CodexAuth' {
            if (-not $Apply) { throw (New-Object System.InvalidOperationException 'OpenAI Codex 인증을 시작하려면 -Apply를 함께 지정하세요.') }
            $result = Invoke-HermesCodexAuthentication @common -ProgressCallback $eventCallback
            if (-not $JsonEvents) { Write-ResultObject $result }
        }
        'LabSetup' {
            if (-not $Apply) {
                throw (New-Object System.InvalidOperationException '연구실 연결 변경을 승인하려면 -Apply를 함께 지정하세요.')
            }
            if ([string]::IsNullOrWhiteSpace($LabInputPath)) {
                throw '암호화된 연구실 연결 입력 파일이 필요합니다.'
            }
            $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
            $inputPath = [System.IO.Path]::GetFullPath($LabInputPath)
            $transportRoot = [System.IO.Path]::GetFullPath((Join-Path $paths.RuntimeRoot 'ui-transport'))
            if (-not (Test-HermesPathContains -ParentPath $transportRoot -ChildPath $inputPath)) {
                throw '연구실 연결 입력 파일은 마법사 런타임 transport 폴더 안에 있어야 합니다.'
            }
            try {
                $input = Unprotect-HermesLabInput -LiteralPath $inputPath
                $arguments = @{
                    HermesHome = $paths.HermesHome
                    InstallDir = $paths.InstallDir
                    RuntimeRoot = $paths.RuntimeRoot
                    ProfileName = [string]$input.ProfileName
                    FullName = [string]$input.FullName
                    Role = [string]$input.Role
                    ModelName = [string]$input.ModelName
                    MattermostURL = [string]$input.MattermostURL
                    MattermostToken = [string]$input.MattermostToken
                    HomeChannelID = [string]$input.HomeChannelID
                    NetBirdIP = [string]$input.NetBirdIP
                    DashboardPort = [int]$input.DashboardPort
                    DashboardUsername = [string]$input.DashboardUsername
                    DashboardPassword = [string]$input.DashboardPassword
                    ReuseExistingProfile = [bool]$input.ReuseExistingProfile
                    ProgressCallback = $eventCallback
                }
                $result = Invoke-HermesLabSetup @arguments
                if ($JsonEvents) {
                    & $eventCallback ([pscustomobject][ordered]@{
                        type = 'complete'
                        timestamp = (Get-Date).ToUniversalTime().ToString('o')
                        stage = 'lab-setup'
                        state = 'succeeded'
                        percent = 100
                        message = '연구실 Hermes 연결과 검증이 완료되었습니다.'
                        data = $result
                    })
                } else {
                    Write-ResultObject $result
                }
            } finally {
                if (Test-Path -LiteralPath $inputPath -PathType Leaf) {
                    Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
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
