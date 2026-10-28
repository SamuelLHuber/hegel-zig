const std = @import("std");

/// The libhegel release this package is pinned to. `include/hegel.h` is the
/// header from the same release.
pub const libhegel_version = "0.48.0";

const Artifact = struct { name: []const u8, sha256: []const u8 };

fn artifactFor(target: std.Target) ?Artifact {
    return switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            .x86_64 => .{ .name = "libhegel-linux-amd64.a", .sha256 = "9123fd093e9994e0fb5b5151e5429b27991180a962352024e5dd588c1ec48dbd" },
            .aarch64 => .{ .name = "libhegel-linux-arm64.a", .sha256 = "622a2fce27cea68ea22a742a9b4a1361032d0e725f40773f4725422c0f55a56b" },
            else => null,
        },
        .macos => switch (target.cpu.arch) {
            .aarch64 => .{ .name = "libhegel-darwin-arm64.a", .sha256 = "c8d3478e5eb4e21f5a14770b42842922c2a14d58736782448236748dc3a497e4" },
            else => null,
        },
        else => null,
    };
}

const examples = [_][]const u8{
    "echo",
    "failing",
    "custom_output",
    "invalid_argument",
    "pool",
    "spans_collections",
    "state_machine",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libhegel_override = b.option(
        []const u8,
        "libhegel",
        "Path to a libhegel static library to link instead of downloading the pinned release",
    );

    const libhegel = libhegelArchive(b, target.result, libhegel_override);

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("include/hegel.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_mod = b.addModule("hegel_c", .{
        .root_source_file = translate.getOutput(),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkLibhegel(c_mod, target.result, libhegel);

    const hegel_mod = b.addModule("hegel", .{
        .root_source_file = b.path("src/hegel.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hegel_c", .module = c_mod }},
    });

    const test_step = b.step("test", "Run the hegel-zig test suite");
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};
    const unit_tests = b.addTest(.{ .root_module = hegel_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    for ([_][]const u8{ "tests/properties.zig", "tests/failures.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "hegel_c", .module = c_mod },
                    .{ .name = "hegel", .module = hegel_mod },
                },
            }),
            .filters = test_filters,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const examples_step = b.step("examples", "Build and run every ported libhegel example");
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "hegel_c", .module = c_mod },
                    .{ .name = "hegel", .module = hegel_mod },
                },
            }),
        });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.expectExitCode(0);
        examples_step.dependOn(&run.step);
        const run_one = b.addRunArtifact(exe);
        run_one.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run examples/{s}.zig", .{name})).dependOn(&run_one.step);
    }
}

fn libhegelArchive(b: *std.Build, target: std.Target, override: ?[]const u8) std.Build.LazyPath {
    if (override) |path| return .{ .cwd_relative = path };
    const artifact = artifactFor(target) orelse {
        const fail = b.addFail(b.fmt(
            "no prebuilt libhegel {s} for {s}-{s}; build libhegel yourself and pass -Dlibhegel=/path/to/libhegel.a",
            .{ libhegel_version, @tagName(target.cpu.arch), @tagName(target.os.tag) },
        ));
        const wf = b.addWriteFiles();
        wf.step.dependOn(&fail.step);
        return wf.add("libhegel-unsupported.a", "");
    };
    const fetcher = b.addExecutable(.{
        .name = "fetch_libhegel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_libhegel.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const fetch = b.addRunArtifact(fetcher);
    fetch.addArg(b.fmt(
        "https://github.com/hegeldev/hegel/releases/download/libhegel/{s}/{s}",
        .{ libhegel_version, artifact.name },
    ));
    fetch.addArg(artifact.sha256);
    return fetch.addOutputFileArg(artifact.name);
}

fn linkLibhegel(mod: *std.Build.Module, target: std.Target, archive: std.Build.LazyPath) void {
    mod.addObjectFile(archive);
    // libhegel is a Rust staticlib; it needs the unwinder that ships with
    // Zig's libc++/libunwind plus the usual system libraries Rust's std uses.
    mod.link_libcpp = true;
    switch (target.os.tag) {
        .linux => for ([_][]const u8{ "pthread", "dl", "m", "rt" }) |lib| mod.linkSystemLibrary(lib, .{}),
        .macos => {
            mod.linkSystemLibrary("iconv", .{});
            mod.linkFramework("CoreFoundation", .{});
            mod.linkFramework("Security", .{});
        },
        else => {},
    }
}
