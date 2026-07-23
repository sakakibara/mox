//! Impact analysis: which configurations a source edit would change.
//!
//! A machine is one instance of a configuration; the source that expresses a
//! configuration is never stale, so simulating every configuration covers
//! every machine, including ones that never published anything. This machine
//! holds the entire source tree, so it can simulate any configuration --
//! compose a file under that configuration's bindings and see whether a
//! proposed edit alters its output. No machine ever publishes file content.
//!
//! Because compose reads sources from disk, the two composes straddle the
//! edit: the caller takes a `snapshot` under every configuration BEFORE
//! writing the edit, writes it, takes another AFTER, and `impact` diffs the
//! two.

const std = @import("std");
const compose = @import("../compose/root.zig");
const source = @import("../source/root.zig");
const machine = @import("../machine/root.zig");
const config_space = @import("config_space.zig");

const Io = std.Io;
const ManagedFile = source.tree.ManagedFile;
const MachineState = machine.state.MachineState;
const Configuration = config_space.Configuration;

/// Composed output of one file under every simulated configuration, from one
/// on-disk source state. Entries are index-aligned with the `configs` slice
/// passed to `snapshot`; null means the file is gated off for that
/// configuration.
pub const Snapshot = struct {
    per_config: []const ?[]const u8,
    this_machine: ?[]const u8,
};

pub const Impact = struct {
    /// Labels of configurations whose composed output changed.
    affected: []const []const u8,
    /// Whether the edit changes this machine's own output.
    this_machine_changes: bool,
};

/// Compose `file` under every configuration's bindings, from the CURRENT
/// source tree on disk. Every configuration's compose reuses this machine's
/// `MachineState` for interpolation: values a configuration can't reproduce
/// (interpolation-only facts) are identical before and after the edit, so
/// they never create a false positive; only gating/structure differences
/// matter.
pub fn snapshot(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    configs: []const Configuration,
    m_state: *const MachineState,
    secrets: ?compose.catB.SecretCtx,
) !Snapshot {
    const per = try arena.alloc(?[]const u8, configs.len);
    for (configs, 0..) |cfg, i| {
        per[i] = try composeOrNull(arena, io, file, &cfg.bindings, m_state, secrets);
    }
    const this_out = for (configs) |cfg| {
        if (cfg.is_this_machine) break try composeOrNull(arena, io, file, &cfg.bindings, m_state, secrets);
    } else null;
    return .{ .per_config = per, .this_machine = this_out };
}

/// Compose one file, mapping the axis-gating "no output for this machine"
/// errors to null so a gated-off file is a clean absence rather than a failure.
fn composeOrNull(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    m_state: *const MachineState,
    secrets: ?compose.catB.SecretCtx,
) !?[]const u8 {
    return try compose.composeFileTracked(arena, io, file, bindings, m_state, secrets, null, null);
}

/// Diff before/after snapshots taken around a source edit. A configuration is
/// affected when its composed output changed (including a gating flip between
/// output and no-output).
pub fn impact(
    arena: std.mem.Allocator,
    configs: []const Configuration,
    before: Snapshot,
    after: Snapshot,
) !Impact {
    var affected: std.ArrayList([]const u8) = .empty;
    for (configs, 0..) |cfg, i| {
        if (cfg.is_this_machine) continue;
        if (changed(before.per_config[i], after.per_config[i]))
            try affected.append(arena, cfg.label);
    }
    return .{
        .affected = try affected.toOwnedSlice(arena),
        .this_machine_changes = changed(before.this_machine, after.this_machine),
    };
}

fn changed(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return false;
    if (a == null or b == null) return true;
    return !std.mem.eql(u8, a.?, b.?);
}

const testing = std.testing;

fn writeFile(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

fn srcPathAlloc(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const io = std.testing.io;
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "src" });
}

const fixture_src = "common\n" ++
    "# mox: when os=darwin\n" ++
    "mac line\n" ++
    "# mox: end\n" ++
    "# mox: when os=linux\n" ++
    "linux line\n" ++
    "# mox: end\n";

fn hasLabel(configs: []const Configuration, label: []const u8) bool {
    for (configs) |c| {
        if (std.mem.eql(u8, c.label, label)) return true;
    }
    return false;
}

fn containsLabel(labels: []const []const u8, label: []const u8) bool {
    for (labels) |l| {
        if (std.mem.eql(u8, l, label)) return true;
    }
    return false;
}

test "impact: an edit inside a gated region affects only that configuration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", fixture_src);

    const src_dir = try srcPathAlloc(a, &tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    const file = tree.files[0];

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");
    const ax = try source.axes.ofFile(a, io, file);
    const configs = try config_space.enumerate(a, &this, ax, &.{}, &.{});

    // Guard the fixture itself: a sibling configuration must actually exist,
    // or the negative assertion below would pass vacuously.
    try testing.expect(configs.len >= 2);
    try testing.expect(hasLabel(configs, "os=linux"));

    var env_map = std.process.Environ.Map.init(a);
    const m_state = try machine.state.capture(a, io, .{ .map = &env_map });

    const before = try snapshot(a, io, file, configs, &m_state, null);
    try writeFile(io, tmp.dir, "src/.zshrc", "common\n" ++
        "# mox: when os=darwin\n" ++
        "mac line EDITED\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "linux line\n" ++
        "# mox: end\n");
    const tree2 = try source.tree.walk(a, io, src_dir, "/home/me");
    const after = try snapshot(a, io, tree2.files[0], configs, &m_state, null);

    const got = try impact(a, configs, before, after);
    try testing.expect(got.this_machine_changes);

    // os=linux composes the same bytes before and after: it is not affected,
    // even though it is a real, reachable sibling configuration (asserted above).
    try testing.expect(!containsLabel(got.affected, "os=linux"));
}

test "impact: an edit outside any gated region affects every configuration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFile(io, tmp.dir, "src/.zshrc", fixture_src);

    const src_dir = try srcPathAlloc(a, &tmp);
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    const file = tree.files[0];

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");
    const ax = try source.axes.ofFile(a, io, file);
    const configs = try config_space.enumerate(a, &this, ax, &.{}, &.{});

    try testing.expect(configs.len >= 2);
    try testing.expect(hasLabel(configs, "os=linux"));

    var env_map = std.process.Environ.Map.init(a);
    const m_state = try machine.state.capture(a, io, .{ .map = &env_map });

    const before = try snapshot(a, io, file, configs, &m_state, null);
    try writeFile(io, tmp.dir, "src/.zshrc", "common EDITED\n" ++
        "# mox: when os=darwin\n" ++
        "mac line\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "linux line\n" ++
        "# mox: end\n");
    const tree2 = try source.tree.walk(a, io, src_dir, "/home/me");
    const after = try snapshot(a, io, tree2.files[0], configs, &m_state, null);

    const got = try impact(a, configs, before, after);
    try testing.expect(got.this_machine_changes);

    // A base-line edit reaches every configuration, including siblings.
    try testing.expect(containsLabel(got.affected, "os=linux"));
}
