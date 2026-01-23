const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const MAX_FILE_SIZE = 50 * 1024 * 1024; // 50 MB max for shell history

pub const ImportSource = enum {
    zsh_history,
    bash_history,
};

pub const ImportResult = struct {
    imported_count: usize,
    skipped_count: usize,
    already_exists_count: usize,
};

/// Import directory history from shell history file
pub fn importFromShellHistory(
    allocator: Allocator,
    source: ImportSource,
    data_file_path: []const u8,
) !ImportResult {
    const history_path = try getShellHistoryPath(allocator, source);
    defer allocator.free(history_path);

    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;

    // Read existing entries to avoid duplicates
    var existing_paths = std.StringHashMap(void).init(allocator);
    defer {
        var it = existing_paths.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        existing_paths.deinit();
    }

    if (fs.openFileAbsolute(data_file_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, MAX_FILE_SIZE);
        defer allocator.free(content);

        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Format: timestamp:path
            const colon_idx = mem.indexOf(u8, line, ":") orelse continue;
            if (colon_idx >= line.len - 1) continue;
            const path = line[colon_idx + 1 ..];
            // Duplicate the path to ensure it outlives the content buffer
            const owned_path = try allocator.dupe(u8, path);
            try existing_paths.put(owned_path, {});
        }
    } else |_| {
        // File doesn't exist yet, that's fine
    }

    // Read shell history
    const history_file = fs.openFileAbsolute(history_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("zj: history file not found: {s}\n", .{history_path});
            return error.FileNotFound;
        }
        return err;
    };
    defer history_file.close();

    const history_content = try history_file.readToEndAlloc(allocator, MAX_FILE_SIZE);
    defer allocator.free(history_content);

    // Extract cd commands and collect unique paths
    var paths_to_import = std.StringHashMap(void).init(allocator);
    defer {
        var it = paths_to_import.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        paths_to_import.deinit();
    }

    var result = ImportResult{
        .imported_count = 0,
        .skipped_count = 0,
        .already_exists_count = 0,
    };

    var lines = mem.splitScalar(u8, history_content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const command = extractCommand(line, source);
        if (command.len == 0) continue;

        const path = extractCdPath(command) orelse {
            continue;
        };

        // Skip relative paths
        if (!isAbsoluteOrTildePath(path)) {
            result.skipped_count += 1;
            continue;
        }

        // Expand ~ to home directory
        const expanded = expandTilde(allocator, path, home) catch {
            result.skipped_count += 1;
            continue;
        };
        defer allocator.free(expanded);

        // Normalize path to resolve .. and . components
        const normalized = normalizePath(allocator, expanded) catch {
            result.skipped_count += 1;
            continue;
        };
        defer allocator.free(normalized);

        // Skip if already in existing data
        if (existing_paths.contains(normalized)) {
            result.already_exists_count += 1;
            continue;
        }

        // Skip if already collected
        if (paths_to_import.contains(normalized)) {
            continue;
        }

        // Verify directory exists
        if (!directoryExists(normalized)) {
            result.skipped_count += 1;
            continue;
        }

        // Add to import list
        const owned_path = try allocator.dupe(u8, normalized);
        try paths_to_import.put(owned_path, {});
    }

    // Write to data file
    if (paths_to_import.count() > 0) {
        try appendToDataFile(allocator, paths_to_import, data_file_path);
        result.imported_count = paths_to_import.count();
    }

    return result;
}

/// Get the path to shell history file
fn getShellHistoryPath(allocator: Allocator, source: ImportSource) ![]const u8 {
    // Check HISTFILE environment variable first (common to both shells)
    if (std.posix.getenv("HISTFILE")) |histfile| {
        return try allocator.dupe(u8, histfile);
    }

    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const filename = switch (source) {
        .zsh_history => ".zsh_history",
        .bash_history => ".bash_history",
    };
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, filename });
}

/// Extract command from history line (handles zsh extended history format)
fn extractCommand(line: []const u8, source: ImportSource) []const u8 {
    switch (source) {
        .zsh_history => {
            // zsh extended history format: ": timestamp:0;command"
            if (line.len > 2 and line[0] == ':' and line[1] == ' ') {
                if (mem.indexOf(u8, line, ";")) |semicolon_idx| {
                    if (semicolon_idx + 1 < line.len) {
                        return line[semicolon_idx + 1 ..];
                    }
                }
                return "";
            }
            // Regular format: just the command
            return line;
        },
        .bash_history => {
            // bash history is just the command
            return line;
        },
    }
}

/// Extract path from cd command, returns null if not a valid cd command
fn extractCdPath(command: []const u8) ?[]const u8 {
    const trimmed = mem.trim(u8, command, " \t");

    // Must start with "cd "
    if (!mem.startsWith(u8, trimmed, "cd ")) {
        return null;
    }

    // Skip "cd "
    var rest = mem.trim(u8, trimmed[3..], " \t");

    // Skip options like -P, -L
    while (rest.len > 0 and rest[0] == '-') {
        // Find end of option
        const space_idx = mem.indexOf(u8, rest, " ") orelse return null;
        rest = mem.trim(u8, rest[space_idx..], " \t");
    }

    if (rest.len == 0) {
        return null; // cd with no path (goes to HOME)
    }

    // Security: skip commands with shell expansion
    if (mem.indexOf(u8, rest, "$(") != null or
        mem.indexOf(u8, rest, "`") != null)
    {
        return null;
    }

    // Handle quoted paths (with escape handling)
    var path = rest;
    var was_quoted = false;
    if ((path[0] == '"' or path[0] == '\'') and path.len > 1) {
        const quote = path[0];
        // Find closing quote, skipping escaped quotes
        var i: usize = 1;
        var found_close = false;
        while (i < path.len) : (i += 1) {
            if (path[i] == '\\' and i + 1 < path.len) {
                // Skip escaped character
                i += 1;
                continue;
            }
            if (path[i] == quote) {
                path = path[1..i];
                found_close = true;
                was_quoted = true;
                break;
            }
        }
        if (!found_close) {
            // Unclosed quote - skip this path as it's malformed
            return null;
        }
    }

    // For unquoted paths, remove trailing comments and command separators
    if (!was_quoted) {
        if (mem.indexOf(u8, path, " #")) |idx| {
            path = path[0..idx];
        }
        if (mem.indexOf(u8, path, " &&")) |idx| {
            path = path[0..idx];
        }
        if (mem.indexOf(u8, path, " ||")) |idx| {
            path = path[0..idx];
        }
        if (mem.indexOf(u8, path, " ;")) |idx| {
            path = path[0..idx];
        }
        if (mem.indexOf(u8, path, " |")) |idx| {
            path = path[0..idx];
        }
    }

    path = mem.trim(u8, path, " \t");

    if (path.len == 0 or mem.eql(u8, path, "-")) {
        return null;
    }

    return path;
}

/// Check if path is absolute or starts with ~
fn isAbsoluteOrTildePath(path: []const u8) bool {
    if (path.len == 0) return false;
    return path[0] == '/' or path[0] == '~';
}

/// Expand ~ to home directory
fn expandTilde(allocator: Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (path.len == 0 or path[0] != '~') {
        return try allocator.dupe(u8, path);
    }

    // Just ~ or ~/...
    if (path.len == 1 or path[1] == '/') {
        const rest = if (path.len > 1) path[1..] else "";
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, rest });
    }

    // ~user/... format - not supported for now, skip
    return error.UnsupportedTildeFormat;
}

/// Normalize path by resolving . and .. components
fn normalizePath(allocator: Allocator, path: []const u8) ![]const u8 {
    // Use realpath-like resolution by splitting and processing components
    var components: std.ArrayListUnmanaged([]const u8) = .empty;
    defer components.deinit(allocator);

    var it = mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0 or mem.eql(u8, component, ".")) {
            // Skip empty components and current directory references
            continue;
        } else if (mem.eql(u8, component, "..")) {
            // Go up one directory if possible
            if (components.items.len > 0) {
                _ = components.pop();
            }
            // If at root, just ignore the ..
        } else {
            try components.append(allocator, component);
        }
    }

    // Reconstruct path
    if (components.items.len == 0) {
        return try allocator.dupe(u8, "/");
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    for (components.items) |component| {
        try result.append(allocator, '/');
        try result.appendSlice(allocator, component);
    }

    return try result.toOwnedSlice(allocator);
}

/// Check if a directory exists
fn directoryExists(path: []const u8) bool {
    var dir = fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Append paths to data file
fn appendToDataFile(
    allocator: Allocator,
    paths: std.StringHashMap(void),
    data_file_path: []const u8,
) !void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(data_file_path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    const file = try fs.createFileAbsolute(data_file_path, .{ .truncate = false });
    defer file.close();

    // Seek to end
    try file.seekFromEnd(0);

    const now = std.time.timestamp();
    var it = paths.keyIterator();
    while (it.next()) |key| {
        const line = try std.fmt.allocPrint(allocator, "{d}:{s}\n", .{ now, key.* });
        defer allocator.free(line);
        _ = try file.write(line);
    }
}

// Tests
test "extractCommand zsh extended format" {
    const result = extractCommand(": 1700000000:0;cd ~/projects", .zsh_history);
    try std.testing.expectEqualStrings("cd ~/projects", result);
}

test "extractCommand zsh regular format" {
    const result = extractCommand("cd ~/projects", .zsh_history);
    try std.testing.expectEqualStrings("cd ~/projects", result);
}

test "extractCommand bash format" {
    const result = extractCommand("cd ~/projects", .bash_history);
    try std.testing.expectEqualStrings("cd ~/projects", result);
}

test "extractCdPath basic" {
    const result = extractCdPath("cd ~/projects");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("~/projects", result.?);
}

test "extractCdPath absolute" {
    const result = extractCdPath("cd /home/user/projects");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/home/user/projects", result.?);
}

test "extractCdPath with options" {
    const result = extractCdPath("cd -P ~/projects");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("~/projects", result.?);
}

test "extractCdPath relative should work but filter later" {
    const result = extractCdPath("cd foo");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("foo", result.?);
}

test "extractCdPath cd alone" {
    const result = extractCdPath("cd");
    try std.testing.expect(result == null);
}

test "extractCdPath cd -" {
    const result = extractCdPath("cd -");
    try std.testing.expect(result == null);
}

test "extractCdPath with shell expansion should be skipped" {
    const result = extractCdPath("cd $(pwd)");
    try std.testing.expect(result == null);
}

test "extractCdPath with backtick expansion should be skipped" {
    const result = extractCdPath("cd `pwd`");
    try std.testing.expect(result == null);
}

test "isAbsoluteOrTildePath" {
    try std.testing.expect(isAbsoluteOrTildePath("/home/user"));
    try std.testing.expect(isAbsoluteOrTildePath("~/projects"));
    try std.testing.expect(!isAbsoluteOrTildePath("foo"));
    try std.testing.expect(!isAbsoluteOrTildePath("../bar"));
    try std.testing.expect(!isAbsoluteOrTildePath(""));
}

test "expandTilde home" {
    const allocator = std.testing.allocator;

    const result = try expandTilde(allocator, "~/projects", "/home/user");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/projects", result);
}

test "expandTilde just tilde" {
    const allocator = std.testing.allocator;

    const result = try expandTilde(allocator, "~", "/home/user");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user", result);
}

test "expandTilde absolute path unchanged" {
    const allocator = std.testing.allocator;

    const result = try expandTilde(allocator, "/home/user/projects", "/home/other");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/projects", result);
}

test "normalizePath removes dot components" {
    const allocator = std.testing.allocator;

    const result = try normalizePath(allocator, "/home/user/./projects");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/projects", result);
}

test "normalizePath resolves dotdot components" {
    const allocator = std.testing.allocator;

    const result = try normalizePath(allocator, "/home/user/../other/projects");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/other/projects", result);
}

test "normalizePath handles traversal beyond root" {
    const allocator = std.testing.allocator;

    const result = try normalizePath(allocator, "/home/../../etc");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/etc", result);
}

test "normalizePath root only" {
    const allocator = std.testing.allocator;

    const result = try normalizePath(allocator, "/");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/", result);
}

test "extractCdPath with double quotes" {
    const result = extractCdPath("cd \"/path/with spaces\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/path/with spaces", result.?);
}

test "extractCdPath with single quotes" {
    const result = extractCdPath("cd '/path/with spaces'");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/path/with spaces", result.?);
}

test "extractCdPath with unclosed quote returns null" {
    const result = extractCdPath("cd \"/path/unclosed");
    try std.testing.expect(result == null);
}

test "extractCdPath with escaped quote" {
    const result = extractCdPath("cd \"/path/with\\\"quote\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/path/with\\\"quote", result.?);
}
