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
//!
//! A desired package that is not installed is missing, unless this machine
//! was seen holding it (the record `seen.zig` keeps) and its manager says it
//! is not on the machine in any form: then it was had here and lost, and is
//! removed. Both answers are inputs; the classification stays a set
//! computation.

const std = @import("std");

const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

pub const Row = manifest_mod.Row;
pub const Manifest = manifest_mod.Manifest;
pub const Backend = backend_mod.Backend;

/// A desired package that is not installed, carrying both what the manifest
/// calls it and the id it is compared by, so a consumer can match either
/// without re-deriving the adapter's namespace.
pub const Missing = struct {
    row: Row,
    id: []const u8,
};

/// A desired package that is installed, but that its manager holds astray
/// from the row: what the manager does to it next acts on another package.
/// Carries the adapter's account of why, and the repair for the user to run.
pub const Astray = struct {
    row: Row,
    id: []const u8,
    why: []const u8,
    fix: []const u8,
};

/// A desired package that is installed, but whose binding its manager could
/// not judge, so whether it is held astray is unknown.
pub const Unchecked = struct {
    row: Row,
    id: []const u8,
    why: []const u8,
};

pub const Drift = struct {
    /// Desired here, not installed, and not lost: never seen here, or still
    /// on the machine in some form.
    missing: []const Missing = &.{},
    /// Desired here, not installed, seen here before, and on the machine in
    /// no form its manager can see.
    removed: []const Missing = &.{},
    /// Installed, declared nowhere in the manifest, and not blacklisted.
    untracked: []const []const u8 = &.{},
    /// Desired here and installed, but held astray from the row.
    astray: []const Astray = &.{},
    /// Desired here and installed, but not judged for being held astray.
    unchecked: []const Unchecked = &.{},

    pub fn clean(self: Drift) bool {
        return self.missing.len == 0 and self.removed.len == 0 and self.untracked.len == 0 and self.astray.len == 0 and self.unchecked.len == 0;
    }
};

/// What decides whether a desired package that is not installed was lost:
/// the ids this machine was seen holding through the backend, and of those
/// that are not installed, the ids its manager holds in any form. A row is
/// removed only when its id is in `seen` and not in `present`; the empty
/// default, a record not in effect, leaves every such row missing.
pub const Lost = struct {
    seen: []const []const u8 = &.{},
    present: []const []const u8 = &.{},
};

/// The desired rows for `b` whose package is not installed but that this
/// machine was seen holding: the rows `Backend.present` is asked about.
pub fn candidates(
    arena: std.mem.Allocator,
    b: Backend,
    desired: []const Row,
    installed: []const []const u8,
    seen: []const []const u8,
) ![]const Row {
    var installed_set = std.StringHashMap(void).init(arena);
    for (installed) |i| try installed_set.put(i, {});
    var seen_set = std.StringHashMap(void).init(arena);
    for (seen) |i| try seen_set.put(i, {});

    var out: std.ArrayList(Row) = .empty;
    for (desired) |row| {
        if (!std.mem.eql(u8, row.backend, b.name)) continue;
        const id = try b.idOf(arena, row);
        if (!installed_set.contains(id) and seen_set.contains(id)) try out.append(arena, row);
    }
    return out.toOwnedSlice(arena);
}

/// The ids of `rows` naming `b`, distinct, in row order.
pub fn idsOf(arena: std.mem.Allocator, b: Backend, rows: []const Row) ![]const []const u8 {
    var distinct = std.StringHashMap(void).init(arena);
    var out: std.ArrayList([]const u8) = .empty;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.backend, b.name)) continue;
        const id = try b.idOf(arena, row);
        if ((try distinct.fetchPut(id, {})) != null) continue;
        try out.append(arena, id);
    }
    return out.toOwnedSlice(arena);
}

/// The desired rows for `b` whose package is installed: the rows
/// `Backend.astray` is asked about.
pub fn held(
    arena: std.mem.Allocator,
    b: Backend,
    desired: []const Row,
    installed: []const []const u8,
) ![]const Row {
    var installed_set = std.StringHashMap(void).init(arena);
    for (installed) |i| try installed_set.put(i, {});

    var out: std.ArrayList(Row) = .empty;
    for (desired) |row| {
        if (!std.mem.eql(u8, row.backend, b.name)) continue;
        if (installed_set.contains(try b.idOf(arena, row))) try out.append(arena, row);
    }
    return out.toOwnedSlice(arena);
}

/// Drift for one backend. `desired` is the gated selection (any backend;
/// rows for others are ignored), `installed` what the backend reports,
/// `judged` its `astray` answer for the rows `held` names, and `lost` the
/// record and its `present` answer for the rows `candidates` names.
pub fn compute(
    arena: std.mem.Allocator,
    b: Backend,
    desired: []const Row,
    installed: []const []const u8,
    judged: Backend.Judged,
    lost: Lost,
    m: Manifest,
) !Drift {
    const backend = b.name;
    var installed_set = std.StringHashMap(void).init(arena);
    for (installed) |i| try installed_set.put(i, {});
    var astray_by_id = std.StringHashMap(Backend.Astray).init(arena);
    for (judged.astray) |s| try astray_by_id.put(s.id, s);
    var unchecked_by_id = std.StringHashMap(Backend.Unchecked).init(arena);
    for (judged.unchecked) |u| try unchecked_by_id.put(u.id, u);
    var seen_set = std.StringHashMap(void).init(arena);
    for (lost.seen) |i| try seen_set.put(i, {});
    var present_set = std.StringHashMap(void).init(arena);
    for (lost.present) |i| try present_set.put(i, {});

    var missing: std.ArrayList(Missing) = .empty;
    var removed: std.ArrayList(Missing) = .empty;
    var strayed: std.ArrayList(Astray) = .empty;
    var unjudged: std.ArrayList(Unchecked) = .empty;
    for (desired) |row| {
        if (!std.mem.eql(u8, row.backend, backend)) continue;
        const id = try b.idOf(arena, row);
        if (!installed_set.contains(id)) {
            const lost_here = seen_set.contains(id) and !present_set.contains(id);
            try (if (lost_here) &removed else &missing).append(arena, .{ .row = row, .id = id });
        } else if (astray_by_id.get(id)) |s| {
            try strayed.append(arena, .{ .row = row, .id = id, .why = s.why, .fix = s.fix });
        } else if (unchecked_by_id.get(id)) |u| {
            try unjudged.append(arena, .{ .row = row, .id = id, .why = u.why });
        }
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
    var reported = std.StringHashMap(void).init(arena);
    for (installed) |i| {
        if (declared.contains(i)) continue;
        if (reported.contains(i)) continue;
        try reported.put(i, {});
        try untracked.append(arena, i);
    }

    return .{
        .missing = try missing.toOwnedSlice(arena),
        .removed = try removed.toOwnedSlice(arena),
        .untracked = try untracked.toOwnedSlice(arena),
        .astray = try strayed.toOwnedSlice(arena),
        .unchecked = try unjudged.toOwnedSlice(arena),
    };
}

const testing = std.testing;
const test_backend = @import("test_backend.zig");

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

    const d = try compute(a, test_backend.make("brew"), &desired, &.{"ripgrep"}, .{}, .{}, m);
    try testing.expectEqual(@as(usize, 1), d.missing.len);
    try testing.expectEqualStrings("fd", d.missing[0].row.name);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
}

test "compute: untracked is installed minus everything the manifest declares" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{rowOf("ripgrep", "brew", null)};
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, test_backend.make("brew"), &desired, &.{ "ripgrep", "htop" }, .{}, .{}, m);
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

    const d = try compute(a, test_backend.make("brew"), &desired, &.{ "ripgrep", "work-tool" }, .{}, .{}, m);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
    try testing.expectEqual(@as(usize, 0), d.missing.len);
}

test "compute: a blacklisted package is never untracked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m: Manifest = .{ .blacklist = &.{blacklistOf("usage", "brew")} };

    const d = try compute(a, test_backend.make("brew"), &.{}, &.{"usage"}, .{}, .{}, m);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
}

test "compute: another backend's rows and installs do not cross over" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const all = [_]Row{ rowOf("ripgrep", "brew", null), rowOf("bat", "dnf", null) };
    const m: Manifest = .{ .packages = &all };

    // `bat` is declared for dnf only, so on brew it is untracked.
    const d = try compute(a, test_backend.make("brew"), &all, &.{ "ripgrep", "bat" }, .{}, .{}, m);
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

    const d = try compute(a, test_backend.make("brew"), &desired, &.{"docker"}, .{}, .{}, m);
    try testing.expectEqual(@as(usize, 1), d.missing.len);
    try testing.expectEqualStrings("docker", d.missing[0].row.name);
    try testing.expectEqualStrings("cask:docker", d.missing[0].id);
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

    const d = try compute(a, test_backend.make("brew"), &desired, &.{"cask:ghostty"}, .{}, .{}, m);
    try testing.expect(d.clean());
}

test "compute: clean reports no drift either way" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{rowOf("ripgrep", "brew", null)};
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, test_backend.make("brew"), &desired, &.{"ripgrep"}, .{}, .{}, m);
    try testing.expect(d.clean());
}

test "compute: a blacklisted cask is never untracked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m: Manifest = .{ .blacklist = &.{caskBlacklistOf("ghostty", "brew")} };

    const d = try compute(a, test_backend.make("brew"), &.{}, &.{"cask:ghostty"}, .{}, .{}, m);
    try testing.expectEqual(@as(usize, 0), d.untracked.len);
}

test "compute: an installed row its manager holds astray is astray, not missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{ rowOf("emacs-plus@30", "brew", null), rowOf("ripgrep", "brew", null) };
    const m: Manifest = .{ .packages = &desired };
    const answers = [_]Backend.Astray{.{ .id = "emacs-plus@30", .why = "moved", .fix = "repair" }};

    const d = try compute(a, test_backend.make("brew"), &desired, &.{ "emacs-plus@30", "ripgrep" }, .{ .astray = &answers }, .{}, m);
    try testing.expectEqual(@as(usize, 0), d.missing.len);
    try testing.expectEqual(@as(usize, 1), d.astray.len);
    try testing.expectEqualStrings("emacs-plus@30", d.astray[0].row.name);
    try testing.expectEqualStrings("moved", d.astray[0].why);
    try testing.expectEqualStrings("repair", d.astray[0].fix);
    try testing.expect(!d.clean());
}

test "compute: an answer for a row that is not installed leaves it missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{rowOf("emacs-plus@30", "brew", null)};
    const m: Manifest = .{ .packages = &desired };
    const answers = [_]Backend.Astray{.{ .id = "emacs-plus@30", .why = "moved", .fix = "repair" }};

    const d = try compute(a, test_backend.make("brew"), &desired, &.{}, .{ .astray = &answers }, .{}, m);
    try testing.expectEqual(@as(usize, 1), d.missing.len);
    try testing.expectEqual(@as(usize, 0), d.astray.len);
}

test "compute: an installed row its manager could not judge is unchecked, and the rest stand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{ rowOf("emacs-plus@30", "brew", null), rowOf("readline", "brew", null), rowOf("fd", "brew", null) };
    const m: Manifest = .{ .packages = &desired };
    const judged: Backend.Judged = .{
        .astray = &.{.{ .id = "emacs-plus@30", .why = "moved", .fix = "repair" }},
        .unchecked = &.{ .{ .id = "readline", .why = "unreadable" }, .{ .id = "fd", .why = "unreadable" } },
    };

    // fd is not installed: missing, whatever the adapter said of it.
    const d = try compute(a, test_backend.make("brew"), &desired, &.{ "emacs-plus@30", "readline" }, judged, .{}, m);
    try testing.expectEqual(@as(usize, 1), d.astray.len);
    try testing.expectEqual(@as(usize, 1), d.unchecked.len);
    try testing.expectEqualStrings("readline", d.unchecked[0].row.name);
    try testing.expectEqualStrings("unreadable", d.unchecked[0].why);
    try testing.expectEqual(@as(usize, 1), d.missing.len);
    try testing.expect(!d.clean());
}

test "compute: a seen row not installed and not present is removed, the rest missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ripgrep was seen and is gone; fd was seen and is still on the machine
    // as a dependency; bat was never seen here.
    const desired = [_]Row{ rowOf("ripgrep", "brew", null), rowOf("fd", "brew", null), rowOf("bat", "brew", null) };
    const m: Manifest = .{ .packages = &desired };
    const lost: Lost = .{ .seen = &.{ "ripgrep", "fd" }, .present = &.{"fd"} };

    const d = try compute(a, test_backend.make("brew"), &desired, &.{}, .{}, lost, m);
    try testing.expectEqual(@as(usize, 1), d.removed.len);
    try testing.expectEqualStrings("ripgrep", d.removed[0].row.name);
    try testing.expectEqualStrings("ripgrep", d.removed[0].id);
    try testing.expectEqual(@as(usize, 2), d.missing.len);
    try testing.expectEqualStrings("fd", d.missing[0].row.name);
    try testing.expectEqualStrings("bat", d.missing[1].row.name);
    try testing.expect(!d.clean());
}

test "compute: a seen row that is installed is neither missing nor removed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const desired = [_]Row{rowOf("ripgrep", "brew", null)};
    const m: Manifest = .{ .packages = &desired };

    const d = try compute(a, test_backend.make("brew"), &desired, &.{"ripgrep"}, .{}, .{ .seen = &.{"ripgrep"} }, m);
    try testing.expect(d.clean());
}

test "Drift.clean: a removed row alone is drift" {
    const d: Drift = .{ .removed = &.{.{ .row = rowOf("ripgrep", "brew", null), .id = "ripgrep" }} };
    try testing.expect(!d.clean());
}

test "candidates: the desired rows of this backend not installed and seen here, by id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The cask docker is seen and not installed, though the formula docker
    // is; ripgrep is installed; fd was never seen; bat is another backend's.
    const desired = [_]Row{ rowOf("ripgrep", "brew", null), rowOf("fd", "brew", null), caskRow("docker"), rowOf("bat", "dnf", null) };

    const rows = try candidates(a, test_backend.make("brew"), &desired, &.{ "ripgrep", "docker" }, &.{ "ripgrep", "cask:docker", "bat" });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("docker", rows[0].name);
}

test "idsOf: the distinct ids of this backend's rows, in row order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = [_]Row{ rowOf("fd", "brew", "profile=work"), caskRow("docker"), rowOf("bat", "dnf", null), rowOf("fd", "brew", "profile=home") };
    const ids = try idsOf(a, test_backend.make("brew"), &rows);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("fd", ids[0]);
    try testing.expectEqualStrings("cask:docker", ids[1]);
}

test "held: the desired rows of this backend that are installed, by id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The formula `docker` is installed, which does not hold the cask row.
    const desired = [_]Row{ rowOf("ripgrep", "brew", null), rowOf("fd", "brew", null), caskRow("docker"), rowOf("bat", "dnf", null) };

    const rows = try held(a, test_backend.make("brew"), &desired, &.{ "ripgrep", "docker", "bat" });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("ripgrep", rows[0].name);
}
