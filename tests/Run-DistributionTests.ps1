[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('hermes-distribution-test-' + [Guid]::NewGuid().ToString('N'))
$passed = 0
function Assert { param($Condition,[string]$Name) if (-not $Condition) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
try {
    $one = & (Join-Path $projectRoot 'Build-Distributions.ps1') -DestinationRoot (Join-Path $fixture 'one')
    $two = & (Join-Path $projectRoot 'Build-Distributions.ps1') -DestinationRoot (Join-Path $fixture 'two')
    Assert ($one.Packages.Count -eq 3 -and -not $one.Published -and -not $one.Signed) 'User, Admin and Research unsigned local distributions'
    Assert (Test-Path -LiteralPath $one.Checksums) 'ZIP checksums provided'
    foreach ($package in $one.Packages) {
        $other = @($two.Packages | Where-Object Kind -eq $package.Kind)[0]
        Assert ($other.SHA256 -ceq $package.SHA256) ('Reproducible ZIP: ' + $package.Kind)
        $archive = [IO.Compression.ZipFile]::OpenRead($package.Path)
        try {
            $entries = @($archive.Entries | ForEach-Object FullName)
            $name = [IO.Path]::GetFileNameWithoutExtension($package.Path)
            Assert (@($entries | Where-Object { -not $_.StartsWith($name + '/') -or $_ -match '\.\.|\\' }).Count -eq 0) 'Archive entries stay within a single relative root'
            Assert (@($entries | Where-Object { $_ -match '(?i)(^|/)(\.git|\.env|auth\.json|config\.yaml|ui-transport|runtime|tests)(/|$)|\.(bin|bak|log)$' }).Count -eq 0) 'No personal runtime, authentication, backups, or tests packaged'
            Assert (@($entries | Where-Object { $_ -match '(?i)\.exe$' }).Count -eq 0) 'Docker installer is downloaded only after consent, never bundled'
        } finally { $archive.Dispose() }
        $extract = Join-Path $fixture ('unpacked-' + $package.Kind)
        [IO.Compression.ZipFile]::ExtractToDirectory($package.Path,$extract)
        $root = Join-Path $extract $name
        Assert (Test-Path -LiteralPath (Join-Path $root $package.EntryPoint)) 'Role-specific launcher exists'
        Assert ((Test-Path -LiteralPath (Join-Path $root 'src/HermesEasySetup.Docker.psm1')) -and (Test-Path -LiteralPath (Join-Path $root 'config/docker-desktop.json'))) 'Docker discovery and verified-download pin included'
        $hashes = [IO.File]::ReadAllLines((Join-Path $root 'FILES.sha256'))
        foreach ($line in $hashes) {
            if ($line -notmatch '^([a-f0-9]{64})  ([^\r\n]+)$') { throw 'Malformed file manifest' }
            $expected = $Matches[1]; $relative = $Matches[2]
            if ($relative.Contains('..') -or [IO.Path]::IsPathRooted($relative)) { throw 'Unsafe file manifest path' }
            if ((Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) { throw "File checksum mismatch: $relative" }
        }
        Assert ($hashes.Count -gt 20 -and @($entries).Count -eq $hashes.Count + 2) 'Every source file checksum matches; only manifest and readme are generated'
        if ($package.Kind -eq 'User') {
            Assert (-not (Test-Path -LiteralPath (Join-Path $root 'HermesAdminSetup.Gui.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $root 'assets'))) 'User ZIP omits admin UI and server plugin payload'
            $gui = 'HermesEasySetup.Gui.ps1'
        } elseif ($package.Kind -eq 'Research') {
            Assert (-not (Test-Path -LiteralPath (Join-Path $root 'assets')) -and (Test-Path -LiteralPath (Join-Path $root 'ui/ResearchWindow.xaml'))) 'Research ZIP includes unified local UI without optional server plugin'
            $gui = 'HermesResearchSetup.Gui.ps1'
        } else {
            Assert (-not (Test-Path -LiteralPath (Join-Path $root 'HermesEasySetup.Gui.ps1')) -and (Test-Path -LiteralPath (Join-Path $root 'assets/bot-control/com.infonet.bot-control-0.6.2.tar.gz'))) 'Admin ZIP includes pinned plugin and omits user UI'
            $gui = 'HermesAdminSetup.Gui.ps1'
        }
        $ps = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root $gui) -SmokeTest
        Assert ($LASTEXITCODE -eq 0) ('Extracted ' + $package.Kind + ' GUI loads without installing anything')
    }
    $rejected = $false
    try { & (Join-Path $projectRoot 'Build-Distributions.ps1') -DestinationRoot (Join-Path $fixture 'one') | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Existing distributions are not silently overwritten'
    Write-Host "$passed distribution tests passed"
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedFixture) -cne $expectedParent -or [IO.Path]::GetFileName($resolvedFixture) -cnotmatch '^hermes-distribution-test-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
