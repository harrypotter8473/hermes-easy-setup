[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force

$script:passed = 0
$script:failed = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host "PASS $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "FAIL $Name" -ForegroundColor Red
        $script:failed++
    }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    Assert-True -Condition ($Expected -eq $Actual) -Name "$Name (expected=$Expected, actual=$Actual)"
}

$tempBase = [System.IO.Path]::GetTempPath()
$testRoot = Join-Path $tempBase ('hermes-easy-setup-tests-' + [guid]::NewGuid().ToString('N'))
$testRootFull = [System.IO.Path]::GetFullPath($testRoot)
New-Item -ItemType Directory -Path $testRootFull -Force | Out-Null

try {
    $source = Get-HermesSourceConfig
    Assert-Equal 'NousResearch/hermes-agent' $source.hermes.repository 'official repository pin'
    Assert-Equal 64 ([string]$source.installer.sha256).Length 'installer SHA-256 length'
    Assert-True (Test-HermesSourceConfig -Config $source).Valid 'source config validates'

    $evil = ($source | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $evil.installer.uri = 'https://evil.example/install.ps1'
    Assert-True (-not (Test-HermesSourceConfig -Config $evil).Valid) 'unapproved source host rejected'
    $badCommit = ($source | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $badCommit.hermes.commitSha = 'main'
    Assert-True (-not (Test-HermesSourceConfig -Config $badCommit).Valid) 'non-immutable commit rejected'

    $redacted = Protect-HermesLogText 'Authorization: Bearer abc.def API_KEY=supersecret sk-abcdefghijklmnop https://url-user:url-secret@example.com/path'
    Assert-True ($redacted -notmatch 'abc\.def|supersecret|sk-abcdefghijklmnop|url-secret') 'log secrets redacted'
    Assert-True ($redacted -match 'https://\[REDACTED\]@example\.com/path') 'URL userinfo redacted'
    Assert-True ($redacted -match '\[REDACTED') 'redaction marker retained'

    Assert-True (-not (Test-HermesSafeTargetPath -LiteralPath 'C:\' -Label 'test').Safe) 'drive root target rejected'
    Assert-True (Test-HermesSafeTargetPath -LiteralPath (Join-Path $testRootFull 'home') -Label 'test').Safe 'nested target accepted'

    $planA = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime')
    $planB = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime')
    $planC = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime') -IncludeDesktop
    Assert-Equal $planA.Fingerprint $planB.Fingerprint 'plan fingerprint deterministic'
    Assert-True ($planA.Fingerprint -ne $planC.Fingerprint) 'material option changes fingerprint'

    $systemGitHome = Join-Path $testRootFull 'system-git-probe-home'
    $signedSystemGit = Get-HermesVerificationGitPath -HermesHome $systemGitHome
    Assert-True (-not [string]::IsNullOrWhiteSpace($signedSystemGit)) 'signed Program Files Git is available for verification tests'

    $planManagedGit = Join-Path $planA.HermesHome 'git\cmd\git.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $planManagedGit) -Force | Out-Null
    Copy-Item -LiteralPath $signedSystemGit -Destination $planManagedGit
    $installEngineModulePath = (Resolve-Path -LiteralPath (Join-Path $projectRoot 'src\HermesEasySetup.InstallEngine.psm1')).Path
    $installEngineModule = Get-Module | Where-Object { [string]::Equals([string]$_.Path, $installEngineModulePath, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    Assert-True ($null -ne $installEngineModule) 'InstallEngine module context is available for private resolver tests'
    $signedManagedCandidate = & $installEngineModule { param($path) Test-HermesGitCandidate -LiteralPath $path -RequireValidSignature } $planManagedGit
    Assert-Equal ([System.IO.Path]::GetFullPath($planManagedGit)) $signedManagedCandidate 'signed Git candidate passes leaf validation'
    New-Item -ItemType Directory -Path $planA.RuntimeRoot -Force | Out-Null

    $callerGitConfig = Join-Path $testRootFull 'caller.gitconfig'
    $callerGitConfigText = "[core]`n`tautocrlf = true`n"
    [System.IO.File]::WriteAllText($callerGitConfig, $callerGitConfigText, (New-Object System.Text.UTF8Encoding($false)))
    $previousGlobalConfig = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL', [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $callerGitConfig, [EnvironmentVariableTarget]::Process)
        $repositoryEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'repository'
        $gitConfigPath = [string]$repositoryEnvironment['GIT_CONFIG_GLOBAL']
        $token = [System.IO.Path]::GetFileName($gitConfigPath).Substring(11, 32)
        $gitAttributesPath = Join-Path $planA.RuntimeRoot ("git-attributes-$token.txt")
        $attributesConfigValue = ([System.IO.Path]::GetFullPath($gitAttributesPath)).Replace('\', '/').Replace('"', '\"')
        $gitConfigText = "[core]`n`tautocrlf = false`n`tattributesFile = `"$attributesConfigValue`"`n"
        Assert-Equal $planA.HermesHome $repositoryEnvironment['HERMES_HOME'] 'stage environment preserves HERMES_HOME'
        Assert-True ($repositoryEnvironment.ContainsKey('GIT_CONFIG_GLOBAL')) 'fresh repository stage receives managed global Git config'
        Assert-True ($gitConfigPath.StartsWith(([System.IO.Path]::GetFullPath($planA.RuntimeRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) 'managed Git config stays inside RuntimeRoot'
        Assert-True ((Split-Path -Leaf $gitConfigPath) -match '^git-global-[0-9a-f]{32}\.config$') 'managed Git config uses an unpredictable filename'
        Assert-Equal $gitConfigText ([System.IO.File]::ReadAllText($gitConfigPath, [System.Text.Encoding]::UTF8)) 'managed Git config forces LF and empty global attributes'
        Assert-Equal 0 (Get-Item -LiteralPath $gitAttributesPath).Length 'managed global attributes file is empty'
        $coreRead = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--file', $gitConfigPath, '--bool', '--get', 'core.autocrlf') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal 0 $coreRead.ExitCode 'managed Git config is accepted by Git'
        Assert-Equal 'false' $coreRead.StdOut.Trim() 'Git reads managed core.autocrlf as false'
        $upstreamGlobalWrite = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--global', 'windows.appendAtomically', 'false') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal 0 $upstreamGlobalWrite.ExitCode 'upstream global Git write targets managed config'
        $coreAfterWrite = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--file', $gitConfigPath, '--bool', '--get', 'core.autocrlf') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal 'false' $coreAfterWrite.StdOut.Trim() 'upstream global write preserves managed core.autocrlf'
        $attributesAfterWrite = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--file', $gitConfigPath, '--path', '--get', 'core.attributesFile') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal ([System.IO.Path]::GetFullPath($gitAttributesPath)) ([System.IO.Path]::GetFullPath($attributesAfterWrite.StdOut.Trim())) 'upstream global write preserves managed attributes file'
        $gitConfigBytes = [System.IO.File]::ReadAllBytes($gitConfigPath)
        Assert-True (-not ($gitConfigBytes[0] -eq 0xEF -and $gitConfigBytes[1] -eq 0xBB -and $gitConfigBytes[2] -eq 0xBF)) 'managed Git config has no UTF-8 BOM'

        $repositoryEnvironmentAgain = New-HermesStageEnvironment -Plan $planA -Stage 'repository'
        $gitConfigPathAgain = [string]$repositoryEnvironmentAgain['GIT_CONFIG_GLOBAL']
        Assert-True (-not $gitConfigPath.Equals($gitConfigPathAgain, [StringComparison]::OrdinalIgnoreCase)) 'managed Git config path is never reused'
        Assert-Equal $callerGitConfigText ([System.IO.File]::ReadAllText($callerGitConfig, [System.Text.Encoding]::UTF8)) 'caller global Git config is unchanged'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_CONFIG_PARAMETERS') -and $null -eq $repositoryEnvironmentAgain['GIT_CONFIG_PARAMETERS']) 'ambient Git command parameters are removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_CONFIG_SYSTEM') -and $null -eq $repositoryEnvironmentAgain['GIT_CONFIG_SYSTEM']) 'ambient Git system redirect is removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_EXEC_PATH') -and $null -eq $repositoryEnvironmentAgain['GIT_EXEC_PATH']) 'ambient Git executable redirect is removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_COMMON_DIR') -and $null -eq $repositoryEnvironmentAgain['GIT_COMMON_DIR']) 'ambient Git common directory redirect is removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_NAMESPACE') -and $null -eq $repositoryEnvironmentAgain['GIT_NAMESPACE']) 'ambient Git namespace redirect is removed'
        Assert-Equal '0' $repositoryEnvironmentAgain['GIT_CONFIG_NOSYSTEM'] 'default Git system configuration remains enabled'
        Assert-Equal '1' $repositoryEnvironmentAgain['GIT_ATTR_NOSYSTEM'] 'system Git attributes are disabled'

        Remove-HermesStageEnvironmentArtifacts -Environment $repositoryEnvironment -Plan $planA
        Remove-HermesStageEnvironmentArtifacts -Environment $repositoryEnvironmentAgain -Plan $planA
        Assert-True (-not (Test-Path -LiteralPath $gitConfigPath)) 'first managed Git config is removed after stage'
        Assert-True (-not (Test-Path -LiteralPath $gitConfigPathAgain)) 'second managed Git config is removed after stage'
        Assert-True (-not (Test-Path -LiteralPath $gitAttributesPath)) 'managed Git attributes are removed after stage'
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $previousGlobalConfig, [EnvironmentVariableTarget]::Process)
    }

    $existingRepositoryEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'repository' -ExistingCheckout
    Assert-True ($existingRepositoryEnvironment.ContainsKey('GIT_CONFIG_GLOBAL') -and $null -eq $existingRepositoryEnvironment['GIT_CONFIG_GLOBAL']) 'existing checkout does not receive fresh clone config'
    Assert-True ($existingRepositoryEnvironment.ContainsKey('GIT_COMMON_DIR') -and $null -eq $existingRepositoryEnvironment['GIT_COMMON_DIR']) 'existing checkout removes ambient common directory'
    $trustedGitPathPrefix = [System.IO.Path]::GetDirectoryName($signedSystemGit) + [System.IO.Path]::PathSeparator
    Assert-True ([string]$existingRepositoryEnvironment['PATH'] -like "$trustedGitPathPrefix*") 'repository stage PATH starts with Program Files Git'
    $gitStageEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'git'
    Assert-True ([string]$gitStageEnvironment['PATH'] -like "$trustedGitPathPrefix*") 'official Git stage PATH starts with Program Files Git'
    Assert-True ($gitStageEnvironment.ContainsKey('GIT_CONFIG_GLOBAL') -and $null -eq $gitStageEnvironment['GIT_CONFIG_GLOBAL']) 'official Git stage removes ambient global config'
    $uvEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'uv'
    Assert-True ([string]$uvEnvironment['PATH'] -like "$trustedGitPathPrefix*") 'later automatic stage PATH starts with Program Files Git'
    Assert-True ($uvEnvironment.ContainsKey('GIT_CONFIG_GLOBAL') -and $null -eq $uvEnvironment['GIT_CONFIG_GLOBAL']) 'later automatic stage removes ambient global config'
    Assert-True ($uvEnvironment.ContainsKey('GIT_COMMON_DIR') -and $null -eq $uvEnvironment['GIT_COMMON_DIR']) 'later automatic stage removes ambient common directory'
    Assert-Equal ([System.IO.Path]::GetFullPath($signedSystemGit)) (Get-HermesVerificationGitPath -HermesHome $planA.HermesHome) 'Program Files Git is selected'

    $unsignedGitHome = Join-Path $testRootFull 'unsigned-git-home'
    $unsignedGitFixture = Join-Path $unsignedGitHome 'git\cmd\git.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $unsignedGitFixture) -Force | Out-Null
    [System.IO.File]::WriteAllText($unsignedGitFixture, 'fixture', (New-Object System.Text.UTF8Encoding($false)))
    $unsignedManagedCandidate = & $installEngineModule { param($path) Test-HermesGitCandidate -LiteralPath $path -RequireValidSignature } $unsignedGitFixture
    Assert-True ([string]::IsNullOrWhiteSpace($unsignedManagedCandidate)) 'unsigned managed Git is rejected'

    $competingGitHome = Join-Path $testRootFull 'competing-git-home'
    $competingGitExe = Join-Path $competingGitHome 'git\cmd\git.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $competingGitExe) -Force | Out-Null
    Copy-Item -LiteralPath $signedSystemGit -Destination $competingGitExe
    [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $competingGitExe) 'git.cmd'), '@exit /b 0', (New-Object System.Text.ASCIIEncoding))
    $competingManagedCandidate = & $installEngineModule { param($path) Test-HermesGitCandidate -LiteralPath $path -RequireValidSignature } $competingGitExe
    Assert-True ([string]::IsNullOrWhiteSpace($competingManagedCandidate)) 'managed Git with competing git.cmd is rejected'

    Assert-Equal 'plain' (ConvertTo-WindowsProcessArgument -Argument 'plain') 'plain argv unchanged'
    Assert-Equal '"two words"' (ConvertTo-WindowsProcessArgument -Argument 'two words') 'space argv quoted'
    $probeVariable = 'HERMES_EASY_SETUP_REMOVE_PROBE'
    $previousProbe = [Environment]::GetEnvironmentVariable($probeVariable, [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable($probeVariable, 'ambient', [EnvironmentVariableTarget]::Process)
        $probeCommand = "if (Test-Path Env:$probeVariable) { Write-Output present } else { Write-Output absent }"
        $probeResult = Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList @('-NoLogo', '-NoProfile', '-Command', $probeCommand) -Environment @{ $probeVariable = $null } -TimeoutSeconds 30
        Assert-Equal 0 $probeResult.ExitCode 'child process environment removal succeeds'
        Assert-Equal 'absent' $probeResult.StdOut.Trim() 'null environment entry is not inherited by child process'
    } finally {
        [Environment]::SetEnvironmentVariable($probeVariable, $previousProbe, [EnvironmentVariableTarget]::Process)
    }
    $frameText = 'noise' + [Environment]::NewLine + '{"stage":"one","ok":true}' + [Environment]::NewLine + 'more'
    $frame = ConvertFrom-HermesJsonFrame -Text $frameText -RequiredProperty 'stage'
    Assert-Equal 'one' $frame.stage 'last valid JSON frame parsed'
    Assert-True (Test-HermesStageFrame -Frame ([pscustomobject]@{stage='uv';ok=$true;skipped=$false;reason=$null;duration_ms=1}) -ExpectedStage 'uv').Valid 'valid stage frame accepted'
    Assert-True (-not (Test-HermesStageFrame -Frame ([pscustomobject]@{stage='wrong';ok=$true;skipped=$false;reason=$null;duration_ms=1}) -ExpectedStage 'uv').Valid) 'wrong stage frame rejected'

    $contract = Get-Content -Raw (Join-Path $projectRoot 'config\hermes-manifest.json') | ConvertFrom-Json
    function New-TestManifest([bool]$Desktop) {
        $stages = @()
        foreach ($name in @($contract.baseStages)) {
            $category = if (@('uv','python','git','node','system-packages') -contains $name) {
                'prereqs'
            } elseif (@('repository','venv','dependencies','node-deps') -contains $name) {
                'install'
            } elseif (@('path','config-templates','platform-sdks','bootstrap-marker') -contains $name) {
                'finalize'
            } else {
                'post-install'
            }
            $stages += [pscustomobject]@{
                name = [string]$name
                title = "Title $name"
                category = $category
                needs_user_input = (@('configure','gateway') -contains [string]$name)
            }
            if ($Desktop -and [string]$name -eq 'node-deps') {
                $stages += [pscustomobject]@{name='desktop';title='Desktop';category='install';needs_user_input=$false}
            }
        }
        return [pscustomobject]@{protocol_version=1;stages=$stages}
    }
    $baseManifest = New-TestManifest $false
    $desktopManifest = New-TestManifest $true
    Assert-True (Test-HermesInstallerManifest -Manifest $baseManifest -IncludeDesktop $false).Valid 'reviewed base manifest accepted'
    Assert-True (Test-HermesInstallerManifest -Manifest $desktopManifest -IncludeDesktop $true).Valid 'reviewed desktop manifest accepted'
    $baseManifest.stages[0].needs_user_input = $true
    Assert-True (-not (Test-HermesInstallerManifest -Manifest $baseManifest -IncludeDesktop $false).Valid) 'unexpected interactive stage rejected'
    $baseManifest = New-TestManifest $false

    $state = New-HermesInstallState -Plan $planA -Manifest $baseManifest
    $state = Set-HermesStageRecord -State $state -Name 'uv' -Status 'Succeeded' -DurationMs 5
    $statePath = Join-Path $testRootFull 'state\state.json'
    [void](Save-HermesInstallState -LiteralPath $statePath -State $state)
    $roundTrip = Read-HermesInstallState -LiteralPath $statePath
    Assert-True (Test-HermesStateCanResume -State $roundTrip -Plan $planA -Manifest $baseManifest) 'matching checkpoint resumes'
    Assert-True (-not (Test-HermesStateCanResume -State $roundTrip -Plan $planC -Manifest $baseManifest)) 'different plan checkpoint rejected'
    Assert-Equal 'Succeeded' (Get-HermesStageRecord -State $roundTrip -Name 'uv').status 'stage status persisted'

    $state.status = 'Failed'
    [void](Save-HermesInstallState -LiteralPath $statePath -State $state)
    $replacedState = Read-HermesInstallState -LiteralPath $statePath
    Assert-Equal 'Failed' $replacedState.status 'existing state file atomically replaced'
    $stateTemporaryFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter '.state-*.tmp' -File -Force)
    Assert-Equal 0 $stateTemporaryFiles.Count 'state replacement leaves no temporary file'

    $fixture = Join-Path $testRootFull 'fixture-install.ps1'
    $fixtureScript = 'param([switch]$Manifest)' + [Environment]::NewLine + 'if($Manifest){''{"protocol_version":1,"stages":[]}''}'
    [System.IO.File]::WriteAllText($fixture, $fixtureScript, (New-Object System.Text.UTF8Encoding $false))
    $fixtureConfig = ($source | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $fixtureConfig.installer.sha256 = ConvertTo-HermesSha256 -LiteralPath $fixture
    $fixtureConfig.installer.sizeBytes = (Get-Item -LiteralPath $fixture).Length
    $fixtureConfig.installer.maxBytes = 4096
    Assert-True (Test-HermesInstallerFile -LiteralPath $fixture -SourceConfig $fixtureConfig).Valid 'matching installer fixture accepted'
    [System.IO.File]::AppendAllText($fixture, '#tamper')
    Assert-True (-not (Test-HermesInstallerFile -LiteralPath $fixture -SourceConfig $fixtureConfig).Valid) 'tampered installer fixture rejected'

    [System.IO.File]::WriteAllText($fixture, "Write-Output 'fixture'", (New-Object System.Text.UTF8Encoding $false))
    $fixtureConfig.installer.sha256 = ConvertTo-HermesSha256 -LiteralPath $fixture
    $fixtureConfig.installer.sizeBytes = (Get-Item -LiteralPath $fixture).Length
    $fixtureConfig.installer.maxBytes = 4096
    $downloadRoot = Join-Path $testRootFull 'download'
    $downloadPaths = Get-HermesDefaultPaths -HermesHome (Join-Path $downloadRoot 'home') -RuntimeRoot $downloadRoot
    New-Item -ItemType Directory -Path $downloadPaths.LogDir -Force | Out-Null
    $downloader = { param($uri,$destination,$maximum); Copy-Item -LiteralPath $fixture -Destination $destination }.GetNewClosure()
    $verified = Get-HermesVerifiedInstaller -SourceConfig $fixtureConfig -Paths $downloadPaths -Downloader $downloader -LogPath (Join-Path $downloadPaths.LogDir 'test.log')
    Assert-Equal $fixtureConfig.installer.sha256 $verified.Sha256 'custom downloader content verified'

    $bundleRuntime = Join-Path $testRootFull 'bundle-runtime'
    $bundleHome = Join-Path $testRootFull 'bundle-home'
    New-Item -ItemType Directory -Path $bundleHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $bundleHome '.env'), 'API_KEY=must-not-ship')
    $bundle = Export-HermesDiagnosticBundle -HermesHome $bundleHome -RuntimeRoot $bundleRuntime
    $expanded = Join-Path $testRootFull 'expanded-bundle'
    Expand-Archive -LiteralPath $bundle.Path -DestinationPath $expanded
    $entries = @(Get-ChildItem -LiteralPath $expanded -Recurse -File | ForEach-Object { $_.Name })
    Assert-True ($entries -notcontains '.env') 'diagnostic bundle excludes .env'
    Assert-True ($entries -notcontains 'config.yaml') 'diagnostic bundle excludes config.yaml'
    Assert-True ($entries -contains 'preflight.json') 'diagnostic bundle includes preflight summary'

    [xml]$xaml = Get-Content -Raw (Join-Path $projectRoot 'ui\MainWindow.xaml')
    Assert-True ($null -ne $xaml.DocumentElement) 'GUI XAML is well-formed XML'
    $xamlText = Get-Content -Raw (Join-Path $projectRoot 'ui\MainWindow.xaml')
    Assert-True ($xamlText -match 'x:Name="ApprovalCheck"') 'GUI has explicit approval control'
    Assert-True ($xamlText -match 'x:Name="InstallButton"[^>]*IsEnabled="False"') 'GUI install starts disabled'
} finally {
    if (Test-Path -LiteralPath $testRootFull -PathType Container) {
        $resolved = [System.IO.Path]::GetFullPath($testRootFull)
        $tempPrefix = [System.IO.Path]::GetFullPath($tempBase)
        if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'hermes-easy-setup-tests-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

Write-Host ''
Write-Host "Passed: $script:passed  Failed: $script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
