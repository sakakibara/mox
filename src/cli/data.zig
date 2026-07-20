const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const toml = @import("toml");
const json = @import("json");
const mox = @import("../root.zig");

const Io = std.Io;

const max_bytes: usize = 4 * 1024 * 1024;

pub const Format = enum { toml, json };

const GetSpec = struct {
    name: cli.spec.Pos([]const u8, .{ .help = "data source name (bare stem or *.toml path)" }),
    format: cli.spec.Opt(Format, .{ .default = "toml", .value_name = "format", .help = "toml or json" }),
};

/// `mox data get <name> [--format=toml|json]`: print a TOML data source,
/// resolving the private layer before the repo layer (private shadows repo).
/// `<name>` is a bare stem (`.toml` appended) or an explicit `*.toml` path
/// relative to the `data/` roots.
fn get(ctx: *app.Ctx, a: cli.args.Args(GetSpec)) anyerror!u8 {
    const context = ctx.context.?;
    const name = a.name;

    if (escapesRoot(name)) {
        try ctx.err.print("mox data get: invalid name '{s}': must not contain '..' or a leading '/'\n", .{name});
        return 2;
    }

    const format = a.format orelse .toml;

    const filename = try normalizeName(ctx.alloc, name);
    const private_candidate = try std.fs.path.join(ctx.alloc, &.{ context.paths.private_dir, "data", filename });
    const repo_candidate = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "data", filename });

    const path = resolve(ctx.io, private_candidate, repo_candidate) orelse {
        try ctx.err.print(
            "mox data get: no data source '{s}'; looked in:\n  {s}\n  {s}\n",
            .{ name, private_candidate, repo_candidate },
        );
        return 1;
    };

    const content = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(max_bytes));

    if (format == .toml) {
        try ctx.out.writeAll(content);
        return 0;
    }

    const v = toml.parse(ctx.alloc, content, .{}) catch |e| {
        try ctx.err.print("mox data get: {s}: TOML parse failed: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    const jv = try tomlToJson(ctx.alloc, v);
    try json.encode(ctx.out, jv, .{ .indent = 2 });
    try ctx.out.writeAll("\n");
    return 0;
}

/// True when `name` could resolve outside the `data/` root: an absolute path or
/// any `..` segment, on either separator (a Windows `\`/drive form must be
/// caught even on POSIX and vice versa). Refused so `data get` cannot read
/// arbitrary files off the data sandbox.
fn escapesRoot(name: []const u8) bool {
    return mox.source.path.keyEscapes(name);
}

/// A bare name gets `.toml` appended; a name already ending in `.toml`
/// (possibly a nested path) is used verbatim relative to the `data/` root.
fn normalizeName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, name, ".toml")) return name;
    return std.fmt.allocPrint(arena, "{s}.toml", .{name});
}

/// Return the first of the two candidate paths that exists on disk, private
/// first. Null when neither exists.
fn resolve(io: Io, private_candidate: []const u8, repo_candidate: []const u8) ?[]const u8 {
    if (fileExists(io, private_candidate)) return private_candidate;
    if (fileExists(io, repo_candidate)) return repo_candidate;
    return null;
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Convert a parsed TOML value into a JSON value, preserving table insertion
/// order. Datetime/date/time render to their canonical TOML text.
fn tomlToJson(arena: std.mem.Allocator, v: toml.Value) !json.Value {
    return switch (v) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .integer = @as(i128, i) },
        .float => |f| .{ .float = f },
        .boolean => |b| .{ .bool = b },
        .datetime => |d| .{ .string = try formatDateTime(arena, d) },
        .date => |d| .{ .string = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }) },
        .time => |t| .{ .string = try formatTime(arena, t) },
        .array => |arr| blk: {
            const out = try arena.alloc(json.Value, arr.items.len);
            for (arr.items, 0..) |item, i| out[i] = try tomlToJson(arena, item);
            break :blk .{ .array = out };
        },
        .table => |tbl| blk: {
            var obj: json.ObjectMap = .empty;
            var it = tbl.iterator();
            while (it.next()) |entry| {
                try obj.put(arena, entry.key_ptr.*, try tomlToJson(arena, entry.value_ptr.*));
            }
            break :blk .{ .object = obj };
        },
    };
}

fn formatDateTime(arena: std.mem.Allocator, d: toml.DateTime) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T", .{ d.date.year, d.date.month, d.date.day });
    try writeTime(w, d.time);
    if (d.tz_offset_minutes) |off| {
        if (off == 0) {
            try w.writeByte('Z');
        } else {
            const abs: u16 = @intCast(if (off < 0) -off else off);
            const sign: u8 = if (off < 0) '-' else '+';
            try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 });
        }
    }
    return aw.toOwnedSlice();
}

fn formatTime(arena: std.mem.Allocator, t: toml.Time) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try writeTime(&aw.writer, t);
    return aw.toOwnedSlice();
}

fn writeTime(w: *Io.Writer, t: toml.Time) !void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanos == 0) return;
    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{t.nanos}) catch unreachable;
    var end: usize = 9;
    while (end > 1 and buf[end - 1] == '0') : (end -= 1) {}
    try w.writeByte('.');
    try w.writeAll(buf[0..end]);
}

const get_cmd = app.command(GetSpec, .{
    .name = "get",
    .summary = "Print a data source",
    .usage = "mox data get <name> [--format=toml|json]",
    .details = "Private shadows repo.",
    .group = .general,
    .needs_context = true,
}, get);

fn dataUsage(ctx: *app.Ctx) anyerror!u8 {
    return app.usageError(ctx, "usage: mox data get <name> [--format=toml|json]\n", .{});
}

pub const command = app.Command{
    .name = "data",
    .summary = "Print a data source",
    .group = .general,
    .run = dataUsage,
    .subcommands = &.{get_cmd},
};

const testing = std.testing;

fn tmpAbs(alloc: std.mem.Allocator, io: Io, sub_path: []const u8, rel: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, alloc);
    return std.fs.path.join(alloc, &.{ cwd, ".zig-cache", "tmp", sub_path, rel });
}

test "resolve: private shadows repo" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "private/data");
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "private/data/ids.toml", .data = "src = \"private\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "src = \"repo\"\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const priv = try tmpAbs(arena.allocator(), io, &tmp.sub_path, "private/data/ids.toml");
    const repo = try tmpAbs(arena.allocator(), io, &tmp.sub_path, "repo/data/ids.toml");

    const chosen = resolve(io, priv, repo).?;
    try testing.expectEqualStrings(priv, chosen);
    const content = try Io.Dir.cwd().readFileAlloc(io, chosen, arena.allocator(), .limited(4096));
    try testing.expectEqualStrings("src = \"private\"\n", content);
}

test "resolve: falls back to repo when private absent, null when neither" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "x = 1\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const priv = try tmpAbs(arena.allocator(), io, &tmp.sub_path, "private/data/ids.toml");
    const repo = try tmpAbs(arena.allocator(), io, &tmp.sub_path, "repo/data/ids.toml");
    const missing = try tmpAbs(arena.allocator(), io, &tmp.sub_path, "repo/data/nope.toml");

    try testing.expectEqualStrings(repo, resolve(io, priv, repo).?);
    try testing.expect(resolve(io, priv, missing) == null);
}

test "escapesRoot: rejects traversal and absolute, allows normal names" {
    try testing.expect(escapesRoot("../../x"));
    try testing.expect(escapesRoot("../secret"));
    try testing.expect(escapesRoot("/etc/passwd"));
    try testing.expect(escapesRoot("a/../b"));
    try testing.expect(!escapesRoot("ids"));
    try testing.expect(!escapesRoot("sub/ids.toml"));
    // A `..` inside a filename segment is not a traversal.
    try testing.expect(!escapesRoot("foo..bar"));
}

test "normalizeName: bare gets .toml, path kept verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ids.toml", try normalizeName(arena.allocator(), "ids"));
    try testing.expectEqualStrings("sub/ids.toml", try normalizeName(arena.allocator(), "sub/ids.toml"));
}

test "tomlToJson: array-of-tables with datetime renders to canonical text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\[[ident]]
        \\name = "work"
        \\priority = 2
        \\created = 2026-07-10T09:30:00Z
        \\
        \\[[ident]]
        \\name = "home"
        \\enabled = true
    ;
    const v = try toml.parse(a, src, .{});
    const jv = try tomlToJson(a, v);

    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try json.encode(&aw.writer, jv, .{ .indent = 2 });
    const out = aw.written();

    // Insertion order preserved; datetime is a JSON string in TOML canonical form.
    try testing.expect(std.mem.indexOf(u8, out, "\"created\": \"2026-07-10T09:30:00Z\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"priority\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"enabled\": true") != null);
    // Array-of-tables becomes a JSON array under the table key.
    try testing.expect(std.mem.indexOf(u8, out, "\"ident\": [") != null);
}
