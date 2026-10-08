[CmdletBinding()]
param([string]$DestinationRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'hermes-easy-setup-dist'))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force
function Assert-DistributionPath { param([string]$Path) & (Get-Module HermesEasySetup.Admin) { param($Value) Assert-HermesAdminPath $Value } $Path }
$DestinationRoot = [IO.Path]::GetFullPath($DestinationRoot)
Assert-DistributionPath $DestinationRoot
if ($DestinationRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($DestinationRoot).TrimEnd('\') -or $DestinationRoot.StartsWith('\\') -or
    $DestinationRoot -eq $PSScriptRoot -or (Test-HermesPathContains -ParentPath $PSScriptRoot -ChildPath $DestinationRoot)) { throw '배포 출력은 소스 폴더 밖의 별도 로컬 폴더를 선택하세요.' }
$version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
if ($version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'Invalid distribution version' }
# Explicit allowlist, never archive the worktree, runtime, .git, backups, or personal notes.
$common = @('HermesEasySetup.ps1','VERSION','LICENSE','README.md','SECURITY.md',
    'config/hermes-manifest.json','config/hermes-source.json','config/mattermost-desktop.json','config/mattermost-server.json','config/bot-control.json','config/docker-desktop.json',
    'src/HermesEasySetup.Loader.psm1','src/HermesEasySetup.Core.psm1','src/HermesEasySetup.Preflight.psm1','src/HermesEasySetup.StateStore.psm1',
    'src/HermesEasySetup.Execution.psm1','src/HermesEasySetup.Protocol.psm1','src/HermesEasySetup.InstallEngine.psm1','src/HermesEasySetup.Codex.psm1',
    'src/HermesEasySetup.Lab.psm1','src/HermesEasySetup.Mattermost.psm1','src/HermesEasySetup.Docker.psm1','src/HermesEasySetup.Admin.psm1','src/HermesEasySetup.AdminBots.ps1','src/HermesEasySetup.AdminNetwork.ps1','src/HermesEasySetup.Research.psm1','src/HermesEasySetup.ResearchRuntime.psm1','src/HermesEasySetup.Bundle.psm1',
    'docs/installation-guide.ko.md','docs/admin-guide.ko.md','docs/two-pc-checklist.ko.md','docs/recovery-guide.ko.md','docs/admin-step5-validation.ko.md')
$package = & (Get-Module HermesEasySetup.Admin) { Get-HermesAdminBotControlPackage }
$roles = @(
    @{ Name = 'User'; Entry = 'Start-HermesEasySetup.cmd'; Files = @('Start-HermesEasySetup.cmd','HermesEasySetup.Gui.ps1','ui/MainWindow.xaml') },
    @{ Name = 'Admin'; Entry = 'Start-HermesAdminSetup.cmd'; Files = @('Start-HermesAdminSetup.cmd','HermesAdminSetup.Gui.ps1','ui/AdminWindow.xaml',('assets/bot-control/' + $package.Pin.file)) },
    @{ Name = 'Research'; Entry = 'Start-HermesResearchSetup.cmd'; Files = @('Start-HermesResearchSetup.cmd','HermesResearchSetup.Gui.ps1','ui/ResearchWindow.xaml','docs/research-guide.ko.md') }
)
$plans = @()
foreach ($role in $roles) {
    $files = @($common + $role.Files | Sort-Object -Unique)
    foreach ($file in $files) {
        $path = Join-Path $PSScriptRoot $file
        Assert-DistributionPath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('배포 파일이 없습니다: ' + $file) }
    }
    $name = 'Hermes-' + $role.Name + '-Setup-' + $version
    $path = Join-Path $DestinationRoot ($name + '.zip')
    if (Test-Path -LiteralPath $path) { throw '같은 이름의 배포 ZIP이 있습니다. 다른 출력 폴더를 선택하세요. 덮어쓰지 않습니다.' }
    $plans += [pscustomobject]@{ Name = $name; Role = $role.Name; Entry = $role.Entry; Files = $files; Path = $path }
}
$checksumPath = Join-Path $DestinationRoot 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $checksumPath) { throw '기존 체크섬 파일은 덮어쓰지 않습니다.' }
New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$encoding = New-Object Text.UTF8Encoding $false
$stamp = [DateTimeOffset]::Parse('2026-01-01T00:00:00+00:00')
function Add-ZipText {
    param($Archive,[string]$Name,[string]$Content)
    $entry = $Archive.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $stamp
    $stream = $entry.Open()
    try { $bytes = $encoding.GetBytes($Content); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
$outputs = @()
foreach ($plan in $plans) {
    $fileStream = [IO.File]::Open($plan.Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $archive = New-Object IO.Compression.ZipArchive($fileStream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        $manifest = @()
        foreach ($file in $plan.Files) {
            $source = Join-Path $PSScriptRoot $file
            $entry = $archive.CreateEntry($plan.Name + '/' + $file,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $stamp
            $inputStream = [IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $outputStream = $entry.Open()
            try {
                $hash = [Security.Cryptography.SHA256]::Create()
                try { $digest = ([BitConverter]::ToString($hash.ComputeHash($inputStream))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
                $inputStream.Position = 0; $inputStream.CopyTo($outputStream)
                $manifest += ($digest + '  ' + $file)
            } finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
        Add-ZipText $archive ($plan.Name + '/FILES.sha256') (($manifest -join "`n") + "`n")
        $purpose = $(if ($plan.Role -ceq 'Research') {
            "개인 연구실용입니다. 현재 Windows PC에 로컬 서버·Hermes·에이전트 4개를 구성합니다.`n안내: docs/research-guide.ko.md`n실제 설치·모델 답변은 사용자가 점검해야 합니다.`n"
        } else {
            "관리자용은 서버 PC, 사용자용은 각 연구원 PC에서 실행합니다.`n두 PC 실사용 점검: docs/two-pc-checklist.ko.md`n"
        })
        $note = "Hermes Easy Setup $version — $($plan.Role)`n`n압축을 모두 푼 뒤 $($plan.Entry)를 더블클릭하세요.`n" +
            "현재 패키지는 미서명 테스트 빌드입니다. Windows x64용입니다.`n" + $purpose +
            "실패 시: docs/recovery-guide.ko.md`n개인 인증값·설치 상태·기존 Hermes 프로필은 포함하지 않았습니다.`n" +
            "기존 프로그램·프로필을 제거하지 말고 먼저 안내를 읽으세요.`n"
        Add-ZipText $archive ($plan.Name + '/먼저읽기.txt') $note
    } finally { $archive.Dispose(); $fileStream.Dispose() }
    $outputs += [pscustomobject]@{ Kind = $plan.Role; Path = $plan.Path; SHA256 = (Get-FileHash -LiteralPath $plan.Path -Algorithm SHA256).Hash.ToLowerInvariant(); EntryPoint = $plan.Entry }
}
[IO.File]::WriteAllText($checksumPath,(($outputs | ForEach-Object { $_.SHA256 + '  ' + (Split-Path -Leaf $_.Path) }) -join "`n") + "`n",$encoding)
[pscustomobject]@{ Version = $version; Packages = $outputs; Checksums = $checksumPath; Published = $false; Signed = $false }
