//! One pass from manifest to per-backend drift, shared by every command that
//! needs it: `status` prints it, `apply` installs what it reports missing,
//! `commit` reconciles what it reports untracked. Building it once keeps
//! those three from drifting apart in what they consider desired.
//!
//! A repo with no `data/packages/` is not using the subsystem, and `gather`
//! says so rather than reporting every installed package as untracked.

const std = @import("std");

const resolver_mod = @import("../dsl/resolver.zig");
const backend_mod = @import("backend.zig");
const desired_mod = @import("desired.zig");
const drift_mod = @import("drift.zig");
const manifest_mod = @import("manifest.zig");
const validate_mod = @import("validate.zig");

const Io = std.Io;

pub const Backend = backend_mod.Backend;
pub const Registry = backend_mod.Registry;
pub const Resolver = resolver_mod.Resolver;
pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;
pub const Drift = drift_mod.Drift;

/// One active backend's drift.
pub const BackendDrift = struct {
    backend: []const u8,
    drift: Drift,
    /// Carried from the adapter so a caller can state what this backend
    /// cannot see without knowing which manager it is.
    limitation: ?[]const u8 = null,
};

pub const Report = struct {
    in_use: bool = false,
    backends: []const BackendDrift = &.{},

    pub fn clean(self: Report) bool {
        for (self.backends) |b| {
            if (!b.drift.clean()) return false;
        }
        return true;
    }

    pub fn missingCount(self: Report) usize {
        var n: usize = 0;
        for (self.backends) |b| n += b.drift.missing.len;
        return n;
    }

    pub fn untrackedCount(self: Report) usize {
        var n: usize = 0;
        for (self.backends) |b| n += b.drift.untracked.len;
        return n;
    }
};

/// Load the manifest, check it, and compute drift for every backend usable
/// here. A backend the machine cannot use contributes nothing: its rows are
/// inert and it is never queried.
pub fn gather(
    arena: std.mem.Allocator,
    io: Io,
    registry: Registry,
    repo_dir: []const u8,
    private_dir: []const u8,
    r: *const Resolver,
    diag: ?*Diag,
) !Report {
    const m = try manifest_mod.load(arena, io, repo_dir, private_dir, diag);
    return fromManifest(arena, m, registry, r, diag);
}

/// `gather` for a manifest already loaded, so a caller that reads it for its
/// own reasons does not read it twice.
pub fn fromManifest(
    arena: std.mem.Allocator,
    m: manifest_mod.Manifest,
    registry: Registry,
    r: *const Resolver,
    diag: ?*Diag,
) !Report {
    if (!m.inUse()) return .{};

    try validate_mod.all(arena, m, registry, diag);

    var active: std.ArrayList([]const u8) = .empty;
    var usable: std.ArrayList(Backend) = .empty;
    for (registry.backends) |b| {
        const ok = b.available(arena) catch |e| {
            if (diag) |d| d.set("{s}: available failed: {s}", .{ b.name, @errorName(e) });
            return e;
        };
        if (!ok) continue;
        try active.append(arena, b.name);
        try usable.append(arena, b);
    }

    const rows = try desired_mod.select(arena, m, r, registry, active.items, diag);

    var out: std.ArrayList(BackendDrift) = .empty;
    for (usable.items) |b| {
        const installed = b.installedExplicit(arena) catch |e| {
            if (diag) |d| d.set("{s}: list failed: {s}", .{ b.name, @errorName(e) });
            return e;
        };
        for (installed) |id| {
            if (backend_mod.idShapeOk(id)) continue;
            if (diag) |d| d.set(
                "{s}: reported an id that is not one id ({d} bytes, or contains whitespace); its list output lost its shape",
                .{ b.name, id.len },
            );
            return error.BackendBadOutput;
        }
        try out.append(arena, .{
            .backend = b.name,
            .drift = try drift_mod.compute(arena, b, rows, installed, m),
            .limitation = b.limitation,
        });
    }

    return .{ .in_use = true, .backends = try out.toOwnedSlice(arena) };
}

const testing = std.testing;
const test_backend = @import("test_backend.zig");
const exec = @import("exec.zig");
const brew_mod = @import("brew.zig");

fn rowOf(name: []const u8, backend: []const u8) Row {
    return .{
        .name = name,
        .backend = backend,
        .when = null,
        .fields = &.{},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

test "fromManifest: a repo not using the subsystem reports nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // No manifest files: every installed package would otherwise read as
    // untracked on a machine that never opted in.
    const m: manifest_mod.Manifest = .{ .files = 0 };
    const rep = try fromManifest(a, m, .{ .backends = &.{} }, &r, null);
    try testing.expect(!rep.in_use);
    try testing.expect(rep.clean());
}

test "fromManifest: an unusable backend is never queried" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // test_backend's `available` is unreachable, so a query would error.
    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("bat", "dnf")},
        .files = 1,
    };
    try testing.expectError(error.Unreached, fromManifest(a, m, .{ .backends = &.{test_backend.make("dnf")} }, &r, null));
}

test "fromManifest: drift comes back per backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" },
        .{ .argv = "brew list --full-name --installed-on-request", .stdout = "ripgrep\nhtop\n" },
        .{ .argv = "brew list --cask", .stdout = "" },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{
        .packages = &.{ rowOf("ripgrep", "brew"), rowOf("fd", "brew") },
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, null);
    try testing.expect(rep.in_use);
    try testing.expectEqual(@as(usize, 1), rep.backends.len);
    try testing.expectEqualStrings("brew", rep.backends[0].backend);
    // `fd` is declared but absent; `htop` is installed but declared nowhere.
    try testing.expectEqual(@as(usize, 1), rep.missingCount());
    try testing.expectEqualStrings("fd", rep.backends[0].drift.missing[0].row.name);
    try testing.expectEqual(@as(usize, 1), rep.untrackedCount());
    try testing.expectEqualStrings("htop", rep.backends[0].drift.untracked[0]);
    try testing.expect(!rep.clean());
}

test "fromManifest: a manifest matching the machine is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" },
        .{ .argv = "brew list --full-name --installed-on-request", .stdout = "ripgrep\n" },
        .{ .argv = "brew list --cask", .stdout = "ghostty\n" },
    } };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const cask: Row = .{
        .name = "ghostty",
        .backend = "brew",
        .when = null,
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
    const m: manifest_mod.Manifest = .{
        .packages = &.{ rowOf("ripgrep", "brew"), cask },
        .files = 1,
    };

    const rep = try fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, null);
    try testing.expect(rep.clean());
}

test "fromManifest: an invalid manifest is refused before anything is queried" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var b: brew_mod.Brew = .{ .runner = fake.runner() };

    const m: manifest_mod.Manifest = .{
        .packages = &.{rowOf("ripgrep", "brw")},
        .files = 1,
    };

    var d: Diag = .{};
    try testing.expectError(
        validate_mod.Error.UnknownBackend,
        fromManifest(a, m, .{ .backends = &.{b.backend()} }, &r, &d),
    );
}
