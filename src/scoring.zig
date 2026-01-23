const std = @import("std");

/// Scored directory entry combining frecency and fuzzy match scores
pub const ScoredEntry = struct {
    path: []const u8,
    frecency_score: f64,
    fuzzy_score: i32,
    total_score: f64,
    visit_count: u32,
    last_visit: i64,
};

/// Time-based decay constants (in seconds)
const ONE_HOUR: i64 = 3600;
const ONE_DAY: i64 = 86400;
const ONE_WEEK: i64 = 604800;

/// Calculate frecency score based on visit frequency and recency
/// Uses step-based decay algorithm
pub fn calculateFrecencyScore(visit_count: u32, last_visit: i64, now: i64) f64 {
    const base_score: f64 = @floatFromInt(visit_count);

    // If no timestamp available, use base score
    if (last_visit == 0) {
        return base_score;
    }

    const elapsed = now - last_visit;

    // Step-based decay
    if (elapsed < ONE_HOUR) {
        return base_score * 4.0; // Very recent
    } else if (elapsed < ONE_DAY) {
        return base_score * 2.0; // Today
    } else if (elapsed < ONE_WEEK) {
        return base_score * 1.0; // This week
    } else if (elapsed < ONE_WEEK * 4) {
        return base_score / 2.0; // This month
    } else {
        return base_score / 4.0; // Older
    }
}

/// Calculate combined score from frecency and fuzzy match scores
pub fn calculateTotalScore(frecency_score: f64, fuzzy_score: i32) f64 {
    // Fuzzy score is weighted more heavily to prioritize good matches
    // Frecency provides secondary ranking among similar matches
    const fuzzy_weight: f64 = 10.0;
    const frecency_weight: f64 = 1.0;

    return @as(f64, @floatFromInt(fuzzy_score)) * fuzzy_weight + frecency_score * frecency_weight;
}

/// Compare two scored entries for sorting (descending by total score)
pub fn compareScores(_: void, a: ScoredEntry, b: ScoredEntry) bool {
    if (a.total_score != b.total_score) {
        return a.total_score > b.total_score;
    }
    // Tie-breaker: prefer shorter paths
    return a.path.len < b.path.len;
}

/// Get current Unix timestamp
pub fn getCurrentTimestamp() i64 {
    return std.time.timestamp();
}

test "calculateFrecencyScore within hour" {
    const now: i64 = 1705700000;
    const last_visit: i64 = now - 1800; // 30 minutes ago
    const score = calculateFrecencyScore(10, last_visit, now);
    try std.testing.expectEqual(@as(f64, 40.0), score);
}

test "calculateFrecencyScore within day" {
    const now: i64 = 1705700000;
    const last_visit: i64 = now - 43200; // 12 hours ago
    const score = calculateFrecencyScore(10, last_visit, now);
    try std.testing.expectEqual(@as(f64, 20.0), score);
}

test "calculateFrecencyScore within week" {
    const now: i64 = 1705700000;
    const last_visit: i64 = now - 259200; // 3 days ago
    const score = calculateFrecencyScore(10, last_visit, now);
    try std.testing.expectEqual(@as(f64, 10.0), score);
}

test "calculateFrecencyScore older than week" {
    const now: i64 = 1705700000;
    const last_visit: i64 = now - 1209600; // 2 weeks ago
    const score = calculateFrecencyScore(10, last_visit, now);
    try std.testing.expectEqual(@as(f64, 5.0), score);
}

test "calculateTotalScore" {
    const total = calculateTotalScore(20.0, 100);
    // 100 * 10.0 + 20.0 * 1.0 = 1020.0
    try std.testing.expectEqual(@as(f64, 1020.0), total);
}
