//! The desired set: the manifest rows that belong on THIS machine.
//!
//! A row is desired when its backend is usable here and its `when` gate
//! holds. Which backends are usable is decided by the caller and passed in by
//! name, so the core never learns which executable a manager ships or which
//! OS it runs on -- that is the adapter's knowledge. A row naming a backend
//! that is registered but unusable here is inert; one naming a backend that
//! does not exist is a typo, and `validate.all` has already refused it.
//!
//! Identity is the adapter's `idOf`, never the raw name, so a brew formula
//! and the cask of the same name are two packages here exactly as they are
//! everywhere else. Gates that are disjoint (a pinned row for one profile, a
//! plain row for the rest) are not duplicates, because only one is active.

const std = @import("std");

const axis = @import("../dsl/axis.zig");
const resolver_mod = @import("../dsl/resolver.zig");
const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");
const exec = @import("exec.zig");

pub const Resolver = resolver_mod.Resolver;
pub const Registry = backend_mod.Registry;
pub const Row = manifest_mod.Row;
pub const Manifest = manifest_mod.Manifest;
pub const Diag = manifest_mod.Diag;

pub const Error = error{
    DuplicatePackageRow,
};

/// The rows to install on this machine, in manifest order. `active` names the
/// backends usable here; rows for any other registered backend are inert.
pub fn select(
    arena: std.mem.Allocator,
    m: Manifest,
    r: *const Resolver,
    registry: Registry,
    active: []const []const u8,
    diag: ?*Diag,
) ![]const Row {
    var out: std.ArrayList(Row) = .empty;
    var seen = std.StringHashMap(Row).init(arena);

    for (m.packages) |row| {
        if (!contains(active, row.backend)) continue;
        const b = registry.find(row.backend) orelse continue;
        if (!try gateHolds(arena, row, r)) continue;

        const id = b.idOf(arena, row) catch |e| {
            if (diag) |d| d.set("{s}: row \"{s}\": id failed: {s}", .{ row.label, row.name, exec.errorText(e) });
            return e;
        };
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ row.backend, id });
        if (seen.get(key)) |first| {
            if (diag) |d| d.set(
                "{s}: row {d} and {s}: row {d} both declare \"{s}\" for backend \"{s}\" on this machine",
                .{ first.label, first.index, row.label, row.index, row.name, row.backend },
            );
            return Error.DuplicatePackageRow;
        }
        try seen.put(key, row);

        try out.append(arena, row);
    }

    return out.toOwnedSlice(arena);
}

/// A row with no `when` is unconditional. A parse failure is propagated
/// rather than read as "excluded": `manifest.load` rejects a malformed gate,
/// so what reaches here is an allocation failure, and silently dropping a
/// package on one would be a package quietly missing from the machine.
fn gateHolds(arena: std.mem.Allocator, row: Row, r: *const Resolver) !bool {
    const src = row.when orelse return true;
    const expr = try axis.parseString(arena, src);
    return axis.evaluate(expr, r);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

const testing = std.testing;
const test_backend = @import("test_backend.zig");

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

fn caskRow(name: []const u8, label: []const u8) Row {
    return .{
        .name = name,
        .backend = "brew",
        .when = null,
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        .origin = "/tmp/x.toml",
        .label = label,
        .index = 0,
    };
}

fn brewRegistry() Registry {
    const backends = struct {
        const list = [_]backend_mod.Backend{
            test_backend.make("brew"),
            test_backend.make("dnf"),
        };
    };
    return .{ .backends = &backends.list };
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

    const got = try select(a, m, &r, brewRegistry(), &.{"brew"}, null);
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

    const got = try select(a, m, &r, brewRegistry(), &.{"dnf"}, null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("bat", got[0].name);
}

test "select: the same package active twice is refused, naming both files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // Different gates that both hold here: `validate.all` compares gate text
    // and lets these through, so this is the check that catches them.
    var first = rowOf("ripgrep", "brew", "os=darwin", "data/packages/darwin.toml");
    first.index = 2;
    const m: Manifest = .{ .packages = &.{
        first,
        rowOf("ripgrep", "brew", null, "data/packages/local.toml"),
    } };
    try bindings.put("os", "darwin");

    var d: Diag = .{};
    try testing.expectError(Error.DuplicatePackageRow, select(a, m, &r, brewRegistry(), &.{"brew"}, &d));
    try testing.expectEqualStrings(
        "data/packages/darwin.toml: row 2 and data/packages/local.toml: row 0 both declare \"ripgrep\" for backend \"brew\" on this machine",
        d.capture().?,
    );
}

test "select: a formula and the cask of the same name are two packages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // brew keeps these apart, so the manifest must be able to declare both.
    const m: Manifest = .{ .packages = &.{
        rowOf("docker", "brew", null, "data/packages/darwin.toml"),
        caskRow("docker", "data/packages/darwin.toml"),
    } };

    const got = try select(a, m, &r, brewRegistry(), &.{"brew"}, null);
    try testing.expectEqual(@as(usize, 2), got.len);
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

    const got = try select(a, m, &r, brewRegistry(), &.{"brew"}, null);
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

    const got = try select(a, m, &r, brewRegistry(), &.{ "brew", "dnf" }, null);
    try testing.expectEqual(@as(usize, 2), got.len);
}
