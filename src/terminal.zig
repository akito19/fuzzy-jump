const std = @import("std");
const posix = std.posix;

const TerminalError = error{
    GetAttrFailed,
    SetAttrFailed,
};

const TtyError = error{
    OpenFailed,
};

/// Original terminal state for restoration
pub const TerminalState = struct {
    original_termios: posix.termios,
    fd: posix.fd_t = posix.STDIN_FILENO,
    is_raw: bool = false,
};

/// Enable raw mode for immediate character input
pub fn enableRawMode() !TerminalState {
    return enableRawModeOnFd(posix.STDIN_FILENO);
}

/// Enable raw mode on a specific file descriptor
pub fn enableRawModeOnFd(fd: posix.fd_t) !TerminalState {
    var term = posix.tcgetattr(fd) catch return TerminalError.GetAttrFailed;
    const original = term;

    // Disable echo and canonical mode
    term.lflag.ECHO = false;
    term.lflag.ICANON = false;
    term.lflag.ISIG = false; // Don't send signals on Ctrl-C
    term.lflag.IEXTEN = false; // Disable Ctrl-V

    // Disable input processing
    term.iflag.IXON = false; // Disable Ctrl-S/Q
    term.iflag.ICRNL = false; // Don't convert CR to NL
    term.iflag.BRKINT = false;
    term.iflag.INPCK = false;
    term.iflag.ISTRIP = false;

    // Set read to return immediately with at least 1 byte
    term.cc[@intFromEnum(posix.V.MIN)] = 1;
    term.cc[@intFromEnum(posix.V.TIME)] = 0;

    posix.tcsetattr(fd, .FLUSH, term) catch return TerminalError.SetAttrFailed;

    return TerminalState{
        .original_termios = original,
        .fd = fd,
        .is_raw = true,
    };
}

/// Disable raw mode and restore original terminal state
pub fn disableRawMode(state: TerminalState) void {
    if (state.is_raw) {
        posix.tcsetattr(state.fd, .FLUSH, state.original_termios) catch {};
    }
}

/// Check if stdin is a TTY
pub fn isStdinTty() bool {
    return posix.isatty(posix.STDIN_FILENO);
}

/// Open /dev/tty for direct terminal access
pub fn openTty() TtyError!posix.fd_t {
    return posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return TtyError.OpenFailed;
}

/// Close the TTY file descriptor
pub fn closeTty(fd: posix.fd_t) void {
    posix.close(fd);
}

/// ANSI escape sequences for terminal control
pub const Ansi = struct {
    pub const clear_screen = "\x1b[2J";
    pub const clear_to_end = "\x1b[J";
    pub const cursor_home = "\x1b[H";
    pub const cursor_hide = "\x1b[?25l";
    pub const cursor_show = "\x1b[?25h";
    pub const cursor_save = "\x1b7";
    pub const cursor_restore = "\x1b8";
    pub const cursor_column_1 = "\x1b[1G"; // Move cursor to column 1
    pub const reset_style = "\x1b[0m";
    pub const reverse_video = "\x1b[7m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    /// Generate cursor up sequence for n lines
    pub fn cursorUp(buf: []u8, n: usize) []const u8 {
        if (n == 0) return "";
        const len = std.fmt.bufPrint(buf, "\x1b[{d}A", .{n}) catch return "";
        return buf[0..len.len];
    }
};

/// Read a single byte from stdin
fn readByte() !?u8 {
    return readByteFromFd(posix.STDIN_FILENO);
}

/// Read a single byte from a file descriptor
fn readByteFromFd(fd: posix.fd_t) !?u8 {
    var buf: [1]u8 = undefined;
    const n = posix.read(fd, &buf) catch return null;
    if (n == 0) return null;
    return buf[0];
}

/// Key codes for special keys
pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    escape,
    backspace,
    delete,
    ctrl_c,
    ctrl_n,
    ctrl_p,
    ctrl_u,
    ctrl_w,
    unknown,
};

/// Read a key (handles escape sequences)
pub fn readKey() !Key {
    return readKeyFromFd(posix.STDIN_FILENO);
}

/// Read a key from a file descriptor (handles escape sequences)
pub fn readKeyFromFd(fd: posix.fd_t) !Key {
    const c = try readByteFromFd(fd) orelse return Key.unknown;

    // Handle escape sequences
    if (c == 0x1b) {
        const c2 = try readByteFromFd(fd) orelse return Key.escape;
        if (c2 == '[') {
            const c3 = try readByteFromFd(fd) orelse return Key.unknown;
            return switch (c3) {
                'A' => Key.up,
                'B' => Key.down,
                'C' => Key.right,
                'D' => Key.left,
                '3' => blk: {
                    // Delete key is ESC[3~
                    _ = try readByteFromFd(fd);
                    break :blk Key.delete;
                },
                else => Key.unknown,
            };
        }
        return Key.escape;
    }

    // Handle control characters
    return switch (c) {
        0x03 => Key.ctrl_c, // End of Text
        0x0e => Key.ctrl_n, // Shift Out
        0x10 => Key.ctrl_p, // Data Link Escape
        0x15 => Key.ctrl_u, // Negative Acknowledgment
        0x17 => Key.ctrl_w, // End of Transmission Block
        0x0d, 0x0a => Key.enter,     // CR, LF
        0x7f, 0x08 => Key.backspace, // DEL, BS
        else => Key{ .char = c },
    };
}

/// Sanitize a string for safe terminal display
/// Removes/escapes control characters and ANSI sequences
pub fn sanitizeForDisplay(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == 0x1b) {
            // Escape sequence - skip it
            try output.appendSlice(allocator, "\\e");
            i += 1;
            // Skip the rest of the escape sequence
            if (i < input.len and input[i] == '[') {
                i += 1;
                while (i < input.len and input[i] >= 0x20 and input[i] < 0x40) {
                    i += 1;
                }
                if (i < input.len) {
                    i += 1; // Skip final byte
                }
            }
        } else if (c < 0x20 or c == 0x7f) {
            // Control character
            if (c == '\t') {
                try output.appendSlice(allocator, "    ");
            } else if (c == '\n' or c == '\r') {
                // Skip newlines
            } else {
                // Format as hex: \xNN
                const hex_chars = "0123456789abcdef";
                try output.appendSlice(allocator, "\\x");
                try output.append(allocator, hex_chars[c >> 4]);
                try output.append(allocator, hex_chars[c & 0x0F]);
            }
            i += 1;
        } else {
            try output.append(allocator, c);
            i += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

test "sanitizeForDisplay removes escape sequences" {
    const allocator = std.testing.allocator;

    const result = try sanitizeForDisplay(allocator, "hello\x1b[31mworld\x1b[0m");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello\\eworld\\e", result);
}

test "sanitizeForDisplay handles control characters" {
    const allocator = std.testing.allocator;

    const result = try sanitizeForDisplay(allocator, "hello\x00world");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello\\x00world", result);
}

test "isStdinTty returns boolean" {
    // In test environment, stdin may or may not be a TTY depending on how tests are run
    // This test verifies the function doesn't crash and returns a valid boolean
    const result = isStdinTty();
    try std.testing.expect(result == true or result == false);
}

test "openTty and closeTty" {
    // Skip this test if stdin is not a TTY (CI environment, piped input, etc.)
    // because /dev/tty won't be available
    if (!isStdinTty()) {
        return;
    }

    const fd = openTty() catch |err| {
        // Even with a TTY stdin, /dev/tty may not be available in some environments
        try std.testing.expectEqual(TtyError.OpenFailed, err);
        return;
    };

    // Verify fd is valid (non-negative)
    try std.testing.expect(fd >= 0);
    closeTty(fd);
}

test "readByteFromFd with pipe" {
    // Create a pipe to test reading from a file descriptor
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // Write a byte to the pipe
    _ = try posix.write(pipe[1], "x");

    // Read it back
    const byte = try readByteFromFd(pipe[0]);
    try std.testing.expectEqual(@as(?u8, 'x'), byte);
}

test "readByteFromFd returns null on empty pipe" {
    // Create a pipe and close the write end
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    posix.close(pipe[1]);

    // Read from empty pipe should return null
    const byte = try readByteFromFd(pipe[0]);
    try std.testing.expectEqual(@as(?u8, null), byte);
}

test "readKeyFromFd with regular character" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // Write a regular character
    _ = try posix.write(pipe[1], "a");

    const key = try readKeyFromFd(pipe[0]);
    try std.testing.expectEqual(Key{ .char = 'a' }, key);
}

test "readKeyFromFd with enter key" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // Write carriage return (Enter)
    _ = try posix.write(pipe[1], "\r");

    const key = try readKeyFromFd(pipe[0]);
    try std.testing.expectEqual(Key.enter, key);
}

test "readKeyFromFd with ctrl-c" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // Write Ctrl-C (0x03)
    _ = try posix.write(pipe[1], "\x03");

    const key = try readKeyFromFd(pipe[0]);
    try std.testing.expectEqual(Key.ctrl_c, key);
}

test "readKeyFromFd with arrow up escape sequence" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // Write escape sequence for arrow up
    _ = try posix.write(pipe[1], "\x1b[A");

    const key = try readKeyFromFd(pipe[0]);
    try std.testing.expectEqual(Key.up, key);
}

test "readKeyFromFd with arrow down escape sequence" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // Write escape sequence for arrow down
    _ = try posix.write(pipe[1], "\x1b[B");

    const key = try readKeyFromFd(pipe[0]);
    try std.testing.expectEqual(Key.down, key);
}

test "readKeyFromFd with backspace" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    // Write DEL (0x7f) for backspace
    _ = try posix.write(pipe[1], "\x7f");

    const key = try readKeyFromFd(pipe[0]);
    try std.testing.expectEqual(Key.backspace, key);
}

test "TerminalState stores fd correctly" {
    const state = TerminalState{
        .original_termios = undefined,
        .fd = 42,
        .is_raw = false,
    };
    try std.testing.expectEqual(@as(posix.fd_t, 42), state.fd);
}
