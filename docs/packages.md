# Packages

mox manages installed packages the same way it manages files: a manifest
declares what belongs on a machine, `mox status` reports the difference,
`mox apply` closes it, and `mox commit` records what you did by hand.

A repo with no `data/packages/` directory is not using any of this. No
section prints, no package manager is queried, and no exit code changes.
Creating that directory is what opts in, even before it holds a file: every
manager is then queried and what it has installed is reported UNTRACKED.
The first file is yours to create (`backend = "brew"` on its own is enough);
from then on `mox commit` fills it.

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
```

A `[[blacklist]]` row holds on every machine, so it belongs in a file with no
top-level `when`:

```toml
# data/packages/shared.toml

[[blacklist]]
name = "usage"
backend = "brew"
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
| `when` | An axis expression, the same grammar as `# mox: when` -- os, arch, profile, tool, env. Per row, or once per file as a top-level gate on every `[[packages]]` and `[[bootstrap]]` row in it; a row's own `when` narrows the file's (`(file) and (row)`). A `[[blacklist]]` row takes no gate and may not sit in a gated file. |

A refusal names a row by its position in its array, counting from zero -- the
same numbering `mox commit` uses for a data source's rows.

Every other key belongs to the backend adapter (below). An unknown key, a
missing required one, or a wrong type is an error naming the file and the
row, checked on every machine rather than only where that manager runs. So
is a top-level key the format does not define (`[[package]]`, singular,
would otherwise load as no rows at all and report a clean machine), a `name`
that is blank, runs past 256 bytes, or carries whitespace, control
characters or bytes that are not UTF-8 -- one rule with the shape an id must
have, so a row an adapter writes is a row this loader reads back -- a second
`[[bootstrap]]` row for one backend, and two `[[packages]]` rows that name
one package under the same gate -- the last checked ungated, so a pair gated
to another OS is refused here rather than on the machine it breaks. A file
that begins with a byte order mark is refused by name, since the TOML parser
cannot read past it.

### Blacklist

`[[blacklist]]` rows are installed-but-never-offered: a one-off you do not
want tracked. They take `name`, `backend`, and whichever adapter keys
identify the package (a blacklisted brew cask carries `kind = "cask"`, or it
would name the formula instead). They take no `when` -- a blacklist holds
regardless of which machine is asking -- and for the same reason a file whose
top-level `when` would gate them is refused: put them in an ungated file.
`mox commit` writes a blacklist row into an ungated file that declares the
backend, and says so rather than writing one the next command would refuse.
Where every repo file is gated, the row goes to an ungated file in the
private layer: narrower than the gate the rule refuses, and narrower is what
that layer means -- the row holds on this machine and is in no other
machine's manifest to sit inert in. commit prints the layer it wrote to.

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

`sha256` is 64 hexadecimal characters, either case, and a value of any other
shape is refused when the manifest loads rather than on the one machine that
fetches, where a truncated paste is indistinguishable from a substituted
installer.

`backend` may come from the file default and `when` from the file gate, as
for any row, and is checked the same way: a row for a manager that ships
with its OS (apt, dnf, pacman, zypper, winget) is refused on every machine,
since there is no installer to run, and a row for a plugin this machine
cannot run is left to the machine that can. `mox apply` runs it only when
the row's gate holds and the backend's `available` says the manager is
absent: the file is fetched, refused unless it hashes to the declared
sha256, handed to the backend, and deleted afterwards whether the bootstrap
succeeded or not. brew and scoop know how to run their installers and where
the result lands, so the same apply installs packages through the manager
it just put in place; a plugin runs `bootstrap <path> <out>` itself, streamed
like an install, and writes the directory to put on PATH -- one absolute
existing directory -- as one line into `<out>`, if there is one. If a
bootstrap fails, the rows of that manager are not attempted and the run
fails.
An installer over 64 MiB is refused. `--dry-run` fetches nothing and plans
as though the bootstrap had happened, so what it lists is what the real run
would install, and `status` reports the rows of an absent manager that has
a bootstrap row as MISSING, with a note that apply will bootstrap it, rather
than as a clean machine.

## Backends

A backend is **registered** if mox has an adapter for it, and **usable** if
this machine can run it. A `dnf` row on a mac names a registered adapter that
is inert here; a row naming `dnff` is a typo and is an error. That
distinction is what lets one manifest carry every machine's packages.

Usable is decided by a probe (`<manager> --version`; `apt-get` for
apt). A manager that is not
there is absent and its rows are inert. One that is there but exits nonzero
is *broken*: `status` reports it as drift of its own (below) rather than as
a clean machine, and its rows are neither judged nor installed. When no
package manager at all is usable here, `status` notes
`no package manager is usable on this machine`.

| Backend | Identity | Explicitly installed | Row keys |
|---|---|---|---|
| `brew` | name; a cask is a separate namespace | `brew list --full-name --installed-on-request`, `brew list --cask --full-name`, both under `HOMEBREW_NO_AUTO_UPDATE=1`, so a read-only `status` never refreshes brew's cached API data on a timer (a cache that does not exist yet is still populated once). The cask half is not an explicit-install query (below) | `kind` (`formula`, `cask`) |
| `apt` | name | `apt-mark showmanual`; an install runs `apt-get update` first, so the index it resolves against is current | -- |
| `dnf` | name | `dnf -q repoquery --userinstalled --qf %{name}\n` (`-q` because dnf4 writes its metadata line to stdout; the format string because its default packs several to a line) | -- |
| `pacman` | name | `pacman -Qeq`; an install is `pacman -Syu --needed --noconfirm`, which upgrades the whole system, since a partial sync is not something Arch supports | -- |
| `zypper` | name | a mox-kept ledger (see below) | -- |
| `scoop` | name; a bucket is provenance, not identity | `scoop export` | `bucket` |
| `winget` | `PackageIdentifier` | `winget export`, which reports only what a source supplied (below) | `source`, `scope` (`user`/`machine`), `override` |

An export reports identifiers alone, so a package is one row: two rows for
one identifier under different scopes are a duplicate, not two packages.

An install through scoop adds a row's bucket only when `scoop bucket list`
does not already have it, and winget installs with `--no-upgrade` and then
asks `winget list` whether a failed install is nonetheless there: both
managers answer a second `apply` with an error otherwise, and winget's exit
codes cannot be told apart once truncated to a byte. zypper's ledger records what a failed batch still
landed, read back from `rpm`, so a package installed beside one that failed
is not asked for again.

### What an apt, dnf, pacman or zypper row may name

`name` on these four is a plain package name, and mox checks it against what
a package name is rather than against a list of what it is not: it begins
with a letter or a digit, holds only letters, digits and `.`, `_`, `+` or
`-`, and does not end with `-`. A trailing `+` is fine, since `g++` is a
package.

Two things sit outside that class. An install argv accepts more than package
names -- `apt-get install -y vim nano-` removes nano, and `zypper install vim
!nano` and `zypper install vim -nano` do the same -- and mox never uninstalls
anything, so a row that would ask for one is refused rather than run. And a
name a manager resolves to a package of a different name
(`pkgconfig(libcrypto)` installs `libressl-devel`) is recorded under the name
asked for, so it would read as missing on every status and be reinstalled on
every apply.

The refusal names the file, the row and the rule the name broke, and it is
checked on every machine, not only where that manager runs. dnf takes a full
NEVRA and a bare `name.arch` within that class, which `rpm` reports under the
bare name; both are refused for the same reason. Beyond the check, the
operands are passed after `--`, so nothing a row is named can be read as an
option.

apt is the one exception to the plain name, because its own
`apt-mark showmanual` reports a foreign-architecture package qualified: an
apt row may carry one `:<arch>` suffix, as in `libc6:armhf`, where the
architecture holds only letters, digits and `-`. The colon stays refused on
dnf, pacman and zypper, whose queries never answer with one -- zypper reads
it as a selector separator (`pattern:`, `patch:`) instead.

Whether the manager actually **has** a package of that name is a separate
question, asked where the install is rather than at load, since only the
manager can answer it and a manifest must read the same on every machine.
Before an apt install, mox asks `apt-cache --generate pkgnames` -- apt's one
literal-matching whole-universe query -- and refuses a row naming anything
absent from it: `apt-get install` otherwise falls back to reading the operand
as an unanchored regular expression, so `libz.dev` installs ten packages the
manifest never declared and `ruby.dev` installs hundreds. That listing holds
bare names alone, and it omits a package that exists only for a foreign
architecture -- `wine32` is in no listing on an amd64 or arm64 machine, while
apt installs `wine32:i386` and `apt-mark showmanual` reports exactly that --
so a row carrying an architecture is asked about as written, with
`apt-cache madison`, the query verified to match a qualified name literally
where `apt-cache show` and `apt-cache policy` both fall back to a regex.
Before a dnf install, mox asks `dnf repoquery` the same question, and a name
that is only an rpm capability rather than a package -- `zlib-devel`, which
`zlib-ng-compat-devel` provides -- is refused with the name to declare in its
place. Before a pacman install, mox reads `pacman -Slq`, and a name that is a
package **group** rather than a package -- `xfce4`, which holds fourteen --
is refused with the members named, since `pacman -S` installs every one of
them and `pacman -Qeq` reports the members and never the group. That check
only reads: pacman's database is downloaded only if the listing comes back
empty, which is a machine that has never synced, and what runs then is the
full `pacman -Syu` the install itself was about to run, never a bare
`pacman -Sy` -- which would leave the database ahead of the installed
packages, a state Arch does not support, on every path that then refuses a
row or fails.

An apt row qualified with the machine's own architecture is refused the same
way, as are apt's `:native`, `:all` and `:any`, which apt resolves to the
native package that `apt-mark` then reports bare.

A refused row installs nothing, and it is refused alone: the rows beside it
in the same manifest are installed, and the run counts the refusal as that
row's own failure and exits non-zero over it. One row nobody can install does
not keep every other package off the machine.

These checks run the manager, so `mox apply --dry-run` does not run them: a
dry run lists a row a real apply would refuse as one it would install, and
says so in a note beside the rows it left unchecked.

### What a brew, scoop or winget row may name

These three have grammars of their own, so each has its own class.

A brew `name` is one formula or cask, or a tap-qualified `owner/tap/name`.
Each part begins with a letter or a digit and holds only letters, digits and
`.`, `_`, `+`, `-` or `@` -- `@` because `openssl@3` and `emacs-plus@30` are
real formulae. Everything else a brew operand can be is refused: an option
(`brew install --help` exits 0 having installed nothing, so such a row would
be counted installed, reported missing by the query that follows, and
installed again on every apply), a local Ruby file (`brew install ./x.rb`
runs it), a URL, and `owner/tap` alone, which names a tap rather than
anything `brew list` can report back. Beyond the check, every name mox hands
brew comes after a `--`.

A scoop `name` is one app: a single token of letters, digits and `.`, `_`,
`+` or `-`. So a row cannot be a manifest path or a URL (scoop installs
either), a bucket-qualified name (the bucket is a key of its own), or a
pinned version: `scoop install git@2.1` installs a version that
`scoop export` reports under the bare name, which reads as missing on every
status after.

A winget `name` is one `PackageIdentifier`, and that one is deliberately
wider: an identifier is the publisher's own string (`Notepad++.Notepad++`, a
bare store id), mox cannot enumerate them, and a class narrower than
winget's would refuse a package someone really has. So the rule names what
would make the value something else instead -- it begins with a letter or a
digit, and holds none of `\`, `/`, `:`, `*`, `?`, `"`, `<`, `>` or `|`,
which is what a path, a URL, a pattern or an option needs.

The field values that reach a manager's argv are checked too, because they
land where a name lands. scoop's `bucket` and winget's `source` are each one
token, and are held to the single-token class. winget's `override` is not, and
cannot be -- it exists to hand a command line on to the package's own
installer, so a space and a slash are what it is for -- but it may hold no
`"` and no control byte: those are the bytes no argv carries intact across
both of Windows' command-line parsers, so a value holding one is not the
value the installer would receive.

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

### What a manager cannot be asked

Three of the queries above answer a narrower question than "what did the user
ask for", and each backend says so as a note under itself in `status`, the
way zypper does below.

brew declares `--cask` and `--installed-on-request` as conflicting options, so
there is no explicit-install query for casks: `brew list --cask --full-name`
is the whole Caskroom, and a cask another cask pulled in through
`depends_on cask:` is reported untracked until it is declared or blacklisted.

`winget export` reports only packages a source supplied, so one installed
outside a source is invisible to it: its row is reported missing on every
status, and an install mox runs for it reports success each time.

### zypper's ledger

zypper has no explicitly-installed query (`--userinstalled` is not a flag it
knows, and `--installed-only` includes every dependency), so mox records what
it installed in `<state_dir>/zypper.txt` and treats that as the explicit set.

That record is never trusted on its own: it is intersected with what `rpm`
reports actually present, so a package removed behind mox's back drops out,
is reported missing, and is reinstalled rather than assumed to be there. A
batch that failed part-way is read back the same way, so the rows that did
land are recorded rather than retried forever.

Because what is installed is read back from `rpm`, a zypper row names a
package, plainly -- the rule above, plus two spellings it names in its own
words: a `pattern:`, `patch:`, `product:`, `srcpackage:` or `application:`
selector, and a version relation (`vim=9.0`) or an architecture suffix
(`vim.x86_64`), each of which would install and then read as missing on
every status. The cost is that a package installed by hand is
invisible to mox on zypper and will never be offered for tracking. `mox status` prints that as a note
under the backend rather than leaving it to be discovered.

## Drift

- **MISSING** -- declared for this machine, not installed.
- **UNTRACKED** -- installed, declared nowhere in the manifest, not
  blacklisted.
- **ERROR** -- the manifest itself was refused, so no backend was reached
  (`ERROR     the manifest was refused; the reason is the mox status:
  packages: line`). Counted toward the exit code: an empty section would
  otherwise read as a clean machine.
- **BROKEN** -- the manager is installed but cannot answer
  (`BROKEN    brew (brew --version exited 1)`). Its rows are neither judged
  nor installed, and a machine in that state is not a clean one: `status`
  counts it toward the exit code and `apply` fails on it. `commit` only
  notes it, since a manager that cannot list has nothing to reconcile.

Untracked is measured against every row the manifest declares, not only the
ones desired here: a package gated to another profile is already tracked, and
offering to re-add it would write a second row for something the manifest
already carries.

Package drift counts toward `mox status`'s exit code exactly as file drift
does, and `--json` / `--porcelain` carry both sets (see
[commands.md](commands.md#status)).

## Installing and reconciling

`mox apply` installs what is missing after the pre-script stage, with the
machine re-read in between when a pre-script ran, so a gate on a tool or
fact a pre-script provided holds here; the machine is re-read again after
any install or bootstrap, so a package installed here is a tool the
post-scripts see. A declared manager that is absent is bootstrapped first
(above). apt, dnf,
pacman, zypper and plugins get the whole set for their backend in one
invocation; brew, scoop and winget install row by row, and a row that fails
leaves the rest to proceed. The manager's own output is streamed rather
than captured, so progress and errors reach the terminal as they happen,
and it may talk to the terminal itself (`sudo` asking for a password; apt
runs with `DEBIAN_FRONTEND=noninteractive` so debconf does not). A batch
that failed may have landed some of its rows, so the re-capture runs after
any attempt, and after a bootstrap alone; the summary then says how many
rows were in failed batches, since a per-row manager counts only the
batches it lost. An install is not time-bounded by default -- a manager may
legitimately compile for an hour -- and `MOX_INSTALL_TIMEOUT_MS` bounds it
when set: at the bound the manager gets SIGINT first, so it can roll back
its transaction, and SIGKILL ten seconds later.
`--dry-run` lists what it would install and installs nothing.

apply **only ever installs**. Removal is never automatic: an untracked
package is reported and reconciled, never uninstalled behind you. (What a
manager does on the way -- pacman's full upgrade, a dependency brew drops --
is the manager's own behavior, not a mox decision.)

`mox commit` offers each untracked package `[y/b/s]`:

- **add** -- append a row to the manifest file that already speaks that
  backend, with whichever adapter fields identify it. The file chosen is
  the first of: a repo file whose default `backend` is it, a repo file
  carrying a row for it, then the same two in the private layer -- skipping
  any file whose own `when` excludes this machine, since a row appended
  there would never be desired here. When no
  file remains, commit says so once per backend
  (`no data/packages file that holds on this machine
  declares backend "x"; add one to record its N untracked package(s)`) and counts those packages as skipped: creating a
  file is a decision about where the rows live, not one to make silently.
- **blacklist** -- append a `[[blacklist]]` row so it is never offered again
- **skip** -- leave it untracked; the default, so `--yes` records nothing
  and the run still exits 1 while anything is untracked

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
POSIX script and a PowerShell twin. Names are `[A-Za-z0-9_-]`. Two files that
could both run here naming one backend is an error naming both; a runnable
file beside a not-runnable twin is the cross-platform case, and the runnable
one wins.

- Unix runs a plain file directly; it must be executable (`chmod +x`), and
  one that is not is an error naming the file -- never "no such backend". A
  Windows-only kind (`.ps1`, `.exe`, `.cmd`) is *not runnable here*: a note,
  not an error, and a manifest row naming it is inert rather than refused.
- Windows has no executable bit, so kind decides: `.ps1` runs through
  `pwsh`, or `powershell` where pwsh is not installed; `.exe` and `.cmd`
  directly. Any other file is *not runnable here*, printed
  as a note under `packages:`, so a MacPorts script in a shared repo neither
  breaks nor silently vanishes on a Windows machine.

A backend name never begins with a dot, so nothing there that does is one:
an empty `scripts/backends/` can be version-controlled, and shell plugins can
carry the eol rule that keeps them LF-clean on Windows. What git and an
editor keep in a tracked directory (`.gitkeep`, `.keep`, `.gitignore`,
`.gitattributes`, `.editorconfig`) passes without remark; any other dotfile
is ignored and said as a note, since that is also how a backend ends up
hidden by accident, and it must not read as a typo from the manifest's side. A directory there is an error naming the
path, never "no backend named x".

There is no axis gating (`os=darwin/`) and no private-layer shadowing.
Whether a backend is usable on this machine is its own `available` verb, and
nothing else: a plugin hidden under an `os=` directory would be undiscovered
elsewhere, and every shared-manifest row naming it would read as a typo there.

A runnable plugin named like a shipped backend overrides it, and `status`
says `note      brew: scripts/backends/brew overrides the built-in` on every
run. One that is not runnable here (`brew.ps1` on macOS) is noted and the
built-in keeps its place, so the rows it validates stay validated.

### The protocol

| Verb | stdin | stdout | Exit |
|---|---|---|---|
| `available` | -- | -- | 0 usable here; 1 not usable here; anything else, 64 included, is a broken plugin |
| `id` | one row, `{ name = "...", ... }` | exactly one id | 1: the row is refused, say why on stderr; anything else, 64 included, is a broken plugin |
| `list` | -- | one id per line: what was explicitly installed | nonzero, 64 included: failed |
| `install` | rows, one per line | streamed to the terminal | nonzero, 64 included: failed |
| `declare <id>` | -- | a TOML row body: `name = "..."` plus adapter fields | nonzero, 64 included: failed |
| `bootstrap <path> <out>` | -- | streamed to the terminal; the bin dir to put on PATH, if any, is written to the file `<out>` as one line, an absolute path (a second line, or a relative path, is bad output) | 64: not implemented; other nonzero: failed |
| `limitation` | -- | one line on what it cannot see, at most 200 bytes and no control bytes | 64: none; other nonzero: failed |

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
  check. A refused row fails on every machine that can run the plugin, not
  only where the manager is installed; where the plugin itself cannot run
  (a POSIX script on Windows) its rows are inert, not checked.
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
- **Exit 64 means "this optional verb is not implemented"** -- `bootstrap` and
  `limitation` are the optional ones -- reported by plugin and verb where it
  was needed. Nothing is substituted for a missing verb. Every other verb is
  required, so 64 from one of them carries no meaning: `available` reads it as
  a broken plugin like any other unexpected exit, and `id`, `list`, `install`
  and `declare` as a failure like any other nonzero exit.
- Every captured call is time-bounded like a setup script
  (`MOX_SCRIPT_TIMEOUT_MS`);
  a `list` blocked on a manager's lock is a timeout failure naming the
  backend, not a hung `mox status`. The bound covers the whole call, and
  every child leads its own process group, so the kill takes whatever the
  call left behind -- a helper holding the pipe (`port ... | awk`), a
  manager behind a `sudo`. Interrupting mox takes them with it too: a
  Ctrl-C during a query kills the query's group before mox dies of the
  interrupt itself, so no manager is left holding a lock.
- A streamed call (`install`, `bootstrap`) is handed the terminal for its
  run, the way a shell hands it to a job. `sudo` can prompt, Ctrl-C goes to
  the manager and ends mox with it, and Ctrl-Z suspends the job and hands
  the terminal back, so the shell can `fg` it later. A run with no terminal
  to hand over (`mox apply &`, a CI job) cannot answer a prompt, so an
  install that stops waiting for one is ended and named rather than waited
  on forever. Its bound is
  `MOX_INSTALL_TIMEOUT_MS` (none by default: a manager may compile for an
  hour), and at that bound its group is interrupted, then killed ten
  seconds later. A captured verb must never prompt: it is not the
  foreground job, so a read from the terminal stops it, and mox ends a
  captured child that stops the moment it stops rather than waiting out the
  bound -- or forever, where the bound is disabled.
  Windows has neither process groups nor job control, so there a bound
  reaches the direct process alone and no terminal changes hands.
  A killed call names the bound it ran under -- `timed out after <ms>ms
  (MOX_INSTALL_TIMEOUT_MS), killed`, or `(MOX_SCRIPT_TIMEOUT_MS)` for a
  captured one, or `timed out, killed` where neither was armed. One ended
  for want of a terminal says `stopped, and this run has no terminal that
  could resume it; killed`.
- The shipped backends' own manager calls are bounded the same way, and a
  probe killed at the bound is a named failure, never read as an absent
  manager. A manager that answers its probe with anything but "here" or
  "not here" -- a shipped one whose `--version` fails, a plugin whose
  `available` neither succeeds nor exits 1 -- is BROKEN (above), unless no
  row names it, in which case it is a note and its absence changes
  nothing.
- Output is split on newline and trimmed of `\r` (a PowerShell plugin emits
  CRLF); an id that is empty, exceeds 256 bytes, or carries whitespace, a
  control byte or a byte that is not UTF-8 is an error naming the plugin.
  That is the same rule, in the same bytes, the manifest enforces on a
  `name`, so a row `declare` writes is a row the next command can read back. That catches a lost line separator across a large
  set; a fixture test in your repo is the real defence.

`bootstrap` runs only when the manifest declares a `[[bootstrap]]` row for
the backend and `available` says the manager is absent. mox fetches the
installer and refuses to hand it over unless it hashes to the declared
sha256; the plugin then runs the verified file however its manager needs.
The verb is streamed, so its output is the terminal's and it may take as
long as an install; the bin dir, if there is one, goes into the file the
second argument names, as a single line holding an absolute path. A second
line, or a relative path, is bad output: progress text must not land on
PATH.

### Environment and which commands run a plugin

A plugin runs as you, at the trust `scripts/pre` already has, under the
same environment a setup script gets: `MOX_REPO`, `MOX_STATE_DIR`,
`MOX_HOME`, `PATH` and every fact as `MOX_FACT_*`, plus `MOX_PACKAGES_DEPTH`,
which says that a mox already sits above this one. It is read as a yes or no
-- any value present, `0` included, means one is -- so a plugin cannot clear
it by setting it, and the number it carries is capped rather than counted
without end. A mox reached from
inside a plugin discovers no plugin at all and says so as a note, so a plugin
that calls mox cannot multiply itself; the compiled backends still work
there. That holds for `status`
and `commit` as much as for `apply`; only `apply` refreshes the state bin dir
on the way. `status` runs `available`, `list`, `id` and `limitation`;
`commit` adds `declare`; `apply` adds `install` and `bootstrap`; `--dry-run`
runs the read-only set. `status` lists every discovered plugin by path
before it runs
anything, as `note` lines in the `packages:` section, or on stderr as
`mox status: note: ...` under `--json` and `--porcelain`, whose stdout stays
machine-pure. mox flushes its own output before every call, so those lines
reach the terminal before the plugin's do.

### A complete plugin

MacPorts, as a POSIX script at `scripts/backends/macports`:

```sh
#!/bin/sh
set -eu
cmd=${1:-}; shift || true
name() { printf '%s\n' "$1" | sed -n 's/^{ *name = "\([^"]*\)".*/\1/p'; }
case "$cmd" in
available) command -v port >/dev/null 2>&1 ;;
id)        IFS= read -r l && name "$l" ;;
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

A green run is not a silent one. Plugin stderr is the terminal's by design,
so a fixture plugin that is meant to fail writes its complaint straight to
the terminal, past the writers the harness captures: `fakeports: kind keg is
not a thing`, and a `sh` syntax error for the plugin a test deliberately
leaves unparseable. Zig's build runner prints `failed command:` for any step
that wrote to stderr at all, so it prints one for that step too. The
authoritative signal is the exit code and the `N passed` summary; those three
lines on an exit-0 run are the fixtures working. Anything else is new.

Whether that argv is *right* is a separate gate, because it cannot be
answered without the real thing:

| Gate | Covers |
|---|---|
| `zig build test-backends` | brew, read-only, differential against brew's own output |
| `sh tests/linux_backends_test.sh` | apt, dnf (both generations), zypper, pacman -- a full install round trip per image, in containers; and Homebrew bootstrapped from its pinned installer in a Debian container, installing one formula in the same apply |
| `pwsh -NoProfile -File tests/windows_backends_test.ps1` | scoop, winget: read-only where present; on a runner without scoop, a bootstrap from the pinned installer plus one install |

All three run nightly in CI, or on demand. Only the real manager can say
whether a query's format string still yields one name per line, or whether
an image without `sudo` installs at all; the hermetic tests cannot. A skip
is never a pass: under CI every one of the three fails when a case skipped,
because there the case is the reason the job exists. A check that cannot
apply to a backend at all is reported N/A instead, and does not fail
anything: zypper's ledger reports nothing untracked by construction, so the
check that measures untracked names has nothing to measure there. The one
real exception is brew's tap check, which needs a formula installed from a
third-party tap -- something no CI runner should do -- so it skips there and
says so. The brew checks compare the adapter
against Homebrew's own install receipts rather than against the command the
adapter runs, so an adapter asking the wrong question cannot agree with the
oracle.
