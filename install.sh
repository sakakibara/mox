#!/bin/sh
# mox installer. Fetches the release binary for this OS/arch, verifies it
# against the release's SHA256SUMS, and installs it -- depending on nothing a
# fresh machine lacks (a POSIX shell, curl or wget, tar, and sha256sum,
# shasum or openssl). Any arguments after `--` are handed straight to the installed mox, so
# one command can take a bare machine all the way to configured:
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)" -- \
#       init --clone https://github.com/<you>/dotfiles --apply
#
# Overrides (environment):
#   MOX_VERSION     release tag to install          (default: latest)
#   TMPDIR          where the download is staged    (default: /tmp)
#   BINDIR          install directory               (default: $HOME/.local/bin)
#   MOX_REPO_SLUG   GitHub owner/repo to fetch from  (default: sakakibara/mox)
#   MOX_BASE_URL    download base URL (mirror)       (default: the GitHub release)

set -eu

REPO_SLUG="${MOX_REPO_SLUG:-sakakibara/mox}"
VERSION="${MOX_VERSION:-latest}"
BINDIR="${BINDIR:-${HOME}/.local/bin}"

die() { echo "mox install: $*" >&2; exit 1; }
say() { echo "mox install: $*" >&2; }

# `sh -c "$(curl ...)" -- ARGS` makes `--` the $0 placeholder (not in $@), but
# `sh install.sh -- ARGS` leaves it as $1. Strip a leading `--` so both forms
# forward ARGS cleanly to mox.
if [ "${1:-}" = "--" ]; then shift; fi

if command -v curl >/dev/null 2>&1; then
	dl() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
	dl() { wget -qO "$2" "$1"; }
else
	die "need curl or wget"
fi

# Compute a file's SHA-256 as bare lowercase hex. `-c`-style checking is not
# portable (macOS's sha256sum takes different flags than GNU's), so we compute
# and string-compare instead -- every tool below AGREES on the digest.
if command -v sha256sum >/dev/null 2>&1; then
	sha256hex() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	sha256hex() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif command -v openssl >/dev/null 2>&1; then
	sha256hex() { openssl dgst -sha256 "$1" | awk '{ print $NF }'; }
else
	die "need sha256sum, shasum, or openssl to verify the download"
fi

os="$(uname -s)"
case "$os" in
Darwin) os_tag=macos ;;
Linux) os_tag=linux ;;
*) die "unsupported OS '$os' -- on Windows run install.ps1" ;;
esac

arch="$(uname -m)"
case "$arch" in
arm64 | aarch64) arch_tag=aarch64 ;;
x86_64 | amd64) arch_tag=x86_64 ;;
*) die "unsupported architecture '$arch'" ;;
esac

asset="mox-${arch_tag}-${os_tag}.tar.gz"

if [ -n "${MOX_BASE_URL:-}" ]; then
	base="$MOX_BASE_URL"
elif [ "$VERSION" = latest ]; then
	base="https://github.com/${REPO_SLUG}/releases/latest/download"
else
	base="https://github.com/${REPO_SLUG}/releases/download/${VERSION}"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mox-install.XXXXXX" 2>/dev/null)" || die "could not create a staging directory under ${TMPDIR:-/tmp}"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading ${asset} (${VERSION})"
dl "${base}/${asset}" "${tmp}/${asset}" || die "could not download ${base}/${asset}"
dl "${base}/SHA256SUMS" "${tmp}/SHA256SUMS" || die "could not download ${base}/SHA256SUMS"

# Verify against ONLY this asset's SHA256SUMS entry, and require it to exist --
# a missing entry is a failure, never a silent skip.
expected="$(awk -v f="$asset" '$2 == f { print $1; found = 1 } END { exit !found }' "${tmp}/SHA256SUMS")" ||
	die "SHA256SUMS has no entry for ${asset}"
say "verifying checksum"
actual="$(sha256hex "${tmp}/${asset}")"
[ "$expected" = "$actual" ] ||
	die "checksum verification FAILED for ${asset} -- refusing to install"

tar -xzf "${tmp}/${asset}" -C "$tmp" || die "could not extract ${asset}"
[ -f "${tmp}/mox" ] || die "archive did not contain a mox binary"

mkdir -p "$BINDIR" 2>/dev/null || die "could not create ${BINDIR}"
# Staged in the target directory (same filesystem, so the rename is atomic)
# and moved into place, rather than written over the live binary: an
# interrupted or short write must not leave a truncated mox behind. The
# staging path is per-process so two installs cannot collide.
[ -d "${BINDIR}/mox" ] && die "${BINDIR}/mox is a directory; remove it or set BINDIR"
staged="${BINDIR}/.mox.install.$$"
trap 'rm -rf "$tmp" "$staged"' EXIT INT TERM
install -m 0755 "${tmp}/mox" "$staged" 2>/dev/null ||
	{ cp "${tmp}/mox" "$staged" 2>/dev/null && chmod 0755 "$staged" 2>/dev/null; } ||
	{ rm -f "$staged"; die "could not install to ${BINDIR} (set BINDIR to a writable directory)"; }
mv -f "$staged" "${BINDIR}/mox" ||
	{ rm -f "$staged"; die "could not replace ${BINDIR}/mox"; }

say "installed ${BINDIR}/mox ($("${BINDIR}/mox" version 2>/dev/null || echo '?'))"

case ":${PATH}:" in
*":${BINDIR}:"*) ;;
*) say "note: ${BINDIR} is not on your PATH -- add it to run 'mox' directly" ;;
esac

# Full pass-through: anything after `--` runs against the freshly installed mox,
# so install-and-bootstrap is a single command.
if [ "$#" -gt 0 ]; then
	say "running: mox $*"
	# An EXIT trap does not survive exec, and this is the path the documented
	# one-liner takes, so clean up before replacing the process.
	rm -rf "$tmp"
	trap - EXIT INT TERM
	exec "${BINDIR}/mox" "$@"
fi
