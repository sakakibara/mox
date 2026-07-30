# Using mox day to day

Everything in mox is two motions: **edit a live config where it lives, then
`mox commit`** -- and, for how a config *varies* across machines, **edit its
source, then `mox apply`**. This walks through the tasks they show up in. For
the composition model behind them, see the
[README](../README.md#how-it-works); for the full comment DSL, [dsl.md](dsl.md).

Throughout, `mox` is assumed on your `PATH` (the installer puts it in
`~/.local/bin`). The repo mox reads from is `$MOX_REPO`, defaulting to
`~/.local/share/mox/dotfiles`.

## Starting out

On a machine that already has your dotfiles repo published:

```sh
# install mox, clone the repo, and apply -- in one line
# (<you> expands to https://github.com/<you>/dotfiles; owner/repo,
# host/owner/repo, full URLs, and ssh remotes work too)
sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)" -- \
    init --clone <you> --apply
```

Starting fresh with nothing yet:

```sh
mox init          # creates the repo skeleton (src/, scripts/)
```

Either way, `mox apply` interviews you once for any facts your files need (an
email, a signing key) and writes them to `$XDG_CONFIG_HOME/mox/facts.toml` -- which
stays on the machine, never in the repo. There is no schema to maintain: apply
scans the repo for what it actually asks -- a gate compared by value, a
capture, a script's `MOX_FACT_*` use -- and asks only the questions a
condition reachable on this machine's answers-so-far still leaves open, so a
personal machine is never asked a work-only or backend-only question. On a
machine with no one to answer -- CI, a scripted bootstrap -- `mox apply
--defaults` never prompts: it binds each fact to its declared default (a
capture's `| default`, or a source's own `# mox: default <name>="<value>"`)
and declines everything else, a decline being a persisted empty value, not an
error.

## Managing a file

`mox add` copies a live file into `src/` under its normal name:

```sh
mox add ~/.config/fish/config.fish     # -> src/.config/fish/config.fish
mox add-tree ~/.config/nvim            # every file under a directory
```

The file is now managed. Check state any time:

```sh
mox status        # clean / OUTDATED / DRIFT / MISSING / STALE / GATED per file
mox diff          # the actual composed-vs-live diff
```

## The edit loop

Day to day, change a config by editing the **live** file, where it lives --
your shell or editor picks the change up immediately, like it would on an
unmanaged machine -- then let mox route it back into the repo:

```sh
vim ~/.zshrc             # edit the real file, in place
mox commit ~/.zshrc      # status, diff, apply, and commit all take paths
```

A path argument is absolute, `~`-relative, or relative to the directory you
are in -- so `cd ~/.config/nvim && mox commit init.lua` works, and tab
completion there gives you an argument that means what it looks like. See
[Path arguments](commands.md#path-arguments).

Structure -- an overlay, a `# mox: when` region, a loop, anything about how
the file *varies* -- lives only in sources. For that, edit the **source**
and apply:

```sh
mox edit ~/.zshrc     # opens src/.zshrc in $EDITOR; --axis <tuple> for an overlay
mox apply             # composes and writes it live (mox apply --dry-run to preview)
```

`commit` confirms each change and routes it to the right place. A text file
routes per hunk -- a base line to `src/`, a fragment line to its fragment, a
loop-row edit to its data source:

```
.zshrc  hunk 1/1  ->  src/.zshrc (base)
    - export EDITOR=vim
    + export EDITOR=nvim
  [Y]es  [s]kip  [q]uit  [?]help
```

A file composed by **merging layers** (TOML/JSON/YAML/INI/gitconfig) routes per
**key** instead: each changed key goes to the layer that defines it -- edit the
theme your `os=darwin` overlay set, and `[y]` writes the overlay, not the base.
`[p]` picks a different layer; placing a key in a *less* specific layer promotes
it, deleting the overrides that shadowed it here, and if that changes what any
other machine composes, mox lists those configurations with before/after values
and asks first:

```
config.toml  key 1/1  ->  write to os=darwin.toml
    theme  ->  "solarized"
  [Y]es  [p]ick  [s]kip  [q]uit  [?]help
```

A line whose value came from a fact (`<machine.email>`) offers `[f]` -- update
the fact itself, in `facts.toml`, never the repo -- or `[d]` to change the
source's `| default` instead. A value derived from a secret is never routed.

For a file mox owns only part of, `commit` sees just the owned content: an
edit on the program's side of the contract is never routed. See [A file a program also writes](#a-file-a-program-also-writes).

Every routed edit is verified before it sticks: mox recomposes the file under
every configuration the sources express, and anything you did not choose to
affect composing differently rolls the file back.

## When apply meets an edited live file

`mox apply` never silently overwrites a live file you (or a program) edited
since mox last wrote it. It does not prompt either: it writes the files that
are clean, leaves the drifted ones untouched, and prints a report of them:

```
mox apply
  3 written

  1 drifted, left untouched
    ~/.config/nvim/pack-lock.json   edited since mox wrote it
      take the repo's version:  mox apply --overwrite ~/.config/nvim/pack-lock.json
      keep your edit:           mox commit ~/.config/nvim/pack-lock.json
```

`mox apply --overwrite <path>` discards the live edit and writes the composed
output (snapshotted first, recoverable via `mox rollback`). `mox commit <path>`
keeps the live edit, routing it back into the source so the file ends in sync.
`--overwrite` with no path takes the repo's version of every drifted file;
`mox status --drift` lists them all (`--json`/`--porcelain` for tooling). The
run exits 1 while any drift is unresolved, so a script notices. `--force` is a
retained alias of `--overwrite`.

## A Mac-only (or per-profile) difference

The point of mox is per-machine variation without per-machine files. Two ways,
by file type:

**Structured file** (TOML/JSON/YAML/INI/gitconfig) -- add a partial overlay
beside the base:

```
src/.config/aerospace/aerospace.toml            # the base (all machines)
src/.config/aerospace/aerospace.toml.d/os=darwin.toml   # merged in on macOS
```

The overlay deep-merges into the base; the most specific matching tuple wins.
Tuples combine, e.g. `os=darwin+arch=aarch64.toml`.

**Text or code file** -- gate a region in place with the comment DSL:

```fish
# mox: when os=darwin
    set -gx HOMEBREW_PREFIX /opt/homebrew
# mox: end
```

An axis like `os=darwin` is any fact your source compares *by value*. The set of
configurations is discovered from what your sources mention -- mox never records
which machine you are on.

## A per-machine value

A value that differs per machine (your email, a key) is a **fact**, not an axis.
Reference it in a source with a capture:

```gitconfig
[user]
	email = <machine.email | default "you@example.com">
```

Set it (or let `mox apply` prompt you):

```sh
mox facts                       # list; interview for anything missing
mox facts set email you@work.com
```

Pressing Enter at a prompt with no default binds the empty string -- a
decline, not a skip: mox never asks again, and every gate or capture on that
fact reads it as unset. `mox facts set <name> ""` declines the same way from
a script. To change an answer you already gave (or revisit a decline),
`mox facts ask <name>` re-asks that one fact with its full choice list and
default; `mox facts ask` with no name re-asks every fact still unbound or
declined.

Facts live in `$XDG_CONFIG_HOME/mox/facts.toml` on the machine only.

## A secret

Resolve a secret at apply time -- it is written live but never cached or
committed. Whole line:

```toml
# mox: secret "op://Personal/GitHub/token"
```

Or mid-line:

```sh
export TOKEN="<secret:op://Personal/GitHub/token>"
```

Schemes: `env:`, `file://`, `op://` (1Password), `pass://`, `cmd:`. A file that
resolves an `op://`/`pass://` secret is written 0600.

## Keeping secrets out

A fresh repo from `mox init` already has a `.moxignore` guarding common
credential paths (SSH keys, `*.pem`, Claude's credential files); `add` and
`add-tree` refuse a path it matches (`add --force` overrides one), and
`apply` skips a tracked one that a rule now covers. Add your own patterns to
`.moxignore` (gitignore syntax) to keep other paths out. Full reference:
[docs/ignore.md](ignore.md).

## A file a program also writes

Some live files are shared with the program that reads them: you manage a few
keymap tables of `~/.codex/config.toml`, the program rewrites the rest at
runtime. Whole-file management would see every program write as drift.
Instead, declare which key-paths are *yours* -- in the source file itself, as
head directives in its leading comment block:

```toml
# mox: own tui.keymap.global
# mox: own tui.keymap.composer
# mox: own tui.keymap.editor
# mox: check "scripts/check/codex-config"
[tui.keymap.global]
...
```

mox then manages only those subtrees, and never changes a byte outside them --
verified before every write. The remainder is the program's: `apply` carries it
through verbatim, and `status`, `diff`, and `commit` never even look at it.

When the PROGRAM's region is the sparse one -- a settings file where you
manage nearly everything and the program writes a key or two back -- declare
the complement instead:

```jsonc
// mox: disown model
{
  "theme": "dark",
  ...
}
```

Under `disown` the whole file is yours EXCEPT the declared subtrees: apply
reasserts your keys and preserves the program's spans byte-for-byte, present
or not. A declared path owns its whole subtree either way, the directives
never reach the live file, and the full grammar and rules are in
[dsl.md](dsl.md#file-attributes-and-head-directives).

For a file that should exist only where its tool does, make the base
directive-only: the ownership lines plus a whole-file gate, no content, with
the owned content coming from `<name>.d/` overlays:

```toml
# mox: own tui.keymap.global
# mox: when tool=codex
```

with the keymap itself in `config.toml.d/os=darwin.toml` (or any overlay
that matches the machine). On a machine where the gate fails, the live file
and mox's records are untouched; where it holds, the matching overlays
compose the owned content and apply patches it in. This is the pattern for
declaring ownership over machine-gated files.

### Taking ownership

`mox add --own` onboards a live file in one step:

```sh
mox add --own tui.keymap.global --own tui.keymap.composer \
        --own tui.keymap.editor ~/.codex/config.toml
```

It extracts the named subtrees' raw bytes into a new source file (your comments
inside them survive verbatim), writes the `mox: own` directive lines at its
head -- the declaration and the content are created together, in one file --
and reports how much of the file remains the program's.
When the live layout forces it, the extraction reorders spans -- a root-level
key is placed before the block tables so it parses the same -- and the capture
is validated three ways before anything is written: it must parse, lie entirely
within the declaration, and reproduce the live owned content exactly.

`mox add --disown <key-path>` (repeatable, exclusive with `--own`) is the
inverse: the whole live file minus the named subtrees becomes the source,
prefixed with `mox: disown` lines -- comments outside the spans survive
verbatim, and the same three-way validation runs against the owned
complement.

A machine-gated partial file onboards in one command with `--gate
<axis-expr>`:

```sh
mox add --own tui.keymap.global --gate "tool=codex" ~/.codex/config.toml
```

The created source head is the ownership directives followed by the
whole-file `mox: when` gate line, so the file applies only where the
expression holds and stays untouched everywhere else. The expression must
parse; a malformed one is refused with the parser's diagnostic, and nothing
is written.

A named path absent from the live file is an error; a key you want kept *out*
everywhere is declared with `--own-absent <key-path>` instead (own mode only),
and apply then enforces its absence. A plain `mox add` of a target whose
source head declares ownership is refused (it is managed per key-path), and
`add-tree` skips it.

Backing out of ownership is the head edit in reverse: delete the `mox: own`
(or `mox: disown`) lines from the source, and the next `mox apply` returns
the file to whole-file management -- the whole composed source becomes the
contract, drift-checked as one file.

### The lifecycle

- `mox apply` patches the owned content to the composed state and preserves
  every protected byte exactly -- the declared subtrees under `own`, their
  complement under `disown`. A live file that does not parse is refused
  rather than guessed at; an `own` path the composed source does not populate
  is removed from the live file (through the same drift rule below -- a value
  that changed there is drift, never a silent removal); a file whose
  whole-file gate is off for this machine is untouched entirely.
- `mox status` and `mox diff` judge only the owned content: `DRIFT` means it
  changed outside mox, and the program's writes on the protected side never
  surface. The diff is the canonical composed content against the live
  content, labeled with the live path.
- `mox commit` routes per key over the owned content, exactly like a layered
  structured file.

Owned content in `diff` and `export` output is rendered in mox's canonical
serialization: one `= <path>` header line per declared path, the subtree's
keys sorted and indented under it (`key = value` for scalars, `key:` for
nested tables). Each diff hunk is preceded by the `= <path>` header of the
section it falls in, so a changed value always names its key. For a partial
target, `mox export --resolved` writes exactly this serialization: the owned
contract is the deliverable, never a whole live file that belongs partly to
the program.

Drift protection follows the whole-file rule over the owned content: it is
compared against what mox last applied, and a mismatch is reported as drift
and left untouched instead of overwritten. First contact -- no
applied record yet, a path newly added to `own`, or one removed from
`disown` -- needs consent too: live content already matching the source is
adopted without asking (`adopted` in the apply output); anything else is
`DRIFT`, resolved the usual way -- `mox apply --overwrite <path>` or
`mox commit <path>`. A path newly added to `disown` simply
stops being compared -- the protected set grew. There is no way for mox to
take over existing content without you seeing it.

### Validating before the write

The optional `check` directive names a repo-relative executable (plus
arguments) that must accept every candidate before it lands -- app-specific
logic like "the program must parse this" stays in a small repo script:

```sh
#!/bin/sh
# scripts/check/codex-config
exec the-program --validate-config "$MOX_CHECK_FILE"
```

The candidate is materialized in a private temp dir; the hook gets
`MOX_CHECK_FILE` and `MOX_CHECK_DIR` and accepts with exit 0. Any other exit,
or a timeout, refuses the file and reports the hook's output. The full
contract -- spawn rules, timeout override, trust model -- is in
[dsl.md](dsl.md#file-attributes-and-head-directives). Under `--skip-scripts` the hook does not run
and a check-bearing file is not written: never an unvalidated install.

### Secrets in owned content

An owned path whose composed value resolves a [secret](#a-secret) follows the
usual rule -- cleartext is written live, never cached -- so the owned record
keeps only a hash. The consequences: `mox diff` masks such keys on both sides
(a change confined to secret keys shows no diff), `mox commit` skips the file
(`contains a secret; edit its source directly` -- there is no cleartext to
route), snapshots store masked
values, and `mox rollback` refuses a snapshot whose owned values were masked:
placeholders are never written live; re-apply the source instead.

## Syncing a second machine

mox does not commit for you. Commit in the repo, then:

```sh
mox sync          # fetch, fast-forward, push (--no-pull / --no-push to skip a half)
```

On the other machine, `mox sync` (or `git pull`) then `mox apply`. `sync` refuses
to proceed with uncommitted changes or diverged history -- resolve those
yourself, so nothing is auto-merged or force-pushed.

## Undoing an apply

Every overwrite is snapshotted first:

```sh
mox snapshot list
mox rollback <id>       # restore the live files from that snapshot
```

A [partially owned file](#a-file-a-program-also-writes) is not whole-file
restored -- that would clobber what the program wrote since the snapshot.
Rollback re-patches the snapshot's owned content onto the *current* live
file, through the same verification and `check` hook as apply.

`mox diff` before an apply, and `mox apply --dry-run`, both let you look before
you leap.

## Keeping mox current

```sh
mox upgrade             # latest release, verified against SHA256SUMS
mox upgrade v0.1.2      # a specific version (never auto-downgrades on `latest`)
```

## When something looks wrong

```sh
mox doctor              # untracked sources, un-carryable modes, dead gates, bad state
mox doctor --fix        # perform the safe rebuilds
```
