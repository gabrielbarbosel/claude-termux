#!/usr/bin/env sh
# claude-termux wrapper — Runs Claude Code through glibc on Android.

BASE="$HOME/.local/share/claude-termux"
USR="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC="$USR/glibc/lib"

unset LD_PRELOAD LD_LIBRARY_PATH
export GODEBUG=netdns=cgo
export SSL_CERT_FILE="$USR/etc/tls/cert.pem"
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1

# Claude Code only auto-opens URLs (login/OAuth) on Linux when $DISPLAY or
# $WAYLAND_DISPLAY is present — unless $BROWSER points at an opener. Android
# has no display server, so route it through Termux's URL opener.
export BROWSER="${BROWSER:-$USR/bin/termux-open-url}"

# Termux glibc reads its config from $PREFIX/glibc/etc (not /etc), and ships
# resolv.conf/hosts as symlinks into $PREFIX/etc — the files dns-heal below
# maintains. Recreate the symlinks if a glibc update ever drops them, so no
# chroot is needed to redirect filesystem access.
[ -e "$USR/glibc/etc/resolv.conf" ] || ln -sfn "$USR/etc/resolv.conf" "$USR/glibc/etc/resolv.conf" 2>/dev/null || true
[ -e "$USR/glibc/etc/hosts" ] || ln -sfn "$USR/etc/hosts" "$USR/glibc/etc/hosts" 2>/dev/null || true

# Last-resort seed so the API resolves even on a first run without network.
# dns-heal refreshes every pin with live answers whenever the network is up,
# so a stale seed self-corrects on the next start.
mkdir -p "$USR/etc"
[ -f "$USR/etc/hosts" ] || touch "$USR/etc/hosts"
if ! grep -q "api.anthropic.com" "$USR/etc/hosts"; then
  echo "160.79.104.10 api.anthropic.com" >> "$USR/etc/hosts"
  echo "2607:6bc0::10 api.anthropic.com" >> "$USR/etc/hosts"
fi

# Heal resolv.conf and refresh hosts pins with real, network-sourced answers
# (never dns.lookup/getServers, which read the very files being healed).
if command -v node >/dev/null 2>&1; then
  node "$BASE/adapter/dns-heal.js" "$USR/etc/hosts" "$USR/etc/resolv.conf" \
    api.anthropic.com statsig.anthropic.com claude.ai anthropic.com \
    claude.com platform.claude.com console.anthropic.com github.com \
    2>/dev/null || true
fi

# Route `claude update` or `claude upgrade` through our safe updater.
case "${1:-}" in
  update|upgrade) exec bash "$BASE/adapter/update.sh" ;;
esac

# Exec the glibc loader directly — no termux-chroot. The chroot exported
# HOME=/home, poisoning absolute paths the official updater writes (dangling
# symlinks outside the chroot), and glibc already finds its DNS config via
# $PREFIX/glibc/etc.
#
# path-shim.so redirects /etc/resolv.conf and /etc/hosts to $PREFIX/etc at
# the libc layer — the only layer that works here. Node's bundled binary
# ignores NODE_OPTIONS (a JS-level dns shim can't load), and its c-ares
# resolver (dns.resolve*, dns.Resolver, used by the OAuth login flow) reads
# the literal /etc/resolv.conf, which doesn't exist on Android; it then falls
# back to 127.0.0.1:53 and every resolve dies with ETIMEOUT. ld.so --preload
# keeps the shim scoped to this process (an inherited LD_PRELOAD would leak
# into bionic children).
PRELOAD_ARGS=""
[ -f "$BASE/lib/path-shim.so" ] && PRELOAD_ARGS="--preload $BASE/lib/path-shim.so"
exec "$GLIBC/ld-linux-aarch64.so.1" \
  $PRELOAD_ARGS \
  --library-path "$BASE/lib:$GLIBC" \
  "$BASE/bin/claude" "$@"
