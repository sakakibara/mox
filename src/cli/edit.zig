//! `mox edit <name>`: open the source file behind a managed path in `$EDITOR`.
//!
//! `<name>` is a live path (absolute, under HOME) or a src-relative path
//! (`.config/nvim/init.lua`). With no `--axis`, the base source file is
//! edited; `--axis <tuple>` selects the matching overlay (Cat A/C) or region
//! fragment (Cat B) instead. Read-only wrt mox state: takes no lock. When the
//! requested source does not exist, the candidate paths are reported.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Io = std.Io;
const AxisTuple = mox.source.tree.AxisTuple;

/// Canonical absolute live path a `<name>` refers to. An absolute name is
/// returned as-is; a relative name is resolved against `home` (src-relative
/// and home-relative coincide, since `src/X` materializes at `home/X`).
pub fn liveTarget(arena: std.mem.Allocator, name: []const u8, home: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(name)) return arena.dupe(u8, name);
    return mox.source.path.joinKeyOnto(arena, home, name);
}

/// Render an axis tuple to its canonical filename form: pairs sorted by name
/// (parseFilename already sorts), joined by `+`, e.g. `os=darwin+profile=work`.
pub fn tupleFilename(arena: std.mem.Allocator, tuple: AxisTuple) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (tuple.pairs, 0..) |p, i| {
        if (i > 0) try w.writeByte('+');
        try w.print("{s}={s}", .{ p.name, p.value });
    }
    return aw.toOwnedSlice();
}

/// True when two axis tuples bind exactly the same (name, value) pairs. Both
/// are sorted by name (parseFilename guarantees it), so a positional compare
/// suffices.
pub fn tuplesEqual(a: AxisTuple, b: AxisTuple) bool {
    if (a.pairs.len != b.pairs.len) return false;
    for (a.pairs, b.pairs) |pa, pb| {
        if (!std.mem.eql(u8, pa.name, pb.name)) return false;
        if (!std.mem.eql(u8, pa.value, pb.value)) return false;
    }
    return true;
}

const Spec = struct {
    name: cli.spec.Pos([]const u8, .{ .help = "managed live path or src-relative name" }),
    axis: cli.spec.Opt([]const u8, .{ .value_name = "tuple", .help = "edit the overlay/fragment for this axis tuple instead" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const name = a.name;
    const axis_str: ?[]const u8 = a.axis;
    const live_path = try liveTarget(ctx.alloc, name, context.paths.home);

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, context.paths.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox edit: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        else => return e,
    };

    var found: ?mox.source.tree.ManagedFile = null;
    for (tree.files) |f| {
        if (std.mem.eql(u8, f.live_path, live_path)) {
            found = f;
            break;
        }
    }

    const target_path: []const u8 = blk: {
        const file = found orelse {
            // Not managed: report where a base file would live.
            const rel = std.mem.trimStart(u8, live_path[@min(context.paths.home.len, live_path.len)..], "/");
            const cand = try std.fs.path.join(ctx.alloc, &.{ src_dir, rel });
            try ctx.err.print("mox edit: {s}: not managed (no source at {s})\n", .{ name, cand });
            return 1;
        };

        if (axis_str) |as| {
            const want = mox.source.tuple.parseFilename(ctx.alloc, as) catch {
                try ctx.err.print("mox edit: invalid axis tuple '{s}'\n", .{as});
                return 2;
            };
            if (overlayFor(file, want)) |p| break :blk p;
            const tuple_name = try tupleFilename(ctx.alloc, want);
            const base_abs = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, file.source_base_path });
            const overlay_dir = try std.fmt.allocPrint(ctx.alloc, "{s}.d", .{base_abs});
            const cand = try mox.source.path.joinKeyOnto(ctx.alloc, overlay_dir, tuple_name);
            try ctx.err.print("mox edit: no overlay for '{s}' on {s} (looked for {s})\n", .{ as, name, cand });
            return 1;
        }

        if (!file.has_base) {
            try ctx.err.print("mox edit: {s} has no base file; pass --axis <tuple> to edit an overlay\n", .{name});
            return 1;
        }
        break :blk file.source_base_abs;
    };

    return editFile(ctx, target_path);
}

/// Absolute path of the overlay (Cat A/C) or region fragment (Cat B) on `file`
/// whose tuple equals `want`, or null when none matches.
fn overlayFor(file: mox.source.tree.ManagedFile, want: AxisTuple) ?[]const u8 {
    for (file.overlays) |ov| {
        if (tuplesEqual(ov.tuple, want)) return ov.path;
    }
    for (file.regions) |region| {
        for (region.fragments) |frag| {
            if (tuplesEqual(frag.tuple, want)) return frag.path;
        }
    }
    return null;
}

/// Spawn `$EDITOR <path>` inheriting the terminal, and wait for it. `$EDITOR`
/// may carry arguments (e.g. `code -w`), split on whitespace.
fn editFile(ctx: *app.Ctx, path: []const u8) !u8 {
    const context = ctx.context.?;
    const editor = context.env.getAlloc(ctx.alloc, "EDITOR") catch {
        try ctx.err.writeAll("mox edit: $EDITOR is not set\n");
        return 1;
    };
    if (editor.len == 0) {
        try ctx.err.writeAll("mox edit: $EDITOR is empty\n");
        return 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, editor, ' ');
    while (it.next()) |word| try argv.append(ctx.alloc, word);
    try argv.append(ctx.alloc, path);

    var child = std.process.spawn(ctx.io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        try ctx.err.print("mox edit: cannot launch editor '{s}': {s}\n", .{ editor, @errorName(e) });
        return 1;
    };
    const term = child.wait(ctx.io) catch |e| {
        try ctx.err.print("mox edit: editor wait failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub const command = app.command(Spec, .{
    .name = "edit",
    .summary = "Open the source behind a managed path in $EDITOR",
    .usage = "mox edit <name> [--axis <tuple>]",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "liveTarget: absolute name is returned verbatim, relative joins home" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/home/me/.zshrc", try liveTarget(a, "/home/me/.zshrc", "/home/me"));
    const want = try std.fs.path.join(a, &.{ "/home/me", ".config", "nvim", "init.lua" });
    try testing.expectEqualStrings(want, try liveTarget(a, ".config/nvim/init.lua", "/home/me"));
}

test "tupleFilename: renders sorted pairs joined by plus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try mox.source.tuple.parseFilename(arena.allocator(), "profile=work+os=darwin");
    try testing.expectEqualStrings("os=darwin+profile=work", try tupleFilename(arena.allocator(), t));
}

test "tuplesEqual: same pairs match, differing pairs do not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try mox.source.tuple.parseFilename(a, "os=darwin");
    const y = try mox.source.tuple.parseFilename(a, "os=darwin");
    const z = try mox.source.tuple.parseFilename(a, "os=linux");
    try testing.expect(tuplesEqual(x, y));
    try testing.expect(!tuplesEqual(x, z));
}
