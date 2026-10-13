const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");
const state_cli = @import("state.zig");

const Spec = struct {
    id: cli.Pos([]const u8, .{ .optional = true, .help = "list what this snapshot holds" }),
};

/// `mox snapshot [<id>]`: list snapshot ids, oldest first, or what one holds.
fn list(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const st = (try state_cli.open(ctx, .{ .writes = false, .locked = false })) orelse return 2;
    if (a.id) |id| return entries(ctx, st, id);
    const gens = try st.listed();
    if (gens.len == 0) {
        try ctx.out.writeAll("no snapshots\n");
        return 0;
    }
    for (gens) |l| {
        if (l.gen.kind == .rollback or l.gen.run_kind == .rollback) {
            if (l.gen.undoes) |of| {
                try ctx.out.print("{s} (what rolling back {s} replaced)\n", .{ l.id, of });
                continue;
            }
        }
        try ctx.out.print("{s}\n", .{l.id});
    }
    return 0;
}

/// Every entry generation `id` displaced, one per line: its key, its type,
/// and the blob path of its content or the target of its link; a
/// directory's members follow it, indented.
fn entries(ctx: *app.Ctx, st: *const mox.state.Draft, id: []const u8) !u8 {
    const g = (try st.displacedOf(id)) orelse {
        try ctx.err.print("mox snapshot: no snapshot '{s}' (see 'mox snapshot')\n", .{id});
        return 1;
    };
    const keys = try ctx.alloc.dupe([]const u8, g.displaced.keys());
    std.mem.sort([]const u8, keys, {}, lessStr);
    for (keys) |key| {
        const d = g.displaced.get(key).?;
        if (d.root != null) continue;
        try line(ctx, st, "", key, d);
        if (d.type != .dir) continue;
        for (keys) |member| {
            const m = g.displaced.get(member).?;
            const root = m.root orelse continue;
            if (std.mem.eql(u8, root, key)) try line(ctx, st, "  ", member, m);
        }
    }
    return 0;
}

fn line(ctx: *app.Ctx, st: *const mox.state.Draft, indent: []const u8, key: []const u8, d: mox.state.generation.Displaced) !void {
    switch (d.type) {
        .file => try ctx.out.print("{s}{s} file {s}\n", .{ indent, key, try st.blobPath(d.blob.?) }),
        .link => try ctx.out.print("{s}{s} link -> {s}\n", .{ indent, key, d.target orelse "" }),
        .dir => try ctx.out.print("{s}{s} dir\n", .{ indent, key }),
    }
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const command = app.command(Spec, .{
    .name = "snapshot",
    .usage = "mox snapshot [<id>]",
    .summary = "List snapshots (taken before every overwrite, removal or rollback), or what one holds",
    .group = .general,
    .needs_context = true,
}, list);
