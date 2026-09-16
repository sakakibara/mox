//! The desired set: the manifest rows that belong on THIS machine.
//!
//! A row is desired when its backend is active here and its `when` gate
//! holds. Backend activation is decided by the caller and passed in as a
//! list of names, so the core never learns which executable a manager ships
//! or which OS it runs on -- that is the adapter's knowledge.
//!
//! Two contradictions are refused rather than resolved: the same package
//! desired twice on one machine, and a package both desired and blacklisted.
//! Gates that are disjoint (a pinned row for one profile, a plain row for
//! the rest) are not duplicates, because only one of them is ever active.

const std = @import("std");

const axis = @import("../dsl/axis.zig");
const resolver_mod = @import("../dsl/resolver.zig");
const manifest_mod = @import("manifest.zig");

pub const Resolver = resolver_mod.Resolver;
pub const Row = manifest_mod.Row;
pub const Manifest = manifest_mod.Manifest;
pub const Diag = manifest_mod.Diag;

pub const Error = error{
    DuplicatePackageRow,
    BlacklistedPackageDesired,
};

/// The rows to install on this machine, in manifest order. `active_backends`
/// names the backends usable here; rows for any other backend are inert.
pub fn select(
    arena: std.mem.Allocator,
    m: Manifest,
    r: *const Resolver,
    active_backends: []const []const u8,
    diag: ?*Diag,
) ![]const Row {
    var out: std.ArrayList(Row) = .empty;
    var seen = std.StringHashMap(Row).init(arena);

    for (m.packages) |row| {
        if (!contains(active_backends, row.backend)) continue;
        if (!gateHolds(arena, row, r)) continue;

        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ row.backend, row.name });
        if (seen.get(key)) |first| {
            if (diag) |d| d.set(
                "{s} and {s} both declare \"{s}\" for backend \"{s}\" on this machine",
                .{ first.label, row.label, row.name, row.backend },
            );
            return Error.DuplicatePackageRow;
        }
        try seen.put(key, row);

        if (blacklistEntry(m, row.backend, row.name)) |b| {
            if (diag) |d| d.set(
                "{s} declares \"{s}\" for backend \"{s}\", which {s} blacklists",
                .{ row.label, row.name, row.backend, b.label },
            );
            return Error.BlacklistedPackageDesired;
        }

        try out.append(arena, row);
    }

    return out.toOwnedSlice(arena);
}

/// Whether a package is blacklisted for a backend, regardless of gating: a
/// blacklist row suppresses the untracked report, which has no gate of its
/// own.
pub fn isBlacklisted(m: Manifest, backend: []const u8, name: []const u8) bool {
    return blacklistEntry(m, backend, name) != null;
}

fn blacklistEntry(m: Manifest, backend: []const u8, name: []const u8) ?manifest_mod.BlacklistRow {
    for (m.blacklist) |b| {
        if (std.mem.eql(u8, b.backend, backend) and std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// A row with no `when` is unconditional. A `when` that fails to parse here
/// cannot happen: `manifest.load` already rejected it, so a parse failure at
/// this point excludes the row rather than inventing a second diagnostic.
fn gateHolds(arena: std.mem.Allocator, row: Row, r: *const Resolver) bool {
    const src = row.when orelse return true;
    const expr = axis.parseString(arena, src) catch return false;
    return axis.evaluate(expr, r);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

const testing = std.testing;

fn rowOf(name: []const u8, backend: []const u8, when: ?[]const u8, label: []const u8) Row {
    return .{
        .name = name,
        .backend = backend,
        .when = when,
        .fields = &.{},
        .origin = "/tmp/x.toml",
        .label = label,
        .index = 0,
    };
}

test "select: keeps rows whose backend is active and whose gate holds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    try bindings.put("profile", "personal");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const m: Manifest = .{ .packages = &.{
        rowOf("ripgrep", "brew", null, "data/packages/darwin.toml"),
        rowOf("steam", "brew", "profile=personal", "data/packages/darwin.toml"),
        rowOf("work-tool", "brew", "profile=work", "data/packages/darwin.toml"),
    } };

    const got = try select(a, m, &r, &.{"brew"}, null);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("ripgrep", got[0].name);
    try testing.expectEqualStrings("steam", got[1].name);
}

test "select: a row for an inactive backend is inert" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const m: Manifest = .{ .packages = &.{
        rowOf("ripgrep", "brew", null, "data/packages/darwin.toml"),
        rowOf("bat", "dnf", null, "data/packages/fedora.toml"),
    } };

    const got = try select(a, m, &r, &.{"dnf"}, null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("bat", got[0].name);
}

test "select: the same package active twice is refused, naming both files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const m: Manifest = .{ .packages = &.{
        rowOf("ripgrep", "brew", null, "data/packages/darwin.toml"),
        rowOf("ripgrep", "brew", null, "data/packages/local.toml"),
    } };

    var d: Diag = .{};
    try testing.expectError(Error.DuplicatePackageRow, select(a, m, &r, &.{"brew"}, &d));
    try testing.expectEqualStrings(
        "data/packages/darwin.toml and data/packages/local.toml both declare \"ripgrep\" for backend \"brew\" on this machine",
        d.capture().?,
    );
}

test "select: disjoint gates for one package are not a duplicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("profile", "work");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const m: Manifest = .{ .packages = &.{
        rowOf("ripgrep", "brew", "profile=work", "data/packages/darwin.toml"),
        rowOf("ripgrep", "brew", "not profile=work", "data/packages/darwin.toml"),
    } };

    const got = try select(a, m, &r, &.{"brew"}, null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("profile=work", got[0].when.?);
}

test "select: the same name on two backends is not a duplicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const m: Manifest = .{ .packages = &.{
        rowOf("ripgrep", "brew", null, "data/packages/darwin.toml"),
        rowOf("ripgrep", "dnf", null, "data/packages/fedora.toml"),
    } };

    const got = try select(a, m, &r, &.{ "brew", "dnf" }, null);
    try testing.expectEqual(@as(usize, 2), got.len);
}

test "select: a desired package that is also blacklisted is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const m: Manifest = .{
        .packages = &.{rowOf("usage", "brew", null, "data/packages/darwin.toml")},
        .blacklist = &.{.{
            .name = "usage",
            .backend = "brew",
            .origin = "/tmp/x.toml",
            .label = "data/packages/local.toml",
            .index = 0,
        }},
    };

    var d: Diag = .{};
    try testing.expectError(Error.BlacklistedPackageDesired, select(a, m, &r, &.{"brew"}, &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "blacklists") != null);
}

test "isBlacklisted: matches on backend and name together" {
    const m: Manifest = .{ .blacklist = &.{.{
        .name = "usage",
        .backend = "brew",
        .origin = "/tmp/x.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    }} };
    try testing.expect(isBlacklisted(m, "brew", "usage"));
    try testing.expect(!isBlacklisted(m, "dnf", "usage"));
    try testing.expect(!isBlacklisted(m, "brew", "ripgrep"));
}
