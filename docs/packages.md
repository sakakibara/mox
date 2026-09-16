# Packages

mox manages installed packages the same way it manages files: a manifest
declares what belongs on a machine, `mox status` reports the difference,
`mox apply` closes it, and `mox commit` records what you did by hand.

A repo with no `data/packages/` directory is not using any of this. No
section prints, no package manager is queried, and no exit code changes.
Creating that directory is what opts in.

## The manifest

`data/packages/*.toml`, read from the repo and the private layer. Each file
is a mox data source in the same `[[rows]]` shape as `data/completions.toml`
and `data/facts.toml`.

```toml
# data/packages/darwin.toml
backend = "brew"

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
| `when` | An axis expression, the same grammar as `# mox: when` -- os, arch, profile, tool, env. |

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

## Backends

A backend is **registered** if mox has an adapter for it, and **usable** if
this machine can run it. A `dnf` row on a mac names a registered adapter that
is simply inert here; a row naming `dnff` is a typo and is an error. That
distinction is what lets one manifest carry every machine's packages.

| Backend | Identity | Explicitly installed | Row keys |
|---|---|---|---|
| `brew` | name; a cask is a separate namespace | `brew list --full-name --installed-on-request`, `brew list --cask` | `kind` (`formula`, `cask`) |
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
its re-capture: a pre-script is what installs the package manager itself on a
fresh machine, and a package installed here is a tool the re-capture must
see. The whole set for a backend goes to its manager in one invocation, and
the manager's own output is streamed rather than captured, so progress and
errors reach the terminal as they happen. `--dry-run` lists what it would
install and installs nothing.

apply **only ever installs**. Removal is never automatic: an untracked
package is reported and reconciled, never uninstalled behind you.

`mox commit` offers each untracked package:

- **add** -- append a row to the manifest file that already speaks that
  backend, with whichever adapter fields identify it
- **blacklist** -- append a `[[blacklist]]` row so it is never offered again
- **skip** -- leave it untracked

A row is always **appended**, never edited in place, so every existing byte
of that file -- comments, ordering, a row you were mid-thought on -- survives
untouched. A path-scoped `mox commit <file>` names files and skips packages
entirely.

## Adding a backend

One adapter file implementing `available`, `validate`, `idOf`,
`installedExplicit`, `install` and `declare`, plus a line in the registry.
The manifest format and the core (loading, gating, drift, reconcile) do not
change -- adding apt, dnf, pacman, scoop, winget and zypper touched none of
them.

Two contracts are worth stating for a new adapter:

- `idOf` must keep apart anything the manager keeps apart. brew casks carry a
  prefix for exactly this reason: without it a declared `docker` cask would be
  satisfied by the `docker` formula.
- `declare` is the inverse of `idOf`: given an id the manager reported, it
  returns the row that would name it. `idOf(declare(id))` must equal `id`, or
  a reconciled row will not match the package it came from.

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

All three run nightly in CI. Both bugs the container suite was written after
were invisible to the hermetic tests: dnf5 concatenating every name onto one
line when its format string lacks a trailing newline, and a minimal image
having no `sudo`, which made elevating unconditionally fail every install.
