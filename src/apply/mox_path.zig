//! The `$MOX_PATH` channel: every setup script gets an
//! env var naming a writable file in this run's private temp area. A script
//! that installs a tool into an arbitrary location -- one that is neither
//! `$PATH` nor this repo's `data/paths.toml` registry -- appends that
//! directory to the file
//! (one absolute path per line, modeled on GitHub Actions' `GITHUB_PATH`).
//! After each stage, mox reads back whatever is new, widens the tool probe's
//! search space with it, and prepends it to `$PATH` for every later script
//! and check hook in this run. The file lives under the state dir and is
//! deleted when the run ends, same private-temp-area treatment as the
//! `MOX_CHECK_FILE`/`MOX_CHECK_DIR` staging in `cli/apply.zig`.

const std = @import("std");

const Io = std.Io;

/// Absolute path of this run's `$MOX_PATH` file, under `state_dir`. Callers
/// create it empty at the start of a run and delete it (`Io.Dir.cwd().
/// deleteFile`) when the run ends -- it dies with the run, never left behind.
pub fn filePath(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, "mox-path" });
}

/// Incremental reader over the `$MOX_PATH` file: each call to `readNew`
/// returns only the lines appended since the previous call (or since the
/// file was created, on the first call), so a later stage's read never
/// reprocesses -- or re-warns about -- an earlier stage's lines.
pub const Reader = struct {
    path: []const u8,
    consumed_bytes: usize = 0,
    consumed_lines: usize = 0,

    /// Read whatever is new, validate each line, and return the valid
    /// absolute directories in file order. A relative or otherwise malformed
    /// line (blank lines aside, which are silently skipped like a `$PATH`
    /// segment) prints one stderr warning naming the file and its 1-based
    /// line number and is excluded -- never a silent drop. A missing file (no
    /// script ever wrote to it) yields no directories.
    pub fn readNew(self: *Reader, arena: std.mem.Allocator, io: Io, stderr: *std.Io.Writer) ![]const []const u8 {
        const bytes = Io.Dir.cwd().readFileAlloc(io, self.path, arena, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };
        if (bytes.len <= self.consumed_bytes) {
            self.consumed_bytes = bytes.len;
            return &.{};
        }
        const new_bytes = bytes[self.consumed_bytes..];
        self.consumed_bytes = bytes.len;

        // A trailing '\n' ends the last real line rather than starting a new
        // (still-empty) one: dropping it here keeps `consumed_lines` counting
        // actual file lines, not one extra per read that happens to land on a
        // newline boundary.
        const trailing_newline = new_bytes[new_bytes.len - 1] == '\n';
        const effective = if (trailing_newline) new_bytes[0 .. new_bytes.len - 1] else new_bytes;
        if (effective.len == 0) return &.{};

        var out: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, effective, '\n');
        while (lines.next()) |raw| {
            self.consumed_lines += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (!std.fs.path.isAbsolute(line)) {
                stderr.print(
                    "mox apply: {s}:{d}: MOX_PATH line is not an absolute directory path, ignored: {s}\n",
                    .{ self.path, self.consumed_lines, line },
                ) catch {};
                continue;
            }
            try out.append(arena, try arena.dupe(u8, line));
        }
        return out.toOwnedSlice(arena);
    }
};

/// `existing` (a `PATH` value, or null when unset) with `dirs` prepended, in
/// order, so a script or check hook spawned after this run's `$MOX_PATH`
/// additions finds them ahead of everything already on `PATH`. Returns
/// `existing` verbatim (duped) when `dirs` is empty.
pub fn prependToPath(arena: std.mem.Allocator, existing: ?[]const u8, dirs: []const []const u8) ![]const u8 {
    if (dirs.len == 0) return arena.dupe(u8, existing orelse "");
    var out: std.ArrayList(u8) = .empty;
    for (dirs) |d| {
        try out.appendSlice(arena, d);
        try out.append(arena, std.fs.path.delimiter);
    }
    if (existing) |e| try out.appendSlice(arena, e);
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

test "filePath: joins under state_dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try filePath(arena.allocator(), "/state");
    try testing.expectEqualStrings(try std.fs.path.join(arena.allocator(), &.{ "/state", "mox-path" }), p);
}

test "Reader.readNew: a missing file yields no directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err_aw: Io.Writer.Allocating = .init(a);

    var r: Reader = .{ .path = "/definitely/does/not/exist/mox-path" };
    const got = try r.readNew(a, testing.io, &err_aw.writer);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "Reader.readNew: valid absolute lines are returned in file order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "mox-path" });

    try tmp.dir.writeFile(io, .{ .sub_path = "mox-path", .data = "/one\n/two\n" });
    var err_aw: Io.Writer.Allocating = .init(a);
    var r: Reader = .{ .path = path };
    const got = try r.readNew(a, io, &err_aw.writer);

    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("/one", got[0]);
    try testing.expectEqualStrings("/two", got[1]);
    try testing.expectEqualStrings("", err_aw.writer.buffered());
}

test "Reader.readNew: a second call only sees lines appended since the first" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "mox-path" });

    try tmp.dir.writeFile(io, .{ .sub_path = "mox-path", .data = "/one\n" });
    var err_aw: Io.Writer.Allocating = .init(a);
    var r: Reader = .{ .path = path };
    const first = try r.readNew(a, io, &err_aw.writer);
    try testing.expectEqual(@as(usize, 1), first.len);

    // Append more, as a later stage's script would (via `Dir.writeFile`
    // rewriting the whole file, since this `Io` has no file-append mode --
    // the effect for the reader is identical to a real script's `>>`).
    try tmp.dir.writeFile(io, .{ .sub_path = "mox-path", .data = "/one\n/two\n" });
    const second = try r.readNew(a, io, &err_aw.writer);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqualStrings("/two", second[0]);
}

test "Reader.readNew: a relative line warns with the file and its line number, and is excluded" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "mox-path" });

    try tmp.dir.writeFile(io, .{ .sub_path = "mox-path", .data = "/good\nrelative/oops\n/also-good\n" });
    var err_aw: Io.Writer.Allocating = .init(a);
    var r: Reader = .{ .path = path };
    const got = try r.readNew(a, io, &err_aw.writer);

    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("/good", got[0]);
    try testing.expectEqualStrings("/also-good", got[1]);
    const warned = err_aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, warned, path) != null);
    try testing.expect(std.mem.indexOf(u8, warned, ":2:") != null);
    try testing.expect(std.mem.indexOf(u8, warned, "relative/oops") != null);
}

test "Reader.readNew: blank lines are skipped silently, no warning" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "mox-path" });

    try tmp.dir.writeFile(io, .{ .sub_path = "mox-path", .data = "/one\n\n/two\n" });
    var err_aw: Io.Writer.Allocating = .init(a);
    var r: Reader = .{ .path = path };
    const got = try r.readNew(a, io, &err_aw.writer);

    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("", err_aw.writer.buffered());
}

test "prependToPath: dirs join before the existing PATH, delimiter-separated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try prependToPath(a, "/usr/bin", &.{ "/new/one", "/new/two" });
    const want = try std.fmt.allocPrint(a, "/new/one{c}/new/two{c}/usr/bin", .{ std.fs.path.delimiter, std.fs.path.delimiter });
    try testing.expectEqualStrings(want, got);
}

test "prependToPath: no dirs returns the existing PATH unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try prependToPath(a, "/usr/bin", &.{});
    try testing.expectEqualStrings("/usr/bin", got);
}

test "prependToPath: a null existing PATH still yields the dirs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try prependToPath(a, null, &.{"/new/one"});
    const want = try std.fmt.allocPrint(a, "/new/one{c}", .{std.fs.path.delimiter});
    try testing.expectEqualStrings(want, got);
}
