//! invalid_argument.zig — port of libhegel's examples/invalid_argument.c.
//!
//! Feeds typed invalid arguments to the API and asserts each returns
//! HEGEL_E_INVALID_ARG with a diagnostic instead of aborting the process:
//!   - hegel_generate_integer with min_value > max_value;
//!   - hegel_string_generator_text with an unknown codec ("ebcdic").

const std = @import("std");
const h = @import("check.zig");
const c = h.c;

pub fn main() !u8 {
    const ctx = c.hegel_context_new();
    var s: ?*c.hegel_settings_t = null;
    try h.ok(ctx, c.hegel_settings_new(ctx, &s));
    try h.ok(ctx, c.hegel_settings_set_test_cases(ctx, s, 1));
    try h.ok(ctx, c.hegel_settings_set_database(ctx, s, &h.str("")));
    try h.ok(ctx, c.hegel_settings_set_derandomize(ctx, s, true));
    try h.ok(ctx, c.hegel_settings_set_seed(ctx, s, 1, true));

    var run: ?*c.hegel_run_t = null;
    try h.ok(ctx, c.hegel_run_start(ctx, s, null, null, &run));

    var tc: ?*c.hegel_test_case_t = null;
    try h.ok(ctx, c.hegel_next_test_case(ctx, run, &tc));
    if (tc == null) {
        std.debug.print("expected a test case\n", .{});
        return 1;
    }

    var good = true;

    var n: i64 = undefined;
    var rc = c.hegel_generate_integer(ctx, tc, 10, 5, &n);
    if (rc != c.HEGEL_E_INVALID_ARG) {
        std.debug.print("expected HEGEL_E_INVALID_ARG ({d}) for min > max, got rc={d}\n", .{ c.HEGEL_E_INVALID_ARG, rc });
        good = false;
    }
    var err = h.slice(c.hegel_context_last_error(ctx));
    if (err.len == 0) {
        std.debug.print("expected a diagnostic message for min > max\n", .{});
        good = false;
    } else {
        std.debug.print("min > max correctly rejected: rc={d}, message=\"{s}\"\n", .{ rc, err });
    }

    var gen: ?*c.hegel_string_generator_t = null;
    rc = c.hegel_string_generator_text(ctx, 0, 10, &h.str("ebcdic"), 0, std.math.maxInt(u32), null, 0, null, 0, h.str(""), h.str(""), &gen);
    if (rc != c.HEGEL_E_INVALID_ARG) {
        std.debug.print("expected HEGEL_E_INVALID_ARG ({d}) for unknown codec, got rc={d}\n", .{ c.HEGEL_E_INVALID_ARG, rc });
        good = false;
    }
    err = h.slice(c.hegel_context_last_error(ctx));
    if (err.len == 0) {
        std.debug.print("expected a diagnostic message for the unknown codec\n", .{});
        good = false;
    } else {
        std.debug.print("unknown codec correctly rejected: rc={d}, message=\"{s}\"\n", .{ rc, err });
    }

    try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_INVALID, null));
    try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
    try h.ok(ctx, c.hegel_run_free(ctx, run));
    try h.ok(ctx, c.hegel_settings_free(ctx, s));
    try h.ok(ctx, c.hegel_context_free(ctx));
    return if (good) 0 else 1;
}
