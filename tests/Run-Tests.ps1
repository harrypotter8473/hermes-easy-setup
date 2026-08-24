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

    $redacted = Protect-HermesLogText 'Authorization: Bearer abc.def API_KEY=supersecret sk-abcdefghijklmnop'
    Assert-True ($redacted -notmatch 'abc\.def|supersecret|sk-abcdefghijklmnop') 'log secrets redacted'
    Assert-True ($redacted -match '\[REDACTED') 'redaction marker retained'

    Assert-True (-not (Test-HermesSafeTargetPath -LiteralPath 'C:\' -Label 'test').Safe) 'drive root target rejected'
    Assert-True (Test-HermesSafeTargetPath -LiteralPath (Join-Path $testRootFull 'home') -Label 'test').Safe 'nested target accepted'

    $planA = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime')
    $planB = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime')
    $planC = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime') -IncludeDesktop
    Assert-Equal $planA.Fingerprint $planB.Fingerprint 'plan fingerprint deterministic'
    Assert-True ($planA.Fingerprint -ne $planC.Fingerprint) 'material option changes fingerprint'

    Assert-Equal 'plain' (ConvertTo-WindowsProcessArgument -Argument 'plain') 'plain argv unchanged'
    Assert-Equal '"two words"' (ConvertTo-WindowsProcessArgument -Argument 'two words') 'space argv quoted'
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
