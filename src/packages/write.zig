//! Appending a reconciled row to a manifest file.
//!
//! An append, never an edit: the new block goes at the end of the file, so
//! every existing byte -- comments, ordering, spacing, a row someone is
//! mid-thought on -- is preserved exactly. toml-zig's document editors refuse
//! array-of-tables paths anyway, and a whole-array rewrite would re-emit the
//! list canonically and drop its comments.

const std = @import("std");
const builtin = @import("builtin");

const apply_write = @import("../apply/write.zig");
const axis = @import("../dsl/axis.zig");
const resolver_mod = @import("../dsl/resolver.zig");
const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;

pub const Declaration = backend_mod.Backend.Declaration;
pub const Manifest = manifest_mod.Manifest;
pub const Source = manifest_mod.Source;
pub const Resolver = resolver_mod.Resolver;

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

pub const Error = error{ NoManifestFileForBackend, TooManySymlinkHops };

/// The file a row for `backend` belongs in. Every repo file is preferred over
/// every private one -- a package belongs in the shared manifest unless the
/// user says otherwise -- and within a layer, one whose own default backend
/// matches before one that merely carries a row for it. Basename order breaks
/// ties so the same machine always picks the same file. A file whose own
/// `when` does not hold on this machine is never the target: a row recorded
/// there would not be desired on the machine that just recorded it.
pub fn targetFor(arena: std.mem.Allocator, m: Manifest, backend: []const u8, r: *const Resolver) !?Source {
    for ([_]bool{ false, true }) |private| {
        for (m.sources) |src| {
            if (src.private != private) continue;
            if (!try gateHolds(arena, src, r)) continue;
            if (src.default_backend) |d| {
                if (std.mem.eql(u8, d, backend)) return src;
            }
        }
        for (m.sources) |src| {
            if (src.private != private) continue;
            if (!try gateHolds(arena, src, r)) continue;
            if (carriesRow(m, src, backend)) return src;
        }
    }
    return null;
}

/// A file with no `when` is unconditional. `manifest.load` rejected a
/// malformed gate, so a failure here is allocation, and is propagated rather
/// than read as "excluded".
fn gateHolds(arena: std.mem.Allocator, src: Source, r: *const Resolver) !bool {
    const expr_src = src.when orelse return true;
    const expr = try axis.parseString(arena, expr_src);
    return axis.evaluate(expr, r);
}

/// Whether `src` already holds a row for `backend`: a package or a blacklist
/// entry, either one saying the file speaks that backend.
fn carriesRow(m: Manifest, src: Source, backend: []const u8) bool {
    for (m.packages) |row| {
        if (std.mem.eql(u8, row.backend, backend) and std.mem.eql(u8, row.origin, src.path)) return true;
    }
    for (m.blacklist) |row| {
        if (std.mem.eql(u8, row.backend, backend) and std.mem.eql(u8, row.origin, src.path)) return true;
    }
    return false;
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
        const key = Key{ .s = p.key };
        switch (p.value) {
            .string => |v| try out.writer.print("{f} = {f}\n", .{ key, Quoted{ .s = v } }),
            .int => |v| try out.writer.print("{f} = {d}\n", .{ key, v }),
            .boolean => |v| try out.writer.print("{f} = {s}\n", .{ key, if (v) "true" else "false" }),
            .strings => |vs| {
                try out.writer.print("{f} = [", .{key});
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
        const key = Key{ .s = p.key };
        switch (p.value) {
            .string => |v| try out.writer.print(", {f} = {f}", .{ key, Quoted{ .s = v } }),
            .int => |v| try out.writer.print(", {f} = {d}", .{ key, v }),
            .boolean => |v| try out.writer.print(", {f} = {s}", .{ key, if (v) "true" else "false" }),
            .strings => |vs| {
                try out.writer.print(", {f} = [", .{key});
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
/// and a crash mid-write must not leave it empty. A manifest that is a
/// symlink is rewritten where the link points, so the link survives.
pub fn append(arena: std.mem.Allocator, io: Io, link_path: []const u8, block: []const u8) !void {
    const path = try resolveLinks(arena, io, link_path);
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
    try apply_write.writeAtomic(io, path, buf.items, try modeOf(io, path));
}

const max_link_hops: usize = 8;

/// The file `path` finally names, following a symlink chain with each
/// relative target read against the directory of the link that holds it. A
/// dangling link resolves to its missing target, which the caller then
/// creates, making the link good rather than replacing it.
fn resolveLinks(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var cur = path;
    var hops: usize = 0;
    while (true) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(io, cur, &buf) catch |e| switch (e) {
            error.NotLink, error.FileNotFound => return cur,
            else => return e,
        };
        if (hops == max_link_hops) return Error.TooManySymlinkHops;
        hops += 1;
        const target = buf[0..n];
        cur = if (std.fs.path.isAbsolute(target))
            try arena.dupe(u8, target)
        else
            try std.fs.path.resolve(arena, &.{ std.fs.path.dirname(cur) orelse ".", target });
    }
}

/// The mode the rewrite keeps: a private manifest the user made 0600 must
/// not come back 0644 for having a row appended.
fn modeOf(io: Io, path: []const u8) !u32 {
    if (!Io.File.Permissions.has_executable_bit) return 0o644;
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return st.permissions.toMode();
}

/// Whether a key can be written bare: `[A-Za-z0-9_-]+`, the TOML bare-key
/// charset.
pub fn keyOk(k: []const u8) bool {
    if (k.len == 0) return false;
    for (k) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

/// A TOML key: bare when it can be, a basic string otherwise. The manifest
/// accepts any key, so what is handed to a plugin or written back must spell
/// it the way TOML reads it, not lose the quotes it needed.
const Key = struct {
    s: []const u8,

    pub fn format(self: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (keyOk(self.s)) return w.writeAll(self.s);
        return (Quoted{ .s = self.s }).format(w);
    }
};

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
            else => if (c < 0x20 or c == 0x7f) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        };
        try w.writeByte('"');
    }
};

const testing = std.testing;

fn sourceOf(label: []const u8, path: []const u8, default_backend: ?[]const u8, private: bool) Source {
    return .{ .path = path, .label = label, .default_backend = default_backend, .private = private };
}

fn gatedSource(label: []const u8, path: []const u8, default_backend: ?[]const u8, when: []const u8) Source {
    return .{ .path = path, .label = label, .default_backend = default_backend, .when = when, .private = false };
}

/// A machine with no bindings at all: every gated file is excluded, every
/// ungated one is in.
const no_bindings: std.StringHashMap([]const u8) = .init(testing.allocator);
const unbound: Resolver = .{ .live = &.{ .bindings = &no_bindings } };

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

test "inlineRow: a key outside the bare charset is quoted, never misparsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try inlineRow(a, "x", &.{
        .{ .key = "my key", .value = .{ .int = 1 } },
        .{ .key = "a.b", .value = .{ .string = "v" } },
    });
    try testing.expectEqualStrings("{ name = \"x\", \"my key\" = 1, \"a.b\" = \"v\" }", got);
}

test "targetFor: a file carrying only a blacklist row for the backend speaks it" {
    const row: manifest_mod.BlacklistRow = .{
        .name = "usage",
        .backend = "brew",
        .fields = &.{},
        .origin = "/r/mixed.toml",
        .label = "data/packages/mixed.toml",
        .index = 0,
    };
    const m: Manifest = .{
        .blacklist = &.{row},
        .sources = &.{
            sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false),
            sourceOf("data/packages/mixed.toml", "/r/mixed.toml", null, false),
        },
    };
    try testing.expectEqualStrings("/r/mixed.toml", (try targetFor(testing.allocator, m, "brew", &unbound)).?.path);
}

test "targetFor: prefers a file whose own default names the backend" {
    const m: Manifest = .{ .sources = &.{
        sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false),
        sourceOf("data/packages/b.toml", "/r/b.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/b.toml", (try targetFor(testing.allocator, m, "brew", &unbound)).?.path);
}

test "targetFor: prefers the repo layer over the private one" {
    const m: Manifest = .{ .sources = &.{
        sourceOf("data/packages/local.toml", "/p/local.toml", "brew", true),
        sourceOf("data/packages/darwin.toml", "/r/darwin.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/darwin.toml", (try targetFor(testing.allocator, m, "brew", &unbound)).?.path);
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
    try testing.expectEqualStrings("/r/mixed.toml", (try targetFor(testing.allocator, m, "brew", &unbound)).?.path);
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
    try testing.expectEqualStrings("/r/mixed.toml", (try targetFor(testing.allocator, m, "brew", &unbound)).?.path);
}

test "targetFor: no file speaks the backend" {
    const m: Manifest = .{ .sources = &.{sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false)} };
    try testing.expect((try targetFor(testing.allocator, m, "brew", &unbound)) == null);
}

test "targetFor: a file whose gate excludes this machine is never the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const excluded: Manifest = .{ .sources = &.{
        gatedSource("data/packages/linux.toml", "/r/linux.toml", "brew", "os=linux"),
    } };
    try testing.expect((try targetFor(a, excluded, "brew", &r)) == null);

    // The same file, gated to this machine, is the target as before.
    const included: Manifest = .{ .sources = &.{
        gatedSource("data/packages/darwin.toml", "/r/darwin.toml", "brew", "os=darwin"),
    } };
    try testing.expectEqualStrings("/r/darwin.toml", (try targetFor(a, included, "brew", &r)).?.path);
}

test "targetFor: an excluded file is passed over for one that holds here" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // Basename order would pick a.toml; its gate hands the row to b.toml.
    const m: Manifest = .{ .sources = &.{
        gatedSource("data/packages/a.toml", "/r/a.toml", "brew", "os=linux"),
        sourceOf("data/packages/b.toml", "/r/b.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/b.toml", (try targetFor(a, m, "brew", &r)).?.path);
}

test "render: DEL is escaped, as a TOML basic string requires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{ .name = "a\x7fb\x01c" }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"a\\u007fb\\u0001c\"\n", got);
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

test "append: an existing file keeps its mode" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.toml", .data = "backend = \"brew\"\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "p.toml" });
    try Io.Dir.cwd().setFilePermissions(io, path, Io.File.Permissions.fromMode(0o600), .{});

    try append(a, io, path, "\n[[packages]]\nname = \"htop\"\n");

    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, st.permissions.toMode() & 0o777));
}

test "append: a symlinked manifest is rewritten through the link, which survives" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/p.toml", .data = "backend = \"brew\"\n" });
    // A relative link, resolved against the link's own directory, through a
    // second hop, so both the relative and the chained case are covered.
    try tmp.dir.symLink(io, "../real/p.toml", "repo/mid.toml", .{});
    try tmp.dir.symLink(io, "mid.toml", "repo/p.toml", .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const link = try std.fs.path.join(a, &.{ root, "repo", "p.toml" });
    const real = try std.fs.path.join(a, &.{ root, "real", "p.toml" });

    try append(a, io, link, "\n[[packages]]\nname = \"htop\"\n");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("mid.toml", buf[0..try Io.Dir.cwd().readLink(io, link, &buf)]);
    const after = try Io.Dir.cwd().readFileAlloc(io, real, a, .limited(1 << 20));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"htop\"\n", after);
}

test "append: a symlink chain past the hop bound is refused by name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "l0", "l0", .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "l0" });

    try testing.expectError(Error.TooManySymlinkHops, append(a, io, link, "\n[[packages]]\nname = \"htop\"\n"));
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
