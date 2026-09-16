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
# One case runs the other way round. mox never uninstalls anything, and an
# install argv accepts more than package names: `apt-get install -y vim nano-`
# removes nano. The hermetic suite proves the adapter refuses such a row; only
# a real apt, with a real nano installed beside it, proves that the row would
# have removed the package and that mox stopped before it could. That case
# runs with the default set, not from the image/backend/package arguments.

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
  arm64 | aarch64) platform=linux/arm64 target=aarch64-linux-musl ;;
  *) platform=linux/amd64 target=x86_64-linux-musl ;;
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

if [ "$#" -gt 0 ]; then
  while [ "$#" -ge 3 ]; do
    run_case "$1" "$2" "$3"
    shift 3
  done
else
  run_case debian:stable apt ripgrep
  run_remove_suffix_case debian:stable
  # Both dnf generations: dnf5 (fedora) logs to stderr, dnf4 (rocky) writes
  # its metadata line to stdout, which the adapter's query must not read as
  # a package name.
  run_case fedora:latest dnf ripgrep
  # jq, not ripgrep: Rocky 9's default repos carry no ripgrep -- it lives in
  # EPEL, which the stock image does not enable, so that case could only fail.
  run_case rockylinux:9 dnf jq
  run_case opensuse/tumbleweed zypper ripgrep
  # Arch publishes no arm64 image, so this case skips on an arm64 host.
  run_case archlinux:latest pacman ripgrep
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
