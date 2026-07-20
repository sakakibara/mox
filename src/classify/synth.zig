//! Region synthesis: turn a base-file edit routed to an axis into a
//! `replace from "<region>"` region plus two fragments.
//!
//! When `mox commit` routes a shared base edit to an axis pair the base has no
//! region for yet, it wraps the edited base lines in a region directive: the
//! ORIGINAL lines become the universal fallback body (every machine that does
//! not match the axis keeps them), and the NEW lines are written as the axis
//! fragment at `<file>.d/<region>/<value><ext>` (machines matching `region=value`
//! pick it up). This is the one place commit edits the base's directive
//! structure, so the plan is always previewed before it is written.

const std = @import("std");
const diff = @import("../diff/root.zig");
const dsl = @import("../dsl/root.zig");

const Io = std.Io;

const max_base_bytes: usize = 64 * 1024 * 1024;

pub const Plan = struct {
    /// 0-based base line range the region block replaces (the edit's own range).
    start: u32,
    del: u32,
    /// The region block: the directive line, the ORIGINAL base lines, the end
    /// line. A SPLICE, not a whole-file image: the base it lands in is read at
    /// write time, so several edits to one base compose instead of one
    /// overwriting the other with a snapshot taken before it.
    base_lines: []const []const u8,
    /// Absolute path of the axis fragment to create.
    fragment_path: []const u8,
    /// Content for that fragment (the new lines).
    fragment_content: []const u8,
    /// The region directive line inserted into the base (for preview).
    directive_line: []const u8,
    region: []const u8,
    value: []const u8,
};

/// Why synthesizing a `<region>` region over the base lines `[start, start+del)`
/// would corrupt the file or destroy existing data. Callers must refuse such a
/// narrowing outright:
///
/// - The directive line takes the position of the first wrapped line, so
///   wrapping line 1 pushes a shebang below it (the script stops being
///   executable) and displaces a whole-file `when` gate from the top of the
///   file, silently disabling it.
/// - Fragments are keyed by region NAME, so a second region of a name the file
///   already uses shares the first one's `.d/<region>/` directory: the fragment
///   synthesized here would ALSO be picked up by the pre-existing region,
///   replacing its body on every machine that matches the value.
/// - A fragment file may already sit at the exact path synthesis would write
///   (a leftover with no directive claiming its region name). No configuration
///   reads an unclaimed fragment, so nothing in the impact analysis notices
///   the overwrite: the leftover's content would be lost silently.
pub const Hazard = union(enum) {
    first_line,
    shebang,
    region_taken: []const u8,
    fragment_exists: []const u8,

    pub fn message(h: Hazard, arena: std.mem.Allocator) ![]const u8 {
        return switch (h) {
            .first_line => "a region cannot wrap the first line of a file",
            .shebang => "a region cannot wrap a shebang line",
            .region_taken => |name| try std.fmt.allocPrint(
                arena,
                "the file already has a region named \"{s}\", which would pick up the new fragment too",
                .{name},
            ),
            .fragment_exists => |path| try std.fmt.allocPrint(
                arena,
                "a fragment already exists at \"{s}\"; synthesizing here would overwrite it",
                .{path},
            ),
        };
    }
};

/// The hazard in narrowing `[start, start+del)` of `base_content` to a
/// `<region>` region valued `value`, or null when the synthesis is safe.
/// `marker` is the file's comment marker and `base_abs` the base file's
/// absolute path, both as passed to `planRegion`.
pub fn hazardOf(
    arena: std.mem.Allocator,
    io: Io,
    base_abs: []const u8,
    base_content: []const u8,
    marker: []const u8,
    start: u32,
    del: u32,
    region: []const u8,
    value: []const u8,
) !?Hazard {
    if (start == 0) return .first_line;
    const lines = try diff.lines.splitLines(arena, base_content);
    const s = @min(@as(usize, start), lines.len);
    const e = @min(s + @as(usize, del), lines.len);
    for (lines[s..e]) |l| {
        if (std.mem.startsWith(u8, l, "#!")) return .shebang;
    }
    const parsed = try dsl.driver.parseFile(arena, base_content, marker, null);
    for (parsed.directives) |d| {
        const dir_name: ?[]const u8 = switch (d.kind) {
            .replace => |r| r.from,
            .from => |f| f.dir,
            else => null,
        };
        if (dir_name) |n| {
            if (std.mem.eql(u8, n, region)) return .{ .region_taken = n };
        }
    }
    const fragment_path = try fragmentPathFor(arena, base_abs, region, value);
    const exists = blk: {
        Io.Dir.cwd().access(io, fragment_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists) return .{ .fragment_exists = fragment_path };
    return null;
}

/// Build the synthesis plan. `base_abs` is the base file's absolute path (used
/// to derive the `.d/` fragment location and extension); `start`/`del` are the
/// 0-based base line range the edit replaced; `new_lines` is the edited text.
/// The caller must have cleared `hazardOf` for the same range.
pub fn planRegion(
    arena: std.mem.Allocator,
    base_abs: []const u8,
    base_content: []const u8,
    marker: []const u8,
    start: u32,
    del: u32,
    new_lines: []const []const u8,
    region: []const u8,
    value: []const u8,
) !Plan {
    const lines = try diff.lines.splitLines(arena, base_content);
    const s = @min(@as(usize, start), lines.len);
    const e = @min(s + @as(usize, del), lines.len);
    const old_lines = lines[s..e];

    const directive_line = try std.fmt.allocPrint(arena, "{s} mox: replace from \"{s}\"", .{ marker, region });
    const end_line = try std.fmt.allocPrint(arena, "{s} mox: end", .{marker});

    // The region body is the ORIGINAL lines wrapped by the directive markers.
    var region_block: std.ArrayList([]const u8) = .empty;
    try region_block.append(arena, directive_line);
    for (old_lines) |l| try region_block.append(arena, l);
    try region_block.append(arena, end_line);

    return .{
        .start = start,
        .del = del,
        .base_lines = try region_block.toOwnedSlice(arena),
        .fragment_path = try fragmentPathFor(arena, base_abs, region, value),
        .fragment_content = try joinLines(arena, new_lines, true),
        .directive_line = directive_line,
        .region = region,
        .value = value,
    };
}

/// Write a base file's synthesized regions: `base_content` (its bytes with every
/// plan's region block already spliced in, composed by the caller against the
/// CURRENT base) and one axis fragment per plan, creating the region
/// directories. Callers write only after every prompt.
///
/// All-or-nothing: a failure partway leaves neither a region without its
/// fragment nor a fragment without its region -- the base returns to its
/// pre-call bytes and every fragment and region directory this call created is
/// removed.
pub fn materialize(
    arena: std.mem.Allocator,
    io: Io,
    base_abs: []const u8,
    base_content: []const u8,
    plans: []const Plan,
) !void {
    const prior = try Io.Dir.cwd().readFileAlloc(io, base_abs, arena, .limited(max_base_bytes));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = base_abs, .data = base_content });

    const Created = struct { fragment: []const u8, dir: ?[]const u8 };
    var created: std.ArrayList(Created) = .empty;
    errdefer {
        for (created.items) |c| {
            Io.Dir.cwd().deleteFile(io, c.fragment) catch {};
            if (c.dir) |d| Io.Dir.cwd().deleteTree(io, d) catch {};
        }
        Io.Dir.cwd().writeFile(io, .{ .sub_path = base_abs, .data = prior }) catch {};
    }

    for (plans) |plan| {
        const made_dir = missingAncestor(io, plan.fragment_path);
        try created.append(arena, .{ .fragment = plan.fragment_path, .dir = made_dir });
        if (std.fs.path.dirname(plan.fragment_path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = plan.fragment_path, .data = plan.fragment_content });
    }
}

/// The topmost directory that has to be created to hold `path`, or null when
/// its parent already exists. Removing it removes EVERY directory the write
/// creates, so a rollback leaves no empty `.d/` shell behind.
pub fn missingAncestor(io: Io, path: []const u8) ?[]const u8 {
    var topmost: ?[]const u8 = null;
    var dir = std.fs.path.dirname(path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const exists = blk: {
            Io.Dir.cwd().access(io, d, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) break;
        topmost = d;
    }
    return topmost;
}

/// Absolute path of the axis fragment a `<region>`/`<value>` narrowing of
/// `base_abs` would write, matching the layout `planRegion` synthesizes.
fn fragmentPathFor(arena: std.mem.Allocator, base_abs: []const u8, region: []const u8, value: []const u8) ![]const u8 {
    const ext = baseExtension(base_abs);
    const fragment_name = try std.fmt.allocPrint(arena, "{s}{s}", .{ value, ext });
    // base_abs is a native path this fragment is written to and read back from,
    // so the overlay path must use the native separator, not a portable key's.
    const overlay_dir = try std.fmt.allocPrint(arena, "{s}.d", .{base_abs});
    return std.fs.path.join(arena, &.{ overlay_dir, region, fragment_name });
}

fn joinLines(arena: std.mem.Allocator, lines: []const []const u8, trailing_nl: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines, 0..) |l, i| {
        if (i > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, l);
    }
    if (trailing_nl and lines.len > 0) try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// Extension of a base filename, INCLUDING the leading dot, or "" when there
/// is none. A dotfile with no further dot (`.zshrc`) has no extension; a real
/// extension (`init.lua` -> `.lua`) is preserved so the fragment composes with
/// the right comment dialect.
fn baseExtension(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (basename.len == 0) return "";
    if (basename[0] == '.') {
        const rest = basename[1..];
        if (std.mem.indexOfScalar(u8, rest, '.') == null) return "";
    }
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return "";
    return basename[dot..];
}

const testing = std.testing;
const source = @import("../source/root.zig");
const compose = @import("../compose/root.zig");

test "planRegion: wraps the edited base lines in a splice and names the fragment by value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plan = try planRegion(
        a,
        "/abs/src/.zshrc",
        "export A=1\nexport KEY=old\nexport B=2\n",
        "#",
        1,
        1,
        &.{"export KEY=new"},
        "profile",
        "work",
    );
    // The plan is a splice of the edit's OWN line range -- never a whole-file
    // image, which would revert whatever else the same commit wrote to the base.
    try testing.expectEqual(@as(u32, 1), plan.start);
    try testing.expectEqual(@as(u32, 1), plan.del);
    try testing.expectEqual(@as(usize, 3), plan.base_lines.len);
    try testing.expectEqualStrings("# mox: replace from \"profile\"", plan.base_lines[0]);
    try testing.expectEqualStrings("export KEY=old", plan.base_lines[1]);
    try testing.expectEqualStrings("# mox: end", plan.base_lines[2]);
    const expected_frag = try std.fs.path.join(a, &.{ "/abs/src/.zshrc.d", "profile", "work" });
    try testing.expectEqualStrings(expected_frag, plan.fragment_path);
    try testing.expectEqualStrings("export KEY=new\n", plan.fragment_content);
}

test "hazardOf: line 1 and a shebang are refused, an interior plain line is not" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const script = "#!/bin/sh\nexport A=1\nexport B=2\n";
    // Line 1 can never be wrapped: the directive would displace it.
    try testing.expect((try hazardOf(a, io, "/abs/src/script.sh", script, "#", 0, 1, "os", "darwin")).? == .first_line);
    // A pure insertion at the top is line 1 just the same.
    try testing.expect((try hazardOf(a, io, "/abs/src/script.sh", script, "#", 0, 0, "os", "darwin")).? == .first_line);
    // An interior line is safe.
    try testing.expectEqual(@as(?Hazard, null), try hazardOf(a, io, "/abs/src/script.sh", script, "#", 1, 1, "os", "darwin"));
    // A shebang that somehow sits below line 1 is still never wrappable.
    try testing.expect((try hazardOf(a, io, "/abs/src/script.sh", "export A=1\n#!/bin/sh\n", "#", 1, 1, "os", "darwin")).? == .shebang);
}

test "hazardOf: a region name the file already uses is refused, another name is not" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "export A=1\n" ++
        "export EDITOR=vim\n" ++
        "# mox: replace from \"os\"\n" ++
        "export PAGER=less\n" ++
        "# mox: end\n";
    // A second `os` region would share `.d/os/` with the first: the fragment
    // synthesized for `export EDITOR` would replace the existing region's body.
    const hz = (try hazardOf(a, io, "/abs/src/.zshrc", src, "#", 1, 1, "os", "darwin")).?;
    try testing.expect(hz == .region_taken);
    try testing.expectEqualStrings("os", hz.region_taken);
    // A region name the file does not use yet is free.
    try testing.expectEqual(@as(?Hazard, null), try hazardOf(a, io, "/abs/src/.zshrc", src, "#", 1, 1, "profile", "work"));
    // The bare `from` shorthand claims the name just the same.
    const bare = "export A=1\nexport EDITOR=vim\n# mox: from \"profile\"\nexport PAGER=less\n# mox: end\n";
    try testing.expect((try hazardOf(a, io, "/abs/src/.zshrc", bare, "#", 1, 1, "profile", "work")).? == .region_taken);
}

test "hazardOf: a leftover fragment file at the write path is refused, a free path is not" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "src/.zshrc.d/os");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc.d/os/darwin", .data = "leftover, unclaimed by any directive\n" });
    const cwd = try std.process.currentPathAlloc(io, a);
    const src_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "src" });
    const base_abs = try std.fs.path.join(a, &.{ src_dir, ".zshrc" });

    const content = "export A=1\nexport EDITOR=vim\nexport B=2\n";
    // "os"/"darwin" would write over the leftover fragment: refused.
    const hz = (try hazardOf(a, io, base_abs, content, "#", 1, 1, "os", "darwin")).?;
    try testing.expect(hz == .fragment_exists);
    // A value with no fragment on disk yet is free.
    try testing.expectEqual(@as(?Hazard, null), try hazardOf(a, io, base_abs, content, "#", 1, 1, "os", "linux"));
}

test "baseExtension: dotfile has none, real extension is kept" {
    try testing.expectEqualStrings("", baseExtension("/x/.zshrc"));
    try testing.expectEqualStrings(".lua", baseExtension("/x/init.lua"));
    try testing.expectEqualStrings("", baseExtension("/x/.gitconfig"));
}

test "synthesized region recomposes to the fallback for one profile and the fragment for the other" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc", .data = "export A=1\nexport KEY=old\nexport B=2\n" });
    const cwd = try std.process.currentPathAlloc(io, a);
    const src_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "src" });
    const base_abs = try std.fs.path.join(a, &.{ src_dir, ".zshrc" });

    const base_content = try Io.Dir.cwd().readFileAlloc(io, base_abs, a, .limited(1 << 20));
    const plan = try planRegion(a, base_abs, base_content, "#", 1, 1, &.{"export KEY=new"}, "profile", "work");
    const spliced = "export A=1\n# mox: replace from \"profile\"\nexport KEY=old\n# mox: end\nexport B=2\n";
    try materialize(a, io, base_abs, spliced, &.{plan});

    // Rewalk so the new region is picked up, then compose per profile.
    const tree = try source.tree.walk(a, io, src_dir, "/home/me");
    try testing.expectEqual(@as(usize, 1), tree.files.len);
    const file = tree.files[0];

    var personal = std.StringHashMap([]const u8).init(a);
    try personal.put("profile", "personal");
    const personal_out = (try compose.composeFile(a, io, file, &personal, null, null)).?;
    try testing.expectEqualStrings("export A=1\nexport KEY=old\nexport B=2\n", personal_out);

    var work = std.StringHashMap([]const u8).init(a);
    try work.put("profile", "work");
    const work_out = (try compose.composeFile(a, io, file, &work, null, null)).?;
    try testing.expectEqualStrings("export A=1\nexport KEY=new\nexport B=2\n", work_out);
}

test "materialize: a failure writing the fragment restores the base and leaves no region behind" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A regular FILE where the region directory would go: creating
    // `.zshrc.d/profile/` under it must fail, part-way through the write.
    try tmp.dir.createDirPath(io, "src");
    const original = "export A=1\nexport KEY=old\nexport B=2\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc", .data = original });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc.d", .data = "not a directory\n" });
    const cwd = try std.process.currentPathAlloc(io, a);
    const src_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "src" });
    const base_abs = try std.fs.path.join(a, &.{ src_dir, ".zshrc" });

    const plan = try planRegion(a, base_abs, original, "#", 1, 1, &.{"export KEY=new"}, "profile", "work");
    const spliced = "export A=1\n# mox: replace from \"profile\"\nexport KEY=old\n# mox: end\nexport B=2\n";
    try testing.expectError(error.NotDir, materialize(a, io, base_abs, spliced, &.{plan}));

    // All-or-nothing: the base never keeps a region whose fragment does not
    // exist, so it is back to its exact pre-call bytes.
    try testing.expectEqualStrings(original, try Io.Dir.cwd().readFileAlloc(io, base_abs, a, .limited(1 << 20)));
}
