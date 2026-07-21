# Ignoring files

mox never manages a file unless you `add` it -- but `add-tree` and a scaffolded
starter repo both want a way to say "never even offer this one," the way
`.gitignore` does for git. An **ignore rule** is that: a repo-scoped,
gitignore-syntax pattern that keeps a path out of mox entirely.

## Where rules live

Two optional files, both repo-scoped (there is no per-directory or global
ignore file):

- `.mox/ignore` -- namespaced alongside mox's other repo state.
- `.moxignore` -- at the repo root, the conventional name.

Either or both may exist; a missing file contributes nothing. When both exist
they are merged, `.mox/ignore` first and root `.moxignore` last, so a rule in
`.moxignore` wins a tie over one in `.mox/ignore` under gitignore's
last-match-wins semantics (see below).

## Syntax

Each line is a gitignore-style pattern, matched against the **home-relative**
path of the live file (`.claude/.credentials.json`, not an absolute path):

- `#` starts a comment; a literal leading `#` is written `\#`. Blank lines are
  skipped.
- `*` matches any run of characters except `/`; `?` matches one character;
  `[...]` matches a character class (`[a-z]`, and `[!...]` / `[^...]` to
  negate).
- `**` matches zero or more path segments, so `.claude/**` covers everything
  under `.claude` at any depth, and a pattern that starts or ends with `**`
  spans left or right accordingly.
- A pattern containing no `/` matches a basename at any depth (`*.jsonl`
  matches `.claude/projects/x.jsonl`); a pattern containing a `/`, or an
  explicit leading `/`, is rooted at the repo root's corresponding
  home-relative position (`/CLAUDE.md` matches `CLAUDE.md` but not
  `sub/CLAUDE.md`).
- A trailing `/` makes the rule directory-only: it matches a directory but
  never a file of the same name.
- A leading `!` negates the rule, re-including a path an earlier rule
  ignored. Rules are evaluated in file order (namespaced file, then root
  file), and the last matching rule for a given path wins.

A directory rule also covers everything inside it: a file under an ignored
directory is itself ignored even though no rule names the file directly. A
rule that only matches a directory when checked as a directory (a trailing-`/`
rule) still reaches a file inside it through this ancestor check.

## Axis-gating

An ignore file is not a separate template language -- it is composed through
mox's own comment DSL, the same one that gates source files (see
[dsl.md](dsl.md)). Wrapping lines in a `# mox: when <axis>` / `# mox: end`
region makes them apply only on a matching machine:

```
.ssh/id_*
!.ssh/id_*.pub

# mox: when os=linux
.config/some-linux-only-secret
# mox: end
```

A plain file with no `# mox:` directive is used exactly as written, with no
comment-marker inference needed.

## What "ignored" means

The same check -- has this home-relative path (or one of its ancestor
directories) matched a rule -- applies everywhere mox touches a live path:

- **`add` / `add-tree`** refuse an ignored path rather than starting to manage
  it. `add` reports `matches an ignore rule; use --force to add it anyway` and
  exits 1; `--force` overrides the refusal for that one invocation.
  `add-tree` has no `--force`; it silently counts a matching file or directory
  as skipped and continues the walk (an ignored directory is not descended
  into at all).
- **`apply`** never composes or writes a tracked source whose live path
  matches; it prints `skipping <path> (ignored)` for each one.
- **`.mox-exact` pruning** -- a directory marked exact has its unmanaged live
  entries swept on `apply` so it mirrors the source exactly -- never deletes
  an ignored live entry, even under `--force`. If a foreign, unmanaged
  directory is not itself ignored but contains an ignored file somewhere
  inside it, the whole directory is refused rather than deleted around the
  ignored file.
- **`status` / `diff`** skip a tracked source that matches an ignore rule --
  there is nothing to report or compare, since it is never applied.
- **`doctor`** flags a tracked source that also matches an ignore rule as an
  advisory (`tracked-and-ignored`): the file is tracked in `src/` but will
  never be applied, a contradiction it asks you to resolve by removing one
  side or the other.

## The `mox init` scaffold

`mox init` writes a starter `.moxignore` guarding common credential
locations -- `.claude/.credentials.json`, `.ssh/id_*` (with the corresponding
`.pub` keys re-included), `*.pem`, and similar. Its header explains that any
line can be deleted, e.g. to track a secret in a private repo. The scaffold is
a plain, fully-editable file: mox places no other restriction on what you can
manage, and never refuses to manage a file that no ignore rule names.

## warn-on-add

Independent of ignore rules, `add` and `add-tree` print a non-blocking
`note: <path> looks like a secret and will be committed` when the file being
added has a name that looks credential-like (an SSH private key, a `.pem` or
`.key` file, a `.credentials.json`). This is advisory only -- the file is
still added -- since only an ignore rule actually blocks it.
