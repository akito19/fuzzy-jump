const std = @import("std");
const posix = std.posix;
const terminal = @import("terminal.zig");
const scoring = @import("scoring.zig");
const fuzzy = @import("fuzzy.zig");
const Allocator = std.mem.Allocator;

const MAX_DISPLAY_ENTRIES = 100;
const MAX_INPUT_LEN = 256;
const DEFAULT_VISIBLE_LINES = 20;
const INLINE_VISIBLE_LINES = 10;
const SEPARATOR_LINE = "─────────────────────────────────────────────\n";

const EntryList = std.ArrayListUnmanaged(scoring.ScoredEntry);
const InputBuffer = std.ArrayListUnmanaged(u8);
const OutputBuffer = std.ArrayListUnmanaged(u8);

/// TUI state
pub const TUI = struct {
    allocator: Allocator,
    all_entries: []scoring.ScoredEntry,
    filtered_entries: EntryList,
    input: InputBuffer,
    output_buf: OutputBuffer,
    selected_index: usize,
    scroll_offset: usize,
    terminal_state: ?terminal.TerminalState,
    visible_lines: usize,
    inline_mode: bool,
    rendered_lines: usize,
    input_fd: posix.fd_t,
    owns_input_fd: bool,

    pub fn init(allocator: Allocator, entries: []scoring.ScoredEntry) TUI {
        return initWithFd(allocator, entries, posix.STDIN_FILENO, false);
    }

    pub fn initWithFd(allocator: Allocator, entries: []scoring.ScoredEntry, fd: posix.fd_t, owns_fd: bool) TUI {
        return .{
            .allocator = allocator,
            .all_entries = entries,
            .filtered_entries = .empty,
            .input = .empty,
            .output_buf = .empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .terminal_state = null,
            .visible_lines = DEFAULT_VISIBLE_LINES,
            .inline_mode = false,
            .rendered_lines = 0,
            .input_fd = fd,
            .owns_input_fd = owns_fd,
        };
    }

    pub fn initInline(allocator: Allocator, entries: []scoring.ScoredEntry) TUI {
        return .{
            .allocator = allocator,
            .all_entries = entries,
            .filtered_entries = .empty,
            .input = .empty,
            .output_buf = .empty,
            .selected_index = 0,
            .scroll_offset = 0,
            .terminal_state = null,
            .visible_lines = INLINE_VISIBLE_LINES,
            .inline_mode = true,
            .rendered_lines = 0,
            .input_fd = posix.STDIN_FILENO,
            .owns_input_fd = false,
        };
    }

    /// Set initial query text
    pub fn setInitialQuery(self: *TUI, query: []const u8) !void {
        self.input.clearRetainingCapacity();
        try self.input.appendSlice(self.allocator, query);
    }

    pub fn deinit(self: *TUI) void {
        self.filtered_entries.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.output_buf.deinit(self.allocator);
        if (self.terminal_state) |state| {
            self.cleanup();
            terminal.disableRawMode(state);
        }
        if (self.owns_input_fd) {
            terminal.closeTty(self.input_fd);
        }
    }

    /// Run the interactive TUI
    pub fn run(self: *TUI) !?[]const u8 {
        // Enter raw mode on the input fd
        self.terminal_state = try terminal.enableRawModeOnFd(self.input_fd);

        // Initial filter with empty query
        try self.filterEntries();
        try self.render();

        // Main event loop
        while (true) {
            const key = try terminal.readKeyFromFd(self.input_fd);

            switch (key) {
                .escape, .ctrl_c => {
                    return null; // Cancelled
                },
                .enter => {
                    if (self.filtered_entries.items.len > 0) {
                        return self.filtered_entries.items[self.selected_index].path;
                    }
                    return null;
                },
                .up, .ctrl_p => {
                    if (self.selected_index > 0) {
                        self.selected_index -= 1;
                        self.adjustScroll();
                    }
                },
                .down, .ctrl_n => {
                    if (self.selected_index + 1 < self.filtered_entries.items.len) {
                        self.selected_index += 1;
                        self.adjustScroll();
                    }
                },
                .backspace => {
                    if (self.input.items.len > 0) {
                        // Handle UTF-8: find start of last character
                        var i = self.input.items.len - 1;
                        while (i > 0 and (self.input.items[i] & 0xC0) == 0x80) {
                            i -= 1;
                        }
                        self.input.shrinkRetainingCapacity(i);
                        try self.resetSelectionAndFilter();
                    }
                },
                .ctrl_u => {
                    self.input.clearRetainingCapacity();
                    try self.resetSelectionAndFilter();
                },
                .ctrl_w => {
                    self.deleteWord();
                    try self.resetSelectionAndFilter();
                },
                .char => |c| {
                    if (c >= 0x20 and c < 0x7F and self.input.items.len < MAX_INPUT_LEN) {
                        try self.input.append(self.allocator, c);
                        try self.resetSelectionAndFilter();
                    }
                },
                else => {},
            }

            try self.render();
        }
    }

    /// Filter entries based on current input
    fn filterEntries(self: *TUI) !void {
        self.filtered_entries.clearRetainingCapacity();

        const query = self.input.items;

        for (self.all_entries) |*entry| {
            if (fuzzy.fuzzyMatch(query, entry.path)) |fuzzy_score| {
                // Recalculate total score with new fuzzy score
                var scored = entry.*;
                scored.fuzzy_score = fuzzy_score;
                scored.total_score = scoring.calculateTotalScore(scored.frecency_score, fuzzy_score);
                try self.filtered_entries.append(self.allocator, scored);
            }
        }

        // Sort by total score
        std.mem.sort(scoring.ScoredEntry, self.filtered_entries.items, {}, scoring.compareScores);

        // Limit to max display entries
        if (self.filtered_entries.items.len > MAX_DISPLAY_ENTRIES) {
            self.filtered_entries.shrinkRetainingCapacity(MAX_DISPLAY_ENTRIES);
        }

        // Adjust selected index if out of bounds
        if (self.selected_index >= self.filtered_entries.items.len) {
            self.selected_index = if (self.filtered_entries.items.len > 0) self.filtered_entries.items.len - 1 else 0;
        }
    }

    /// Adjust scroll offset to keep selected item visible
    fn adjustScroll(self: *TUI) void {
        const max_visible = self.visible_lines - 2; // Account for input line and padding

        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + max_visible) {
            self.scroll_offset = self.selected_index - max_visible + 1;
        }
    }

    /// Delete last word from input
    fn deleteWord(self: *TUI) void {
        if (self.input.items.len == 0) return;

        // Skip trailing spaces
        var i = self.input.items.len;
        while (i > 0 and self.input.items[i - 1] == ' ') {
            i -= 1;
        }

        // Delete until space or start
        while (i > 0 and self.input.items[i - 1] != ' ') {
            i -= 1;
        }

        self.input.shrinkRetainingCapacity(i);
    }

    /// Reset selection state and re-filter entries
    fn resetSelectionAndFilter(self: *TUI) !void {
        self.selected_index = 0;
        self.scroll_offset = 0;
        try self.filterEntries();
    }

    /// Render the TUI using a buffer and single write
    fn render(self: *TUI) !void {
        if (self.inline_mode) {
            try self.renderInline();
        } else {
            try self.renderFullscreen();
        }
    }

    /// Render fullscreen TUI
    fn renderFullscreen(self: *TUI) !void {
        self.output_buf.clearRetainingCapacity();

        // Hide cursor and move to top
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.cursor_hide);
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.cursor_home);
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.clear_screen);

        // Render input line
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.bold);
        try self.output_buf.appendSlice(self.allocator, "> ");
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);
        try self.output_buf.appendSlice(self.allocator, self.input.items);
        try self.output_buf.appendSlice(self.allocator, "_\n");

        // Separator
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.dim);
        try self.output_buf.appendSlice(self.allocator, SEPARATOR_LINE);
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);

        // Render entries
        const max_visible = @min(self.visible_lines - 2, self.filtered_entries.items.len);
        const end_idx = @min(self.scroll_offset + max_visible, self.filtered_entries.items.len);

        for (self.filtered_entries.items[self.scroll_offset..end_idx], 0..) |entry, i| {
            const global_idx = self.scroll_offset + i;
            const is_selected = global_idx == self.selected_index;

            // Sanitize path for display
            const safe_path = try terminal.sanitizeForDisplay(self.allocator, entry.path);
            defer self.allocator.free(safe_path);

            if (is_selected) {
                try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reverse_video);
                try self.output_buf.appendSlice(self.allocator, terminal.Ansi.bold);
                try self.output_buf.appendSlice(self.allocator, "> ");
            } else {
                try self.output_buf.appendSlice(self.allocator, "  ");
            }

            try self.output_buf.appendSlice(self.allocator, safe_path);

            if (is_selected) {
                try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);
            }

            try self.output_buf.appendSlice(self.allocator, "\n");
        }

        // Show count
        try self.output_buf.appendSlice(self.allocator, "\n");
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.dim);

        var count_buf: [64]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "  {d} matches", .{self.filtered_entries.items.len});
        try self.output_buf.appendSlice(self.allocator, count_str);

        if (self.filtered_entries.items.len > max_visible) {
            const range_str = try std.fmt.bufPrint(&count_buf, " (showing {d}-{d})", .{ self.scroll_offset + 1, end_idx });
            try self.output_buf.appendSlice(self.allocator, range_str);
        }
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);

        // Show cursor
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.cursor_show);

        // Write everything at once to stderr
        const stderr = std.fs.File.stderr();
        _ = try stderr.write(self.output_buf.items);
    }

    /// Render inline TUI (below prompt)
    fn renderInline(self: *TUI) !void {
        const stderr = std.fs.File.stderr();
        self.output_buf.clearRetainingCapacity();

        // On subsequent renders, move cursor up by the number of previously rendered lines
        if (self.rendered_lines > 0) {
            var cursor_up_buf: [16]u8 = undefined;
            const cursor_up_seq = terminal.Ansi.cursorUp(&cursor_up_buf, self.rendered_lines);
            try self.output_buf.appendSlice(self.allocator, cursor_up_seq);
            try self.output_buf.appendSlice(self.allocator, terminal.Ansi.cursor_column_1);
        }

        // Hide cursor and clear from cursor to end of screen
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.cursor_hide);
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.clear_to_end);

        var lines_rendered: usize = 0;

        // Render input line
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.bold);
        try self.output_buf.appendSlice(self.allocator, "> ");
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);
        try self.output_buf.appendSlice(self.allocator, self.input.items);
        try self.output_buf.appendSlice(self.allocator, "_\n");
        lines_rendered += 1;

        // Separator
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.dim);
        try self.output_buf.appendSlice(self.allocator, SEPARATOR_LINE);
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);
        lines_rendered += 1;

        // Render entries
        const max_visible = @min(self.visible_lines - 3, self.filtered_entries.items.len);
        const end_idx = @min(self.scroll_offset + max_visible, self.filtered_entries.items.len);

        for (self.filtered_entries.items[self.scroll_offset..end_idx], 0..) |entry, i| {
            const global_idx = self.scroll_offset + i;
            const is_selected = global_idx == self.selected_index;

            // Sanitize path for display
            const safe_path = try terminal.sanitizeForDisplay(self.allocator, entry.path);
            defer self.allocator.free(safe_path);

            if (is_selected) {
                try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reverse_video);
                try self.output_buf.appendSlice(self.allocator, terminal.Ansi.bold);
                try self.output_buf.appendSlice(self.allocator, "> ");
            } else {
                try self.output_buf.appendSlice(self.allocator, "  ");
            }

            try self.output_buf.appendSlice(self.allocator, safe_path);

            if (is_selected) {
                try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);
            }

            try self.output_buf.appendSlice(self.allocator, "\n");
            lines_rendered += 1;
        }

        // Show count
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.dim);

        var count_buf: [64]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "  {d} matches\n", .{self.filtered_entries.items.len}) catch "  ? matches\n";
        try self.output_buf.appendSlice(self.allocator, count_str);
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.reset_style);
        lines_rendered += 1;

        self.rendered_lines = lines_rendered;

        // Show cursor
        try self.output_buf.appendSlice(self.allocator, terminal.Ansi.cursor_show);

        // Write everything at once to stderr
        _ = try stderr.write(self.output_buf.items);
    }

    /// Clean up terminal state
    fn cleanup(self: *TUI) void {
        const stderr = std.fs.File.stderr();

        if (self.inline_mode) {
            // Move cursor up by the number of rendered lines and clear to end of screen
            if (self.rendered_lines > 0) {
                var cursor_up_buf: [16]u8 = undefined;
                const cursor_up_seq = terminal.Ansi.cursorUp(&cursor_up_buf, self.rendered_lines);
                _ = stderr.write(cursor_up_seq) catch {};
                _ = stderr.write(terminal.Ansi.cursor_column_1) catch {};
            }
            _ = stderr.write(terminal.Ansi.clear_to_end) catch {};
            _ = stderr.write(terminal.Ansi.cursor_show) catch {};
            _ = stderr.write(terminal.Ansi.reset_style) catch {};
        } else {
            _ = stderr.write(terminal.Ansi.clear_screen) catch {};
            _ = stderr.write(terminal.Ansi.cursor_home) catch {};
            _ = stderr.write(terminal.Ansi.cursor_show) catch {};
            _ = stderr.write(terminal.Ansi.reset_style) catch {};
        }
    }
};

/// Run interactive selection and return selected path
pub fn selectDirectory(allocator: Allocator, entries: []scoring.ScoredEntry) !?[]const u8 {
    return selectDirectoryWithQuery(allocator, entries, null);
}

/// Run interactive selection with initial query and return selected path
pub fn selectDirectoryWithQuery(allocator: Allocator, entries: []scoring.ScoredEntry, initial_query: ?[]const u8) !?[]const u8 {
    return selectDirectoryWithTty(allocator, entries, initial_query, null);
}

/// Run interactive selection with initial query and TTY fd
pub fn selectDirectoryWithTty(allocator: Allocator, entries: []scoring.ScoredEntry, initial_query: ?[]const u8, tty_fd: ?posix.fd_t) !?[]const u8 {
    if (entries.len == 0) {
        return null;
    }

    var ui = if (tty_fd) |fd|
        TUI.initWithFd(allocator, entries, fd, true)
    else
        TUI.init(allocator, entries);
    defer ui.deinit();

    if (initial_query) |query| {
        try ui.setInitialQuery(query);
    }

    return ui.run();
}

/// Run inline interactive selection with initial query and return selected path
pub fn selectDirectoryInline(allocator: Allocator, entries: []scoring.ScoredEntry, initial_query: ?[]const u8) !?[]const u8 {
    if (entries.len == 0) {
        return null;
    }

    var ui = TUI.initInline(allocator, entries);
    defer ui.deinit();

    if (initial_query) |query| {
        try ui.setInitialQuery(query);
    }

    // Print newline to move below the prompt
    const stderr = std.fs.File.stderr();
    _ = try stderr.write("\n");

    return ui.run();
}
