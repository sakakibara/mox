//! Backend adapters against the REAL package managers.
//!
//! Kept out of `zig build test` -- which must pass on a machine with no
//! package manager installed, and must never touch the one it has -- and run
//! by `zig build test-backends`. The day a manager changes the output or
//! flags an adapter depends on, this goes red.
//!
//! Every check here is READ-ONLY: nothing installs, taps, trusts, or removes.
//! Each is DIFFERENTIAL -- the adapter's answer is compared against the raw
//! tool output obtained independently, so a check fails when the adapter and
//! the manager disagree rather than when the adapter merely disagrees with
//! itself. A manager that is absent skips, and a check with no data to work
//! on skips rather than passing on nothing.

const std = @import("std");
const mox = @import("mox");

const packages = mox.packages;
const testing = std.testing;

fn brewPresent(arena: std.mem.Allocator, io: std.Io) bool {
    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    return b.backend().available(arena) catch false;
}

fn brewIds(arena: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    return b.backend().installedExplicit(arena);
}

/// The raw tool's own answer, read without going through the adapter.
fn rawLines(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const []const u8 {
    const res = try std.process.run(arena, io, .{ .argv = argv });
    if (res.term != .exited or res.term.exited != 0) return error.CommandFailed;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try out.append(arena, line);
    }
    return out.toOwnedSlice(arena);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

test "brew: available agrees with brew answering for itself" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };

    const available = b.backend().available(a) catch false;
    const answered = blk: {
        const res = std.process.run(a, io, .{ .argv = &.{ "brew", "--version" } }) catch break :blk false;
        break :blk res.term == .exited and res.term.exited == 0;
    };
    try testing.expectEqual(answered, available);
}

test "brew: every formula brew reports is an id, spelled identically" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!brewPresent(a, io)) return error.SkipZigTest;

    const ids = try brewIds(a, io);
    const raw = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    if (raw.len == 0) return error.SkipZigTest;

    // Verbatim, both ways: a formula must arrive unprefixed and untranslated,
    // because ids are compared against manifest names by exact match.
    for (raw) |name| {
        if (!contains(ids, name)) {
            std.debug.print("formula '{s}' missing from adapter ids\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "brew: every cask brew reports is an id under the cask prefix" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!brewPresent(a, io)) return error.SkipZigTest;

    const ids = try brewIds(a, io);
    const raw = try rawLines(a, io, &.{ "brew", "list", "--cask" });
    if (raw.len == 0) return error.SkipZigTest;

    // Drops the prefix and this fails, which is the point: a cask sharing a
    // formula's name would otherwise satisfy that formula's row.
    for (raw) |name| {
        const want = try std.fmt.allocPrint(a, "{s}{s}", .{ packages.brew.cask_prefix, name });
        if (!contains(ids, want)) {
            std.debug.print("cask '{s}' missing from adapter ids as '{s}'\n", .{ name, want });
            return error.TestUnexpectedResult;
        }
        // And never under its bare name, which is a formula's namespace.
        if (contains(ids, name)) {
            std.debug.print("cask '{s}' also present unprefixed\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "brew: the adapter reports exactly what brew reports, nothing extra" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!brewPresent(a, io)) return error.SkipZigTest;

    const ids = try brewIds(a, io);
    const formulae = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    const casks = try rawLines(a, io, &.{ "brew", "list", "--cask" });
    try testing.expectEqual(formulae.len + casks.len, ids.len);
}

test "brew: a tap-qualified formula is reported the way a row spells it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!brewPresent(a, io)) return error.SkipZigTest;

    const raw = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    var qualified: ?[]const u8 = null;
    for (raw) |name| {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            qualified = name;
            break;
        }
    }
    // Nothing tapped here: skip rather than pass on an empty search, so this
    // never reads as green coverage on a runner with no tapped formula.
    const name = qualified orelse return error.SkipZigTest;

    const ids = try brewIds(a, io);
    try testing.expect(contains(ids, name));
    // Three segments, so the tap is derivable from the name alone.
    var parts = std.mem.splitScalar(u8, name, '/');
    _ = parts.next();
    _ = parts.next();
    try testing.expect(parts.next() != null);
}
