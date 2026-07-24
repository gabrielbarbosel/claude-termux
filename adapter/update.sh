#!/usr/bin/env bash
# claude-termux update — Downloads, extracts, and swaps the Claude Code binary.
set -euo pipefail

BASE="$HOME/.local/share/claude-termux"
GLIBC="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib"
CLAUDE_BIN="$BASE/bin/claude"
STAGING="$HOME/.cache/claude-termux/staging"
REGISTRY_URL="https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64/latest"

die() { echo "   ✗ $*" >&2; exit 1; }

# parse_json prints the first string value of the given key in a JSON blob.
parse_json() { echo "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }

run_claude() {
  unset LD_PRELOAD LD_LIBRARY_PATH 2>/dev/null || true
  GODEBUG=netdns=cgo \
  SSL_CERT_FILE="${PREFIX:-/data/data/com.termux/files/usr}/etc/tls/cert.pem" \
    "$GLIBC/ld-linux-aarch64.so.1" --library-path "$BASE/lib:$GLIBC" \
    "$CLAUDE_BIN" "$@" 2>/dev/null
}

rollback() {
  [ -f "$CLAUDE_BIN.bak" ] && mv "$CLAUDE_BIN.bak" "$CLAUDE_BIN" && echo "   ✓ Rolled back to v$CURRENT"
}

cleanup() { rm -rf "$STAGING" 2>/dev/null || true; }
trap cleanup EXIT

# Get current version
CURRENT=$(run_claude -v 2>/dev/null | head -n1 | cut -d' ' -f1 || echo "unknown")

echo "⠋ Checking for updates..."
metadata=$(curl -fsSL "$REGISTRY_URL") || die "Cannot reach npm registry."

LATEST=$(parse_json "$metadata" version)
URL=$(parse_json "$metadata" tarball)
SHA512=$(parse_json "$metadata" integrity)

[ -n "$URL" ] && [ -n "$SHA512" ] || die "Invalid release metadata."

if [ "$CURRENT" = "$LATEST" ]; then
  echo "✓ Claude Code is already up to date (v$CURRENT)"
  exit 0
fi

echo "  v$CURRENT → v$LATEST"
echo "⠋ Downloading..."

mkdir -p "$STAGING"
dl="$STAGING/claude.tgz"
curl -fsSL -o "$dl" "$URL" || die "Download failed."

# Verify checksum
if [[ "$SHA512" =~ ^sha512- ]]; then
  expected_hex=$(printf '%s' "${SHA512#sha512-}" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  actual_hex=$(sha512sum "$dl" | cut -d' ' -f1)
  if [ "$actual_hex" != "$expected_hex" ]; then
    die "Checksum mismatch — aborting."
  fi
fi

echo "✓ Downloaded and verified."
echo "⠋ Extracting package..."

tar -xzf "$dl" -C "$STAGING" 2>/dev/null || die "Extraction failed."
bin="$STAGING/package/claude"
[ -f "$bin" ] || die "Binary not found in archive."

# Backup and swap
[ -f "$CLAUDE_BIN" ] && cp "$CLAUDE_BIN" "$CLAUDE_BIN.bak"
cp "$bin" "$CLAUDE_BIN" && chmod +x "$CLAUDE_BIN"

# Rewrite the OAuth callback URLs (localhost -> 127.0.0.1) for Android.
"$BASE/adapter/patch" "$CLAUDE_BIN" "$CLAUDE_BIN"

NEW=$(run_claude -v 2>/dev/null | head -n1 | cut -d' ' -f1 || echo "")
if [ -z "$NEW" ]; then
  echo "✗ Binary verification failed."; rollback; exit 1
fi

echo "✓ Updated successfully: v$CURRENT → v$NEW"
