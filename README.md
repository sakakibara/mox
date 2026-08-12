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

### sh & curl

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)"
```

### sh & wget

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)"
```

### powershell

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sakakibara/mox/main/install.ps1)))
```

mox is meant to be the *first* thing on a new machine -- it installs your
runtimes and packages from there. Any arguments after the script (after `--`
in the sh forms) are passed to the installed mox, so one line installs and
bootstraps:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)" -- \
    init --clone <you> --apply
```

`--clone <you>` is shorthand for `https://github.com/<you>/dotfiles`;
`owner/repo`, `host/owner/repo`, full URLs, ssh remotes, and local paths
all work too. The powershell form takes the same arguments directly, no
`--`: `& ([scriptblock]::Create((irm .../install.ps1))) init --clone <you> --apply`.
For a non-interactive machine, add `--defaults`: the facts interview
then binds every unanswered fact to its declared default and declines
the rest, instead of prompting -- a zero-touch bootstrap.

`MOX_VERSION` pins a release tag; `MOX_BASE_URL` points at a mirror. Update in
place with `mox upgrade` (it verifies the download against `SHA256SUMS`).

To build from source instead (requires Zig 0.16.0): `zig build`.

## Quickstart

Two motions cover everything:

- **Tweak a config**: edit the live file, where it lives, in its normal
  format -- then `mox commit` routes the change back into the right
  source, verified.
- **Change how a config varies**: per-OS overlays, gated regions, and
  per-machine facts live in `src/` -- edit the source (`mox edit`) and
  `mox apply`.

```sh
mox init                              # a fresh repo (or: init --clone <url> --apply)
mox add ~/.config/fish/config.fish    # start managing an existing file
vim ~/.config/fish/config.fish        # keep editing it where it lives
mox commit                            # route the edits back into src/
```

`mox add` copies the file into your repo's `src/` under its normal name
(`src/.config/fish/config.fish`) -- no `dot_`/`executable_` prefixes, no
template language in the body.

## Day to day

| You want to... | Do this |
| --- | --- |
| Change a config | edit the live file, then `mox commit` |
| Make something Mac-only (or per-profile) | `mox edit <path>` (`--axis` for an overlay), add a `foo.toml.d/os=darwin.toml` overlay or a `# mox: when os=darwin` block, then `mox apply` |
| See what's managed and what changed | `mox status` (`mox diff` for the actual diff) |
| Manage a new file / a whole dir | `mox add <path>` / `mox add -r <dir>` |
| Preview before writing | `mox apply --dry-run` |
| Use a per-machine value (email, key) | a *fact* -- `mox facts`, referenced as `<machine.email>` |
| Share to another machine | `mox publish -m "..."` here, `mox update` there |
| Undo a bad apply | `mox rollback` (the newest snapshot; `mox snapshot` lists them) |
| Update mox itself | `mox upgrade` |

A step-by-step walkthrough of each task is in [docs/usage.md](docs/usage.md).

## How it works

mox composes each managed file from a **base** file in `src/` plus
**overlays** selected by *axes* -- `os`, `arch`, `profile`, `machine`, and
any fact your source compares by value. How an overlay applies depends on
the file's format:

- **Structured files** (TOML, JSON, YAML, INI, gitconfig): overlays are
  sibling files in a `<name>.d/` directory, named by the axis tuple they
  match (`config.toml.d/os=darwin.toml`). An overlay is a partial document
  that deep-merges into the base -- nested tables merge key by key, a
  scalar or array replaces -- and the most specific matching tuple wins.
- **Text and code files** (`.zshrc`, a Lua config): per-axis content is
  selected *in place* by a small comment DSL -- a `# mox: when os=darwin`
  region, an `include` / `replace from` splice from the file's `.d/`
  directory, a `for` loop over data rows. The full DSL is one page:
  [docs/dsl.md](docs/dsl.md).
- **Whole-file gating**, either kind: a leading `# mox: when <expr>`
  governs whether the file appears at all; a file with overlays and no
  base materializes only where an overlay matches.

The rest of the model, briefly:

- **Facts** -- interpolated per-machine values (`<machine.email>`), kept
  in `$XDG_CONFIG_HOME/mox/facts.toml`, never in the repo. There is no
  schema file: `mox apply` discovers the questions to ask straight from
  your sources -- every fact a gate compares by value, a capture
  interpolates, or a script consumes -- and asks each only when the
  configuration it applies to is actually reachable. `# mox: default
  <name>="<value>"` declares a fact's interview default in the source
  that owns the concern. `data/facts.toml` rows can *derive* facts (an
  env override, then candidate dirs), and `tool=<name>` / `env=<name>`
  gates probe the machine live -- no pre-registered vocabulary anywhere.
- **Secrets** -- `# mox: secret "<uri>"` or a mid-line `<secret:URI>`
  resolves at apply time from `env:`, `file://`, `op://` (1Password),
  `pass://`, or `cmd:`. Cleartext reaches the live file only, never mox
  state or the repo; an `op://`/`pass://` file is applied 0600.
- **Modes and symlinks** -- a file's target mode is its source's own
  permission bits; what git cannot carry (0600, symlink targets,
  seed-once intent) lives in `.mox/attributes.toml`, maintained by mox.
  A symlink is a source whose content is the link target, composed by
  axis like anything else.
- **Partial ownership** -- for a file a program also writes, `mox: own
  <key-path>` head directives (or `mox: disown` for the complement)
  scope mox to the declared subtrees. mox never changes a byte of the
  other side -- verified before every write, refused when it cannot be
  proven -- and an optional `mox: check` script must accept each
  candidate. Onboard with `mox add --own`; the walkthrough is in
  [docs/usage.md](docs/usage.md#a-file-a-program-also-writes).
- **Ignore rules** -- a repo-scoped `.moxignore` (gitignore syntax,
  axis-gated like any file) keeps paths out of mox entirely; `mox init`
  scaffolds one guarding common secret paths. See
  [docs/ignore.md](docs/ignore.md).
- **Setup scripts** -- `scripts/pre/` run before the write pass,
  `scripts/post/` after, every apply; gate by subdir
  (`scripts/pre/os=darwin/`) or a leading `# mox: when`, and guard
  expensive work with `mox trigger`.

## Commands

Full behavioral contracts for every command are in
[docs/commands.md](docs/commands.md).

| Command | What it does |
| --- | --- |
| `init` | Initialize a fresh repo; `--clone <url>` clones an existing one and stops for review (`--apply` to bootstrap in one step) |
| `add <path>` / `add -r <dir>` | Start managing a live file (or every file under a dir) as `src/` sources; `--own`/`--disown` key-paths onboard a partially owned file |
| `apply` | Compose and write every managed file. Never silently overwrites a hand-edited live file: leaves drift untouched and reports it, resolved with `apply --overwrite <path>` or `commit <path>` |
| `commit` | Route live-file edits back into their sources -- per hunk for text, per key for merged layers -- confirming each, and verifying that no configuration you did not choose changes |
| `diff` / `status` | Composed-vs-live diff; per-file state (`clean`, `OUTDATED`, `DRIFT`, ...) plus the live probe log. `status` exits 1 on anything actionable |
| `edit <name>` | Open the source behind a live path in `$EDITOR`; `--axis <tuple>` opens the overlay or fragment for that variant |
| `mv <old> <new>` / `remove <name>` | Rename a source (live target moves on next apply) / stop managing (source to recoverable trash; `--purge` also removes the live file) |
| `export <out>` | Bake the fully composed tree to a directory (`--as <tuple>` for another machine's view) -- the walk-away guarantee |
| `facts` | List, set, and interview for facts; `facts probe` resolves one `tool=`/`env=` query scriptably |
| `data get <name>` | Print a data source as TOML or JSON, private layer applied |
| `doctor` | Health report (untracked sources, uncarriable modes, dead gates, malformed state); `--fix` performs the safe rebuilds |
| `snapshot` / `rollback [<id>]` | List pre-overwrite snapshots; restore live files from one, newest by default |
| `update` | Fetch, rebase, and apply -- the inbound edge; refuses uncommitted changes and stops on a rebase conflict |
| `publish [-m <msg>]` | Commit the source tree and push -- the outbound edge; stages only mox's own directories |
| `path` / `git -- <args>` | Print the repo dir (`cd $(mox path)`); run git in it from anywhere |
| `secret <uri>` | Resolve a secret URI to stdout |
| `trigger ...` | Staleness primitives for setup scripts (`hash`, `seen-version`, `every`) |
| `upgrade` / `uninstall` | Self-update, `SHA256SUMS`-verified / remove machine-local state, preserving your repo and recoverable trash |

## Privacy

**Nothing about a machine leaves it.** mox records no per-machine file in the
repo. `commit` decides where an edit belongs by simulating it against the
configurations your source expresses (`os=darwin`, `profile=work`), and by
asking you. Your facts -- an email, a signing key -- are values, never
classifications: they stay in `$XDG_CONFIG_HOME/mox/facts.toml` and never enter
the repo in any form.
