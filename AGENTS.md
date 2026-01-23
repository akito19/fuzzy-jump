# AGENTS.md

## Project Overview

z-jump (zj) is a fuzzy directory jump tool written in Zig. It extracts directory navigation history from shell history files and provides fast directory switching using Frecency scoring (frequency + recency) combined with fuzzy matching.

### Key Features

- Frecency-based scoring algorithm
- Fuzzy matching with basename prioritization
- Interactive TUI (Terminal User Interface)
- Multi-shell support (bash, zsh, fish)
- UTF-8 support

## Requirements

- Zig 0.15.0 or later

## Build Commands

| Command | Description |
|---------|-------------|
| `zig build` | Debug build |
| `zig build -Doptimize=ReleaseFast` | Release build (recommended for production) |
| `zig build test` | Run unit tests |
| `zig build run -- [args]` | Build and run immediately |

## Code Structure

```
src/
├── main.zig        # Entry point, CLI argument parsing, workflow control
├── history.zig     # Shell history parsing (zsh/bash), path extraction and normalization
├── scoring.zig     # Frecency score calculation, combined score computation
├── fuzzy.zig       # Fuzzy matching with basename priority, match level scoring
├── tui.zig         # Interactive UI, real-time filtering, key bindings
├── terminal.zig    # Terminal control, raw mode, ANSI escape sequences
└── shell/
    ├── zj.bash     # Bash shell integration script
    ├── zj.zsh      # Zsh shell integration script
    └── zj.fish     # Fish shell integration script
```

## Development Flow

1. Create a new branch from `main`:
   ```bash
   git switch -c <prefix>/<description>
   ```

2. Use appropriate branch prefixes:
   - `feature/` - New features
   - `fix/` - Bug fixes
   - `chore/` - Maintenance tasks
   - `deps/` - Dependency updates
   - `test/` - Test additions or improvements

3. Push and create a pull request (e.g., using `gh` CLI)

4. **Never auto-merge without approval** - All PRs require review approval before merging

## Code Style

- Follow Zig standard coding style
- Write tests within each module using `test` blocks
- Run `zig build test` before committing to ensure all tests pass

## Security Considerations

When modifying this codebase, be aware of the following security measures:

- **Path traversal prevention**: Shell integration scripts validate paths for newline characters
- **Input sanitization**: TUI sanitizes ESC sequences and control characters in displayed paths
- **Shell expansion skip**: Commands containing `$(...)` are excluded from history parsing
- **Absolute paths only**: Only existing absolute paths are stored and used
- **Quote handling**: Proper quoting in shell scripts (`cd -- "$dir"`)
