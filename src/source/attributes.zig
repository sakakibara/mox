//! `<repo>/.mox/attributes.toml`: per-target facts a source file cannot
//! carry itself.
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
//! `format = "jsonc"` reads a `.json` target as JSON with comments.
//!
//! Strict JSON has no comments, so a strict-JSON target's directives live
//! here: `own`/`disown` (key-path lists), `check` (an argv), `when` (the
//! whole-file gate) and `defaults` (fact name -> interview default). Every
//! other target declares them as head directives in its own source.
//!
//! `released = true` is a tombstone `mox remove` leaves: the target is no
//! longer managed, and every machine keeps its live file.
//!
//! An entry that breaks the schema is that target's error alone: `load`
//! records it on the entry, and `loadStrict` refuses the whole file.
//!
//! ```toml
//! [".ssh/config"]
//! mode = "0600"
//!
//! [".claude/settings.json"]
//! disown = ["model"]
//! ```

const std = @import("std");
const toml = @import("toml");
const head = @import("head.zig");
const format_mod = @import("format.zig");

const Io = std.Io;

const max_bytes: usize = 1024 * 1024;

/// Schema string named in every `load` error, so a user sees the full
/// contract rather than guessing from one bad field.
const schema_text = "mode: string, symlink: bool, seed_once: bool, format: \"jsonc\", own/disown/check: string arrays, when: string, defaults: table of strings, released: bool";

/// Names the target key and offending field a `load` error was raised for.
/// Mirrors the `Diag` pattern used elsewhere in mox (fixed buffer, no
/// allocation): `dsl`/`compose`/`source.tree` each define their own rather
/// than share one, to avoid import cycles between leaf modules.
pub const Diag = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, text: []const u8) void {
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }

    pub fn capture(self: *const Diag) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
};

/// Human text for a `loadStrict` error, naming the full schema so the fix is
/// obvious without cross-referencing docs.
pub fn diagText(e: anyerror) []const u8 {
    return switch (e) {
        error.UnknownAttributeKey => "unknown key (schema: " ++ schema_text ++ ")",
        error.InvalidAttributeValue => "invalid entry (schema: " ++ schema_text ++ ")",
        error.AttributesHaveComments => "comments here would be lost; remove them",
        else => @errorName(e),
    };
}

/// One `defaults` member: a fact name and its interview default.
pub const Default = struct { name: []const u8, value: []const u8 };

/// Per-target attributes. A null or empty field means "not recorded".
pub const Entry = struct {
    /// Octal mode, present only when git cannot carry it (not 0644/0755).
    mode: ?u32 = null,
    /// True when the source file's content is a symlink target rather than
    /// literal file content: apply plants a symlink at the live path.
    symlink: bool = false,
    /// True when the target is seeded once: apply writes it only when it is
    /// absent, then never composes, drift-checks, or overwrites the user's copy.
    seed_once: bool = false,
    /// `format = "jsonc"` on a `.json` target.
    jsonc: bool = false,
    /// `own` or `disown`, with `paths` the declared key-paths as written.
    ownership: head.Ownership = .none,
    paths: []const []const u8 = &.{},
    /// The `check` argv.
    check: []const []const u8 = &.{},
    /// The whole-file gate's axis expression.
    when: ?[]const u8 = null,
    defaults: []const Default = &.{},
    /// A tombstone: the target is no longer managed.
    released: bool = false,
    /// Why the entry breaks the schema, or empty. Set only by `load`.
    err: []const u8 = "",

    /// True when the entry holds any directive key.
    pub fn hasDirectives(e: Entry) bool {
        return e.ownership != .none or e.check.len > 0 or e.when != null or e.defaults.len > 0;
    }
};

/// True when no field is recorded. Such an entry carries no information:
/// `load` drops it and `write` emits no table for it.
pub fn entryEmpty(e: Entry) bool {
    return e.mode == null and !e.symlink and !e.seed_once and !e.jsonc and !e.released and
        !e.hasDirectives() and e.err.len == 0;
}

/// A loaded `.mox/attributes.toml`, keyed by target home-relative key. All
/// strings and the map itself are owned by the arena passed to `load`.
pub const Attributes = struct {
    arena: std.mem.Allocator,
    map: std.StringHashMap(Entry),
    /// The loaded file holds a comment, which `write` would drop.
    has_comment: bool = false,
    /// Where the file was read from, for the comment refusal.
    path: []const u8 = "",

    pub fn init(arena: std.mem.Allocator) Attributes {
        return .{ .arena = arena, .map = std.StringHashMap(Entry).init(arena) };
    }

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

    /// True when `key` is recorded as `format = "jsonc"`.
    pub fn jsonc(self: *const Attributes, key: []const u8) bool {
        if (self.map.get(key)) |e| return e.jsonc;
        return false;
    }

    /// True when `key` carries a tombstone.
    pub fn released(self: *const Attributes, key: []const u8) bool {
        if (self.map.get(key)) |e| return e.released;
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

    /// `error.AttributesHaveComments` when the loaded file holds a comment: a
    /// rewrite would drop it. Every command that rewrites the file checks
    /// this before any side effect.
    pub fn refuseComments(self: *const Attributes) error{AttributesHaveComments}!void {
        if (self.has_comment) return error.AttributesHaveComments;
    }

    /// Serialize to `<repo_dir>/.mox/attributes.toml` deterministically (keys
    /// sorted, so diffs stay stable). An entry with no recorded field emits no
    /// table. When the result is empty the file is removed rather than left as
    /// an empty stub. A file that held a comment is refused, never rewritten.
    pub fn write(self: *const Attributes, io: Io, repo_dir: []const u8) !void {
        try self.refuseComments();
        const path = try std.fs.path.join(self.arena, &.{ repo_dir, ".mox", "attributes.toml" });

        var keys: std.ArrayList([]const u8) = .empty;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (entryEmpty(kv.value_ptr.*)) continue;
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
            if (entry.jsonc) try out.appendSlice(self.arena, "format = \"jsonc\"\n");
            if (entry.ownership != .none) {
                try out.appendSlice(self.arena, if (entry.ownership == .own) "own = " else "disown = ");
                try writeStringArray(self.arena, &out, entry.paths);
            }
            if (entry.check.len > 0) {
                try out.appendSlice(self.arena, "check = ");
                try writeStringArray(self.arena, &out, entry.check);
            }
            if (entry.when) |w| {
                try out.appendSlice(self.arena, "when = ");
                try writeQuoted(self.arena, &out, w);
                try out.append(self.arena, '\n');
            }
            if (entry.defaults.len > 0) {
                try out.appendSlice(self.arena, "defaults = { ");
                for (entry.defaults, 0..) |d, j| {
                    if (j != 0) try out.appendSlice(self.arena, ", ");
                    try out.appendSlice(self.arena, d.name);
                    try out.appendSlice(self.arena, " = ");
                    try writeQuoted(self.arena, &out, d.value);
                }
                try out.appendSlice(self.arena, " }\n");
            }
            if (entry.released) try out.appendSlice(self.arena, "released = true\n");
        }

        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    }
};

fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn writeStringArray(arena: std.mem.Allocator, out: *std.ArrayList(u8), items: []const []const u8) !void {
    try out.append(arena, '[');
    for (items, 0..) |item, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try writeQuoted(arena, out, item);
    }
    try out.appendSlice(arena, "]\n");
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

/// A fact name as `# mox: default` takes it: `[a-z][a-z0-9_]*`.
fn validFactName(s: []const u8) bool {
    if (s.len == 0 or !(s[0] >= 'a' and s[0] <= 'z')) return false;
    for (s[1..]) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) return false;
    }
    return true;
}

/// Why `e`'s directive keys cannot be held for a target that is not strict
/// JSON, naming the first one.
fn directiveHome(e: Entry) []const u8 {
    const tail = " is a directive key, which only a strict-JSON target takes; write it as a head directive in the file";
    if (e.ownership == .own) return "own" ++ tail;
    if (e.ownership == .disown) return "disown" ++ tail;
    if (e.check.len > 0) return "check" ++ tail;
    if (e.when != null) return "when" ++ tail;
    return "defaults" ++ tail;
}

/// Parse one entry's table. A schema violation is recorded in `err`, with the
/// fields read so far kept, never returned as an error.
fn parseEntry(arena: std.mem.Allocator, key: []const u8, tbl: anytype) !Entry {
    var e: Entry = .{};
    var own: ?[]const []const u8 = null;
    var disown: ?[]const []const u8 = null;
    var fit = tbl.iterator();
    while (fit.next()) |field| {
        const name = field.key_ptr.*;
        const v = field.value_ptr.*;
        if (std.mem.eql(u8, name, "mode")) {
            if (v != .string) return failed(arena, e, "mode", "a string of octal digits");
            e.mode = parseMode(v.string) orelse return failed(arena, e, "mode", "a string of octal digits");
        } else if (std.mem.eql(u8, name, "symlink")) {
            if (v != .boolean) return failed(arena, e, "symlink", "a bool");
            e.symlink = v.boolean;
        } else if (std.mem.eql(u8, name, "seed_once")) {
            if (v != .boolean) return failed(arena, e, "seed_once", "a bool");
            e.seed_once = v.boolean;
        } else if (std.mem.eql(u8, name, "released")) {
            if (v != .boolean) return failed(arena, e, "released", "a bool");
            e.released = v.boolean;
        } else if (std.mem.eql(u8, name, "format")) {
            if (v != .string or !std.mem.eql(u8, v.string, "jsonc"))
                return failedText(arena, e, "format = \"jsonc\" is the only format value");
            if (!format_mod.isJsonPath(key))
                return failedText(arena, e, "format = \"jsonc\" applies only to a .json path");
            e.jsonc = true;
        } else if (std.mem.eql(u8, name, "own") or std.mem.eql(u8, name, "disown")) {
            const list = (try stringList(arena, v)) orelse return failed(arena, e, name, "a non-empty array of key-paths");
            if (list.len == 0) return failed(arena, e, name, "a non-empty array of key-paths");
            if (name.len == 3) own = list else disown = list;
        } else if (std.mem.eql(u8, name, "check")) {
            const list = (try stringList(arena, v)) orelse return failed(arena, e, "check", "a non-empty array of strings");
            if (list.len == 0) return failed(arena, e, "check", "a non-empty array of strings");
            e.check = list;
        } else if (std.mem.eql(u8, name, "when")) {
            if (v != .string or v.string.len == 0) return failed(arena, e, "when", "an axis expression string");
            e.when = v.string;
        } else if (std.mem.eql(u8, name, "defaults")) {
            if (v != .table) return failed(arena, e, "defaults", "a table of fact name = \"value\"");
            var out: std.ArrayList(Default) = .empty;
            var dit = v.table.iterator();
            while (dit.next()) |d| {
                if (!validFactName(d.key_ptr.*) or d.value_ptr.* != .string)
                    return failed(arena, e, "defaults", "a table of fact name = \"value\"");
                try out.append(arena, .{ .name = d.key_ptr.*, .value = d.value_ptr.string });
            }
            std.mem.sort(Default, out.items, {}, lessDefault);
            e.defaults = try out.toOwnedSlice(arena);
        } else {
            return failedText(arena, e, try std.fmt.allocPrint(arena, "unknown key \"{s}\" (schema: " ++ schema_text ++ ")", .{name}));
        }
    }
    if (own != null and disown != null) return failedText(arena, e, "own and disown are exclusive per file");
    if (own) |l| {
        e.ownership = .own;
        e.paths = l;
    }
    if (disown) |l| {
        e.ownership = .disown;
        e.paths = l;
    }
    if (e.check.len > 0 and e.ownership == .none) return failedText(arena, e, "check requires own or disown in the same entry");
    if (e.hasDirectives() and format_mod.resolve(key, e.jsonc) != .json) return failedText(arena, e, directiveHome(e));
    if (e.released and (e.mode != null or e.symlink or e.seed_once or e.jsonc or e.hasDirectives()))
        return failedText(arena, e, "released = true is a tombstone and takes no other keys");
    return e;
}

/// Why `e` cannot be held for `key`, or null when it can: the keys whose
/// validity depends on the target's path -- `format` and the directive keys
/// -- checked as `load` checks them.
pub fn invalidAt(e: Entry, key: []const u8) ?[]const u8 {
    if (e.jsonc and !format_mod.isJsonPath(key)) return "format = \"jsonc\" applies only to a .json path";
    if (e.hasDirectives() and format_mod.resolve(key, e.jsonc) != .json) return directiveHome(e);
    return null;
}

fn lessDefault(_: void, a: Default, b: Default) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn failed(arena: std.mem.Allocator, e: Entry, field: []const u8, want: []const u8) !Entry {
    return failedText(arena, e, try std.fmt.allocPrint(arena, "{s} must be {s}", .{ field, want }));
}

fn failedText(arena: std.mem.Allocator, e: Entry, text: []const u8) !Entry {
    var out = e;
    out.err = try std.fmt.allocPrint(arena, ".mox/attributes.toml: {s}", .{text});
    return out;
}

fn stringList(arena: std.mem.Allocator, v: toml.Value) !?[]const []const u8 {
    if (v != .array) return null;
    const out = try arena.alloc([]const u8, v.array.items.len);
    for (v.array.items, out) |item, *o| {
        if (item != .string) return null;
        o.* = item.string;
    }
    return out;
}

/// True when `content` holds a TOML comment.
fn holdsComment(content: []const u8) bool {
    var t = toml.Tokenizer.init(content);
    while (t.next()) |tok| {
        if (tok.kind == .comment) return true;
    }
    return false;
}

/// Load `<repo_dir>/.mox/attributes.toml`. A missing file yields an empty map
/// (not an error), and a TOML parse error fails the load. An entry that
/// breaks the schema -- an unknown key, a wrong-typed value, a directive key
/// on a target that is not strict JSON -- is kept with its `err` set: it is
/// that target's error, and the rest of the file still applies.
pub fn load(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !Attributes {
    var attrs = Attributes.init(arena);

    const path = try std.fs.path.join(arena, &.{ repo_dir, ".mox", "attributes.toml" });
    attrs.path = path;
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |e| switch (e) {
        error.FileNotFound => return attrs,
        else => return e,
    };
    attrs.has_comment = holdsComment(content);

    const v = try toml.parse(arena, content, .{});
    if (v != .table) return attrs;

    var it = v.table.iterator();
    while (it.next()) |entry| {
        const e: Entry = if (entry.value_ptr.* != .table)
            try failedText(arena, .{}, "an entry must be a table")
        else
            try parseEntry(arena, entry.key_ptr.*, entry.value_ptr.table);
        if (entryEmpty(e)) continue;
        try attrs.set(entry.key_ptr.*, e);
    }
    return attrs;
}

/// Where and why `<repo_dir>/.mox/attributes.toml` is not valid TOML:
/// `.mox/attributes.toml:<line>:<col>: <reason>`.
pub fn parseFailure(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) ![]const u8 {
    return parseFailureNamed(arena, io, repo_dir, ".mox/attributes.toml");
}

/// `parseFailure` for the attributes file under `root`, named `name`.
pub fn parseFailureNamed(arena: std.mem.Allocator, io: Io, root: []const u8, name: []const u8) ![]const u8 {
    const generic = try std.fmt.allocPrint(arena, "{s}: not valid TOML", .{name});
    const path = try std.fs.path.join(arena, &.{ root, ".mox", "attributes.toml" });
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch return generic;
    var errs: std.ArrayList(toml.Diagnostic) = .empty;
    _ = toml.parse(arena, content, .{ .errors = &errs }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            if (errs.items.len == 0) return generic;
            const start: usize = @min(@as(usize, @intCast(errs.items[0].span.start)), content.len);
            var line: usize = 1;
            var line_start: usize = 0;
            for (content[0..start], 0..) |c, i| if (c == '\n') {
                line += 1;
                line_start = i + 1;
            };
            return std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}", .{ name, line, start - line_start + 1, errs.items[0].message });
        },
    };
    return generic;
}

/// `load`, refusing a file any entry of which breaks the schema: the
/// commands that rewrite the file must not round-trip a half-read entry.
/// `diag`, when non-null, names the offending target key and the reason.
pub fn loadStrict(arena: std.mem.Allocator, io: Io, repo_dir: []const u8, diag: ?*Diag) !Attributes {
    const attrs = try load(arena, io, repo_dir);
    var keys: std.ArrayList([]const u8) = .empty;
    var it = attrs.map.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.err.len > 0) try keys.append(arena, kv.key_ptr.*);
    }
    if (keys.items.len == 0) return attrs;
    std.mem.sort([]const u8, keys.items, {}, lessKey);
    const first = keys.items[0];
    if (diag) |d| {
        var buf: [512]u8 = undefined;
        d.set(std.fmt.bufPrint(&buf, "\"{s}\" ({s})", .{ first, attrs.map.get(first).?.err }) catch first);
    }
    const reason = attrs.map.get(first).?.err;
    return if (std.mem.indexOf(u8, reason, "unknown key") != null) error.UnknownAttributeKey else error.InvalidAttributeValue;
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

test "load: an unknown key fails loudly instead of being dropped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".mox/attributes.toml",
        .data = "[\".config/app.local\"]\nseed_one = true\n",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var diag: Diag = .{};
    try testing.expectError(error.UnknownAttributeKey, loadStrict(a, io, repo, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.capture().?, "seed_one") != null);
    try testing.expect(std.mem.indexOf(u8, diagText(error.UnknownAttributeKey), "schema") != null);
}

test "load: an unquoted (non-string) mode fails loudly instead of being dropped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".mox/attributes.toml",
        .data = "[\".ssh/config\"]\nmode = 600\n",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var diag: Diag = .{};
    try testing.expectError(error.InvalidAttributeValue, loadStrict(a, io, repo, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.capture().?, "mode") != null);
}

test "load: a mode string that is not valid octal fails loudly" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".mox/attributes.toml",
        .data = "[\".ssh/config\"]\nmode = \"nope\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    try testing.expectError(error.InvalidAttributeValue, loadStrict(a, io, repo, null));
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

fn loadText(a: std.mem.Allocator, tmp: *std.testing.TmpDir, text: []const u8) !Attributes {
    const io = testing.io;
    try tmp.dir.createDirPath(io, ".mox");
    try tmp.dir.writeFile(io, .{ .sub_path = ".mox/attributes.toml", .data = text });
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    return load(a, io, repo);
}

test "load: format accepts only \"jsonc\", and only on a .json path; the error stays on its entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const attrs = try loadText(a, &tmp,
        \\["a.json"]
        \\format = "jsonc"
        \\
        \\["b.json"]
        \\format = "yaml"
        \\
        \\["c.toml"]
        \\format = "jsonc"
        \\
        \\["d.jsonc"]
        \\format = "jsonc"
        \\
    );
    try testing.expect(attrs.jsonc("a.json"));
    try testing.expectEqualStrings("", attrs.lookup("a.json").?.err);
    try testing.expect(std.mem.indexOf(u8, attrs.lookup("b.json").?.err, "only format value") != null);
    try testing.expect(std.mem.indexOf(u8, attrs.lookup("c.toml").?.err, "only to a .json path") != null);
    try testing.expect(std.mem.indexOf(u8, attrs.lookup("d.jsonc").?.err, "only to a .json path") != null);
}

test "load: directive keys are accepted only on a strict-JSON target" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const attrs = try loadText(a, &tmp,
        \\[".claude/settings.json"]
        \\disown = ["model", "autoMode"]
        \\check = ["scripts/check/claude", "--strict"]
        \\when = "tool=claude"
        \\defaults = { profile = "personal" }
        \\
        \\["app.toml"]
        \\own = ["a"]
        \\
        \\["app.jsonc"]
        \\when = "os=darwin"
        \\
        \\["vscode.json"]
        \\format = "jsonc"
        \\defaults = { profile = "work" }
        \\
    );
    const e = attrs.lookup(".claude/settings.json").?;
    try testing.expectEqualStrings("", e.err);
    try testing.expectEqual(head.Ownership.disown, e.ownership);
    try testing.expectEqual(@as(usize, 2), e.paths.len);
    try testing.expectEqualStrings("autoMode", e.paths[1]);
    try testing.expectEqualStrings("--strict", e.check[1]);
    try testing.expectEqualStrings("tool=claude", e.when.?);
    try testing.expectEqualStrings("profile", e.defaults[0].name);
    try testing.expectEqualStrings("personal", e.defaults[0].value);
    for ([_][]const u8{ "app.toml", "app.jsonc", "vscode.json" }) |k| {
        try testing.expect(std.mem.indexOf(u8, attrs.lookup(k).?.err, "write it as a head directive in the file") != null);
    }
}

test "load: check without ownership, own with disown, and a tombstone with other keys are refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const attrs = try loadText(a, &tmp,
        \\["a.json"]
        \\check = ["x"]
        \\
        \\["b.json"]
        \\own = ["a"]
        \\disown = ["b"]
        \\
        \\["c.json"]
        \\released = true
        \\mode = "0600"
        \\
        \\["d.json"]
        \\released = true
        \\
    );
    try testing.expect(std.mem.indexOf(u8, attrs.lookup("a.json").?.err, "check requires own or disown") != null);
    try testing.expect(std.mem.indexOf(u8, attrs.lookup("b.json").?.err, "exclusive") != null);
    try testing.expect(std.mem.indexOf(u8, attrs.lookup("c.json").?.err, "tombstone") != null);
    try testing.expect(attrs.released("d.json"));
    try testing.expectEqualStrings("", attrs.lookup("d.json").?.err);
}

test "roundtrip: directive keys, format and a tombstone write deterministically and load back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var attrs = Attributes.init(a);
    try attrs.set("s.json", .{
        .ownership = .own,
        .paths = &.{ "a", "b.\"c d\"" },
        .check = &.{"scripts/check/s"},
        .when = "os=darwin",
        .defaults = &.{.{ .name = "profile", .value = "work" }},
    });
    try attrs.set("v.json", .{ .jsonc = true });
    try attrs.set("gone.json", .{ .released = true });
    try attrs.write(io, repo);

    const written = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ repo, ".mox", "attributes.toml" }), a, .limited(max_bytes));
    try testing.expectEqualStrings(
        \\["gone.json"]
        \\released = true
        \\
        \\["s.json"]
        \\own = ["a", "b.\"c d\""]
        \\check = ["scripts/check/s"]
        \\when = "os=darwin"
        \\defaults = { profile = "work" }
        \\
        \\["v.json"]
        \\format = "jsonc"
        \\
    , written);

    const back = try load(a, io, repo);
    const s = back.lookup("s.json").?;
    try testing.expectEqualStrings("", s.err);
    try testing.expectEqualStrings("b.\"c d\"", s.paths[1]);
    try testing.expect(back.jsonc("v.json"));
    try testing.expect(back.released("gone.json"));
}

test "write: a file holding a comment is refused, never rewritten" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "# why this mode\n[\".ssh/config\"]\nmode = \"0600\"\n";
    var attrs = try loadText(a, &tmp, text);
    try testing.expect(attrs.has_comment);
    try attrs.set(".zshrc", .{ .mode = 0o600 });
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    try testing.expectError(error.AttributesHaveComments, attrs.write(io, repo));
    try testing.expectEqualStrings(text, try tmp.dir.readFileAlloc(io, ".mox/attributes.toml", a, .limited(max_bytes)));
    try testing.expect(std.mem.indexOf(u8, diagText(error.AttributesHaveComments), "comments here would be lost; remove them") != null);

    const plain = try loadText(a, &tmp, "[\".ssh/config\"]\nmode = \"0600\" \n");
    try testing.expect(!plain.has_comment);
}
