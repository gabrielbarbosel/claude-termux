#!/usr/bin/env bash
# claude-termux installer — Complete setup: downloads Claude Code, configures shell.
# Usage: curl -fsSL https://raw.githubusercontent.com/gabrielbarbosel/claude-termux/main/install.sh | bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/gabrielbarbosel/claude-termux/main"
BASE="$HOME/.local/share/claude-termux"
BIN_DIR="$HOME/.local/bin"
GLIBC="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib"

echo "claude-termux — Claude Code for Android/Termux"
echo ""

# Requirements — auto-install missing packages
echo "⠋ Checking requirements..."
[ "$(uname -m)" = "aarch64" ] || { echo "✗ ARM64 (aarch64) required."; exit 1; }

if [ ! -f "$GLIBC/ld-linux-aarch64.so.1" ]; then
  echo "⠋ Installing glibc..."
  pkg install -y glibc-repo 2>/dev/null; pkg install -y glibc
fi
command -v curl >/dev/null || { echo "⠋ Installing curl..."; pkg install -y curl; }

[ -f "$GLIBC/ld-linux-aarch64.so.1" ] || { echo "✗ glibc install failed."; exit 1; }
echo "✓ Requirements met."

# Configure nsswitch.conf for DNS resolution inside glibc
GLIBC_ETC="${PREFIX:-/data/data/com.termux/files/usr}/glibc/etc"
mkdir -p "$GLIBC_ETC"
if [ ! -f "$GLIBC_ETC/nsswitch.conf" ] || ! grep -q 'hosts:' "$GLIBC_ETC/nsswitch.conf" 2>/dev/null; then
  echo 'hosts: files dns' > "$GLIBC_ETC/nsswitch.conf"
fi

# Adapter scripts — use local repo if available, otherwise download from GitHub
mkdir -p "$BASE/adapter" "$BASE/bin" "$BASE/lib" "$BIN_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ -f "$SCRIPT_DIR/adapter/wrapper.sh" ]; then
  cp "$SCRIPT_DIR/adapter/"* "$BASE/adapter/" 2>/dev/null || true
  echo "✓ Adapter installed (local)."
else
  echo "⠋ Downloading adapter scripts..."
  for f in wrapper.sh update.sh self-heal.sh dns-heal.js path-shim.c patch; do
    curl -fsSL -o "$BASE/adapter/$f" "$REPO/adapter/$f" \
      || { echo "✗ Failed to download $f"; exit 1; }
  done
  echo "✓ Adapter installed (remote)."
fi
chmod +x "$BASE/adapter/"*.sh "$BASE/adapter/patch"

# glibc shims
ln -sfn "$GLIBC/libc.so.6" "$BASE/lib/libc.so"
ln -sfn "$GLIBC/libc.so.6" "$BASE/lib/libc.so.6"
ln -sfn "$GLIBC/libdl.so.2" "$BASE/lib/libdl.so" 2>/dev/null || true
ln -sfn "$GLIBC/libdl.so.2" "$BASE/lib/libdl.so.2" 2>/dev/null || true


# path-shim.so — libc-layer redirect of /etc/resolv.conf|hosts to $PREFIX/etc
# (node's bundled binary ignores NODE_OPTIONS; its c-ares resolver reads the
# literal /etc/resolv.conf, absent on Android → ETIMEOUT on OAuth login).
# Use the prebuilt aarch64 .so from the repo; rebuild locally if a compiler
# targeting glibc is available.
if [ ! -f "$BASE/lib/path-shim.so" ]; then
  curl -fsSL -o "$BASE/lib/path-shim.so" "$REPO/adapter/path-shim.so" 2>/dev/null \
    || echo "⚠ path-shim.so unavailable — OAuth login may fail with ETIMEOUT (see README)"
fi

# Install wrapper with correct shebang for this system
sed "1s|#!/usr/bin/env sh|#!${PREFIX:-/data/data/com.termux/files/usr}/bin/sh|" \
  "$BASE/adapter/wrapper.sh" > "$BIN_DIR/claude"
chmod +x "$BIN_DIR/claude"

# Download Claude binary (reuses update.sh)
bash "$BASE/adapter/update.sh"

# Shell config
RC="$HOME/.bashrc"
if ! grep -q 'claude-termux/adapter/self-heal.sh' "$RC" 2>/dev/null; then
  cat >> "$RC" << 'EOF'
export PATH="$HOME/.local/bin:$PATH"
claude() {
  hash -r
  "$HOME/.local/share/claude-termux/adapter/self-heal.sh"
  "$HOME/.local/bin/claude" "$@"
}
EOF
  echo "✓ Shell configured. Run: source ~/.bashrc"
else
  echo "✓ Shell already configured."
fi

echo ""
echo "✓ Installed. Run: source ~/.bashrc && claude"
