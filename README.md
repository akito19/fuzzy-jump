# fj - Fuzzy Directory Jump

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
curl -fsSL https://raw.githubusercontent.com/akito19/fuzzy-jump/main/install.sh | sh
```

You can also specify the install directory:

```bash
curl -fsSL https://raw.githubusercontent.com/akito19/fuzzy-jump/main/install.sh | FJ_INSTALL_DIR=/usr/local/bin sh
```

### Build from Source

Requires Zig 0.15.0 or later.

```bash
git clone https://github.com/akito19/fuzzy-jump.git
cd fuzzy-jump
zig build -Doptimize=ReleaseFast
cp zig-out/bin/fj ~/.local/bin/
```

## Shell Integration

### Zsh

Add to your `~/.zshrc`:

```zsh
eval "$(fj init zsh)"
```

### Bash

Add to your `~/.bashrc`:

```bash
eval "$(fj init bash)"
```

### Fish

Add to your `~/.config/fish/config.fish`:

```fish
fj init fish | source
```

### cd Override (Optional)

You can optionally enable cd override, which falls back to `fj` when the normal `cd` command fails:

```bash
# Bash/Zsh
export FJ_CD_OVERRIDE=1
eval "$(fj init zsh)"  # or bash

# Fish
set -gx FJ_CD_OVERRIDE 1
fj init fish | source
```

With this enabled:

| Command | Behavior |
|---------|----------|
| `cd` | Go to `$HOME` (normal) |
| `cd -` | Go to previous directory (normal) |
| `cd /existing/path` | Normal cd |
| `cd proj` | If not found, search with `fj proj` |

## Usage

```
fj [OPTIONS] [QUERY]
fj init <SHELL>
fj import <SOURCE>
fj self-update
<command> | fj [QUERY]
```

### Arguments

- `[QUERY]` - Fuzzy search pattern for directory name

### Commands

| Command | Description |
|---------|-------------|
| `init <SHELL>` | Print shell integration script (`bash`, `zsh`, or `fish`) |
| `import <SOURCE>` | Import history from shell history file (`--zsh-history`, `--bash-history`) |
| `self-update` | Update fj to the latest version |

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

`fj` can read paths from stdin, allowing integration with tools like `ghq`, `fd`, `find`, etc.

```bash
# Select from ghq-managed repositories
ghq list -p | fj

# Select from fd results
fd -t d | fj

# Filter piped input with a query
ghq list -p | fj proj
```

### Examples

```bash
# Launch interactive mode
fj

# Search for directories matching "proj"
fj proj

# Jump to a directory starting with "work"
fj work

# Import directories from zsh history (bootstrap)
fj import --zsh-history

# Update to the latest version
fj self-update

# Select from ghq repositories and cd into it
cd "$(ghq list -p | fj)"
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

## Migration from zj

If you are upgrading from a previous version (`zj`), you need to manually migrate your history file:

```bash
mv ~/.local/share/zj ~/.local/share/fj
```

## License

MIT
