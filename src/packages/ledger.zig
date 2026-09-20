//! What mox installed, for a manager that cannot say.
//!
//! Most managers answer "what did the user install on purpose" themselves
//! (`brew list --installed-on-request`, `apt-mark showmanual`,
//! `dnf repoquery --userinstalled`,
//! `pacman -Qe`). zypper has no such query -- verified against zypper 1.14:
//! `--userinstalled` is not a flag it knows, and `--installed-only` returns
//! every dependency too. So for those managers mox records what it installed
//! and treats that as the explicit set.
//!
//! The ledger is machine-local state, not repo content: it says what happened
//! on THIS machine, which is exactly what the state directory holds. It is a
//! candidate set, never the answer on its own -- an adapter intersects it with
//! what the system actually has, so a package removed behind mox's back drops
//! out and is reported missing rather than assumed present.

const std = @import("std");

const apply_write = @import("../apply/write.zig");

const Io = std.Io;

pub const Ledger = struct {
    io: Io,
    /// The directory the record lives in; `<backend>.txt` under it.
    dir: []const u8,
    backend: []const u8,

    fn path(self: Ledger, arena: std.mem.Allocator) ![]const u8 {
        const file = try std.fmt.allocPrint(arena, "{s}.txt", .{self.backend});
        return std.fs.path.join(arena, &.{ self.dir, file });
    }

    /// Every id recorded for this backend. A missing ledger is not an error:
    /// nothing has been installed through mox here yet.
    pub fn read(self: Ledger, arena: std.mem.Allocator) ![]const []const u8 {
        const p = try self.path(arena);
        const text = Io.Dir.cwd().readFileAlloc(self.io, p, arena, .limited(4 << 20)) catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };

        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try out.append(arena, line);
        }
        return out.toOwnedSlice(arena);
    }

    /// Record `ids`, keeping the file a set: re-installing a package already
    /// recorded must not grow a second entry for it.
    pub fn add(self: Ledger, arena: std.mem.Allocator, ids: []const []const u8) !void {
        const existing = try self.read(arena);

        var seen = std.StringHashMap(void).init(arena);
        for (existing) |id| try seen.put(id, {});

        var buf: std.ArrayList(u8) = .empty;
        for (existing) |id| {
            try buf.appendSlice(arena, id);
            try buf.append(arena, '\n');
        }
        var added = false;
        for (ids) |id| {
            if (id.len == 0 or seen.contains(id)) continue;
            try seen.put(id, {});
            try buf.appendSlice(arena, id);
            try buf.append(arena, '\n');
            added = true;
        }
        if (!added and existing.len > 0) return;

        try Io.Dir.cwd().createDirPath(self.io, self.dir);
        const p = try self.path(arena);
        // Atomic: a record that vanished mid-write would read as nothing ever
        // installed, and every package would be installed again.
        try apply_write.writeAtomic(self.io, p, buf.items, 0o644);
    }
};

const testing = std.testing;

fn tmpLedger(a: std.mem.Allocator, io: Io, sub: []const u8, backend: []const u8) !Ledger {
    const cwd = try std.process.currentPathAlloc(io, a);
    const dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", sub, "state", "packages" });
    return .{ .io = io, .dir = dir, .backend = backend };
}

test "read: an absent ledger is empty, not an error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try tmpLedger(a, io, &tmp.sub_path, "zypper");
    try testing.expectEqual(@as(usize, 0), (try l.read(a)).len);
}

test "add then read: ids round-trip in order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try tmpLedger(a, io, &tmp.sub_path, "zypper");
    try l.add(a, &.{ "ripgrep", "bat" });

    const got = try l.read(a);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("ripgrep", got[0]);
    try testing.expectEqualStrings("bat", got[1]);
}

test "add: recording the same id twice keeps one entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try tmpLedger(a, io, &tmp.sub_path, "zypper");
    try l.add(a, &.{"ripgrep"});
    try l.add(a, &.{ "ripgrep", "bat" });
    try l.add(a, &.{"ripgrep"});

    const got = try l.read(a);
    try testing.expectEqual(@as(usize, 2), got.len);
}

test "add: separate backends keep separate ledgers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zypper = try tmpLedger(a, io, &tmp.sub_path, "zypper");
    const other = try tmpLedger(a, io, &tmp.sub_path, "winget");
    try zypper.add(a, &.{"ripgrep"});

    try testing.expectEqual(@as(usize, 1), (try zypper.read(a)).len);
    try testing.expectEqual(@as(usize, 0), (try other.read(a)).len);
}

test "add: an empty id is never recorded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try tmpLedger(a, io, &tmp.sub_path, "zypper");
    try l.add(a, &.{ "", "bat" });

    // The file, not the ids it parses to: `read` skips empty lines, so a
    // blank line written here would be invisible through it.
    const p = try l.path(a);
    const text = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(4 << 20));
    try testing.expectEqualStrings("bat\n", text);
}
