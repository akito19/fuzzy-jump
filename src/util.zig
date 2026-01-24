const std = @import("std");
const fs = std.fs;

/// Check if a directory exists
pub fn directoryExists(path: []const u8) bool {
    var dir = fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Ensure parent directory exists, creating it if necessary
pub fn ensureParentDirExists(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
}

/// Print error message with "zj: " prefix and exit with code 1
pub fn exitWithError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zj: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

test "directoryExists returns true for existing directory" {
    // Root directory should always exist
    try std.testing.expect(directoryExists("/"));
}

test "directoryExists returns false for non-existing directory" {
    try std.testing.expect(!directoryExists("/nonexistent_dir_12345_zj_test"));
}

test "directoryExists returns false for file path" {
    // /etc/passwd is a file, not a directory
    try std.testing.expect(!directoryExists("/etc/passwd"));
}

test "ensureParentDirExists succeeds for existing parent" {
    // /tmp always exists, so this should succeed without creating anything
    try ensureParentDirExists("/tmp/test_file");
}

test "ensureParentDirExists succeeds for path without parent" {
    // Root-level path has no parent to create
    try ensureParentDirExists("/test_file");
}
