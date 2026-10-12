//! `mox-state-dump --state <dir> [--repo <dir> --home <dir>]...`: print the
//! normalized state dump of a state directory. Built by `zig build
//! state-dump` for the differential gate; never shipped. The tombstones are
//! read from the first repo's tree.

const std = @import("std");
const mox = @import("mox");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args_z = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, args_z.len);
    for (args_z, args) |z, *o| o.* = z;

    var state: ?[]const u8 = null;
    var repos: std.ArrayList([]const u8) = .empty;
    var homes: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--state")) {
            state = value;
        } else if (std.mem.eql(u8, flag, "--repo")) {
            try repos.append(arena, value);
        } else if (std.mem.eql(u8, flag, "--home")) {
            try homes.append(arena, value);
        } else return error.UnknownFlag;
    }
    if (i != args.len or repos.items.len != homes.items.len) return error.Usage;

    var parts: std.ArrayList(mox.state_dump.Part) = .empty;
    for (repos.items, homes.items) |r, h| try parts.append(arena, .{ .repo = r, .home = h });
    var tombstones: []const []const u8 = &.{};
    if (parts.items.len > 0) {
        const src = try std.fs.path.join(arena, &.{ parts.items[0].repo, "src" });
        if (mox.source.tree.walk(arena, io, src, parts.items[0].home)) |tree| {
            tombstones = tree.released;
        } else |_| {}
    }
    const d = try mox.state_dump.load(arena, io, .{
        .state_dir = state orelse return error.Usage,
        .parts = parts.items,
        .tombstones = tombstones,
    });
    var buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    try w.interface.writeAll(try mox.state_dump.render(arena, d, mox.state_dump.verbatim));
    try w.interface.flush();
}
