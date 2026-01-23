const std = @import("std");

/// Score bonuses for different match types
const EXACT_MATCH_BONUS: i32 = 100;
const PREFIX_MATCH_BONUS: i32 = 75;
const BASENAME_MATCH_BONUS: i32 = 50;
const CONSECUTIVE_BONUS: i32 = 10;
const SEPARATOR_BONUS: i32 = 5;
const BASE_CHAR_SCORE: i32 = 1;
const MAX_CONSECUTIVE_BONUS: i32 = 5;

/// Length bonus constants
const LENGTH_BONUS_MAX: i32 = 20;
const LENGTH_BONUS_MAX_LEN: usize = 200;
const LENGTH_BONUS_DIVISOR: i32 = 10;

/// Fuzzy match with basename-priority scoring
/// Returns match score or null if no match
pub fn fuzzyMatch(pattern: []const u8, path: []const u8) ?i32 {
    if (pattern.len == 0) {
        return 0; // Empty pattern matches everything with score 0
    }

    const basename = getBasename(path);

    // Try exact match on basename first (highest priority)
    if (exactMatchIgnoreCase(pattern, basename)) {
        return EXACT_MATCH_BONUS + lengthBonus(path.len);
    }

    // Try prefix match on basename
    if (prefixMatchIgnoreCase(pattern, basename)) {
        return PREFIX_MATCH_BONUS + lengthBonus(path.len);
    }

    // Try fuzzy match on basename
    if (fuzzyMatchCore(pattern, basename)) |basename_score| {
        return BASENAME_MATCH_BONUS + basename_score + lengthBonus(path.len);
    }

    // Try fuzzy match on full path (lowest priority)
    if (fuzzyMatchCore(pattern, path)) |path_score| {
        return path_score + lengthBonus(path.len);
    }

    return null; // No match
}

/// Core fuzzy matching - byte-based for simplicity and reliability
fn fuzzyMatchCore(pattern: []const u8, text: []const u8) ?i32 {
    if (pattern.len == 0) return 0;
    if (text.len == 0) return null;

    var score: i32 = 0;
    var consecutive: i32 = 0;
    var pattern_idx: usize = 0;
    var text_idx: usize = 0;
    var prev_matched = false;

    while (pattern_idx < pattern.len) {
        const pattern_byte = toLowerByte(pattern[pattern_idx]);

        var found = false;
        while (text_idx < text.len) {
            const text_byte = toLowerByte(text[text_idx]);

            if (pattern_byte == text_byte) {
                score += BASE_CHAR_SCORE;

                // Consecutive match bonus
                if (prev_matched) {
                    consecutive += 1;
                    score += @min(consecutive, MAX_CONSECUTIVE_BONUS);
                } else {
                    consecutive = 0;
                }

                // Check if match is after separator
                if (text_idx > 0) {
                    const prev_byte = text[text_idx - 1];
                    if (prev_byte == '/' or prev_byte == '_' or prev_byte == '-' or prev_byte == ' ') {
                        score += SEPARATOR_BONUS;
                    }
                }

                prev_matched = true;
                text_idx += 1;
                found = true;
                break;
            }

            prev_matched = false;
            consecutive = 0;
            text_idx += 1;
        }

        if (!found) return null; // Pattern character not found
        pattern_idx += 1;
    }

    return score;
}

/// Get basename (last path component) from a path
pub fn getBasename(path: []const u8) []const u8 {
    if (path.len == 0) return path;

    // Find last slash
    var last_slash: usize = 0;
    var found_slash = false;

    for (path, 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
            found_slash = true;
        }
    }

    if (found_slash and last_slash + 1 < path.len) {
        return path[last_slash + 1 ..];
    }

    return path;
}

/// Check for exact match (case-insensitive, byte-based)
fn exactMatchIgnoreCase(pattern: []const u8, text: []const u8) bool {
    if (pattern.len != text.len) return false;

    for (pattern, text) |p, t| {
        if (toLowerByte(p) != toLowerByte(t)) {
            return false;
        }
    }

    return true;
}

/// Check for prefix match (case-insensitive, byte-based)
fn prefixMatchIgnoreCase(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    if (text.len < pattern.len) return false;

    for (pattern, text[0..pattern.len]) |p, t| {
        if (toLowerByte(p) != toLowerByte(t)) {
            return false;
        }
    }

    return true;
}

/// Calculate length bonus (shorter paths are preferred)
fn lengthBonus(len: usize) i32 {
    const len_i32: i32 = @intCast(@min(len, LENGTH_BONUS_MAX_LEN));
    return @max(0, LENGTH_BONUS_MAX - @divFloor(len_i32, LENGTH_BONUS_DIVISOR));
}

/// Convert a byte to lowercase (ASCII only)
fn toLowerByte(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') {
        return c + ('a' - 'A');
    }
    return c;
}

// Tests

test "getBasename" {
    try std.testing.expectEqualStrings("work", getBasename("/home/user/projects/work"));
    try std.testing.expectEqualStrings("projects", getBasename("/home/user/projects"));
    try std.testing.expectEqualStrings("home", getBasename("/home"));
    try std.testing.expectEqualStrings("file.txt", getBasename("file.txt"));
}

test "exactMatchIgnoreCase" {
    try std.testing.expect(exactMatchIgnoreCase("work", "work"));
    try std.testing.expect(exactMatchIgnoreCase("work", "WORK"));
    try std.testing.expect(exactMatchIgnoreCase("WORK", "work"));
    try std.testing.expect(!exactMatchIgnoreCase("work", "works"));
    try std.testing.expect(!exactMatchIgnoreCase("works", "work"));
}

test "prefixMatchIgnoreCase" {
    try std.testing.expect(prefixMatchIgnoreCase("work", "workflow"));
    try std.testing.expect(prefixMatchIgnoreCase("WORK", "workflow"));
    try std.testing.expect(!prefixMatchIgnoreCase("workflow", "work"));
    try std.testing.expect(prefixMatchIgnoreCase("", "anything"));
}

test "fuzzyMatch exact basename" {
    const score = fuzzyMatch("work", "/home/user/projects/work");
    try std.testing.expect(score != null);
    try std.testing.expect(score.? >= EXACT_MATCH_BONUS);
}

test "fuzzyMatch prefix basename" {
    const score = fuzzyMatch("work", "/home/user/projects/workflow");
    try std.testing.expect(score != null);
    try std.testing.expect(score.? >= PREFIX_MATCH_BONUS);
    try std.testing.expect(score.? < EXACT_MATCH_BONUS);
}

test "fuzzyMatch partial" {
    const score = fuzzyMatch("proj", "/home/user/projects");
    try std.testing.expect(score != null);
    try std.testing.expect(score.? > 0);
}

test "fuzzyMatch no match" {
    const score = fuzzyMatch("xyz", "/home/user/projects");
    try std.testing.expect(score == null);
}

test "fuzzyMatchCore consecutive bonus" {
    const score1 = fuzzyMatchCore("abc", "abc");
    const score2 = fuzzyMatchCore("abc", "aXbXc");
    try std.testing.expect(score1 != null);
    try std.testing.expect(score2 != null);
    try std.testing.expect(score1.? > score2.?);
}
