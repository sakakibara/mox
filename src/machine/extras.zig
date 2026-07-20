//! User-supplied extensions to the built-in TOOL_WATCH_LIST and
//! ENV_WATCH_LIST. Loaded from `$XDG_CONFIG_HOME/mox/extras.toml`.
//!
//! Schema:
//!
//!   tools = ["my-binary", "company-cli"]
//!   envs  = ["MY_CUSTOM_VAR", "INTERNAL_ENV"]
//!
//! Both arrays are optional; absent file returns empty extras.

const std = @import("std");
const toml = @import("toml");

const Io = std.Io;

const max_extras_bytes: usize = 16 * 1024;

pub const Extras = struct {
    /// Additional binaries to scan `$PATH` for, beyond the built-in
    /// TOOL_WATCH_LIST. Each becomes a `tool=<name>` axis binding and
    /// surfaces via `<machine.tool_path.<name>>`.
    tools: []const []const u8 = &.{},
    /// Additional env vars to capture (presence + value), beyond the built-in
    /// ENV_WATCH_LIST. Each becomes an `env=<name>` axis binding and
    /// surfaces via `<env.<name>>`.
    envs: []const []const u8 = &.{},
};

/// Load extras from `path`. Missing file returns empty extras (not an error).
pub fn load(arena: std.mem.Allocator, io: Io, path: []const u8) !Extras {
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_extras_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    const v = try toml.parse(arena, content, .{});
    if (v != .table) return .{};
    return .{
        .tools = try stringArrayField(arena, &v, "tools"),
        .envs = try stringArrayField(arena, &v, "envs"),
    };
}

fn stringArrayField(arena: std.mem.Allocator, v: *const toml.Value, key: []const u8) ![]const []const u8 {
    const got = v.table.get(key) orelse return &.{};
    if (got != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (got.array.items) |item| {
        if (item != .string) continue;
        try out.append(arena, item.string);
    }
    return out.toOwnedSlice(arena);
}

test "load: missing file returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try load(arena.allocator(), std.testing.io, "/no/such/path/extras.toml");
    try std.testing.expectEqual(@as(usize, 0), e.tools.len);
    try std.testing.expectEqual(@as(usize, 0), e.envs.len);
}

test "load: reads tools and envs arrays" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "extras.toml",
        .data = "tools = [\"foo\", \"bar\"]\nenvs = [\"X\", \"Y\", \"Z\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "extras.toml",
    });
    defer std.testing.allocator.free(path);

    const e = try load(arena.allocator(), io, path);
    try std.testing.expectEqual(@as(usize, 2), e.tools.len);
    try std.testing.expectEqualStrings("foo", e.tools[0]);
    try std.testing.expectEqualStrings("bar", e.tools[1]);
    try std.testing.expectEqual(@as(usize, 3), e.envs.len);
}

test "load: missing arrays default to empty" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "extras.toml",
        .data = "tools = [\"only-tools\"]\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "extras.toml",
    });
    defer std.testing.allocator.free(path);

    const e = try load(arena.allocator(), io, path);
    try std.testing.expectEqual(@as(usize, 1), e.tools.len);
    try std.testing.expectEqual(@as(usize, 0), e.envs.len);
}
