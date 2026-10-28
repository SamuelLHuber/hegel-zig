//! Failing properties: libhegel must find and shrink counterexamples, and
//! the Zig layer must report them.

const std = @import("std");
const hegel = @import("hegel");
const gen = hegel.gen;
const TestCase = hegel.TestCase;

const fast: hegel.Settings = .{ .test_cases = 200, .database = "", .derandomize = true };

/// Runs `property` (expected to fail) and returns the single failure's
/// report, checking that it mentions every string in `needles`.
fn expectFailure(comptime property: anytype, needles: []const []const u8) !void {
    var result = try hegel.run(std.testing.allocator, fast, property);
    defer result.deinit();
    try std.testing.expectEqual(hegel.Status.failed, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.failures.len);
    const report = result.failures[0].report;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, report, needle) == null) {
            std.debug.print("report is missing \"{s}\":\n{s}\n", .{ needle, report });
            return error.TestUnexpectedResult;
        }
    }
}

test "shrinks an integer to the boundary" {
    try expectFailure(struct {
        fn property(tc: *TestCase) !void {
            const n = try tc.draw(gen.integers(i64, .{ .min = 0, .max = 100 }));
            if (n >= 5) return tc.fail("n = {d}", .{n});
        }
    }.property, &.{ "Draw 1: 5\n", "n = 5" });
}

test "shrinks a list to a minimal counterexample" {
    try expectFailure(struct {
        fn property(tc: *TestCase) !void {
            const xs = try tc.draw(gen.lists(gen.integers(u32, .{ .max = 1000 }), .{}));
            var sum: u64 = 0;
            for (xs) |x| sum += x;
            try tc.expect(sum < 100);
        }
    }.property, &.{"Draw 1: { 100 }\n"});
}

test "shrinks text" {
    try expectFailure(struct {
        fn property(tc: *TestCase) !void {
            const s = try tc.draw(gen.text(.{ .codec = "ascii" }));
            try tc.expect(s.len < 3);
        }
    }.property, &.{"Draw 1: \"000\"\n"});
}

test "expectEqual reports both values" {
    try expectFailure(struct {
        fn property(tc: *TestCase) !void {
            const a = try tc.draw(gen.integers(u8, .{}));
            try tc.expectEqual(@as(u8, 0), a / 2);
        }
    }.property, &.{ "Draw 1: 2\n", "expected 0, found 1" });
}

test "any error from the property is a failure, including std.testing" {
    try expectFailure(struct {
        fn property(tc: *TestCase) !void {
            const n = try tc.draw(gen.integers(u16, .{}));
            try std.testing.expect(n < 1000);
        }
    }.property, &.{ "Draw 1: 1000\n", "error: TestUnexpectedResult" });
}

test "notes are included in the report" {
    try expectFailure(struct {
        fn property(tc: *TestCase) !void {
            const n = try tc.draw(gen.integers(u8, .{}));
            tc.note("half = {d}", .{n / 2});
            try tc.expect(n < 10);
        }
    }.property, &.{ "Draw 1: 10\n", "half = 5\n" });
}

test "failure carries a blob that reproduces it" {
    const property = struct {
        fn property(tc: *TestCase) !void {
            const n = try tc.draw(gen.integers(u32, .{}));
            try tc.expect(n < 12345);
        }
    }.property;
    var result = try hegel.run(std.testing.allocator, fast, property);
    defer result.deinit();
    try std.testing.expectEqual(hegel.Status.failed, result.status);
    const blob = result.failures[0].reproduction_blob orelse return error.TestExpectedBlob;

    var replay = try hegel.run(std.testing.allocator, .{ .database = "", .reproduce = blob }, property);
    defer replay.deinit();
    try std.testing.expectEqual(hegel.Status.failed, replay.status);
    try std.testing.expect(std.mem.indexOf(u8, replay.failures[0].report, "Draw 1: 12345\n") != null);
}

test "distinct bugs are reported separately" {
    var result = try hegel.run(std.testing.allocator, .{ .test_cases = 500, .database = "", .derandomize = true, .report_multiple_failures = true }, struct {
        fn property(tc: *TestCase) !void {
            const n = try tc.draw(gen.integers(i32, .{ .min = -1000, .max = 1000 }));
            if (n < -10) return error.TooSmall;
            if (n > 10) return error.TooBig;
        }
    }.property);
    defer result.deinit();
    try std.testing.expectEqual(hegel.Status.failed, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.failures.len);
}

test "check returns HegelPropertyFailed" {
    // The report goes to stderr; only the error matters here.
    try std.testing.expectError(error.HegelPropertyFailed, hegel.check(.{ .test_cases = 50, .database = "", .derandomize = true, .verbosity = .quiet }, struct {
        fn property(tc: *TestCase) !void {
            try tc.expect(!try tc.draw(gen.booleans()));
        }
    }.property));
}

test "invalid arguments fail the property with a diagnostic" {
    try expectFailure(struct {
        fn property(tc: *TestCase) !void {
            _ = try tc.draw(gen.integers(i32, .{ .min = 10, .max = 5 }));
        }
    }.property, &.{ "HegelInvalidArgument", "min_value <= max_value" });
}
