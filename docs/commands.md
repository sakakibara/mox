# Command reference

The behavioral contract of every command, with each one's flags in a
table beneath it. Those tables are rendered from the same declarations
`mox <cmd> --help` and `mox __schema` are derived from (the schema
carries each positional's completion behavior, so a completion generator
reads the same table), and a test fails when they and argv disagree --
so a flag here is one mox accepts, spelled the way it accepts it. What a flag *means* is
prose, and hand-written. [usage.md](usage.md) walks through the
day-to-day tasks.

Mutating commands (`add`, `apply`, `commit`, `mv`, `publish`, `remove`,
`rollback`, `uninstall`, `update`, `facts set`, `facts ask`, a bare `facts`
that reaches the interview, and `doctor` under `--fix`, `--rebuild-provenance`
or `--rebuild-coupling`) take a single-writer lock at `<state dir>/mox.lock`
(`$MOX_STATE_DIR`, default `$XDG_STATE_HOME/mox`); a second process sharing
that state directory is refused while the first runs. The lock is per state
directory, so runs given different `MOX_STATE_DIR` values take different locks
and do not serialize against each other -- one state directory per live tree.
`upgrade` takes no lock: it replaces the mox binary, not the repo or the live
tree. An unknown command exits 2.

## Path arguments

Every command taking a live path -- `add`, `apply`,
`commit`, `diff`, `edit`, `mv`, `remove`, `status` -- reads it the same
way:

| Spelling | Names |
| --- | --- |
| `/home/me/.config/nvim/init.lua` | itself |
| `~/.config/nvim/init.lua` | the same file, tilde expanded against `$HOME` (`%USERPROFILE%` on Windows) |
| `init.lua` | `init.lua` in the current directory |
| `../fish/config.fish` | the sibling directory's file, as in a shell |

A non-absolute path is relative to the current directory, like every
other command's. `.` and `..` resolve, so any spelling of a path equals
the file it names.

The tilde is expanded by mox as well as by the shell, because a shell
does not always get there first: quoting stops it (`"~/x"`), PowerShell
passes `~` through to a native program verbatim, and a script may build
the argument without a shell at all. `~user` is not expanded and is
refused rather than read as a directory named `~user`; on Windows, spell
the tail with `/`.

This is the live-path rule, and it covers the commands above.
`export --facts <path>` names a file outside the live tree and takes it
as given: mox expands no tilde there, so spell the path out or leave it
unquoted for the shell to expand.

Environment variables are the shell's to expand, and mox does not: a
literal `$HOME` reaches it only when something meant it literally.

Paths are printed back the same way: a live path under the home
directory is shown as `~/...`, including in the commands a report tells
you to run -- mox expands the tilde itself, so those survive being
pasted quoted, into a script, or into a shell that expands no tilde at
all. `mox status --json`/`--porcelain` emit the real absolute path,
since their consumer expands nothing.

## init

Initialize a fresh mox repo (`src/` and `scripts/`). `--clone <url>`
clones an existing dotfiles repo into the repo dir; by default it stops
for you to review -- a cloned repo's files and scripts are untrusted
until you look at them -- and `--apply` applies right away for a
one-command bootstrap. Refuses a non-empty repo dir. `--apply`'s facts
interview is the ordinary interactive one; add `--defaults` (see
[apply](#apply)) for the zero-touch form that binds declared defaults
and declines the rest instead of prompting.

The skeleton is not a git repository: run `git init` in it, and add a
remote, before `mox publish`, `mox update` or `mox git` can work, and
`mox doctor` skips its tracked-source check until you do. `--clone`
arrives with git history already.

`--clone` accepts shorthand alongside full URLs:

| Argument | Clones |
| --- | --- |
| `owner` | `https://github.com/owner/dotfiles` |
| `owner/repo` | `https://github.com/owner/repo` |
| `host/owner/repo` | `https://host/owner/repo` |
| `host/owner/.../repo` (more segments) | `https://host/owner/.../repo` |
| anything with a scheme, a colon, or a leading `/`, `.` or `~` | used as given |

The shorthand is sugar only: an argument with a scheme, a colon
(scp-style `git@host:path` remotes, drive letters), a leading `/`, `.`,
or `~` (local paths), an empty segment, or a character outside
`[A-Za-z0-9._-]` is passed to `git clone` verbatim, so any host and any
protocol git speaks keep working spelled out.

<!-- generated: flags init -->
| Flag | Description |
| --- | --- |
| `--clone <url>` | git clone <url> into the repo dir (review it, then run 'mox apply'); <owner>, <owner>/<repo>, and <host>/<owner>/<repo> are shorthand for https URLs (owner alone assumes a repo named dotfiles) |
| `--apply` | after cloning, apply immediately (write files, run scripts) instead of stopping to review |
| `--defaults` | with --apply: never prompt in the facts interview; bind declared defaults and decline the rest |
<!-- /generated -->

## add

Start managing a live file as a base file in `src/`. A path matching a
repo ignore rule (`.moxignore` / `.mox/ignore`) is refused (`--force`
overrides).

`-r`/`--recursive` takes a directory instead, capturing every non-junk
regular file and symlink under it; already-managed files, junk (editor
temp, OS metadata), non-regular entries, and ignored paths are counted as
skipped, and the run reports `Added N file(s); M skipped, K failed`. A
directory without `-r` is refused, as is `-r` on a file. `--seed-once`
applies to every file captured. `--force` overrides the ignore rule
matching the path you named and no other, so forcing an ignored
directory still honors the rules inside it. The key-path options below
name a location inside one file and are refused with `-r`.

Partial ownership at onboarding:

- `--own <key-path>` (repeatable) takes partial ownership of a
  structured file instead: the named subtrees are extracted into the
  source (comments inside them survive) under `mox: own` head
  directives.
- `--own-absent <key-path>` declares a key mox enforces as absent.
- `--disown <key-path>` (repeatable, exclusive with `--own`) captures
  the whole file MINUS the named subtrees under `mox: disown`
  directives.
- `--gate <axis-expr>` (with `--own`/`--disown`) writes a whole-file
  `mox: when` gate line after the directives, onboarding a
  machine-gated partial file in one command. The expression must
  parse; a malformed one is refused with the parser's diagnostic.

A plain `add` of a target whose source head declares ownership is
refused.

<!-- generated: flags add -->
| Flag | Description |
| --- | --- |
| `--recursive, -r` | add every non-junk file under a directory |
| `--seed-once` | seed the target once; never overwrite an existing one |
| `--force` | add even if the path matches an ignore rule |
| `--own <key-path>` | manage only this key-path of the live file (repeatable; single file only) |
| `--own-absent <key-path>` | declare a key-path mox enforces as absent (repeatable; single file only) |
| `--disown <key-path>` | manage the whole file except this key-path (repeatable; single file only) |
| `--gate <axis-expr>` | gate the created partial source on this axis expression (single file only) |
<!-- /generated -->

## mv

Rename a managed file's source (base file and its `.d/` overlay dir) so
the live target changes on the next apply. The old source is copied
into the timestamped trash first (recoverable); its
`.mox/attributes.toml` entry (mode, symlink, seed-once) is carried to
the new name; a head ownership declaration travels inside the renamed
source, and a partial target's owned record is re-keyed -- the old live
file keeps its owned content, like any orphaned live file. The old live
path is not removed: apply writes the new one and leaves the old file
orphaned, to delete yourself.

## remove

Stop managing a file: move its source (base + `.d/`) into
`<state dir>/trash/<timestamp>/` recoverably and leave the live file
orphaned. mox forgets the path's applied state, so a later re-add
starts from first contact. `--purge` also deletes the live file,
snapshotting it first; it is refused for a partially owned file (the
live remainder is not mox's to delete).

<!-- generated: flags remove -->
| Flag | Description |
| --- | --- |
| `--purge` | also delete the live file (snapshotted first) |
<!-- /generated -->

## apply

Compose all managed files and write them to their live paths
(`--dry-run`, `--overwrite`, `--skip-scripts`, `--defaults`, or a list of
paths to limit the run).

Before composing, apply discovers the repo's fact interview (below) and
walks it: on a terminal it prompts for every
eligible unbound fact and persists the answers, then re-captures so the
run composes against them. `--defaults` never prompts: every eligible
fact binds its declared default when it has one, and is declined (bound
to the empty string) otherwise -- the non-interactive, zero-touch form.
Off a terminal without `--defaults` (scripts, CI), and under
`--dry-run`, nothing is asked or persisted; a stderr notice lists the
facts left unbound (`unbound facts: <names>`) and how to resolve them.
There is no global refusal for an unresolved fact -- that is a
per-script concern (below), not this pass's to fail wholesale.

A repo carrying a `data/packages/` manifest also installs what that
manifest declares and the machine lacks, after the pre stage and its
re-capture; the machine is re-read again after any install or bootstrap,
so a package installed here is a tool the post scripts see. A manager the
manifest declares a `[[bootstrap]]` row for is installed first when absent,
from its verified installer, and used by this same run; if that bootstrap
fails, its rows are not attempted.
apt, dnf, pacman, zypper and plugins get their whole set in one invocation;
brew, scoop and winget install row by row, and a failed row leaves the rest
to proceed. Any failure is an error class (rc 2), and a failed batch or a
bootstrap alone still triggers the re-capture, since the machine changed.
apply only ever installs -- an untracked package is
reported by `mox status` and reconciled by `mox commit`, never uninstalled.
Under `--dry-run` nothing is fetched or installed and the run lists what
it would install, planned as though any absent manager had been
bootstrapped. The failures a plan can have on its own -- a probe that did not
answer, a row whose absent manager cannot be bootstrapped -- are counted
beside them (`Packages: N would be installed, N failed`), so a plan that
could not be made is not read as a clean one.
`--skip-scripts` skips packages as it skips scripts (both change the machine
beyond its files), and a path-scoped apply names files and installs nothing.
When a pre-script ran, the machine is re-read before packages are planned,
so a `when` gate on a tool or fact the pre stage provided holds in the same
run. An install is not time-bounded unless `MOX_INSTALL_TIMEOUT_MS` is set; a
bootstrap's own download is a captured call, bounded like every other by
`MOX_SCRIPT_TIMEOUT_MS`.
A repo without `data/packages/` never queries a package manager.

apply never prompts about drift. It writes every file that is clean or absent
and never silently changes one that has drifted -- a live file edited
since mox last wrote it, or one mox never wrote (a first apply or
migration). Drifted files are left untouched, listed in a report on
stdout, and the run exits 1. The report names each file, what changed,
and the exact command to resolve it: `mox apply --overwrite <path>`
takes the repo's version, `mox commit <path>` keeps the live edit by
routing it back into its source. `--overwrite` with no
paths overwrites every drifted file; a path list scopes it. `mox status
--drift` lists the full set at any time, and `--json`/`--porcelain` emit
it for tooling. A genuine failure -- an unresolvable fact contract, an
unwritable target, an unsnapshottable removal -- exits 2, distinct from
drift's 1.

A partially owned file (an `own` or `disown` head declaration) is
patched around the other side's content: the owned content is written,
every protected byte is preserved exactly, drift is judged on the owned
content only, and its `check` hook (if any) must accept the candidate
first. Under `--skip-scripts` the hook does not run and a check-bearing
file is not written.

A file mox previously wrote whose source now composes to nothing (an
emptied data set, a region gated away) is removed rather than left as a
stale copy -- snapshot-first, so `mox rollback` recovers it. One edited
since mox wrote it is not deleted silently: it is reported as drift and
kept until resolved. See `docs/dsl.md` (Empty output) and `keep-empty`.

Every `scripts/pre/`/`scripts/post/` script lands under one of five labels,
summarized on the closing line (`scripts: N ran, N skipped, N failed, N
blocked, N declined`): `ran` (exit 0); `skipped` (its directory tuple or
`# mox: when` gate did not match); `declined` (every fact it needs is
bound but empty -- green, does not fail the run); `blocked` (a needed
fact could not be resolved -- see Scripts in
[dsl.md](dsl.md#scripts); counts into the failing exit like `failed`,
under its own label); `failed` (nonzero exit, abnormal
termination, a time-out, or a stop for a terminal the run does not
have). A stage file that cannot be spawned, a gate directory that
cannot be read, and a subdirectory named like a tuple that is not one are
counted under `failed` too, though none of them is a script.
`--skip-scripts` skips scripts and their fact checks entirely.

<!-- generated: flags apply -->
| Flag | Description |
| --- | --- |
| `--dry-run` | report only, write nothing |
| `--overwrite` | overwrite drifted files |
| `--skip-scripts` | compose and write files, run no scripts; also installs no packages |
| `--defaults` | never prompt: bind each unbound fact's default, decline the rest |
| `--color <color>` | auto|always|never |
<!-- /generated -->

## commit

Route edits made to live files back into their sources.

Each change is confirmed on a terminal, and every prompt also accepts
`q`, which aborts the whole run without writing anything. The keys are:

- `y` accept, `s` skip, for a routed hunk.
- `s` skip, `x` split, for one that lies in no single source (`x` splits
  it at its origin boundaries).
- `f` fact, `d` default, `s` skip, for an interpolated value: write the
  fact, or the source's `| default`.

`--yes` takes the defaults, terminal or not; `--dry-run`, or a non-TTY
without `--yes`, reports only and exits 1 if edits remain;
`--abort-on-prompt` is strict CI mode, exiting 2 on the first would-be
prompt.

Routing: base lines go to `src/`, fragment lines to their fragment,
loop-row edits to the data source. Private-origin edits go only to the
private layer, never repo `src/`. A value derived from a secret or an
interpolation is reported, never routed.

Keeping a live edit works for every kind of drift, not only a file mox
last wrote. When there is no stored baseline -- a first apply, or a
secret-bearing composition whose cleartext is deliberately not cached --
commit recomposes the source to rebuild a verifiable baseline and routes
the edit against it. A source that now composes to nothing is the one
exception: there is no file to route into, so commit reports it and
leaves the live copy for you to remove or re-fill.

A first-contact hunk always needs a human. `--yes` takes no default for
one: it is reported as `manual: <path>:<line> first contact, needs
confirmation`, the source is left untouched, and -- unlike the package
pass -- the run still exits 0. In a script, read the `N manual` count
rather than the exit code.

A file merged from several layers routes per KEY instead of per line
(`y` accept, `p` pick a layer, `s` skip): each changed key goes to the
layer that defines it, and `p` picks a different layer. A shared (base
or universal-fragment) edit prompts for where it belongs: keep it
universal (the default, and what `--yes` takes) or narrow it to an axis
the source compares by value (synthesizing a `replace from` region). Anything that would reach a
machine beyond the one you chose -- promoting a key to a layer other
machines read, say -- lists those configurations and asks first.

The result is verified by recomposing every configuration the source
expresses; a violation -- any configuration you did not choose to
affect composing differently than before -- aborts the write and
restores the source. When a changed token also lives in other managed
sources, commit prompts `[Y/n/d/D/q]` to update them in the same write
pass.

A partially owned file always routes per key, over its owned content
only; one whose owned content resolved a secret is skipped (its record
is a hash -- edit the source directly).

A repo carrying a `data/packages/` manifest is reconciled before the file
pass: each untracked package (installed, declared nowhere, not
blacklisted) is offered `y` add, `b` blacklist, `s` skip -- add a row to
the file that declares its backend, blacklist it, or skip; skip is the
default, so `--yes` records nothing and exits 1 while anything stays
untracked. A row is appended the
moment it is
chosen, so `q` here ends the run before the file pass and says how many
rows were already recorded (rc 1); `--abort-on-prompt` exits 2 at the
first package prompt the same way. A backend plugin's `declare` verb runs
here (see [packages.md](packages.md#the-protocol)). `--dry-run` lists the
untracked packages and writes nothing; a path-scoped `mox commit <file>`
skips packages entirely.

<!-- generated: flags commit -->
| Flag | Description |
| --- | --- |
| `--dry-run` | report only, exit 1 if edits remain |
| `--yes` | take defaults without prompting |
| `--abort-on-prompt` | strict CI: rc 2 on the first prompt |
| `--color <color>` | auto|always|never |
<!-- /generated -->

## diff

Show a unified diff of the composed output against each live file
(`--stat` for a per-file added/removed summary). A partially owned
file diffs its canonical owned content only, with secret-bearing keys
masked on both sides. Read-only and takes no lock. A difference is not
an error, so a run that completes exits 0 whether or not anything
differs; a refusal -- a path that is not managed, a malformed ownership
declaration or `attributes.toml` -- exits 1.

<!-- generated: flags diff -->
| Flag | Description |
| --- | --- |
| `--stat` | per-file added/removed summary instead of full hunks |
| `--color <color>` | auto|always|never |
<!-- /generated -->

## edit

Open the source file behind a managed live path (see [Path
arguments](#path-arguments)) in `$EDITOR`. `--axis <tuple>` edits the matching
overlay or region fragment instead of the base -- the way to reach a variant
your current machine does not compose. Takes no lock of its own (`--apply`
takes apply's), and reports the candidate path when the source does not exist.

<!-- generated: flags edit -->
| Flag | Description |
| --- | --- |
| `--axis <tuple>` | edit the overlay/fragment for this axis tuple instead |
| `--apply` | apply the edited file after the editor exits |
<!-- /generated -->

## status

Show each managed file's state: `clean`, `OUTDATED`, `DRIFT`,
`MISSING`, `STALE`, `GATED`, `ERROR`, plus this run's probe log (every
`tool=`/`env=` name asked and whether it resolved) and, when non-empty,
an `unbound facts:` section listing every discovered fact still
eligible and unbound, each with its provenance -- its own section, not
folded into the probe log. `STALE` is a file mox wrote whose source now
composes to nothing: apply will remove it (an edited such file is
`DRIFT` instead, kept until resolved). A partially owned file is
classified on its owned content only, so the program's writes on the
other side never surface. Exits 1 if any file is `OUTDATED`, `DRIFT`,
`MISSING`, `STALE`, or `ERROR`.

A repo carrying a `data/packages/` manifest also gets a `packages:`
section: per backend, each declared package still `MISSING`, each installed
package `UNTRACKED` (declared nowhere and not blacklisted), and each manager
that is installed but cannot answer `BROKEN`. A declared row of a backend this machine
can use whose `when` excludes this machine is `GATED` there, printed with the
gate that excluded it: it is not drift and counts toward nothing, but a row
that appeared in no output at all could not be told from a row the manifest
never carried, which is what a `when` written under the wrong table header
produces. A backend this machine cannot use contributes no rows at all, gated
ones included. A manifest
mox would not read
at all is one `ERROR` row naming where the refusal is, since an empty section
would read as a clean machine. The file table and the packages section each close with a
one-line summary: what needs attention by label, then what does not;
`--drift` prints only the actionable half and the machine formats print
neither. A
path-scoped `mox status <file>` names files and reports no packages, as a
path-scoped apply or commit reaches none.
A repo without that directory is not using the package subsystem, so no
section prints and no package manager is queried. A repo with plugins under
`scripts/backends/` has them executed here (their `available`, `list`, `id`
and `limitation` verbs), each listed by path first; see
[packages.md](packages.md#adding-a-backend). Package drift counts
toward the exit code exactly as file drift does, so `mox status` answers
one question -- does this machine match what it declares -- over files
and packages alike. A manifest that is itself malformed, a plugin that
fails, or a manager query that fails is an error, not drift: the run exits
1 with `mox status: packages: ...` on stderr. A manifest mox would not read
at all says so on stdout too, as a record of its own in both machine formats,
so a refusal is never read as a clean machine; a plugin or query failure
leaves the package set partial, so tooling reads rc 1 with that stderr line
as an error. Plugin notes go to stderr as `mox status: note: ...` in those
modes.

`--drift` shows only the drift set (the report `mox apply` prints for the
same tree, from the same classifier -- the two never disagree), dropping
the clean/gated table and the probe/unbound context. The `packages:`
section is drift, so `--drift` keeps it, but only its drift: clean and
`GATED` rows go the way the clean file table does, the notes go to stderr as
they do under `--json`, and a machine with no package drift at all prints no
section. A `GATED` package is not in the serialized set either, exactly as a
`GATED` file is not.
One asymmetry to know: a `MISSING` file is not in the drift set (apply
writes it without asking) while a `MISSING` package is (apply installs it,
and `commit` may record it instead). `--json` and
`--porcelain` serialize that set for tooling instead of the human report.

`--json` emits `{"files": [...], "packages": [...]}`. A file is
`{path, kind, key?, first_contact}`; a broken manager is
`{backend, state: "broken", exit, probe, why?}`, where `exit` is the exit
code or `null` for a call that never reached one -- killed at its bound,
ended for want of a terminal, or answered in a shape that is not an answer
-- and `why` states that reason in words, so a genuine exit of 255 is never
read as one of them; a manifest that would not load is
`{state: "refused"}`, alone and leading the package set, since it is the
whole pass rather than one backend; a package is
`{backend, state, id, name?}`, where `state` is `missing` or `untracked`
and `id` is the identity its backend compares by -- a brew cask carries
its `cask:` prefix, so it can never be read as the formula of the same
name. `name` is what the manifest row spells, and is present only for a
missing package.

`--porcelain` emits stable tab-separated lines, one record per line, with
the record kind as the first field. File records are `kind`, `key`,
`first_contact` (0/1), `path`. Package records are `package_missing` or
`package_untracked`, then `backend`, then `id`; a broken manager is
`package_broken`, then `backend`, then the exit code, then the probe, then
why -- the exit code being `-` for a call that never reached one (killed at
its bound, ended for want of a terminal, or answered in a shape that is not
an answer), which is what tells those apart from a genuine exit of 255, and
`why` being empty wherever the code already says it; a manifest that would
not load is `package_refused`, a record of one field. Field count varies by
kind, so switch on the first field before reading the rest. In
`--porcelain` the free-form fields are
C-escaped (`\\`, `\t`, `\n`, `\r`) so a tab or newline in them can never
break the framing; unescape those four to recover exact bytes. Both imply
`--drift` and keep the same exit code.

<!-- generated: flags status -->
| Flag | Description |
| --- | --- |
| `--color <color>` | auto|always|never |
| `--drift` | show only the drift set (suppress the clean/gated table) |
| `--json` | emit the drift set as JSON (implies --drift) |
| `--porcelain` | emit the drift set as stable tab-separated lines: kind, key, first_contact (0/1), path for a file; package_missing or package_untracked, backend, id for a package; package_broken, backend, exit code (- where the call never reached one), probe, why for a manager that cannot answer; package_refused alone for a manifest that would not load (implies --drift) |
<!-- /generated -->

## export

`export [--as <tuple>] [--facts <path>] [--cleartext-secrets] <out>` bakes a
flat resolved tree: compose every managed file for the current machine (or the
given axis tuple) and write it under `<out>/<live-rel>`. `<out>` and
`--facts` are each absolute, `~`-relative, or relative to the current
directory. A partially owned
target exports its canonical owned serialization -- the ownership contract,
not a whole live file. Read-only wrt mox state; the walk-away guarantee and CI
parity input.

Everything composes before anything is written, so a run that cannot
compose every file reports them and writes nothing: an export is a
deliverable, and a tree that silently lacks a file is worse than no
tree. Composing still happens exactly once, which matters because a
second pass would resolve every `op://` secret again -- another round
trip, another biometric prompt.

`--as` binds axes by tuple, whose values are filename-safe by grammar
(`[A-Za-z0-9_.-]` and non-ASCII bytes; `+` separates pairs and `=` splits
them) and so cannot carry an address, a key, or anything holding a space.
`--facts <path>` replaces the machine's own `facts.toml` instead: compose
against a machine that does not exist, without fabricating an
`XDG_CONFIG_HOME` around a temporary file. Derived facts (`data/facts.toml`)
and `tool=`/`env=` probes still resolve against the running machine. The two
compose -- `--facts` supplies the values and `--as` places the
machine -- which is what a matrix check over a repo's config space needs.

A tuple naming the same axis twice is accepted and the LAST pair wins
(`--as os=a+os=b` binds `os` to `b`). The same spelling in an overlay filename
means something else: every pair must match, so `os=a+os=b` can never match
and `os=a+os=a` matches whenever `os=a` does. Nothing warns about either; a
duplicate axis is a mistake to catch by reading.

An export that would bake a resolved secret as cleartext names those files and
refuses until `--cleartext-secrets` is passed, deciding before any of it
reaches disk. The flag is demanded only when a secret is actually present: one
required on every run is one you type unread, which is the attention a consent
gate exists to keep. With it, each such file is written and the count is
reported; a secret-manager value lands at 0600 unless `.mox/attributes.toml`
sets its mode, any other resolved secret at
the file's composed mode.

<!-- generated: flags export -->
| Flag | Description |
| --- | --- |
| `--cleartext-secrets` | required only when the export bakes a resolved secret as cleartext |
| `--as <tuple>` | compose as if bound to this axis tuple |
| `--facts <path>` | read facts from this file instead of the machine's own |
<!-- /generated -->

Exit 0 when every file composed and was written, 2 on any failure: a source tree that is
missing or cannot be walked, a facts file that cannot be read, a file that
does not compose, or a resolved secret with no `--cleartext-secrets`.

## facts

List facts (`name = "value"` lines, a machine-readable format kept
byte-frozen for other tooling to parse); interview for any discovered
fact still unanswered. Refuses loudly (rather than reporting an empty
config space) when the source tree exists but cannot be parsed; a repo
with no `src/` at all lists nothing and exits 0, and `mox status` is
what reports a missing source tree. `--report` replaces
the listing with every discovered fact's state -- `bound "<value>"`,
`declined (bound empty)`, or `UNBOUND`, each with its provenance (source
count, needing scripts) and, when conditioned, the expression it is
asked under.

`facts set <name> <value>` writes one directly; an empty value is the
scriptable decline (`mox facts set <name> ""`), identical to pressing
Enter at an unanswered prompt with no default. A name that is a machine
axis (os, arch, machine, hostname) is refused: the machine's own value
is used, so a fact cannot set it.

`facts ask [<name>]` re-runs the interview interactively (refuses off a
terminal -- there is no non-interactive form of "ask again"). With
`<name>`, that fact alone, even if already bound: the change-an-answer
flow, with its full choice list, default, and provenance. Bare, every
fact currently unbound or declined whose condition holds -- wider than
the standard interview, which never revisits a decline.

`facts probe tool=<name>` / `facts probe env=<name>` resolves a single
live probe scriptably: exit 0 present, 1 absent, 2 error.

<!-- generated: flags facts -->
| Flag | Description |
| --- | --- |
| `--report` | print every dimension's state (bound/declined/UNBOUND), provenance, and asking-condition instead |
<!-- /generated -->

## data

Print a data source as TOML or JSON (`--format=toml|json`); the
private layer shadows the repo.

<!-- generated: flags data -->
| Flag | Description |
| --- | --- |
| `--format <format>` | toml or json |
<!-- /generated -->

## doctor

Health report: source files not tracked by git, source modes git cannot carry
that are not yet in `.mox/attributes.toml` (lost on clone), sources that
compose to nothing under every configuration (a contradictory or mistyped
whole-file gate), malformed state (provenance), a file in the private layer's
`data/` that is not a data source (`private-data <path>`), since nothing
applies it, and a `facts.toml` fact bound
on this machine that nothing in the repo consumes (`unused-fact <name> (bound
but unused by this repo)`) -- advisory, since deleting or renaming a fact the
repo no longer reads is the user's call. When the unused name is a probable
rename of some still-unbound fact (a short edit distance), the advisory
bridges the two and names the migration directly: `unused-fact persona (bound
but unused; unbound "profile" -- renamed? mox facts set profile <value>)`. A
leftover `data/facts-schema.toml` gets its own one-line notice: nothing
reads it (the interview derives from the repo's own sources), delete it.
`--rebuild-provenance` recomposes and re-records every tracked file's
provenance (partial targets keep no line provenance and are skipped);
`--rebuild-coupling` rescans source tokens and rewrites the stored coupling
graph under `<state dir>/coupling/`; `--fix` performs the safe rebuilds. Mutating
runs take the lock; exits 1 while any problem or advisory remains, or a check
could not run (a source tree outside git skips the tracked-source check), so
it can gate CI.

The run ends on exactly one summary line: `mox doctor: N problem(s) found`,
or `N advisory item(s) need attention` when there are no problems, or
`N check(s) skipped (coverage incomplete)` when there are neither, or
`healthy`.

<!-- generated: flags doctor -->
| Flag | Description |
| --- | --- |
| `--fix` | perform the safe rebuilds |
| `--rebuild-provenance` | recompose every recorded file and re-record its provenance |
| `--rebuild-coupling` | rescan source tokens and rebuild the coupling graph |
<!-- /generated -->

## snapshot / rollback

`snapshot` lists apply snapshots (taken before every overwrite);
`rollback [<id>]` restores live files from one, defaulting to the
newest and announcing which it took. A partially owned file
is never whole-file restored: the snapshot's owned subtree is
re-patched onto the current live file (the program's writes since then
survive) through the same verification and `check` hook as apply, and
a snapshot whose owned values were secret-masked is refused --
re-apply the source instead.

`MOX_SNAPSHOT_RETENTION` is how many to keep (default 10); apply prunes
the rest. A value that is not an integer warns and the default stands.

## update

The inbound edge -- remote to source to live. Fetches, rebases onto
the upstream, then applies, so the machine ends the run current rather
than merely holding current sources. Any uncommitted change refuses
the update until you commit it; mox never commits on your behalf.

Rebase rather than fast-forward-only, because the same repo edited on
several machines diverges routinely and refusing that would hand back
a manual rebase every time. Only commits absent from the upstream are
replayed, so published history is never rewritten. A conflict stops
mid-rebase for you to resolve and `git rebase --continue`, or abort.

`--no-apply` stops after the rebase, for a `mox diff` before writing.
That is mox's guarded fetch without the write -- a dirty tree refused,
a missing upstream reported in mox's terms, the arriving commit count
printed -- which `mox git -- pull --rebase` does not give you.

Exit 0 clean, 1 drift left for a decision, 2 a refusal or failure, the
same contract `apply` uses. Sending work the other way is `publish`.

<!-- generated: flags update -->
| Flag | Description |
| --- | --- |
| `--no-apply` | stop after the rebase; write no live files |
| `--color <color>` | auto|always|never |
<!-- /generated -->

## publish

The outbound edge -- live to source to remote. With `-m <message>` it
commits the repo's pending source changes and pushes them; without it,
it pushes what is already committed, and refuses rather than invent a
message when a path mox owns is dirty.

Staging is by explicit path, never a blanket `git add -A`: only the
directories mox owns (`src/`, `data/`, `scripts/`, `.mox/`, and
`.moxignore`) are publish's to commit. A dotfiles repo is exactly where
a stray note or a pasted credential ends up, and anything dirty outside
those paths is reported and left for you to stage deliberately with
`mox git -- add`.

Refuses a repo part-way through a merge or rebase, as `apply` and
`commit` do. Bringing work the other way is `update`.

<!-- generated: flags publish -->
| Flag | Description |
| --- | --- |
| `--message, -m <message>` | commit the source tree with this message before pushing |
<!-- /generated -->

## path

Print the repo directory. The sole line on stdout is the path -- no
`~` contraction, no trailing prose -- so `cd $(mox path)` works.

## git

Run git in the repo from wherever you are, passing its stdout, stderr,
and exit code through untouched. Put flags after `--` so mox does not
read them: `mox git -- log --oneline`.

The repo lives under a data directory nobody stands in, so this and
`path` are reach rather than sugar. Everything git does stays git's
vocabulary; the two edges mox names (`update`, `publish`) earn their
own commands by doing more than git, not by wrapping a verb.

## secret

Resolve a secret URI to stdout: `env:NAME`, `file://PATH`,
`op://VAULT/ITEM/FIELD`, `pass://ENTRY`, or `cmd:SHELL` (runs
`/bin/sh -c` and takes the first stdout line).

## trigger

Setup-script staleness primitives (`hash`, `seen-version`, `every`)
for guarding expensive work inside a setup script.

## version

Print the running build's version as `mox <version>`, one line on
stdout and nothing else, so a script can read it without parsing. `mox
--version` prints the same line.

## upgrade

Download and install a newer mox release, verified against its
`SHA256SUMS`, replacing the running binary. `mox upgrade <version>`
for a specific one; never auto-downgrades; `--yes` skips the prompt.

<!-- generated: flags upgrade -->
| Flag | Description |
| --- | --- |
| `--yes` | skip the confirmation prompt |
<!-- /generated -->

## uninstall

Remove mox's machine-local state (applied records, provenance, ...).
The private layer is preserved unless `--purge-private`; snapshots (the
pre-mox content of every file mox overwrote) and trash (the sources
`remove` and `mv` displaced) are preserved unless
`--purge-snapshots` / `--purge-trash` or confirmed on a terminal. The
user's source repo is never touched.

<!-- generated: flags uninstall -->
| Flag | Description |
| --- | --- |
| `--purge-private` | also delete the private layer |
| `--purge-trash` | delete trash non-interactively |
| `--purge-snapshots` | delete snapshots (pre-mox backups) non-interactively |
<!-- /generated -->

## For tooling

Two surfaces exist for a program rather than a person. `mox __schema` is
not listed in `mox --help` at all; `mox status --json` / `--porcelain`
are listed under `mox status` but answer questions a human already has
better answers to.

`mox status --json` / `--porcelain` emit the drift set (see
[status](#status)). Paths there are absolute, never contracted to `~`,
since the consumer expands nothing.

`mox __schema` emits the whole command table as one versioned JSON
envelope -- every command with its flags, positionals, completion
behavior, declared constraints, and subcommands, recursed:

```
{"version":2,"program":"mox","commands":[{"name":"init", ... }]}
```

It is derived from the same declarations the parser and `--help` are, so
it cannot describe a flag argv does not accept. `constraints` carries the
relations a command enforces (`--gate` requires one of `--own`,
`--own-absent`, `--disown`; `--recursive` rules those out), so a caller
composing an invocation can honour them instead of discovering them from
a rejected one. `version` is bumped whenever the emitted shape changes in
a way a consumer must branch on.
