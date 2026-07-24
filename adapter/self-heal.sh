#!/usr/bin/env sh
# claude-termux self-heal — Re-patches if an official update overwrites the wrapper.

BASE="$HOME/.local/share/claude-termux"
GLIBC="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib"
WRAPPER="$HOME/.local/bin/claude"
VERSIONS="$HOME/.local/share/claude/versions"

NEW_BIN=""

# Case 1: official updater replaced the wrapper with a raw ELF binary.
ELF_MAGIC=$(printf '\177ELF')
if [ -f "$WRAPPER" ] && [ ! -L "$WRAPPER" ] && [ "$(head -c 4 "$WRAPPER" 2>/dev/null)" = "$ELF_MAGIC" ]; then
  NEW_BIN="$WRAPPER"
fi

# Case 2: official updater replaced the wrapper with a symlink into its
# versioned layout (~/.local/share/claude/versions/<v>). Even when the target
# is valid, the raw glibc ELF cannot run without the loader (and chroot-era
# links point at /home/..., dangling entirely) — adopt the newest downloaded
# version instead of following the link.
if [ -z "$NEW_BIN" ] && [ -L "$WRAPPER" ]; then
  case "$(readlink "$WRAPPER" 2>/dev/null)" in
    */.local/share/claude/versions/*)
      latest=$(ls -t "$VERSIONS" 2>/dev/null | head -n 1)
      if [ -n "$latest" ] && [ -f "$VERSIONS/$latest" ]; then
        NEW_BIN="$VERSIONS/$latest"
      fi
      ;;
  esac
fi

[ -n "$NEW_BIN" ] || exit 0

echo "[claude-termux] Official binary detected — re-configuring wrapper..."

mkdir -p "$BASE/bin" "$BASE/lib"
[ -f "$BASE/bin/claude" ] && cp "$BASE/bin/claude" "$BASE/bin/claude.bak"

if [ "$NEW_BIN" = "$WRAPPER" ]; then
  mv "$WRAPPER" "$BASE/bin/claude"
else
  cp "$NEW_BIN" "$BASE/bin/claude"
  rm -f "$WRAPPER"
fi
chmod +x "$BASE/bin/claude"

# Rewrite the OAuth callback URLs (localhost -> 127.0.0.1) for Android.
"$BASE/adapter/patch" "$BASE/bin/claude" "$BASE/bin/claude"

ln -sfn "$GLIBC/libc.so.6" "$BASE/lib/libc.so"
ln -sfn "$GLIBC/libc.so.6" "$BASE/lib/libc.so.6"

sed "1s|#!/usr/bin/env sh|#!${PREFIX:-/data/data/com.termux/files/usr}/bin/sh|" \
  "$BASE/adapter/wrapper.sh" > "$WRAPPER"
chmod +x "$WRAPPER"
echo "✓ Ready."
