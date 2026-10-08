[CmdletBinding()]
param([switch]$SmokeTest,[string]$PreviewPath,[ValidateSet('Server','Team')][string]$PreviewStep = 'Team')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start-HermesResearchSetup.cmd로 실행하세요.' }
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$reader = New-Object Xml.XmlNodeReader ([xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ui\ResearchWindow.xaml')))
try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
$ui = @{}
foreach ($name in @(
    'WizardTabs','ServerTab','HermesTab','TeamTab','DockerCheckButton','DockerOpenButton','DockerStatus',
    'DockerPrerequisites','DockerAlternatives','DockerInstallConsent','DockerInstallButton','DockerGuideButton',
    'ServerRestoreButton','ServerId','ServerPort','AdminUsername','AdminEmail','AdminPassword','PasswordConfirm',
    'ServerResumeCheck','ServerConsent','ServerCreateButton','ServerOpenButton','ServerNextButton','ServerStatus',
    'HermesPlanButton','HermesStatusButton','HermesPlanText','HermesConsent','HermesInstallButton',
    'AuthButton','AuthOpenButton','AuthStatus','AuthCode','ModelCombo','HermesNextButton',
    'TeamServerURL','HomeChannelID','TeamAdminPassword','AgentRows','RoleEditorCombo','RoleName','RoleInstructions','RoleSaveButton',
    'TeamResumeCheck','TeamConsent','TeamApplyButton','TeamOpenButton','TeamResult','Progress','Log','CloseButton'
)) {
    $ui[$name] = $window.FindName($name)
    if ($null -eq $ui[$name]) { throw "필수 연구실 컨트롤이 없습니다: $name" }
}
$script:paths = Get-HermesDefaultPaths
$script:roles = @(Get-HermesResearchRoles -RuntimeRoot $script:paths.RuntimeRoot)
$script:agents = @()
$script:busy = $false
$script:dockerReady = $false
$script:dockerCanInstall = $false
$script:dockerCanOpen = $false
$script:dockerRebootRequired = $false
$script:initialDockerCheck = $false
$script:serverReady = $false
$script:serverIdentity = $null
$script:serverURL = $null
$script:channelURL = $null
$script:hermesReady = $false
$script:authenticated = $false
$script:plan = $null
$script:authURL = $null
$script:worker = $null
$script:workerAction = ''
$script:workerResult = $null
$script:workerFailed = $false
$script:workerEOF = $false
$script:pendingLine = $null
$script:stderr = $null
$script:inputPath = $null
$script:botIndex = -1
$script:preferredModel = $null

function Add-ResearchLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $ui.Log.AppendText((Protect-HermesLogText $Message) + [Environment]::NewLine)
    if ($ui.Log.Text.Length -gt 24000) { $ui.Log.Text = $ui.Log.Text.Substring($ui.Log.Text.Length - 18000) }
    $ui.Log.ScrollToEnd()
}

function Refresh-ResearchButtons {
    $idle = -not $script:busy
    $ui.CloseButton.IsEnabled = $idle
    foreach ($name in @('DockerCheckButton','DockerGuideButton','ServerRestoreButton','ServerId','ServerPort',
        'AdminUsername','AdminEmail','AdminPassword','PasswordConfirm','ServerResumeCheck','ServerConsent',
        'HermesConsent','TeamAdminPassword','TeamResumeCheck','TeamConsent','RoleEditorCombo','RoleName','RoleInstructions','RoleSaveButton')) {
        $ui[$name].IsEnabled = $idle
    }
    $ui.DockerOpenButton.IsEnabled = $idle -and $script:dockerCanOpen
    $ui.DockerInstallConsent.IsEnabled = $idle -and $script:dockerCanInstall
    $ui.DockerInstallButton.IsEnabled = $idle -and $script:dockerCanInstall -and $ui.DockerInstallConsent.IsChecked -eq $true
    $ui.ServerCreateButton.IsEnabled = $idle -and $script:dockerReady -and $ui.ServerConsent.IsChecked -eq $true
    $ui.ServerOpenButton.IsEnabled = $idle -and $script:serverReady
    $ui.ServerNextButton.IsEnabled = $ui.ServerOpenButton.IsEnabled
    $ui.HermesTab.IsEnabled = $script:serverReady
    $ui.HermesPlanButton.IsEnabled = $idle -and $script:serverReady
    $ui.HermesStatusButton.IsEnabled = $ui.HermesPlanButton.IsEnabled
    $ui.HermesInstallButton.IsEnabled = $idle -and $null -ne $script:plan -and $ui.HermesConsent.IsChecked -eq $true
    $ui.AuthButton.IsEnabled = $idle -and $script:hermesReady
    $ui.AuthOpenButton.IsEnabled = $null -ne $script:authURL
    $ui.ModelCombo.IsEnabled = $idle -and $script:authenticated
    $ui.HermesNextButton.IsEnabled = $idle -and $script:authenticated -and $null -ne $ui.ModelCombo.SelectedItem
    $ui.TeamTab.IsEnabled = $script:serverReady -and $script:authenticated
    $ui.TeamApplyButton.IsEnabled = $idle -and $ui.TeamTab.IsEnabled -and $null -ne $ui.ModelCombo.SelectedItem -and $ui.TeamConsent.IsChecked -eq $true
    $ui.TeamOpenButton.IsEnabled = $idle -and $script:serverReady
    foreach ($agent in $script:agents) {
        $agent.Name.IsEnabled = $idle
        $agent.Token.IsEnabled = $idle
        $agent.Role.IsEnabled = $idle
        $agent.Issue.IsEnabled = $idle -and $script:serverReady -and $script:dockerReady
    }
}

function Add-ResearchAgentRows {
    $columns = @(160,200,0,150,105)
    foreach ($width in $columns) {
        $column = New-Object Windows.Controls.ColumnDefinition
        $column.Width = $(if ($width -eq 0) { New-Object Windows.GridLength(1,[Windows.GridUnitType]::Star) } else { New-Object Windows.GridLength($width) })
        [void]$ui.AgentRows.ColumnDefinitions.Add($column)
    }
    $header = New-Object Windows.Controls.RowDefinition
    $header.Height = [Windows.GridLength]::Auto
    [void]$ui.AgentRows.RowDefinitions.Add($header)
    $headers = @('독립 프로필','에이전트 이름','봇 토큰','역할','토큰 발급')
    for ($columnIndex = 0; $columnIndex -lt $headers.Count; $columnIndex++) {
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $headers[$columnIndex]; $label.FontWeight = 'SemiBold'; $label.Margin = '0,0,8,8'
        [Windows.Controls.Grid]::SetColumn($label,$columnIndex)
        [void]$ui.AgentRows.Children.Add($label)
    }
    $defaults = @(New-HermesResearchDefaultAgents)
    for ($i = 0; $i -lt $defaults.Count; $i++) {
        $row = New-Object Windows.Controls.RowDefinition; $row.Height = [Windows.GridLength]::Auto
        [void]$ui.AgentRows.RowDefinitions.Add($row)
        $profile = New-Object Windows.Controls.TextBlock
        $profile.Text = [string]$defaults[$i].ProfileName; $profile.FontSize = 12; $profile.VerticalAlignment = 'Center'
        $name = New-Object Windows.Controls.TextBox; $name.Text = [string]$defaults[$i].DisplayName
        $token = New-Object Windows.Controls.PasswordBox
        $role = New-Object Windows.Controls.ComboBox; $role.DisplayMemberPath = 'Name'; $role.SelectedValuePath = 'Id'
        foreach ($item in $script:roles) { [void]$role.Items.Add($item) }
        $role.SelectedValue = [string]$defaults[$i].RoleId
        $issue = New-Object Windows.Controls.Button; $issue.Content = '봇 발급'; $issue.Tag = $i
        $issue.Add_Click({ param($sender,$args) Start-ResearchBotIssuance -Index ([int]$sender.Tag) })
        [Windows.Automation.AutomationProperties]::SetName($name,('에이전트 {0} 이름' -f ($i + 1)))
        [Windows.Automation.AutomationProperties]::SetName($token,('에이전트 {0} 봇 토큰' -f ($i + 1)))
        [Windows.Automation.AutomationProperties]::SetName($role,('에이전트 {0} 역할' -f ($i + 1)))
        $controls = @($profile,$name,$token,$role,$issue)
        for ($columnIndex = 0; $columnIndex -lt $controls.Count; $columnIndex++) {
            $control = $controls[$columnIndex]; $control.Margin = '0,0,8,10'
            [Windows.Controls.Grid]::SetRow($control,($i + 1)); [Windows.Controls.Grid]::SetColumn($control,$columnIndex)
            [void]$ui.AgentRows.Children.Add($control)
        }
        $script:agents += [pscustomobject]@{ ProfileName = [string]$defaults[$i].ProfileName; Name = $name; Token = $token; Role = $role; Issue = $issue }
    }
}

function Refresh-ResearchRoles {
    param([string]$SelectedId)
    foreach ($agent in $script:agents) {
        $oldId = [string]$agent.Role.SelectedValue
        $agent.Role.Items.Clear()
        foreach ($role in $script:roles) { [void]$agent.Role.Items.Add($role) }
        $agent.Role.SelectedValue = $oldId
    }
    $ui.RoleEditorCombo.Items.Clear()
    foreach ($role in $script:roles) { [void]$ui.RoleEditorCombo.Items.Add($role) }
    $ui.RoleEditorCombo.DisplayMemberPath = 'Name'; $ui.RoleEditorCombo.SelectedValuePath = 'Id'
    if ($SelectedId) { $ui.RoleEditorCombo.SelectedValue = $SelectedId } else { $ui.RoleEditorCombo.SelectedIndex = 0 }
}

function Get-ResearchSavedPreferences {
    param($State)
    $ownerSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($State.SchemaVersion -ne 1 -or $State.Manager -cne 'HermesEasySetup.Research.v1' -or
        $State.OwnerSID -cne $ownerSID -or $State.TeamID -cnotmatch '^[a-f0-9]{32}$' -or
        $State.ServerURL -cne $script:serverURL -or $State.HomeChannelID -cne $ui.HomeChannelID.Text) { throw '저장된 연구팀 소유 정보가 현재 연구실과 일치하지 않습니다.' }
    foreach ($key in @('HermesHome','InstallDir','RuntimeRoot')) {
        if ([IO.Path]::GetFullPath([string]$State.$key) -ine [IO.Path]::GetFullPath([string]$script:paths.$key)) { throw '저장된 연구팀 경로가 현재 설정과 일치하지 않습니다.' }
    }
    $index = 0
    $data = [pscustomobject]@{
        SchemaVersion = 1; ServerURL = $State.ServerURL; HomeChannelID = $State.HomeChannelID
        ModelName = $State.ModelName; Roles = $script:roles
        # Validate public metadata without loading credentials from profiles.
        Agents = @($State.Profiles | ForEach-Object {
            $index++
            [pscustomobject]@{ ProfileName = $_.ProfileName; DisplayName = $_.DisplayName; RoleId = $_.RoleId; BotToken = ('a' * 25) + [string]$index }
        })
    }
    return (Assert-HermesResearchTeamInput -InputObject $data)
}

function Read-ResearchSavedTeam {
    $path = Join-Path $script:paths.RuntimeRoot 'research\team.json'
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $path).Length -gt 262144) { throw '저장된 연구팀 기록의 크기가 올바르지 않습니다.' }
    $preferences = Get-ResearchSavedPreferences ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json)
    foreach ($agent in $script:agents) {
        $saved = @($preferences.Agents | Where-Object ProfileName -CEQ $agent.ProfileName)[0]
        $agent.Name.Text = [string]$saved.DisplayName; $agent.Role.SelectedValue = [string]$saved.RoleId
    }
    $script:preferredModel = [string]$preferences.ModelName
    if ($ui.ModelCombo.Items.Contains($script:preferredModel)) { $ui.ModelCombo.SelectedItem = $script:preferredModel }
    $ui.TeamResumeCheck.IsChecked = $true
    Add-ResearchLog '이전에 저장한 네 에이전트의 이름·역할·모델을 불러왔습니다. 토큰은 다시 입력하거나 같은 봇을 발급해 불러오세요.'
}

function Get-ResearchServerInput {
    param([AllowNull()][string]$AdminSecret)
    $identity = $script:serverIdentity
    $sameIdentity = ($null -ne $identity -and [string]$identity.ServerId -ceq $ui.ServerId.Text.Trim())
    $data = [pscustomobject]@{
        ServerId = $ui.ServerId.Text.Trim(); Port = $ui.ServerPort.Text.Trim()
        SiteName = $(if ($sameIdentity) { [string]$identity.SiteName } else { '1인 연구실' })
        TeamName = $(if ($sameIdentity) { [string]$identity.TeamName } else { 'research' })
        TeamDisplayName = $(if ($sameIdentity) { [string]$identity.TeamDisplayName } else { '개인 연구실' })
        ChannelName = $(if ($sameIdentity) { [string]$identity.ChannelName } else { 'agents' })
        AdminUsername = $ui.AdminUsername.Text.Trim(); AdminEmail = $ui.AdminEmail.Text.Trim()
        AdminPassword = $(if ($PSBoundParameters.ContainsKey('AdminSecret')) { $AdminSecret } else { $ui.AdminPassword.Password }); NetworkMode = 'Local'; NetworkAddress = ''
    }
    Assert-HermesAdminInput $data
    return $data
}

function Read-ResearchServerRecord {
    $serverId = $ui.ServerId.Text.Trim()
    if ($serverId -cnotmatch '^[a-z][a-z0-9-]{1,30}[a-z0-9]$') { throw '서버 ID를 확인하세요.' }
    $path = Join-Path (Get-HermesAdminRoot) ($serverId + '\deployment.json')
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '저장된 연구 서버가 없습니다. 먼저 로컬 서버를 설치하세요.' }
    $state = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$state.Status -cne 'Ready' -or [string]$state.Identity.ServerId -cne $serverId -or
        [string]$state.ChannelId -cnotmatch '^[a-z0-9]{26}$' -or [string]$state.TeamId -cnotmatch '^[a-z0-9]{26}$') { throw '서버 완료 기록을 확인하지 못했습니다. 같은 서버를 이어서 설치하세요.' }
    if ($state.PSObject.Properties['NetworkAddress'] -and -not [string]::IsNullOrWhiteSpace([string]$state.NetworkAddress)) { throw '이 초기 연구실 마법사는 로컬 전용 서버를 사용합니다. 공유된 서버는 관리자 마법사에서 먼저 확인하세요.' }
    $port = 0
    if (-not [int]::TryParse([string]$state.Identity.Port,[ref]$port) -or $port -lt 1024 -or $port -gt 65535) { throw '저장된 서버 포트가 올바르지 않습니다.' }
    foreach ($key in @('TeamName','ChannelName')) { if ([string]$state.Identity.$key -cnotmatch '^[a-z][a-z0-9-]{1,30}[a-z0-9]$') { throw '저장된 팀·채널 주소가 올바르지 않습니다.' } }
    $ui.ServerPort.Text = [string]$port; $ui.AdminUsername.Text = [string]$state.Identity.AdminUsername; $ui.AdminEmail.Text = [string]$state.Identity.AdminEmail
    $script:serverIdentity = $state.Identity
    $script:serverURL = "http://127.0.0.1:$port"
    $script:channelURL = "$($script:serverURL)/$($state.Identity.TeamName)/channels/$($state.Identity.ChannelName)"
    $ui.TeamServerURL.Text = $script:serverURL; $ui.HomeChannelID.Text = [string]$state.ChannelId
    $script:serverReady = $true; $ui.ServerResumeCheck.IsChecked = $true
    $ui.ServerStatus.Text = "연구실 주소: $($script:serverURL)`n팀·채널 준비 기록을 불러왔습니다. 연구팀 연결 시 각 봇과 채널 접근을 다시 확인합니다."
    try { Read-ResearchSavedTeam } catch { Add-ResearchLog '기존 연구팀 배정을 불러오지 못했습니다. 같은 연구실·Windows 사용자·설치 경로인지 확인하세요. 기존 기록은 변경하지 않았습니다.' }
}

function Save-ResearchEncryptedInput {
    param($Value)
    $path = Join-Path $script:paths.RuntimeRoot ('ui-transport\research-' + [guid]::NewGuid().ToString('N') + '.bin')
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $path
    $script:inputPath = Protect-HermesLabInput -Value $Value -LiteralPath $path
    return $script:inputPath
}

function Start-ResearchWorker {
    param([string]$Action,[string[]]$ExtraArguments = @())
    if ($script:busy) { return }
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'HermesEasySetup.ps1'),
        '-Action',$Action,'-JsonEvents','-HermesHome',$script:paths.HermesHome,'-InstallDir',$script:paths.InstallDir,'-RuntimeRoot',$script:paths.RuntimeRoot) + $ExtraArguments
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Get-HermesPowerShellExecutable
    $start.Arguments = (($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument ([string]$_) }) -join ' ')
    $start.WorkingDirectory = $PSScriptRoot; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    try { if (-not $process.Start()) { throw '작업 프로세스를 시작하지 못했습니다.' } } catch { $process.Dispose(); throw }
    $script:worker = $process; $script:workerAction = $Action; $script:workerResult = $null
    $script:workerFailed = $false; $script:workerEOF = $false; $script:busy = $true
    $script:stderr = $process.StandardError.ReadToEndAsync()
    $script:pendingLine = $process.StandardOutput.ReadLineAsync()
    $ui.Progress.Value = 0; Refresh-ResearchButtons; $timer.Start()
}

function Read-ResearchWorkerLine {
    param([string]$Line)
    if (-not $Line) { return }
    try { $event = $Line | ConvertFrom-Json } catch { return }
    if ($event.PSObject.Properties['type']) {
        if ([string]$event.type -ceq 'oauth') {
            if ([string]$event.data.URL -ceq 'https://auth.openai.com/codex/device' -and [string]$event.data.UserCode -cmatch '^[A-Z0-9][A-Z0-9-]{3,63}$') {
                $script:authURL = [string]$event.data.URL; $ui.AuthCode.Text = [string]$event.data.UserCode
                $ui.AuthStatus.Text = '인증 페이지를 열어 로그인하고 이 일회용 코드를 입력하세요.'; Refresh-ResearchButtons
            }
        } else {
            if ($event.PSObject.Properties['message']) { Add-ResearchLog ([string]$event.message) }
        }
        if ($event.PSObject.Properties['percent']) { $ui.Progress.Value = [math]::Min(100,[math]::Max(0,[double]$event.percent)) }
        if ([string]$event.type -ceq 'error') { $script:workerFailed = $true }
        if ([string]$event.type -ceq 'complete' -and $event.PSObject.Properties['data']) { $script:workerResult = $event.data }
    } elseif (@('AdminPreflight','DockerStatus','Plan','CodexStatus') -contains $script:workerAction) { $script:workerResult = $event }
}

function Set-ResearchDockerStatus {
    param($Status)
    if ($null -eq $Status -or $Status.Ready -isnot [bool] -or $Status.CanInstall -isnot [bool] -or $Status.CanOpen -isnot [bool]) { throw 'Docker 상태 응답을 확인하지 못했습니다.' }
    $rebootRequired = ($Status.PSObject.Properties['RebootRequired'] -and $Status.RebootRequired -eq $true)
    if ($rebootRequired) { $script:dockerRebootRequired = $true }
    $script:dockerReady = [bool]$Status.Ready -and -not $script:dockerRebootRequired
    $script:dockerCanInstall = [bool]$Status.CanInstall -and -not [bool]$Status.Installed
    $script:dockerCanOpen = [bool]$Status.CanOpen
    $ui.DockerStatus.Text = [string]$Status.Summary
    if ($script:dockerRebootRequired) { $ui.DockerStatus.Text += [Environment]::NewLine + '이번 설치에서 재부팅 필요를 확인했습니다. 직접 Windows를 재부팅한 뒤 마법사를 다시 실행하세요.' }
    $ui.DockerPrerequisites.Text = (@($Status.Prerequisites | ForEach-Object {
        $label = $(switch ([string]$_.State) { 'Pass' { '충족' } 'Fail' { '미충족' } default { '확인 필요' } })
        '[{0}] {1}: {2}' -f $label,$_.Name,$_.Message
    }) -join [Environment]::NewLine)
    if ($Status.PSObject.Properties['Alternatives'] -and $Status.Alternatives) { $ui.DockerAlternatives.Text = @($Status.Alternatives) -join [Environment]::NewLine }
    $ui.DockerInstallConsent.IsChecked = $false
    Refresh-ResearchButtons
}

function Set-ResearchAuthStatus {
    param($Status)
    $script:hermesReady = $true
    $script:authenticated = [bool]$Status.LoggedIn
    $ui.AuthStatus.Text = [string]$Status.Summary
    $previous = $(if ($script:preferredModel) { $script:preferredModel } else { [string]$ui.ModelCombo.SelectedItem })
    $ui.ModelCombo.Items.Clear()
    foreach ($model in @($Status.Models)) { [void]$ui.ModelCombo.Items.Add([string]$model) }
    if ($previous -and @($Status.Models) -contains $previous) { $ui.ModelCombo.SelectedItem = $previous }
    elseif ($ui.ModelCombo.Items.Count -gt 0) { $ui.ModelCombo.SelectedIndex = 0 }
}

function Complete-ResearchWorker {
    $timer.Stop()
    $process = $script:worker; $process.WaitForExit()
    $action = $script:workerAction; $result = $script:workerResult
    $success = ($process.ExitCode -eq 0 -and -not $script:workerFailed -and $null -ne $result)
    $process.Dispose(); $script:worker = $null; $script:pendingLine = $null; $script:stderr = $null
    $script:busy = $false
    if ($script:inputPath -and (Test-Path -LiteralPath $script:inputPath -PathType Leaf)) { Remove-Item -LiteralPath $script:inputPath -Force -ErrorAction SilentlyContinue }
    $script:inputPath = $null
    switch ($action) {
        { $_ -in @('DockerStatus','DockerInstall') } {
            if ($null -ne $result) {
                Set-ResearchDockerStatus $result
                if (-not $success) { $script:dockerReady = $false }
                if ($action -ceq 'DockerInstall') {
                    if ($result.RebootRequired) { Add-ResearchLog 'Docker 설치 후 Windows 재부팅이 필요합니다. 저장한 뒤 직접 재부팅하고 마법사를 다시 열어 준비 상태를 확인하세요.' }
                    elseif (-not $result.Ready -and $result.Installed) { Add-ResearchLog 'Docker 설치와 서버 준비는 별개입니다. Docker Desktop을 열어 약관·설정을 확인한 뒤 준비 상태를 다시 검사하세요.' }
                }
            } else {
                $script:dockerReady = $false; $script:dockerCanInstall = $false; $script:dockerCanOpen = $false
                $ui.DockerStatus.Text = 'Docker 확인·설치를 완료하지 못했습니다. 아래 안내를 확인하고 준비 상태를 다시 검사하세요.'
                $ui.DockerInstallConsent.IsChecked = $false
            }
        }
        'AdminPreflight' {
            $script:dockerReady = $success -and [bool]$result.Ready
            $ui.DockerStatus.Text = $(if ($script:dockerReady) { 'Docker Desktop / Linux 엔진 준비 완료' } else { 'Docker Desktop을 실행한 뒤 다시 확인하세요.' })
        }
        'AdminSetup' {
            if ($success -and [bool]$result.Ready) { Read-ResearchServerRecord; Add-ResearchLog '로컬 연구 서버가 준비되었습니다. 다음 단계에서 Hermes를 구성하세요.' }
            else { $script:serverReady = $false; $ui.ServerStatus.Text = '서버 설치를 완료하지 못했습니다. 오류 확인 후 같은 입력으로 이어서 설치하세요.'; $ui.ServerResumeCheck.IsChecked = $true }
        }
        'AdminBotSetup' {
            if ($success -and $script:botIndex -ge 0 -and $script:botIndex -lt $script:agents.Count) {
                $secret = Read-HermesAdminBotCredential $result
                try { $script:agents[$script:botIndex].Token.Password = [string]$secret.Token } finally { $secret = $null }
                Add-ResearchLog ('봇 토큰을 해당 행에 채웠습니다: ' + $script:agents[$script:botIndex].ProfileName)
            }
        }
        'Plan' {
            $script:plan = $(if ($success) { $result } else { $null })
            if ($success) {
                $ui.HermesPlanText.Text = "릴리스: $($result.SourceTag)`ncommit: $($result.SourceCommit)`n코드: $($result.InstallDir)`n데이터: $($result.HermesHome)`n계획 지문: $($result.Fingerprint)`n기본 CLI 설치 · Computer Use/Desktop 자동 설치 건너뜀"
            }
        }
        'Install' {
            if ($success -and [bool]$result.Verified -and [bool]$result.Installed -and @($result.FailedChecks).Count -eq 0) {
                $script:hermesReady = $true
                Add-ResearchLog 'Hermes 설치 검증 완료. 모델 인증 상태를 확인합니다.'
                Start-ResearchWorker 'CodexStatus'
            }
        }
        { $_ -in @('CodexStatus','CodexAuth') } {
            if ($success) { Set-ResearchAuthStatus $result }
            else { $script:authenticated = $false; $ui.AuthStatus.Text = 'Hermes 설치 또는 모델 인증 상태를 확인하지 못했습니다. 진행 안내를 확인하세요.' }
            $ui.AuthCode.Clear(); $script:authURL = $null
        }
        'ResearchTeamSetup' {
            if ($null -ne $result) {
                $script:preferredModel = [string]$result.ModelName
                $lines = @($result.Profiles | ForEach-Object {
                    $text = '{0} ({1}): {2}' -f $_.DisplayName,$_.ProfileName,$_.Status
                    if ($_.ErrorCode) { $text += ' — ' + [string]$_.ErrorCode }
                    $text
                })
                $ui.TeamResult.Text = $lines -join [Environment]::NewLine
                $ui.TeamResumeCheck.IsChecked = $true
            }
            if ($success -and [bool]$result.Succeeded) { Add-ResearchLog '네 Gateway 기동을 확인했습니다. 연구 채널에서 각 봇을 @멘션해 실제 모델 답변을 확인하세요.' }
            else { Add-ResearchLog '일부 연구팀 설정을 완료하지 못했습니다. 결과를 확인하고 연구 프로필 재설정으로 다시 시도하세요.' }
        }
    }
    if (-not $success -and -not $script:workerFailed) { Add-ResearchLog '작업의 완료 결과를 확인하지 못했습니다. 이전 데이터는 보존됩니다.' }
    Refresh-ResearchButtons
}

function Start-ResearchBotIssuance {
    param([int]$Index)
    if ($script:busy -or -not $script:serverReady -or $Index -lt 0 -or $Index -ge $script:agents.Count) { return }
    try {
        $data = Get-ResearchServerInput -AdminSecret $ui.TeamAdminPassword.Password
        $data | Add-Member BotUsername $script:agents[$Index].ProfileName
        $data | Add-Member BotDisplayName $script:agents[$Index].Name.Text.Trim()
        $data | Add-Member BotDescription 'Hermes local research agent'
        Assert-HermesAdminBotInput $data
        $script:botIndex = $Index
        $path = Save-ResearchEncryptedInput $data
        Start-ResearchWorker 'AdminBotSetup' @('-Apply','-AdminInputPath',$path)
        $data = $null
    } catch { Add-ResearchLog $_.Exception.Message; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
}

function Remove-ResearchUnusedInput {
    if (-not $script:busy -and $script:inputPath -and (Test-Path -LiteralPath $script:inputPath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:inputPath -Force -ErrorAction SilentlyContinue; $script:inputPath = $null
    }
}

Add-ResearchAgentRows
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$workerTick = {
    try {
        while (-not $script:workerEOF -and $script:pendingLine.IsCompleted) {
            $line = $script:pendingLine.GetAwaiter().GetResult()
            if ($null -eq $line) { $script:workerEOF = $true; break }
            Read-ResearchWorkerLine $line
            $script:pendingLine = $script:worker.StandardOutput.ReadLineAsync()
        }
        if ($script:worker.HasExited -and $script:workerEOF) { Complete-ResearchWorker }
    } catch {
        $script:workerFailed = $true; Add-ResearchLog '작업 표시를 완료하지 못했습니다. 진행 결과를 확인하고 같은 입력으로 다시 시도하세요.'
        $script:workerEOF = $true; $script:pendingLine = $null
        if ($null -eq $script:worker) { $timer.Stop(); $script:busy = $false; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
        elseif ($script:worker.HasExited) { Complete-ResearchWorker }
    }
}
$timer.Add_Tick($workerTick)

$ui.RoleEditorCombo.Add_SelectionChanged({
    $selected = $ui.RoleEditorCombo.SelectedItem
    if ($null -ne $selected) { $ui.RoleName.Text = [string]$selected.Name; $ui.RoleInstructions.Text = [string]$selected.Instructions }
})
Refresh-ResearchRoles
$ui.RoleSaveButton.Add_Click({
    try {
        $selected = $ui.RoleEditorCombo.SelectedItem
        if ($null -eq $selected -or $script:busy) { return }
        $id = [string]$selected.Id
        $changed = @($script:roles | ForEach-Object {
            if ([string]$_.Id -ceq $id) { [pscustomobject]@{ Id = $id; Name = $ui.RoleName.Text.Trim(); Instructions = $ui.RoleInstructions.Text.Trim() } } else { $_ }
        })
        $publicText = ($changed | ConvertTo-Json -Depth 8 -Compress)
        foreach ($agent in $script:agents) {
            if ($agent.Token.Password.Length -eq 26 -and $publicText.Contains($agent.Token.Password)) { throw '봇 토큰을 역할 이름·지침에 저장할 수 없습니다.' }
        }
        $null = Save-HermesResearchRoles -Roles $changed -RuntimeRoot $script:paths.RuntimeRoot
        $script:roles = @(Get-HermesResearchRoles -RuntimeRoot $script:paths.RuntimeRoot)
        Refresh-ResearchRoles -SelectedId $id
        Add-ResearchLog '역할 템플릿을 저장했습니다. 기존 에이전트에 적용하려면 연구 프로필 재설정으로 실행하세요.'
    } catch { Add-ResearchLog $_.Exception.Message }
})
foreach ($name in @('ServerConsent','HermesConsent','TeamConsent','DockerInstallConsent')) {
    $ui[$name].Add_Checked({ Refresh-ResearchButtons }); $ui[$name].Add_Unchecked({ Refresh-ResearchButtons })
}
$ui.ModelCombo.Add_SelectionChanged({ Refresh-ResearchButtons })
$ui.DockerCheckButton.Add_Click({ try { $script:dockerReady = $false; Start-ResearchWorker 'DockerStatus' } catch { Add-ResearchLog $_.Exception.Message; Refresh-ResearchButtons } })
$ui.DockerOpenButton.Add_Click({
    try {
        if ($script:busy -or -not $script:dockerCanOpen) { return }
        Open-HermesDockerDesktop | Out-Null
        $script:dockerReady = $false; Refresh-ResearchButtons
        Add-ResearchLog 'Docker Desktop의 약관과 초기 설정을 직접 확인하세요. Linux 엔진 실행 후 준비 상태를 다시 검사하세요.'
    } catch { Add-ResearchLog $_.Exception.Message }
})
$ui.DockerInstallButton.Add_Click({
    try {
        if ($script:busy -or -not $script:dockerCanInstall -or $ui.DockerInstallConsent.IsChecked -ne $true) { return }
        $script:dockerReady = $false; $ui.DockerInstallConsent.IsChecked = $false
        Add-ResearchLog '공식 Docker 설치 파일을 다운로드·검증합니다. 설치 창에서 요청하는 내용은 직접 확인하세요. 약관을 자동 동의하거나 PC를 재부팅하지 않습니다.'
        Start-ResearchWorker 'DockerInstall' @('-Apply')
    } catch { Add-ResearchLog $_.Exception.Message; Refresh-ResearchButtons }
})
$ui.DockerGuideButton.Add_Click({ if (-not $script:busy) { Start-Process 'https://docs.docker.com/desktop/setup/install/windows-install/' | Out-Null } })
$ui.ServerRestoreButton.Add_Click({ try { Read-ResearchServerRecord; Start-ResearchWorker 'DockerStatus' } catch { $script:serverReady = $false; Add-ResearchLog $_.Exception.Message; Refresh-ResearchButtons } })
$ui.ServerCreateButton.Add_Click({
    try {
        if ($script:busy -or $ui.ServerConsent.IsChecked -ne $true -or -not $script:dockerReady) { return }
        if ($ui.AdminPassword.Password -cne $ui.PasswordConfirm.Password) { throw '비밀번호 확인이 일치하지 않습니다.' }
        $path = Save-ResearchEncryptedInput (Get-ResearchServerInput)
        $extra = @('-Apply','-AdminInputPath',$path)
        if ($ui.ServerResumeCheck.IsChecked -eq $true) { $extra += '-Resume' }
        Start-ResearchWorker 'AdminSetup' $extra
        $ui.AdminPassword.Clear(); $ui.PasswordConfirm.Clear()
    } catch { Add-ResearchLog $_.Exception.Message; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
})
foreach ($name in @('ServerId','ServerPort','AdminUsername','AdminEmail')) {
    $ui[$name].Add_TextChanged({ if (-not $script:busy) { $script:serverReady = $false; $script:serverIdentity = $null; Refresh-ResearchButtons } })
}
$ui.ServerOpenButton.Add_Click({ if ($script:serverReady) { Start-Process $script:serverURL | Out-Null } })
$ui.ServerNextButton.Add_Click({ if ($script:serverReady) { $ui.WizardTabs.SelectedIndex = 1 } })
$ui.HermesPlanButton.Add_Click({
    try { $script:plan = $null; $ui.HermesConsent.IsChecked = $false; Start-ResearchWorker 'Plan' @('-SkipComputerUse','-SetupMode','Later') }
    catch { Add-ResearchLog $_.Exception.Message }
})
$ui.HermesInstallButton.Add_Click({
    try {
        if ($script:busy -or $null -eq $script:plan -or $ui.HermesConsent.IsChecked -ne $true) { return }
        $extra = @('-Apply','-SkipComputerUse','-SetupMode','Later','-ExpectedPlanFingerprint',[string]$script:plan.Fingerprint)
        $prior = Read-HermesInstallState -LiteralPath $script:paths.StateFile
        if ($null -ne $prior -and @('Running','Failed') -contains [string]$prior.status -and [string]$prior.plan_fingerprint -ceq [string]$script:plan.Fingerprint) { $extra += '-Resume' }
        Start-ResearchWorker 'Install' $extra
    } catch { Add-ResearchLog $_.Exception.Message }
})
$ui.HermesStatusButton.Add_Click({ try { Start-ResearchWorker 'CodexStatus' } catch { Add-ResearchLog $_.Exception.Message } })
$ui.AuthButton.Add_Click({ try { $ui.AuthCode.Clear(); $script:authURL = $null; Start-ResearchWorker 'CodexAuth' @('-Apply') } catch { Add-ResearchLog $_.Exception.Message } })
$ui.AuthOpenButton.Add_Click({ if ($script:authURL -ceq 'https://auth.openai.com/codex/device') { Start-Process $script:authURL | Out-Null } })
$ui.HermesNextButton.Add_Click({ if ($script:authenticated -and $null -ne $ui.ModelCombo.SelectedItem) { $ui.WizardTabs.SelectedIndex = 2 } })
$ui.TeamOpenButton.Add_Click({ if ($script:serverReady) { Start-Process $script:channelURL | Out-Null } })
$ui.TeamApplyButton.Add_Click({
    try {
        if ($script:busy -or $ui.TeamConsent.IsChecked -ne $true -or -not $script:authenticated -or -not $script:serverReady) { return }
        $data = [pscustomobject]@{
            SchemaVersion = 1; ServerURL = $ui.TeamServerURL.Text; HomeChannelID = $ui.HomeChannelID.Text
            ModelName = [string]$ui.ModelCombo.SelectedItem; Roles = $script:roles
            Agents = @($script:agents | ForEach-Object { [pscustomobject]@{
                ProfileName = $_.ProfileName; DisplayName = $_.Name.Text.Trim(); RoleId = [string]$_.Role.SelectedValue; BotToken = $_.Token.Password
            } })
        }
        $null = Assert-HermesResearchTeamInput -InputObject $data
        $path = Save-ResearchEncryptedInput $data
        $extra = @('-Apply','-ResearchInputPath',$path)
        if ($ui.TeamResumeCheck.IsChecked -eq $true) { $extra += '-Resume' }
        Start-ResearchWorker 'ResearchTeamSetup' $extra
        $data = $null
    } catch { Add-ResearchLog $_.Exception.Message; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
})
$ui.CloseButton.Add_Click({ $window.Close() })
$window.Add_Closing({ param($sender,$eventArgs)
    if ($script:busy) { $eventArgs.Cancel = $true; Add-ResearchLog '설치·인증·연결 작업 완료 후 창을 닫으세요.' }
    else { foreach ($agent in $script:agents) { $agent.Token.Clear() }; $ui.AdminPassword.Clear(); $ui.PasswordConfirm.Clear(); $ui.TeamAdminPassword.Clear(); Remove-ResearchUnusedInput }
})
Refresh-ResearchButtons
if ($SmokeTest) {
    if ($script:agents.Count -ne 4 -or $ui.ServerCreateButton.IsEnabled -or $ui.HermesInstallButton.IsEnabled -or $ui.TeamApplyButton.IsEnabled) { throw '연구실 기본 동작이 안전하지 않습니다.' }
    if ($ui.HermesTab.IsEnabled -or $ui.TeamTab.IsEnabled -or $ui.ServerConsent.IsChecked -or $ui.TeamConsent.IsChecked) { throw '준비되지 않은 연구실 단계가 활성화됐습니다.' }
    if (@($script:agents | Where-Object { $_.Token.Password }).Count -ne 0 -or $ui.AdminPassword.Password -or $ui.PasswordConfirm.Password) { throw '초기 입력에 비밀값이 있습니다.' }
    foreach ($agent in $script:agents) { if ($agent.Role.Items.Count -ne 4 -or $null -eq $agent.Role.SelectedItem) { throw '연구 역할 네 개가 표시되지 않습니다.' } }
    if ($ui.DockerInstallConsent.IsChecked -or $ui.DockerInstallButton.IsEnabled -or $ui.DockerOpenButton.IsEnabled) { throw '확인 전 Docker 설치·실행이 활성화됐습니다.' }
    $dockerFixture = [pscustomobject]@{
        Installed = $false; Ready = $false; CanInstall = $true; CanOpen = $false; RebootRequired = $false
        Summary = '미설치 테스트'; Prerequisites = @(); Alternatives = @('대안 안내 테스트')
    }
    $script:workerAction = 'DockerStatus'; $script:workerResult = $null
    Read-ResearchWorkerLine ($dockerFixture | ConvertTo-Json -Compress)
    if ($null -eq $script:workerResult -or $script:workerResult.Installed) { throw 'Docker 조회 JSON이 처리되지 않습니다.' }
    Set-ResearchDockerStatus $script:workerResult
    if ($ui.DockerInstallButton.IsEnabled -or -not $ui.DockerInstallConsent.IsEnabled) { throw 'Docker 설치 동의가 우회됐습니다.' }
    $ui.DockerInstallConsent.IsChecked = $true
    if (-not $ui.DockerInstallButton.IsEnabled) { throw '동의한 미설치 환경에서 Docker 설치가 활성화되지 않습니다.' }
    $script:busy = $true; Refresh-ResearchButtons
    if ($ui.DockerInstallButton.IsEnabled -or $ui.DockerInstallConsent.IsEnabled -or $ui.DockerCheckButton.IsEnabled) { throw 'Docker 작업 중 입력이 차단되지 않습니다.' }
    $script:busy = $false
    $dockerFixture.Installed = $true; $dockerFixture.CanInstall = $false; $dockerFixture.CanOpen = $true
    Set-ResearchDockerStatus $dockerFixture
    $ui.ServerConsent.IsChecked = $true
    if ($ui.ServerCreateButton.IsEnabled -or $ui.DockerInstallButton.IsEnabled) { throw 'Docker 설치만으로 서버 준비가 완료됐습니다.' }
    $dockerFixture.Ready = $true; $dockerFixture.RebootRequired = $true
    Set-ResearchDockerStatus $dockerFixture
    if ($ui.ServerCreateButton.IsEnabled) { throw '재부팅 필요 상태에서 서버 설치가 활성화됐습니다.' }
    $dockerFixture.RebootRequired = $false
    Set-ResearchDockerStatus $dockerFixture
    if ($ui.ServerCreateButton.IsEnabled) { throw '다시 확인이 이번 설치의 재부팅 요구를 지웠습니다.' }
    $script:dockerRebootRequired = $false # Simulate a fresh wizard session after reboot.
    $script:workerAction = 'DockerInstall'; $script:workerResult = $null
    Read-ResearchWorkerLine ([pscustomobject]@{ type = 'complete'; message = '설치 테스트'; data = $dockerFixture } | ConvertTo-Json -Compress -Depth 6)
    if ($null -eq $script:workerResult -or -not $script:workerResult.Installed) { throw 'Docker 설치 complete 이벤트가 처리되지 않습니다.' }
    Set-ResearchDockerStatus $script:workerResult
    if (-not $ui.ServerCreateButton.IsEnabled) { throw 'Docker Linux 엔진 준비 확인이 서버 단계로 연결되지 않습니다.' }
    $ui.ServerConsent.IsChecked = $false
    $script:dockerReady = $false; $script:dockerCanInstall = $false; $script:dockerCanOpen = $false
    $ui.DockerStatus.Text = '설치 위치·공식 서명·Linux 엔진과 PC 준비 상태를 확인합니다.'
    $ui.DockerAlternatives.Text = 'WSL2 Ubuntu 직접 설치 또는 별도 Linux·기존 Mattermost 서버 연결이 대안입니다. 이 초기 버전에서는 대안 안내만 제공합니다.'
    $script:serverURL = 'http://127.0.0.1:18065'; $ui.HomeChannelID.Text = 'c' * 26
    $saved = [pscustomobject]@{
        SchemaVersion = 1; Manager = 'HermesEasySetup.Research.v1'; OwnerSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        TeamID = 'a' * 32; ServerURL = $script:serverURL; HomeChannelID = $ui.HomeChannelID.Text
        HermesHome = $script:paths.HermesHome; InstallDir = $script:paths.InstallDir; RuntimeRoot = $script:paths.RuntimeRoot
        ModelName = 'mock-model'; Profiles = @(New-HermesResearchDefaultAgents)
    }
    $saved.Profiles[0].DisplayName = '수정된 총괄'; $saved.Profiles[0].RoleId = 'reviewer'; $saved.Profiles[3].RoleId = 'planner'
    $preferences = Get-ResearchSavedPreferences $saved
    if ($preferences.Agents[0].DisplayName -cne '수정된 총괄' -or $preferences.Agents[0].RoleId -cne 'reviewer') { throw '기존 이름·교환한 역할이 복원되지 않습니다.' }
    $saved.OwnerSID = 'S-1-5-18'; $rejected = $false
    try { $null = Get-ResearchSavedPreferences $saved } catch { $rejected = $true }
    if (-not $rejected) { throw '다른 사용자의 연구팀 배정을 불러왔습니다.' }
    $script:serverReady = $true; $script:hermesReady = $true; $script:authenticated = $true
    [void]$ui.ModelCombo.Items.Add('mock-model'); $ui.ModelCombo.SelectedIndex = 0
    Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled -or -not $ui.TeamTab.IsEnabled) { throw '모델 인증이 생성 동의를 우회했습니다.' }
    $ui.TeamConsent.IsChecked = $true; Refresh-ResearchButtons
    if (-not $ui.TeamApplyButton.IsEnabled) { throw '연구팀 생성 조건이 충족돼도 버튼이 활성화되지 않습니다.' }
    $script:busy = $true; Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled -or $ui.CloseButton.IsEnabled -or @($script:agents | Where-Object { $_.Token.IsEnabled }).Count -ne 0) { throw '작업 중 입력과 닫기가 차단되지 않습니다.' }
    $script:busy = $false; Refresh-ResearchButtons
    $script:worker = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
    $script:worker | Add-Member ScriptMethod WaitForExit { }
    $script:worker | Add-Member ScriptMethod Dispose { }
    $script:pendingLine = [pscustomobject]@{ IsCompleted = $true }
    $script:pendingLine | Add-Member ScriptMethod GetAwaiter { throw 'mock read failure' }
    $script:workerEOF = $false; $script:busy = $true; $script:workerAction = 'mock-fault'; $script:workerResult = $null
    & $workerTick
    if ($script:busy -or $null -ne $script:worker -or -not $ui.CloseButton.IsEnabled) { throw '작업 읽기 실패 후 종료 잠금이 풀리지 않습니다.' }
    $ui.Log.Clear()
    if ($PreviewPath) {
        $ui.WizardTabs.SelectedIndex = $(if ($PreviewStep -ceq 'Server') { 0 } else { 2 })
        $window.Show(); $window.UpdateLayout()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Open([IO.Path]::GetFullPath($PreviewPath),[IO.FileMode]::CreateNew)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    Write-Host 'PASS local research WPF: Docker consent/status/reboot gates, server-first flow, masked tokens, restored roles and failed-worker cleanup'
    $window.Close(); exit 0
}
$window.Add_ContentRendered({
    if (-not $script:busy -and -not $script:initialDockerCheck) {
        $script:initialDockerCheck = $true
        try { Start-ResearchWorker 'DockerStatus' } catch { Add-ResearchLog $_.Exception.Message }
    }
})
$window.ShowDialog() | Out-Null
