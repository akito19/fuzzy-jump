const std = @import("std");
const Io = std.Io;

/// Check if a directory exists
pub fn directoryExists(io: Io, path: []const u8) bool {
    var dir = Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Ensure parent directory exists, creating it if necessary
pub fn ensureParentDirExists(io: Io, path: []const u8) !void {
    if (Io.Dir.path.dirname(path)) |dir| {
        Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
}

/// Print error message with "fj: " prefix and exit with code 1
pub fn exitWithError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fj: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Get an environment variable via libc getenv(3).
/// Returns null if the variable is unset.
pub fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

test "directoryExists returns true for existing directory" {
    // Root directory should always exist
    try std.testing.expect(directoryExists(std.testing.io, "/"));
}

test "directoryExists returns false for non-existing directory" {
    try std.testing.expect(!directoryExists(std.testing.io, "/nonexistent_dir_12345_fj_test"));
}

test "directoryExists returns false for file path" {
    // /etc/passwd is a file, not a directory
    try std.testing.expect(!directoryExists(std.testing.io, "/etc/passwd"));
}

test "ensureParentDirExists succeeds for existing parent" {
    // /tmp always exists, so this should succeed without creating anything
    try ensureParentDirExists(std.testing.io, "/tmp/test_file");
}

test "ensureParentDirExists succeeds for path without parent" {
    // Root-level path has no parent to create
    try ensureParentDirExists(std.testing.io, "/test_file");
}
