const std = @import("std");
const state_mod = @import("state.zig");
const source_axes = @import("../source/axes.zig");
const dsl = @import("../dsl/root.zig");

/// Convert a MachineState into a flat Bindings hashmap suitable for axis evaluation.
/// Single-value axes use direct key=value (e.g. "os" -> "linux").
/// `path=` (the only closed multi-value axis eagerly known here) uses a
/// compound key with sentinel value "1" (e.g. "path=brew_prefix" -> "1").
/// `tool=`/`env=` are open axes with no fixed vocabulary to enumerate: a
/// `Resolver.Live` answers them by probing, not from this map.
pub fn fromMachineState(arena: std.mem.Allocator, m: state_mod.MachineState) !std.StringHashMap([]const u8) {
    var b = std.StringHashMap([]const u8).init(arena);
    try b.put("os", m.os);
    try b.put("arch", m.arch);
    // `machine` binds the first label only: the FULL hostname is
    // network-volatile on macOS (a laptop reports a different
    // "Foo.attlocal.net"-style name per network), so binding it whole would
    // make a `machine=`-gated region silently stop matching when the network
    // changes. The full name is still available, as the separate `hostname`
    // fact, for a caller that genuinely wants it.
    try b.put("machine", firstLabel(m.hostname));
    try b.put("hostname", m.hostname);

    if (m.brew_prefix.len > 0) {
        try b.put("path=brew_prefix", "1");
    }
    if (m.cargo_home.len > 0) {
        try b.put("path=cargo_home", "1");
    }
    if (m.gopath.len > 0) {
        try b.put("path=gopath", "1");
    }
    if (m.pnpm_home.len > 0) {
        try b.put("path=pnpm_home", "1");
    }
    // Custom facts contribute to axis matching too: `# mox: when profile=work`
    // resolves against `bindings.get("profile")`. Built-in fields above take
    // priority on name conflict.
    for (m.custom_facts) |f| {
        if (b.contains(f.name)) continue;
        try b.put(f.name, f.value);
    }
    return b;
}

/// Seed `bindings` with every STATIC `tool=`/`env=` literal `ax` records
/// (`source.axes`'s repo-wide scan of `when`/`where`/tuple expressions) that
/// `resolver` finds true, pre-probed once through the live resolver.
///
/// A hypothetical-configuration consumer (`config_space.enumerate`'s
/// callers: doctor's axis-space walk, commit's cross-configuration
/// verification, impact analysis) clones `bindings` into every configuration
/// it simulates, but is itself a `fixed` resolver that never probes -- so
/// without this, every `tool=`/`env=` gate would silently read as unbound in
/// every hypothetical configuration, including this machine's own. Seeding
/// closes that for every literal the source tree actually names.
///
/// `path=` needs no seeding here: `fromMachineState` already binds every
/// member it detects, eagerly and unconditionally, since it is closed and
/// derived rather than probed. A data-driven name (`tool=<entry.when>`) is
/// never recorded by `source.axes` in the first place -- only the axis name
/// is -- so it cannot be seeded and stays unbound in a hypothetical
/// configuration: an owned fidelity divergence, not a bug.
pub fn seedStaticMultiValue(
    bindings: *std.StringHashMap([]const u8),
    ax: source_axes.Axes,
    resolver: dsl.resolver.Resolver,
) !void {
    var it = ax.values.keyIterator();
    while (it.next()) |k| {
        const key = k.*;
        if (bindings.contains(key)) continue;
        const eq = std.mem.indexOfScalar(u8, key, '=') orelse continue;
        const axis = key[0..eq];
        const value = key[eq + 1 ..];
        const is_open_axis = std.mem.eql(u8, axis, "tool") or std.mem.eql(u8, axis, "env");
        if (!is_open_axis) continue;
        if (resolver.has(axis, value)) try bindings.put(key, "1");
    }
}

/// The hostname up to (not including) its first `.`, or the whole string
/// when it carries no dot. Exported so a caller that synthesizes a
/// `machine=` narrowing (`mox commit`'s machine-local candidate) derives the
/// same value this binding uses, instead of the raw hostname.
pub fn firstLabel(hostname: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, hostname, '.') orelse return hostname;
    return hostname[0..dot];
}

test "fromMachineState: machine binds the first hostname label, hostname keeps the full name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = state_mod.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "Foo.attlocal.net",
        .username = "u",
        .home = "/h",
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    var b = try fromMachineState(arena.allocator(), m);
    try std.testing.expectEqualStrings("Foo", b.get("machine").?);
    try std.testing.expectEqualStrings("Foo.attlocal.net", b.get("hostname").?);
}

test "fromMachineState: an undotted hostname binds identically to machine and hostname" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = state_mod.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "plainhost",
        .username = "u",
        .home = "/h",
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    var b = try fromMachineState(arena.allocator(), m);
    try std.testing.expectEqualStrings("plainhost", b.get("machine").?);
    try std.testing.expectEqualStrings("plainhost", b.get("hostname").?);
}

const TestProbe = struct {
    present_names: []const []const u8,

    fn presentFn(ctx: *anyopaque, name: []const u8) bool {
        const self: *TestProbe = @ptrCast(@alignCast(ctx));
        for (self.present_names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn probe(self: *TestProbe) dsl.resolver.Resolver.Probe {
        return .{ .ctx = self, .presentFn = presentFn };
    }
};

fn axesWithValue(a: std.mem.Allocator, key: []const u8) !source_axes.Axes {
    var ax: source_axes.Axes = .{
        .names = std.StringHashMap(void).init(a),
        .values = std.StringHashMap(void).init(a),
        .compared = std.StringHashMap(void).init(a),
        .valuesOf = std.StringHashMap(std.ArrayList(source_axes.Value)).init(a),
    };
    try ax.values.put(key, {});
    return ax;
}

test "seedStaticMultiValue: a static tool= literal the live probe confirms is seeded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const ax = try axesWithValue(a, "tool=fd");
    var stub = TestProbe{ .present_names = &.{"fd"} };
    const live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings, .probe = stub.probe() };
    const resolver: dsl.resolver.Resolver = .{ .live = &live };

    try seedStaticMultiValue(&bindings, ax, resolver);
    try std.testing.expectEqualStrings("1", bindings.get("tool=fd").?);
}

test "seedStaticMultiValue: a static tool= literal the live probe refutes is left unbound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const ax = try axesWithValue(a, "tool=nope");
    var stub = TestProbe{ .present_names = &.{} };
    const live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings, .probe = stub.probe() };
    const resolver: dsl.resolver.Resolver = .{ .live = &live };

    try seedStaticMultiValue(&bindings, ax, resolver);
    try std.testing.expect(!bindings.contains("tool=nope"));
}

test "seedStaticMultiValue: path= is never seeded here -- fromMachineState already binds it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const ax = try axesWithValue(a, "path=brew_prefix");
    // The stub answers true for anything, so a wrong seed would be caught.
    var stub = TestProbe{ .present_names = &.{"brew_prefix"} };
    const live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings, .probe = stub.probe() };
    const resolver: dsl.resolver.Resolver = .{ .live = &live };

    try seedStaticMultiValue(&bindings, ax, resolver);
    try std.testing.expect(!bindings.contains("path=brew_prefix"));
}

test "seedStaticMultiValue: an already-bound key is left alone, never re-probed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("tool=fd", "1");
    const ax = try axesWithValue(a, "tool=fd");
    // A stub that would panic-worthy assert false is unnecessary; absent
    // names simply answer false, so a probe call would flip the binding to
    // unset if it were consulted -- it must not be.
    var stub = TestProbe{ .present_names = &.{} };
    const live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings, .probe = stub.probe() };
    const resolver: dsl.resolver.Resolver = .{ .live = &live };

    try seedStaticMultiValue(&bindings, ax, resolver);
    try std.testing.expectEqualStrings("1", bindings.get("tool=fd").?);
}

test "fromMachineState: path= binds only the tool homes actually detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = state_mod.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test",
        .username = "u",
        .home = "/h",
        .brew_prefix = "/opt/homebrew",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    var b = try fromMachineState(arena.allocator(), m);
    try std.testing.expectEqualStrings("linux", b.get("os").?);
    try std.testing.expect(b.contains("path=brew_prefix"));
    try std.testing.expect(!b.contains("path=cargo_home"));
}
