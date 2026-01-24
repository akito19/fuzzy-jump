# zj - Fuzzy Directory Jump

A fuzzy directory jump tool that extends `cd`. It extracts directory navigation history from your shell history, scores entries using frecency (frequency + recency), and filters candidates with fuzzy matching. When multiple candidates exist, it presents a peco-like interactive TUI for selection.

## Features

- Automatic extraction of `cd` commands from shell history (bash/zsh)
- Frecency scoring (prioritizes frequently used and recently accessed directories)
- Fuzzy matching with basename-priority scoring
- Interactive TUI with real-time filtering
- Pipe input support (use with `ghq`, `fd`, etc.)
- UTF-8 support (works with non-ASCII directory names)

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/akito19/z-jump/main/install.sh | sh
```

You can also specify the install directory:

```bash
curl -fsSL https://raw.githubusercontent.com/akito19/z-jump/main/install.sh | ZJ_INSTALL_DIR=/usr/local/bin sh
```

### Build from Source

Requires Zig 0.15.0 or later.

```bash
git clone https://github.com/akito19/z-jump.git
cd z-jump
zig build -Doptimize=ReleaseFast
cp zig-out/bin/zj ~/.local/bin/
```

## Shell Integration

### Zsh

Add to your `~/.zshrc`:

```zsh
eval "$(zj init zsh)"
```

### Bash

Add to your `~/.bashrc`:

```bash
eval "$(zj init bash)"
```

### Fish

Add to your `~/.config/fish/config.fish`:

```fish
zj init fish | source
```

### cd Override (Optional)

You can optionally enable cd override, which falls back to `zj` when the normal `cd` command fails:

```bash
# Bash/Zsh
export ZJ_CD_OVERRIDE=1
eval "$(zj init zsh)"  # or bash

# Fish
set -gx ZJ_CD_OVERRIDE 1
zj init fish | source
```

With this enabled:

| Command | Behavior |
|---------|----------|
| `cd` | Go to `$HOME` (normal) |
| `cd -` | Go to previous directory (normal) |
| `cd /existing/path` | Normal cd |
| `cd proj` | If not found, search with `zj proj` |

## Usage

```
zj [OPTIONS] [QUERY]
zj init <SHELL>
zj import <SOURCE>
zj self-update
<command> | zj [QUERY]
```

### Arguments

- `[QUERY]` - Fuzzy search pattern for directory name

### Commands

| Command | Description |
|---------|-------------|
| `init <SHELL>` | Print shell integration script (`bash`, `zsh`, or `fish`) |
| `import <SOURCE>` | Import history from shell history file (`--zsh-history`, `--bash-history`) |
| `self-update` | Update zj to the latest version |

### Options

| Option | Description |
|--------|-------------|
| `-h`, `--help` | Show help message |
| `-v`, `--version` | Show version |
| `--debug-history` | Show parsed history entries |

### Import Sources

| Source | Description |
|--------|-------------|
| `--zsh-history` | Import from `~/.zsh_history` (or `$HISTFILE`) |
| `--bash-history` | Import from `~/.bash_history` (or `$HISTFILE`) |

### Pipe Input

`zj` can read paths from stdin, allowing integration with tools like `ghq`, `fd`, `find`, etc.

```bash
# Select from ghq-managed repositories
ghq list -p | zj

# Select from fd results
fd -t d | zj

# Filter piped input with a query
ghq list -p | zj proj
```

### Examples

```bash
# Launch interactive mode
zj

# Search for directories matching "proj"
zj proj

# Jump to a directory starting with "work"
zj work

# Import directories from zsh history (bootstrap)
zj import --zsh-history

# Update to the latest version
zj self-update

# Select from ghq repositories and cd into it
cd "$(ghq list -p | zj)"
```

## Interactive Keys

| Key | Action |
|-----|--------|
| `↑` / `Ctrl-P` | Move to previous entry |
| `↓` / `Ctrl-N` | Move to next entry |
| `Enter` | Select directory |
| `Esc` / `Ctrl-C` | Cancel |
| `Backspace` | Delete character |
| `Ctrl-U` | Clear input |
| `Ctrl-W` | Delete word |

## How It Works

1. **History Parsing**: Extracts `cd` commands from `~/.zsh_history` or `~/.bash_history`
2. **Frecency Scoring**: Calculates score based on visit count and last access time
3. **Fuzzy Matching**: Matches query against paths with basename priority
4. **TUI Selection**: Presents interactive selection when multiple candidates exist

## License

MIT
