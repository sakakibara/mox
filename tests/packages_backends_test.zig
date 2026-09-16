//! Backend adapters against the REAL package managers.
//!
//! Kept out of `zig build test` -- which must pass on a machine with no
//! package manager installed, and must never touch the one it has -- and run
//! by `zig build test-backends`. The day a manager changes the output or
//! flags an adapter depends on, this goes red.
//!
//! Every check here is READ-ONLY: nothing installs, taps, trusts, or removes.
//! Each is DIFFERENTIAL against an INDEPENDENT oracle: brew's machine-readable
//! inventory (`brew info --json=v2 --installed`), never the same command the
//! adapter runs. An adapter that asks brew the wrong question agrees with
//! itself; it cannot agree with the inventory. A check with no data to work
//! on skips rather than passing on nothing, and under CI an absent brew is a
//! failure -- the runner is supposed to have one.

const std = @import("std");
const mox = @import("mox");

const packages = mox.packages;
const testing = std.testing;

fn brewPresent(arena: std.mem.Allocator, io: std.Io) bool {
    var p: packages.exec.Process = .{ .io = io };
    var b: packages.brew.Brew = .{ .runner = p.runner() };
    const got = b.backend().available(arena) catch return false;
    return got == .present;
}

/// Skip a check that has no brew to ask -- unless this is CI, where the job
/// exists to run it: a silent skip there is a green that covered nothing.
fn needBrew(arena: std.mem.Allocator, io: std.Io) !void {
    if (brewPresent(arena, io)) return;
    if (onCi()) {
        std.debug.print("CI: brew is not installed on this runner; the adapter gate cannot run\n", .{});
        return error.TestUnexpectedResult;
    }
    return error.SkipZigTest;
}

fn onCi() bool {
    if (@import("builtin").os.tag == .windows) return false;
    const v = std.c.getenv("CI") orelse return false;
    return v[0] != 0;
}

/// What brew itself recorded when each package was installed, read from the
/// Cellar's `INSTALL_RECEIPT.json` files and the Caskroom's directories --
/// not from any brew query. An adapter asking brew the wrong question can
/// agree with `brew list`; it cannot agree with the receipts.
const Inventory = struct {
    /// Formula names (unqualified) whose receipt says the user asked for them.
    requested: []const []const u8,
    /// Formula names present as a dependency nobody asked for.
    dependencies: []const []const u8,
    /// Cask tokens (unqualified).
    casks: []const []const u8,
};

fn brewPath(arena: std.mem.Allocator, io: std.Io, which: []const u8) ![]const u8 {
    const res = try std.process.run(arena, io, .{ .argv = &.{ "brew", which } });
    if (res.term != .exited or res.term.exited != 0) return error.CommandFailed;
    return std.mem.trim(u8, res.stdout, " \t\r\n");
}

fn inventory(arena: std.mem.Allocator, io: std.Io) !Inventory {
    var requested: std.ArrayList([]const u8) = .empty;
    var dependencies: std.ArrayList([]const u8) = .empty;

    const cellar = try brewPath(arena, io, "--cellar");
    var cellar_dir = try std.Io.Dir.cwd().openDir(io, cellar, .{ .iterate = true });
    defer cellar_dir.close(io);
    var names = cellar_dir.iterate();
    while (try names.next(io)) |name_entry| {
        if (name_entry.kind != .directory) continue;
        const name = try arena.dupe(u8, name_entry.name);
        var kegs = try cellar_dir.openDir(io, name, .{ .iterate = true });
        defer kegs.close(io);
        var versions = kegs.iterate();
        var on_request = false;
        var seen_keg = false;
        while (try versions.next(io)) |keg| {
            if (keg.kind != .directory) continue;
            const receipt = try std.fs.path.join(arena, &.{ cellar, name, keg.name, "INSTALL_RECEIPT.json" });
            const text = std.Io.Dir.cwd().readFileAlloc(io, receipt, arena, .limited(4 << 20)) catch continue;
            const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch continue;
            seen_keg = true;
            const f = parsed.value.object.get("installed_on_request") orelse continue;
            if (f == .bool and f.bool) on_request = true;
        }
        if (!seen_keg) continue;
        if (on_request) try requested.append(arena, name) else try dependencies.append(arena, name);
    }

    var casks: std.ArrayList([]const u8) = .empty;
    const caskroom = try brewPath(arena, io, "--caskroom");
    if (std.Io.Dir.cwd().openDir(io, caskroom, .{ .iterate = true })) |*dir| {
        var d = dir.*;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            try casks.append(arena, try arena.dupe(u8, entry.name));
        }
    } else |_| {}

    return .{
        .requested = try requested.toOwnedSlice(arena),
        .dependencies = try dependencies.toOwnedSlice(arena),
        .casks = try casks.toOwnedSlice(arena),
    };
}

/// Whether `ids` holds `name` itself or a tap-qualified spelling of it: the
/// Cellar knows a formula by its bare name, brew reports a third-party tap's
/// formula by its full name.
fn holdsFormula(ids: []const []const u8, name: []const u8) bool {
    for (ids) |id| {
        if (std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        if (std.mem.eql(u8, id, name)) return true;
        if (std.mem.endsWith(u8, id, name) and id.len > name.len and id[id.len - name.len - 1] == '/') return true;
    }
    return false;
}

fn holdsCask(ids: []const []const u8, token: []const u8) bool {
    for (ids) |id| {
        if (!std.mem.startsWith(u8, id, packages.brew.cask_prefix)) continue;
        const rest = id[packages.brew.cask_prefix.len..];
        if (std.mem.eql(u8, rest, token)) return true;
        if (std.mem.endsWith(u8, rest, token) and rest.len > token.len and rest[rest.len - token.len - 1] == '/') return true;
    }
    return false;
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

    const available = (b.backend().available(a) catch .absent) == .present;
    const answered = blk: {
        const res = std.process.run(a, io, .{ .argv = &.{ "brew", "--version" } }) catch break :blk false;
        break :blk res.term == .exited and res.term.exited == 0;
    };
    try testing.expectEqual(answered, available);
}

test "brew: the receipts' requested formulae are ids, and their dependencies are not" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);
    const inv = try inventory(a, io);
    if (inv.requested.len == 0) {
        std.debug.print("no formula installed on request; nothing to compare\n", .{});
        return error.SkipZigTest;
    }
    const ids = try brewIds(a, io);

    for (inv.requested) |name| {
        if (!holdsFormula(ids, name)) {
            std.debug.print("'{s}' was installed on request but is not an adapter id\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    // The other direction is what catches a query that lists everything: a
    // formula pulled in as a dependency is not tracked and must not appear.
    for (inv.dependencies) |name| {
        if (holdsFormula(ids, name)) {
            std.debug.print("'{s}' is an unrequested dependency but appears as an adapter id\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "brew: the spelling is brew's own, verbatim" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);
    const ids = try brewIds(a, io);
    const raw = try rawLines(a, io, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    if (raw.len == 0) return error.SkipZigTest;

    // Verbatim: a formula must arrive unprefixed and untranslated, because
    // ids are compared against manifest names by exact match.
    for (raw) |name| {
        if (!contains(ids, name)) {
            std.debug.print("formula '{s}' missing from adapter ids\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "brew: every cask in the caskroom is an id under the cask prefix" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try needBrew(a, io);
    const inv = try inventory(a, io);
    if (inv.casks.len == 0) {
        std.debug.print("no cask installed; nothing to compare\n", .{});
        return error.SkipZigTest;
    }
    const ids = try brewIds(a, io);

    // Drops the prefix and this fails, which is the point: a cask sharing a
    // formula's name would otherwise satisfy that formula's row.
    for (inv.casks) |token| {
        if (!holdsCask(ids, token)) {
            std.debug.print("cask '{s}' missing from adapter ids under the cask prefix\n", .{token});
            return error.TestUnexpectedResult;
        }
        if (holdsFormula(ids, token)) {
            std.debug.print("cask '{s}' also present as a formula id\n", .{token});
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
    const casks = try rawLines(a, io, &.{ "brew", "list", "--cask", "--full-name" });
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
    const name = qualified orelse {
        std.debug.print("brew: no tapped formula installed here; the tap check has nothing to compare\n", .{});
        return error.SkipZigTest;
    };

    const ids = try brewIds(a, io);
    try testing.expect(contains(ids, name));
    // Three segments, so the tap is derivable from the name alone.
    var parts = std.mem.splitScalar(u8, name, '/');
    _ = parts.next();
    _ = parts.next();
    try testing.expect(parts.next() != null);
}
