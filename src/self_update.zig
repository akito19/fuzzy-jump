const std = @import("std");
const builtin = @import("builtin");
const http = std.http;

pub const VERSION = "0.2.1";

const GITHUB_REPO = "akito19/z-jump";

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,

    pub fn assetName(self: Platform, allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "zj-{s}-{s}-{s}.tar.gz", .{ version, self.os, self.arch });
    }
};

pub const UpdateCheckResult = struct {
    current_version: []const u8,
    latest_version: []const u8,
    is_up_to_date: bool,
    download_url: ?[]const u8,
};

pub const SelfUpdateError = error{
    UnsupportedPlatform,
    NetworkError,
    RateLimitExceeded,
    ReleaseNotFound,
    InvalidResponse,
    DownloadFailed,
    ExtractionFailed,
    PermissionDenied,
    SelfExePathNotFound,
    ChecksumMismatch,
    ChecksumFileNotFound,
};

/// Detect the current platform
pub fn detectPlatform() SelfUpdateError!Platform {
    const os: []const u8 = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => return SelfUpdateError.UnsupportedPlatform,
    };

    const arch: []const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => return SelfUpdateError.UnsupportedPlatform,
    };

    return Platform{ .os = os, .arch = arch };
}

/// Semantic version for comparison
pub const SemanticVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(version_str: []const u8) ?SemanticVersion {
        // Remove leading 'v' if present
        const str = if (version_str.len > 0 and version_str[0] == 'v')
            version_str[1..]
        else
            version_str;

        var iter = std.mem.splitScalar(u8, str, '.');
        const major_str = iter.next() orelse return null;
        const minor_str = iter.next() orelse return null;
        const patch_str = iter.next() orelse return null;

        const major = std.fmt.parseInt(u32, major_str, 10) catch return null;
        const minor = std.fmt.parseInt(u32, minor_str, 10) catch return null;
        const patch = std.fmt.parseInt(u32, patch_str, 10) catch return null;

        return SemanticVersion{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn compare(self: SemanticVersion, other: SemanticVersion) std.math.Order {
        if (self.major != other.major) {
            return std.math.order(self.major, other.major);
        }
        if (self.minor != other.minor) {
            return std.math.order(self.minor, other.minor);
        }
        return std.math.order(self.patch, other.patch);
    }

    pub fn isOlderThan(self: SemanticVersion, other: SemanticVersion) bool {
        return self.compare(other) == .lt;
    }
};

/// HTTP fetch helper to reduce code duplication
fn httpFetch(allocator: std.mem.Allocator, url: []const u8, extra_headers: []const http.Header) !struct { status: http.Status, body: []const u8 } {
    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
        .extra_headers = extra_headers,
    }) catch {
        return SelfUpdateError.NetworkError;
    };

    // Duplicate the written data and free the writer
    const body = try allocator.dupe(u8, aw.written());
    aw.deinit();
    return .{ .status = result.status, .body = body };
}

/// Check for updates by querying GitHub API
pub fn checkForUpdate(allocator: std.mem.Allocator) !UpdateCheckResult {
    const headers: []const http.Header = &.{
        .{ .name = "User-Agent", .value = "zj-self-update/" ++ VERSION },
        .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
    };

    const response = try httpFetch(allocator, "https://api.github.com/repos/" ++ GITHUB_REPO ++ "/releases/latest", headers);
    defer allocator.free(response.body);

    if (response.status == .forbidden) {
        return SelfUpdateError.RateLimitExceeded;
    }

    if (response.status == .not_found) {
        return SelfUpdateError.ReleaseNotFound;
    }

    if (response.status != .ok) {
        return SelfUpdateError.InvalidResponse;
    }

    // Parse JSON to extract tag_name
    const latest_version = extractTagName(allocator, response.body) catch {
        return SelfUpdateError.InvalidResponse;
    };

    const current_semver = SemanticVersion.parse(VERSION) orelse return SelfUpdateError.InvalidResponse;
    const latest_semver = SemanticVersion.parse(latest_version) orelse return SelfUpdateError.InvalidResponse;

    const is_up_to_date = !current_semver.isOlderThan(latest_semver);

    var download_url: ?[]const u8 = null;
    if (!is_up_to_date) {
        const platform = try detectPlatform();
        const version_without_v = if (latest_version.len > 0 and latest_version[0] == 'v')
            latest_version[1..]
        else
            latest_version;
        const asset_name = try platform.assetName(allocator, version_without_v);
        defer allocator.free(asset_name);

        download_url = try std.fmt.allocPrint(
            allocator,
            "https://github.com/{s}/releases/download/{s}/{s}",
            .{ GITHUB_REPO, latest_version, asset_name },
        );
    }

    return UpdateCheckResult{
        .current_version = VERSION,
        .latest_version = latest_version,
        .is_up_to_date = is_up_to_date,
        .download_url = download_url,
    };
}

/// Extract tag_name from GitHub API JSON response
fn extractTagName(allocator: std.mem.Allocator, json_body: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch {
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const tag_name_value = root.object.get("tag_name") orelse return error.InvalidResponse;
    if (tag_name_value != .string) return error.InvalidResponse;

    return allocator.dupe(u8, tag_name_value.string) catch return error.InvalidResponse;
}

/// Generate a random temporary directory path
fn generateTempDirPath(allocator: std.mem.Allocator) ![]const u8 {
    const base_tmp = std.posix.getenv("TMPDIR") orelse "/tmp";

    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    return std.fmt.allocPrint(allocator, "{s}/zj-update-{x}", .{ base_tmp, random_bytes });
}

/// Download SHA256SUMS file from GitHub release
fn downloadChecksums(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/releases/download/{s}/SHA256SUMS",
        .{ GITHUB_REPO, version },
    );
    defer allocator.free(url);

    const headers: []const http.Header = &.{
        .{ .name = "User-Agent", .value = "zj-self-update/" ++ VERSION },
    };

    const response = try httpFetch(allocator, url, headers);
    errdefer allocator.free(response.body);

    if (response.status == .not_found) {
        allocator.free(response.body);
        return SelfUpdateError.ChecksumFileNotFound;
    }

    if (response.status != .ok) {
        allocator.free(response.body);
        return SelfUpdateError.DownloadFailed;
    }

    return response.body;
}

/// Verify SHA256 checksum of data against expected hash
fn verifyChecksum(data: []const u8, expected_hash: []const u8) bool {
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});

    var hex_buf: [64]u8 = undefined;
    const hex_hash = std.fmt.bufPrint(&hex_buf, "{x}", .{hash}) catch return false;

    return std.mem.eql(u8, hex_hash, expected_hash);
}

/// Parse SHA256SUMS file and find the hash for the given filename
fn findChecksumForFile(checksums_content: []const u8, filename: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, checksums_content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Format: "hash  filename" (two spaces between)
        if (std.mem.indexOf(u8, line, "  ")) |sep_idx| {
            const hash = line[0..sep_idx];
            const name = line[sep_idx + 2 ..];
            if (std.mem.eql(u8, name, filename)) {
                return hash;
            }
        }
    }
    return null;
}

/// Download and extract the update
fn downloadAndExtract(allocator: std.mem.Allocator, url: []const u8, version: []const u8, asset_name: []const u8) ![]const u8 {
    const headers: []const http.Header = &.{
        .{ .name = "User-Agent", .value = "zj-self-update/" ++ VERSION },
    };

    const response = try httpFetch(allocator, url, headers);
    defer allocator.free(response.body);

    if (response.status != .ok) {
        return SelfUpdateError.DownloadFailed;
    }

    // Download and verify checksum
    const checksums = downloadChecksums(allocator, version) catch |err| {
        if (err == SelfUpdateError.ChecksumFileNotFound) {
            std.debug.print("Warning: SHA256SUMS file not found, skipping checksum verification\n", .{});
        } else {
            return err;
        }
        return err;
    };
    defer allocator.free(checksums);

    const expected_hash = findChecksumForFile(checksums, asset_name) orelse {
        std.debug.print("Warning: Checksum for {s} not found in SHA256SUMS\n", .{asset_name});
        return SelfUpdateError.ChecksumMismatch;
    };

    if (!verifyChecksum(response.body, expected_hash)) {
        std.debug.print("Checksum verification failed!\n", .{});
        return SelfUpdateError.ChecksumMismatch;
    }

    // Create random temp directory
    const tmp_dir_path = try generateTempDirPath(allocator);
    errdefer allocator.free(tmp_dir_path);

    std.fs.deleteTreeAbsolute(tmp_dir_path) catch {};
    std.fs.makeDirAbsolute(tmp_dir_path) catch {
        return SelfUpdateError.PermissionDenied;
    };

    // Decompress gzip to a buffer first
    var gzip_reader: std.Io.Reader = .fixed(response.body);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&gzip_reader, .gzip, &decompress_buffer);

    var tar_data_writer: std.Io.Writer.Allocating = .init(allocator);
    defer tar_data_writer.deinit();

    _ = decompress.reader.streamRemaining(&tar_data_writer.writer) catch {
        return SelfUpdateError.ExtractionFailed;
    };

    // Extract tar
    var tar_reader: std.Io.Reader = .fixed(tar_data_writer.written());
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var tar_iter: std.tar.Iterator = .init(&tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    while (tar_iter.next() catch return SelfUpdateError.ExtractionFailed) |entry| {
        const file_name = entry.name;
        // Look for the 'zj' binary
        if (std.mem.endsWith(u8, file_name, "/zj") or std.mem.eql(u8, file_name, "zj")) {
            const binary_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "zj" });
            errdefer allocator.free(binary_path);

            const file = std.fs.createFileAbsolute(binary_path, .{}) catch {
                return SelfUpdateError.PermissionDenied;
            };
            defer file.close();

            // Write the binary content using tar iterator's streamRemaining
            var file_write_buf: [8192]u8 = undefined;
            var file_writer = file.writer(&file_write_buf);
            tar_iter.streamRemaining(entry, &file_writer.interface) catch {
                return SelfUpdateError.ExtractionFailed;
            };
            file_writer.interface.flush() catch {
                return SelfUpdateError.PermissionDenied;
            };

            // Store tmp_dir_path for later cleanup (returned via binary_path's directory)
            allocator.free(tmp_dir_path);
            return binary_path;
        }
    }

    allocator.free(tmp_dir_path);
    return SelfUpdateError.ExtractionFailed;
}

/// Create a backup of the current binary
fn createBackup(allocator: std.mem.Allocator, self_exe_path: []const u8) ![]const u8 {
    const dir_path = std.fs.path.dirname(self_exe_path) orelse return SelfUpdateError.SelfExePathNotFound;
    const backup_path = try std.fs.path.join(allocator, &.{ dir_path, "zj.backup" });
    errdefer allocator.free(backup_path);

    std.fs.copyFileAbsolute(self_exe_path, backup_path, .{}) catch {
        return SelfUpdateError.PermissionDenied;
    };

    return backup_path;
}

/// Restore from backup
fn restoreFromBackup(backup_path: []const u8, self_exe_path: []const u8) void {
    std.fs.renameAbsolute(backup_path, self_exe_path) catch {
        std.debug.print("Warning: Failed to restore from backup at {s}\n", .{backup_path});
    };
}

/// Atomically replace the current binary with the new one
fn atomicReplace(allocator: std.mem.Allocator, new_binary: []const u8) !void {
    // Get current executable path
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe_path = std.fs.selfExePath(&self_exe_buf) catch {
        return SelfUpdateError.SelfExePathNotFound;
    };

    // Create backup of current binary
    const backup_path = try createBackup(allocator, self_exe_path);
    defer allocator.free(backup_path);
    errdefer restoreFromBackup(backup_path, self_exe_path);

    // Create path for temporary new binary in same directory
    const dir_path = std.fs.path.dirname(self_exe_path) orelse return SelfUpdateError.SelfExePathNotFound;
    const new_path = try std.fs.path.join(allocator, &.{ dir_path, "zj.new" });
    defer allocator.free(new_path);

    // Copy new binary to same directory
    std.fs.copyFileAbsolute(new_binary, new_path, .{}) catch {
        return SelfUpdateError.PermissionDenied;
    };
    errdefer std.fs.deleteFileAbsolute(new_path) catch {};

    // Set executable permission
    const new_file = std.fs.openFileAbsolute(new_path, .{ .mode = .read_write }) catch {
        return SelfUpdateError.PermissionDenied;
    };
    new_file.chmod(0o755) catch {
        new_file.close();
        return SelfUpdateError.PermissionDenied;
    };
    new_file.close();

    // Atomic rename
    std.fs.renameAbsolute(new_path, self_exe_path) catch {
        return SelfUpdateError.PermissionDenied;
    };

    // Success - remove backup
    std.fs.deleteFileAbsolute(backup_path) catch {};
}

/// Print update error messages
fn printUpdateError(err: SelfUpdateError) void {
    switch (err) {
        SelfUpdateError.NetworkError => {
            std.debug.print("Could not connect to GitHub. Check your internet connection.\n", .{});
        },
        SelfUpdateError.RateLimitExceeded => {
            std.debug.print("Rate limit exceeded. Please try again later.\n", .{});
        },
        SelfUpdateError.ReleaseNotFound => {
            std.debug.print("No releases found.\n", .{});
        },
        SelfUpdateError.UnsupportedPlatform => {
            std.debug.print("Unsupported platform.\n", .{});
        },
        SelfUpdateError.DownloadFailed => {
            std.debug.print("Failed to download update.\n", .{});
        },
        SelfUpdateError.ExtractionFailed => {
            std.debug.print("Failed to extract update.\n", .{});
        },
        SelfUpdateError.PermissionDenied => {
            std.debug.print("Permission denied. Try running with sudo or check file permissions.\n", .{});
        },
        SelfUpdateError.SelfExePathNotFound => {
            std.debug.print("Could not determine executable path.\n", .{});
        },
        SelfUpdateError.ChecksumMismatch => {
            std.debug.print("Checksum verification failed. The downloaded file may be corrupted.\n", .{});
        },
        SelfUpdateError.ChecksumFileNotFound => {
            std.debug.print("Checksum file not found in release.\n", .{});
        },
        SelfUpdateError.InvalidResponse => {
            std.debug.print("Invalid response from server.\n", .{});
        },
    }
}

/// Main self-update function
pub fn selfUpdate(allocator: std.mem.Allocator) !void {
    // Check for updates
    std.debug.print("Checking for updates...\n", .{});

    const result = checkForUpdate(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                std.debug.print("Out of memory.\n", .{});
                return err;
            },
            else => |e| {
                printUpdateError(e);
                return e;
            },
        }
    };
    defer if (result.download_url) |url| allocator.free(url);
    defer allocator.free(result.latest_version);

    if (result.is_up_to_date) {
        std.debug.print("\u{2713} zj v{s} is the latest version\n", .{VERSION});
        return;
    }

    // Update available
    std.debug.print("Update available: v{s} -> {s}\n", .{ VERSION, result.latest_version });

    const download_url = result.download_url orelse return SelfUpdateError.DownloadFailed;

    // Get asset name for checksum lookup
    const platform = try detectPlatform();
    const version_without_v = if (result.latest_version.len > 0 and result.latest_version[0] == 'v')
        result.latest_version[1..]
    else
        result.latest_version;
    const asset_name = try platform.assetName(allocator, version_without_v);
    defer allocator.free(asset_name);

    std.debug.print("Downloading...\n", .{});

    const new_binary = downloadAndExtract(allocator, download_url, result.latest_version, asset_name) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                std.debug.print("Out of memory.\n", .{});
                return err;
            },
            else => |e| {
                printUpdateError(e);
                return e;
            },
        }
    };
    defer allocator.free(new_binary);

    // Get temp directory path from binary path for cleanup
    const tmp_dir_path = std.fs.path.dirname(new_binary);

    std.debug.print("Installing...\n", .{});

    atomicReplace(allocator, new_binary) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                std.debug.print("Out of memory.\n", .{});
                return err;
            },
            else => |e| {
                printUpdateError(e);
                return e;
            },
        }
    };

    // Clean up temp directory
    if (tmp_dir_path) |path| {
        std.fs.deleteTreeAbsolute(path) catch {};
    }

    std.debug.print("\u{2713} Successfully updated zj from v{s} to {s}\n", .{ VERSION, result.latest_version });
}

// Tests

test "SemanticVersion.parse valid versions" {
    const v1 = SemanticVersion.parse("1.2.3").?;
    try std.testing.expectEqual(@as(u32, 1), v1.major);
    try std.testing.expectEqual(@as(u32, 2), v1.minor);
    try std.testing.expectEqual(@as(u32, 3), v1.patch);

    const v2 = SemanticVersion.parse("v0.1.0").?;
    try std.testing.expectEqual(@as(u32, 0), v2.major);
    try std.testing.expectEqual(@as(u32, 1), v2.minor);
    try std.testing.expectEqual(@as(u32, 0), v2.patch);
}

test "SemanticVersion.parse invalid versions" {
    try std.testing.expect(SemanticVersion.parse("1.2") == null);
    try std.testing.expect(SemanticVersion.parse("abc") == null);
    try std.testing.expect(SemanticVersion.parse("") == null);
}

test "SemanticVersion.compare" {
    const v1 = SemanticVersion.parse("1.0.0").?;
    const v2 = SemanticVersion.parse("1.0.1").?;
    const v3 = SemanticVersion.parse("1.1.0").?;
    const v4 = SemanticVersion.parse("2.0.0").?;

    try std.testing.expect(v1.isOlderThan(v2));
    try std.testing.expect(v1.isOlderThan(v3));
    try std.testing.expect(v1.isOlderThan(v4));
    try std.testing.expect(v2.isOlderThan(v3));
    try std.testing.expect(v3.isOlderThan(v4));

    try std.testing.expect(!v2.isOlderThan(v1));
    try std.testing.expect(!v1.isOlderThan(v1));
}

test "detectPlatform" {
    const platform = detectPlatform() catch {
        // Skip test on unsupported platforms
        return;
    };
    try std.testing.expect(platform.os.len > 0);
    try std.testing.expect(platform.arch.len > 0);
}

test "extractTagName valid JSON" {
    const allocator = std.testing.allocator;

    const valid_json =
        \\{"tag_name": "v1.2.3", "name": "Release 1.2.3"}
    ;
    const tag = try extractTagName(allocator, valid_json);
    defer allocator.free(tag);
    try std.testing.expectEqualStrings("v1.2.3", tag);
}

test "extractTagName invalid JSON" {
    const allocator = std.testing.allocator;

    const invalid_json = "not valid json";
    try std.testing.expectError(error.InvalidResponse, extractTagName(allocator, invalid_json));
}

test "extractTagName missing tag_name" {
    const allocator = std.testing.allocator;

    const missing_tag =
        \\{"name": "Release 1.2.3", "id": 12345}
    ;
    try std.testing.expectError(error.InvalidResponse, extractTagName(allocator, missing_tag));
}

test "verifyChecksum" {
    // SHA256 of "hello world\n" is well-known
    const data = "hello world\n";
    const expected_hash = "a948904f2f0f479b8f8564cbf12dac6b18b7b0e3a58c4e1f7f2b2a8e3d1c2b3a"; // fake hash for test
    try std.testing.expect(!verifyChecksum(data, expected_hash));

    // Test with correct hash for empty string
    const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expect(verifyChecksum("", empty_hash));
}

test "findChecksumForFile" {
    const checksums =
        \\abc123def456  zj-0.1.0-darwin-arm64.tar.gz
        \\def789abc012  zj-0.1.0-linux-amd64.tar.gz
        \\123456789abc  zj-0.1.0-darwin-amd64.tar.gz
    ;

    const hash1 = findChecksumForFile(checksums, "zj-0.1.0-darwin-arm64.tar.gz");
    try std.testing.expect(hash1 != null);
    try std.testing.expectEqualStrings("abc123def456", hash1.?);

    const hash2 = findChecksumForFile(checksums, "zj-0.1.0-linux-amd64.tar.gz");
    try std.testing.expect(hash2 != null);
    try std.testing.expectEqualStrings("def789abc012", hash2.?);

    const hash3 = findChecksumForFile(checksums, "nonexistent.tar.gz");
    try std.testing.expect(hash3 == null);
}

test "generateTempDirPath" {
    const allocator = std.testing.allocator;

    const path1 = try generateTempDirPath(allocator);
    defer allocator.free(path1);

    const path2 = try generateTempDirPath(allocator);
    defer allocator.free(path2);

    // Paths should be different (random)
    try std.testing.expect(!std.mem.eql(u8, path1, path2));

    // Paths should contain "zj-update-"
    try std.testing.expect(std.mem.indexOf(u8, path1, "zj-update-") != null);
    try std.testing.expect(std.mem.indexOf(u8, path2, "zj-update-") != null);
}
