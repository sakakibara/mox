# Run with: pwsh -NoProfile -File tests/windows_backends_test.ps1   (from the repo root)
#
# The Windows package adapters against the REAL scoop and winget.
#
# A manager that is present is probed READ-ONLY: nothing is installed, and
# no manifest declares a package this machine lacks that the run would then
# try to fetch. What is exercised is the QUERY path: whether each manager's
# export still has the JSON shape the adapter reads (`apps[].Name`,
# `Sources[].Packages[].PackageIdentifier`).
#
# scoop absent on a CI runner is the fresh-machine case, and is exercised as
# one: `mox apply` fetches the pinned installer, verifies its digest, installs
# scoop under a fixture profile and one app through it, and a fresh `mox
# status` sees both. That runs only under CI, because the installer edits
# the user's PATH in the registry.
#
# A manager that is absent anywhere else SKIPS, loudly and counted. A skip is
# never a pass: "this runner had no winget" must never read as "the winget
# adapter works".
$ErrorActionPreference = 'Stop'
# mox's exit code is read from $LASTEXITCODE: rc 1 for drift is an answer,
# not an error to stop on.
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("mox-winpkg-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$passes = 0; $fails = 0; $skips = 0

function Ok([string]$m)   { Write-Host "  ok   $m";                  $script:passes++ }
function No([string]$m, [string]$d) { Write-Host "  FAIL $m`n      $d"; $script:fails++ }
function Skip([string]$m, [string]$d) { Write-Host "  SKIP $m`n      $d"; $script:skips++ }

try {
    $mox = Join-Path $repo 'zig-out\bin\mox.exe'
    if (-not (Test-Path -LiteralPath $mox)) {
        Write-Host "building mox"
        & zig build --prefix (Join-Path $work 'out') | Out-Null
        $mox = Join-Path $work 'out\bin\mox.exe'
    }
    if (-not (Test-Path -LiteralPath $mox)) { throw "no mox binary at $mox" }

    # One fixture repo per backend, declaring a name no manager will ever
    # carry. status must report exactly that one MISSING, which it can only do
    # by having parsed the manager's export: a query that failed is an error,
    # and a query that returned nothing would make it missing for the wrong
    # reason (there would be no UNTRACKED rows either).
    # `mox <args>` with stdout and stderr captured apart: the packages section
    # header is on stdout, and an adapter error naming the section
    # (`mox status: packages: ...`) is on stderr, so a merged stream would let
    # the error satisfy the header check.
    function Invoke-Mox([string]$case, [string[]]$moxArgs) {
        $errFile = Join-Path $case ("stderr-" + [Guid]::NewGuid().ToString('N') + ".txt")
        $out = & $mox @moxArgs 2> $errFile | Out-String
        $rc = $LASTEXITCODE
        $err = if (Test-Path -LiteralPath $errFile) { Get-Content -Raw -LiteralPath $errFile } else { '' }
        if ($null -eq $err) { $err = '' }
        return @{ Out = $out; Err = $err; Rc = $rc }
    }

    function Tail([string]$text) {
        return ($text -split "`n" | Select-Object -Last 5 | Out-String)
    }

    function Probe([string]$backend, [string]$exe) {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            if ($backend -eq 'scoop' -and $env:CI) {
                BootstrapScoop
                return
            }
            Skip "$backend`: $exe is not on PATH" "install it on the runner to cover this adapter"
            return
        }

        $case = Join-Path $work $backend
        New-Item -ItemType Directory -Path (Join-Path $case 'repo\src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $case 'repo\data\packages') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $case 'state') -Force | Out-Null
        @"
backend = "$backend"

[[packages]]
name = "mox-absent-probe-package"
"@ | Set-Content -LiteralPath (Join-Path $case "repo\data\packages\$backend.toml") -Encoding utf8

        $env:MOX_REPO = Join-Path $case 'repo'
        $env:MOX_STATE_DIR = Join-Path $case 'state'
        $run = Invoke-Mox $case @('status')
        Remove-Item Env:\MOX_REPO, Env:\MOX_STATE_DIR -ErrorAction SilentlyContinue
        $out = $run.Out

        if ($out -match "packages:") {
            Ok "$backend`: the manager answered and a packages section was reported"
        } else {
            No "$backend`: no packages section" (Tail ($out + $run.Err))
            return
        }

        if ($out -match "MISSING\s+$backend\s+mox-absent-probe-package") {
            Ok "$backend`: a package no machine has is reported MISSING"
        } else {
            No "$backend`: expected the probe package MISSING" (Tail $out)
        }

        # The export parsed into real ids. Without this a query that silently
        # returned nothing would still satisfy the MISSING check above.
        $untracked = ([regex]::Matches($out, "UNTRACKED\s+$backend\s+(\S+)"))
        if ($untracked.Count -gt 0) {
            Ok "$backend`: the export parsed into $($untracked.Count) installed id(s)"
            $longest = ($untracked | ForEach-Object { $_.Groups[1].Value.Length } | Measure-Object -Maximum).Maximum
            if ($longest -lt 200) {
                Ok "$backend`: ids come back one per entry"
            } else {
                No "$backend`: an id is $longest chars; the export lost its per-entry split" `
                   ($untracked[0].Groups[1].Value.Substring(0, 100))
            }
        } else {
            Skip "$backend`: the manager reports nothing installed on this runner" `
                 "the parse path is not covered here"
        }

        if ($run.Err -match "mox status: packages:") {
            No "$backend`: the adapter reported an error" ($run.Err -split "`n" | Where-Object { $_ -match 'packages:' } | Out-String)
        }
    }

    # The fresh-machine case: no scoop, a manifest that declares its installer
    # and one app, and one `mox apply` that must end with both present. The
    # profile is a fixture directory, which is where the installer puts scoop
    # (`$env:USERPROFILE\scoop`) and where the adapter expects its shims.
    function BootstrapScoop {
        $backend = 'scoop'
        $case = Join-Path $work 'scoop-bootstrap'
        $fixtureHome = Join-Path $case 'home'
        New-Item -ItemType Directory -Path (Join-Path $case 'repo\src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $case 'repo\data\packages') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $case 'state') -Force | Out-Null
        New-Item -ItemType Directory -Path $fixtureHome -Force | Out-Null
        # scoop's installer at a fixed commit, and what it must hash to; a
        # fresh machine's manifest carries the same pair.
        @"
backend = "scoop"

[[bootstrap]]
url = "https://raw.githubusercontent.com/ScoopInstaller/Install/1e2f334083d609986d8c8bc9e31ae8e87c39fab4/install.ps1"
sha256 = "94f983b190438311e006b957db7c8422709e0ba62a6c2ac04e278164108f2512"

[[packages]]
name = "7zip"
"@ | Set-Content -LiteralPath (Join-Path $case 'repo\data\packages\windows.toml') -Encoding utf8

        $saved = @{ HOME = $env:HOME; USERPROFILE = $env:USERPROFILE; PATH = $env:PATH }
        try {
            $env:MOX_REPO = Join-Path $case 'repo'
            $env:MOX_STATE_DIR = Join-Path $case 'state'
            $env:HOME = $fixtureHome
            $env:USERPROFILE = $fixtureHome
            $apply = Invoke-Mox $case @('apply')

            if ($apply.Rc -eq 0) {
                Ok "$backend`: apply on a machine without scoop exits 0"
            } else {
                No "$backend`: apply exited $($apply.Rc)" (Tail ($apply.Out + $apply.Err))
            }
            if ($apply.Out -match "bootstrapping\s+scoop") {
                Ok "$backend`: an absent manager is bootstrapped from its declared installer"
            } else {
                No "$backend`: apply did not bootstrap scoop" (Tail $apply.Out)
            }
            if ($apply.Out -match "Packages: 1 installed, 0 failed") {
                Ok "$backend`: the same apply installed through the manager it just bootstrapped"
            } else {
                No "$backend`: apply did not report a successful install" (Tail ($apply.Out + $apply.Err))
            }

            # A fresh process finds scoop only through its shims: the
            # installer's PATH edit is in the registry, not this process.
            $env:PATH = (Join-Path $fixtureHome 'scoop\shims') + ';' + $env:PATH
            $status = Invoke-Mox $case @('status')
            if ($status.Out -match "clean\s+scoop" -or $status.Out -match "UNTRACKED\s+scoop\s") {
                Ok "$backend`: the bootstrapped manager answers a fresh status"
            } else {
                No "$backend`: status after apply got no answer from scoop" (Tail ($status.Out + $status.Err))
            }
            if ($status.Out -match "MISSING\s+scoop\s+7zip") {
                No "$backend`: 7zip is still MISSING after apply" (Tail $status.Out)
            } else {
                Ok "$backend`: the drift is clean after apply"
            }
        } finally {
            Remove-Item Env:\MOX_REPO, Env:\MOX_STATE_DIR -ErrorAction SilentlyContinue
            $env:HOME = $saved.HOME
            $env:USERPROFILE = $saved.USERPROFILE
            $env:PATH = $saved.PATH
        }
    }

    Probe 'scoop'  'scoop'
    Probe 'winget' 'winget'

    Write-Host ""
    if ($skips -gt 0) {
        Write-Host "$passes passed, $fails failed, $skips skipped"
    } else {
        Write-Host "$passes passed, $fails failed"
    }
    if ($fails -gt 0) { exit 1 }
    # A skip is never a pass. On a developer machine an absent manager is a
    # fact of life; on CI it means this gate proved nothing it exists to
    # prove, so it fails the run.
    if ($env:CI -and $skips -gt 0) {
        Write-Host "CI: $skips case(s) skipped; this gate must run them all"
        exit 1
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
