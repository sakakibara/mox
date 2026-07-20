const std = @import("std");
const toml = @import("toml.zig");
const dep_toml = @import("toml");

const Io = std.Io;
const ReadFileAllocError = Io.Dir.ReadFileAllocError;

pub const LoadError = ReadFileAllocError || toml.ParseError;

const max_file_bytes: usize = 4 * 1024 * 1024;

/// Load a TOML data source from disk. The caller is responsible for resolving
/// the absolute path (typically `<file>.d/<rel_path>`). Returned strings and
/// records are owned by `arena`.
pub fn loadFile(arena: std.mem.Allocator, io: Io, abs_path: []const u8) LoadError!toml.ArrayMap {
    const content = try Io.Dir.cwd().readFileAlloc(io, abs_path, arena, .limited(max_file_bytes));
    return try toml.parse(arena, content);
}

pub const ScalarError = error{ NonScalarData, DataFileError } || std.mem.Allocator.Error;

/// Look up a scalar in `data/<file>.toml`, the private layer shadowing the repo
/// exactly as `mox data get` does. `table` (when non-null) then `key` navigate
/// one level deep. Returns the rendered scalar text (arena-owned), or null when
/// the file, table, or key is absent (a `| default` may then rescue it). A
/// present-but-non-scalar value (array/table) is `error.NonScalarData`; a read
/// or TOML parse failure is `error.DataFileError`.
///
/// `file` is a bare stem; the joins are native (`repo_dir`/`data`/`file.toml`),
/// never a portable key, so the same call is correct on every platform.
pub fn lookupScalar(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    private_dir: []const u8,
    file: []const u8,
    table: ?[]const u8,
    key: []const u8,
) ScalarError!?[]const u8 {
    const filename = try std.fmt.allocPrint(arena, "{s}.toml", .{file});
    const content = (try readShadowed(arena, io, repo_dir, private_dir, filename)) orelse return null;

    const doc = dep_toml.parse(arena, content, .{}) catch return error.DataFileError;
    if (doc != .table) return null;

    const leaf: dep_toml.Value = blk: {
        if (table) |t| {
            const tv = doc.table.get(t) orelse return null;
            if (tv != .table) return null;
            break :blk tv.table.get(key) orelse return null;
        }
        break :blk doc.table.get(key) orelse return null;
    };

    const text = toml.scalarText(arena, leaf) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DataFileError,
    };
    if (text) |t| return t;
    return error.NonScalarData;
}

/// Read `data/<filename>` from the private layer if present there, else the
/// repo. Null when it exists in neither.
fn readShadowed(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    private_dir: []const u8,
    filename: []const u8,
) ScalarError!?[]const u8 {
    if (private_dir.len > 0) {
        const p = try std.fs.path.join(arena, &.{ private_dir, "data", filename });
        if (try readIfExists(arena, io, p)) |c| return c;
    }
    if (repo_dir.len == 0) return null;
    const r = try std.fs.path.join(arena, &.{ repo_dir, "data", filename });
    return readIfExists(arena, io, r);
}

fn readIfExists(arena: std.mem.Allocator, io: Io, path: []const u8) ScalarError!?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => error.DataFileError,
    };
}

test "loadFile: error path for missing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = loadFile(arena.allocator(), std.testing.io, "/nonexistent/path.toml");
    try std.testing.expectError(error.FileNotFound, result);
}

fn tmpDataAbs(a: std.mem.Allocator, io: Io, sub: []const u8, rel: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", sub, rel });
}

test "lookupScalar: renders string, int, bool, and a two-level table scalar" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/signing.toml", .data = "personal_key = \"AAAAkey\"\ncount = 3\nenabled = true\n[keys]\npersonal = \"SUBKEY\"\n" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpDataAbs(a, io, &tmp.sub_path, "repo");

    try std.testing.expectEqualStrings("AAAAkey", (try lookupScalar(a, io, repo, "", "signing", null, "personal_key")).?);
    try std.testing.expectEqualStrings("3", (try lookupScalar(a, io, repo, "", "signing", null, "count")).?);
    try std.testing.expectEqualStrings("true", (try lookupScalar(a, io, repo, "", "signing", null, "enabled")).?);
    try std.testing.expectEqualStrings("SUBKEY", (try lookupScalar(a, io, repo, "", "signing", "keys", "personal")).?);
}

test "lookupScalar: private layer shadows repo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "private/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "k = \"repo\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "private/data/ids.toml", .data = "k = \"priv\"\n" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpDataAbs(a, io, &tmp.sub_path, "repo");
    const priv = try tmpDataAbs(a, io, &tmp.sub_path, "private");

    try std.testing.expectEqualStrings("priv", (try lookupScalar(a, io, repo, priv, "ids", null, "k")).?);
    // Without the private layer the repo value shows through.
    try std.testing.expectEqualStrings("repo", (try lookupScalar(a, io, repo, "", "ids", null, "k")).?);
}

test "lookupScalar: missing file and missing key are null; non-scalar errors" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/signing.toml", .data = "k = \"v\"\nlist = [1, 2]\n" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpDataAbs(a, io, &tmp.sub_path, "repo");

    try std.testing.expect((try lookupScalar(a, io, repo, "", "nope", null, "k")) == null); // missing file
    try std.testing.expect((try lookupScalar(a, io, repo, "", "signing", null, "absent")) == null); // missing key
    try std.testing.expect((try lookupScalar(a, io, repo, "", "signing", "k", "sub")) == null); // key is not a table
    try std.testing.expectError(error.NonScalarData, lookupScalar(a, io, repo, "", "signing", null, "list"));
}
