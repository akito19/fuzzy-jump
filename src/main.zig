const std = @import("std");
const history = @import("history.zig");
const scoring = @import("scoring.zig");
const fuzzy = @import("fuzzy.zig");
const tui = @import("tui.zig");
const terminal = @import("terminal.zig");
const import_history = @import("import.zig");
const self_update = @import("self_update.zig");

const VERSION = self_update.VERSION;

/// Auto-select thresholds
const AUTO_SELECT_MIN_SCORE: i32 = 100;
const AUTO_SELECT_SCORE_MARGIN: i32 = 50;

const ScoredEntryList = std.ArrayListUnmanaged(scoring.ScoredEntry);

/// Shell type for init command
const ShellType = enum {
    bash,
    zsh,
    fish,
};

/// Parsed command line arguments
const ParsedArgs = struct {
    query: ?[]const u8,
    debug_history: bool,
    show_help: bool,
    show_version: bool,
    init_shell: ?ShellType,
    query_mode: bool,
    query_prefix: ?[]const u8,
    import_source: ?import_history.ImportSource,
    self_update: bool,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try parseArgs(allocator);

    if (args.show_help) {
        try printHelp();
        return;
    }

    if (args.show_version) {
        try printVersion();
        return;
    }

    if (args.init_shell) |shell| {
        try printInit(shell);
        return;
    }

    if (args.import_source) |source| {
        try runImport(allocator, source);
        return;
    }

    if (args.self_update) {
        self_update.selfUpdate(allocator) catch {
            std.process.exit(1);
        };
        return;
    }

    // Check if stdin is a pipe (not a TTY)
    if (!terminal.isStdinTty()) {
        runPipeMode(allocator, args.query);
        return;
    }

    var parsed_history = try history.parseHistory(allocator);
    defer parsed_history.deinit();

    if (args.query_mode) {
        try runQueryMode(allocator, parsed_history.entries.items, args.query_prefix);
        return;
    }

    if (args.debug_history) {
        try debugHistory(parsed_history.entries.items);
        return;
    }

    var scored_entries = try loadAndScoreEntries(allocator, parsed_history.entries.items, args.query);
    defer scored_entries.deinit(allocator);

    if (scored_entries.items.len == 0) {
        if (parsed_history.entries.items.len == 0) {
            // No history at all
            std.debug.print("zj: No history yet.\n", .{});
            std.debug.print("    Start using cd to build history, or run:\n", .{});
            std.debug.print("    zj import --zsh-history\n", .{});
        } else {
            // History exists but no matches for query
            std.debug.print("zj: no matching directories found\n", .{});
        }
        std.process.exit(1);
    }

    // Try auto-select for exact or single matches
    if (args.query != null) {
        if (tryAutoSelect(scored_entries.items)) |path| {
            try outputPath(path);
            return;
        }
    }

    // Interactive selection
    runInteractiveSelection(allocator, scored_entries.items);
}

/// Parse command line arguments
fn parseArgs(allocator: std.mem.Allocator) !ParsedArgs {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip program name

    var result = ParsedArgs{
        .query = null,
        .debug_history = false,
        .show_help = false,
        .show_version = false,
        .init_shell = null,
        .query_mode = false,
        .query_prefix = null,
        .import_source = null,
        .self_update = false,
    };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.show_version = true;
        } else if (std.mem.eql(u8, arg, "--debug-history")) {
            result.debug_history = true;
        } else if (std.mem.eql(u8, arg, "init")) {
            // Parse shell type for init subcommand
            if (args.next()) |shell_arg| {
                if (std.mem.eql(u8, shell_arg, "bash")) {
                    result.init_shell = .bash;
                } else if (std.mem.eql(u8, shell_arg, "zsh")) {
                    result.init_shell = .zsh;
                } else if (std.mem.eql(u8, shell_arg, "fish")) {
                    result.init_shell = .fish;
                } else {
                    std.debug.print("zj: unknown shell '{s}'. Supported: bash, zsh, fish\n", .{shell_arg});
                    std.process.exit(1);
                }
            } else {
                std.debug.print("zj: 'init' requires a shell argument. Usage: zj init <bash|zsh|fish>\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "import")) {
            // Parse import source
            if (args.next()) |source_arg| {
                if (std.mem.eql(u8, source_arg, "--zsh-history")) {
                    result.import_source = .zsh_history;
                } else if (std.mem.eql(u8, source_arg, "--bash-history")) {
                    result.import_source = .bash_history;
                } else {
                    std.debug.print("zj: unknown import source '{s}'. Supported: --zsh-history, --bash-history\n", .{source_arg});
                    std.process.exit(1);
                }
            } else {
                std.debug.print("zj: 'import' requires a source argument. Usage: zj import <--zsh-history|--bash-history>\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--query") or std.mem.eql(u8, arg, "-q")) {
            result.query_mode = true;
            result.query_prefix = args.next(); // null = empty prefix (all entries)
        } else if (std.mem.eql(u8, arg, "self-update")) {
            result.self_update = true;
        } else if (arg[0] != '-') {
            result.query = arg;
        }
    }

    return result;
}

/// Load history and convert to scored entries
fn loadAndScoreEntries(
    allocator: std.mem.Allocator,
    entries: []const history.HistoryEntry,
    query: ?[]const u8,
) !ScoredEntryList {
    const now = scoring.getCurrentTimestamp();
    var scored_entries: ScoredEntryList = .empty;
    errdefer scored_entries.deinit(allocator);

    for (entries) |entry| {
        const frecency = scoring.calculateFrecencyScore(entry.visit_count, entry.timestamp, now);

        var fuzzy_score: i32 = 0;
        if (query) |q| {
            if (fuzzy.fuzzyMatch(q, entry.path)) |score| {
                fuzzy_score = score;
            } else {
                continue;
            }
        }

        try scored_entries.append(allocator, .{
            .path = entry.path,
            .frecency_score = frecency,
            .fuzzy_score = fuzzy_score,
            .total_score = scoring.calculateTotalScore(frecency, fuzzy_score),
            .visit_count = entry.visit_count,
            .last_visit = entry.timestamp,
        });
    }

    std.mem.sort(scoring.ScoredEntry, scored_entries.items, {}, scoring.compareScores);
    return scored_entries;
}

/// Try to auto-select if there's a single match or a significantly better top match
fn tryAutoSelect(entries: []const scoring.ScoredEntry) ?[]const u8 {
    if (entries.len == 1) {
        return entries[0].path;
    }

    if (entries.len > 1) {
        const top = entries[0];
        const second = entries[1];

        if (top.fuzzy_score >= AUTO_SELECT_MIN_SCORE and
            top.fuzzy_score > second.fuzzy_score + AUTO_SELECT_SCORE_MARGIN)
        {
            return top.path;
        }
    }

    return null;
}

/// Run interactive TUI selection
fn runInteractiveSelection(allocator: std.mem.Allocator, entries: []scoring.ScoredEntry) void {
    const maybe_selected = tui.selectDirectory(allocator, entries) catch {
        std.debug.print("zj: selection error\n", .{});
        std.process.exit(1);
    };

    if (maybe_selected) |selected| {
        outputPath(selected) catch {
            std.process.exit(1);
        };
    } else {
        std.debug.print("zj: selection cancelled\n", .{});
        std.process.exit(1);
    }
}

const MAX_PIPE_SIZE = 10 * 1024 * 1024; // 10 MB max for pipe input

/// Run pipe mode: read lines from stdin, select with TUI using /dev/tty
fn runPipeMode(allocator: std.mem.Allocator, query: ?[]const u8) void {
    // Read all content from stdin
    const stdin = std.fs.File.stdin();
    const content = stdin.readToEndAlloc(allocator, MAX_PIPE_SIZE) catch {
        std.debug.print("zj: failed to read from stdin\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(content);

    if (content.len == 0) {
        std.debug.print("zj: no input received from pipe\n", .{});
        std.process.exit(1);
    }

    // Split content into lines
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        // Skip empty lines
        if (line.len == 0) continue;
        lines.append(allocator, line) catch {
            std.debug.print("zj: memory allocation failed\n", .{});
            std.process.exit(1);
        };
    }

    if (lines.items.len == 0) {
        std.debug.print("zj: no input received from pipe\n", .{});
        std.process.exit(1);
    }

    // Convert lines to ScoredEntry (with frecency_score = 0)
    var scored_entries = std.ArrayListUnmanaged(scoring.ScoredEntry){};
    defer scored_entries.deinit(allocator);

    for (lines.items) |line| {
        var fuzzy_score: i32 = 0;
        if (query) |q| {
            if (fuzzy.fuzzyMatch(q, line)) |score| {
                fuzzy_score = score;
            } else {
                continue; // Skip non-matching lines
            }
        }

        scored_entries.append(allocator, .{
            .path = line,
            .frecency_score = 0,
            .fuzzy_score = fuzzy_score,
            .total_score = scoring.calculateTotalScore(0, fuzzy_score),
            .visit_count = 0,
            .last_visit = 0,
        }) catch {
            std.debug.print("zj: memory allocation failed\n", .{});
            std.process.exit(1);
        };
    }

    if (scored_entries.items.len == 0) {
        std.debug.print("zj: no matching entries found\n", .{});
        std.process.exit(1);
    }

    // Sort by score and try auto-select if query was provided
    if (query != null) {
        std.mem.sort(scoring.ScoredEntry, scored_entries.items, {}, scoring.compareScores);

        // Try auto-select for single match or significantly better top match
        if (tryAutoSelect(scored_entries.items)) |path| {
            outputPath(path) catch {
                std.process.exit(1);
            };
            return;
        }
    }

    // Open /dev/tty for keyboard input (only needed for interactive selection)
    const tty_fd = terminal.openTty() catch {
        std.debug.print("zj: failed to open /dev/tty (not running in a terminal?)\n", .{});
        std.process.exit(1);
    };

    // Run TUI with /dev/tty for input
    const maybe_selected = tui.selectDirectoryWithTty(allocator, scored_entries.items, null, tty_fd) catch {
        std.debug.print("zj: selection error\n", .{});
        std.process.exit(1);
    };

    if (maybe_selected) |selected| {
        outputPath(selected) catch {
            std.process.exit(1);
        };
    } else {
        std.debug.print("zj: selection cancelled\n", .{});
        std.process.exit(1);
    }
}

/// Output selected path to stdout
fn outputPath(path: []const u8) !void {
    const stdout = std.fs.File.stdout();

    // Validate path has no dangerous characters
    for (path) |c| {
        if (c == 0 or c == '\n' or c == '\r') {
            std.debug.print("zj: invalid path\n", .{});
            std.process.exit(1);
        }
    }

    _ = try stdout.write(path);
    _ = try stdout.write("\n");
}

fn printHelp() !void {
    const help =
        \\zj - Fuzzy directory jump
        \\
        \\USAGE:
        \\    zj [OPTIONS] [QUERY]
        \\    zj init <SHELL>
        \\    <command> | zj [QUERY]
        \\
        \\ARGUMENTS:
        \\    [QUERY]    Fuzzy search pattern for directory name
        \\
        \\COMMANDS:
        \\    init <SHELL>         Print shell integration script (bash, zsh, fish)
        \\    import <SOURCE>      Import history from shell history file
        \\                         Sources: --zsh-history, --bash-history
        \\    self-update          Update zj to the latest version
        \\
        \\OPTIONS:
        \\    -h, --help           Show this help message
        \\    -v, --version        Show version
        \\    -q, --query [PREFIX] List completions matching PREFIX (for shell integration)
        \\    --debug-history      Show parsed history entries
        \\
        \\PIPE INPUT:
        \\    zj can read paths from stdin when piped:
        \\        ghq list -p | zj          # Select from ghq-managed repositories
        \\        fd -t d | zj              # Select from fd results
        \\        ghq list -p | zj proj     # Filter with query
        \\
        \\INTERACTIVE KEYS:
        \\    Up/Down, Ctrl-P/N    Navigate entries
        \\    Enter                Select directory
        \\    Esc, Ctrl-C          Cancel
        \\    Backspace            Delete character
        \\    Ctrl-U               Clear input
        \\    Ctrl-W               Delete word
        \\
        \\SHELL INTEGRATION:
        \\    Zsh (~/.zshrc):
        \\        eval "$(zj init zsh)"
        \\
        \\    Bash (~/.bashrc):
        \\        eval "$(zj init bash)"
        \\
        \\    Fish (~/.config/fish/config.fish):
        \\        zj init fish | source
        \\
        \\    To enable cd override (fallback to zj when cd fails):
        \\        export ZJ_CD_OVERRIDE=1  # or: set -gx ZJ_CD_OVERRIDE 1 (fish)
        \\
    ;
    std.debug.print("{s}\n", .{help});
}

fn printVersion() !void {
    std.debug.print("zj version {s}\n", .{VERSION});
}

fn printInit(shell: ShellType) !void {
    const stdout = std.fs.File.stdout();
    const script = switch (shell) {
        .bash => @embedFile("shell/zj.bash"),
        .zsh => @embedFile("shell/zj.zsh"),
        .fish => @embedFile("shell/zj.fish"),
    };
    _ = try stdout.write(script);
}

fn runImport(allocator: std.mem.Allocator, source: import_history.ImportSource) !void {
    const data_file_path = try history.getDataFilePath(allocator);
    defer allocator.free(data_file_path);

    const source_name = switch (source) {
        .zsh_history => "zsh history",
        .bash_history => "bash history",
    };

    std.debug.print("Importing from {s}...\n", .{source_name});

    const result = import_history.importFromShellHistory(allocator, source, data_file_path) catch |err| {
        if (err == error.FileNotFound) {
            std.process.exit(1);
        }
        std.debug.print("zj: import failed: {}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("Done! Imported {d} directories", .{result.imported_count});
    if (result.skipped_count > 0) {
        std.debug.print(" (skipped {d} relative/invalid paths)", .{result.skipped_count});
    }
    if (result.already_exists_count > 0) {
        std.debug.print(" ({d} already in history)", .{result.already_exists_count});
    }
    std.debug.print(".\n", .{});
}

fn debugHistory(entries: []const history.HistoryEntry) !void {
    std.debug.print("Parsed {d} history entries:\n\n", .{entries.len});

    for (entries[0..@min(entries.len, 50)]) |entry| {
        std.debug.print("  {s}\n", .{entry.path});
        std.debug.print("    visits: {d}, timestamp: {d}\n\n", .{ entry.visit_count, entry.timestamp });
    }

    if (entries.len > 50) {
        std.debug.print("  ... and {d} more\n", .{entries.len - 50});
    }
}

/// Run interactive query mode with inline TUI (for shell completion widget)
fn runQueryMode(
    allocator: std.mem.Allocator,
    entries: []const history.HistoryEntry,
    initial_query: ?[]const u8,
) !void {
    // Load all entries with frecency scores
    var scored_entries = try loadAndScoreEntries(allocator, entries, null);
    defer scored_entries.deinit(allocator);

    if (scored_entries.items.len == 0) {
        std.process.exit(1);
    }

    // Run inline TUI with initial query
    const maybe_selected = tui.selectDirectoryInline(allocator, scored_entries.items, initial_query) catch {
        std.process.exit(1);
    };

    if (maybe_selected) |selected| {
        try outputPath(selected);
    } else {
        std.process.exit(1);
    }
}

test {
    _ = @import("terminal.zig");
    _ = @import("history.zig");
    _ = @import("scoring.zig");
    _ = @import("fuzzy.zig");
    _ = @import("tui.zig");
    _ = @import("import.zig");
    _ = @import("self_update.zig");
}
