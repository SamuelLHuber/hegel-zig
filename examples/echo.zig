//! echo.zig — port of libhegel's examples/echo.c.
//!
//! Draws an integer in [0, 100], runs 50 test cases via the libhegel event
//! loop, asserts every drawn value is in range, and prints a short summary.

const std = @import("std");
const h = @import("check.zig");
const c = h.c;

pub fn main() !u8 {
    const ctx = c.hegel_context_new();
    var s: ?*c.hegel_settings_t = null;
    try h.ok(ctx, c.hegel_settings_new(ctx, &s));
    try h.ok(ctx, c.hegel_settings_set_test_cases(ctx, s, 50));
    try h.ok(ctx, c.hegel_settings_set_database(ctx, s, &h.str(""))); // disable database
    try h.ok(ctx, c.hegel_settings_set_derandomize(ctx, s, true));
    try h.ok(ctx, c.hegel_settings_set_seed(ctx, s, 42, true));

    var run: ?*c.hegel_run_t = null;
    try h.ok(ctx, c.hegel_run_start(ctx, s, null, null, &run));

    var cases: usize = 0;
    while (true) {
        // The run is finished when next returns HEGEL_OK with a NULL case.
        var tc: ?*c.hegel_test_case_t = null;
        try h.ok(ctx, c.hegel_next_test_case(ctx, run, &tc));
        if (tc == null) break;

        var n: i64 = undefined;
        const rc = c.hegel_generate_integer(ctx, tc, 0, 100, &n);
        if (rc == c.HEGEL_E_STOP_TEST) {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_OVERRUN, null));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        }
        if (rc != c.HEGEL_OK) {
            std.debug.print("hegel_generate_integer failed: rc={d} {s}\n", .{ rc, h.slice(c.hegel_context_last_error(ctx)) });
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_VALID, null));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        }

        if (n < 0 or n > 100) {
            var buf: [64]u8 = undefined;
            const origin = try std.fmt.bufPrint(&buf, "out-of-range value {d}", .{n});
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_INTERESTING, &h.str(origin)));
        } else {
            cases += 1;
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_VALID, null));
        }
        // Every handle hegel_next_test_case hands back is owned by the caller
        // and must be released, even though the run keeps its own reference.
        try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
    }

    var result: ?*c.hegel_run_result_t = null;
    try h.ok(ctx, c.hegel_run_result(ctx, run, &result));
    var status: c.hegel_run_status_t = undefined;
    try h.ok(ctx, c.hegel_run_result_status(ctx, result, &status));
    const status_str = switch (status) {
        c.HEGEL_RUN_STATUS_PASSED => "PASSED",
        c.HEGEL_RUN_STATUS_FAILED => "FAILED",
        else => "ERROR",
    };

    var nf: usize = 0;
    try h.ok(ctx, c.hegel_run_result_failure_count(ctx, result, &nf));
    std.debug.print("ran {d} valid test cases, {s}, {d} failures\n", .{ cases, status_str, nf });
    for (0..nf) |i| {
        var f: ?*c.hegel_failure_t = null;
        try h.ok(ctx, c.hegel_run_result_failure(ctx, result, i, &f));
        var origin: c.hegel_string_t = undefined;
        try h.ok(ctx, c.hegel_failure_origin(ctx, f, &origin));
        std.debug.print("  failure {d}: origin={s}\n", .{ i, h.slice(origin) });
        try h.ok(ctx, c.hegel_failure_free(ctx, f));
    }
    if (status == c.HEGEL_RUN_STATUS_ERROR) {
        var run_err: [*c]const c.hegel_string_t = null;
        try h.ok(ctx, c.hegel_run_result_error(ctx, result, &run_err));
        std.debug.print("run error: {s}\n", .{h.slice(run_err.*)});
    }

    // The result is a caller-owned snapshot, freed independently of the run.
    try h.ok(ctx, c.hegel_run_result_free(ctx, result));
    try h.ok(ctx, c.hegel_run_free(ctx, run));
    try h.ok(ctx, c.hegel_settings_free(ctx, s));
    try h.ok(ctx, c.hegel_context_free(ctx));
    return if (status == c.HEGEL_RUN_STATUS_PASSED) 0 else 1;
}
