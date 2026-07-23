const std = @import("std");
const mox = @import("mox");

const Io = std.Io;

fn writeFile(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

/// Build the absolute path to `<tmp>/src` using `tmp.parent_dir` to compute the
/// canonical `<cwd>/.zig-cache/tmp/<sub_path>` location.
fn srcPathAlloc(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const io = std.testing.io;
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "src" });
}

test "walk: returns files in a total order, not the filesystem's" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Created in an order that is neither sorted nor reverse-sorted, so a walk
    // that simply echoed creation or directory-iteration order would not match.
    // Iteration order is the FILESYSTEM's -- APFS and ext4 hand back the same
    // directory differently -- and every command walks this slice, so status
    // and diff would list files, and commit would prompt for them, in a
    // machine-dependent order.
    try writeFile(io, tmp.dir, "src/.zshrc", "z\n");
    try writeFile(io, tmp.dir, "src/.bashrc", "b\n");
    try writeFile(io, tmp.dir, "src/.config/nvim/init.lua", "n\n");
    try writeFile(io, tmp.dir, "src/.aliases", "a\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 4), result.files.len);
    var prev: []const u8 = "";
    for (result.files) |f| {
        try std.testing.expect(std.mem.lessThan(u8, prev, f.live_path));
        prev = f.live_path;
    }
}

test "walk: finds a single managed file with no .d directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zshrc", "export EDITOR=nvim\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expect(result.files[0].has_base);
    try std.testing.expectEqual(@as(usize, 0), result.files[0].overlays.len);
    try std.testing.expectEqual(@as(usize, 0), result.files[0].regions.len);
}

test "walk: orphan .d/ without axis-named files is regular subdir (Gap 6)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ~/.config/fish/conf.d/abbreviations.fish is a real fish autoload file,
    // not a mox overlay. Without this fix, mox saw `conf.d/` and invented a
    // phantom `conf` managed file, hiding `abbreviations.fish` from the walk.
    try writeFile(io, tmp.dir, "src/.config/fish/conf.d/abbreviations.fish", "abbr -a foo bar\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), tree.files.len);
    // The managed file should be the real abbreviations.fish, not a phantom
    // `conf` (which would lose the actual file).
    try std.testing.expect(std.mem.endsWith(u8, tree.files[0].source_base_path, "/abbreviations.fish"));
    try std.testing.expect(tree.files[0].has_base);
}

test "walk: finds managed file with category-A overlays" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/os=darwin", "[gpg]\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/profile=work", "[user]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqual(@as(usize, 2), result.files[0].overlays.len);
    try std.testing.expectEqual(@as(usize, 0), result.files[0].regions.len);
}

test "walk: finds managed file with category-B regions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/role.lua", "local M = {}\nreturn M\n");
    try writeFile(io, tmp.dir, "src/role.lua.d/profile/work.lua", "M.kind = \"work\"\n");
    try writeFile(io, tmp.dir, "src/role.lua.d/profile/personal.lua", "M.kind = \"personal\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqual(@as(usize, 0), result.files[0].overlays.len);
    try std.testing.expectEqual(@as(usize, 1), result.files[0].regions.len);
    try std.testing.expectEqualStrings("profile", result.files[0].regions[0].name);
    try std.testing.expectEqual(@as(usize, 2), result.files[0].regions[0].fragments.len);
}

test "walk: a fragment filename is a candidate axis value in its own right" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `darwin.sh` stands for `os=darwin` with an extension; `host.local` stands
    // for the whole name, because a hostname contains dots. The filename alone
    // cannot say which, so the walk carries both readings and the matcher
    // settles it against the bindings.
    try writeFile(io, tmp.dir, "src/.zshrc", "x\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/os/darwin.sh", "a\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/machine/host.local", "b\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/machine/plain", "c\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    for (result.files[0].regions) |region| {
        for (region.fragments) |frag| {
            if (std.mem.endsWith(u8, frag.path, "darwin.sh")) {
                try std.testing.expectEqualStrings("darwin", frag.tuple.pairs[0].value);
                try std.testing.expectEqualStrings("darwin.sh", frag.exact_tuple.?.pairs[0].value);
            } else if (std.mem.endsWith(u8, frag.path, "host.local")) {
                try std.testing.expectEqualStrings("host", frag.tuple.pairs[0].value);
                try std.testing.expectEqualStrings("host.local", frag.exact_tuple.?.pairs[0].value);
            } else if (std.mem.endsWith(u8, frag.path, "plain")) {
                // Nothing to strip: there is only one reading.
                try std.testing.expectEqualStrings("plain", frag.tuple.pairs[0].value);
                try std.testing.expect(frag.exact_tuple == null);
            } else {
                return error.UnexpectedFragment;
            }
        }
    }
}

test "walk: an overlay filename is a candidate axis value in its own right" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `os=darwin.toml` stands for `os=darwin` with an extension; `machine=host.local`
    // stands for the whole value, because a hostname contains dots. The filename
    // alone cannot say which, so the walk carries both readings and the matcher
    // settles it against the bindings.
    try writeFile(io, tmp.dir, "src/config.toml", "x = 1\n");
    try writeFile(io, tmp.dir, "src/config.toml.d/os=darwin.toml", "a = 1\n");
    try writeFile(io, tmp.dir, "src/config.toml.d/machine=host.local", "b = 1\n");
    try writeFile(io, tmp.dir, "src/config.toml.d/profile=personal", "c = 1\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    for (result.files[0].overlays) |ov| {
        if (std.mem.endsWith(u8, ov.path, "os=darwin.toml")) {
            try std.testing.expectEqualStrings("darwin", ov.tuple.pairs[0].value);
            try std.testing.expectEqualStrings("darwin.toml", ov.exact_tuple.?.pairs[0].value);
        } else if (std.mem.endsWith(u8, ov.path, "machine=host.local")) {
            try std.testing.expectEqualStrings("host", ov.tuple.pairs[0].value);
            try std.testing.expectEqualStrings("host.local", ov.exact_tuple.?.pairs[0].value);
        } else if (std.mem.endsWith(u8, ov.path, "profile=personal")) {
            // Nothing to strip: there is only one reading.
            try std.testing.expectEqualStrings("personal", ov.tuple.pairs[0].value);
            try std.testing.expect(ov.exact_tuple == null);
        } else {
            return error.UnexpectedOverlay;
        }
    }
}

test "walk: ignores junk files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zshrc", "");
    try writeFile(io, tmp.dir, "src/.DS_Store", "");
    try writeFile(io, tmp.dir, "src/.zshrc.swp", "");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
}

test "walk: orphan .d directory (whole-file axis gating)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml.d/os=darwin.toml", "[gaps]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expect(!result.files[0].has_base);
    try std.testing.expectEqual(@as(usize, 1), result.files[0].overlays.len);
}

test "walk: refuses symlinks in source tree" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zshrc", "");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.symLink(io, "/etc/passwd", "src/.bad", .{});

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectError(error.SymlinkInSource, result);
}
