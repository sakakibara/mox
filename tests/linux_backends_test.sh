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
# command can. One runs the round trip a
# multiarch machine needs, which is the one place a colon in a name is the
# name apt itself reports; one covers a machine with no package index, where
# apt's listing must come back empty; one covers a pacman database that
# is merely old, where a name it lacks must still reach pacman; one covers a
# package no repository carries, installed from a .deb, which apt would
# install and mox must therefore keep; one covers a pacman database that
# is SHORT rather than old, where a repository's groups all read as no group
# at all; one covers a name zypper has nothing at all for, which makes
# `zypper install` install none of the batch it is in; and one covers a
# configured, synced and EMPTY pacman repository, which contributes no line to
# the listing and so can never read as complete. The hermetic
# suite proves what the adapter does; only the real manager proves what the
# row would have done. These run with the default set, not from the
# image/backend/package arguments.
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

# A pacman database that is merely OLD, which is the normal state of an Arch
# machine between upgrades. A name it has never heard of must NOT be refused:
# the install argv is `pacman -Syu`, which syncs before it resolves. Absence
# is not evidence here, where it is for apt -- mox runs apt's own update
# immediately before reading apt's listing.
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
    ok "$backend ($image): a name the stale database lacks is handed to pacman, not refused"
  fi

  if grep -q "^installed=1" "$out" && grep -q "^apply-exit=0" "$out"; then
    ok "$backend ($image): the sync the install itself runs resolved it"
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

# A pacman CHECK must only read. `pacman -Sy` without `-u` leaves the sync
# database ahead of the installed packages, which Arch documents as an
# unsupported partial upgrade -- and a check that runs it leaves the machine
# in that state on every path out, a refused row included. Two phases: a
# machine that has never synced, where the database has to be downloaded
# before anything can be judged, and one that already has it, where nothing
# may be written at all.
run_pacman_sync_case() {
  image="$1"
  backend="pacman sync"

  case_dir="$work/pacman-sync"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/data/packages" "$case_dir/state"
  cp "$mox_bin" "$case_dir/mox"
  # A group: refused, so every path after the database read is the failing
  # one this case is about.
  cat >"$case_dir/repo/data/packages/pacman.toml" <<'EOF'
backend = "pacman"

[[packages]]
name = "fprint"
EOF

  out="$case_dir/out.txt"
  pull_image "$image" "$backend" "$case_dir" || return 0

  if ! docker run --rm --platform "$platform" -v "$case_dir:/w" "$image" sh -c '
      set -e
      export MOX_REPO=/w/repo MOX_STATE_DIR=/w/state HOME=/root
      [ -f /var/lib/pacman/sync/core.db ] && { echo "this image ships a synced database; the case cannot run"; exit 1; }
      echo "--- unsynced ---"
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      echo "--- pending upgrades ---"
      pacman -Qu > /tmp/pending.txt 2>&1 || true
      echo "pending=$(grep -c . /tmp/pending.txt)"
      echo "--- synced ---"
      touch /tmp/marker
      sleep 1
      rc=0
      /w/mox apply || rc=$?
      echo "apply-exit=$rc"
      if [ -n "$(find /var/lib/pacman/sync -newer /tmp/marker)" ]; then
        echo "database=written"
      else
        echo "database=untouched"
      fi
    ' >"$out" 2>&1; then
    no "$backend ($image): container run failed" "$(tail -3 "$out")"
    return
  fi

  # A machine left with a synced database and un-upgraded packages has
  # pending upgrades against a database it never asked for.
  if grep -q "^pending=0" "$out"; then
    ok "$backend ($image): an unsynced machine is left upgraded, never half-synced"
  else
    no "$backend ($image): the run left the machine in a partial-upgrade state" \
      "$(grep -E '^pending=|^apply-exit=' "$out" | head -2)"
  fi

  if grep -q "database=untouched" "$out"; then
    ok "$backend ($image): a check against a database that is already there writes nothing"
  else
    no "$backend ($image): a check wrote to the sync database" "$(grep -E 'database=' "$out")"
  fi

  if grep -q "names no pacman package" "$out"; then
    ok "$backend ($image): the row is still refused, on both runs"
  else
    no "$backend ($image): the row was not refused" "$(tail -5 "$out")"
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

# A repository that is configured, synced and EMPTY contributes no line to
# `pacman -Sl`, which is the same stdout a missing database gives -- so it can
# never read as complete, and a completeness check on every apply would sync on
# every apply. A row the listing already carries has no question for the
# database, so nothing is asked of it and nothing is synced ahead of the
# install's own refresh.
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
  run_apt_no_repositories_case debian:stable
  run_dependency_case debian:stable apt
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
  run_case opensuse/tumbleweed zypper ripgrep
  # zypper's only other case installs a real package; these two are the
  # negative half every other manager already has.
  run_zypper_provide_name_case opensuse/leap:15.6
  run_zypper_unknown_name_case opensuse/tumbleweed ripgrep
  # Arch publishes no arm64 image, so these cases skip on an arm64 host.
  run_case archlinux:latest pacman ripgrep
  run_pacman_group_case archlinux:latest
  run_pacman_sync_case archlinux:latest
  run_pacman_partial_db_case archlinux:latest
  run_pacman_stale_case archlinux:latest
  run_pacman_provision_case archlinux:latest
  run_pacman_empty_repo_case archlinux:latest ripgrep
  run_dependency_case archlinux:latest pacman
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
