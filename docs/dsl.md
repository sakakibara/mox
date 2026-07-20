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
| `for <var> in <source> [when <axis>] [where <row>] [into "<path>"]` | Repeat the body once per data row; `into` writes one file per row instead of inlining. |

## Axis expressions

Axes are machine facts: `os`, `arch`, `profile`, `machine`, and the
multi-value `tool`, `env`, `path`. An axis expression is boolean over them:

```
os=darwin
tool=fd and not env=WSL
(email and signing_key) or os=linux
```

- `name=value` - exact equality. Values are bare tokens, never quoted, so
  there is no glob or regex here.
- `name` (no `=`) - presence: true when the axis is bound to a non-empty value.
- `and`, `or`, `not`, and `( ... )` grouping. `not` may repeat.

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

### `into` -- one file per row

A top-level `for ... into "<path-template>"` is a generator: it writes one file
per row at the rendered path (relative to the source's target directory), and
the source itself is not materialized. Each row's body composes like any loop
body (nested `when`/`for` allowed), driven by the data source -- so machine-local
data in the private layer decides what a machine generates. Removing a row from
the data removes its file on the next apply (snapshot-first, recoverable).
`into` is valid only on a top-level `for`.

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

## File attributes

Bodies carry no template language, but a managed file still has a mode, and may
be a symlink or seeded once. mox has no filename prefix for any of these; the
source file keeps its native name and the attributes git cannot carry live in a
generated `.mox/attributes.toml`.

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

`.mox/attributes.toml` is generated and maintained by mox (`add`, `mv`); do not
edit it by hand.

## Concurrency and snapshots

mox serializes its own mutating runs with a single-writer lock
(`state/mox.lock`), so two `apply` / `commit` / `rollback` runs never overlap.
The lock does not cover third-party writers: an external edit made to a live
file between mox reading it and writing it in the same run is not captured in
that run's snapshot, so a later `mox rollback` restores the pre-run content, not
the intervening edit. Do not edit a managed file while mox is applying.
