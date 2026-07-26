const std = @import("std");
const state_mod = @import("state.zig");

/// Convert a MachineState into a flat Bindings hashmap suitable for axis evaluation.
/// Single-value axes use direct key=value (e.g. "os" -> "linux").
/// Multi-value axes use compound keys with sentinel value "1" (e.g. "tool=fd" -> "1").
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

    for (m.tools_on_path) |t| {
        const key = try std.fmt.allocPrint(arena, "tool={s}", .{t});
        try b.put(key, "1");
    }
    for (m.defined_envs) |e| {
        const key = try std.fmt.allocPrint(arena, "env={s}", .{e});
        try b.put(key, "1");
    }
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
        .tools_on_path = &.{},
        .defined_envs = &.{},
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
        .tools_on_path = &.{},
        .defined_envs = &.{},
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

test "fromMachineState: basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = state_mod.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test",
        .username = "u",
        .home = "/h",
        .tools_on_path = &.{"fd"},
        .defined_envs = &.{},
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
    try std.testing.expectEqualStrings("linux", b.get("os").?);
    try std.testing.expect(b.contains("tool=fd"));
}
