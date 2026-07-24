# Changelog

All notable changes to mox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-24

### Added
- Structured commit routing. A file composed by merging layers (`.toml`,
  `.json`, `.yaml`, `.ini`, gitconfig) now commits per KEY instead of per line:
  each changed key routes to the layer that defines it (`[y]`), `[p]` opens a
  picker to place it in any viable layer -- promoting a key to a less specific
  layer deletes the overrides that would shadow it on this machine -- and `[s]`
  leaves it. A placement that reaches a machine configuration beyond the one
  you chose (a promote other machines would compose) lists those configurations
  with before/after values and asks first, enumerated over the repo-wide
  configuration space so a machine revealed only by another file's overlay --
  or one whose os/arch no source names at all -- is still seen. Every routed
  edit passes the recompose-verify guard; a key derived from a secret or an
  interpolation is never routed.
- Interpolated-value edits route to the machine fact. Editing a line whose
  value came from `<machine.X>` offers `[f]` (write the fact) and `[d]` (change
  the source's `| default` instead); neither touches repo `src` with a resolved
  value.
- Interactive drift resolution in `mox apply`. A live file edited since mox
  last wrote it now asks, per file on a terminal: `[o]verwrite` (discard the
  live edit), `[c]ommit` (route the live edit back into its source, then leave
  the file in sync), `[d]iff`, `[s]kip`, or `[O]`/`[S]` for the rest. Off a
  terminal, and under `--yes`/`--dry-run`/`--force`, behaviour is exactly as
  before.
- Path scoping: `status`, `diff`, `apply`, and `commit` accept managed-file
  paths (absolute, live, or src-relative) to limit the run, with shell
  completion for managed files.
- A straddling hunk -- one spanning several sources' lines -- can be split at
  its provenance boundaries (`[x]`), each piece then routing on its own.
- Color. `mox diff` renders colorized hunks; commit prompts are colorized,
  self-explaining legends (`[y]es  [s]kip ...`). `--color auto|always|never`
  and `NO_COLOR` are honoured.

### Changed
- Managed files enumerate in a stable name order everywhere -- `status` and
  `diff` listings, `commit` prompts, generator output -- instead of the
  filesystem's directory order, which differs between APFS and ext4.
- Commit prompts are reworked around explicit keys: a routed hunk is `[y/s]`,
  an unroutable one `[s/x]`, an interpolated one `[f/d/s]`, a structured key
  `[y/p/s]`. Split is offered only where a hunk can actually be split.

### Fixed
- `mox diff` no longer fails on a generator source (`for ... into`) with
  `IntoOnNonGenerator`; it diffs the files the generator produces, as `status`
  already reported them.
- A comment or layout edit to a structured file whose overlays do not match
  this machine now routes by line and commits. Such a file composes verbatim
  from its base, but was attributed to an overlay merge -- stranding those
  edits as manual. Provenance recorded by an earlier mox is refreshed from the
  current source when it provably describes the same content, so the fix
  applies without re-running `apply` first.
- A layer only another machine's configuration reads failing to parse no
  longer aborts the whole commit with a bare error. The configuration is named
  once with the failing file, treated as unverifiable-but-pre-broken, and an
  edit that has nothing to do with it still commits; an edit that MAKES a
  configuration stop composing still rolls back.

## [0.1.6] - 2026-07-21

### Added
- The comment DSL now recognizes PowerShell and batch files: `.ps1`, `.psm1`,
  `.psd1` use a `#` marker and `.cmd`, `.bat` use `rem`, so a `# mox: when` /
  `rem mox: when` directive gates those files like any other source.

### Fixed
- `mox doctor` no longer reports a Windows-gated PowerShell module (a `.psm1`
  gated `# mox: when os=windows`) as "never-materializes". The gate is now
  parsed, so the module is correctly seen to materialize on Windows.

## [0.1.5] - 2026-07-21

### Fixed
- `mox doctor` no longer reports a tracked file as "tracked-and-ignored" when it
  is ignored only inside a `# mox: when` region (intentional per-machine
  gating, e.g. a Windows-only `*.ps1` ignored on macOS). The advisory now fires
  only for a file ignored by an unconditional rule -- one that can never apply
  under any configuration.

## [0.1.4] - 2026-07-21

### Added
- A repo-scoped ignore mechanism. Rules live in `.moxignore` (root) or
  `.mox/ignore` (both optional, merged), use gitignore syntax matched against
  the home-relative path (a file under an ignored directory is itself ignored),
  and can be axis-gated with `# mox: when` -- composed through mox's own DSL, no
  separate template language. A matching path is refused by `add`/`add-tree`
  (`add --force` overrides), never materialized by `apply`, exempt from
  `.mox-exact` pruning even under `--force`, hidden from `status`/`diff`, and
  flagged by `doctor` when a tracked source also matches. `mox init` scaffolds a
  starter `.moxignore` guarding common secret files (fully deletable), and
  `add`/`add-tree` print a non-blocking note when a file that looks like a
  secret is added.

## [0.1.3] - 2026-07-21

### Added
- `mox upgrade [<version>] [--yes]` self-updates the binary: it fetches the
  latest (or a named) release, verifies the download against the release's
  `SHA256SUMS` before unpacking it, and atomically replaces the running binary
  -- never auto-downgrading, and refusing any download it cannot verify.
- Releases now include an `aarch64-windows` (ARM Windows) binary.

## [0.1.2] - 2026-07-21

### Added
- `mox init --clone <url> --apply` clones and applies in one step, so the
  installer one-liner brings up a whole machine from scratch:
  `sh -c "$(curl -fsSL .../install.sh)" -- init --clone <url> --apply`. Without
  `--apply`, `init --clone` still stops for review first -- the safe default,
  since applying a freshly cloned repo runs its setup scripts.

## [0.1.1] - 2026-07-21

### Added
- A one-line installer (`install.sh`, `install.ps1`): it downloads the release
  binary for the host platform, verifies it against a published `SHA256SUMS`,
  and installs it, depending on nothing a fresh machine lacks (a shell, curl or
  wget, and tar). Arguments after `--` pass straight to mox, so
  `init --clone <url> --apply` installs and bootstraps a machine in one command.
  `BINDIR`, `MOX_VERSION`, and `MOX_BASE_URL` tune the install.
- Releases now publish a `SHA256SUMS` asset covering every binary.

### Fixed
- `mox mv` on a generator source now re-keys its produced-set manifest to the new
  location, so the next apply prunes the old leaves instead of orphaning them.

## [0.1.0] - 2026-07-20

Initial release. mox keeps config files in their native format and composes
per-machine output from axis overlays, with no template syntax in file bodies.
Nothing about a machine is recorded outside it.

### Composition
- Three file categories detected automatically: structured deep-merge (TOML,
  JSON, YAML, INI, gitconfig), comment-DSL code/text, and whole-file binary.
- Axis overlays via `<file>.d/` directories; most-specific axis tuple wins. An
  axis is a fact the source compares by value; a fact merely tested for presence
  (`when signing_key`) is a local conditional that classifies nothing and never
  leaves the machine. A structured file with no base and no matching overlay is
  cleanly absent, so an OS- or profile-specific file can be pure overlays.
- Comment DSL: `include`, `replace`, `append`, `prepend`, `remove`, `from`, and
  `when` regions, plus bounded `for` loops over TOML/JSON/YAML data sources with
  optional per-row `where` filters. Directives nest -- a `for` or `when` region
  body is itself a template, so nested loops and per-row conditionals compose
  natively -- and a leading whole-file `# mox: when` gate conditions whether a
  file materializes while still composing it in its native format.
- `for <var> in <source> into "<path-template>"` generators fan out to one file
  per data row at the rendered path, the source itself not materializing;
  removing a row removes its file on the next apply, snapshot-first.
- Interpolation captures `<machine.X>`, `<env.X>`, `<entry.X>`, and
  `<data.FILE.KEY>` (a committed shared scalar), with `| default` and
  left-to-right fallback chains. A `<var>.field` reference resolves against the
  named enclosing loop.
- Private layer overlays and per-machine facts (`facts.toml`), with a
  schema-driven first-run interview supporting dependent prompts.
- Secret resolution during apply via `env:`, `file://`, `op://`, `pass://`, and
  `cmd:` URIs, as a whole-line `secret` directive or a mid-line `<secret:URI>`
  capture (escape a literal `>` in the URI as `\>`).
- The bounded DSL is specified in `docs/dsl-grammar.ebnf` and locked by a
  non-feature rejection-test suite.

### Applying
- `apply` composes and writes live files with a drift guard: a hand-edited live
  file is never silently overwritten (`--force` to override), with pre-overwrite
  snapshots and `rollback`. A live file changed by another process mid-apply is
  detected right before the write and refused rather than clobbered.
- File attributes travel natively: a managed file's mode is its source file's own
  permission bits (git carries 0644 and 0755), while modes git cannot carry
  (0600, 0444), symlink targets, and `mox add --seed-once` intent are recorded in
  a generated `.mox/attributes.toml`. `.mox-exact` directories prune live entries
  mox did not write. A live file that resolves an `op://` or `pass://` secret is
  applied at 0600 automatically (unless an explicit attribute mode is set); the
  same holds for `mox export --resolved`, which also announces each secret it bakes.
- Setup scripts run every apply (guard expensive work with `mox trigger`),
  including PowerShell and axis-gated script directories; scripts see mox paths
  and facts as environment variables. `--skip-scripts` and `--dry-run` available.

### Editing back
- `commit` routes hand edits to a live file back into the right source (base,
  fragment, or data-source row) via a line-provenance map, with a privacy
  invariant that private-origin edits never reach the shared source tree.
- A shared edit is routed by simulating it against the configurations the source
  itself expresses, and by asking: `commit` synthesizes the overlay region an
  edit needs and verifies that no other configuration's output changes.
- Cross-file coupling: a changed shared token prompts to update its other
  consumers, with a persisted coupling graph and decline list.

### Lifecycle
- `init` (with `--clone`), `add`, `add-tree`, `status`, `diff`, `edit`, `mv`,
  `remove`, `export --resolved`, `snapshot`, `rollback`, `doctor`, `uninstall`,
  `sync`, `data get`, `facts`, `secret`, `trigger`. `status`, `export`,
  `doctor`, and `remove` understand generators.
- `mox doctor` reports a `never-materializes` advisory for a source that composes
  to nothing under every configuration in its axis space, which is typically a
  contradictory or mistyped whole-file gate.
- Single-writer lock on mutating commands.
