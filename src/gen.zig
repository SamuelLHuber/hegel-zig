//! Generators: values with a `Value` type and a
//! `generate(self, *TestCase) DrawError!Value` method. Draw them with
//! `tc.draw(generator)`. Any struct with that shape is a generator, so
//! composite generators are ordinary Zig structs.

const std = @import("std");
const hegel = @import("hegel.zig");
const c = hegel.c;
const TestCase = hegel.TestCase;
const DrawError = hegel.DrawError;

pub fn Integers(comptime T: type) type {
    return struct {
        min: T = std.math.minInt(T),
        max: T = std.math.maxInt(T),

        pub const Value = T;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!T {
            return tc.integer(T, self.min, self.max);
        }
    };
}

/// Integers of type `T` in `[min, max]` (default: the whole range of `T`).
pub fn integers(comptime T: type, bounds: Integers(T)) Integers(T) {
    return bounds;
}

pub fn Floats(comptime T: type) type {
    return struct {
        min: ?f64 = null,
        max: ?f64 = null,
        /// Default: allowed only when unbounded.
        allow_nan: ?bool = null,
        /// Default: allowed unless both bounds are set.
        allow_infinity: ?bool = null,
        exclude_min: bool = false,
        exclude_max: bool = false,

        pub const Value = T;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!T {
            return tc.float(T, self);
        }
    };
}

pub fn floats(comptime T: type, opts: Floats(T)) Floats(T) {
    return opts;
}

pub const Booleans = struct {
    p: f64 = 0.5,

    pub const Value = bool;
    pub fn generate(self: Booleans, tc: *TestCase) DrawError!bool {
        return tc.boolean(self.p);
    }
};

pub fn booleans() Booleans {
    return .{};
}

pub const Bytes = struct {
    min_size: u64 = 0,
    max_size: u64 = 64,

    pub const Value = []u8;
    pub fn generate(self: Bytes, tc: *TestCase) DrawError![]u8 {
        return tc.bytes(self.min_size, self.max_size);
    }
};

pub fn bytes(opts: Bytes) Bytes {
    return opts;
}

pub const Text = struct {
    min_size: u64 = 0,
    max_size: u64 = 64,
    /// `"ascii"`, `"latin-1"` or `"utf-8"` (the default).
    codec: ?[]const u8 = null,
    min_codepoint: u32 = 0,
    max_codepoint: u32 = std.math.maxInt(u32),
    include_characters: []const u8 = "",
    exclude_characters: []const u8 = "",

    pub const Value = []const u8;
    pub fn generate(self: Text, tc: *TestCase) DrawError![]const u8 {
        var g: ?*c.hegel_string_generator_t = null;
        const codec: ?c.hegel_string_t = if (self.codec) |cd| hegel.str(cd) else null;
        try tc.wrap(c.hegel_string_generator_text(
            tc.ctx,
            self.min_size,
            self.max_size,
            if (codec) |*cd| cd else null,
            self.min_codepoint,
            self.max_codepoint,
            null,
            0,
            null,
            0,
            hegel.str(self.include_characters),
            hegel.str(self.exclude_characters),
            &g,
        ));
        defer _ = c.hegel_string_generator_free(tc.ctx, g);
        return tc.string(g.?);
    }
};

/// UTF-8 strings of `min_size..max_size` code points.
pub fn text(opts: Text) Text {
    return opts;
}

pub const Regex = struct {
    pattern: []const u8,
    fullmatch: bool = false,

    pub const Value = []const u8;
    pub fn generate(self: Regex, tc: *TestCase) DrawError![]const u8 {
        var g: ?*c.hegel_string_generator_t = null;
        try tc.wrap(c.hegel_string_generator_regex(tc.ctx, hegel.str(self.pattern), self.fullmatch, null, &g));
        defer _ = c.hegel_string_generator_free(tc.ctx, g);
        return tc.string(g.?);
    }
};

/// Strings matching `pattern` (anywhere, or entirely with `.fullmatch`).
pub fn fromRegex(pattern: []const u8, opts: struct { fullmatch: bool = false }) Regex {
    return .{ .pattern = pattern, .fullmatch = opts.fullmatch };
}

pub fn Just(comptime T: type) type {
    return struct {
        value: T,

        pub const Value = T;
        pub fn generate(self: @This(), _: *TestCase) DrawError!T {
            return self.value;
        }
    };
}

pub fn just(value: anytype) Just(@TypeOf(value)) {
    return .{ .value = value };
}

pub fn SampledFrom(comptime T: type) type {
    return struct {
        items: []const T,

        pub const Value = T;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!T {
            if (self.items.len == 0) return error.HegelInvalidArgument;
            return self.items[try tc.integer(usize, 0, self.items.len - 1)];
        }
    };
}

/// One of `items`, shrinking towards the first.
pub fn sampledFrom(comptime T: type, items: []const T) SampledFrom(T) {
    return .{ .items = items };
}

pub fn Lists(comptime G: type) type {
    return struct {
        element: G,
        min_size: u64 = 0,
        max_size: u64 = 32,

        pub const Value = []G.Value;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.list"));
            const coll = try tc.collection(self.min_size, self.max_size);
            defer coll.deinit();
            var items: std.ArrayList(G.Value) = .empty;
            const element_label = try tc.label("hegel-zig.list_element");
            while (try coll.more()) {
                try tc.startSpan(element_label);
                try items.append(tc.arena, try tc.draw(self.element));
                try tc.stopSpan(false);
            }
            try tc.stopSpan(false);
            return items.items;
        }
    };
}

/// Slices of `element` values, allocated in the test case's arena.
pub fn lists(element: anytype, opts: struct { min_size: u64 = 0, max_size: u64 = 32 }) Lists(@TypeOf(element)) {
    return .{ .element = element, .min_size = opts.min_size, .max_size = opts.max_size };
}

pub fn Optionals(comptime G: type) type {
    return struct {
        element: G,

        pub const Value = ?G.Value;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.optional"));
            const value: Value = if (try tc.boolean(0.75)) try tc.draw(self.element) else null;
            try tc.stopSpan(false);
            return value;
        }
    };
}

/// `null` or a value of `element`, shrinking towards `null`.
pub fn optionals(element: anytype) Optionals(@TypeOf(element)) {
    return .{ .element = element };
}

pub fn OneOf(comptime Gs: type) type {
    const info = @typeInfo(Gs).@"struct";
    const names = info.field_names;
    return struct {
        generators: Gs,

        pub const Value = info.field_types[0].Value;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.one_of"));
            const index = try tc.integer(usize, 0, names.len - 1);
            const value = blk: inline for (names, 0..) |name, i| {
                if (i == index) break :blk try tc.draw(@field(self.generators, name));
            } else unreachable;
            try tc.stopSpan(false);
            return value;
        }
    };
}

/// A value from one of the generators in the tuple `generators` (which must
/// share a `Value` type), shrinking towards the first.
pub fn oneOf(generators: anytype) OneOf(@TypeOf(generators)) {
    return .{ .generators = generators };
}

pub fn Map(comptime G: type, comptime f: anytype) type {
    return struct {
        inner: G,

        pub const Value = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            return f(try tc.draw(self.inner));
        }
    };
}

/// `f(value)` for each `value` drawn from `inner`.
pub fn map(inner: anytype, comptime f: anytype) Map(@TypeOf(inner), f) {
    return .{ .inner = inner };
}

pub fn Filter(comptime G: type, comptime predicate: fn (G.Value) bool) type {
    return struct {
        inner: G,

        pub const Value = G.Value;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            const filter_label = try tc.label("hegel-zig.filter");
            for (0..3) |_| {
                try tc.startSpan(filter_label);
                const value = try tc.draw(self.inner);
                if (predicate(value)) {
                    try tc.stopSpan(false);
                    return value;
                }
                try tc.stopSpan(true);
            }
            return error.HegelAssume;
        }
    };
}

/// Values of `inner` satisfying `predicate`; rejects the test case after
/// three misses, so keep the predicate permissive.
pub fn filter(inner: anytype, comptime predicate: fn (@TypeOf(inner).Value) bool) Filter(@TypeOf(inner), predicate) {
    return .{ .inner = inner };
}
