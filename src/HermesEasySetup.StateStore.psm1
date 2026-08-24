Set-StrictMode -Version 2.0

function Read-HermesInstallState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $null }
    try { return ([System.IO.File]::ReadAllText($LiteralPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Save-HermesInstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$State
    )

    $parent = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.state-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 14), (New-Object System.Text.UTF8Encoding $false))
    try {
        if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $LiteralPath, [System.Management.Automation.Language.NullString]::Value, $true)
        } else {
            [System.IO.File]::Move($temporary, $LiteralPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $LiteralPath
}

function New-HermesInstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $records = @()
    foreach ($stage in @($Manifest.stages)) {
        $records += [pscustomobject]@{
            name = [string]$stage.name
            title = [string]$stage.title
            category = [string]$stage.category
            needs_user_input = [bool]$stage.needs_user_input
            status = 'Pending'
            reason = $null
            started_at = $null
            finished_at = $null
            duration_ms = $null
            installer_sha256 = $null
        }
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [pscustomobject]@{
        schema_version = 2
        plan_fingerprint = [string]$Plan.Fingerprint
        source_commit = [string]$Plan.SourceCommit
        hermes_home = [string]$Plan.HermesHome
        install_dir = [string]$Plan.InstallDir
        runtime_root = [string]$Plan.RuntimeRoot
        status = 'Running'
        created_at = $now
        updated_at = $now
        completed_at = $null
        verification = $null
        resume_reapplies_stages = $true
        stages = $records
    }
}

function Get-HermesStageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return @($State.stages | Where-Object { [string]$_.name -eq $Name } | Select-Object -First 1)[0]
}

function Set-HermesStageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Pending', 'Running', 'Succeeded', 'Skipped', 'Failed')][string]$Status,
        [AllowNull()][string]$Reason,
        [AllowNull()][Nullable[int]]$DurationMs,
        [AllowNull()][string]$InstallerSha256
    )

    $record = Get-HermesStageRecord -State $State -Name $Name
    if ($null -eq $record) { throw "상태 파일에 알 수 없는 단계가 있습니다: $Name" }
    $record.status = $Status
    if ($Status -eq 'Running') {
        $record.started_at = (Get-Date).ToUniversalTime().ToString('o')
        $record.finished_at = $null
    }
    if (@('Succeeded', 'Skipped', 'Failed') -contains $Status) { $record.finished_at = (Get-Date).ToUniversalTime().ToString('o') }
    $record.reason = $(if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { Protect-HermesLogText $Reason })
    if ($null -ne $DurationMs) { $record.duration_ms = [int]$DurationMs }
    if (-not [string]::IsNullOrWhiteSpace($InstallerSha256)) { $record.installer_sha256 = $InstallerSha256.ToUpperInvariant() }
    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    return $State
}

function Test-HermesStateCanResume {
    [CmdletBinding()]
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Manifest
    )

    if ($null -eq $State) { return $false }
    try {
        if ([int]$State.schema_version -ne 2) { return $false }
        if (@('Running', 'Failed') -notcontains [string]$State.status) { return $false }
        if ([string]$State.plan_fingerprint -ne [string]$Plan.Fingerprint) { return $false }
        if ([string]$State.source_commit -ne [string]$Plan.SourceCommit) { return $false }
        $stateNames = @($State.stages | ForEach-Object { [string]$_.name })
        $manifestNames = @($Manifest.stages | ForEach-Object { [string]$_.name })
        if ($stateNames.Count -ne $manifestNames.Count -or @($stateNames | Select-Object -Unique).Count -ne $stateNames.Count) { return $false }
        for ($index = 0; $index -lt $stateNames.Count; $index++) {
            if ($stateNames[$index] -ne $manifestNames[$index]) { return $false }
            if (@('Pending', 'Running', 'Succeeded', 'Skipped', 'Failed') -notcontains [string]$State.stages[$index].status) { return $false }
        }
        return $true
    } catch { return $false }
}

function Reset-HermesStateForSafeResume {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    foreach ($record in @($State.stages)) {
        $record.status = 'Pending'
        $record.reason = $null
        $record.started_at = $null
        $record.finished_at = $null
        $record.duration_ms = $null
        $record.installer_sha256 = $null
    }
    $State.status = 'Running'
    $State.completed_at = $null
    $State.verification = $null
    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    return $State
}

function Enter-HermesInstallLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) { New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null }
    $lockPath = Join-Path $RuntimeRoot 'install.lock'
    try {
        $stream = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
        Throw-HermesEasySetupError -Message '다른 Hermes Easy Setup 작업이 실행 중입니다. 완료 후 다시 시도하세요.' -ExitCode 40 -Category 'InstallLock'
    }
    return [pscustomobject]@{ Path = $lockPath; Stream = $stream }
}

function Exit-HermesInstallLock {
    [CmdletBinding()]
    param([AllowNull()]$Lock)
    if ($null -ne $Lock -and $null -ne $Lock.Stream) { $Lock.Stream.Dispose() }
}

Export-ModuleMember -Function @(
    'Read-HermesInstallState', 'Save-HermesInstallState', 'New-HermesInstallState',
    'Get-HermesStageRecord', 'Set-HermesStageRecord', 'Test-HermesStateCanResume',
    'Reset-HermesStateForSafeResume', 'Enter-HermesInstallLock', 'Exit-HermesInstallLock'
)
