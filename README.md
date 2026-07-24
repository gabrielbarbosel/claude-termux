# claude-termux

Run [Claude Code](https://claude.ai) on Android/Termux — no root required.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gabrielbarbosel/claude-termux/main/install.sh | bash
source ~/.bashrc
```

That's it. Dependencies, binary download, glibc runtime configuration — all handled automatically.

## Usage

```bash
claude                 # Start (same as desktop)
claude update          # Update to latest version
claude --version       # Show version
```

## How it works

The official Claude Code binary targets glibc. Android uses Bionic. This adapter bridges the gap by routing execution of the official `linux-arm64` binary through a glibc dynamic loader setup.

| File | Role |
|---|---|
| `wrapper.sh` | Routes execution through glibc's dynamic linker |
| `update.sh` | Downloads, verifies (SHA512), and swaps the native binary from the npm registry |
| `self-heal.sh` | Auto-repairs if an official update overwrites the wrapper |

## Requirements

- Termux from [F-Droid](https://f-droid.org/) or [GitHub releases](https://github.com/termux/termux-app/releases) (not Google Play Store)
- ARM64 device

All package dependencies (`glibc`, `curl`) are installed automatically.

## Uninstall

```bash
rm -rf ~/.local/share/claude-termux ~/.local/bin/claude
# Remove the claude() function from ~/.bashrc
```

## License

MIT
