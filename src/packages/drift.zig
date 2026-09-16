//! Package drift: the difference between what a backend reports installed
//! and what the manifest declares.
//!
//! Both sides are compared as backend ids, never as raw names: a manager
//! that keeps two namespaces apart (a brew cask and the formula of the same
//! name) says so through `idOf`, so the core stays a plain set difference
//! with no per-manager knowledge.
//!
//! Untracked is measured against every row the manifest DECLARES for the
//! backend, not merely the ones desired here: a package gated to another
//! profile is already tracked, and offering to re-add it would write a
//! second row for something the manifest already carries.

const std = @import("std");

const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

pub const Row = manifest_mod.Row;
pub const Manifest = manifest_mod.Manifest;
pub const Backend = backend_mod.Backend;

pub const Drift = struct {
    /// Desired here, not installed.
    missing: []const Row = &.{},
    /// Installed, declared nowhere in the manifest, and not blacklisted.
    untracked: []const []const u8 = &.{},

    pub fn clean(self: Drift) bool {
        return self.missing.len == 0 and self.untracked.len == 0;
    }
};

/// Drift for one backend. `desired` is the gated selection (any backend;
/// rows for others are ignored), `installed` what the backend reports.
pub fn compute(
    arena: std.mem.Allocator,
    b: Backend,
    desired: []const Row,
    installed: []const []const u8,
    m: Manifest,
) !Drift {
    const backend = b.name;
    var installed_set = std.StringHashMap(void).init(arena);
    for (installed) |i| try installed_set.put(i, {});

    var missing: std.ArrayList(Row) = .empty;
    for (desired) |row| {
        if (!std.mem.eql(u8, row.backend, backend)) continue;
        if (!installed_set.contains(try b.idOf(arena, row))) try missing.append(arena, row);
    }

    var declared = std.StringHashMap(void).init(arena);
    for (m.packages) |row| {
        if (!std.mem.eql(u8, row.backend, backend)) continue;
        try declared.put(try b.idOf(arena, row), {});
    }
    for (m.blacklist) |bl| {
        if (!std.mem.eql(u8, bl.backend, backend)) continue;
        try declared.put(try b.idOf(arena, bl.asRow()), {});
    }

    var untracked: std.ArrayList([]const u8) = .empty;
    for (installed) |i| {
        if (!declared.contains(i)) try untracked.append(arena, i);
    }

    return .{
        .missing = try missing.toOwnedSlice(arena),
        .untracked = try untracked.toOwnedSlice(arena),
    };
}

const testing = std.testing;

/// A backend whose ids mirror brew's two namespaces, so the collision a flat
/// name comparison would miss is exercised without depending on the brew
/// adapter. Only `idOf` and `name` are reached from here.
const TestBackend = struct {
    fn make(name: []const u8) Backend {
        return .{ .name = name, .ctx = undefined, .vtable = &vt };
    }

    const vt: Backend.VTable = .{
        .available = unreached_available,
        .validate = unreached_validate,
        .idOf = idOf,
        .installedExplicit = unreached_installed,
        .install = unreached_install,
    };

    fn idOf(_: *anyopaque, arena: std.mem.Allocator, row: Row) anyerror![]const u8 {
        const f = row.field("kind") orelse return row.name;
        const s = switch (f) {
            .string => |v| v,
            else => return row.name,
        };
        if (!std.mem.eql(u8, s, "cask")) return row.name;
        return std.fmt.allocPrint(arena, "cask:{s}", .{row.name});
    }

    fn unreached_available(_: *anyopaque, _: std.mem.Allocator) anyerror!bool {
        return error.Unreached;
    }
    fn unreached_validate(_: *anyopaque, _: Row, _: ?*manifest_mod.Diag) anyerror!void {
        return error.Unreached;
    }
    fn unreached_installed(_: *anyopaque, _: std.mem.Allocator) anyerror![]const []const u8 {
        return error.Unreached;
    }
    fn unreached_install(_: *anyopaque, _: std.mem.Allocator, _: []const Row) anyerror!void {
        return error.Unreached;
    }
};

fn rowOf(name: []const u8, backend: []const u8, when: ?[]const u8) Row {
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

fn caskRow(name: []const u8) Row {
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

fn blacklistOf(name: []const u8, backend: []const u8) manifest_mod.BlacklistRow {
    return .{
        .name = name,
        .backend = backend,
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

fn caskBlacklistOf(name: []const u8, backend: []const u8) manifest_mod.BlacklistRow {
    return .{
        .name = name,
        .backend = backend,
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
}

test "compute: missing is desired minus installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{ rowOf("ripgrep", "brew", null), rowOf("fd", "brew", null) };
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, TestBackend.make("brew"), &desired, &.{"ripgrep"}, m);
    try testing.expectEqual(@as(usize, 1), d.missing.len);
    try testing.expectEqualStrings("fd", d.missing[0].name);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
}

test "compute: untracked is installed minus everything the manifest declares" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{rowOf("ripgrep", "brew", null)};
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, TestBackend.make("brew"), &desired, &.{ "ripgrep", "htop" }, m);
    try testing.expectEqual(@as(usize, 1), d.untracked.len);
    try testing.expectEqualStrings("htop", d.untracked[0]);
}

test "compute: a package gated to another machine is tracked, not untracked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Declared for the work profile, so absent from this machine's desired
    // set -- but installed here. Offering it would duplicate an existing row.
    const all = [_]Row{ rowOf("ripgrep", "brew", null), rowOf("work-tool", "brew", "profile=work") };
    const desired = [_]Row{rowOf("ripgrep", "brew", null)};
    const m: Manifest = .{ .packages = &all };

    const d = try compute(a, TestBackend.make("brew"), &desired, &.{ "ripgrep", "work-tool" }, m);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
    try testing.expectEqual(@as(usize, 0), d.missing.len);
}

test "compute: a blacklisted package is never untracked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m: Manifest = .{ .blacklist = &.{blacklistOf("usage", "brew")} };

    const d = try compute(a, TestBackend.make("brew"), &.{}, &.{"usage"}, m);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
}

test "compute: another backend's rows and installs do not cross over" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const all = [_]Row{ rowOf("ripgrep", "brew", null), rowOf("bat", "dnf", null) };
    const m: Manifest = .{ .packages = &all };

    // `bat` is declared for dnf only, so on brew it is untracked.
    const d = try compute(a, TestBackend.make("brew"), &all, &.{ "ripgrep", "bat" }, m);
    try testing.expectEqual(@as(usize, 1), d.untracked.len);
    try testing.expectEqualStrings("bat", d.untracked[0]);
    try testing.expectEqual(@as(usize, 0), d.missing.len);
}

test "compute: a cask is not satisfied by the formula of the same name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The formula `docker` is installed; the manifest wants the CASK.
    const desired = [_]Row{caskRow("docker")};
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, TestBackend.make("brew"), &desired, &.{"docker"}, m);
    try testing.expectEqual(@as(usize, 1), d.missing.len);
    try testing.expectEqualStrings("docker", d.missing[0].name);
    // And the installed formula is untracked: nothing declares it.
    try testing.expectEqual(@as(usize, 1), d.untracked.len);
    try testing.expectEqualStrings("docker", d.untracked[0]);
}

test "compute: a declared cask matches its prefixed installed id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{caskRow("ghostty")};
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, TestBackend.make("brew"), &desired, &.{"cask:ghostty"}, m);
    try testing.expect(d.clean());
}

test "compute: clean reports no drift either way" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{rowOf("ripgrep", "brew", null)};
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, TestBackend.make("brew"), &desired, &.{"ripgrep"}, m);
    try testing.expect(d.clean());
}

test "compute: a blacklisted cask is never untracked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m: Manifest = .{ .blacklist = &.{caskBlacklistOf("ghostty", "brew")} };

    const d = try compute(a, TestBackend.make("brew"), &.{}, &.{"cask:ghostty"}, m);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
}
