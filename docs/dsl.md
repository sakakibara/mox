# mox DSL reference

mox has no template language. A managed file is composed from a base file plus
overlays selected by *axes*, with a small set of directives written as comment
lines. The normative grammar is in `dsl-grammar.ebnf`; this page is the
practical tour: every directive, with the rules that govern it.

A directive is a comment line whose body starts with `mox:`. The comment
marker is the file's own line-comment lead: a structured format's own (`#` for
TOML, YAML, INI and gitconfig, `//` for JSONC), and for any other file the one
inferred from extension, shebang, or an apparent directive line:

```
# mox: when os=darwin        (shell, toml, gitconfig, python, ...)
-- mox: replace "work.lua"   (lua, sql)
// mox: include "extra.js"   (js, ts, jsonc, c, ...)
```

Strict JSON has no comments, so a `.json` source carries no directive at
all: its ownership, gate and interview defaults live in
`.mox/attributes.toml` (see File attributes and head directives), and its
captures inside string values (see Captures in JSON).

## Line directives

One line, no body.

| Directive | Effect |
|---|---|
| `include "<path>" [when <axis>]` | Splice fragment `<name>.d/<path>` in place, optionally gated by an axis expression. |
| `secret "<uri>"` | Resolve a secret and emit its value. Schemes: `op://`, `pass://`, `env:`, `file://`, `cmd:` (runs the system shell -- `/bin/sh -c`, or `cmd.exe /c` on Windows -- and takes the first stdout line). |
| `default <name>="<value>"` | Declare the interview default for fact `<name>`; stripped from output, never gates or emits anything. `<name>` is `[a-z][a-z0-9_]*`. |
| `keep-empty` | Materialize the file even when it composes to nothing, instead of omitting it (see Empty output). No arguments; stripped from output. |

None of these is written in strict JSON: a secret there is a `<secret:URI>`
capture inside a string, an interview default the `defaults` attribute, a
fragment an overlay, and `keep-empty` is never needed.

## Empty output

A file that composes to nothing is not written: an empty render means "no
file", not "a 0-byte file". This applies to any source carrying a directive
whose output ends up empty -- a `for` over an empty data set, a `when`/region
that gated everything away -- and matches the generator rule, where zero rows
already produce zero files.

Three kinds of file are exempt. A file mox infers **no comment marker** for,
so it could not carry a directive in the first place: a genuinely empty
`.hushlogin` or `.keep` is written verbatim as an empty file. A structured
file (`.toml`, `.json`, `.jsonc`, `.yaml`, `.yml`, `.ini`, gitconfig) that
composes through the structural path rather than the region one -- strict
JSON always does, and an empty JSON document is no document, so an empty
`.json` base is refused instead (write `{}`). And a partially owned file
(`own`/`disown`): mox patches only its declared keys into a file a program
also writes, so an empty render there means "mox owns nothing here", not "no
file", and is exempt from format validation too.

Note what the first exemption is NOT: it is the absence of an inferred comment
marker, not the absence of directives. An empty `.sh`, `.zsh`, `.conf`, `.lua`
or `.py` composes through the region path whether or not it holds a directive,
so it renders empty and is not written. To keep such a file present -- a
conditionally-present but empty file, or an empty placeholder with an
extension -- add the `keep-empty` directive in the file's own comment marker
(`# mox: keep-empty` in a `.sh`, `-- mox: keep-empty` in a `.lua`).

When a file that mox previously wrote starts composing to nothing, `mox apply`
removes the stale live copy (snapshot-first, so `mox rollback` recovers it). A
live copy edited since mox wrote it is not deleted silently: it is reported as
drift and kept until `mox apply --overwrite <path>`.

## Region directives

A region opens with a directive line, spans the following lines, and closes at
`# mox: end`. A standalone `when` may omit `end` to gate to end of file (a
whole-file gate must be the first line that is neither a shebang nor another
consumed head directive; see File attributes and head directives). The lines
between opener and `end` are the region's literal fallback body, used when the
selecting condition is false or no fragment matches. A body is itself a
template: it may contain nested directives -- a `when` or `for` inside a `for`,
and so on -- each closed by its own `# mox: end`, matched by depth. A
directive line counts as an opener or a closer by its first word as the
parser reads it, so `when(os=darwin)` nests like `when os=darwin`, and an
`end` followed by anything else is refused on the line it stands on.

| Directive | Effect |
|---|---|
| `replace "<path>" [when <axis>]` | When the axis matches, substitute fragment `<name>.d/<path>`; else keep the body. With no `when` the body is always kept and the fragment never read. |
| `replace from "<region>"` | Pick the best-matching fragment from an overlay region by axis; else keep the body. Takes no `when`: the fragment filenames carry the axes, so a gate is refused (`WhenOnReplaceFrom`) rather than accepted and ignored. |
| `append "<path>" [when <axis>]` | Emit the body, then splice the fragment after it. |
| `prepend "<path>" [when <axis>]` | Splice the fragment first, then emit the body. |
| `remove when <axis>` | Drop the body when the axis matches; else keep it. |
| `from "<region>"` | Like `replace from`, with no literal-body condition of its own. |
| `when <axis>` | Emit the body only when the axis matches. |
| `for <var> in <source> [when <axis>] [where <row>] [into "<path>"]` | Repeat the body once per data row; `into` makes the file a generator (see Generator directives). |

A structurally merged source (a `.toml`, `.jsonc`, `.yaml`, `.yml`, `.ini` or
gitconfig file with `.d/` overlays) cannot carry a region directive in any of
its layers, base or overlay, whether or not the layer matches the machine
composing: in a merge a directive line is only a comment, so the region's
body would land unconditionally. The same goes for a line directive
(`secret`, `default`, `include`), which the merge would drop. The compose
refuses with `InlineDirectiveWithOverlay`, naming the layer and line. A
whole-file gate that excludes the composing machine does not exempt the file
either, nor does a base-less source none of whose overlays match here: the
scan runs before either decides the file is absent. A line
that reads as a directive is one wherever it sits, a string value included:
the DSL reads comment lines, not the format. Gate such content with an
overlay instead, or keep the file single-layer.

Strict JSON reads its layers as JSON instead: any comment in a `.json` layer
is refused, a `mox:` one naming where its directive lives (the attributes key
for `own`, `disown`, `check`, a leading `when` and `default`; an overlay
`<file>.d/<axis>.json` for a region or `include`; a `<secret:URI>` capture
for `secret`), and a string that merely spells `// mox:` is content.

The rule reads the same way from the other side. An axis-named `.d/` file is
an overlay only where a category has layers to fold or to pick from: a
structural merge, or a binary file's single winning layer. A text source has
neither -- it composes from its base and the directives written in it -- so
a `.d/` file named for an axis tuple beside one could only ever be dropped,
and the compose refuses it with `OverlayOnTextFile`, naming it. Vary text per
machine with a region directive and its `<name>.d/<region>/` fragments, or a
`when` gate. A generator source (`for ... into`) refuses one too, in every
category, with `OverlayOnGenerator`: the generator's own path never
materializes, so no layer beside it has anything to compose into. Neither
refusal depends on the overlay matching the machine composing.

## Axis expressions

Axes are machine facts: the built-ins `os`, `arch`, `machine` and `hostname`,
any custom or `data/facts.toml`-derived fact (below) -- one you name yourself,
such as `profile`, is an axis the moment a source compares it -- and the open
`tool`, `env` (any name is a live query, below). `path` is a reserved name
that binds nothing, so a `path=` comparison errors loudly instead of silently
never matching. `machine` is the first label of the hostname (e.g. `Foo` out
of `Foo.attlocal.net`), stable across networks; `hostname` is the
full name, for the rarer case that wants it. An axis expression is boolean
over them:

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

`tool=<name>` and `env=<name>` are open axes: neither has a fixed
vocabulary, so any name is a live query rather than a lookup against a
pre-enumerated fact set. `tool=<name>` resolves against `$PATH`, then this
repo's own `data/paths.toml` PATH registry resolved against this machine
(captures expanded, nonexistent directories skipped, `shells`/`prepend`
irrelevant to an existence check) -- the same directories the shells
themselves put on `$PATH`, so "gate says installed" and "shell can run it"
never diverge -- then any directory a setup script named via `$MOX_PATH`
(see Scripts, below): in that order, so a `$PATH` hit always wins. A
`data/paths.toml` row's own `when` field gates whether that row
contributes on EITHER a tool name (checked against `$PATH`+`$MOX_PATH`
only, never against another row's directory -- one pass, no fixpoint) OR
a bound single-value fact name -- either presence enables the row.
`<machine.tool_path.NAME>` interpolation resolves through the same search
space. `env=<name>` resolves directly against this machine's captured
environ, same as `<env.NAME>` interpolation; a set-but-empty variable reads
as unset, matching every other axis's presence test. Both are probed once
per name per run and memoized; `mox status` and `mox facts probe` surface
what was actually asked and its outcome.

## Loops

`for <var> in <source>` iterates a TOML array. `<source>` is either a bare name
(the per-file data file `<name>.d/<source>`), a quoted repo-relative path
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
machine axis -- so `when os=darwin and id.signing_key` mixes both.

Row predicates (`<row>`, used by `where` and an in-loop `when`):

- `<var>.field` - field is present and non-empty.
- `<var>.field = "x"` / `<var>.field has "x"` - equality / membership.
- `axis = <var>.field` - the field's value, checked as an axis binding.
- `bound <var>.field` - the field's value, checked for PRESENCE as a
  single-value machine fact -- the twin of `axis = <var>.field` above,
  which checks by equality instead. A field value naming a multi-value
  axis (`tool`, `env`) always reads false: presence never resolves via
  a multi-value key, so `bound` is for single-value facts only.
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
  appended (`kubectl completion` -> `kubectl completion fish`).
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

- `<entry.field>` - a loop row field. When the field's string itself carries
  captures (a `data/paths.toml` row authored as `dir = "<machine.brew_prefix>/bin"`,
  where `brew_prefix` is a `data/facts.toml`-derived fact), they expand
  through this same mechanism -- but only one level deep: the result of that
  nested expansion is spliced verbatim and never scanned again, so a row
  value cannot chain into a second round of expansion. An unknown capture
  inside a row value is a compose error with the same diagnostics as an
  inline one; `| default` chains inside a row value resolve the same way too.
- `<machine.field>` - a machine fact: `os`, `arch`, `home`, `xdg_config_home`,
  `tool_path.<name>`, a custom fact, or a `data/facts.toml`-derived one.
- `<env.NAME>` - a captured environment variable value.
- `<data.FILE.KEY>` - a committed shared scalar from `data/FILE.toml` (the
  private layer shadows the repo, exactly as `mox data` resolves it).
  `KEY` is a top-level key; `<data.FILE.TABLE.KEY>` reads a scalar one table
  deep. Only these two depths exist. A string renders as its exact bytes, an
  integer/bool as its TOML literal, a float in decimal notation with a
  fractional part (`1.5`, `3.0`, `0.0001`); a JSON string that is the
  capture alone emits the value in its own JSON type (see Captures in JSON).
  A missing file or key is a compose error unless a `default` rescues it; a
  non-scalar value (array/table) is always an error, even with a default.
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
  backslashes.) Off the resolving path -- the parse-only compose, never a
  run that writes or compares content -- it emits a `<SECRET:URI>`
  placeholder instead of resolving. A resolution failure is a fatal compose
  error that never
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

### Captures in JSON

In a JSON or JSONC source a capture lives inside a string token, and expands
per token: the string is decoded (so `"<a | default \"x\">"` is the capture
`<a | default "x">`), expanded, and written back as a JSON string, with every
`"`, `\` and control byte in the resolved value escaped. A Windows path, a
quote in a secret, or a newline in a fact value cannot break the document,
and the expansion never adds a line. A string with no capture, and every byte
outside a capture-bearing string -- structure, whitespace, a JSONC comment --
is left exactly as written, so a capture-free file composes byte for byte;
a capture inside a comment is not expanded.

A string value (not a key) that is exactly one `<data.FILE.KEY>` capture,
with no chain and no default, emits the scalar in its own JSON type:

```json
{ "port": "<data.server.port>", "debug": "<data.server.debug>" }
```

composes to `{ "port": 8080, "debug": false }` when `data/server.toml` holds
`port = 8080` and `debug = false`. A TOML integer or float becomes a number, a
bool a bool, a string a string, and a date-time stays a string. A number is
written as JavaScript writes it: the shortest digits that read back as the
same value, in decimal notation for 1e-7 <= |x| < 1e21 (`100000`, `0.0001`,
`3`) and in exponent notation otherwise (`1e+300`, `1e-7`). A TOML `inf`
or `nan`, which JSON cannot hold, is a compose error naming the capture. The
type is the value's as resolved, so a private `data/` file that shadows it
with another TOML type changes the emitted type too; store a TOML string to
keep a string. Anything else -- a chain, a default, text around the capture, a key
-- is a string. A key capture that expands to a key its object already holds
is refused (see Validation). A capture written outside a string
(`"port": <data.server.port>`) is not JSON and is refused, with the hint to
quote it.

A resolved secret is kept out of mox's own on-disk state, but `mox export`
bakes the resolved cleartext into every file it writes -- that flat tree is the
walk-away and CI-parity output. So an export that would bake one names those
files and refuses until `--cleartext-secrets` is passed, decided before any
content reaches disk; with the flag, a file carrying a secret-manager value
(`op://`, `pass://`) is written at 0600 unless `.mox/attributes.toml` sets an
explicit mode, and the count is reported with the modes used. The consent
gate covers every scheme; the 0600 mode is reserved for the unambiguous ones,
since `env:`/`file://`/`cmd:` are often not secrets at all. Aiming export at a
committed or CI directory cannot ship a secret unnoticed.

## Fact and data model

- **Facts** are per-machine values kept in `$XDG_CONFIG_HOME/mox/facts.toml`,
  plus auto-detected machine state (os, arch, tools on PATH, env vars) and
  `data/facts.toml`-derived facts (below). They drive axis expressions and
  `<machine.*>` / `<env.*>` captures. There is no schema file: `mox apply`
  (and `mox facts`) discover which facts to ask about directly from the
  repo's own sources -- every fact a gate compares by value, a capture
  interpolates, a bare presence test names, or a script consumes (see
  Scripts, below), and every fact a `data/packages/` row's `when` names
  -- and ask each only when the configuration it gates is
  reachable given the answers bound so far in the same run, so a personal
  machine is never asked a work-only or backend-only question. A
  `# mox: default <name>="<value>"` line (above) declares a fact's interview
  default in the source that owns the concern; it is an interview default
  only -- an unbound fact never silently reads as it. A prompt lists the
  values the repo compares in parentheses and a default in brackets:
  `holt_backend (gdrive, icloud) [icloud]: `. With no default it ends
  `; Enter skips` instead -- `profile (personal, work; Enter skips): ` --
  and Enter there binds the empty string: a persisted decline, the same
  state as legitimately empty, never re-asked by the interview. The skip
  is announced with the command that answers it later,
  `mox facts ask <name>`. The full surface -- `mox facts`,
  `facts ask`, `facts --report`, `status`'s `unbound facts:` section,
  `doctor`'s stale-fact advisory, `apply --defaults` -- is in
  [commands.md](commands.md).
- **Data files** are `data/*.toml` (shared, repo-relative) or `<name>.d/*.toml`
  (per-file). Their arrays feed `for` loops; their top-level scalars feed
  `<data.FILE.KEY>` captures.
- **Fragments** live under `<name>.d/`; overlay regions select the
  best-matching one by axis tuple.

### Derived facts (`data/facts.toml`)

Repo-provided, private-shadowed, `[[facts]]` rows deriving a single-value
fact mox has no built-in knowledge of (a package manager's home directory,
say). Each row:

- `name` (required, the same charset as an axis name).
- `env` (optional): an override variable consulted first. Set-but-empty
  counts as unset; a set value must itself name an existing directory to
  win, or resolution falls through to `candidates`.
- `candidates` (optional): paths tried in order; `~` expands to home. The
  first that exists on disk binds the fact. A Windows path's backslashes
  need TOML's `'single-quoted'` literal string (or plain `/` forward
  slashes) -- a `"double-quoted"` string treats `\` as an escape.

Nothing existing (env unset/rejected and no candidate exists) leaves the row
unbound -- no fact, no error. A bound row behaves exactly like any other
fact: `<machine.NAME>` captures it, `when NAME` tests its presence,
`when NAME="..."` compares its value. A row's `name` colliding with a
built-in field or a reserved axis name (`tool`, `env`, `path`) is a capture
error naming the conflict; a malformed row (bad name charset, wrong field
type) is a capture error naming the row. A missing `data/facts.toml`
derives nothing and is not an error. Re-derived on the post-pre-script
re-capture, so a bootstrap script that installs the thing a row detects is
seen by the very same apply.

## Scripts

Every regular file in a stage is spawned (OS noise such as `.DS_Store` and
`._*` aside), so a stage holds executables only: a file without the
executable bit fails the run and is named, whether its gate is open or
closed, so a stray file fails the run on every machine, not only the one
whose gate it opens. On Windows, which has no such bit, a `.ps1` runs under
PowerShell and any other file must be a program; one that cannot be spawned
fails the run and is named, and a closed gate is only skipped there. Setup
scripts under `scripts/pre/` and
`scripts/post/` are gated the same way managed files are. A script inside a
single-tuple subdir (`scripts/pre/os=darwin/`) runs only on a matching
machine; a subdirectory whose name carries an `=` but is not a tuple fails
the run and is named, so a mistyped gate is never taken for one that closed.
A script may add its own axis-expression gate as a `# mox: when <expr>`
comment among its leading lines:

```
#!/bin/sh
# mox: when os=darwin or os=linux
```

The expression is the axis language above. The header is found by scanning to
the first content line (at most 16 lines in); `#` is the comment marker for
both shell and `.ps1`. When a script sits in a gated subdir and also carries a
header, both must hold for it to run. A header that fails to parse is a hard
error for that script, not a silent skip.

Every setup script (both stages) runs with mox's own environment plus
`MOX_REPO` (the dotfiles repo root), `MOX_STATE_DIR`, `MOX_HOME` (the live
root), `MOX_TRIGGER_PENDING` (where the script's `mox trigger` records wait
until it exits 0, so a script that fails is run again by the next apply),
a `PATH` led by `<state dir>/bin`, a directory holding only the mox
that is running the script (so `mox` resolves to it even from a bootstrap that
ran mox by absolute path), and every fact as `MOX_FACT_<UPPERCASE_NAME>` (a
character outside `[A-Z0-9_]` in the fact name becomes `_`; a name that cannot
be encoded distinctly -- non-ASCII, or a collision with another fact's
sanitized form -- is left out and warned about instead of silently colliding).

### Fact contracts

A script's consumption of `MOX_FACT_*` is a checkable contract, not just an
environment variable it happens to read. mox resolves it one of two ways:

- **Scanned**, by default: every literal `MOX_FACT_[A-Z0-9_]+` token found
  anywhere in the script's text (CRLF-tolerant, same pattern for bash and
  PowerShell -- `$MOX_FACT_X`, `${MOX_FACT_X}`, `%MOX_FACT_X%` all match). A
  token naming a fact the repo already consumes elsewhere is one more
  occurrence of it, whose own condition the fact is asked under, exactly as a
  declared name is. A token naming no such fact registers nothing: it is
  matched text rather than a stated contract, and the projection is one-way
  (`MOX_FACT_A_B` names `a.b`, `a_b` and `A-B` alike), so it stays fail-closed
  and blocks the script instead.
- **Declared**, with a `# mox: needs <name>...` head line (scanned the same
  window as `# mox: when`, above -- both may appear, in either order). When
  present it REPLACES the token scan entirely: an empty `# mox: needs` line
  declares "needs nothing" and always runs, regardless of what tokens the
  script's text contains. Each name the line lists is a use of that fact like
  any other: it registers a new, free-form interview question when nothing
  else in the repo consumes the name, and either way it is one more
  occurrence whose own condition the fact is asked under.
  A `# mox: needs` line that fails to parse (a name outside the fact-name
  charset) blocks the script outright -- its contract is unknowable, and the
  token scan is not consulted as a fallback.

A gate directory's tuple is an axis comparison in its own right, so the fact
that opens it is one the interview asks about; and a fact a script inside it
declares with `# mox: needs`, scans a token for, or names in a `# mox: when`
head of its own, is
asked about where that tuple holds -- the same condition the runner requires
before running the script at all. Conditions across uses OR together, here as
everywhere: a fact `src/` uses only behind `when profile=work` and an ungated
script needs is asked on every machine, because that script runs on every
machine -- whether the script declares the need or the scan reads it from a
token, since the runner blocks the run on either.

Each needed fact (declared or scanned) is checked against THIS stage's
actual projected environment, not an abstract name set -- so a projection
collision (two names sanitizing to the same `MOX_FACT_*`, both dropped) or a
name that maps to no fact at all is caught here, not assumed away. The
script then lands under one of five labels -- the ones the closing summary
counts -- each printed as shown below; `failed` has several forms:

| Outcome | Printed | When |
| --- | --- | --- |
| ran | `  ran <path>` (stdout) | exit 0; every needed fact bound non-empty |
| skipped | `  skipped <path>` (stdout) | the directory tuple or `# mox: when` gate did not match |
| declined | `  skipped (declined) <path>: <name>[, <name>...]` (stdout) | every needed fact is bound but empty -- green, does not fail the run |
| blocked | `mox apply: <path>: blocked: <reason>` (stderr, one line per unresolved fact) | a needed fact could not be resolved -- fails the run under its own summary count, distinct from `failed` |
| failed | `mox apply: <path>: exit <code>` (stderr) | nonzero exit |
| failed | `mox apply: <path>: timed out after <ms>ms, killed` / `... terminated abnormally` (stderr) | killed after `MOX_SCRIPT_TIMEOUT_MS` (default 600000ms, `<= 0` disables), or exited abnormally |
| failed | `mox apply: <path>: stopped, and this run has no terminal that could resume it; killed` (stderr) | the script asked the terminal something a run with none (`mox apply &`, a CI job) cannot answer |

A stage file that cannot be spawned, a gate directory that cannot be read, a
file that is not executable, and a subdirectory named like a tuple that is
not one print their own `mox apply: <path>: ...` lines and count under
`failed` too, though none of them is a script.

A script leads its own process group, so the bound reaches what it started
and not the script alone: an orphan holding mox's stdout would keep a
`mox apply | ...` pipeline open long after the run. It is handed the
terminal for its run, the way a shell hands it to a foreground job, so a
`sudo` in a pre-script can prompt and Ctrl-C goes to the script rather than
orphaning it; Ctrl-Z suspends it and hands the terminal back. Windows has
neither process groups nor job control, so there the bound reaches the
direct process alone.

`<reason>` in the `blocked` line names the fact and the remediation: never
bound but interviewable (`mox facts set <name> <value>`, or answer the
interview); an unresolved derived fact (its `data/facts.toml` env override
or candidate dirs); a built-in, which is never projected as `MOX_FACT_*`
(gate the script instead); a name mox cannot bind or derive at all; a
projection collision (names both colliding facts); or a scanned token
matching no known fact (bind it, or declare the script's real contract with
`# mox: needs`, which also silences a false-positive match inside comment
text).

`script_env` (and the contract it is checked against) is rebuilt after every
re-capture -- including the one a pre-stage script triggers by persisting a
fact -- so a post-stage script sees and is judged against exactly the
fresh, current env, never the pre-stage's stale projection.

Setup scripts and check hooks find the running mox first on their `PATH`,
through `<state dir>/bin`, a directory mox owns: it holds the running mox
and nothing else, and anything else placed there is removed on every apply
that is not a dry run (a dry run spawns nothing and leaves it alone).
Every setup script (both stages) also gets `MOX_PATH`, naming a writable file
private to this run (deleted when the run ends). A script that installs a tool
somewhere `tool=` would not otherwise see -- neither `$PATH` nor this repo's
`data/paths.toml` registry -- appends that directory there, one absolute path
per line (modeled on GitHub Actions' `GITHUB_PATH`). After each stage, mox
reads back whatever is new: it joins the `tool=` search space for the rest of
the run and is prepended to `PATH` for every later script and check hook,
behind the running mox's own directory, which stays first; a directory
already on `PATH` moves to the front rather than appearing twice. A relative
or otherwise malformed line is a stderr warning naming the file and line,
never a silent skip.

## File attributes and head directives

A body expresses content, not metadata: a managed file still has a mode, may
be a symlink or seeded once, and may be owned only in part, and none of that
can be written inside it as content. mox has no filename prefix for any of
these. Filesystem metadata git cannot carry lives in `.mox/attributes.toml`.
The ownership contract, the whole-file gate and interview defaults are the
file's own directives, written in its leading comment block as head
directives -- where the format has comments. Strict JSON has none, so a
`.json` target's directives are attributes instead:

| Target | `own` / `disown` / `check` | whole-file `when` | `default` |
|---|---|---|---|
| TOML, YAML, INI, gitconfig | head directive, `#` | head directive, `#` | line directive, `#` |
| JSONC (`.jsonc`, or `format = "jsonc"`) | head directive, `//` | head directive, `//` | line directive, `//` |
| strict JSON (`.json`) | `own` / `disown` / `check` attribute | `when` attribute | `defaults` attribute |
| any other text file | not allowed | head directive, its marker | line directive, its marker |

Each file has one home for its directives: a directive attribute on any
target but strict JSON is refused ("write it as a head directive in the
file"), and a `mox:` comment in strict JSON is refused naming its attribute.

### Attributes (`.mox/attributes.toml`)

An entry is keyed by the target's home-relative key:

```toml
[".ssh/config"]
mode = "0600"

[".claude/settings.json"]
disown = ["model", "autoMode", "feedbackDrafts"]

[".config/Code/User/settings.json"]
format = "jsonc"
```

- **Mode.** The target's mode is the source file's own permission bits: `chmod
  +x` the source and git carries the exec bit (git round-trips 0644 and 0755
  across a clone). A mode git cannot carry -- anything other than 0644 or 0755,
  such as 0600 or 0444 -- is recorded as `mode`, since git collapses it to 0644
  on clone.
- **Symlink.** `mox add` of a live symlink stores the link target as the source
  content and flags `symlink = true`. Apply plants a symlink at the live path.
  The target is ordinary composed content, so it can vary by axis or interpolate
  captures.
- **Seed-once.** `mox add --seed-once` records `seed_once = true`. Apply writes
  the target only when it is absent and never overwrites, drift-checks, or
  commits an existing one -- for a machine-local skeleton the user then edits.
- **Format.** A `.json` target is strict JSON. `format = "jsonc"` reads one as
  JSON with comments and trailing commas, for a program that reads them (VS
  Code's `settings.json`, `tsconfig.json`); a `.jsonc` file is JSONC by its
  name. No other `format` value, and no other path, is accepted.
- **Directives of a strict-JSON target.** `own` and `disown` are lists of
  key-paths, exclusive as their head forms are; `check` is the argv list the
  `check` head directive takes, and requires `own` or `disown` in the same
  entry; `when` is an axis expression, the whole-file gate; `defaults` is a
  table of fact name to interview default (`defaults = { profile = "work" }`),
  as `default` lines declare. Fact discovery and the axis inventory read
  them exactly as they read head directives.
- **Released.** `released = true` is the tombstone `mox remove` leaves (see
  Sources that leave the tree). It takes no other key.

An entry that breaks the schema -- an unknown key, a wrong type, a directive
key on a target that is not strict JSON -- is that file's error alone: it is
reported as the file's `ERROR`, and every other file still applies. One with
no source at its path, such as a mistyped tombstone, is reported at that path
the same way, and nothing is swept while it stands. A file that is not valid
TOML, the repo's or the private layer's, stops the run in every command with
exit 2, named with its line, column and reason.

The file is maintained by mox (`add`, `mv`, `remove`): commands that write
entries rewrite it deterministically, so it carries no comments. A command
that would rewrite a file holding one is refused before it changes anything
("comments here would be lost; remove them").

### Head directives (partial ownership)

A source file with comments declares its ownership contract in its LEADING
comment block -- recognized after an optional shebang and before the first
content line, one directive per line, in the format's comment marker:

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

A strict-JSON target declares the same contract in its attributes, and its
source is the JSON alone:

```toml
[".claude/settings.json"]
disown = ["model"]
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
  names a validation hook; see below. It requires an `own` or `disown`
  declaration in the same head -- a source carrying `check` alone is
  refused.

The directives never reach composed output: compose strips exactly the
recognized lines from the base text, so the live file a program reads contains
no mox syntax. Overlays cannot declare ownership; the contract is the file's,
machine-independent, stated once. A whole-file gate shares the same leading
block, before or after the ownership lines -- the whole block is read in one
pass, and the gate holds as long as only consumed directive lines precede it.

A base may hold no content of its own: a TOML, YAML, INI or gitconfig base may
consist of nothing BUT its leading block (ownership directives, an optional
`check`, an optional whole-file gate), and a JSONC base is that block and
`{}`, since an empty JSON document is no document. A strict-JSON target needs
no base at all: its attributes entry and its overlays are a complete file, and
a base it does have is `{}` or real content -- an empty one is refused. The
overlays in `<name>.d/` then supply all owned content, per machine. This is
the way to declare ownership for a machine-gated file: the contract and the
gate live in the base (or the attributes), the per-machine content in
overlays, and a machine where the gate fails leaves the live file (and mox's
records) completely untouched.

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
Ownership requires a structured target (TOML, JSON, JSONC, YAML, INI,
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

A partially owned target's live file is read in the target's format and
dialect: a live file that does not parse is refused, since mox cannot patch
what it cannot preserve, with its location and a hint (`live ~/x.json:3:9:
...`). A strict-JSON live file holding a comment or a trailing comma is
refused this way; its program would reject it too unless it reads JSONC.

### Check hook

`check "<repo-relative executable>" ["arg" ...]` (a strict-JSON target's
`check = ["<exe>", "arg", ...]` attribute)
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

## JSON and JSONC

A `.json` target is strict RFC 8259 JSON: no comments, no trailing commas, the
format its programs read. A `.jsonc` target, or a `.json` one whose attributes
set `format = "jsonc"`, is JSON with comments, and is structured just the
same: its layers merge, it can be partially owned, and `mox commit` writes
edits back into it. Every layer, overlay and fragment of a target, and its
live file, is read in the target's dialect.

A single layer passes through as written, comments and formatting included,
with only its capture-bearing strings rewritten. A multi-layer composition
re-emits the merged document as plain pretty-printed JSON, in either dialect,
so comments survive only the single-layer pass-through. `mox commit` writes a
strict-JSON source back as strict JSON, never introducing a comment or a
trailing comma, and refuses one that does not parse strictly before editing
it.

## Validation

Every structured layer is parsed in its target's format and dialect before it
composes: the base after its head pass (a line named in the error is the line
the source file has it on), and every overlay, private ones included,
matching this machine or not -- a broken layer is the repo's problem on every
machine. Every composed output is then parsed again after capture expansion.
The parsers are mox's own for each format: JSON or JSONC, TOML, YAML 1.2.2
(a stream, so zero or several documents are as valid as one), and INI, in the
gitconfig dialect for gitconfig. A generic INI file may hold a bare key
(`skip-networking` in a `my.cnf`).

Some layers are no document until composed, and are checked through the
output instead: an `include` fragment (a member snippet such as
`\tsigningkey = ...`), a non-JSON layer holding a capture (TOML's
`label = "<a | default "x">"`, or a bare `port = <data.u.port>`), a non-JSON
layer holding a region (alternate regions may repeat a key), and a JSONC layer
composed through its regions or loops. A strict-JSON layer has no such case:
its captures live inside strings, and it has no regions.

In the JSON family, a duplicate object key is refused where mox could have
made it: in a layer of a multi-layer merge, which parsing would silently
reduce to its last value, and in output where a key capture expanded. A
single layer with no key capture is passed to its program as written: JSON
permits duplicate keys, and what they mean is the program's call. TOML and
YAML require a mapping's keys to be unique, so a repeated key is refused in
any layer or output of those formats.

Only a source whose bytes compose into the target in its format is checked:
a symlink source holds a link target and a generator template holds a loop,
so neither is parsed as its key's format. A strict-JSON key's generator
template spells its loop with `//` lines.

A layer of a merge is read before captures expand, so a bare capture in a
merged TOML or YAML layer is reported at its line and column with a hint to
put it inside a string. `mox commit` reports a layer or live file that does
not parse the same way.

A failure is that file's `ERROR` in `apply`, `status`, `diff` and `export`,
and nothing of it reaches the live tree:

```
ERROR ~/.claude/settings.json (src/.claude/settings.json:1:1: mox directive "disown" in strict JSON, which has no comments; declare it in .mox/attributes.toml and remove the comments:)
      [".claude/settings.json"]
      disown = ["model", "autoMode"]
ERROR ~/app.toml (composed output line 2 from src/app.toml and src/app.toml.d/os=darwin.toml: invalid integer)
```

The location is `<layer>:<line>:<col>` for a layer and `composed output line
<n> from <layers>` for output. A duplicate key is printed as a JSON string.
mox never prints a byte of a live file in a parse error: a live file is
the user's data and may hold secrets mox never wrote, whether mox manages
all of it or part of it. The same holds for an output a secret was
resolved into. Since a parser's message can quote any line, such an error
gives the location and fixed text only: `does not parse as toml`, or for
INI the parser's error kind, such as `expected assignment`; a duplicate key
reads `duplicate key <redacted>`, and a hint that would quote the file is
left out. A layer the user wrote in the repo keeps the parser's full
reason. A strict-JSON failure carries a hint by its cause: the attributes
entry that replaces every head directive of the layer, printed under the
row ready to paste (see Region directives); `format = "jsonc"` for any
other comment; removing a trailing comma; `{}` for an empty file; quoting a
bare capture; stripping a byte order mark. An empty partial render ("mox
owns nothing here") is exempt.

## Sources that leave the tree

Every record mox keeps of a file it wrote names the repo it came from and the
HOME it was applied under (the real paths of both), so one repo's records,
or one HOME's, are never mistaken for another's when several `MOX_REPO`s or
HOMEs share a state directory. After the walk, `mox apply` finds the records
of this repo and HOME whose path no managed file -- repo or private layer,
gated-off ones included, since a gate is not removal -- and no generator
manifest names: a source that was deleted, moved, or released. The sweep of
an orphaned generator's files takes only manifests of this repo and HOME
that list no file outside it; an untagged manifest, written before manifests
named their repo, is never swept. Both sweeps leave a `.moxignore`-matched
file alone, and `status` and `diff` judge every such file exactly as the
sweep would.

- An unedited whole file or symlink is removed, snapshot-first, so `mox
  rollback` recovers it; an edited one is drift, kept until it is named:
  `mox apply --overwrite <path>` removes it, snapshot-first, and `mox commit
  <path>` keeps the edit by forgetting the path on this machine. An unscoped
  `--overwrite` never removes it. One already gone is forgotten.
- A partially owned file is never removed, since the rest of it is the
  program's: it is reported once as no longer managed, left in place, and
  its records forgotten.
- A path below a symlinked directory -- one on disk, or one the tree plants as
  a symlink -- names a file outside HOME's own tree: it is never removed,
  only forgotten.
- A released path is forgotten and never removed -- on macOS and Windows,
  whose filesystems ignore case, whatever the ASCII case its record or its
  generator spells (other case differences, and Unicode normalization, are
  not folded; see the warning below) -- a
  `.moxignore`-matched one left alone, and one that is the same file as a
  managed path (a case-only rename on a case-insensitive filesystem, or a
  hardlink) forgotten with nothing removed.

`mox status` reports such a file `STALE` (an edited one `DRIFT`), and `mox
diff` shows a pending removal. Nothing is swept -- by this sweep or by the
sweep of an orphaned generator's leaves -- in a path-scoped apply, or in a run
where any file failed to compose or write or carried a head error: a failure
at a moved path must not remove the old path's file before the new one is
written. A record that names no repo -- a one-line whole-file record, a
bare symlink target, an owned record without `repo` -- is never swept; apply
tags the record of every file it still produces, unchanged ones included.

`mox mv` therefore moves no state: every machine's next apply, this one
included, removes the old live file (or reports it as drift) and writes the
new one. `mox remove` leaves a tombstone, `released = true`, in
`.mox/attributes.toml`: every machine's apply forgets the path's records --
a released generator's leaves included -- and keeps its live file. A
tombstone is one line and is never pruned, since mox cannot know when every
machine has applied; `mox add` or `mox mv` onto the path removes it, and a
source back at a released path without one is that file's error. A
tombstone that matches no record, no generator and no managed file here is
a warning in `status` and `apply` (`WARN released ~/x matches nothing mox
manages`) until an apply has seen it once; one that a managed file matches
only by case is a warning on every run, naming that file. `mox remove
--purge` deletes the live file here and leaves no tombstone, so other
machines' applies remove their unedited copies too.

## Private layer

The private layer is `<state dir>/private/`, machine-local and never
committed. It mirrors `src/`: its overlays, regions and fragments compose over
the repo's sources at the same path, and its `data/` shadows the repo's.
Its attributes are `<state dir>/private/.mox/attributes.toml`; neither
`data/` nor `.mox/` is ever walked as a source.

- A private-only path (one the repo does not manage) is the private layer's
  alone, and its entry may set any key.
- For a path the repo manages, a private entry may set only `mode`, which
  wins over the repo's mode and over the automatic 0600 for an `op://` or
  `pass://` secret -- the way to keep a file private on one machine, such as
  one a private overlay adds a `cmd:` secret to. Any other key there is that
  file's error.
- A private base at a path the repo manages is an error naming both: vary
  the repo's file with a private overlay instead.
- A private overlay defining content under a path the repo disowns is
  refused, naming the overlay.

The private layer's gates and defaults reach fact discovery like the repo's,
so a fact only a private source compares is still asked. `mox remove` of a
private-only file forgets it here and writes no tombstone, editing the
private attributes, not the repo's.

## Concurrency and snapshots

mox serializes its own mutating runs with a single-writer lock at
`<state dir>/mox.lock`, so two `apply` / `commit` / `rollback` runs that share
a state directory never overlap. The lock is per state directory: runs given
different `MOX_STATE_DIR` values take different locks and can write the same
live tree at the same time, so keep one state directory per live tree.
The lock does not cover third-party writers: an external edit made to a live
file between mox reading it and writing it in the same run is not captured in
that run's snapshot, so a later `mox rollback` restores the pre-run content, not
the intervening edit. Do not edit a managed file while mox is applying.
