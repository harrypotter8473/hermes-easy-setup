Set-StrictMode -Version 2.0

function Resolve-HermesResearchHuman {
    param($InputObject)
    $options = $InputObject.WizardOptions
    $manager = @($InputObject.Agents | Where-Object { $_.RoleId -ceq 'planner' })[0]
    $user = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ('/api/v4/users/username/' + $options.HumanUsername) -Token $manager.BotToken
    if ($user.id -cnotmatch '^[a-z0-9]{26}$' -or $user.delete_at -ne 0 -or ($user.PSObject.Properties['is_bot'] -and $user.is_bot -eq $true)) { throw '활성 사람 계정을 선택하세요.' }
    $member = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ('/api/v4/channels/' + $InputObject.HomeChannelID + '/members/' + $user.id) -Token $manager.BotToken
    if ($member.user_id -cne $user.id -or $member.channel_id -cne $InputObject.HomeChannelID) { throw '연구자 계정이 연구 채널에 참여해야 합니다.' }
    return [string]$user.id
}

function Get-HermesResearchMigrationTasks {
    param($Prior, $Paths, $BrokerPlan)
    $plans = @($BrokerPlan)
    foreach ($profile in @($Prior.Profiles)) {
        $plan = Get-HermesResearchTaskPlan -ProfileName $profile.ProfileName -HermesHome $Paths.HermesHome -RuntimeRoot $Paths.RuntimeRoot -OwnerSID $Prior.OwnerSID -TeamID $Prior.TeamID -PowerShellPath (Get-HermesPowerShellExecutable)
        if ($null -ne $profile.GatewayTask -and $profile.GatewayTask -cnotin @($plan.TaskName, $BrokerPlan.TaskName, '')) { throw 'ResearchMigrationTaskBindingRejected' }
        $plans += $plan
    }
    $result = @()
    foreach ($plan in $plans) {
        $tasks = @(Get-HermesResearchGatewayTask -TaskName $plan.TaskName)
        if ($tasks.Count -gt 1) { throw 'ResearchMigrationTaskCollision' }
        if ($tasks.Count -eq 1) {
            Assert-HermesResearchOwnedTask -Task $tasks[0] -Plan $plan -HasOwnership $true
            $result += [pscustomobject]@{ Plan = $plan; Task = $tasks[0] }
        }
    }
    return $result
}

function Assert-HermesResearchBrokerIdle {
    param([string]$ResearchRoot, [string]$Python, [hashtable]$Environment)
    $database = Join-Path $ResearchRoot 'broker.sqlite'
    if (-not (Test-Path -LiteralPath $database)) { return }
    if (-not (Test-HermesSafeTargetPath -LiteralPath $database).Safe) { throw 'ResearchStatePathRejected' }
    $program = 'import sqlite3,sys,pathlib; c=sqlite3.connect(pathlib.Path(sys.argv[1]).as_uri()+"?mode=ro",uri=True); n=c.execute("SELECT count(*) FROM posts WHERE state=''running''").fetchone()[0]; c.close(); print(n)'
    $result = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-I','-S','-B','-c',$program,$database) -Environment $Environment -TimeoutSeconds 15
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0 -or $result.StdOut.Trim() -cne '0') { throw '연구 작업이 실행 중이거나 상태를 확인할 수 없습니다. 작업이 끝난 뒤 전환하세요.' }
}

function Get-HermesResearchBrokerProcessSnapshot {
    param([int]$ProcessID)
    if ($ProcessID -le 0) { throw 'ResearchBrokerProcessIDRejected' }
    $records = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $ProcessID) -ErrorAction Stop)
    if ($records.Count -eq 0) { return $null }
    if ($records.Count -ne 1 -or [int]$records[0].ProcessId -ne $ProcessID -or [string]::IsNullOrWhiteSpace([string]$records[0].CommandLine)) { throw 'ResearchBrokerProcessRecordRejected' }
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessID)
        # Keep a handle to this exact process so a recycled PID cannot redirect
        # the later Kill call to another process between identity checks.
        $null = $process.Handle
        if ($process.HasExited) { $process.Dispose(); return $null }
        $ticks = $process.StartTime.ToUniversalTime().Ticks
        $created = ([DateTime]$records[0].CreationDate).ToUniversalTime().Ticks
        if ([Math]::Abs($ticks - $created) -gt [TimeSpan]::TicksPerMillisecond) { throw 'ResearchBrokerProcessChanged' }
        return [pscustomobject]@{ ProcessID=$ProcessID;CreationTicks=$ticks;PhysicalPath=[string]$process.MainModule.FileName;CommandLine=[string]$records[0].CommandLine;Process=$process }
    } catch { if ($null -ne $process) { $process.Dispose() }; throw 'ResearchBrokerProcessIdentityUnavailable' }
}

function Test-HermesResearchBrokerCommandLine {
    param([string]$CommandLine,[string]$Python,[string]$PhysicalPath,[string]$ResearchRoot)
    $pathPattern = {
        param([string]$Value)
        $escaped = [regex]::Escape([IO.Path]::GetFullPath($Value).TrimEnd('\'))
        if ($Value -match '\s') { return ('(?i:"' + $escaped + '")') }
        return ('(?i:(?:"' + $escaped + '"|' + $escaped + '))')
    }
    $executable = '(?:' + (& $pathPattern $Python) + '|' + (& $pathPattern $PhysicalPath) + ')'
    $broker = & $pathPattern (Join-Path $ResearchRoot 'engine\research_team\broker.py')
    $root = & $pathPattern $ResearchRoot
    return [regex]::IsMatch($CommandLine,('^' + $executable + '[ \t]+-I[ \t]+-S[ \t]+-B[ \t]+' + $broker + '[ \t]+serve[ \t]+--root[ \t]+' + $root + '[ \t]*$'))
}

function Get-HermesResearchBrokerHeartbeat {
    param([string]$ResearchRoot,[switch]$AllowStale)
    $path = Join-Path $ResearchRoot 'broker-status.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe -or (Get-Item -LiteralPath $path).Length -gt 262144) { throw 'ResearchBrokerHeartbeatPathRejected' }
    try {
        $status = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
        $now = ([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
        if ([int]$status.pid -le 0 -or [double]$status.updated_at -le 0 -or (-not $AllowStale -and [double]$status.updated_at -lt ($now-30)) -or [double]$status.updated_at -gt ($now+5)) { throw 'NotFresh' }
        return $status
    } catch { throw 'ResearchBrokerHeartbeatNotFresh' }
}

function Enter-HermesResearchMaintenance {
    param([string]$ResearchRoot, $Tasks, $BrokerPlan, [string]$Python)
    # Task Scheduler may report Ready after stopping only the PowerShell runner.
    # A live, precisely identified Python child must also be quiesced.
    $brokerTasks = @($Tasks | Where-Object { $null -ne $_ -and $_.Plan.TaskName -ceq $BrokerPlan.TaskName })
    if ($brokerTasks.Count -eq 0) { return $null }
    if ($brokerTasks.Count -ne 1) { throw 'ResearchBrokerTaskCollision' }
    $current = @(Get-HermesResearchGatewayTask -TaskName $BrokerPlan.TaskName)
    if ($current.Count -ne 1) { throw 'ResearchMigrationTaskChanged' }
    Assert-HermesResearchOwnedTask -Task $current[0] -Plan $BrokerPlan -HasOwnership $true
    $status = Get-HermesResearchBrokerHeartbeat -ResearchRoot $ResearchRoot -AllowStale
    if ($null -eq $status) {
        if ([string]$current[0].State -eq 'Running') { throw 'ResearchBrokerHeartbeatUnavailable' }
        return $null
    }
    $processPath = Get-HermesResearchPythonProcessPath -Python $Python
    $initial = Get-HermesResearchBrokerProcessSnapshot -ProcessID ([int]$status.pid)
    if ($null -eq $initial) {
        if ([string]$current[0].State -eq 'Running') { throw 'ResearchBrokerProcessUnavailable' }
        return $null
    }
    try {
        $null = Get-HermesResearchBrokerHeartbeat -ResearchRoot $ResearchRoot
        if (-not [string]::Equals($initial.PhysicalPath,$processPath,[StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-HermesResearchBrokerCommandLine -CommandLine $initial.CommandLine -Python $Python -PhysicalPath $processPath -ResearchRoot $ResearchRoot)) { throw 'ResearchBrokerCommandIdentityRejected' }
        $identity = [pscustomobject]@{ProcessID=$initial.ProcessID;CreationTicks=$initial.CreationTicks;PhysicalPath=$initial.PhysicalPath;CommandLine=$initial.CommandLine;ResearchRoot=$ResearchRoot;Python=$Python;TaskName=$BrokerPlan.TaskName;MaintenanceStartedAt=0.0}
    } finally { $initial.Process.Dispose() }
    $path = Join-Path $ResearchRoot 'maintenance.json'
    $started = ([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
    $identity.MaintenanceStartedAt = $started
    Write-HermesResearchAtomicText -LiteralPath $path -Text (@{ owner = 'HermesEasySetup.Research'; started_at = $started } | ConvertTo-Json)
    $deadline = (Get-Date).AddSeconds(60)
    do {
        $status = Get-HermesResearchBrokerHeartbeat -ResearchRoot $ResearchRoot
        if ($null -ne $status -and [int]$status.pid -eq $identity.ProcessID -and $status.PSObject.Properties['maintenance'] -and $status.maintenance -eq $true -and $status.active -eq $false -and [double]$status.updated_at -ge $started) {
            $snapshot = Get-HermesResearchBrokerProcessSnapshot -ProcessID $identity.ProcessID
            if ($null -eq $snapshot) { return $null }
            try {
                if ($snapshot.CreationTicks -ne $identity.CreationTicks -or $snapshot.CommandLine -cne $identity.CommandLine -or -not [string]::Equals($snapshot.PhysicalPath,$identity.PhysicalPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'ResearchBrokerProcessChanged' }
                return $identity
            } finally { $snapshot.Process.Dispose() }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Remove-Item -LiteralPath $path -Force
    throw '기존 분배 서비스가 작업 종료·전환 대기를 확인하지 못했습니다. 진행 중 작업이 끝난 뒤 다시 전환하세요. 서비스는 강제 종료하지 않았습니다.'
}

function Exit-HermesResearchMaintenance {
    param([string]$ResearchRoot)
    $path = Join-Path $ResearchRoot 'maintenance.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe) { throw 'ResearchMaintenancePathRejected' }
    $value = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($value.owner -cne 'HermesEasySetup.Research') { throw 'ResearchMaintenanceOwnerRejected' }
    Remove-Item -LiteralPath $path -Force
}

function Backup-HermesResearchMigration {
    param($Paths, $Prior, $Tasks)
    $backup = Join-Path $Paths.RuntimeRoot ('research\migrations\' + [guid]::NewGuid().ToString('N'))
    if (-not (Test-HermesSafeTargetPath -LiteralPath $backup).Safe) { throw 'ResearchBackupPathRejected' }
    New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
    $files = @()
    foreach ($name in @('team.json','policy.json','private.json','live-test.json')) {
        $files += @{ Source = (Join-Path $Paths.RuntimeRoot ('research\' + $name)); Relative = $name }
    }
    foreach ($profile in @($Prior.Profiles)) {
        foreach ($name in @('.env','config.yaml','SOUL.md','gateway.parked')) {
            $files += @{ Source = (Join-Path $Paths.HermesHome ('profiles\' + $profile.ProfileName + '\' + $name)); Relative = ('profiles\' + $profile.ProfileName + '\' + $name) }
        }
    }
    $manifest = @()
    foreach ($file in $files) {
        if (-not (Test-HermesSafeTargetPath -LiteralPath $file.Source).Safe) { throw 'ResearchBackupSourceRejected' }
        if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) { continue }
        $target = Join-Path $backup $file.Relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.Source -Destination $target -ErrorAction Stop
        $hash = ConvertTo-HermesSha256 -LiteralPath $file.Source
        if ($hash -cne (ConvertTo-HermesSha256 -LiteralPath $target)) { throw 'ResearchBackupHashMismatch' }
        $manifest += @{ Relative = $file.Relative; Sha256 = $hash }
    }
    foreach ($item in @($Tasks)) {
        $xml = Export-ScheduledTask -TaskName $item.Plan.TaskName -TaskPath '\' -ErrorAction Stop
        Write-HermesResearchAtomicText -LiteralPath (Join-Path $backup ($item.Plan.TaskName + '.xml')) -Text $xml
    }
    Write-HermesResearchAtomicText -LiteralPath (Join-Path $backup 'migration.json') -Text (@{ State = 'BackedUp'; TeamID = $Prior.TeamID; Files = $manifest; Tasks = @($Tasks | ForEach-Object { $_.Plan.TaskName }); HistoryPreservedInPlace = $true } | ConvertTo-Json -Depth 8)
    return $backup
}

function Stop-HermesResearchMigrationTasks {
    param($Tasks,$BrokerIdentity)
    if ($null -ne $BrokerIdentity -and @($Tasks | Where-Object { $_.Plan.TaskName -ceq $BrokerIdentity.TaskName }).Count -ne 1) { throw 'ResearchBrokerStopTaskBindingRejected' }
    # All targets were validated together before any stop. Keep disabled tasks
    # recoverable; never unregister them or touch a personal/root gateway task.
    foreach ($item in @($Tasks)) {
        $current = @(Get-HermesResearchGatewayTask -TaskName $item.Plan.TaskName)
        if ($current.Count -ne 1) { throw 'ResearchMigrationTaskChanged' }
        Assert-HermesResearchOwnedTask -Task $current[0] -Plan $item.Plan -HasOwnership $true
        Disable-ScheduledTask -TaskName $item.Plan.TaskName -TaskPath '\' -ErrorAction Stop | Out-Null
        if ([string]$current[0].State -eq 'Running') { Stop-ScheduledTask -TaskName $item.Plan.TaskName -TaskPath '\' -ErrorAction Stop }
    }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $running = @($Tasks | Where-Object { @((Get-HermesResearchGatewayTask -TaskName $_.Plan.TaskName) | Where-Object { [string]$_.State -eq 'Running' }).Count -gt 0 })
        if ($running.Count -eq 0) {
            if ($null -ne $BrokerIdentity) {
                $snapshot = Get-HermesResearchBrokerProcessSnapshot -ProcessID $BrokerIdentity.ProcessID
                if ($null -eq $snapshot) { return }
                try {
                    $status = Get-HermesResearchBrokerHeartbeat -ResearchRoot $BrokerIdentity.ResearchRoot
                    if ($snapshot.CreationTicks -ne $BrokerIdentity.CreationTicks -or $snapshot.CommandLine -cne $BrokerIdentity.CommandLine -or
                        -not [string]::Equals($snapshot.PhysicalPath,$BrokerIdentity.PhysicalPath,[StringComparison]::OrdinalIgnoreCase) -or
                        -not (Test-HermesResearchBrokerCommandLine -CommandLine $snapshot.CommandLine -Python $BrokerIdentity.Python -PhysicalPath $BrokerIdentity.PhysicalPath -ResearchRoot $BrokerIdentity.ResearchRoot) -or
                        $null -eq $status -or [int]$status.pid -ne $BrokerIdentity.ProcessID -or $status.maintenance -ne $true -or $status.active -ne $false -or [double]$status.updated_at -lt $BrokerIdentity.MaintenanceStartedAt) { throw 'ResearchBrokerStopIdentityRejected' }
                    # The maintenance acknowledgement proves the model loop is
                    # idle. Terminate only this held process handle, never a PID
                    # name match, personal gateway, or unverified process tree.
                    $snapshot.Process.Kill()
                    if (-not $snapshot.Process.WaitForExit(10000)) { throw 'ResearchBrokerProcessStopTimeout' }
                } finally { $snapshot.Process.Dispose() }
            }
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'ResearchMigrationTaskStopTimeout'
}

function Confirm-HermesResearchNativeDetached {
    param($Paths, [string]$Python, [hashtable]$Environment, [string[]]$ProfileNames)
    $helper = Join-Path $Paths.RuntimeRoot 'research\engine\research_team\native_cutover.py'
    $result = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-I','-S','-B',$helper,'--source',$Paths.InstallDir,'--home',$Paths.HermesHome,'--profiles',($ProfileNames -join ',')) -Environment $Environment -TimeoutSeconds 60
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw '기존 연구 봇의 응답 경로 중지를 확인하지 못했습니다. 새 분배 엔진은 시작하지 않았습니다. 개인 Gateway는 중지하지 않았습니다.' }
    try { $status = $result.StdOut.Trim() | ConvertFrom-Json; if ($status.detached -ne $true) { throw 'NotDetached' } } catch { throw 'ResearchNativeDetachNotVerified' }
}

function Invoke-HermesResearchLiveTest {
    param([string]$ResearchRoot, [string]$Python, [hashtable]$Environment, [string]$UserID)
    $evidence = Join-Path $ResearchRoot 'live-test.json'
    $test = [ordered]@{ Passed = $false; Live = $false; RequestID = ''; Roles = @(); AuditPassed = $false; EvidencePath = $evidence; ErrorCode = 'LiveTestNotPassed' }
    $started = ([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
    $result = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-I','-S','-B',(Join-Path $ResearchRoot 'engine\research_team\broker.py'),'self-test','--root',$ResearchRoot,'--user-id',$UserID) -Environment $Environment -TimeoutSeconds 1800
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { $test.ErrorCode = $(if ($result.TimedOut) { 'LiveTestTimeout' } else { 'LiveTestFailed' }); return [pscustomobject]$test }
    try {
        $answer = $result.StdOut.Trim() | ConvertFrom-Json
        if ($answer.ready -eq $true -and $answer.live -eq $true -and $answer.audits_verified -eq $true -and $answer.search_verified -eq $true -and $answer.read_verified -eq $true -and $answer.messages_verified -eq $true -and
            $answer.request_id -cmatch '^req_[a-f0-9]{32}$' -and @($answer.roles_verified).Count -eq 4 -and (@($answer.roles_verified | Sort-Object) -join ',') -ceq 'analyst,auditor,manager,researcher' -and (Test-Path -LiteralPath $evidence -PathType Leaf)) {
            if (-not (Test-HermesSafeTargetPath -LiteralPath $evidence).Safe -or (Get-Item -LiteralPath $evidence).Length -gt 262144) { throw 'EvidencePathRejected' }
            $saved = [IO.File]::ReadAllText($evidence) | ConvertFrom-Json
            if ($saved.request_id -cne $answer.request_id -or [double]$saved.tested_at -lt $started -or $saved.ready -ne $true -or $saved.live -ne $true) { throw 'StaleEvidenceRejected' }
            $check = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-I','-S','-B',(Join-Path $ResearchRoot 'engine\research_team\broker.py'),'check','--root',$ResearchRoot) -Environment $Environment -TimeoutSeconds 30
            if (-not $check.Started -or $check.TimedOut -or $check.ExitCode -ne 0) { throw 'EvidenceCheckFailed' }
            $verified = $check.StdOut.Trim() | ConvertFrom-Json
            if ($verified.ready -ne $true -or $verified.live_test_verified -ne $true) { throw 'EvidenceBindingsRejected' }
            $test.Passed = $true; $test.Live = $true; $test.RequestID = $answer.request_id; $test.Roles = @($answer.roles_verified); $test.AuditPassed = $true; $test.ErrorCode = ''
        }
    } catch { $test.ErrorCode = 'LiveTestEvidenceRejected' }
    return [pscustomobject]$test
}
