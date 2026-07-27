# mox DSL reference

mox has no template language. A managed file is composed from a base file plus
overlays selected by *axes*, with a small set of directives written as comment
lines. The normative grammar is in `dsl-grammar.ebnf`; this page is the
practical one-page tour. If it grows past one page, the DSL has overreached.

A directive is a comment line whose body starts with `mox:`. The comment
marker is the file's own line-comment lead, inferred from extension, shebang,
or an apparent directive line:

```
# mox: when os=darwin        (shell, toml, gitconfig, python, ...)
-- mox: replace "work.lua"   (lua, sql)
// mox: include "extra.js"   (js, ts, c, ...)
```

## Line directives

One line, no body.

| Directive | Effect |
|---|---|
| `include "<path>" [when <axis>]` | Splice fragment `<base>.d/<path>` in place, optionally gated by an axis expression. |
| `secret "<uri>"` | Resolve a secret and emit its value. Schemes: `op://`, `pass://`, `env:`, `file://`, `cmd:` (runs the system shell -- `/bin/sh -c`, or `cmd.exe /c` on Windows -- and takes the first stdout line). |

## Region directives

A region opens with a directive line, spans the following lines, and closes at
`# mox: end`. A standalone `when` may omit `end` to gate to end of file (a
whole-file gate must be at line 1, or line 2 after a shebang). The lines
between opener and `end` are the region's literal fallback body, used when the
selecting condition is false or no fragment matches. A body is itself a
template: it may contain nested directives -- a `when` or `for` inside a `for`,
and so on -- each closed by its own `# mox: end`, matched by depth.

| Directive | Effect |
|---|---|
| `replace "<path>" when <axis>` | When the axis matches, substitute fragment `<base>.d/<path>`; else keep the body. |
| `replace from "<region>"` | Pick the best-matching fragment from an overlay region by axis; else keep the body. |
| `append "<path>" [when <axis>]` | Emit the body, then splice the fragment after it. |
| `prepend "<path>" [when <axis>]` | Splice the fragment first, then emit the body. |
| `remove when <axis>` | Drop the body when the axis matches; else keep it. |
| `from "<region>"` | Like `replace from`, with no literal-body condition of its own. |
| `when <axis>` | Emit the body only when the axis matches. |
| `for <var> in <source> [when <axis>] [where <row>] [into "<path>"]` | Repeat the body once per data row; `into` makes the file a generator (see Generator directives). |

## Axis expressions

Axes are machine facts: `os`, `arch`, `profile`, `machine`, `hostname`, and
the multi-value `tool`, `env`, `path`. `machine` is the first label of the
hostname (e.g. `Foo` out of `Foo.attlocal.net`), stable across networks;
`hostname` is the full name, for the rarer case that wants it. An axis
expression is boolean over them:

```
os=darwin
tool=fd and not env=WSL
(email and signing_key) or os=linux
```

- `name=value` - exact equality. A value is a bare token (ASCII letters,
  digits, `_`, `+`, `-`, `.`) or a quoted string; either way it is an exact
  token, so there is no glob or regex here. Quoting is the escape hatch for
  a value outside the bare-token set, e.g. a non-ASCII fact value
  (`profile="日本語"`).
- `name` (no `=`) - presence: true when the axis is bound to a non-empty value.
- `and`, `or`, `not`, and `( ... )` grouping. `not` may repeat.

`tool=<name>` resolves against `$PATH`, then this machine's detected tool-home
bin directories when present (`<brew_prefix>/bin`, `<cargo_home>/bin`,
`<gopath>/bin`, `<pnpm_home>`), then any directory a setup script named via
`$MOX_PATH` (see Scripts, below) -- in that order, so a `$PATH` hit always
wins. `<machine.tool_path.NAME>` interpolation resolves through the same
search space.

## Loops

`for <var> in <source>` iterates a TOML array. `<source>` is either a bare name
(the per-file data file `<base>.d/<name>`), a quoted repo-relative path
(`"data/abbreviations.toml"`, which the private layer shadows), or -- inside
another loop -- an enclosing row's list field (`for url in id.match_urls`). The
array is the file's stem (`abbreviations`). Each body line is a template
expanded per row. An optional `where <row>` predicate filters rows:

```
# mox: for entry in abbreviations.toml where entry.shells has "fish"
#   abbr <entry.key>="<entry.expansion>"
# mox: end
```

A loop body is a template, so it may nest a `when` or another `for`.
`<var.field>` captures resolve against the innermost enclosing loop that names
`<var>`, then against `machine`/`env`/`data`. A `when` inside a loop tests the
row (row predicates below), and a bare name or `name=value` still tests a
machine axis -- so `when os=macos and id.signing_key` mixes both.

Row predicates (`<row>`, used by `where` and an in-loop `when`):

- `<var>.field` - field is present and non-empty.
- `<var>.field = "x"` / `<var>.field has "x"` - equality / membership.
- `axis = <var>.field` - the field's value, checked as an axis binding.
- a bare `axis` or `axis=value` - a machine-axis test.
- `and`, `or`, `not`, `( ... )`. An unknown loop variable is an error.

### Body lines and the comment marker

Each body line may be written commented, in the file's own marker: compose
strips leading whitespace, then ONE marker, then one space or tab, and an
uncommented line passes through unchanged. A body line that must EMIT a
leading marker doubles it: `##compdef x` emits `#compdef x`. Both rules are
locked by tests.

## Generator directives

A generator directive makes its source file a GENERATOR: the file emits one
live file per data row into its own target directory and never materializes
at its own path. A generator source holds exactly its directive and nothing
else; stray top-level content is rejected. Its produced set is manifest-
tracked: removing a row removes that row's file on the next apply, a false
gate empties (and so prunes) the whole set, and a generator whose source
leaves the tree has its set swept -- all snapshot-first, recoverable.

### `for ... into` -- one file per row

A top-level `for ... into "<path-template>"` writes one file per row at the
rendered path. Each row's body composes like any loop body (nested
`when`/`for` allowed), driven by the data source -- so machine-local data in
the private layer decides what a machine generates. `into` is valid only on
a top-level `for`.

### `completions` -- lazy shell-completion stubs

```
# mox: completions fish "data/completions.toml"
# mox: completions zsh "data/completions.toml" when not profile=minimal
```

One generator source per shell's completion directory: fish's
`.config/fish/completions/`, a zsh fpath directory, bash-completion's lazy
dir (`.local/share/bash-completion/completions/`), or a directory the
PowerShell profile dot-sources. The shell is a positional typed token
validated against the supported set (`fish`, `zsh`, `bash`, `powershell`)
-- never a `key=value` argument, which would be surface-identical to an
axis atom. Each applicable registry row emits one stub (`<name>.fish`,
`_<name>`, bare `<name>`, `<name>.ps1`) that asks the INSTALLED tool for
its completion script on the first completion request of a session: no
shell-startup work beyond PowerShell's one tiny registration, and
completions that always match the installed version. fish, zsh, and bash
ride their shells' own per-command lazy loading; the PowerShell stub is a
self-replacing `Register-ArgumentCompleter` that loads the generated
script on first request and answers it by re-entering `TabExpansion2`.
The registry is a TOML array of `[[completions]]` rows (the array key
is the registry filename stem, so `data/completions.toml` holds
`[[completions]]`):

- `name` (required): the completed command; first char `[A-Za-z0-9_]`,
  then `[A-Za-z0-9_.-]`.
- `command`: completion-emitting command prefix; the shell name is
  appended (`herdr completion` -> `herdr completion fish`).
- `fish` / `zsh` / `bash` / `powershell`: full per-shell override for
  irregular CLIs (`pip completion --zsh`); wins over `command`.
- `shells`: allow-list of shells the row covers; the only way a requested
  shell is skipped. A covered shell without a resolved command is an
  error, so a forgotten shell can never be silent.
- `zsh_dispatch`: completion function the zsh stub dispatches when the
  generated script defines something other than `_<name>`.

The zsh stub always ends `compdef <dispatch> <name>` then `<dispatch> "$@"`:
inside `eval`, `funcstack[1]` is `(eval)`, so a generated script's trailing
self-dispatch guard never fires, and a script that does not rebind the
service would re-run the generator command on every request instead of once
per session. The stubs' presence guards see PATH executables only (a tool
provided purely as a function or alias never triggers its stub), and a stub
serves exactly its declared `name` (variant names like `pip3.11` need their
own rows). An unknown shell token is rejected with a diagnostic naming the
accepted set.

## Captures

A capture `<...>` substitutes one value inside a region body or loop template.
It is a plain lookup - no arithmetic, no transforms, no regex:

- `<entry.field>` - a loop row field.
- `<machine.field>` - a machine fact (`os`, `arch`, `home`, `brew_prefix`,
  `xdg_config_home`, `tool_path.<name>`, custom facts, ...).
- `<env.NAME>` - a captured environment variable value.
- `<data.FILE.KEY>` - a committed shared scalar from `data/FILE.toml` (the
  private layer shadows the repo, exactly as `mox data get` resolves it).
  `KEY` is a top-level key; `<data.FILE.TABLE.KEY>` reads a scalar one table
  deep. Only these two depths exist. A string renders as its exact bytes, an
  integer/bool as its TOML literal. A missing file or key is a compose error
  unless a `default` rescues it; a non-scalar value (array/table) is always an
  error, even with a default.
- `<a | b | c>` - a chain: first non-empty member wins.
- `<a | default "x">` - literal fallback when the chain is empty.
- `<secret:URI>` - resolve a secret and splice its value mid-line. The schemes
  are those of the whole-line `secret` directive (`op://`, `pass://`, `env:`,
  `file://`, `cmd:`), resolved through the same apply-wide cache, and `cmd:`
  takes the first stdout line. The URI runs verbatim to the closing `>` (so a
  `"` is legal here, unlike in the directive). To place a literal `>` in the
  URI -- a `cmd:` shell redirect such as `2>&1` -- escape it as `\>`; `\\` is a
  literal backslash, and every other backslash stands for itself. (The
  whole-line `secret` directive has no `>` terminator and so does no such
  unescaping: a `cmd:` payload moved between the two forms must adjust its
  backslashes.) With no secrets configured it emits a `<SECRET:URI>` placeholder
  rather
  than resolving. A resolution failure is a fatal compose error that never
  echoes the value; an empty `<secret:>` is rejected up front. A resolved
  secret never reaches disk or the terminal: its value is kept out of the
  applied-content cache and snapshots, and `mox diff` redacts any hunk touching
  a secret line. (Redaction of a secret you have since removed relies on that
  file's stored provenance; a file first applied by an older mox that predates
  provenance tracking would not have it -- reapply once to record it.)
  A live file that resolves an `op://` or `pass://` secret is applied at mode
  0600 automatically (dedicated secret managers hold only secrets, so this is
  never a false positive), unless `.mox/attributes.toml` sets an explicit mode.
  The ambiguous schemes (`env:`, `file://`, `cmd:` -- the last often a non-secret
  value like a computed theme name) are left at their composed mode; mark one
  `mode = "0600"` in `.mox/attributes.toml` when it is sensitive.

Captures must not be adjacent (`<a><b>`) and a name must not repeat within one
template; both are compose-time errors. A malformed `data.` capture (`<data.x>`
or one nested deeper than a table) is rejected up front.

A resolved secret is kept out of mox's own on-disk state, but `mox export
--resolved` bakes the resolved cleartext into every file it writes -- that flat
tree is the walk-away and CI-parity output. There too an `op://`/`pass://` file
is written at 0600, and export announces on stderr each file into which it baked
such a secret, so aiming it at a committed or CI directory cannot silently ship
one unnoticed.

## Fact and data model

- **Facts** come from the machine interview (`data/facts-schema.toml`) plus
  auto-detected machine state (os, arch, tools on PATH, env vars). They drive
  axis expressions and `<machine.*>` / `<env.*>` captures.
- **Data files** are `data/*.toml` (shared, repo-relative) or `<base>.d/*.toml`
  (per-file). Their arrays feed `for` loops; their top-level scalars feed
  `<data.FILE.KEY>` captures.
- **Fragments** live under `<base>.d/`; overlay regions select the
  best-matching one by axis tuple.

## Scripts

Setup scripts under `scripts/pre/` and `scripts/post/` are gated the same way
managed files are. A script inside a single-tuple subdir (`scripts/pre/os=darwin/`)
runs only on a matching machine, and a script may add its own axis-expression
gate as a `# mox: when <expr>` comment among its leading lines:

```
#!/bin/sh
# mox: when os=darwin or os=linux
```

The expression is the axis language above. The header is found by scanning to
the first content line (at most 16 lines in); `#` is the comment marker for both
shell and `.ps1`. When a script sits in a gated subdir and also carries a header,
both must hold for it to run. A header that fails to parse is a hard error for
that script, not a silent skip.

Every script (both stages) and check hook also gets `MOX_PATH`, naming a
writable file private to this run (deleted when the run ends). A script that
installs a tool somewhere `tool=` would not otherwise see -- neither `$PATH`
nor a detected tool home -- appends that directory there, one absolute path
per line (modeled on GitHub Actions' `GITHUB_PATH`). After each stage, mox
reads back whatever is new: it joins the `tool=` search space for the rest of
the run and is prepended to `PATH` for every later script and check hook. A
relative or otherwise malformed line is a stderr warning naming the file and
line, never a silent skip.

## File attributes and head directives

Bodies carry no template language, but a managed file still has a mode, may be
a symlink or seeded once, and may be owned only in part. mox has no filename
prefix for any of these. Filesystem metadata git cannot carry lives in
`.mox/attributes.toml`; the ownership contract is content semantics and lives
in the source file itself, as head directives.

### Attributes (`.mox/attributes.toml`)

- **Mode.** The target's mode is the source file's own permission bits: `chmod
  +x` the source and git carries the exec bit (git round-trips 0644 and 0755
  across a clone). A mode git cannot carry -- anything other than 0644 or 0755,
  such as 0600 or 0444 -- is recorded in `.mox/attributes.toml`, since git
  collapses it to 0644 on clone.
- **Symlink.** `mox add` of a live symlink stores the link target as the source
  content and flags `symlink = true`. Apply plants a symlink at the live path.
  The target is ordinary composed content, so it can vary by axis or interpolate
  captures.
- **Seed-once.** `mox add --seed-once` records `seed_once = true`. Apply writes
  the target only when it is absent and never overwrites, drift-checks, or
  commits an existing one -- for a machine-local skeleton the user then edits.

`.mox/attributes.toml` is maintained by mox (`add`, `mv`, `remove`); commands
that re-key or drop entries rewrite it deterministically.

### Head directives (partial ownership)

A structured source file declares its ownership contract in its LEADING
comment block -- recognized after an optional shebang and before the first
content line, one directive per line, in the file's comment marker (`#`
everywhere, `//` for JSONC):

```toml
# mox: own tui.keymap.global
# mox: own tui.keymap.composer
# mox: check "scripts/check/codex-config"
[tui.keymap.global]
...
```

```jsonc
// mox: disown model
{ ... }
```

- **`own <path>`** (repeatable; the rest of the line is ONE key-path)
  declares the key subtrees mox manages inside the target; every byte outside
  them stays the program's.
- **`disown <path>`** (repeatable) is the complement: mox manages the whole
  file EXCEPT the declared subtrees -- for a file where the program's region
  is the sparse one. The composed source may define nothing under a disowned
  path, and a disowned path's live content is always preserved byte-for-byte,
  present or not. `own` and `disown` are mutually exclusive per file.
- **`check "<repo-relative exe>" ["arg" ...]`** (quoted argv items, once)
  names a validation hook; see below.

The directives never reach composed output: compose strips exactly the
recognized lines from the base text, so the live file a program reads contains
no mox syntax. Overlays cannot declare ownership; the contract is the file's,
machine-independent, stated once at its head. A whole-file gate shares the
same leading block, before or after the ownership lines -- the whole block is
read in one pass, and the gate holds as long as only consumed directive lines
precede it.

The base may consist of nothing BUT its leading block: ownership directives,
an optional `check`, an optional whole-file gate, zero content. Overlays in
`<name>.d/` then supply all owned content, per machine. (This is general
structured-merge behavior: a blank base -- or blank first layer -- of a
multi-layer structured file composes from the remaining layers.) This is the way to
declare ownership for a machine-gated file: the contract and the gate live in
the base, the per-machine content in overlays, and a machine where the gate
fails leaves the live file (and mox's records) completely untouched.

A key-path is TOML dotted-key syntax, verbatim: bare segments
(`A-Za-z0-9_-`), `"..."`/`'...'`-quoted segments, whitespace allowed around
the dots (`projects."/tmp/example"`, `remote."my origin".url`). Segments
match on decoded key content, per the format's dialect: ini and gitconfig
sections and keys match case-insensitively, a gitconfig quoted subsection is
matched verbatim (case-sensitive), and a YAML declared segment is a string
key -- a non-string key may sit inside an owned subtree, never on the
declared path itself. An owned YAML scalar that does not render on one
line (a multiline string value) refuses the file rather than reflowing
it. Reasserted owned content renders with LF line endings even in a CRLF
live file; every remainder byte, CRLF included, is preserved untouched.
Ownership requires a structured target (TOML, JSON, YAML, INI,
gitconfig) and cannot combine with `symlink`, `seed_once`, or a generator
source. Under `own`, the composed source must lie entirely within the
declaration -- a composed leaf outside every declared path is a per-file
error -- and a declared path the source does not populate is enforced as
absent from the live file. Under `disown`, enforced absence does not exist;
the inverted check refuses a composed source that defines content under a
disowned path.

A change to the declared list is first contact for the affected content: an
`own` path you add (or a `disown` path you remove) has its live content
adopted when it already matches the source, and reported as drift otherwise;
a `disown` path you add simply stops being compared.

### Check hook

`check "<repo-relative executable>" ["arg" ...]`
validates every candidate partial write before it lands (apply and rollback
both run it). The executable is spawned directly with the argv given -- no
shell -- with cwd at the repo root; a `.ps1` checker runs under PowerShell
with the same dispatch as setup scripts. The candidate is materialized in a
private temp dir under the live file's basename, and the child gets
`MOX_CHECK_FILE` (the candidate's path) and `MOX_CHECK_DIR`. Exit 0 accepts;
any other exit, or a timeout, refuses the file and reports the hook's
output. The timeout defaults to 30s, overridden per run with
`MOX_CHECK_TIMEOUT_MS` (a value <= 0 disables it); on POSIX the hook leads
its own process group and the whole group is killed on timeout, on Windows
the hook process is terminated. The temp dir holds only the candidate: a
tool that resolves sibling files must be wrapped by the checker script.
`check` executes repo-authored code at apply time -- the same authority as
`scripts/`, with the same opt-out: under `--skip-scripts` the hook does not
run and the check-bearing file is not written.

## Concurrency and snapshots

mox serializes its own mutating runs with a single-writer lock
(`state/mox.lock`), so two `apply` / `commit` / `rollback` runs never overlap.
The lock does not cover third-party writers: an external edit made to a live
file between mox reading it and writing it in the same run is not captured in
that run's snapshot, so a later `mox rollback` restores the pre-run content, not
the intervening edit. Do not edit a managed file while mox is applying.
