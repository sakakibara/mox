#Requires -Version 5
# mox installer for Windows. Downloads the release binary, verifies it against
# the release's SHA256SUMS, and installs it. Anything you pass runs against the
# installed mox, so install-and-bootstrap is one command:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/sakakibara/mox/main/install.ps1))) `
#       init --clone https://github.com/<you>/dotfiles --apply
#
# Overrides (environment):
#   MOX_VERSION     release tag to install          (default: latest)
#   BINDIR          install directory               (default: %USERPROFILE%\.local\bin)
#   MOX_REPO_SLUG   GitHub owner/repo to fetch from  (default: sakakibara/mox)
#   MOX_BASE_URL    download base URL (mirror)       (default: the GitHub release)

$ErrorActionPreference = 'Stop'

$repoSlug = if ($env:MOX_REPO_SLUG) { $env:MOX_REPO_SLUG } else { 'sakakibara/mox' }
$version  = if ($env:MOX_VERSION)   { $env:MOX_VERSION }   else { 'latest' }
$binDir   = if ($env:BINDIR)        { $env:BINDIR }        else { Join-Path $env:USERPROFILE '.local\bin' }

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne 'AMD64') { throw "mox install: unsupported architecture '$arch'" }
$asset = 'mox-x86_64-windows.zip'

$base = if ($env:MOX_BASE_URL) { $env:MOX_BASE_URL }
        elseif ($version -eq 'latest') { "https://github.com/$repoSlug/releases/latest/download" }
        else { "https://github.com/$repoSlug/releases/download/$version" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mox-install-" + [System.Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host "mox install: downloading $asset ($version)"
    Invoke-WebRequest -Uri "$base/$asset" -OutFile (Join-Path $tmp $asset) -UseBasicParsing
    Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS') -UseBasicParsing

    # Verify against ONLY this asset's SHA256SUMS entry; a missing entry fails.
    $expected = $null
    foreach ($lineText in (Get-Content (Join-Path $tmp 'SHA256SUMS'))) {
        $parts = $lineText.Trim() -split '\s+'
        if ($parts.Length -ge 2 -and $parts[-1] -eq $asset) { $expected = $parts[0].ToLower(); break }
    }
    if (-not $expected) { throw "mox install: SHA256SUMS has no entry for $asset" }
    Write-Host "mox install: verifying checksum"
    $actual = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $tmp $asset)).Hash.ToLower()
    if ($expected -ne $actual) { throw "mox install: checksum verification FAILED for $asset -- refusing to install" }

    Expand-Archive -Path (Join-Path $tmp $asset) -DestinationPath $tmp -Force
    $exe = Join-Path $tmp 'mox.exe'
    if (-not (Test-Path $exe)) { throw "mox install: archive did not contain mox.exe" }

    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Copy-Item $exe (Join-Path $binDir 'mox.exe') -Force
    Write-Host "mox install: installed $(Join-Path $binDir 'mox.exe')"

    if (($env:PATH -split ';') -notcontains $binDir) {
        Write-Host "mox install: note: $binDir is not on your PATH -- add it to run 'mox' directly"
    }

    # Full pass-through: any arguments run against the freshly installed mox.
    if ($args.Count -gt 0) {
        Write-Host "mox install: running: mox $($args -join ' ')"
        & (Join-Path $binDir 'mox.exe') @args
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
