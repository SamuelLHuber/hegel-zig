---
name: hegel-zig
description: "How to write property-based tests in Zig with hegel-zig (Hegel / libhegel). Use when adding hegel-zig to a Zig project, writing `hegel.check` properties, choosing or writing generators, stateful (state-machine) tests, reproducing a failure from a blob, or calling libhegel's C API directly from Zig through `hegel.c`. Requires Zig 0.17.0."
---

# Property-based testing in Zig with hegel-zig

hegel-zig drives the native Hegel engine (libhegel) through its C ABI.
The engine generates values, shrinks counterexamples, keeps the example
database and replays failures. Your code draws values and states
properties. Requires **Zig 0.17.0**.

## 1. Add the dependency

```sh
zig fetch --save git+https://github.com/SamuelLHuber/hegel-zig
```

```zig
// build.zig
const hegel = b.dependency("hegel", .{ .target = target, .optimize = optimize });
tests.root_module.addImport("hegel", hegel.module("hegel"));
```

On the first build the package downloads the libhegel static library and
checks its SHA-256. It also links libc++ and the system libraries libhegel
needs. Supported out of the box: `x86_64-linux`, `aarch64-linux` and
`aarch64-macos`. For other targets, or offline builds, pass
`-Dlibhegel=/path/to/libhegel.a`.

## 2. Write a property

```zig
const std = @import("std");
const hegel = @import("hegel");
const gen = hegel.gen;

test "sorting is idempotent" {
    try hegel.check(.{}, struct {
        fn property(tc: *hegel.TestCase) !void {
            const xs = try tc.draw(gen.lists(gen.integers(i32, .{}), .{ .max_size = 50 }));
            const a = try tc.allocator().dupe(i32, xs);
            std.mem.sort(i32, a, {}, std.sort.asc(i32));
            const b = try tc.allocator().dupe(i32, a);
            std.mem.sort(i32, b, {}, std.sort.asc(i32));
            try tc.expectEqualSlices(i32, a, b);
        }
    }.property);
}
```

Rules:

- A property is `fn (*hegel.TestCase) !void`. Any returned error counts as
  a failure. To pass state in, use
  `hegel.checkWithContext(settings, ctx, fn (@TypeOf(ctx), *TestCase) !void)`.
- Draw every input with `try tc.draw(generator)`. Always `try`: the engine
  stops or rejects test cases through `error.HegelStopTest`,
  `error.HegelAssume` and `error.HegelRetry`. Never `catch` those and carry
  on.
- `tc.assume(cond)` discards the test case. Prefer constraining the
  generator: heavy rejection fails the `filter_too_much` health check.
- Prefer `tc.expect`, `tc.expectEqual`, `tc.expectEqualSlices` and
  `tc.fail(fmt, args)`. They print only in the final shrunk report.
  `std.testing.expect*` also works, but logs on every shrink attempt.
- Allocate from `tc.allocator()`, an arena that is freed when the test case
  ends. Don't hand drawn slices to code that outlives the test case.
- Don't `@panic` or hit `unreachable` in a property. A panic aborts the
  process before shrinking. Return an error instead.
- `tc.note(fmt, args)` and `tc.noteLine(s)` attach context to the report.
  `tc.event(label)` and `tc.eventValue(v, label)` feed statistics.
  `tc.target(v, label)` steers the search towards larger `v`.

A failing `check` prints the shrunk draws, the Zig error return trace and a
line like `Reproduce with: .reproduce = "AX…"`. Paste that into
`Settings.reproduce` to replay the failure deterministically.

## 3. Settings

`hegel.Settings` fields are all optional; unset fields keep the engine
defaults, including `HEGEL_*` environment variables and `hegel.toml`
profiles. The common ones:

```zig
const settings: hegel.Settings = .{
    .test_cases = 500,
    .derandomize = true, // a fixed seed derived from the test, for CI
    .database = "", // "" disables the example database
    .reproduce = null, // a blob from a failure report
};
```

Also available: `seed`, `database_key`, `verbosity`, `profile`,
`report_multiple_failures`, `stop_on_first_failure`, `print_blob`, `output`
(redirect engine output), `backend`, `nondeterminism_strictness`,
`show_statistics`, `unbounded_choices`, `phases`, `suppress_health_check`
and `test_location`. `hegel.resolveSettings` reports the effective values.
`hegel.registerProfile` and `hegel.setDefaultProfile` change them for the
whole process.

To assert on the outcome instead of failing the test (for example to check
that a bug is found), use `hegel.run(gpa, settings, property)`. It returns a
`RunResult` with `status`, `error_kind`, `failed_health_check` and
`failures` (each with `report` and `reproduction_blob`); call `deinit()`
when done. `hegel.replay(settings, blob, property)` runs a single blob and
returns `.reproduced`, `.passed`, `.overrun` or `.invalid`.

## 4. Generators (`hegel.gen`)

| Need | Generator |
|---|---|
| numbers | `integers(T, .{ .min, .max })` (any width up to 128 bits), `floats(f32/f64, .{ .min, .max, .allow_nan, .allow_infinity, … })` |
| booleans | `booleans()`, `weightedBooleans(p)` |
| bytes / text | `bytes(.{ .min_size, .max_size })`, `text(.{ .codec, .min_size, .max_size, .min_codepoint, .max_codepoint, … })`, `fromRegex(pattern, .{ .fullmatch })` |
| constants / choices | `just(v)`, `sampledFrom(T, items)`, `oneOf(.{ g1, g2 })`, `optionals(g)`, `permutations(T, items)` |
| collections | `lists(g, .{…})`, `uniqueLists(g, .{…})`, `arrays(g, n)`, `tuples(.{ g1, g2 })`, `hashMaps(kg, vg, .{…})`, `hashSets(g, .{…})` |
| transforms | `map(g, f)`, `filter(g, pred)` (prefer bounds over filters), `flatMap(g, f)` |
| dependent draws | `composite(T, fn (*TestCase) DrawError!T)` |
| recursive data | `recursive(T, leaf_gen, extend, .{ .max_depth, .max_leaves })` |
| from a type | `default(T)`: ints, floats, bools, enums, optionals, arrays, `[]const` slices, structs, tagged unions |
| formats | `dates`, `times`, `datetimes`, `uuids(.{ .version })`, `ipv4Addresses`, `ipv6Addresses`, `ipAddresses`, `emails`, `urls`, `domains(.{ .max_length })` |
| grammars | `gen.Grammar.init(gpa, lark_source, .{…})`, then `fromGrammar(&grammar, .{})`; call `grammar.deinit()` |

Use `default(T)` for plain data types and `composite` when one draw
depends on another:

```zig
fn sizedPair(tc: *hegel.TestCase) hegel.DrawError!struct { usize, []const u8 } {
    const n = try tc.draw(gen.integers(usize, .{ .max = 16 }));
    const s = try tc.draw(gen.bytes(.{ .min_size = n, .max_size = n }));
    return .{ n, s };
}
// const p = try tc.draw(gen.composite(struct { usize, []const u8 }, sizedPair));
```

A custom generator is any struct with `pub const Value = T` and
`pub fn generate(self, tc: *hegel.TestCase) hegel.DrawError!T` that draws
its parts with `tc.draw`. It can be nested inside every combinator above.
Draw sub-values through `tc.draw` rather than calling the engine directly,
so the engine can shrink them.

For recursive values, `extend(tc, child)` builds one branch. It must take
`child` as `anytype` and draw sub-values with `tc.draw(child)` (often
`tc.draw(gen.lists(child, .{ .min_size = 1 }))`).

## 5. Stateful testing

Sequential: the engine picks rules, and you apply them to the system under
test and a model.

```zig
var sm = try tc.stateMachine(&.{ "push", "pop", "clear" }, 50);
defer sm.deinit();
while (try sm.nextRule()) |rule| switch (rule) {
    0 => {}, // push: apply to the system and the model, then compare
    1 => if (model_len == 0) try sm.reject() else {}, // precondition failed
    2 => {},
    else => unreachable,
};
```

Use `tc.stateMachineWith(.{ .rules, .invariants, .min_concurrency,
.max_concurrency, .step_count })` for rule groups, weights, invariants
and concurrent workers:

1. Loop `while (try sm.nextGroup()) |group|`.
2. For each worker `i < sm.concurrency`, create a `tc.clone()` and call
   `setWorker(i)` on it. Drive it (on its own thread if you like) with
   `sm.nextRuleFor(&clone, i)` and `sm.rejectFor(&clone, i)`. `deinit` the
   clone when done.
3. At each join point, check invariant `k` when
   `try sm.shouldCheckInvariant(k)`. Always check the initial and final
   states.

Pools of symbolic variables: `tc.pool()` with `add`, `generate(consume)`
and `restore`.

## 6. Dropping to the C API

`hegel.c` is the whole `hegel.h`, translated by Zig. Use it only when the
wrapper lacks something; every `hegel.h` function is already wrapped. If you
do drive it by hand:

- Loop `hegel_next_test_case` and `hegel_mark_complete`, and treat
  `HEGEL_E_STOP_TEST`, `HEGEL_E_ASSUME` and `HEGEL_E_RETRY` as engine
  control flow, not failures.
- Free every engine-owned value with its matching `*_free` function.
- Never share one `hegel_context_t` between threads. Give each thread its
  own context and a `hegel_test_case_clone`.
- Before reading a test case's print document, call
  `hegel_printer_resolve` on its root printer.

`examples/` in the hegel-zig repo shows each libhegel C sample written
against the raw API.

## 7. Verify

```sh
zig build test          # your tests
zig build test -Doptimize=ReleaseSafe
```

A property that never fails proves nothing. When adding one, break the code
under test on purpose once, check that hegel finds and shrinks the bug, then
revert.
