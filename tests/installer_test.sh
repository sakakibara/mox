#!/usr/bin/env sh
# Run with: sh tests/installer_test.sh   (from the repo root)
#
# install.sh is published from `main` and is the first thing a fresh machine
# runs, and until this existed nothing exercised it at all. Everything here is
# offline: MOX_BASE_URL points at a fixture release served over file://, so the
# test covers the real code path without depending on a published release.

set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

passes=0
fails=0
ok() { printf '  ok   %s\n' "$1"; passes=$((passes + 1)); }
no() { printf '  FAIL %s\n      %s\n' "$1" "$2"; fails=$((fails + 1)); }

# The asset name install.sh will construct for this host.
case "$(uname -s)" in
Darwin) os_tag=macos ;;
Linux) os_tag=linux ;;
*) echo "unsupported OS for this test" >&2; exit 0 ;;
esac
case "$(uname -m)" in
arm64 | aarch64) arch_tag=aarch64 ;;
x86_64 | amd64) arch_tag=x86_64 ;;
*) echo "unsupported arch for this test" >&2; exit 0 ;;
esac
asset="mox-${arch_tag}-${os_tag}.tar.gz"

if command -v sha256sum >/dev/null 2>&1; then
	sha() { sha256sum "$1" | cut -d' ' -f1; }
else
	sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

# A fixture release: a stand-in mox that reports a version and passes an exit
# code through, so the installer's own behaviour is what is measured.
rel="$work/release"
mkdir -p "$rel" "$work/stage"
cat > "$work/stage/mox" <<'EOF'
#!/bin/sh
case "${1:-}" in
version) echo "mox 9.9.9-fixture" ;;
fail) exit 42 ;;
*) echo "fixture: $*" ;;
esac
EOF
chmod 0755 "$work/stage/mox"
(cd "$work/stage" && tar -czf "$rel/$asset" mox)
(cd "$rel" && sha "$asset" | awk -v n="$asset" '{ print $1 "  " n }' > SHA256SUMS)

base="file://$rel"

printf '\ninstalling from a fixture release\n'
bin="$work/bin"
if MOX_BASE_URL="$base" BINDIR="$bin" sh "$repo/install.sh" >"$work/out1" 2>&1; then
	ok "a verified release installs"
else
	no "a verified release installs" "$(tail -2 "$work/out1")"
fi
[ -x "$bin/mox" ] && ok "the binary is present and executable" || no "the binary is present and executable" "missing"
[ "$("$bin/mox" version)" = "mox 9.9.9-fixture" ] && ok "the installed binary runs" || no "the installed binary runs" "wrong output"

printf '\nthe pass-through path\n'
# `install.sh -- ARGS` execs the installed mox; its exit code is the one the
# caller sees, or a failed bootstrap looks like a successful one.
set +e
MOX_BASE_URL="$base" BINDIR="$work/bin2" sh "$repo/install.sh" -- fail >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 42 ] && ok "the exec'd mox's exit code reaches the caller" || no "the exec'd mox's exit code reaches the caller" "got $code, want 42"

# A private TMPDIR, so nothing else on the machine can add or reap an entry
# while this looks. The staging directory is gone by the time the installer
# execs, so a curl shim lists TMPDIR while the download is in flight: that
# proves the directory was made there, not merely that nothing is left.
mkdir -p "$work/tmp" "$work/shim"
real_curl=$(command -v curl)
printf '#!/bin/sh\nls -1 "$TMPDIR" >> "%s"\nexec "%s" "$@"\n' "$work/tmp-seen" "$real_curl" > "$work/shim/curl"
chmod +x "$work/shim/curl"
PATH="$work/shim:$PATH" TMPDIR="$work/tmp" MOX_BASE_URL="$base" BINDIR="$work/bin3" sh "$repo/install.sh" -- version >/dev/null 2>&1
grep -q '^mox-install\.' "$work/tmp-seen" 2>/dev/null && ok "the download is staged under TMPDIR" || no "the download is staged under TMPDIR" "$(cat "$work/tmp-seen" 2>/dev/null)"
left=$(find "$work/tmp" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
[ "$left" -eq 0 ] && ok "the exec path leaves no temp directory behind" || no "the exec path leaves no temp directory behind" "$left entry(ies) left in TMPDIR"
set +e
out=$(TMPDIR="$work/nowhere" MOX_BASE_URL="$base" BINDIR="$work/bin4" sh "$repo/install.sh" 2>&1)
code=$?
set -e
case "$out" in
	*"mox install: could not create a staging directory under $work/nowhere"*) [ "$code" -ne 0 ] && ok "a TMPDIR that does not exist is refused by name" || no "a TMPDIR that does not exist is refused by name" "exit 0" ;;
	*) no "a TMPDIR that does not exist is refused by name" "$out" ;;
esac

printf '\nrefusals, and what they leave behind\n'
# A pre-existing install must survive a refused one. This pins that
# verification happens before anything is written -- not the atomicity of the
# write itself, which needs an interrupted process to observe and is covered
# only by reading the staged-then-renamed code.
keep="$work/keep"
mkdir -p "$keep"
printf '#!/bin/sh\necho ORIGINAL\n' > "$keep/mox"
chmod 0755 "$keep/mox"

bad="$work/badsum"
mkdir -p "$bad"
cp "$rel/$asset" "$bad/$asset"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$asset" > "$bad/SHA256SUMS"
set +e
MOX_BASE_URL="file://$bad" BINDIR="$keep" sh "$repo/install.sh" >"$work/out2" 2>&1
code=$?
set -e
[ "$code" -ne 0 ] && ok "a checksum mismatch refuses" || no "a checksum mismatch refuses" "exit 0"
[ "$("$keep/mox")" = "ORIGINAL" ] && ok "a refused install leaves the existing binary intact" || no "a refused install leaves the existing binary intact" "clobbered"

miss="$work/missing"
mkdir -p "$miss"
cp "$rel/$asset" "$miss/$asset"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "some-other-asset.tar.gz" > "$miss/SHA256SUMS"
set +e
MOX_BASE_URL="file://$miss" BINDIR="$work/bin4" sh "$repo/install.sh" >"$work/out3" 2>&1
code=$?
set -e
[ "$code" -ne 0 ] && ok "a SHA256SUMS with no entry for the asset refuses" || no "a SHA256SUMS with no entry for the asset refuses" "exit 0"
[ ! -e "$work/bin4/mox" ] && ok "a refused install writes no binary" || no "a refused install writes no binary" "installed anyway"

isdir="$work/isdir"
mkdir -p "$isdir/mox"
: > "$isdir/mox/marker"
set +e
MOX_BASE_URL="$base" BINDIR="$isdir" sh "$repo/install.sh" >"$work/out4" 2>&1
code=$?
set -e
[ "$code" -ne 0 ] && ok "a directory at the target refuses" || no "a directory at the target refuses" "exit 0"
[ -f "$isdir/mox/marker" ] && [ -z "$(find "$isdir" -maxdepth 1 -name '.mox.install.*' -print 2>/dev/null)" ] && ok "the directory is left as it was, with no staging file beside it" || no "the directory is left as it was, with no staging file beside it" "$(ls -A "$isdir")"

printf '\n%d passed, %d failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
