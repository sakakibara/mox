# Run with: pwsh -NoProfile -File tests/installer_test.ps1   (from the repo root)
#
# install.ps1 against a fixture release served over HTTP: the asset name for
# each arch, the checksum gate and a missing checksum line, a directory at
# the target, an install over an existing binary, staging leftovers, and on
# Windows the bootstrapped command's exit code, with cmd.exe standing in for
# mox.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("mox-installer-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$passes = 0; $fails = 0
function Ok([string]$d) { Write-Host "  ok   $d"; $script:passes++ }
function No([string]$d, [string]$why) { Write-Host "  FAIL $d"; Write-Host "      $why"; $script:fails++ }

# A fixture release holding a stand-in mox.exe.
$rel = Join-Path $work 'release'
New-Item -ItemType Directory -Path (Join-Path $rel 'pkg') | Out-Null
Set-Content -LiteralPath (Join-Path $rel 'pkg/mox.exe') -Value 'fixture binary' -NoNewline
$asset = 'mox-x86_64-windows.zip'
Compress-Archive -Path (Join-Path $rel 'pkg/mox.exe') -DestinationPath (Join-Path $rel $asset) -Force
$sum = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $rel $asset)).Hash.ToLower()
Set-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Value "$sum  $asset`n" -NoNewline

# The ARM64 asset carries its own stand-in, so a test can tell which one landed.
$asset_arm = 'mox-aarch64-windows.zip'
New-Item -ItemType Directory -Path (Join-Path $rel 'pkg-arm') | Out-Null
Set-Content -LiteralPath (Join-Path $rel 'pkg-arm/mox.exe') -Value 'arm fixture binary' -NoNewline
Compress-Archive -Path (Join-Path $rel 'pkg-arm/mox.exe') -DestinationPath (Join-Path $rel $asset_arm) -Force
$sum_arm = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $rel $asset_arm)).Hash.ToLower()
$sums_both = "$sum  $asset`n$sum_arm  $asset_arm`n"
Set-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Value $sums_both -NoNewline

$python = $null
foreach ($cand in @(@('python3'), @('python'), @('py', '-3'))) {
    if (Get-Command $cand[0] -ErrorAction SilentlyContinue) { $python = $cand; break }
}
if (-not $python) { Write-Host 'FAIL no python interpreter on PATH to serve the fixture'; exit 1 }
$port = Get-Random -Minimum 20000 -Maximum 40000
$server = $null
try {
    $server = Start-Process -FilePath $python[0] -ArgumentList ($python[1..($python.Count)] + @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $rel)) -PassThru
    $up = $false
    foreach ($i in 1..50) {
        try { $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $port); $c.Close(); $up = $true; break } catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $up) { throw "the fixture server did not come up on port $port" }
} catch {
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    throw
}
$env:MOX_BASE_URL = "http://127.0.0.1:$port"
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue

function Run([string]$bindir, [string[]]$extra) {
    $env:BINDIR = $bindir
    $out = & pwsh -NoProfile -File (Join-Path $repo 'install.ps1') @extra 2>&1 | Out-String
    return @{ Rc = $LASTEXITCODE; Out = $out }
}

try {
    Write-Host 'a verified release installs'
    $bin1 = Join-Path $work 'bin1'
    $r = Run $bin1 @()
    if ($r.Rc -eq 0 -and (Test-Path -LiteralPath (Join-Path $bin1 'mox.exe') -PathType Leaf)) { Ok 'the binary is installed' } else { No 'the binary is installed' $r.Out }
    if (-not (Test-Path -LiteralPath (Join-Path $bin1 'mox.exe.new')) -and -not (Test-Path -LiteralPath (Join-Path $bin1 'mox.exe.old'))) { Ok 'no staging file is left behind' } else { No 'no staging file is left behind' (Get-ChildItem $bin1 | Out-String) }

    Write-Host 'an install over an existing binary replaces it'
    Set-Content -LiteralPath (Join-Path $bin1 'mox.exe') -Value 'ORIGINAL' -NoNewline
    $r = Run $bin1 @()
    if ($r.Rc -eq 0 -and (Get-Content -LiteralPath (Join-Path $bin1 'mox.exe') -Raw) -eq 'fixture binary') { Ok 'the existing binary is replaced' } else { No 'the existing binary is replaced' $r.Out }
    if (-not (Test-Path -LiteralPath (Join-Path $bin1 'mox.exe.new')) -and -not (Test-Path -LiteralPath (Join-Path $bin1 'mox.exe.old'))) { Ok 'the stepped-aside binary is gone' } else { No 'the stepped-aside binary is gone' (Get-ChildItem $bin1 | Out-String) }

    Write-Host 'the replace is staged beside the target'
    $stale = Join-Path $work 'stale'
    New-Item -ItemType Directory -Path $stale | Out-Null
    Set-Content -LiteralPath (Join-Path $stale 'mox.exe.new') -Value 'leftover' -NoNewline
    $r = Run $stale @()
    if ($r.Rc -eq 0 -and (Get-Content -LiteralPath (Join-Path $stale 'mox.exe') -Raw) -eq 'fixture binary' -and -not (Test-Path -LiteralPath (Join-Path $stale 'mox.exe.new'))) { Ok 'a leftover staging file is replaced and gone' } else { No 'a leftover staging file is replaced and gone' (Get-ChildItem $stale | Out-String) }
    $blocked = Join-Path $work 'blocked'
    New-Item -ItemType Directory -Path (Join-Path $blocked 'mox.exe.new') | Out-Null
    Set-Content -LiteralPath (Join-Path $blocked 'mox.exe') -Value 'ORIGINAL' -NoNewline
    $r = Run $blocked @()
    if ($r.Rc -ne 0 -and (Get-Content -LiteralPath (Join-Path $blocked 'mox.exe') -Raw) -eq 'ORIGINAL') { Ok 'a directory squatting on the staging name refuses and leaves the binary' } else { No 'a directory squatting on the staging name refuses and leaves the binary' $r.Out }

    if ($IsWindows) {
        Write-Host 'the pass-through path'
        # cmd.exe is a self-contained program: as the fixture binary it can be
        # bootstrapped, and its exit code is the one the caller must see.
        $cmdrel = Join-Path $work 'cmdrel'
        New-Item -ItemType Directory -Path (Join-Path $cmdrel 'pkg') | Out-Null
        Copy-Item -LiteralPath $env:ComSpec -Destination (Join-Path $cmdrel 'pkg/mox.exe')
        Copy-Item -LiteralPath (Join-Path $rel $asset) -Destination (Join-Path $rel "$asset.orig")
        Compress-Archive -Path (Join-Path $cmdrel 'pkg/mox.exe') -DestinationPath (Join-Path $rel $asset) -Force
        $sum_cmd = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $rel $asset)).Hash.ToLower()
        Set-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Value "$sum_cmd  $asset`n$sum_arm  $asset_arm`n" -NoNewline
        $r = Run (Join-Path $work 'bincmd') @('/c', 'exit 42')
        if ($r.Rc -eq 42) { Ok "the bootstrapped command's exit code reaches the caller" } else { No "the bootstrapped command's exit code reaches the caller" "rc=$($r.Rc) $($r.Out)" }
        Move-Item -LiteralPath (Join-Path $rel "$asset.orig") -Destination (Join-Path $rel $asset) -Force
        Set-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Value $sums_both -NoNewline
    }

    Write-Host 'the arch picks the asset'
    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    $binarm = Join-Path $work 'binarm'
    $r = Run $binarm @()
    $armfile = Join-Path $binarm 'mox.exe'
    if ($r.Rc -eq 0 -and (Test-Path -LiteralPath $armfile -PathType Leaf) -and ((Get-Content -LiteralPath $armfile -Raw) -eq 'arm fixture binary')) { Ok 'an ARM64 machine installs the aarch64 asset' } else { No 'an ARM64 machine installs the aarch64 asset' $r.Out }
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'

    Write-Host 'refusals, and what they leave behind'
    $noline = Join-Path $work 'noline'
    Set-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Value "$sum_arm  $asset_arm`n" -NoNewline
    $r = Run $noline @()
    if ($r.Rc -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $noline 'mox.exe'))) { Ok 'a release whose SHA256SUMS lacks the asset refuses' } else { No 'a release whose SHA256SUMS lacks the asset refuses' $r.Out }
    Set-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Value $sums_both -NoNewline

    $isdir = Join-Path $work 'isdir'
    New-Item -ItemType Directory -Path (Join-Path $isdir 'mox.exe') | Out-Null
    Set-Content -LiteralPath (Join-Path $isdir 'mox.exe/marker') -Value 'keep'
    $r = Run $isdir @()
    if ($r.Rc -ne 0) { Ok 'a directory at the target refuses' } else { No 'a directory at the target refuses' 'exit 0' }
    if ((Test-Path -LiteralPath (Join-Path $isdir 'mox.exe/marker')) -and -not (Test-Path -LiteralPath (Join-Path $isdir 'mox.exe.old')) -and -not (Test-Path -LiteralPath (Join-Path $isdir 'mox.exe.new'))) { Ok 'the directory is left as it was' } else { No 'the directory is left as it was' (Get-ChildItem $isdir -Recurse | Out-String) }

    $keep = Join-Path $work 'keep'
    New-Item -ItemType Directory -Path $keep | Out-Null
    Set-Content -LiteralPath (Join-Path $keep 'mox.exe') -Value 'ORIGINAL' -NoNewline
    Set-Content -LiteralPath (Join-Path $rel 'SHA256SUMS') -Value ("0" * 64 + "  $asset`n") -NoNewline
    $r = Run $keep @()
    if ($r.Rc -ne 0) { Ok 'a checksum mismatch refuses' } else { No 'a checksum mismatch refuses' 'exit 0' }
    if ((Get-Content -LiteralPath (Join-Path $keep 'mox.exe') -Raw) -eq 'ORIGINAL') { Ok 'a refused install leaves the existing binary intact' } else { No 'a refused install leaves the existing binary intact' 'clobbered' }
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host "$passes passed, $fails failed"
if ($fails -gt 0) { exit 1 }
