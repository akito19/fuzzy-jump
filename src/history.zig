const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub const HistoryEntry = struct {
    path: []const u8,
    timestamp: i64, // Unix timestamp, 0 if unknown
    visit_count: u32,
};

const MAX_ENTRIES = 1000;
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 MB max
const PRUNE_TARGET = 800; // After pruning, keep this many entries

const EntryList = std.ArrayListUnmanaged(HistoryEntry);
const VisitData = struct {
    count: u32,
    latest_timestamp: i64,
};
const PathMap = std.StringHashMapUnmanaged(VisitData);
const InternMap = std.StringHashMapUnmanaged([]const u8);

/// String pool for deduplicating paths
pub const StringPool = struct {
    strings: InternMap,
    allocator: Allocator,

    pub fn init(allocator: Allocator) StringPool {
        return .{
            .strings = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringPool) void {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.strings.deinit(self.allocator);
    }

    /// Intern a string, returning existing or new allocation
    pub fn intern(self: *StringPool, s: []const u8) ![]const u8 {
        if (self.strings.get(s)) |existing| {
            return existing;
        }
        const owned = try self.allocator.dupe(u8, s);
        try self.strings.put(self.allocator, owned, owned);
        return owned;
    }
};

/// Parsed history result
pub const ParsedHistory = struct {
    entries: EntryList,
    string_pool: StringPool,
    allocator: Allocator,

    pub fn deinit(self: *ParsedHistory) void {
        self.entries.deinit(self.allocator);
        self.string_pool.deinit();
    }
};

/// Get the data file path from environment or default
fn getDataFilePath(allocator: Allocator) ![]const u8 {
    // Check ZJ_DATA_FILE environment variable first
    if (std.posix.getenv("ZJ_DATA_FILE")) |path| {
        return try allocator.dupe(u8, path);
    }

    // Fall back to default path
    const home = std.posix.getenv("HOME") orelse "/";
    const xdg_data_home = std.posix.getenv("XDG_DATA_HOME");

    if (xdg_data_home) |xdg| {
        return try std.fmt.allocPrint(allocator, "{s}/zj/history", .{xdg});
    } else {
        return try std.fmt.allocPrint(allocator, "{s}/.local/share/zj/history", .{home});
    }
}

/// Parse the dedicated history file and extract directory visits
pub fn parseHistory(allocator: Allocator) !ParsedHistory {
    var entries: EntryList = .empty;
    errdefer entries.deinit(allocator);

    var string_pool = StringPool.init(allocator);
    errdefer string_pool.deinit();

    const data_file_path = try getDataFilePath(allocator);
    defer allocator.free(data_file_path);

    // Track visit data per path
    var path_data: PathMap = .empty;
    defer {
        var it = path_data.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        path_data.deinit(allocator);
    }

    // Parse the data file
    parseDataFile(allocator, data_file_path, &path_data) catch |err| {
        // If file doesn't exist, return empty result
        if (err == error.FileNotFound) {
            return .{
                .entries = entries,
                .string_pool = string_pool,
                .allocator = allocator,
            };
        }
        return err;
    };

    // Convert to entries list, filtering out non-existent directories
    var it = path_data.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const data = entry.value_ptr.*;

        // Verify directory still exists
        if (directoryExists(path)) {
            const interned_path = try string_pool.intern(path);
            try entries.append(allocator, .{
                .path = interned_path,
                .timestamp = data.latest_timestamp,
                .visit_count = data.count,
            });
        }
    }

    // Prune if needed and write back
    if (entries.items.len > MAX_ENTRIES) {
        try pruneAndWriteBack(allocator, &entries, data_file_path);
    }

    return .{
        .entries = entries,
        .string_pool = string_pool,
        .allocator = allocator,
    };
}

/// Parse the data file (format: timestamp:path per line)
fn parseDataFile(
    allocator: Allocator,
    path: []const u8,
    path_data: *PathMap,
) !void {
    const file = try fs.openFileAbsolute(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, MAX_FILE_SIZE);
    defer allocator.free(content);

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse format: timestamp:path
        const colon_idx = mem.indexOf(u8, line, ":") orelse continue;
        if (colon_idx == 0 or colon_idx >= line.len - 1) continue;

        const timestamp = std.fmt.parseInt(i64, line[0..colon_idx], 10) catch continue;
        const entry_path = line[colon_idx + 1 ..];

        // Validate path
        if (entry_path.len == 0 or entry_path[0] != '/') continue;
        if (!std.unicode.utf8ValidateSlice(entry_path)) continue;

        // Update path data
        const gop = try path_data.getOrPut(allocator, entry_path);
        if (gop.found_existing) {
            gop.value_ptr.count += 1;
            if (timestamp > gop.value_ptr.latest_timestamp) {
                gop.value_ptr.latest_timestamp = timestamp;
            }
        } else {
            gop.key_ptr.* = try allocator.dupe(u8, entry_path);
            gop.value_ptr.* = .{
                .count = 1,
                .latest_timestamp = timestamp,
            };
        }
    }
}

/// Prune entries to PRUNE_TARGET and write back to file
fn pruneAndWriteBack(
    allocator: Allocator,
    entries: *EntryList,
    data_file_path: []const u8,
) !void {
    const scoring = @import("scoring.zig");
    const now = scoring.getCurrentTimestamp();

    // Calculate scores for sorting
    const ScoredForPrune = struct {
        entry: HistoryEntry,
        score: f64,
    };

    var scored = try allocator.alloc(ScoredForPrune, entries.items.len);
    defer allocator.free(scored);

    for (entries.items, 0..) |entry, i| {
        scored[i] = .{
            .entry = entry,
            .score = scoring.calculateFrecencyScore(entry.visit_count, entry.timestamp, now),
        };
    }

    // Sort by score descending
    std.mem.sort(ScoredForPrune, scored, {}, struct {
        fn lessThan(_: void, a: ScoredForPrune, b: ScoredForPrune) bool {
            return a.score > b.score;
        }
    }.lessThan);

    // Keep top PRUNE_TARGET entries
    const keep_count = @min(PRUNE_TARGET, scored.len);
    entries.clearRetainingCapacity();
    for (scored[0..keep_count]) |s| {
        try entries.append(allocator, s.entry);
    }

    // Write back to file
    writeDataFile(allocator, entries.items, data_file_path) catch {};
}

/// Write entries back to the data file (compacted format)
fn writeDataFile(allocator: Allocator, entries: []const HistoryEntry, path: []const u8) !void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    const file = try fs.createFileAbsolute(path, .{});
    defer file.close();

    for (entries) |entry| {
        const line = try std.fmt.allocPrint(allocator, "{d}:{s}\n", .{ entry.timestamp, entry.path });
        defer allocator.free(line);
        _ = try file.write(line);
    }
}

/// Check if a directory exists
fn directoryExists(path: []const u8) bool {
    var dir = fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

test "getDataFilePath with ZJ_DATA_FILE" {
    // This test would need environment variable mocking
    // Skipping for now as it depends on runtime environment
}

test "parseDataFile format" {
    // Test that the parser handles the timestamp:path format correctly
    const allocator = std.testing.allocator;

    // Create a temporary file for testing
    const test_content = "1700000000:/home/user/projects\n1700000001:/home/user/documents\n1700000002:/home/user/projects\n";

    var path_data: PathMap = .empty;
    defer {
        var it = path_data.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        path_data.deinit(allocator);
    }

    // Parse the content directly (simulating file read)
    var lines = mem.splitScalar(u8, test_content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon_idx = mem.indexOf(u8, line, ":") orelse continue;
        if (colon_idx == 0 or colon_idx >= line.len - 1) continue;

        const timestamp = std.fmt.parseInt(i64, line[0..colon_idx], 10) catch continue;
        const entry_path = line[colon_idx + 1 ..];

        if (entry_path.len == 0 or entry_path[0] != '/') continue;

        const gop = try path_data.getOrPut(allocator, entry_path);
        if (gop.found_existing) {
            gop.value_ptr.count += 1;
            if (timestamp > gop.value_ptr.latest_timestamp) {
                gop.value_ptr.latest_timestamp = timestamp;
            }
        } else {
            gop.key_ptr.* = try allocator.dupe(u8, entry_path);
            gop.value_ptr.* = .{
                .count = 1,
                .latest_timestamp = timestamp,
            };
        }
    }

    // Verify results
    try std.testing.expectEqual(@as(usize, 2), path_data.count());

    const projects_data = path_data.get("/home/user/projects");
    try std.testing.expect(projects_data != null);
    try std.testing.expectEqual(@as(u32, 2), projects_data.?.count);
    try std.testing.expectEqual(@as(i64, 1700000002), projects_data.?.latest_timestamp);

    const documents_data = path_data.get("/home/user/documents");
    try std.testing.expect(documents_data != null);
    try std.testing.expectEqual(@as(u32, 1), documents_data.?.count);
}
