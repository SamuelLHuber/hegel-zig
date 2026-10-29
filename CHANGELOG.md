# Changelog

All notable changes to hegel-zig are documented here. Versions follow
[Semantic Versioning](https://semver.org); while the version is 0.x, minor
releases may break the API.

## [0.1.0] - 2026-10-29

First release. Requires Zig 0.17.0; pinned to libhegel 0.48.0.

### Added

- `hegel.c`: the complete libhegel 0.48.0 C API, translated from the
  vendored, SHA-256-checked `include/hegel.h`.
- An idiomatic layer that calls all 144 functions of that API:
  `hegel.check` for `zig test`, `hegel.run` and `RunResult`, `hegel.replay`
  from a failure blob, `TestCase` (draws, `assume`, notes, events, targets,
  spans, clones, blocks, pools, printer), and every setting, including
  phases, health checks, backends, profiles and `hegel.resolveSettings`.
- `hegel.gen` generators: integers of any width, floats, booleans, bytes,
  text, regex, `just`, `sampledFrom`, `oneOf`, optionals, lists, unique
  lists, arrays, tuples, hash maps and sets, permutations, `map`, `filter`,
  `flatMap`, `composite`, `recursive`, dates, times, datetimes, UUIDs, IP
  addresses, emails, URLs, domains, Lark grammars, and `default(T)`, which
  derives a generator from a type at compile time.
- Stateful testing: rules, rule groups, weights, invariants and concurrent
  workers.
- `hegel.Printer`, wrapping libhegel's pretty-printer for counterexamples.
- The seven libhegel C samples, ported to Zig (`zig build examples`).
- An agent skill, `.agents/skills/hegel-zig/SKILL.md`, shipped in the package.
- A devenv environment with every dependency pinned and checksum-verified.

[0.1.0]: https://github.com/SamuelLHuber/hegel-zig/releases/tag/v0.1.0
