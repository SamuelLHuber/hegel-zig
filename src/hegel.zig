//! Property-based testing for Zig, powered by libhegel.
//!
//! libhegel does all of the generation, shrinking and run scheduling; this
//! module is a thin, idiomatic layer over its C ABI. The raw C API is
//! re-exported as `hegel.c` for anything this layer does not cover.
//!
//! ```zig
//! test "addition commutes" {
//!     try hegel.check(.{}, struct {
//!         fn property(tc: *hegel.TestCase) !void {
//!             const a = try tc.draw(hegel.gen.integers(i32, .{}));
//!             const b = try tc.draw(hegel.gen.integers(i32, .{}));
//!             try tc.expectEqual(a +% b, b +% a);
//!         }
//!     }.property);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// The raw libhegel C API, translated from `include/hegel.h`.
pub const c = @import("hegel_c");

pub const gen = @import("gen.zig");

/// Errors a draw can return. `HegelStopTest` and `HegelAssume` are control
/// flow for the engine and must be propagated out of the property with `try`.
pub const DrawError = error{
    /// The engine ran out of choices for this test case; it is discarded.
    HegelStopTest,
    /// The test case was rejected by `assume` or a filter; it is discarded.
    HegelAssume,
    /// A recursive generation attempt outgrew its leaf budget and must be
    /// unwound to the enclosing `gen.recursive` (see `Recursion`).
    HegelRetry,
    /// libhegel rejected an argument (see the failure report for details).
    HegelInvalidArgument,
    /// libhegel returned an unexpected error.
    HegelEngine,
    OutOfMemory,
};

/// Errors returned by `check` when the property does not hold.
pub const CheckError = error{ HegelPropertyFailed, HegelRunError };

pub const Verbosity = enum(u32) {
    normal = c.HEGEL_VERBOSITY_NORMAL,
    quiet = c.HEGEL_VERBOSITY_QUIET,
    verbose = c.HEGEL_VERBOSITY_VERBOSE,
    debug = c.HEGEL_VERBOSITY_DEBUG,
};

/// Receives each line of engine output instead of stderr.
pub const OutputSink = struct {
    context: ?*anyopaque,
    writeLine: *const fn (context: ?*anyopaque, line: []const u8) void,
};

/// Run settings. `null` leaves the engine default (which also honours
/// `HEGEL_*` environment variables and `hegel.toml` profiles).
pub const Settings = struct {
    test_cases: ?u64 = null,
    seed: ?u64 = null,
    derandomize: ?bool = null,
    /// Example-database directory; `""` disables the database.
    database: ?[]const u8 = null,
    database_key: ?[]const u8 = null,
    verbosity: ?Verbosity = null,
    report_multiple_failures: ?bool = null,
    stop_on_first_failure: ?bool = null,
    print_blob: ?bool = null,
    /// Start from a named profile (see `hegel_settings_new_for_profile`).
    profile: ?[]const u8 = null,
    /// Replay a single failure from its reproduction blob.
    reproduce: ?[]const u8 = null,
    output: ?OutputSink = null,
    backend: ?Backend = null,
    nondeterminism_strictness: ?NondeterminismStrictness = null,
    /// Print event / eventValue statistics at the end of the run.
    show_statistics: ?bool = null,
    /// Let test cases make any number of choices.
    unbounded_choices: ?bool = null,
    phases: ?Phases = null,
    suppress_health_check: ?HealthChecks = null,
    /// Where the test lives; used for Antithesis assertion reporting.
    test_location: ?TestLocation = null,
};

pub const Backend = enum(u32) {
    default = c.HEGEL_BACKEND_DEFAULT,
    urandom = c.HEGEL_BACKEND_URANDOM,
};

pub const NondeterminismStrictness = enum(u32) {
    quiet = c.HEGEL_NONDETERMINISM_QUIET,
    warn = c.HEGEL_NONDETERMINISM_WARN,
    @"error" = c.HEGEL_NONDETERMINISM_ERROR,
};

pub const Phases = packed struct(u32) {
    explicit: bool = true,
    reuse: bool = true,
    generate: bool = true,
    target: bool = true,
    shrink: bool = true,
    _: u27 = 0,

    pub const all: Phases = .{};
};

pub const HealthChecks = packed struct(u32) {
    filter_too_much: bool = false,
    too_slow: bool = false,
    test_cases_too_large: bool = false,
    large_initial_test_case: bool = false,
    _: u28 = 0,

    pub const all: HealthChecks = .{ .filter_too_much = true, .too_slow = true, .test_cases_too_large = true, .large_initial_test_case = true };
};

pub const TestLocation = struct {
    file: []const u8,
    line: u32,
    class_name: []const u8,
    function: []const u8,

    pub fn fromSource(src: std.builtin.SourceLocation) TestLocation {
        return .{ .file = src.file, .line = src.line, .class_name = src.module, .function = src.fn_name };
    }
};

pub const RunErrorKind = enum(u32) {
    none = c.HEGEL_RUN_ERROR_NONE,
    health_check = c.HEGEL_RUN_ERROR_HEALTH_CHECK,
    flaky = c.HEGEL_RUN_ERROR_FLAKY,
    nondeterministic = c.HEGEL_RUN_ERROR_NONDETERMINISTIC,
    unsatisfiable = c.HEGEL_RUN_ERROR_UNSATISFIABLE,
    usage = c.HEGEL_RUN_ERROR_USAGE,
    internal = c.HEGEL_RUN_ERROR_INTERNAL,
    _,
};

/// The effective configuration of a settings value after profiles,
/// `hegel.toml` and `HEGEL_*` environment variables are applied.
pub const ResolvedSettings = struct {
    test_cases: u64,
    verbosity: Verbosity,
    seed: ?u64,
    derandomize: bool,
    /// `null`: the default database; `""`: disabled. Owned by the caller's allocator.
    database: ?[]const u8,
    phases: Phases,
    suppress_health_check: HealthChecks,
    report_multiple_failures: bool,
    stop_on_first_failure: bool,
    show_statistics: bool,
    unbounded_choices: bool,
    print_blob: bool,
    backend: Backend,
    nondeterminism_strictness: NondeterminismStrictness,
};

/// Reads back what `settings` resolves to.
pub fn resolveSettings(gpa: Allocator, settings: Settings) !ResolvedSettings {
    const ctx = c.hegel_context_new().?;
    defer _ = c.hegel_context_free(ctx);
    const h = try buildSettings(ctx, settings);
    defer _ = c.hegel_settings_free(ctx, h);
    var r: ResolvedSettings = undefined;
    try ensure(ctx, c.hegel_settings_get_test_cases(ctx, h, &r.test_cases));
    var verbosity: c.hegel_verbosity_t = undefined;
    try ensure(ctx, c.hegel_settings_get_verbosity(ctx, h, &verbosity));
    r.verbosity = @fromBackingInt(@intCast(verbosity));
    var seed: u64 = 0;
    var has_seed = false;
    try ensure(ctx, c.hegel_settings_get_seed(ctx, h, &seed, &has_seed));
    r.seed = if (has_seed) seed else null;
    try ensure(ctx, c.hegel_settings_get_derandomize(ctx, h, &r.derandomize));
    var db: [*c]const c.hegel_string_t = null;
    try ensure(ctx, c.hegel_settings_get_database(ctx, h, &db));
    r.database = if (db != null) try gpa.dupe(u8, slice(db.*)) else null;
    var bits: u32 = 0;
    try ensure(ctx, c.hegel_settings_get_phases(ctx, h, &bits));
    r.phases = @bitCast(bits);
    try ensure(ctx, c.hegel_settings_get_suppress_health_check(ctx, h, &bits));
    r.suppress_health_check = @bitCast(bits);
    try ensure(ctx, c.hegel_settings_get_report_multiple_failures(ctx, h, &r.report_multiple_failures));
    try ensure(ctx, c.hegel_settings_get_stop_on_first_failure(ctx, h, &r.stop_on_first_failure));
    try ensure(ctx, c.hegel_settings_get_show_statistics(ctx, h, &r.show_statistics));
    try ensure(ctx, c.hegel_settings_get_unbounded_choices(ctx, h, &r.unbounded_choices));
    try ensure(ctx, c.hegel_settings_get_print_blob(ctx, h, &r.print_blob));
    var backend: c.hegel_backend_t = undefined;
    try ensure(ctx, c.hegel_settings_get_backend(ctx, h, &backend));
    r.backend = @fromBackingInt(@intCast(backend));
    var strictness: c.hegel_nondeterminism_strictness_t = undefined;
    try ensure(ctx, c.hegel_settings_get_nondeterminism_strictness(ctx, h, &strictness));
    r.nondeterminism_strictness = @fromBackingInt(@intCast(strictness));
    return r;
}

/// Registers `settings` as the process-wide profile `name`.
pub fn registerProfile(name: []const u8, settings: Settings) !void {
    const ctx = c.hegel_context_new().?;
    defer _ = c.hegel_context_free(ctx);
    const h = try buildSettings(ctx, settings);
    defer _ = c.hegel_settings_free(ctx, h);
    try ensure(ctx, c.hegel_settings_register_profile(ctx, str(name), h));
}

/// Makes `name` the default profile for every later run in the process.
pub fn setDefaultProfile(name: []const u8) !void {
    const ctx = c.hegel_context_new().?;
    defer _ = c.hegel_context_free(ctx);
    try ensure(ctx, c.hegel_set_default_profile(ctx, str(name)));
}

/// Pins the Unicode version text generation uses (call once, at startup).
pub fn setUnicodeVersion(unicode_version: []const u8) !void {
    const ctx = c.hegel_context_new().?;
    defer _ = c.hegel_context_free(ctx);
    try ensure(ctx, c.hegel_set_unicode_version(ctx, str(unicode_version)));
}

pub const Status = enum { passed, failed, errored };

pub const Failure = struct {
    origin: []const u8,
    /// The draws, notes and error of the shrunk counterexample.
    report: []const u8,
    reproduction_blob: ?[]const u8,
    caveat: ?[]const u8,
};

pub const RunResult = struct {
    arena: std.heap.ArenaAllocator,
    status: Status,
    failures: []const Failure,
    error_message: ?[]const u8,
    error_kind: RunErrorKind = .none,
    /// Set when `error_kind == .health_check`.
    failed_health_check: HealthChecks = .{},
    valid_test_cases: usize,

    pub fn deinit(self: *RunResult) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn passed(self: RunResult) bool {
        return self.status == .passed;
    }

    pub fn writeReport(self: RunResult, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.status) {
            .passed => try w.print("Property passed ({d} valid test cases)\n", .{self.valid_test_cases}),
            .errored => try w.print("Hegel run error ({t}): {s}\n", .{ self.error_kind, self.error_message orelse "unknown error" }),
            .failed => for (self.failures, 0..) |f, i| {
                try w.print("Property failed (failure {d} of {d}, origin: {s})\n", .{ i + 1, self.failures.len, f.origin });
                try w.writeAll(f.report);
                if (f.caveat) |cv| try w.print("Caveat: {s}\n", .{cv});
                if (f.reproduction_blob) |blob| try w.print("Reproduce with: .reproduce = \"{s}\"\n", .{blob});
            },
        }
    }
};

/// One generated test case. Draw values with `draw`; everything allocated
/// through `allocator()` lives until the test case completes.
pub const TestCase = struct {
    ctx: *c.hegel_context_t,
    raw: *c.hegel_test_case_t,
    arena: Allocator,
    capture: bool,
    depth: u32 = 0,
    draws: u32 = 0,
    output: std.ArrayList(u8) = .empty,
    message: ?[]const u8 = null,
    /// Set on handles from `clone` / `block`, which `deinit` releases.
    owned: bool = false,

    pub fn allocator(tc: *TestCase) Allocator {
        return tc.arena;
    }

    /// Draws a value from `generator` (see `hegel.gen`). Top-level draws are
    /// recorded and shown in the failure report.
    pub fn draw(tc: *TestCase, generator: anytype) DrawError!@TypeOf(generator).Value {
        const G = @TypeOf(generator);
        tc.depth += 1;
        const value = generator.generate(tc) catch |err| {
            tc.depth -= 1;
            return err;
        };
        tc.depth -= 1;
        if (tc.depth == 0 and tc.capture) {
            tc.draws += 1;
            if (G.Value == []const u8) {
                tc.record("Draw {d}: \"{f}\"", .{ tc.draws, std.zig.fmtString(value) });
            } else {
                tc.record("Draw {d}: {any}", .{ tc.draws, value });
            }
        }
        return value;
    }

    /// Rejects the test case unless `condition` holds.
    pub fn assume(tc: *TestCase, condition: bool) DrawError!void {
        _ = tc;
        if (!condition) return error.HegelAssume;
    }

    /// Adds a line to the failure report of this test case.
    pub fn note(tc: *TestCase, comptime fmt: []const u8, args: anytype) void {
        tc.record(fmt, args);
    }

    /// Fails the property with a formatted message.
    pub fn fail(tc: *TestCase, comptime fmt: []const u8, args: anytype) error{HegelPropertyFailed} {
        if (tc.capture) tc.message = std.fmt.allocPrint(tc.arena, fmt, args) catch null;
        return error.HegelPropertyFailed;
    }

    pub fn expect(tc: *TestCase, ok: bool) error{HegelPropertyFailed}!void {
        if (!ok) return tc.fail("expectation failed", .{});
    }

    /// Like `std.testing.expectEqual`, but only prints in the final report
    /// instead of on every shrink attempt.
    pub fn expectEqual(tc: *TestCase, expected: anytype, actual: @TypeOf(expected)) error{HegelPropertyFailed}!void {
        if (!std.meta.eql(expected, actual)) return tc.fail("expected {any}, found {any}", .{ expected, actual });
    }

    pub fn expectEqualSlices(tc: *TestCase, comptime T: type, expected: []const T, actual: []const T) error{HegelPropertyFailed}!void {
        if (!std.mem.eql(T, expected, actual)) return tc.fail("expected {any}, found {any}", .{ expected, actual });
    }

    /// Guides the search towards larger values of `value`.
    pub fn target(tc: *TestCase, value: f64, name: []const u8) DrawError!void {
        try tc.wrap(c.hegel_target(tc.ctx, tc.raw, value, str(name)));
    }

    /// Records an event for the run statistics.
    /// Records a numeric observation, summarised when `show_statistics` is on.
    pub fn eventValue(tc: *TestCase, value: f64, name: []const u8) DrawError!void {
        try tc.wrap(c.hegel_event_value(tc.ctx, tc.raw, value, str(name)));
    }

    /// Writes a line into the engine's own print region for this test case
    /// (see `printer`), as opposed to `note`, which hegel-zig reports itself.
    pub fn noteLine(tc: *TestCase, line: []const u8) DrawError!void {
        try tc.wrap(c.hegel_note(tc.ctx, tc.raw, str(line)));
    }

    /// A handle with its own choice sequence and error context, for driving
    /// from another thread. It shares `tc`'s thread-safe arena. Call `deinit`.
    pub fn clone(tc: *TestCase) DrawError!TestCase {
        var raw: ?*c.hegel_test_case_t = null;
        try tc.wrap(c.hegel_test_case_clone(tc.ctx, tc.raw, &raw));
        return tc.derived(raw.?) catch |err| {
            _ = c.hegel_test_case_free(tc.ctx, raw);
            return err;
        };
    }

    /// A handle sharing `tc`'s choices whose printed lines are indented by
    /// `indent` columns. Call `deinit`.
    pub fn block(tc: *TestCase, indent: u64) DrawError!TestCase {
        var raw: ?*c.hegel_test_case_t = null;
        try tc.wrap(c.hegel_test_case_block(tc.ctx, tc.raw, indent, &raw));
        return tc.derived(raw.?) catch |err| {
            _ = c.hegel_test_case_free(tc.ctx, raw);
            return err;
        };
    }

    /// Releases a handle returned by `clone` or `block`.
    pub fn deinit(tc: *TestCase) void {
        assert(tc.owned);
        _ = c.hegel_test_case_free(tc.ctx, tc.raw);
        _ = c.hegel_context_free(tc.ctx);
        tc.* = undefined;
    }

    /// Prefixes this handle's printed lines with `[worker N +X.XXXms]`.
    pub fn setWorker(tc: *TestCase, worker_index: u32) DrawError!void {
        try tc.wrap(c.hegel_test_case_set_worker(tc.ctx, tc.raw, worker_index));
    }

    /// The pretty-printer document for this test case's print region.
    pub fn printer(tc: *TestCase, options: PrinterOptions) (DrawError || PrinterError)!Printer {
        const opts = try options.toRaw(tc.ctx);
        defer _ = c.hegel_printer_options_free(tc.ctx, opts);
        var raw: ?*c.hegel_printer_t = null;
        try tc.wrap(c.hegel_test_case_printer(tc.ctx, tc.raw, opts, &raw));
        return .{ .ctx = tc.ctx, .raw = raw.? };
    }

    /// The span label of a generator built from others (see `label`).
    pub fn labelCombine(tc: *TestCase, labels: []const u64) DrawError!u64 {
        var out: u64 = undefined;
        try tc.wrap(c.hegel_label_combine(tc.ctx, labels.ptr, labels.len, &out));
        return out;
    }

    /// The engine's leaf/branch bookkeeping for one recursive value. Prefer
    /// `gen.recursive`, which drives it. Call `deinit`.
    pub fn recursion(tc: *TestCase, max_depth: u64, max_leaves: u64) DrawError!Recursion {
        var raw: ?*c.HegelRecursion = null;
        try tc.wrap(c.hegel_new_recursion(tc.ctx, tc.raw, max_depth, max_leaves, &raw));
        return .{ .tc = tc, .raw = raw.? };
    }

    pub fn event(tc: *TestCase, name: []const u8) DrawError!void {
        try tc.wrap(c.hegel_event(tc.ctx, tc.raw, str(name)));
    }

    pub fn boolean(tc: *TestCase, p: f64) DrawError!bool {
        var out: bool = undefined;
        try tc.wrap(c.hegel_generate_boolean(tc.ctx, tc.raw, p, false, false, &out));
        return out;
    }

    /// Draws an integer of any width in `[min, max]`.
    pub fn integer(tc: *TestCase, comptime T: type, min: T, max: T) DrawError!T {
        const info = @typeInfo(T).int;
        if (info.bits < 64 or (info.bits == 64 and info.signedness == .signed)) {
            var out: i64 = undefined;
            try tc.wrap(c.hegel_generate_integer(tc.ctx, tc.raw, min, max, &out));
            return @intCast(out);
        }
        const W = @Int(.signed, std.mem.alignForward(u16, info.bits + 1, 8));
        const n = @divExact(@bitSizeOf(W), 8);
        var lo: [n]u8 = undefined;
        var hi: [n]u8 = undefined;
        var out: [n]u8 = undefined;
        std.mem.writeInt(W, &lo, min, .little);
        std.mem.writeInt(W, &hi, max, .little);
        var out_len: usize = 0;
        try tc.wrap(c.hegel_generate_integer_big(tc.ctx, tc.raw, &lo, n, &hi, n, &out, n, &out_len));
        return @intCast(std.mem.readInt(W, &out, .little));
    }

    pub fn float(tc: *TestCase, comptime T: type, opts: gen.Floats(T)) DrawError!T {
        if (T != f32 and T != f64) @compileError("hegel: floats support f32 and f64");
        const unbounded = opts.min == null and opts.max == null;
        var out: f64 = undefined;
        try tc.wrap(c.hegel_generate_float(
            tc.ctx,
            tc.raw,
            @bitSizeOf(T),
            opts.min orelse -std.math.inf(f64),
            opts.max orelse std.math.inf(f64),
            opts.allow_nan orelse unbounded,
            opts.allow_infinity orelse (opts.min == null or opts.max == null),
            opts.exclude_min,
            opts.exclude_max,
            std.math.floatTrueMin(T),
            &out,
        ));
        return @floatCast(out);
    }

    pub fn bytes(tc: *TestCase, min_size: u64, max_size: u64) DrawError![]u8 {
        var res: c.hegel_generate_bytes_result_t = undefined;
        try tc.wrap(c.hegel_generate_bytes(tc.ctx, tc.raw, min_size, max_size, &res));
        defer _ = c.hegel_generate_bytes_result_free(tc.ctx, &res);
        return tc.arena.dupe(u8, res.data[0..res.len]);
    }

    /// Draws a string from a libhegel string generator.
    pub fn string(tc: *TestCase, generator: *const c.hegel_string_generator_t) DrawError![]const u8 {
        var res: c.hegel_owned_string_t = undefined;
        try tc.wrap(c.hegel_generate_string(tc.ctx, tc.raw, generator, &res));
        defer _ = c.hegel_owned_string_free(tc.ctx, &res);
        return tc.arena.dupe(u8, if (res.len == 0) "" else res.data[0..res.len]);
    }

    pub fn startSpan(tc: *TestCase, span_label: u64) DrawError!void {
        try tc.wrap(c.hegel_start_span(tc.ctx, tc.raw, span_label));
    }

    pub fn stopSpan(tc: *TestCase, discard: bool) DrawError!void {
        try tc.wrap(c.hegel_stop_span(tc.ctx, tc.raw, discard));
    }

    /// An engine-sized collection: call `more` until it returns false.
    pub fn collection(tc: *TestCase, min_size: u64, max_size: u64) DrawError!Collection {
        var raw: ?*c.hegel_collection_t = null;
        try tc.wrap(c.hegel_new_collection(tc.ctx, tc.raw, min_size, max_size, &raw));
        return .{ .tc = tc, .raw = raw.? };
    }

    pub fn pool(tc: *TestCase) DrawError!Pool {
        var raw: ?*c.hegel_pool_t = null;
        try tc.wrap(c.hegel_new_pool(tc.ctx, tc.raw, &raw));
        return .{ .tc = tc, .raw = raw.? };
    }

    /// A sequential state machine (one concurrency group) over `rules`.
    pub fn stateMachine(tc: *TestCase, rules: []const []const u8, max_steps: i64) DrawError!StateMachine {
        const specs = try tc.arena.alloc(StateMachine.Rule, rules.len);
        for (rules, specs) |r, *spec| spec.* = .{ .name = r };
        return tc.stateMachineWith(.{ .rules = specs, .step_count = max_steps });
    }

    /// A state machine with rule groups, weights, invariants and concurrency.
    pub fn stateMachineWith(tc: *TestCase, options: StateMachine.Options) DrawError!StateMachine {
        const rules = options.rules;
        const names = try tc.arena.alloc(c.hegel_string_t, rules.len);
        const groups = try tc.arena.alloc(i64, rules.len);
        const weights = try tc.arena.alloc(f64, rules.len);
        for (rules, names, groups, weights) |r, *name, *group, *weight| {
            name.* = str(r.name);
            group.* = r.group;
            weight.* = r.weight;
        }
        const invariants = options.invariants;
        const inv_names = try tc.arena.alloc(c.hegel_string_t, invariants.len);
        const inv_always = try tc.arena.alloc(bool, invariants.len);
        for (invariants, inv_names, inv_always) |inv, *name, *always| {
            name.* = str(inv.name);
            always.* = inv.always_check;
        }
        var raw: ?*c.hegel_state_machine_t = null;
        var concurrency: i64 = 0;
        try tc.wrap(c.hegel_new_state_machine(
            tc.ctx,
            tc.raw,
            names.ptr,
            groups.ptr,
            weights.ptr,
            names.len,
            inv_names.ptr,
            inv_always.ptr,
            inv_names.len,
            options.min_concurrency,
            options.max_concurrency,
            options.step_count,
            &raw,
            &concurrency,
        ));
        return .{ .tc = tc, .raw = raw.?, .concurrency = @intCast(concurrency) };
    }

    pub fn label(tc: *TestCase, name: []const u8) DrawError!u64 {
        var out: u64 = undefined;
        try tc.wrap(c.hegel_label_from_name(tc.ctx, str(name), &out));
        return out;
    }

    pub fn wrap(tc: *TestCase, rc: c.hegel_result_t) DrawError!void {
        if (rc == c.HEGEL_OK) return;
        if (rc == c.HEGEL_E_STOP_TEST) return error.HegelStopTest;
        if (rc == c.HEGEL_E_ASSUME) return error.HegelAssume;
        if (rc == c.HEGEL_E_RETRY) return error.HegelRetry;
        const msg = lastError(tc.ctx);
        tc.message = std.fmt.allocPrint(tc.arena, "libhegel error {d}: {s}", .{ rc, msg }) catch null;
        return if (rc == c.HEGEL_E_INVALID_ARG) error.HegelInvalidArgument else error.HegelEngine;
    }

    /// Contexts must not be shared across threads, so each handle gets one.
    fn derived(tc: *TestCase, raw: *c.hegel_test_case_t) DrawError!TestCase {
        const ctx = c.hegel_context_new() orelse return error.OutOfMemory;
        return .{ .ctx = ctx, .raw = raw, .arena = tc.arena, .capture = tc.capture, .owned = true };
    }

    fn record(tc: *TestCase, comptime fmt: []const u8, args: anytype) void {
        if (!tc.capture) return;
        tc.output.print(tc.arena, fmt ++ "\n", args) catch {};
    }
};

pub const Collection = struct {
    tc: *TestCase,
    raw: *c.hegel_collection_t,

    pub fn more(self: Collection) DrawError!bool {
        var out: bool = undefined;
        try self.tc.wrap(c.hegel_collection_more(self.tc.ctx, self.tc.raw, self.raw, &out));
        return out;
    }

    /// Tells the engine the last element was rejected (e.g. a duplicate).
    pub fn reject(self: Collection, why: []const u8) DrawError!void {
        const s = str(why);
        try self.tc.wrap(c.hegel_collection_reject(self.tc.ctx, self.tc.raw, self.raw, &s));
    }

    pub fn deinit(self: Collection) void {
        _ = c.hegel_collection_free(self.tc.ctx, self.raw);
    }
};

/// Engine-tracked variable ids, the building block for stateful tests.
pub const Pool = struct {
    tc: *TestCase,
    raw: *c.hegel_pool_t,

    pub fn add(self: Pool) DrawError!i64 {
        var id: i64 = undefined;
        try self.tc.wrap(c.hegel_pool_add(self.tc.ctx, self.tc.raw, self.raw, &id));
        return id;
    }

    /// Draws a live variable id; `consume` removes it from the pool.
    pub fn generate(self: Pool, consume: bool) DrawError!i64 {
        var id: i64 = undefined;
        try self.tc.wrap(c.hegel_pool_generate(self.tc.ctx, self.tc.raw, self.raw, consume, &id));
        return id;
    }

    /// Puts back a variable a consuming `generate` removed, e.g. when the
    /// drawn value is discarded unused.
    pub fn restore(self: Pool, variable_id: i64) DrawError!void {
        try self.tc.wrap(c.hegel_pool_restore(self.tc.ctx, self.tc.raw, self.raw, variable_id));
    }

    pub fn deinit(self: Pool) void {
        _ = c.hegel_pool_free(self.tc.ctx, self.raw);
    }
};

pub const StateMachine = struct {
    tc: *TestCase,
    raw: *c.hegel_state_machine_t,
    /// Number of concurrent workers the engine drew for this test case.
    concurrency: u32 = 1,
    in_round: bool = false,

    pub const Rule = struct {
        name: []const u8,
        /// Rules sharing a group run in the same concurrent round.
        group: i64 = 0,
        weight: f64 = 1.0,
    };

    pub const Invariant = struct {
        name: []const u8,
        /// Check at every join point instead of sampling.
        always_check: bool = false,
    };

    pub const Options = struct {
        rules: []const Rule,
        invariants: []const Invariant = &.{},
        min_concurrency: i64 = 1,
        max_concurrency: i64 = 1,
        step_count: i64 = 50,
    };

    /// Sequential driver: the index of the next rule to apply, or null once
    /// the engine has decided the test case has run enough steps.
    pub fn nextRule(self: *StateMachine) DrawError!?usize {
        while (true) {
            if (!self.in_round) {
                _ = try self.nextGroup() orelse return null;
                self.in_round = true;
            }
            if (try self.nextRuleFor(self.tc, 0)) |rule| return rule;
            self.in_round = false;
        }
    }

    /// Tells the engine the last sequential rule's precondition did not hold.
    pub fn reject(self: StateMachine) DrawError!void {
        try self.rejectFor(self.tc, 0);
    }

    /// Starts the next round at a join point and returns its group id, or
    /// null when the machine is done. Call on the root test case.
    pub fn nextGroup(self: StateMachine) DrawError!?i64 {
        var group: i64 = undefined;
        try self.tc.wrap(c.hegel_state_machine_next_group(self.tc.ctx, self.tc.raw, self.raw, &group));
        return if (group == c.HEGEL_STATE_MACHINE_DONE) null else group;
    }

    /// The next rule for worker `worker_index` in the current round, drawn
    /// through `worker` (a `clone` of the root for concurrent workers), or
    /// null when that worker's round is over.
    pub fn nextRuleFor(self: StateMachine, worker: *TestCase, worker_index: u32) DrawError!?usize {
        var rule: i64 = undefined;
        try worker.wrap(c.hegel_state_machine_next_rule(worker.ctx, worker.raw, self.raw, worker_index, &rule));
        return if (rule == c.HEGEL_STATE_MACHINE_DONE) null else @intCast(rule);
    }

    pub fn rejectFor(self: StateMachine, worker: *TestCase, worker_index: u32) DrawError!void {
        try worker.wrap(c.hegel_state_machine_rule_rejected(worker.ctx, worker.raw, self.raw, worker_index));
    }

    /// Whether to run invariant `index` at this join point. The initial and
    /// final states should always be checked without asking.
    pub fn shouldCheckInvariant(self: StateMachine, index: usize) DrawError!bool {
        var out: bool = undefined;
        try self.tc.wrap(c.hegel_state_machine_should_check_invariant(self.tc.ctx, self.tc.raw, self.raw, @intCast(index), &out));
        return out;
    }

    pub fn deinit(self: StateMachine) void {
        _ = c.hegel_state_machine_free(self.tc.ctx, self.raw);
    }
};

/// Leaf/branch bookkeeping for a recursive value (see `gen.recursive`).
pub const Recursion = struct {
    tc: *TestCase,
    raw: *c.HegelRecursion,

    /// Whether the sub-value at `depth` should be a branch.
    pub fn branch(self: Recursion, depth: u64) DrawError!bool {
        var out: bool = undefined;
        try self.tc.wrap(c.hegel_recursion_branch(self.tc.ctx, self.tc.raw, self.raw, depth, &out));
        return out;
    }

    /// Counts a leaf; `error.HegelRetry` means unwind and call `retry`.
    pub fn leaf(self: Recursion) DrawError!void {
        try self.tc.wrap(c.hegel_recursion_leaf(self.tc.ctx, self.tc.raw, self.raw));
    }

    pub fn retry(self: Recursion) DrawError!void {
        try self.tc.wrap(c.hegel_recursion_retry(self.tc.ctx, self.tc.raw, self.raw));
    }

    /// Accepts the finished value; `error.HegelRetry` means start again
    /// from the root without calling `retry`.
    pub fn finish(self: Recursion) DrawError!void {
        try self.tc.wrap(c.hegel_recursion_finish(self.tc.ctx, self.tc.raw, self.raw));
    }

    pub fn deinit(self: Recursion) void {
        _ = c.hegel_recursion_free(self.tc.ctx, self.raw);
    }
};

pub const PrinterError = error{ HegelInvalidArgument, HegelInvalidHandle };

pub const PrinterOptions = struct {
    max_width: ?u64 = null,

    fn toRaw(self: PrinterOptions, ctx: *c.hegel_context_t) PrinterError!*c.hegel_printer_options_t {
        var raw: ?*c.hegel_printer_options_t = null;
        try printerCheck(c.hegel_printer_options_new(ctx, &raw));
        errdefer _ = c.hegel_printer_options_free(ctx, raw);
        if (self.max_width) |w| try printerCheck(c.hegel_printer_options_set_max_width(ctx, raw, w));
        return raw.?;
    }
};

/// libhegel's Wadler-style pretty printer: groups either fit on one line or
/// break at every `breakable`.
pub const Printer = struct {
    ctx: *c.hegel_context_t,
    raw: *c.hegel_printer_t,
    owned_ctx: bool = false,

    /// A standalone document. Call `deinit`.
    pub fn init(options: PrinterOptions) PrinterError!Printer {
        const ctx = c.hegel_context_new().?;
        errdefer _ = c.hegel_context_free(ctx);
        const opts = try options.toRaw(ctx);
        defer _ = c.hegel_printer_options_free(ctx, opts);
        var raw: ?*c.hegel_printer_t = null;
        try printerCheck(c.hegel_printer_new(ctx, opts, &raw));
        return .{ .ctx = ctx, .raw = raw.?, .owned_ctx = true };
    }

    pub fn deinit(self: *Printer) void {
        _ = c.hegel_printer_free(self.ctx, self.raw);
        if (self.owned_ctx) _ = c.hegel_context_free(self.ctx);
        self.* = undefined;
    }

    pub fn text(self: Printer, s: []const u8) PrinterError!void {
        try printerCheck(c.hegel_printer_text(self.ctx, self.raw, str(s)));
    }

    pub fn breakable(self: Printer, sep: []const u8) PrinterError!void {
        try printerCheck(c.hegel_printer_breakable(self.ctx, self.raw, str(sep)));
    }

    /// Text emitted only when the enclosing group breaks.
    pub fn ifBreak(self: Printer, s: []const u8) PrinterError!void {
        try printerCheck(c.hegel_printer_if_break(self.ctx, self.raw, str(s)));
    }

    pub fn comment(self: Printer, s: []const u8) PrinterError!void {
        try printerCheck(c.hegel_printer_comment(self.ctx, self.raw, str(s)));
    }

    pub fn hardBreak(self: Printer) PrinterError!void {
        try printerCheck(c.hegel_printer_hard_break(self.ctx, self.raw));
    }

    pub fn beginGroup(self: Printer, indent: u64, open: []const u8) PrinterError!void {
        try printerCheck(c.hegel_printer_begin_group(self.ctx, self.raw, indent, str(open)));
    }

    pub fn endGroup(self: Printer, close: []const u8) PrinterError!void {
        try printerCheck(c.hegel_printer_end_group(self.ctx, self.raw, str(close)));
    }

    pub fn shiftIndent(self: Printer, delta: i64) PrinterError!void {
        try printerCheck(c.hegel_printer_shift_indent(self.ctx, self.raw, delta));
    }

    /// Re-lays out a flat debug representation (e.g. `{any}` output) so its
    /// `(…)`, `[…]` and `{…}` groups break like structurally printed values.
    pub fn reflow(self: Printer, s: []const u8) PrinterError!void {
        var opts: ?*c.hegel_reflow_options_t = null;
        try printerCheck(c.hegel_reflow_options_new(self.ctx, &opts));
        defer _ = c.hegel_reflow_options_free(self.ctx, opts);
        try printerCheck(c.hegel_printer_reflow(self.ctx, self.raw, opts, str(s)));
    }

    /// A hole at the current position to fill later; `resolve` splices it in.
    /// The returned handle shares this document and must be `deinit`ed.
    pub fn deferred(self: Printer) PrinterError!Printer {
        var raw: ?*c.hegel_printer_t = null;
        try printerCheck(c.hegel_printer_deferred(self.ctx, self.raw, &raw));
        return .{ .ctx = self.ctx, .raw = raw.? };
    }

    pub fn beginSpeculative(self: Printer) PrinterError!void {
        try printerCheck(c.hegel_printer_begin_speculative(self.ctx, self.raw));
    }

    pub fn commitSpeculative(self: Printer) PrinterError!void {
        try printerCheck(c.hegel_printer_commit_speculative(self.ctx, self.raw));
    }

    pub fn abortSpeculative(self: Printer) PrinterError!void {
        try printerCheck(c.hegel_printer_abort_speculative(self.ctx, self.raw));
    }

    /// Splices in every deferred hole and seals the document.
    pub fn resolve(self: Printer) PrinterError!void {
        try printerCheck(c.hegel_printer_resolve(self.ctx, self.raw));
    }

    pub fn isLive(self: Printer) PrinterError!bool {
        var out: bool = undefined;
        try printerCheck(c.hegel_printer_is_live(self.ctx, self.raw, &out));
        return out;
    }

    /// Lays out and seals the document, returning a copy owned by `gpa`.
    pub fn value(self: Printer, gpa: Allocator) (PrinterError || Allocator.Error)![]u8 {
        var res: c.hegel_printer_value_result_t = .{ .data = null, .len = 0 };
        try printerCheck(c.hegel_printer_value(self.ctx, self.raw, &res));
        defer _ = c.hegel_printer_value_result_free(self.ctx, &res);
        return gpa.dupe(u8, if (res.len == 0) "" else res.data[0..res.len]);
    }

    /// The diagnostic for the last failed call.
    pub fn lastErrorMessage(self: Printer) []const u8 {
        return lastError(self.ctx);
    }
};

fn printerCheck(rc: c.hegel_result_t) PrinterError!void {
    if (rc == c.HEGEL_OK) return;
    return if (rc == c.HEGEL_E_INVALID_HANDLE) error.HegelInvalidHandle else error.HegelInvalidArgument;
}

pub fn str(s: []const u8) c.hegel_string_t {
    return .{ .data = if (s.len == 0) null else s.ptr, .len = s.len };
}

fn slice(s: c.hegel_string_t) []const u8 {
    return if (s.len == 0) "" else s.data[0..s.len];
}

fn lastError(ctx: *const c.hegel_context_t) []const u8 {
    return slice(c.hegel_context_last_error(ctx));
}

/// The version string of the linked libhegel.
pub fn lastErrorMessage(ctx: *const c.hegel_context_t) []const u8 {
    return lastError(ctx);
}

pub fn version() []const u8 {
    const ctx = c.hegel_context_new().?;
    defer _ = c.hegel_context_free(ctx);
    var v: c.hegel_string_t = undefined;
    if (c.hegel_version(ctx, &v) != c.HEGEL_OK) return "unknown";
    return slice(v);
}

fn ensure(ctx: *c.hegel_context_t, rc: c.hegel_result_t) error{HegelInvalidArgument}!void {
    if (rc == c.HEGEL_OK) return;
    std.log.scoped(.hegel).warn("libhegel error {d}: {s}", .{ rc, lastError(ctx) });
    return error.HegelInvalidArgument;
}

fn buildSettings(ctx: *c.hegel_context_t, s: Settings) !*c.hegel_settings_t {
    var raw: ?*c.hegel_settings_t = null;
    if (s.profile) |p| {
        try ensure(ctx, c.hegel_settings_new_for_profile(ctx, str(p), &raw));
    } else {
        try ensure(ctx, c.hegel_settings_new(ctx, &raw));
    }
    const h = raw.?;
    errdefer _ = c.hegel_settings_free(ctx, h);
    if (s.test_cases) |n| try ensure(ctx, c.hegel_settings_set_test_cases(ctx, h, n));
    if (s.seed) |seed| try ensure(ctx, c.hegel_settings_set_seed(ctx, h, seed, true));
    if (s.derandomize) |d| try ensure(ctx, c.hegel_settings_set_derandomize(ctx, h, d));
    if (s.database) |db| {
        const v = str(db);
        try ensure(ctx, c.hegel_settings_set_database(ctx, h, &v));
    }
    if (s.database_key) |key| {
        const v = str(key);
        try ensure(ctx, c.hegel_settings_set_database_key(ctx, h, &v));
    }
    if (s.verbosity) |v| try ensure(ctx, c.hegel_settings_set_verbosity(ctx, h, @backingInt(v)));
    if (s.report_multiple_failures) |v| try ensure(ctx, c.hegel_settings_set_report_multiple_failures(ctx, h, v));
    if (s.stop_on_first_failure) |v| try ensure(ctx, c.hegel_settings_set_stop_on_first_failure(ctx, h, v));
    if (s.print_blob) |v| try ensure(ctx, c.hegel_settings_set_print_blob(ctx, h, v));
    if (s.backend) |v| try ensure(ctx, c.hegel_settings_set_backend(ctx, h, @backingInt(v)));
    if (s.nondeterminism_strictness) |v| try ensure(ctx, c.hegel_settings_set_nondeterminism_strictness(ctx, h, @backingInt(v)));
    if (s.show_statistics) |v| try ensure(ctx, c.hegel_settings_set_show_statistics(ctx, h, v));
    if (s.unbounded_choices) |v| try ensure(ctx, c.hegel_settings_set_unbounded_choices(ctx, h, v));
    if (s.phases) |v| try ensure(ctx, c.hegel_settings_set_phases(ctx, h, @bitCast(v)));
    if (s.suppress_health_check) |v| try ensure(ctx, c.hegel_settings_set_suppress_health_check(ctx, h, @bitCast(v)));
    if (s.test_location) |l| try ensure(ctx, c.hegel_settings_set_test_location(ctx, h, str(l.file), l.line, str(l.class_name), str(l.function)));
    return h;
}

fn outputTrampoline(user_data: ?*anyopaque, line: [*c]const u8, len: usize) callconv(.c) void {
    const sink: *const OutputSink = @ptrCast(@alignCast(user_data.?));
    sink.writeLine(sink.context, if (len == 0) "" else line[0..len]);
}

/// Runs `property` (a `fn (*TestCase) !void`) against generated test cases
/// and returns the outcome. The caller owns the result.
pub fn run(gpa: Allocator, settings: Settings, comptime property: anytype) !RunResult {
    return runImpl(gpa, settings, {}, property, false);
}

/// Like `run`, for a `fn (@TypeOf(context), *TestCase) !void` property.
pub fn runWithContext(gpa: Allocator, settings: Settings, context: anytype, comptime property: anytype) !RunResult {
    return runImpl(gpa, settings, context, property, true);
}

/// Runs `property` and returns `error.HegelPropertyFailed` (after printing
/// the shrunk counterexample) if it does not hold. Intended for `test` blocks.
pub fn check(settings: Settings, comptime property: anytype) !void {
    var result = try run(defaultAllocator(), settings, property);
    defer result.deinit();
    return expectPassed(result);
}

pub fn checkWithContext(settings: Settings, context: anytype, comptime property: anytype) !void {
    var result = try runWithContext(defaultAllocator(), settings, context, property);
    defer result.deinit();
    return expectPassed(result);
}

pub const ReplayOutcome = enum {
    /// The property failed again.
    reproduced,
    /// The property passed: the blob is stale or the failure is flaky.
    passed,
    /// The blob's choices no longer fit the property's draws.
    overrun,
    /// The replayed test case was rejected by an assumption.
    invalid,
};

/// Replays one reproduction blob once, without a run loop. Prefer
/// `Settings.reproduce`, which replays until the failure recurs.
pub fn replay(settings: Settings, blob: []const u8, comptime property: anytype) !ReplayOutcome {
    return replayImpl(settings, blob, {}, property, false);
}

pub fn replayWithContext(settings: Settings, blob: []const u8, context: anytype, comptime property: anytype) !ReplayOutcome {
    return replayImpl(settings, blob, context, property, true);
}

fn replayImpl(settings: Settings, blob: []const u8, context: anytype, comptime property: anytype, comptime with_ctx: bool) !ReplayOutcome {
    const ctx = c.hegel_context_new().?;
    defer _ = c.hegel_context_free(ctx);
    const s = try buildSettings(ctx, settings);
    defer _ = c.hegel_settings_free(ctx, s);
    const callback: c.hegel_output_callback_t = if (settings.output != null) &outputTrampoline else null;
    const user_data: ?*anyopaque = if (settings.output) |*o| @ptrCast(@constCast(o)) else null;
    var raw: ?*c.hegel_test_case_t = null;
    try ensure(ctx, c.hegel_test_case_from_blob(ctx, s, str(blob), callback, user_data, &raw));
    defer _ = c.hegel_test_case_free(ctx, raw);
    var arena: std.heap.ArenaAllocator = .init(defaultAllocator());
    defer arena.deinit();
    var tc: TestCase = .{ .ctx = ctx, .raw = raw.?, .arena = arena.allocator(), .capture = false };
    var outcome: ReplayOutcome = .passed;
    var status: u32 = c.HEGEL_STATUS_VALID;
    var origin: ?[]const u8 = null;
    if (callProperty(context, property, with_ctx, &tc)) |_| {} else |err| switch (err) {
        error.HegelStopTest => {
            outcome = .overrun;
            status = c.HEGEL_STATUS_OVERRUN;
        },
        error.HegelAssume => {
            outcome = .invalid;
            status = c.HEGEL_STATUS_INVALID;
        },
        else => {
            outcome = .reproduced;
            status = c.HEGEL_STATUS_INTERESTING;
            origin = try failureOrigin(tc.arena, err, @errorReturnTrace());
        },
    }
    const origin_str: ?c.hegel_string_t = if (origin) |o| str(o) else null;
    try ensure(ctx, c.hegel_mark_complete(ctx, raw.?, status, if (origin_str) |*o| o else null));
    return outcome;
}

fn defaultAllocator() Allocator {
    return if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;
}

fn expectPassed(result: RunResult) CheckError!void {
    if (result.status == .passed) return;
    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    result.writeReport(&stderr.file_writer.interface) catch {};
    return if (result.status == .failed) error.HegelPropertyFailed else error.HegelRunError;
}

fn callProperty(context: anytype, comptime property: anytype, comptime with_ctx: bool, tc: *TestCase) anyerror!void {
    return if (with_ctx) property(context, tc) else property(tc);
}

fn runImpl(gpa: Allocator, settings: Settings, context: anytype, comptime property: anytype, comptime with_ctx: bool) !RunResult {
    var result: RunResult = .{
        .arena = .init(gpa),
        .status = .passed,
        .failures = &.{},
        .error_message = null,
        .valid_test_cases = 0,
    };
    errdefer result.arena.deinit();
    const ra = result.arena.allocator();

    const ctx = c.hegel_context_new().?;
    defer _ = c.hegel_context_free(ctx);
    const s = try buildSettings(ctx, settings);
    defer _ = c.hegel_settings_free(ctx, s);

    const callback: c.hegel_output_callback_t = if (settings.output != null) &outputTrampoline else null;
    const user_data: ?*anyopaque = if (settings.output) |*o| @ptrCast(@constCast(o)) else null;
    var hrun: ?*c.hegel_run_t = null;
    if (settings.reproduce) |blob| {
        try ensure(ctx, c.hegel_run_start_blob(ctx, s, str(blob), callback, user_data, &hrun));
    } else {
        try ensure(ctx, c.hegel_run_start(ctx, s, callback, user_data, &hrun));
    }
    defer _ = c.hegel_run_free(ctx, hrun);

    var reports: std.StringHashMapUnmanaged([]const u8) = .empty;
    var case_arena: std.heap.ArenaAllocator = .init(gpa);
    defer case_arena.deinit();

    while (true) {
        var raw: ?*c.hegel_test_case_t = null;
        try ensure(ctx, c.hegel_next_test_case(ctx, hrun, &raw));
        const raw_tc = raw orelse break;
        defer _ = c.hegel_test_case_free(ctx, raw_tc);
        _ = case_arena.reset(.retain_capacity);

        var capture: bool = false;
        try ensure(ctx, c.hegel_test_case_should_capture(ctx, raw_tc, &capture));
        var tc: TestCase = .{ .ctx = ctx, .raw = raw_tc, .arena = case_arena.allocator(), .capture = capture };

        var status: u32 = c.HEGEL_STATUS_VALID;
        var origin: ?[]const u8 = null;
        if (callProperty(context, property, with_ctx, &tc)) |_| {
            result.valid_test_cases += 1;
        } else |err| switch (err) {
            error.HegelStopTest => status = c.HEGEL_STATUS_OVERRUN,
            error.HegelAssume => status = c.HEGEL_STATUS_INVALID,
            else => {
                status = c.HEGEL_STATUS_INTERESTING;
                const trace = @errorReturnTrace();
                origin = try failureOrigin(tc.arena, err, trace);
                if (capture) {
                    try appendEngineDocument(&tc);
                    const report = try failureReport(&tc, err, trace);
                    const gop = try reports.getOrPut(ra, try ra.dupe(u8, origin.?));
                    gop.value_ptr.* = try ra.dupe(u8, report);
                }
            },
        }
        const origin_str: ?c.hegel_string_t = if (origin) |o| str(o) else null;
        try ensure(ctx, c.hegel_mark_complete(ctx, raw_tc, status, if (origin_str) |*o| o else null));
    }

    var hres: ?*c.hegel_run_result_t = null;
    try ensure(ctx, c.hegel_run_result(ctx, hrun, &hres));
    defer _ = c.hegel_run_result_free(ctx, hres);

    var rstatus: c.hegel_run_status_t = undefined;
    try ensure(ctx, c.hegel_run_result_status(ctx, hres, &rstatus));
    result.status = switch (rstatus) {
        c.HEGEL_RUN_STATUS_PASSED => .passed,
        c.HEGEL_RUN_STATUS_FAILED => .failed,
        else => .errored,
    };
    if (result.status == .errored) {
        var msg: [*c]const c.hegel_string_t = null;
        try ensure(ctx, c.hegel_run_result_error(ctx, hres, &msg));
        if (msg != null) result.error_message = try ra.dupe(u8, slice(msg.*));
        var kind: c.hegel_run_error_kind_t = undefined;
        var hc: u32 = 0;
        try ensure(ctx, c.hegel_run_result_error_kind(ctx, hres, &kind, &hc));
        result.error_kind = @fromBackingInt(@intCast(kind));
        result.failed_health_check = @bitCast(hc);
    }

    var count: usize = 0;
    try ensure(ctx, c.hegel_run_result_failure_count(ctx, hres, &count));
    const failures = try ra.alloc(Failure, count);
    for (failures, 0..) |*f, i| {
        var hf: ?*c.hegel_failure_t = null;
        try ensure(ctx, c.hegel_run_result_failure(ctx, hres, i, &hf));
        defer _ = c.hegel_failure_free(ctx, hf);
        var o: c.hegel_string_t = undefined;
        try ensure(ctx, c.hegel_failure_origin(ctx, hf, &o));
        var blob: [*c]const c.hegel_string_t = null;
        try ensure(ctx, c.hegel_failure_reproduction_blob(ctx, hf, &blob));
        var caveat: [*c]const c.hegel_string_t = null;
        try ensure(ctx, c.hegel_failure_caveat(ctx, hf, &caveat));
        const origin = try ra.dupe(u8, slice(o));
        f.* = .{
            .origin = origin,
            .report = reports.get(origin) orelse "",
            .reproduction_blob = if (blob != null) try ra.dupe(u8, slice(blob.*)) else null,
            .caveat = if (caveat != null) try ra.dupe(u8, slice(caveat.*)) else null,
        };
    }
    result.failures = failures;
    return result;
}

/// Appends what was printed through `noteLine` and test-case printers.
fn appendEngineDocument(tc: *TestCase) !void {
    var raw: ?*c.hegel_printer_t = null;
    if (c.hegel_test_case_printer(tc.ctx, tc.raw, null, &raw) != c.HEGEL_OK) return;
    defer _ = c.hegel_printer_free(tc.ctx, raw);
    var res: c.hegel_printer_value_result_t = .{ .data = null, .len = 0 };
    // Fails harmlessly when no clone or deferred hole is outstanding.
    _ = c.hegel_printer_resolve(tc.ctx, raw);
    if (c.hegel_printer_value(tc.ctx, raw, &res) != c.HEGEL_OK) return;
    defer _ = c.hegel_printer_value_result_free(tc.ctx, &res);
    if (res.len == 0) return;
    try tc.output.appendSlice(tc.arena, res.data[0..res.len]);
    if (res.data[res.len - 1] != '\n') try tc.output.append(tc.arena, '\n');
}

/// A stable identity for a failure: the error name plus a hash of where it
/// was returned from, so distinct bugs are shrunk and reported separately.
fn failureOrigin(arena: Allocator, err: anyerror, trace: ?*std.builtin.StackTrace) ![]const u8 {
    const t = trace orelse return std.fmt.allocPrint(arena, "error.{t}", .{err});
    const len = @min(t.index, t.instruction_addresses.len);
    var h: std.hash.Wyhash = .init(0);
    h.update(std.mem.sliceAsBytes(t.instruction_addresses[0..len]));
    return std.fmt.allocPrint(arena, "error.{t}@{x:0>16}", .{ err, h.final() });
}

fn failureReport(tc: *TestCase, err: anyerror, trace: ?*std.builtin.StackTrace) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .fromArrayList(tc.arena, &tc.output);
    const w = &aw.writer;
    w.print("error: {t}", .{err}) catch return error.OutOfMemory;
    if (tc.message) |m| w.print(": {s}", .{m}) catch return error.OutOfMemory;
    w.writeByte('\n') catch return error.OutOfMemory;
    if (trace) |t| std.debug.writeErrorReturnTrace(t, .{ .writer = w, .mode = .no_color }) catch return error.OutOfMemory;
    return aw.written();
}

test "libhegel version" {
    try std.testing.expectEqualStrings("0.48.0", version());
}

test "translated constants" {
    try std.testing.expectEqual(0, c.HEGEL_OK);
    try std.testing.expectEqual(-1, c.HEGEL_E_STOP_TEST);
    try std.testing.expectEqual(std.math.minInt(i64), c.HEGEL_STATE_MACHINE_DONE);
}
