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

set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

passes=0
fails=0
skips=0
ok() { printf '  ok   %s\n' "$1"; passes=$((passes + 1)); }
no() { printf '  FAIL %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }
# A skip is never a pass. It is printed, counted, and named in the summary,
# so "this host could not run it" can never read as "this backend is fine".
skip() { printf '  SKIP %s\n      %s\n' "$1" "$2"; skips=$((skips + 1)); }

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found; skipping (this suite is the real-manager gate)" >&2
  exit 0
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

# One round trip: declare `pkg` for `backend`, and require MISSING -> install
# -> clean against `image`.
run_case() {
  image="$1"
  backend="$2"
  pkg="$3"

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
  # Arch publishes no arm64 image, so an Apple-silicon workstation cannot run
  # that case at all. Pull first to tell "this host has no such image" apart
  # from "the adapter is broken": only the second is a failure.
  if ! docker pull --platform "$platform" "$image" >"$case_dir/pull.txt" 2>&1; then
    if grep -q "no matching manifest" "$case_dir/pull.txt"; then
      skip "$backend ($image): no $platform image; run this case on an amd64 host" \
        "$(tail -1 "$case_dir/pull.txt")"
      return
    fi
    no "$backend ($image): docker pull failed" "$(tail -2 "$case_dir/pull.txt")"
    return
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

  if echo "$before" | grep -q "MISSING   $backend $pkg"; then
    ok "$backend ($image): a declared package the machine lacks is MISSING"
  else
    no "$backend ($image): expected '$pkg' MISSING before apply" "$(echo "$before" | tail -5)"
  fi

  if grep -q "Packages: 1 installed, 0 failed" "$out"; then
    ok "$backend ($image): apply installed it through the real manager"
  else
    no "$backend ($image): apply did not report a successful install" "$(grep -i 'packages:\|failed' "$out" | tail -3)"
  fi

  if echo "$after" | grep -q "MISSING   $backend $pkg"; then
    no "$backend ($image): still MISSING after apply" "$(echo "$after" | tail -5)"
  else
    ok "$backend ($image): the drift is clean after apply"
  fi

  # The query must return bare names. A format regression (dnf5 without its
  # trailing newline) runs every name together, which shows up as one absurd
  # untracked entry rather than many.
  longest="$(echo "$after" | grep "UNTRACKED $backend " | sed "s/.*UNTRACKED $backend //" | awk '{ print length }' | sort -rn | head -1)"
  if [ -z "$longest" ] || [ "$longest" -lt 80 ]; then
    ok "$backend ($image): installed names come back one per line"
  else
    no "$backend ($image): an untracked name is $longest chars; the query lost its separator" \
      "$(echo "$after" | grep "UNTRACKED $backend " | head -1 | cut -c1-100)"
  fi
}

if [ "$#" -gt 0 ]; then
  while [ "$#" -ge 3 ]; do
    run_case "$1" "$2" "$3"
    shift 3
  done
else
  run_case debian:stable apt ripgrep
  run_case fedora:latest dnf ripgrep
  run_case opensuse/tumbleweed zypper ripgrep
  # Arch publishes no arm64 image, so this case skips on an arm64 host.
  run_case archlinux:latest pacman ripgrep
fi

if [ "$skips" -gt 0 ]; then
  printf '\n%d passed, %d failed, %d skipped\n' "$passes" "$fails" "$skips"
else
  printf '\n%d passed, %d failed\n' "$passes" "$fails"
fi
[ "$fails" -eq 0 ]
