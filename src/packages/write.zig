//! Appending a reconciled row to a manifest file.
//!
//! An append, never an edit: the new block goes at the end of the file, so
//! every existing byte -- comments, ordering, spacing, a row someone is
//! mid-thought on -- is preserved exactly. toml-zig's document editors refuse
//! array-of-tables paths anyway, and a whole-array rewrite would re-emit the
//! list canonically and drop its comments.

const std = @import("std");

const apply_write = @import("../apply/write.zig");
const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;

pub const Declaration = backend_mod.Backend.Declaration;
pub const Manifest = manifest_mod.Manifest;
pub const Source = manifest_mod.Source;

pub const Array = enum {
    packages,
    blacklist,

    fn header(self: Array) []const u8 {
        return switch (self) {
            .packages => "[[packages]]",
            .blacklist => "[[blacklist]]",
        };
    }
};

pub const Error = error{NoManifestFileForBackend};

/// The file a row for `backend` belongs in. Every repo file is preferred over
/// every private one -- a package belongs in the shared manifest unless the
/// user says otherwise -- and within a layer, one whose own default backend
/// matches before one that merely carries a row for it. Basename order breaks
/// ties so the same machine always picks the same file.
pub fn targetFor(m: Manifest, backend: []const u8) ?Source {
    for ([_]bool{ false, true }) |private| {
        for (m.sources) |src| {
            if (src.private != private) continue;
            if (src.default_backend) |d| {
                if (std.mem.eql(u8, d, backend)) return src;
            }
        }
        for (m.sources) |src| {
            if (src.private != private) continue;
            for (m.packages) |row| {
                if (!std.mem.eql(u8, row.backend, backend)) continue;
                if (!std.mem.eql(u8, row.origin, src.path)) continue;
                return src;
            }
        }
    }
    return null;
}

/// Render the block `append` would write, without touching the filesystem.
/// `backend` is written only when the target file declares no matching
/// default, so a row never restates what its file already says.
pub fn render(
    arena: std.mem.Allocator,
    array: Array,
    decl: Declaration,
    backend: ?[]const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("\n{s}\n", .{array.header()});
    try out.writer.print("name = {f}\n", .{Quoted{ .s = decl.name }});
    if (backend) |b| try out.writer.print("backend = {f}\n", .{Quoted{ .s = b }});
    for (decl.fields) |p| {
        switch (p.value) {
            .string => |v| try out.writer.print("{s} = {f}\n", .{ p.key, Quoted{ .s = v } }),
            .int => |v| try out.writer.print("{s} = {d}\n", .{ p.key, v }),
            .boolean => |v| try out.writer.print("{s} = {s}\n", .{ p.key, if (v) "true" else "false" }),
            .strings => |vs| {
                try out.writer.print("{s} = [", .{p.key});
                for (vs, 0..) |v, i| {
                    if (i > 0) try out.writer.writeAll(", ");
                    try out.writer.print("{f}", .{Quoted{ .s = v }});
                }
                try out.writer.writeAll("]\n");
            },
        }
    }
    return out.written();
}

/// One row as a single-line TOML inline table, the form a plugin reads from
/// its stdin one row per line: `{ name = "ghostty", kind = "cask" }`.
pub fn inlineRow(arena: std.mem.Allocator, name: []const u8, fields: []const manifest_mod.Pair) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{{ name = {f}", .{Quoted{ .s = name }});
    for (fields) |p| {
        switch (p.value) {
            .string => |v| try out.writer.print(", {s} = {f}", .{ p.key, Quoted{ .s = v } }),
            .int => |v| try out.writer.print(", {s} = {d}", .{ p.key, v }),
            .boolean => |v| try out.writer.print(", {s} = {s}", .{ p.key, if (v) "true" else "false" }),
            .strings => |vs| {
                try out.writer.print(", {s} = [", .{p.key});
                for (vs, 0..) |v, i| {
                    if (i > 0) try out.writer.writeAll(", ");
                    try out.writer.print("{f}", .{Quoted{ .s = v }});
                }
                try out.writer.writeAll("]");
            },
        }
    }
    try out.writer.writeAll(" }");
    return out.written();
}

/// Append the block to `path`, creating the file when it does not exist. The
/// rewrite is atomic: a manifest in the private layer lives in no git repo,
/// and a crash mid-write must not leave it empty.
pub fn append(arena: std.mem.Allocator, io: Io, path: []const u8, block: []const u8) !void {
    const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            try apply_write.writeAtomic(io, path, std.mem.trimStart(u8, block, "\n"), 0o644);
            return;
        },
        else => return e,
    };

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, existing);
    // A file not ending in a newline would otherwise glue its last line to
    // the new header.
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        try buf.append(arena, '\n');
    }
    try buf.appendSlice(arena, block);
    try apply_write.writeAtomic(io, path, buf.items, 0o644);
}

/// A TOML basic string. A package name is normally plain, but a manager is
/// free to use any bytes, and an unescaped quote or backslash would produce a
/// manifest that no longer parses.
const Quoted = struct {
    s: []const u8,

    pub fn format(self: Quoted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (self.s) |c| switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        };
        try w.writeByte('"');
    }
};

const testing = std.testing;

fn sourceOf(label: []const u8, path: []const u8, default_backend: ?[]const u8, private: bool) Source {
    return .{ .path = path, .label = label, .default_backend = default_backend, .private = private };
}

test "render: a bare formula is name only when the file declares the backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{ .name = "htop" }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"htop\"\n", got);
}

test "render: a cask carries its identifying field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{
        .name = "ghostty",
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
    }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"ghostty\"\nkind = \"cask\"\n", got);
}

test "render: backend is written only when the file does not already say it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .blacklist, .{ .name = "usage" }, "brew");
    try testing.expectEqualStrings("\n[[blacklist]]\nname = \"usage\"\nbackend = \"brew\"\n", got);
}

test "render: a quote or backslash in a name cannot break the manifest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{ .name = "we\"ird\\name" }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"we\\\"ird\\\\name\"\n", got);
}

test "render: int, bool and string-array fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{
        .name = "Xcode",
        .fields = &.{
            .{ .key = "id", .value = .{ .int = 497799835 } },
            .{ .key = "pin", .value = .{ .boolean = true } },
            .{ .key = "args", .value = .{ .strings = &.{ "--a", "--b" } } },
        },
    }, null);
    try testing.expectEqualStrings(
        "\n[[packages]]\nname = \"Xcode\"\nid = 497799835\npin = true\nargs = [\"--a\", \"--b\"]\n",
        got,
    );
}

test "inlineRow: a row renders as one inline table on one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try inlineRow(a, "ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }});
    try testing.expectEqualStrings("{ name = \"ghostty\", kind = \"cask\" }", got);
    try testing.expect(std.mem.indexOfScalar(u8, got, '\n') == null);
}

test "targetFor: prefers a file whose own default names the backend" {
    const m: Manifest = .{ .sources = &.{
        sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false),
        sourceOf("data/packages/b.toml", "/r/b.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/b.toml", targetFor(m, "brew").?.path);
}

test "targetFor: prefers the repo layer over the private one" {
    const m: Manifest = .{ .sources = &.{
        sourceOf("data/packages/local.toml", "/p/local.toml", "brew", true),
        sourceOf("data/packages/darwin.toml", "/r/darwin.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/darwin.toml", targetFor(m, "brew").?.path);
}

test "targetFor: a repo file merely carrying a row beats a private file declaring the default" {
    const row: manifest_mod.Row = .{
        .name = "ripgrep",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/r/mixed.toml",
        .label = "data/packages/mixed.toml",
        .index = 0,
    };
    const m: Manifest = .{
        .packages = &.{row},
        .sources = &.{
            sourceOf("data/packages/local.toml", "/p/local.toml", "brew", true),
            sourceOf("data/packages/mixed.toml", "/r/mixed.toml", null, false),
        },
    };
    try testing.expectEqualStrings("/r/mixed.toml", targetFor(m, "brew").?.path);
}

test "targetFor: falls back to a file already carrying a row for the backend" {
    const row: manifest_mod.Row = .{
        .name = "ripgrep",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/r/mixed.toml",
        .label = "data/packages/mixed.toml",
        .index = 0,
    };
    const m: Manifest = .{
        .packages = &.{row},
        .sources = &.{sourceOf("data/packages/mixed.toml", "/r/mixed.toml", null, false)},
    };
    try testing.expectEqualStrings("/r/mixed.toml", targetFor(m, "brew").?.path);
}

test "targetFor: no file speaks the backend" {
    const m: Manifest = .{ .sources = &.{sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false)} };
    try testing.expect(targetFor(m, "brew") == null);
}

test "append: adds a block and leaves every existing byte alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original =
        \\# a comment someone wrote
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"  # trailing note
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "p.toml", .data = original });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "p.toml" });

    try append(a, io, path, "\n[[packages]]\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expect(std.mem.startsWith(u8, after, original));
    try testing.expect(std.mem.indexOf(u8, after, "# a comment someone wrote") != null);
    try testing.expect(std.mem.indexOf(u8, after, "# trailing note") != null);
    try testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"htop\"\n"));
}

test "append: a file not ending in a newline does not glue its last line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.toml", .data = "backend = \"brew\"" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "p.toml" });

    try append(a, io, path, "\n[[packages]]\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"htop\"\n", after);
}

test "append: a missing file is created without a leading blank line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "new.toml" });

    try append(a, io, path, "\n[[packages]]\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings("[[packages]]\nname = \"htop\"\n", after);
}

test "append then load: the appended row parses back as written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/packages/darwin.toml",
        .data = "backend = \"brew\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const path = try std.fs.path.join(a, &.{ repo, "data", "packages", "darwin.toml" });

    const block = try render(a, .packages, .{
        .name = "ghostty",
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
    }, null);
    try append(a, io, path, block);

    // The round trip that matters: what was written is what loads.
    const m = try manifest_mod.load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 1), m.packages.len);
    try testing.expectEqualStrings("ghostty", m.packages[0].name);
    try testing.expectEqualStrings("brew", m.packages[0].backend);
    try testing.expectEqualStrings("cask", m.packages[0].field("kind").?.string);
}
