//! failing.zig — port of libhegel's examples/failing.c.
//!
//! A failing property, with libhegel shrinking to a minimal counterexample
//! and reporting it back through the result API. Property: every integer in
//! [0, 100] is < 5. Exits 0 if the failing run was correctly detected and
//! the reported failure carries the expected origin string.

const std = @import("std");
const h = @import("check.zig");
const c = h.c;

const ORIGIN = "n >= 5";

pub fn main() !u8 {
    const ctx = c.hegel_context_new();
    var s: ?*c.hegel_settings_t = null;
    try h.ok(ctx, c.hegel_settings_new(ctx, &s));
    try h.ok(ctx, c.hegel_settings_set_test_cases(ctx, s, 200));
    try h.ok(ctx, c.hegel_settings_set_database(ctx, s, &h.str("")));
    try h.ok(ctx, c.hegel_settings_set_derandomize(ctx, s, true));
    try h.ok(ctx, c.hegel_settings_set_seed(ctx, s, 0xc0ffee, true));

    var run: ?*c.hegel_run_t = null;
    try h.ok(ctx, c.hegel_run_start(ctx, s, null, null, &run));

    var smallest: ?i64 = null;
    while (true) {
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
            std.debug.print("hegel_generate_integer: rc={d} {s}\n", .{ rc, h.slice(c.hegel_context_last_error(ctx)) });
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_VALID, null));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        }

        if (n < 5) {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_VALID, null));
        } else {
            // Track the smallest counterexample seen, to show the shrink.
            smallest = if (smallest) |m| @min(m, n) else n;
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_INTERESTING, &h.str(ORIGIN)));
        }
        // The caller owns every handle from hegel_next_test_case and must free it.
        try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
    }

    var result: ?*c.hegel_run_result_t = null;
    try h.ok(ctx, c.hegel_run_result(ctx, run, &result));
    var status: c.hegel_run_status_t = undefined;
    try h.ok(ctx, c.hegel_run_result_status(ctx, result, &status));
    if (status != c.HEGEL_RUN_STATUS_FAILED) {
        std.debug.print("FAIL: expected a failing run, got status {d}\n", .{status});
        return 1;
    }

    var nf: usize = 0;
    try h.ok(ctx, c.hegel_run_result_failure_count(ctx, result, &nf));
    if (nf < 1) {
        std.debug.print("FAIL: expected at least one failure, got {d}\n", .{nf});
        return 1;
    }

    var f: ?*c.hegel_failure_t = null;
    try h.ok(ctx, c.hegel_run_result_failure(ctx, result, 0, &f));
    var origin: c.hegel_string_t = undefined;
    try h.ok(ctx, c.hegel_failure_origin(ctx, f, &origin));
    if (!std.mem.eql(u8, h.slice(origin), ORIGIN)) {
        std.debug.print("FAIL: expected origin to contain {s}, got: {s}\n", .{ ORIGIN, h.slice(origin) });
        return 1;
    }

    var caveat: [*c]const c.hegel_string_t = null;
    try h.ok(ctx, c.hegel_failure_caveat(ctx, f, &caveat));
    if (caveat != null) {
        std.debug.print("FAIL: expected no caveat for a deterministic failure, got: {s}\n", .{h.slice(caveat.*)});
        return 1;
    }
    if (smallest != 5) {
        std.debug.print("FAIL: expected the engine to shrink to n = 5, smallest seen: {?d}\n", .{smallest});
        return 1;
    }

    std.debug.print("got expected failure: origin={s} (shrunk to n = {?d})\n", .{ h.slice(origin), smallest });

    // Result and failure are caller-owned snapshots, freed independently.
    try h.ok(ctx, c.hegel_failure_free(ctx, f));
    try h.ok(ctx, c.hegel_run_result_free(ctx, result));
    try h.ok(ctx, c.hegel_run_free(ctx, run));
    try h.ok(ctx, c.hegel_settings_free(ctx, s));
    try h.ok(ctx, c.hegel_context_free(ctx));
    return 0;
}
