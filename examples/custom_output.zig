//! custom_output.zig — port of libhegel's examples/custom_output.c.
//!
//! Passes an output callback to hegel_run_start, runs a small passing
//! property at debug verbosity, and checks the engine's progress lines
//! arrived at the callback (with the user_data pointer passed through)
//! instead of being written to stderr.

const std = @import("std");
const h = @import("check.zig");
const c = h.c;

const Capture = struct {
    lines: usize = 0,
    saw_summary: bool = false,
};

fn captureLine(user_data: ?*anyopaque, line: [*c]const u8, len: usize) callconv(.c) void {
    const cap: *Capture = @ptrCast(@alignCast(user_data.?));
    const text = std.mem.span(line);
    if (text.len != len) {
        std.debug.print("line/len mismatch: {d} vs {d}\n", .{ text.len, len });
        std.process.abort();
    }
    cap.lines += 1;
    // The engine ends every run with a "Test done. ..." summary at debug
    // verbosity; remember whether it reached us.
    if (std.mem.startsWith(u8, text, "Test done.")) cap.saw_summary = true;
}

pub fn main() !u8 {
    const ctx = c.hegel_context_new();
    var cap: Capture = .{};

    var s: ?*c.hegel_settings_t = null;
    try h.ok(ctx, c.hegel_settings_new(ctx, &s));
    try h.ok(ctx, c.hegel_settings_set_test_cases(ctx, s, 10));
    try h.ok(ctx, c.hegel_settings_set_database(ctx, s, &h.str(""))); // disable database
    try h.ok(ctx, c.hegel_settings_set_seed(ctx, s, 42, true));
    try h.ok(ctx, c.hegel_settings_set_verbosity(ctx, s, c.HEGEL_VERBOSITY_DEBUG));

    var run: ?*c.hegel_run_t = null;
    try h.ok(ctx, c.hegel_run_start(ctx, s, captureLine, &cap, &run));

    while (true) {
        var tc: ?*c.hegel_test_case_t = null;
        try h.ok(ctx, c.hegel_next_test_case(ctx, run, &tc));
        if (tc == null) break;
        var n: i64 = undefined;
        const rc = c.hegel_generate_integer(ctx, tc, 0, 100, &n);
        const status: u32 = if (rc == c.HEGEL_OK) c.HEGEL_STATUS_VALID else c.HEGEL_STATUS_OVERRUN;
        try h.ok(ctx, c.hegel_mark_complete(ctx, tc, status, null));
        try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
    }

    var result: ?*c.hegel_run_result_t = null;
    try h.ok(ctx, c.hegel_run_result(ctx, run, &result));
    var status: c.hegel_run_status_t = undefined;
    try h.ok(ctx, c.hegel_run_result_status(ctx, result, &status));
    try h.ok(ctx, c.hegel_run_result_free(ctx, result));
    try h.ok(ctx, c.hegel_run_free(ctx, run));
    try h.ok(ctx, c.hegel_settings_free(ctx, s));
    try h.ok(ctx, c.hegel_context_free(ctx));

    std.debug.print("captured {d} engine output line(s), summary seen: {s}\n", .{ cap.lines, if (cap.saw_summary) "yes" else "no" });
    if (status != c.HEGEL_RUN_STATUS_PASSED or cap.lines == 0 or !cap.saw_summary) {
        std.debug.print("expected a passing run whose debug output reached the callback\n", .{});
        return 1;
    }
    return 0;
}
