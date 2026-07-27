const std = @import("std");

/// How an axis binding is answered. Every evaluation surface (axis/row-expr
/// evaluators, overlay/fragment tuple matching, script-stage gates, the facts
/// interview, ignore-rule gates, the catA whole-file gate) takes a `Resolver`
/// instead of a raw bindings map, so the answer source can vary without
/// touching any of those call sites.
///
/// - `live`: this machine's captured snapshot (what `apply`/`status`/`diff`/
///   `export` compose against).
/// - `fixed`: a snapshot for a hypothetical configuration (doctor's axis-space
///   walk, classify/config-space, impact analysis, commit's cross-
///   configuration verification) -- never probes, distinct from `live` only
///   by tag.
/// - `override`: a layer that wins over an inner resolver, carrying
///   `export --as` tuples or the facts interview's working set. An axis the
///   override map touches at all (its direct key or any of its compound
///   `axis=value` keys) answers entirely from the override, never falling
///   through to the inner resolver even for a value the override itself does
///   not name -- so an overridden axis's real binding never leaks through.
pub const Resolver = union(enum) {
    live: *const Live,
    fixed: *const std.StringHashMap([]const u8),
    override: *const Override,

    /// A live snapshot plus its lazy tool-probe layer. `bindings` answers
    /// exactly like `fixed`'s map; `probe`, when present, is asked for
    /// `tool=name` only when `bindings` does not already carry that name --
    /// so a name the eager watch-list scan seeded never probes, and only a
    /// name it never asked about does. `probe` is null for a resolver built
    /// without one (every hand-built test fixture); a real captured machine
    /// always supplies one.
    pub const Live = struct {
        bindings: *const std.StringHashMap([]const u8),
        probe: ?Probe = null,
    };

    /// A minimal duck-typed presence probe: `ctx` is the concrete prober
    /// (`machine.path_lookup.ToolProbe`), reached through a function pointer
    /// rather than a direct type so this dsl-layer file does not depend on
    /// the machine layer's IO/environ types.
    pub const Probe = struct {
        ctx: *anyopaque,
        presentFn: *const fn (ctx: *anyopaque, name: []const u8) bool,

        pub fn present(self: Probe, name: []const u8) bool {
            return self.presentFn(self.ctx, name);
        }
    };

    pub const Override = struct {
        map: *const std.StringHashMap([]const u8),
        inner: *const Resolver,
    };

    /// The axis's direct (single-value) binding, or null when unbound. Never
    /// resolves via a multi-value membership key (`tool=fd`) -- that is
    /// `has`'s job, nor via the live variant's probe (an open axis has no
    /// direct binding to probe for; `has` is the only path that ever
    /// probes). On the override arm this shadows only on a direct key hit --
    /// unlike `has`, which shadows on any touched key, direct or compound --
    /// currently unreachable since every override producer writes direct
    /// keys only.
    pub fn lookup(self: Resolver, axis: []const u8) ?[]const u8 {
        return switch (self) {
            .live => |l| l.bindings.get(axis),
            .fixed => |m| m.get(axis),
            .override => |o| o.map.get(axis) orelse o.inner.lookup(axis),
        };
    }

    /// True when `axis` is bound to a non-empty value via direct lookup: the
    /// bare-presence form (`when tool`, `entry.field` with no dot). Never
    /// resolves via a multi-value membership key.
    pub fn presence(self: Resolver, axis: []const u8) bool {
        const v = self.lookup(axis) orelse return false;
        return v.len > 0;
    }

    /// True when `axis=value` holds: a single-value axis (os, arch, profile,
    /// machine, hostname, custom facts) compares its direct binding; a
    /// multi-value axis (tool, env, path) is membership in the compound
    /// `axis=value` key set. On the live variant, a `tool=` query the
    /// bindings map does not already answer falls through to the probe
    /// layer -- so a name the eager scan never watched still resolves,
    /// lazily, instead of answering false forever.
    pub fn has(self: Resolver, axis: []const u8, value: []const u8) bool {
        return switch (self) {
            .live => |l| if (hasInMap(l.bindings, axis, value))
                true
            else if (l.probe != null and std.mem.eql(u8, axis, "tool"))
                l.probe.?.present(value)
            else
                false,
            .fixed => |m| hasInMap(m, axis, value),
            .override => |o| if (touchesAxis(o.map, axis))
                hasInMap(o.map, axis, value)
            else
                o.inner.has(axis, value),
        };
    }
};

/// `axis=value` membership within one flat map: a direct key wins outright
/// (single-value axis semantics); otherwise scan for the compound
/// `axis=value` key without materializing that string, so an over-long axis
/// value (a deep `path=`, a big `env=`) still matches instead of silently
/// falling through a fixed-size buffer.
fn hasInMap(map: *const std.StringHashMap([]const u8), axis: []const u8, value: []const u8) bool {
    if (map.get(axis)) |got| return std.mem.eql(u8, got, value);
    var it = map.keyIterator();
    while (it.next()) |k| {
        const key = k.*;
        if (key.len == axis.len + 1 + value.len and
            key[axis.len] == '=' and
            std.mem.startsWith(u8, key, axis) and
            std.mem.eql(u8, key[axis.len + 1 ..], value)) return true;
    }
    return false;
}

/// True when `map` binds `axis` at all -- directly, or via any compound
/// `axis=value` key -- regardless of which value. Used by the override layer
/// to decide whether an axis is fully shadowed (never falls through to the
/// inner resolver) versus untouched (delegates).
fn touchesAxis(map: *const std.StringHashMap([]const u8), axis: []const u8) bool {
    if (map.contains(axis)) return true;
    var it = map.keyIterator();
    while (it.next()) |k| {
        const key = k.*;
        if (key.len > axis.len and key[axis.len] == '=' and std.mem.startsWith(u8, key, axis)) return true;
    }
    return false;
}

test "live: has/presence/lookup mirror direct and compound-key semantics" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    try m.put("os", "darwin");
    try m.put("tool=fd", "1");
    try m.put("empty", "");
    const r: Resolver = .{ .live = &.{ .bindings = &m } };

    try std.testing.expect(r.has("os", "darwin"));
    try std.testing.expect(!r.has("os", "linux"));
    try std.testing.expect(r.has("tool", "fd"));
    try std.testing.expect(!r.has("tool", "rg"));
    try std.testing.expectEqualStrings("darwin", r.lookup("os").?);
    try std.testing.expect(r.lookup("missing") == null);
    try std.testing.expect(r.presence("os"));
    try std.testing.expect(!r.presence("empty"));
    try std.testing.expect(!r.presence("missing"));
    // Bare presence never resolves via a multi-value compound key.
    try std.testing.expect(!r.presence("tool"));
}

test "fixed: identical answers to live, distinguished only by tag" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    try m.put("os", "linux");
    const r: Resolver = .{ .fixed = &m };
    try std.testing.expect(r.has("os", "linux"));
    try std.testing.expectEqualStrings("linux", r.lookup("os").?);
}

test "override: a touched axis fully shadows the inner resolver, even for an unlisted value" {
    var inner_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer inner_map.deinit();
    try inner_map.put("os", "darwin");
    try inner_map.put("tool=fd", "1");
    const inner: Resolver = .{ .live = &.{ .bindings = &inner_map } };

    var over_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer over_map.deinit();
    try over_map.put("os", "linux");
    const ovr: Resolver.Override = .{ .map = &over_map, .inner = &inner };
    const r: Resolver = .{ .override = &ovr };

    try std.testing.expect(r.has("os", "linux"));
    // The override's os=linux fully shadows the inner os=darwin: the inner
    // value never leaks through, even asking about a value the override
    // itself does not name.
    try std.testing.expect(!r.has("os", "darwin"));
    // An axis the override never touches delegates to the inner resolver.
    try std.testing.expect(r.has("tool", "fd"));
}

test "override: an untouched axis falls through to the inner resolver" {
    var inner_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer inner_map.deinit();
    try inner_map.put("profile", "work");
    const inner: Resolver = .{ .live = &.{ .bindings = &inner_map } };

    var over_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer over_map.deinit();
    const ovr: Resolver.Override = .{ .map = &over_map, .inner = &inner };
    const r: Resolver = .{ .override = &ovr };

    try std.testing.expectEqualStrings("work", r.lookup("profile").?);
    try std.testing.expect(r.presence("profile"));
}

test "override: lookup and presence prefer the override's own binding" {
    var inner_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer inner_map.deinit();
    try inner_map.put("email", "old@example.com");
    const inner: Resolver = .{ .live = &.{ .bindings = &inner_map } };

    var over_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer over_map.deinit();
    try over_map.put("email", "new@example.com");
    const ovr: Resolver.Override = .{ .map = &over_map, .inner = &inner };
    const r: Resolver = .{ .override = &ovr };

    try std.testing.expectEqualStrings("new@example.com", r.lookup("email").?);
}

test "override: a multi-value axis over-256-byte value still matches through the override layer" {
    var inner_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer inner_map.deinit();
    const inner: Resolver = .{ .live = &.{ .bindings = &inner_map } };

    const long = "/" ** 300;
    var over_map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer over_map.deinit();
    try over_map.put("path=" ++ long, "1");
    const ovr: Resolver.Override = .{ .map = &over_map, .inner = &inner };
    const r: Resolver = .{ .override = &ovr };

    try std.testing.expect(r.has("path", long));
}

/// A `Probe` stub that answers from a fixed name list and records whether it
/// was ever asked, so a test can assert the probe layer was (or was not)
/// consulted at all -- not just what it would have answered.
const TestProbe = struct {
    present_names: []const []const u8,
    called: bool = false,

    fn presentFn(ctx: *anyopaque, name: []const u8) bool {
        const self: *TestProbe = @ptrCast(@alignCast(ctx));
        self.called = true;
        for (self.present_names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn probe(self: *TestProbe) Resolver.Probe {
        return .{ .ctx = self, .presentFn = presentFn };
    }
};

test "live: a tool name already seeded in bindings answers without consulting the probe" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    try m.put("tool=fd", "1");
    var stub = TestProbe{ .present_names = &.{"fd"} };
    const live: Resolver.Live = .{ .bindings = &m, .probe = stub.probe() };
    const r: Resolver = .{ .live = &live };

    try std.testing.expect(r.has("tool", "fd"));
    try std.testing.expect(!stub.called);
}

test "live: a tool name bindings never saw falls through to the probe, present" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    var stub = TestProbe{ .present_names = &.{"herdr"} };
    const live: Resolver.Live = .{ .bindings = &m, .probe = stub.probe() };
    const r: Resolver = .{ .live = &live };

    try std.testing.expect(r.has("tool", "herdr"));
    try std.testing.expect(stub.called);
}

test "live: a tool name bindings never saw falls through to the probe, absent" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    var stub = TestProbe{ .present_names = &.{} };
    const live: Resolver.Live = .{ .bindings = &m, .probe = stub.probe() };
    const r: Resolver = .{ .live = &live };

    try std.testing.expect(!r.has("tool", "nope"));
    try std.testing.expect(stub.called);
}

test "live: a non-tool axis never consults the probe" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    var stub = TestProbe{ .present_names = &.{"darwin"} };
    const live: Resolver.Live = .{ .bindings = &m, .probe = stub.probe() };
    const r: Resolver = .{ .live = &live };

    try std.testing.expect(!r.has("os", "darwin"));
    try std.testing.expect(!stub.called);
}

test "live: a null probe leaves an unseeded tool name false, same as before probing existed" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    const live: Resolver.Live = .{ .bindings = &m };
    const r: Resolver = .{ .live = &live };

    try std.testing.expect(!r.has("tool", "fd"));
}
