# Changelog

All notable changes to mox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-07-31

### Added
- A leading `~` in a path argument is expanded by mox, not only by the shell:
  a quoted `"~/x"`, a non-initial `--path=~/x`, PowerShell (which passes `~`
  to a native program verbatim), and a caller that builds the argument
  without a shell all reach the same file now. `~user` is refused rather than
  read as a directory of that name.
- `docs/commands.md` documents the two surfaces meant for a program rather
  than a person: `status --json`/`--porcelain`, and `mox __schema` (the whole
  command table as versioned JSON, constraints included). Neither is listed in
  `mox --help`, which is for finding a verb.

### Changed
- **Breaking:** a non-absolute path argument is now relative to the current
  directory, not to `$HOME`. Every command taking a live path (`add`,
  `apply`, `commit`, `diff`, `edit`, `mv`, `remove`, `status`) reads it the
  same way, so `mox commit init.lua` inside `~/.config/nvim` names that file
  -- which is what a shell's completion offers there -- rather than a
  `~/init.lua` that does not exist. `.` and `..` resolve, so
  `../fish/config.fish` reaches the sibling directory. A path spelled
  relative to `$HOME` from elsewhere (`mox status .config/nvim/init.lua`)
  no longer resolves: spell it `~/.config/nvim/init.lua`.
- Human-facing output shows a path under the home directory as `~/...` rather
  than in full, across every command that prints one -- previously only the
  drift report's table label did, and not even the resolution command beside
  it. Those commands are contracted now too: mox expands the tilde itself, so
  a pasted line works quoted, in a script, and in a shell that expands none.
  `--json`/`--porcelain` and `mox diff`'s unified-diff headers stay absolute,
  since their consumer expands nothing.
- `not managed` names the path it looked for when that differs from the
  argument as written, so a spelling resolved against the current directory
  reports where it actually went rather than leaving the reader to guess.
- The drift report no longer shortens the path to fit its other columns. At 80
  columns the fixed columns left it about a dozen bytes, so the one thing on a
  row that identifies a file was the one thing unreadable; the details now
  move to a line under the path instead, and only a path wider than the
  terminal itself is elided. The per-row `keep: mox commit`, identical on
  every row, moved into the guidance, which now spells out both resolutions --
  pre-filled with the path when exactly one file drifted.
- `add`'s flag relations (`--disown` against `--own`/`--own-absent`,
  `--seed-once` against the key-path options, `--gate`'s dependency on one of
  them, and the new `-r`) are declared on the command rather than checked in
  its body, so `--help` states them under `Constraints:` and the schema
  carries them. A violation is now a usage error (exit 2) like any other
  malformed invocation, where the hand-rolled checks exited 1.

### Removed
- **Breaking:** `mox add-tree <dir>` is now `mox add -r <dir>`. Recursion is a
  mode of `add`, as it is for `cp`, `rm`, `rsync`, and `git rm`, rather than a
  command of its own -- so `--seed-once` works over a tree, and `--force`
  applies to the directory you name, neither of which `add-tree` accepted.
  `--force` stops at that directory: the rules inside the tree still hold, so
  one flag can never sweep a subtree past an ignore list. The key-path options
  (`--own`, `--own-absent`, `--disown`, `--gate`) name a location inside one
  file and are refused with `-r`.

### Fixed
- A secret that resolves to nothing is refused instead of written. Every
  backend can return an empty value from a lookup it calls successful -- a
  variable set to `""`, an empty file, a manager exiting 0 with no output --
  and mox composed that into the live file, replacing a working credential
  with an empty one. Since a secret-bearing file is deliberately not
  baselined in cleartext, drift detection could not flag the result either.
  All five schemes now fail with `SecretEmpty`, distinct from `SecretNotFound`
  so the message does not claim a variable that is plainly set is missing.
- Windows: `facts.toml` is read from the directory it is written to. The
  machine's `xdg_config_home` resolved to `%USERPROFILE%\.config` while mox
  wrote the file under `%LOCALAPPDATA%`, so an interview answer was saved and
  then never found again and every run re-asked. All four `xdg_*` machine
  facts now resolve through the same base-directory rules as mox's own paths
  (`$XDG_*`, then `%LOCALAPPDATA%` on Windows, then the POSIX nesting), so on
  Windows they name `%LOCALAPPDATA%` where they previously named
  `%USERPROFILE%\.config` and friends.
- Windows: a home directory spelled with a lower-case drive letter no longer
  makes every managed file read as unmanaged. `std.fs.path` upper-cases a
  drive as it resolves, so the source walk keyed files under `c:\...` while
  every path argument resolved to `C:\...` and matched nothing. The home is
  canonicalized once, where it is resolved, so both sides agree by
  construction. `USERPROFILE` is never spelled that way; a hand-set `HOME`
  may be. On such a machine the first apply after upgrading reports its files
  as first-contact drift (the applied records were keyed by the old spelling)
  and leaves them untouched until resolved, as with any drift.
- `mox add` reads the home directory the way every other command does. It
  consulted only `HOME` and refused outright where just `USERPROFILE` is set,
  and treated an empty `HOME` as a home of `""` rather than as unset --
  keying a capture off the filesystem root. With no home named at all, it now
  refuses instead of taking `/` for the user's home.
- An empty `MOX_SNAPSHOT_RETENTION` or `MOX_UPGRADE_TARGET_BIN` is treated as
  unset, matching every other variable mox reads.

## [0.8.0] - 2026-07-30

### Added
- `mox status --drift`, `--json`, and `--porcelain`: emit the drift set (the
  same set `mox apply` reports, from the same classifier) as a filtered view
  or as machine-readable data for tooling.
- `# mox: keep-empty` line directive: materialize a directive-bearing file
  even when it composes to nothing, for a conditionally-present but empty file.

### Changed
- `mox apply` is now non-interactive: it writes the files that are clean or
  absent and never prompts. A drifted file -- one edited since mox last wrote
  it, or one mox never wrote (a first apply or migration) -- is left untouched
  and listed in a report on stdout, with the exact command to resolve it:
  `mox apply --overwrite <path>` takes the repo's version, `mox commit <path>`
  keeps the live edit. `--overwrite` is the flag's name now, with `--force`
  retained as an alias. Exit codes are 0 (clean), 1 (drift left unresolved),
  2 (a genuine failure); the drift report moved from stderr to stdout.
- `mox commit` keeps a hand-edit for every kind of drift, not only a file mox
  last wrote. With no stored baseline (a first apply, or a secret-bearing
  composition whose cleartext is not cached) it recomposes the source to
  rebuild a verifiable baseline and routes the edit against it.
- A managed symlink whose live path is a directory now converges under
  `--overwrite`: the directory is snapshotted (recoverable via `mox rollback`)
  and replaced with the link, instead of being refused.
- A directive-bearing file that composes to nothing is no longer written as a
  0-byte file; it is omitted, matching the generator rule where zero data
  already produces zero files. A file mox previously wrote whose source now
  composes to nothing is removed on apply (snapshot-first, recoverable via
  `mox rollback`); one edited since mox wrote it is reported as drift and kept
  until resolved. `mox status` shows such a file as `STALE`, or `DRIFT` when
  edited, and `mox diff` shows its live content as removed. A file with no
  directives is unaffected: a genuinely empty file is still written verbatim.

## [0.7.1] - 2026-07-28

### Changed
- A dimension's asking condition -- the OR of every occurrence's condition,
  shown on `mox facts --report`'s "asked when ..." line and re-evaluated
  each interview wave -- is now simplified at construction: exact-duplicate
  disjuncts are dropped, and a disjunct whose and-conjoined atoms are a
  strict superset of another disjunct's atoms is absorbed (`A or (A and B)`
  reduces to `A`). A gate value like `profile="new york"` that contains a
  space or any character outside the bare-token set now renders quoted in
  written-back conditions, matching the DSL's own value grammar.

## [0.7.0] - 2026-07-28

### Added
- The config-space interview: `mox apply` (and `mox facts`) now discover
  which facts to ask about directly from a repo's own sources instead of a
  hand-maintained schema file -- every fact a gate compares by value, a
  capture interpolates, a bare presence test names, or a script consumes,
  each asked only when the configuration it gates is reachable given the
  answers bound so far in the same run (a personal machine is never asked a
  work-only or backend-only question). A `# mox: default <name>="<value>"`
  line directive declares a fact's interview default in the source that
  owns the concern; it is an interview default only, never a silent
  fallback for an unbound fact. `mox apply --defaults` never prompts:
  every eligible fact binds its declared default, or is declined (bound to
  the empty string), for a non-interactive bootstrap. `mox facts --report`
  lists every discovered fact's state (bound, declined, or unbound) with
  its provenance; `mox facts ask [<name>]` re-interviews one fact (even if
  already bound, the change-an-answer flow) or every unbound/declined one;
  `mox status` gains an `unbound facts:` section; `mox doctor` flags a
  bound fact nothing in the repo consumes, bridging it to a probable
  rename when one is close.
- Script fact contracts: a setup script's use of `MOX_FACT_*` is now a
  checkable contract, resolved from a literal `MOX_FACT_[A-Z0-9_]+` token
  scan of the script's text, or overridden with a `# mox: needs
  <name>...` head line (an empty line declares "needs nothing"). Each
  needed fact is checked against the stage's actual projected
  environment and lands in one of six outcomes: runs, skips (gate
  false), skips declined (green, the needed fact was bound but
  explicitly empty), or blocks (red, counted like a failed script under
  its own summary label) -- naming the fact and its remediation, and
  failing closed on a token that maps to no known fact.

### Changed
- A non-interactive `mox apply` (no terminal, no `--defaults`) no longer
  refuses the run when a fact is unbound: it lists the unbound facts on
  stderr and proceeds, and a script that actually needs one of them is
  blocked individually instead. **Breaking** for a script or CI job that
  relied on the previous global refusal to catch a missing fact early --
  it now needs its own `# mox: needs` contract (or a consuming gate) to
  be blocked the same way.
- The schema's gated-only interview defaults are replaced by the
  `# mox: default` directive, declared in-source: a gate-only fact no
  longer gets an implicit default from where it happens to be compared.
- The DSL's reserved words now include `default`.
- `mox facts` now refuses loudly, instead of reporting an empty config
  space, when the source tree cannot be scanned for its interview.

### Removed
- `data/facts-schema.toml` support is gone: the hand-maintained schema
  file is no longer read, superseded by the sources-derived interview
  above. A repo that still has one gets a one-time notice from `mox
  apply` and `mox doctor` naming the file and saying to delete it.

### Fixed
- A post-stage setup script now sees the current, post-recapture fact
  environment: previously it could read the pre-stage env even after a
  pre-stage script persisted a new fact.

## [0.6.0] - 2026-07-28

### Added
- `mox init --clone` accepts shorthand: `owner` expands to
  `https://github.com/owner/dotfiles`, `owner/repo` to
  `https://github.com/owner/repo`, and `host/owner/repo` to
  `https://host/owner/repo`. Full URLs, ssh remotes, and local paths are
  passed to `git clone` verbatim as before.

## [0.5.0] - 2026-07-27

### Added
- `tool=<name>` and `env=<name>` are now open axes: any name resolves as a
  live probe (against `$PATH` plus this repo's resolved `data/paths.toml`
  registry for `tool=`, against the captured environ for `env=`) instead of
  a lookup against a pre-enumerated watch list, so a name never registered
  anywhere still resolves. `<machine.tool_path.NAME>` and `<env.NAME>`
  interpolation share the same resolution.
- `data/facts.toml`: a repo-provided, private-shadowed registry of
  `[[facts]]` rows deriving a single-value fact (name/env/candidates) mox
  has no built-in knowledge of, re-derived on the post-pre-script
  re-capture. A bound row behaves like any other fact; a name colliding
  with a built-in field or a reserved axis name, or a malformed row, is a
  capture error naming it.
- An explicit `$MOX_PATH` channel: a setup script can append a directory a
  tool installed into that neither `$PATH` nor `data/paths.toml` would
  otherwise see, and it joins the search space for the rest of the run.
- `mox status` prints a probe log naming every `tool=`/`env=` name a run
  actually asked and whether it resolved, so a typo'd gate is visible
  instead of a silent false forever; `mox facts probe tool=<name> |
  env=<name>` is the scriptable single-name counterpart.
- An axis value may now be a quoted string, admitting a non-ASCII value
  (a Kanji profile name, a Kanji `COMPUTERNAME`) that the bare-token
  grammar rejected outright.
- The `machine` axis/fact now binds only the hostname's first label
  (network-stable), with the full name available separately as a new
  `hostname` axis/fact.
- A data row's own captures (`dir = "<machine.brew_prefix>/bin"`) now
  expand through `<entry.field>` splices, one level deep.
- Many previously-silent failures across apply, rollback, commit, doctor,
  and status now surface as a visible warning or a hard error instead of
  passing unnoticed.
- A new row-predicate form, `bound <var>.<field>`: substitutes the row
  field's value, then checks it names a bound single-value machine fact by
  presence -- the twin of the existing `axis = <var>.field` form, which
  checks the substituted value by equality instead.

### Changed
- A capture written inside a data-row string value now expands (one
  level); previously it spliced as literal text. A literal angle
  bracket sequence in a data value that happens to spell a capture now
  resolves or errors instead of passing through verbatim.
- **Breaking** for anyone gating on a dotted `machine=<value>`: `machine`
  no longer binds the raw hostname, only its first label: an overlay or
  fragment named for a full dotted hostname must be renamed to the first
  label, or switched to the new `hostname` axis.
- A custom fact or `data/facts.toml` row named `tool`, `env`, or `path` is
  now rejected at load time: it would otherwise silently shadow that axis's
  whole binding.
- The DSL's reserved words now include `bound`.

### Removed
- The `path=` axis and its built-in tool-home detection (Homebrew, cargo,
  go, pnpm) are gone: mox ships with zero built-in directory knowledge.
  `path` stays a reserved name so a leftover `path=` source errors loudly
  instead of composing to a silent false forever; a repo that wants the old
  facts declares them in `data/facts.toml` instead, and their PATH
  directories are ordinary `data/paths.toml` rows.
- `<xdg_config_home>/mox/extras.toml` is no longer read (superseded by the
  open `tool=`/`env=` probes above). A one-time notice names the file and
  states it is no longer read when mox finds one still on disk, so an
  unmigrated machine finds out instead of watching its gates go quietly
  dark.

### Fixed
- A batch of previously-swallowed error paths now propagate or warn instead
  of failing silently: an fsync failure, a rollback symlink read failure, a
  partial-target walk error, a snapshot mode-capture stat failure, a
  facts.toml value dropped for the wrong type, an unencodable fact name
  left out of script env, an unparseable timeout or snapshot-retention
  override, a coupling-graph persist failure, and a post-edit restore
  failure that used to discard the original error.
- `mox doctor` now flags an unknown `scripts/` stage directory, an
  unparseable tuple, an out-of-vocabulary `os=`/`arch=` gate or overlay
  value, an unknown or wrong-typed `attributes.toml` key, and a
  completions registry row key outside its schema -- all previously
  dropped or silently ignored.
- `mox status` ERROR rows now name the error and the failing item.
- Machine capture now consults `HOMEBREW_PREFIX` and a per-user linuxbrew
  install, and errors when neither `HOME` nor `USERPROFILE` is set instead
  of proceeding with an empty home.
- `mox upgrade` falls back to `wget` when `curl` is absent.
- `mox add`'s home-membership check now resolves both sides through
  `realpath`.

## [0.4.0] - 2026-07-27

### Added
- Completions generator directive: `# mox: completions <shell>
  "data/completions.toml" [when <axis-expr>]` turns a source file into a
  generator that emits one lazy completion stub per registry row into its
  target directory -- fish, zsh, bash, and PowerShell. A stub asks the
  INSTALLED tool for its completion script on the first completion
  request of a session, riding each shell where a native per-command lazy
  loader exists (fish completions dir, zsh fpath, bash-completion v2) and
  a self-replacing Register-ArgumentCompleter on PowerShell -- so
  completions cost nothing at shell startup and can never go stale
  against the installed version. The zsh stub always rebinds and
  dispatches explicitly: inside `eval`, a generated script never fires
  its own trailing self-dispatch guard (funcstack[1] is `(eval)`), and
  without the rebind a non-rebinding script would re-run its generator on
  every request. Registry rows declare `name`, a `command` prefix or
  full per-shell overrides, an optional `shells` allow-list, and
  `zsh_dispatch` for scripts that register a differently-named
  function; every gap is a row-named compose error, never a silent skip.
  Stub shapes are byte-golden-tested and exercised in real shells
  (zpty compsys sessions proving first-TAB completion, fish
  `complete -C`, pwsh `TabExpansion2`).
- Loop bodies: the marker-strip rule (one leading marker plus one space
  is removed from a commented body line) and its doubled-marker escape
  (`##x` emits `#x`) are now documented and test-locked.

### Fixed
- Apply now sweeps the manifests of generators that left the tree: a
  generator source deleted directly (git rm, an editor) or stripped of
  its directive used to leave every produced file live forever, with
  only `mox remove` pruning the set. Orphaned sets are pruned
  snapshot-first against the global keep set; a failed or parse-broken
  generator keeps its manifest, and the sweep never runs on a scoped
  apply or after a drift-prompt abort.

## [0.3.0] - 2026-07-26

### Added
- Partial ownership: mox can now manage part of a file a program also
  writes. Declare it in the source's leading comment block -- `# mox: own
  <key-path>` (the file is yours only at those paths) or `# mox: disown
  <key-path>` (the file is yours except those paths) -- and mox composes,
  applies, drifts, and commits the owned subtrees with full semantics
  (overlays, axes, captures, secrets, per-key commit routing with the
  layer picker) while provably never changing a byte outside them: the
  remainder is byte-compared on every write, in production. A live file
  the program rewrites no longer reads as drift; an edit inside your
  region still does, per key path. Supported for TOML, JSON, YAML, INI,
  and gitconfig; shapes the span model cannot address (yaml anchors,
  dotted-key spellings of an owned table) are refused by name, never
  guessed at.
- `# mox: check "<repo-relative exe>" [args]`: an optional validation hook
  for partial files. The candidate is staged privately and the hook runs
  with `MOX_CHECK_FILE`/`MOX_CHECK_DIR`; nonzero or a timeout
  (`MOX_CHECK_TIMEOUT_MS`, default 30s, process-group kill) refuses the
  write. `--skip-scripts` skips the hook AND the write, so nothing
  unvalidated installs.
- `mox add --own <path>` / `--disown <path>` (repeatable) onboard a live
  file in one command: the named subtrees (or their complement) are
  extracted raw -- comments intact -- into a new source headed by the
  matching directives. `--own-absent <path>` declares enforced absence;
  `--gate "<axis expr>"` writes a whole-file gate alongside, onboarding a
  machine-gated file in one line (and warns when the gate does not hold
  locally). A directive-only base (directives plus a gate, no content)
  composes entirely from its overlays.
- `mox status` annotates partial files with their ownership inventory
  (`(own N)` / `(disown N)`), including gated-off ones.
- Structured per-key commit prompts now show the old and new value under
  each key, and structured/owned diffs label every hunk with its key-path
  section, so a scalar change names its key.
- `mox doctor` flags an attributes entry that no managed target derives.
- Fuzz targets for the head-directive parser, the key-path grammar, and
  the partial span engine run in the bounded suite and the nightly fuzz
  step.

### Changed
- `mox remove` now forgets the applied-state records for the removed
  target (all files, not only partial ones). Previously a re-added file
  could inherit stale state; removal now means mox has genuinely stopped
  tracking the path.
- `mox rollback` on a partial target re-patches the snapshot's owned
  subtree onto the current live file instead of restoring whole bytes, so
  the program's writes since the snapshot survive; a secret-masked
  snapshot is refused rather than written live.
- At the apply drift prompt, `q` now stops the run, reports every
  unresolved file, and exits nonzero -- previously it silently dropped
  the remaining files and exited clean.

### Fixed
- `mox status >> log` (any command with a redirect) no longer overwrites
  the target from byte zero: standard streams are opened in streaming
  mode, so appends append.
- A FIFO or other non-regular file at a live path no longer hangs mox:
  every live read guards the file kind first and reports the path
  instead.
- `mox add` now takes the same single-writer lock as every other
  mutating command, resolves relative paths against HOME like its
  siblings, and records canonical keys for `./`-spelled paths --
  previously such a path silently split the attributes key from the walk
  key and a restrictive mode (0600) was lost on re-apply.
- `mox add-tree` refuses a missing or non-directory argument and a
  directory outside HOME (each was silently accepted before), captures
  symlinks like single `add`, reports non-regular entries as skipped, and
  rebuilds the coupling graph after a bulk add so the first commit can
  offer coupled updates.
- A symlinked live path under partial ownership is patched at its resolved
  target -- the link survives and one inode is parsed, race-guarded, and
  replaced -- instead of being silently replaced by a regular file while
  the target kept stale content.

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
