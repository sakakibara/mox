#!/bin/sh
# mox installer. Fetches the release binary for this OS/arch, verifies it
# against the release's SHA256SUMS, and installs it -- depending on nothing a
# fresh machine lacks (a POSIX shell, curl or wget, tar, and sha256sum or
# shasum). Any arguments after `--` are handed straight to the installed mox, so
# one command can take a bare machine all the way to configured:
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/sakakibara/mox/main/install.sh)" -- \
#       init --clone https://github.com/<you>/dotfiles --apply
#
# Overrides (environment):
#   MOX_VERSION     release tag to install          (default: latest)
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

tmp="$(mktemp -d)"
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

mkdir -p "$BINDIR"
install -m 0755 "${tmp}/mox" "${BINDIR}/mox" 2>/dev/null ||
	{ cp "${tmp}/mox" "${BINDIR}/mox" && chmod 0755 "${BINDIR}/mox"; } ||
	die "could not install to ${BINDIR} (set BINDIR to a writable directory)"

say "installed ${BINDIR}/mox ($("${BINDIR}/mox" version 2>/dev/null || echo '?'))"

case ":${PATH}:" in
*":${BINDIR}:"*) ;;
*) say "note: ${BINDIR} is not on your PATH -- add it to run 'mox' directly" ;;
esac

# Full pass-through: anything after `--` runs against the freshly installed mox,
# so install-and-bootstrap is a single command.
if [ "$#" -gt 0 ]; then
	say "running: mox $*"
	exec "${BINDIR}/mox" "$@"
fi
