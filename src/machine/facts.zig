const std = @import("std");
const toml = @import("toml");

const Io = std.Io;
const state_mod = @import("state.zig");

const max_facts_bytes: usize = 64 * 1024;

/// `load`'s result: the usable facts plus the names of any top-level keys
/// dropped for a non-string value, so a caller can warn instead of leaving
/// the drop silent.
pub const LoadResult = struct {
    facts: []const state_mod.Fact,
    /// Top-level keys whose value was not a string, in file order.
    skipped: []const []const u8 = &.{},
};

/// Load custom machine facts from a TOML file.
///
/// Top-level scalar string entries become facts. A non-string value (number,
/// bool, array, nested table) is dropped -- facts feed into axis matching and
/// `<machine.X>` substitution, both stringly-typed -- and named in `skipped`
/// so the caller can warn: loud on capture use (a `when profile=work` gate
/// simply never matches), it must not also be silent here.
///
/// A missing file is not an error: returns an empty result. This lets
/// `mox apply` work uniformly whether or not the user has configured facts.
pub fn load(arena: std.mem.Allocator, io: Io, path: []const u8) !LoadResult {
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_facts_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .{ .facts = &.{} },
        else => return e,
    };

    const v = try toml.parse(arena, content, .{});
    if (v != .table) return .{ .facts = &.{} };

    var out: std.ArrayList(state_mod.Fact) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    var it = v.table.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .string => |s| try out.append(arena, .{ .name = entry.key_ptr.*, .value = s }),
            else => try skipped.append(arena, entry.key_ptr.*),
        }
    }
    return .{ .facts = try out.toOwnedSlice(arena), .skipped = try skipped.toOwnedSlice(arena) };
}

test "load: missing file returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try load(arena.allocator(), std.testing.io, "/nonexistent/path/facts.toml");
    try std.testing.expectEqual(@as(usize, 0), r.facts.len);
    try std.testing.expectEqual(@as(usize, 0), r.skipped.len);
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

    const r = try load(arena.allocator(), io, facts_path);
    try std.testing.expectEqual(@as(usize, 3), r.facts.len);
    try std.testing.expectEqual(@as(usize, 0), r.skipped.len);

    var got_email: ?[]const u8 = null;
    var got_profile: ?[]const u8 = null;
    for (r.facts) |f| {
        if (std.mem.eql(u8, f.name, "email")) got_email = f.value;
        if (std.mem.eql(u8, f.name, "profile")) got_profile = f.value;
    }
    try std.testing.expectEqualStrings("test@example.com", got_email.?);
    try std.testing.expectEqualStrings("personal", got_profile.?);
}

test "load: skips non-string values, and names them in skipped" {
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

    const r = try load(arena.allocator(), io, facts_path);
    try std.testing.expectEqual(@as(usize, 1), r.facts.len);
    try std.testing.expectEqualStrings("name", r.facts[0].name);
    try std.testing.expectEqualStrings("hello", r.facts[0].value);

    try std.testing.expectEqual(@as(usize, 3), r.skipped.len);
    try std.testing.expectEqualStrings("count", r.skipped[0]);
    try std.testing.expectEqualStrings("enabled", r.skipped[1]);
    try std.testing.expectEqualStrings("places", r.skipped[2]);
}
