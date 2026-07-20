# Changelog

All notable changes to mox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
