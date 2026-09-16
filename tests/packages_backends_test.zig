//! Backend adapters against the REAL package managers.
//!
//! Kept out of `zig build test` -- which must pass on a machine with no
//! package manager installed, and must never touch the one it has -- and run
//! by `zig build test-backends` on a schedule. The day a manager changes the
//! output or flags an adapter depends on, this goes red on a branch instead
//! of on a machine.
//!
//! Every check here is READ-ONLY. Nothing installs, taps, trusts, or removes.
//! A manager that is absent skips its own checks rather than failing, so the
//! suite is meaningful on each platform without being a lie on the others.

const std = @import("std");
const mox = @import("mox");

const packages = mox.packages;
const testing = std.testing;

fn brewPresent(arena: std.mem.Allocator, io: std.Io) bool {
    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    return b.backend().available(arena) catch false;
}

test "brew: available agrees with brew answering for itself" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };

    const available = try b.backend().available(a);
    const res = std.process.run(a, io, .{ .argv = &.{ "brew", "--version" } }) catch {
        try testing.expect(!available);
        return;
    };
    const ok = res.term == .exited and res.term.exited == 0;
    try testing.expectEqual(ok, available);
}

test "brew: installedExplicit reports real ids in the manifest's namespace" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!brewPresent(a, io)) return error.SkipZigTest;

    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    const ids = try b.backend().installedExplicit(a);

    // A machine with brew has something installed on request; an empty set
    // here would mean the query shape changed under us and every desired
    // package would read as missing.
    try testing.expect(ids.len > 0);

    for (ids) |id| {
        try testing.expect(id.len > 0);
        // Lines arrive trimmed: a stray blank or carriage return would make
        // an id that matches no row.
        try testing.expect(std.mem.trim(u8, id, " \t\r\n").len == id.len);
    }
}

test "brew: a tap-qualified formula is reported the way a row spells it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!brewPresent(a, io)) return error.SkipZigTest;

    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    const ids = try b.backend().installedExplicit(a);

    // The adapter compares ids verbatim, so a tapped formula must come back
    // fully qualified (`owner/tap/formula`) rather than bare. Only assert it
    // when this machine actually has one.
    for (ids) |id| {
        if (std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        if (std.mem.indexOfScalar(u8, id, '/') == null) continue;
        var parts = std.mem.splitScalar(u8, id, '/');
        _ = parts.next();
        _ = parts.next();
        try testing.expect(parts.next() != null);
        return;
    }
}

test "brew: casks and formulae stay in separate id namespaces" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!brewPresent(a, io)) return error.SkipZigTest;

    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    const ids = try b.backend().installedExplicit(a);

    var formulae = std.StringHashMap(void).init(a);
    for (ids) |id| {
        if (std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        try formulae.put(id, {});
    }
    // A cask id must never collide with a formula id, which is the whole
    // reason the prefix exists.
    for (ids) |id| {
        if (!std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        try testing.expect(!formulae.contains(id));
    }
}
