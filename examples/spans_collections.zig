//! spans_collections.zig — port of libhegel's examples/spans_collections.c.
//!
//! Builds a list of booleans from the span + collection primitives and
//! checks every drawn list stays inside its size bounds.

const std = @import("std");
const h = @import("check.zig");
const c = h.c;

/// Span labels identify the generator a span belongs to; derive them from
/// names (and, for a generator with components, from the components'
/// labels) rather than numbering them by hand.
const Labels = struct {
    list: u64,
    list_element: u64,

    fn init(ctx: ?*c.hegel_context_t) !Labels {
        var list_kind: u64 = undefined;
        var boolean_kind: u64 = undefined;
        try h.ok(ctx, c.hegel_label_from_name(ctx, h.str("example.list"), &list_kind));
        try h.ok(ctx, c.hegel_label_from_name(ctx, h.str("example.boolean"), &boolean_kind));
        const parts = [2]u64{ list_kind, boolean_kind };
        var labels: Labels = undefined;
        try h.ok(ctx, c.hegel_label_combine(ctx, &parts, parts.len, &labels.list));
        try h.ok(ctx, c.hegel_label_from_name(ctx, h.str("example.list_element"), &labels.list_element));
        return labels;
    }
};

/// Draws a list of booleans sized in [min_size, max_size] using a span
/// wrapping a collection (more/draw loop). Returns the number of elements
/// drawn, or null on engine error (e.g. HEGEL_E_STOP_TEST).
fn drawBoolList(ctx: ?*c.hegel_context_t, tc: ?*c.hegel_test_case_t, labels: Labels, min_size: u64, max_size: u64) ?usize {
    if (c.hegel_start_span(ctx, tc, labels.list) != c.HEGEL_OK) return null;
    defer _ = c.hegel_stop_span(ctx, tc, false);

    var collection: ?*c.hegel_collection_t = null;
    if (c.hegel_new_collection(ctx, tc, min_size, max_size, &collection) != c.HEGEL_OK) return null;
    // The collection handle is caller-owned and freed independently of the test case.
    defer _ = c.hegel_collection_free(ctx, collection);

    var n: usize = 0;
    while (true) {
        var more: bool = undefined;
        if (c.hegel_collection_more(ctx, tc, collection, &more) != c.HEGEL_OK) return null;
        if (!more) break;
        if (c.hegel_start_span(ctx, tc, labels.list_element) != c.HEGEL_OK) return null;
        var value: bool = undefined;
        const rc = c.hegel_generate_boolean(ctx, tc, 0.5, false, false, &value);
        _ = c.hegel_stop_span(ctx, tc, false);
        if (rc != c.HEGEL_OK) return null;
        n += 1;
    }
    return n;
}

pub fn main() !u8 {
    const ctx = c.hegel_context_new();
    const labels = try Labels.init(ctx);

    var s: ?*c.hegel_settings_t = null;
    try h.ok(ctx, c.hegel_settings_new(ctx, &s));
    try h.ok(ctx, c.hegel_settings_set_test_cases(ctx, s, 100));
    try h.ok(ctx, c.hegel_settings_set_database(ctx, s, &h.str("")));
    try h.ok(ctx, c.hegel_settings_set_derandomize(ctx, s, true));
    try h.ok(ctx, c.hegel_settings_set_seed(ctx, s, 0xfeedface, true));

    var run: ?*c.hegel_run_t = null;
    try h.ok(ctx, c.hegel_run_start(ctx, s, null, null, &run));

    const min_size = 0;
    const max_size = 8;
    var total: usize = 0;
    var max_seen: usize = 0;

    while (true) {
        var tc: ?*c.hegel_test_case_t = null;
        try h.ok(ctx, c.hegel_next_test_case(ctx, run, &tc));
        if (tc == null) break;

        const n = drawBoolList(ctx, tc, labels, min_size, max_size) orelse {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_OVERRUN, null));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        };
        if (n < min_size or n > max_size) {
            var buf: [64]u8 = undefined;
            const origin = try std.fmt.bufPrint(&buf, "size {d} out of range", .{n});
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_INTERESTING, &h.str(origin)));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        }
        total += 1;
        max_seen = @max(max_seen, n);
        try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_VALID, null));
        // The caller owns every handle from hegel_next_test_case and must free it.
        try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
    }

    var result: ?*c.hegel_run_result_t = null;
    try h.ok(ctx, c.hegel_run_result(ctx, run, &result));
    var status: c.hegel_run_status_t = undefined;
    try h.ok(ctx, c.hegel_run_result_status(ctx, result, &status));
    const passed = status == c.HEGEL_RUN_STATUS_PASSED;
    try h.ok(ctx, c.hegel_run_result_free(ctx, result));

    std.debug.print("ran {d} valid cases (max list size seen: {d}), {s}\n", .{ total, max_seen, if (passed) "PASSED" else "FAILED" });

    try h.ok(ctx, c.hegel_run_free(ctx, run));
    try h.ok(ctx, c.hegel_settings_free(ctx, s));
    try h.ok(ctx, c.hegel_context_free(ctx));
    return if (passed) 0 else 1;
}
