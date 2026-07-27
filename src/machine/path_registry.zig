//! `data/paths.toml` (repo layer, private-shadowed): the same PATH registry
//! the dotfiles' own shell fragments render into `$PATH` doubles as the
//! tool-probe's extra search directories (D8) -- "gate says installed" and
//! "shell can run it" read the same rows, so they cannot diverge. Only the
//! `dir` and `when` fields matter here; `shells`/`prepend` are irrelevant to
//! an existence scan (they govern how a *real* `$PATH` string is built, a
//! concern this file's caller does not have) and are ignored.
//!
//! Row resolution here is a permissive, best-effort companion to the real
//! compose engine, not a duplicate of it: `data/paths.toml` is a generic
//! for-loop data source mox does not own the schema of (unlike
//! `data/facts.toml`), so a row this module cannot make sense of is skipped,
//! never a capture error. Only `<machine.NAME>` and `<env.NAME>` captures are
//! understood -- deliberately not the full `compose.interp` engine, since
//! `machine/` sits below `compose/` in the dependency graph.

const std = @import("std");
const toml = @import("../data/toml.zig");
const data_source = @import("../data/source.zig");
const path_lookup = @import("path_lookup.zig");
const state_mod = @import("state.zig");

const Io = std.Io;
const Environ = @import("env").Env;
const Fact = state_mod.Fact;

const RawRow = struct { dir: []const u8, when: ?[]const u8 = null };

/// Every `[[paths]]` row from `data/paths.toml` carrying a string `dir`,
/// paired with its optional `when` gate. A row with no (string) `dir` is
/// skipped -- permissively, since this schema is not mox's to enforce.
/// Missing file (either layer, or `repo_dir` itself empty) yields no rows.
fn loadRows(arena: std.mem.Allocator, io: Io, repo_dir: []const u8, private_dir: []const u8) ![]const RawRow {
    const content = (try data_source.readShadowed(arena, io, repo_dir, private_dir, "paths.toml")) orelse
        return &.{};
    const array_map = toml.parse(arena, content) catch return &.{};
    const records = array_map.get("paths") orelse return &.{};

    var rows: std.ArrayList(RawRow) = .empty;
    for (records) |rec| {
        const dir_v = rec.get("dir") orelse continue;
        if (dir_v != .string or dir_v.string.len == 0) continue;
        const when_v = rec.get("when");
        const when: ?[]const u8 = if (when_v != null and when_v.? == .string and when_v.?.string.len > 0)
            when_v.?.string
        else
            null;
        try rows.append(arena, .{ .dir = dir_v.string, .when = when });
    }
    return rows.toOwnedSlice(arena);
}

/// Resolve `data/paths.toml` into the directories that should widen the tool
/// probe's search space, in file order. `facts` is every fact this machine
/// already has bound (built-in scalar fields plus derived and machine-local
/// custom facts) -- both `<machine.NAME>` expansion and a `when` gate's
/// fact-presence check read from it. `base_probe` answers a `when` gate's
/// tool-presence check: it must be `$PATH`(+`$MOX_PATH`) ONLY, never a probe
/// already widened by this same resolution, so a row can never gate itself
/// (or another row) into existence -- one pass, no fixpoint.
pub fn resolve(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    repo_dir: []const u8,
    private_dir: []const u8,
    facts: []const Fact,
    base_probe: *path_lookup.ToolProbe,
) ![]const []const u8 {
    const rows = try loadRows(arena, io, repo_dir, private_dir);
    if (rows.len == 0) return &.{};

    var dirs: std.ArrayList([]const u8) = .empty;
    for (rows) |row| {
        if (row.when) |w| {
            if (!(base_probe.present(w) or factPresent(facts, w))) continue;
        }
        const expanded = (try expandForProbe(arena, row.dir, facts, environ)) orelse continue;
        if (expanded.len == 0) continue;
        try dirs.append(arena, expanded);
    }
    return dirs.toOwnedSlice(arena);
}

fn factPresent(facts: []const Fact, name: []const u8) bool {
    for (facts) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value.len > 0;
    }
    return false;
}

fn factLookup(facts: []const Fact, name: []const u8) ?[]const u8 {
    for (facts) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

/// Expand every `<machine.NAME>` / `<env.NAME>` placeholder in `tmpl`
/// against `facts` / `environ`. Null when a placeholder names something
/// unresolvable (unbound fact, unset env var) or unsupported (any other
/// capture form, e.g. `<data.X>`) -- the row is skipped rather than composed
/// with a hole in it.
fn expandForProbe(arena: std.mem.Allocator, tmpl: []const u8, facts: []const Fact, environ: Environ) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < tmpl.len) {
        const open = std.mem.indexOfScalarPos(u8, tmpl, i, '<') orelse {
            try out.appendSlice(arena, tmpl[i..]);
            break;
        };
        try out.appendSlice(arena, tmpl[i..open]);
        const close = std.mem.indexOfScalarPos(u8, tmpl, open, '>') orelse return null;
        const inner = tmpl[open + 1 .. close];
        if (std.mem.startsWith(u8, inner, "machine.")) {
            const field = inner[8..];
            const v = factLookup(facts, field) orelse return null;
            try out.appendSlice(arena, v);
        } else if (std.mem.startsWith(u8, inner, "env.")) {
            const name = inner[4..];
            const v = environ.getAlloc(arena, name) catch null;
            if (v == null or v.?.len == 0) return null;
            try out.appendSlice(arena, v.?);
        } else {
            return null;
        }
        i = close + 1;
    }
    return try out.toOwnedSlice(arena);
}

test "loadRows: missing file returns no rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try loadRows(arena.allocator(), std.testing.io, "", "");
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "loadRows: a row with no dir is skipped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/paths.toml",
        .data = "[[paths]]\nwhen = \"brew\"\n\n[[paths]]\ndir = \"/usr/local/bin\"\n",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    const r = try loadRows(a, io, repo, "");
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("/usr/local/bin", r[0].dir);
}

fn baseProbe(a: std.mem.Allocator, io: Io, environ: Environ) !path_lookup.ToolProbe {
    return path_lookup.ToolProbe.init(a, io, environ);
}

test "resolve: a literal dir with no when is included unconditionally" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/paths.toml", .data = "[[paths]]\ndir = \"/usr/local/bin\"\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    const environ: Environ = .{ .map = &map };
    var probe = try baseProbe(a, io, environ);

    const dirs = try resolve(a, io, environ, repo, "", &.{}, &probe);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expectEqualStrings("/usr/local/bin", dirs[0]);
}

test "resolve: a machine capture expands against a bound fact" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/paths.toml", .data = "[[paths]]\ndir = \"<machine.brew_prefix>/bin\"\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    const environ: Environ = .{ .map = &map };
    var probe = try baseProbe(a, io, environ);
    const facts = [_]Fact{.{ .name = "brew_prefix", .value = "/opt/homebrew" }};

    const dirs = try resolve(a, io, environ, repo, "", &facts, &probe);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expectEqualStrings("/opt/homebrew/bin", dirs[0]);
}

test "resolve: an unbound machine capture skips the row instead of erroring" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/paths.toml", .data = "[[paths]]\ndir = \"<machine.brew_prefix>/bin\"\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    const environ: Environ = .{ .map = &map };
    var probe = try baseProbe(a, io, environ);

    const dirs = try resolve(a, io, environ, repo, "", &.{}, &probe);
    try std.testing.expectEqual(@as(usize, 0), dirs.len);
}

test "resolve: a when gate on fact presence includes only once the fact is bound" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/paths.toml",
        .data = "[[paths]]\ndir = \"/opt/homebrew/bin\"\nwhen = \"brew_prefix\"\n",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    const environ: Environ = .{ .map = &map };
    var probe = try baseProbe(a, io, environ);

    const without = try resolve(a, io, environ, repo, "", &.{}, &probe);
    try std.testing.expectEqual(@as(usize, 0), without.len);

    const facts = [_]Fact{.{ .name = "brew_prefix", .value = "/opt/homebrew" }};
    const with = try resolve(a, io, environ, repo, "", &facts, &probe);
    try std.testing.expectEqual(@as(usize, 1), with.len);
}

test "resolve: a when tool-gate evaluates against the base layer only, never a row-contributed dir (no fixpoint)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "only-dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "only-dir/herdr", .data = "" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const only_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "only-dir" });

    // Row A contributes a dir that has "herdr" -- but NOT on the real $PATH.
    // Row B is gated on "herdr" being a tool. If the when-check saw row A's
    // dir, row B would wrongly resolve true; it must not.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/paths.toml",
        .data = try std.fmt.allocPrint(
            a,
            "[[paths]]\ndir = \"{s}\"\n\n[[paths]]\ndir = \"/usr/local/other\"\nwhen = \"herdr\"\n",
            .{only_dir},
        ),
    });

    var map = std.process.Environ.Map.init(a);
    const environ: Environ = .{ .map = &map };
    var probe = try baseProbe(a, io, environ);

    const dirs = try resolve(a, io, environ, repo, "", &.{}, &probe);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expectEqualStrings(only_dir, dirs[0]);
}

test "resolve: shells/prepend fields are irrelevant to inclusion" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/paths.toml",
        .data = "[[paths]]\ndir = \"/only/fish\"\nshells = [\"fish\"]\nprepend = true\n",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    var map = std.process.Environ.Map.init(a);
    const environ: Environ = .{ .map = &map };
    var probe = try baseProbe(a, io, environ);

    const dirs = try resolve(a, io, environ, repo, "", &.{}, &probe);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expectEqualStrings("/only/fish", dirs[0]);
}

test "resolve: registry absent contributes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = std.process.Environ.Map.init(a);
    const environ: Environ = .{ .map = &map };
    var probe = try baseProbe(a, std.testing.io, environ);

    const dirs = try resolve(a, std.testing.io, environ, "", "", &.{}, &probe);
    try std.testing.expectEqual(@as(usize, 0), dirs.len);
}
