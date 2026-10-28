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

/// Booleans that are true with probability `p`.
pub fn weightedBooleans(p: f64) Booleans {
    return .{ .p = p };
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
        try tc.wrap(self.build(tc.ctx, &g));
        defer _ = c.hegel_string_generator_free(tc.ctx, g);
        return tc.string(g.?);
    }

    fn build(self: Text, ctx: *c.hegel_context_t, out: *?*c.hegel_string_generator_t) c.hegel_result_t {
        const codec: ?c.hegel_string_t = if (self.codec) |cd| hegel.str(cd) else null;
        return c.hegel_string_generator_text(
            ctx,
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
            out,
        );
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

pub const Date = c.hegel_date_t;
pub const Time = c.hegel_time_t;
pub const DateTime = c.hegel_datetime_t;

pub const Dates = struct {
    min: Date = .{ .year = 1, .month = 1, .day = 1 },
    max: Date = .{ .year = 9999, .month = 12, .day = 31 },

    pub const Value = Date;
    pub fn generate(self: Dates, tc: *TestCase) DrawError!Date {
        var out: Date = undefined;
        try tc.wrap(c.hegel_generate_date(tc.ctx, tc.raw, self.min, self.max, &out));
        return out;
    }
};

/// Proleptic Gregorian dates, shrinking toward 2000-01-01.
pub fn dates(bounds: Dates) Dates {
    return bounds;
}

pub const Times = struct {
    min: Time = .{ .hour = 0, .minute = 0, .second = 0, .nanosecond = 0 },
    max: Time = .{ .hour = 23, .minute = 59, .second = 59, .nanosecond = 999_999_999 },

    pub const Value = Time;
    pub fn generate(self: Times, tc: *TestCase) DrawError!Time {
        var out: Time = undefined;
        try tc.wrap(c.hegel_generate_time(tc.ctx, tc.raw, self.min, self.max, &out));
        return out;
    }
};

/// Times of day, shrinking toward `min`.
pub fn times(bounds: Times) Times {
    return bounds;
}

pub const DateTimes = struct {
    min: DateTime = .{ .date = (Dates{}).min, .time = (Times{}).min },
    max: DateTime = .{ .date = (Dates{}).max, .time = (Times{}).max },

    pub const Value = DateTime;
    pub fn generate(self: DateTimes, tc: *TestCase) DrawError!DateTime {
        var out: DateTime = undefined;
        try tc.wrap(c.hegel_generate_datetime(tc.ctx, tc.raw, self.min, self.max, &out));
        return out;
    }
};

/// Naive (timezone-free) datetimes, shrinking toward 2000-01-01T00:00:00.
pub fn datetimes(bounds: DateTimes) DateTimes {
    return bounds;
}

pub const Uuids = struct {
    /// Forces the RFC 4122 version nibble (and variant) when set.
    version: ?u4 = null,

    pub const Value = [16]u8;
    pub fn generate(self: Uuids, tc: *TestCase) DrawError![16]u8 {
        var out: [16]u8 = undefined;
        try tc.wrap(c.hegel_generate_uuid(tc.ctx, tc.raw, self.version orelse 0, self.version != null, &out));
        return out;
    }
};

/// 16 big-endian UUID bytes; never the nil UUID.
pub fn uuids(opts: Uuids) Uuids {
    return opts;
}

pub const Ipv4Addresses = struct {
    pub const Value = [4]u8;
    pub fn generate(_: Ipv4Addresses, tc: *TestCase) DrawError![4]u8 {
        var out: [4]u8 = undefined;
        try tc.wrap(c.hegel_generate_ipv4(tc.ctx, tc.raw, &out));
        return out;
    }
};

pub const Ipv6Addresses = struct {
    pub const Value = [16]u8;
    pub fn generate(_: Ipv6Addresses, tc: *TestCase) DrawError![16]u8 {
        var out: [16]u8 = undefined;
        try tc.wrap(c.hegel_generate_ipv6(tc.ctx, tc.raw, &out));
        return out;
    }
};

pub const IpAddress = union(enum) { v4: [4]u8, v6: [16]u8 };

pub const IpAddresses = struct {
    pub const Value = IpAddress;
    pub fn generate(_: IpAddresses, tc: *TestCase) DrawError!IpAddress {
        if (try tc.boolean(0.5)) return .{ .v6 = try tc.draw(Ipv6Addresses{}) };
        return .{ .v4 = try tc.draw(Ipv4Addresses{}) };
    }
};

/// Network-order IPv4 address bytes.
pub fn ipv4Addresses() Ipv4Addresses {
    return .{};
}

/// Network-order IPv6 address bytes.
pub fn ipv6Addresses() Ipv6Addresses {
    return .{};
}

/// IPv4 or IPv6 addresses.
pub fn ipAddresses() IpAddresses {
    return .{};
}

pub const FormattedString = struct {
    kind: enum { email, url, domain },
    max_length: u64 = 255,

    pub const Value = []const u8;
    pub fn generate(self: FormattedString, tc: *TestCase) DrawError![]const u8 {
        var g: ?*c.hegel_string_generator_t = null;
        try tc.wrap(switch (self.kind) {
            .email => c.hegel_string_generator_email(tc.ctx, &g),
            .url => c.hegel_string_generator_url(tc.ctx, &g),
            .domain => c.hegel_string_generator_domain(tc.ctx, self.max_length, &g),
        });
        defer _ = c.hegel_string_generator_free(tc.ctx, g);
        return tc.string(g.?);
    }
};

/// RFC 5321/5322 email addresses.
pub fn emails() FormattedString {
    return .{ .kind = .email };
}

/// RFC 3986 http/https URLs.
pub fn urls() FormattedString {
    return .{ .kind = .url };
}

/// Fully-qualified domain names of at most `max_length` (4..=255) characters.
pub fn domains(opts: struct { max_length: u64 = 255 }) FormattedString {
    return .{ .kind = .domain, .max_length = opts.max_length };
}

/// A compiled Lark grammar. Build once, draw with `gen.fromGrammar`.
pub const Grammar = struct {
    ctx: *c.hegel_context_t,
    raw: *c.hegel_grammar_t,

    pub const File = struct { path: []const u8, text: []const u8 };

    pub const Options = struct {
        /// The rule to generate; `start` when null.
        start: ?[]const u8 = null,
        /// Most characters per string; 0 for the engine default (8192).
        max_size: u64 = 0,
        /// Rule nesting limit; 0 for the engine default (200).
        max_depth: u32 = 0,
        /// Restricts generated terminals to this alphabet.
        alphabet: ?Text = null,
        /// `%declare`d terminals, emitted as markers (see `placeholder`).
        explicit: []const []const u8 = &.{},
        /// Contents for the grammar's `%import`s; unlisted paths fall back
        /// to the grammars bundled with libhegel.
        files: []const File = &.{},
        /// Receives libhegel's explanation when `init` fails.
        diagnostic: ?*std.Io.Writer = null,
    };

    pub const InitError = error{ HegelInvalidArgument, OutOfMemory };

    pub fn init(gpa: std.mem.Allocator, source: []const u8, options: Options) InitError!Grammar {
        const ctx = c.hegel_context_new().?;
        errdefer _ = c.hegel_context_free(ctx);
        var builder: ?*c.hegel_grammar_builder_t = null;
        try check(ctx, options.diagnostic, c.hegel_grammar_builder_new(ctx, hegel.str(source), &builder));
        defer _ = c.hegel_grammar_builder_free(ctx, builder);
        var index: usize = 0;
        while (true) : (index += 1) {
            var path: c.hegel_string_t = undefined;
            const rc = c.hegel_grammar_builder_file(ctx, builder, index, &path);
            if (rc == c.HEGEL_E_NOT_FOUND) break;
            try check(ctx, options.diagnostic, rc);
            const wanted = if (path.len == 0) "" else path.data[0..path.len];
            const contents: ?c.hegel_string_t = for (options.files) |f| {
                if (std.mem.eql(u8, f.path, wanted)) break hegel.str(f.text);
            } else null;
            try check(ctx, options.diagnostic, c.hegel_grammar_builder_provide(ctx, builder, index, if (contents) |*t| t else null));
        }
        const start: ?c.hegel_string_t = if (options.start) |st| hegel.str(st) else null;
        const explicit = try gpa.alloc(c.hegel_string_t, options.explicit.len);
        defer gpa.free(explicit);
        for (options.explicit, explicit) |name, *e| e.* = hegel.str(name);
        var alphabet: ?*c.hegel_string_generator_t = null;
        defer _ = c.hegel_string_generator_free(ctx, alphabet);
        if (options.alphabet) |a| try check(ctx, options.diagnostic, a.build(ctx, &alphabet));
        var raw: ?*c.hegel_grammar_t = null;
        try check(ctx, options.diagnostic, c.hegel_grammar_new(
            ctx,
            builder,
            if (start) |*st| st else null,
            options.max_size,
            options.max_depth,
            alphabet,
            explicit.ptr,
            explicit.len,
            &raw,
        ));
        return .{ .ctx = ctx, .raw = raw.? };
    }

    pub fn deinit(self: *Grammar) void {
        _ = c.hegel_grammar_free(self.ctx, self.raw);
        _ = c.hegel_context_free(self.ctx);
        self.* = undefined;
    }

    /// The marker that stands for explicit terminal `name` in generated
    /// strings. Borrowed from the grammar.
    pub fn placeholder(self: Grammar, name: []const u8) error{HegelInvalidArgument}![]const u8 {
        var out: c.hegel_string_t = undefined;
        try check(self.ctx, null, c.hegel_grammar_placeholder(self.ctx, self.raw, hegel.str(name), &out));
        return if (out.len == 0) "" else out.data[0..out.len];
    }

    /// The diagnostic for the last failed call (e.g. a grammar error).
    pub fn lastErrorMessage(self: Grammar) []const u8 {
        return hegel.lastErrorMessage(self.ctx);
    }

    fn check(ctx: *c.hegel_context_t, diagnostic: ?*std.Io.Writer, rc: c.hegel_result_t) error{HegelInvalidArgument}!void {
        if (rc == c.HEGEL_OK) return;
        if (diagnostic) |w| w.writeAll(hegel.lastErrorMessage(ctx)) catch {};
        return error.HegelInvalidArgument;
    }
};

pub const FromGrammar = struct {
    grammar: *const Grammar,
    max_size: u64 = 0,

    pub const Value = []const u8;
    pub fn generate(self: FromGrammar, tc: *TestCase) DrawError![]const u8 {
        var res: c.hegel_owned_string_t = undefined;
        try tc.wrap(c.hegel_generate_grammar(tc.ctx, tc.raw, self.grammar.raw, self.max_size, &res));
        defer _ = c.hegel_owned_string_free(tc.ctx, &res);
        return tc.arena.dupe(u8, if (res.len == 0) "" else res.data[0..res.len]);
    }
};

/// Strings in the language of `grammar`.
pub fn fromGrammar(grammar: *const Grammar, opts: struct { max_size: u64 = 0 }) FromGrammar {
    return .{ .grammar = grammar, .max_size = opts.max_size };
}

fn ValuesOf(comptime Gs: type) type {
    const field_types = @typeInfo(Gs).@"struct".field_types;
    var values: [field_types.len]type = undefined;
    for (field_types, &values) |G, *V| V.* = G.Value;
    const frozen = values;
    return @Tuple(&frozen);
}

pub fn Tuples(comptime Gs: type) type {
    return struct {
        generators: Gs,

        pub const Value = ValuesOf(Gs);
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.tuple"));
            var out: Value = undefined;
            inline for (0..@typeInfo(Gs).@"struct".field_types.len) |i| out[i] = try tc.draw(self.generators[i]);
            try tc.stopSpan(false);
            return out;
        }
    };
}

/// Tuples drawing each element from the matching generator in `generators`.
pub fn tuples(generators: anytype) Tuples(@TypeOf(generators)) {
    return .{ .generators = generators };
}

pub fn Arrays(comptime G: type, comptime n: usize) type {
    return struct {
        element: G,

        pub const Value = [n]G.Value;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.array"));
            var out: Value = undefined;
            for (&out) |*v| v.* = try tc.draw(self.element);
            try tc.stopSpan(false);
            return out;
        }
    };
}

/// Fixed-length arrays of `n` elements.
pub fn arrays(element: anytype, comptime n: usize) Arrays(@TypeOf(element), n) {
    return .{ .element = element };
}

fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (T == []const u8 or T == []u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

pub fn UniqueLists(comptime G: type) type {
    return struct {
        element: G,
        min_size: u64 = 0,
        max_size: u64 = 32,

        pub const Value = []G.Value;
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.unique_list"));
            const coll = try tc.collection(self.min_size, self.max_size);
            defer coll.deinit();
            var items: std.ArrayList(G.Value) = .empty;
            const element_label = try tc.label("hegel-zig.list_element");
            outer: while (try coll.more()) {
                try tc.startSpan(element_label);
                const v = try tc.draw(self.element);
                for (items.items) |existing| if (eql(existing, v)) {
                    try tc.stopSpan(true);
                    try coll.reject("duplicate element");
                    continue :outer;
                };
                try tc.stopSpan(false);
                try items.append(tc.arena, v);
            }
            try tc.stopSpan(false);
            return items.items;
        }
    };
}

/// Lists without duplicate elements (compared with `std.mem.eql` for byte
/// slices and `std.meta.eql` otherwise).
pub fn uniqueLists(element: anytype, opts: struct { min_size: u64 = 0, max_size: u64 = 32 }) UniqueLists(@TypeOf(element)) {
    return .{ .element = element, .min_size = opts.min_size, .max_size = opts.max_size };
}

fn MapOf(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringArrayHashMapUnmanaged(V);
    return std.AutoArrayHashMapUnmanaged(K, V);
}

pub fn HashMaps(comptime KG: type, comptime VG: type) type {
    return struct {
        keys: KG,
        values: VG,
        min_size: u64 = 0,
        max_size: u64 = 32,

        pub const Value = MapOf(KG.Value, VG.Value);
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.hash_map"));
            const coll = try tc.collection(self.min_size, self.max_size);
            defer coll.deinit();
            var out: Value = .empty;
            const entry_label = try tc.label("hegel-zig.hash_map_entry");
            while (try coll.more()) {
                try tc.startSpan(entry_label);
                const k = try tc.draw(self.keys);
                if (out.contains(k)) {
                    try tc.stopSpan(true);
                    try coll.reject("duplicate key");
                    continue;
                }
                const v = try tc.draw(self.values);
                try tc.stopSpan(false);
                try out.put(tc.arena, k, v);
            }
            try tc.stopSpan(false);
            return out;
        }
    };
}

/// Array hash maps (insertion-ordered) with distinct keys.
pub fn hashMaps(keys: anytype, values: anytype, opts: struct { min_size: u64 = 0, max_size: u64 = 32 }) HashMaps(@TypeOf(keys), @TypeOf(values)) {
    return .{ .keys = keys, .values = values, .min_size = opts.min_size, .max_size = opts.max_size };
}

/// Sets as array hash maps with `void` values.
pub fn hashSets(elements: anytype, opts: struct { min_size: u64 = 0, max_size: u64 = 32 }) HashMaps(@TypeOf(elements), Just(void)) {
    return .{ .keys = elements, .values = just({}), .min_size = opts.min_size, .max_size = opts.max_size };
}

pub fn Permutations(comptime T: type) type {
    return struct {
        items: []const T,

        pub const Value = []T;
        pub fn generate(self: @This(), tc: *TestCase) DrawError![]T {
            const out = try tc.arena.dupe(T, self.items);
            if (out.len < 2) return out;
            for (0..out.len - 1) |i| {
                const j = try tc.integer(usize, i, out.len - 1);
                std.mem.swap(T, &out[i], &out[j]);
            }
            return out;
        }
    };
}

/// Orderings of `items`, shrinking toward the original order.
pub fn permutations(comptime T: type, items: []const T) Permutations(T) {
    return .{ .items = items };
}

fn FlatMapValue(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?.Value;
}

pub fn FlatMap(comptime G: type, comptime f: anytype) type {
    return struct {
        inner: G,

        pub const Value = FlatMapValue(f);
        pub fn generate(self: @This(), tc: *TestCase) DrawError!Value {
            try tc.startSpan(try tc.label("hegel-zig.flat_map"));
            const v = try tc.draw(f(try tc.draw(self.inner)));
            try tc.stopSpan(false);
            return v;
        }
    };
}

/// Draws from the generator `f` returns for a value of `inner`.
pub fn flatMap(inner: anytype, comptime f: anytype) FlatMap(@TypeOf(inner), f) {
    return .{ .inner = inner };
}

pub fn Composite(comptime T: type, comptime f: fn (*TestCase) DrawError!T) type {
    return struct {
        pub const Value = T;
        pub fn generate(_: @This(), tc: *TestCase) DrawError!T {
            try tc.startSpan(try tc.label("hegel-zig.composite"));
            const v = try f(tc);
            try tc.stopSpan(false);
            return v;
        }
    };
}

/// A generator from a function that draws freely, e.g. a length then a list
/// of that length.
pub fn composite(comptime T: type, comptime f: fn (*TestCase) DrawError!T) Composite(T, f) {
    return .{};
}

pub fn Recursive(comptime T: type, comptime Leaf: type, comptime extend: anytype) type {
    return struct {
        const Self = @This();
        leaf: Leaf,
        max_depth: u64 = 5,
        max_leaves: u64 = 50,

        /// The handle `extend` draws its sub-values through.
        pub const Child = struct {
            self: *const Self,
            rec: hegel.Recursion,
            depth: u64,

            pub const Value = T;
            pub fn generate(child: Child, tc: *TestCase) DrawError!T {
                try tc.startSpan(try tc.label("hegel-zig.recursive_node"));
                const v = if (try child.rec.branch(child.depth))
                    try extend(tc, Child{ .self = child.self, .rec = child.rec, .depth = child.depth + 1 })
                else leaf: {
                    try child.rec.leaf();
                    break :leaf try tc.draw(child.self.leaf);
                };
                try tc.stopSpan(false);
                return v;
            }
        };

        pub const Value = T;
        pub fn generate(self: *const Self, tc: *TestCase) DrawError!T {
            const rec = try tc.recursion(self.max_depth, self.max_leaves);
            defer rec.deinit();
            while (true) {
                const root: Child = .{ .self = self, .rec = rec, .depth = 0 };
                const v = tc.draw(root) catch |err| switch (err) {
                    error.HegelRetry => {
                        try rec.retry();
                        continue;
                    },
                    else => return err,
                };
                rec.finish() catch |err| switch (err) {
                    error.HegelRetry => continue,
                    else => return err,
                };
                return v;
            }
        }
    };
}

/// Recursive values: leaves come from `leaf`; `extend(tc, child)` builds a
/// branch, drawing sub-values with `tc.draw(child)`. The engine bounds depth
/// and leaf count and retries oversized attempts.
pub fn recursive(comptime T: type, leaf: anytype, comptime extend: anytype, opts: struct { max_depth: u64 = 5, max_leaves: u64 = 50 }) Recursive(T, @TypeOf(leaf), extend) {
    return .{ .leaf = leaf, .max_depth = opts.max_depth, .max_leaves = opts.max_leaves };
}

pub fn Default(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub fn generate(_: @This(), tc: *TestCase) DrawError!T {
            switch (@typeInfo(T)) {
                .bool => return tc.boolean(0.5),
                .int => return tc.integer(T, std.math.minInt(T), std.math.maxInt(T)),
                .float => return tc.float(T, .{}),
                .void => return {},
                .@"enum" => |info| {
                    const tags = comptime blk: {
                        var out: [info.field_values.len]T = undefined;
                        for (info.field_values, &out) |v, *t| t.* = @fromBackingInt(@intCast(v));
                        break :blk out;
                    };
                    return tc.draw(sampledFrom(T, &tags));
                },
                .optional => |info| return tc.draw(optionals(default(info.child))),
                .array => |info| return tc.draw(arrays(default(info.child), info.len)),
                .pointer => |info| {
                    if (info.size != .slice or !info.attrs.@"const") @compileError("hegel.gen.default: unsupported pointer type " ++ @typeName(T));
                    if (info.child == u8) return tc.draw(text(.{}));
                    return tc.draw(lists(default(info.child), .{}));
                },
                .@"struct" => |info| {
                    var out: T = undefined;
                    inline for (info.field_names, info.field_types) |name, FT| @field(out, name) = try tc.draw(default(FT));
                    return out;
                },
                .@"union" => |info| {
                    if (info.tag_type == null) @compileError("hegel.gen.default: untagged union " ++ @typeName(T));
                    const n = info.field_names.len;
                    const pick = try tc.integer(usize, 0, n - 1);
                    inline for (info.field_names, info.field_types, 0..) |name, FT, i| {
                        if (i == pick) return @unionInit(T, name, try tc.draw(default(FT)));
                    }
                    unreachable;
                },
                else => @compileError("hegel.gen.default: unsupported type " ++ @typeName(T)),
            }
        }
    };
}

/// A generator for any value of `T`, derived from its type: integers,
/// floats, bools, enums, optionals, arrays, `[]const u8` (text), other
/// const slices (lists), structs and tagged unions.
pub fn default(comptime T: type) Default(T) {
    return .{};
}
