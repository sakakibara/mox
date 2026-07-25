# mox

A dotfiles manager that keeps your config files in their native format,
synced across machines, with per-axis overlays for per-OS, per-profile,
and per-machine differences.

Named for the mox: a small artifact that costs nothing to play and
powers everything else.

## Install

One command, depending on nothing a fresh machine lacks (a shell, curl or wget,
and tar). It downloads the release binary for your platform, verifies it against
the release's `SHA256SUMS`, and installs to `~/.local/bin` (override with
`BINDIR`):

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)"
```

mox is meant to be the *first* thing on a new machine -- it installs your
runtimes and packages from there. Pass any mox arguments after `--` to install
and bootstrap in one step:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)" -- \
    init --clone https://github.com/<you>/dotfiles --apply
```

On Windows (PowerShell):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sakakibara/mox/main/install.ps1)))
```

`MOX_VERSION` pins a release tag; `MOX_BASE_URL` points at a mirror. Update in
place with `mox upgrade` (it verifies the download against `SHA256SUMS`).

To build from source instead (requires Zig 0.16.0): `zig build`.

## Quickstart

The whole model is one loop: **edit a config in its normal format, then
`mox apply`.**

```sh
mox init                              # a fresh repo (or: init --clone <url> --apply)
mox add ~/.config/fish/config.fish    # start managing an existing file
mox apply                             # write every managed file to its live path
```

`mox add` copies the file into your repo's `src/` under its normal name
(`src/.config/fish/config.fish`) -- no `dot_`/`executable_` prefixes. From then
on you edit the source and run `mox apply`; mox composes it (see
[How it works](#how-it-works)) and writes it live.

## Day to day

| You want to... | Do this |
| --- | --- |
| See what's managed and what changed | `mox status` (`mox diff` for the actual diff) |
| Manage a new file / a whole dir | `mox add <path>` / `mox add-tree <dir>` |
| Change a config | edit the source (`mox edit <path>` opens it), then `mox apply` |
| Preview before writing | `mox apply --dry-run` |
| Keep a hand-edit you made to the *live* file | `mox commit <path>` -- routes it back into the source |
| Make something Mac-only (or per-profile) | a `foo.toml.d/os=darwin.toml` overlay, or a `# mox: when os=darwin` block |
| Use a per-machine value (email, key) | a *fact* -- `mox facts`, referenced as `<machine.email>` |
| Share to another machine | `git push` in the repo, then `mox apply` there (or `mox sync`) |
| Undo a bad apply | `mox snapshot list`, then `mox rollback <id>` |
| Update mox itself | `mox upgrade` |

A step-by-step walkthrough of each task is in [docs/usage.md](docs/usage.md).

## How it works

mox composes each managed file from a **base** file in `src/` plus **overlays**
selected by *axes* -- `os`, `arch`, `profile`, `machine`, and any fact your
source compares by value. How an overlay applies depends on the file's format.

### Structured files (TOML, JSON, YAML, INI, gitconfig)

Overlays are sibling files in a `<name>.d/` directory, each named by the axis
tuple it matches. `config.toml` beside `config.toml.d/os=darwin.toml` composes to
the merged darwin variant on a Mac, and to the base elsewhere. An overlay is a
*partial* document that deep-merges into the base -- nested tables merge key by
key, while a scalar or array replaces -- and the most specific matching tuple
wins. A file can also be gated as a whole: with no base it materializes only
where an overlay matches, and a leading `# mox: when` on line 1 governs whether
it appears at all.

### Text and code files (`.zshrc`, a Lua config)

These select their per-axis content *in place*, through a small comment DSL: a
`# mox: when os=darwin` region, or an `include` / `replace from` directive that
splices a fragment from the file's `.d/` directory. There is no template language
in the file body -- only that DSL (`include`, `replace`, `for`, `when`, and more,
covered in [docs/dsl.md](docs/dsl.md)).

### Facts

Values you interpolate -- an email, a signing key -- are *facts*, written
`<machine.email | default "...">` in a source and kept in
`$XDG_CONFIG_HOME/mox/facts.toml`, never in the repo. `mox apply` interviews you
once for any a reachable file needs and are not yet set.

### Secrets

A whole-line `# mox: secret "<uri>"` or a mid-line `<secret:URI>` capture resolves
a secret at apply time from `env:`, `file://`, `op://` (1Password), `pass://`, or
`cmd:`. The cleartext is written to the live file but never cached in mox state or
committed, and a file that resolves an `op://`/`pass://` secret is applied 0600.

### Modes and symlinks

Managed files keep their native names -- no mode or type prefix. A file's target
mode is its source's own permission bits, so `chmod +x` the source and git
carries the exec bit (0644 and 0755 survive a clone). Modes git cannot carry
(0600, 0444), symlink targets, and `mox add --seed-once` intent are recorded in
`.mox/attributes.toml` (maintained by mox). A symlink is just a source file
whose content is the link target, so it composes by axis like anything else.

### Partial ownership

Some files are written by both you and the program that reads them -- a few
keymap tables in a config the program otherwise rewrites at runtime, or a
settings file where the program writes a couple of keys back. The contract is
declared in the source file itself, as comment directives in its leading
comment block:

```toml
# mox: own tui.keymap.global
# mox: own tui.keymap.composer
# mox: check "scripts/check/codex-config"
[tui.keymap.global]
...
```

`own` makes mox manage only the declared key subtrees; `disown` is the
complement -- mox manages the whole file EXCEPT the declared subtrees, for a
file where the program's region is the sparse one (`// mox: disown model` in a
settings.json). Either way mox never changes a byte of the other side --
verified before every write, and refused outright when the live file cannot be
patched provably -- and the directives never reach the live file. Drift follows
the whole-file rule over the owned content: it is compared against what mox
last applied, so a change there -- the program's or yours -- is surfaced,
never silently overwritten, and taking ownership of existing content (first
apply, or a change to the declared list) adopts it only when it already
matches the source. An optional `check` directive names a repo script that
must accept each candidate before it is written. Onboard a file with `mox add
--own` or `mox add --disown`; the walkthrough is in
[docs/usage.md](docs/usage.md#a-file-a-program-also-writes) and the directive
reference in [docs/dsl.md](docs/dsl.md#file-attributes-and-head-directives).

### Ignoring files

A repo-scoped `.moxignore` / `.mox/ignore` (gitignore syntax, axis-gated like
any other file) keeps a path out of mox entirely: refused by `add`/`add-tree`,
skipped by `apply`, and exempt from exact-directory pruning. `mox init`
scaffolds a starter file guarding common secret paths. See
[docs/ignore.md](docs/ignore.md).

### Setup scripts

`scripts/pre/` run before the write pass (bootstrap installers); `scripts/post/`
run after (reloads). Each runs on every apply -- guard expensive work inside the
script with `mox trigger`. Gate a script by a single-tuple subdir
(`scripts/pre/os=darwin/`) and/or a leading `# mox: when os=darwin or os=linux`
comment.

## Commands

| Command | What it does |
| --- | --- |
| `init` | Initialize a fresh mox repo (`src/` and `scripts/`). `--clone <url>` clones an existing dotfiles repo into the repo dir; by default it stops for you to review (a cloned repo's files and scripts are untrusted until you look at them), `--apply` applies right away for a one-command bootstrap. Refuses a non-empty repo dir |
| `add <path>` | Start managing a live file as a base file in `src/`. A path matching a repo ignore rule (`.moxignore` / `.mox/ignore`) is refused (`--force` overrides). `--own <key-path>` (repeatable) takes partial ownership of a structured file instead: the named subtrees are extracted into the source (comments inside them survive) under `mox: own` head directives; `--own-absent <key-path>` declares a key mox enforces as absent; `--disown <key-path>` (repeatable, exclusive with `--own`) captures the whole file MINUS the named subtrees under `mox: disown` directives. A plain `add` of a target whose source head declares ownership is refused |
| `add-tree <dir>` | Recursively `add` every non-junk regular file under a live directory; already-managed files, junk, and paths matching a repo ignore rule are skipped |
| `mv <old> <new>` | Rename a managed file's source (base file and its `.d/` overlay dir) so the live target changes on the next apply. The old source is copied into the timestamped trash first (recoverable); its `.mox/attributes.toml` entry (mode, symlink, seed-once) is carried to the new name, a head ownership declaration travels inside the renamed source, and a partial target's owned record is re-keyed -- the old live file keeps its owned content, like any orphaned live file. Takes the lock |
| `remove <name>` | Stop managing a file: move its source (base + `.d/`) into `<state>/trash/<timestamp>/` recoverably and leave the live file orphaned. mox forgets the path's applied state, so a later re-add starts from first contact. `--purge` also deletes the live file, snapshotting it first; it is refused for a partially owned file (the live remainder is not mox's to delete). Takes the lock |
| `apply` | Compose all managed files and write them to their live paths (`--dry-run`, `--force`, `--skip-scripts`, or a list of paths to limit the run). A live file edited since mox last wrote it is never overwritten silently: on a terminal each one asks `[o]verwrite` (discard the live edit), `[c]ommit` (route the live edit back into its source layer, verified like any other commit), `[d]iff`, `[s]kip`, or `[O]`/`[S]` to answer the rest the same way -- so two drifted files wanting opposite outcomes are resolved in one run. Off a terminal, or with `--yes`/`--dry-run`, drifted files are skipped and reported and the run exits 1; `--force` overwrites them all without asking. A partially owned file (an `own` or `disown` head declaration) is patched around the other side's content: the owned content is written, every protected byte is preserved exactly, drift is judged on the owned content only, and its `check` hook (if any) must accept the candidate first -- under `--skip-scripts` the hook does not run and a check-bearing file is not written |
| `commit` | Route edits made to live files back into their sources. Each change is confirmed on a terminal -- `[y/s]` for a routed hunk, `[s/x]` for one that lies in no single source (`x` splits it at its origin boundaries), `[f/d/s]` for an interpolated value (write the fact, or the source's `| default`) -- with `--yes` taking the defaults, `--dry-run` or a non-TTY reporting only and exiting 1 if edits remain, and `--abort-on-prompt` as strict CI mode, exiting 2 on the first would-be prompt. Base lines go to `src/`, fragment lines to their fragment, loop-row edits to the data source; private-origin edits go only to the private layer, never repo `src/`; a value derived from a secret or an interpolation is reported, never routed. A file merged from several layers routes per KEY instead of per line, `[y/p/s]`: each changed key goes to the layer that defines it, and `p` picks a different layer. A shared (base or universal-fragment) edit prompts for where it belongs: keep it universal (the default, and what `--yes` takes) or narrow it to an axis the source compares by value (synthesizing a `replace from` region). Anything that would reach a machine beyond the one you chose -- promoting a key to a layer other machines read, say -- lists those configurations and asks first. The result is verified by recomposing every configuration the source expresses; a violation -- any configuration you did not choose to affect composing differently than before -- aborts the write and restores the source. When a changed token also lives in other managed sources, commit prompts `[Y/n/d/D/q]` to update them in the same write pass. A partially owned file always routes per key, over its owned content only; one whose owned content resolved a secret is skipped (its record is a hash -- edit the source directly) |
| `diff` | Show a unified diff of the composed output against each live file (`--stat` for a per-file added/removed summary). A partially owned file diffs its canonical owned content only, with secret-bearing keys masked on both sides. Read-only; takes no lock and always exits 0 |
| `edit <name>` | Open the source file behind a managed live path (or src-relative name) in `$EDITOR`. `--axis <tuple>` edits the matching overlay (Cat A/C) or region fragment (Cat B) instead of the base. Read-only; takes no lock, and reports the candidate path when the source does not exist |
| `status` | Show each managed file's state: `clean`, `OUTDATED`, `DRIFT`, `MISSING`, `GATED`, `ERROR`. A partially owned file is classified on its owned content only, so the program's writes on the other side never surface. Exits 1 if any file is `OUTDATED`, `DRIFT`, `MISSING`, or `ERROR` |
| `export --resolved [--as <tuple>] <out>` | Bake a flat resolved tree: compose every managed file for the current machine (or the given axis tuple) and write it under `<out>/<live-rel>`. A partially owned target exports its canonical owned serialization -- the ownership contract, not a whole live file. Read-only wrt mox state; the walk-away guarantee and CI parity input |
| `facts` | List facts; interview for missing ones (`facts set <name> <value>`) |
| `data get <name>` | Print a data source as TOML or JSON (`--format=toml\|json`); the private layer shadows the repo |
| `doctor` | Health report: source files not tracked by git, source modes git cannot carry that are not yet in `.mox/attributes.toml` (lost on clone), sources that compose to nothing under every configuration (a contradictory or mistyped whole-file gate), and malformed state (provenance). `--rebuild-provenance` recomposes and re-records every tracked file's provenance (partial targets keep no line provenance and are skipped); `--rebuild-coupling` rescans source tokens and rewrites the stored coupling graph under `<state>/coupling/`; `--fix` performs the safe rebuilds. Mutating runs take the lock; exits 1 while problems remain |
| `snapshot list` | List apply snapshots (taken before every overwrite) |
| `rollback <id>` | Restore live files from a snapshot. A partially owned file is never whole-file restored: the snapshot's owned subtree is re-patched onto the current live file (the program's writes since then survive) through the same verification and `check` hook as apply, and a snapshot whose owned values were secret-masked is refused -- re-apply the source instead |
| `sync` | Fetch, fast-forward, and push the dotfiles repo (`--no-pull` / `--no-push` skip a half). Any uncommitted change refuses the sync until you commit it; mox never commits on your behalf. Fast-forwards the upstream branch only: diverged local history is refused (merge or rebase it yourself, then re-run) rather than auto-merged and pushed, and a rejected push asks you to sync again. Takes the lock |
| `secret <uri>` | Resolve a secret URI to stdout: `env:NAME`, `file://PATH`, `op://VAULT/ITEM/FIELD`, `pass://ENTRY`, or `cmd:SHELL` (runs `/bin/sh -c` and takes the first stdout line) |
| `trigger ...` | Setup-script staleness primitives (`hash`, `seen-version`, `every`) |
| `upgrade` | Download and install a newer mox release, verified against its `SHA256SUMS`, replacing the running binary. `mox upgrade <version>` for a specific one; never auto-downgrades; `--yes` skips the prompt |
| `uninstall` | Remove mox's machine-local state (applied records, provenance, ...). The private layer is preserved unless `--purge-private`; snapshots and trash -- your recoverable pre-mox originals -- are preserved unless `--purge-snapshots` / `--purge-trash` or confirmed on a terminal. The user's source repo is never touched. Takes the lock |
| `help`, `version` | Show help or the mox version |

Mutating commands (`apply`, `commit`, `rollback`, `facts set`, `sync`, `upgrade`)
take a single-writer lock at `state/mox.lock`; a second process is refused while
the first runs. An unknown command exits 2.

## Privacy

**Nothing about a machine leaves it.** mox records no per-machine file in the
repo. `commit` decides where an edit belongs by simulating it against the
configurations your source expresses (`os=darwin`, `profile=work`), and by
asking you. Your facts -- an email, a signing key -- are values, never
classifications: they stay in `$XDG_CONFIG_HOME/mox/facts.toml` and never enter
the repo in any form.
