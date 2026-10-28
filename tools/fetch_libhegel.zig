//! Build-time helper: downloads a libhegel release artifact, verifies its
//! SHA-256 digest and writes it to the requested output path.
//!
//! Usage: fetch_libhegel <url> <sha256-hex> <out-path>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) fatal("usage: fetch_libhegel <url> <sha256> <out>", .{});
    const url = args[1];
    const want = args[2];
    const out_path = args[3];

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    try client.initDefaultProxies(arena, init.environ_map);

    var body: std.Io.Writer.Allocating = .init(init.gpa);
    defer body.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch |err| fatal("failed to download {s}: {t}", .{ url, err });
    if (res.status != .ok) fatal("failed to download {s}: HTTP {d}", .{ url, @backingInt(res.status) });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body.written(), &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&got, want)) {
        fatal("checksum mismatch for {s}\n  expected {s}\n  got      {s}", .{ url, want, &got });
    }

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body.written());
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fetch_libhegel: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
