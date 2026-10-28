//! Shared helpers for the example programs; the Zig counterpart of
//! libhegel's `examples/hegel_check.h`.

const std = @import("std");
pub const c = @import("hegel_c");

pub const CallError = error{HegelCallFailed};

/// Fails with a diagnostic (the context's last error) unless `rc` is
/// `HEGEL_OK`. Use it for setup / bookkeeping / teardown calls whose only
/// non-zero outcome would be a programming error, not for draws.
pub fn ok(ctx: ?*c.hegel_context_t, rc: c.hegel_result_t) CallError!void {
    if (rc == c.HEGEL_OK) return;
    std.debug.print("libhegel call failed: rc={d}: {s}\n", .{ rc, slice(c.hegel_context_last_error(ctx)) });
    return error.HegelCallFailed;
}

/// A `hegel_string_t` borrowing `s` (NULL data for the empty string, like
/// the C examples' `HEGEL_STRING`).
pub fn str(s: []const u8) c.hegel_string_t {
    return .{ .data = if (s.len == 0) null else s.ptr, .len = s.len };
}

pub fn slice(s: c.hegel_string_t) []const u8 {
    return if (s.len == 0) "" else s.data[0..s.len];
}
