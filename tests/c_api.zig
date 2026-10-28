//! Settings, run results, test-case handles, state machines, the printer
//! and blob replay, each exercised against the real engine.

const std = @import("std");
const hegel = @import("hegel");
const gen = hegel.gen;
const TestCase = hegel.TestCase;
const gpa = std.testing.allocator;

const fast: hegel.Settings = .{ .test_cases = 100, .database = "", .derandomize = true };

const Lines = struct {
    buf: std.ArrayList(u8) = .empty,

    fn sink(self: *Lines) hegel.OutputSink {
        return .{ .context = self, .writeLine = writeLine };
    }

    fn writeLine(ctx: ?*anyopaque, line: []const u8) void {
        const self: *Lines = @ptrCast(@alignCast(ctx.?));
        self.buf.appendSlice(gpa, line) catch {};
        self.buf.append(gpa, '\n') catch {};
    }

    fn contains(self: Lines, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.buf.items, needle) != null;
    }

    fn deinit(self: *Lines) void {
        self.buf.deinit(gpa);
    }
};

test "settings round-trip through the engine" {
    const r = try hegel.resolveSettings(gpa, .{
        .test_cases = 7,
        .seed = 42,
        .derandomize = true,
        .database = "",
        .verbosity = .quiet,
        .report_multiple_failures = false,
        .stop_on_first_failure = true,
        .print_blob = false,
        .backend = .urandom,
        .nondeterminism_strictness = .warn,
        .show_statistics = true,
        .unbounded_choices = true,
        .phases = .{ .shrink = false, .target = false },
        .suppress_health_check = .{ .too_slow = true },
        .test_location = .fromSource(@src()),
    });
    defer if (r.database) |d| gpa.free(d);
    try std.testing.expectEqual(@as(u64, 7), r.test_cases);
    try std.testing.expectEqual(@as(?u64, 42), r.seed);
    try std.testing.expect(r.derandomize);
    try std.testing.expectEqualStrings("", r.database.?);
    try std.testing.expectEqual(hegel.Verbosity.quiet, r.verbosity);
    try std.testing.expect(!r.report_multiple_failures and r.stop_on_first_failure and !r.print_blob);
    try std.testing.expectEqual(hegel.Backend.urandom, r.backend);
    try std.testing.expectEqual(hegel.NondeterminismStrictness.warn, r.nondeterminism_strictness);
    try std.testing.expect(r.show_statistics and r.unbounded_choices);
    try std.testing.expect(r.phases.generate and r.phases.reuse and !r.phases.shrink and !r.phases.target);
    try std.testing.expectEqual(hegel.HealthChecks{ .too_slow = true }, r.suppress_health_check);
}

test "default settings resolve" {
    const r = try hegel.resolveSettings(gpa, .{});
    defer if (r.database) |d| gpa.free(d);
    try std.testing.expect(r.test_cases > 0);
    try std.testing.expectEqual(hegel.Phases.all, r.phases);
    try std.testing.expectEqual(hegel.Backend.default, r.backend);
}

test "registered profiles are snapshots usable by name and as the default" {
    try hegel.registerProfile("hegel-zig-test", .{ .test_cases = 13, .show_statistics = true });
    const r = try hegel.resolveSettings(gpa, .{ .profile = "hegel-zig-test" });
    defer if (r.database) |d| gpa.free(d);
    try std.testing.expectEqual(@as(u64, 13), r.test_cases);
    try std.testing.expect(r.show_statistics);

    const before = try hegel.resolveSettings(gpa, .{});
    defer if (before.database) |d| gpa.free(d);
    try hegel.registerProfile("hegel-zig-baseline", .{});
    try hegel.setDefaultProfile("hegel-zig-baseline");
    const after = try hegel.resolveSettings(gpa, .{});
    defer if (after.database) |d| gpa.free(d);
    try std.testing.expectEqual(before.test_cases, after.test_cases);

    try std.testing.expectError(error.HegelInvalidArgument, hegel.setDefaultProfile("default"));
    try std.testing.expectError(error.HegelInvalidArgument, hegel.registerProfile("", .{}));
    try std.testing.expectError(error.HegelInvalidArgument, hegel.setUnicodeVersion("not a version"));
}

fn rejectEverything(tc: *TestCase) !void {
    const x = try tc.draw(gen.integers(u32, .{}));
    try tc.assume(x == 12345678);
}

test "health check failures report their kind" {
    var result = try hegel.run(gpa, .{ .test_cases = 100, .database = "", .derandomize = true }, rejectEverything);
    defer result.deinit();
    try std.testing.expectEqual(hegel.Status.errored, result.status);
    try std.testing.expectEqual(hegel.RunErrorKind.health_check, result.error_kind);
    try std.testing.expect(result.failed_health_check.filter_too_much);
}

test "suppressing the health check turns it into unsatisfiable" {
    var result = try hegel.run(gpa, .{ .test_cases = 100, .database = "", .derandomize = true, .suppress_health_check = .all }, rejectEverything);
    defer result.deinit();
    try std.testing.expectEqual(hegel.Status.errored, result.status);
    try std.testing.expect(result.error_kind != .health_check);
    try std.testing.expect(result.error_kind != .none);
}

test "phases without generate run no test cases" {
    var result = try hegel.run(gpa, .{ .test_cases = 100, .database = "", .phases = .{ .generate = false } }, struct {
        fn property(tc: *TestCase) !void {
            _ = try tc.draw(gen.booleans());
            return error.ShouldNotRun;
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(result.passed());
    try std.testing.expectEqual(@as(usize, 0), result.valid_test_cases);
}

test "statistics report events and event values" {
    var lines: Lines = .{};
    defer lines.deinit();
    var settings = fast;
    settings.show_statistics = true;
    settings.output = lines.sink();
    var result = try hegel.run(gpa, settings, struct {
        fn property(tc: *TestCase) !void {
            const x = try tc.draw(gen.integers(u8, .{}));
            try tc.event(if (x % 2 == 0) "even" else "odd");
            try tc.eventValue(@floatFromInt(x), "x-value");
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(result.passed());
    try std.testing.expect(lines.contains("even"));
    try std.testing.expect(lines.contains("x-value"));
}

test "event values reject non-finite observations" {
    var result = try hegel.run(gpa, fast, struct {
        fn property(tc: *TestCase) !void {
            try tc.eventValue(std.math.nan(f64), "bad");
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(!result.passed());
}

test "urandom backend, unbounded choices and test location run" {
    try hegel.check(.{
        .test_cases = 50,
        .database = "",
        .backend = .urandom,
        .unbounded_choices = true,
        .nondeterminism_strictness = .@"error",
        .test_location = .fromSource(@src()),
    }, struct {
        fn property(tc: *TestCase) !void {
            const xs = try tc.draw(gen.lists(gen.integers(u8, .{}), .{}));
            try tc.expect(xs.len <= 32);
        }
    }.property);
}

var flaky_calls: u32 = 0;

test "nondeterminism under error strictness errors the run" {
    flaky_calls = 0;
    var result = try hegel.run(gpa, .{ .test_cases = 100, .database = "", .derandomize = true, .nondeterminism_strictness = .@"error" }, struct {
        fn property(tc: *TestCase) !void {
            _ = try tc.draw(gen.integers(u8, .{}));
            flaky_calls += 1;
            if (flaky_calls % 3 == 0) return error.Flaky;
        }
    }.property);
    defer result.deinit();
    try std.testing.expectEqual(hegel.Status.errored, result.status);
    try std.testing.expect(result.error_kind == .flaky or result.error_kind == .nondeterministic);
}

test "clones draw independently and blocks share the choice sequence" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            var worker = try tc.clone();
            defer worker.deinit();
            try worker.setWorker(1);
            const a = try worker.draw(gen.integers(u8, .{ .max = 10 }));
            try tc.expect(a <= 10);
            var indented = try tc.block(2);
            defer indented.deinit();
            const b = try indented.draw(gen.integers(u8, .{ .max = 10 }));
            try tc.expect(b <= 10);
            try indented.noteLine("inside block");
            try tc.noteLine("outside block");
            const ls = [_]u64{ try tc.label("a"), try tc.label("b") };
            const ab = try tc.labelCombine(&ls);
            const ba = try tc.labelCombine(&.{ ls[1], ls[0] });
            try tc.expect(ab != ba);
            try tc.expect(try tc.labelCombine(ls[0..1]) != ls[0]);
        }
    }.property);
}

test "clones are driven from parallel threads" {
    try hegel.check(fast, struct {
        fn worker(handle: *TestCase, sum: *std.atomic.Value(u64), failed: *std.atomic.Value(bool)) void {
            const xs = handle.draw(gen.lists(gen.integers(u8, .{ .max = 100 }), .{ .max_size = 8 })) catch {
                failed.store(true, .seq_cst);
                return;
            };
            for (xs) |x| {
                if (x > 100) failed.store(true, .seq_cst);
                _ = sum.fetchAdd(x, .seq_cst);
            }
            handle.noteLine("worker done") catch failed.store(true, .seq_cst);
        }

        fn property(tc: *TestCase) !void {
            var handles: [4]TestCase = undefined;
            var made: usize = 0;
            defer for (handles[0..made]) |*h| h.deinit();
            while (made < handles.len) : (made += 1) {
                handles[made] = try tc.clone();
                try handles[made].setWorker(@intCast(made));
            }
            var sum: std.atomic.Value(u64) = .init(0);
            var failed: std.atomic.Value(bool) = .init(false);
            var threads: [4]std.Thread = undefined;
            for (&threads, &handles) |*t, *h| t.* = try std.Thread.spawn(.{}, worker, .{ h, &sum, &failed });
            for (threads) |t| t.join();
            try tc.expect(!failed.load(.seq_cst));
            try tc.expect(sum.load(.seq_cst) <= 4 * 8 * 100);
        }
    }.property);
}

test "engine notes and test-case printer output reach the failure report" {
    var result = try hegel.run(gpa, fast, struct {
        fn property(tc: *TestCase) !void {
            const x = try tc.draw(gen.integers(u8, .{}));
            try tc.noteLine("engine note");
            var p = try tc.printer(.{ .max_width = 40 });
            defer p.deinit();
            try p.text("printed via hegel_printer");
            try p.hardBreak();
            var worker = try tc.clone();
            defer worker.deinit();
            try worker.setWorker(3);
            try worker.noteLine("from worker");
            if (x > 3) return error.Big;
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(!result.passed());
    const report = result.failures[0].report;
    try std.testing.expect(std.mem.indexOf(u8, report, "engine note") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "printed via hegel_printer") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "[worker 3") != null);
}

fn render(width: u64, comptime build: fn (hegel.Printer) hegel.PrinterError!void) ![]u8 {
    var p = try hegel.Printer.init(.{ .max_width = width });
    defer p.deinit();
    try build(p);
    return p.value(gpa);
}

fn list(p: hegel.Printer) hegel.PrinterError!void {
    try p.beginGroup(4, "[");
    try p.breakable("");
    for ([_][]const u8{ "alpha", "beta", "gamma" }, 0..) |item, i| {
        if (i > 0) {
            try p.text(",");
            try p.breakable(" ");
        }
        try p.text(item);
    }
    try p.ifBreak(",");
    try p.shiftIndent(-4);
    try p.breakable("");
    try p.shiftIndent(4);
    try p.endGroup("]");
}

test "printer groups fit on one line or break everywhere" {
    const wide = try render(80, list);
    defer gpa.free(wide);
    try std.testing.expectEqualStrings("[alpha, beta, gamma]", wide);
    const narrow = try render(10, list);
    defer gpa.free(narrow);
    try std.testing.expectEqualStrings("[\n    alpha,\n    beta,\n    gamma,\n]", narrow);
}

test "printer comments, reflow, deferred holes and speculation" {
    var p = try hegel.Printer.init(.{ .max_width = 20 });
    defer p.deinit();
    try p.text("head");
    var hole = try p.deferred();
    defer hole.deinit();
    try p.text(" tail");
    try p.comment(" // note");
    try p.hardBreak();
    try p.beginSpeculative();
    try p.text("dropped");
    try p.abortSpeculative();
    try p.beginSpeculative();
    try p.text("kept");
    try p.commitSpeculative();
    try p.hardBreak();
    try p.reflow("Point{x: 1, ys: [10, 20, 30]}");
    try hole.text("<filled>");
    try std.testing.expect(try hole.isLive());
    try std.testing.expectError(error.HegelInvalidArgument, p.text("bad\nnewline"));
    try std.testing.expectError(error.HegelInvalidArgument, p.commitSpeculative());
    try p.resolve();
    try std.testing.expect(!try hole.isLive());
    try std.testing.expectError(error.HegelInvalidHandle, hole.text("late"));
    const out = try p.value(gpa);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "head<filled> tail // note\nkept\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "dropped") == null);
    const reflowed = out[std.mem.indexOf(u8, out, "kept\n").? + 5 ..];
    try std.testing.expect(std.mem.indexOfScalar(u8, reflowed, '\n') != null);
    var it = std.mem.splitScalar(u8, reflowed, '\n');
    while (it.next()) |line| try std.testing.expect(line.len <= 20);
    try std.testing.expectError(error.HegelInvalidArgument, hegel.Printer.init(.{ .max_width = 0 }));
}

test "pool restore puts consumed variables back" {
    try hegel.check(fast, struct {
        fn property(tc: *TestCase) !void {
            const pool = try tc.pool();
            defer pool.deinit();
            const id = try pool.add();
            const got = try pool.generate(true);
            try tc.expectEqual(id, got);
            try pool.restore(got);
            try tc.expectEqual(id, try pool.generate(false));
            try std.testing.expectError(error.HegelInvalidArgument, pool.restore(id + 1000));
        }
    }.property);
}

const Counter = struct {
    value: std.atomic.Value(i64) = .init(0),
    invariant_checks: u32 = 0,
    rounds: u32 = 0,
    max_concurrency: u32 = 0,
};

test "state machines with groups, weights, invariants and concurrent workers" {
    var counter: Counter = .{};
    try hegel.checkWithContext(fast, &counter, struct {
        fn property(stats: *Counter, tc: *TestCase) !void {
            var model: std.atomic.Value(i64) = .init(0);
            var sm = try tc.stateMachineWith(.{
                .rules = &.{
                    .{ .name = "inc", .group = 1, .weight = 2.0 },
                    .{ .name = "dec_if_positive", .group = 1 },
                    .{ .name = "read", .group = 2 },
                },
                .invariants = &.{
                    .{ .name = "non_negative", .always_check = true },
                    .{ .name = "sampled" },
                },
                .min_concurrency = 1,
                .max_concurrency = 3,
                .step_count = 20,
            });
            defer sm.deinit();
            stats.max_concurrency = @max(stats.max_concurrency, sm.concurrency);
            try tc.expect(sm.concurrency >= 1 and sm.concurrency <= 3);
            while (try sm.nextGroup()) |group| {
                stats.rounds += 1;
                try tc.expect(group == 1 or group == 2);
                for (0..sm.concurrency) |w| {
                    var worker = try tc.clone();
                    defer worker.deinit();
                    try worker.setWorker(@intCast(w));
                    while (try sm.nextRuleFor(&worker, @intCast(w))) |rule| switch (rule) {
                        0 => _ = model.fetchAdd(1, .seq_cst),
                        1 => if (model.load(.seq_cst) > 0) {
                            _ = model.fetchSub(1, .seq_cst);
                        } else try sm.rejectFor(&worker, @intCast(w)),
                        2 => try tc.expect(group == 2),
                        else => return error.UnknownRule,
                    };
                }
                if (try sm.shouldCheckInvariant(0)) {
                    stats.invariant_checks += 1;
                    try tc.expect(model.load(.seq_cst) >= 0);
                }
                _ = try sm.shouldCheckInvariant(1);
            }
            try std.testing.expectError(error.HegelInvalidArgument, sm.shouldCheckInvariant(5));
        }
    }.property);
    try std.testing.expect(counter.rounds > 0 and counter.invariant_checks > 0);
    try std.testing.expect(counter.max_concurrency > 1);
}

test "state machine creation validates its options" {
    var result = try hegel.run(gpa, fast, struct {
        fn property(tc: *TestCase) !void {
            _ = try tc.stateMachineWith(.{ .rules = &.{.{ .name = "r", .weight = -1 }} });
        }
    }.property);
    defer result.deinit();
    try std.testing.expect(!result.passed());
}

fn failsAboveTen(tc: *TestCase) !void {
    if (try tc.draw(gen.integers(u32, .{})) > 10) return error.TooBig;
}

fn alwaysPasses(tc: *TestCase) !void {
    _ = try tc.draw(gen.integers(u32, .{}));
}

test "replay runs a blob once and reports whether it reproduced" {
    var result = try hegel.run(gpa, fast, failsAboveTen);
    defer result.deinit();
    const blob = result.failures[0].reproduction_blob.?;
    try std.testing.expectEqual(hegel.ReplayOutcome.reproduced, try hegel.replay(fast, blob, failsAboveTen));
    try std.testing.expectEqual(hegel.ReplayOutcome.passed, try hegel.replay(fast, blob, alwaysPasses));
    try std.testing.expectError(error.HegelInvalidArgument, hegel.replay(fast, "not a blob", alwaysPasses));
}
