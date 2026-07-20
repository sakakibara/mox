const std = @import("std");
const toml = @import("toml");

const Io = std.Io;
const state_mod = @import("state.zig");

const max_facts_bytes: usize = 64 * 1024;

/// Load custom machine facts from a TOML file.
///
/// Top-level scalar string entries become facts. Non-string values
/// (numbers, bools, arrays, nested tables) are silently skipped — facts
/// are meant to feed into axis matching and `<machine.X>` substitution,
/// both of which are stringly-typed.
///
/// A missing file is not an error: returns an empty slice. This lets
/// `mox apply` work uniformly whether or not the user has configured facts.
pub fn load(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const state_mod.Fact {
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_facts_bytes)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };

    const v = try toml.parse(arena, content, .{});
    if (v != .table) return &.{};

    var out: std.ArrayList(state_mod.Fact) = .empty;
    var it = v.table.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .string => |s| try out.append(arena, .{ .name = entry.key_ptr.*, .value = s }),
            else => {},
        }
    }
    return out.toOwnedSlice(arena);
}

test "load: missing file returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try load(arena.allocator(), std.testing.io, "/nonexistent/path/facts.toml");
    try std.testing.expectEqual(@as(usize, 0), facts.len);
}

test "load: reads top-level scalar string entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "facts.toml",
        .data = "email = \"test@example.com\"\nprofile = \"personal\"\ntimezone = \"Japan\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const facts_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "facts.toml",
    });
    defer std.testing.allocator.free(facts_path);

    const facts = try load(arena.allocator(), io, facts_path);
    try std.testing.expectEqual(@as(usize, 3), facts.len);

    var got_email: ?[]const u8 = null;
    var got_profile: ?[]const u8 = null;
    for (facts) |f| {
        if (std.mem.eql(u8, f.name, "email")) got_email = f.value;
        if (std.mem.eql(u8, f.name, "profile")) got_profile = f.value;
    }
    try std.testing.expectEqualStrings("test@example.com", got_email.?);
    try std.testing.expectEqualStrings("personal", got_profile.?);
}

test "load: skips non-string values" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "facts.toml",
        .data = "name = \"hello\"\n" ++
            "count = 42\n" ++
            "enabled = true\n" ++
            "places = [\"a\", \"b\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const facts_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "facts.toml",
    });
    defer std.testing.allocator.free(facts_path);

    const facts = try load(arena.allocator(), io, facts_path);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try std.testing.expectEqualStrings("name", facts[0].name);
    try std.testing.expectEqualStrings("hello", facts[0].value);
}
