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

# A 32-bit PowerShell host on a 64-bit machine reports x86 here and the real
# architecture in PROCESSOR_ARCHITEW6432, so prefer that when it is set.
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$asset = switch ($arch) {
    'AMD64' { 'mox-x86_64-windows.zip' }
    'ARM64' { 'mox-aarch64-windows.zip' }
    default { throw "mox install: unsupported architecture '$arch'" }
}

$base = if ($env:MOX_BASE_URL) { $env:MOX_BASE_URL }
        elseif ($version -eq 'latest') { "https://github.com/$repoSlug/releases/latest/download" }
        else { "https://github.com/$repoSlug/releases/download/$version" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mox-install-" + [System.Guid]::NewGuid())
$staged = $null
$old = $null
$target = $null
$steppedAside = $false
$installed = $false
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
    # Staged beside the target and renamed into place: an interrupted or short
    # write must not leave a truncated mox.exe where a working one was. Windows
    # cannot rename over a running binary, so the old one steps aside first --
    # the same dance `mox upgrade` does.
    $target = Join-Path $binDir 'mox.exe'
    $staged = "$target.new"
    $old = "$target.old"
    foreach ($p in @($target, $staged, $old)) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            throw "mox install: $p is a directory; remove it or set BINDIR"
        }
    }
    Copy-Item -LiteralPath $exe -Destination $staged -Force
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $target -Destination $old -Force
        $steppedAside = $true
        Move-Item -LiteralPath $staged -Destination $target -Force
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    } else {
        Move-Item -LiteralPath $staged -Destination $target -Force
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "mox install: $target is not a file after install" }
    $installed = $true
    Write-Host "mox install: installed $target"

    if (($env:PATH -split ';') -notcontains $binDir) {
        Write-Host "mox install: note: $binDir is not on your PATH -- add it to run 'mox' directly"
    }

    # Full pass-through: any arguments run against the freshly installed mox.
    if ($args.Count -gt 0) {
        Write-Host "mox install: running: mox $($args -join ' ')"
        & $target @args
        # A native command's exit code does not trip $ErrorActionPreference, so
        # without this a failed `init --clone --apply` reports success.
        $code = $LASTEXITCODE
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        # Run as a file, the exit code is the script's. Run as a script block
        # in the caller's session, `exit` would close that session; the code
        # is left in $LASTEXITCODE for the caller to read.
        if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') { exit $code }
        $global:LASTEXITCODE = $code
        return
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    # A failed run leaves neither a staging file nor a stepped-aside binary
    # behind: the old binary goes back where it was.
    if ($staged -and (Test-Path -LiteralPath $staged -PathType Leaf)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
    if ($steppedAside -and -not $installed -and (Test-Path -LiteralPath $old -PathType Leaf)) {
        Move-Item -LiteralPath $old -Destination $target -Force -ErrorAction SilentlyContinue
    }
}
