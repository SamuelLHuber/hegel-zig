//! pool.zig — port of libhegel's examples/pool.c.
//!
//! Stateful-style testing with the variable-pool primitives. Each test case
//! models a tiny stack of integers; on every step the engine chooses between
//! push (generate a value, register it in the pool) and pop (draw a live
//! variable id with consume=true). The invariant: the pool only ever hands
//! back ids we put in and have not yet consumed.

const std = @import("std");
const h = @import("check.zig");
const c = h.c;

const max_live = 64;

/// Shadow map of live variables: id -> value, by linear scan.
const LiveSet = struct {
    ids: [max_live]i64 = undefined,
    values: [max_live]i64 = undefined,
    count: usize = 0,

    fn add(self: *LiveSet, id: i64, value: i64) void {
        if (self.count >= max_live) {
            std.debug.print("live_set overflow\n", .{});
            std.process.exit(2);
        }
        self.ids[self.count] = id;
        self.values[self.count] = value;
        self.count += 1;
    }

    /// Removes `id`, returning its stored value, or null if absent.
    fn remove(self: *LiveSet, id: i64) ?i64 {
        for (self.ids[0..self.count], 0..) |live_id, i| {
            if (live_id != id) continue;
            const value = self.values[i];
            self.ids[i] = self.ids[self.count - 1];
            self.values[i] = self.values[self.count - 1];
            self.count -= 1;
            return value;
        }
        return null;
    }
};

pub fn main() !u8 {
    const ctx = c.hegel_context_new();
    var s: ?*c.hegel_settings_t = null;
    try h.ok(ctx, c.hegel_settings_new(ctx, &s));
    try h.ok(ctx, c.hegel_settings_set_test_cases(ctx, s, 100));
    try h.ok(ctx, c.hegel_settings_set_database(ctx, s, &h.str("")));
    try h.ok(ctx, c.hegel_settings_set_derandomize(ctx, s, true));
    try h.ok(ctx, c.hegel_settings_set_seed(ctx, s, 0x5ca1ab1e, true));

    var run: ?*c.hegel_run_t = null;
    try h.ok(ctx, c.hegel_run_start(ctx, s, null, null, &run));

    const steps = 12;
    var total: usize = 0;
    var max_pool: usize = 0;
    var good = true;

    while (true) {
        var tc: ?*c.hegel_test_case_t = null;
        try h.ok(ctx, c.hegel_next_test_case(ctx, run, &tc));
        if (tc == null) break;

        var live: LiveSet = .{};
        var pool: ?*c.hegel_pool_t = null;
        if (c.hegel_new_pool(ctx, tc, &pool) != c.HEGEL_OK) {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_OVERRUN, null));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        }

        var overran = false;
        var bad = false;
        for (0..steps) |_| {
            var push: bool = undefined;
            if (c.hegel_generate_boolean(ctx, tc, 0.5, false, false, &push) != c.HEGEL_OK) {
                overran = true;
                break;
            }
            if (push or live.count == 0) {
                // Push: generate a value and register it in the pool.
                var value: i64 = undefined;
                if (c.hegel_generate_integer(ctx, tc, 0, 1000, &value) != c.HEGEL_OK) {
                    overran = true;
                    break;
                }
                var var_id: i64 = undefined;
                if (c.hegel_pool_add(ctx, tc, pool, &var_id) != c.HEGEL_OK) {
                    overran = true;
                    break;
                }
                live.add(var_id, value);
            } else {
                // Pop: draw a live variable and consume it.
                var var_id: i64 = undefined;
                if (c.hegel_pool_generate(ctx, tc, pool, true, &var_id) != c.HEGEL_OK) {
                    overran = true;
                    break;
                }
                // Invariant: the engine only hands back live ids.
                if (live.remove(var_id) == null) {
                    bad = true;
                    break;
                }
            }
            max_pool = @max(max_pool, live.count);
        }

        // The pool handle is caller-owned and freed independently of the test case.
        try h.ok(ctx, c.hegel_pool_free(ctx, pool));

        if (bad) {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_INTERESTING, &h.str("drew a non-live variable")));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            good = false;
            continue;
        }
        if (overran) {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_OVERRUN, null));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        }
        total += 1;
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

    std.debug.print("ran {d} valid cases (max live pool size seen: {d}), {s}\n", .{ total, max_pool, if (passed) "PASSED" else "FAILED" });

    try h.ok(ctx, c.hegel_run_free(ctx, run));
    try h.ok(ctx, c.hegel_settings_free(ctx, s));
    try h.ok(ctx, c.hegel_context_free(ctx));
    return if (passed and good) 0 else 1;
}
