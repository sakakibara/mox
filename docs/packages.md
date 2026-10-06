# Packages

mox manages installed packages the same way it manages files: a manifest
declares what belongs on a machine, `mox status` reports the difference,
`mox apply` closes it, and `mox commit` records what you did by hand.

A repo with no `data/packages/` directory is not using any of this. No
section prints, no package manager is queried, and no exit code changes.
Creating that directory is what opts in, even before it holds a file: every
manager is then queried and what it has installed is reported UNTRACKED.
The first file is yours to create (`backend = "brew"` on its own is enough);
from then on `mox commit` fills it.

## The manifest

`data/packages/*.toml`, read from the repo and the private layer. Each file
is a mox data source: arrays of tables, the shape `data/completions.toml`
and `data/facts.toml` already use.

```toml
# data/packages/darwin.toml
backend = "brew"
when = "os=darwin"

[[packages]]
name = "ripgrep"

[[packages]]
name = "d12frosted/emacs-plus/emacs-plus@30"
when = "profile=personal"

[[packages]]
name = "ghostty"
kind = "cask"
```

A `[[blacklist]]` row holds on every machine, so it belongs in a file with no
top-level `when`:

```toml
# data/packages/shared.toml

[[blacklist]]
name = "usage"
backend = "brew"
```

Files are free grouping: `darwin.toml`, `fedora.toml`, a private
`local.toml`. A private file **shadows** a repo file of the same basename and
**adds to** the set under any other name, so machine-local packages live
beside the shared list without replacing it.

### Core keys

| Key | Meaning |
|---|---|
| `name` | The backend-native identifier. Required. |
| `backend` | Which manager. Per row, or once per file as a top-level default. Must name a registered adapter. |
| `when` | An axis expression, the same grammar as `# mox: when` -- os, arch, profile, tool, env. Per row, or once per file as a top-level gate on every `[[packages]]` and `[[bootstrap]]` row in it; a row's own `when` narrows the file's (`(file) and (row)`). A `[[blacklist]]` row takes no gate and may not sit in a gated file. |

A refusal names a `[[packages]]` row by its `name` -- `row "ghostty"` -- as
soon as the row has one that survives the shape rule below. A row with no
usable name yet is named by its position in its array, counting from zero
(`row 0 has no "name"`), and so are the two rows a duplicate refusal cites and
every `[[bootstrap]]` row; a `[[blacklist]]` refusal carries the position and
the name both.

Every other key belongs to the backend adapter (below). An unknown key, a
missing required one, or a wrong type is an error naming the file and the
row, checked on every machine rather than only where that manager runs. So
is a top-level key the format does not define (`[[package]]`, singular,
would otherwise load as no rows at all and report a clean machine), a `name`
that is blank, runs past 256 bytes, or carries whitespace, control
characters or bytes that are not UTF-8 -- one rule with the shape an id must
have, so a row an adapter writes is a row this loader reads back -- a second
`[[bootstrap]]` row for one backend, and two `[[packages]]` rows that name
one package under the same gate -- the last checked ungated, so a pair gated
to another OS is refused here rather than on the machine it breaks. A file
that begins with a byte order mark is refused by name, since the TOML parser
cannot read past it.

### Blacklist

`[[blacklist]]` rows are installed-but-never-offered: a one-off you do not
want tracked. They take `name`, `backend`, and whichever adapter keys
identify the package (a blacklisted brew cask carries `kind = "cask"`, or it
would name the formula instead). They take no `when` -- a blacklist holds
regardless of which machine is asking -- and for the same reason a file whose
top-level `when` would gate them is refused: put them in an ungated file.
`mox commit` writes a blacklist row into an ungated file that declares the
backend, and says so rather than writing one the next command would refuse.
Where every repo file is gated, the row goes to an ungated file in the
private layer: narrower than the gate the rule refuses, and narrower is what
that layer means -- the row holds on this machine and is in no other
machine's manifest to sit inert in. commit prints the layer it wrote to.

Declaring the same package in `[[packages]]` and `[[blacklist]]` is a
contradiction and is refused.

### Bootstrap

A `[[bootstrap]]` row names the installer for a manager that may be absent:

```toml
[[bootstrap]]
backend = "brew"
url = "https://raw.githubusercontent.com/Homebrew/install/<commit>/install.sh"
sha256 = "<hex>"
when = "os=darwin"
```

`sha256` is 64 hexadecimal characters, either case, and a value of any other
shape is refused when the manifest loads rather than on the one machine that
fetches, where a truncated paste is indistinguishable from a substituted
installer.

`backend` may come from the file default and `when` from the file gate, as
for any row, and is checked the same way: a row for a manager that ships
with its OS (apt, dnf, pacman, zypper, winget) is refused on every machine,
since there is no installer to run, and a row for a plugin this machine
cannot run is left to the machine that can. `mox apply` runs it only when
the row's gate holds and the backend's `available` says the manager is
absent: the file is fetched, refused unless it hashes to the declared
sha256, handed to the backend, and deleted afterwards whether the bootstrap
succeeded or not. brew and scoop know how to run their installers and where
the result lands, so the same apply installs packages through the manager
it just put in place. scoop looks there first: its installer puts the shims
directory on PATH by writing the registry and its own session, so a terminal
opened before the first apply never sees it and the next apply in that
terminal probes scoop as absent -- where a scoop that answers is adopted
rather than installed over, which its installer refuses anyway. A plugin runs
`bootstrap <path> <out>` itself, streamed
like an install, and writes the directory to put on PATH -- one absolute
existing directory -- as one line into `<out>`, if there is one. If a
bootstrap fails, the rows of that manager are not attempted and the run
fails.
An installer over 64 MiB is refused. `--dry-run` fetches nothing and plans
as though the bootstrap had happened, so what it lists is what the real run
would install, and `status` reports the rows of an absent manager that has
a bootstrap row as MISSING, with a note that apply will bootstrap it, rather
than as a clean machine.

## Backends

A backend is **registered** if mox has an adapter for it, and **usable** if
this machine can run it. A `dnf` row on a mac names a registered adapter that
is inert here; a row naming `dnff` is a typo and is an error. That
distinction is what lets one manifest carry every machine's packages.

Usable is decided by a probe (`<manager> --version`; `apt-get` for
apt). A manager that is not
there is absent and its rows are inert. One that is there but exits nonzero
is *broken*: `status` reports it as drift of its own (below) rather than as
a clean machine, and its rows are neither judged nor installed. When no
package manager at all is usable here, `status` notes
`no package manager is usable on this machine`.

| Backend | Identity | Explicitly installed | Row keys |
|---|---|---|---|
| `brew` | name; a cask is a separate namespace | `brew list --full-name --installed-on-request`, `brew list --cask --full-name`, both under `HOMEBREW_NO_AUTO_UPDATE=1`, so a read-only `status` never refreshes brew's cached API data on a timer (a cache that does not exist yet is still populated once), and with `HOMEBREW_NO_INSTALL_FROM_API` unset, since under it the listing clones homebrew/core on a machine that has never tapped it. The install runs under the user's own environment. The cask half is not an explicit-install query (below) | `kind` (`formula`, `cask`) |
| `apt` | name | `apt-mark showmanual`, intersected with what `dpkg-query` reports `installed`: a package an interrupted run left unpacked is listed as manual and is not on the machine in any usable sense, so its row reads missing and the install configures it. An install runs `apt-get update` first, so the index it resolves against is current | -- |
| `dnf` | name | `dnf -q --assumeno repoquery --userinstalled --qf %{name}\n` (`-q` because dnf4 writes its metadata line to stdout; `--assumeno` because dnf4 writes its key-import question there too, ending it without a newline, so the first name of the listing is glued to it; the format string because its default packs several to a line); the install and the mark carry `--setopt=assumeno=0`, since a dnf.conf `assumeno=True` otherwise outranks `-y` and aborts both | -- |
| `pacman` | name | `pacman -Qeq`; an install is one `pacman -Syu --needed --noconfirm` transaction with the rows as its targets, which upgrades the whole system, since a partial sync is not something Arch supports | -- |
| `zypper` | name | a mox-kept ledger (see below) | -- |
| `scoop` | name, compared without case; a bucket is provenance, not identity | `scoop export`, which is every app directory (below) | `bucket` |
| `winget` | `PackageIdentifier` | `winget export`, which misses what no source supplied and carries what nobody asked for (below) | `source`, `scope` (`user`/`machine`), `override` |

An export reports identifiers alone, so a package is one row: two rows for
one identifier under different scopes are a duplicate, not two packages.

scoop's namespace is case-insensitive -- it finds a manifest with a
case-insensitive filter and installs into a directory the filesystem compares
the same way -- so `FiraCode-NF` and `firacode-nf` are one app, one id, and
two rows spelling both are a duplicate. `mox commit` records the spelling
scoop reports, along with the bucket the app came from unless that is `main`:
without it, `scoop install` on a machine that has not added that bucket
aborts with "Couldn't find manifest".

An install through scoop adds a row's bucket only when `scoop bucket list`
does not already have it, and passes `--no-update-scoop`, since
`scoop install` otherwise updates scoop and git-pulls every bucket first --
a row declares presence, not currency. winget installs with `--exact` (`--id`
restricts the field searched, not the match type, and winget's default is a
case-insensitive substring match), `--no-upgrade`, and
`--disable-interactivity` plus `--silent`, since an apply has no terminal to
answer a prompt with and no time bound by default; a row carrying `override`
gets no `--silent`, because an override replaces the installer's whole
argument string and is then what decides. Before installing, winget is asked
`winget list` whether it has the package already, and asked again if the
install failed: a package its export cannot see is there either way, and such
a row is marked rather than installed (below). zypper's ledger records what a
failed batch still landed, read back from `rpm`, so a package installed
beside one that failed is not asked for again.

A scoop app whose install FAILED is reported by `scoop export` like any
other, and is not installed in any usable sense, so mox reads its row as
missing and hands it back to `scoop install`, which repairs it. Two such apps
are refused instead, each as that row's own failure: repairing a HELD app
would undo a hold you set, and mox installs for this user alone, so repairing
a GLOBAL one here would leave a second copy. The refusal names the
`scoop reset` to run.

Each of those asks the manager, so `mox apply --dry-run` runs none of them
and says beside the rows what it left unchecked, exactly as it does for the
Linux managers.

### What an apt, dnf, pacman or zypper row may name

`name` on these four is a plain package name, and mox checks it against what
a package name is rather than against a list of what it is not: it begins
with a letter or a digit, holds only letters, digits and `.`, `_`, `+` or
`-`, and does not end with `-`. A trailing `+` is fine, since `g++` is a
package.

Two things sit outside that class. An install argv accepts more than package
names -- `apt-get install -y vim nano-` removes nano, and `zypper install vim
!nano` and `zypper install vim -nano` do the same -- and mox never uninstalls
anything, so a row that would ask for one is refused rather than run. And a
name a manager resolves to a package of a different name
(`pkgconfig(libcrypto)` installs `libressl-devel`) is recorded under the name
asked for, so it would read as missing on every status and be reinstalled on
every apply.

The refusal names the file, the row and the rule the name broke, and it is
checked on every machine, not only where that manager runs. dnf takes a full
NEVRA and a bare `name.arch` within that class, which `rpm` reports under the
bare name; both are refused for the same reason. Beyond the check, the
operands are passed after `--`, so nothing a row is named can be read as an
option.

apt is the one exception to the plain name, because its own
`apt-mark showmanual` reports a foreign-architecture package qualified: an
apt row may carry one `:<arch>` suffix, as in `libc6:armhf`, where the
architecture holds only letters, digits and `-`. The colon stays refused on
dnf, pacman and zypper, whose queries never answer with one -- zypper reads
it as a selector separator (`pattern:`, `patch:`) instead.

Whether the manager actually **has** a package of that name is a separate
question, asked where the install is rather than at load, since only the
manager can answer it and a manifest must read the same on every machine.
Before an apt install, mox asks `apt-cache --generate pkgnames` -- apt's one
literal-matching whole-universe query -- and refuses a row naming anything
absent from it: `apt-get install` otherwise falls back to reading the operand
as an unanchored regular expression, so `libz.dev` installs ten packages the
manifest never declared and `ruby.dev` installs hundreds. The listing is
asked for under `APT::Architectures=<native>`,
`Dir::State::status=/dev/null` and `APT::Cache::AllNames=false`, so it holds
the native architecture's repository packages and nothing else: the plain
listing prints most foreign-architecture-only names bare, and a bare row
naming one would install `name:<arch>`, which `apt-mark showmanual` then
reports qualified; and an apt.conf `APT::Cache::AllNames "true"` would put
virtual names in it, where `awk` would then be refused as pinned rather than
told what provides it. Such a row is refused with the qualified spelling to
declare. That listing holds bare names alone, and it omits a package that
exists only for a foreign architecture -- `wine32` is in no listing on an
amd64 or arm64 machine, while apt installs `wine32:i386` and `apt-mark
showmanual` reports exactly that -- so a row carrying an architecture is
asked about as written, with `apt-cache madison`, the query verified to match
a qualified name literally where `apt-cache show` and `apt-cache policy` both
fall back to a regex. A row qualifying an architecture dpkg has not enabled
(`dpkg --print-foreign-architectures`) is refused with the command that
enables it, unless dpkg already has the package installed under it.

Every one of those judgements keys on the architecture dpkg reports, so mox
asks apt which one it resolves against -- `apt-config dump
APT::Architecture` -- and refuses the whole apt pass when the two disagree,
naming the setting and both architectures. Nothing else shows the
difference: `apt-cache policy` heads the stanza bare over a version table
holding the other architecture's package alone, `apt-cache madison` reports
that package alone, and the native listing still carries the name, so the row
passes every refusal and the install then fails on dependencies and takes the
batch with it, identically on every apply after. `apt-mark showmanual`
answers about apt's architecture too, printing a set of dependencies no row
declares and dpkg has installed and configured, so the refusal covers
`status` as much as `apply`: apt is reported broken rather than reporting
another machine's packages untracked. The plural `APT::Architectures` cannot
put apt on another architecture -- apt inserts its own into that list
whatever the configuration names -- so the singular key is the one asked
about.

A flat repository (`deb [trusted=yes] file:/repo ./`) keeps every
architecture in one index, so the listing prints its foreign-only names bare
too. The stanza `apt-cache policy` prints for the row settles those: apt
heads it with the name it resolves the row to, and a bare row headed
`name:<arch>` is refused with that spelling to declare when dpkg has the
architecture enabled, and told to enable it when not -- an install carrying
such a package fails at dpkg and installs nothing. A row apt prints no
stanza for at all is an operand apt cannot locate, which is all the empty
answer says: a purely virtual name and a package built for one architecture
alone each get a stanza of their own and are refused on the branches above.
An operand apt cannot locate takes the whole batch down, so that row is
refused too.

The repositories are not the whole answer, because a package installed from a
`.deb` is in none of them. mox reads `dpkg-query` too, and a bare row whose
package is installed under this machine's own architecture -- or under
`all` -- is kept: `apt-get install` marks it manually installed and the row
converges from there. The same query is what refuses a bare row whose package
is installed only for a foreign architecture, where `apt-get install` sets
`name:<arch>` to manual and `apt-mark showmanual` reports it qualified.

A bare name apt has as a virtual name rather than a package is refused with
what provides it named, the way a dnf capability is: `apt-get install a52dec`
installs `liba52-0.7.4-dev`, which apt-mark then reports under its own name.

A held or pinned package is refused too, and for a different reason: neither
the index nor the package list knows about either, and `apt-get install`
answers a batch carrying one by installing nothing at all -- so one such row
would keep every other package in the manifest off the machine. mox reads
`apt-mark showhold` and `apt-cache policy` before the install and refuses the
row. A hold is the user's decision, so it is never overridden.

A package dpkg has left `install ok unpacked` -- an interrupted run -- is on
the disk and not set up. `apt-mark showmanual` lists it and `apt-mark
showauto` may too, so both the explicit set and the already-installed set are
intersected with what `dpkg-query` reports `installed`: the row reads
missing, and goes to `apt-get install`, which configures it (and marks it
manual when it was auto), where `apt-mark manual` alone would have left it
unpacked.

Before a dnf install, mox asks `dnf repoquery` the same question, and a name
that is only an rpm capability rather than a package -- `zlib-devel`, which
`zlib-ng-compat-devel` provides -- is refused with the name to declare in its
place. Before a pacman install, mox reads `pacman -Sl`, and a name that is a
package **group** rather than a package -- `xfce4`, which holds fourteen --
is refused with the members named, since `pacman -S` installs every one of
them and `pacman -Qeq` reports the members and never the group. A name that
is an ALPM **provision** rather than a package goes the same way: `cron` is
in no `pacman -Sl` line and is no group either, but `pacman -S cron` installs
`cronie` and `pacman -Qeq` reports `cronie`. mox asks
`pacman -S --print --print-format '%n'`, which resolves the name and prints
the transaction without running any of it, and refuses a row whose own name
is not among what pacman would install -- naming what pacman resolved it to.
`sh`, `java-runtime`, `ttf-font` and `smtp-forwarder` are all such names.

A name pacman resolves to nothing at all is refused too, because
`pacman -S` answers a batch carrying one with "target not found" and installs
none of it -- and so is a name `pacman -Sl` lists that `pacman -S` still
answers that way, which is what a repository configured with a `Usage` that
leaves out `Install` produces. So the listing settles only whether a name is
a group or a package, and every row to install is then asked of
`pacman -S --print`: the whole batch in one call, and a row that transaction
does not carry on its own. That call's stderr is read, because pacman exits
1 the same way for a name it has nothing for (`error: target not found`) and
for a package whose dependency no repository satisfies (`could not satisfy
dependencies`, with the dependency named on stdout); each refusal quotes
what pacman said.

A row whose package **conflicts with an installed package** is refused as
well. `pacman -S --print` does not report that -- the transaction prints and
exits 0 -- and the install then asks "Remove <package>? [y/N]", which
`--noconfirm` answers no, so the batch fails as one with "unresolvable
package conflicts detected" and nothing beside the row lands, on every apply.
mox never removes a package, so the row goes rather than the batch. The
install is one `-Syu`, so the conflict is judged against the machine that
upgrade leaves, not the one it starts from: an installed package the row's
`Replaces` (from `pacman -Si`) names is one pacman replaces in that
transaction, answering its own "Replace X with Y?" yes under `--noconfirm`,
and is no conflict; an installed package some other pending package replaces
is gone from that machine too, and is no conflict either -- `pacman -Qu` is
blind to a replacement, so the upgrade's own targets are asked for with
`pacman -Su --print --print-format '%n'` against the copy, `pacman -Si` read
for the ones the machine does not already have, and each installed package
their `Replaces` names at a version it satisfies counted as gone; and a
versioned spec is compared, with `vercmp`, against the version `pacman -Qu`
against mox's database copy says the upgrade will leave, or the installed
version when no upgrade is pending -- the `xf86-*` drivers declare
`xorg-server<21.1.1`, which the same upgrade moves past. Exit 1 with both
streams empty is how `pacman -Qu` says nothing is pending; any other failure
of either query is said out loud, naming the command, its exit code and what
it printed, since the answer read in its place is the machine as it stands.
Both directions are read: the row's `Conflicts With` against what
`pacman -Qi` says is installed, by name or by provision, and each installed
package's own `Conflicts With` -- of the version the upgrade will leave,
read from `pacman -Si` against the copy when one is pending -- against the
row and what it provides, for a conflict declared on that side alone. The
refusal names the installed package pacman would have removed.

Every one of these answers is a sync database's, and the system's is only as
current as the machine's last sync -- absence from a database synced months
ago says nothing about a row. A check never mutates the system, and a bare
`pacman -Sy` that brought the system's database forward would leave it ahead
of the installed packages, a state Arch does not support, on every path that
then refuses a row. So mox syncs a copy of its own, the way `checkupdates`
from pacman-contrib does: `pacman -Sy --dbpath /var/cache/mox/pacman-db
--logfile /dev/null`, with the copy's `local` a symlink to the system's local
database, so that `--print` resolves against what the machine has. The copy
lives under `/var/cache` rather than mox's state directory because pacman 7
downloads as its `DownloadUser`, which cannot reach into a home directory of
mode 0700, Arch's default; it is root-owned, kept between applies, and read
by nothing but these checks. It is made by one elevated `sh -c` --
`install -d -m 755 /var/cache/mox /var/cache/mox/pacman-db`, then an
`rmdir` of the copy's `local` when a real empty directory stands there,
then `ln -sfnT <DBPath>/local /var/cache/mox/pacman-db/local` -- run on the
terminal, so that sudo can ask for a password once, and only when `stat` and
`readlink` find it missing, with a mode the download user could not
traverse, or with `local` not a link to the system's -- so after the first
apply an apply elevates `pacman` alone, and a sudoers rule that grants
nothing else serves it. An empty directory at the copy's `local`, which a
sync into the copy before the link leaves, is removed for the link; one with
entries in it is named and left. When the make cannot run, the message gives
that same command line to run once as root, `rmdir` and all, since `ln
-sfnT` against a real directory there fails with "cannot overwrite
directory"; a regular file or other non-directory
at either level is named instead, since `install -d` could only fail on it.
Beside these, what pacman itself says on stderr while resolving a batch it
does resolve -- a warning about pacman.conf -- reaches the terminal as it
came. A sync that fails with `db.lck` left in the
copy -- what a pacman killed outright mid-sync leaves behind -- names the
file and says it may be removed once no pacman is running. The install that
follows is the single `pacman -Syu --needed --noconfirm` transaction with
the rows as its targets, which is what records a row the upgrade would
otherwise pull in as some other package's dependency as explicitly
installed.

Before a zypper install, mox asks `zypper search --match-exact --type
package` which of the row names its repositories carry under exactly that
name. An rpm **virtual provide** is spelled like a package name and resolves
like a dnf capability: `zypper install smtp_daemon` exits 0 having installed
`postfix`, and `rpm -qa` reports `postfix`, so the row reads as missing and
is reinstalled on every apply -- silently, since zypper exits 0 each time.
Such a row is refused with its providers named, from
`zypper search --provides --match-exact`. A name zypper has nothing at all
for is refused too, because `zypper install` answers a batch carrying one by
installing none of it. Both searches run with `--no-color`: zypper.conf's
`useColors = always` colours the table even into a pipe, `NO_COLOR` does not
undo it, and a coloured table names no package. A package zypper has
**locked** (`zypper addlock`) and not yet installed is refused the way apt's
held one is: the search table's status column reads `l` for it,
`zypper install` answers a batch carrying it by installing nothing at all,
and the lock is the user's decision, so the row is refused with
`zypper removelock` named and the lock left in place. One installed and
locked (`il`) stops the batch the same way only when an update for it is
pending, which the search table cannot show, so
`zypper list-updates --all` is asked about such rows: one it lists is
refused with both versions named, one it does not list is installed with the
batch, and when it cannot answer the row is refused rather than risked.

An apt row qualified with the machine's own architecture is refused the same
way, as are apt's `:native`, `:all` and `:any`, which apt resolves to the
native package that `apt-mark` then reports bare.

A refused row installs nothing, and it is refused alone: the rows beside it
in the same manifest are installed, and the run counts the refusal as that
row's own failure and exits non-zero over it. One row nobody can install does
not keep every other package off the machine.

These checks run the manager, so `mox apply --dry-run` does not run them: a
dry run lists a row a real apply would refuse as one it would install, and
says so in a note beside the rows it left unchecked.

### What a brew, scoop or winget row may name

These three have grammars of their own, so each has its own class.

A brew `name` is one formula or cask, or a tap-qualified `owner/tap/name`.
Each part begins with a letter or a digit and holds only letters, digits and
`.`, `_`, `+`, `-` or `@` -- `@` because `openssl@3` and `emacs-plus@30` are
real formulae. Everything else a brew operand can be is refused: an option
(`brew install --help` exits 0 having installed nothing, so such a row would
be counted installed, reported missing by the query that follows, and
installed again on every apply), a local Ruby file (`brew install ./x.rb`
runs it), a URL, and `owner/tap` alone, which names a tap rather than
anything `brew list` can report back. Beyond the check, every name mox hands
brew comes after a `--`.

Before a brew install, mox asks `brew info --json=v2` what each row's name
stands for, and refuses a row naming an **alias** rather than the package
brew reports back: `brew install ag` installs `the_silver_searcher`, which is
the name `brew list --full-name --installed-on-request` answers with, so an
`ag` row would read as missing and that formula as untracked on every run.
The refusal names the formula or cask to declare instead.

Formulae and casks are asked about separately, because the two namespaces
share names: `docker` is a formula of its own and an old token of the cask
`docker-desktop`, and `dash` is a cask of its own and an old name of the
formula `dash-shell`, so one answer must never stand in for the other. brew
answers for none of a batch carrying a name it does not have, so mox then
asks about each name on its own rather than letting one bad row turn the
check off for the rest.

A tap-qualified row is asked about too. `homebrew/core/ripgrep` is answered
with `ripgrep`, which is the name brew reports back, so that row is refused
with the bare name to declare; a third-party tap's formula is answered with
its own qualified name, and such a row stands. A row naming a tap this
machine does not have yet gets no answer at all and is kept -- declaring it
is the decision to trust that tap.

A scoop `name` is one app: a single token of letters, digits and `.`, `_`,
`+` or `-`. So a row cannot be a manifest path or a URL (scoop installs
either), a bucket-qualified name (the bucket is a key of its own), or a
pinned version: `scoop install git@2.1` installs a version that
`scoop export` reports under the bare name, which reads as missing on every
status after.

A `bucket` is a bucket NAME and never a repository. `scoop bucket add <name>`
takes the repository as a second operand and looks an unqualified name up in
scoop's own list of ten, so a bucket outside that list can only be added with
a URL -- and a URL is not one token, which is the class a value spliced into
scoop's argv is held to. Such a row is refused before anything runs, naming
the `scoop bucket add <name> <repository>` to run once; after that the bucket
is in `scoop bucket list` and every row in it installs like any other.

A winget `name` is one `PackageIdentifier`, and that one is deliberately
wider: an identifier is the publisher's own string (`Notepad++.Notepad++`, a
bare store id), mox cannot enumerate them, and a class narrower than
winget's would refuse a package someone really has. So the rule names what
would make the value something else instead -- it begins with a letter or a
digit, and holds none of `\`, `/`, `:`, `*`, `?`, `"`, `<`, `>` or `|`,
which is what a path, a URL, a pattern or an option needs.

The field values that reach a manager's argv are checked too, because they
land where a name lands. scoop's `bucket` and winget's `source` are each one
token, and are held to the single-token class -- which matters most for
scoop, a PowerShell script whose `-File` parser reads an escaped quote
differently from the way Zig serializes an argv, so a value carrying
whitespace and a `"` together could leave its own argument and become several
operands. winget's `override` is held to neither class, and cannot be: it
exists to hand a command line on to the package's own installer, so a space,
a slash and the quotes an installer argument needs (`/DIR="C:\Program
Files\App"`) are what it is for. winget is spawned directly, so the
`CommandLineToArgvW` inside `winget.exe` reverses that serialization exactly
and the value arrives whole; the one byte it may not hold is a control byte,
which no argv carries intact.

### brew taps

A tap is not a key. A tap-qualified name names its own tap, and declaring
such a row **is** the decision to trust it:

```toml
[[packages]]
name = "d12frosted/emacs-plus/emacs-plus@30"
```

mox taps it and trusts that one formula (`brew trust --formula`), never the
whole tap -- an untrusted third-party tap is ignored outright since Homebrew
6.0, and whole-tap trust would extend to everything it ever adds. A cask from
a third-party tap is trusted as a cask; the two namespaces are distinct.

### What a manager cannot be asked

Every query above answers the question its manager can answer, and that is
not always "what did the user ask for". Some answer something NARROWER, and
miss a package you really have; others answer something WIDER, and report
packages nobody chose. Each backend says which as a note under itself in
`status`, the way zypper does below.

**Narrower.** brew declares `--cask` and `--installed-on-request` as
conflicting options, so there is no explicit-install query for casks:
`brew list --cask --full-name` is the whole Caskroom, and a cask another cask
pulled in through `depends_on cask:` is reported untracked until it is
declared or blacklisted. zypper has no such query at all, which is what the
ledger below exists for. And `winget export` reports only packages a source
supplied, so one installed outside a source is invisible to it: its row is
reported missing on every status, and every apply marks it (below) rather
than reporting an install that did not happen.

**Wider.** Neither Windows manager records who asked for a package, so
neither can be asked. `scoop export` is every app directory, dependencies
included. `winget export` is every installed package a configured source can
correlate, which on a real machine is every redistributable and every Store
app. So a first `mox status` there reports a great deal untracked, and none
of it is wrong -- it is what the manager can see. `mox commit` is how that
set comes down: declare what you meant to keep, blacklist the rest.

### zypper's ledger

zypper has no explicitly-installed query (`--userinstalled` is not a flag it
knows, and `--installed-only` includes every dependency), so mox records what
it installed in `<state dir>/zypper.txt` and treats that as the explicit set.

That record is never trusted on its own: it is intersected with what `rpm`
reports actually present, so a package removed behind mox's back drops out,
is reported missing, and is reinstalled rather than assumed to be there. A
batch that failed part-way is read back the same way, so the rows that did
land are recorded rather than retried forever.

Because what is installed is read back from `rpm`, a zypper row names a
package, plainly -- the rule above, plus two spellings it names in its own
words: a `pattern:`, `patch:`, `product:`, `srcpackage:` or `application:`
selector, and a version relation (`vim=9.0`) or an architecture suffix
(`vim.x86_64`), each of which would install and then read as missing on
every status. The cost is that a package installed by hand is
invisible to mox on zypper and will never be offered for tracking. `mox status` prints that as a note
under the backend rather than leaving it to be discovered.

## Drift

- **MISSING** -- declared for this machine, not installed.
- **UNTRACKED** -- installed, declared nowhere in the manifest, not
  blacklisted.
- **ERROR** -- the manifest itself was refused, so no backend was reached
  (`ERROR     the package pass was refused; the reason is the mox status:
  packages: line`). Counted toward the exit code: an empty section would
  otherwise read as a clean machine.
- **BROKEN** -- the manager is installed but cannot answer
  (`BROKEN    brew (brew --version exited 1)`). Its rows are neither judged
  nor installed, and a machine in that state is not a clean one: `status`
  counts it toward the exit code and `apply` fails on it. `commit` only
  notes it, since a manager that cannot list has nothing to reconcile.

Untracked is measured against every row the manifest declares, not only the
ones desired here: a package gated to another profile is already tracked, and
offering to re-add it would write a second row for something the manifest
already carries.

Package drift counts toward `mox status`'s exit code exactly as file drift
does, and `--json` / `--porcelain` carry both sets (see
[commands.md](commands.md#status)).

## Installing and reconciling

`mox apply` installs what is missing after the pre-script stage, with the
machine re-read in between when a pre-script ran, so a gate on a tool or
fact a pre-script provided holds here; the machine is re-read again after
any install or bootstrap, so a package installed here is a tool the
post-scripts see. A declared manager that is absent is bootstrapped first
(above). apt, dnf,
pacman, zypper and plugins get the whole set for their backend in one
invocation; brew (apart from the casks that elevate, below), scoop and winget
install row by row, and a row that fails leaves the rest to proceed. The manager's own output is streamed rather
than captured, so progress and errors reach the terminal as they happen,
and it may talk to the terminal itself (`sudo` asking for a password; apt
runs with `DEBIAN_FRONTEND=noninteractive` so debconf does not). A batch
that failed may have landed some of its rows, so the re-capture runs after
any attempt, and after a bootstrap alone; the summary then says how many
rows were in failed batches, since a per-row manager counts only the
batches it lost -- or, for zypper, which reads the machine back before and
after a batch, how many of them the failed batch landed, with no hedge when
none did and no credit for a package the machine had before. An install is not time-bounded by default -- a manager may
legitimately compile for an hour -- and `MOX_INSTALL_TIMEOUT_MS` bounds it
when set: at the bound the manager gets SIGINT first, so it can roll back
its transaction, and SIGKILL ten seconds later.
`--dry-run` lists what it would install and installs nothing.

An install, a bootstrap's installer, or a setup script that prints nothing
for five minutes is named on stderr, and again every five minutes it stays
quiet:

```
mox apply: brew: logi-options+ has printed nothing for 5m; it may be waiting for an answer on the terminal (Ctrl-C stops the run)
```

Nothing is ended for it; `MOX_INSTALL_TIMEOUT_MS` is the one bound that
kills. mox does not sit between the child and your terminal -- a pipe there
would turn off an installer's progress bars and change what it asks -- so
quiet is read from the modification time and size of mox's own stdout and
stderr, which a write to a terminal, a pipe, or a file advances. Where
neither can be read that way (`/dev/null`, any stream on Windows) the line
says how long the call has been running instead of how long it has been
quiet.

Before the first install, the volumes the installs write to are measured
with `df -P -k` -- for brew, its prefix, and `/private/tmp` on a mac when a
cask is to be installed -- and one with less than 10 GiB free is named with
the space it has. It is a warning: the installs go ahead. A vendor installer
that runs out of disk has been seen to hang rather than fail, which the
warning is there to head off.

Ctrl-C during an install ends the run once the manager has wound down, and
the last line says what was running then -- the one package, the batch of
casks, the installer, or the setup script:

```
mox apply: interrupted while running brew: autoconf; it may have been left part-done
```

A hangup of the terminal while an install or a setup script holds it (an
ssh session closing) ends the run the same way, with the same line: the
kernel sends SIGHUP to the group holding the terminal, and a run that went
on would have nobody to answer what came next. A manager that
catches the interrupt to clean up and exits 130 -- brew does -- ends the run
the same way, rather than mox going on to the next install. The same holds
for an installer and a setup script: a child that held the terminal and
exits 130, for whatever reason, is taken as the user's Ctrl-C and stops the
apply.

Every brew command runs with `HOMEBREW_NO_ASK=1`. Homebrew 7.0 turns its
ask mode on by default, and with a terminal on stdin and stdout -- which an
install has, when mox does -- `brew install` would stop at `Do you want to
proceed with the installation? [y/n]` whenever its plan carries a dependency
the row did not name. A brew that is on no PATH (Homebrew's installer leaves
`/opt/homebrew/bin` off it until a shell profile adds it) is looked for in
the prefixes its installer uses -- `/opt/homebrew`, `/usr/local`, and
Linuxbrew's -- before it is called absent, and a brew found there is the one
the run uses, rather than one the bootstrap installs again.

A brew cask whose install elevates -- a `pkg`, an installer run with
`sudo: true`, a keyboard layout, or a preflight or postflight step that needs
sudo, mirroring Homebrew's own `requires_sudo?` as `brew info --json=v2`
shows it -- is installed together with the others like it, in one
`brew install --cask`, before every other brew row. Homebrew clears sudo's
cached credential the first time each brew process needs it, so one process
per cask would ask for the administrator password once per cask; one process
asks once. brew downloads every cask of that run first, so the prompt comes
when the downloads are done. A line before the run says so:

```
mox: brew: karabiner-elements, logi-options+ need administrator access to install, so they are installed first, in one brew run; Homebrew downloads them all first, then clears sudo's cached credential before its first elevated step, so the administrator password may be asked once more when the downloads are done
```

brew goes on to the next cask when one fails, and when that run fails mox
reads the installed casks back and names each one it left uninstalled. A
cask brew cannot describe is installed on its own, like every other row, and
so is one whose elevation the JSON does not show -- a cask that elevates
only from a `preflight`/`postflight` Ruby block or through a sudo fallback of
its own: its brew run may ask for the password again.

A dnf install answers dnf's own questions, and the import of a repository's
signing key is one of them: on a machine whose rpm holds no key for a
repository dnf installs from, the first install imports the one that
repository's `gpgkey=` names, and every package signed with it is trusted
from then on. Nothing is asked. What reaches the terminal is dnf's record of
having done it, the install being streamed -- on dnf 4.14.0, `Importing GPG
key 0x350D275D:`, the fingerprint, and `Key imported successfully`. The
queries mox runs import nothing: they decline that question, so a repository
that would have needed the import contributes no name to them. Where
accepting that key is a decision to take deliberately, import it before the
first `mox apply`.

apply **only ever installs**. Removal is never automatic: an untracked
package is reported and reconciled, never uninstalled behind you. (What a
manager does on the way -- pacman's full upgrade, a dependency brew drops --
is the manager's own behavior, not a mox decision.)

A declared package the manager ALREADY HAS, installed as something else's
dependency, is **marked** rather than installed. A manager writes its
explicit-install record when it installs something, and installing a package
it has already is nothing it does: the row would read missing on every status
and every apply would install nothing at all. So mox runs the manager's own
mark command instead -- `brew tab --installed-on-request`, `apt-mark manual`,
`dnf mark install` on dnf4 and `dnf mark user` on dnf5 (each with
`--setopt=assumeno=0`, as the install has), `pacman -D --asexplicit` -- which
changes that record and leaves the machine alone. winget has no such
record and so no mark command: a package its export cannot see is one
`winget list` reports and `winget install` refuses, so the row is counted
there too, and counted as already present rather than installed, since mox
put nothing on the machine. The
summary counts those rows apart from the ones mox installed:

```
Packages: 1 installed, 0 failed, 1 already on the machine
```

What the machine already has is asked before anything else, so such a row is
marked before the checks an install needs -- the index refresh, the package
listing, apt's holds and pins, pacman's sync -- and converges where those
would refuse it: a package no enabled dnf repository carries any more, a held
apt package, a pacman that cannot sync. A mark that fails is that row's own
failure, counted as one, and the rows beside it are marked or installed all
the same. There is no fallback to an install, which would exit 0, change
nothing, and leave the row missing.

`mox commit` offers each untracked package `[y/b/s]`:

- **add** -- append a row to the manifest file that already speaks that
  backend, with whichever adapter fields identify it. The file chosen is
  the first of: a repo file whose default `backend` is it, a repo file
  carrying a row for it, then the same two in the private layer -- skipping
  any file whose own `when` excludes this machine, since a row appended
  there would never be desired here. When no
  file remains, commit says so once per backend
  (`no data/packages file that holds on this machine
  declares backend "x"; add one to record its N untracked package(s)`) and counts those packages as skipped: creating a
  file is a decision about where the rows live, not one to make silently.
- **blacklist** -- append a `[[blacklist]]` row so it is never offered again
- **skip** -- leave it untracked; the default, so `--yes` records nothing
  and the run still exits 1 while anything is untracked

A row is always **appended**, never edited in place, so every existing byte
of that file -- comments, ordering, a row you were mid-thought on -- survives
untouched. The read and the rewrite run under an exclusive lock on the
directory the manifest file lives in, so a second mox writing that file waits
rather than reading the same bytes and dropping whichever row landed first --
which the state lock alone would not prevent, keying as it does on a state
directory that `mox commit` and `sudo mox commit` have one each of. A
directory takes no such lock on Windows, where two runs are serialized only
by the state lock they share. A row is appended the moment it is chosen:
`q` at a package
prompt ends the run before the file pass and says how many rows were already
recorded (rc 1), and `--abort-on-prompt` exits 2 at the first package prompt
the same way. A path-scoped `mox commit <file>` names files and skips
packages entirely.

## Adding a backend

Any package manager can be given a backend without rebuilding mox. The seven
above are compiled in because they are what mox supports out of the box, with
no shell dependency; everything else is a **plugin**: an executable in the
repo that speaks the protocol below. A plugin satisfies exactly the same
contract as a compiled backend, so `status`, `apply` and `commit` cannot tell
them apart. What stays fixed by mox is the set of things a backend is asked to
do -- there is no `remove` or `upgrade` verb, and adding one is a mox change.

### Where

`scripts/backends/<name>`, flat, repo only. The name is the filename stem:
`macports` and `macports.ps1` both name `macports`, so one plugin can ship a
POSIX script and a PowerShell twin. Names are `[A-Za-z0-9_-]`. Two files that
could both run here naming one backend is an error naming both; a runnable
file beside a not-runnable twin is the cross-platform case, and the runnable
one wins.

- Unix runs a plain file directly; it must be executable (`chmod +x`), and
  one that is not is an error naming the file -- never "no such backend". A
  Windows-only kind (`.ps1`, `.exe`, `.cmd`) is *not runnable here*: a note,
  not an error, and a manifest row naming it is inert rather than refused.
- Windows has no executable bit, so kind decides: `.ps1` runs through
  `pwsh`, or `powershell` where pwsh is not installed; `.exe` and `.cmd`
  directly. Any other file is *not runnable here*, printed
  as a note under `packages:`, so a MacPorts script in a shared repo neither
  breaks nor silently vanishes on a Windows machine.

A backend name never begins with a dot, so nothing there that does is one:
an empty `scripts/backends/` can be version-controlled, and shell plugins can
carry the eol rule that keeps them LF-clean on Windows. What git and an
editor keep in a tracked directory passes without remark: the placeholders
that keep an empty one (`.gitkeep`, `.keep`) and the rules that govern it
(`.gitignore`, `.gitattributes`, `.editorconfig`). So does the OS and editor
noise mox passes over anywhere in a repo -- `.DS_Store`, an AppleDouble
`._name`, `Thumbs.db`, `desktop.ini`, a vim swap file (`.swp`, `.swo`), an
emacs backup or lock (`name~`, `#name#`, `.#name`) -- several of which begin
with no dot at all and are passed over here all the same. Any other dotfile
is ignored and said as a note, since that is also how a backend ends up
hidden by accident, and it must not read as a typo from the manifest's side.
A directory there is an error naming the path, never "no backend named x".

There is no axis gating (`os=darwin/`) and no private-layer shadowing.
Whether a backend is usable on this machine is its own `available` verb, and
nothing else: a plugin hidden under an `os=` directory would be undiscovered
elsewhere, and every shared-manifest row naming it would read as a typo there.

A runnable plugin named like a shipped backend overrides it, and `status`
says `note      brew: scripts/backends/brew overrides the built-in` on every
run. One that is not runnable here (`brew.ps1` on macOS) is noted and the
built-in keeps its place, so the rows it validates stay validated.

### The protocol

| Verb | stdin | stdout | Exit |
|---|---|---|---|
| `available` | -- | -- | 0 usable here; 1 not usable here; anything else, 64 included, is a broken plugin |
| `id` | one row, `{ name = "...", ... }` | exactly one id | 1: the row is refused, say why on stderr; anything else, 64 included, is a broken plugin |
| `list` | -- | one id per line: what was explicitly installed | nonzero, 64 included: failed |
| `install` | rows, one per line | streamed to the terminal | nonzero, 64 included: failed |
| `declare <id>` | -- | a TOML row body: `name = "..."` plus adapter fields | nonzero, 64 included: failed |
| `bootstrap <path> <out>` | -- | streamed to the terminal; the bin dir to put on PATH, if any, is written to the file `<out>` as one line, an absolute path (a second line, or a relative path, is bad output) | 64: not implemented; other nonzero: failed |
| `limitation` | -- | one line on what it cannot see, at most 200 bytes and no control bytes | 64: none; other nonzero: failed |

Rows arrive as TOML inline tables carrying `name` and the row's adapter
keys -- never `backend` or `when`, which are mox's. `id` is asked one row at
a time and must answer exactly one line; `install` gets every row of the
batch, one per line. A plugin's stderr is the terminal's for every verb, so
a refusal reason or a crash is seen as written. Ids are opaque to mox: it
compares them and never parses them, so a manager with two namespaces
prefixes them itself (`cask:ghostty`) and the manifest row still spells
`name = "ghostty"`, `kind = "cask"` -- the same shape as for a compiled
backend.

- **`id` is both validate and idOf.** A row the plugin cannot name is refused
  with the plugin's own reason, which is stronger than any key list mox could
  check. A refused row fails on every machine that can run the plugin, not
  only where the manager is installed; where the plugin itself cannot run
  (a POSIX script on Windows) its rows are inert, not checked.
- **`declare` is checked, not trusted.** The row it returns is handed back to
  `id`, and refused unless the answer is the id it came from. A plugin whose
  two halves disagree cannot write a row that will never match its package.
  The row is `name` plus adapter keys: one carrying `backend` or `when`, or
  a key outside `[A-Za-z0-9_-]`, is refused.
- **`install` gets the whole set.** A manager that resolves a batch in one
  pass gets one call; a per-item manager loops over its stdin.
- **No ledger mode.** A manager with no explicitly-installed query keeps its
  own record under `<state dir>` and intersects it in `list`; `list` has
  one meaning.
- **Exit 64 means "this optional verb is not implemented"** -- `bootstrap` and
  `limitation` are the optional ones -- reported by plugin and verb where it
  was needed. Nothing is substituted for a missing verb. Every other verb is
  required, so 64 from one of them carries no meaning: `available` reads it as
  a broken plugin like any other unexpected exit, and `id`, `list`, `install`
  and `declare` as a failure like any other nonzero exit.
- Every captured call runs under `LC_ALL=C` with `LANGUAGE` unset, because
  mox parses what it prints and parses one language; a streamed call keeps
  your locale, because what it prints reaches your terminal
- Every captured call is time-bounded like a setup script
  (`MOX_SCRIPT_TIMEOUT_MS`);
  a `list` blocked on a manager's lock is a timeout failure naming the
  backend, not a hung `mox status`. The bound covers the whole call, and
  every child leads its own process group, so the kill takes whatever the
  call left in that group -- a helper holding the pipe (`port ... | awk`), a
  manager behind a `sudo`. What it does not take is something that left the
  group on purpose: a process that makes itself a group leader (`setsid`,
  `setpgrp`) is no longer addressed by the kill, which is how a manager
  starting a daemon leaves one running. Interrupting mox takes them with it too: a
  Ctrl-C during a query kills the query's group before mox dies of the
  interrupt itself, so no manager is left holding a lock.
- A streamed call (`install`, `bootstrap`) is handed the terminal for its
  run, the way a shell hands it to a job. `sudo` can prompt, the manager
  reads the terminal on stdin (a plugin verb reads what mox hands it
  there instead: its rows, or nothing), Ctrl-C goes to the manager and ends mox with it -- whether the
  manager dies of it or exits 130 -- and Ctrl-Z suspends the job and hands
  the terminal back, so the shell can `fg` it later. Where mox's stdin is
  not a terminal it holds (a pipe, a file, a run in the background), a
  streamed call's stdin is closed. A run with no terminal
  to hand over (`mox apply &`, a CI job) cannot answer a prompt, so an
  install that stops waiting for one is ended and named rather than waited
  on forever. Its bound is
  `MOX_INSTALL_TIMEOUT_MS` (none by default: a manager may compile for an
  hour), and at that bound its group is interrupted, then killed ten
  seconds later. A captured verb must never prompt: it is not the
  foreground job, so a read from the terminal stops it, and mox ends a
  captured child that stops the moment it stops rather than waiting out the
  bound -- or forever, where the bound is disabled.
  Windows has neither process groups nor job control, so there a bound
  reaches the direct process alone and no terminal changes hands.
  A killed call names the bound it ran under where the command armed one for
  that call itself: an install, or a bootstrap's installer run, says `timed
  out after <ms>ms (MOX_INSTALL_TIMEOUT_MS), killed`, and a bootstrap's
  download -- captured, and bounded like a setup script -- says
  `(MOX_SCRIPT_TIMEOUT_MS)`. A query verb names no bound: a `list` killed at
  `MOX_SCRIPT_TIMEOUT_MS` says `timed out, killed`, which is also what a call
  reports where the bound that could have fired was not armed. One ended
  for want of a terminal says `stopped, and this run has no terminal that
  could resume it; killed`.
- The shipped backends' own manager calls are bounded the same way, and a
  probe killed at the bound is a named failure, never read as an absent
  manager. A manager that answers its probe with anything but "here" or
  "not here" -- a shipped one whose `--version` fails, a plugin whose
  `available` neither succeeds nor exits 1 -- is BROKEN (above), unless no
  row names it, in which case it is a note and its absence changes
  nothing.
- Output is split on newline, and each line is trimmed of `\r` and of the
  spaces and tabs around it (a PowerShell plugin emits CRLF, and pads a
  column). What is left is the id: one that is empty, exceeds 256 bytes, or
  carries whitespace, a control byte or a byte that is not UTF-8 is an error
  naming the plugin. That is the class the manifest enforces on a `name`,
  applied to what the trim left, so `  ripgrep  ` from `list` or `id` is
  taken as `ripgrep`, where the manifest would refuse those same bytes as a
  `name`. A `declare` answer is held to the class as written: its `name` is
  read as TOML, and a padded one is refused, so a row `declare` writes is a
  row the next command can read back. The shape rule catches a lost line
  separator across a large set; a fixture test in your repo is the real
  defence.

`bootstrap` runs only when the manifest declares a `[[bootstrap]]` row for
the backend and `available` says the manager is absent. mox fetches the
installer and refuses to hand it over unless it hashes to the declared
sha256; the plugin then runs the verified file however its manager needs.
The verb is streamed, so its output is the terminal's and it may take as
long as an install; the bin dir, if there is one, goes into the file the
second argument names, as a single line holding an absolute path. A second
line, or a relative path, is bad output: progress text must not land on
PATH.

### Environment and which commands run a plugin

A plugin runs as you, at the trust `scripts/pre` already has, under the
same environment a setup script gets: `MOX_REPO`, `MOX_STATE_DIR`,
`MOX_HOME`, `PATH` and every fact as `MOX_FACT_*`, plus `MOX_PACKAGES_DEPTH`,
which says that a mox already sits above this one. It is read as a yes or no
-- any value present, `0` and the empty string included, means one is -- so a
plugin can neither clear it by setting it nor by emptying it, and the number
it carries is capped rather than counted without end. What the marker cannot
survive is being removed: a plugin that unsets it, or calls mox through a
scrubbed environment (`env -i`), leaves that mox nothing to read and is
discovered by it again. The environment is the only channel to a child
process, so a plugin that empties its own is asking for the run below to
start over.

The environment is what a setup script gets; the fact CONTRACT is not. A
setup script's `MOX_FACT_*` use is read out of its text, asked for at the
interview and blocked on when unresolved ([dsl.md](dsl.md#fact-contracts));
a plugin's is not read at all. A plugin is any executable -- a compiled
`.exe` as readily as a shell script -- so there is no text mox may rely on
having, and a contract that held only for the plugins written in a scripting
language would read as coverage while silently skipping the rest. A fact
that no `src/` source and no setup script consumes is therefore never asked
about on a plugin's behalf, and one the repo consumes only behind a gate is
asked only where that gate holds; either way `MOX_FACT_<NAME>` is simply
absent from the plugin's environment. A plugin that requires a fact checks
for it in `available` and exits 1 -- it is the one judge of whether it is
usable here -- saying why on stderr, which reaches the terminal, or through
`limitation`. A mox reached from
inside a plugin discovers no plugin at all and says so as a note, so a plugin
that calls mox cannot multiply itself; the compiled backends still work
there. That holds for `status`
and `commit` as much as for `apply`; only `apply` refreshes the state bin dir
on the way. `status` runs `available`, `list`, `id` and `limitation`;
`commit` adds `declare`; `apply` adds `install` and `bootstrap`; `--dry-run`
runs the read-only set. `status` lists every discovered plugin by path
before it runs
anything, as `note` lines in the `packages:` section, or on stderr as
`mox status: note: ...` under `--json` and `--porcelain`, whose stdout stays
machine-pure. mox flushes its own output before every call, so those lines
reach the terminal before the plugin's do.

### A complete plugin

MacPorts, as a POSIX script at `scripts/backends/macports`:

```sh
#!/bin/sh
set -eu
cmd=${1:-}; shift || true
name() { printf '%s\n' "$1" | sed -n 's/^{ *name = "\([^"]*\)".*/\1/p'; }
case "$cmd" in
available) command -v port >/dev/null 2>&1 ;;
id)        IFS= read -r l && name "$l" ;;
list)      port -q echo requested | awk 'NF { print $1 }' ;;
install)   set --; while IFS= read -r l; do [ -n "$l" ] || continue; set -- "$@" "$(name "$l")"; done
           sudo port -N install "$@" ;;
declare)   printf 'name = "%s"\n' "$1" ;;
limitation) echo "variants are not tracked; a port is matched by name alone" ;;
*)         exit 64 ;;
esac
```

That is longer than a purely declarative form of the same thing would be, and
that is accepted: a schema rich enough to also express a ledger, a second
namespace, or running an installer is a scripting language in TOML, and the
first manager with a quirk it lacks would need a mox release again.

## Testing

`zig build test` is hermetic: every manager call goes through a scripted
runner, so it passes with no package manager installed and never touches the
machine running it. That proves an adapter emits the argv it intends, and
nothing more.

A green run is not a silent one. Plugin stderr is the terminal's by design,
so a fixture plugin that is meant to fail writes its complaint straight to
the terminal, past the writers the harness captures: `fakeports: kind keg is
not a thing`, and a `sh` syntax error for the plugin a test deliberately
leaves unparseable. Zig's build runner prints `failed command:` for any step
that wrote to stderr at all, so it prints one for that step too. The
authoritative signal is the exit code and the `N passed` summary; those three
lines on an exit-0 run are the fixtures working. Anything else is new.

Whether that argv is *right* is a separate gate, because it cannot be
answered without the real thing:

| Gate | Covers |
|---|---|
| `zig build test-backends` | brew, read-only, differential against brew's own output |
| `sh tests/linux_backends_test.sh` | apt, dnf (both generations), zypper, pacman -- a full install round trip per image, in containers; and Homebrew bootstrapped from its pinned installer in a Debian container, installing one formula in the same apply |
| `pwsh -NoProfile -File tests/windows_backends_test.ps1` | scoop, winget: read-only where present; on a runner without scoop, a bootstrap from the pinned installer plus one install |

All three run nightly in CI, or on demand; the Windows one runs on every
push as well, a schedule firing only from the default branch. Only the real
manager can say
whether a query's format string still yields one name per line, or whether
an image without `sudo` installs at all; the hermetic tests cannot. A skip
is never a pass: under CI every one of the three fails when a case skipped,
because there the case is the reason the job exists. A check that cannot
apply to a backend at all is reported N/A instead, and does not fail
anything: zypper's ledger reports nothing untracked by construction, so the
check that measures untracked names has nothing to measure there. A manager
only the OS can supply reads the same way: no runner image provisions
winget, and mox declares no installer for it, so a winget that will not
answer `winget --version` under a bound is N/A rather than a skip -- while
one that answers is gated like every other manager, and scoop, which mox
bootstraps from its own pinned installer, is never excused. brew's tap check
skips even under CI, needing a formula installed from a
third-party tap -- something no CI runner should do -- and says so. The brew checks compare the adapter
against Homebrew's own install receipts rather than against the command the
adapter runs, so an adapter asking the wrong question cannot agree with the
oracle.
