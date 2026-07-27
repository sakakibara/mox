# Command reference

The behavioral contract of every command. `mox <cmd> --help` lists the
flags; [usage.md](usage.md) walks through the day-to-day tasks.

Mutating commands (`apply`, `commit`, `rollback`, `facts set`, `sync`,
`upgrade`, `mv`, `remove`, `uninstall`) take a single-writer lock at
`state/mox.lock`; a second process is refused while the first runs. An
unknown command exits 2.

## init

Initialize a fresh mox repo (`src/` and `scripts/`). `--clone <url>`
clones an existing dotfiles repo into the repo dir; by default it stops
for you to review -- a cloned repo's files and scripts are untrusted
until you look at them -- and `--apply` applies right away for a
one-command bootstrap. Refuses a non-empty repo dir.

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

## add-tree

Recursively `add` every non-junk regular file under a live directory;
already-managed files, junk, and paths matching a repo ignore rule are
skipped.

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
(`--dry-run`, `--force`, `--skip-scripts`, or a list of paths to limit
the run).

A live file edited since mox last wrote it is never overwritten
silently. On a terminal each one asks `[o]verwrite` (discard the live
edit), `[c]ommit` (route the live edit back into its source layer,
verified like any other commit), `[d]iff`, `[s]kip`, or `[O]`/`[S]` to
answer the rest the same way -- so two drifted files wanting opposite
outcomes are resolved in one run. Off a terminal, or with `--dry-run`,
drifted files are skipped and reported and the run exits 1; `--force`
overwrites them all without asking.

A partially owned file (an `own` or `disown` head declaration) is
patched around the other side's content: the owned content is written,
every protected byte is preserved exactly, drift is judged on the owned
content only, and its `check` hook (if any) must accept the candidate
first. Under `--skip-scripts` the hook does not run and a check-bearing
file is not written.

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

Open the source file behind a managed live path (or src-relative name)
in `$EDITOR`. `--axis <tuple>` edits the matching overlay or region
fragment instead of the base -- the way to reach a variant your current
machine does not compose. Read-only; takes no lock, and reports the
candidate path when the source does not exist.

## status

Show each managed file's state: `clean`, `OUTDATED`, `DRIFT`,
`MISSING`, `GATED`, `ERROR`, plus this run's probe log (every
`tool=`/`env=` name asked and whether it resolved). A partially owned
file is classified on its owned content only, so the program's writes
on the other side never surface. Exits 1 if any file is `OUTDATED`,
`DRIFT`, `MISSING`, or `ERROR`.

## export

`export --resolved [--as <tuple>] <out>` bakes a flat resolved tree:
compose every managed file for the current machine (or the given axis
tuple) and write it under `<out>/<live-rel>`. A partially owned target
exports its canonical owned serialization -- the ownership contract,
not a whole live file. Read-only wrt mox state; the walk-away
guarantee and CI parity input.

## facts

List facts; interview for missing ones. `facts set <name> <value>`
writes one; `facts probe tool=<name>` / `facts probe env=<name>`
resolves a single live probe scriptably (exit 0 present, 1 absent,
2 error).

## data get

Print a data source as TOML or JSON (`--format=toml|json`); the
private layer shadows the repo.

## doctor

Health report: source files not tracked by git, source modes git
cannot carry that are not yet in `.mox/attributes.toml` (lost on
clone), sources that compose to nothing under every configuration (a
contradictory or mistyped whole-file gate), and malformed state
(provenance). `--rebuild-provenance` recomposes and re-records every
tracked file's provenance (partial targets keep no line provenance and
are skipped); `--rebuild-coupling` rescans source tokens and rewrites
the stored coupling graph under `<state>/coupling/`; `--fix` performs
the safe rebuilds. Mutating runs take the lock; exits 1 while problems
remain.

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
