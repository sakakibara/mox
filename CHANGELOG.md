# Changelog

All notable changes to mox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.0] - 2026-09-21

### Added
- Packages. A `data/packages/*.toml` manifest of `[[packages]]` rows (core
  keys `name`, `backend`, `when`; every other key belongs to the backend,
  which refuses an unknown one naming the file and row), `[[blacklist]]`
  rows for what is installed but never to be offered, and `[[bootstrap]]`
  rows naming a manager's installer by URL and sha256. Files union across the
  repo and private layers with per-basename shadowing, and a file-level
  `when` gates every `[[packages]]` and `[[bootstrap]]` row in the file,
  narrowed by a row's own; a `[[blacklist]]` row holds on every machine, so
  it takes no gate and may not sit in a gated file. Seven
  backends ship:
  brew (formulae and casks as distinct namespaces; a tap-qualified name is
  the tap and the decision to trust that one formula or cask, never the
  whole tap), apt, dnf, pacman, zypper (no explicitly-installed query, so mox
  keeps a ledger and intersects it with what rpm reports present), scoop and
  winget. A backend whose query answers something other than "what did the
  user ask for" says so as a note under itself, in whichever direction:
  brew has no explicit-install query for casks and `winget export` reports
  only what a source supplied, while `scoop export` is every app directory
  and `winget export` also carries every installed package a source can
  correlate.
- Any other manager is a plugin: an executable at `scripts/backends/<name>`
  speaking seven verbs (`available`, `id`, `list`, `install`, `declare`,
  `bootstrap`, `limitation`) on the same contract as a shipped backend. `id`
  is both validation and identity; a `declare` answer is handed back to `id`
  and refused unless it round-trips, against the same shape the manifest
  enforces, so a row `declare` writes is a row the next command reads back;
  exit 64 names an optional verb the plugin lacks, and `available` has none;
  a plugin named like a shipped backend overrides it and `status` says so.
  Ids are opaque, calls are time-bounded, and an id that is empty, exceeds
  256 bytes, or carries whitespace, a control byte or a byte that is not
  UTF-8 is refused as a lost line separator. A `limitation` line is capped at
  200 bytes and may carry no control byte. Plugins are handed
  `MOX_PACKAGES_DEPTH`, and a mox reached from inside one discovers no
  plugin and says so, so a plugin that calls mox cannot multiply itself. A
  backend name never begins with a dot, so nothing in `scripts/backends/`
  that does is one: an empty directory can be kept in git and shell plugins
  can carry the eol rule that keeps them LF-clean on Windows. What git and an
  editor keep there passes without remark; any other dotfile is ignored and
  said as a note, since that is also how a backend ends up hidden by
  accident. A directory named like a plugin says what it is rather than that
  no such backend exists.
- `status` reports each backend's MISSING and UNTRACKED packages, `apply`
  installs the missing, and `commit` offers each untracked package to add,
  blacklist or skip. Nothing ever uninstalls. A repo without
  `data/packages/` queries no manager and reports nothing; one with the
  directory and no file yet is in use and reports everything installed as
  untracked, ready for a first file to record it in. `--skip-scripts` and a
  path-scoped `apply`, `commit` or `status` reach no package.
- `apply` installs a declared manager that is absent from its verified
  installer and then uses it in the same run -- brew and scoop by the path it
  landed at, a plugin by the bin dir it reports -- after the pre stage and its
  re-capture. `--dry-run` plans as though that had happened, and counts a
  plan's own failures as the real run counts its own.
- `commit` appends a package row the moment it is chosen and never edits one;
  `q` ends the run before the file pass, saying how many rows were already
  recorded. The append holds an exclusive lock on the manifest file's
  directory across its read and its rewrite, so two runs that share a repo but
  have a state directory each -- `mox commit` beside `sudo mox commit` --
  cannot both read the file before either writes it and drop a row. Windows
  locks no directory, and there the state lock is what stands between them. A
  row appended to a manifest the user created and left empty begins where a
  row appended to a manifest that never existed begins: the newline that
  separates a block from what precedes it is dropped when nothing does.
- `status` reports the rows of an absent manager that has a bootstrap row as
  missing and notes that apply will bootstrap it; a manager whose `--version`
  fails is reported `BROKEN` and counted in the exit code, as is one that
  answered its probe and then failed a query -- one manager that cannot answer
  is that manager's row, beside every other manager's results, never a refusal
  of the whole pass. A `BROKEN` row says what was asked and why it could not
  answer; the `package_broken` porcelain record carries backend, exit code and
  that reason, and the JSON entry is `{backend, state, exit, probe, why?}`.
- A package pass that produced nothing at all -- a manifest that would not
  load or validate, or a plugin set that could not be discovered -- is a
  record of its own on stdout and in both machine formats (`ERROR     the
  package pass was refused; the reason is the mox status: packages: line`,
  `{"state":"refused"}` and `package_refused`), so a refusal is never read as
  a clean machine.
- Every captured manager call is bounded by the setup-script timeout: the
  bound covers reading its output and waiting for it, and a kill is reported
  as a timeout naming the backend. A streamed install is not bounded unless
  `MOX_INSTALL_TIMEOUT_MS` is set. `mox --help` names
  `MOX_SCRIPT_TIMEOUT_MS`, `MOX_INSTALL_TIMEOUT_MS` and
  `MOX_PACKAGES_DEPTH`. Under `--json` and `--porcelain`, plugin notes go to
  stderr and stdout stays machine-pure.
- Every child leads its own process group, and a streamed one is handed the
  terminal for its run, so `sudo` can prompt and Ctrl-C reaches the manager
  (and ends mox with it); at a bound the child's whole group is interrupted
  and then killed, so no manager outlives the run that started it (Windows has
  neither groups nor job control, so there the direct process is terminated at
  once). A Ctrl-C during a query kills the query's group before mox dies of
  the interrupt; a Ctrl-Z during an install suspends the job and hands the
  terminal back, so the shell can resume it.
- A call a signal ended says which signal ended it, rather than reporting an
  exit of 255 that a manager refusing a row with a printed reason would also
  report -- a manager the out-of-memory killer took said nothing at all. A
  child killed from outside takes whatever it left running with it, as one
  killed at its bound does, so a manager that outlived the shell in front of
  it keeps no database lock with nothing to explain it. A captured call asks
  after its child on a schedule rather than only when a read comes back empty:
  anything the child left running holds the pipe the answer is read from, so a
  straggler writing even once a step could keep the loop from noticing the
  child had exited and turn an answer already in hand into a timeout. A run a
  signal ends names the batch it was installing, in one write from the handler
  itself, so an interrupted install says more than that it began.
- A read that a refusal rests on says when it came back empty. Three reads of
  what the repositories hold answered nothing on failure: two left the machine
  an upgrade would produce looking like the machine as it stands, so a row was
  judged against a version the upgrade replaces, and the third never asked
  whether it had an answer at all, so a failed read found no package
  conflicting with anything and sent every row to the install, which is the
  outcome that read exists to prevent. Each says so now, in pacman's own
  words, as the four reads beside them already did. A baseline read that
  cannot run at all is no reason to install nothing: where rpm is missing the
  batch goes ahead without a baseline and says so, and a read killed at its
  bound still stops the install and says that too. A listing drops a line that
  is not a package name wherever that line could be read back as one, the dnf
  listing a `status` reports from included.
- A manifest refuses a `name` its manager would read as an operation rather
  than a package. Each manager has its own class, because each has its own
  grammar. apt, dnf, pacman and zypper take a name beginning with a letter or
  a digit and carrying only `[A-Za-z0-9._+-]`, never ending in `-`, which all
  four read as a request to REMOVE that package; a trailing `+` stays legal,
  since `g++` is a package, and an apt name may carry one `:<arch>` qualifier,
  which is the one name apt itself reports with a colon in it.
- brew takes a formula or cask, `@` included for `openssl@3`, or a
  tap-qualified `owner/tap/name`, so a row cannot be an option (`brew install
  --help` exits 0 having installed nothing, which would count as installed and
  reinstall forever), a local Ruby file or a URL. scoop takes one token, so a
  row cannot be a manifest path, a URL, a bucket-qualified name or a pinned
  version that scoop then reports under its bare name; winget's identifiers
  are the publisher's own strings, so its rule refuses what would make one a
  path, a URL, a pattern or an option rather than narrowing what an identifier
  may hold.
- A row naming a capability rather than a package (`pkgconfig(...)`), a
  version relation, or an architecture suffix is refused for the same reason:
  it installs under one name and is read back under another, so it would be
  reported missing and reinstalled forever. The field values an adapter
  splices into its manager's argv -- scoop's `bucket`, winget's `source` --
  are held to the same class as a name, and winget's `override`, which exists
  to carry an installer's own command line, is held to what an argv can carry
  intact. `mox commit` puts a row it is about to write through that same
  check, so no manager's answer can produce a file a later command refuses.
- Whether a manager HAS a package of that name is asked of the manager itself
  before an install -- apt against `apt-cache --generate pkgnames`, narrowed
  to the native architecture and to repository packages so a bare row can only
  mean the package apt-mark would report bare, or against `apt-cache madison`
  for a name carrying an architecture, dnf against `dnf repoquery`, pacman
  against `pacman -Sg`, brew against `brew info --json=v2` -- so a name apt
  would read as a regular expression, a name apt has only for a foreign
  architecture, a name apt has as a virtual name rather than a package, a name
  that is only an rpm capability, a pacman group, a brew alias, and an apt row
  carrying the machine's own architecture or apt's `:native`, `:all` or `:any`
  are each refused with the name to declare instead, having installed nothing.
- The repositories are not apt's whole answer: `dpkg-query` says which
  architecture an already-installed package is under, so a bare row whose
  package came from a `.deb` and is native (or `all`) is kept -- apt-get marks
  it manual and the row converges -- while one whose package is installed only
  for a foreign architecture is refused with the qualified spelling. apt is
  asked two more questions, because a held package and a pinned one each make
  `apt-get install` install nothing at all: `apt-mark showhold` and
  `apt-cache policy` name the row to refuse, and a hold is never overridden.
- brew is asked once per kind, formulae and casks being separate namespaces
  that share names, and about tap-qualified rows as well, since brew reports a
  `homebrew/core` formula bare; a batch brew answers for none of is asked
  again one name at a time, so one name brew cannot resolve does not turn the
  check off for the rest. A name a manager merely cannot find is not refused
  where absence is no evidence: pacman's database is whatever the machine last
  synced, and the install syncs it. pacman's "this is no group" answer IS
  acted on, so it is asked of a database every repository in `pacman-conf
  --repo-list` answered for, and mox syncs first when one of them did not.
- A refused row is its own failure: the rows beside it are installed, since
  one bad row in a manifest must not keep every other package off the machine.
  `mox apply --dry-run` runs none of those checks -- they refresh an index and
  elevate, which a dry run may not do -- and says, beside the rows it would
  install, which manager list it left them unchecked against. A brew mark that
  fails is that row's own failure too, as it already was for every other
  manager, so the count of what landed stays true and a run that only marked
  says so rather than claiming it reached the installer.
- A manifest also refuses an unknown top-level key, a `name` that is blank
  or carries whitespace, a control byte or a byte that is not UTF-8 or runs
  past 256 bytes -- one rule with the shape an id must have, so a row an
  adapter writes is a row the loader reads back -- a file-level `backend`
  naming no adapter, a byte order mark, a second `[[bootstrap]]` row for one
  backend, and two rows naming one package under the same gate, and a zypper
  row naming a pattern, patch, product, source package or application rather
  than a package, which `rpm` could never report back. `doctor` notes a file
  in the private layer's `data/` that is not a data source, since nothing
  applies it.
- `zig build test-backends` checks the brew adapter against the real brew,
  differentially; `tests/linux_backends_test.sh` runs apt, dnf, zypper and
  pacman through a full install round trip in containers;
  `tests/windows_backends_test.ps1` probes scoop and winget read-only where
  present and, on a runner without scoop, bootstraps it from the pinned
  installer and installs one app; the Linux suite also bootstraps Homebrew
  in a Debian container. All three run nightly or on demand, and the Windows
  one runs on every push too: a schedule fires only from the default branch,
  so the branch that changes those adapters was the one branch it never ran
  on. A manager the runner does not supply is a skip and fails the gate,
  except winget, which no runner image provisions and mox declares no
  installer for: a winget that will not answer `winget --version` under a
  bound is reported n/a and fails nothing, while one that answers is gated
  like any other.

### Changed
- BREAKING: `status --json` emits `{"files":[...],"packages":[...]}` rather
  than an array, and `--porcelain` adds `package_missing` and
  `package_untracked` records of three fields; field count now varies by the
  leading kind. Package drift counts toward the exit code as file drift does.
- `status` and `commit` execute repo code they did not before: a backend
  plugin's `available`, `list`, `id`, `limitation` and (for `commit`)
  `declare`; each plugin is named by path in the report first.
- A bad `MOX_SCRIPT_TIMEOUT_MS` value warns as `mox: ...` rather than
  `mox apply: ...`, since every command now reads it. Diagnostics hold
  1 KiB instead of 200 bytes and end a message that still does not fit with
  `...` instead of cutting it silently.
- `mox commit` skips a manifest file whose own `when` excludes this machine
  when it looks for somewhere to record a package row: a row appended there
  would never be desired on the machine that recorded it. A blacklist row
  goes to an ungated file, and commit says so rather than writing one the
  next command would refuse. A diagnostic that names two files says which
  layer a private file is in, and one about a row names that row's place in
  its array.
- A setup script and a `check` hook each lead their own process group, so a
  bound reaches what the script started rather than the script alone: an
  orphan holding mox's stdout would keep a `mox apply | ...` pipeline open
  long after the run. A setup script is handed the terminal for its run, the
  way a streamed install is, so a `sudo` in a pre-script can prompt, Ctrl-C
  goes to the script, and Ctrl-Z suspends it; one that stops waiting for a
  terminal the run does not have (`mox apply &`, a CI job) is ended and
  named rather than waited out to the bound. Every child mox waits on itself
  is waited on the same way, so a captured query or a `check` hook that stops
  -- anything reaching for `sudo` from a background process group -- is ended
  at once instead of sitting out its bound, or forever where the bound is
  disabled -- a captured child is read from rather than waited on, so it is
  asked what it is doing between reads. mox answers SIGQUIT as it answers
  SIGINT, SIGTERM and SIGHUP: Ctrl-backslash takes the child's group with it
  rather than leaving it running.
- The report a run closes with leads with the count the exit code is made of,
  so the line and the code cannot disagree, and then names what needs
  attention, by label, before what does not; the package section closes the
  same way. The count a `status` leads with is the files, and the packages add
  their own. A row whose manager this machine cannot use contributes nothing
  to any of them, gated rows included, which the help had promised in wider
  terms than it could keep.
- `mox upgrade`'s help no longer names a specific repository: it fetches from
  the release the running build was built to look for.
- A plugin gets the setup-script environment, every fact as `MOX_FACT_*`
  included, and never the fact contract that goes with it: its text is not
  scanned, no fact is asked for on its behalf, and no run is blocked for one
  it lacks. A plugin is any executable, a compiled one included, so there is
  no text mox may rely on having, and a check that held only for the plugins
  written in a scripting language would read as coverage while skipping the
  rest. A plugin that requires a fact tests for it in `available` and exits 1,
  saying why on stderr or through `limitation` -- it is the one judge of
  whether it is usable on a machine. Said in the guide, which promised the
  environment and left the rest to be inferred.
- `commit` refuses a structured edit that changes anything outside the key
  it writes: an edit to a YAML value that anchors aliases elsewhere fails.
- `commit` leaves manual an edit that adds new `<...>` text to a string
  field carried by a bare capture.
- `commit` leaves a row edit manual when the loop's rows up to the edited one
  differ from the last apply (a row changed, added or dropped, the template
  changed, the data source shadowed by the private layer) or the edited
  row's text repeats in the loop; a row committed beside a held hunk is
  manual until the file is re-applied.
- In a file with a loop or with lines from more than one source, `commit`
  routes only changes every shortest line diff agrees on: a change touching
  a line shaped like a loop row is held unless it replaces one row line with
  one line, other non-row changes in that file are held with it, a change
  that could move a line between the private layer and the repo holds every
  non-row change, a row edit is manual when the row renders elsewhere in
  the file unchanged, and a file whose line counts multiply past 2^24 holds
  every change. Coupled renames are found in each routed region as merged,
  and a region mixing private-layer and repo lines is never offered for a
  split.
- `commit` refuses a key edit to a file merged from layers together with any
  line, row or fact edit to the same file (a `d` default rewrite included,
  hard links too), even on other lines, and two `d` default rewrites of one
  fact to different values, although each could land alone.
- A coupled rename is dropped when its old token is in a data row a routed
  row write renders from, or in a directive line or template of a loop or
  generator source whose row write was routed.
- A row edit writes only the fields whose value changed, each in its stored
  TOML type, keeping key, spacing and trailing comment, instead of rewriting
  every captured field as `key = "value"`.
- A unit owning an edit to a source restored because another unit failed,
  and a unit with an unrouted hunk, are not committed. Declined-only files,
  final-newline differences and every file `commit` skips with an edit
  exit 1.
- `commit` shows a live path as `~/...` in the messages that printed it
  absolute: failed verification, unrouted hunks, hunks left only in the
  live file, the notice before a narrowing prompt, a key no layer can hold,
  partially owned files, secret-bearing files and symlink target changes.
  Generator-leaf and symlink prompts name the path relative to home, as
  file prompts do.

### Fixed
- `commit` applies an identical edit once. A fragment included twice in a
  file and edited the same way in both places produced two identical
  edits, both applied, so a deleted line took the next one with it and the
  file failed as "recomposed output still differs from live".
- No non-interactive `commit` adopts content mox never wrote. A
  first-contact line already needed a human, but under `--yes` a
  first-contact file merged from layers had each key routed unasked, one no
  layer matches on this machine had an overlay created for it, a generator
  leaf had its row written into the data source, and a symlink had its
  target kept into the source. Each is now `first contact, needs
  confirmation`, `--dry-run` says so instead of promising the write, and the
  run exits 1.
- `commit` no longer reports "the edited sources no longer compose" for a
  file it wrote nothing to. A file whose every change stayed manual or
  declined, and whose source composes to nothing on this machine, was
  reported as broken by the routing and had its sources restored; it is now
  reported as its changes remaining only in the live file.
- The section merge for a layered `.ini` file matches headers as the ini
  dialect reads them. It trimmed a section name, so `[ s ]` in an overlay
  replaced keys of `[s]` in the base, and it kept the case of a quoted part,
  so `[foo "bar"]` did not replace keys of `[foo "Bar"]`; commit read each
  pair the other way, so an edit to a key an overlay supplied could go to
  the wrong layer, and a capture in the overlay's value could go unseen.
  `[ s ]` and `[s]` now compose as two sections, and `[foo "bar"]` replaces
  keys of `[foo "Bar"]`.
- `commit` refuses an edit under a key, table or section of a file merged
  from layers whose name holds a capture, such as
  `[includeIf "gitdir:<machine.home>/work/"]`. Live holds the resolved name,
  which no source layer defines, so the edit was taken for a new key and
  written into the base under that name; it is now manual as named by an
  interpolation capture. A key the user adds beside such a key, which this
  machine's composed output did not have, is still taken for a new key.
- A key `commit` routes into a file merged from layers must recompose to its
  live value even when another change in that file stays manual or
  declined. Such a file was excused from matching live as a whole, so a key
  routed to the wrong place was never checked: a table or key named by a
  capture was written into the source under its resolved name, and the file
  was reported committed. Any routed key that does not recompose to its live
  value now restores the file's sources.
- `commit` refuses an edit that leaves the file unable to compose in any
  configuration that composed it before, including one the edit was allowed
  to change. The check for an allowed configuration stopped at whether it
  was allowed, so a coupled token update that made a source unparseable on
  other machines was committed.
- A coupled token update reaches a source gated off this machine. Such a
  source composes to nothing here, before the update as after, but that was
  taken for the update breaking it, and a sync counted as universal only if
  it changed every other configuration, including those the file does not
  exist in. The rename was refused, so a token never synced into a file
  gated to another machine.
- A file `commit` does not commit has a coupled token update to its own
  source undone with the rest. Only sources an edit was routed into were
  saved to be restored, so a token synced into an edited file stayed
  written when that file was then refused, even when it left the source
  composing to nothing.
- `commit` finds every capture compose could expand in a value of a file
  merged from layers, including one inside a literal `<...>`. A value such
  as `Me <<machine.email>>` was taken for plain text, so an edit to it wrote
  the resolved value into the source and the capture was lost; it is now
  manual as interpolation-derived. A `<name | default "x">`, which compose
  leaves as text, is no longer taken for a capture, so an edit to such a
  value routes.
- `commit` checks the source around an insertion before routing it. An
  insertion replaces no line, so nothing confirmed that the source still held
  what the hunk was diffed against: after the source changed since the last
  apply, the new lines were placed at a stale position and only the
  recompose check that follows rejected the file, as "recomposed output
  still differs from live" with no hunk counted manual. The lines on either
  side of the insertion within its span must now match the source, a
  captured value matching its template, or the hunk is manual with its
  reason.
- Region nesting is counted by each directive's first word as the parser
  reads it. An opener written with no space after its verb, such as
  `when(os=darwin)`, parsed as a region but was not counted as nesting, so
  the enclosing region closed at the inner `end`: the lines after it escaped
  their gate silently when the enclosing gate ran to end of file, and
  otherwise the file failed on an unmatched `end`.
- An `end` followed by other text, such as `end # note`, is refused, naming
  its line. It was read as body content, so the enclosing region ran on to a
  later `end`, swallowing the lines between, or, with none, became a gate to
  end of file. This includes such a line inside a literal `replace`,
  `append`, `prepend`, `remove` or `from` body, which was emitted as text.
- A malformed directive in a file whose head carries `own`, `disown` or
  `check` is named by its line in the source file; the count skipped the
  head lines.
- The ignore files find their regions with the marker and nesting rules
  compose uses. A gate written with a tab between `#` and `mox:` was never
  composed, so its rules applied on every machine; such a file whose
  `mox:` line is not a directive is now refused, as the same line with one
  space already was. `doctor`, which looks for rules that apply on every
  machine, counted as one a rule inside a `for`, `remove`, `from` or gated
  `replace`, or under a gate spelled with a tab, extra spaces, or no space
  after `mox:`; and it missed a rule the body of an `append`, `prepend` or
  plain `replace` emits everywhere when a `when` line sat above it in that
  body, where compose emits the line as text.
- A lock names its holder by the process that took it, recorded as the time
  that process started -- from the kernel's process table on macOS, from the
  process's own stat line on Linux -- so a later run can tell a holder still
  working from one a reboot left behind. The marker was the machine's boot
  wall-clock time, which macOS moves whenever the clock is disciplined,
  observed changing twice in one session with no reboot: a run whose lock was
  written before such a step was judged to belong to a dead machine, so a
  second run took the lock while the first was still working, and each then
  deleted the other's.
- `apply --dry-run` reports what it would do rather than what it did. The
  count of files written reached the report whether or not any were, so a plan
  said it had applied the files it was only describing. A dry run also
  proposed every symlink afresh and counted each as a write, answering before
  working out whether the link already pointed where it was meant to; it asks
  the question the real run asks, so a plan and a `status` of the same machine
  agree.
- A source fragment is private when it sits under the private root, not when
  its path merely begins with the same letters. A repository whose own root is
  a sibling of that root -- a directory whose name extends it -- had its
  ordinary files read as private ones. Nothing private escaped that way, since
  a real private path always carries the separator the test was missing, but a
  shared fragment taken for private loses the offer to place its edit, and the
  sync that carries a rename into the sources coupled to it was skipped
  without a word. The question is answered in one place now, the module that
  owns what a path means here, which the commit path already reached.
- A staging file goes with the write that failed. It was removed when a
  permission check or a recheck failed but not when the write or the rename
  did, so what an interrupted write left behind stayed beside the file it was
  meant to become. A staging path carries its own writer's name, so no two
  writers share one entry.
- `export` resolves a path it is given the way every other path argument is
  resolved, rather than taking a leading tilde literally and making a
  directory of it.
- `diff --help` says what its exit codes mean, since a difference is not a
  failure but a refusal is.
- The timeout watchdog for setup scripts and check hooks runs on its own
  thread. On a host with one CPU it could run inline, sleeping out the
  whole bound before the wait began and then reporting every script as
  timed out. Where no thread can be had for it, the wait is unbounded
  rather than the child unreaped.
- A private layer's `data/` is data, not source. It was walked as a source
  tree, so a private data file was planned as a managed file at `~/data/...`
  and a symlinked one failed the run.
- `doctor`'s unknown-stage message named only `pre/` and `post/`, though
  `check/` hooks and `backends/` plugins are run too.
- `update --help`'s description says `--no-apply` stops after the rebase,
  agreeing with the flag's own line and both guides; it said the fetch.
- A whole-file gate on a TOML, JSON, YAML, INI or gitconfig source scopes the
  rest of that file without disabling it. A held gate diverted the file past
  the directive path, so every further directive under it went unread: its
  `when` and `for` lines reached the live file as content, and the bodies they
  were meant to select landed unconditionally. The same file without the gate
  composed correctly, and the text categories always read the gate as the
  region it is. A gate that does not hold still makes the file absent.
- A capture written in a `.d/` overlay of a TOML, JSON, YAML, INI or gitconfig
  source is a fact the interview asks for. Discovery read an overlay's
  filename and never its content, so a `<machine.NAME>` there was interpolated
  at compose time yet never asked: alone it failed the file with an unknown
  machine field no interview could bind, and inside a fallback chain it
  resolved silently to the next member. The overlay's own filename tuple
  conditions the ask, exactly as it conditions the merge. An overlay of a text
  or binary source is unaffected, since compose expands neither.
- An axis-named `.d/` file beside a source that can never fold one in is
  refused instead of silently dropped. A `.d/os=darwin.sh` beside a text
  source was enumerated as an overlay and then read by nothing: the file
  composed from its base alone, the whole layer vanished with no output
  change and no diagnostic anywhere, and the same tuple beside a structured
  source merged as written. Text has no layer to merge into and no whole-file
  pick, so that layer is refused with `OverlayOnTextFile`, naming it; vary
  text per machine with a region directive and its `<name>.d/<region>/`
  fragments, or a `when` gate. A generator source (`for ... into`) refuses one
  the same way in every category, with `OverlayOnGenerator` -- its own path
  never materializes, so nothing beside it has anything to compose into, and a
  structured generator dropped its overlays just as silently. Neither refusal
  depends on the overlay matching the machine composing.
- An overlay or region-fragment filename whose value carries a dot offers both
  of its readings at the interview. Compose matches `.d/zone=eu.local` as the
  whole written value first and as the extension-stripped `eu` second, but
  only `eu` reached the observed set: the prompt suggested a value that
  selects nothing, and answering the one that does drew an "is not among
  zone's observed values" confirmation. Both readings are recorded, as the
  axis scan behind the config space already recorded them.
- A setup script inside a `scripts/<stage>/<tuple>/` gate directory is asked
  about only where that tuple holds. Its `# mox: needs` names and its own
  `# mox: when` head were contributed unconditioned, so a fact reachable only
  through a gated script was asked on every machine. The gate directory's own
  tuple is now a value comparison in its own right as well -- it registered
  nothing at all before, so a fact named only by a gate directory was never
  asked, leaving a gate that could not open and a script that never ran.
- A fact a script declares with `# mox: needs` is asked wherever that script
  runs, even where `src/` uses the same fact only behind a gate. Once anything
  in `src/` had made the name real, the declaration contributed no occurrence
  at all and the narrower `src/` condition stood alone: on a machine whose
  gate is closed the fact was never asked, and the script that declared it --
  ungated, so the runner still reached it -- blocked on a fact no interview
  had offered to bind. A declared name
  is an occurrence like any other now, asked under the script's own gate
  directory, or unconditionally at a stage's top level, OR'd with every other
  use of the same fact.
- A fact a script consumes through a scanned `MOX_FACT_*` token, declaring no
  `# mox: needs` head, is asked wherever that script runs. Only a declared
  need widened the asking condition; a scanned one contributed no occurrence
  at all, though discovery already reported the script as needing the fact and
  the runner already blocked the run on it. An ungated script reading
  `$MOX_FACT_OP_ACCOUNT` for a name `src/` captures only behind
  `when profile=work` left a machine on another profile with a fact the
  interview never offered, `mox status` never listed, and apply refused to
  proceed without. A scanned token is now an occurrence like a declared name,
  asked under the script's own gate directory, or unconditionally at a stage's
  top level. It never registers a new fact the way a declared name does: a
  token is matched text, and the projection onto it is one-way, so one
  matching no known fact still blocks its script rather than becoming an
  interview question for a fact that may not exist.
- Recorded provenance names the source line a composed line actually came
  from. The leading-block pass takes a structured source's ownership and
  `check` lines out of the text before it is composed, and a held whole-file
  gate's own line with them, and the recorded base-line numbers counted the
  shortened text: every number below a removed line was short by the lines
  removed above it. `mox commit` routes a live edit by those numbers. A
  replacement was caught by the text comparison the router makes before
  writing and became a manual hunk, but an insertion carries no old text to
  compare against, so it was written a line too early and only the recompose
  that follows the write caught it -- as "recomposed output still differs from
  live", a refusal naming nothing the user could act on. A line the pass
  separates from its neighbour now ends a run of numbering rather than
  extending it, so the numbers name the lines the file has. The same
  numbering reaches a structured file carrying an inline `<secret:URI>`,
  whose lines are recorded one at a time so only the secret's own line is
  redacted: each of the others claimed to come from line 1, which left every
  hunk of such a file unroutable.
- A layer carrying an inline `mox:` directive beside a structurally merged
  source is refused on every machine, which is what that refusal has always
  said it is. The scan ran after the composing machine had already decided
  the file was absent -- its whole-file gate closed, or no overlay of a
  base-less source matching -- so one repository was refused on one machine
  and composed nothing, quietly, on another. The scan runs first now. A closed
  gate's own line is not itself taken for the inline directive it resembles:
  the gate line comes off the scanned text whether or not the gate holds.
- A plugin cannot open the recursion guard it runs under by emptying
  `MOX_PACKAGES_DEPTH`. The marker was read the way a path is read, where an
  empty value means unset, so `MOX_PACKAGES_DEPTH= mox status` from inside a
  plugin put that mox at the top of the chain: it discovered the same plugins
  and ran each of them again, and so did every mox below it, with nothing in
  mox left to stop the chain -- killing the run at the top did not end it,
  since each level below leads its own process group. The marker is read for
  presence now, so an empty value says what `0` and `yes` already said, and
  the run below is told there is one more mox above it.
- `--help` sends a reader to `docs/commands.md` for the full contract of
  every command, which is where the contracts are; it named the README,
  which is an overview and defers them to that file. Its line on
  `MOX_PACKAGES_DEPTH` says that an empty value counts like any other.
- `commit` exits 1 while anything is left undone. A run whose every hunk was
  reported manual exited 0, though the same state exited 1 under `--dry-run`
  and 2 under `--abort-on-prompt`, and `mox status` went on reporting the
  drift that run had left behind. The code answered whether a file had failed
  to verify rather than whether work remained, so a wholly-manual run passed
  and adding one routable hunk to it was what turned the 0 into a 1. A manual
  hunk now reads in a script the way a skipped secret and an untracked package
  already did, and the documentation no longer tells a script to parse a
  printed count instead.
- A first-contact hunk needs a human in every non-interactive mode, and
  `--dry-run` predicts that refusal rather than the route it is refusing. The
  report called such a hunk routable and announced the edit it would make,
  while the `--yes` run it was predicting called the same hunk manual and
  wrote nothing. The refusal also reached only part of the run: a shared line
  in a file expressing more than one configuration went to the "where does
  this belong?" question, whose default `--yes` took unasked, so a `--yes`
  commit of a file mox had never written could rewrite that file's source
  unseen. One path now answers for both, so the preview and the run agree by
  construction.
- A plugin whose `declare` verb fails is reported in the same words every
  other backend failure is reported in. `commit` printed the internal error
  name -- `declare failed: PluginFailed` -- where a sentence for that failure
  already existed and every sibling call already used it.
- `commit` routes a loop hunk to the line's own data row. A row added since
  the last apply, a row rendering several lines, or rows rendering the same
  text sent the edit to another row, reported committed; each is now manual
  with its reason.
- `commit` treats a generator leaf whose data changed since the last apply
  as stale: an unedited one has no drift, an edited one is manual, instead
  of routing the old value back into the data source.
- A row edit reaches the row whatever the loop variable is named; only
  `entry` was recognized, and the unit failed with no reason given.
- A row edit ends at the next table header of any kind and ignores lines
  inside multi-line strings, arrays and inline tables; a following
  `[table]`'s same-named field, or a line inside a value, was rewritten.
- A row edit no longer replaces a stored capture with this machine's
  expansion, turns integers, booleans and arrays into strings, drops the
  rest of a multi-line value, or mis-decodes `\` and `"`.
- A row edit is not moved onto another row by a line edit in the same data
  file that adds or removes a table header above it.
- A loop line whose edit fits more than one split into fields is manual;
  the leftmost split could write a field the user did not edit.
- An edited loop row that the line diff paired with a nearby equal line, and
  a literal line paired with an equal line of another source, are held; the
  edit was written as a literal line or into a source the user did not edit,
  the private layer's lines into the repo included.
- A row edit whose row also renders elsewhere in the file is manual unless
  that rendering was edited the same way; the other rendering changed at the
  next apply.
- Two routed edits that overlap and differ -- one data row through two loops,
  overlapping line edits, a row edit beside a line or key edit to the same
  field, one fact set two ways, one symlink source given two targets -- no
  longer overwrite each other with both reported committed; the later is
  manual, naming the first.
- A coupled rename no longer rewrites the old token inside a line another
  unit routed, or inside the directive or template a routed row edit was
  checked against.
- Coupled renames into one file apply in one pass, so `foo -> bar` and
  `bar -> baz` in one run no longer turn `foo` into `baz`; two new names for
  one token are both dropped with a warning.
- A coupled rename into a path that matches no managed file is dropped with
  a warning; it was written with no backup and no verification.
- A coupled rename into a generator source, or one leaving its target
  unable to compose here, is reported undone instead of aborting the run
  after the prompts.
- A coupled rename whose origin or target is not committed is undone and
  reported with its cause, not counted; a target shared by two origins no
  longer loses one origin's update silently.
- Nothing is recorded until every unit is settled. A later unit's failure
  could restore a data source, base or fragment under a unit already
  recorded committed, and the next apply discarded its live edit; every
  unit with an edit to a restored source now fails with it, held hunks
  included, naming the cause.
- A failed symlink restores only its own source, and generator leaves are
  settled with the files that share their data source rather than as a
  batch.
- A fact reverted because its unit failed re-verifies every unit that read
  it; those passing only under the new value are not committed.
- A unit with a hunk that could not be routed where the user chose is not
  committed, even beside a manual hunk.
- A source reached through two spellings, such as a symlink or `./`, is one
  file: it was backed up and written twice, the later write clobbering the
  earlier.
- A write that fails restores every source the run wrote and records
  nothing, exit 2; earlier writes stayed on disk unverified. A source that
  cannot be read before writing stops the run with nothing written.
- A restore that fails no longer loses the pre-run bytes: they are copied to
  `<state dir>/commit-recovery/<timestamp>/` and each path is named.
- A temporary write made to check a route is restored with the same
  guarantees, under `--dry-run` too, and leaves no empty `.d/` behind.
- `commit --dry-run` checks a key's placement as `--yes` does, for single-
  and multi-configuration files, so a key no layer can hold is manual in
  the preview instead of failing at write. The preview runs the same row
  checks, conflicts, coupled renames and parse-back as `--yes`, and reports
  the same manual, not-committed and undone lines.
- `commit` exits 1 when a file is left undone: its source yields no file
  here (a secret-bearing file included, now reported like any other), every
  hunk was declined, it differs only in its final newline (reported
  `manual: <path>: final newline differs`), a generator fails to re-expand,
  a recorded path holds a special file (reported `manual: <path> (not a
  regular file)`), or a file skipped for a head declaration that cannot be
  read was edited since it was last recorded. A special file at a path
  never recorded is skipped with exit 0.

## [0.11.0] - 2026-09-09

### Added
- `export --facts <path>` composes against a facts file instead of the
  machine's own; a missing, unreadable or malformed file is refused naming the
  file, and a row that binds nothing (not a string, or naming a machine axis:
  os, arch, machine, hostname) is reported by name and reason, for the
  machine's own file too. An unreadable `data/facts.toml` is named as such
  rather than as the file `--facts` named. `export --as hostname=<name>` binds
  `machine` to the name's first label unless the tuple binds `machine` itself,
  as a real machine does, and a hostname with no label before its first dot is
  refused. A facts file behind an unreadable directory, or one over 64 KiB, is
  named for what it is rather than as missing or by a bare error name, `apply`
  names the machine's facts file the same way, and an unreadable
  `data/paths.toml` is named as itself.

### Changed
- `mox facts` no longer lists a row naming a machine axis (os, arch, machine,
  hostname), which never bound anything, and `facts set` refuses such a name;
  `apply` and `facts` report a row that binds nothing in one wording, the
  reason before `ignored`.
- BREAKING: `export` refuses to bake any resolved secret (`env:`, `file://`
  and `cmd:` included) without `--cleartext-secrets`; a secret-manager value
  lands at 0600 unless `.mox/attributes.toml` sets its mode, any other at the
  file's composed mode, and the report says how many of each.
- BREAKING: a structurally merged source (`.toml`, `.json`, `.yaml`, `.yml`,
  `.ini`, gitconfig with `.d/` overlays) carrying an inline `mox:` directive
  in any layer, base or overlay, matching the composing machine or not, is
  refused with `InlineDirectiveWithOverlay`, naming the layer and the line as
  written, and a layer that cannot be read is named the same way; a merge
  would emit a region's body unconditionally and drop a `secret` or `default`
  as a comment. `apply` and `export` explain a compose failure the same way.
- BREAKING: `doctor` exits 1 while any advisory remains or a check could not
  run, not only on problems, so it can gate CI; `--help` states the codes.
- BREAKING: `apply` exits 2 on a stage file it cannot spawn, a gate directory
  it cannot read, or a subdirectory named like a tuple that is not one, in a
  closed gate as in an open one; a closed gate's contents went unexamined
  before.
- BREAKING: `export` exits 2 on any failure to compose or write; it exited 1.
- BREAKING: a bare `publish` refuses only when a path mox owns is dirty,
  naming those and any stray beside them; strays alone are reported and the
  push goes ahead, as with `-m` (any dirty path refused before).

### Fixed
- `update --no-apply` is described as stopping after the rebase, not the
  fetch, in its flag list and both guides: the source tree is brought
  current, only the live files wait.
- Secret backends run under the environment mox was given, not the process's
  own, and the backend program is looked up on that environment's PATH,
  passing over a directory or an unrunnable file of its name the way a shell
  does. `mox edit` spawns the editor and `mox init --clone` spawns git under
  that environment as well.
- `export --as` reads its tuple verbatim: a dotted value such as
  `hostname=studio.local` no longer loses `.local` as if it were an extension,
  and a value that once read as a filename with an extension now binds as
  written.
- `edit --axis` reaches an overlay whose axis value carries a dot the way
  compose does (the verbatim reading first, then the extension-stripped one),
  the path reported for a missing overlay carries the base's extension, and a
  missing fragment is reported by the directory it would sit under; a file
  that has both overlays and regions is told that both were looked for when
  neither matches.
- The docs no longer name a `--force` alias `apply` never had, `apply --help`
  no longer names `--overwrite` as its own alias, and `rollback --help` says
  its id is optional.
- Setup scripts and check hooks find the running mox first on PATH, through a
  state directory that holds only it (anything else found there is removed,
  and a directory that cannot be made, opened or read is reported and the run
  goes on); it stays ahead of what `$MOX_PATH` adds (a directory already on
  PATH is moved to the front, not repeated), and the warning for a bin
  directory that cannot be made prints once per run; a dry run, which spawns
  nothing, leaves the directory as it is, and rollback touches it only when a
  check hook runs.
- `commit` no longer crashes on a first-contact structured file whose live
  copy holds no keys; it is nothing to commit.
- `commit` refuses a fact value that cannot name an overlay (a path separator,
  `=`, the `+` pair separator, a trailing dot or a Windows device name) in a
  narrowed region's fragment as in a first-contact overlay, instead of writing
  outside the repo or a file no later command can read; the refusal, like
  every manual outcome, leaves the edit reported as uncommitted at exit 1;
  reading such a value from an existing overlay's name stays as it was.
- `doctor` reads the source tree's own git status under the environment mox
  was given, and a repository enclosing a repo that is not a git working tree
  no longer answers for it.
- The installers name the aarch64 Windows asset, replace the binary
  atomically, stage the download under `TMPDIR` and clean it before handing
  over, refuse a directory at the target and leave no staging file behind, and
  install.ps1 passes the bootstrapped command's exit code through without
  closing an interactive session; a PowerShell installer suite runs on the
  Windows CI leg, both installer suites gate a release too, and the README
  names the digest tool the installer needs.
- `apply` reports every script a closed gate directory skipped, in directory
  order, reads a gate directory's tuple verbatim so a dotted value such as
  `profile=work.v2` gates the machine bound to it, fails a gated directory it
  cannot read instead of aborting the run, names a non-executable file in a
  closed gate as it does in an open one, and names a subdirectory whose name
  carries an `=` but is not a tuple instead of dropping it silently; OS noise
  such as `.DS_Store` in a stage is passed over, by `doctor` as by `apply`,
  and `doctor` reads a gate directory's name the same way and reports one it
  cannot read.
- `export` reports a missing or unwalkable source tree with the same
  diagnostics as `apply`, documents its exit codes, and notes an `--as` value
  no source names, since every gate on that axis then closes (a presence test,
  a negated comparison or a private-layer source counts as naming it).
- `publish` and `update` read `git status` unquoted, so a path with non-ASCII
  bytes or spaces is staged; `publish -m` commits by the paths it staged, so a
  stray the user had staged beforehand stays staged and out of the commit, as
  the report says; `publish --help` and the usage guide describe what a bare
  `publish` does with strays.
- The docs state all three empty-render exemptions, that a repeated `--as`
  axis takes its last value, that a `$MOX_PATH` directory already on `PATH`
  moves to the front rather than appearing twice, and that `--facts` replaces
  only the machine's own facts file while derived facts and tool probes still
  resolve on the running machine.

## [0.10.0] - 2026-08-12

### Added
- `docs/commands.md` carries each command's flags in a table beneath it,
  rendered from the same declarations `--help`, shell completion, and
  `__schema` are derived from. A test re-renders every table and fails when
  one disagrees with argv, printing the block to paste -- so a flag added,
  renamed, or dropped cannot leave the reference describing a command that no
  longer exists. It also refuses a table for a command that is gone, which is
  the drift that actually misleads. The prose stays hand-written: a
  declaration can say a flag exists, never what it means.
- `mox publish` sends this machine's work the other way: with `-m <message>` it
  commits the repo's pending source changes and pushes them, without it pushes
  what is already committed. It stages by explicit path -- only `src/`,
  `data/`, `scripts/`, `.mox/`, and `.moxignore` -- never a blanket `git add
  -A`, because a dotfiles repo is exactly where a stray note or a pasted
  credential ends up; anything dirty outside those paths is reported and left
  to stage deliberately. It is a verb rather than `update --push` because
  outbound never defaults on: a wrong apply is snapshotted and reversible, a
  push cannot be recalled.
- `mox path` prints the repo directory as the sole line on stdout, so
  `cd $(mox path)` works, and `mox git -- <args>` runs git in the repo from
  anywhere with its output and exit code passed through. The repo lives under
  a data directory nobody stands in, and until now mox offered no way to reach
  it.
- `mox edit --apply` writes the edited file live once the editor exits, scoped
  to that one file. The inner loop is edit-then-apply and it cost two
  commands. `--apply` now means the same thing on `init`, `update`, and
  `edit`: and make it take effect.

### Fixed
- Every `git` mox spawns now runs under the environment mox itself reads
  through, rather than the raw process one. In production those are the same
  value, so a user's git config, signing, and credential helpers keep working.
  They differ when a caller hands mox a synthetic environment: such a run
  resolved mox's own paths from it while git read the operator's real
  `~/.gitconfig`, so a machine with commit signing enabled had mox's own
  commit block on a signing agent waiting for a human that a non-interactive
  caller does not have.
- `mox export` composes every file before writing any of them, so the secret
  gate decides before cleartext reaches disk, and a run that cannot compose
  every file reports them all and writes nothing rather than leaving a tree
  that silently lacks one. Composing stays a single pass: a second would
  resolve every `op://` secret again, costing another round trip and another
  biometric prompt.
- `apply` and `commit` refuse a repo left part-way through a merge, rebase,
  cherry-pick, or revert, rather than composing its conflict markers into live
  files and running setup scripts from a half-applied revision. The refusal is
  a marker-file lookup in `.git`, so it needs no `git` on PATH, costs no
  subprocess, and reads a repo that is not a git checkout as idle. It holds
  however the repo got there -- previously only the git half refused, which the
  `git pull` the docs offered as its equivalent walked straight past.

### Changed
- **Breaking:** `mox export --resolved` is now just `mox export`, and the
  cleartext gate fires on the hazard instead of on every run. `--resolved` was
  required on every invocation with only one legal value, which trains a user
  to type it unread -- the opposite of what a consent gate needs. The real
  hazard is narrower: export bakes resolved secrets to disk as cleartext. An
  export that would do so now names those files and refuses until
  `--cleartext-secrets` is passed, and a secret-free repo needs no flag.
- **Breaking:** `mox sync` is now `mox update`, and it applies. mox moves
  configuration along one line -- live file, source, remote -- and named only
  the local pair (`apply`, `commit`); `sync` was two directions crammed into
  one verb, reaching outward to a remote it was never asked to publish to and
  never inward to live files, so the machine it claimed to synchronize still
  held stale dotfiles when it finished. `update` is the inbound edge end to
  end: fetch, rebase, apply. `--no-apply` stops after the fetch for a
  `mox diff` first; `--no-pull` and `--no-push` are gone with the halves they
  gated, and publishing is `mox publish`.
- **Breaking:** `update` rebases rather than fast-forwarding. The same repo
  edited on several machines diverges as a matter of course, and `--ff-only`
  handed that back as a manual rebase every time. Only commits absent from the
  upstream are replayed, so published history is never rewritten; a conflict
  stops mid-rebase, which `apply` and `commit` now refuse until it is resolved
  or aborted. No `--autostash`: a dirty tree is refused before the fetch.
- **Breaking:** `update` uses `apply`'s exit contract -- 0 clean, 1 drift left
  for a decision, 2 a refusal or failure. Refusals moved from 1 to 2 so a
  caller never has to ask which phase produced the code.
- **Breaking:** `mox data get <name>` is now `mox data <name>`, and
  `mox snapshot list` is now `mox snapshot`. Each group had exactly one
  subcommand that removed no ambiguity, and bare `mox snapshot` already
  listed snapshots identically.
- **Breaking:** `apply --force` is gone; `--overwrite` is the only spelling.
  It was a redundant alias on apply while meaning something unrelated on `add`
  (bypass an ignore rule). Every diagnostic that said "re-run with --force"
  now names `--overwrite`.
- `mox rollback` with no id restores the newest snapshot, announcing which one
  it took. Undoing the apply just run is the case that matters, and it
  required reading an id back out of another command.

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

[0.12.0]: https://github.com/sakakibara/mox/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/sakakibara/mox/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/sakakibara/mox/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/sakakibara/mox/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/sakakibara/mox/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/sakakibara/mox/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/sakakibara/mox/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/sakakibara/mox/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/sakakibara/mox/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sakakibara/mox/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sakakibara/mox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sakakibara/mox/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/sakakibara/mox/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/sakakibara/mox/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/sakakibara/mox/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/sakakibara/mox/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/sakakibara/mox/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/sakakibara/mox/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sakakibara/mox/releases/tag/v0.1.0
