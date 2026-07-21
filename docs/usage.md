# Using mox day to day

Everything in mox is one loop: **change a config in its normal format, then run
`mox apply`.** This walks through the tasks that loop shows up in. For the
composition model behind it, see the [README](../README.md#how-it-works); for the
full comment DSL, [dsl.md](dsl.md).

Throughout, `mox` is assumed on your `PATH` (the installer puts it in
`~/.local/bin`). The repo mox reads from is `$MOX_REPO`, defaulting to
`~/.local/share/mox/dotfiles`.

## Starting out

On a machine that already has your dotfiles repo published:

```sh
# install mox, clone the repo, and apply -- in one line
sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)" -- \
    init --clone https://github.com/<you>/dotfiles --apply
```

Starting fresh with nothing yet:

```sh
mox init          # creates the repo skeleton (src/, scripts/)
```

Either way, `mox apply` interviews you once for any facts your files need (an
email, a signing key) and writes them to `~/.config/mox/facts.toml` -- which
stays on the machine, never in the repo.

## Managing a file

`mox add` copies a live file into `src/` under its normal name:

```sh
mox add ~/.config/fish/config.fish     # -> src/.config/fish/config.fish
mox add-tree ~/.config/nvim            # every file under a directory
```

The file is now managed. Check state any time:

```sh
mox status        # clean / OUTDATED / DRIFT / MISSING / GATED per file
mox diff          # the actual composed-vs-live diff
```

## The edit loop

To change a config, edit its **source** and apply:

```sh
mox edit ~/.zshrc     # opens src/.zshrc in $EDITOR
mox apply             # composes and writes it live (mox apply --dry-run to preview)
```

If you instead hand-edited the **live** file (say `~/.zshrc` directly), pull that
change back into the source:

```sh
mox commit ~/.zshrc
```

`commit` confirms each hunk and routes it to the right place -- a base line to
`src/`, a fragment line to its fragment, a loop-row edit to its data source.

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

Facts live in `~/.config/mox/facts.toml` on the machine only.

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
