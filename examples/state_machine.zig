//! state_machine.zig — port of libhegel's examples/state_machine.c.
//!
//! Engine-owned rule selection for stateful testing: the engine decides
//! which rule runs at each step (with swarm testing), how many rules make up
//! each round and how many rounds to run. This drives the sequential case:
//! one concurrency group, concurrency fixed at 1.
//!
//! A tiny counter machine with rules increment / decrement (skipped at zero)
//! / reset; the invariant is that the counter stays non-negative.

const std = @import("std");
const h = @import("check.zig");
const c = h.c;

const rules = [_]c.hegel_string_t{ h.str("increment"), h.str("decrement"), h.str("reset") };
const rule_groups = [_]i64{ 0, 0, 0 };
const invariants = [_]c.hegel_string_t{h.str("non_negative")};

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

    var total: usize = 0;
    var rule_counts: [rules.len]usize = @splat(0);
    var good = true;

    while (true) {
        var tc: ?*c.hegel_test_case_t = null;
        try h.ok(ctx, c.hegel_next_test_case(ctx, run, &tc));
        if (tc == null) break;

        var machine: ?*c.hegel_state_machine_t = null;
        var concurrency: i64 = undefined;
        if (c.hegel_new_state_machine(ctx, tc, &rules, &rule_groups, null, rules.len, &invariants, null, invariants.len, 1, 1, 50, &machine, &concurrency) != c.HEGEL_OK) {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_OVERRUN, null));
            try h.ok(ctx, c.hegel_test_case_free(ctx, tc));
            continue;
        }

        var counter: i64 = 0;
        var overran = false;
        var bad = false;
        rounds: while (true) {
            var group: i64 = undefined;
            if (c.hegel_state_machine_next_group(ctx, tc, machine, &group) != c.HEGEL_OK) {
                overran = true;
                break;
            }
            if (group == c.HEGEL_STATE_MACHINE_DONE) break;
            if (group != 0) {
                bad = true;
                break;
            }
            while (true) {
                var rule: i64 = undefined;
                if (c.hegel_state_machine_next_rule(ctx, tc, machine, 0, &rule) != c.HEGEL_OK) {
                    overran = true;
                    break :rounds;
                }
                if (rule == c.HEGEL_STATE_MACHINE_DONE) break;
                if (rule < 0 or rule >= rules.len) {
                    bad = true;
                    break :rounds;
                }
                rule_counts[@intCast(rule)] += 1;
                switch (rule) {
                    0 => counter += 1,
                    1 => if (counter > 0) {
                        counter -= 1;
                    },
                    2 => counter = 0,
                    else => unreachable,
                }
            }
            // Invariant, checked at the join point after each round.
            if (counter < 0) {
                bad = true;
                break;
            }
        }

        // The state-machine handle is caller-owned and freed independently of the test case.
        try h.ok(ctx, c.hegel_state_machine_free(ctx, machine));

        if (bad) {
            try h.ok(ctx, c.hegel_mark_complete(ctx, tc, c.HEGEL_STATUS_INTERESTING, &h.str("invariant violated")));
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

    // Every rule should have been selected at least once across the run —
    // swarm testing restricts the mix per test case, not globally.
    for (rules, rule_counts) |rule, count| {
        if (count == 0) {
            std.debug.print("rule {s} was never selected\n", .{h.slice(rule)});
            good = false;
        }
    }

    std.debug.print("ran {d} valid cases (rule mix: {d}/{d}/{d}), {s}\n", .{ total, rule_counts[0], rule_counts[1], rule_counts[2], if (passed) "PASSED" else "FAILED" });

    try h.ok(ctx, c.hegel_run_free(ctx, run));
    try h.ok(ctx, c.hegel_settings_free(ctx, s));
    try h.ok(ctx, c.hegel_context_free(ctx));
    return if (passed and good) 0 else 1;
}
