//! The generators built on libhegel's format, temporal, grammar and
//! recursion APIs, plus the type-directed and structural combinators.

const std = @import("std");
const hegel = @import("hegel");
const gen = hegel.gen;
const TestCase = hegel.TestCase;

const fast: hegel.Settings = .{ .test_cases = 100, .database = "", .derandomize = true };

fn daysIn(year: i32, month: u8) u8 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn dateBefore(a: gen.Date, b: gen.Date) bool {
    if (a.year != b.year) return a.year < b.year;
    if (a.month != b.month) return a.month < b.month;
    return a.day <= b.day;
}

test "dates are valid calendar days within bounds" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const lo: gen.Date = .{ .year = 1999, .month = 12, .day = 30 };
            const hi: gen.Date = .{ .year = 2001, .month = 3, .day = 1 };
            const d = try tc.draw(gen.dates(.{ .min = lo, .max = hi }));
            try tc.expect(d.month >= 1 and d.month <= 12);
            try tc.expect(d.day >= 1 and d.day <= daysIn(d.year, d.month));
            try tc.expect(dateBefore(lo, d) and dateBefore(d, hi));
            const any = try tc.draw(gen.dates(.{}));
            try tc.expect(any.day <= daysIn(any.year, any.month));
        }
    }.property);
}

test "times and datetimes are in range" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const t = try tc.draw(gen.times(.{ .min = .{ .hour = 9, .minute = 0, .second = 0, .nanosecond = 0 }, .max = .{ .hour = 17, .minute = 0, .second = 0, .nanosecond = 0 } }));
            try tc.expect(t.hour >= 9 and t.hour <= 17);
            try tc.expect(t.minute < 60 and t.second < 60 and t.nanosecond < 1_000_000_000);
            if (t.hour == 17) try tc.expect(t.minute == 0 and t.second == 0 and t.nanosecond == 0);
            const dt = try tc.draw(gen.datetimes(.{}));
            try tc.expect(dt.date.day <= daysIn(dt.date.year, dt.date.month));
            try tc.expect(dt.time.hour < 24);
        }
    }.property);
}

test "uuids honour the requested version and are never nil" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const v4 = try tc.draw(gen.uuids(.{ .version = 4 }));
            try tc.expectEqual(@as(u8, 4), v4[6] >> 4);
            try tc.expectEqual(@as(u8, 0b10), v4[8] >> 6);
            const any = try tc.draw(gen.uuids(.{}));
            try tc.expect(!std.mem.allEqual(u8, &any, 0));
        }
    }.property);
}

test "ip addresses cover both families" {
    const Seen = struct { v4: bool = false, v6: bool = false };
    var seen: Seen = .{};
    try hegel.checkWithContext(fast, &seen, struct {
        fn property(s: *Seen, tc: *TestCase) !void {
            _ = try tc.draw(gen.ipv4Addresses());
            _ = try tc.draw(gen.ipv6Addresses());
            switch (try tc.draw(gen.ipAddresses())) {
                .v4 => s.v4 = true,
                .v6 => s.v6 = true,
            }
        }
    }.property);
    try std.testing.expect(seen.v4 and seen.v6);
}

test "emails, urls and domains are well formed" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const email = try tc.draw(gen.emails());
            try tc.expect(std.mem.count(u8, email, "@") >= 1);
            const url = try tc.draw(gen.urls());
            try tc.expect(std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"));
            const domain = try tc.draw(gen.domains(.{ .max_length = 20 }));
            try tc.expect(domain.len >= 1 and domain.len <= 20);
            for (domain) |ch| try tc.expect(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-');
        }
    }.property);
}

test "lark grammars generate strings in their language" {
    var grammar = try gen.Grammar.init(std.testing.allocator,
        \\start: pair ("," pair)*
        \\pair: KEY "=" DIGIT
        \\KEY: /[a-z]{1,3}/
        \\%import common.DIGIT
    , .{});
    defer grammar.deinit();
    try hegel.checkWithContext(fast, &grammar, struct {
        fn property(g: *gen.Grammar, tc: *TestCase) !void {
            const s = try tc.draw(gen.fromGrammar(g, .{}));
            var pairs = std.mem.splitScalar(u8, s, ',');
            while (pairs.next()) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return tc.fail("no '=' in {s}", .{pair});
                try tc.expect(eq >= 1 and eq <= 3);
                for (pair[0..eq]) |ch| try tc.expect(std.ascii.isLower(ch));
                try tc.expect(pair.len == eq + 2 and std.ascii.isDigit(pair[eq + 1]));
            }
        }
    }.property);
}

test "grammar errors are reported, not crashes" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.HegelInvalidArgument, gen.Grammar.init(std.testing.allocator, "start: undefined_rule", .{ .diagnostic = &w }));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "undefined_rule") != null);
}

test "grammar alphabets restrict regex terminals" {
    var grammar = try gen.Grammar.init(std.testing.allocator,
        \\start: WORD
        \\WORD: /.+/
    , .{ .alphabet = gen.text(.{ .codec = "ascii", .min_codepoint = 'a', .max_codepoint = 'c' }), .max_size = 8 });
    defer grammar.deinit();
    try hegel.checkWithContext(fast, &grammar, struct {
        fn property(g: *gen.Grammar, tc: *TestCase) !void {
            const s = try tc.draw(gen.fromGrammar(g, .{}));
            try tc.expect(s.len >= 1 and s.len <= 8);
            for (s) |ch| try tc.expect(ch >= 'a' and ch <= 'c');
        }
    }.property);
}

test "grammar explicit terminals become placeholders" {
    var grammar = try gen.Grammar.init(std.testing.allocator,
        \\start: "x" NAME "y"
        \\%declare NAME
    , .{ .explicit = &.{"NAME"} });
    defer grammar.deinit();
    const marker = try grammar.placeholder("NAME");
    try std.testing.expect(marker.len > 0);
    try std.testing.expectError(error.HegelInvalidArgument, grammar.placeholder("OTHER"));
}

test "tuples, arrays and permutations" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const t = try tc.draw(gen.tuples(.{ gen.integers(u8, .{ .max = 9 }), gen.booleans(), gen.text(.{ .max_size = 3 }) }));
            try tc.expect(t[0] <= 9);
            _ = t[1];
            try tc.expect(t[2].len <= 12);
            const a = try tc.draw(gen.arrays(gen.integers(i16, .{ .min = -1, .max = 1 }), 4));
            for (a) |x| try tc.expect(x >= -1 and x <= 1);
            const items = [_]u8{ 1, 2, 3, 4, 5 };
            const p = try tc.draw(gen.permutations(u8, &items));
            const sorted = p;
            std.mem.sort(u8, sorted, {}, std.sort.asc(u8));
            try tc.expectEqualSlices(u8, &items, sorted);
        }
    }.property);
}

test "unique lists, hash maps and hash sets have distinct keys" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const xs = try tc.draw(gen.uniqueLists(gen.integers(u8, .{ .max = 20 }), .{ .min_size = 3, .max_size = 10 }));
            try tc.expect(xs.len >= 3 and xs.len <= 10);
            for (xs, 0..) |x, i| for (xs[i + 1 ..]) |y| try tc.expect(x != y);
            const words = try tc.draw(gen.uniqueLists(gen.text(.{ .max_size = 2, .codec = "ascii" }), .{ .min_size = 2 }));
            for (words, 0..) |x, i| for (words[i + 1 ..]) |y| try tc.expect(!std.mem.eql(u8, x, y));
            const m = try tc.draw(gen.hashMaps(gen.integers(u8, .{ .max = 5 }), gen.booleans(), .{ .min_size = 2, .max_size = 6 }));
            try tc.expect(m.count() >= 2 and m.count() <= 6);
            const sm = try tc.draw(gen.hashMaps(gen.text(.{ .max_size = 3 }), gen.integers(i32, .{}), .{}));
            _ = sm.count();
            const set = try tc.draw(gen.hashSets(gen.integers(u4, .{}), .{ .min_size = 16 }));
            try tc.expectEqual(@as(usize, 16), set.count());
        }
    }.property);
}

fn sizedList(n: u8) gen.Lists(gen.Integers(u8)) {
    return gen.lists(gen.integers(u8, .{}), .{ .min_size = n, .max_size = n });
}

fn evenSum(tc: *TestCase) hegel.DrawError!struct { u32, u32 } {
    const a = try tc.draw(gen.integers(u32, .{ .max = 1000 }));
    const b = try tc.draw(gen.integers(u32, .{ .max = 1000 }));
    return .{ a, if ((a + b) % 2 == 0) b else b + 1 };
}

test "flatMap and composite draw dependent values" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const xs = try tc.draw(gen.flatMap(gen.integers(u8, .{ .max = 8 }), sizedList));
            try tc.expect(xs.len <= 8);
            const pair = try tc.draw(gen.composite(struct { u32, u32 }, evenSum));
            try tc.expectEqual(@as(u32, 0), (pair[0] + pair[1]) % 2);
        }
    }.property);
}

const Tree = union(enum) {
    leaf: u8,
    node: []const Tree,

    fn depth(t: Tree) usize {
        return switch (t) {
            .leaf => 0,
            .node => |kids| blk: {
                var d: usize = 0;
                for (kids) |k| d = @max(d, k.depth());
                break :blk d + 1;
            },
        };
    }

    fn leaves(t: Tree) usize {
        return switch (t) {
            .leaf => 1,
            .node => |kids| blk: {
                var n: usize = 0;
                for (kids) |k| n += k.leaves();
                break :blk n;
            },
        };
    }
};

fn leafOf(x: u8) Tree {
    return .{ .leaf = x };
}

fn extendTree(tc: *TestCase, child: anytype) hegel.DrawError!Tree {
    const kids = try tc.draw(gen.lists(child, .{ .min_size = 1, .max_size = 3 }));
    return .{ .node = kids };
}

test "recursive generators respect depth and leaf budgets" {
    const Seen = struct { max_depth: usize = 0 };
    var seen: Seen = .{};
    try hegel.checkWithContext(.{ .test_cases = 200, .database = "", .derandomize = true }, &seen, struct {
        fn property(s: *Seen, tc: *TestCase) !void {
            const t = try tc.draw(gen.recursive(Tree, gen.map(gen.integers(u8, .{}), leafOf), extendTree, .{ .max_depth = 3, .max_leaves = 10 }));
            try tc.expect(t.depth() <= 3);
            try tc.expect(t.leaves() >= 1 and t.leaves() <= 10);
            s.max_depth = @max(s.max_depth, t.depth());
        }
    }.property);
    try std.testing.expect(seen.max_depth >= 1);
}

test "recursive counterexamples shrink" {
    var result = try hegel.run(std.testing.allocator, fast, struct {
        fn property(tc: *TestCase) !void {
            const t = try tc.draw(gen.recursive(Tree, gen.map(gen.integers(u8, .{}), leafOf), extendTree, .{}));
            if (t.leaves() >= 3) return error.TooManyLeaves;
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(!result.passed());
    try std.testing.expectEqual(@as(usize, 1), result.failures.len);
}

const Color = enum { red, green, blue };
const Shape = union(enum) { circle: f32, square: u16, none };
const Record = struct {
    id: u32,
    ok: bool,
    color: Color,
    name: []const u8,
    tags: []const i8,
    pos: [2]i16,
    parent: ?u64,
    shape: Shape,
};

test "default derives generators from types" {
    const Seen = struct { colors: [3]bool = @splat(false) };
    var seen: Seen = .{};
    try hegel.checkWithContext(fast, &seen, struct {
        fn property(s: *Seen, tc: *TestCase) !void {
            const r = try tc.draw(gen.default(Record));
            s.colors[@backingInt(r.color)] = true;
            try tc.expect(std.unicode.utf8ValidateSlice(r.name));
            try tc.expect(r.tags.len <= 32);
            _ = r.shape;
        }
    }.property);
    try std.testing.expect(seen.colors[0] and seen.colors[1] and seen.colors[2]);
}

test "weighted booleans follow their probability at the extremes" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            try tc.expect(try tc.draw(gen.weightedBooleans(1.0)));
            try tc.expect(!try tc.draw(gen.weightedBooleans(0.0)));
        }
    }.property);
}
