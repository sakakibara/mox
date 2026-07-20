# mox

A dotfiles manager that keeps your config files in their native format,
synced across machines, with per-axis overlays for per-OS, per-profile,
and per-machine differences.

Named for the mox: a small artifact that costs nothing to play and
powers everything else.

## Build

Requires Zig 0.16.0.

```sh
zig build
./zig-out/bin/mox
```

## How it works

mox composes each managed file from a base file in `src/` plus overlays
selected by *axes* -- `os`, `arch`, `profile`, `machine`, and any fact your
source compares by value. How an overlay applies depends on the file's format.
A **structured** file (TOML, JSON, YAML, INI, gitconfig) takes overlays as
sibling files in a `<name>.d/` directory, each named by the axis tuple it
matches: a `config.toml` beside `config.toml.d/os=darwin.toml` composes to the
merged darwin variant on a Mac and to the base elsewhere. The overlay is a
partial document that deep-merges into the base -- nested tables merge key by
key, while a scalar or array in the overlay replaces the base's -- and the most
specific matching tuple wins. A structured file can be gated as a whole, too:
with no base it materializes only where an overlay matches, and a leading
`# mox: when` at line 1 governs whether it appears at all -- either way overlays
still deep-merge. A **text or code** file (a `.zshrc`, a Lua config)
instead selects its per-axis content in place, through the comment DSL: a
`# mox: when os=darwin` region, or an `include` / `replace from` directive that
splices a fragment from the file's `.d/` directory. Either way files keep their
native format; there is no template language in the file body, only that small
comment DSL (`include`, `replace`, `for`, `when`, and more, covered in
[docs/dsl.md](docs/dsl.md)). Values you interpolate -- an email, a signing key --
are *facts*, kept in `$XDG_CONFIG_HOME/mox/facts.toml`, never in the repo.

Managed files keep their native names -- no mode or type prefix on the filename.
A file's target mode is its source file's own permission bits, so `chmod +x` the
source and git carries the exec bit (0644 and 0755 round-trip a clone). The
attributes git cannot carry -- a mode that is neither 0644 nor 0755 (0600, 0444),
a symlink target, and `mox add --seed-once` intent -- are recorded in a
generated `.mox/attributes.toml`, keyed by portable target path. That file is
machine-written; do not hand-edit it. A symlink is a regular source file whose
content is the link target, so it composes by axis like any other file; `mox add`
of a live symlink captures it. See [docs/dsl.md](docs/dsl.md) for details.

Setup scripts live in `scripts/pre/` (run before the write pass, for bootstrap
installers) and `scripts/post/` (run after, for reloads). Each runs on every
apply -- guard expensive work inside the script with `mox trigger`. A script is
gated by a single-tuple subdir (`scripts/pre/os=darwin/`) and may add its own
axis-expression gate as a `# mox: when os=darwin or os=linux` comment among its
leading lines; both must hold for it to run.

## Quickstart

```sh
mox init                 # create a fresh repo (src/ and scripts/)
mox add ~/.zshrc         # start managing a live file
mox facts                # fill in any facts your files interpolate
mox apply                # compose every managed file to its live path
```

Edit a live file and `mox commit` routes the change back into the right source;
`mox status` and `mox diff` show what differs before you apply. (These assume
`mox` is on your `PATH`; otherwise call `./zig-out/bin/mox`.)

## Commands

| Command | What it does |
| --- | --- |
| `init` | Initialize a fresh mox repo (`src/` and `scripts/`). `--clone <url>` clones an existing dotfiles repo into the repo dir for you to review; it does not apply (a cloned repo's files and scripts are untrusted until you look at them -- run `mox apply` yourself once you have). Refuses a non-empty repo dir |
| `add <path>` | Start managing a live file as a base file in `src/` |
| `add-tree <dir>` | Recursively `add` every non-junk regular file under a live directory; already-managed files and junk are skipped |
| `mv <old> <new>` | Rename a managed file's source (base file and its `.d/` overlay dir) so the live target changes on the next apply. The old source is copied into the timestamped trash first (recoverable); its `.mox/attributes.toml` entry (mode, symlink, seed-once) is carried to the new name. Takes the lock |
| `remove <name>` | Stop managing a file: move its source (base + `.d/`) into `<state>/trash/<timestamp>/` recoverably and leave the live file orphaned. `--purge` also deletes the live file, snapshotting it first. Takes the lock |
| `apply` | Compose all managed files and write them to their live paths (`--dry-run`, `--force`) |
| `commit` | Route edits made to live files back into their sources. Each changed hunk is confirmed `[Y/n/m]` on a terminal (`--yes` takes the defaults; `--dry-run` or a non-TTY only reports and exits 1 if edits remain; `--abort-on-prompt` is strict CI mode, exiting 2 on the first would-be prompt). Base lines go to `src/`, fragment lines to their fragment, loop-row edits to the data source; private-origin edits go only to the private layer, never repo `src/`; secret, interpolated, and structural-merge hunks are reported as manual. A shared (base or universal-fragment) edit prompts for where it belongs: keep it universal (the default, and what `--yes` takes) or narrow it to an axis the source compares by value (synthesizing a `replace from` region). The choice is verified by recomposing every other configuration the source expresses; a violation -- any configuration you did not choose to affect composing differently than before -- aborts the write and restores the source. When a changed token also lives in other managed sources, commit prompts `[Y/n/d/D/q]` to update them in the same write pass |
| `diff` | Show a unified diff of the composed output against each live file (`--stat` for a per-file added/removed summary). Read-only; takes no lock and always exits 0 |
| `edit <name>` | Open the source file behind a managed live path (or src-relative name) in `$EDITOR`. `--axis <tuple>` edits the matching overlay (Cat A/C) or region fragment (Cat B) instead of the base. Read-only; takes no lock, and reports the candidate path when the source does not exist |
| `status` | Show each managed file's state: `clean`, `OUTDATED`, `DRIFT`, `MISSING`, `GATED`, `ERROR`. Exits 1 if any file is `OUTDATED`, `DRIFT`, `MISSING`, or `ERROR` |
| `export --resolved [--as <tuple>] <out>` | Bake a flat resolved tree: compose every managed file for the current machine (or the given axis tuple) and write it under `<out>/<live-rel>`. Read-only wrt mox state; the walk-away guarantee and CI parity input |
| `facts` | List facts; interview for missing ones (`facts set <name> <value>`) |
| `data get <name>` | Print a data source as TOML or JSON (`--format=toml\|json`); the private layer shadows the repo |
| `doctor` | Health report: source files not tracked by git, source modes git cannot carry that are not yet in `.mox/attributes.toml` (lost on clone), sources that compose to nothing under every configuration (a contradictory or mistyped whole-file gate), and malformed state (provenance). `--rebuild-provenance` recomposes and re-records every tracked file's provenance; `--rebuild-coupling` rescans source tokens and rewrites the stored coupling graph under `<state>/coupling/`; `--fix` performs the safe rebuilds. Mutating runs take the lock; exits 1 while problems remain |
| `snapshot list` | List apply snapshots (taken before every overwrite) |
| `rollback <id>` | Restore live files from a snapshot |
| `sync` | Fetch, fast-forward, and push the dotfiles repo (`--no-pull` / `--no-push` skip a half). Any uncommitted change refuses the sync until you commit it; mox never commits on your behalf. Fast-forwards the upstream branch only: diverged local history is refused (merge or rebase it yourself, then re-run) rather than auto-merged and pushed, and a rejected push asks you to sync again. Takes the lock |
| `secret <uri>` | Resolve a secret URI to stdout: `env:NAME`, `file://PATH`, `op://VAULT/ITEM/FIELD`, `pass://ENTRY`, or `cmd:SHELL` (runs `/bin/sh -c` and takes the first stdout line) |
| `trigger ...` | Setup-script staleness primitives (`hash`, `seen-version`, `every`) |
| `uninstall` | Remove mox's machine-local state (applied records, provenance, ...). The private layer is preserved unless `--purge-private`; snapshots and trash -- your recoverable pre-mox originals -- are preserved unless `--purge-snapshots` / `--purge-trash` or confirmed on a terminal. The user's source repo is never touched. Takes the lock |
| `help`, `version` | Show help or the mox version |

Mutating commands (`apply`, `commit`, `rollback`, `facts set`, `sync`) take a single-writer
lock at `state/mox.lock`; a second process is refused while the first runs.
An unknown command exits 2.

## Privacy

**Nothing about a machine leaves it.** mox records no per-machine file in the
repo. `commit` decides where an edit belongs by simulating it against the
configurations your source expresses (`os=darwin`, `profile=work`), and by
asking you. Your facts -- an email, a signing key -- are values, never
classifications: they stay in `$XDG_CONFIG_HOME/mox/facts.toml` and never enter
the repo in any form.
