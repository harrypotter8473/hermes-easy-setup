[CmdletBinding()]
param([switch]$SmokeTest,[string]$PreviewPath,[ValidateSet('Server','Hermes','Team')][string]$PreviewStep = 'Team')

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
    'UseExistingHermesCheck','ExistingHermesHome','ExistingHermesInstallDir','ExistingHermesStatus',
    'AuthButton','AuthOpenButton','AuthStatus','AuthCode','ModelCombo','HermesNextButton',
    'TeamServerURL','HomeChannelID','TeamAdminPassword','AgentRows','RoleEditorCombo','RoleName','RoleInstructions','RoleSaveButton',
    'PersonaResetButton','PolicyJson','PolicyLoadButton','PolicySaveButton','PolicyRoleRows','PolicyDefaultsButton',
    'WorkspacePath','WorkspaceBrowseButton','HumanUsername','SelectedModelSummary','ModelEgressConsent','PublicWebConsent','MigrationConsent',
    'TeamResumeCheck','TeamConsent','TeamApplyButton','TeamOpenButton','TeamResult','Progress','Log','CloseButton'
)) {
    $ui[$name] = $window.FindName($name)
    if ($null -eq $ui[$name]) { throw "필수 연구실 컨트롤이 없습니다: $name" }
}
$script:paths = Get-HermesDefaultPaths
$script:defaultPaths = $script:paths
$script:useExistingHermes = $false
$ui.ExistingHermesHome.Text = $script:paths.HermesHome
$ui.ExistingHermesInstallDir.Text = $script:paths.InstallDir
$script:roles = @(Get-HermesResearchRoles -RuntimeRoot $script:paths.RuntimeRoot)
$ui.PolicyJson.Text = (Get-HermesResearchPolicy -RuntimeRoot $script:paths.RuntimeRoot | ConvertTo-Json -Depth 15)
$script:policyRows = @{}
$script:teamInputsEdited = $false
$script:restoringTeam = $false
$script:lastLoadedTeamKey = $null
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
        'HermesConsent','UseExistingHermesCheck','TeamAdminPassword','TeamResumeCheck','TeamConsent','RoleEditorCombo','RoleName','RoleInstructions','RoleSaveButton','PersonaResetButton','PolicyJson','PolicyLoadButton','PolicySaveButton',
        'WorkspacePath','WorkspaceBrowseButton','HumanUsername','ModelEgressConsent','PublicWebConsent','MigrationConsent','PolicyDefaultsButton','PolicyRoleRows')) {
        $ui[$name].IsEnabled = $idle
    }
    $ui.DockerOpenButton.IsEnabled = $idle -and $script:dockerCanOpen
    $ui.DockerInstallConsent.IsEnabled = $idle -and $script:dockerCanInstall
    $ui.DockerInstallButton.IsEnabled = $idle -and $script:dockerCanInstall -and $ui.DockerInstallConsent.IsChecked -eq $true
    $ui.ServerCreateButton.IsEnabled = $idle -and $script:dockerReady -and $ui.ServerConsent.IsChecked -eq $true
    $ui.ServerOpenButton.IsEnabled = $idle -and $script:serverReady
    $ui.ServerNextButton.IsEnabled = $ui.ServerOpenButton.IsEnabled
    $ui.HermesTab.IsEnabled = $script:serverReady
    $ui.ExistingHermesHome.IsEnabled = $idle -and $script:useExistingHermes
    $ui.ExistingHermesInstallDir.IsEnabled = $idle -and $script:useExistingHermes
    $ui.HermesPlanButton.IsEnabled = $idle -and $script:serverReady -and -not $script:useExistingHermes
    $ui.HermesStatusButton.IsEnabled = $idle -and $script:serverReady
    $ui.HermesConsent.IsEnabled = $idle -and -not $script:useExistingHermes
    $ui.HermesInstallButton.IsEnabled = $idle -and -not $script:useExistingHermes -and $null -ne $script:plan -and $ui.HermesConsent.IsChecked -eq $true
    $ui.AuthButton.IsEnabled = $idle -and $script:hermesReady -and -not $script:useExistingHermes
    foreach ($name in @('HermesPlanText','HermesConsent','HermesInstallButton','AuthButton','AuthOpenButton','AuthCode')) {
        $ui[$name].Visibility = $(if ($script:useExistingHermes) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible })
    }
    $ui.AuthOpenButton.IsEnabled = $null -ne $script:authURL
    $ui.ModelCombo.IsEnabled = $idle -and $script:authenticated
    $ui.HermesNextButton.IsEnabled = $idle -and $script:authenticated -and $null -ne $ui.ModelCombo.SelectedItem
    $ui.TeamTab.IsEnabled = $script:serverReady -and $script:authenticated
    $ui.TeamApplyButton.IsEnabled = $idle -and $ui.TeamTab.IsEnabled -and $null -ne $ui.ModelCombo.SelectedItem -and $ui.TeamConsent.IsChecked -eq $true -and $ui.ModelEgressConsent.IsChecked -eq $true -and $ui.PublicWebConsent.IsChecked -eq $true
    $ui.SelectedModelSummary.Text = $(if ($null -ne $ui.ModelCombo.SelectedItem) { '네 역할에 적용할 모델: ' + [string]$ui.ModelCombo.SelectedItem } else { '모델: 2단계에서 인증한 공통 모델을 네 역할에 적용합니다.' })
    $ui.TeamOpenButton.IsEnabled = $idle -and $script:serverReady
    foreach ($agent in $script:agents) {
        $agent.Name.IsEnabled = $idle
        $agent.Token.IsEnabled = $idle
        $agent.Role.IsEnabled = $idle
        $agent.Issue.IsEnabled = $idle -and $script:serverReady -and $script:dockerReady
    }
}

function Add-ResearchPolicyRows {
    $headers = @('역할','자료 읽기','시도','수정','감사','전체 초','토큰 상한','응답 토큰','응답 초')
    $widths = @(65,65,55,50,50,70,90,85,70)
    for ($column = 0; $column -lt $headers.Count; $column++) {
        $definition = New-Object Windows.Controls.ColumnDefinition
        $definition.Width = New-Object Windows.GridLength($widths[$column])
        $ui.PolicyRoleRows.ColumnDefinitions.Add($definition)
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $headers[$column]; $label.Margin = '2,0,2,6'; $label.FontSize = 12
        [Windows.Controls.Grid]::SetColumn($label,$column)
        [void]$ui.PolicyRoleRows.Children.Add($label)
    }
    $ui.PolicyRoleRows.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $keys = @('attempts','revisions','audits','seconds','tokens','max_output_tokens','per_call_timeout_seconds')
    $index = 0
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        $index++
        $ui.PolicyRoleRows.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = @('관리','조사','분석','감사')[$index - 1]; $label.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetRow($label,$index); [void]$ui.PolicyRoleRows.Children.Add($label)
        $read = New-Object Windows.Controls.CheckBox
        $read.VerticalAlignment = 'Center'; $read.HorizontalAlignment = 'Center'
        [Windows.Automation.AutomationProperties]::SetName($read,($label.Text + ' 입력 자료 읽기 허용'))
        [Windows.Controls.Grid]::SetRow($read,$index); [Windows.Controls.Grid]::SetColumn($read,1)
        [void]$ui.PolicyRoleRows.Children.Add($read)
        $row = @{ ReadWorkspace = $read; Limits = @{} }
        for ($limitIndex = 0; $limitIndex -lt $keys.Count; $limitIndex++) {
            $box = New-Object Windows.Controls.TextBox
            $box.Margin = '2,2,2,2'; $box.Padding = '4,5'; $box.FontSize = 12
            [Windows.Automation.AutomationProperties]::SetName($box,($label.Text + ' ' + $headers[$limitIndex + 2]))
            [Windows.Controls.Grid]::SetRow($box,$index); [Windows.Controls.Grid]::SetColumn($box,($limitIndex + 2))
            [void]$ui.PolicyRoleRows.Children.Add($box)
            $row.Limits[$keys[$limitIndex]] = $box
        }
        $script:policyRows[$role] = $row
    }
}

function Set-ResearchWizardOptions {
    param($Options, [switch]$LimitsOnly)
    if (-not $LimitsOnly) {
        $ui.WorkspacePath.Text = [string]$Options.WorkspacePath
        $ui.HumanUsername.Text = [string]$Options.HumanUsername
        # Saved installation consent is not consent for a new installation/test.
        $ui.ModelEgressConsent.IsChecked = $false; $ui.PublicWebConsent.IsChecked = $false; $ui.MigrationConsent.IsChecked = $false
    }
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        $row = $script:policyRows[$role]
        $row.ReadWorkspace.IsChecked = [bool]$Options.Roles.$role.ReadWorkspace
        foreach ($key in $row.Limits.Keys) { $row.Limits[$key].Text = [string]$Options.Roles.$role.Limits.$key }
    }
}

function Get-ResearchWizardOptions {
    $options = New-HermesResearchWizardOptions -WorkspacePath $ui.WorkspacePath.Text.Trim() -HumanUsername $ui.HumanUsername.Text.Trim()
    $options.AllowModelEgress = $ui.ModelEgressConsent.IsChecked -eq $true
    $options.AllowPublicWeb = $ui.PublicWebConsent.IsChecked -eq $true
    $options.MigrationConsent = $ui.MigrationConsent.IsChecked -eq $true
    foreach ($role in @('manager','researcher','analyst','auditor')) {
        $row = $script:policyRows[$role]
        $options.Roles[$role].ReadWorkspace = $row.ReadWorkspace.IsChecked -eq $true
        foreach ($key in $row.Limits.Keys) {
            $amount = 0
            if (-not [int]::TryParse($row.Limits[$key].Text.Trim(),[ref]$amount)) { throw ($role + ': 실행 한도에는 정수를 입력하세요.') }
            $options.Roles[$role].Limits[$key] = $amount
        }
    }
    return (Assert-HermesResearchWizardOptions -Options $options -RuntimeRoot $script:paths.RuntimeRoot)
}

function Test-ResearchWorkflowEvidence {
    param($Result)
    if ($null -eq $Result -or -not $Result.PSObject.Properties['ExecutionReady'] -or $Result.ExecutionReady -ne $true -or -not $Result.PSObject.Properties['WorkflowTest']) { return $false }
    $test = $Result.WorkflowTest
    if ($null -eq $test) { return $false }
    foreach ($key in @('Passed','Live','AuditPassed','RequestID','Roles','EvidencePath')) { if (-not $test.PSObject.Properties[$key]) { return $false } }
    if ($test.Passed -ne $true -or $test.Live -ne $true -or $test.AuditPassed -ne $true -or [string]::IsNullOrWhiteSpace([string]$test.RequestID) -or [string]::IsNullOrWhiteSpace([string]$test.EvidencePath)) { return $false }
    $roles = @($test.Roles | Sort-Object -Unique)
    return ($roles.Count -eq 4 -and ($roles -join ',') -ceq 'analyst,auditor,manager,researcher')
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

function Get-ResearchSavedConnections {
    param($State, $Service)
    $null = Get-ResearchSavedPreferences $State
    if (-not $State.PSObject.Properties['ExecutionMode'] -or $State.ExecutionMode -cne 'GovernedBroker' -or $Service.schema_version -ne 1 -or
        $Service.server_url -cne $State.ServerURL -or $Service.channel_id -cne $State.HomeChannelID) { throw '저장된 비공개 연결과 연구팀 기록이 일치하지 않습니다.' }
    foreach ($pair in @(@('hermes_home','HermesHome'),@('install_dir','InstallDir'))) {
        if ([IO.Path]::GetFullPath([string]$Service.($pair[0])) -ine [IO.Path]::GetFullPath([string]$State.($pair[1]))) { throw '저장된 봇 연결의 Hermes 경로가 다릅니다.' }
    }
    if ([IO.Path]::GetFullPath([string]$Service.python) -ine [IO.Path]::GetFullPath((Join-Path $State.InstallDir 'venv\Scripts\python.exe'))) { throw '저장된 봇 연결의 Python 경로가 다릅니다.' }
    if ($Service.messaging.reply_in_thread -ne $true -or $Service.messaging.bot_replies_require_mention -ne $true -or
        @($Service.messaging.bot_observers).Count -ne 1 -or $Service.messaging.bot_observers[0] -cne 'manager') { throw '저장된 봇 응답 정책이 연구팀 정책과 다릅니다.' }
    $canonicalRoles = @('manager','researcher','analyst','auditor')
    if (@($Service.bots.PSObject.Properties).Count -ne 4 -or @($Service.bots.PSObject.Properties.Name | Where-Object { $canonicalRoles -cnotcontains $_ }).Count -ne 0) { throw '저장된 봇 연결은 네 역할과 정확히 일치해야 합니다.' }
    $manifest = Get-HermesResearchPersonaManifest
    $tokens = @{}; $seenTokens = @(); $seenUsers = @(); $seenNames = @()
    foreach ($persona in $manifest.Personas) {
        $profiles = @($State.Profiles | Where-Object { $_.RoleId -ceq $persona.LegacyRoleId })
        if ($profiles.Count -ne 1) { throw '저장된 봇 역할이 중복되거나 누락됐습니다.' }
        $profile = $profiles[0]
        $bot = $Service.bots.([string]$persona.CanonicalName)
        if (($profile.PSObject.Properties['CanonicalRole'] -and $profile.CanonicalRole -cne $persona.CanonicalName) -or
            [string]$bot.user_id -cnotmatch '^[a-z0-9]{26}$' -or $bot.user_id -cne $profile.BotUserID -or
            [string]$bot.token -cnotmatch '^[a-z0-9]{26}$' -or [string]$bot.username -cnotmatch '^[a-z0-9][a-z0-9._-]{1,63}$' -or
            $seenTokens -ccontains $bot.token -or $seenUsers -ccontains $bot.user_id -or $seenNames -ccontains $bot.username) { throw '저장된 봇의 역할·계정·인증 연결이 일치하지 않습니다.' }
        $seenTokens += $bot.token; $seenUsers += $bot.user_id; $seenNames += $bot.username
        $tokens[[string]$profile.ProfileName] = [string]$bot.token
    }
    return $tokens
}

function Read-ResearchSavedTeam {
    param([switch]$OnlyIfUnedited)
    if ($OnlyIfUnedited -and $script:teamInputsEdited) { return }
    $path = Join-Path $script:paths.RuntimeRoot 'research\team.json'
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $path).Length -gt 262144) { throw '저장된 연구팀 기록의 크기가 올바르지 않습니다.' }
    $savedState = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $preferences = Get-ResearchSavedPreferences $savedState
    $key = $path + '|' + $script:paths.HermesHome + '|' + $script:paths.InstallDir + '|' + $savedState.TeamID
    if ($OnlyIfUnedited -and $script:lastLoadedTeamKey -ceq $key) { return }
    $options = $null
    if ($savedState.PSObject.Properties['WizardOptions'] -and $null -ne $savedState.WizardOptions) { $options = Assert-HermesResearchWizardOptions -Options $savedState.WizardOptions -RuntimeRoot $script:paths.RuntimeRoot }
    $tokens = @{}
    $privatePath = Join-Path $script:paths.RuntimeRoot 'research\private.json'
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $privatePath
    if (Test-Path -LiteralPath $privatePath -PathType Leaf) {
        if ((Get-Item -LiteralPath $privatePath).Length -gt 262144) { throw '저장된 비공개 연결 파일의 크기가 올바르지 않습니다.' }
        $service = $null
        try {
            $service = [IO.File]::ReadAllText($privatePath,[Text.Encoding]::UTF8) | ConvertFrom-Json
            $tokens = Get-ResearchSavedConnections -State $savedState -Service $service
        } finally { $service = $null }
    }
    # Commit to the form only after every public/private binding validates.
    $script:restoringTeam = $true
    try {
        if ($null -ne $options) { Set-ResearchWizardOptions -Options $options }
        foreach ($agent in $script:agents) {
            $saved = @($preferences.Agents | Where-Object ProfileName -CEQ $agent.ProfileName)[0]
            $agent.Name.Text = [string]$saved.DisplayName; $agent.Role.SelectedValue = [string]$saved.RoleId
            if ($tokens.ContainsKey([string]$agent.ProfileName)) { $agent.Token.Password = $tokens[[string]$agent.ProfileName] }
        }
        $script:preferredModel = [string]$preferences.ModelName
        if ($ui.ModelCombo.Items.Contains($script:preferredModel)) { $ui.ModelCombo.SelectedItem = $script:preferredModel }
        $ui.TeamResumeCheck.IsChecked = $true; $script:lastLoadedTeamKey = $key
    } finally { $tokens.Clear(); $script:restoringTeam = $false }
    if (Test-Path -LiteralPath $privatePath -PathType Leaf) { Add-ResearchLog '저장된 네 봇 연결·이름·역할·모델을 복원했습니다. 토큰은 가려진 입력란에만 넣었으며 설치 시 서버에서 다시 검증합니다.' }
    else { Add-ResearchLog '이전에 저장한 이름·역할·모델을 불러왔습니다. 이전 형식은 토큰을 입력하거나 같은 봇의 발급 기록을 불러오세요.' }
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
    $wasRestoring = $script:restoringTeam
    $script:restoringTeam = $true
    try { $ui.HumanUsername.Text = [string]$state.Identity.AdminUsername } finally { $script:restoringTeam = $wasRestoring }
    $script:serverReady = $true; $ui.ServerResumeCheck.IsChecked = $true
    $ui.ServerStatus.Text = "연구실 주소: $($script:serverURL)`n팀·채널 준비 기록을 불러왔습니다. 연구팀 연결 시 각 봇과 채널 접근을 다시 확인합니다."
    try { Read-ResearchSavedTeam -OnlyIfUnedited } catch { Add-ResearchLog '기존 연구팀 배정을 불러오지 못했습니다. 같은 연구실·Windows 사용자·설치 경로인지 확인하세요. 기존 기록은 변경하지 않았습니다.' }
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
    if ($script:useExistingHermes -and $Action -cin @('Plan','Install','CodexAuth')) { throw '기존 Hermes 사용 모드에서는 설치·업데이트·새 로그인을 실행하지 않습니다.' }
    if ($script:useExistingHermes -and $Action -cin @('CodexStatus','ResearchTeamSetup')) {
        if ([string]::IsNullOrWhiteSpace($ui.ExistingHermesHome.Text) -or [string]::IsNullOrWhiteSpace($ui.ExistingHermesInstallDir.Text)) { throw '기존 Hermes 데이터 폴더와 코드 폴더를 모두 확인하세요.' }
        $script:paths = Get-HermesDefaultPaths -HermesHome $ui.ExistingHermesHome.Text.Trim() -InstallDir $ui.ExistingHermesInstallDir.Text.Trim() -RuntimeRoot $script:defaultPaths.RuntimeRoot
        $ExtraArguments = @($ExtraArguments) + @('-UseExistingHermes')
    }
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
    if (-not $previous -and $Status.PSObject.Properties['PreferredModel']) { $previous = [string]$Status.PreferredModel }
    if ($Status.PSObject.Properties['RuntimeKind'] -and $Status.RuntimeKind -ceq 'Existing') {
        $ui.ExistingHermesStatus.Text = "기존 설치 사용: $($Status.Version)`n코드: $($script:paths.InstallDir)`n데이터·인증·기존 프로필 유지 / 재설치 없음"
    }
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
            if ($success) {
                Set-ResearchAuthStatus $result
                try { Read-ResearchSavedTeam -OnlyIfUnedited } catch { Add-ResearchLog '선택한 Hermes에서 기존 연구팀 연결을 복원하지 못했습니다. 입력 중인 값은 유지했습니다. 같은 연구실·설치 경로인지 확인하세요.' }
            }
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
            if ($success -and [bool]$result.Succeeded) {
                $ui.PolicyJson.Text = (Get-HermesResearchPolicy -RuntimeRoot $script:paths.RuntimeRoot | ConvertTo-Json -Depth 15)
                if (Test-ResearchWorkflowEvidence $result) {
                    $ui.TeamResult.Text = "사용 준비 완료 — 실제 네 역할 작업·결과·감사 통과 기록 확인`n" + $ui.TeamResult.Text + "`n검증 기록: " + [string]$result.WorkflowTest.EvidencePath
                    Add-ResearchLog ('실제 자동 분업 테스트를 통과했습니다. 연구 채널에서 관리 봇을 @멘션하여 보고서를 요청하세요. 테스트 요청: ' + [string]$result.WorkflowTest.RequestID)
                } else {
                    $reason = $(if ($result.PSObject.Properties['PendingSettings']) { @($result.PendingSettings) -join ', ' } else { '네 역할의 실제 작업·감사 통과 증거가 확인되지 않음' })
                    if ($result.PSObject.Properties['WorkflowTest'] -and $null -ne $result.WorkflowTest -and $result.WorkflowTest.PSObject.Properties['ErrorCode']) { $reason += ' ' + [string]$result.WorkflowTest.ErrorCode }
                    $ui.TeamResult.Text = "사용 준비 미완료 — 연결·설정만으로 완료 처리하지 않습니다.`n" + $ui.TeamResult.Text
                    Add-ResearchLog ('실제 분업 테스트를 완료하지 못했습니다. 확인 후 같은 연구팀으로 다시 시도하세요. ' + $reason)
                }
            }
            else {
                $reason = ''
                if ($null -ne $result -and $result.PSObject.Properties['PendingSettings']) { $reason = @($result.PendingSettings) -join ', ' }
                if ($null -ne $result -and $result.PSObject.Properties['WorkflowTest'] -and $null -ne $result.WorkflowTest -and $result.WorkflowTest.PSObject.Properties['ErrorCode']) { $reason += ' ' + [string]$result.WorkflowTest.ErrorCode }
                $ui.TeamResult.Text = "사용 준비 미완료 — 실제 분업 검증을 통과하지 못했습니다.`n" + $ui.TeamResult.Text + "`n" + $reason.Trim()
                Add-ResearchLog ('연구팀의 연결·설정 또는 실제 분업 테스트를 완료하지 못했습니다. 같은 연구팀으로 다시 시도하세요. ' + $reason.Trim())
            }
        }
    }
    if (-not $success -and -not $script:workerFailed) { Add-ResearchLog '작업의 완료 결과를 확인하지 못했습니다. 일부 설정이 적용됐을 수 있으므로 상태를 다시 확인한 뒤 재시도하세요.' }
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
Add-ResearchPolicyRows
Set-ResearchWizardOptions -Options (New-HermesResearchWizardOptions)
foreach ($agent in $script:agents) {
    $agent.Name.Add_TextChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } })
    $agent.Role.Add_SelectionChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } })
    $agent.Token.Add_PasswordChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } })
}
foreach ($control in @('WorkspacePath','HumanUsername')) { $ui[$control].Add_TextChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } }) }
foreach ($row in $script:policyRows.Values) {
    foreach ($box in $row.Limits.Values) { $box.Add_TextChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } }) }
    $row.ReadWorkspace.Add_Click({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } })
}
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
$ui.PersonaResetButton.Add_Click({
    if ($script:busy) { return }
    $script:roles = @(Get-HermesResearchRoles)
    Refresh-ResearchRoles
    Add-ResearchLog '제공된 관리·조사·분석·감사 TXT 전체를 불러왔습니다. 연구팀 생성·재설정으로 적용하세요.'
})
$ui.PolicyLoadButton.Add_Click({ try { if (-not $script:busy) { $ui.PolicyJson.Text = (Get-HermesResearchPolicy -RuntimeRoot $script:paths.RuntimeRoot | ConvertTo-Json -Depth 15) } } catch { Add-ResearchLog $_.Exception.Message } })
$ui.PolicySaveButton.Add_Click({
    try {
        if ($script:busy) { return }
        $ui.PolicyJson.Text = (Get-ResearchWizardOptions | ConvertTo-Json -Depth 15)
        Add-ResearchLog '현재 설치 선택을 표시했습니다. 연구팀 설치 시 실제 사용자 ID·모델·경로와 연결하여 저장합니다.'
    } catch { Add-ResearchLog $_.Exception.Message }
})
$ui.PolicyDefaultsButton.Add_Click({ if (-not $script:busy) { Set-ResearchWizardOptions -Options (New-HermesResearchWizardOptions) -LimitsOnly } })
$ui.WorkspaceBrowseButton.Add_Click({
    try {
        if ($script:busy) { return }
        Add-Type -AssemblyName System.Windows.Forms
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description = '연구용 작업 폴더를 선택하세요. 입력 자료는 하위 inputs 폴더에서 읽습니다.'
            $picker.SelectedPath = $ui.WorkspacePath.Text
            if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $ui.WorkspacePath.Text = $picker.SelectedPath }
        } finally { $picker.Dispose() }
    } catch { Add-ResearchLog $_.Exception.Message }
})
$ui.RoleSaveButton.Add_Click({
    try {
        $selected = $ui.RoleEditorCombo.SelectedItem
        if ($null -eq $selected -or $script:busy) { return }
        $id = [string]$selected.Id
        $changed = @($script:roles | ForEach-Object {
            if ([string]$_.Id -ceq $id) { [pscustomobject]@{ Id = $id; Name = $ui.RoleName.Text.Trim(); Instructions = $ui.RoleInstructions.Text } } else { $_ }
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
foreach ($name in @('ServerConsent','HermesConsent','TeamConsent','DockerInstallConsent','ModelEgressConsent','PublicWebConsent')) {
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
function Reset-ResearchHermesSelection {
    $script:hermesReady = $false; $script:authenticated = $false; $script:plan = $null
    $script:preferredModel = $null
    $script:authURL = $null; $ui.AuthCode.Clear(); $ui.ModelCombo.Items.Clear()
    $ui.HermesConsent.IsChecked = $false; $ui.HermesPlanText.Clear()
    $ui.AuthStatus.Text = '선택한 경로에서 기존 Hermes·인증을 다시 확인하세요.'
    $ui.TeamConsent.IsChecked = $false
    Refresh-ResearchButtons
}
$ui.UseExistingHermesCheck.Add_Checked({ $script:useExistingHermes = $true; Reset-ResearchHermesSelection })
$ui.UseExistingHermesCheck.Add_Unchecked({ $script:useExistingHermes = $false; $script:paths = $script:defaultPaths; Reset-ResearchHermesSelection })
foreach ($name in @('ExistingHermesHome','ExistingHermesInstallDir')) {
    $ui[$name].Add_TextChanged({ if ($script:useExistingHermes -and -not $script:busy) { Reset-ResearchHermesSelection } })
}
$ui.HermesPlanButton.Add_Click({
    try { $script:plan = $null; $ui.HermesConsent.IsChecked = $false; Start-ResearchWorker 'Plan' @('-SkipComputerUse','-SetupMode','Later') }
    catch { Add-ResearchLog $_.Exception.Message }
})
$ui.HermesInstallButton.Add_Click({
    try {
        if ($script:busy -or $script:useExistingHermes -or $null -eq $script:plan -or $ui.HermesConsent.IsChecked -ne $true) { return }
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
            WizardOptions = (Get-ResearchWizardOptions)
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
$script:teamInputsEdited = $false
if ($SmokeTest) {
    if ($script:agents.Count -ne 4 -or $ui.ServerCreateButton.IsEnabled -or $ui.HermesInstallButton.IsEnabled -or $ui.TeamApplyButton.IsEnabled) { throw '연구실 기본 동작이 안전하지 않습니다.' }
    if ($ui.HermesTab.IsEnabled -or $ui.TeamTab.IsEnabled -or $ui.ServerConsent.IsChecked -or $ui.TeamConsent.IsChecked) { throw '준비되지 않은 연구실 단계가 활성화됐습니다.' }
    if ($script:policyRows.Count -ne 4 -or [string]::IsNullOrWhiteSpace($ui.WorkspacePath.Text) -or -not $ui.PolicyJson.IsReadOnly) { throw 'JSON 없이 설정할 네 역할의 기본 선택이 준비되지 않았습니다.' }
    if ($ui.ModelEgressConsent.IsChecked -or $ui.PublicWebConsent.IsChecked -or $ui.MigrationConsent.IsChecked) { throw '모델·웹·기존 연결 전환 동의가 미리 선택됐습니다.' }
    if (Test-ResearchWorkflowEvidence ([pscustomobject]@{ExecutionReady=$true})) { throw '연결 준비만으로 실제 분업 테스트가 통과됐습니다.' }
    $workflowFixture = [pscustomobject]@{ ExecutionReady = $true; WorkflowTest = [pscustomobject]@{Passed=$true;Live=$true;AuditPassed=$true;RequestID='fixture-request';EvidencePath='fixture-evidence';Roles=@('manager','researcher','analyst','auditor')} }
    if (-not (Test-ResearchWorkflowEvidence $workflowFixture)) { throw '네 역할의 실제 테스트 증거가 준비 상태로 연결되지 않습니다.' }
    $workflowFixture.WorkflowTest.Live = $false
    if (Test-ResearchWorkflowEvidence $workflowFixture) { throw '모의 테스트를 실제 분업 검증으로 표시했습니다.' }
    $workflowFixture.WorkflowTest.Live = $true; $workflowFixture.WorkflowTest.Roles = @('manager','researcher','analyst')
    if (Test-ResearchWorkflowEvidence $workflowFixture) { throw '감사 역할이 누락된 테스트를 완료로 표시했습니다.' }
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
    $resumeFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-gui-resume-' + [guid]::NewGuid().ToString('N'))
    $priorPaths = $script:paths
    $priorKey = $script:lastLoadedTeamKey
    $priorEdited = $script:teamInputsEdited
    $formBefore = @($script:agents | ForEach-Object { @{Name=$_.Name.Text;Role=[string]$_.Role.SelectedValue;Token=$_.Token.Password} })
    try {
        $script:paths = [pscustomobject]@{ RuntimeRoot=(Join-Path $resumeFixtureRoot 'runtime');HermesHome=(Join-Path $resumeFixtureRoot 'home');InstallDir=(Join-Path $resumeFixtureRoot 'home\hermes-agent') }
        $fixtureState = ($saved | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        foreach ($key in @('RuntimeRoot','HermesHome','InstallDir')) { $fixtureState.$key = $script:paths.$key }
        $fixtureState | Add-Member NoteProperty ExecutionMode 'GovernedBroker'
        $fixtureBots = [ordered]@{}
        $fixtureIndex = 0
        foreach ($persona in (Get-HermesResearchPersonaManifest).Personas) {
            $fixtureIndex++
            $profile = @($fixtureState.Profiles | Where-Object { $_.RoleId -ceq $persona.LegacyRoleId })[0]
            $userID = 'u' + (([string][char](96 + $fixtureIndex)) * 25)
            $profile | Add-Member NoteProperty BotUserID $userID
            $profile | Add-Member NoteProperty CanonicalRole ([string]$persona.CanonicalName)
            $fixtureBots[$persona.CanonicalName] = @{token=(([string][char](96 + $fixtureIndex)) * 26);user_id=$userID;username=('fixture_'+$persona.CanonicalName);display_name=$profile.DisplayName}
        }
        $fixtureService = (@{schema_version=1;hermes_home=$script:paths.HermesHome;install_dir=$script:paths.InstallDir;python=(Join-Path $script:paths.InstallDir 'venv\Scripts\python.exe');server_url=$script:serverURL;channel_id=$ui.HomeChannelID.Text;bots=$fixtureBots;messaging=@{reply_in_thread=$true;bot_replies_require_mention=$true;bot_observers=@('manager')}} | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        $restored = Get-ResearchSavedConnections -State $fixtureState -Service $fixtureService
        if ($restored.Count -ne 4 -or $restored['research-reviewer'] -cne ('a' * 26)) { throw '교환된 관리 역할의 계정 토큰이 실제 프로필에 매핑되지 않습니다.' }
        $fixtureService.bots.manager.user_id = 'z' * 26
        $rejected = $false; try { $null = Get-ResearchSavedConnections -State $fixtureState -Service $fixtureService } catch { $rejected = $true }
        if (-not $rejected) { throw '다른 봇 계정의 비공개 연결을 복원했습니다.' }
        $fixtureService.bots.manager.user_id = 'u' + ('a' * 25)
        $researchRoot = Join-Path $script:paths.RuntimeRoot 'research'
        New-Item -ItemType Directory -Path $researchRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $researchRoot 'team.json'),($fixtureState | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $researchRoot 'private.json'),($fixtureService | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
        $script:teamInputsEdited = $false; $script:lastLoadedTeamKey = $null
        Read-ResearchSavedTeam -OnlyIfUnedited
        if (@($script:agents | Where-Object { $_.Token.Password.Length -ne 26 }).Count -ne 0 -or $ui.Log.Text.Contains('a' * 26)) { throw '복원된 비공개 토큰이 비어 있거나 안내에 노출됐습니다.' }
        $script:agents[0].Name.Text = '사용자가 입력 중인 값'
        if (-not $script:teamInputsEdited) { throw '연구팀 입력 편집이 추적되지 않습니다.' }
        Read-ResearchSavedTeam -OnlyIfUnedited
        if ($script:agents[0].Name.Text -cne '사용자가 입력 중인 값') { throw '상태 새로고침이 입력 중인 이름을 덮어썼습니다.' }
        $fixtureService.channel_id = 'x' * 26
        [IO.File]::WriteAllText((Join-Path $researchRoot 'private.json'),($fixtureService | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Read-ResearchSavedTeam } catch { $rejected = $true }
        if (-not $rejected -or $script:agents[0].Name.Text -cne '사용자가 입력 중인 값') { throw '다른 채널의 연결이 입력란을 변경했습니다.' }
    } finally {
        $script:paths = $priorPaths; $script:lastLoadedTeamKey = $priorKey
        $script:restoringTeam = $true
        for ($index = 0; $index -lt 4; $index++) { $script:agents[$index].Name.Text=$formBefore[$index].Name; $script:agents[$index].Role.SelectedValue=$formBefore[$index].Role; $script:agents[$index].Token.Password=$formBefore[$index].Token }
        $script:restoringTeam = $false; $script:teamInputsEdited = $priorEdited
        $resolvedFixture = [IO.Path]::GetFullPath($resumeFixtureRoot)
        $fixturePrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-gui-resume-'
        if ($resolvedFixture.StartsWith($fixturePrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixture)) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
    }
    $saved.OwnerSID = 'S-1-5-18'; $rejected = $false
    try { $null = Get-ResearchSavedPreferences $saved } catch { $rejected = $true }
    if (-not $rejected) { throw '다른 사용자의 연구팀 배정을 불러왔습니다.' }
    $script:serverReady = $true; $script:hermesReady = $true; $script:authenticated = $true
    [void]$ui.ModelCombo.Items.Add('mock-model'); $ui.ModelCombo.SelectedIndex = 0
    Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled -or -not $ui.TeamTab.IsEnabled) { throw '모델 인증이 생성 동의를 우회했습니다.' }
    $ui.TeamConsent.IsChecked = $true; Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled) { throw '모델·웹 전송 선택 없이 자동 분업 설치가 활성화됐습니다.' }
    $ui.ModelEgressConsent.IsChecked = $true; $ui.PublicWebConsent.IsChecked = $true; Refresh-ResearchButtons
    if (-not $ui.TeamApplyButton.IsEnabled) { throw '연구팀 생성 조건이 충족돼도 버튼이 활성화되지 않습니다.' }
    $formOptions = Get-ResearchWizardOptions
    if ($formOptions.Roles.researcher.Limits.revisions -ne 2 -or $formOptions.WorkspacePath -cne $ui.WorkspacePath.Text) { throw '화면 선택이 설치 정책 입력으로 전달되지 않습니다.' }
    $script:busy = $true; Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled -or $ui.CloseButton.IsEnabled -or @($script:agents | Where-Object { $_.Token.IsEnabled }).Count -ne 0) { throw '작업 중 입력과 닫기가 차단되지 않습니다.' }
    $script:busy = $false; Refresh-ResearchButtons
    $ui.UseExistingHermesCheck.IsChecked = $true
    if ($ui.TeamConsent.Content -isnot [Windows.Controls.TextBlock] -or -not $ui.TeamConsent.Content.Text.Contains('실제 모델')) { throw '기존 Hermes 선택이 실제 분업 테스트 동의 문구를 제거했습니다.' }
    $script:plan = [pscustomobject]@{ Fingerprint = 'fixture' }
    $ui.HermesConsent.IsChecked = $true
    Set-ResearchAuthStatus ([pscustomobject]@{ LoggedIn = $true; Models = @('original-model','other-model'); PreferredModel = 'original-model'; Summary = 'fixture existing credentials'; RuntimeKind = 'Existing'; Version = 'fixture version' })
    Refresh-ResearchButtons
    if ($ui.HermesPlanButton.IsEnabled -or $ui.HermesInstallButton.IsEnabled -or $ui.AuthButton.IsEnabled -or [string]$ui.ModelCombo.SelectedItem -cne 'original-model') { throw '기존 Hermes 모드가 재설치·새 로그인을 허용하거나 기존 모델 선택을 잃었습니다.' }
    $originalHomeText = $ui.ExistingHermesHome.Text
    $script:preferredModel = 'other-model'
    $ui.ExistingHermesHome.Text = $originalHomeText + '-changed'
    if ($script:authenticated -or $ui.HermesNextButton.IsEnabled -or $ui.TeamApplyButton.IsEnabled -or $null -ne $script:preferredModel) { throw '경로 변경이 이전 인증·모델 선택을 재사용했습니다.' }
    $ui.ExistingHermesHome.Text = $originalHomeText
    $ui.UseExistingHermesCheck.IsChecked = $false
    Refresh-ResearchButtons
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
        if ($PreviewStep -ceq 'Hermes') {
            $ui.UseExistingHermesCheck.IsChecked = $true
            Set-ResearchAuthStatus ([pscustomobject]@{ LoggedIn = $true; Models = @('existing-model'); PreferredModel = 'existing-model'; Summary = '미리보기: 기존 Hermes와 저장된 인증 발견 — 기존 파일 변경 없음'; RuntimeKind = 'Existing'; Version = 'Hermes existing source (commit example)' })
            Refresh-ResearchButtons
        }
        $ui.WizardTabs.SelectedIndex = $(switch ($PreviewStep) { 'Server' { 0 } 'Hermes' { 1 } default { 2 } })
        $window.Show(); $window.UpdateLayout()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Open([IO.Path]::GetFullPath($PreviewPath),[IO.FileMode]::CreateNew)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    Write-Host 'PASS local research WPF: Docker/model/web consent, JSON-free policy, live evidence gate, private-token resume bindings and edit preservation, failed-worker cleanup'
    $window.Close(); exit 0
}
$window.Add_ContentRendered({
    if (-not $script:busy -and -not $script:initialDockerCheck) {
        $script:initialDockerCheck = $true
        try { Start-ResearchWorker 'DockerStatus' } catch { Add-ResearchLog $_.Exception.Message }
    }
})
$window.ShowDialog() | Out-Null
