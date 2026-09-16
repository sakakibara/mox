# Packages

mox manages installed packages the same way it manages files: a manifest
declares what belongs on a machine, `mox status` reports the difference,
`mox apply` closes it, and `mox commit` records what you did by hand.

A repo with no `data/packages/` directory is not using any of this. No
section prints, no package manager is queried, and no exit code changes.
Creating that directory is what opts in.

## The manifest

`data/packages/*.toml`, read from the repo and the private layer. Each file
is a mox data source: arrays of tables, the shape `data/completions.toml`
and `data/facts.toml` already use.

```toml
# data/packages/darwin.toml
backend = "brew"
when = "os=darwin"

[[packages]]
name = "ripgrep"

[[packages]]
name = "d12frosted/emacs-plus/emacs-plus@30"
when = "profile=personal"

[[packages]]
name = "ghostty"
kind = "cask"

[[blacklist]]
name = "usage"
```

Files are free grouping: `darwin.toml`, `fedora.toml`, a private
`local.toml`. A private file **shadows** a repo file of the same basename and
**adds to** the set under any other name, so machine-local packages live
beside the shared list without replacing it.

### Core keys

| Key | Meaning |
|---|---|
| `name` | The backend-native identifier. Required. |
| `backend` | Which manager. Per row, or once per file as a top-level default. Must name a registered adapter. |
| `when` | An axis expression, the same grammar as `# mox: when` -- os, arch, profile, tool, env. Per row, or once per file as a top-level gate on every row in it; a row's own `when` narrows the file's (`(file) and (row)`). |

Every other key belongs to the backend adapter (below). An unknown key, a
missing required one, or a wrong type is an error naming the file and the
row, checked on every machine rather than only where that manager runs.

### Blacklist

`[[blacklist]]` rows are installed-but-never-offered: a one-off you do not
want tracked. They take `name`, `backend`, and whichever adapter keys
identify the package (a blacklisted brew cask carries `kind = "cask"`, or it
would name the formula instead). They take no `when` -- a blacklist holds
regardless of which machine is asking.

Declaring the same package in `[[packages]]` and `[[blacklist]]` is a
contradiction and is refused.

### Bootstrap

A `[[bootstrap]]` row names the installer for a manager that may be absent:

```toml
[[bootstrap]]
backend = "brew"
url = "https://raw.githubusercontent.com/Homebrew/install/<commit>/install.sh"
sha256 = "<hex>"
when = "os=darwin"
```

`backend` may come from the file default and `when` from the file gate, as
for any row. `mox apply` runs it only when the row's gate holds and the
backend's `available` says the manager is absent: the file is fetched,
refused unless it hashes to the declared sha256, handed to the backend, and
deleted afterwards. brew and scoop know how to run their installers and
where the result lands, so the same apply installs packages through the
manager it just put in place; a plugin runs `bootstrap <path>` itself and
reports the directory to put on PATH. An installer over 64 MiB is refused.
`--dry-run` fetches nothing and plans as though the bootstrap had happened,
so what it lists is what the real run would install.

## Backends

A backend is **registered** if mox has an adapter for it, and **usable** if
this machine can run it. A `dnf` row on a mac names a registered adapter that
is simply inert here; a row naming `dnff` is a typo and is an error. That
distinction is what lets one manifest carry every machine's packages.

| Backend | Identity | Explicitly installed | Row keys |
|---|---|---|---|
| `brew` | name; a cask is a separate namespace | `brew list --full-name --installed-on-request`, `brew list --cask --full-name` | `kind` (`formula`, `cask`) |
| `apt` | name | `apt-mark showmanual` | -- |
| `dnf` | name | `dnf repoquery --userinstalled` | -- |
| `pacman` | name | `pacman -Qeq` | -- |
| `zypper` | name | a mox-kept ledger (see below) | -- |
| `scoop` | name; a bucket is provenance, not identity | `scoop export` | `bucket` |
| `winget` | `PackageIdentifier` | `winget export` | `source`, `scope` (`user`/`machine`), `override` |

### brew taps

A tap is not a key. A tap-qualified name names its own tap, and declaring
such a row **is** the decision to trust it:

```toml
[[packages]]
name = "d12frosted/emacs-plus/emacs-plus@30"
```

mox taps it and trusts that one formula (`brew trust --formula`), never the
whole tap -- an untrusted third-party tap is ignored outright since Homebrew
6.0, and whole-tap trust would extend to everything it ever adds. A cask from
a third-party tap is trusted as a cask; the two namespaces are distinct.

### zypper's ledger

zypper has no explicitly-installed query (`--userinstalled` is not a flag it
knows, and `--installed-only` includes every dependency), so mox records what
it installed in `<state_dir>/zypper.txt` and treats that as the explicit set.

That record is never trusted on its own: it is intersected with what `rpm`
reports actually present, so a package removed behind mox's back drops out,
is reported missing, and is reinstalled rather than assumed to be there.

The cost is that a package installed by hand is invisible to mox on zypper
and will never be offered for tracking. `mox status` prints that as a note
under the backend rather than leaving it to be discovered.

## Drift

- **MISSING** -- declared for this machine, not installed.
- **UNTRACKED** -- installed, declared nowhere in the manifest, not
  blacklisted.

Untracked is measured against every row the manifest declares, not only the
ones desired here: a package gated to another profile is already tracked, and
offering to re-add it would write a second row for something the manifest
already carries.

Package drift counts toward `mox status`'s exit code exactly as file drift
does, and `--json` / `--porcelain` carry both sets (see
[commands.md](commands.md#status)).

## Installing and reconciling

`mox apply` installs what is missing, after the pre-script stage and before
its re-capture, so a package installed here is a tool the re-capture sees; a
declared manager that is absent is bootstrapped first (above). The whole set
for a backend goes to its manager in one invocation -- brew is the
exception, installing row by row so one failure leaves the rest to proceed
-- and the manager's own output is streamed rather than captured, so
progress and errors reach the terminal as they happen. A batch that failed
may have landed some of its rows, so the re-capture runs after any attempt.
`--dry-run` lists what it would install and installs nothing.

apply **only ever installs**. Removal is never automatic: an untracked
package is reported and reconciled, never uninstalled behind you.

`mox commit` offers each untracked package:

- **add** -- append a row to the manifest file that already speaks that
  backend, with whichever adapter fields identify it
- **blacklist** -- append a `[[blacklist]]` row so it is never offered again
- **skip** -- leave it untracked

A row is always **appended**, never edited in place, so every existing byte
of that file -- comments, ordering, a row you were mid-thought on -- survives
untouched, and it is appended the moment it is chosen: `q` at a package
prompt ends the run before the file pass and says how many rows were already
recorded (rc 1), and `--abort-on-prompt` exits 2 at the first package prompt
the same way. A path-scoped `mox commit <file>` names files and skips
packages entirely.

## Adding a backend

Any package manager can be given a backend without rebuilding mox. The seven
above are compiled in because they are what mox supports out of the box, with
no shell dependency; everything else is a **plugin**: an executable in the
repo that speaks the protocol below. A plugin satisfies exactly the same
contract as a compiled backend, so `status`, `apply` and `commit` cannot tell
them apart. What stays fixed by mox is the set of things a backend is asked to
do -- there is no `remove` or `upgrade` verb, and adding one is a mox change.

### Where

`scripts/backends/<name>`, flat, repo only. The name is the filename stem:
`macports` and `macports.ps1` both name `macports`, so one plugin can ship a
POSIX script and a PowerShell twin. Names are `[A-Za-z0-9_-]`.

- Unix runs a plain file directly; it must be executable (`chmod +x`), and
  one that is not is an error naming the file -- never "no such backend". A
  Windows-only kind (`.ps1`, `.exe`, `.cmd`) is *not runnable here*: a note,
  not an error, and a manifest row naming it is inert rather than refused.
- Windows has no executable bit, so kind decides: `.ps1` runs through pwsh,
  `.exe` and `.cmd` directly. Any other file is *not runnable here*, printed
  as a note under `packages:`, so a MacPorts script in a shared repo neither
  breaks nor silently vanishes on a Windows machine.

There is no axis gating (`os=darwin/`) and no private-layer shadowing.
Whether a backend is usable on this machine is its own `available` verb, and
nothing else: a plugin hidden under an `os=` directory would be undiscovered
elsewhere, and every shared-manifest row naming it would read as a typo there.

A plugin named like a shipped backend overrides it, and `status` says
`note  brew: scripts/backends/brew overrides the built-in` on every run.

### The protocol

| Verb | stdin | stdout | Exit |
|---|---|---|---|
| `available` | -- | -- | 0 usable here; 1 not usable here; anything else is a broken plugin |
| `id` | one row, `{ name = "...", ... }` | exactly one id | 1: the row is refused, say why on stderr; 64: not implemented; anything else is a broken plugin |
| `list` | -- | one id per line: what was explicitly installed | nonzero: failed |
| `install` | rows, one per line | streamed to the terminal | nonzero: failed |
| `declare <id>` | -- | a TOML row body: `name = "..."` plus adapter fields | 64: not implemented; other nonzero: failed |
| `bootstrap <path>` | -- | optionally one line: a directory to put on PATH | 64: not implemented |
| `limitation` | -- | one line on what it cannot see | 64: none |

Rows arrive as TOML inline tables carrying `name` and the row's adapter
keys -- never `backend` or `when`, which are mox's. `id` is asked one row at
a time and must answer exactly one line; `install` gets every row of the
batch, one per line. A plugin's stderr is the terminal's for every verb, so
a refusal reason or a crash is seen as written. Ids are opaque to mox: it
compares them and never parses them, so a manager with two namespaces
prefixes them itself (`cask:ghostty`) and the manifest row still spells
`name = "ghostty"`, `kind = "cask"` -- the same shape as for a compiled
backend.

- **`id` is both validate and idOf.** A row the plugin cannot name is refused
  with the plugin's own reason, which is stronger than any key list mox could
  check. A refused row fails on every machine that reads the manifest, not
  only where the manager runs.
- **`declare` is checked, not trusted.** The row it returns is handed back to
  `id`, and refused unless the answer is the id it came from. A plugin whose
  two halves disagree cannot write a row that will never match its package.
  The row is `name` plus adapter keys: one carrying `backend` or `when`, or
  a key outside `[A-Za-z0-9_-]`, is refused.
- **`install` gets the whole set.** A manager that resolves a batch in one
  pass gets one call; a per-item manager loops over its stdin.
- **No ledger mode.** A manager with no explicitly-installed query keeps its
  own record under `$MOX_STATE_DIR` and intersects it in `list`; `list` has
  one meaning.
- **Exit 64 means "this verb is not implemented"**, reported by plugin and
  verb where it was needed. Nothing is substituted for a missing verb.
- Every call is time-bounded like a setup script (`MOX_SCRIPT_TIMEOUT_MS`);
  a `list` blocked on a manager's lock is a timeout failure naming the
  backend, not a hung `mox status`. The shipped backends' own manager calls
  are bounded the same way.
- Output is split on newline and trimmed of `\r` (a PowerShell plugin emits
  CRLF); an id that is empty, contains whitespace, or exceeds 256 bytes is an
  error naming the plugin. That catches a lost line separator across a large
  set; a fixture test in your repo is the real defence.

`bootstrap` runs only when the manifest declares a `[[bootstrap]]` row for
the backend and `available` says the manager is absent. mox fetches the
installer and refuses to hand it over unless it hashes to the declared
sha256; the plugin then runs the verified file however its manager needs.
Progress goes to stderr; the one line on stdout, if any, is a bin dir mox
puts on PATH so the same run can use what was just installed.

### Environment and which commands run a plugin

A plugin runs as you, at the trust `scripts/pre` already has, under the
same environment a setup script gets: `MOX_REPO`, `MOX_STATE_DIR`,
`MOX_HOME`, `PATH` and every fact as `MOX_FACT_*`. That holds for `status`
and `commit` as much as for `apply`; only `apply` refreshes the state bin dir
on the way. `status` runs `available`, `list`, `id` and `limitation`; `commit` adds
`declare`; `apply` adds `install` and `bootstrap`; `--dry-run` runs the
read-only set. `status` lists every discovered plugin by path before it runs
anything.

### A complete plugin

MacPorts, as a POSIX script at `scripts/backends/macports`:

```sh
#!/bin/sh
set -eu
cmd=${1:-}; shift || true
name() { printf '%s\n' "$1" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'; }
case "$cmd" in
available) command -v port >/dev/null 2>&1 ;;
id)        while IFS= read -r l; do [ -n "$l" ] || continue; name "$l"; done ;;
list)      port -q echo requested | awk 'NF { print $1 }' ;;
install)   set --; while IFS= read -r l; do [ -n "$l" ] || continue; set -- "$@" "$(name "$l")"; done
           sudo port -N install "$@" ;;
declare)   printf 'name = "%s"\n' "$1" ;;
limitation) echo "variants are not tracked; a port is matched by name alone" ;;
*)         exit 64 ;;
esac
```

That is longer than a purely declarative form of the same thing would be, and
that is accepted: a schema rich enough to also express a ledger, a second
namespace, or running an installer is a scripting language in TOML, and the
first manager with a quirk it lacks would need a mox release again.

## Testing

`zig build test` is hermetic: every manager call goes through a scripted
runner, so it passes with no package manager installed and never touches the
machine running it. That proves an adapter emits the argv it intends, and
nothing more.

Whether that argv is *right* is a separate gate, because it cannot be
answered without the real thing:

| Gate | Covers |
|---|---|
| `zig build test-backends` | brew, read-only, differential against brew's own output |
| `sh tests/linux_backends_test.sh` | apt, dnf, zypper, pacman -- a full install round trip per distro, in containers |
| `pwsh -NoProfile -File tests/windows_backends_test.ps1` | scoop, winget, read-only |

All three run nightly in CI. Only the real manager can say whether a query's
format string still yields one name per line, or whether an image without
`sudo` installs at all; the hermetic tests cannot.
