const std = @import("std");
const posix = std.posix;

pub const TerminalError = error{
    GetAttrFailed,
    SetAttrFailed,
};

/// Original terminal state for restoration
pub const TerminalState = struct {
    original_termios: posix.termios,
    is_raw: bool = false,
};

/// Enable raw mode for immediate character input
pub fn enableRawMode() !TerminalState {
    var term = posix.tcgetattr(posix.STDIN_FILENO) catch return TerminalError.GetAttrFailed;
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

    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, term) catch return TerminalError.SetAttrFailed;

    return TerminalState{
        .original_termios = original,
        .is_raw = true,
    };
}

/// Disable raw mode and restore original terminal state
pub fn disableRawMode(state: TerminalState) void {
    if (state.is_raw) {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, state.original_termios) catch {};
    }
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
    pub const reset_style = "\x1b[0m";
    pub const reverse_video = "\x1b[7m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
};

/// Read a single byte from stdin
pub fn readByte() !?u8 {
    var buf: [1]u8 = undefined;
    const stdin = std.fs.File.stdin();
    const n = stdin.read(&buf) catch return null;
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
    const c = try readByte() orelse return Key.unknown;

    // Handle escape sequences
    if (c == 0x1b) {
        const c2 = try readByte() orelse return Key.escape;
        if (c2 == '[') {
            const c3 = try readByte() orelse return Key.unknown;
            return switch (c3) {
                'A' => Key.up,
                'B' => Key.down,
                'C' => Key.right,
                'D' => Key.left,
                '3' => blk: {
                    // Delete key is ESC[3~
                    _ = try readByte();
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
