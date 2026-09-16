//! Manifest checks that hold on every machine, run once after loading.
//!
//! A row naming an unregistered backend, a key its adapter does not accept,
//! or a package both declared and blacklisted is wrong wherever it is read --
//! not wrong only where that manager happens to be installed. So these run
//! against the whole manifest, ungated and regardless of which backends this
//! machine can use, and none of them is a skip.

const std = @import("std");

const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

pub const Registry = backend_mod.Registry;
pub const Manifest = manifest_mod.Manifest;
pub const Diag = manifest_mod.Diag;

pub const Error = error{
    UnknownBackend,
    BlacklistedPackageDeclared,
};

/// Check every row against the registry and its adapter. `diag` (when
/// non-null) names the file and row behind any failure.
pub fn all(
    arena: std.mem.Allocator,
    m: Manifest,
    registry: Registry,
    diag: ?*Diag,
) !void {
    for (m.packages) |row| {
        const b = registry.find(row.backend) orelse {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": no backend named \"{s}\"",
                .{ row.label, row.name, row.backend },
            );
            return Error.UnknownBackend;
        };
        try b.validate(row, diag);
    }

    for (m.blacklist) |bl| {
        const b = registry.find(bl.backend) orelse {
            if (diag) |d| d.set(
                "{s}: blacklist row \"{s}\": no backend named \"{s}\"",
                .{ bl.label, bl.name, bl.backend },
            );
            return Error.UnknownBackend;
        };
        try b.validate(bl.asRow(), diag);
    }

    // A bootstrap row names its backend the same way, and a typo there would
    // otherwise surface only on the one apply that needs the installer.
    for (m.bootstrap) |b| {
        if (registry.find(b.backend) != null) continue;
        if (diag) |d| d.set(
            "{s}: bootstrap row: no backend named \"{s}\"",
            .{ b.label, b.backend },
        );
        return Error.UnknownBackend;
    }

    try contradictions(arena, m, registry, diag);
}

/// A package both declared and blacklisted. Compared by backend id, so a
/// blacklisted cask never collides with the formula of the same name, and
/// checked ungated: a blacklist holds regardless of which machine asks, so
/// the contradiction must not surface only where the gate happens to pass.
fn contradictions(
    arena: std.mem.Allocator,
    m: Manifest,
    registry: Registry,
    diag: ?*Diag,
) !void {
    for (m.blacklist) |bl| {
        const b = registry.find(bl.backend) orelse continue;
        const blocked = b.idOf(arena, bl.asRow()) catch |e| {
            if (diag) |d| d.set("{s}: blacklist row \"{s}\": id failed: {s}", .{ bl.label, bl.name, @errorName(e) });
            return e;
        };
        for (m.packages) |row| {
            if (!std.mem.eql(u8, row.backend, bl.backend)) continue;
            const id = b.idOf(arena, row) catch |e| {
                if (diag) |d| d.set("{s}: row \"{s}\": id failed: {s}", .{ row.label, row.name, @errorName(e) });
                return e;
            };
            if (!std.mem.eql(u8, id, blocked)) continue;
            if (diag) |d| d.set(
                "{s} declares \"{s}\" for backend \"{s}\", which {s} blacklists",
                .{ row.label, row.name, row.backend, bl.label },
            );
            return Error.BlacklistedPackageDeclared;
        }
    }
}

const testing = std.testing;
const test_backend = @import("test_backend.zig");

fn rowOf(name: []const u8, backend: []const u8, when: ?[]const u8) manifest_mod.Row {
    return .{
        .name = name,
        .backend = backend,
        .when = when,
        .fields = &.{},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

fn caskRow(name: []const u8) manifest_mod.Row {
    return .{
        .name = name,
        .backend = "brew",
        .when = null,
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

fn blacklistOf(name: []const u8, backend: []const u8, fields: []const manifest_mod.Pair) manifest_mod.BlacklistRow {
    return .{
        .name = name,
        .backend = backend,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/local.toml",
        .index = 0,
    };
}

fn registryOf(backends: []const backend_mod.Backend) Registry {
    return .{ .backends = backends };
}

test "all: a row naming no registered backend is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{ .packages = &.{rowOf("ripgrep", "brw", null)} };

    var d: Diag = .{};
    try testing.expectError(Error.UnknownBackend, all(a, m, registryOf(&.{brew}), &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: row \"ripgrep\": no backend named \"brw\"",
        d.capture().?,
    );
}

test "all: a backend this machine cannot use is still a known backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A dnf row on a mac is registered and valid; only its availability
    // differs, and that is not this pass's business.
    const brew = test_backend.make("brew");
    const dnf = test_backend.make("dnf");
    const m: Manifest = .{ .packages = &.{rowOf("bat", "dnf", null)} };

    try all(a, m, registryOf(&.{ brew, dnf }), null);
}

test "all: a blacklist row naming no registered backend is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{ .blacklist = &.{blacklistOf("usage", "brw", &.{})} };

    var d: Diag = .{};
    try testing.expectError(Error.UnknownBackend, all(a, m, registryOf(&.{brew}), &d));
}

test "all: a package both declared and blacklisted is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{rowOf("usage", "brew", null)},
        .blacklist = &.{blacklistOf("usage", "brew", &.{})},
    };

    var d: Diag = .{};
    try testing.expectError(Error.BlacklistedPackageDeclared, all(a, m, registryOf(&.{brew}), &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "blacklists") != null);
}

test "all: the contradiction surfaces even where the gate excludes the row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Gated to work machines, blacklisted outright: wrong everywhere, so it
    // must not wait for a work machine to say so.
    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{rowOf("usage", "brew", "profile=work")},
        .blacklist = &.{blacklistOf("usage", "brew", &.{})},
    };

    try testing.expectError(Error.BlacklistedPackageDeclared, all(a, m, registryOf(&.{brew}), null));
}

test "all: a blacklisted cask does not contradict the formula of the same name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{rowOf("docker", "brew", null)},
        .blacklist = &.{blacklistOf("docker", "brew", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})},
    };

    try all(a, m, registryOf(&.{brew}), null);
}

test "all: a blacklisted cask does contradict the declared cask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const brew = test_backend.make("brew");
    const m: Manifest = .{
        .packages = &.{caskRow("docker")},
        .blacklist = &.{blacklistOf("docker", "brew", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})},
    };

    try testing.expectError(Error.BlacklistedPackageDeclared, all(a, m, registryOf(&.{brew}), null));
}
