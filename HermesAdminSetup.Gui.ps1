[CmdletBinding()]
param([switch]$SmokeTest,[switch]$ProbeDocker)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start-HermesAdminSetup.cmd로 실행하세요.' }
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$reader = New-Object Xml.XmlNodeReader ([xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ui\AdminWindow.xaml')))
$window = [Windows.Markup.XamlReader]::Load($reader)
$reader.Close()
$ui = @{}
foreach ($name in @('CheckButton','DockerButton','DockerStatus','FormPanel','ServerId','SiteName','TeamName','TeamDisplayName','ChannelName','Port','AdminUsername','AdminEmail','AdminPassword','PasswordConfirm','StorageNote','ResumeCheck','BotControlCheck','BotControlButton','ConsentCheck','Progress','Log','OpenButton','ConsoleButton','CreateButton','CloseButton','BotPanel','BotUsername','BotDisplayName','BotDescription','BotAdminPassword','BotConsentCheck','BotCreateButton','BotResult','CopyBotTokenButton','CopyChannelButton')) {
    $ui[$name] = $window.FindName($name)
    if (-not $ui[$name]) { throw "Missing control: $name" }
}
$script:busy = $false
foreach ($name in @('NetworkMode','NetworkAddress')) { $ui[$name] = $window.FindName($name); if (-not $ui[$name]) { throw "Missing control: $name" } }
$ui.NetworkAddress.Text = [string](Get-HermesNetBirdIPv4)
$script:dockerReady = $false
$script:worker = $null
$script:pendingLine = $null
$script:stderr = $null
$script:eof = $false
$script:workerAction = ''
$script:inputPath = $null
$script:result = $null
$script:botResult = $null
$script:copiedToken = $null
$script:cliFailed = $false
$script:preflightResult = $null
$runtimeRoot = (Get-HermesDefaultPaths).RuntimeRoot
$ui.StorageNote.Text = '설치 기록: ' + (Get-HermesAdminRoot) + '\<서버 ID>  |  관리자 암호는 평문 파일·명령줄·로그에 저장하지 않습니다.'

function Update-Buttons {
    $ui.CheckButton.IsEnabled = -not $script:busy
    $ui.DockerButton.IsEnabled = -not $script:busy
    $ui.FormPanel.IsEnabled = -not $script:busy
    $ui.CreateButton.IsEnabled = -not $script:busy -and $script:dockerReady -and $ui.ConsentCheck.IsChecked -eq $true
    $ui.CloseButton.IsEnabled = -not $script:busy
    $ui.OpenButton.IsEnabled = -not $script:busy -and $null -ne $script:result
    $ui.ConsoleButton.IsEnabled = $ui.OpenButton.IsEnabled
    $ui.BotControlButton.IsEnabled = $ui.OpenButton.IsEnabled -and $script:result.BotControlReady
    $ui.BotPanel.IsEnabled = -not $script:busy
    $ui.BotCreateButton.IsEnabled = -not $script:busy -and $script:dockerReady -and $ui.BotConsentCheck.IsChecked -eq $true
    $ui.CopyBotTokenButton.IsEnabled = -not $script:busy -and $null -ne $script:botResult
    $ui.CopyChannelButton.IsEnabled = $ui.CopyBotTokenButton.IsEnabled
}
function Add-Log { param([string]$Message) $ui.Log.AppendText($Message + [Environment]::NewLine); $ui.Log.ScrollToEnd() }
function Read-WorkerLine {
    param([string]$Line)
    if (-not $Line) { return }
    try { $event = $Line | ConvertFrom-Json } catch { return }
    if ($event.PSObject.Properties['type']) {
        if ($event.PSObject.Properties['message']) { Add-Log ([string]$event.message) }
        if ($event.PSObject.Properties['percent']) { $ui.Progress.Value = [double]$event.percent }
        if ($event.type -eq 'error') { $script:cliFailed = $true }
        if ($event.type -eq 'complete') {
            if ($script:workerAction -eq 'AdminBotSetup') { $script:botResult = $event.data }
            else { $script:result = $event.data }
        }
    } elseif ($script:workerAction -eq 'AdminPreflight' -and $event.PSObject.Properties['Ready']) { $script:preflightResult = $event }
}
function Start-Worker {
    param([string]$Action,[string[]]$ExtraArguments = @())
    if ($script:busy) { return }
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'HermesEasySetup.ps1'),'-Action',$Action,'-JsonEvents') + $ExtraArguments
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Get-HermesPowerShellExecutable
    $start.Arguments = (($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument $_ }) -join ' ')
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $script:worker = New-Object Diagnostics.Process
    $script:worker.StartInfo = $start
    $script:workerAction = $Action
    $script:cliFailed = $false
    $script:eof = $false
    $script:preflightResult = $null
    if ($Action -eq 'AdminSetup') { $script:result = $null }
    $script:botResult = $null
    $ui.BotResult.Text = '발급 결과 확인 중이거나 아직 발급 전입니다.'
    $ui.Progress.Value = 0
    if (-not $script:worker.Start()) { throw '설치 작업을 시작하지 못했습니다.' }
    $script:stderr = $script:worker.StandardError.ReadToEndAsync()
    $script:pendingLine = $script:worker.StandardOutput.ReadLineAsync()
    $script:busy = $true
    Update-Buttons
    $timer.Start()
}
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    try {
        while (-not $script:eof -and $script:pendingLine.IsCompleted) {
            $line = $script:pendingLine.GetAwaiter().GetResult()
            if ($null -eq $line) { $script:eof = $true; break }
            Read-WorkerLine $line
            $script:pendingLine = $script:worker.StandardOutput.ReadLineAsync()
        }
        if (-not $script:worker.HasExited -or -not $script:eof) { return }
        $timer.Stop()
        $success = $script:worker.ExitCode -eq 0 -and -not $script:cliFailed
        if ($script:workerAction -eq 'AdminPreflight') {
            $script:dockerReady = $success -and $null -ne $script:preflightResult -and $script:preflightResult.Ready
            $ui.DockerStatus.Text = $(if ($script:dockerReady) { '준비 완료: 로컬 Docker Desktop / Linux AMD64' } else { 'Docker가 준비되지 않았습니다. 아래 오류를 확인하고 다시 검사하세요.' })
        } elseif ($script:workerAction -eq 'AdminBotSetup') {
            if ($success -and $script:botResult) {
                $ui.BotResult.Text = "봇: $($script:botResult.BotDisplayName) (@$($script:botResult.BotUsername))`n서버: $($script:botResult.ServerURL)`nHome Channel ID: $($script:botResult.HomeChannelId)`n토큰: 암호화 보관 완료 · 아래 버튼으로 복사"
                Add-Log '봇 발급 결과를 아래에서 복사하세요. Hermes 실행·연결은 사용자용 마법사에서 진행합니다.'
            } else { $script:botResult = $null; $ui.BotResult.Text = '완료하지 못했습니다. 위 오류를 확인하고 동일한 입력으로 재시도하세요.' }
        } elseif ($success -and $script:result) {
            Add-Log ('접속 주소: ' + $script:result.ServerURL + '  /  관리자: ' + $script:result.AdminUsername)
            Add-Log '브라우저에서 직접 로그인하세요. 재설치가 아닌 이어서 설정에는 동일한 입력과 비밀번호가 필요합니다.'
            Add-Log ('공개 범위: ' + $script:result.Scope + ' / 다른 PC 접속은 아직 미검증')
            $ui.ResumeCheck.IsChecked = $true
        } else {
            $script:result = $null
            Add-Log '설정을 완료하지 못했습니다. 데이터는 보존합니다. 오류를 해결하고 같은 입력·비밀번호로 이어서 설정하세요.'
            $ui.ResumeCheck.IsChecked = $true
        }
        if (-not $success -and -not $script:cliFailed) { Add-Log '작업 프로세스가 예기치 않게 종료되었습니다. 마법사를 다시 열어 준비 상태를 확인하세요.' }
        # Never echo raw worker stderr: PowerShell errors may include source lines with user data.
        $script:worker.Dispose(); $script:worker = $null; $script:busy = $false
        if ($script:inputPath -and (Test-Path -LiteralPath $script:inputPath)) { Remove-Item -LiteralPath $script:inputPath -Force }
        $script:inputPath = $null
        Update-Buttons
    } catch {
        if (-not $script:cliFailed) { Add-Log '진행 표시를 읽지 못했습니다. 작업 종료를 기다린 뒤 같은 입력으로 이어서 설정하세요.' }
        $script:cliFailed = $true
        $script:eof = $true
        # Keep polling the tracked worker rather than freezing the UI or killing a deployment mid-write.
        if ($null -eq $script:worker) { $timer.Stop(); $script:busy = $false; Update-Buttons }
    }
})
$ui.ConsentCheck.Add_Checked({ Update-Buttons })
$ui.ConsentCheck.Add_Unchecked({ Update-Buttons })
$ui.BotConsentCheck.Add_Checked({ Update-Buttons })
$ui.BotConsentCheck.Add_Unchecked({ Update-Buttons })
$ui.CheckButton.Add_Click({ try { Add-Log 'Docker 준비 상태 확인 중…'; Start-Worker 'AdminPreflight' } catch { Add-Log $_.Exception.Message; Update-Buttons } })
$ui.DockerButton.Add_Click({
    try {
        Open-HermesDockerDesktop | Out-Null
        Add-Log 'Docker Desktop을 열었습니다. Linux 엔진이 준비되면 준비 확인을 누르세요.'
    } catch { Add-Log 'Docker Desktop을 열지 못했습니다. 시작 메뉴에서 직접 실행하세요.' }
})
$ui.CreateButton.Add_Click({
    try {
        if ($script:busy -or -not $script:dockerReady -or $ui.ConsentCheck.IsChecked -ne $true) { return }
        if ($ui.AdminPassword.Password -cne $ui.PasswordConfirm.Password) { throw '비밀번호 확인이 일치하지 않습니다.' }
        $data = [pscustomobject]@{ ServerId = $ui.ServerId.Text.Trim(); SiteName = $ui.SiteName.Text.Trim(); TeamName = $ui.TeamName.Text.Trim(); TeamDisplayName = $ui.TeamDisplayName.Text.Trim(); ChannelName = $ui.ChannelName.Text.Trim(); Port = $ui.Port.Text.Trim(); AdminUsername = $ui.AdminUsername.Text.Trim(); AdminEmail = $ui.AdminEmail.Text.Trim(); AdminPassword = $ui.AdminPassword.Password }
        Assert-HermesAdminInput $data
        $data | Add-Member -NotePropertyName NetworkMode -NotePropertyValue (@('Keep','Share','Local')[$ui.NetworkMode.SelectedIndex])
        $data | Add-Member NetworkAddress $ui.NetworkAddress.Text.Trim()
        $script:inputPath = Join-Path $runtimeRoot ('ui-transport\admin-' + [Guid]::NewGuid().ToString('N') + '.bin')
        $null = Protect-HermesLabInput $data $script:inputPath
        $extra = @('-Apply','-AdminInputPath',$script:inputPath,'-RuntimeRoot',$runtimeRoot)
        if ($ui.ResumeCheck.IsChecked -eq $true) { $extra += '-Resume' }
        if ($ui.BotControlCheck.IsChecked -eq $true) { $extra += '-InstallBotControl' }
        Add-Log '별도 로컬 서버 설치를 시작합니다.'
        Start-Worker 'AdminSetup' $extra
        $ui.AdminPassword.Clear(); $ui.PasswordConfirm.Clear(); $data = $null
    } catch {
        Add-Log $_.Exception.Message
        if (-not $script:busy -and $script:inputPath -and (Test-Path -LiteralPath $script:inputPath)) { Remove-Item -LiteralPath $script:inputPath -Force }
        Update-Buttons
    }
})
$ui.OpenButton.Add_Click({ if ($script:result) { Start-Process $script:result.ChannelURL | Out-Null } })
$ui.BotCreateButton.Add_Click({
    try {
        if ($script:busy -or -not $script:dockerReady -or $ui.BotConsentCheck.IsChecked -ne $true) { return }
        $data = [pscustomobject]@{ ServerId = $ui.ServerId.Text.Trim(); SiteName = $ui.SiteName.Text.Trim(); TeamName = $ui.TeamName.Text.Trim(); TeamDisplayName = $ui.TeamDisplayName.Text.Trim(); ChannelName = $ui.ChannelName.Text.Trim(); Port = $ui.Port.Text.Trim(); AdminUsername = $ui.AdminUsername.Text.Trim(); AdminEmail = $ui.AdminEmail.Text.Trim(); AdminPassword = $ui.BotAdminPassword.Password; BotUsername = $ui.BotUsername.Text.Trim(); BotDisplayName = $ui.BotDisplayName.Text.Trim(); BotDescription = $ui.BotDescription.Text.Trim() }
        Assert-HermesAdminBotInput $data
        $script:inputPath = Join-Path $runtimeRoot ('ui-transport\admin-bot-' + [Guid]::NewGuid().ToString('N') + '.bin')
        $null = Protect-HermesLabInput $data $script:inputPath
        Start-Worker 'AdminBotSetup' @('-Apply','-AdminInputPath',$script:inputPath,'-RuntimeRoot',$runtimeRoot)
        $ui.BotAdminPassword.Clear(); $data = $null
    } catch {
        Add-Log $_.Exception.Message
        if (-not $script:busy -and $script:inputPath -and (Test-Path -LiteralPath $script:inputPath)) { Remove-Item -LiteralPath $script:inputPath -Force }
        Update-Buttons
    }
})
$clipboardTimer = New-Object Windows.Threading.DispatcherTimer
$clipboardTimer.Interval = [TimeSpan]::FromSeconds(60)
function Clear-CopiedBotToken {
    $clipboardTimer.Stop()
    try { if ($script:copiedToken -and [Windows.Clipboard]::ContainsText() -and [Windows.Clipboard]::GetText() -ceq $script:copiedToken) { [Windows.Clipboard]::Clear() } } catch { }
    $script:copiedToken = $null
}
$clipboardTimer.Add_Tick({ Clear-CopiedBotToken })
$ui.CopyBotTokenButton.Add_Click({
    try {
        if (-not $script:botResult -or $script:busy) { return }
        $secret = Read-HermesAdminBotCredential $script:botResult
        [Windows.Clipboard]::SetText($secret.Token)
        $script:copiedToken = $secret.Token; $secret = $null
        $clipboardTimer.Stop(); $clipboardTimer.Start()
        Add-Log '봇 토큰을 복사했습니다. 사용자용 마법사에 붙여 넣으세요.'
    } catch { Add-Log '토큰 복사에 실패했습니다. 동일한 입력으로 발급 결과를 다시 확인하세요.' }
})
$ui.CopyChannelButton.Add_Click({
    try { if ($script:botResult -and -not $script:busy) { [Windows.Clipboard]::SetText($script:botResult.HomeChannelId) } }
    catch { Add-Log '클립보드를 사용할 수 없습니다. 잠시 후 다시 복사하세요.' }
})
$ui.ConsoleButton.Add_Click({ if ($script:result) { Start-Process $script:result.AdminURL | Out-Null } })
$ui.BotControlButton.Add_Click({ if ($script:result -and $script:result.BotControlReady) { Start-Process $script:result.BotControlURL | Out-Null } })
$ui.CloseButton.Add_Click({ $window.Close() })
$window.Add_Closing({ param($sender,$e) if ($script:busy) { $e.Cancel = $true; Add-Log '설치·확인이 진행 중입니다. 작업 완료 후 닫아 주세요.' } })
Update-Buttons
if ($SmokeTest) {
    if ($ui.CreateButton.IsEnabled -or $ui.ConsentCheck.IsChecked -or $ui.AdminPassword.Password -or $ui.BotCreateButton.IsEnabled -or $ui.CopyBotTokenButton.IsEnabled -or $ui.BotConsentCheck.IsChecked -or $ui.BotAdminPassword.Password) { throw 'Unsafe admin defaults.' }
    if ($ui.NetworkMode.SelectedIndex -ne 0 -or $ui.NetworkMode.Items.Count -ne 3) { throw 'Network scope must default to Keep, with explicit share/unshare choices.' }
    if ($ProbeDocker) {
        Start-Worker 'AdminPreflight'
        $probeWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($script:busy -and $probeWatch.Elapsed.TotalSeconds -lt 55) {
            $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 50
        }
        if ($script:busy -or -not $script:dockerReady) { throw ('Admin GUI worker did not complete successfully: ' + $ui.Log.Text) }
        if ($ui.CreateButton.IsEnabled) { throw 'Docker readiness must not bypass user consent.' }
        Write-Host 'PASS admin hidden CLI worker, streaming JSON, dispatcher completion and consent gate'
    }
    $script:workerAction = 'AdminBotSetup'
    Read-WorkerLine '{"type":"complete","data":{"Kind":"Bot","Ready":true,"BotUsername":"fixture_bot","HomeChannelId":"fixture-channel"}}'
    Update-Buttons
    if (-not $ui.CopyBotTokenButton.IsEnabled -or -not $ui.CopyChannelButton.IsEnabled -or $null -ne $script:result) { throw 'Bot result routing is incorrect.' }
    $script:botResult = $null; Update-Buttons
    if ($ui.CopyBotTokenButton.IsEnabled) { throw 'Copy must not be enabled without a verified result.' }
    Write-Host 'PASS bot result routing, separate consent and token copy gates'
    $window.Measure((New-Object Windows.Size(900,890))); $window.Arrange((New-Object Windows.Rect(0,0,900,890))); $window.UpdateLayout()
    $window.Close()
    Write-Host 'PASS admin WPF controls, event wiring and safe defaults'
    exit 0
}
try { $null = $window.ShowDialog() } finally { $timer.Stop(); Clear-CopiedBotToken }
