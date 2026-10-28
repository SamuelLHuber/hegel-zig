# hegel-zig

Property-based testing for [Zig](https://ziglang.org), powered by
[Hegel](https://hegel.dev).

Hegel is a property-based testing engine (based on Hypothesis) shipped as a
native library, [libhegel](https://github.com/hegeldev/hegel/tree/main/libhegel),
with a C ABI. Every Hegel frontend — Rust, Python, Go, Odin, Lean, … — is a
thin language layer over that one engine: libhegel does generation, shrinking,
the example database and run scheduling; the frontend only drives the run loop
and offers an idiomatic API.

Zig can consume C headers directly, so hegel-zig does not need a hand-written
FFI layer at all: `build.zig` runs `translate-c` on libhegel's own `hegel.h`
and links the prebuilt static library from the matching libhegel release.
On top of that sits an idiomatic layer (`src/hegel.zig`, `src/gen.zig`).

Requires **Zig 0.17.0**. Pinned to **libhegel 0.48.0**.

## Install

```sh
zig fetch --save git+https://github.com/SamuelLHuber/hegel-zig
```

```zig
// build.zig
const hegel = b.dependency("hegel", .{ .target = target, .optimize = optimize });
my_tests.root_module.addImport("hegel", hegel.module("hegel"));
```

The libhegel static library for the target is downloaded from the
[libhegel GitHub release](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.48.0)
on first build, verified against a pinned SHA-256, and cached by the Zig build
system. To use your own build of libhegel instead (offline builds, unsupported
targets, local engine changes), pass `-Dlibhegel=/path/to/libhegel.a`.

## Usage

```zig
const std = @import("std");
const hegel = @import("hegel");
const gen = hegel.gen;

test "reversing twice is the identity" {
    try hegel.check(.{}, struct {
        fn property(tc: *hegel.TestCase) !void {
            const xs = try tc.draw(gen.lists(gen.integers(i32, .{}), .{}));
            const ys = try tc.allocator().dupe(i32, xs);
            std.mem.reverse(i32, ys);
            std.mem.reverse(i32, ys);
            try tc.expectEqualSlices(i32, xs, ys);
        }
    }.property);
}
```

When a property fails, libhegel shrinks the counterexample and `check` prints
it together with the error return trace, then returns
`error.HegelPropertyFailed`:

```
Property failed (failure 1 of 1, origin: error.HegelPropertyFailed@7d4f…)
Draw 1: { 100 }
error: HegelPropertyFailed: expectation failed
/home/me/project/tests/sum.zig:12:13: 0x… in property (sum.zig)
            try tc.expect(sum < 100);
            ^
Reproduce with: .reproduce = "AAEAAAAB…"
```

Any error returned from the property counts as a failure, so
`std.testing.expect*` works too. `tc.expect` / `tc.expectEqual` /
`tc.fail` are quieter alternatives: they only print in the final report rather
than on every shrink attempt.

### API at a glance

| | |
|---|---|
| `hegel.check(settings, property)` | run in a `test` block; fails with the shrunk counterexample |
| `hegel.checkWithContext(settings, ctx, property)` | same, for `fn (@TypeOf(ctx), *TestCase) !void` |
| `hegel.run(gpa, settings, property)` | returns a `RunResult` (status, failures, reports, reproduction blobs) |
| `tc.draw(generator)` | draw a value; top-level draws appear in the report |
| `hegel.replay(settings, blob, property)` | run one reproduction blob; `.reproduced` or `.passed` |
| `hegel.resolveSettings`, `registerProfile`, `setDefaultProfile`, `setUnicodeVersion` | read back effective settings; process-wide configuration |
| `tc.assume(cond)`, `tc.note(fmt, args)`, `tc.noteLine(s)`, `tc.target(v, label)`, `tc.event(label)`, `tc.eventValue(v, label)` | |
| `tc.allocator()` | arena that lives for the test case |
| `tc.clone()`, `tc.block(indent)`, `tc.setWorker(i)` | handles for concurrent workers and indented output regions |
| `tc.printer(opts)`, `hegel.Printer.init(opts)` | libhegel's pretty-printer: groups, breaks, comments, reflow, deferred holes, speculation |
| `tc.pool()` (`add`, `generate`, `restore`), `tc.collection(min, max)`, `tc.startSpan/stopSpan`, `tc.label`, `tc.labelCombine`, `tc.recursion(depth, leaves)` | low-level engine primitives |
| `tc.stateMachine(rules, max_steps)`, `tc.stateMachineWith(.{ .rules, .invariants, .min_concurrency, .max_concurrency, .step_count })` | stateful testing: rule groups, weights, invariants, workers (`nextGroup`, `nextRuleFor`, `rejectFor`, `shouldCheckInvariant`) |
| `hegel.c` | the full translated libhegel C API |

Every one of the 144 functions in libhegel 0.48.0's `hegel.h` is wrapped
by this layer; `hegel.c` remains available for direct use.

Generators (`hegel.gen`): `integers(T, .{ .min, .max })` (any width, including
`u64`/`i128` via libhegel's big-integer draw), `floats(f32|f64, .{…})`,
`booleans()`, `bytes(.{…})`, `text(.{ .codec, .min_size, .max_size, … })`,
`fromRegex(pattern, .{ .fullmatch })`, `just(v)`, `sampledFrom(T, items)`,
`lists(g, .{…})`, `optionals(g)`, `oneOf(.{ g1, g2, … })`, `map(g, f)`,
`filter(g, pred)`, `weightedBooleans(p)`, `tuples(.{ g1, g2, … })`,
`arrays(g, n)`, `uniqueLists(g, .{…})`, `hashMaps(kg, vg, .{…})`,
`hashSets(g, .{…})`, `permutations(T, items)`, `flatMap(g, f)`,
`composite(T, f)`, `recursive(T, leaf, extend, .{ .max_depth, .max_leaves })`,
`default(T)` (derived from the type at compile time: ints, floats, bools,
enums, optionals, arrays, `[]const` slices, structs, tagged unions),
`dates(.{…})`, `times(.{…})`, `datetimes(.{…})`, `uuids(.{ .version })`,
`ipv4Addresses()`, `ipv6Addresses()`, `ipAddresses()`, `emails()`, `urls()`,
`domains(.{ .max_length })`, and `fromGrammar(&grammar, .{…})` for
[Lark](https://lark-parser.readthedocs.io/) grammars built with
`gen.Grammar.init(gpa, source, .{ .start, .alphabet, .explicit, .files, .diagnostic })`.

A generator is any value with a `Value` type and a
`generate(self, *TestCase) hegel.DrawError!Value` method, so composite
generators are ordinary structs:

```zig
const Points = struct {
    pub const Value = Point;
    pub fn generate(_: Points, tc: *hegel.TestCase) hegel.DrawError!Point {
        return .{
            .x = try tc.draw(gen.integers(i16, .{})),
            .y = try tc.draw(gen.integers(i16, .{})),
        };
    }
};
```

`Settings` mirrors libhegel's: `test_cases`, `seed`, `derandomize`,
`database` (`""` disables it), `database_key`, `verbosity`,
`report_multiple_failures`, `stop_on_first_failure`, `print_blob`, `profile`,
`reproduce` (a reproduction blob), `output` (redirect engine output),
`backend`, `nondeterminism_strictness`, `show_statistics`,
`unbounded_choices`, `phases`, `suppress_health_check` and `test_location`.
`RunResult` carries `error_kind` and `failed_health_check` when a run errors.
Text printed with `tc.noteLine` and test-case printers is appended to the
failure report.
Unset fields keep the engine defaults, including `HEGEL_*` environment
variables and `hegel.toml` profiles.

## Why a wrapper, if Zig can call libhegel directly?

You can skip the wrapper: `hegel.c` is the whole translated C API, and
[`examples/`](examples) uses nothing else. The package has to exist either
way, since something must fetch the pinned library, translate the header and
link it (`link_libcpp` for the Rust unwinder, plus system libraries). The
idiomatic layer on top earns its place because:

- **The C API is a protocol.** A correct run loops over `hegel_next_test_case`
  / `hegel_mark_complete`, maps `STOP_TEST`, `ASSUME` and `RETRY` differently
  from real failures, records draws only on the final replay, frees each
  engine-owned value with its matching function, and collects every
  failure's origin, report and reproduction blob. `hegel.check` does this
  once; written by hand, it is easy to get subtly wrong, and the usual
  symptom is a test that passes when it should fail.
- **It has pitfalls you only find by testing against the engine**, e.g. a
  `hegel_context_t` must not be shared between threads, and the print
  document needs `hegel_printer_resolve` once clones exist. Fixing them here
  means every user gets the fix, and CI checks it on every platform.
- **Zig can do more than C**: generators type-checked and composed at
  compile time, `gen.default(T)` derived via `@typeInfo`, per-test-case
  arenas, and counterexamples reported with Zig error return traces.
- **Upgrades happen in one place.** When libhegel's ABI changes, this layer
  and its tests change, not every project that uses it.

For coding agents, [`.agents/skills/hegel-zig/SKILL.md`](.agents/skills/hegel-zig/SKILL.md)
covers installation, writing properties, generators, stateful testing and
the raw C API. Copy it into your project's `.agents/skills/` (or
`.claude/skills/`) to use it there.

## Examples: the libhegel C samples, in Zig

[`examples/`](examples) is a one-to-one port of
[libhegel's C examples](https://github.com/hegeldev/hegel/tree/main/libhegel/examples),
calling the translated C API directly (no wrapper), to show that libhegel
works from Zig as-is:

| Zig | C original | What it checks |
|---|---|---|
| `echo.zig` | `echo.c` | basic run loop, passing property |
| `failing.zig` | `failing.c` | failure detection, shrinking to `n = 5`, origin and caveat |
| `custom_output.zig` | `custom_output.c` | output callback with `user_data` |
| `invalid_argument.zig` | `invalid_argument.c` | `HEGEL_E_INVALID_ARG` + diagnostics instead of aborts |
| `pool.zig` | `pool.c` | variable pools |
| `spans_collections.zig` | `spans_collections.c` | labels, spans and collections |
| `state_machine.zig` | `state_machine.c` | engine-driven rule selection |

```sh
zig build examples          # build and run all of them (each must exit 0)
zig build run-failing       # run one
zig build test              # the test suite for the idiomatic layer
```

## Platforms

Prebuilt libhegel static libraries are used for `x86_64-linux`,
`aarch64-linux` and `aarch64-macos` (all tested in CI). Other targets
(e.g. Windows, which libhegel ships as MSVC import libraries) need
`-Dlibhegel=…`.

## Development

The dev environment is defined with [devenv](https://devenv.sh): Zig 0.17.0
comes from a locked nixpkgs (`devenv.lock`), and the libhegel archive is
fetched by Nix against the same SHA-256 as `build.zig`, so builds need no
network access beyond the Nix store.

```sh
devenv shell                # zig 0.17.0 + the pinned libhegel on PATH
hz-test                     # zig build test against the Nix-fetched libhegel
hz-examples                 # zig build examples, likewise
hz-check                    # what CI runs: zig fmt --check, tests and examples in Debug and ReleaseSafe
devenv test                 # hz-check in a fresh environment
```

Without devenv, any Zig 0.17.0 works; `build.zig` fetches libhegel itself.

## Notes

- libhegel is a Rust `staticlib`; linking it needs an unwinder, which hegel-zig
  gets from Zig's bundled libc++/libunwind (`link_libcpp`), plus the usual
  system libraries (`pthread`, `dl`, `m`, `rt` on Linux).
- Panics inside a property abort the process, as they do in any Zig test;
  return errors instead.
- `include/hegel.h` is the unmodified header of the pinned libhegel release.
  Upgrading libhegel means replacing it and the checksums in `build.zig` and
  `devenv.nix`.

## License

MIT. libhegel and `include/hegel.h` are MIT-licensed by Antithesis, LLC.
