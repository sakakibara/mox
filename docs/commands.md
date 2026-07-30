# Command reference

The behavioral contract of every command. `mox <cmd> --help` lists the
flags; [usage.md](usage.md) walks through the day-to-day tasks.

Mutating commands (`apply`, `commit`, `rollback`, `facts set`, `sync`,
`upgrade`, `mv`, `remove`, `uninstall`) take a single-writer lock at
`state/mox.lock`; a second process is refused while the first runs. An
unknown command exits 2.

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
does not always get there first: quoting stops it (`"~/x"`), so does a
non-initial position (`--path=~/x`), PowerShell passes `~` through to a
native program verbatim, and a script may build the argument without a
shell at all. `~user` is not expanded and is refused rather than read as
a directory named `~user`; on Windows, spell the tail with `/`.

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

`--clone` accepts shorthand alongside full URLs:

| Argument | Clones |
| --- | --- |
| `owner` | `https://github.com/owner/dotfiles` |
| `owner/repo` | `https://github.com/owner/repo` |
| `host/owner/repo` | `https://host/owner/repo` |
| anything else | used as given |

The shorthand is sugar only: an argument with a scheme, a colon
(scp-style `git@host:path` remotes, drive letters), a leading `/`, `.`,
or `~` (local paths), an empty segment, or a character outside
`[A-Za-z0-9._-]` is passed to `git clone` verbatim, so any host and any
protocol git speaks keep working spelled out.

## add

Start managing a live file as a base file in `src/`. A path matching a
repo ignore rule (`.moxignore` / `.mox/ignore`) is refused (`--force`
overrides).

`-r`/`--recursive` takes a directory instead, capturing every non-junk
regular file and symlink under it; already-managed files, junk (editor
temp, OS metadata), non-regular entries, and ignored paths are counted as
skipped, and the run reports `Added N file(s); M skipped, K failed`. A
directory without `-r` is refused, as is `-r` on a file. `--seed-once`
and `--force` mean the same thing in both modes; the key-path options
below name a location inside one file and are refused with `-r`.

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

## mv

Rename a managed file's source (base file and its `.d/` overlay dir) so
the live target changes on the next apply. The old source is copied
into the timestamped trash first (recoverable); its
`.mox/attributes.toml` entry (mode, symlink, seed-once) is carried to
the new name; a head ownership declaration travels inside the renamed
source, and a partial target's owned record is re-keyed -- the old live
file keeps its owned content, like any orphaned live file.

## remove

Stop managing a file: move its source (base + `.d/`) into
`<state>/trash/<timestamp>/` recoverably and leave the live file
orphaned. mox forgets the path's applied state, so a later re-add
starts from first contact. `--purge` also deletes the live file,
snapshotting it first; it is refused for a partially owned file (the
live remainder is not mox's to delete).

## apply

Compose all managed files and write them to their live paths
(`--dry-run`, `--overwrite`, `--skip-scripts`, `--defaults`, or a list of
paths to limit the run). `--force` is a retained alias of `--overwrite`.

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

apply is non-interactive. It writes every file that is clean or absent
and never silently changes one that has drifted -- a live file edited
since mox last wrote it, or one mox never wrote (a first apply or
migration). Drifted files are left untouched, listed in a report on
stdout, and the run exits 1. The report names each file, what changed,
and the exact command to resolve it: `mox apply --overwrite <path>`
takes the repo's version, `mox commit <path>` keeps the live edit by
routing it back into its source. `--overwrite` (alias `--force`) with no
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

Every `scripts/pre/`/`scripts/post/` script lands in one of six outcomes,
summarized on the closing line (`scripts: N ran, N skipped, N failed, N
blocked, N declined`): `ran` (exit 0); `skipped` (its directory tuple or
`# mox: when` gate did not match); `declined` (every fact it needs is
bound but empty -- green, does not fail the run); `blocked` (a needed
fact could not be resolved -- see Scripts in
[dsl.md](dsl.md#scripts); counts into the failing exit like `failed`,
under its own label); `failed` (nonzero exit or abnormal termination);
timed out (also counted under `failed`). `--skip-scripts` skips scripts
and their fact checks entirely.

## commit

Route edits made to live files back into their sources.

Each change is confirmed on a terminal:

- `[y/s]` for a routed hunk.
- `[s/x]` for one that lies in no single source (`x` splits it at its
  origin boundaries).
- `[f/d/s]` for an interpolated value: write the fact, or the source's
  `| default`.

`--yes` takes the defaults; `--dry-run` or a non-TTY reports only and
exits 1 if edits remain; `--abort-on-prompt` is strict CI mode, exiting
2 on the first would-be prompt.

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

A file merged from several layers routes per KEY instead of per line,
`[y/p/s]`: each changed key goes to the layer that defines it, and `p`
picks a different layer. A shared (base or universal-fragment) edit
prompts for where it belongs: keep it universal (the default, and what
`--yes` takes) or narrow it to an axis the source compares by value
(synthesizing a `replace from` region). Anything that would reach a
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

## diff

Show a unified diff of the composed output against each live file
(`--stat` for a per-file added/removed summary). A partially owned
file diffs its canonical owned content only, with secret-bearing keys
masked on both sides. Read-only; takes no lock and always exits 0.

## edit

Open the source file behind a managed live path (see [Path
arguments](#path-arguments)) in `$EDITOR`. `--axis <tuple>` edits the matching overlay or region
fragment instead of the base -- the way to reach a variant your current
machine does not compose. Read-only; takes no lock, and reports the
candidate path when the source does not exist.

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

`--drift` shows only the drift set (the report `mox apply` prints for the
same tree, from the same classifier -- the two never disagree), dropping
the clean/gated table and the probe/unbound context. `--json` and
`--porcelain` serialize that set for tooling instead of the human report:
`--json` as an array of `{path, kind, key?, first_contact}`, `--porcelain`
as stable tab-separated lines (`kind`, `key`, `first_contact` 0/1,
`path`). In `--porcelain` the free-form `key` and `path` fields are
C-escaped (`\\`, `\t`, `\n`, `\r`) so a tab or newline in them can never
break the framing; unescape those four to recover exact bytes. Both imply
`--drift` and keep the same exit code.

## export

`export --resolved [--as <tuple>] <out>` bakes a flat resolved tree:
compose every managed file for the current machine (or the given axis
tuple) and write it under `<out>/<live-rel>`. A partially owned target
exports its canonical owned serialization -- the ownership contract,
not a whole live file. Read-only wrt mox state; the walk-away
guarantee and CI parity input.

## facts

List facts (`name = "value"` lines, a machine-readable format kept
byte-frozen for other tooling to parse); interview for any discovered
fact still unanswered. Refuses loudly (rather than reporting an empty
config space) when the source tree cannot be scanned. `--report` replaces
the listing with every discovered fact's state -- `bound "<value>"`,
`declined (bound empty)`, or `UNBOUND`, each with its provenance (source
count, needing scripts) and, when conditioned, the expression it is
asked under.

`facts set <name> <value>` writes one directly; an empty value is the
scriptable decline (`mox facts set <name> ""`), identical to pressing
Enter at an unanswered prompt with no default.

`facts ask [<name>]` re-runs the interview interactively (refuses off a
terminal -- there is no non-interactive form of "ask again"). With
`<name>`, that fact alone, even if already bound: the change-an-answer
flow, with its full choice list, default, and provenance. Bare, every
fact currently unbound or declined whose condition holds -- wider than
the standard interview, which never revisits a decline.

`facts probe tool=<name>` / `facts probe env=<name>` resolves a single
live probe scriptably (exit 0 present, 1 absent, 2 error), unchanged.

## data get

Print a data source as TOML or JSON (`--format=toml|json`); the
private layer shadows the repo.

## doctor

Health report: source files not tracked by git, source modes git
cannot carry that are not yet in `.mox/attributes.toml` (lost on
clone), sources that compose to nothing under every configuration (a
contradictory or mistyped whole-file gate), malformed state
(provenance), and a `facts.toml` fact bound on this machine that
nothing in the repo consumes (`unused-fact <name> (bound but unused by
this repo)`) -- advisory, since deleting or renaming a fact the repo no
longer reads is the user's call. When the unused name is a probable
rename of some still-unbound fact (a short edit distance), the advisory
bridges the two and names the migration directly:
`unused-fact persona (bound but unused; unbound "profile" -- renamed?
mox facts set profile <value>)`. A leftover `data/facts-schema.toml`
gets its own one-line notice: it is no longer read (the interview
derives from the repo's own sources), delete it. `--rebuild-provenance`
recomposes and re-records every tracked file's provenance (partial
targets keep no line provenance and are skipped); `--rebuild-coupling`
rescans source tokens and rewrites the stored coupling graph under
`<state>/coupling/`; `--fix` performs the safe rebuilds. Mutating runs
take the lock; exits 1 while problems remain.

## snapshot / rollback

`snapshot list` lists apply snapshots (taken before every overwrite);
`rollback <id>` restores live files from one. A partially owned file
is never whole-file restored: the snapshot's owned subtree is
re-patched onto the current live file (the program's writes since then
survive) through the same verification and `check` hook as apply, and
a snapshot whose owned values were secret-masked is refused --
re-apply the source instead.

## sync

Fetch, fast-forward, and push the dotfiles repo (`--no-pull` /
`--no-push` skip a half). Any uncommitted change refuses the sync
until you commit it; mox never commits on your behalf. Fast-forwards
the upstream branch only: diverged local history is refused (merge or
rebase it yourself, then re-run) rather than auto-merged and pushed,
and a rejected push asks you to sync again.

## secret

Resolve a secret URI to stdout: `env:NAME`, `file://PATH`,
`op://VAULT/ITEM/FIELD`, `pass://ENTRY`, or `cmd:SHELL` (runs
`/bin/sh -c` and takes the first stdout line).

## trigger

Setup-script staleness primitives (`hash`, `seen-version`, `every`)
for guarding expensive work inside a setup script.

## upgrade

Download and install a newer mox release, verified against its
`SHA256SUMS`, replacing the running binary. `mox upgrade <version>`
for a specific one; never auto-downgrades; `--yes` skips the prompt.

## uninstall

Remove mox's machine-local state (applied records, provenance, ...).
The private layer is preserved unless `--purge-private`; snapshots and
trash -- your recoverable pre-mox originals -- are preserved unless
`--purge-snapshots` / `--purge-trash` or confirmed on a terminal. The
user's source repo is never touched.
