# Run with: pwsh -NoProfile -File tests/windows_backends_test.ps1   (from the repo root)
#
# The Windows package adapters against the REAL scoop and winget.
#
# READ-ONLY: nothing is installed, and no manifest declares a package this
# machine lacks that the run would then try to fetch. What is exercised is the
# QUERY path: whether each manager's export still has the JSON shape the
# adapter reads (`apps[].Name`, `Sources[].Packages[].PackageIdentifier`).
#
# A manager that is absent SKIPS, loudly and counted. A skip is never a pass:
# "this runner had no winget" must never read as "the winget adapter works".
$ErrorActionPreference = 'Stop'
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
    function Probe([string]$backend, [string]$exe) {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
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
        $out = & $mox status 2>&1 | Out-String
        Remove-Item Env:\MOX_REPO, Env:\MOX_STATE_DIR -ErrorAction SilentlyContinue

        if ($out -match "packages:") {
            Ok "$backend`: the manager answered and a packages section was reported"
        } else {
            No "$backend`: no packages section" ($out -split "`n" | Select-Object -Last 5 | Out-String)
            return
        }

        if ($out -match "MISSING\s+$backend\s+mox-absent-probe-package") {
            Ok "$backend`: a package no machine has is reported MISSING"
        } else {
            No "$backend`: expected the probe package MISSING" ($out -split "`n" | Select-Object -Last 5 | Out-String)
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

        if ($out -match "mox status: packages:") {
            No "$backend`: the adapter reported an error" ($out -split "`n" | Where-Object { $_ -match 'packages:' } | Out-String)
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
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
