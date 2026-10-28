//! Passing properties: exercise every generator through the idiomatic API.

const std = @import("std");
const hegel = @import("hegel");
const gen = hegel.gen;
const TestCase = hegel.TestCase;

const fast: hegel.Settings = .{ .test_cases = 100, .database = "", .derandomize = true };

test "integers stay within bounds for every width" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const a = try tc.draw(gen.integers(i8, .{}));
            const b = try tc.draw(gen.integers(u16, .{ .min = 10, .max = 20 }));
            const d = try tc.draw(gen.integers(i64, .{ .min = -5, .max = 5 }));
            const e = try tc.draw(gen.integers(u64, .{ .min = std.math.maxInt(u64) - 3 }));
            const f = try tc.draw(gen.integers(i128, .{ .min = std.math.minInt(i128), .max = std.math.minInt(i128) + 1 }));
            _ = a;
            try tc.expect(b >= 10 and b <= 20);
            try tc.expect(d >= -5 and d <= 5);
            try tc.expect(e >= std.math.maxInt(u64) - 3);
            try tc.expect(f <= std.math.minInt(i128) + 1);
        }
    }.property);
}

test "addition commutes" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const a = try tc.draw(gen.integers(i32, .{}));
            const b = try tc.draw(gen.integers(i32, .{}));
            try tc.expectEqual(a +% b, b +% a);
        }
    }.property);
}

test "bounded floats are finite and in range" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const x = try tc.draw(gen.floats(f64, .{ .min = -1.0, .max = 1.0 }));
            try tc.expect(!std.math.isNan(x) and x >= -1.0 and x <= 1.0);
            const y = try tc.draw(gen.floats(f32, .{ .min = 0.0, .max = 10.0, .exclude_min = true }));
            try tc.expect(y > 0.0 and y <= 10.0);
            _ = try tc.draw(gen.floats(f64, .{}));
        }
    }.property);
}

test "text, regex and bytes" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const s = try tc.draw(gen.text(.{ .max_size = 10 }));
            try tc.expect(std.unicode.utf8ValidateSlice(s));
            try tc.expect(try std.unicode.utf8CountCodepoints(s) <= 10);
            const ascii = try tc.draw(gen.text(.{ .codec = "ascii", .min_size = 1, .max_size = 5 }));
            for (ascii) |ch| try tc.expect(ch < 128);
            const id = try tc.draw(gen.fromRegex("[a-z]{3}[0-9]", .{ .fullmatch = true }));
            try tc.expectEqual(@as(usize, 4), id.len);
            const raw = try tc.draw(gen.bytes(.{ .min_size = 2, .max_size = 4 }));
            try tc.expect(raw.len >= 2 and raw.len <= 4);
        }
    }.property);
}

fn isEven(x: u32) bool {
    return x % 2 == 0;
}

fn double(x: u8) u16 {
    return @as(u16, x) * 2;
}

test "combinators: lists, optionals, oneOf, map, filter, sampledFrom, just" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const xs = try tc.draw(gen.lists(gen.integers(u8, .{ .max = 9 }), .{ .min_size = 1, .max_size = 6 }));
            try tc.expect(xs.len >= 1 and xs.len <= 6);
            for (xs) |x| try tc.expect(x <= 9);

            const maybe = try tc.draw(gen.optionals(gen.booleans()));
            _ = maybe;

            const pick = try tc.draw(gen.oneOf(.{ gen.just(@as(i32, -1)), gen.integers(i32, .{ .min = 100, .max = 200 }) }));
            try tc.expect(pick == -1 or (pick >= 100 and pick <= 200));

            const even = try tc.draw(gen.filter(gen.integers(u32, .{ .max = 1000 }), isEven));
            try tc.expect(even % 2 == 0);

            const doubled = try tc.draw(gen.map(gen.integers(u8, .{}), double));
            try tc.expect(doubled % 2 == 0);

            const colour = try tc.draw(gen.sampledFrom([]const u8, &.{ "red", "green", "blue" }));
            try tc.expect(colour.len >= 3);
        }
    }.property);
}

const Point = struct { x: i16, y: i16 };

/// A user-defined composite generator is an ordinary struct.
const Points = struct {
    pub const Value = Point;
    pub fn generate(_: Points, tc: *TestCase) hegel.DrawError!Point {
        return .{
            .x = try tc.draw(gen.integers(i16, .{ .min = -100, .max = 100 })),
            .y = try tc.draw(gen.integers(i16, .{ .min = -100, .max = 100 })),
        };
    }
};

test "custom generators compose" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const ps = try tc.draw(gen.lists(Points{}, .{ .max_size = 5 }));
            for (ps) |p| try tc.expect(@abs(p.x) <= 100 and @abs(p.y) <= 100);
        }
    }.property);
}

test "assume discards test cases" {
    var result = try hegel.run(std.testing.allocator, fast, struct {
        fn property(tc: *TestCase) !void {
            const n = try tc.draw(gen.integers(u8, .{}));
            try tc.assume(n != 0);
            try tc.expect(255 / n >= 1);
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(result.passed());
    try std.testing.expect(result.valid_test_cases > 0);
}

test "context is passed through and test cases are counted" {
    var calls: usize = 0;
    try hegel.checkWithContext(.{ .test_cases = 20, .database = "" }, &calls, struct {
        fn property(n: *usize, tc: *TestCase) !void {
            n.* += 1;
            _ = try tc.draw(gen.booleans());
        }
    }.property);
    try std.testing.expect(calls >= 2);
}

test "pool hands back only live variables" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const pool = try tc.pool();
            defer pool.deinit();
            var live: std.AutoHashMapUnmanaged(i64, void) = .empty;
            for (0..12) |_| {
                if (live.count() == 0 or try tc.draw(gen.booleans())) {
                    try live.put(tc.allocator(), try pool.add(), {});
                } else {
                    const id = try pool.generate(true);
                    try tc.expect(live.remove(id));
                }
            }
        }
    }.property);
}

test "state machine selects every rule" {
    var counts: [3]usize = @splat(0);
    try hegel.checkWithContext(fast, &counts, struct {
        fn property(rule_counts: *[3]usize, tc: *TestCase) !void {
            var machine = try tc.stateMachine(&.{ "increment", "decrement", "reset" }, 50);
            defer machine.deinit();
            var counter: u32 = 0;
            while (try machine.nextRule()) |rule| {
                rule_counts[rule] += 1;
                switch (rule) {
                    0 => counter += 1,
                    1 => if (counter > 0) {
                        counter -= 1;
                    } else try machine.reject(),
                    2 => counter = 0,
                    else => unreachable,
                }
            }
        }
    }.property);
    for (counts) |n| try std.testing.expect(n > 0);
}

test "engine output can be redirected" {
    const Sink = struct {
        lines: usize = 0,
        fn writeLine(ctx: ?*anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.lines += 1;
        }
    };
    var sink: Sink = .{};
    var settings = fast;
    settings.test_cases = 10;
    settings.verbosity = .debug;
    settings.output = .{ .context = &sink, .writeLine = Sink.writeLine };
    var result = try hegel.run(std.testing.allocator, settings, struct {
        fn property(tc: *TestCase) !void {
            _ = try tc.draw(gen.integers(u8, .{}));
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(result.passed());
    try std.testing.expect(sink.lines > 0);
}
