#!/usr/bin/env sh
# Run with: sh tests/linux_backends_test.sh [image backend package]...
#   e.g.    sh tests/linux_backends_test.sh debian:stable apt ripgrep
# With no arguments it runs every pair below.
#
# The Linux package adapters against the REAL managers, in containers.
#
# The hermetic suite asserts that an adapter EMITS a given argv; it cannot
# know whether that argv is right, or whether the manager's output parses
# back. Only the real manager can answer that: whether a query's format
# string still yields one name per line, whether an image without `sudo`
# installs at all.
#
# Each run is a full round trip against a real manager: declare a package the
# machine lacks, see it reported MISSING, install it for real, see the drift
# go clean. A mox built for the container's own platform runs inside it; the
# host needs only docker and zig.
#
# zypper is here for a second reason: it is the one manager with no
# explicitly-installed query, so its explicit set is a mox-kept ledger. This
# exercises that ledger against the real thing.
#
# brew is here for a third: the container has no brew, so its round trip
# starts with `mox apply` bootstrapping Homebrew from the pinned installer --
# the same fetch, digest check and non-interactive install a fresh machine
# gets -- before installing the package through it.
#
# Several cases run the other way round, because a name a manager resolves to
# something other than itself is a fact about the manager that no fake can
# establish: `apt-get install -y vim nano-` removes nano; `apt-get install --
# bsdextrautil.` installs bsdextrautils, apt having matched the operand as a
# regular expression; `dnf install zlib-devel` installs zlib-ng-compat-devel,
# `zlib-devel` being a capability rather than a package; `zypper install
# smtp_daemon` installs postfix and exits 0 every time after, `smtp_daemon`
# being an rpm virtual provide; `pacman -S cron` installs cronie, `cron` being
# an ALPM provision that is in no listing and no group; `pacman -S xfce4`
# installs all fourteen members of a group that `pacman -Qeq` never reports;
# `apt-get install sl:any` installs sl, which `apt-mark showmanual` then
# reports bare; and a bare operand naming a package only the foreign
# architecture has installs `name:<arch>`, which it reports qualified. Two
# more are about what the manager REFUSES to install: a held package and a
# pinned one each make `apt-get install` install nothing at all, so a row
# naming either must go rather than the batch. Three run the round trip for a
# package the manager ALREADY HAS, installed as another package's dependency,
# where an install cannot converge the row at all and only the manager's mark
# command can; three more put that same package where an install-time check
# would refuse it -- absent from every enabled dnf repository, held by
# apt-mark, on a pacman that cannot sync -- and require the mark all the
# same, because a package the machine has needs no install and so no check
# that serves one. One runs the round trip a
# multiarch machine needs, which is the one place a colon in a name is the
# name apt itself reports; one covers a machine with no package index, where
# apt's listing must come back empty; one covers a pacman database that
# is merely old, where a name it lacks must still install; one covers a
# package no repository carries, installed from a .deb, which apt would
# install and mox must therefore keep; one covers a pacman database that
# is SHORT rather than old, where a repository's groups all read as no group
# at all; one covers a name zypper has nothing at all for, which makes
# `zypper install` install none of the batch it is in; one covers a name
# pacman has nothing at all for, which makes `pacman -S` install none of the
# batch it is in the same way; one covers a zypper.conf that colours every
# table zypper writes, pipe or not; one covers a configured, synced and
# EMPTY pacman repository, which contributes no line to the listing; one
# covers a row a pacman upgrade pulls in as another package's dependency,
# which the install must still record as asked for; one covers a repository
# pacman lists but will not install from (`Usage = Sync Search`); one
# covers a zypper lock, which makes `zypper install` install none of the
# batch it is in; one covers a lock on a package installed with an update
# pending, which does the same while a lock on one at its newest does
# nothing; one covers a pacman package whose dependency no repository
# satisfies, which `pacman -S --print` refuses with the same exit code as a
# name it has nothing for; one covers a row that conflicts with an installed
# package, in each direction, which `--print` passes and the install then
# refuses as a batch; one covers the database copy under a umask of 077,
# which pacman's download user must still traverse; and one covers a stale
# lock in that copy; one covers a flat apt repository, whose single index
# puts foreign-only names in the native listing bare and a package for an
# architecture dpkg has not enabled in the batch; one covers an apt.conf
# that lists virtual names as packages; one covers an apt.conf that puts apt
# on another architecture than dpkg's, where every query still answers and
# none of them shows the difference; one covers a package dpkg left
# unpacked, which apt-mark lists as manual and only an install can finish;
# one covers a dnf.conf `assumeno=True`, which outranks `-y`; and one covers
# a dnf repository whose signing key rpm has not imported, where dnf4 asks
# about the import on the stdout a query reads its names from. The
# hermetic suite proves what the adapter does; only the real manager proves
# what the row would have done. These run with the
# default set, not from the image/backend/package arguments.
#
# A manager's IMAGE TAGS are part of what this suite covers. A floating tag
# is ONE point in a manager's version range, and an adapter can be whole at
# that point and broken a release behind it: dnf5 5.4.x (Fedora 44) accepts a
# `--` before the operands that dnf5 5.2.x (Fedora 41, 42 and 43) exits 2 on,
# so a suite running `latest` alone can be green over an adapter that installs
# nothing at all on three current releases -- and green again the day `latest`
# moves on. Cover the range: pin at least one release behind the floating tag,
# and keep the pin when the tag moves.

set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

passes=0
fails=0
skips=0
nas=0
ok() { printf '  ok   %s\n' "$1"; passes=$((passes + 1)); }
no() { printf '  FAIL %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
# A skip is never a pass. It is printed, counted, and named in the summary,
# so "this host could not run it" can never read as "this backend is fine".
skip() { printf '  SKIP %s\n      %s\n' "$1" "$2"; skips=$((skips + 1)); }
# Not a skip: the check does not apply to this backend at all, so no host and
# no runner could ever run it. Counted apart from skips, which fail CI --
# a check that was never going to run must not fail a green nightly.
na() { printf '  N/A  %s\n      %s\n' "$1" "$2"; nas=$((nas + 1)); }

# A skip is never a pass: a host without docker has not run the gate.
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found; skipping (this suite is the real-manager gate)" >&2
  exit 2
fi

# The container's platform, so the binary that runs inside it is the one the
# host can build. A runner is x86_64; an Apple-silicon workstation is arm64.
arch="$(uname -m)"
case "$arch" in
  arm64 | aarch64) platform=linux/arm64 target=aarch64-linux-musl foreign_arch=armhf ;;
  *) platform=linux/amd64 target=x86_64-linux-musl foreign_arch=i386 ;;
esac

echo "Building mox for $target"
(cd "$repo" && zig build -Dtarget="$target" --prefix "$work/out" >/dev/null)
mox_bin="$work/out/bin/mox"
[ -x "$mox_bin" ] || { echo "build produced no binary at $mox_bin" >&2; exit 1; }

# Arch publishes no arm64 image, so an Apple-silicon workstation cannot run
# that case at all. Pull first to tell "this host has no such image" apart
# from "the adapter is broken": only the second is a failure. Returns 1 when
# the case cannot run, having already reported why -- which a caller must
# swallow with `|| return 0`, or `set -e` ends the run before the summary and
# the remaining cases never happen.
pull_image() {
  image="$1"
  backend="$2"
  case_dir="$3"
  if docker pull --platform "$platform" "$image" >"$case_dir/pull.txt" 2>&1; then
    return 0
  fi
  if grep -q "no matching manifest" "$case_dir/pull.txt"; then
    skip "$backend ($image): no $platform image; run this case on an amd64 host" \
      "$(tail -1 "$case_dir/pull.txt")"
    return 1
  fi
  no "$backend ($image): docker pull failed" "$(tail -2 "$case_dir/pull.txt")"
  return 1
}

# Whether pacman can sync on this host at all, asked once and remembered.
# Every pacman check reads a database, and mox syncs its own copy to answer
# from; a host whose pacman cannot run its download sandbox -- `error
# restricting syscalls via seccomp: 22!` under x86 emulation -- fails that
# sync in every case, which is the host's limitation and not the adapter's.
# The cases that build a database of their own already tell the two apart
# with their own guard; this asks the same question for the ones that take
# the image's. Returns 1 when the case cannot run, having already reported
# why, on the same terms as `pull_image`.
pacman_sync_probe=""
pacman_can_sync() {
  image="$1"
  backend="$2"
  probe="$work/pacman-sync-probe.txt"
  if [ -z "$pacman_sync_probe" ]; then
    if docker run --rm --platform "$platform" "$image" pacman -Sy --noconfirm >"$probe" 2>&1; then
      pacman_sync_probe=ok
    else
      pacman_sync_probe=failed
    fi
  fi
  [ "$pacman_sync_probe" = ok ] && return 0
  skip "$backend ($image): pacman could not sync here, so the database every check reads could not be built" \
    "$(tail -2 "$probe")"
  return 1
}

# One round trip: declare `pkg` for `backend`, and require MISSING -> install
# -> clean against `image`.
run_case() {
  image="$1"
  backend="$2"
  pkg="$3"
  if [ "$backend" = brew ]; then
    run_brew_case "$image" "$pkg"
    return
  fi

  case_dir="$work/$backend"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/$backend.toml" <<EOF
backend = "$backend"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0
  if [ "$backend" = pacman ]; then
    pacman_can_sync "$image" "$backend" || return 0
  fi

  # `sh -c` rather than separate runs: the container is torn down each time,
  # so the install and the status that must see it have to share one.
  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      echo "--- before ---"
      /w/mox status || true
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      /w/mox status || true
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,$p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+$backend $pkg"; then
    ok "$backend ($image): a declared package the machine lacks is MISSING"
  else
    no "$backend ($image): expected '$pkg' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 1 installed, 0 failed" "$out"; then
    ok "$backend ($image): apply installed it through the real manager"
  else
    no "$backend ($image): apply did not report a successful install" "$(grep -i 'packages:\|failed' "$out" | tail -3)"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+$backend $pkg"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi

  # The query must return bare names. A format regression (dnf5 without its
  # trailing newline) runs every name together, which shows up as one absurd
  # untracked entry rather than many.
  longest="$(echo "$after" | grep "UNTRACKED $backend " | sed "s/.*UNTRACKED $backend //" | awk '{ print length }' | sort -rn | head -1)"
  # No UNTRACKED name is N/A, never a skip: the explicit set drives MISSING as
  # well as UNTRACKED, so a query that came back empty or garbled has already
  # failed the check above. Nothing untracked can only mean the set holds
  # exactly what mox declared, which no runner can change.
  if [ -z "$longest" ]; then
    if [ "$backend" = zypper ]; then
      na "$backend ($image): installed names come back one per line" \
        "zypper never reports UNTRACKED by design (its explicit set is the ledger intersected with rpm, so it holds only what mox declared), leaving no name to measure"
    else
      na "$backend ($image): installed names come back one per line" \
        "$image marks nothing else as explicitly installed, so $backend's explicit set is the declared package alone and there is no other name to measure"
    fi
  elif [ "$longest" -lt 80 ]; then
    ok "$backend ($image): installed names come back one per line"
  else
    no "$backend ($image): an untracked name is $longest chars; the query lost its separator" \
      "$(echo "$after" | grep "UNTRACKED $backend " | head -1 | cut -c1-100)"
  fi
}

# Homebrew's own installer at a fixed commit, and what it must hash to; a
# fresh machine's manifest carries the same pair.
brew_installer_url="https://raw.githubusercontent.com/Homebrew/install/c8188c1d48d77234a458b944d1d1b750f015a1c4/install.sh"
brew_installer_sha256="12479a24be3f5307eecac7cde670fad7118640f031229e964f544b1367b52a41"

# The brew round trip: no brew in the image, so `mox apply` must bootstrap it
# from the declared installer and install `pkg` through it in the same run.
# Homebrew refuses to install as root, so the run is a plain user with
# passwordless sudo, which the installer itself needs on Linux to create its
# prefix. The status afterwards sees brew only with that prefix on PATH: a
# new process inherits nothing from the apply that installed it.
run_brew_case() {
  image="$1"
  pkg="$2"
  backend=brew

  case_dir="$work/$backend"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/$backend.toml" <<EOF
backend = "brew"

[[bootstrap]]
url = "$brew_installer_url"
sha256 = "$brew_installer_sha256"

[[packages]]
name = "$pkg"
EOF
  cat >"$case_dir/user.sh" <<'EOF'
set -e
export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/home/tester
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
/w/mox apply || true
echo "--- after ---"
PATH="/home/linuxbrew/.linuxbrew/bin:$PATH" /w/mox status || true
EOF
  # What Homebrew's installer needs on Debian, and a user it will run as.
  cat >"$case_dir/root.sh" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends sudo curl ca-certificates git procps file build-essential >/dev/null
useradd -m -s /bin/bash tester
echo "tester ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/tester
chmod -R a+rwX /w
exec su tester -c "sh /w/user.sh"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh /w/root.sh >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  apply="$(sed -n '/--- apply ---/,/--- after ---/p' "$out")"
  after="$(sed -n '/--- after ---/,$p' "$out")"

  # The label column's width is mox's business, not this gate's.
  if echo "$apply" | grep -qE "bootstrapping[[:space:]]+$backend"; then
    ok "$backend ($image): an absent manager is bootstrapped from its declared installer"
  else
    no "$backend ($image): apply did not bootstrap $backend" "$(echo "$apply" | tail -5)"
  fi

  if echo "$apply" | grep -q "Packages: 1 installed, 0 failed"; then
    ok "$backend ($image): the same apply installed through the manager it just bootstrapped"
  else
    no "$backend ($image): apply did not report a successful install" "$(echo "$apply" | grep -i 'packages:\|failed\|bootstrap' | tail -3)"
  fi

  if echo "$after" | grep -qE "clean[[:space:]]+$backend$|UNTRACKED[[:space:]]+$backend "; then
    ok "$backend ($image): the bootstrapped manager answers a fresh status"
  else
    no "$backend ($image): status after apply got no answer from $backend" "$(echo "$after" | tail -5)"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+$backend $pkg"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi
}

# A row named `nano-` is apt's remove form, not a package. The row must be
# refused by `mox status` -- which never runs apt at all -- and the nano the
# image has installed must still be there afterwards.
run_remove_suffix_case() {
  image="$1"
  backend="apt remove-suffix"

  case_dir="$work/remove-suffix"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "nano-"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  # nano is installed first so its survival is a fact about this run, not
  # about what the image happened to ship.
  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      apt-get update >/dev/null
      apt-get install -y nano >/dev/null
      [ -x /bin/nano ] || { echo "nano did not install; the case cannot run"; exit 1; }
      echo "--- status ---"
      rc=0
      /w/mox status || rc=$?
      echo "status-exit=$rc"
      echo "--- nano ---"
      [ -x /bin/nano ] && echo "nano=present" || echo "nano=gone"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  # The message names the file, the row and the rule the name broke.
  if grep -q 'data/packages/apt.toml: row "nano-": apt rows name a package: a name does not end with "-"' "$out"; then
    ok "$backend ($image): the row is refused, naming the file, the row and the reason"
  else
    no "$backend ($image): status did not refuse the row with the expected message" "$(grep -i 'packages:' "$out" | tail -3)"
  fi

  if grep -q "status-exit=0" "$out"; then
    no "$backend ($image): a refused package pass exited 0" "$(grep 'status-exit=' "$out")"
  else
    ok "$backend ($image): a refused package pass is counted in the exit code"
  fi

  if grep -q "nano=present" "$out"; then
    ok "$backend ($image): nano is still installed; the row never reached apt"
  else
    no "$backend ($image): nano was removed" "$(tail -5 "$out")"
  fi
}

# A row named `bsdextrautil.` is not a package: apt falls back to matching an
# install operand as an unanchored regex, and installs bsdextrautils. mox must
# refuse the batch, naming the row, and leave the collateral uninstalled.
run_regex_operand_case() {
  image="$1"
  backend="apt regex-operand"

  case_dir="$work/regex-operand"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "bsdextrautil."

[[packages]]
name = "sl"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      dpkg -s bsdextrautils >/dev/null 2>&1 && { echo "the image ships bsdextrautils; the case cannot run"; exit 1; }
      dpkg -s sl >/dev/null 2>&1 && { echo "the image ships sl; the case cannot run"; exit 1; }
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      dpkg -s bsdextrautils >/dev/null 2>&1 && echo "collateral=present" || echo "collateral=absent"
      dpkg -s sl >/dev/null 2>&1 && echo "sibling=present" || echo "sibling=absent"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q 'mox: apt: row "bsdextrautil." names no apt package' "$out"; then
    ok "$backend ($image): the row is refused, naming it and what apt would have done"
  else
    no "$backend ($image): apply did not refuse the row with the expected message" "$(tail -5 "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi

  if grep -q "collateral=absent" "$out"; then
    ok "$backend ($image): bsdextrautils was never installed; the manifest declares no such package"
  else
    no "$backend ($image): apt installed a package the manifest never declared" "$(tail -5 "$out")"
  fi

  # One row nobody can install must not keep every other package off the
  # machine: the refusal is that row's failure, not the batch's.
  if grep -q "sibling=present" "$out" && grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it installed, and the refusal is counted as one row's failure"
  else
    no "$backend ($image): a refused row stopped the rows that were fine" \
      "$(grep -E 'sibling=|Packages:' "$out" | tail -3)"
  fi
}

# A package that exists ONLY for the foreign architecture is the case
# `apt-cache --generate pkgnames` cannot answer: measured on Debian trixie,
# that listing holds bare names alone and omits `wine32` altogether, while apt
# resolves and installs `wine32:<foreign>` and `apt-mark showmanual` reports
# exactly that. The row must round-trip, and the good row beside it must land.
run_foreign_only_case() {
  image="$1"
  foreign="$2"
  backend="apt foreign-only"

  case_dir="$work/foreign-only"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<EOF
backend = "apt"

[[packages]]
name = "wine32:$foreign"

[[packages]]
name = "sl"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      dpkg --add-architecture '"$foreign"'
      apt-get update >/dev/null
      # The premise of the case: the name exists for the foreign
      # architecture and for no other, and apts own listing omits it.
      apt-cache --generate pkgnames | grep -qx wine32 && { echo "this apt lists wine32 bare; the case cannot run"; exit 1; }
      echo "--- before ---"
      /w/mox status || true
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      /w/mox status || true
      echo "--- showmanual ---"
      apt-mark showmanual | grep -x "wine32:'"$foreign"'" || echo "not-manual"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- showmanual ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+apt wine32:$foreign"; then
    ok "$backend ($image): a package only the foreign architecture has is MISSING"
  else
    no "$backend ($image): expected 'wine32:$foreign' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 2 installed, 0 failed" "$out"; then
    ok "$backend ($image): it installed through the real apt, beside the row next to it"
  else
    no "$backend ($image): apply did not install both rows" "$(grep -i 'packages:\|^mox: apt' "$out" | tail -3)"
  fi

  # apt-mark is what mox reads back, so the qualified name must be in it.
  if grep -qx "wine32:$foreign" "$out"; then
    ok "$backend ($image): apt-mark reports it under the qualified name"
  else
    no "$backend ($image): apt-mark did not report wine32:$foreign" "$(sed -n '/--- showmanual ---/,$p' "$out")"
  fi

  if echo "$after" | grep -qE "(MISSING|UNTRACKED)[[:space:]]+apt wine32:$foreign"; then
    no "$backend ($image): drift over wine32:$foreign survived apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi
}

# A package that exists only for the foreign architecture and that apt's own
# listing prints BARE. `run_foreign_only_case` covers the name the listing
# omits; this covers the 78 of trixie's 90 armhf-only names it prints, where a
# bare row is kept, apt installs the foreign package, and `apt-mark showmanual`
# reports it qualified -- missing and untracked for ever. The name is found in
# the container rather than fixed here, because which names these are differs
# per release and per architecture pair.
run_foreign_only_bare_case() {
  image="$1"
  foreign="$2"
  backend="apt foreign-only-bare"

  case_dir="$work/foreign-only-bare"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      foreign='"$foreign"'
      native="$(dpkg --print-architecture)"
      dpkg --add-architecture "$foreign"
      apt-get update >/dev/null

      decode() {
        case "$1" in
          *.lz4) /usr/lib/apt/apt-helper cat-file "$1" ;;
          *.gz) zcat "$1" ;;
          *.xz) xzcat "$1" ;;
          *) cat "$1" ;;
        esac
      }
      cd /var/lib/apt/lists
      for arch in "$native" "$foreign"; do
        for f in *binary-${arch}_Packages*; do decode "$f"; done |
          awk "/^Package: /{print \$2}" | sort -u > "/tmp/$arch.txt"
      done
      apt-cache --generate pkgnames | sort -u > /tmp/all.txt
      # In the foreign index, in no native index, and printed bare all the
      # same: the case the plain listing cannot answer.
      comm -13 "/tmp/$native.txt" "/tmp/$foreign.txt" | comm -12 - /tmp/all.txt > /tmp/cand.txt
      pkg="$(head -1 /tmp/cand.txt)"
      [ -n "$pkg" ] || { echo "no foreign-only name is listed bare here; the case cannot run"; exit 1; }
      echo "pkg=$pkg"
      echo "bare-listed=$(grep -cx "$pkg" /tmp/all.txt)"
      # The harm, without installing it: apt resolves the bare operand to the
      # foreign package, which is what it would have put on the machine.
      apt-get install -s -y -- "$pkg" 2>&1 | grep -q "$pkg:$foreign" &&
        echo "resolves=$pkg:$foreign" || echo "resolves=none"

      cat > /w/repo/data/packages/apt.toml <<TOML
backend = "apt"

[[packages]]
name = "$pkg"

[[packages]]
name = "sl"
TOML
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- installed ---"
      dpkg -l "$pkg" 2>/dev/null | grep -c "^ii" || echo 0
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  pkg="$(sed -n 's/^pkg=//p' "$out")"

  if grep -q "^bare-listed=1" "$out"; then
    ok "$backend ($image): apt's plain listing prints the foreign-only name bare"
  else
    no "$backend ($image): the premise does not hold; the name is not listed bare" "$(grep '^bare-listed=' "$out")"
  fi

  if grep -q "^resolves=$pkg:$foreign" "$out"; then
    ok "$backend ($image): apt would resolve the bare operand to the foreign package"
  else
    no "$backend ($image): apt did not resolve the bare operand to $pkg:$foreign" "$(grep '^resolves=' "$out")"
  fi

  if grep -q "row \"$pkg\" names an apt package for the architecture \"$foreign\" alone" "$out" &&
    grep -q "declare \"$pkg:$foreign\" instead" "$out"; then
    ok "$backend ($image): the row is refused, and told the spelling apt reports back"
  else
    no "$backend ($image): the bare foreign-only row was not refused" "$(grep -E '^mox: apt|Packages:' "$out" | tail -3)"
  fi

  if grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it still installed"
  else
    no "$backend ($image): a refused row stopped the row that was fine" "$(grep -E 'Packages:' "$out")"
  fi

  if [ "$(tail -1 "$out")" = "0" ]; then
    ok "$backend ($image): nothing the manifest never declared landed"
  else
    no "$backend ($image): apt installed the foreign package after all" "$(tail -2 "$out")"
  fi
}

# A held package and a pinned one each make apt-get install NOTHING at all, so
# one of them in a batch keeps every other package in the manifest off the
# machine. Both must be refused at check time, as rows, and the hold must
# survive: it is the user's decision, not mox's to override.
run_apt_hold_pin_case() {
  image="$1"
  backend="apt hold-pin"

  case_dir="$work/apt-hold-pin"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "sl"

[[packages]]
name = "cowsay"

[[packages]]
name = "bsdextrautils"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      apt-get update >/dev/null
      apt-get purge -y bsdextrautils >/dev/null 2>&1 || true
      apt-mark hold sl >/dev/null
      printf "Package: cowsay\nPin: release *\nPin-Priority: -1\n" > /etc/apt/preferences.d/no-cowsay
      # The harm, measured here rather than assumed: a batch carrying either
      # one installs nothing at all.
      rc=0; apt-get install -y -qq -- sl bsdextrautils >/tmp/h.txt 2>&1 || rc=$?
      echo "hold-batch-exit=$rc"
      echo "hold-collateral=$(dpkg -l bsdextrautils 2>/dev/null | grep -c "^ii" || true)"
      rc=0; apt-get install -y -qq -- cowsay bsdextrautils >/tmp/p.txt 2>&1 || rc=$?
      echo "pin-batch-exit=$rc"
      echo "pin-collateral=$(dpkg -l bsdextrautils 2>/dev/null | grep -c "^ii" || true)"
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      echo "installed=$(dpkg -l bsdextrautils 2>/dev/null | grep -c "^ii" || true)"
      echo "still-held=$(apt-mark showhold | grep -cx sl || true)"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^hold-batch-exit=100" "$out" && grep -q "^hold-collateral=0" "$out" &&
    grep -q "^pin-batch-exit=100" "$out" && grep -q "^pin-collateral=0" "$out"; then
    ok "$backend ($image): a held or pinned operand makes apt-get install nothing at all"
  else
    no "$backend ($image): the premise does not hold on this apt" "$(grep -E '^(hold|pin)-' "$out")"
  fi

  if grep -q 'row "sl" names a package apt-mark holds' "$out"; then
    ok "$backend ($image): the held row is refused by name"
  else
    no "$backend ($image): the held row was not refused" "$(grep -E '^mox: apt' "$out" | tail -3)"
  fi

  if grep -q 'row "cowsay" names a package apt has no installation candidate for' "$out"; then
    ok "$backend ($image): the pinned row is refused by name"
  else
    no "$backend ($image): the pinned row was not refused" "$(grep -E '^mox: apt' "$out" | tail -3)"
  fi

  if grep -q "^installed=1" "$out" && grep -q "Packages: 1 installed, 2 failed" "$out"; then
    ok "$backend ($image): the row beside them installed"
  else
    no "$backend ($image): two refused rows kept the third off the machine" \
      "$(grep -E '^installed=|Packages:' "$out")"
  fi

  if grep -q "^still-held=1" "$out" && ! grep -q "allow-change-held-packages" "$out"; then
    ok "$backend ($image): the hold is left as its owner set it"
  else
    no "$backend ($image): the run overrode the hold" "$(grep -E '^still-held=' "$out")"
  fi
}

# The pin refusal under a locale apt translates. `apt-cache policy` is the
# query that says whether a pin rejects every version of a package, and it
# prints its `Candidate:` line in the user's language: on apt 3.0.3 under
# ja_JP.UTF-8 the word is Japanese, so a parser reading the English word finds
# no line at all, keeps the pinned row, and the install exits 100 having put
# nothing on the machine -- the very batch failure the refusal exists to
# prevent. mox pins every captured call to the C locale, and this holds it
# to that: the locale is generated in the container, the harm measured on
# the raw query, and the apply run with that locale exported.
run_apt_pin_locale_case() {
  image="$1"
  backend="apt pin-locale"

  case_dir="$work/apt-pin-locale"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF2'
backend = "apt"

[[packages]]
name = "cowsay"

[[packages]]
name = "bsdextrautils"
EOF2

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      apt-get update >/dev/null
      apt-get install -y -qq locales >/dev/null 2>&1
      sed -i "s/^# *ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/" /etc/locale.gen
      locale-gen >/dev/null
      apt-get purge -y bsdextrautils >/dev/null 2>&1 || true
      printf "Package: cowsay\nPin: release *\nPin-Priority: -1\n" > /etc/apt/preferences.d/no-cowsay
      export LANG=ja_JP.UTF-8
      unset LC_ALL LANGUAGE
      # The harm, measured on the raw query: the stanza is there, the
      # English field name is not.
      apt-cache policy cowsay >/tmp/policy.txt 2>&1 || true
      echo "policy-stanza=$(grep -c "^cowsay:" /tmp/policy.txt || true)"
      echo "policy-candidate-english=$(grep -c "Candidate:" /tmp/policy.txt || true)"
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      echo "installed=$(dpkg -l bsdextrautils 2>/dev/null | grep -c "^ii" || true)"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^policy-stanza=1" "$out" && grep -q "^policy-candidate-english=0" "$out"; then
    ok "$backend ($image): apt-cache policy translates its Candidate line under ja_JP.UTF-8"
  else
    no "$backend ($image): the premise does not hold on this apt" "$(grep -E '^policy-' "$out")"
  fi

  if grep -q 'row "cowsay" names a package apt has no installation candidate for' "$out"; then
    ok "$backend ($image): the pinned row is refused by name under ja_JP.UTF-8"
  else
    no "$backend ($image): the pinned row was not refused under ja_JP.UTF-8" "$(grep -E '^mox: apt|^E:' "$out" | tail -3)"
  fi

  if grep -q "^installed=1" "$out" && grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it installed under ja_JP.UTF-8"
  else
    no "$backend ($image): the pinned row kept the other off the machine" \
      "$(grep -E '^installed=|Packages:' "$out")"
  fi
}

# A machine with no package index at all. The plain listing still prints the
# dpkg status file's own packages there -- 78 lines on trixie, 88 on bookworm
# -- so it cannot tell that machine apart from a working one; the listing the
# adapter asks for excludes the status file, and comes back empty.
run_apt_no_repositories_case() {
  image="$1"
  backend="apt no-repositories"

  case_dir="$work/apt-no-repos"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "sl"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      rm -f /etc/apt/sources.list
      rm -f /etc/apt/sources.list.d/*
      apt-get update >/dev/null 2>&1 || true
      native="$(dpkg --print-architecture)"
      echo "plain=$(apt-cache --generate pkgnames | grep -c . || true)"
      echo "asked=$(apt-cache -o APT::Architectures=$native -o Dir::State::status=/dev/null --generate pkgnames | grep -c . || true)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^plain=0" "$out"; then
    no "$backend ($image): the premise does not hold; the plain listing is already empty" "$(grep '^plain=' "$out")"
  else
    ok "$backend ($image): the plain listing still prints the status file's packages"
  fi

  if grep -q "^asked=0" "$out"; then
    ok "$backend ($image): the listing the adapter asks for is empty, which is the signal"
  else
    no "$backend ($image): the listing is not empty on a machine with no index" "$(grep '^asked=' "$out")"
  fi

  if grep -q "lists no packages at all, which is a machine with no repositories configured" "$out"; then
    ok "$backend ($image): the run says the machine has no repositories, not that the row names none"
  else
    no "$backend ($image): the guard did not fire" "$(grep -E '^mox|Packages:' "$out" | tail -3)"
  fi
}

# apt's resolution architecture is a setting of its own, and dpkg's is what
# both halves of mox's apt oracle key on. Under `APT::Architecture "<foreign>";`
# every query still answers and none of them shows the difference: `dpkg
# --print-architecture` keeps saying the native one, `apt-cache policy sl`
# heads the stanza BARE over a version table holding the foreign package
# alone, `apt-cache madison sl` reports the foreign line alone, and the native
# listing still carries the name. So the row passes every refusal and the
# install fails on dependencies, taking the whole batch with it on every apply
# after. The same setting makes `apt-mark showmanual` answer about apt's
# architecture rather than dpkg's, and every name it then prints is installed
# and configured, so `status` would report each of them untracked.
run_apt_arch_desync_case() {
  image="$1"
  foreign="$2"
  backend="apt arch-desync"

  case_dir="$work/apt-arch-desync"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "sl"

[[packages]]
name = "hello"
EOF
  cat >"$case_dir/case.sh" <<CASE
set -e
export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
foreign=$foreign
CASE
  cat >>"$case_dir/case.sh" <<'CASE'
apt-get --version | head -1
native="$(dpkg --print-architecture)"
dpkg --add-architecture "$foreign"
apt-get update >/dev/null
echo "manual-agreeing=$(apt-mark showmanual | grep -c . || true)"

printf 'APT::Architecture "%s";\n' "$foreign" > /etc/apt/apt.conf.d/99mox-arch
echo "--- premise ---"
echo "dpkg=$native"
apt-config dump APT::Architecture
echo "policy-header=$(apt-cache policy sl | head -1)"
echo "madison=$(apt-cache madison sl | head -1)"
echo "listed=$(apt-cache -o "APT::Architectures=$native" -o Dir::State::status=/dev/null -o APT::Cache::AllNames=false --generate pkgnames | grep -cx sl || true)"
echo "manual-desync=$(apt-mark showmanual | grep -c . || true)"
echo "--- status ---"
/w/mox status || true
echo "--- apply ---"
rc=0
/w/mox apply || rc=$?
echo "apply-exit=$rc"
echo "installed=$(dpkg-query -W -f '${Status}' sl 2>/dev/null | grep -c 'ok installed' || true)"

echo "--- agreeing ---"
printf 'APT::Architecture "%s";\n' "$native" > /etc/apt/apt.conf.d/99mox-arch
rc=0
/w/mox apply || rc=$?
echo "agree-exit=$rc"
echo "agree-installed=$(dpkg-query -W -f '${Status}' sl 2>/dev/null | grep -c 'ok installed' || true)"
echo "--- after ---"
/w/mox status || true
CASE

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh /w/case.sh >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  premise="$(sed -n '/--- premise ---/,/--- status ---/p' "$out")"
  if echo "$premise" | grep -q "^dpkg=" && echo "$premise" | grep -qx "APT::Architecture \"$foreign\";"; then
    ok "$backend ($image): apt resolves against $foreign while dpkg still reports its own"
  else
    no "$backend ($image): the premise does not hold; apt and dpkg agree here" "$premise"
  fi

  if echo "$premise" | grep -qx "policy-header=sl:" && echo "$premise" | grep -q "^madison=.* $foreign Packages$"; then
    ok "$backend ($image): policy heads the stanza bare and madison names the foreign package, so no parse can see it"
  else
    no "$backend ($image): policy or madison showed the difference, so this case proves nothing" "$premise"
  fi

  if echo "$premise" | grep -qx "listed=1"; then
    ok "$backend ($image): the native listing still carries the name, so the row passes every refusal"
  else
    no "$backend ($image): the listing does not carry the name" "$premise"
  fi

  if [ "$(sed -n 's/^manual-agreeing=//p' "$out")" != "$(sed -n 's/^manual-desync=//p' "$out")" ]; then
    ok "$backend ($image): apt-mark answers about apt's architecture, so the explicit set is another machine's"
  else
    no "$backend ($image): apt-mark reported the same set either way" \
      "$(grep -E '^manual-' "$out")"
  fi

  if grep -q 'mox: apt: apt'"'"'s own APT::Architecture is "'"$foreign"'" while dpkg'"'"'s architecture is' "$out" &&
    grep -q 'unset APT::Architecture so apt agrees with `dpkg --print-architecture`' "$out"; then
    ok "$backend ($image): the pass is refused, naming the setting and both architectures"
  else
    no "$backend ($image): the machine-level refusal did not fire" "$(grep -E '^mox: apt|Packages:' "$out" | tail -3)"
  fi

  if grep -q "^apply-exit=0$" "$out" || grep -q "^installed=1" "$out"; then
    no "$backend ($image): the apply went ahead under the disagreement" \
      "$(grep -E '^apply-exit=|^installed=' "$out")"
  else
    ok "$backend ($image): nothing was installed and the run exits non-zero"
  fi

  status="$(sed -n '/--- status ---/,/--- apply ---/p' "$out")"
  if echo "$status" | grep -q "BROKEN *apt" && ! echo "$status" | grep -q "UNTRACKED *apt"; then
    ok "$backend ($image): status calls apt broken rather than reporting another machine's packages untracked"
  else
    no "$backend ($image): status did not refuse the apt pass" "$status"
  fi

  if grep -q "^agree-exit=0$" "$out" && grep -q "^agree-installed=1" "$out"; then
    ok "$backend ($image): the setting agreeing with dpkg refuses nothing and installs as usual"
  else
    no "$backend ($image): a setting that agrees with dpkg was refused" \
      "$(grep -E '^agree-exit=|^agree-installed=' "$out")"
  fi

  after="$(sed -n '/--- after ---/,$p' "$out")"
  if echo "$after" | grep -qE "(MISSING|UNTRACKED|BROKEN) +apt"; then
    no "$backend ($image): drift over apt survived the agreeing apply" "$after"
  else
    ok "$backend ($image): the drift is clean once apt and dpkg agree"
  fi
}

# A pacman database that is merely OLD, which is the normal state of an Arch
# machine between upgrades. A name it has never heard of must NOT be refused:
# the check syncs mox's own copy of the database and reads that, so the old
# database is never what a row is judged by -- and is left as old as it was
# until the install's own `-Syu` brings it forward.
run_pacman_stale_case() {
  image="$1"
  backend="pacman stale"

  case_dir="$work/pacman-stale"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "uv"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      cp /etc/pacman.d/mirrorlist /tmp/mirrorlist
      echo "Server=https://archive.archlinux.org/repos/2024/01/01/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "archive-sync=failed"; exit 0; }
      cp /tmp/mirrorlist /etc/pacman.d/mirrorlist
      echo "archive-sync=ok"
      echo "stale-names=$(pacman -Slq | grep -c . || true)"
      echo "stale-has-uv=$(pacman -Slq | grep -cx uv || true)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "installed=$(pacman -Qq uv >/dev/null 2>&1 && echo 1 || echo 0)"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^archive-sync=failed" "$out"; then
    skip "$backend ($image): the Arch archive did not answer, so no stale database could be built" \
      "$(tail -2 "$out")"
    return
  fi

  if grep -q "^stale-has-uv=0" "$out" && ! grep -q "^stale-names=0" "$out"; then
    ok "$backend ($image): the database is stale, not empty, and does not carry the name"
  else
    no "$backend ($image): the premise does not hold" "$(grep -E '^stale-' "$out")"
  fi

  if grep -q "names no pacman package" "$out"; then
    no "$backend ($image): an installable row was refused for being absent from a stale database" \
      "$(grep 'names no pacman package' "$out")"
  else
    ok "$backend ($image): a name the stale database lacks is not refused against it"
  fi

  if grep -q "^installed=1" "$out" && grep -q "^apply-exit=0" "$out"; then
    ok "$backend ($image): the check's own copy of the database resolved it, and it installed"
  else
    no "$backend ($image): the row did not install" "$(grep -E '^installed=|^apply-exit=|Packages:' "$out")"
  fi
}

# A foreign-architecture package is the one name apt reports with a colon in
# it, so declaring it must round-trip: MISSING -> install -> clean.
run_multiarch_case() {
  image="$1"
  foreign="$2"
  backend="apt multiarch"

  case_dir="$work/multiarch"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<EOF
backend = "apt"

[[packages]]
name = "libc6:$foreign"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      dpkg --add-architecture '"$foreign"'
      apt-get update >/dev/null
      echo "--- before ---"
      /w/mox status || true
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      /w/mox status || true
      echo "--- showmanual ---"
      apt-mark showmanual | grep ":'"$foreign"'" || echo "not-manual"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- showmanual ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+apt libc6:$foreign"; then
    ok "$backend ($image): a foreign-architecture package the machine lacks is MISSING"
  else
    no "$backend ($image): expected 'libc6:$foreign' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 1 installed, 0 failed" "$out"; then
    ok "$backend ($image): apply installed it through the real apt"
  else
    no "$backend ($image): apply did not report a successful install" "$(grep -i 'packages:\|failed' "$out" | tail -3)"
  fi

  # apt-mark is what mox reads back, so the qualified name must be in it.
  if grep -q "^libc6:$foreign" "$out"; then
    ok "$backend ($image): apt-mark reports the package under the qualified name"
  else
    no "$backend ($image): apt-mark did not report libc6:$foreign" "$(sed -n '/--- showmanual ---/,$p' "$out")"
  fi

  if echo "$after" | grep -qE "(MISSING|UNTRACKED)[[:space:]]+apt libc6:$foreign"; then
    no "$backend ($image): drift over libc6:$foreign survived apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi
}

# `zlib-devel` is not a package in Fedora; it is a capability that
# zlib-ng-compat-devel provides. The row must be refused with the name to
# write in its place, and nothing installed behind the user's back.
run_provide_name_case() {
  image="$1"
  backend="dnf provide-name"

  case_dir="$work/provide-name"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/dnf.toml" <<'EOF'
backend = "dnf"

[[packages]]
name = "zlib-devel"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      rpm -q zlib-devel >/dev/null 2>&1 && { echo "this image has a real zlib-devel; the case cannot run"; exit 1; }
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      rpm -q zlib-ng-compat-devel >/dev/null 2>&1 && echo "collateral=present" || echo "collateral=absent"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  # The message must carry the name to declare, or the user is left with a
  # row that fails on every apply and no way to learn what to write.
  if grep -q 'mox: dnf: row "zlib-devel" names no dnf package; it is a capability provided by "zlib-ng-compat-devel"' "$out"; then
    ok "$backend ($image): the row is refused, naming the package that provides it"
  else
    no "$backend ($image): apply did not name the real package" "$(tail -5 "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi

  if grep -q "collateral=absent" "$out"; then
    ok "$backend ($image): zlib-ng-compat-devel was never installed; the manifest declares no such package"
  else
    no "$backend ($image): dnf installed a package the manifest never declared" "$(tail -5 "$out")"
  fi
}

# apt reads `:native`, `:all` and `:any` as the native package, and `apt-mark
# showmanual` reports what it installed under the bare name -- so a row
# spelling one installs and is MISSING on every status after. Each must be
# refused with the bare name to declare instead, and nothing installed.
run_apt_native_alias_case() {
  image="$1"
  backend="apt native-alias"

  case_dir="$work/native-alias"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "bsdextrautils:native"

[[packages]]
name = "bsdmainutils:all"

[[packages]]
name = "sl:any"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      for p in bsdextrautils bsdmainutils sl; do
        dpkg -s "$p" >/dev/null 2>&1 && { echo "the image ships $p; the case cannot run"; exit 1; }
      done
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      for p in bsdextrautils bsdmainutils sl; do
        dpkg -s "$p" >/dev/null 2>&1 && echo "collateral=$p" || true
      done
      echo "collateral-end"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  missed=""
  for pair in 'bsdextrautils:native bsdextrautils' 'bsdmainutils:all bsdmainutils' 'sl:any sl'; do
    row="${pair% *}"
    bare="${pair#* }"
    grep -q "row \"$row\" carries the qualifier .*declare \"$bare\" instead" "$out" || missed="$missed $row"
  done
  if [ -z "$missed" ]; then
    ok "$backend ($image): every qualifier apt reads as native is refused, naming the bare row"
  else
    no "$backend ($image): rows not refused with the bare name to declare:$missed" "$(tail -5 "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi

  if grep -q "^collateral=" "$out"; then
    no "$backend ($image): apt installed a package under a name the row could never read back" "$(grep '^collateral=' "$out")"
  else
    ok "$backend ($image): none of the three landed; the rows never reached apt"
  fi
}

# `fprint` is a package GROUP: `pacman -S fprint` installs libfprint and
# fprintd, and `pacman -Qeq` reports those two and never the group -- so the
# row is MISSING on every status while the machine carries two packages no
# manifest declares. The row must be refused, naming the members.
run_pacman_group_case() {
  image="$1"
  backend="pacman group"

  case_dir="$work/pacman-group"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "fprint"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0
  pacman_can_sync "$image" "$backend" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      for p in libfprint fprintd; do
        pacman -Q "$p" >/dev/null 2>&1 && { echo "the image ships $p; the case cannot run"; exit 1; }
      done
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      for p in libfprint fprintd; do
        pacman -Q "$p" >/dev/null 2>&1 && echo "collateral=$p" || true
      done
      echo "collateral-end"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  # The message must name the members, or the user is left with a row that
  # fails on every apply and nothing to write in its place.
  if grep -q 'mox: pacman: row "fprint" names no pacman package; it is a group of 2 packages ("fprintd", "libfprint")' "$out"; then
    ok "$backend ($image): the row is refused, naming the packages the group holds"
  else
    no "$backend ($image): apply did not refuse the group with its members named" "$(tail -5 "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi

  if grep -q "^collateral=" "$out"; then
    no "$backend ($image): pacman installed group members the manifest never declared" "$(grep '^collateral=' "$out")"
  else
    ok "$backend ($image): no member of the group landed; the row never reached pacman"
  fi
}

# A pacman package built by hand, for a repository the case controls:
# `mkpkg name ver depend outdir [conflict]` writes `outdir/name-ver-any.pkg.tar`,
# which `repo-add` takes. bsdtar and repo-add both ship with pacman; makepkg
# would need fakeroot, which a base install does not.
pacman_mkpkg='mkpkg() {
  d=/tmp/mkpkg/$1-$2
  rm -rf "$d"
  mkdir -p "$d/usr/share/$1"
  echo "$1 $2" > "$d/usr/share/$1/README"
  {
    printf "pkgname = %s\npkgver = %s\npkgdesc = a test package\nurl = http://localhost\nbuilddate = 0\npackager = mox\nsize = 0\narch = any\n" "$1" "$2"
    if [ -n "$3" ]; then printf "depend = %s\n" "$3"; fi
    if [ -n "${5:-}" ]; then printf "conflict = %s\n" "$5"; fi
    if [ -n "${6:-}" ]; then printf "replaces = %s\n" "$6"; fi
  } > "$d/.PKGINFO"
  (cd "$d" && bsdtar -cf "$4/$1-$2-any.pkg.tar" .PKGINFO usr)
}
'

# What a pacman apply does to the SYSTEM. A check never mutates it: the
# check syncs mox's own copy of the sync database and reads that, so an
# apply whose every row is refused leaves the system's sync database as it
# was -- absent, on a machine that has never synced -- and pacman's log
# without a line, however many times it runs. The install is the one write,
# and it is the single `pacman -Syu --needed` transaction. Three group-only
# applies first, then one with a real package; the system's database
# directory, pacman's own log and its pending-upgrade count say what
# happened.
run_pacman_sync_case() {
  image="$1"
  backend="pacman sync"

  case_dir="$work/pacman-sync"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  # A group: refused, so every path after the database read is the one
  # that must leave the system alone.
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "fprint"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0
  pacman_can_sync "$image" "$backend" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      [ -f /var/lib/pacman/sync/core.db ] && { echo "this image ships a synced database; the case cannot run"; exit 1; }
      pacman -Q ripgrep >/dev/null 2>&1 && { echo "the image ships ripgrep; the case cannot run"; exit 1; }
      echo "--- three refused applies ---"
      log_before=$(grep -c "\[PACMAN\] Running" /var/log/pacman.log 2>/dev/null || true)
      refusals=0
      for i in 1 2 3; do
        rc=0
        /w/mox apply >/tmp/apply-$i.txt 2>&1 || rc=$?
        echo "apply-$i-exit=$rc"
        grep -q "names no pacman package" /tmp/apply-$i.txt && refusals=$((refusals + 1))
      done
      cat /tmp/apply-1.txt
      echo "refusals=$refusals"
      echo "system-dbs-after-refusals=$(ls /var/lib/pacman/sync 2>/dev/null | grep -c "\.db$" || true)"
      log_after=$(grep -c "\[PACMAN\] Running" /var/log/pacman.log 2>/dev/null || true)
      echo "pacman-runs-during-refusals=$((log_after - log_before))"
      echo "private-dbs=$(ls /var/cache/mox/pacman-db/sync 2>/dev/null | grep -c "\.db$" || true)"
      echo "--- one install ---"
      printf "backend = \"pacman\"\n\n[[packages]]\nname = \"ripgrep\"\n" > /w/repo/data/packages/pacman.toml
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- pending upgrades ---"
      pacman -Qu > /tmp/pending.txt 2>&1 || true
      echo "pending=$(grep -c . /tmp/pending.txt)"
      echo "upgrades=$(grep -c "Running .pacman -Syu" /var/log/pacman.log || true)"
      echo "bare-syncs=$(grep -c "Running .pacman -Sy " /var/log/pacman.log || true)"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^refusals=3" "$out"; then
    ok "$backend ($image): the group is refused on every apply"
  else
    no "$backend ($image): the row was not refused each time" "$(grep -E '^refusals=|^apply-[123]-exit=' "$out")"
  fi

  # A check never mutates the system: after three applies that installed
  # nothing, the system has no sync database and pacman logged nothing,
  # while mox's own copy answered.
  if grep -q "^system-dbs-after-refusals=0" "$out" && grep -q "^pacman-runs-during-refusals=0" "$out"; then
    ok "$backend ($image): three refused applies left the system's database and log untouched"
  else
    no "$backend ($image): a refused apply wrote to the system" "$(grep -E '^system-dbs-|^pacman-runs-' "$out")"
  fi

  if grep -q "^private-dbs=[1-9]" "$out"; then
    ok "$backend ($image): the check answered from mox's own copy of the database"
  else
    no "$backend ($image): mox's own database copy was not synced" "$(grep -E '^private-dbs=' "$out")"
  fi

  if grep -q "Packages: 1 installed, 0 failed" "$out" && grep -q "^upgrades=1" "$out" && grep -q "^bare-syncs=0" "$out"; then
    ok "$backend ($image): the install is the apply's one upgrade, and no bare sync ever runs"
  else
    no "$backend ($image): the install's upgrade count is off" "$(grep -E '^upgrades=|^bare-syncs=|Packages:' "$out")"
  fi

  # A machine left with a synced database and un-upgraded packages has
  # pending upgrades against a database it never asked for.
  if grep -q "^pending=0" "$out"; then
    ok "$backend ($image): the machine is left upgraded, never half-synced"
  else
    no "$backend ($image): the run left the machine in a partial-upgrade state" "$(grep -E '^pending=' "$out")"
  fi
}

# Both halves of the oracle a BARE apt row is judged by, in one container.
# A package installed from a .deb is in no repository, so the repository
# listing cannot answer for it: marked auto it is absent from
# `apt-mark showmanual` too, yet dpkg has it under the row's own name and the
# row converges, so it must be KEPT rather than refused. What converges it is
# a mark, the package being on the machine already. The same query is what
# still refuses a bare name whose package exists only for a foreign
# architecture, where an install sets `name:<arch>` to manual instead and
# apt-mark reports it qualified.
run_apt_local_deb_case() {
  image="$1"
  foreign="$2"
  backend="apt local-deb"

  case_dir="$work/apt-local-deb"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "moxlocaldemo"

[[packages]]
name = "moxforeigndemo"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      dpkg --add-architecture '"$foreign"'
      apt-get update >/dev/null
      native="$(dpkg --print-architecture)"
      build() {
        rm -rf /tmp/p
        mkdir -p /tmp/p/DEBIAN
        printf "Package: %s\nVersion: 1.0\nSection: misc\nPriority: optional\nArchitecture: %s\nMaintainer: mox <mox@example.invalid>\nDescription: a package no repository carries\n" "$1" "$2" > /tmp/p/DEBIAN/control
        dpkg-deb --build /tmp/p "/tmp/$1.deb" >/dev/null
        dpkg -i --force-architecture "/tmp/$1.deb" >/dev/null
        apt-mark auto "$1" >/dev/null 2>&1 || apt-mark auto "$1:$2" >/dev/null 2>&1
      }
      build moxlocaldemo "$native"
      build moxforeigndemo '"$foreign"'
      # The premises: neither is manual, so both rows read as MISSING, and
      # the repository listing holds neither.
      apt-mark showmanual | grep -qx moxlocaldemo && { echo "the local package is already manual; the case cannot run"; exit 1; }
      apt-cache -o "APT::Architectures=$native" -o Dir::State::status=/dev/null --generate pkgnames > /tmp/listing.txt
      grep -qx moxlocaldemo /tmp/listing.txt && { echo "a repository carries moxlocaldemo; the case cannot run"; exit 1; }
      grep -qx moxforeigndemo /tmp/listing.txt && { echo "a repository carries moxforeigndemo; the case cannot run"; exit 1; }
      echo "--- before ---"
      /w/mox status || true
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- after ---"
      /w/mox status || true
      echo "--- showmanual ---"
      apt-mark showmanual | grep -x moxlocaldemo || echo "local-not-manual"
      apt-mark showmanual | grep -x "moxforeigndemo:'"$foreign"'" || echo "foreign-not-manual"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- showmanual ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+apt moxlocaldemo"; then
    ok "$backend ($image): a locally installed package marked auto reads as MISSING"
  else
    no "$backend ($image): expected 'moxlocaldemo' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  # The half this case exists for: the row apt WOULD install must not be
  # refused, whatever the repository listing says.
  if grep -q 'row "moxlocaldemo"' "$out"; then
    no "$backend ($image): a row apt would have installed was refused" "$(grep 'row \"moxlocaldemo\"' "$out")"
  else
    ok "$backend ($image): a row no repository carries but dpkg has natively is kept"
  fi

  if grep -qx "moxlocaldemo" "$out"; then
    ok "$backend ($image): the real apt-mark recorded it manually installed, so apt-mark reports it"
  else
    no "$backend ($image): apt-mark does not report moxlocaldemo" "$(sed -n '/--- showmanual ---/,$p' "$out")"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+apt moxlocaldemo"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift over the locally installed package is clean after apply"
  fi

  # The other half: a bare name whose package is only ever reported
  # qualified must still go.
  want="mox: apt: row \"moxforeigndemo\" names an apt package for the architecture \"$foreign\" alone, which apt-mark reports as \"moxforeigndemo:$foreign\", so the row could never read as installed; declare \"moxforeigndemo:$foreign\" instead"
  if grep -qF "$want" "$out"; then
    ok "$backend ($image): a bare name only the foreign architecture has is still refused"
  else
    no "$backend ($image): the foreign-architecture row was not refused with the qualified spelling" "$(grep '^mox: apt' "$out" | tail -3)"
  fi

  # The kept row is MARKED rather than installed, apt having had the package
  # since the `dpkg -i` above; the refused one is still one row's failure.
  if grep -q "Packages: 0 installed, 1 failed, 1 already on the machine and now recorded as asked for" "$out"; then
    ok "$backend ($image): the kept row converged and the refused one is counted as its own failure"
  else
    no "$backend ($image): apply did not converge one row and refuse the other" "$(grep -i 'packages:\|apply-exit=' "$out" | tail -3)"
  fi
}

# A name apt has as a VIRTUAL name rather than a package: `apt-get install
# a52dec` installs `liba52-0.7.4-dev`, which apt-mark reports under its own
# name. The row must be refused with what provides it named -- the regex
# warning is not what apt would have done here.
run_apt_virtual_name_case() {
  image="$1"
  backend="apt virtual"

  case_dir="$work/apt-virtual"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "a52dec"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      apt-get update >/dev/null
      native="$(dpkg --print-architecture)"
      # The premise: no package by that name, and exactly one that provides it.
      apt-cache -o "APT::Architectures=$native" -o Dir::State::status=/dev/null --generate pkgnames | grep -qx a52dec && { echo "this release has a52dec as a package; the case cannot run"; exit 1; }
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      dpkg-query -W -f "${Package}\n" liba52-0.7.4-dev 2>/dev/null && echo "collateral=liba52-0.7.4-dev" || true
      echo "collateral-end"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -qF 'mox: apt: row "a52dec" names no apt package; it is a virtual name provided by "liba52-0.7.4-dev", and apt-mark reports only a package'"'"'s own name, so declare the one you want instead' "$out"; then
    ok "$backend ($image): the row is refused with the package that provides it named"
  else
    no "$backend ($image): apply did not name the provider" "$(grep '^mox: apt' "$out" | tail -3)"
  fi

  if grep -q "^collateral=" "$out"; then
    no "$backend ($image): apt installed a provider the manifest never declared" "$(grep '^collateral=' "$out")"
  else
    ok "$backend ($image): no provider landed; the row never reached apt-get"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# A PARTIALLY synced pacman database: one repository's database is missing
# while another answers. `pacman -Sl` is then non-empty, so nothing about the
# listing says it is short, and `pacman -Sg <group>` exits 1 for every group
# the missing repository holds -- the same answer a real package gives. A
# group declared in that state must still be refused, not installed.
run_pacman_partial_db_case() {
  image="$1"
  backend="pacman partial-db"

  case_dir="$work/pacman-partial-db"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "xfce4"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      [ -f /var/lib/pacman/sync/extra.db ] || { echo "this image has no extra database to drop; the case cannot run"; exit 1; }
      rm -f /var/lib/pacman/sync/extra.db
      # The premises: the listing still answers, and the group question does
      # not -- which is exactly what a name that is no group answers too.
      pacman -Sl 2>/dev/null | grep -q . || { echo "the listing is empty, not short; the case cannot run"; exit 1; }
      pacman -Sg xfce4 >/dev/null 2>&1 && { echo "the missing database still answers; the case cannot run"; exit 1; }
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      for p in exo garcon xfce4-session xfce4-panel; do
        pacman -Q "$p" >/dev/null 2>&1 && echo "collateral=$p" || true
      done
      echo "collateral-end"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no short database could be built" \
      "$(tail -2 "$out")"
    return
  fi

  if grep -q 'mox: pacman: row "xfce4" names no pacman package; it is a group of' "$out"; then
    ok "$backend ($image): a group in the repository whose database was missing is still refused"
  else
    no "$backend ($image): the group was not refused against a short database" "$(tail -5 "$out")"
  fi

  if grep -q "^collateral=" "$out"; then
    no "$backend ($image): pacman installed group members the manifest never declared" "$(grep '^collateral=' "$out")"
  else
    ok "$backend ($image): no member of the group landed"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# `cron` is an ALPM PROVISION: it is in no `pacman -Sl` line and no group
# either, but `pacman -S cron` installs `cronie`, which `pacman -Qeq` then
# reports -- so the row is MISSING for ever, cronie UNTRACKED for ever, and
# every apply installs it again. Only the real pacman can establish that the
# provision resolves and that the row's own name is absent from what it
# resolves to.
run_pacman_provision_case() {
  image="$1"
  backend="pacman provision"

  case_dir="$work/pacman-provision"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "cron"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      pacman -Q cronie >/dev/null 2>&1 && { echo "the image ships cronie; the case cannot run"; exit 1; }
      # The premises: no package of that name, no group of that name, and
      # pacman resolves it all the same.
      pacman -Sl 2>/dev/null | awk "\$2 == \"cron\"" | grep -q . && { echo "this image has a real cron package; the case cannot run"; exit 1; }
      pacman -Sg cron >/dev/null 2>&1 && { echo "cron is a group here; the case cannot run"; exit 1; }
      pacman -S --print --print-format "%n" -- cron >/dev/null 2>&1 || { echo "cron resolves to nothing here; the case cannot run"; exit 1; }
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      pacman -Q cronie >/dev/null 2>&1 && echo "collateral=cronie" || echo "collateral=absent"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no database could answer" "$(tail -2 "$out")"
    return
  fi

  # The message must carry the name to declare, or the user is left with a
  # row that fails on every apply and no way to learn what to write.
  if grep -q 'mox: pacman: row "cron" names no pacman package; it is a provision that "cronie" satisfies' "$out"; then
    ok "$backend ($image): the row is refused, naming the package that satisfies it"
  else
    no "$backend ($image): apply did not name the package pacman would install" "$(tail -5 "$out")"
  fi

  if grep -q "collateral=absent" "$out"; then
    ok "$backend ($image): cronie was never installed; the manifest declares no such package"
  else
    no "$backend ($image): pacman installed a package the manifest never declared" "$(grep '^collateral=' "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# A name pacman has NOTHING for, beside a real package. Measured on pacman
# 7.1.0 against a synced database, `pacman -S --needed --noconfirm -- cowsay
# mox-no-such-package` exits 1 with "target not found" and installs neither,
# so the bad row kept the good one off the machine on every apply, and every
# apply reported the batch failed. The check syncs first, so absence from the
# database is current and the row is refused on its own; the row beside it
# installs. The stale case above is the other half: a name only a current
# database has must not be refused against the old one.
run_pacman_unknown_name_case() {
  image="$1"
  pkg="$2"
  backend="pacman unknown-name"

  case_dir="$work/pacman-unknown-name"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "$pkg"

[[packages]]
name = "mox-no-such-package"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pacman -Q $pkg >/dev/null 2>&1 && { echo 'the image ships $pkg; the case cannot run'; exit 1; }
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo 'sync=failed'; exit 0; }
      # The premises: the name is in no listing, no group, and pacman
      # resolves it to nothing.
      pacman -Sl 2>/dev/null | awk '\$2 == \"mox-no-such-package\"' | grep -q . && { echo 'the name is a package here; the case cannot run'; exit 1; }
      pacman -Sg mox-no-such-package >/dev/null 2>&1 && { echo 'the name is a group here; the case cannot run'; exit 1; }
      rc=0; pacman -S --print --print-format '%n' -- mox-no-such-package >/dev/null 2>&1 || rc=\$?
      echo \"print-exit=\$rc\"
      echo '--- apply ---'
      rc=0
      /w/mox apply || rc=\$?
      echo \"apply-exit=\$rc\"
      echo \"installed=\$(pacman -Qq $pkg >/dev/null 2>&1 && echo 1 || echo 0)\"
      echo \"upgrades=\$(grep -c 'Running .pacman -Syu' /var/log/pacman.log || true)\"
    " >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no database could answer" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^print-exit=1" "$out"; then
    ok "$backend ($image): pacman resolves the name to nothing"
  else
    no "$backend ($image): the premise does not hold on this pacman" "$(grep -E '^print-exit=' "$out")"
  fi

  if grep -q 'mox: pacman: row "mox-no-such-package" names no pacman package in this machine.s repositories' "$out"; then
    ok "$backend ($image): the name pacman has nothing for is refused, by name"
  else
    no "$backend ($image): the unknown name was not refused" "$(tail -5 "$out")"
  fi

  if grep -q "^installed=1" "$out" && grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it installed; one bad row kept nothing off the machine"
  else
    no "$backend ($image): the good row did not install" "$(grep -E '^installed=|Packages:|^mox apply' "$out" | tail -3)"
  fi

  if grep -q "^upgrades=1" "$out"; then
    ok "$backend ($image): the install's own upgrade is the apply's only one"
  else
    no "$backend ($image): the upgrade count is off" "$(grep -E '^upgrades=' "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# A row the install's own upgrade pulls in as another package's dependency.
# A repository the case controls carries `a` 2-1; once that is installed the
# repository moves to `a` 3-1, which depends on `foo`, and the manifest
# declares `foo`. In one `pacman -Syu --needed -- foo` transaction foo is a
# target and pacman records it "Explicitly installed"; split into a `-Syu`
# and a `-S --needed -- foo`, the upgrade of `a` lands foo as a dependency
# and the second step skips it as up to date, so the apply reports it
# installed while `pacman -Qeq` never does and every status says MISSING.
run_pacman_upgrade_dependency_case() {
  image="$1"
  backend="pacman upgrade-dependency"

  case_dir="$work/pacman-upgrade-dependency"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "foo"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "$pacman_mkpkg"'
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      for p in a foo; do
        pacman -Q "$p" >/dev/null 2>&1 && { echo "the image ships $p; the case cannot run"; exit 1; }
      done
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      mkdir -p /srv/repo
      mkpkg a 2-1 "" /srv/repo
      mkpkg a 3-1 foo /srv/repo
      mkpkg foo 1-1 "" /srv/repo
      (cd /srv/repo && repo-add -q moxtest.db.tar.gz a-2-1-any.pkg.tar >/dev/null 2>&1)
      printf "[moxtest]\nSigLevel = Never\nServer = file:///srv/repo\n" >> /etc/pacman.conf
      pacman -Sy --noconfirm >/dev/null 2>&1
      pacman -S --noconfirm a >/dev/null 2>&1
      (cd /srv/repo && repo-add -q -R moxtest.db.tar.gz a-3-1-any.pkg.tar foo-1-1-any.pkg.tar >/dev/null 2>&1)
      echo "premise-a=$(pacman -Q a | tr " " =)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "a-after=$(pacman -Q a | tr " " =)"
      echo "reason=$(pacman -Qi foo 2>/dev/null | sed -n "s/^Install Reason *: //p")"
      echo "--- after ---"
      /w/mox status || true
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no upgrade could be built" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^premise-a=a=2-1" "$out" && grep -q "^a-after=a=3-1" "$out"; then
    ok "$backend ($image): the install's upgrade moved a from 2-1 to 3-1, which pulls foo in"
  else
    no "$backend ($image): the premise does not hold" "$(grep -E '^premise-a=|^a-after=' "$out")"
  fi

  if grep -q "Packages: 1 installed, 0 failed" "$out" && grep -q "^apply-exit=0" "$out"; then
    ok "$backend ($image): the apply installed the row"
  else
    no "$backend ($image): the apply did not report the row installed" "$(grep -E 'Packages:|^apply-exit=|^mox apply' "$out")"
  fi

  if grep -q "^reason=Explicitly installed" "$out"; then
    ok "$backend ($image): pacman records the row as asked for, being a target of the one transaction"
  else
    no "$backend ($image): pacman records the row as a dependency, so it reads MISSING for ever" "$(grep -E '^reason=' "$out")"
  fi

  after="$(sed -n '/--- after ---/,$p' "$out")"
  if echo "$after" | grep -qE "MISSING[[:space:]]+pacman foo"; then
    no "$backend ($image): the row is still MISSING after the apply that installed it" "$(echo "$after" | tail -3)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi
}

# A repository configured `Usage = Sync Search` puts its packages in
# `pacman -Sl` while `pacman -S` answers each with "target not found", and a
# batch carrying one installs nothing. The listing alone would keep the row;
# only `pacman -S --print`, asked of every row, refuses it.
run_pacman_sync_search_case() {
  image="$1"
  pkg="$2"
  backend="pacman sync-search"

  case_dir="$work/pacman-sync-search"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "sidepkg"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "$pacman_mkpkg"'
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      for p in sidepkg "$pkg"; do
        pacman -Q "$p" >/dev/null 2>&1 && { echo "the image ships $p; the case cannot run"; exit 1; }
      done
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      mkdir -p /srv/side
      mkpkg sidepkg 1-1 "" /srv/side
      (cd /srv/side && repo-add -q side.db.tar.gz sidepkg-1-1-any.pkg.tar >/dev/null 2>&1)
      printf "[side]\nSigLevel = Never\nUsage = Sync Search\nServer = file:///srv/side\n" >> /etc/pacman.conf
      pacman -Sy --noconfirm >/dev/null 2>&1
      echo "--- premise ---"
      echo "listed=$(pacman -Sl side | grep -c " sidepkg " || true)"
      rc=0; pacman -S --print --print-format "%n" -- sidepkg >/dev/null 2>&1 || rc=$?
      echo "print-exit=$rc"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no database could answer" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^listed=1" "$out" && grep -q "^print-exit=1" "$out"; then
    ok "$backend ($image): pacman lists the name and still resolves it to nothing"
  else
    no "$backend ($image): the premise does not hold on this pacman" "$(grep -E '^listed=|^print-exit=' "$out")"
  fi

  if grep -q 'mox: pacman: row "sidepkg" names a package pacman lists and still will not install (error: target not found: sidepkg), which is a repository whose Usage in pacman.conf leaves out Install' "$out"; then
    ok "$backend ($image): the row is refused, naming the repository setting that answers for it"
  else
    no "$backend ($image): the listed-but-uninstallable name was not refused" "$(tail -5 "$out")"
  fi

  if grep -q "^installed=1" "$out" && grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it installed; one bad row kept nothing off the machine"
  else
    no "$backend ($image): the good row did not install" "$(grep -E '^installed=|Packages:|^mox apply' "$out" | tail -3)"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# A repository that is configured, synced and EMPTY contributes no line to
# `pacman -Sl`, which is the same stdout a missing database gives. Nothing may
# read that as a database still to be repaired: the row beside it installs
# and the apply exits 0.
run_pacman_empty_repo_case() {
  image="$1"
  pkg="$2"
  backend="pacman empty-repo"

  case_dir="$work/pacman-empty-repo"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      mkdir -p /srv/empty
      repo-add /srv/empty/emptyrepo.db.tar.gz >/tmp/ra.txt 2>&1 || { echo 'repo-add=failed'; exit 0; }
      printf '\n[emptyrepo]\nSigLevel = Never\nServer = file:///srv/empty\n' >> /etc/pacman.conf
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo 'sync=failed'; exit 0; }
      # The premises: the repository is configured, its database is present
      # and synced, and it contributes nothing to the listing.
      pacman-conf --repo-list | grep -qx emptyrepo || { echo 'the empty repository is not configured; the case cannot run'; exit 1; }
      [ -f /var/lib/pacman/sync/emptyrepo.db ] || { echo 'the empty database did not sync; the case cannot run'; exit 1; }
      pacman -Sl 2>/dev/null | awk '\$1 == \"emptyrepo\"' | grep -q . && { echo 'the empty repository carries packages; the case cannot run'; exit 1; }
      echo '--- apply ---'
      rc=0
      /w/mox apply || rc=\$?
      echo \"apply-exit=\$rc\"
      echo \"installed=\$(pacman -Qq $pkg >/dev/null 2>&1 && echo 1 || echo 0)\"
    " >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^repo-add=failed" "$out" || grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): no empty repository could be built and synced here" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^installed=1" "$out"; then
    ok "$backend ($image): the row installed beside a repository that carries nothing"
  else
    no "$backend ($image): the row did not install" "$(tail -5 "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    ok "$backend ($image): an empty repository is not a failure"
  else
    no "$backend ($image): apply failed over an empty repository" "$(grep 'apply-exit=' "$out")"
  fi
}

# `smtp_daemon` is an rpm VIRTUAL PROVIDE: `zypper install smtp_daemon` exits
# 0 having installed postfix, `rpm -qa` reports postfix, and a second install
# says postfix already provides it and exits 0 again -- so the row is MISSING
# for ever and reinstalled on every apply, silently. Only the real zypper can
# establish that the name resolves to a package of another name.
run_zypper_provide_name_case() {
  image="$1"
  backend="zypper provide-name"

  case_dir="$work/zypper-provide-name"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/zypper.toml" <<'EOF'
backend = "zypper"

[[packages]]
name = "smtp_daemon"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      rpm -q postfix >/dev/null 2>&1 && { echo "the image ships postfix; the case cannot run"; exit 1; }
      rpm -q smtp_daemon >/dev/null 2>&1 && { echo "this image has a real smtp_daemon; the case cannot run"; exit 1; }
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- collateral ---"
      rpm -q postfix >/dev/null 2>&1 && echo "collateral=postfix" || echo "collateral=absent"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  # The message must carry a name to declare, or the user is left with a row
  # that reinstalls on every apply and no way to learn what to write.
  if grep -q 'mox: zypper: row "smtp_daemon" names no zypper package; it is a capability provided by ' "$out" &&
    grep -q '"postfix"' "$out"; then
    ok "$backend ($image): the row is refused, naming the packages that provide it"
  else
    no "$backend ($image): apply did not name what provides the capability" "$(tail -5 "$out")"
  fi

  if grep -q "collateral=absent" "$out"; then
    ok "$backend ($image): postfix was never installed; the manifest declares no such package"
  else
    no "$backend ($image): zypper installed a package the manifest never declared" "$(grep '^collateral=' "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# The other half of the zypper check: a name zypper has nothing at all for
# must go alone, because `zypper install ripgrep nosuchpkgxyz` exits 104
# having installed NEITHER -- one bad row would keep every package beside it
# off the machine.
run_zypper_unknown_name_case() {
  image="$1"
  pkg="$2"
  backend="zypper unknown-name"

  case_dir="$work/zypper-unknown-name"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/zypper.toml" <<EOF
backend = "zypper"

[[packages]]
name = "$pkg"

[[packages]]
name = "mox-no-such-package"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      rpm -q $pkg >/dev/null 2>&1 && { echo 'the image ships $pkg; the case cannot run'; exit 1; }
      echo '--- apply ---'
      rc=0
      /w/mox apply || rc=\$?
      echo \"apply-exit=\$rc\"
      echo \"installed=\$(rpm -q $pkg >/dev/null 2>&1 && echo 1 || echo 0)\"
    " >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q 'mox: zypper: row "mox-no-such-package" names no zypper package in this machine.s repositories' "$out"; then
    ok "$backend ($image): the name zypper has nothing for is refused"
  else
    no "$backend ($image): the unknown name was not refused" "$(tail -5 "$out")"
  fi

  if grep -q "^installed=1" "$out"; then
    ok "$backend ($image): the row beside it installed; one bad row kept nothing off the machine"
  else
    no "$backend ($image): the good row did not install" "$(tail -5 "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# A LOCKED package makes `zypper install` install none of the batch it is
# in: zypper exits 4 asking to choose a solution, on every apply, and the row
# beside it never lands. The lock is the user's decision, so the row is
# refused with `zypper removelock` named and the lock left as it was; and
# the read-back that found nothing landed leaves the summary nothing to
# hedge about.
run_zypper_lock_case() {
  image="$1"
  pkg="$2"
  backend="zypper lock"

  case_dir="$work/zypper-lock"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/zypper.toml" <<EOF
backend = "zypper"

[[packages]]
name = "ripgrep"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      for p in ripgrep "$pkg"; do
        rpm -q "$p" >/dev/null 2>&1 && { echo "the image ships $p; the case cannot run"; exit 1; }
      done
      zypper addlock ripgrep >/dev/null
      echo "--- premise ---"
      zypper --non-interactive refresh >/dev/null 2>&1 || true
      echo "locked-rows=$(zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep | grep -c "^ *l *|" || true)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "landed-ripgrep=$(rpm -q ripgrep >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "landed-pkg=$(rpm -q "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "lock-kept=$(zypper ll | grep -c ripgrep || true)"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^locked-rows=1" "$out"; then
    ok "$backend ($image): the search table reads the lock in its status column"
  else
    no "$backend ($image): the premise does not hold on this zypper" "$(grep -E '^locked-rows=' "$out")"
  fi

  if grep -q 'mox: zypper: row "ripgrep" names a package zypper has locked, and an install carrying a locked package installs nothing at all, so it was not installed; `zypper removelock ripgrep` to let mox install it' "$out"; then
    ok "$backend ($image): the locked row is refused, naming the lock to lift"
  else
    no "$backend ($image): the locked row was not refused" "$(tail -5 "$out")"
  fi

  if grep -q "^landed-pkg=1" "$out" && grep -q "^landed-ripgrep=0" "$out" && grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it installed; the locked one did not"
  else
    no "$backend ($image): the good row did not install, or the locked one did" "$(grep -E '^landed-|Packages:|^mox apply' "$out" | tail -3)"
  fi

  if grep -q "^lock-kept=1" "$out"; then
    ok "$backend ($image): the lock survives; it is the user's decision"
  else
    no "$backend ($image): the lock was lifted" "$(grep -E '^lock-kept=' "$out")"
  fi

  if grep -q "may have landed" "$out"; then
    no "$backend ($image): the summary hedges about rows the read-back found absent" "$(grep 'Packages:' "$out")"
  else
    ok "$backend ($image): nothing is hedged about; the read-back said what landed"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# The name check under a locale zypper translates. `zypper search` types each
# row in the user's language: with its translations installed (a desktop
# install ships them; the container image strips them, so they are put back
# here) the Type column reads a Japanese word under ja_JP.UTF-8 and `Paket`
# under de_DE.UTF-8 where a parser reading `package` expects English, so
# every row is refused as naming no package and nothing ever installs. mox
# pins every captured call to the C locale, and this holds it to that.
run_zypper_locale_case() {
  image="$1"
  pkg="$2"
  backend="zypper locale"

  case_dir="$work/zypper-locale"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/zypper.toml" <<EOF2
backend = "zypper"

[[packages]]
name = "$pkg"

[[packages]]
name = "mox-no-such-package"
EOF2

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      rpm -q $pkg >/dev/null 2>&1 && { echo 'the image ships $pkg; the case cannot run'; exit 1; }
      echo '%_install_langs all' > /etc/rpm/macros.langs
      zypper --non-interactive --quiet install -y glibc-locale >/dev/null 2>&1
      zypper --non-interactive --quiet install -y -f zypper libzypp >/dev/null 2>&1
      export LANG=ja_JP.UTF-8
      unset LC_ALL LANGUAGE
      # The harm, measured on the raw query: the row is there, the English
      # type is not.
      zypper --non-interactive --quiet search --match-exact --type package -- $pkg >/tmp/search.txt 2>&1 || true
      echo \"search-row=\$(grep -c '| $pkg ' /tmp/search.txt || true)\"
      echo \"search-type-english=\$(grep -c '| package' /tmp/search.txt || true)\"
      echo '--- apply ---'
      rc=0
      /w/mox apply || rc=\$?
      echo \"apply-exit=\$rc\"
      echo \"installed=\$(rpm -q $pkg >/dev/null 2>&1 && echo 1 || echo 0)\"
    " >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^search-row=1" "$out" && grep -q "^search-type-english=0" "$out"; then
    ok "$backend ($image): zypper search translates its Type column under ja_JP.UTF-8"
  else
    no "$backend ($image): the premise does not hold on this zypper" "$(grep -E '^search-' "$out")"
  fi

  if grep -q "^installed=1" "$out" && ! grep -q "row \"$pkg\" names no zypper package" "$out"; then
    ok "$backend ($image): a real package installs under ja_JP.UTF-8"
  else
    no "$backend ($image): the real package was refused under ja_JP.UTF-8" "$(grep -E '^mox: zypper|^installed=' "$out" | tail -3)"
  fi

  if grep -q 'mox: zypper: row "mox-no-such-package" names no zypper package in this machine.s repositories' "$out" && ! grep -q "apply-exit=0" "$out"; then
    ok "$backend ($image): the name zypper has nothing for is still refused under ja_JP.UTF-8"
  else
    no "$backend ($image): the unknown name was not refused under ja_JP.UTF-8" "$(grep -E '^mox: zypper|^apply-exit=' "$out" | tail -3)"
  fi
}

# The name check under a zypper.conf that colours every pipe. With
# `useColors = always` under `[color]`, `zypper search` wraps every cell of
# its table in SGR sequences even into a pipe, `NO_COLOR=1` does not undo
# it, and a parser reading the bare word `package` matches nothing: every
# row is refused and nothing ever installs. mox asks for the plain table
# with `--no-color`, and this holds it to that.
run_zypper_color_case() {
  image="$1"
  pkg="$2"
  backend="zypper color"

  case_dir="$work/zypper-color"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/zypper.toml" <<EOF2
backend = "zypper"

[[packages]]
name = "$pkg"

[[packages]]
name = "mox-no-such-package"
EOF2

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      rpm -q $pkg >/dev/null 2>&1 && { echo 'the image ships $pkg; the case cannot run'; exit 1; }
      printf '\n[color]\nuseColors = always\n' >> /etc/zypp/zypper.conf
      # The harm, measured on the raw query: the row is there, wrapped in
      # escape sequences, and the bare type is not.
      NO_COLOR=1 zypper --non-interactive --quiet search --match-exact --type package -- $pkg >/tmp/search.txt 2>&1 || true
      echo \"search-row=\$(grep -c \"$pkg\" /tmp/search.txt || true)\"
      echo \"search-colored=\$(grep -c \"\$(printf '\033')\\[\" /tmp/search.txt || true)\"
      echo \"search-type-plain=\$(grep -c '| package' /tmp/search.txt || true)\"
      echo '--- apply ---'
      rc=0
      /w/mox apply || rc=\$?
      echo \"apply-exit=\$rc\"
      echo \"installed=\$(rpm -q $pkg >/dev/null 2>&1 && echo 1 || echo 0)\"
    " >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^search-row=1" "$out" && ! grep -q "^search-colored=0" "$out" && grep -q "^search-type-plain=0" "$out"; then
    ok "$backend ($image): zypper search colours its table into a pipe under useColors = always, NO_COLOR or not"
  else
    no "$backend ($image): the premise does not hold on this zypper" "$(grep -E '^search-' "$out")"
  fi

  if grep -q "^installed=1" "$out" && ! grep -q "row \"$pkg\" names no zypper package" "$out"; then
    ok "$backend ($image): a real package installs under useColors = always"
  else
    no "$backend ($image): the real package was refused under useColors = always" "$(grep -E '^mox: zypper|^installed=' "$out" | tail -3)"
  fi

  if grep -q 'mox: zypper: row "mox-no-such-package" names no zypper package in this machine.s repositories' "$out" && ! grep -q "apply-exit=0" "$out"; then
    ok "$backend ($image): the name zypper has nothing for is still refused under useColors = always"
  else
    no "$backend ($image): the unknown name was not refused under useColors = always" "$(grep -E '^mox: zypper|^apply-exit=' "$out" | tail -3)"
  fi
}

# A row naming a package the manager ALREADY HAS, installed as another
# package's dependency. The row is missing because the manager's
# explicit-install query reports what the user asked for, and nothing asked
# for a dependency -- and an install does not change that: measured on dnf
# 4.14.0, dnf5 5.2.18 and 5.4.3, `dnf install` exits 0 saying the package is
# installed already and leaves the reason alone; measured on pacman 7.1.0,
# `pacman -S --needed` skips it and even a full reinstall leaves the reason
# `dependency`. So the row reads missing on every status and every apply
# reinstalls nothing, for ever. mox must record the row's own claim with the
# manager's mark command instead, and say what it did: marked, not installed.
#
# apt is here for the other half of the same question. `apt-get install` sets
# an automatically installed package manual when it has no upgrade to do, but
# apt 3.0.3 upgrading the package leaves it automatic, so the row converges
# one apply late. What is asserted for all three is the same: the mark ran,
# the row went clean, and the manager's own record now reports the package.
run_dependency_case() {
  image="$1"
  manager="$2"
  backend="$manager dependency"

  case_dir="$work/$manager-dependency"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  case "$manager" in
    pacman) pkg=acl ;;
    *) pkg=groff-base ;;
  esac
  cat >"$case_dir/repo/data/packages/$manager.toml" <<EOF
backend = "$manager"

[[packages]]
name = "$pkg"
EOF

  # Each script leaves the same three things on stdout: whether the premise
  # held, whether the manager's own install healed the record (asked of dnf
  # and pacman, whose answer does not move with the version), and what the
  # record says once mox has run.
  case "$manager" in
    dnf)
      cat >"$case_dir/case.sh" <<'CASE'
set -e
export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
dnf install -y man-db >/dev/null 2>&1 || true
echo "--- premise ---"
if dnf -q repoquery --installed --qf '%{name}\n' groff-base | grep -qx groff-base; then
  echo "premise-installed=yes"
else
  echo "premise-installed=no"
fi
if dnf -q repoquery --userinstalled --qf '%{name}\n' | grep -qx groff-base; then
  echo "premise-asked-for=yes"
else
  echo "premise-asked-for=no"
fi
echo "--- defect ---"
rc=0
dnf install -y groff-base >/dev/null 2>&1 || rc=$?
echo "manager-install-exit=$rc"
if dnf -q repoquery --userinstalled --qf '%{name}\n' | grep -qx groff-base; then
  echo "defect=healed"
else
  echo "defect=stands"
fi
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
/w/mox apply || true
echo "--- after ---"
/w/mox status || true
echo "--- record ---"
if dnf -q repoquery --userinstalled --qf '%{name}\n' | grep -qx groff-base; then
  echo "record=asked-for"
else
  echo "record=dependency"
fi
CASE
      ;;
    pacman)
      cat >"$case_dir/case.sh" <<'CASE'
set -e
export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
pacman -Sy --noconfirm >/dev/null 2>&1 || true
echo "--- premise ---"
if pacman -Qdq | grep -qx acl; then
  echo "premise-installed=yes"
else
  echo "premise-installed=no"
fi
if pacman -Qeq | grep -qx acl; then
  echo "premise-asked-for=yes"
else
  echo "premise-asked-for=no"
fi
echo "--- defect ---"
rc=0
pacman -S --needed --noconfirm -- acl >/dev/null 2>&1 || rc=$?
echo "manager-install-exit=$rc"
if pacman -Qeq | grep -qx acl; then
  echo "defect=healed"
else
  echo "defect=stands"
fi
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
/w/mox apply || true
echo "--- after ---"
/w/mox status || true
echo "--- record ---"
if pacman -Qeq | grep -qx acl; then
  echo "record=asked-for"
else
  echo "record=dependency"
fi
CASE
      ;;
    apt)
      cat >"$case_dir/case.sh" <<'CASE'
set -e
export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
apt-get update >/dev/null
apt-get install -y man-db >/dev/null 2>&1 || true
echo "--- premise ---"
if apt-mark showauto | grep -qx groff-base; then
  echo "premise-installed=yes"
else
  echo "premise-installed=no"
fi
if apt-mark showmanual | grep -qx groff-base; then
  echo "premise-asked-for=yes"
else
  echo "premise-asked-for=no"
fi
echo "--- defect ---"
echo "manager-install-exit=0"
echo "defect=not-asked"
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
/w/mox apply || true
echo "--- after ---"
/w/mox status || true
echo "--- record ---"
if apt-mark showmanual | grep -qx groff-base; then
  echo "record=asked-for"
else
  echo "record=dependency"
fi
CASE
      ;;
  esac

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh /w/case.sh >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "premise-installed=yes" "$out" && grep -q "premise-asked-for=no" "$out"; then
    ok "$backend ($image): the machine has $pkg as a dependency and nothing asked for it"
  else
    no "$backend ($image): the case could not put $pkg in the state it is about" "$(sed -n '/--- premise ---/,/--- defect ---/p' "$out")"
  fi

  case "$manager" in
    apt)
      na "$backend ($image): the manager's own install leaves the record alone" \
        "apt-get install sets an automatically installed package manual when it has no upgrade to do, so what it leaves behind moves with the release and with the index; only what mox does is asserted here"
      ;;
    *)
      if grep -q "defect=stands" "$out"; then
        ok "$backend ($image): the manager's own install exits 0 and leaves the record alone"
      else
        no "$backend ($image): $manager's install healed the record, so this case proves nothing" "$(sed -n '/--- defect ---/,/--- before ---/p' "$out")"
      fi
      ;;
  esac

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- record ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+$manager $pkg"; then
    ok "$backend ($image): the row reads MISSING before the apply"
  else
    no "$backend ($image): expected '$pkg' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 0 installed, 0 failed, 1 already on the machine and now recorded as asked for" "$out"; then
    ok "$backend ($image): the apply says the row was marked, never that it was installed"
  else
    no "$backend ($image): apply did not report the row as marked" "$(grep -i 'packages:' "$out" | tail -3)"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+$manager $pkg"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi

  if grep -q "record=asked-for" "$out"; then
    ok "$backend ($image): $manager's own record now reports $pkg as asked for"
  else
    no "$backend ($image): $manager still records $pkg as a dependency" "$(sed -n '/--- record ---/,$p' "$out")"
  fi
}

# The dependency round trip on a machine where the install-time check would
# refuse the row: the package is on the machine, and no enabled repository
# carries it. A dropped third-party repository, a release upgrade or a
# package the distribution retired all leave a machine here, and the check
# that asks the repositories what an install would land has no business with
# a package that is not going to be installed. Proved before the fix on
# Fedora with every repository `enabled=0`: `MISSING dnf groff-base`, then
# `Packages: 0 installed, 1 failed` with "names no dnf package in this
# machine's repositories", identically on every apply after -- while `dnf -q
# repoquery --installed` answered and `dnf mark user -y` exited 0 in that
# same state.
run_dnf_no_repository_case() {
  image="$1"
  backend="dnf no-repository"

  case_dir="$work/dnf-no-repository"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/dnf.toml" <<'EOF'
backend = "dnf"

[[packages]]
name = "groff-base"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      dnf install -y man-db >/dev/null 2>&1 || true
      sed -i "s/^enabled=1/enabled=0/" /etc/yum.repos.d/*.repo
      echo "--- premise ---"
      if dnf -q repoquery --installed --qf "%{name}\n" groff-base 2>/dev/null | grep -qx groff-base; then
        echo "premise-installed=yes"
      else
        echo "premise-installed=no"
      fi
      if dnf -q repoquery --userinstalled --qf "%{name}\n" 2>/dev/null | grep -qx groff-base; then
        echo "premise-asked-for=yes"
      else
        echo "premise-asked-for=no"
      fi
      rc=0; answer="$(dnf -q repoquery --qf "%{name}\n" groff-base 2>/dev/null)" || rc=$?
      echo "repositories-exit=$rc"
      echo "repositories-answer=$answer"
      echo "--- before ---"
      /w/mox status || true
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      /w/mox status || true
      echo "--- record ---"
      if dnf -q repoquery --userinstalled --qf "%{name}\n" 2>/dev/null | grep -qx groff-base; then
        echo "record=asked-for"
      else
        echo "record=dependency"
      fi
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "premise-installed=yes" "$out" && grep -q "premise-asked-for=no" "$out" && grep -qx "repositories-answer=" "$out"; then
    ok "$backend ($image): the machine has groff-base as a dependency, and no enabled repository carries it"
  else
    no "$backend ($image): the case could not put groff-base in the state it is about" "$(sed -n '/--- premise ---/,/--- before ---/p' "$out")"
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- record ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+dnf groff-base"; then
    ok "$backend ($image): the row reads MISSING before the apply"
  else
    no "$backend ($image): expected 'groff-base' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q 'names no dnf package' "$out"; then
    no "$backend ($image): the row was refused for the repositories, which have nothing to say about a package the machine has" "$(grep '^mox: dnf' "$out" | tail -3)"
  else
    ok "$backend ($image): the repositories were never asked about a package the machine already has"
  fi

  if grep -q "Packages: 0 installed, 0 failed, 1 already on the machine and now recorded as asked for" "$out"; then
    ok "$backend ($image): the apply says the row was marked, never that it was installed"
  else
    no "$backend ($image): apply did not report the row as marked" "$(grep -i 'packages:' "$out" | tail -3)"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+dnf groff-base"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi

  if grep -q "record=asked-for" "$out"; then
    ok "$backend ($image): dnf's own record now reports groff-base as asked for"
  else
    no "$backend ($image): dnf still records groff-base as a dependency" "$(sed -n '/--- record ---/,$p' "$out")"
  fi
}

# The dependency round trip on an apt where the row's package is HELD. The
# hold refusal exists because an install carrying a held package installs
# nothing at all -- and a package the machine already has needs no install:
# `apt-mark manual` takes a held package, and the hold is left exactly as its
# owner set it.
run_apt_held_dependency_case() {
  image="$1"
  backend="apt held-dependency"

  case_dir="$work/apt-held-dependency"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "groff-base"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      apt-get update >/dev/null
      apt-get install -y man-db >/dev/null 2>&1 || true
      apt-mark hold groff-base >/dev/null
      echo "--- premise ---"
      if apt-mark showauto | grep -qx groff-base; then
        echo "premise-installed=yes"
      else
        echo "premise-installed=no"
      fi
      if apt-mark showmanual | grep -qx groff-base; then
        echo "premise-asked-for=yes"
      else
        echo "premise-asked-for=no"
      fi
      echo "premise-held=$(apt-mark showhold | grep -cx groff-base || true)"
      echo "--- before ---"
      /w/mox status || true
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      /w/mox status || true
      echo "--- record ---"
      if apt-mark showmanual | grep -qx groff-base; then
        echo "record=asked-for"
      else
        echo "record=dependency"
      fi
      echo "still-held=$(apt-mark showhold | grep -cx groff-base || true)"
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "premise-installed=yes" "$out" && grep -q "premise-asked-for=no" "$out" && grep -q "^premise-held=1" "$out"; then
    ok "$backend ($image): the machine has groff-base as a held dependency that nothing asked for"
  else
    no "$backend ($image): the case could not put groff-base in the state it is about" "$(sed -n '/--- premise ---/,/--- before ---/p' "$out")"
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- record ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+apt groff-base"; then
    ok "$backend ($image): the row reads MISSING before the apply"
  else
    no "$backend ($image): expected 'groff-base' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q 'names a package apt-mark holds' "$out"; then
    no "$backend ($image): the row was refused for a hold that stops an install it does not need" "$(grep '^mox: apt' "$out" | tail -3)"
  else
    ok "$backend ($image): the hold was never asked about a package the machine already has"
  fi

  if grep -q "Packages: 0 installed, 0 failed, 1 already on the machine and now recorded as asked for" "$out"; then
    ok "$backend ($image): the apply says the row was marked, never that it was installed"
  else
    no "$backend ($image): apply did not report the row as marked" "$(grep -i 'packages:' "$out" | tail -3)"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+apt groff-base"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi

  if grep -q "record=asked-for" "$out"; then
    ok "$backend ($image): apt's own record now reports groff-base as asked for"
  else
    no "$backend ($image): apt still records groff-base as a dependency" "$(sed -n '/--- record ---/,$p' "$out")"
  fi

  if grep -q "^still-held=1" "$out" && ! grep -q "allow-change-held-packages" "$out"; then
    ok "$backend ($image): the hold is left as its owner set it"
  else
    no "$backend ($image): the run touched the hold" "$(grep -E '^still-held=|^mox: apt' "$out")"
  fi
}

# The dependency round trip on a pacman that cannot sync: the container has
# no network, so the sync of mox's own database copy the check runs fails. Marking
# needs only `pacman -Qdq` and `pacman -D --asexplicit`, both local, so the
# row the machine has converges; the row beside it, which needs the sync,
# is the one that fails. Proved before the fix with mox on an Arch machine
# whose sync fails: `install did not run: DistroRefreshFailed`, record
# unchanged.
run_pacman_no_sync_case() {
  image="$1"
  backend="pacman no-sync"

  case_dir="$work/pacman-no-sync"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "acl"

[[packages]]
name = "ripgrep"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --network none --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      echo "--- premise ---"
      rc=0; pacman -Syu --noconfirm >/dev/null 2>&1 || rc=$?
      echo "sync-exit=$rc"
      if pacman -Qdq | grep -qx acl; then
        echo "premise-installed=yes"
      else
        echo "premise-installed=no"
      fi
      if pacman -Qeq | grep -qx acl; then
        echo "premise-asked-for=yes"
      else
        echo "premise-asked-for=no"
      fi
      echo "--- before ---"
      /w/mox status || true
      echo "--- apply ---"
      /w/mox apply || true
      echo "--- after ---"
      /w/mox status || true
      echo "--- record ---"
      if pacman -Qeq | grep -qx acl; then
        echo "record=asked-for"
      else
        echo "record=dependency"
      fi
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "premise-installed=yes" "$out" && grep -q "premise-asked-for=no" "$out" && grep -q "^sync-exit=[1-9]" "$out"; then
    ok "$backend ($image): the machine has acl as a dependency that nothing asked for, and cannot sync"
  else
    no "$backend ($image): the case could not put the machine in the state it is about" "$(sed -n '/--- premise ---/,/--- before ---/p' "$out")"
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- record ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+pacman acl"; then
    ok "$backend ($image): the row reads MISSING before the apply"
  else
    no "$backend ($image): expected 'acl' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 0 installed, 1 failed, 1 already on the machine and now recorded as asked for" "$out"; then
    ok "$backend ($image): the apply marked the row the machine has, and failed only the one that needed the sync"
  else
    no "$backend ($image): apply did not report one row marked and one failed" "$(grep -i 'packages:\|^mox apply' "$out" | tail -3)"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+pacman acl"; then
    no "$backend ($image): acl is still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift over acl is clean after apply"
  fi

  if grep -q "record=asked-for" "$out"; then
    ok "$backend ($image): pacman's own record now reports acl as asked for"
  else
    no "$backend ($image): pacman still records acl as a dependency" "$(sed -n '/--- record ---/,$p' "$out")"
  fi
}

# A package INSTALLED and locked with an update pending: `zypper install`
# asks whether to lift the lock or skip the update, exits 4, and installs
# none of the batch -- while one installed and locked at its newest lets the
# batch land. The search table reads `il` for both; only `zypper
# list-updates --all` tells them apart. The image's own pending updates
# supply the package, or `down` names one to step back a build so that there
# is one; a lock on a package with none pending (bash) must not be refused.
run_zypper_installed_lock_case() {
  image="$1"
  pkg="$2"
  down="${3:-}"
  backend="zypper installed-lock"

  # One directory per image, never one reused: this case writes its manifest
  # from INSIDE the container, so `data/packages` is empty when the bind
  # mount is made, and a second mount of a path just deleted and recreated
  # showed the container an empty tree the host had already filled.
  case_dir="$work/zypper-installed-lock-$(printf '%s' "$image" | tr '/:.' '---')"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      down="${2:-}"
      rpm -q "$pkg" >/dev/null 2>&1 && { echo "the image ships $pkg; the case cannot run"; exit 1; }
      zypper --non-interactive refresh >/dev/null 2>&1 || true
      # A stable release ships what its repositories already hold, so nothing
      # on it has an update pending: `down` names a package to step back one
      # build, which gives the lock something to stop.
      if [ -n "$down" ]; then
        zypper --non-interactive install --oldpackage --allow-downgrade "$down<$(rpm -q --qf "%{VERSION}-%{RELEASE}" "$down")" >/dev/null 2>&1 || true
      fi
      # A warning about a repository is not a row of the table, and Leap
      # writes one to stdout.
      LC_ALL=C zypper --non-interactive --quiet --no-color list-updates --all 2>/dev/null | grep -v "^Warning:" | grep -v "^$" > /tmp/lu.txt || true
      # The image ships no awk: the third row of the table, third column.
      name=$(sed -n 3p /tmp/lu.txt | cut -d "|" -f 3 | tr -d " ")
      [ -n "$name" ] || { echo "pending=none"; exit 0; }
      grep -q "| bash " /tmp/lu.txt && { echo "bash has an update pending here; the case cannot run"; exit 1; }
      printf "backend = \"zypper\"\n\n[[packages]]\nname = \"%s\"\n\n[[packages]]\nname = \"bash\"\n\n[[packages]]\nname = \"%s\"\n" "$name" "$pkg" > /w/repo/data/packages/zypper.toml
      zypper addlock "$name" >/dev/null
      zypper addlock bash >/dev/null
      echo "--- premise ---"
      echo "pending=$name"
      echo "status-rows=$(LC_ALL=C zypper --non-interactive --quiet --no-color search --match-exact --type package -- "$name" bash | grep -c "^il *|" || true)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "landed-pkg=$(rpm -q "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "locks-kept=$(zypper ll | grep -c "$name\|bash" || true)"
    ' sh "$pkg" "$down" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^pending=none" "$out"; then
    skip "$backend ($image): this image has no package with an update pending, so no lock could stop a batch" "$(tail -2 "$out")"
    return
  fi
  name="$(sed -n 's/^pending=//p' "$out")"

  if grep -q "^status-rows=2" "$out"; then
    ok "$backend ($image): both rows read il in the search table; the table cannot tell them apart"
  else
    no "$backend ($image): the premise does not hold on this zypper" "$(grep -E '^status-rows=' "$out")"
  fi

  if grep -q "mox: zypper: row \"$name\" names a package zypper has installed and locked with an update pending (" "$out" && grep -q " available), and an install carrying it asks which to keep and installs nothing at all, so it was not installed; \`zypper removelock $name\` to let mox install it" "$out"; then
    ok "$backend ($image): the locked row with an update pending is refused, naming both versions"
  else
    no "$backend ($image): the locked row with an update pending was not refused" "$(grep '^mox: zypper' "$out" | tail -3)"
  fi

  if grep -q 'row "bash" names a package zypper has installed and locked' "$out"; then
    no "$backend ($image): the locked row with no update pending was refused, though it stops nothing" "$(grep 'row "bash"' "$out")"
  else
    ok "$backend ($image): the locked row with no update pending goes with the batch"
  fi

  if grep -q "^landed-pkg=1" "$out" && grep -q "Packages: 2 installed, 1 failed" "$out"; then
    ok "$backend ($image): the batch beside the refused row landed"
  else
    no "$backend ($image): the batch did not land" "$(grep -E '^landed-|Packages:|^mox apply' "$out" | tail -3)"
  fi

  if grep -q "^locks-kept=2" "$out"; then
    ok "$backend ($image): both locks survive; they are the user's decision"
  else
    no "$backend ($image): a lock was lifted" "$(grep -E '^locks-kept=' "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# A package whose dependency no repository satisfies: `pacman -S --print`
# exits 1 exactly as for a name pacman has nothing for, and only its stderr
# (`could not satisfy dependencies`) and stdout (`:: unable to satisfy
# dependency`) say which. Read by the exit code alone, the refusal told the
# user their repository's Usage in pacman.conf was wrong, quoting a "target
# not found" pacman never printed.
run_pacman_unsatisfiable_case() {
  image="$1"
  pkg="$2"
  backend="pacman unsatisfiable"

  case_dir="$work/pacman-unsatisfiable"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "needy"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "$pacman_mkpkg"'
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      for p in needy "$pkg"; do
        pacman -Q "$p" >/dev/null 2>&1 && { echo "the image ships $p; the case cannot run"; exit 1; }
      done
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      mkdir -p /srv/repo
      mkpkg needy 1-1 mox-no-such-dep /srv/repo
      (cd /srv/repo && repo-add -q moxtest.db.tar.gz needy-1-1-any.pkg.tar >/dev/null 2>&1)
      printf "[moxtest]\nSigLevel = Never\nServer = file:///srv/repo\n" >> /etc/pacman.conf
      pacman -Sy --noconfirm >/dev/null 2>&1
      echo "--- premise ---"
      rc=0; pacman -S --print --print-format "%n" -- needy >/tmp/print-out.txt 2>/tmp/print-err.txt || rc=$?
      echo "print-exit=$rc"
      echo "print-stderr=$(cat /tmp/print-err.txt)"
      echo "print-stdout=$(cat /tmp/print-out.txt)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no repository could be built" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^print-exit=1" "$out" && grep -q "^print-stderr=error: failed to prepare transaction (could not satisfy dependencies)" "$out" && grep -q "^print-stdout=:: unable to satisfy dependency 'mox-no-such-dep' required by needy" "$out"; then
    ok "$backend ($image): pacman exits 1 with the cause on stderr and the dependency on stdout"
  else
    no "$backend ($image): the premise does not hold on this pacman" "$(grep -E '^print-' "$out")"
  fi

  if grep -q "mox: pacman: row \"needy\" names a package pacman cannot install here, a dependency of it being satisfied by nothing in this machine's repositories (unable to satisfy dependency 'mox-no-such-dep' required by needy), so it was not installed; add the repository that carries it, or drop the row" "$out"; then
    ok "$backend ($image): the row is refused in pacman's own words, naming the dependency"
  else
    no "$backend ($image): the row was not refused for its dependency" "$(grep '^mox: pacman' "$out" | tail -3)"
  fi

  if grep -q "Usage in pacman.conf\|target not found" "$out"; then
    no "$backend ($image): the refusal blamed a repository setting, or quoted words pacman never printed" "$(grep 'Usage\|target not found' "$out")"
  else
    ok "$backend ($image): nothing pacman did not say is quoted, and no repository setting is blamed"
  fi

  if grep -q "^installed=1" "$out" && grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it installed; one bad row kept nothing off the machine"
  else
    no "$backend ($image): the good row did not install" "$(grep -E '^installed=|Packages:|^mox apply' "$out" | tail -3)"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# A row that CONFLICTS with an installed package, in either direction:
# `pacman -S --print` prints the transaction and exits 0, the install asks
# "Remove <installed>? [y/N]" and `--noconfirm` answers no, so the batch
# fails as one and nothing beside the row lands, on every apply. mox never
# removes a package, so the row goes rather than the batch. `newcomer`
# declares the conflict with the installed `holder`; the installed `guard`
# declares one with `rowb`, which declares nothing back.
run_pacman_conflict_case() {
  image="$1"
  pkg="$2"
  backend="pacman conflict"

  case_dir="$work/pacman-conflict"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "newcomer"

[[packages]]
name = "rowb"

[[packages]]
name = "$pkg"

[[packages]]
name = "succ"

[[packages]]
name = "drv"

[[packages]]
name = "rowc"

[[packages]]
name = "conflictrow"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  # Beside the two genuine conflicts, four the apply's own `-Syu` resolves,
  # which were refused all the same when judged against the machine as it
  # stood: `succ` replaces the installed `holder2` it conflicts with (pacman
  # answers its own "Replace holder2 with succ?" yes under --noconfirm);
  # `drv` conflicts with `srv<2` and the upgrade takes srv from 1-1 to 2-1;
  # the installed `guard2` 1-1 conflicts with `rowc` and its 2-1 does not;
  # and `conflictrow` conflicts with the installed `oldname`, which no row
  # names at all -- the repository has dropped it for `newname`, whose
  # `replaces` names it, so the same `-Syu` removes it. `pacman -Qu` is
  # blind to that rename, printing nothing and exiting 1.
  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c "$pacman_mkpkg"'
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      for p in holder guard newcomer rowb holder2 succ srv drv guard2 rowc oldname newname conflictrow "$pkg"; do
        pacman -Q "$p" >/dev/null 2>&1 && { echo "the image ships $p; the case cannot run"; exit 1; }
      done
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      mkdir -p /srv/repo
      mkpkg holder 1-1 "" /srv/repo
      mkpkg guard 1-1 "" /srv/repo rowb
      mkpkg newcomer 1-1 "" /srv/repo holder
      mkpkg rowb 1-1 "" /srv/repo
      mkpkg holder2 1-1 "" /srv/repo
      mkpkg succ 1-1 "" /srv/repo holder2 "holder2<2"
      mkpkg srv 1-1 "" /srv/repo
      mkpkg srv 2-1 "" /srv/repo
      mkpkg drv 1-1 "" /srv/repo "srv<2"
      mkpkg guard2 1-1 "" /srv/repo rowc
      mkpkg guard2 2-1 "" /srv/repo
      mkpkg rowc 1-1 "" /srv/repo
      mkpkg oldname 1-1 "" /srv/repo
      mkpkg newname 2-1 "" /srv/repo "" oldname
      mkpkg conflictrow 1-1 "" /srv/repo oldname
      (cd /srv/repo && repo-add -q moxtest.db.tar.gz holder-1-1-any.pkg.tar guard-1-1-any.pkg.tar newcomer-1-1-any.pkg.tar rowb-1-1-any.pkg.tar holder2-1-1-any.pkg.tar succ-1-1-any.pkg.tar srv-1-1-any.pkg.tar drv-1-1-any.pkg.tar guard2-1-1-any.pkg.tar rowc-1-1-any.pkg.tar oldname-1-1-any.pkg.tar conflictrow-1-1-any.pkg.tar >/dev/null 2>&1)
      printf "[moxtest]\nSigLevel = Never\nServer = file:///srv/repo\n" >> /etc/pacman.conf
      pacman -Sy --noconfirm >/dev/null 2>&1
      pacman -S --noconfirm holder guard holder2 srv guard2 oldname >/dev/null 2>&1
      (cd /srv/repo && repo-add -q -R moxtest.db.tar.gz srv-2-1-any.pkg.tar guard2-2-1-any.pkg.tar newname-2-1-any.pkg.tar >/dev/null 2>&1)
      (cd /srv/repo && repo-remove -q moxtest.db.tar.gz oldname >/dev/null 2>&1)
      echo "--- premise ---"
      rc=0; pacman -S --print --print-format "%n" --noconfirm -- newcomer rowb "$pkg" >/tmp/print.txt 2>&1 || rc=$?
      echo "print-exit=$rc"
      echo "print-rows=$(grep -c "^newcomer$\|^rowb$" /tmp/print.txt || true)"
      rc=0; pacman -Qu >/tmp/qu.txt 2>&1 || rc=$?
      echo "qu-exit=$rc"
      echo "qu-names-newname=$(grep -c "^newname " /tmp/qu.txt || true)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "kept=$(pacman -Qq holder guard 2>/dev/null | grep -c . || true)"
      echo "collateral=$(pacman -Qq newcomer rowb 2>/dev/null | grep -c . || true)"
      echo "replaced=$(pacman -Qq succ >/dev/null 2>&1 && echo 1 || echo 0)/$(pacman -Qq holder2 >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "versioned=$(pacman -Qq drv >/dev/null 2>&1 && echo 1 || echo 0)/$(pacman -Q srv 2>/dev/null | tr " " "-")"
      echo "reverse=$(pacman -Qq rowc >/dev/null 2>&1 && echo 1 || echo 0)/$(pacman -Q guard2 2>/dev/null | tr " " "-")"
      echo "renamed=$(pacman -Qq conflictrow >/dev/null 2>&1 && echo 1 || echo 0)/$(pacman -Qq newname >/dev/null 2>&1 && echo 1 || echo 0)/$(pacman -Qq oldname >/dev/null 2>&1 && echo 1 || echo 0)"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no repository could be built" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^print-exit=0" "$out" && grep -q "^print-rows=2" "$out"; then
    ok "$backend ($image): --print prints both conflicting rows and exits 0, so it cannot be the check"
  else
    no "$backend ($image): the premise does not hold on this pacman" "$(grep -E '^print-' "$out")"
  fi

  if grep -q 'mox: pacman: row "newcomer" names a package that conflicts with "holder", which this machine has installed; pacman would have to remove holder to install it, and mox never removes a package, so the row was not installed: remove holder yourself, or drop the row' "$out"; then
    ok "$backend ($image): the row declaring the conflict is refused, naming the installed package"
  else
    no "$backend ($image): the row declaring the conflict was not refused" "$(grep 'row "newcomer"' "$out" | tail -2)"
  fi

  if grep -q 'mox: pacman: row "rowb" names a package that "guard", which this machine has installed, declares a conflict with ("rowb"); pacman would have to remove guard to install it, and mox never removes a package, so the row was not installed: remove guard yourself, or drop the row' "$out"; then
    ok "$backend ($image): the row an installed package declares a conflict with is refused, naming it"
  else
    no "$backend ($image): the row an installed package conflicts with was not refused" "$(grep 'row "rowb"' "$out" | tail -2)"
  fi

  if grep -q "^installed=1" "$out" && grep -q "Packages: 5 installed, 2 failed" "$out"; then
    ok "$backend ($image): the rows beside them installed; two bad rows kept nothing off the machine"
  else
    no "$backend ($image): the good rows did not install" "$(grep -E '^installed=|Packages:|^mox apply' "$out" | tail -3)"
  fi

  if grep -q "^replaced=1/0" "$out" && ! grep -q 'row "succ"' "$out"; then
    ok "$backend ($image): a row that replaces the installed package it conflicts with installs, pacman replacing it in the upgrade"
  else
    no "$backend ($image): the row replacing an installed package was refused, or did not replace it" "$(grep -E '^replaced=|row "succ"' "$out" | tail -2)"
  fi

  if grep -q "^versioned=1/srv-2-1" "$out" && ! grep -q 'row "drv"' "$out"; then
    ok "$backend ($image): a versioned conflict the upgrade moves past installs beside that upgrade"
  else
    no "$backend ($image): the row whose versioned conflict the upgrade resolves was refused" "$(grep -E '^versioned=|row "drv"' "$out" | tail -2)"
  fi

  if grep -q "^reverse=1/guard2-2-1" "$out" && ! grep -q 'row "rowc"' "$out"; then
    ok "$backend ($image): a conflict the installed package's own upgrade drops installs beside that upgrade"
  else
    no "$backend ($image): the row an installed package's old version conflicted with was refused" "$(grep -E '^reverse=|row "rowc"' "$out" | tail -2)"
  fi

  if grep -q "^qu-names-newname=0" "$out"; then
    ok "$backend ($image): -Qu is blind to the rename, so it cannot be the whole oracle"
  else
    no "$backend ($image): -Qu already reports the rename here, so this case proves nothing" "$(grep -E '^qu-' "$out")"
  fi

  if grep -q "^renamed=1/1/0" "$out" && ! grep -q 'row "conflictrow"' "$out"; then
    ok "$backend ($image): a row conflicting with a package the upgrade replaces away installs"
  else
    no "$backend ($image): the row conflicting with a replaced package was refused, or the rename did not happen" "$(grep -E '^renamed=|row "conflictrow"' "$out" | tail -2)"
  fi

  if grep -q "^kept=2" "$out" && grep -q "^collateral=0" "$out"; then
    ok "$backend ($image): nothing was removed and neither conflicting row landed"
  else
    no "$backend ($image): the machine was changed beyond the good row" "$(grep -E '^kept=|^collateral=' "$out")"
  fi

  if grep -q "apply-exit=0" "$out"; then
    no "$backend ($image): a refused install exited 0" "$(grep 'apply-exit=' "$out")"
  else
    ok "$backend ($image): a refused install is counted in the exit code"
  fi
}

# The database copy under a caller's umask of 077: `mkdir -p` made
# `/var/cache/mox` and the copy 700, pacman's download user could not
# traverse them, the sync failed with "Permission denied", and a later
# apply under 022 failed the same way, since `mkdir -p` repairs nothing
# that exists. Both halves: a fresh copy made under 077 must sync, and a
# 700 tree left by an earlier run must be repaired.
run_pacman_umask_case() {
  image="$1"
  pkg="$2"
  backend="pacman umask"

  case_dir="$work/pacman-umask"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      pacman -Q "$pkg" >/dev/null 2>&1 && { echo "the image ships $pkg; the case cannot run"; exit 1; }
      [ -e /var/cache/mox ] && { echo "the image ships /var/cache/mox; the case cannot run"; exit 1; }
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      echo "--- fresh under 077 ---"
      rc=0
      (umask 077 && /w/mox apply) || rc=$?
      echo "fresh-exit=$rc"
      echo "fresh-modes=$(stat -c %a /var/cache/mox /var/cache/mox/pacman-db | tr "\n" " ")"
      echo "fresh-installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "--- repair of a 700 tree ---"
      pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 || true
      rm -rf /var/cache/mox /w/state
      mkdir -p /w/state
      (umask 077 && mkdir -p /var/cache/mox/pacman-db)
      echo "before-modes=$(stat -c %a /var/cache/mox /var/cache/mox/pacman-db | tr "\n" " ")"
      rc=0
      /w/mox apply || rc=$?
      echo "repair-exit=$rc"
      echo "repair-modes=$(stat -c %a /var/cache/mox /var/cache/mox/pacman-db | tr "\n" " ")"
      echo "repair-installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no copy could be made" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^fresh-exit=0" "$out" && grep -q "^fresh-installed=1" "$out" && grep -q "^fresh-modes=755 755 " "$out"; then
    ok "$backend ($image): a copy made under umask 077 is 755 on both levels, and the row installed through it"
  else
    no "$backend ($image): the copy made under umask 077 did not serve the install" "$(grep -E '^fresh-|Permission denied|^mox' "$out" | tail -4)"
  fi

  if grep -q "^before-modes=700 700 " "$out"; then
    ok "$backend ($image): the premise holds: a 700 tree stood where the copy goes"
  else
    no "$backend ($image): the premise does not hold" "$(grep -E '^before-modes=' "$out")"
  fi

  if grep -q "^repair-exit=0" "$out" && grep -q "^repair-installed=1" "$out" && grep -q "^repair-modes=755 755 " "$out"; then
    ok "$backend ($image): a 700 tree is repaired to 755, and the row installed through it"
  else
    no "$backend ($image): the 700 tree was not repaired" "$(grep -E '^repair-|Permission denied|^mox' "$out" | tail -4)"
  fi
}

# The first apply of a user sudo asks for a password: the copy's make is
# elevated, and as a captured call it had no terminal for sudo to ask on --
# sudo stopped it, the read loop reported it killed, and the apply failed
# with no copy made, on every apply until root made the copy by hand. The
# make is one streamed call now, so sudo asks once, on the terminal, and
# the apply goes on to make the copy and install.
run_pacman_sudo_password_case() {
  image="$1"
  pkg="$2"
  backend="pacman sudo-password"

  case_dir="$work/pacman-sudo-password"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "$pkg"
EOF
  # `expect` gives the apply a terminal and answers the one prompt on it.
  cat >"$case_dir/inner.sh" <<'EOF'
export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/home/tester
rc=0
/w/mox apply || rc=$?
echo "apply-exit=$rc"
EOF
  cat >"$case_dir/drive.exp" <<'EOF'
set timeout 900
spawn setpriv --reuid=tester --regid=tester --init-groups bash /w/inner.sh
expect {
  -re "password for tester:" { send "pw\r"; exp_continue }
  eof
}
catch wait result
exit [lindex $result 3]
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      pkg="$1"
      pacman -Q "$pkg" >/dev/null 2>&1 && { echo "the image ships $pkg; the case cannot run"; exit 1; }
      [ -e /var/cache/mox ] && { echo "the image ships /var/cache/mox; the case cannot run"; exit 1; }
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      pacman -S --noconfirm sudo expect >/dev/null 2>&1 || { echo "sync=failed"; exit 0; }
      useradd -m tester
      echo tester:pw | chpasswd
      echo "tester ALL=(ALL:ALL) ALL" >/etc/sudoers.d/tester
      chmod 440 /etc/sudoers.d/tester
      chown -R tester /w/state
      echo "--- apply ---"
      rc=0
      expect -f /w/drive.exp || rc=$?
      echo "expect-exit=$rc"
      echo "copy=$(stat -L -c %F /var/cache/mox 2>&1)"
      echo "link=$(readlink /var/cache/mox/pacman-db/local 2>&1)"
      echo "installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so sudo and expect could not be installed" "$(tail -2 "$out")"
    return
  fi

  prompts="$(grep -c 'password for tester' "$out" || true)"
  if [ "$prompts" -ge 1 ] && ! grep -q "stopped, and this run has no terminal" "$out"; then
    ok "$backend ($image): sudo asked for the password on the terminal ($prompts prompt(s)), and nothing was stopped waiting for one"
  else
    no "$backend ($image): sudo did not get to ask on the terminal" "$(grep -E 'password|stopped|^mox' "$out" | tail -3)"
  fi

  if grep -q "^apply-exit=0" "$out" && grep -q "^copy=directory" "$out" && grep -q "^link=/var/lib/pacman/local" "$out"; then
    ok "$backend ($image): the first apply made the copy, with local linked to the system's"
  else
    no "$backend ($image): the first apply did not make the copy" "$(grep -E '^apply-exit=|^copy=|^link=|^mox' "$out" | tail -4)"
  fi

  if grep -q "^installed=1" "$out" && grep -q "Packages: 1 installed, 0 failed" "$out"; then
    ok "$backend ($image): and installed the row through it"
  else
    no "$backend ($image): the row did not install on the first apply" "$(grep -E '^installed=|Packages:|^mox' "$out" | tail -3)"
  fi
}

# What stands where the copy goes: a real directory at the copy's `local`
# (what a sync into the copy before the link leaves), which `ln -sfn`
# nested the link inside so that every apply after re-ran the make and
# `--print` resolved against an empty local; the same with entries in it,
# which nothing may remove; and a regular file at `/var/cache/mox`, which
# `install -d` fails on with "File exists". With it, a warning pacman prints
# beside a transaction it does resolve, which the batch `--print` used to
# drop.
run_pacman_local_dir_case() {
  image="$1"
  pkg="$2"
  backend="pacman local-dir"

  case_dir="$work/pacman-local-dir"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      pacman -Q "$pkg" >/dev/null 2>&1 && { echo "the image ships $pkg; the case cannot run"; exit 1; }
      [ -e /var/cache/mox ] && { echo "the image ships /var/cache/mox; the case cannot run"; exit 1; }
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      printf "\n[options]\nMoxBogus = 1\n" >> /etc/pacman.conf
      echo "--- empty directory at local ---"
      install -d -m 755 /var/cache/mox/pacman-db/local
      rc=0
      /w/mox apply || rc=$?
      echo "empty-exit=$rc"
      echo "empty-link=$(readlink /var/cache/mox/pacman-db/local 2>&1)"
      echo "empty-installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "--- directory with entries at local ---"
      pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 || true
      rm -rf /var/cache/mox /w/state
      mkdir -p /w/state
      install -d -m 755 /var/cache/mox/pacman-db/local
      touch /var/cache/mox/pacman-db/local/keep
      rc=0
      /w/mox apply || rc=$?
      echo "kept-exit=$rc"
      echo "kept-file=$(stat -c %F /var/cache/mox/pacman-db/local/keep 2>&1)"
      echo "kept-installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
      echo "--- regular file at /var/cache/mox ---"
      rm -rf /var/cache/mox /w/state
      mkdir -p /w/state
      touch /var/cache/mox
      rc=0
      /w/mox apply || rc=$?
      echo "file-exit=$rc"
      echo "file-after=$(stat -c %F /var/cache/mox 2>&1)"
      echo "file-installed=$(pacman -Qq "$pkg" >/dev/null 2>&1 && echo 1 || echo 0)"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no copy could be made" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^empty-exit=0" "$out" && grep -q "^empty-link=/var/lib/pacman/local" "$out" && grep -q "^empty-installed=1" "$out"; then
    ok "$backend ($image): an empty directory at the copy's local is replaced by the link, and the row installed"
  else
    no "$backend ($image): the empty directory at local was not replaced" "$(grep -E '^empty-|^mox' "$out" | tail -4)"
  fi

  empty="$(sed -n '/--- empty directory at local ---/,/--- directory with entries at local ---/p' "$out")"
  if echo "$empty" | grep -q "warning: config file /etc/pacman.conf, line [0-9]*: directive 'MoxBogus' in section 'options' not recognized."; then
    ok "$backend ($image): pacman's own warning beside a transaction it resolved reached the terminal"
  else
    no "$backend ($image): pacman's warning was dropped" "$(echo "$empty" | grep -c warning)"
  fi

  if grep -q "^kept-exit=[1-9]" "$out" && grep -q "^kept-file=regular empty file" "$out" && grep -q "^kept-installed=0" "$out" \
    && grep -q "mox: pacman: /var/cache/mox/pacman-db/local is a directory with entries in it, where the copy of pacman's databases the check reads keeps a link to /var/lib/pacman/local; mox removes nothing there, so move it aside as root, after which an apply makes the link" "$out"; then
    ok "$backend ($image): a directory with entries at local is named and left, and nothing was installed through an empty local"
  else
    no "$backend ($image): the directory with entries at local was not named, or was removed" "$(grep -E '^kept-|^mox' "$out" | tail -4)"
  fi

  if grep -q "^file-exit=[1-9]" "$out" && grep -q "^file-after=regular empty file" "$out" && grep -q "^file-installed=0" "$out" \
    && grep -q "mox: pacman: /var/cache/mox is a regular empty file, not a directory, so the copy of pacman's databases the check reads at /var/cache/mox/pacman-db cannot be made; move it aside as root, after which an apply makes the copy" "$out"; then
    ok "$backend ($image): a regular file where the copy goes is named, and no make was tried against it"
  else
    no "$backend ($image): the regular file at /var/cache/mox was not named" "$(grep -E '^file-|^mox' "$out" | tail -4)"
  fi
}

# A stale `db.lck` in the copy, which a pacman killed outright mid-sync
# leaves behind: pacman says only "unable to lock database" for a sync, and
# the apply named nothing but an error. It must name the file.
run_pacman_stale_lock_case() {
  image="$1"
  pkg="$2"
  backend="pacman stale-lock"

  case_dir="$work/pacman-stale-lock"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/pacman.toml" <<EOF
backend = "pacman"

[[packages]]
name = "$pkg"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      pkg="$1"
      pacman -Q "$pkg" >/dev/null 2>&1 && { echo "the image ships $pkg; the case cannot run"; exit 1; }
      pacman -Sy --noconfirm >/tmp/sy.txt 2>&1 || { echo "sync=failed"; exit 0; }
      install -d -m 755 /var/cache/mox /var/cache/mox/pacman-db
      ln -sfn /var/lib/pacman/local /var/cache/mox/pacman-db/local
      # What SIGKILL leaves: measured, pacman removes the lock on an
      # interrupt and not on a kill.
      pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null >/dev/null 2>&1 &
      sleep 0.3
      kill -KILL $! 2>/dev/null || true
      wait $! 2>/dev/null || true
      [ -e /var/cache/mox/pacman-db/db.lck ] || touch /var/cache/mox/pacman-db/db.lck
      echo "--- premise ---"
      rc=0; pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null >/tmp/sy2.txt 2>&1 || rc=$?
      echo "sync-exit=$rc"
      echo "sync-said=$(grep -c "unable to lock database" /tmp/sy2.txt || true)"
      echo "--- apply ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
    ' sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  if grep -q "^sync=failed" "$out"; then
    skip "$backend ($image): pacman could not sync here, so no lock could be left" "$(tail -2 "$out")"
    return
  fi

  if grep -q "^sync-exit=1" "$out" && grep -q "^sync-said=1" "$out"; then
    ok "$backend ($image): a stale lock fails the sync with nothing naming the file"
  else
    no "$backend ($image): the premise does not hold on this pacman" "$(grep -E '^sync-' "$out")"
  fi

  if grep -q "mox: pacman: the sync of mox's database copy failed and /var/cache/mox/pacman-db/db.lck exists, which a pacman killed outright mid-sync leaves behind; only this sync ever takes that lock, so once no pacman is running it may be removed, as root" "$out"; then
    ok "$backend ($image): the apply names the lock file and says it may be removed"
  else
    no "$backend ($image): the apply did not name the lock file" "$(grep '^mox' "$out" | tail -3)"
  fi

  if grep -q "install did not run: the index or database refresh the install resolves against did not complete, so nothing was installed" "$out" && ! grep -q "apply-exit=0" "$out"; then
    ok "$backend ($image): the failure is worded, and counted in the exit code"
  else
    no "$backend ($image): the failure is a bare error name, or exited 0" "$(grep -E 'install did not run|apply-exit=' "$out")"
  fi
}

# A flat repository (`deb [trusted=yes] file:/repo ./`) keeps every
# architecture in one index, so apt's native listing prints its foreign-only
# names bare and cannot refuse them: `apt-get install -y -- mox-flat-armhf`
# installs `mox-flat-armhf:armhf`, which apt-mark reports qualified, and the
# row is missing and the package untracked on every run after. A package in
# that index built for an architecture dpkg has not enabled takes the whole
# batch down instead: apt 2.6.1 answers "Unable to locate package", apt
# 2.8.3 and 3.0.3 reach dpkg, which refuses the architecture. The stanza
# `apt-cache policy` heads with the qualified name is what tells the two
# rows apart from a native one, so both must be refused with the rest of
# the batch installed -- and the qualified spelling must still install and
# converge, madison having named no architecture for a flat line.
run_apt_flat_repo_case() {
  image="$1"
  foreign="$2"
  backend="apt flat-repo"
  case "$foreign" in
    i386) other=armhf ;;
    *) other=i386 ;;
  esac

  case_dir="$work/apt-flat-repo"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<EOF
backend = "apt"

[[packages]]
name = "mox-flat-$foreign"

[[packages]]
name = "mox-flat-$other"

[[packages]]
name = "sl"
EOF
  cat >"$case_dir/qualified.toml" <<EOF
backend = "apt"

[[packages]]
name = "mox-flat-$foreign:$foreign"
EOF
  cat >"$case_dir/case.sh" <<'CASE'
set -e
export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
apt-get update >/dev/null
apt-get install -y dpkg-dev >/dev/null 2>&1
apt-get --version | head -1
dpkg --add-architecture "$FOREIGN"
build() {
  rm -rf /tmp/p
  mkdir -p /tmp/p/DEBIAN
  printf "Package: %s\nVersion: 1.0\nArchitecture: %s\nMaintainer: mox <mox@example.invalid>\nDescription: a package a flat repository carries\n" "$1" "$2" > /tmp/p/DEBIAN/control
  dpkg-deb --build /tmp/p "/repo/${1}_1.0_$2.deb" >/dev/null
}
mkdir -p /repo
build "mox-flat-$FOREIGN" "$FOREIGN"
build "mox-flat-$OTHER" "$OTHER"
(cd /repo && dpkg-scanpackages . /dev/null > Packages 2>/dev/null)
echo "deb [trusted=yes] file:/repo ./" > /etc/apt/sources.list.d/flat.list
apt-get update >/dev/null 2>&1
native="$(dpkg --print-architecture)"
echo "--- premise ---"
apt-cache -o "APT::Architectures=$native" -o Dir::State::status=/dev/null -o APT::Cache::AllNames=false --generate pkgnames | grep -x "mox-flat-$FOREIGN" || echo "listing-lacks-foreign"
apt-cache -o "APT::Architectures=$native" -o Dir::State::status=/dev/null -o APT::Cache::AllNames=false --generate pkgnames | grep -x "mox-flat-$OTHER" || echo "listing-lacks-other"
echo "--- madison ---"
apt-cache madison "mox-flat-$FOREIGN:$FOREIGN"
echo "--- policy ---"
apt-cache policy "mox-flat-$FOREIGN" "mox-flat-$OTHER"
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
rc=0
/w/mox apply || rc=$?
echo "apply-exit=$rc"
echo "--- after ---"
/w/mox status || true
echo "--- qualified ---"
cp /w/qualified.toml /w/repo/data/packages/apt.toml
/w/mox status || true
echo "--- qualified apply ---"
rc=0
/w/mox apply || rc=$?
echo "qualified-apply-exit=$rc"
echo "--- qualified after ---"
/w/mox status || true
echo "--- showmanual ---"
apt-mark showmanual | grep -x "mox-flat-$FOREIGN:$FOREIGN" || echo "foreign-not-manual"
CASE

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" -e FOREIGN="$foreign" -e OTHER="$other" "$image" sh /w/case.sh >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  premise="$(sed -n '/--- premise ---/,/--- madison ---/p' "$out")"
  if echo "$premise" | grep -qx "mox-flat-$foreign" && echo "$premise" | grep -qx "mox-flat-$other"; then
    ok "$backend ($image): the native listing prints both flat-index names bare"
  else
    no "$backend ($image): the flat index did not defeat the listing, so this case proves nothing" "$premise"
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- qualified ---/p' "$out")"
  policy="$(sed -n '/--- policy ---/,/--- before ---/p' "$out")"

  if echo "$before" | grep -qE "MISSING[[:space:]]+apt mox-flat-$foreign" && echo "$before" | grep -qE "MISSING[[:space:]]+apt mox-flat-$other"; then
    ok "$backend ($image): both bare rows read MISSING before the apply"
  else
    no "$backend ($image): expected both flat rows MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  want="mox: apt: row \"mox-flat-$foreign\" names an apt package for the architecture \"$foreign\" alone, which apt-mark reports as \"mox-flat-$foreign:$foreign\", so the row could never read as installed; declare \"mox-flat-$foreign:$foreign\" instead"
  if grep -qF "$want" "$out"; then
    ok "$backend ($image): the bare row for the enabled foreign architecture is refused with the qualified spelling"
  else
    no "$backend ($image): the foreign flat row was not refused with the qualified spelling" "$(grep '^mox: apt' "$out" | tail -3)"
  fi

  # Which refusal the un-enabled architecture gets follows what apt printed:
  # a stanza headed with the qualified name (apt 2.8.3, 3.0.3) or none at all
  # (apt 2.4.14, 2.6.1).
  if echo "$policy" | grep -q "^mox-flat-$other:$other:"; then
    want="mox: apt: row \"mox-flat-$other\" names an apt package for the architecture \"$other\" alone, which this machine's dpkg has not enabled, so an install carrying it fails at dpkg and installs nothing at all, and it was not installed; \`dpkg --add-architecture $other\` and declare \"mox-flat-$other:$other\" to let mox install it"
    shape="a stanza apt heads with the qualified name"
  else
    want="mox: apt: row \"mox-flat-$other\" names a package apt-cache policy prints no stanza for, which is an operand apt cannot locate at all, and an install carrying one installs nothing at all, so it was not installed"
    shape="no stanza at all"
  fi
  if grep -qF "$want" "$out"; then
    ok "$backend ($image): the bare row for an architecture dpkg has not enabled is refused, apt having printed $shape"
  else
    no "$backend ($image): the un-enabled architecture's row was not refused as $shape" "$(grep '^mox: apt' "$out" | tail -3)"
  fi

  if grep -q "Packages: 1 installed, 2 failed" "$out" && ! grep -q "may have landed" "$out"; then
    ok "$backend ($image): the row beside them installed, and the two refusals are their own failures"
  else
    no "$backend ($image): apply did not install the rest of the batch alone" "$(grep -i 'packages:\|apply-exit=' "$out" | head -2)"
  fi

  if echo "$after" | grep -qE "UNTRACKED[[:space:]]+apt mox-flat"; then
    no "$backend ($image): a flat-index package landed under a name no row could match" "$(echo "$after" | grep 'mox-flat')"
  else
    ok "$backend ($image): nothing landed under the qualified name behind a bare row"
  fi

  qualified="$(sed -n '/--- qualified after ---/,/--- showmanual ---/p' "$out")"
  if grep -q "qualified-apply-exit=0" "$out" && sed -n '/--- qualified apply ---/,/--- qualified after ---/p' "$out" | grep -q "Packages: 1 installed, 0 failed"; then
    ok "$backend ($image): the qualified row installs from the flat index"
  else
    no "$backend ($image): the qualified row did not install" "$(sed -n '/--- qualified apply ---/,/--- qualified after ---/p' "$out" | grep -i 'mox: apt\|packages:' | tail -3)"
  fi

  if echo "$qualified" | grep -qE "MISSING[[:space:]]+apt" || ! grep -qx "mox-flat-$foreign:$foreign" "$out"; then
    no "$backend ($image): the qualified row did not converge" "$(echo "$qualified" | tail -4)"
  else
    ok "$backend ($image): the drift over the qualified row is clean after apply, and apt-mark reports the qualified name"
  fi
}

# apt.conf `APT::Cache::AllNames "true"` makes `apt-cache pkgnames` list
# virtual names too, so `awk` -- a name only mawk, gawk and original-awk
# provide -- reads as a package, and `apt-cache policy awk` then answers
# `Candidate: (none)`: the row would be refused as pinned rather than told
# what provides it. The listing pins the option back to false.
run_apt_allnames_case() {
  image="$1"
  backend="apt allnames"

  case_dir="$work/apt-allnames"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "awk"

[[packages]]
name = "sl"
EOF
  cat >"$case_dir/case.sh" <<'CASE'
set -e
export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
apt-get update >/dev/null
apt-get --version | head -1
printf 'APT::Cache::AllNames "true";\n' > /etc/apt/apt.conf.d/99mox-case
native="$(dpkg --print-architecture)"
echo "--- premise ---"
apt-cache -o "APT::Architectures=$native" -o Dir::State::status=/dev/null --generate pkgnames | grep -x awk || echo "conf-does-not-list-awk"
apt-cache policy awk
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
rc=0
/w/mox apply || rc=$?
echo "apply-exit=$rc"
echo "--- after ---"
/w/mox status || true
CASE

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh /w/case.sh >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  premise="$(sed -n '/--- premise ---/,/--- before ---/p' "$out")"
  if echo "$premise" | grep -qx awk && echo "$premise" | grep -q "Candidate: (none)"; then
    ok "$backend ($image): under the conf the plain listing prints awk, which policy answers with no candidate"
  else
    no "$backend ($image): the conf did not put awk in the listing, so this case proves nothing" "$premise"
  fi

  if grep -q 'row "awk" names no apt package; it is a virtual name provided by' "$out"; then
    ok "$backend ($image): awk is refused as the virtual name it is, with its providers named"
  else
    no "$backend ($image): awk was not refused as a virtual name" "$(grep '^mox: apt' "$out" | tail -3)"
  fi

  if grep -q "Packages: 1 installed, 1 failed" "$out"; then
    ok "$backend ($image): the row beside it installed"
  else
    no "$backend ($image): apply did not install the rest of the batch" "$(grep -i 'packages:' "$out" | tail -2)"
  fi
}

# A package an interrupted run left `install ok unpacked` is on the disk and
# not set up, and `apt-mark showmanual` lists it all the same. The explicit
# set is intersected with what dpkg has configured, so the row reads MISSING;
# `apt-get install -y -- <name>` then configures it (measured: "Setting up
# sl" on apt 2.6.1 and 3.0.3), where `apt-mark manual` on one apt holds as
# auto would have left it unpacked -- so that row goes to the install too.
run_apt_unpacked_case() {
  image="$1"
  backend="apt unpacked"

  case_dir="$work/apt-unpacked"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/apt.toml" <<'EOF'
backend = "apt"

[[packages]]
name = "sl"

[[packages]]
name = "cowsay"
EOF
  cat >"$case_dir/case.sh" <<'CASE'
set -e
export DEBIAN_FRONTEND=noninteractive MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
apt-get update >/dev/null
apt-get --version | head -1
apt-get install -y sl cowsay >/dev/null 2>&1
apt-mark auto cowsay >/dev/null
cd /tmp && apt-get download sl cowsay >/dev/null 2>&1 && dpkg --unpack sl_*.deb cowsay_*.deb >/dev/null 2>&1
echo "--- premise ---"
dpkg-query -W -f '${Package} ${Status}\n' sl cowsay
apt-mark showmanual | grep -x sl || echo "sl-not-manual"
apt-mark showauto | grep -x cowsay || echo "cowsay-not-auto"
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
rc=0
/w/mox apply || rc=$?
echo "apply-exit=$rc"
echo "--- after ---"
/w/mox status || true
echo "--- dpkg ---"
dpkg-query -W -f '${Package} ${Status}\n' sl cowsay
CASE

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh /w/case.sh >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  premise="$(sed -n '/--- premise ---/,/--- before ---/p' "$out")"
  if echo "$premise" | grep -q "^sl install ok unpacked" && echo "$premise" | grep -q "^cowsay install ok unpacked" && echo "$premise" | grep -qx sl && echo "$premise" | grep -qx cowsay; then
    ok "$backend ($image): both packages are unpacked, one manual and one auto"
  else
    no "$backend ($image): the case could not put the packages in the state it is about" "$premise"
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- dpkg ---/p' "$out")"
  if echo "$before" | grep -qE "MISSING[[:space:]]+apt sl" && echo "$before" | grep -qE "MISSING[[:space:]]+apt cowsay"; then
    ok "$backend ($image): a package apt-mark lists but dpkg has not configured reads MISSING"
  else
    no "$backend ($image): expected both rows MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 2 installed, 0 failed" "$out" && ! grep -q "marking it manually installed" "$out"; then
    ok "$backend ($image): both rows go to the install, and neither is merely marked"
  else
    no "$backend ($image): apply did not install both rows" "$(grep -i 'packages:\|marking it' "$out" | tail -3)"
  fi

  dpkg_after="$(sed -n '/--- dpkg ---/,$p' "$out")"
  if echo "$dpkg_after" | grep -q "^sl install ok installed" && echo "$dpkg_after" | grep -q "^cowsay install ok installed"; then
    ok "$backend ($image): the real apt-get configured both"
  else
    no "$backend ($image): a package is still unpacked after the apply" "$dpkg_after"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+apt"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi
}

# dnf.conf `assumeno=True` outranks `-y`: `dnf install -y tree` under it
# exits 1 with "Operation aborted." (dnf 4.14.0) or "Operation aborted by
# the user." (dnf5 5.2.18, 5.4.3) and installs nothing, and dnf5's `dnf mark
# user -y` aborts the same way. The install and the mark each carry
# `--setopt=assumeno=0`, which puts the answer back.
run_dnf_assumeno_case() {
  image="$1"
  backend="dnf assumeno"

  case_dir="$work/dnf-assumeno"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/dnf.toml" <<'EOF'
backend = "dnf"

[[packages]]
name = "tree"

[[packages]]
name = "groff-base"
EOF
  cat >"$case_dir/case.sh" <<'CASE'
set -e
export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
dnf --version | head -1
dnf install -y man-db >/dev/null 2>&1 || true
printf 'assumeno=True\n' >> /etc/dnf/dnf.conf
echo "--- premise ---"
rc=0
LC_ALL=C dnf install -y tree > /tmp/plain.txt 2>&1 || rc=$?
echo "plain-install-exit=$rc"
tail -1 /tmp/plain.txt
rpm -q tree || true
if dnf -q repoquery --installed --qf '%{name}\n' groff-base | grep -qx groff-base; then
  echo "dependency-installed=yes"
else
  echo "dependency-installed=no"
fi
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
rc=0
/w/mox apply || rc=$?
echo "apply-exit=$rc"
echo "--- after ---"
/w/mox status || true
echo "--- record ---"
rpm -q tree || true
if dnf -q repoquery --userinstalled --qf '%{name}\n' | grep -qx groff-base; then
  echo "record=asked-for"
else
  echo "record=dependency"
fi
CASE

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh /w/case.sh >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  premise="$(sed -n '/--- premise ---/,/--- before ---/p' "$out")"
  if echo "$premise" | grep -q "plain-install-exit=1" && echo "$premise" | grep -q "Operation aborted" && echo "$premise" | grep -q "package tree is not installed" && echo "$premise" | grep -q "dependency-installed=yes"; then
    ok "$backend ($image): under assumeno=True the manager's own -y install aborts, and groff-base is a dependency"
  else
    no "$backend ($image): the case could not put dnf in the state it is about" "$premise"
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  after="$(sed -n '/--- after ---/,/--- record ---/p' "$out")"
  if echo "$before" | grep -qE "MISSING[[:space:]]+dnf tree" && echo "$before" | grep -qE "MISSING[[:space:]]+dnf groff-base"; then
    ok "$backend ($image): both rows read MISSING before the apply"
  else
    no "$backend ($image): expected both rows MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 1 installed, 0 failed, 1 already on the machine and now recorded as asked for" "$out" && grep -q "apply-exit=0" "$out"; then
    ok "$backend ($image): the install and the mark both went through under the conf"
  else
    no "$backend ($image): apply did not install one row and mark the other" "$(grep -i 'packages:\|Operation aborted\|apply-exit=' "$out" | tail -3)"
  fi

  record="$(sed -n '/--- record ---/,$p' "$out")"
  if echo "$record" | grep -q "^tree-" && echo "$record" | grep -q "record=asked-for"; then
    ok "$backend ($image): rpm has tree, and dnf records groff-base as asked for"
  else
    no "$backend ($image): the machine does not show what the apply reported" "$record"
  fi

  if echo "$after" | grep -qE "MISSING[[:space:]]+dnf"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi
}

# A repository whose signing key rpm has not imported, under
# `repo_gpgcheck=1` and `skip_if_unavailable=1`: dnf4 asks whether to import
# it on the STDOUT a query reads names from, exits 0, and ends the question
# without a newline, so it is glued to the first name of the listing.
# Measured on dnf 4.14.0 with rockylinux:9's `extras` repository so
# configured and `jq` in `baseos`: `dnf -q repoquery --qf '%{name}\n' jq`
# exits 0 with stdout `Is this ok [y/N]: jq\n\n`, where `dnf -q --assumeno
# repoquery --qf '%{name}\n' jq` answers `jq\n\n`. Without the option mox
# finds no package of that name and the row never converges; the name class
# keeps the question out of the name set besides, so no message can quote it
# back as the package to declare.
run_dnf_unimported_key_case() {
  image="$1"
  pkg="$2"
  backend="dnf unimported-key"

  case_dir="$work/dnf-unimported-key"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  cat >"$case_dir/repo/data/packages/dnf.toml" <<EOF
backend = "dnf"

[[packages]]
name = "$pkg"
EOF
  cat >"$case_dir/case.sh" <<'CASE'
set -e
export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
pkg="$1"
dnf --version | head -1
rpm -q gpg-pubkey >/dev/null 2>&1 && { echo "this image has a signing key imported already; the case cannot run"; exit 1; }
rpm -q "$pkg" >/dev/null 2>&1 && { echo "this image ships $pkg; the case cannot run"; exit 1; }
# Not every repository: the one that carries the package must still answer,
# or there is no name for the question to be glued to.
sed -i '/^\[extras\]/a repo_gpgcheck=1\nskip_if_unavailable=1' /etc/yum.repos.d/rocky-extras.repo
echo "--- premise ---"
rc=0
LC_ALL=C dnf -q repoquery --qf '%{name}\n' "$pkg" > /tmp/plain.txt 2>/dev/null || rc=$?
echo "plain-exit=$rc"
echo "plain-stdout=$(tr -d '\n' < /tmp/plain.txt)"
echo "--- before ---"
/w/mox status || true
echo "--- apply ---"
rc=0
/w/mox apply || rc=$?
echo "apply-exit=$rc"
echo "--- after ---"
/w/mox status || true
echo "--- record ---"
rpm -q "$pkg" || true
CASE

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh /w/case.sh "$pkg" >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  premise="$(sed -n '/--- premise ---/,/--- before ---/p' "$out")"
  if echo "$premise" | grep -q "^plain-exit=0" && echo "$premise" | grep -q "^plain-stdout=Is this ok \[y/N\]: $pkg$"; then
    ok "$backend ($image): dnf's own query writes the key question to stdout, glued to the one name it answers"
  else
    no "$backend ($image): the case could not put dnf in the state it is about" "$premise"
  fi

  before="$(sed -n '/--- before ---/,/--- apply ---/p' "$out")"
  if echo "$before" | grep -qE "MISSING[[:space:]]+dnf $pkg"; then
    ok "$backend ($image): the row reads MISSING before the apply"
  else
    no "$backend ($image): expected '$pkg' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  # The question is dnf talking, never a package: mox must not read it as a
  # name, and must not quote it back as the one to declare.
  if grep -q "^mox: dnf: .*Is this ok" "$out"; then
    no "$backend ($image): mox read dnf's question as a package name" "$(grep '^mox: dnf: ' "$out" | head -1)"
  else
    ok "$backend ($image): no mox message names dnf's question"
  fi

  if grep -q "Packages: 1 installed, 0 failed" "$out" && grep -q "apply-exit=0" "$out"; then
    ok "$backend ($image): the row installs through the repository that did answer"
  else
    no "$backend ($image): apply did not install the row" "$(grep -i 'packages:\|apply-exit=\|^mox: dnf' "$out" | tail -3)"
  fi

  after="$(sed -n '/--- after ---/,/--- record ---/p' "$out")"
  if echo "$after" | grep -qE "MISSING[[:space:]]+dnf"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi

  if sed -n '/--- record ---/,$p' "$out" | grep -q "^$pkg-"; then
    ok "$backend ($image): rpm has the package the apply reported"
  else
    no "$backend ($image): the machine does not show what the apply reported" "$(sed -n '/--- record ---/,$p' "$out")"
  fi
}

if [ "$#" -gt 0 ]; then
  while [ "$#" -ge 3 ]; do
    run_case "$1" "$2" "$3"
    shift 3
  done
else
  run_case debian:stable apt ripgrep
  run_remove_suffix_case debian:stable
  run_regex_operand_case debian:stable
  run_apt_native_alias_case debian:stable
  # The foreign architecture is whichever one the host is not: i386 beside
  # amd64 (Steam, wine), armhf beside arm64 (cross work).
  run_multiarch_case debian:stable "$foreign_arch"
  # wine32 is built for i386 and armhf and for no 64-bit architecture, so it
  # is the one name that exists for the foreign architecture alone on both
  # kinds of host -- the case apt's own listing cannot answer.
  run_foreign_only_case debian:stable "$foreign_arch"
  # The other half of that: a foreign-only name apt's plain listing prints
  # BARE, which is the majority of them.
  run_foreign_only_bare_case debian:stable "$foreign_arch"
  # The half no repository can answer for: a package installed from a .deb,
  # beside a bare name whose package is only ever reported qualified.
  run_apt_local_deb_case debian:stable "$foreign_arch"
  run_apt_virtual_name_case debian:stable
  run_apt_hold_pin_case debian:stable
  run_apt_pin_locale_case debian:stable
  run_apt_no_repositories_case debian:stable
  run_apt_arch_desync_case debian:12 "$foreign_arch"
  run_apt_arch_desync_case debian:stable "$foreign_arch"
  run_dependency_case debian:stable apt
  run_apt_held_dependency_case debian:stable
  # The flat-index refusal differs by apt version -- 2.6.1 prints no policy
  # stanza for an architecture dpkg has not enabled, 3.0.3 prints one -- so
  # the pinned release and the floating one both run.
  run_apt_flat_repo_case debian:12 "$foreign_arch"
  run_apt_flat_repo_case debian:stable "$foreign_arch"
  run_apt_allnames_case debian:12
  run_apt_unpacked_case debian:12
  run_apt_unpacked_case debian:stable
  # Both dnf generations: dnf5 (fedora) logs to stderr, dnf4 (rocky) writes
  # its metadata line to stdout, which the adapter's query must not read as
  # a package name.
  run_case fedora:latest dnf ripgrep
  run_provide_name_case fedora:latest
  # A pinned release behind the floating one, because an adapter is broken or
  # whole per version range: dnf5 5.2.x (Fedora 41, 42 and 43) exits 2 on a
  # `--` before the operands that dnf5 5.4.x (Fedora 44) accepts. Only a
  # pinned tag can hold a range still while `latest` moves.
  run_case fedora:42 dnf ripgrep
  # jq, not ripgrep: Rocky 9's default repos carry no ripgrep -- it lives in
  # EPEL, which the stock image does not enable, so that case could only fail.
  run_case rockylinux:9 dnf jq
  # The same row on both dnf generations, whose mark commands are each exit 2
  # on the other's spelling: dnf4 has `mark install` and dnf5 `mark user`.
  run_dependency_case rockylinux:9 dnf
  run_dependency_case fedora:42 dnf
  run_dependency_case fedora:latest dnf
  run_dnf_no_repository_case rockylinux:9
  run_dnf_no_repository_case fedora:latest
  run_dnf_assumeno_case rockylinux:9
  run_dnf_assumeno_case fedora:42
  run_dnf_assumeno_case fedora:latest
  # dnf4 alone: dnf5 5.2.18 and 5.4.3 both send the key question to stderr,
  # where it is no part of the listing.
  run_dnf_unimported_key_case rockylinux:9 jq
  run_case opensuse/tumbleweed zypper ripgrep
  # zypper's only other case installs a real package; these two are the
  # negative half every other manager already has.
  run_zypper_provide_name_case opensuse/leap:15.6
  run_zypper_unknown_name_case opensuse/tumbleweed ripgrep
  run_zypper_locale_case opensuse/tumbleweed ripgrep
  run_zypper_color_case opensuse/tumbleweed ripgrep
  run_zypper_lock_case opensuse/tumbleweed bat
  run_zypper_installed_lock_case opensuse/tumbleweed ripgrep
  # The same case on the older zypper of a stable release, whose
  # `list-updates --all` table is the one this parse reads: 1.14.94 against
  # Tumbleweed's 1.14.101. Leap ships what its repositories hold, so curl
  # steps back one build to give the lock an update to stop.
  run_zypper_installed_lock_case opensuse/leap:15.6 ripgrep curl
  # Arch publishes no arm64 image, so these cases skip on an arm64 host.
  run_case archlinux:latest pacman ripgrep
  run_pacman_group_case archlinux:latest
  run_pacman_sync_case archlinux:latest
  run_pacman_partial_db_case archlinux:latest
  run_pacman_stale_case archlinux:latest
  run_pacman_provision_case archlinux:latest
  run_pacman_unknown_name_case archlinux:latest cowsay
  run_pacman_empty_repo_case archlinux:latest ripgrep
  run_pacman_upgrade_dependency_case archlinux:latest
  run_pacman_sync_search_case archlinux:latest bat
  run_dependency_case archlinux:latest pacman
  run_pacman_no_sync_case archlinux:latest
  run_pacman_unsatisfiable_case archlinux:latest cowsay
  run_pacman_conflict_case archlinux:latest cowsay
  run_pacman_umask_case archlinux:latest cowsay
  run_pacman_stale_lock_case archlinux:latest cowsay
  run_pacman_sudo_password_case archlinux:latest cowsay
  run_pacman_local_dir_case archlinux:latest cowsay
  run_case debian:stable brew hello
fi

summary="$passes passed, $fails failed"
if [ "$skips" -gt 0 ]; then
  summary="$summary, $skips skipped"
fi
if [ "$nas" -gt 0 ]; then
  summary="$summary, $nas n/a"
fi
printf '\n%s\n' "$summary"
# A skip is never a pass. On a developer machine an unavailable image or
# architecture is a fact of life; on CI it means the gate tested nothing it
# was added to test, so it fails the run. N/A is not counted here: it says
# the check does not apply to that backend, which no runner can change.
if [ -n "${CI:-}" ] && [ "$skips" -gt 0 ]; then
  printf 'CI: %d case(s) skipped; this gate must run them all\n' "$skips" >&2
  exit 1
fi
[ "$fails" -eq 0 ]
