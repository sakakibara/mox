const std = @import("std");
const mox = @import("mox");

test "trigger integration: seen-version persists across reloads" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const state_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "triggers.state" });
    defer std.testing.allocator.free(state_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    {
        var s = try mox.trigger.state.State.loadOrEmpty(arena.allocator(), io, state_path);
        try std.testing.expect(try s.checkSeenVersion(arena.allocator(), "eza-0.18.0"));
        try s.save();
    }

    {
        var s = try mox.trigger.state.State.loadOrEmpty(arena.allocator(), io, state_path);
        try std.testing.expect(!try s.checkSeenVersion(arena.allocator(), "eza-0.18.0"));
    }
}
