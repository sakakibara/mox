//! `<repo>/.mox/attributes.toml`: native file attributes that git cannot carry.
//!
//! mox derives a managed file's mode from the source file's on-disk mode: git
//! round-trips `100755`/`100644`, so 0755/0644 survive a fresh clone via
//! `stat`. Git collapses every other mode to `100644`, so 0600/0444 are lost.
//! This record travels with the repo and is AUTHORITATIVE for the modes it
//! holds; everything else comes from `stat`.
//!
//! Keys are target home-relative keys (`/`-separated, e.g. `.ssh/config`),
//! never native paths -- the record is shared across machines.
//!
//! A symlinked target is a regular source file whose content is the target
//! path, marked `symlink = true` here (no actual symlink sits in the repo).
//!
//! Seed-once is an intent no file reveals, so it too lives here as
//! `seed_once = true`: apply writes the target only when it is absent, then
//! leaves the user's copy alone.
//!
//! ```toml
//! [".ssh/config"]
//! mode = "0600"
//!
//! [".config/nvim"]
//! symlink = true
//!
//! [".config/app.local"]
//! seed_once = true
//! ```

const std = @import("std");
const toml = @import("toml");

const Io = std.Io;

const max_bytes: usize = 1024 * 1024;

/// Per-target attributes. Only fields git cannot carry are recorded; a null
/// field means "derive it natively" (mode from `stat`).
pub const Entry = struct {
    /// Octal mode, present only when git cannot carry it (not 0644/0755).
    mode: ?u32 = null,
    /// True when the source file's content is a symlink target rather than
    /// literal file content: apply plants a symlink at the live path.
    symlink: bool = false,
    /// True when the target is seeded once: apply writes it only when it is
    /// absent, then never composes, drift-checks, or overwrites the user's copy.
    seed_once: bool = false,
};

/// A loaded `.mox/attributes.toml`, keyed by target home-relative key. All
/// strings and the map itself are owned by the arena passed to `load`.
pub const Attributes = struct {
    arena: std.mem.Allocator,
    map: std.StringHashMap(Entry),

    /// The full entry for `key`, or null when the record holds none.
    pub fn lookup(self: *const Attributes, key: []const u8) ?Entry {
        return self.map.get(key);
    }

    /// The recorded mode for `key`, or null to derive it from `stat`.
    pub fn mode(self: *const Attributes, key: []const u8) ?u32 {
        if (self.map.get(key)) |e| return e.mode;
        return null;
    }

    /// True when `key`'s source file records a symlink target.
    pub fn symlink(self: *const Attributes, key: []const u8) bool {
        if (self.map.get(key)) |e| return e.symlink;
        return false;
    }

    /// True when `key` is recorded as seed-once.
    pub fn seedOnce(self: *const Attributes, key: []const u8) bool {
        if (self.map.get(key)) |e| return e.seed_once;
        return false;
    }

    /// Set (or replace) `key`'s entry. `key` is duped into the arena.
    pub fn set(self: *Attributes, key: []const u8, entry: Entry) !void {
        const gop = try self.map.getOrPut(key);
        if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, key);
        gop.value_ptr.* = entry;
    }

    /// Remove `key`'s entry, returning true when one was present.
    pub fn remove(self: *Attributes, key: []const u8) bool {
        return self.map.remove(key);
    }

    /// Serialize to `<repo_dir>/.mox/attributes.toml` deterministically (keys
    /// sorted, so diffs stay stable). An entry with no recorded field emits no
    /// table. When the result is empty the file is removed rather than left as
    /// an empty stub.
    pub fn write(self: *const Attributes, io: Io, repo_dir: []const u8) !void {
        const path = try std.fs.path.join(self.arena, &.{ repo_dir, ".mox", "attributes.toml" });

        var keys: std.ArrayList([]const u8) = .empty;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.mode == null and !kv.value_ptr.symlink and !kv.value_ptr.seed_once) continue;
            try keys.append(self.arena, kv.key_ptr.*);
        }
        std.mem.sort([]const u8, keys.items, {}, lessKey);

        if (keys.items.len == 0) {
            Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
            return;
        }

        var out: std.ArrayList(u8) = .empty;
        for (keys.items, 0..) |key, i| {
            if (i != 0) try out.append(self.arena, '\n');
            const entry = self.map.get(key).?;
            try out.append(self.arena, '[');
            try writeQuoted(self.arena, &out, key);
            try out.appendSlice(self.arena, "]\n");
            if (entry.mode) |m| {
                const octal = try std.fmt.allocPrint(self.arena, "0{o}", .{m});
                try out.appendSlice(self.arena, "mode = \"");
                try out.appendSlice(self.arena, octal);
                try out.appendSlice(self.arena, "\"\n");
            }
            if (entry.symlink) try out.appendSlice(self.arena, "symlink = true\n");
            if (entry.seed_once) try out.appendSlice(self.arena, "seed_once = true\n");
        }

        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    }
};

fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Emit `s` as a TOML basic (double-quoted) string. Control characters are
/// escaped too: a target key is a filename, which may legally hold a newline or
/// tab, and an unescaped control byte would make the whole file unparseable.
fn writeQuoted(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        '\r' => try out.appendSlice(arena, "\\r"),
        // TOML basic strings must escape every control char, including DEL.
        else => if (c < 0x20 or c == 0x7f) {
            try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{X:0>4}", .{c}));
        } else try out.append(arena, c),
    };
    try out.append(arena, '"');
}

/// Parse an octal mode string (`"0600"`, `"600"`, `"0o600"`), or null when it
/// is not a valid octal literal. Masked to the permission bits, so a
/// hand-edited setuid or over-0o777 record never reaches `chmod`.
fn parseMode(s: []const u8) ?u32 {
    var digits = s;
    if (std.mem.startsWith(u8, digits, "0o") or std.mem.startsWith(u8, digits, "0O")) {
        digits = digits[2..];
    }
    if (digits.len == 0) return null;
    const parsed = std.fmt.parseInt(u32, digits, 8) catch return null;
    return parsed & 0o777;
}

/// Load `<repo_dir>/.mox/attributes.toml`. A missing file yields an empty map
/// (not an error). A TOML parse error fails the load; within a well-formed
/// file, an entry with an unexpected shape (non-table, or a field of the wrong
/// type) is skipped so the rest still applies.
pub fn load(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !Attributes {
    var attrs: Attributes = .{ .arena = arena, .map = std.StringHashMap(Entry).init(arena) };

    const path = try std.fs.path.join(arena, &.{ repo_dir, ".mox", "attributes.toml" });
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |e| switch (e) {
        error.FileNotFound => return attrs,
        else => return e,
    };

    const v = try toml.parse(arena, content, .{});
    if (v != .table) return attrs;

    var it = v.table.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) continue;
        const tbl = entry.value_ptr.table;
        var e: Entry = .{};
        if (tbl.get("mode")) |mv| {
            if (mv == .string) e.mode = parseMode(mv.string);
        }
        if (tbl.get("symlink")) |sv| {
            if (sv == .boolean) e.symlink = sv.boolean;
        }
        if (tbl.get("seed_once")) |sv| {
            if (sv == .boolean) e.seed_once = sv.boolean;
        }
        if (e.mode == null and !e.symlink and !e.seed_once) continue;
        try attrs.set(entry.key_ptr.*, e);
    }
    return attrs;
}

const testing = std.testing;

test "load: missing file yields an empty map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var attrs = try load(arena.allocator(), testing.io, "/nonexistent/repo");
    try testing.expectEqual(@as(usize, 0), attrs.map.count());
    try testing.expect(attrs.mode(".ssh/config") == null);
}

test "parse: reads octal mode strings keyed by target key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".mox/attributes.toml",
        .data =
        \\[".ssh/config"]
        \\mode = "0600"
        \\
        \\[".local/share/x"]
        \\mode = "0444"
        \\
        ,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var attrs = try load(a, io, repo);
    try testing.expectEqual(@as(u32, 0o600), attrs.mode(".ssh/config").?);
    try testing.expectEqual(@as(u32, 0o444), attrs.mode(".local/share/x").?);
    try testing.expect(attrs.mode("nope") == null);
}

test "roundtrip: write then load recovers modes, deterministic sorted order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var attrs: Attributes = .{ .arena = a, .map = std.StringHashMap(Entry).init(a) };
    try attrs.set(".ssh/config", .{ .mode = 0o600 });
    try attrs.set(".bin/tool", .{ .mode = 0o444 });
    try attrs.write(io, repo);

    const path = try std.fs.path.join(a, &.{ repo, ".mox", "attributes.toml" });
    const written = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes));
    const expected =
        \\[".bin/tool"]
        \\mode = "0444"
        \\
        \\[".ssh/config"]
        \\mode = "0600"
        \\
    ;
    try testing.expectEqualStrings(expected, written);

    var back = try load(a, io, repo);
    try testing.expectEqual(@as(u32, 0o600), back.mode(".ssh/config").?);
    try testing.expectEqual(@as(u32, 0o444), back.mode(".bin/tool").?);
}

test "roundtrip: symlink flag, alone and beside a mode" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var attrs: Attributes = .{ .arena = a, .map = std.StringHashMap(Entry).init(a) };
    try attrs.set(".config/nvim", .{ .symlink = true });
    try attrs.set(".ssh/id", .{ .mode = 0o600, .symlink = true });
    try attrs.write(io, repo);

    const path = try std.fs.path.join(a, &.{ repo, ".mox", "attributes.toml" });
    const written = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes));
    const expected =
        \\[".config/nvim"]
        \\symlink = true
        \\
        \\[".ssh/id"]
        \\mode = "0600"
        \\symlink = true
        \\
    ;
    try testing.expectEqualStrings(expected, written);

    var back = try load(a, io, repo);
    try testing.expect(back.symlink(".config/nvim"));
    try testing.expect(back.mode(".config/nvim") == null);
    try testing.expect(back.symlink(".ssh/id"));
    try testing.expectEqual(@as(u32, 0o600), back.mode(".ssh/id").?);
    try testing.expect(!back.symlink("nope"));
}

test "roundtrip: seed_once flag, alone and combined with mode and symlink" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var attrs: Attributes = .{ .arena = a, .map = std.StringHashMap(Entry).init(a) };
    try attrs.set(".config/app.local", .{ .seed_once = true });
    try attrs.set(".ssh/id", .{ .mode = 0o600, .symlink = true, .seed_once = true });
    try attrs.write(io, repo);

    const path = try std.fs.path.join(a, &.{ repo, ".mox", "attributes.toml" });
    const written = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes));
    const expected =
        \\[".config/app.local"]
        \\seed_once = true
        \\
        \\[".ssh/id"]
        \\mode = "0600"
        \\symlink = true
        \\seed_once = true
        \\
    ;
    try testing.expectEqualStrings(expected, written);

    var back = try load(a, io, repo);
    try testing.expect(back.seedOnce(".config/app.local"));
    try testing.expect(back.mode(".config/app.local") == null);
    try testing.expect(!back.symlink(".config/app.local"));
    try testing.expect(back.seedOnce(".ssh/id"));
    try testing.expect(back.symlink(".ssh/id"));
    try testing.expectEqual(@as(u32, 0o600), back.mode(".ssh/id").?);
    try testing.expect(!back.seedOnce("nope"));
}

test "write: an empty map removes the file rather than leaving a stub" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var attrs: Attributes = .{ .arena = a, .map = std.StringHashMap(Entry).init(a) };
    try attrs.set(".ssh/config", .{ .mode = 0o600 });
    try attrs.write(io, repo);
    const path = try std.fs.path.join(a, &.{ repo, ".mox", "attributes.toml" });
    try Io.Dir.cwd().access(io, path, .{});

    _ = attrs.remove(".ssh/config");
    try attrs.write(io, repo);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "parseMode: accepts leading zero and 0o prefix, rejects junk" {
    try testing.expectEqual(@as(u32, 0o600), parseMode("0600").?);
    try testing.expectEqual(@as(u32, 0o755), parseMode("755").?);
    try testing.expectEqual(@as(u32, 0o444), parseMode("0o444").?);
    try testing.expect(parseMode("") == null);
    try testing.expect(parseMode("nope") == null);
    try testing.expect(parseMode("0899") == null);
}

test "parseMode: masks off setuid and over-0o777 bits" {
    try testing.expectEqual(@as(u32, 0o755), parseMode("4755").?);
    try testing.expectEqual(@as(u32, 0o777), parseMode("7777").?);
}

test "roundtrip: a key with control chars (newline, tab) survives write and load" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    // A newline and a tab are legal in a Unix filename; the key must round-trip
    // rather than corrupt the whole file into an unparseable state.
    const key = "weird\nname\twith\x01ctl\x7f";
    var attrs: Attributes = .{ .arena = a, .map = std.StringHashMap(Entry).init(a) };
    try attrs.set(key, .{ .mode = 0o600 });
    try attrs.write(io, repo);

    var back = try load(a, io, repo);
    try testing.expectEqual(@as(u32, 0o600), back.mode(key).?);
}
