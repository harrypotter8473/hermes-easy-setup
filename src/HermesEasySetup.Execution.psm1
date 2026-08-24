Set-StrictMode -Version 2.0

$script:HermesExecutionMaximumStreamBytes = 4MB
$script:HermesExecutionTreeKillWaitMilliseconds = 10000
$script:HermesExecutionExitWaitMilliseconds = 5000
$script:HermesExecutionStreamWaitMilliseconds = 5000

function Get-HermesExecutionWindowsDirectory {
    $windowsDirectory = [Environment]::GetFolderPath('Windows')
    if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
        throw 'The Windows directory could not be resolved.'
    }

    return [System.IO.Path]::GetFullPath($windowsDirectory).TrimEnd('\', '/')
}

function Assert-HermesExecutionPathIsNotReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$StopAt
    )

    $currentPath = [System.IO.Path]::GetFullPath($LiteralPath).TrimEnd('\', '/')
    $stopPath = [System.IO.Path]::GetFullPath($StopAt).TrimEnd('\', '/')
    $stopPrefix = $stopPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $currentPath.Equals($stopPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $currentPath.StartsWith($stopPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Trusted executable path is outside the Windows directory: $currentPath"
    }

    while ($true) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Trusted executable path contains a reparse point: $currentPath"
        }
        if ($currentPath.Equals($stopPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parentPath) -or
            $parentPath.Equals($currentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Trusted executable path did not resolve beneath the Windows directory: $LiteralPath"
        }
        $currentPath = [System.IO.Path]::GetFullPath($parentPath).TrimEnd('\', '/')
    }
}

function Get-HermesExecutionSystemExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [switch]$RequireMicrosoftSignature
    )

    $windowsDirectory = Get-HermesExecutionWindowsDirectory
    $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $windowsDirectory $RelativePath))
    if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
        throw "$DisplayName was not found at the required System32 path: $expectedPath"
    }

    Assert-HermesExecutionPathIsNotReparsePoint -LiteralPath $expectedPath -StopAt $windowsDirectory
    $item = Get-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
    $actualPath = [System.IO.Path]::GetFullPath($item.FullName)
    if (-not $actualPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$DisplayName did not resolve to the exact required System32 path: $actualPath"
    }

    if ($RequireMicrosoftSignature) {
        $signature = Get-AuthenticodeSignature -FilePath $expectedPath -ErrorAction Stop
        if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
            throw "$DisplayName does not have a valid Authenticode signature."
        }
        $subject = [string]$signature.SignerCertificate.Subject
        if ($subject -notmatch '(?i)(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
            throw "$DisplayName is not signed by Microsoft Corporation."
        }
    }

    return $expectedPath
}

function Limit-HermesExecutionStreamText {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$StreamName
    )

    if ($null -eq $Text) { return '' }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    $maximumBytes = [int]$script:HermesExecutionMaximumStreamBytes
    if ($bytes.Length -le $maximumBytes) { return $Text }

    $marker = "`r`n[Hermes Easy Setup: $StreamName output truncated; original UTF-8 bytes=$($bytes.Length), limit=$maximumBytes.]"
    $markerBytes = $encoding.GetBytes($marker)
    $prefixByteCount = [math]::Max(0, $maximumBytes - $markerBytes.Length)

    # Do not end the retained prefix in the middle of a UTF-8 code point.
    while ($prefixByteCount -gt 0 -and $prefixByteCount -lt $bytes.Length -and
        (($bytes[$prefixByteCount] -band 0xC0) -eq 0x80)) {
        $prefixByteCount--
    }

    $prefix = $encoding.GetString($bytes, 0, $prefixByteCount)
    return $prefix + $marker
}

function Get-HermesExecutionTaskText {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$StreamName
    )

    try {
        if (-not $Task.Wait($script:HermesExecutionStreamWaitMilliseconds)) {
            return "[Hermes Easy Setup: $StreamName capture did not close within the bounded wait.]"
        }
        return Limit-HermesExecutionStreamText -Text ([string]$Task.Result) -StreamName $StreamName
    } catch {
        return "[Hermes Easy Setup: $StreamName capture failed.]"
    }
}

function Stop-HermesExecutionProcessTree {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    $taskKillPath = Get-HermesExecutionSystemExecutable `
        -RelativePath 'System32\taskkill.exe' -DisplayName 'taskkill.exe'
    $taskKillInfo = New-Object System.Diagnostics.ProcessStartInfo
    $taskKillInfo.FileName = $taskKillPath
    $taskKillInfo.Arguments = '/PID {0} /T /F' -f $Process.Id
    $taskKillInfo.UseShellExecute = $false
    $taskKillInfo.CreateNoWindow = $true
    $taskKillInfo.RedirectStandardOutput = $true
    $taskKillInfo.RedirectStandardError = $true

    $taskKill = New-Object System.Diagnostics.Process
    $taskKill.StartInfo = $taskKillInfo
    try {
        if ($taskKill.Start()) {
            $taskKillOut = $taskKill.StandardOutput.ReadToEndAsync()
            $taskKillErr = $taskKill.StandardError.ReadToEndAsync()
            if (-not $taskKill.WaitForExit($script:HermesExecutionTreeKillWaitMilliseconds)) {
                try { $taskKill.Kill() } catch {}
                [void]$taskKill.WaitForExit(2000)
            }
            try { [void]$taskKillOut.Wait(1000) } catch {}
            try { [void]$taskKillErr.Wait(1000) } catch {}
        }
    } finally {
        $taskKill.Dispose()
    }

    try {
        if (-not $Process.WaitForExit($script:HermesExecutionExitWaitMilliseconds)) {
            try { $Process.Kill() } catch {}
            [void]$Process.WaitForExit(2000)
        }
    } catch {}
}

function ConvertTo-WindowsProcessArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            for ($i = 0; $i -lt (($backslashes * 2) + 1); $i++) { [void]$builder.Append([char]92) }
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        for ($i = 0; $i -lt $backslashes; $i++) { [void]$builder.Append([char]92) }
        $backslashes = 0
        [void]$builder.Append($character)
    }
    for ($i = 0; $i -lt ($backslashes * 2); $i++) { [void]$builder.Append([char]92) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-HermesPowerShellExecutable {
    [CmdletBinding()]
    param()

    return Get-HermesExecutionSystemExecutable `
        -RelativePath 'System32\WindowsPowerShell\v1.0\powershell.exe' `
        -DisplayName 'Windows PowerShell' -RequireMicrosoftSignature
}

function Invoke-HermesProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 0,
        [switch]$Visible
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-WindowsProcessArgument -Argument ([string]$_) }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = -not $Visible
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $info.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        $info.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw "Process could not be started: $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = $false

        if ($TimeoutSeconds -gt 0) {
            $requestedMilliseconds = [int64]$TimeoutSeconds * 1000
            $waitMilliseconds = $(if ($requestedMilliseconds -gt [int]::MaxValue) { [int]::MaxValue } else { [int]$requestedMilliseconds })
            if (-not $process.WaitForExit($waitMilliseconds)) {
                $timedOut = $true
                Stop-HermesExecutionProcessTree -Process $process
            } else {
                $process.WaitForExit()
            }
        } else {
            $process.WaitForExit()
        }

        $stdout = Get-HermesExecutionTaskText -Task $stdoutTask -StreamName 'StdOut'
        $stderr = Get-HermesExecutionTaskText -Task $stderrTask -StreamName 'StdErr'
        $exitCode = $(if ($timedOut) { -1 } else { $process.ExitCode })
        $elapsed = [int64]$watch.ElapsedMilliseconds
        $duration = $(if ($elapsed -gt [int]::MaxValue) { [int]::MaxValue } else { [int]$elapsed })
        return [pscustomobject]@{
            FilePath   = $FilePath
            Arguments  = @($ArgumentList)
            ExitCode   = $exitCode
            StdOut     = $stdout
            StdErr     = $stderr
            TimedOut   = $timedOut
            DurationMs = $duration
        }
    } finally {
        $watch.Stop()
        $process.Dispose()
    }
}

function ConvertFrom-HermesJsonFrame {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$RequiredProperty
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lines = @($Text -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim()
        if (-not $line.StartsWith('{')) { continue }
        try {
            $frame = $line | ConvertFrom-Json
            if ($frame.PSObject.Properties.Name -contains $RequiredProperty) { return $frame }
        } catch {}
    }
    return $null
}

function Publish-HermesEvent {
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$Callback,
        [Parameter(Mandatory = $true)][string]$Type,
        [string]$Stage,
        [string]$State,
        [string]$Message,
        [int]$Percent = -1,
        [AllowNull()]$Data
    )

    $event = [pscustomobject]@{
        type      = $Type
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        stage     = $Stage
        state     = $State
        message   = $(if ($null -eq $Message) { $null } else { Protect-HermesLogText $Message })
        percent   = $Percent
        data      = $Data
    }
    if ($null -ne $Callback) { & $Callback $event | Out-Null }
    return $event
}

function Write-HermesCapturedOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ProcessResult,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$Stage,
        [AllowNull()][scriptblock]$Callback
    )

    foreach ($streamName in @('StdOut', 'StdErr')) {
        $value = [string]$ProcessResult.$streamName
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $level = $(if ($streamName -eq 'StdErr') { 'WARN' } else { 'INFO' })
        $sent = 0
        foreach ($line in @($value -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            Write-HermesEasySetupLog -LiteralPath $LogPath -Message "[$Stage][$streamName] $line" -Level $level
            if ($sent -lt 500) {
                [void](Publish-HermesEvent -Callback $Callback -Type 'log' -Stage $Stage -State $streamName.ToLowerInvariant() -Message $line)
                $sent++
            }
        }
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-WindowsProcessArgument',
    'Get-HermesPowerShellExecutable',
    'Invoke-HermesProcess',
    'ConvertFrom-HermesJsonFrame',
    'Publish-HermesEvent',
    'Write-HermesCapturedOutput'
)
